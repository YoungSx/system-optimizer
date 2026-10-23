[CmdletBinding()]
param(
    [ValidateRange(30, 3650)]
    [int] $MinimumAgeDays = 30
)

$modulePath = Join-Path $PSScriptRoot 'cleanup.psm1'
Import-Module -Name $modulePath -Force -ErrorAction Stop
New-SystemCleanupPlan -MinimumAgeDays $MinimumAgeDays | ConvertTo-Json -Depth 5
