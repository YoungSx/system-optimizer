[CmdletBinding()]
param()

# Behaviour tests for the safety contract, not for a particular class list.
# Fixtures live inside the real Temp folder because Temp is the one class whose
# root the product controls; everything else is exercised through the same
# generic plan and executor path.

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot '..\scripts\systemoptimizer.psm1') -Force
# The facade exports the product surface. These tests also exercise the
# filesystem primitives and the plan store directly, so those modules are loaded
# on purpose: re-importing them must not disturb the composed session.
Import-Module -Name (Join-Path $PSScriptRoot '..\scripts\core\filesystem.psm1')
Import-Module -Name (Join-Path $PSScriptRoot '..\scripts\core\plan.psm1')
Import-Module -Name (Join-Path $PSScriptRoot '..\scripts\core\environment.psm1')

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$scratchRoot = $null
$planScratchRoot = $null
$oldBypass = $null

try {
    # --- user context contract ------------------------------------------------
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            # Running in an elevated session (e.g. CI runner). Verify administrator refusal by default.
            $oldBypass = $env:SYSTEM_OPTIMIZER_ALLOW_ADMIN
            $env:SYSTEM_OPTIMIZER_ALLOW_ADMIN = $null
            $adminRejected = $false
            try { Assert-StandardUserContext | Out-Null }
            catch { $adminRejected = $_.Exception.Message -like '*non-administrator session*' }
            $env:SYSTEM_OPTIMIZER_ALLOW_ADMIN = '1'
            Assert-True $adminRejected 'An administrator session must be refused.'
        }
    }

    # --- catalog contract -----------------------------------------------------
    $catalog = @(Get-CleanupCatalog)
    Assert-True ($catalog.Count -gt 0) 'The catalog must declare at least one cleanup class.'
    foreach ($definition in $catalog) {
        Assert-True ([bool]$definition.Title) "Class '$($definition.Id)' must have a title."
        Assert-True ([bool]$definition.Impact) "Class '$($definition.Id)' must explain its impact."
        Assert-True ($definition.Risk -in @('Low', 'Review', 'High')) "Class '$($definition.Id)' must declare a known risk level."
        Assert-True ($definition.MinAgeDays -ge 0) "Class '$($definition.Id)' must declare a non-negative age floor."
        Assert-True ($null -ne $definition.Collect) "Class '$($definition.Id)' must provide a collector."
    }
    $duplicateIds = @($catalog | Group-Object Id | Where-Object { $_.Count -gt 1 })
    Assert-True ($duplicateIds.Count -eq 0) 'Cleanup class ids must be unique.'

    $unknownRejected = $false
    try { New-SystemCleanupPlan -ClassId 'no-such-class' | Out-Null }
    catch { $unknownRejected = $_.Exception.Message -like 'Unknown cleanup class*' }
    Assert-True $unknownRejected 'An unknown class id must be rejected before any scan.'

    # A Review category must be unreachable unless the caller names it in -OptIn.
    $optInClasses = @($catalog | Where-Object { $_.RequiresExplicitOptIn })
    foreach ($definition in $optInClasses) {
        $optInRejected = $false
        try { New-SystemCleanupPlan -ClassId $definition.Id | Out-Null }
        catch { $optInRejected = $_.Exception.Message -like '*requires explicit opt-in*' }
        Assert-True $optInRejected "Class '$($definition.Id)' must refuse a scan without -OptIn."
    }

    # --- scanning -------------------------------------------------------------
    $tempRoot = [IO.Path]::GetTempPath().TrimEnd('\')
    $scratchRoot = Join-Path $tempRoot ("system-optimizer-test-" + [Guid]::NewGuid().ToString('N'))
    $nestedRoot = Join-Path $scratchRoot 'nested'
    New-Item -Path $nestedRoot -ItemType Directory -Force | Out-Null
    $oldFile = Join-Path $scratchRoot 'old.bin'
    $nestedOldFile = Join-Path $nestedRoot 'nested-old.bin'
    $recentFile = Join-Path $scratchRoot 'recent.bin'
    [IO.File]::WriteAllBytes($oldFile, [byte[]](1, 2, 3, 4))
    [IO.File]::WriteAllBytes($nestedOldFile, [byte[]](5, 6, 7))
    [IO.File]::WriteAllBytes($recentFile, [byte[]](8, 9))
    $oldDate = [DateTime]::UtcNow.AddDays(-45)
    [IO.File]::SetLastWriteTimeUtc($oldFile, $oldDate)
    [IO.File]::SetLastWriteTimeUtc($nestedOldFile, $oldDate)

    $scan = Get-CandidatesFromRoot -Root $scratchRoot -CutoffUtc ([DateTime]::UtcNow.AddDays(-30))
    Assert-True ($scan.Candidates.Count -eq 2) 'The scanner must include exactly the two old files.'
    Assert-True (($scan.Candidates.Path -contains $oldFile) -and ($scan.Candidates.Path -contains $nestedOldFile)) 'Old files in nested folders must be included.'
    Assert-True (-not ($scan.Candidates.Path -contains $recentFile)) 'Files newer than the cutoff must be excluded.'
    foreach ($candidate in $scan.Candidates) {
        Assert-True ([bool]$candidate.Root) 'Every candidate must record the root it was found under.'
    }

    $insideRoot = Test-PathWithinRoot -Path $oldFile -Root $scratchRoot
    $outsideRoot = Test-PathWithinRoot -Path $tempRoot -Root $scratchRoot
    $siblingRoot = Test-PathWithinRoot -Path "$scratchRoot-sibling\file.bin" -Root $scratchRoot
    Assert-True $insideRoot 'A child path must be inside the root.'
    Assert-True (-not $outsideRoot) 'A parent path must not pass the containment check.'
    Assert-True (-not $siblingRoot) 'A path sharing a name prefix must not pass the containment check.'

    # --- approval gate --------------------------------------------------------
    $approvalRejected = $false
    try { Get-SystemCleanupPlanExecution -PlanId ('a' * 32) -ApprovedPlanId ('b' * 32) -Confirm:$false | Out-Null }
    catch { $approvalRejected = $_.Exception.Message -like 'Approval does not match this cleanup plan*' }
    Assert-True $approvalRejected 'A mismatched approval must fail before loading a plan.'

    # --- plan integrity -------------------------------------------------------
    $planScratchRoot = Join-Path $tempRoot ("system-optimizer-test-" + [Guid]::NewGuid().ToString('N'))
    $planStore = Join-Path $planScratchRoot 'plans'
    $planFixtureRoot = Join-Path $planScratchRoot 'files'
    New-Item -Path $planFixtureRoot -ItemType Directory -Force | Out-Null
    New-Item -Path $planStore -ItemType Directory -Force | Out-Null
    Set-PlanStoreRoot -Path $planStore

    $plannedFile = Join-Path $planFixtureRoot 'planned-old-file.bin'
    [IO.File]::WriteAllBytes($plannedFile, [byte[]](10, 11, 12))
    [IO.File]::SetLastWriteTimeUtc($plannedFile, $oldDate)
    $plannedItem = Get-Item -LiteralPath $plannedFile -Force
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $profileRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)

    function Write-TestPlan {
        param([string] $Id, [string] $FilePath, [IO.FileInfo] $FileInfo, [string] $ScanRoot)

        $candidate = [ordered]@{
            Id = [Guid]::NewGuid().ToString('N')
            Root = $ScanRoot
            Path = [IO.Path]::GetFullPath($FilePath)
            Length = [long]$FileInfo.Length
            LastWriteFileTimeUtc = [long]$FileInfo.LastWriteTimeUtc.ToFileTimeUtc()
            CreationFileTimeUtc = [long]$FileInfo.CreationTimeUtc.ToFileTimeUtc()
        }
        $section = [ordered]@{
            ClassId = 'temp'
            Title = 'test'
            TitleEn = 'test'
            Risk = 'Low'
            MinAgeDays = 30
            Impact = 'test'
            RequiresExplicitOptIn = $false
            Roots = @($ScanRoot)
            CandidateCount = 1
            EstimatedBytes = [long]$FileInfo.Length
            EstimatedSize = 'test'
            SkippedReparsePoints = 0
            SkippedReadErrors = 0
            Candidates = @($candidate)
        }
        $plan = [ordered]@{
            SchemaVersion = 2
            PlanId = $Id
            CreatedFileTimeUtc = [long][DateTime]::UtcNow.ToFileTimeUtc()
            ExpiresAtFileTimeUtc = [long][DateTime]::UtcNow.AddHours(1).ToFileTimeUtc()
            UserSid = $userSid
            ProfileRoot = $profileRoot
            FreeBytesBefore = $null
            Classes = @($section)
        }
        $json = $plan | ConvertTo-Json -Depth 8
        $encoding = [Text.UTF8Encoding]::new($false)
        $bytes = $encoding.GetBytes($json)
        $path = Join-Path $planStore "$Id.json"
        [IO.File]::WriteAllBytes($path, $bytes)
        $hasher = [Security.Cryptography.SHA256]::Create()
        try { $digest = [BitConverter]::ToString($hasher.ComputeHash($bytes)).Replace('-', '') }
        finally { $hasher.Dispose() }
        [IO.File]::WriteAllText("$path.sha256", $digest, $encoding)
        return $path
    }

    $planId = [Guid]::NewGuid().ToString('N')
    $planPath = Write-TestPlan -Id $planId -FilePath $plannedFile -FileInfo $plannedItem -ScanRoot $planFixtureRoot

    $dryRun = Get-SystemCleanupPlanExecution -PlanId $planId -ApprovedPlanId $planId -WhatIf
    Assert-True ($dryRun.Status -eq 'NotExecuted') 'WhatIf must report that nothing was executed.'
    Assert-True (Test-Path -LiteralPath $plannedFile -PathType Leaf) 'WhatIf must leave the candidate in place.'

    $summary = Get-SystemCleanupPlanDetails -PlanId $planId
    $fullDetails = Get-SystemCleanupPlanDetails -PlanId $planId -Full
    Assert-True ($summary.Sections[0].Items.Count -eq 1) 'The plan summary must list the candidate.'
    Assert-True ($null -eq $summary.Sections[0].Items[0].PSObject.Properties['Path']) 'The default summary must not expose full paths.'
    Assert-True ($fullDetails.Sections[0].Items[0].Path -eq $plannedFile) 'Only the explicit full view may expose full paths.'

    $changedPlan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
    $changedPlan.Classes[0].MinAgeDays = 31
    $changedPlan | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $planPath -Encoding utf8
    $tamperRejected = $false
    try { Get-SystemCleanupPlanExecution -PlanId $planId -ApprovedPlanId $planId -Confirm:$false | Out-Null }
    catch { $tamperRejected = $_.Exception.Message -like 'The cleanup plan changed after the scan*' }
    Assert-True $tamperRejected 'A modified plan must fail its checksum.'
    Assert-True (Test-Path -LiteralPath $plannedFile -PathType Leaf) 'A modified plan must delete nothing.'

    Remove-SystemCleanupPlan -PlanId $planId | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $planPath) -and -not (Test-Path -LiteralPath "$planPath.sha256")) 'Discarding a plan must remove its manifest.'

    # --- stale candidate ------------------------------------------------------
    $freshPlanId = [Guid]::NewGuid().ToString('N')
    $freshFileInfo = Get-Item -LiteralPath $plannedFile -Force
    Write-TestPlan -Id $freshPlanId -FilePath $plannedFile -FileInfo $freshFileInfo -ScanRoot $planFixtureRoot | Out-Null
    [IO.File]::AppendAllText($plannedFile, 'changed')
    $staleResult = Get-SystemCleanupPlanExecution -PlanId $freshPlanId -ApprovedPlanId $freshPlanId -Confirm:$false
    Assert-True ($staleResult.SkippedCount -eq 1 -and $staleResult.MovedCount -eq 0) 'A candidate changed after scanning must be skipped.'
    Assert-True (Test-Path -LiteralPath $plannedFile -PathType Leaf) 'A changed candidate must remain in place.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $planStore "$freshPlanId.json"))) 'An executed plan must remove its manifest.'

    # --- containment and profile guards at execution time ---------------------
    $outsideFile = Join-Path $profileRoot 'system-optimizer-outside-test.bin'
    [IO.File]::WriteAllBytes($outsideFile, [byte[]](1, 2))
    [IO.File]::SetLastWriteTimeUtc($outsideFile, $oldDate)
    $outsideInfo = Get-Item -LiteralPath $outsideFile -Force
    $forgedId = [Guid]::NewGuid().ToString('N')
    # A root outside the profile: the plan is sealed and valid, and must still
    # be refused, because a plan is not authority to leave the profile.
    Write-TestPlan -Id $forgedId -FilePath $outsideFile -FileInfo $outsideInfo -ScanRoot 'C:\Windows' | Out-Null
    $forgedResult = Get-SystemCleanupPlanExecution -PlanId $forgedId -ApprovedPlanId $forgedId -Confirm:$false
    Assert-True ($forgedResult.MovedCount -eq 0 -and $forgedResult.SkippedCount -eq 1) 'A candidate outside the profile must be skipped.'
    Assert-True (Test-Path -LiteralPath $outsideFile -PathType Leaf) 'A candidate outside the profile must remain in place.'
    Remove-Item -LiteralPath $outsideFile -Force -ErrorAction SilentlyContinue

    # --- intent of the age floor ---------------------------------------------
    $youngPlanId = [Guid]::NewGuid().ToString('N')
    $youngFile = Join-Path $planFixtureRoot 'young.bin'
    [IO.File]::WriteAllBytes($youngFile, [byte[]](1))
    $youngInfo = Get-Item -LiteralPath $youngFile -Force
    Write-TestPlan -Id $youngPlanId -FilePath $youngFile -FileInfo $youngInfo -ScanRoot $planFixtureRoot | Out-Null
    $youngResult = Get-SystemCleanupPlanExecution -PlanId $youngPlanId -ApprovedPlanId $youngPlanId -Confirm:$false
    Assert-True ($youngResult.SkippedCount -eq 1 -and $youngResult.MovedCount -eq 0) 'A candidate younger than the age floor must be skipped.'
    Assert-True (Test-Path -LiteralPath $youngFile -PathType Leaf) 'A too-young candidate must remain in place.'

    # --- the happy path, which is the only one that deletes anything ----------
    # Every case above asserts that nothing is removed. Without this one, the
    # Recycle Bin call itself would be untested.
    $happyPlanId = [Guid]::NewGuid().ToString('N')
    $happyFile = Join-Path $planFixtureRoot 'happy-old-file.bin'
    [IO.File]::WriteAllBytes($happyFile, [byte[]](20, 21, 22, 23, 24))
    [IO.File]::SetLastWriteTimeUtc($happyFile, $oldDate)
    $happyInfo = Get-Item -LiteralPath $happyFile -Force
    Write-TestPlan -Id $happyPlanId -FilePath $happyFile -FileInfo $happyInfo -ScanRoot $planFixtureRoot | Out-Null

    $happyResult = Get-SystemCleanupPlanExecution -PlanId $happyPlanId -ApprovedPlanId $happyPlanId -Confirm:$false
    Assert-True ($happyResult.MovedCount -eq 1) 'An approved, unchanged, old candidate must be moved.'
    Assert-True ($happyResult.Status -eq 'Completed') 'Execution must report the Completed status.'
    Assert-True ($happyResult.SkippedCount -eq 0 -and $happyResult.FailedCount -eq 0) 'The happy path must report no skips or failures.'
    Assert-True (-not (Test-Path -LiteralPath $happyFile)) 'A moved file must no longer be at its original path.'
    Assert-True ($null -ne $happyResult.FreeBytesAfter) 'Execution must measure free space after the move.'

    'System Optimizer smoke tests passed.'
}
finally {
    Set-PlanStoreRoot -Path (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'SystemOptimizer\plans')
    foreach ($path in @($scratchRoot, $planScratchRoot)) {
        if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if ($null -ne $oldBypass) {
        $env:SYSTEM_OPTIMIZER_ALLOW_ADMIN = $oldBypass
    }
    else {
        $env:SYSTEM_OPTIMIZER_ALLOW_ADMIN = $null
    }
}
