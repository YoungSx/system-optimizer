[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PlanId
)

# Removes a cancelled plan's local path manifest.

Import-Module -Name (Join-Path $PSScriptRoot 'systemoptimizer.psm1') -Force -ErrorAction Stop
Remove-SystemCleanupPlan -PlanId $PlanId | ConvertTo-Json -Depth 3
