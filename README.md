# 系统优化助手 (Computer Optimizer)

[English](#english-summary) | [中文说明](#中文说明)

---

## 中文说明

**系统优化助手 (Computer Optimizer)** 是一款专为 Windows 10 与 Windows 11 设计的安全磁盘空间回收 Agent Skill，全面对齐**腾讯 WorkBuddy 开放平台技能规范**与通用 Agent 技能规范。它只扫描属于当前用户的、可由软件自动安全重建的缓存类别，将扫描结果整理为直观的可审查计划，并仅在获得用户明确审批后将计划内的文件移入回收站。

### 核心特性与支持类别

| 类别 (Category) | 扫描根路径 (当前用户 Profile 下) | 保留阈值 (Age Floor) | 显式授权 (Opt-in) | 说明 |
| --- | --- | --- | --- | --- |
| `temp` | `%LOCALAPPDATA%\Temp` | 30 天 | 否 | 应用程序写入的临时文件，仅扫描30天前未被变动的文件 |
| `crashdumps` | `%LOCALAPPDATA%\CrashDumps` | 7 天 | 否 | 应用程序历史崩溃转储文件，保留7天供排查近期问题 |
| `thumbnails` | `Microsoft\Windows\Explorer` | 7 天 | 否 | 资源管理器缩略图与图标缓存文件 |
| `wer` | `Microsoft\Windows\WER` (队列与归档) | 7 天 | 否 | Windows 错误报告队列与归档 |
| `dxshadercache` | NVIDIA / AMD / Intel 着色器缓存 | 无 | **必须** | 显卡编译的着色器缓存；重建需重新编译，须单独显式授权并在图形进程空闲时运行 |

- **绝对安全红线**：严禁触碰下载文件夹、桌面、文档、照片、浏览器个人数据（Cookie/密码/历史记录）、网盘同步文件夹、回收站本身、`Windows.old`、系统还原点、WinSxS、注册表、系统服务或任何其他用户目录。
- **权限安全机制**：绝不要求以管理员身份运行（非管理员标准上下文运行）。
- **模块化可扩展**：新增类别仅需在 `scripts/classes/` 下增加一个导出 `Get-CleanupClass` 的模块文件，无需改动计划生成、安全审批与执行流。

### WorkBuddy 规范对齐

1. **元数据规范**：`SKILL.md` 顶层包含 WorkBuddy 官方标准 Frontmatter：
   - `name`: 连字符小写英文字母唯一标识 (`computer-optimizer`)
   - `display_name`: 界面中文展示名（“系统优化助手”）
   - `display_name_en`: 英文展示名称（“Computer Optimizer”）
   - `description`: 意图识别与场景触发描述（含触发时机与触发词）
   - `description_zh` / `description_en`: 中英文双语功能简介
   - `examples_zh` / `examples_en`: 市场与快捷提问指令中英文列表
   - `category` / `version` / `author`: 分类标签、语义化版本与作者名称
2. **正文与指令双语化**：`SKILL.md` 与参考文档 `references/cleanup-policy.md` 均采用中英文双语对照与步骤化 SOP。
3. **ZIP 发布结构规范**：`tools/package-workbuddy.ps1` 严格按照 WorkBuddy 开放平台要求，将 `SKILL.md`、`references/`、`scripts/` 直接置于 ZIP 根目录，彻底避免外层嵌套目录导致的市场解析失败（450019 错误）。

---

## English Summary

**Computer Optimizer** is a safe, transparent disk space recovery Agent Skill designed for Windows 10 and 11, conforming strictly to both **Tencent WorkBuddy specifications** and generic Agent Skill standards. It scans per-user cache categories that programs rebuild on demand, presents them as a single reviewable plan, and moves only explicitly approved files to the Recycle Bin.

### Category Overview

| Category | Roots (under current user profile) | Age Floor | Opt-in | Notes |
| --- | --- | --- | --- | --- |
| `temp` | `Temp` | 30 days | No | Temporary files under user LocalAppData |
| `crashdumps` | `CrashDumps` | 7 days | No | Application crash dumps |
| `thumbnails` | `Microsoft\Windows\Explorer` | 7 days | No | Explorer thumbnail and icon cache files |
| `wer` | `Microsoft\Windows\WER\ReportQueue`, `ReportArchive` | 7 days | No | Windows Error Reporting queue and archive |
| `dxshadercache` | NVIDIA / AMD / Intel Shader Caches | None | **Yes** | GPU shader caches; requires explicit opt-in and idle graphics processes |

---

## 目录结构 / Layout

```
SKILL.md                       Agent instructions (WorkBuddy & Agent Skill compliant frontmatter + bilingual SOP)
CHANGELOG.md                   Version history and release notes
docs/release-process.md        Standard release process, SemVer policy, and SOP
references/cleanup-policy.md   Risk levels, user-facing wording, strict exclusions, research basis
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
scripts/classes/*.psm1         One file per cleanup category (bilingual titles & impacts)
tests/smoke.ps1                Behaviour tests for the safety contract
tools/package-workbuddy.ps1    Build the WorkBuddy marketplace zip and SHA-256 hash
tools/release.ps1              Release assistant: version bump, validation, tag & release
.github/workflows/ci.yml       CI pipeline: smoke tests and package verification on Windows
.github/workflows/release.yml  Release pipeline: automated build and GitHub Release upon tag push
```

## 运行与测试 / Usage

```powershell
# 1. 环境与支持检查 (不修改任何文件)
pwsh -File scripts/check.ps1

# 2. 扫描常规低风险缓存并生成计划
pwsh -File scripts/scan.ps1 -Class temp,crashdumps,thumbnails,wer

# 3. 扫描包含显卡着色器缓存的计划 (需显式 OptIn)
pwsh -File scripts/scan.ps1 -Class dxshadercache -OptIn dxshadercache

# 4. 查看计划明细
pwsh -File scripts/show-plan.ps1 -PlanId <id>

# 5. 用户确认后执行清理 (仅移入回收站)
pwsh -File scripts/clean.ps1 -PlanId <id> -ApprovedPlanId <id> -Confirm:$false

# 6. 取消/废弃未执行的计划
pwsh -File scripts/discard.ps1 -PlanId <id>

# 7. 运行行为安全冒烟测试 (Windows)
pwsh -File tests/smoke.ps1
```

## 审批模型与安全保障 / Approval & Safety Model

- **密封计划清单**：扫描操作在 `%LOCALAPPDATA%\SystemOptimizer\plans` 下生成受 SHA-256 保护的 JSON 计划清单。
- **单次会话审批门禁**：执行时强制要求 `-ApprovedPlanId` 与被执行的计划完全匹配；任何会话层面的重新扫描或参数变动均需重新获得用户授权。
- **执行时严格重验**：执行器在移动每个文件前重新核验：当前用户 SID、计划校验和、计划时效、目录在用户 Profile 内且位于声明根下、全路径无任何重解析点/符号链接、文件大小和时间戳未发生任何变动且仍符合时间保留阈值。任何一项不符合均直接跳过。
- **绝不永久删除**：文件仅移入 Windows 回收站，绝不调用永久删除 API。
- **实测可用空间对比**：在执行前与执行后精确测量驱动器空闲字节数，向用户反馈真实变化。

## 打包与发布 / Packaging & Release

- **发版文档**：完整发版 SOP、SemVer 规范及热修复流程请参阅 [`docs/release-process.md`](docs/release-process.md)。
- **WorkBuddy 打包工具**：
  `tools/package-workbuddy.ps1` 会自动校验元数据，生成符合 WorkBuddy 开放平台规范的标准分发包 `build/computer-optimizer-<version>.zip` 及其 `.sha256` 校验和文件，解压后 `SKILL.md` 直接位于根目录。
- **自动化发版脚本**：
  ```powershell
  # 试运行补丁版本递增预览
  pwsh -File tools/release.ps1 -Bump patch -DryRun

  # 正式递增 minor 版本、更新 CHANGELOG 并创建 Git Tag
  pwsh -File tools/release.ps1 -Bump minor -Commit -Tag
  ```
- **CI / CD**：GitHub Actions (`.github/workflows/ci.yml`) 在每次提交和 PR 时自动运行安全冒烟测试与打包校验；推送版本标签 (`v*`) 时自动触发 (`.github/workflows/release.yml`) 构建分发包并发布 GitHub Release。
