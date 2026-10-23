# System Optimizer

A Windows cleanup Agent Skill. It scans per-user cache categories that programs rebuild on demand, shows them as one reviewable plan, and moves only an explicitly approved plan to the Recycle Bin.

| Category | Roots (under the current user's profile) | Age floor | Opt-in |
| --- | --- | --- | --- |
| `temp` | `Temp` | 30 days | No |
| `crashdumps` | `CrashDumps` | 7 days | No |
| `thumbnails` | `Microsoft\Windows\Explorer` (thumb/icon cache files) | 7 days | No |
| `wer` | `Microsoft\Windows\WER\ReportQueue`, `ReportArchive` | 7 days | No |
| `dxshadercache` | `NVIDIA\DXCache`, `GLCache`, `AMD\DxCache`, `GLCache`, `Intel\ShaderCache` | none | **Yes** |

It does not clean browser data, Downloads, the Recycle Bin, Windows components, the registry, or other users' profiles. It never runs as administrator.

Adding a category means adding one file under `scripts/classes/` that exports `Get-CleanupClass`; the plan, approval, and execution path stays untouched. The catalog validates every module's contract at load time and rejects duplicates.

## Layout

```
SKILL.md                       Agent instructions (portable frontmatter + metadata.workbuddy block)
CHANGELOG.md                   Version history and release notes
docs/release-process.md        Standard release process, SemVer policy, and SOP
references/cleanup-policy.md   Risk levels, user-facing wording, V1 exclusions, research basis
scripts/check.ps1              Report OS/account support and the live catalog; no scan
scripts/scan.ps1               Build a plan; prints the plan summary as JSON
scripts/show-plan.ps1          Show plan details (-Full for every path)
scripts/clean.ps1              Execute one approved plan
scripts/discard.ps1            Delete a cancelled plan's local manifest
scripts/systemoptimizer.psm1   Composition root; exports the product surface only
scripts/core/filesystem.psm1   Path containment, reparse-point and enumeration primitives
scripts/core/environment.psm1  OS, account, profile and cache-root resolution
scripts/core/catalog.psm1      Class registry, contract validation, class readiness
scripts/core/plan.psm1         Sealed plan manifests, checksums, summary rendering
scripts/core/executor.psm1     Revalidating execution into the Recycle Bin
scripts/classes/*.psm1         One file per cleanup category
tests/smoke.ps1                Behaviour tests for the safety contract
tools/package-workbuddy.ps1    Build the WorkBuddy marketplace zip and SHA-256 hash
tools/release.ps1              Release assistant: version bump, validation, tag & release
.github/workflows/ci.yml       CI pipeline: smoke tests and package verification on Windows
.github/workflows/release.yml  Release pipeline: automated build and GitHub Release upon tag push
```

## Run

```powershell
pwsh -File scripts/check.ps1                    # support status + catalog, no scan
pwsh -File scripts/scan.ps1 -Class temp,crashdumps,thumbnails,wer
pwsh -File scripts/scan.ps1 -Class dxshadercache -OptIn dxshadercache
pwsh -File scripts/show-plan.ps1 -PlanId <id>
pwsh -File scripts/clean.ps1 -PlanId <id> -ApprovedPlanId <id> -Confirm:$false
pwsh -File scripts/discard.ps1 -PlanId <id>
pwsh -File tests/smoke.ps1
```

## Approval model

A scan writes a SHA-256 sealed plan manifest under `%LOCALAPPDATA%\SystemOptimizer\plans`. Execution requires `-ApprovedPlanId` to equal the plan being run, revalidates every candidate (user SID, root inside the profile, path inside that root, no reparse point in any path segment, unchanged size and timestamps, still older than the cutoff), and skips anything that no longer matches. There is no fallback to permanent deletion.

Categories marked `RequiresExplicitOptIn` are refused at plan time unless the caller also passes `-OptIn <id>`, so a routine "clean junk" request cannot silently pull in a category whose cleanup the user would notice.

Free space is measured before the scan and after execution; the reported delta is a real measurement but other processes writing to the same drive can dilute it.

## Packaging & Release

- **Release Documentation**: See [`docs/release-process.md`](file:///home/ubuntu/.t3/worktrees/system-optimizer/t3-744f0112/docs/release-process.md) for full release procedures, SemVer rules, and hotfix guidelines.
- **Packaging for WorkBuddy**: `tools/package-workbuddy.ps1` flattens the `metadata.workbuddy` block into the top-level frontmatter WorkBuddy expects (`display_name`, `description_zh`, `description_en`, `category`, `version`, `author`) and writes `build/system-optimizer-<version>.zip` and `.sha256` with `system-optimizer/` as the archive root.
- **Automated Release Script**:
  ```powershell
  # Preview patch bump
  pwsh -File tools/release.ps1 -Bump patch -DryRun

  # Bump minor version, update changelog, verify package, and create git tag
  pwsh -File tools/release.ps1 -Bump minor -Commit -Tag
  ```
- **CI / CD**: Automatically verified on Windows via GitHub Actions (`.github/workflows/ci.yml`). Tag pushes (`v*`) automatically trigger `.github/workflows/release.yml` to build the zip package, verify sha256, and publish a GitHub Release with attached assets.
