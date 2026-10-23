[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot '..\scripts\cleanup.psm1'
$module = Import-Module -Name $modulePath -Force -PassThru
$scratchRoot = $null

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

try {
    $scratchRoot = Join-Path ([IO.Path]::GetTempPath()) ("system-optimizer-test-" + [Guid]::NewGuid().ToString('N'))
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

    $scan = & $module {
        param($Root, $CutoffUtc)
        Get-CandidatesFromRoot -Root $Root -CutoffUtc $CutoffUtc
    } $scratchRoot ([DateTime]::UtcNow.AddDays(-30))

    Assert-True ($scan.Candidates.Count -eq 2) 'Scanner should include only the two old files.'
    Assert-True (($scan.Candidates.Path -contains $oldFile) -and ($scan.Candidates.Path -contains $nestedOldFile)) 'Scanner should include old files in nested folders.'
    Assert-True (-not ($scan.Candidates.Path -contains $recentFile)) 'Scanner should skip files newer than the cutoff.'

    $insideRoot = & $module { param($Path, $Root) Test-PathWithinRoot -Path $Path -Root $Root } $oldFile $scratchRoot
    $outsideRoot = & $module { param($Path, $Root) Test-PathWithinRoot -Path $Path -Root $Root } ([IO.Path]::GetTempPath()) $scratchRoot
    Assert-True $insideRoot 'A child path should remain inside the supported root.'
    Assert-True (-not $outsideRoot) 'A sibling path must not pass the containment check.'

    $approvalRejected = $false
    try {
        Invoke-SystemCleanupPlan -PlanId ('a' * 32) -ApprovedPlanId ('b' * 32) -Confirm:$false | Out-Null
    }
    catch {
        $approvalRejected = $_.Exception.Message -like 'Approval does not match this cleanup plan*'
    }
    Assert-True $approvalRejected 'A mismatched approval must fail before loading or executing a plan.'

    $tempRoot = & $module { Get-SupportedTempRoot }
    $planScratchRoot = Join-Path $tempRoot ("system-optimizer-test-" + [Guid]::NewGuid().ToString('N'))
    $planStore = Join-Path $planScratchRoot 'plans'
    $planFixtureRoot = Join-Path $planScratchRoot 'files'
    New-Item -Path $planFixtureRoot -ItemType Directory -Force | Out-Null
    New-Item -Path $planStore -ItemType Directory -Force | Out-Null
    & $module { param($Path) $script:PlanRoot = $Path } $planStore

    $plannedFile = Join-Path $planFixtureRoot 'planned-old-file.bin'
    [IO.File]::WriteAllBytes($plannedFile, [byte[]](10, 11, 12))
    [IO.File]::SetLastWriteTimeUtc($plannedFile, $oldDate)
    $plannedItem = Get-Item -LiteralPath $plannedFile -Force
    $planId = [Guid]::NewGuid().ToString('N')
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

    function Write-TestPlan {
        param([string] $Id, [string] $FilePath, [IO.FileInfo] $FileInfo)
        $plan = [ordered]@{
            SchemaVersion = 1
            PlanId = $Id
            ExpiresAtFileTimeUtc = [long][DateTime]::UtcNow.AddHours(1).ToFileTimeUtc()
            UserSid = $userSid
            Root = $tempRoot
            MinimumAgeDays = 30
            Candidates = @([ordered]@{
                Id = [Guid]::NewGuid().ToString('N')
                Path = [IO.Path]::GetFullPath($FilePath)
                Length = [long]$FileInfo.Length
                LastWriteFileTimeUtc = [long]$FileInfo.LastWriteTimeUtc.ToFileTimeUtc()
                CreationFileTimeUtc = [long]$FileInfo.CreationTimeUtc.ToFileTimeUtc()
            })
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

    $planPath = Write-TestPlan -Id $planId -FilePath $plannedFile -FileInfo $plannedItem
    $dryRun = Invoke-SystemCleanupPlan -PlanId $planId -ApprovedPlanId $planId -WhatIf
    Assert-True ($dryRun.Status -eq 'NotExecuted') 'WhatIf must report that no cleanup was executed.'
    Assert-True (Test-Path -LiteralPath $plannedFile -PathType Leaf) 'WhatIf must leave the candidate file in place.'

    $summary = Get-SystemCleanupPlanDetails -PlanId $planId
    $fullDetails = Get-SystemCleanupPlanDetails -PlanId $planId -Full
    Assert-True ($summary.Items.Count -eq 1 -and ($null -eq $summary.Items[0].PSObject.Properties['Path'])) 'Default plan details should show filenames without full paths.'
    Assert-True ($fullDetails.Items.Count -eq 1 -and $fullDetails.Items[0].Path -eq $plannedFile) 'Full paths should be available only through the explicit full-details option.'

    $changedPlan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
    $changedPlan.MinimumAgeDays = 31
    $changedPlan | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $planPath -Encoding utf8
    $tamperingRejected = $false
    try { Invoke-SystemCleanupPlan -PlanId $planId -ApprovedPlanId $planId -Confirm:$false | Out-Null }
    catch { $tamperingRejected = $_.Exception.Message -like 'The cleanup plan changed after the scan*' }
    Assert-True $tamperingRejected 'A changed plan must fail checksum validation.'
    Assert-True (Test-Path -LiteralPath $plannedFile -PathType Leaf) 'A changed plan must not delete a candidate file.'

    Remove-SystemCleanupPlan -PlanId $planId | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $planPath) -and -not (Test-Path -LiteralPath "$planPath.sha256")) 'Cancelling a plan must remove its local path manifest.'
    $freshPlanId = [Guid]::NewGuid().ToString('N')
    $freshFileInfo = Get-Item -LiteralPath $plannedFile -Force
    Write-TestPlan -Id $freshPlanId -FilePath $plannedFile -FileInfo $freshFileInfo | Out-Null
    [IO.File]::AppendAllText($plannedFile, 'changed')
    $staleResult = Invoke-SystemCleanupPlan -PlanId $freshPlanId -ApprovedPlanId $freshPlanId -Confirm:$false
    Assert-True ($staleResult.SkippedCount -eq 1 -and $staleResult.MovedCount -eq 0) 'A candidate changed after scanning must be skipped.'
    Assert-True (Test-Path -LiteralPath $plannedFile -PathType Leaf) 'A changed candidate must remain in place.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $planStore "$freshPlanId.json"))) 'An executed plan must remove its local path manifest.'

    'System Optimizer smoke tests passed.'
}
finally {
    Remove-Module $module.Name -Force -ErrorAction SilentlyContinue
    if ($scratchRoot -and (Test-Path -LiteralPath $scratchRoot)) {
        Remove-Item -LiteralPath $scratchRoot -Recurse -Force
    }
    if ($planScratchRoot -and (Test-Path -LiteralPath $planScratchRoot)) {
        Remove-Item -LiteralPath $planScratchRoot -Recurse -Force
    }
}
