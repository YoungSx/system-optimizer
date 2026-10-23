Set-StrictMode -Version Latest

# A class module declares its own dependencies so it can be imported, tested,
# and reasoned about on its own. It never relies on the host module's session.
$script:CorePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'core'
Import-Module -Name (Join-Path $script:CorePath 'filesystem.psm1') -ErrorAction Stop
Import-Module -Name (Join-Path $script:CorePath 'environment.psm1') -ErrorAction Stop

# Crash dumps are large and never read by anything except a debugger, but they
# are also the only evidence of a crash under investigation, so the age floor is
# short rather than zero.

function Get-CleanupClass {
    return [pscustomobject]@{
        Id = 'crashdumps'
        Title = '应用崩溃转储'
        TitleEn = 'Application crash dumps'
        Risk = 'Low'
        MinAgeDays = 7
        RequiresExplicitOptIn = $false
        Impact = '应用崩溃时写下的内存转储文件，只供调试使用。若正在排查某个崩溃，先保留再清理。'
        Roots = @('CrashDumps')
        Collect = {
            param($Root, $CutoffUtc, $MaximumEntries)

            $dumpRoot = Resolve-UserCacheRoot -RelativePath 'CrashDumps'
            if (-not $dumpRoot) { return $null }

            $scan = Get-CandidatesFromRoot -Root $dumpRoot -CutoffUtc $CutoffUtc -MaximumEntries $MaximumEntries
            $scoped = @($scan.Candidates | Where-Object { $_.Path -like '*.dmp' })
            return [pscustomobject]@{
                Candidates = $scoped
                SkippedReparsePoints = $scan.SkippedReparsePoints
                SkippedReadErrors = $scan.SkippedReadErrors
                ObservedEntries = $scan.ObservedEntries
            }
        }
    }
}

Export-ModuleMember -Function Get-CleanupClass
