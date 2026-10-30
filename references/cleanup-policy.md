# 清理策略与安全规范 / Cleanup Policy

## 产品目标 / Product Goal

**中文**：面向非专业 Windows 用户，将复杂的磁盘清理任务简化为直观、可控、透明的操作：仅识别应用程序可自动重新生成的缓存文件，向用户解释清理带来的影响与代价，且只有在获得用户明确批准后，才将计划内的文件移入回收站。
Agent 可汇总扫描证据并协助用户决策，但具体候选文件的发现、规则判定与安全校验全部由底层 PowerShell 核心脚本执行。任何大语言模型生成的路径或推测分类，绝不能直接作为可执行的系统权限。

**English**: Make one narrow task understandable to a non-technical Windows user: identify files that a program will simply recreate, explain the trade-off, and move only an approved plan to the Recycle Bin.
The Agent may summarize evidence and help the user choose. The PowerShell helper owns candidate discovery and target validation. A model-generated path or classification never becomes executable authority.

---

## 候选文件准入判定契约 / How a Category Becomes Eligible

**中文**：每个清理类别模块（位于 `scripts/classes/`）独立声明其唯一标识 (`Id`)、中文标题 (`Title`)、英文标题 (`TitleEn`)、风险等级 (`Risk`)、保留时间阈值 (`MinAgeDays`)、是否需要显式授权 (`RequiresExplicitOptIn`)、用户影响说明 (`Impact`) 以及收集器 (`Collect`)。核心框架不硬编码类别名称，仅严格执行契约校验。

只有同时满足以下全部条件的文件，才会被作为候选对象纳入计划：
- 严格位于该类别声明的根目录之下，且该根目录必须解析在当前登录用户的用户配置目录（User Profile）内部。
- 必须是普通文件（Regular File），严禁为目录、符号链接或重解析点（Reparse Point），且其父路径的任何层级均不得包含重解析点。
- 其最后修改时间戳（LastWriteTimeUtc）必须早于该类别的保留时间阈值（达到设定的最少存留天数）。
- 在执行清理操作前，其实际文件路径、文件大小及时间戳必须与保存的密封计划清单完全一致。

辅助脚本绝不窥探文件内容，不根据文件名或扩展名臆测垃圾，也不扫描任意文件夹。无法访问的项会被自动跳过并记入统计。如果某个类别的根目录不存在，或 Windows 将其重定向至不受支持的位置，该类别将被标记为“不适用 (NotApplicable)”，绝不进行盲目推测。

**English**: A category module declares an id, a title (`Title` and `TitleEn`), a risk level, an age floor, whether it needs an explicit opt-in, a user-facing impact statement (`Impact`), and a collector. The core never knows category names; it only enforces the contract. Adding a category means adding a file under `scripts/classes/`, not editing the approval chain.

A file is selected only when all of these are true:
- It sits below one of the roots the category declared, resolved inside the current user's profile.
- It is a regular file, not a directory or reparse point, and no segment of its path is a reparse point.
- Its last-write timestamp is at least the category's age floor old.
- Its path and metadata still match the saved plan at execution time.

The helper does not inspect file contents, infer junk from names or extensions, or scan arbitrary folders. Inaccessible entries are skipped and counted. If a category's root does not exist or Windows redirected it somewhere unsupported, the class is reported as not applicable instead of guessed at.

---

## 驻留时间阈值 / Age Floors

**中文**：保留时间阈值代表误删风险在多长时间内对用户不可感知或具有安全缓冲：
- **`temp`（临时文件）**：30 天。许多应用程序会长周期保持临时文件句柄打开，近期被触及的任何文件很可能仍被活跃使用。
- **`crashdumps`（崩溃转储）与 `wer`（错误报告）**：7 天。该时长足以供排查最近发生的软件崩溃，同时确保过期无用的陈旧文件被清理。
- **`thumbnails`（缩略图缓存）**：7 天。缩略图重建开销很小，该阈值主要用于保护当前资源管理器正在写入的活跃缓存。
- **`dxshadercache`（着色器缓存）**：无天数限制。这些文件是纯粹的派生计算产物，但它们通过“显式授权（Opt-In）”机制与“活跃进程检测”进行保护，而非简单依赖天数。

阈值设计来自真实机器测量而非主观臆断：在开发机实测中，针对 Temp 的 30 天规则仅发现微量文件，但 GPU 着色器缓存占用超过 1 GB。如果采用单一的全局天数阈值，将导致该技能在最需要释放空间的场景中失效。

**English**: Each floor encodes how long a wrong deletion stays visible:
- 30 days for `temp` — programs hold temp files open for a long time, and anything touched recently may still be in use.
- 7 days for `crashdumps` and `wer` — long enough to investigate a current crash, short enough that the files are stale.
- 7 days for `thumbnails` — cheap to regenerate, so the floor only protects files Explorer is currently writing.
- None for `dxshadercache` — the files are pure derived data, but they are gated by opt-in and a process check instead of by age.

The floors came from measurement, not taste: on the author's machine a 30-day rule against Temp produced zero candidates while 1 GB sat in GPU shader caches. A single global threshold would have made the product useless on the one category that mattered.

---

## 风险等级与永久排除清单 / Risk Levels & Strict Exclusions

| 等级 / Level | 含义 / Meaning | 行为机制 / Behavior |
| --- | --- | --- |
| **低风险 (Low)** | 应用程序在需要时会自动重新生成的数据 / Data automatically rebuilt by apps | 默认纳入常规扫描计划中 / Included by default |
| **需复核 (Review)** | 可重新生成，但重建过程用户可明显感知（如游戏首次启动微卡顿、图标重新加载） / Rebuildable but user-noticeable | 仅在用户显式传入 `-OptIn` 且充分提示影响后纳入 / Requires `-OptIn` and clear notice |
| **高风险 (High)** | 无法重新构建或恢复的用户个人数据与关键状态 / Irreplaceable user data or system state | **严禁实现为清理类别，永久排除 / Permanently excluded** |

### 永久排除清单 (Strict Exclusions)

**中文**：严禁触碰或清理以下任何项目：
- 下载文件夹 (Downloads)、桌面 (Desktop)、文档 (Documents)、图片与相册 (Photos)
- 浏览器个人数据（Cookie、历史浏览记录、保存的密码）
- 各类云盘与同步目录（OneDrive, Dropbox, 腾讯微云等）
- 直接清空回收站 (Empty Recycle Bin)
- 系统底层及还原文件：`Windows.old`、系统还原点、WinSxS 目录、`Windows\Installer`
- 虚拟内存与休眠文件：`pagefile.sys`、`hiberfil.sys`、`swapfile.sys`
- Windows 注册表 (Registry)、驱动程序、系统服务、开机启动项配置
- 其他用户的账户目录或公共配置目录

**English**: Never touch or clean any of the following items:
- Downloads, Desktop, Documents, Photos, and user personal media folders
- Browser personal data (cookies, browsing history, saved credentials)
- Cloud storage sync folders (OneDrive, Dropbox, Weiyun, etc.)
- Emptying the Recycle Bin directly
- Low-level system & recovery storage: `Windows.old`, System Restore points, WinSxS, `Windows\Installer`
- Paging and hibernation files: `pagefile.sys`, `hiberfil.sys`, `swapfile.sys`
- Windows Registry, device drivers, system services, and startup items
- Other users' profiles, accounts, or public shared directories

**注意 / Note**：
切勿向用户宣称“清理缓存能让电脑变快”。本技能唯一支持且可实测的目标是**安全回收磁盘存储空间**。针对 `dxshadercache`，甚至需要说明相反的效果：下次启动依赖 GPU 的大型应用或游戏时，由于着色器需要重新编译，初次加载可能略有卡顿。
Never claim to the user that "cleaning caches speeds up your PC". The sole supported and measurable goal of this skill is **safely recovering disk storage space**. For `dxshadercache`, explain the opposite effect: next time a GPU application starts, initial load may stutter briefly as shaders recompile.

---

## 小白友好型交互话术规范 / Novice-Friendly Conversation Guide

**中文**：交互语言应通俗易懂，一次只引导用户做一个明确决定。切勿要求普通用户理解复杂路径、文件扩展名、PowerShell 命令或“着色器”的底层原理。

**English**: Conversational language must be clear, polite, and novice-friendly. Guide the user to make one explicit decision at a time. Never require standard users to decipher obscure file paths, extensions, PowerShell syntax, or the mechanics of GPU shader pipelines.

### 1. 扫描前提示 / Before Scanning
> **中文**：“我先只检查一下能安全重建的缓存文件，不会打开文件内容，也不会删除任何东西。”
>
> **English**: *"I will first only scan for cache files that can be safely rebuilt. I won't open file contents or delete anything."*

### 2. 扫描后汇报与方案说明 / After Scanning
以清晰的结果和行动为导向 / Clear and action-oriented results:
> **中文**：“找到 3 类可以清理的缓存，合计约 1.2 GB。其中最大的是显卡着色器缓存（1.05 GB），删除后会自动重建，但下次进游戏可能会有轻微卡顿。要清理时，我会把这批文件移到回收站；现在还没有改动任何文件。”
>
> **English**: *"Found 3 categories of cache that can be cleaned, totaling ~1.2 GB. The largest is GPU shader cache (1.05 GB), which will rebuild automatically but may cause slight initial stutter next time games launch. When cleaned, files are moved to the Recycle Bin; nothing has been changed yet."*

### 3. 发起明确单次确认 / Request Plan Approval
给出包含计划 ID、可恢复性说明及清晰选项的三选一提示 / Three-choice approval prompt:
> **中文**：“你想怎么处理？
> - **清理这批文件**（计划 ID: `PLAN_ID`，移入回收站，清空前可随时还原）
> - **先看文件名称**
> - **取消**”
>
> **English**: *"What would you like to do?
> - **Clean this plan** (Plan ID: `PLAN_ID`, move to Recycle Bin, can restore until emptied)
> - **Show file names first**
> - **Cancel**"*

**严格禁止 / Strict Restrictions**:
- **中文**：严禁使用泛化的“是否继续？”（Proceed?）或模糊确认。必须列明类别、预估体积、移入回收站及计划 ID。若用户选择查看详情，默认仅展示文件名与大小样例；仅在用户明确需要时才提供完整路径。用户回复“清理”仅代表授权当前显示的特定计划。任何重新扫描、类别变更、新类别加入、超时过期或目标变更，均必须重新生成计划并重新获得用户授权。
- **English**: Never use generic "Proceed?" or ambiguous confirmations. You must state the categories, estimated size, destination (Recycle Bin), and Plan ID. If the user asks for details, display sample filenames and sizes by default; provide full paths only when requested. A user's "clean" reply authorizes only the current specific plan. Any rescan, category change, expiration, or target adjustment requires generating a fresh plan and obtaining new approval.

---

## 结果汇报与回收站恢复指南 / Results and Recovery Guide

**中文**：
- **区分预估与实测**：汇报时明确说明实际成功移入回收站的文件数量以及这些文件记录的总大小。
- **磁盘剩余空间变化**：底层在执行前后测量系统可用空间。如实汇报实测差值，并通俗告知用户：该数值是系统真实测量结果，但可能因其他后台进程同时向该驱动器写入而有所增减。
- **跳过与失败项如实说明**：若有文件被跳过，以通俗原因汇报（例如“文件正被其他程序打开”、“扫描后文件已被修改”）。
- **回收站恢复指导**：告知用户若需还原，只需打开 Windows 回收站，找到对应文件右键选择“还原”即可。严禁向用户承诺回收站被清空后仍能恢复。

**English**:
- **Distinguish Estimates from Measured Results**: Clearly report both the number of items successfully moved to the Recycle Bin and the total file size they represented.
- **Measured Free Disk Space Change**: The execution engine measures system available storage before and after cleanup. Report the measured difference honestly, reminding the user that background processes may simultaneously write to disk.
- **Explain Skipped and Failed Items**: Plainly explain why items were skipped (e.g. "currently locked by an active application" or "modified after scanning").
- **Recycle Bin Restoration Instructions**: Advise users that to restore any file, they simply open the Windows Recycle Bin, right-click the desired file, and choose "Restore". Never promise restoration once the Recycle Bin has been emptied.

---

## 调研参考依据 / Research Basis

- **Microsoft Storage Sense**: 存储感知与清理建议均基于分类设计，默认不触碰下载与云端文件，针对更激进分类需用户显式勾选 / Category-driven cleanup with opt-in for deeper caches: [Microsoft Storage Sense](https://support.microsoft.com/en-us/windows/experience/storage-filemanagement/manage-drive-space-with-storage-sense)。
- **BleachBit**: 严格分离扫描选择、预览与删除执行，在高级清理前给予明确警告 / Separation of scan, preview, and execution: [General usage](https://docs.bleachbit.org/doc/general-usage/), [Expert mode](https://docs.bleachbit.org/doc/expert-mode/)。
- **CCleaner**: 将扫描发现组织为用户易于理解的高层分类及分类说明，而非杂乱的扁平路径列表 / High-level category grouping and readable impacts rather than flat path dumps.
- **Microsoft WinSxS 指南**: 微软官方明确建议使用系统内置机制维护组件存储，严禁直接手动删除 WinSxS 目录 / Guidance against manual system folder deletion: [Clean Up the WinSxS Folder](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder?view=windows-11)。
- **OWASP GenAI 安全规范**: 明确要求限制 Agent 权限工具、对高影响操作实施单次审批门禁，并在执行层强制进行权限与路径二次校验 / Gating high-impact actions and enforcing secondary execution-time checks: [Excessive Agency](https://genai.owasp.org/llmrisk/llm062025-excessive-agency/)。
