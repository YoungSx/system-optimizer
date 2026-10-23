[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PlanId,
    [switch] $Full
)

# Shows what an existing plan contains. Default output names a few files per
# category; -Full is the only path that reveals complete paths.

Import-Module -Name (Join-Path $PSScriptRoot 'systemoptimizer.psm1') -Force -ErrorAction Stop
Get-SystemCleanupPlanDetails -PlanId $PlanId -Full:$Full | ConvertTo-Json -Depth 6
