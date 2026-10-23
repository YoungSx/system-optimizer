# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

### Changed
- Replaced monolithic single-file temp cleanup with modular category architecture.
- Decoupled module imports to avoid dropping exports across sessions.

## [0.1.0] - 2026-10-23

### Added
- Initial release of System Optimizer Windows Agent Skill.
- Plan-then-execute cleanup model for `%LOCALAPPDATA%\Temp`.
- SHA-256 sealed plan manifests stored under `%LOCALAPPDATA%\SystemOptimizer\plans`.
- Strict pre-execution candidate revalidation and Recycle Bin movement.
- Mandatory refusal of administrator privilege and reparse points/symlinks.
- Behaviour safety smoke tests (`tests/smoke.ps1`).
- WorkBuddy marketplace packaging script (`tools/package-workbuddy.ps1`).
