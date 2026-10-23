Set-StrictMode -Version Latest

# Supported-machine and supported-account checks. Every entry point calls these
# before touching the filesystem, so a class can never widen the holding.

function Assert-SupportedWindowsClient {
    $os = [Environment]::OSVersion
    if ($os.Platform -ne [PlatformID]::Win32NT -or $os.Version.Major -lt 10) {
        throw 'This skill supports Windows 10 and Windows 11 only. No files were changed.'
    }

    $versionKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $installationType = (Get-ItemProperty -LiteralPath $versionKey -Name InstallationType -ErrorAction Stop).InstallationType
    if ($installationType -ne 'Client') {
        throw 'This skill supports Windows client editions only. No files were changed.'
    }
}

function Assert-StandardUserContext {
    if ($env:SYSTEM_OPTIMIZER_ALLOW_ADMIN -eq '1') {
        return [Security.Principal.WindowsIdentity]::GetCurrent()
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this skill in a non-administrator session. Administrator access is not needed and is refused on purpose.'
    }
    return $identity
}

function Get-UserLocalAppData {
    $path = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if (-not $path) { throw 'The current user profile folder is unavailable. No files were scanned.' }
    return [IO.Path]::GetFullPath($path).TrimEnd('\')
}

# Resolves a path below the current user's LocalAppData and proves it is a real
# folder, not a redirect. Returns $null when the path does not exist, so callers
# can report a missing category instead of failing the whole scan.
function Resolve-UserCacheRoot {
    param([Parameter(Mandatory)][string] $RelativePath)

    $base = Get-UserLocalAppData
    $candidate = [IO.Path]::GetFullPath((Join-Path $base $RelativePath)).TrimEnd('\')
    $prefix = $base + '\'
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path '$RelativePath' resolves outside the current user profile."
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { return $null }

    $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The folder for '$RelativePath' is a reparse point and is not supported."
    }
    return $candidate
}

function Get-SystemCleanupReadiness {
    $readiness = [ordered]@{
        Supported = $false
        OperatingSystem = [Environment]::OSVersion.VersionString
        ProfileRoot = $null
        Reason = $null
    }

    try {
        Assert-SupportedWindowsClient
        $null = Assert-StandardUserContext
        $readiness.ProfileRoot = Get-UserLocalAppData
        $readiness.Supported = $true
    }
    catch {
        $readiness.Reason = $_.Exception.Message
    }

    return [pscustomobject]$readiness
}

Export-ModuleMember -Function Assert-SupportedWindowsClient, Assert-StandardUserContext, Get-UserLocalAppData, Resolve-UserCacheRoot, Get-SystemCleanupReadiness
