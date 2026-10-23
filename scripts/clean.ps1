[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string] $PlanId,
    [Parameter(Mandatory)][string] $ApprovedPlanId
)

# Executes one approved plan. -ApprovedPlanId must repeat the plan being run, so
# a typo or a stale conversation cannot authorize a different batch.

Import-Module -Name (Join-Path $PSScriptRoot 'systemoptimizer.psm1') -Force -ErrorAction Stop

$executionParameters = @{
    PlanId = $PlanId
    ApprovedPlanId = $ApprovedPlanId
}
if ($PSBoundParameters.ContainsKey('WhatIf')) { $executionParameters.WhatIf = $WhatIf }
if ($PSBoundParameters.ContainsKey('Confirm')) { $executionParameters.Confirm = $Confirm }

Get-SystemCleanupPlanExecution @executionParameters | ConvertTo-Json -Depth 8
