Set-StrictMode -Version Latest

$script:CorePath = $PSScriptRoot
Import-Module -Name (Join-Path $script:CorePath 'filesystem.psm1') -ErrorAction Stop
Import-Module -Name (Join-Path $script:CorePath 'environment.psm1') -ErrorAction Stop
Import-Module -Name (Join-Path $script:CorePath 'catalog.psm1') -ErrorAction Stop

# Plan store. A plan is the only object that can authorize a deletion: it is
# sealed with a checksum, bound to the user SID, scoped to one class, and
# expiring. Nothing here decides what is junk; that is the class modules' job.

$script:PlanRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'SystemOptimizer\plans'
$script:PlanLifetimeHours = 24
$script:SchemaVersion = 2

# Overridable so tests can isolate the store without touching the real one.
function Set-PlanStoreRoot {
    param([Parameter(Mandatory)][string] $Path)
    $script:PlanRoot = $Path
}

function Get-PlanStoreRoot {
    return $script:PlanRoot
}

function Initialize-PlanStore {
    $parent = Split-Path -Parent $script:PlanRoot
    foreach ($directory in @($parent, $script:PlanRoot)) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            New-Item -Path $directory -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        $item = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The local cleanup plan folder is redirected. No files were changed.'
        }
    }
}

function Remove-PreviousCleanupPlans {
    if (-not (Test-Path -LiteralPath $script:PlanRoot -PathType Container)) { return }
    Initialize-PlanStore

    foreach ($file in Get-ChildItem -LiteralPath $script:PlanRoot -Force -File -ErrorAction Stop) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        if ($file.Name -match '^[0-9a-fA-F]{32}\.json(\.sha256)?$') {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
        }
    }
}

function Remove-CleanupPlanMetadata {
    param([Parameter(Mandatory)][string] $PlanId)

    if ($PlanId -notmatch '^[0-9a-fA-F]{32}$') { throw 'The cleanup plan ID is invalid.' }
    if (-not (Test-Path -LiteralPath $script:PlanRoot -PathType Container)) { return }
    Initialize-PlanStore

    foreach ($path in @((Join-Path $script:PlanRoot "$PlanId.json"), (Join-Path $script:PlanRoot "$PlanId.json.sha256"))) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'The cleanup plan metadata is redirected.' }
        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
    }
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)][byte[]] $Bytes)

    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString($hasher.ComputeHash($Bytes)).Replace('-', '')
    }
    finally {
        $hasher.Dispose()
    }
}

function Write-CleanupPlan {
    param(
        [Parameter(Mandatory)] $Plan,
        [Parameter(Mandatory)][string] $PlanId
    )

    Initialize-PlanStore
    $planPath = Join-Path $script:PlanRoot "$PlanId.json"
    $encoding = [Text.UTF8Encoding]::new($false)
    $bytes = $encoding.GetBytes(($Plan | ConvertTo-Json -Depth 8))
    [IO.File]::WriteAllBytes($planPath, $bytes)
    [IO.File]::WriteAllText("$planPath.sha256", (Get-Sha256Hex -Bytes $bytes), $encoding)
}

function New-SystemCleanupPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]] $ClassId,
        [string[]] $OptIn,
        [switch] $Reload
    )

    $null = Assert-StandardUserContext
    $catalog = @{}
    foreach ($definition in (Get-CleanupCatalog -Reload:$Reload)) {
        $catalog[[string]$definition.Id] = $definition
    }

    $requested = @($ClassId | Select-Object -Unique)
    foreach ($id in $requested) {
        if (-not $catalog.ContainsKey($id)) {
            throw "Unknown cleanup class '$id'. Known classes: $($catalog.Keys -join ', ')."
        }
        # Opt-in is checked here, before any scan, so a Review category is never
        # even measured unless the caller asked for it by name.
        Assert-ClassOptIn -Id $id -OptIn $OptIn
    }

    Remove-PreviousCleanupPlans

    $sections = [System.Collections.Generic.List[object]]::new()
    $blocked = [System.Collections.Generic.List[object]]::new()
    $notApplicable = [System.Collections.Generic.List[object]]::new()

    foreach ($id in $requested) {
        $definition = $catalog[$id]
        $entry = Resolve-CleanupClass -Id $id

        $ready = Test-ClassReady -Entry $entry -Id $id
        if (-not $ready.Ready) {
            $titleEn = if ($definition.PSObject.Properties['TitleEn']) { [string]$definition.TitleEn } else { $null }
            $blocked.Add([pscustomobject]@{ ClassId = $id; Title = $definition.Title; TitleEn = $titleEn; Reason = $ready.Reason })
            continue
        }

        $cutoffUtc = [DateTime]::UtcNow.AddDays(-[int]$definition.MinAgeDays)
        try {
            $collected = Invoke-ClassCollector -Entry $entry -CutoffUtc $cutoffUtc
        }
        catch {
            $titleEn = if ($definition.PSObject.Properties['TitleEn']) { [string]$definition.TitleEn } else { $null }
            $notApplicable.Add([pscustomobject]@{ ClassId = $id; Title = $definition.Title; TitleEn = $titleEn; Reason = $_.Exception.Message })
            continue
        }

        $titleEn = if ($definition.PSObject.Properties['TitleEn']) { [string]$definition.TitleEn } else { $null }
        if ($null -eq $collected) {
            $notApplicable.Add([pscustomobject]@{ ClassId = $id; Title = $definition.Title; TitleEn = $titleEn; Reason = '这台电脑上不存在该类别的缓存目录，已跳过。' })
            continue
        }

        $bytes = [long]0
        foreach ($candidate in $collected.Candidates) { $bytes += [long]$candidate.Length }
        if ($collected.Candidates.Count -eq 0) {
            $notApplicable.Add([pscustomobject]@{ ClassId = $id; Title = $definition.Title; TitleEn = $titleEn; Reason = "没有超过 $($definition.MinAgeDays) 天未修改的文件，已跳过。" })
            continue
        }

        $impactEn = if ($definition.PSObject.Properties['ImpactEn']) { [string]$definition.ImpactEn } else { $null }
        $sections.Add([pscustomobject]@{
            ClassId = $id
            Title = $definition.Title
            TitleEn = $titleEn
            Risk = $definition.Risk
            MinAgeDays = [int]$definition.MinAgeDays
            Impact = $definition.Impact
            ImpactEn = $impactEn
            RequiresExplicitOptIn = [bool]$definition.RequiresExplicitOptIn
            Roots = @($collected.Roots)
            CandidateCount = $collected.Candidates.Count
            EstimatedBytes = $bytes
            EstimatedSize = Format-ByteCount $bytes
            SkippedReparsePoints = $collected.SkippedReparsePoints
            SkippedReadErrors = $collected.SkippedReadErrors
            Candidates = @($collected.Candidates)
        })
    }

    $totalBytes = [long]0
    $totalCount = 0
    foreach ($section in $sections) {
        $totalBytes += [long]$section.EstimatedBytes
        $totalCount += [int]$section.CandidateCount
    }
    if ($sections.Count -gt 0) { $totalBytes = [long]$totalBytes }

    $focusPath = $null
    foreach ($section in $sections) {
        if ($section.Roots.Count -gt 0) { $focusPath = $section.Roots[0]; break }
    }
    $freeBefore = $null
    if ($focusPath) {
        $profileRoot = Get-UserLocalAppData
        $freeBefore = Get-DriveFreeBytes -Path $profileRoot
    }

    $result = [ordered]@{
        PlanId = $null
        Classes = @($requested)
        ClassCount = $sections.Count
        CandidateCount = $totalCount
        EstimatedBytes = $totalBytes
        EstimatedSize = (Format-ByteCount $totalBytes)
        FreeBytesBefore = $freeBefore
        Sections = @($sections | ForEach-Object {
            $secTitleEn = if ($_.PSObject.Properties['TitleEn']) { [string]$_.TitleEn } else { $null }
            $secImpactEn = if ($_.PSObject.Properties['ImpactEn']) { [string]$_.ImpactEn } else { $null }
            [ordered]@{
                ClassId = $_.ClassId
                Title = $_.Title
                TitleEn = $secTitleEn
                Risk = $_.Risk
                MinAgeDays = $_.MinAgeDays
                Impact = $_.Impact
                ImpactEn = $secImpactEn
                RequiresExplicitOptIn = $_.RequiresExplicitOptIn
                Roots = $_.Roots
                CandidateCount = $_.CandidateCount
                EstimatedBytes = $_.EstimatedBytes
                EstimatedSize = $_.EstimatedSize
                SkippedReparsePoints = $_.SkippedReparsePoints
                SkippedReadErrors = $_.SkippedReadErrors
            }
        })
        BlockedClasses = @($blocked)
        NotApplicableClasses = @($notApplicable)
        ExpiresAtUtc = $null
    }

    if ($sections.Count -eq 0) { return [pscustomobject]$result }

    $planId = [Guid]::NewGuid().ToString('N')
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $createdAt = [DateTime]::UtcNow
    $plan = [ordered]@{
        SchemaVersion = $script:SchemaVersion
        PlanId = $planId
        CreatedFileTimeUtc = [long]$createdAt.ToFileTimeUtc()
        ExpiresAtFileTimeUtc = [long]$createdAt.AddHours($script:PlanLifetimeHours).ToFileTimeUtc()
        UserSid = $identity.User.Value
        ProfileRoot = Get-UserLocalAppData
        FreeBytesBefore = $freeBefore
        Classes = @($sections)
    }

    Write-CleanupPlan -Plan $plan -PlanId $planId
    $result.PlanId = $planId
    $result.ExpiresAtUtc = $createdAt.AddHours($script:PlanLifetimeHours).ToString('o')
    return [pscustomobject]$result
}

function Read-SystemCleanupPlan {
    param([Parameter(Mandatory)][string] $PlanId)

    if ($PlanId -notmatch '^[0-9a-fA-F]{32}$') { throw 'The cleanup plan ID is invalid.' }
    $planPath = Join-Path $script:PlanRoot "$PlanId.json"
    if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) { throw 'The cleanup plan was not found. Run a new scan.' }
    $checksumPath = "$planPath.sha256"
    if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) { throw 'The cleanup plan is incomplete. Run a new scan.' }

    $bytes = [IO.File]::ReadAllBytes($planPath)
    $expectedChecksum = [IO.File]::ReadAllText($checksumPath).Trim()
    if (-not (Get-Sha256Hex -Bytes $bytes).Equals($expectedChecksum, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The cleanup plan changed after the scan. Run a new scan.'
    }

    $plan = ([Text.Encoding]::UTF8.GetString($bytes)) | ConvertFrom-Json -ErrorAction Stop
    if ($plan.SchemaVersion -ne $script:SchemaVersion -or $plan.PlanId -ne $PlanId) {
        throw 'The cleanup plan is invalid. Run a new scan.'
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($plan.UserSid -ne $identity.User.Value) { throw 'The cleanup plan belongs to a different Windows user.' }
    if ([DateTime]::FromFileTimeUtc([long]$plan.ExpiresAtFileTimeUtc) -le [DateTime]::UtcNow) {
        throw 'The cleanup plan has expired. Run a new scan.'
    }

    return $plan
}

function Get-SystemCleanupPlanDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $PlanId,
        [switch] $Full
    )

    $plan = Read-SystemCleanupPlan -PlanId $PlanId
    $sections = foreach ($section in @($plan.Classes)) {
        $candidates = @($section.Candidates)
        $items = @($candidates | Sort-Object { [long]$_.Length } -Descending)
        $shown = if ($Full) { $items } else { @($items | Select-Object -First 3) }

        $titleEn = if ($section.PSObject.Properties['TitleEn']) { [string]$section.TitleEn } else { $null }
        $impactEn = if ($section.PSObject.Properties['ImpactEn']) { [string]$section.ImpactEn } else { $null }

        [ordered]@{
            ClassId = [string]$section.ClassId
            Title = [string]$section.Title
            TitleEn = $titleEn
            Risk = [string]$section.Risk
            MinAgeDays = [int]$section.MinAgeDays
            Impact = [string]$section.Impact
            ImpactEn = $impactEn
            CandidateCount = [int]$section.CandidateCount
            EstimatedBytes = [long]$section.EstimatedBytes
            EstimatedSize = Format-ByteCount ([long]$section.EstimatedBytes)
            Items = @($shown | ForEach-Object {
                $entry = [ordered]@{
                    Name = [IO.Path]::GetFileName([string]$_.Path)
                    SizeBytes = [long]$_.Length
                    Size = Format-ByteCount ([long]$_.Length)
                }
                if ($Full) {
                    $entry.Path = [string]$_.Path
                    $entry.LastWriteFileTimeUtc = [long]$_.LastWriteFileTimeUtc
                }
                [pscustomobject]$entry
            })
            IsTruncated = (-not $Full -and $candidates.Count -gt 3)
        }
    }

    return [pscustomobject]@{
        PlanId = [string]$plan.PlanId
        ClassCount = @($plan.Classes).Count
        # Measure-Object -Sum returns a double; the manifest contract is an int.
        CandidateCount = [int](@($plan.Classes | ForEach-Object { [int]$_.CandidateCount } | Measure-Object -Sum).Sum)
        EstimatedSize = Format-ByteCount (@($plan.Classes | ForEach-Object { [long]$_.EstimatedBytes } | Measure-Object -Sum).Sum)
        FreeBytesBefore = $plan.FreeBytesBefore
        ExpiresAtUtc = [DateTime]::FromFileTimeUtc([long]$plan.ExpiresAtFileTimeUtc).ToString('o')
        Sections = @($sections)
    }
}

function Remove-SystemCleanupPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $PlanId)

    Remove-CleanupPlanMetadata -PlanId $PlanId
    return [pscustomobject]@{ PlanId = $PlanId; Status = 'Discarded' }
}

Export-ModuleMember -Function Set-PlanStoreRoot, Get-PlanStoreRoot, Initialize-PlanStore, Remove-PreviousCleanupPlans, Remove-CleanupPlanMetadata, New-SystemCleanupPlan, Read-SystemCleanupPlan, Get-SystemCleanupPlanDetails, Remove-SystemCleanupPlan
