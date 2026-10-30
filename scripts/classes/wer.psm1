Set-StrictMode -Version Latest

# A class module declares its own dependencies so it can be imported, tested,
# and reasoned about on its own. It never relies on the host module's session.
$script:CorePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'core'
Import-Module -Name (Join-Path $script:CorePath 'filesystem.psm1') -ErrorAction Stop
Import-Module -Name (Join-Path $script:CorePath 'environment.psm1') -ErrorAction Stop

# Windows Error Reporting keeps reports in Queue (not yet handled) and Archive
# (already handled). Windows' own Storage Sense cleanup targets both, so both are
# offered here, with a 7-day floor so a crash under active investigation is not
# erased the moment it happens.

$script:RootPaths = @(
    'Microsoft\Windows\WER\ReportQueue'
    'Microsoft\Windows\WER\ReportArchive'
)

function Get-CleanupClass {
    return [pscustomobject]@{
        Id = 'wer'
        Title = 'Windows 错误报告'
        TitleEn = 'Windows Error Reporting'
        Risk = 'Low'
        MinAgeDays = 7
        RequiresExplicitOptIn = $false
        Impact = 'Windows 保存的崩溃与异常报告记录。保留最近 7 天的报告以便排查问题，更早的清理后不再能查看。'
        ImpactEn = 'Crash and exception reports saved by Windows. Retains reports from the last 7 days for troubleshooting; older reports can no longer be viewed once cleared.'
        Roots = $script:RootPaths
        Collect = {
            param($Root, $CutoffUtc, $MaximumEntries)

            $candidates = [System.Collections.Generic.List[object]]::new()
            $reparse = 0
            $readErrors = 0
            $observed = 0
            $found = [System.Collections.Generic.List[string]]::new()

            foreach ($relative in $script:RootPaths) {
                $werRoot = Resolve-UserCacheRoot -RelativePath $relative
                if (-not $werRoot) { continue }
                $found.Add($relative)

                $scan = Get-CandidatesFromRoot -Root $werRoot -CutoffUtc $CutoffUtc -MaximumEntries $MaximumEntries
                $reparse += $scan.SkippedReparsePoints
                $readErrors += $scan.SkippedReadErrors
                $observed += $scan.ObservedEntries
                foreach ($candidate in $scan.Candidates) { $candidates.Add($candidate) }
            }

            if ($found.Count -eq 0) { return $null }

            return [pscustomobject]@{
                Candidates = $candidates.ToArray()
                Roots = $found.ToArray()
                SkippedReparsePoints = $reparse
                SkippedReadErrors = $readErrors
                ObservedEntries = $observed
            }
        }
    }
}

Export-ModuleMember -Function Get-CleanupClass
