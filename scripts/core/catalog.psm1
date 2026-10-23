Set-StrictMode -Version Latest

$script:CorePath = $PSScriptRoot
Import-Module -Name (Join-Path $script:CorePath 'filesystem.psm1') -ErrorAction Stop
Import-Module -Name (Join-Path $script:CorePath 'environment.psm1') -ErrorAction Stop

# Category registry. Adding a cleanup class means adding one file under
# classes/ that exports Get-CleanupClass; nothing in the plan, approval, or
# execution path needs to change.

$script:ClassesPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'classes'
$script:Loaded = [ordered]@{}

function Import-CleanupClasses {
    param([switch] $Reload)

    if ($script:Loaded.Count -gt 0 -and -not $Reload) { return }
    $script:Loaded = [ordered]@{}

    if (-not (Test-Path -LiteralPath $script:ClassesPath -PathType Container)) {
        throw "The cleanup class folder is missing: $script:ClassesPath"
    }

    $classModules = @(Get-ChildItem -LiteralPath $script:ClassesPath -Filter '*.psm1' -File | Sort-Object Name)
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($file in $classModules) {
        $module = Import-Module -Name $file.FullName -Force -PassThru -ErrorAction Stop
        if (-not (& $module { Get-Command -Name Get-CleanupClass -ErrorAction SilentlyContinue })) {
            throw "Cleanup class module '$($file.Name)' does not export Get-CleanupClass."
        }
        $definition = & $module { Get-CleanupClass }

        foreach ($field in @('Id', 'Title', 'Risk', 'MinAgeDays', 'RequiresExplicitOptIn', 'Impact')) {
            if ($null -eq $definition.PSObject.Properties[$field]) {
                throw "Cleanup class '$($file.Name)' is missing the '$field' field."
            }
        }
        if ($definition.Risk -notin @('Low', 'Review', 'High')) {
            throw "Cleanup class '$($definition.Id)' declares an unknown risk level '$($definition.Risk)'."
        }
        if (-not $seen.Add([string]$definition.Id)) {
            throw "Cleanup class id '$($definition.Id)' is declared twice."
        }

        $script:Loaded[[string]$definition.Id] = [pscustomobject]@{
            Definition = $definition
            Module = $module
        }
    }
}

function Get-CleanupCatalog {
    param([switch] $Reload)

    Import-CleanupClasses -Reload:$Reload
    return @($script:Loaded.Values | ForEach-Object { $_.Definition })
}

# A category marked RequiresExplicitOptIn is never reachable through the default
# call. The caller has to name it in -OptIn as well, so an Agent (or a stale
# instruction) cannot silently pull a Review category into a routine cleanup.
function Assert-ClassOptIn {
    param(
        [Parameter(Mandatory)][string] $Id,
        [string[]] $OptIn
    )

    $entry = Resolve-CleanupClass -Id $Id
    if (-not [bool]$entry.Definition.RequiresExplicitOptIn) { return }

    $opted = @($OptIn | Where-Object { $_ -and ($_.Trim() -eq $Id) })
    if ($opted.Count -gt 0) { return }

    throw "Cleanup class '$Id' requires explicit opt-in. Re-run with -OptIn $Id after explaining its impact to the user."
}

function Resolve-CleanupClass {
    param([Parameter(Mandatory)][string] $Id)

    Import-CleanupClasses
    if (-not $script:Loaded.Contains([string]$Id)) {
        $known = ($script:Loaded.Keys -join ', ')
        throw "Unknown cleanup class '$Id'. Known classes: $known."
    }
    return $script:Loaded[[string]$Id]
}

# Invokes a class collector inside its own module scope, where the class'
# private helpers and vendor table are visible.
function Invoke-ClassCollector {
    param(
        [Parameter(Mandatory)] $Entry,
        [Parameter(Mandatory)][DateTime] $CutoffUtc,
        [int] $MaximumEntries = 250000
    )

    $definition = $Entry.Definition
    if (-not $definition.Collect) { throw "Cleanup class '$($definition.Id)' has no collector." }

    $result = & $Entry.Module {
        param($Collector, $CutoffUtc, $MaximumEntries)
        & $Collector -Root $null -CutoffUtc $CutoffUtc -MaximumEntries $MaximumEntries
    } $definition.Collect $CutoffUtc $MaximumEntries

    if ($null -eq $result) { return $null }

    return [pscustomobject]@{
        Candidates = @($result.Candidates)
        Roots = @(if ($result.PSObject.Properties['Roots']) { $result.Roots } else { $definition.Roots })
        SkippedReparsePoints = [int]$result.SkippedReparsePoints
        SkippedReadErrors = [int]$result.SkippedReadErrors
        ObservedEntries = [int]$result.ObservedEntries
    }
}

# Class-level preconditions that must hold both at scan time and at execution
# time. A class declares them by exporting a matching Test-* function.
function Test-ClassReady {
    param(
        [Parameter(Mandatory)] $Entry,
        [Parameter(Mandatory)][string] $Id
    )

    switch ($Id) {
        'dxshadercache' {
            $idle = & $Entry.Module { Test-ShaderCacheIdle }
            if (-not $idle) {
                return [pscustomobject]@{
                    Ready = $false
                    Reason = '检测到桌面或显卡驱动进程正在运行，现在清理着色器缓存会失败或造成卡顿。请关闭游戏后重试。'
                }
            }
        }
    }

    return [pscustomobject]@{ Ready = $true; Reason = $null }
}

Export-ModuleMember -Function Assert-ClassOptIn, Import-CleanupClasses, Get-CleanupCatalog, Resolve-CleanupClass, Invoke-ClassCollector, Test-ClassReady
