Set-StrictMode -Version Latest

# A class module declares its own dependencies so it can be imported, tested,
# and reasoned about on its own. It never relies on the host module's session.
$script:CorePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'core'
Import-Module -Name (Join-Path $script:CorePath 'filesystem.psm1') -ErrorAction Stop
Import-Module -Name (Join-Path $script:CorePath 'environment.psm1') -ErrorAction Stop

# GPU shader caches are large, safe to rebuild, but expensive to rebuild in the
# moment. Deleting them while a game is running or while the display server is
# actively compiling will immediately re-create files and cause stutters.
#
# Because of that trade-off this class:
# 1. Declares Risk = 'Review' and RequiresExplicitOptIn = $true.
# 2. Checks for known GPU processes before declaring itself ready to scan.
# 3. Requires an explicit explanation to the user before they approve.

$script:Vendors = @(
    [pscustomobject]@{ Name = 'NVIDIA'; RelativePath = 'NVIDIA\DXCache' }
    [pscustomobject]@{ Name = 'NVIDIA GL'; RelativePath = 'NVIDIA\GLCache' }
    [pscustomobject]@{ Name = 'AMD'; RelativePath = 'AMD\DxCache' }
    [pscustomobject]@{ Name = 'AMD GL'; RelativePath = 'AMD\GLCache' }
    [pscustomobject]@{ Name = 'Intel'; RelativePath = 'Intel\ShaderCache' }
)

$script:BusyProcesses = @('dwm', 'nvcontainer', 'NVIDIA Overlay', 'RadeonSoftware', 'atiesrxx')

function Get-CleanupClass {
    return [pscustomobject]@{
        Id = 'dxshadercache'
        Title = '显卡着色器缓存'
        TitleEn = 'GPU shader caches'
        Risk = 'Review'
        MinAgeDays = 0
        RequiresExplicitOptIn = $true
        Impact = '显卡驱动为加速渲染保存的编译结果，删除后会自动重建。重建期间启动游戏可能比平时更慢、更卡一些。'
        ImpactEn = 'Pre-compiled shaders saved by graphics drivers to accelerate rendering. Rebuilt automatically, but launching games may experience minor initial stutter while recompiling.'
        Roots = @('NVIDIA\DXCache', 'NVIDIA\GLCache', 'AMD\DxCache', 'AMD\GLCache', 'Intel\ShaderCache')
        Collect = {
            param($Root, $CutoffUtc, $MaximumEntries)

            $candidates = [System.Collections.Generic.List[object]]::new()
            $reparse = 0
            $readErrors = 0
            $observed = 0
            $found = [System.Collections.Generic.List[string]]::new()

            foreach ($vendor in $script:Vendors) {
                $vendorRoot = Resolve-UserCacheRoot -RelativePath $vendor.RelativePath
                if (-not $vendorRoot) { continue }
                $found.Add($vendor.RelativePath)

                $scan = Get-CandidatesFromRoot -Root $vendorRoot -CutoffUtc $CutoffUtc -MaximumEntries $MaximumEntries
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

function Test-ShaderCacheIdle {
    foreach ($name in $script:BusyProcesses) {
        $running = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        if ($running.Count -gt 0) { return $false }
    }
    return $true
}

Export-ModuleMember -Function Get-CleanupClass, Test-ShaderCacheIdle
