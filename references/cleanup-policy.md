# Cleanup Policy

## Product Goal

Make one narrow task understandable to a non-technical Windows user: identify files that a program will simply recreate, explain the trade-off, and move only an approved plan to the Recycle Bin.

The Agent may summarize evidence and help the user choose. The PowerShell helper owns candidate discovery and target validation. A model-generated path or classification never becomes executable authority.

## How a Category Becomes Eligible

A category module declares an id, a title, a risk level, an age floor, whether it needs an explicit opt-in, a user-facing impact statement, and a collector. The core never knows category names; it only enforces the contract. Adding a category means adding a file under `scripts/classes/`, not editing the approval chain.

A file is selected only when all of these are true:

- It sits below one of the roots the category declared, resolved inside the current user's profile.
- It is a regular file, not a directory or reparse point, and no segment of its path is a reparse point.
- Its last-write timestamp is at least the category's age floor old.
- Its path and metadata still match the saved plan at execution time.

The helper does not inspect file contents, infer junk from names or extensions, or scan arbitrary folders. Inaccessible entries are skipped and counted. If a category's root does not exist or Windows redirected it somewhere unsupported, the class is reported as not applicable instead of guessed at.

## Age Floors

Each floor encodes how long a wrong deletion stays visible:

- 30 days for `temp` — programs hold temp files open for a long time, and anything touched recently may still be in use.
- 7 days for `crashdumps` and `wer` — long enough to investigate a current crash, short enough that the files are stale.
- 7 days for `thumbnails` — cheap to regenerate, so the floor only protects files Explorer is currently writing.
- None for `dxshadercache` — the files are pure derived data, but they are gated by opt-in and a process check instead of by age.

The floors came from measurement, not taste: on the author's machine a 30-day rule against Temp produced zero candidates while 1 GB sat in GPU shader caches. A single global threshold would have made the product useless on the one category that mattered.

## Risk Levels

| Level | Meaning | Behavior |
| --- | --- | --- |
| Low | Data an application regenerates on demand | Offered in a normal scan plan |
| Review | Regenerable, but the regeneration is visible to the user (slow first launch, blank icons) | Offered only with an explicit opt-in flag and an impact statement |
| High | User data or state that cannot be reconstructed | Never implemented as a cleanup category |

High-risk, permanently excluded: Downloads, documents, photos, browser cookies/passwords/history, cloud-synced files, Recycle Bin emptying, Windows.old, restore points, WinSxS, `Windows\Installer`, pagefile/hiberfil, the registry, drivers, services, startup configuration, other users' profiles.

Do not claim that removing caches makes the PC faster. The supported, measurable purpose is recovering storage space. For `dxshadercache`, say the opposite of a speed claim: the next launches of GPU-heavy applications may be slower while shaders rebuild.

## Novice-Friendly Conversation

Prefer ordinary language and one decision at a time. Never require the user to know paths, extensions, PowerShell, or what a shader cache is.

Before scanning:

> 我先只检查一下能安全重建的缓存文件，不会打开文件内容，也不会删除任何东西。

After scanning, lead with the result and the action:

> 找到 3 类可以清理的缓存，合计约 1.2 GB。其中最大的是显卡着色器缓存（1.05 GB），删除后会自动重建，但下次进游戏可能有点卡。要清理时，我会把这批文件移到回收站；现在还没有改动文件。

Ask one clear question with choices the user can answer naturally:

> 你想怎么处理？
> - 清理这批文件（计划 `PLAN_ID`，可从回收站恢复，直到回收站被清空）
> - 先看文件名称
> - 取消

Do not use a generic "Proceed?" prompt. Name the categories, approximate size, destination, and plan ID. If the user asks for details, start with a few filenames and sizes; provide full paths only when useful or requested.

If the user chooses cleanup, that response approves only the displayed plan. Any rescan, changed category selection, new category, expired plan, or changed target requires a fresh summary and approval.

## Results and Recovery

- Distinguish the estimate from the outcome: report how many files moved and the sum of their recorded sizes.
- The helper measures free space before the scan and after execution. Report the delta as measured, and say plainly that other processes on the same drive can affect it.
- Name skipped and failed counts with plain reasons: still in use, changed since the scan, blocked by a running application.
- Explain recovery: open the Recycle Bin, select the file, choose Restore. Do not promise recovery after the Recycle Bin is emptied.

## Research Basis

- Storage Sense and Cleanup Recommendations are category-based, keep Downloads and cloud files untouched by default, and require opt-in for the more aggressive categories: [Microsoft Storage Sense](https://support.microsoft.com/en-us/windows/experience/storage-filemanagement/manage-drive-space-with-storage-sense).
- BleachBit separates selection, preview, and deletion, and warns before advanced cleaners: [General usage](https://docs.bleachbit.org/doc/general-usage/), [Expert mode](https://docs.bleachbit.org/doc/expert-mode/).
- CCleaner and similar tools group findings into user-recognizable categories with per-category descriptions rather than a flat file list, which is what this skill's plan output imitates.
- Microsoft advises using built-in mechanisms rather than manually deleting WinSxS contents: [Clean Up the WinSxS Folder](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder?view=windows-11).
- OWASP recommends limiting agent tools, requiring approval for high-impact operations, and validating authorization in the execution layer: [Excessive Agency](https://genai.owasp.org/llmrisk/llm062025-excessive-agency/).
