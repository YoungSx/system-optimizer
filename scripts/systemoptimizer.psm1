Set-StrictMode -Version Latest

# Composition root. Loads the shared primitives first so imported class modules
# can call them, then wires the three core modules into one surface.

$script:CorePath = Join-Path $PSScriptRoot 'core'

Import-Module -Name (Join-Path $script:CorePath 'filesystem.psm1')
Import-Module -Name (Join-Path $script:CorePath 'environment.psm1')
Import-Module -Name (Join-Path $script:CorePath 'catalog.psm1')
Import-Module -Name (Join-Path $script:CorePath 'plan.psm1')
Import-Module -Name (Join-Path $script:CorePath 'executor.psm1')

Export-ModuleMember -Function @(
    'Get-SystemCleanupReadiness',
    'Get-CleanupCatalog',
    'New-SystemCleanupPlan',
    'Get-SystemCleanupPlanDetails',
    'Get-SystemCleanupPlanExecution',
    'Remove-SystemCleanupPlan',
    'Set-PlanStoreRoot',
    'Format-ByteCount'
)
