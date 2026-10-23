[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PlanId
)

$modulePath = Join-Path $PSScriptRoot 'cleanup.psm1'
Import-Module -Name $modulePath -Force -ErrorAction Stop
Remove-SystemCleanupPlan -PlanId $PlanId | ConvertTo-Json -Depth 3
