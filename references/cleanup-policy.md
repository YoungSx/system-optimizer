# Cleanup Policy

## Product Goal

Make one narrow cleanup task understandable to a non-technical Windows user: identify old temporary files, explain the proposed action, and move only an approved plan to the Recycle Bin.

The Agent may summarize evidence and help the user choose. The PowerShell helper owns candidate discovery and target validation. Do not let a model-generated path or classification become executable authority.

## V1 Eligibility

The scanner may select a file only when all of these are true:

- It is below the current user's standard `%LOCALAPPDATA%\Temp` directory.
- The standard Temp path returned by Windows matches that supported location.
- It is a regular file, not a directory or reparse point.
- Its last-write timestamp is at least 30 days old.
- Its path and metadata still match the saved plan at execution time.

The helper does not inspect file contents, infer junk from names or extensions, or scan arbitrary folders. Inaccessible entries are skipped and counted. If Windows has redirected Temp somewhere else, explain that this version does not support that location; do not guess.

## Risk Levels

| Level | Examples | V1 behavior |
| --- | --- | --- |
| Low | Old regular files in the supported current-user Temp folder | Show as one reviewable plan; move to Recycle Bin only after approval |
| Review | Browser cache, app-specific cache, old logs, crash dumps, large files, duplicates | Out of scope; explain that the owner app or a future dedicated scanner should identify these |
| High / excluded | Downloads, documents, photos, browser cookies/passwords/history, cloud files, Recycle Bin emptying, Windows.old, restore points, WinSxS, Windows\Installer, pagefile/hiberfil, registry, drivers, services, startup configuration | Never include in a V1 cleanup plan |

Do not claim that removing temporary files will make the PC faster. The supported and measurable purpose is recovering storage space.

## Novice-Friendly Conversation

Prefer ordinary language and one decision at a time. Avoid requiring the user to know paths, file extensions, PowerShell, or what a cache is.

Before scanning:

> 我先只检查当前账户里超过 30 天没有修改的临时文件，不会打开文件内容，也不会删除任何东西。

After scanning, lead with the result and action:

> 找到 42 个较旧的临时文件，合计约 180 MB。它们位于 Windows 当前账户的临时文件夹。要清理时，我会把这批文件移到回收站；现在还没有改动文件。

Ask one clear question with choices the user can answer naturally:

> 你想怎么处理？
> - 清理这批文件（计划 `PLAN_ID`，可从回收站恢复，直到回收站被清空）
> - 先看文件名称
> - 取消

Do not use a generic "Proceed?" prompt. Name the category, approximate size, destination, and plan ID. If the user asks for details, start with a few filenames and their sizes; provide full paths only when useful or requested.

If the user chooses cleanup, the Agent may treat that response as approval only for the displayed plan. Any rescan, changed selection, new category, expired plan, or changed target requires a fresh summary and approval.

## Results and Recovery

- Distinguish the scan estimate from the result: report how many files were moved and the sum of their recorded sizes.
- Do not claim the exact increase in free space unless it was measured separately and the measurement is attributable to this operation.
- Name skipped and failed counts, and summarize reasons such as changed files, inaccessible files, or Recycle Bin errors.
- Explain how to restore a moved file: open Recycle Bin, select the file, and choose Restore. Do not promise recovery after the Recycle Bin is emptied.

## Research Basis

- Windows Storage Sense and Cleanup Recommendations are category-based and keep Downloads and cloud files untouched by default unless the user opts in: [Microsoft Storage Sense](https://support.microsoft.com/en-us/windows/experience/storage-filemanagement/manage-drive-space-with-storage-sense).
- BleachBit separates selection, preview, and deletion, and provides risk warnings for advanced cleaners: [General usage](https://docs.bleachbit.org/doc/general-usage/) and [Expert mode](https://docs.bleachbit.org/doc/expert-mode/).
- Microsoft advises using built-in mechanisms rather than manually deleting WinSxS contents: [Clean Up the WinSxS Folder](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder?view=windows-11).
- OWASP recommends limiting agent tools, requiring approval for high-impact operations, and validating authorization in the execution layer: [Excessive Agency](https://genai.owasp.org/llmrisk/llm062025-excessive-agency/).
