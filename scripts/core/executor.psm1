Set-StrictMode -Version Latest

$script:CorePath = $PSScriptRoot
Import-Module -Name (Join-Path $script:CorePath 'filesystem.psm1') -ErrorAction Stop
Import-Module -Name (Join-Path $script:CorePath 'environment.psm1') -ErrorAction Stop
Import-Module -Name (Join-Path $script:CorePath 'catalog.psm1') -ErrorAction Stop
Import-Module -Name (Join-Path $script:CorePath 'plan.psm1') -ErrorAction Stop

# Executor. Reads a sealed plan and moves every candidate to the Recycle Bin,
# revalidating each one immediately before the move. Revalidation failure is a
# skip, never a fallback to permanent deletion.

function Get-SystemCleanupPlanExecution {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string] $PlanId,
        [Parameter(Mandatory)][string] $ApprovedPlanId
    )

    if ($ApprovedPlanId -cne $PlanId) { throw 'Approval does not match this cleanup plan.' }

    $plan = Read-SystemCleanupPlan -PlanId $PlanId
    $null = Assert-StandardUserContext
    $freeBefore = Get-DriveFreeBytes -Path $plan.ProfileRoot

    $totalCount = @($plan.Classes | ForEach-Object { [int]$_.CandidateCount } | Measure-Object -Sum).Sum
    $totalBytes = @($plan.Classes | ForEach-Object { [long]$_.EstimatedBytes } | Measure-Object -Sum).Sum
    $target = "$totalCount files across $(@($plan.Classes).Count) categories, $(Format-ByteCount $totalBytes), plan $PlanId"

    if (-not $PSCmdlet.ShouldProcess($target, 'Move approved files to the Recycle Bin')) {
        return [pscustomobject]@{
            PlanId = $PlanId
            Status = 'NotExecuted'
            MovedCount = 0
            EstimatedMovedBytes = [long]0
            SkippedCount = 0
            FailedCount = 0
            Classes = @()
        }
    }

    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop

    $sections = [System.Collections.Generic.List[object]]::new()
    $moved = 0
    $skipped = 0
    $failed = 0
    $movedBytes = [long]0

    foreach ($section in @($plan.Classes)) {
        $classId = [string]$section.ClassId
        $entry = Resolve-CleanupClass -Id $classId

        # A class-level precondition (a busy GPU driver, for example) voids the
        # whole section rather than producing hundreds of per-file failures.
        $ready = Test-ClassReady -Entry $entry -Id $classId
        if (-not $ready.Ready) {
            $skipped += [int]$section.CandidateCount
            $sections.Add([pscustomobject]@{
                ClassId = $classId
                Title = [string]$section.Title
                Status = 'Skipped'
                MovedCount = 0
                SkippedCount = [int]$section.CandidateCount
                FailedCount = 0
                EstimatedMovedBytes = [long]0
                Reason = $ready.Reason
                Details = @()
            })
            continue
        }

        $cutoffUtc = [DateTime]::FromFileTimeUtc([long]$plan.CreatedFileTimeUtc).AddDays(-[int]$section.MinAgeDays)
        $classMoved = 0
        $classSkipped = 0
        $classFailed = 0
        $classBytes = [long]0
        $details = [System.Collections.Generic.List[object]]::new()

        foreach ($candidate in @($section.Candidates)) {
            $root = [string]$candidate.Root
            $path = [string]$candidate.Path

            try {
                # The root is sealed into the plan, but a plan is not authority
                # to delete outside the profile, however it was produced.
                if (-not (Test-PathWithinRoot -Path $root -Root $plan.ProfileRoot)) { throw 'Outside the current user profile' }
                if (-not (Test-PathWithinRoot -Path $path -Root $root)) { throw 'Outside the scanned root' }
                if (-not (Test-NoReparsePointInPath -Path $path -Root $root)) { throw 'Path contains a reparse point or is no longer a file' }

                $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
                if ($item.PSIsContainer) { throw 'Path contains a reparse point or is no longer a file' }
                if ($item.Length -ne [long]$candidate.Length -or
                    $item.LastWriteTimeUtc.ToFileTimeUtc() -ne [long]$candidate.LastWriteFileTimeUtc -or
                    $item.CreationTimeUtc.ToFileTimeUtc() -ne [long]$candidate.CreationFileTimeUtc) {
                    throw 'File changed after the scan'
                }
                if ($item.LastWriteTimeUtc -gt $cutoffUtc) { throw 'File is no longer old enough' }

                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                    $path,
                    [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                    [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
                    [Microsoft.VisualBasic.FileIO.UICancelOption]::ThrowException
                )
                $classMoved++
                $classBytes += [long]$candidate.Length
            }
            catch {
                $message = $_.Exception.Message
                $isSkip = $message -like 'File changed after the scan*' -or
                    $message -like 'File is no longer old enough*' -or
                    $message -like 'Outside *' -or
                    $message -like 'Path contains a reparse point*'
                if ($isSkip) { $classSkipped++ } else { $classFailed++ }
                $details.Add([pscustomobject]@{
                    Name = [IO.Path]::GetFileName($path)
                    Status = if ($isSkip) { 'Skipped' } else { 'Failed' }
                    Reason = $message
                })
            }
        }

        $moved += $classMoved
        $skipped += $classSkipped
        $failed += $classFailed
        $movedBytes += $classBytes

        $sections.Add([pscustomobject]@{
            ClassId = $classId
            Title = [string]$section.Title
            Status = if ($classFailed -eq 0 -and $classSkipped -eq 0) { 'Completed' } elseif ($classMoved -gt 0) { 'PartiallyCompleted' } else { 'NotCompleted' }
            MovedCount = $classMoved
            SkippedCount = $classSkipped
            FailedCount = $classFailed
            EstimatedMovedBytes = $classBytes
            Reason = $null
            Details = $details.ToArray()
        })
    }

    Remove-CleanupPlanMetadata -PlanId $PlanId

    $freeAfter = Get-DriveFreeBytes -Path $plan.ProfileRoot
    $freeDelta = $null
    if ($null -ne $freeBefore -and $null -ne $freeAfter) { $freeDelta = [long]($freeAfter - $freeBefore) }

    return [pscustomobject]@{
        PlanId = $PlanId
        Status = 'Completed'
        MovedCount = $moved
        EstimatedMovedBytes = $movedBytes
        EstimatedMovedSize = Format-ByteCount $movedBytes
        SkippedCount = $skipped
        FailedCount = $failed
        FreeBytesBefore = $freeBefore
        FreeBytesAfter = $freeAfter
        FreeBytesDelta = $freeDelta
        Classes = $sections.ToArray()
    }
}

Export-ModuleMember -Function Get-SystemCleanupPlanExecution
