[CmdletBinding()]
param(
    [string] $Version,
    [ValidateSet('patch', 'minor', 'major')] [string] $Bump,
    [switch] $SkipTests,
    [switch] $DryRun,
    [switch] $Commit,
    [switch] $Tag,
    [switch] $Push
)

# Automated release preparation and version bump script for System Optimizer.
#
# Steps:
# 1. Validates working tree state (clean git status).
# 2. Computes the target Semantic Version from -Version or -Bump.
# 3. Runs safety smoke tests (on Windows).
# 4. Updates version in SKILL.md and CHANGELOG.md.
# 5. Verifies package-workbuddy.ps1 generates a valid zip artifact.
# 6. Optionally commits, tags, and pushes to remote.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$skillRoot = Split-Path -Parent $PSScriptRoot
$skillFile = Join-Path $skillRoot 'SKILL.md'
$changelogFile = Join-Path $skillRoot 'CHANGELOG.md'
$packageScript = Join-Path $PSScriptRoot 'package-workbuddy.ps1'

if (-not (Test-Path -LiteralPath $skillFile -PathType Leaf)) {
    throw "SKILL.md not found at $skillFile"
}

# 1. Read current version from SKILL.md
$skillContent = Get-Content -LiteralPath $skillFile -Raw
$versionMatch = [regex]::Match($skillContent, '(?m)^\s*version:\s*["'']?(?<ver>\d+\.\d+\.\d+)["'']?')
if (-not $versionMatch.Success) {
    throw 'Could not extract current version from SKILL.md.'
}
$currentVersion = $versionMatch.Groups['ver'].Value

# 2. Determine target version
if ($Version) {
    if ($Version -notmatch '^\d+\.\d+\.\d+$') {
        throw "Version '$Version' is not a valid Semantic Version (MAJOR.MINOR.PATCH)."
    }
    $targetVersion = $Version
}
elseif ($Bump) {
    $parts = $currentVersion.Split('.') | ForEach-Object { [int]$_ }
    switch ($Bump) {
        'major' { $parts[0]++; $parts[1] = 0; $parts[2] = 0 }
        'minor' { $parts[1]++; $parts[2] = 0 }
        'patch' { $parts[2]++ }
    }
    $targetVersion = "$($parts[0]).$($parts[1]).$($parts[2])"
}
else {
    throw "Must specify either -Version <X.Y.Z> or -Bump <patch|minor|major>. Current version is $currentVersion."
}

Write-Host "Current version: $currentVersion"
Write-Host "Target version:  $targetVersion"

if ($targetVersion -eq $currentVersion) {
    Write-Warning "Target version $targetVersion is identical to current version."
}

# 3. Check git status
$gitStatus = git status --porcelain
if ($gitStatus -and -not $DryRun) {
    Write-Host "Untracked or uncommitted changes detected:"
    $gitStatus | Write-Host
    throw "Working tree is dirty. Commit or stash changes before releasing."
}

# 4. Run tests
if (-not $SkipTests) {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Write-Host "Running smoke tests..."
        $testScript = Join-Path $skillRoot 'tests/smoke.ps1'
        & pwsh -File $testScript
        if ($LASTEXITCODE -ne 0) {
            throw "Smoke tests failed with exit code $LASTEXITCODE."
        }
    }
    else {
        Write-Warning "Non-Windows platform detected; skipping Windows-specific smoke tests. Use Windows or GitHub Actions CI for full test coverage."
    }
}

$encoding = [Text.UTF8Encoding]::new($false)

# 5. Update SKILL.md
if ($DryRun) {
    Write-Host "[DryRun] Would update version to $targetVersion in $skillFile"
}
else {
    $updatedSkill = [regex]::Replace(
        $skillContent,
        '(?m)^(\s*version:\s*)["'']?(\d+\.\d+\.\d+)["'']?',
        "`${1}$targetVersion"
    )
    [IO.File]::WriteAllText($skillFile, $updatedSkill, $encoding)
    Write-Host "Updated $skillFile with version $targetVersion"
}

# 6. Update CHANGELOG.md if present
if (Test-Path -LiteralPath $changelogFile) {
    $changelogContent = Get-Content -LiteralPath $changelogFile -Raw
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if ($changelogContent -match '(?m)^##\s*\[Unreleased\]') {
        if ($DryRun) {
            Write-Host "[DryRun] Would replace [Unreleased] with [$targetVersion] - $today in $changelogFile"
        }
        else {
            $replacement = "## [Unreleased]`n`n## [$targetVersion] - $today`n"
            $updatedChangelog = [regex]::Replace(
                $changelogContent,
                '(?m)^##\s*\[Unreleased\][ \t]*\r?\n',
                $replacement
            )
            [IO.File]::WriteAllText($changelogFile, $updatedChangelog, $encoding)
            Write-Host "Updated $changelogFile for release $targetVersion ($today)"
        }
    }
}

# 7. Test packaging
Write-Host "Testing WorkBuddy package build..."
$tempBuild = Join-Path $skillRoot 'build-release-check'
try {
    & pwsh -File $packageScript -OutputDirectory $tempBuild | Out-Null
    Write-Host "Package verification succeeded."
}
finally {
    if (Test-Path -LiteralPath $tempBuild) {
        Remove-Item -LiteralPath $tempBuild -Recurse -Force
    }
}

# 8. Git Commit, Tag, Push
$tagName = "v$targetVersion"
if ($DryRun) {
    Write-Host "[DryRun] Completed. Target tag would be: $tagName"
    return
}

if ($Commit) {
    git add $skillFile
    if (Test-Path -LiteralPath $changelogFile) {
        git add $changelogFile
    }
    git commit -m "Release $tagName"
    Write-Host "Committed release changes for $tagName."

    if ($Tag) {
        git tag -a $tagName -m "Release $tagName"
        Write-Host "Created git tag $tagName."

        if ($Push) {
            git push origin HEAD
            git push origin $tagName
            Write-Host "Pushed commit and tag $tagName to origin."
        }
        else {
            Write-Host "Run the following command to push to remote:"
            Write-Host "  git push origin HEAD && git push origin $tagName"
        }
    }
}
else {
    Write-Host ""
    Write-Host "Release preparation complete. To finalize release, run:"
    Write-Host "  git add SKILL.md CHANGELOG.md"
    Write-Host "  git commit -m `"Release $tagName`""
    Write-Host "  git tag -a $tagName -m `"Release $tagName`""
    Write-Host "  git push origin HEAD && git push origin $tagName"
}
