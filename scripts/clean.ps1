[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string] $PlanId,
    [Parameter(Mandatory)][string] $ApprovedPlanId
)

$modulePath = Join-Path $PSScriptRoot 'cleanup.psm1'
Import-Module -Name $modulePath -Force -ErrorAction Stop
$invokeParameters = @{
    PlanId = $PlanId
    ApprovedPlanId = $ApprovedPlanId
}
if ($PSBoundParameters.ContainsKey('WhatIf')) { $invokeParameters.WhatIf = $WhatIf }
if ($PSBoundParameters.ContainsKey('Confirm')) { $invokeParameters.Confirm = $Confirm }
Invoke-SystemCleanupPlan @invokeParameters | ConvertTo-Json -Depth 6
