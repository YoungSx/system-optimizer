[CmdletBinding()]
param()

# Reports whether this machine and account are supported, and which cleanup
# classes exist here. Answers environment questions only: no plan, no changes.

Import-Module -Name (Join-Path $PSScriptRoot 'systemoptimizer.psm1') -Force -ErrorAction Stop

$readiness = Get-SystemCleanupReadiness
$catalog = @()
if ($readiness.Supported) {
    $catalog = @(Get-CleanupCatalog | ForEach-Object {
        [pscustomobject]@{
            Id = $_.Id
            Title = $_.Title
            Risk = $_.Risk
            MinAgeDays = $_.MinAgeDays
            RequiresExplicitOptIn = $_.RequiresExplicitOptIn
        }
    })
}

[pscustomobject]@{
    Supported = $readiness.Supported
    OperatingSystem = $readiness.OperatingSystem
    ProfileRoot = $readiness.ProfileRoot
    Reason = $readiness.Reason
    Classes = $catalog
} | ConvertTo-Json -Depth 4
