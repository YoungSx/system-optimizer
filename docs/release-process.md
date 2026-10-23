# System Optimizer 发版流程指南

本文档定义了 **System Optimizer**（系统优化助手 Agent Skill）的标准发版规范、自动化发布流程与日常操作指南。

---

## 一、版本规范与发版原则

### 1. 语义化版本 (Semantic Versioning)
项目严格遵循 [SemVer 2.0.0](https://semver.org/lang/zh-CN/) 规范，格式为 `MAJOR.MINOR.PATCH`（例如 `0.2.0`）：
- **MAJOR（主版本号）**：包含重大架构调整、不兼容的清理协议/调用接口变更或破坏性安全调整。
- **MINOR（次版本号）**：新增清理类别（例如在 `scripts/classes/` 下新增支持项）、新增扫描规则、扩展计划与审批能力。
- **PATCH（补丁版本号）**：安全加固、Bug 修复、过滤条件完善、文档与文案调整。

### 2. 核心原则
1. **单一事实来源 (Single Source of Truth)**：`SKILL.md` 中的 `metadata.workbuddy.version` 为版本唯一来源，打包脚本会自动提取并注入到 WorkBuddy 规范格式中。
2. **安全先于发布**：发版前必须通过 `tests/smoke.ps1` 冒烟测试（Windows 环境下验证篡改拦截、权限拒绝、路径防穿越等安全机制）。
3. **标签与版本对齐**：Git Tag（如 `v0.2.0`）必须与 `SKILL.md` 中声明的 `version` 完全一致，GitHub Actions 会对此进行硬性校验。

---

## 二、发版架构与工具链

项目提供完整的全自动化与半自动化发版工具链：

| 模块 | 位置 | 说明 |
| --- | --- | --- |
| **版本管理与发版助手** | `tools/release.ps1` | 本地一键更新版本、校验测试、更新变更日志、打包并打 Tag |
| **WorkBuddy 打包脚本** | `tools/package-workbuddy.ps1` | 自动扁平化元数据、构建 `system-optimizer-<version>.zip` 及 SHA-256 校验和 |
| **CI 持续集成** | `.github/workflows/ci.yml` | 每次 PR/Push 到主分支时在 Windows 运行冒烟测试与打包校验 |
| **Release 自动发布** | `.github/workflows/release.yml` | 推送 `v*` Tag 或手动触发时自动测试、打包并发布 GitHub Release 产物 |
| **变更记录** | `CHANGELOG.md` | 记录每个版本的特性、修复与变更内容 |

---

## 三、标准发版操作流程 (SOP)

### 方式 A：使用 `tools/release.ps1`（推荐）

项目内置了 PowerShell 发版辅助脚本，支持自动递增版本、检查工作区、更新文件并执行打包校验。

#### 1. 试运行检查 (DryRun)
在执行正式变更前，推荐使用 `-DryRun` 预览变更：
```powershell
# 预览递增 patch 版本 (0.2.0 -> 0.2.1)
pwsh -File tools/release.ps1 -Bump patch -DryRun

# 预览递增 minor 版本 (0.2.0 -> 0.3.0)
pwsh -File tools/release.ps1 -Bump minor -DryRun

# 预览指定具体版本号
pwsh -File tools/release.ps1 -Version 0.3.0 -DryRun
```

#### 2. 一键发版与打标签
确认无误后，执行发版并自动创建 Git 提交与 Tag：
```powershell
# 本地执行测试、更新版本号、打 Git Tag
pwsh -File tools/release.ps1 -Bump patch -Commit -Tag
```
> **提示**：若在非 Windows 开发机（如 Linux/macOS）上准备发版，脚本会自动提示跳过 Windows 专有的系统测试，完整的安全测试将由 GitHub Actions CI 保证。也可显式传入 `-SkipTests`。

#### 3. 推送至远程仓库
将提交和 Tag 推送到远程分支，触发 GitHub 自动化流水线：
```bash
git push origin HEAD && git push origin --tags
```
*(如果需要一步到位推送到远程，也可以在 `release.ps1` 中追加 `-Push` 参数)*。

---

### 方式 B：手动发版流程

如果你希望全手动控制每个发版细节，请按以下步骤操作：

#### 步骤 1：发版前检查
确保当前分支干净且为最新：
```bash
git checkout master
git pull origin master
git status
```

#### 步骤 2：更新版本号与变更日志
1. 打开 `SKILL.md`，修改 `metadata.workbuddy.version`，例如：
   ```yaml
   metadata:
     workbuddy:
       version: 0.2.1
   ```
2. 打开 `CHANGELOG.md`，将 `## [Unreleased]` 下的内容归档至新版本小节：
   ```markdown
   ## [Unreleased]

   ## [0.2.1] - 2026-10-24
   ### Fixed
   - ...
   ```

#### 步骤 3：验证打包与测试
运行冒烟测试与打包验证：
```powershell
pwsh -File tests/smoke.ps1
pwsh -File tools/package-workbuddy.ps1
```
检查生成的 `build/system-optimizer-0.2.1.zip` 及其 `.sha256` 校验文件。

#### 步骤 4：提交与打标签
```bash
git add SKILL.md CHANGELOG.md
git commit -m "Release v0.2.1"
git tag -a v0.2.1 -m "System Optimizer v0.2.1"
git push origin master
git push origin v0.2.1
```

---

## 四、自动化发布与交付 (GitHub Actions)

推送标签 `v*` 后，GitHub Actions 中的 `.github/workflows/release.yml` 流水线将自动执行以下任务：

1. **版本一致性防呆校验**：提取标签版本与 `SKILL.md` 中的版本对比，防止手误打错 Tag。
2. **Windows 环境安全冒烟测试**：在 `windows-latest` 纯净环境执行 `tests/smoke.ps1`，确保安全契约无破坏。
3. **打包 WorkBuddy 交付物**：执行 `tools/package-workbuddy.ps1` 生成标准 Zip 和 SHA-256 摘要。
4. **提取变更日志**：从 `CHANGELOG.md` 自动提取当前版本的改动说明作为 Release 描述。
5. **发布 GitHub Release**：创建正式 Release，并将如下制品作为附件上传：
   - `system-optimizer-<version>.zip`
   - `system-optimizer-<version>.zip.sha256`

---

## 五、WorkBuddy 市场上传与交付

GitHub Release 生成后，即可交付至 WorkBuddy 市场或用户端：

1. **获取发布包**：
   从 GitHub Releases 页面下载 `system-optimizer-<version>.zip`。
2. **校验哈希**（可选但推荐）：
   ```powershell
   Get-FileHash -Algorithm SHA256 .\system-optimizer-<version>.zip
   ```
   比对哈希值与 `.sha256` 文件一致。
3. **上传平台**：
   - 登录 WorkBuddy 开放平台/技能管理后台。
   - 上传该 Zip 包。平台将识别根目录下的 `SKILL.md` 并解析展示名称、中文/英文描述、分类与版本号。
   - 提交审核或直接上线。

---

## 六、异常处理与回滚指南

### 1. 发现未发布的 Tag 打错或测试未通过
若尚未推送远程：
```bash
git tag -d v0.2.1
```
若已推送到远程但尚未正式公布：
```bash
git push --delete origin v0.2.1
git tag -d v0.2.1
```
在 GitHub Releases 页面中删除对应的草稿或未生效 Release。

### 2. 已上线版本发现严重问题 (Hotfix)
**严禁复用或覆盖已发布的版本号与 Tag！**
1. 立即从 `master` 创建修复分支：
   ```bash
   git checkout -b hotfix/fix-path-traversal
   ```
2. 修复缺陷并添加针对性测试用例。
3. 递增补丁版本（如 `0.2.1` -> `0.2.2`）：
   ```powershell
   pwsh -File tools/release.ps1 -Bump patch -Commit -Tag -Push
   ```
4. 等待 GitHub Actions 生成 `v0.2.2` 发布包，并在市场发布更新。
