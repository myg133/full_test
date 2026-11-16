# Full Test

> 本仓库是 **`test-agent-skills` npm 包**（测试 Agent Skill 套件）的源码与开发过程记录。
> **交付包在 `develop` 分支**；`demand` 分支是需求契约与验收门（**过程文件**，不进 npm 包）。

本仓库采用 **Agent Workspace 工作流**（工作流规范由独立的 `agent-workspace` skill 提供，
安装后在 `~/.agents/skills/agent-workspace/` —— **它不在本仓内**），
使用 `workspace` 分支作为根容器，**所有 worktree 在仓库根平铺**（无中间目录层）。

## 仓库内容（按分支）

| 分支 | 内容 | 说明 |
|---|---|---|
| `develop` | `skills/` `bin/` `README.md` `LICENSE` `package.json` `feature-meta/` | **交付面**：npm 包 `test-agent-skills` 的源码（8 个 skill）+ 追溯件。`npm pack` 129 个文件条目 |
| `demand` | `demands/` `dispatch/` `decisions/` `plan/` `sprint/` `backlog/` | **过程文件**：需求契约（`demand.md` / `acceptance.md` / `decisions.md`）、验收门（`verify-acceptance.sh`）、登记表、勘察记录。**不进 npm 包** |
| `deploy` | `apps/` `argocd/` `environments/` `releases/` `scripts/` | 部署配置骨架（当前为空壳） |
| `workspace` | 仅 `README.md` + `.gitignore` | 根容器，白名单防御 |
| `main` | `README.md` | 占位分支 |

## ⚠️ 公开仓库说明（2026-11-16）

本仓要推到**公开** GitHub，故做过一次**字面量与绝对路径清理**：

- **清理范围**：内部运行时名 + 本机绝对路径（**两类**）。**无任何凭据类内容泄露** ——
  私钥 / 证书 / 云厂商与平台 token / `.env` / `.npmrc` / `id_rsa` 等敏感文件**全部 0 命中**。
- **交付面零改动**：`skills/` 下 **123 个文件逐字未变**（sha256 全等）⇒ npm 包内容与已验收版本完全一致。
- **历史被改写**：清理用 `git filter-repo` 重写了 278 个提交 ⇒ **所有 commit hash 都变了**。
  这是**有意的规范化**，不是「历史原貌」；详见
  `demand` 分支的 `BA/demands/REQ-002-suite-foundation/PUBLIC-REPO-CLEANUP.md`（含替换规则表、
  **验收门 sha 三段式对照表**、诚实声明）。
- **验收门是语义敏感的**：门里的禁用词表与变异体载荷改用**构造式**表达
  （运行时值与原字面量逐字相同 ⇒ **判定语义不变**，已实证）。

## ⚠️ 已知：REQ-012 验收门对当前 `develop` 判红（**不是交付缺陷**）

`demand` 分支的 REQ-012 验收门对当前 `develop` 判 **27 PASS / 2 FAIL**（`AC-002` + `AC-027` ⑤⑥）。

**根因是跨 REQ 的契约冲突，与公开仓库清理无关**（对**清理前**的 `develop` 跑**原始**门，同样 27/2）：

1. `AC-002`：REQ-012 契约的基线表钉死「REQ-009 既有 14 文件逐字未改」，而 **REQ-013 契约明确授权**
   「`SKILL.md` 追加 B 阶段一节」⇒ 该文件 sha 变化 ⇒ 判红（14 个基线文件里只变这 1 个）。
2. `AC-027` ⑤⑥：REQ-012 门要求 `feature-meta/load-runner/` 的判据编号集合 **== REQ-012 的 29 条**、
   「判据条数」取值唯一；而 REQ-013 的记账（41 条判据 / D185~D210）在**同一目录** ⇒ 冲突。
   而 REQ-013 门 `AC-037` 又**要求**该目录含 REQ-013 条目 ⇒ **两门不可同时绿**。

⚠️ 之所以一直没被发现：当时的「上游八门回归」清单里**不含 REQ-012 门** ⇒ 合并后从未复跑过。

**状态**：已如实登记在 `demand` 分支 `dispatch/req-registry.md` 的遗留项表，
**含三条候选修法待需求方拍板**（修复需改契约 + 改门 + 重跑门，属独立 REQ）。

## 目录 ↔ 分支对应表

| 路径 | 分支 | 角色 | 说明 |
|------|------|------|------|
| `./` | `workspace` | **根容器** | **只跟踪 README.md + .gitignore**（白名单防御） |
| `code/` | `develop` | CI 主工作区 | 主开发分支，CI 构建源；`.gitignore` 由 develop 跟踪 |
| `BA/` | `demand` | BA Agent | 需求管理、迭代计划、Agent 注册；`.gitignore` 由 demand 跟踪 |
| `Deploy/` | `deploy` | Deploy Agent | helm/k8s/部署配置，不做构建；`.gitignore` 由 deploy 跟踪 |
| `feature-REQ-xxx/` | `feature/REQ-xxx` | Dev Agent | 需求开发，按需创建，合并后清理 |
| `hotfix-xxx/` | `hotfix/xxx` | Dev Agent | 紧急修复，按需创建 |

**所有 worktree 跟 `README.md` 同级**，在仓库根平铺，没有中间目录层（如 `workspaces/`）。

**关于 `.gitignore`**：
- 仓库根 `.gitignore` 使用**双层防御机制**：
  - **白名单层**：`!README.md` + `!.gitignore` + `*` + `!*/`
  - **`/*/` 屏蔽层**：忽略所有第一层子目录（worktree 都在第一层）
- 即使误操作 `git add .` 也不会污染 workspace 分支，worktree 完全不被影响
- 其他 worktree 各自的 `.gitignore`（如 `code/.gitignore`）由对应工作分支管理，workspace 一概不管

## 快速上手

### 1. 克隆仓库

```bash
git clone https://github.com/myg133/full_test.git my-project
# （或 SSH：git clone git@github.com:myg133/full_test.git my-project）
cd my-project
# 默认在 workspace/ 主 worktree，看到这份 README
```

> clone 下来只有 `workspace` 分支的 README 与 .gitignore ⇒ 其它分支的内容要另拉：
> `git fetch origin && git checkout develop`（或按下面的「快速上手」建 worktree）。

### 2. 注册主 worktree（如已部署过可跳过）

```bash
git worktree add code develop
git worktree add BA demand
git worktree add Deploy deploy
```

### 3. 接到需求后

在仓库根跑：

```bash
git worktree add feature-REQ-001 -b feature/REQ-001 develop
```

或在 `BA/` 里跑（用 `../` 回到仓库根，再平铺）：

```bash
cd BA
git worktree add ../feature-REQ-001 -b feature/REQ-001 develop
```

新 worktree 跟 `code/` `BA/` 在仓库根平铺，**没有中间目录层**。

### 4. 提交 PR

在 `feature-REQ-xxx/` 里编码、测试、提交：

```bash
git commit -m "[Dev] {描述} (关联: REQ-xxx)"
git push -u origin feature/REQ-xxx
# 在 GitHub/GitLab 创建 PR → develop
```

PR 合并后 Dev Agent 自动清理 worktree（详见 `~/.agents/skills/agent-workspace/references/lifecycle/cleanup.md`）。

## 各角色 Agent 入口

- **BA Agent**（主 agent）→ 进入 `BA/` 目录
- **Dev Agent**（子 agent）→ 进入 `feature-REQ-xxx/` 目录
- **QA Agent**（子 agent）→ Pre-merge 进 `feature-REQ-xxx/`，Post-merge 进 `code/` + staging
- **Deploy Agent**（子 agent）→ 进入 `Deploy/` 目录
- **Explore Agent**（子 agent，只读）→ 任意目录

新 agent 启动时先读 `~/.agents/skills/agent-workspace/SKILL.md`（索引），再读 `~/.agents/skills/agent-workspace/references/roles/<角色>.md`。

## 硬规则

- ❌ `workspace` 分支**只跟踪 `README.md` + `.gitignore`**（`git ls-files` 必须只有这两个）
- ✅ `.gitignore` 使用**双层防御**：白名单层 + `/*/` 屏蔽所有第一层子目录
- ❌ 不向 `workspace` 分支提交 PR
- ❌ 不在仓库根加中间目录层（禁止 `workspaces/` `agents/` 等中间层放 worktree）
- ❌ 不做 worktree 二级嵌套（禁止 `feature-xxx/code/`）
- ✅ 各 worktree 自己的 `.gitignore` 由对应 agent 在对应工作分支维护（workspace 不管）
- ✅ BA Agent 每次启动时执行 workspace 巡检

## 详细文档

> ⚠️ 以下文档属于 **`agent-workspace` skill**（**独立于本仓**，安装后位于 `~/.agents/skills/agent-workspace/`），
> **不在本仓任何分支里** ⇒ clone 本仓后这些路径**不存在**，请先安装该 skill。

- 工作流规范：`~/.agents/skills/agent-workspace/SKILL.md`
- 全局约定：`~/.agents/skills/agent-workspace/references/global/`
- 角色工作流：`~/.agents/skills/agent-workspace/references/roles/`
- 初始化：`~/.agents/skills/agent-workspace/references/init/`
- 生命周期与发布：`~/.agents/skills/agent-workspace/references/lifecycle/`
- 模板：`~/.agents/skills/agent-workspace/assets/templates/`
- 自检工具：`python ~/.agents/skills/agent-workspace/scripts/aw.py verify`

### 本仓内的文档

| 位置 | 内容 |
|---|---|
| `BA/demands/REQ-002-suite-foundation/architecture-design.md` | 套件整体架构（能力域 §8 映射） |
| `BA/demands/REQ-002-suite-foundation/PUBLIC-REPO-CLEANUP.md` | **公开仓库字面量清理说明**（替换规则 / 门 sha 对照表 / 诚实声明） |
| `BA/dispatch/req-registry.md` | 需求登记表 + **遗留项表** |
| `BA/demands/<REQ>/` | 各需求的 `demand.md` / `acceptance.md`（判据）/ `decisions.md` / `status.md` / `verify-acceptance.sh` |
| `code/feature-meta/` | 各能力的追溯件四件套（`status.md` / `traceability.md` / `verification-report.md` / `manifest.json`） |

## 平台运行目录

如果你在云开发平台（Claude.ai Projects、Cursor Cloud、Codespaces 等）使用本仓库：

- 平台的"运行目录"通常绑定到仓库根（`my-project/` = `workspace/` 主 worktree）
- 所有 worktree 都在仓库根平铺，**没有中间目录层、没有 worktree 嵌套**
- 平台无关：git worktree add 用相对路径 `xxx` 即可
- 不需要任何特殊适配