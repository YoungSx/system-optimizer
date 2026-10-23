[CmdletBinding()]
param()

# Reports whether this machine and account are supported by the skill.
# It answers environment questions only: no scan, no plan, no file changes.

$modulePath = Join-Path $PSScriptRoot 'cleanup.psm1'
Import-Module -Name $modulePath -Force -ErrorAction Stop
Get-SystemCleanupReadiness | ConvertTo-Json -Depth 3
