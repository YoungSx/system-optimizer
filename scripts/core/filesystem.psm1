Set-StrictMode -Version Latest

# Shared filesystem primitives. Every class and every executor revalidation goes
# through these, so containment, reparse-point, and age rules cannot drift
# between scanning and execution.

function Format-ByteCount {
    param([long] $Bytes)

    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N1} KB' -f ($Bytes / 1KB) }
    return "$Bytes bytes"
}

function Get-NormalizedPath {
    param([Parameter(Mandatory)][string] $Path)

    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-PathWithinRoot {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Root
    )

    $rootPath = Get-NormalizedPath -Path $Root
    $targetPath = [IO.Path]::GetFullPath($Path)
    return $targetPath.StartsWith($rootPath + '\', [StringComparison]::OrdinalIgnoreCase)
}

# Returns $false instead of throwing when any segment is missing, because a
# vanished path is exactly what revalidation must reject rather than crash on.
function Test-NoReparsePointInPath {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Root
    )

    try {
        $current = Get-NormalizedPath -Path $Root
        $rootItem = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }

        $targetPath = [IO.Path]::GetFullPath($Path)
        if (-not (Test-PathWithinRoot -Path $targetPath -Root $current)) { return $false }

        $relativePath = $targetPath.Substring($current.Length).TrimStart('\')
        $parts = $relativePath.Split('\')
        for ($index = 0; $index -lt $parts.Length; $index++) {
            $current = Join-Path $current $parts[$index]
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            $isLast = $index -eq ($parts.Length - 1)
            if (-not $isLast -and -not $item.PSIsContainer) { return $false }
            if ($isLast -and $item.PSIsContainer) { return $false }
        }

        return $true
    }
    catch {
        return $false
    }
}

function Get-CandidatesFromRoot {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][DateTime] $CutoffUtc,
        [int] $MaximumEntries = 250000
    )

    $candidates = [System.Collections.Generic.List[object]]::new()
    $directories = [System.Collections.Generic.Stack[string]]::new()
    $directories.Push($Root)
    $skippedReparsePoints = 0
    $skippedReadErrors = 0
    $observedEntries = 0

    while ($directories.Count -gt 0) {
        $current = $directories.Pop()
        try {
            $children = @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)
        }
        catch {
            $skippedReadErrors++
            continue
        }

        foreach ($child in $children) {
            $observedEntries++
            if ($observedEntries -gt $MaximumEntries) {
                throw "Scanning $Root exceeded $MaximumEntries entries. No cleanup plan was created."
            }

            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $skippedReparsePoints++
                continue
            }

            if ($child.PSIsContainer) {
                $directories.Push($child.FullName)
                continue
            }

            if ($child.LastWriteTimeUtc -gt $CutoffUtc) {
                continue
            }

            $candidates.Add([pscustomobject]@{
                Id = [Guid]::NewGuid().ToString('N')
                Root = [IO.Path]::GetFullPath($Root)
                Path = [IO.Path]::GetFullPath($child.FullName)
                Length = [long]$child.Length
                LastWriteFileTimeUtc = [long]$child.LastWriteTimeUtc.ToFileTimeUtc()
                CreationFileTimeUtc = [long]$child.CreationTimeUtc.ToFileTimeUtc()
            })
        }
    }

    return [pscustomobject]@{
        Candidates = $candidates.ToArray()
        SkippedReparsePoints = $skippedReparsePoints
        SkippedReadErrors = $skippedReadErrors
        ObservedEntries = $observedEntries
    }
}

function Get-DriveFreeBytes {
    param([Parameter(Mandatory)][string] $Path)

    try {
        $volumeRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))
        if (-not $volumeRoot) { return $null }
        $drive = [IO.DriveInfo]::new($volumeRoot)
        if (-not $drive.IsReady) { return $null }
        return [long]$drive.AvailableFreeSpace
    }
    catch {
        return $null
    }
}

Export-ModuleMember -Function Format-ByteCount, Get-NormalizedPath, Test-PathWithinRoot, Test-NoReparsePointInPath, Get-CandidatesFromRoot, Get-DriveFreeBytes
