# Computer Optimizer 发版流程指南

本文档定义了 **Computer Optimizer**（系统优化助手 Agent Skill）的标准发版规范、自动化发布流程与日常操作指南。

---

## 一、版本规范与发版原则

### 1. 语义化版本 (Semantic Versioning)
项目严格遵循 [SemVer 2.0.0](https://semver.org/lang/zh-CN/) 规范，格式为 `MAJOR.MINOR.PATCH`（例如 `0.2.1`）：
- **MAJOR（主版本号）**：包含重大架构调整、不兼容的清理协议/调用接口变更或破坏性安全调整。
- **MINOR（次版本号）**：新增清理类别（例如在 `scripts/classes/` 下新增支持项）、新增扫描规则、扩展计划与审批能力。
- **PATCH（补丁版本号）**：安全加固、Bug 修复、过滤条件完善、文档与文案调整。

### 2. 核心原则
1. **单一事实来源 (Single Source of Truth)**：`SKILL.md` 顶层 YAML frontmatter 中的 `version` 字段为版本唯一来源，打包脚本与 CI/CD 自动化流水线均直接从此提取。
2. **安全先于发布**：发版前必须通过 `tests/smoke.ps1` 冒烟测试（Windows 环境下验证篡改拦截、权限拒绝、路径防穿越等安全机制）。
3. **标签与版本对齐**：Git Tag（如 `v0.2.1`）必须与 `SKILL.md` 中声明的 `version` 完全一致，GitHub Actions 会对此进行硬性校验。
4. **WorkBuddy 规范对齐**：技能包遵循腾讯 WorkBuddy 官方标准，ZIP 根目录下直接存放 `SKILL.md`、`references/` 和 `scripts/`，提供完整的中英文双语与标准元数据。

---

## 二、发版架构与工具链

项目提供完整的全自动化与半自动化发版工具链：

| 模块 | 位置 | 说明 |
| --- | --- | --- |
| **版本管理与发版助手** | `tools/release.ps1` | 本地一键更新版本、校验测试、更新变更日志、打包并打 Tag |
| **WorkBuddy 打包脚本** | `tools/package-workbuddy.ps1` | 校验元数据规范、构建符合 WorkBuddy 根目录要求的 `computer-optimizer-<version>.zip` 及 SHA-256 校验和 |
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
# 预览递增 patch 版本 (0.2.1 -> 0.2.2)
pwsh -File tools/release.ps1 -Bump patch -DryRun

# 预览递增 minor 版本 (0.2.1 -> 0.3.0)
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

#### 3. 推送至远程仓库
```bash
git push origin master
git push origin --tags
```

---

### 方式 B：手动发版流程

若需手动精细化控制各发版环节，请遵循以下步骤：

#### 步骤 1：更新 `CHANGELOG.md`
在 `CHANGELOG.md` 中将 `[Unreleased]` 下的条目归档至新版本标题下，格式如下：
```markdown
## [0.2.1] - 2026-10-30

### Added
- 新增特性说明...

### Changed
- 变更说明...

### Fixed
- 修复说明...
```

#### 步骤 2：更新 `SKILL.md` 元数据
修改 `SKILL.md` 中的 `version` 字段：
```yaml
version: 0.2.1
```

#### 步骤 3：本地验证与打包
运行冒烟测试与打包验证：
```powershell
pwsh -File tests/smoke.ps1
pwsh -File tools/package-workbuddy.ps1
```
检查生成的 `build/computer-optimizer-0.2.1.zip` 及其 `.sha256` 校验文件，确保解压后 `SKILL.md` 直接位于根目录下。

#### 步骤 4：提交与打标签
```bash
git add SKILL.md CHANGELOG.md
git commit -m "Release v0.2.1"
git tag -a v0.2.1 -m "Computer Optimizer v0.2.1"
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
   - `computer-optimizer-<version>.zip`
   - `computer-optimizer-<version>.zip.sha256`

---

## 五、WorkBuddy 市场上传与交付

GitHub Release 生成后，即可交付至 WorkBuddy 市场或用户端：

1. **获取发布包**：
   从 GitHub Releases 页面下载 `computer-optimizer-<version>.zip`。
2. **校验哈希**（可选但推荐）：
   ```powershell
   Get-FileHash computer-optimizer-0.2.1.zip -Algorithm SHA256
   ```
   对比 `.sha256` 文件内容确认无损。
3. **上传至 WorkBuddy 开放平台**：
   在 WorkBuddy 开放平台进入技能管理后台，选择“上传技能包”，直接上传 `computer-optimizer-<version>.zip`。由于该包严格满足 `SKILL.md` 直接位于 ZIP 根目录且包含标准中英文双语 Frontmatter，平台将自动解析技能并进入快速发布/测试流程。

---

## 六、热修复流程 (Hotfix)

若已发布的生产版本发现紧急 Bug 或安全缺陷：

1. 从对应的 Release Tag 检出修复分支：
   ```bash
   git checkout -b hotfix/0.2.2 v0.2.1
   ```
2. 修复问题并编写对应的回归测试（在 `tests/smoke.ps1` 中添加用例）。
3. 运行发版助手升级 Patch 版本：
   ```powershell
   pwsh -File tools/release.ps1 -Bump patch -Commit -Tag
   ```
4. 合并 hotfix 分支回 `master` 并推送：
   ```bash
   git checkout master
   git merge hotfix/0.2.2
   git push origin master
   git push origin v0.2.2
   ```
