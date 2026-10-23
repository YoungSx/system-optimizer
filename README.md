# System Optimizer

A Windows cleanup Agent Skill. V1 does exactly one thing: it finds ordinary files in the current user's `%LOCALAPPDATA%\Temp` that have not changed for 30 days, shows them as a reviewable plan, and moves only an approved plan to the Recycle Bin.

It does not clean browser data, Downloads, the Recycle Bin, Windows components, the registry, or other users' profiles. It never runs as administrator.

## Layout

```
SKILL.md                       Agent instructions (portable frontmatter + metadata.workbuddy block)
references/cleanup-policy.md   Risk levels, user-facing wording, V1 exclusions, research basis
scripts/check.ps1              Report OS/account/Temp support; no scan, no file access
scripts/scan.ps1               Build a plan; prints the plan summary as JSON
scripts/show-plan.ps1          Show plan details (-Full for every path)
scripts/clean.ps1              Execute one approved plan
scripts/discard.ps1            Delete a cancelled plan's local manifest
scripts/cleanup.psm1           Scanning, validation, and execution logic
tests/smoke.ps1                Safety behaviour tests
tools/package-workbuddy.ps1    Build the WorkBuddy marketplace zip
```

## Run

```powershell
pwsh -File scripts/check.ps1                    # environment support only
pwsh -File scripts/scan.ps1                     # plan only, no file changes
pwsh -File scripts/show-plan.ps1 -PlanId <id>
pwsh -File scripts/clean.ps1 -PlanId <id> -ApprovedPlanId <id> -Confirm:$false
pwsh -File scripts/discard.ps1 -PlanId <id>
pwsh -File tests/smoke.ps1
```

## Approval model

A scan writes a SHA-256 sealed plan manifest under `%LOCALAPPDATA%\SystemOptimizer\plans`. Execution requires `-ApprovedPlanId` to equal the plan being run, revalidates every candidate (user SID, root containment, no reparse point in any path segment, unchanged size and timestamps, still older than the cutoff), and skips anything that no longer matches. There is no fallback to permanent deletion.

## Packaging for WorkBuddy

`tools/package-workbuddy.ps1` flattens the `metadata.workbuddy` block into the top-level frontmatter WorkBuddy expects (`display_name`, `description_zh`, `description_en`, `category`, `version`, `author`) and writes `build/system-optimizer-<version>.zip` with `system-optimizer/` as the archive root.
