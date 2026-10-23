[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PlanId,
    [switch] $Full
)

$modulePath = Join-Path $PSScriptRoot 'cleanup.psm1'
Import-Module -Name $modulePath -Force -ErrorAction Stop
Get-SystemCleanupPlanDetails -PlanId $PlanId -Full:$Full | ConvertTo-Json -Depth 5
