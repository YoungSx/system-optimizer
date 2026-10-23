[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]] $Class,

    # Categories whose definition sets RequiresExplicitOptIn must be named here
    # too. Splitting them out keeps a routine cleanup from silently widening.
    [string[]] $OptIn,

    [switch] $Reload
)

# Builds a plan for the requested categories. Changes no candidate file.
# Pass one or more ids from `check.ps1`, for example -Class temp,crashdumps.

# `-Class temp,crashdumps` arrives as one string when the script is launched
# through `pwsh -File`, so split on commas here as well as accepting an array.
function Split-ClassList {
    param([string[]] $Value)
    return @($Value | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

$classIds = Split-ClassList -Value $Class
$optInIds = Split-ClassList -Value $OptIn
if ($classIds.Count -eq 0) { throw 'Specify at least one cleanup class, for example -Class temp,crashdumps.' }

Import-Module -Name (Join-Path $PSScriptRoot 'systemoptimizer.psm1') -Force -ErrorAction Stop
New-SystemCleanupPlan -ClassId $classIds -OptIn $optInIds -Reload:$Reload | ConvertTo-Json -Depth 8
