# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.2] - 2026-10-30

### Added
- Added high-resolution project icon (`assets/icon.png`, 512x512) for visual branding across `README.md`, `SKILL.md`, and WorkBuddy marketplace avatar.
- Updated `tools/package-workbuddy.ps1` to include `assets/` in the WorkBuddy distribution ZIP package.

### Changed
- Renamed skill identifier to `computer-optimizer` (`Computer Optimizer`) to resolve name collision on the WorkBuddy skill marketplace.
- Enhanced bilingual (Chinese & English) coverage across all category definition modules (`ImpactEn` added to `temp`, `crashdumps`, `thumbnails`, `wer`, and `dxshadercache`).
- Included `TitleEn` and `ImpactEn` in JSON plan sections, blocked classes, and details output.
- Updated documentation and packaging targets to reflect the `computer-optimizer` naming.

## [0.2.1] - 2026-10-30

### Added
- Aligned `SKILL.md` frontmatter with official WorkBuddy skill specifications:
  - Standardized top-level fields: `display_name` (系统优化助手), `display_name_en` (System Optimizer), `description_zh`, `description_en`, `examples_zh`, `examples_en`, `category`, `version`, `author`.
  - Added bilingual preset command examples for the WorkBuddy marketplace and quick-prompt panel.
- Added comprehensive bilingual (Chinese & English) instructions to `SKILL.md` and `references/cleanup-policy.md`:
  - Step-by-step SOP workflow (Check -> Scan -> Present -> Threshold check -> Request approval -> Show details -> Clean -> Discard -> Report).
  - Clear novice-friendly conversation guidelines, user reply options, and strict exclusion list.
- Added `@references/cleanup-policy.md` resource reference syntax adhering to WorkBuddy agent guidelines.
- Bilingual README (`README.md`) covering WorkBuddy alignment, supported categories, safety model, and packaging SOP.

### Fixed
- Fixed WorkBuddy ZIP packaging layout in `tools/package-workbuddy.ps1`:
  - Files are now compressed directly into the archive root (`SKILL.md`, `references/`, `scripts/`), fixing upload error `450019` caused by nested wrapper directories.
  - Fixed YAML scalar double-quote formatting bug in `tools/package-workbuddy.ps1`.
- Updated CI verification in `.github/workflows/ci.yml` to validate root-level `SKILL.md` archive structure.

## [0.2.0] - 2026-10-24

### Added
- Pluggable cleanup category registry under `scripts/classes/`.
- Five cleanup categories:
  - `temp`: Temporary files under `%LOCALAPPDATA%\Temp` (30-day floor).
  - `crashdumps`: Application crash dumps under `%LOCALAPPDATA%\CrashDumps` (7-day floor).
  - `thumbnails`: Explorer thumbnail and icon caches (7-day floor).
  - `wer`: Windows Error Reporting queue and archives (7-day floor).
  - `dxshadercache`: GPU shader caches for NVIDIA, AMD, and Intel (requires `-OptIn` and idle graphics processes).
- Execution-time profile guard refusing any plan whose recorded root is outside the user profile.
- Pre- and post-cleanup disk free space measurement.
- Contract validation and unique ID enforcement for category modules.
