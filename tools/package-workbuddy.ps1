[CmdletBinding()]
param(
    [string] $OutputDirectory
)

# Builds a WorkBuddy-uploadable zip from the Agent Skill source.
#
# WorkBuddy open platform specification requirements:
# 1. SKILL.md must be located directly at the root of the ZIP archive.
# 2. Frontmatter must contain: name, display_name, display_name_en, description,
#    description_zh, description_en, examples_zh, examples_en, category, version, author.
# 3. Sub-resources: references/, scripts/, templates/ located directly under archive root.

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
    $val = $found.Groups['value'].Value.Trim()
    if ($val.StartsWith('"') -and $val.EndsWith('"')) {
        $val = $val.Substring(1, $val.Length - 2)
    }
    elseif ($val.StartsWith("'") -and $val.EndsWith("'")) {
        $val = $val.Substring(1, $val.Length - 2)
    }
    return $val
}

function Get-NestedValue {
    param([string] $Text, [string] $Key)
    $pattern = "(?m)^[ \t]+$([regex]::Escape($Key)):\s*(?<value>.*)$"
    $found = [regex]::Match($Text, $pattern)
    if (-not $found.Success) { return $null }
    $val = $found.Groups['value'].Value.Trim()
    if ($val.StartsWith('"') -and $val.EndsWith('"')) {
        $val = $val.Substring(1, $val.Length - 2)
    }
    elseif ($val.StartsWith("'") -and $val.EndsWith("'")) {
        $val = $val.Substring(1, $val.Length - 2)
    }
    return $val
}

function Get-YamlList {
    param([string] $Text, [string] $Key)
    $pattern = "(?m)^$([regex]::Escape($Key)):[ \t]*\r?\n(?<items>(?:[ \t]+-[ \t]+[^\r\n]*(?:\r?\n|$))+)"
    $found = [regex]::Match($Text, $pattern)
    if (-not $found.Success) { return @() }
    $lines = $found.Groups['items'].Value -split '\r?\n'
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        $m = [regex]::Match($line, '^[ \t]+-[ \t]+(?<val>.*)$')
        if ($m.Success) {
            $item = $m.Groups['val'].Value.Trim().Trim('"', "'")
            if ($item) { $result.Add($item) }
        }
    }
    return $result.ToArray()
}

function Format-YamlScalar {
    param([string] $Value)
    # Standard double-quoted YAML scalar
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    return '"' + $escaped + '"'
}

# 1. Resolve metadata fields (top-level preferred, fallback to metadata.workbuddy)
$name = Get-TopLevelValue -Text $frontmatter -Key 'name'
$description = Get-TopLevelValue -Text $frontmatter -Key 'description'
if (-not $name) { throw 'SKILL.md frontmatter is missing name.' }
if (-not $description) { throw 'SKILL.md frontmatter is missing description.' }
$skillName = $name

$metaBlock = ""
$metaMatch = [regex]::Match($frontmatter, '(?ms)^metadata:\s*\r?\n(?<block>(?:[ \t]+.*(?:\r?\n|$))+?)(?=^\S|\z)')
if ($metaMatch.Success) {
    $metaBlock = $metaMatch.Groups['block'].Value
}

$requiredKeys = @('display_name', 'display_name_en', 'description_zh', 'description_en', 'category', 'version', 'author')
$resolvedMetadata = [ordered]@{}

foreach ($key in $requiredKeys) {
    $val = Get-TopLevelValue -Text $frontmatter -Key $key
    if (-not $val -and $metaBlock) {
        $val = Get-NestedValue -Text $metaBlock -Key $key
    }
    if (-not $val) {
        throw "SKILL.md frontmatter is missing required WorkBuddy field '$key'."
    }
    $resolvedMetadata[$key] = $val
}

$examplesZh = Get-YamlList -Text $frontmatter -Key 'examples_zh'
$examplesEn = Get-YamlList -Text $frontmatter -Key 'examples_en'

# 2. Build normalized frontmatter for WorkBuddy
$generated = [System.Collections.Generic.List[string]]::new()
$generated.Add('---')
$generated.Add("name: $name")
$generated.Add("display_name: $(Format-YamlScalar $resolvedMetadata['display_name'])")
$generated.Add("display_name_en: $(Format-YamlScalar $resolvedMetadata['display_name_en'])")
$generated.Add("description: $(Format-YamlScalar $description)")
$generated.Add("description_zh: $(Format-YamlScalar $resolvedMetadata['description_zh'])")
$generated.Add("description_en: $(Format-YamlScalar $resolvedMetadata['description_en'])")

if ($examplesZh.Count -gt 0) {
    $generated.Add('examples_zh:')
    foreach ($ex in $examplesZh) {
        $generated.Add("  - $(Format-YamlScalar $ex)")
    }
}
if ($examplesEn.Count -gt 0) {
    $generated.Add('examples_en:')
    foreach ($ex in $examplesEn) {
        $generated.Add("  - $(Format-YamlScalar $ex)")
    }
}

$generated.Add("category: $(Format-YamlScalar $resolvedMetadata['category'])")
$generated.Add("version: $(Format-YamlScalar $resolvedMetadata['version'])")
$generated.Add("author: $(Format-YamlScalar $resolvedMetadata['author'])")
$generated.Add('---')
$generated.Add('')
$builtSkill = ($generated -join "`n") + "`n" + $body

# 3. Stage the files
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

# 4. Create ZIP archive with SKILL.md directly at root (WorkBuddy specification)
$version = $resolvedMetadata['version']
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$zipPath = Join-Path $OutputDirectory "$skillName-$version.zip"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

$itemsToZip = @(Get-ChildItem -LiteralPath $stageSkill).FullName
Compress-Archive -Path $itemsToZip -DestinationPath $zipPath -CompressionLevel Optimal

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
$hashFile = "$zipPath.sha256"
[IO.File]::WriteAllText($hashFile, "$hash *$([IO.Path]::GetFileName($zipPath))`n", $encoding)

$entries = (Get-ChildItem -LiteralPath $stageSkill -File -Recurse).Count
[pscustomobject]@{
    Zip = $zipPath
    Sha256 = $hash
    Sha256File = $hashFile
    RootFolder = '/'
    FileCount = $entries
    Version = $version
} | ConvertTo-Json
