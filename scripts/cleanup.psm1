Set-StrictMode -Version Latest

$script:PlanRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'SystemOptimizer\plans'
$script:PlanLifetimeHours = 24
$script:MaximumEntries = 250000

function Get-SupportedTempRoot {
    $os = [Environment]::OSVersion
    if ($os.Platform -ne [PlatformID]::Win32NT -or $os.Version.Major -lt 10) {
        throw 'This skill supports Windows 10 and Windows 11 only. No files were changed.'
    }
    $installationType = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name InstallationType -ErrorAction Stop).InstallationType
    if ($installationType -ne 'Client') {
        throw 'This skill supports Windows client editions only. No files were changed.'
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this skill in a non-administrator PowerShell session. Administrator access is not needed.'
    }

    $localAppData = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)).TrimEnd('\')
    $expectedRoot = [IO.Path]::GetFullPath((Join-Path $localAppData 'Temp')).TrimEnd('\')
    $actualRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')

    if (-not $actualRoot.Equals($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The current Windows Temp location is redirected or unsupported. No files were scanned.'
    }

    if (-not (Test-Path -LiteralPath $expectedRoot -PathType Container)) {
        throw 'The current-user Temp folder is unavailable. No files were scanned.'
    }

    $rootItem = Get-Item -LiteralPath $expectedRoot -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The current-user Temp folder is a reparse point. No files were scanned.'
    }

    return $expectedRoot
}

function Get-SystemCleanupReadiness {
    $readiness = [ordered]@{
        Supported = $false
        OperatingSystem = $null
        TempRoot = $null
        Reason = $null
    }

    try {
        $readiness.OperatingSystem = [Environment]::OSVersion.VersionString
        $readiness.TempRoot = Get-SupportedTempRoot
        $readiness.Supported = $true
    }
    catch {
        $readiness.Reason = $_.Exception.Message
    }

    return [pscustomobject]$readiness
}

function Get-CandidatesFromRoot {
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [DateTime] $CutoffUtc
    )

    $candidates = [System.Collections.Generic.List[object]]::new()
    $directories = [System.Collections.Generic.Stack[string]]::new()
    $directories.Push($Root)
    $skippedReparsePoints = 0
    $skippedReadErrors = 0
    $observedEntries = 0

    while ($directories.Count -gt 0) {
        $current = $directories.Pop()
        try {
            $children = @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)
        }
        catch {
            $skippedReadErrors++
            continue
        }

        foreach ($child in $children) {
            $observedEntries++
            if ($observedEntries -gt $script:MaximumEntries) {
                throw "The Temp scan exceeded $($script:MaximumEntries) entries. No cleanup plan was created."
            }

            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $skippedReparsePoints++
                continue
            }

            if ($child.PSIsContainer) {
                $directories.Push($child.FullName)
                continue
            }

            if ($child.LastWriteTimeUtc -gt $CutoffUtc) {
                continue
            }

            $candidates.Add([pscustomobject]@{
                Id = [Guid]::NewGuid().ToString('N')
                Path = [IO.Path]::GetFullPath($child.FullName)
                Length = [long]$child.Length
                LastWriteFileTimeUtc = [long]$child.LastWriteTimeUtc.ToFileTimeUtc()
                CreationFileTimeUtc = [long]$child.CreationTimeUtc.ToFileTimeUtc()
            })
        }
    }

    return [pscustomobject]@{
        Candidates = $candidates.ToArray()
        SkippedReparsePoints = $skippedReparsePoints
        SkippedReadErrors = $skippedReadErrors
    }
}

function Format-ByteCount {
    param([long] $Bytes)

    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N1} KB' -f ($Bytes / 1KB) }
    return "$Bytes bytes"
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

function New-SystemCleanupPlan {
    [CmdletBinding()]
    param(
        [ValidateRange(30, 3650)]
        [int] $MinimumAgeDays = 30
    )

    $root = Get-SupportedTempRoot
    $cutoffUtc = [DateTime]::UtcNow.AddDays(-$MinimumAgeDays)
    $scan = Get-CandidatesFromRoot -Root $root -CutoffUtc $cutoffUtc
    Remove-PreviousCleanupPlans

    if ($scan.Candidates.Count -eq 0) {
        return [pscustomobject]@{
            PlanId = $null
            Scope = 'Current user Temp files'
            MinimumAgeDays = $MinimumAgeDays
            CandidateCount = 0
            EstimatedBytes = [long]0
            EstimatedSize = Format-ByteCount 0
            SkippedReparsePoints = $scan.SkippedReparsePoints
            SkippedReadErrors = $scan.SkippedReadErrors
            ExpiresAtUtc = $null
        }
    }

    $planId = [Guid]::NewGuid().ToString('N')
    $createdAt = [DateTime]::UtcNow
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $plan = [ordered]@{
        SchemaVersion = 1
        PlanId = $planId
        ExpiresAtFileTimeUtc = [long]$createdAt.AddHours($script:PlanLifetimeHours).ToFileTimeUtc()
        UserSid = $identity.User.Value
        Root = $root
        MinimumAgeDays = $MinimumAgeDays
        Candidates = $scan.Candidates
    }

    Initialize-PlanStore

    $planPath = Join-Path $script:PlanRoot "$planId.json"
    $json = $plan | ConvertTo-Json -Depth 8
    $encoding = [Text.UTF8Encoding]::new($false)
    $bytes = $encoding.GetBytes($json)
    [IO.File]::WriteAllBytes($planPath, $bytes)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $checksum = [BitConverter]::ToString($hasher.ComputeHash($bytes)).Replace('-', '')
    }
    finally {
        $hasher.Dispose()
    }
    [IO.File]::WriteAllText("$planPath.sha256", $checksum, $encoding)

    $totalBytes = [long]0
    foreach ($candidate in $scan.Candidates) { $totalBytes += [long]$candidate.Length }

    return [pscustomobject]@{
        PlanId = $planId
        Scope = 'Current user Temp files'
        MinimumAgeDays = $MinimumAgeDays
        CandidateCount = $scan.Candidates.Count
        EstimatedBytes = $totalBytes
        EstimatedSize = Format-ByteCount $totalBytes
        SkippedReparsePoints = $scan.SkippedReparsePoints
        SkippedReadErrors = $scan.SkippedReadErrors
        ExpiresAtUtc = [DateTime]::FromFileTimeUtc([long]$plan.ExpiresAtFileTimeUtc).ToString('o')
    }
}

function Test-PathWithinRoot {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Root
    )

    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $targetPath = [IO.Path]::GetFullPath($Path)
    $prefix = $rootPath + '\'
    return $targetPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Test-NoReparsePointInPath {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Root
    )

    $current = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $rootItem = Get-Item -LiteralPath $current -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }

    $targetPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-PathWithinRoot -Path $targetPath -Root $current)) { return $false }

    $relativePath = $targetPath.Substring($current.Length).TrimStart('\')
    $parts = $relativePath.Split('\')
    for ($index = 0; $index -lt $parts.Length; $index++) {
        $current = Join-Path $current $parts[$index]
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        if ($index -lt ($parts.Length - 1) -and -not $item.PSIsContainer) { return $false }
        if ($index -eq ($parts.Length - 1) -and $item.PSIsContainer) { return $false }
    }

    return $true
}

function Read-SystemCleanupPlan {
    param([Parameter(Mandatory)][string] $PlanId)

    if ($PlanId -notmatch '^[0-9a-fA-F]{32}$') { throw 'The cleanup plan ID is invalid.' }
    $planPath = Join-Path $script:PlanRoot "$PlanId.json"
    if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) { throw 'The cleanup plan was not found. Run a new scan.' }
    $checksumPath = "$planPath.sha256"
    if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) { throw 'The cleanup plan is incomplete. Run a new scan.' }

    $bytes = [IO.File]::ReadAllBytes($planPath)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $actualChecksum = [BitConverter]::ToString($hasher.ComputeHash($bytes)).Replace('-', '')
    }
    finally {
        $hasher.Dispose()
    }
    $expectedChecksum = [IO.File]::ReadAllText($checksumPath).Trim()
    if (-not $actualChecksum.Equals($expectedChecksum, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The cleanup plan changed after the scan. Run a new scan.'
    }

    $planJson = [Text.Encoding]::UTF8.GetString($bytes)
    $plan = $planJson | ConvertFrom-Json -ErrorAction Stop
    if ($plan.SchemaVersion -ne 1 -or $plan.PlanId -ne $PlanId) { throw 'The cleanup plan is invalid. Run a new scan.' }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($plan.UserSid -ne $identity.User.Value) { throw 'The cleanup plan belongs to a different Windows user.' }
    if ([DateTime]::FromFileTimeUtc([long]$plan.ExpiresAtFileTimeUtc) -le [DateTime]::UtcNow) { throw 'The cleanup plan has expired. Run a new scan.' }

    return $plan
}

function Get-SystemCleanupPlanDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $PlanId,
        [switch] $Full
    )

    $plan = Read-SystemCleanupPlan -PlanId $PlanId
    $totalBytes = [long]0
    foreach ($candidate in $plan.Candidates) { $totalBytes += [long]$candidate.Length }

    $items = @($plan.Candidates | Sort-Object { [long]$_.Length } -Descending)
    if (-not $Full) { $items = @($items | Select-Object -First 5) }

    $displayItems = foreach ($candidate in $items) {
        $entry = [ordered]@{
            Name = [IO.Path]::GetFileName([string]$candidate.Path)
            SizeBytes = [long]$candidate.Length
            Size = Format-ByteCount ([long]$candidate.Length)
        }
        if ($Full) {
            $entry.Path = [string]$candidate.Path
            $entry.LastWriteFileTimeUtc = [long]$candidate.LastWriteFileTimeUtc
        }
        [pscustomobject]$entry
    }

    return [pscustomobject]@{
        PlanId = $plan.PlanId
        Scope = 'Current user Temp files'
        MinimumAgeDays = [int]$plan.MinimumAgeDays
        CandidateCount = $plan.Candidates.Count
        EstimatedBytes = $totalBytes
        EstimatedSize = Format-ByteCount $totalBytes
        Items = @($displayItems)
        IsTruncated = (-not $Full -and $plan.Candidates.Count -gt 5)
    }
}

function Invoke-SystemCleanupPlan {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string] $PlanId,
        [Parameter(Mandatory)][string] $ApprovedPlanId
    )

    if ($ApprovedPlanId -cne $PlanId) { throw 'Approval does not match this cleanup plan.' }
    $plan = Read-SystemCleanupPlan -PlanId $PlanId
    $root = Get-SupportedTempRoot
    if (-not ([IO.Path]::GetFullPath($plan.Root).TrimEnd('\').Equals($root, [StringComparison]::OrdinalIgnoreCase))) {
        throw 'The cleanup plan scope changed. Run a new scan.'
    }

    $plannedBytes = [long]0
    foreach ($candidate in $plan.Candidates) { $plannedBytes += [long]$candidate.Length }
    $target = "$($plan.Candidates.Count) files, $(Format-ByteCount $plannedBytes), plan $PlanId"
    if (-not $PSCmdlet.ShouldProcess($target, 'Move approved files to the Recycle Bin')) {
        return [pscustomobject]@{ PlanId = $PlanId; Status = 'NotExecuted'; MovedCount = 0; EstimatedMovedBytes = 0; SkippedCount = 0; FailedCount = 0 }
    }

    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
    $moved = 0
    $skipped = 0
    $failed = 0
    $movedBytes = [long]0
    $details = [System.Collections.Generic.List[object]]::new()
    $cutoffUtc = [DateTime]::UtcNow.AddDays(-[int]$plan.MinimumAgeDays)

    foreach ($candidate in $plan.Candidates) {
        try {
            if (-not (Test-PathWithinRoot -Path $candidate.Path -Root $root)) { throw 'Outside supported Temp folder' }
            if (-not (Test-NoReparsePointInPath -Path $candidate.Path -Root $root)) { throw 'Path contains a reparse point or is no longer a file' }

            $item = Get-Item -LiteralPath $candidate.Path -Force -ErrorAction Stop
            if ($item.Length -ne [long]$candidate.Length -or
                $item.LastWriteTimeUtc.ToFileTimeUtc() -ne [long]$candidate.LastWriteFileTimeUtc -or
                $item.CreationTimeUtc.ToFileTimeUtc() -ne [long]$candidate.CreationFileTimeUtc) {
                throw 'File changed after the scan'
            }
            if ($item.LastWriteTimeUtc -gt $cutoffUtc) { throw 'File is no longer old enough' }

            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                $candidate.Path,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
                [Microsoft.VisualBasic.FileIO.UICancelOption]::ThrowException
            )
            $moved++
            $movedBytes += [long]$candidate.Length
        }
        catch {
            if ($_.Exception.Message -like 'File changed after the scan*' -or
                $_.Exception.Message -like 'File is no longer old enough*' -or
                $_.Exception.Message -like 'Outside supported Temp folder*' -or
                $_.Exception.Message -like 'Path contains a reparse point*') {
                $skipped++
                $details.Add([pscustomobject]@{ Name = [IO.Path]::GetFileName([string]$candidate.Path); Status = 'Skipped'; Reason = $_.Exception.Message })
            }
            else {
                $failed++
                $details.Add([pscustomobject]@{ Name = [IO.Path]::GetFileName([string]$candidate.Path); Status = 'Failed'; Reason = $_.Exception.Message })
            }
        }
    }

    Remove-CleanupPlanMetadata -PlanId $PlanId

    return [pscustomobject]@{
        PlanId = $PlanId
        Status = 'Completed'
        MovedCount = $moved
        EstimatedMovedBytes = $movedBytes
        EstimatedMovedSize = Format-ByteCount $movedBytes
        SkippedCount = $skipped
        FailedCount = $failed
        Details = $details.ToArray()
    }
}

function Remove-SystemCleanupPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $PlanId)

    Remove-CleanupPlanMetadata -PlanId $PlanId
    return [pscustomobject]@{ PlanId = $PlanId; Status = 'Discarded' }
}

Export-ModuleMember -Function Get-SystemCleanupReadiness, New-SystemCleanupPlan, Get-SystemCleanupPlanDetails, Invoke-SystemCleanupPlan, Remove-SystemCleanupPlan
