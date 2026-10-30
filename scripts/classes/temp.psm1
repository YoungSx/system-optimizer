Set-StrictMode -Version Latest

# A class module declares its own dependencies so it can be imported, tested,
# and reasoned about on its own. It never relies on the host module's session.
$script:CorePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'core'
Import-Module -Name (Join-Path $script:CorePath 'filesystem.psm1') -ErrorAction Stop
Import-Module -Name (Join-Path $script:CorePath 'environment.psm1') -ErrorAction Stop

# Low-risk class: the current user's Temp folder, old regular files only.
# This is the V1 behaviour, unchanged, now expressed as one catalog entry.
#
# Temp is the one class where Windows can redirect the folder. A redirected Temp
# is refused rather than followed, because the redirect target has never been
# reviewed by a human.

function Get-CleanupClass {
    return [pscustomobject]@{
        Id = 'temp'
        Title = '临时文件'
        TitleEn = 'Temporary files'
        Risk = 'Low'
        MinAgeDays = 30
        RequiresExplicitOptIn = $false
        Impact = '各类程序运行时写入的临时文件。正在运行的程序会重新创建它们，清理不影响已安装的应用。'
        ImpactEn = 'Temporary files written by applications during execution. Active programs will automatically recreate them, and cleanup does not affect installed software.'
        Roots = @('Temp')
        Collect = {
            param($Root, $CutoffUtc, $MaximumEntries)

            $profileRoot = Get-UserLocalAppData
            $expected = Get-NormalizedPath -Path (Join-Path $profileRoot 'Temp')
            $actual = Get-NormalizedPath -Path ([IO.Path]::GetTempPath())

            if (-not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'The current Windows Temp location is redirected or unsupported. That category was skipped.'
            }
            if (-not (Test-Path -LiteralPath $expected -PathType Container)) { return $null }

            $rootItem = Get-Item -LiteralPath $expected -Force -ErrorAction Stop
            if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'The current-user Temp folder is a reparse point. That category was skipped.'
            }

            $scan = Get-CandidatesFromRoot -Root $expected -CutoffUtc $CutoffUtc -MaximumEntries $MaximumEntries
            return [pscustomobject]@{
                Candidates = $scan.Candidates
                SkippedReparsePoints = $scan.SkippedReparsePoints
                SkippedReadErrors = $scan.SkippedReadErrors
                ObservedEntries = $scan.ObservedEntries
            }
        }
    }
}

Export-ModuleMember -Function Get-CleanupClass
