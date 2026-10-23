[CmdletBinding()]
param(
    [string] $OutputDirectory
)

# Builds a WorkBuddy-uploadable zip from the generic Agent Skill source.
#
# The repository keeps one source of truth: SKILL.md with a portable
# `metadata.workbuddy` block. WorkBuddy expects its marketplace fields at the
# top level of the frontmatter, so the packaging step flattens that block
# instead of maintaining a second hand-written SKILL.md.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$skillRoot = Split-Path -Parent $PSScriptRoot
$skillFile = Join-Path $skillRoot 'SKILL.md'
$skillName = Split-Path -Leaf $skillRoot

if (-not (Test-Path -LiteralPath $skillFile -PathType Leaf)) {
    throw "SKILL.md not found at $skillFile"
}
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $skillRoot 'build'
}

$content = Get-Content -LiteralPath $skillFile -Raw
$match = [regex]::Match($content, '^---\r?\n(?<frontmatter>.*?)\r?\n---\r?\n(?<body>.*)$', 'Singleline')
if (-not $match.Success) {
    throw 'SKILL.md must start with a YAML frontmatter block.'
}
$frontmatter = $match.Groups['frontmatter'].Value
$body = $match.Groups['body'].Value

function Get-TopLevelValue {
    param([string] $Text, [string] $Key)
    $pattern = "(?m)^$([regex]::Escape($Key)):\s*(?<value>.*)$"
    $found = [regex]::Match($Text, $pattern)
    if (-not $found.Success) { return $null }
    return $found.Groups['value'].Value.Trim()
}

$name = Get-TopLevelValue -Text $frontmatter -Key 'name'
$description = Get-TopLevelValue -Text $frontmatter -Key 'description'
if (-not $name) { throw 'SKILL.md frontmatter is missing name.' }
if (-not $description) { throw 'SKILL.md frontmatter is missing description.' }

# Prefer name from frontmatter so checkout/worktree directory names do not alter package root or zip filename
if ($name) {
    $skillName = $name
}

$block = [regex]::Match($frontmatter, '(?ms)^metadata:\s*\r?\n(?<block>(?:[ \t]+.*(?:\r?\n|$))+?)(?=^\S|\z)')
if (-not $block.Success) {
    throw 'SKILL.md frontmatter is missing the metadata block with WorkBuddy fields.'
}
$metadata = $block.Groups['block'].Value

function Get-NestedValue {
    param([string] $Text, [string] $Key)
    $pattern = "(?m)^[ \t]+$([regex]::Escape($Key)):\s*(?<value>.*)$"
    $found = [regex]::Match($Text, $pattern)
    if (-not $found.Success) { return $null }
    return $found.Groups['value'].Value.Trim()
}

function Format-YamlScalar {
    param([string] $Value)
    # Double-quoted YAML keeps colons, apostrophes, and CJK text unambiguous.
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    return '\"' + $escaped + '\"'
}

$required = @('display_name', 'display_name_en', 'description_zh', 'description_en', 'category', 'version', 'author')
$generated = [System.Collections.Generic.List[string]]::new()
$generated.Add('---')
$generated.Add("name: $name")
$generated.Add("description: $(Format-YamlScalar $description)")

foreach ($key in $required) {
    $value = Get-NestedValue -Text $metadata -Key $key
    if (-not $value) { throw "metadata.workbuddy.$key is required for a WorkBuddy package." }
    $generated.Add("${key}: $(Format-YamlScalar $value)")
}

$generated.Add('---')
$generated.Add('')
$builtSkill = ($generated -join "`n") + "`n" + $body

$stageRoot = Join-Path $OutputDirectory 'stage'
$stageSkill = Join-Path $stageRoot $skillName
if (Test-Path -LiteralPath $stageRoot) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
New-Item -Path $stageSkill -ItemType Directory -Force | Out-Null

$encoding = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText((Join-Path $stageSkill 'SKILL.md'), $builtSkill, $encoding)

foreach ($folder in @('references', 'scripts', 'templates')) {
    $source = Join-Path $skillRoot $folder
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { continue }
    $destination = Join-Path $stageSkill $folder
    New-Item -Path $destination -ItemType Directory -Force | Out-Null
    foreach ($file in Get-ChildItem -LiteralPath $source -File -Recurse) {
        $relative = $file.FullName.Substring($source.Length).TrimStart('\', '/')
        $target = Join-Path $destination $relative
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -Path $parent -ItemType Directory -Force | Out-Null }
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
}

$version = Get-NestedValue -Text $metadata -Key 'version'
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$zipPath = Join-Path $OutputDirectory "$skillName-$version.zip"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -LiteralPath $stageSkill -DestinationPath $zipPath -CompressionLevel Optimal

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
$hashFile = "$zipPath.sha256"
[IO.File]::WriteAllText($hashFile, "$hash *$([IO.Path]::GetFileName($zipPath))`n", $encoding)

$entries = (Get-ChildItem -LiteralPath $stageSkill -File -Recurse).Count
[pscustomobject]@{
    Zip = $zipPath
    Sha256 = $hash
    Sha256File = $hashFile
    RootFolder = $skillName
    FileCount = $entries
    Version = $version
} | ConvertTo-Json
