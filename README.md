# test-agent-skills

> Full Test —— 测试 Agent Skill 套件（首期能力域：**需求 → 测试用例设计 → 执行与证据链**）

把测试能力以 **Agent Skill** 的形式安装到用户级 skill 目录 `~/.agents/skills/`，
让 Agent 在任何项目里都能按统一的测试方法论工作。

本包只做两件事：**携带 skill** + **提供安装器 CLI**。skill 本体位于 `skills/<name>/`。

---

## 安装

```bash
npm install -g test-agent-skills
test-agent-skills install
```

或安装到某个项目内：

```bash
npm install test-agent-skills
npx test-agent-skills install
```

安装后：

```
~/.agents/skills/
├── test-case-design/      # 本包安装的 skill
├── test-execute/          # 本包安装的 skill
├── qa-toolchain/          # 本包安装的 skill
├── regression-plan/       # 本包安装的 skill
├── test-report/           # 本包安装的 skill
├── defect-verify/         # 本包安装的 skill
├── security-plan/         # 本包安装的 skill
├── load-profile/          # 本包安装的 skill
└── <你原有的其它 skill>     # 不受影响
```

---

## CLI

```
test-agent-skills <command> [options]
```

| 命令 | 说明 |
|------|------|
| `install` | 把本包 `skills/` 下的各 skill 复制到 `<安装根>/skills/<name>/`，**幂等** |
| `uninstall` | 移除**本包安装的** skill 目录与锁条目，不碰你的其它 skill |
| `list` | 列出本包管理的 skill 及其安装状态 |
| `verify` | 组合校验：把包装到**临时根**、校验 skill 之间的版本配套、**实跑**跨 skill 组合场景 |

| 选项 | 说明 |
|------|------|
| `--root <dir>` | 指定安装根目录，优先级高于 `TEST_AGENT_SKILLS_DIR` |
| `-h, --help` | 帮助 |
| `-v, --version` | 版本号 |

### 安装根目录解析

优先级从高到低：

1. 命令行 `--root <dir>`
2. 环境变量 `TEST_AGENT_SKILLS_DIR`
3. 默认 `~/.agents`

> ⚠️ `TEST_AGENT_SKILLS_DIR` 覆盖的是 **`~/.agents` 这一层**，不是 `~/.agents/skills` 这一层。
>
> ```bash
> TEST_AGENT_SKILLS_DIR=/tmp/sandbox test-agent-skills install
> # → skill 落在 /tmp/sandbox/skills/<name>/
> # → 锁文件落在 /tmp/sandbox/.skill-lock.json
> ```
>
> 该变量主要用于**测试隔离**，避免污染真实的 `~/.agents/skills/`（那是一个 git 仓库）。

### 锁文件协同

安装根目录下的 `.skill-lock.json` 是 skill 清单，格式 `version: 3`：

```json
{
  "version": 3,
  "skills": {
    "test-case-design": {
      "source": "test-agent-skills@0.1.0",
      "sourceType": "npm",
      "sourceUrl": "https://registry.npmjs.org/test-agent-skills/-/test-agent-skills-0.1.0.tgz",
      "skillPath": "SKILL.md",
      "skillFolderHash": "",
      "installedAt": "2026-11-09T08:00:00.000Z",
      "updatedAt": "2026-11-09T08:00:00.000Z"
    }
  },
  "dismissed": {}
}
```

安装器**只增改本包自己的条目**，其它 skill 的既有条目原样保留。

---

## 行为保证

- ✅ **幂等**：重复 `install` 不产生重复目录、不报错；锁文件里同名条目只有一条，重复安装只更新 `updatedAt`。
- ✅ **无副作用**：不改 `~/.bashrc` / `~/.zshrc` / `~/.profile`，不改 PATH，不执行被安装 skill 的任何脚本。
- ✅ **不自动提交**：安装根目录本身可能是 git 仓库，安装产生的变更以**工作区文件变更**形式体现，不自动 `commit` / `push`。
- ✅ **最小侵入**：`uninstall` 只删除本包安装的目录与锁条目。
- ✅ **零第三方依赖**：仅使用 Node.js 内置模块，`engines.node >= 18`。

---

## 包含的 Skill

| Skill | 能力 |
|-------|------|
| `test-case-design` | 需求 → 测试用例设计：拆解需求条目、判定可测试性、套用测试设计方法、按固定 schema 输出用例集与追溯矩阵 |
| `test-execute` | 用例集 → 执行与证据链：读执行配置与用例集、调度可插拔执行器、按断言逐步判定、产出带 sha256 指纹与脱敏留痕的证据链（入口命令：`node skills/test-execute/scripts/run-suite.mjs <suite.json>`） |
| `qa-toolchain` | 项目级 `.tools/` 工具链自举：声明式清单、隔离安装（Python venv / Node 包）、幂等重装、显式降级（入口命令：`qa install` / `qa doctor` / `qa list`） |
| `regression-plan` | 变更 → 回归选样：切分变更条目、按需求条目 / 用例 / 维度 / 方法判影响面、产出 `regression-plan.json`（哪些用例确定重跑、哪些需人工复核、哪些变更判不了）（入口命令：`node skills/regression-plan/scripts/plan-regression.mjs --changelog <file> --cases <file> --cycle-dir <dir>`） |
| `test-report` | 执行产物 → 执行报告：只读消费 `meta.json` / `results.json` / `evidence/` 与可选的回归计划，产出 `report.json` + `report.md`，给出用例层 / 证据层 / 计划对账层三层结论、逐条点名漏跑的用例与判不了的变更，并绑定输入产物的指纹（入口命令：`node skills/test-report/scripts/make-report.mjs --artifacts <run_dir>`） |
| `defect-verify` | 缺陷单 → 缺陷复现用例集：读缺陷单与已有用例集，给每条缺陷**有且只有一个**处置结论（`reused` 复用已有用例 / `derived` 派生 1 条新用例 / `unresolved` 显式说不知道并给理由），产出可被 `test-execute` 直接消费的 `defect-cases.json`，复现用例带 `defect-verify` 与缺陷 id 的 tag（便于按缺陷分批跑）（入口命令：`node skills/defect-verify/scripts/make-defect-cases.mjs --defects <file> --cases <file> --suite <suite> --cycle-dir <dir>`） |
| `security-plan` | 安全上下文 → 安全测试**规划**：读安全上下文（资产 / 信任边界 / 入口点 / 角色 / 资源）+ 可选的依赖扫描结果，派生**威胁模型**（STRIDE + OWASP 十类逐类有交代 + 四类实战补充逐类显式判定）、**权限矩阵**（角色 × 资源 × 动作，越权缺口与越权威胁双向对应）、**安全用例集**与套件配置，产出 `threat-model.json` / `matrix.json` / `suites/SEC-<编号>-<短名>/{cases.json,suite.json}`；只做规划，**不执行**安全用例（`security` 执行器未实现，属后续 REQ）（入口命令：`node skills/security-plan/scripts/make-security-plan.mjs --context <file> [--cases <file>] [--scan <file>] --out-dir <项目根>`） |
| `load-profile` | 压测上下文 → 压测**规划**：读压测上下文（容量目标 / 负载画像 / 阈值及其来源）+ 可选的功能用例集，派生**负载模型本体**（每个容量目标一个）、**压测套件**（按环境分组：同一环境的多条容量目标进同一个套件）与**压测计划清单**，产出 `scenarios/<场景>.json` / `suites/LOAD-<编号>-<短名>/{scenario.json,suite.json}` / `report.json`；只做规划，**不发压**（`load` 执行器未实现，属后续 REQ），没有指标来源就**不写阈值**并留未决问题（入口命令：`node skills/load-profile/scripts/make-load-profile.mjs --context <file> [--cases <file>] --out-dir <项目根>`） |

### `load-profile` 的 runner 适配入口

`load-profile` 分两段交付：**负载模型**（`make-load-profile.mjs`）与
**runner 适配**（把负载模型编译成真实压测工具可消费的命令清单）。适配段**一个请求都不发**：

```bash
# 负载模型 + 套件 + 环境 ⇒ 压测计划（只写 <out-dir>/test-assets/load/plans/）
node skills/load-profile/scripts/plan-load-run.mjs --load-dir <项目根> --out-dir <项目根>

# 复核已产出的计划与负载模型是否自洽（篡改过的计划会判红）
node skills/load-profile/scripts/check-load-run.mjs <项目根>
```

- 计划里每个负载画像段一条**完整可跑的 argv**（多段**不合并**、`--cores 1` 恒定钉死、
  `timeout_s` 秒 → `-d` 毫秒）；
- `args` 的**未知键一律拒绝**（rc=1 + 点名该键），`python` runner **必须**由 `args.command`
  自陈完整命令（**不编造**默认命令）；
- 计划里**不含**任何压测结论（`status` / `result` / `verdict` / `executed` / `passed` /
  `outcome` / `conclusion`）—— 本阶段只产出「该敲什么命令」，**不产出**「压出来是什么」；
- 适配契约详见 `skills/load-profile/references/runner-adapters.md`。

### Skill 之间的版本配套

每个 skill 根级有一份 `skill-meta.json`，声明自己的版本与对别的 skill 的依赖：

```json
{ "name": "test-execute", "version": "0.1.0", "requires": { "test-case-design": ">=0.1.0" } }
```

`test-execute` 对 `test-case-design` 是**硬跨 skill 依赖**（轮次推进走的是
`test-case-design/scripts/cycle-state.mjs`），`regression-plan` 消费它的维度库与方法库，
`test-report` 消费 `test-execute` 的执行产物格式（`meta.json` / `results.json` / `evidence/` 与指纹口径），
`defect-verify` 消费 `test-case-design` 的用例集格式、产出的复现用例由 `test-execute` 消费，
`security-plan` 消费 `test-case-design` 的方法库与维度库（方法号 / 维度 id 的唯一来源）、
并由 `qa-toolchain` 跑扫描器后把结果喂进 `--scan`，
`load-profile` 消费 `test-case-design` 的目录契约与用例集格式（链路存在性对账），
并与 `qa-toolchain` 的工具链声明配套（`loadtest` 由工具链管，本 skill 只声明不安装）。

### 组合门（`verify`）

```bash
node bin/test-agent-skills.mjs verify --root /tmp/verify-root
```

把包装到**临时根**（不碰真实安装根），校验 skill 之间的**版本配套**，
再**实跑**跨 skill 组合场景：`test-execute` 的 offline 夹具（4 passed / 1 failed / 1 blocked / 0 skipped）、
「轮次初始化 → 带轮次执行 → execute 阶段推进」这条硬跨 skill 依赖链路、
「执行产物 → `test-report` 出报告 → 断言三层结论」这条**经过第 5 个 skill** 的链路，
「缺陷单 + 已有用例集 → `defect-verify` 出复现用例集 → 断言处置结论自洽」
这条**经过第 6 个 skill** 的链路，
以及「安全上下文 + 功能用例集 + 依赖扫描结果 → `security-plan` 出安全测试计划 →
断言威胁模型 / 权限矩阵 / 安全用例集逐项自洽、且产物能被上游加载层消费」
这条**经过第 7 个 skill** 的链路，
和「压测上下文 + 功能用例集 → `load-profile` 出负载模型与压测套件 →
断言负载画像逐字可追溯、无指标来源就不写阈值、套件按环境分组、引用不漂移、
且产物能被上游加载层消费」这条**经过第 8 个 skill** 的链路。

依赖版本不满足时，组合门报**版本问题**（点名哪个 skill、要求什么、实际什么），
而不是让下游报业务错。

- 不传 `--root` 时用**默认临时根**，跑完（含失败）自动清理；
- 传 `--root <dir>` 时该目录是**调用方自己的持久根**，组合门只往里写、不清理它 ——
  同一个 `--root` 可以反复跑，每次结果都相同。
- `verify` **故意不读** `TEST_AGENT_SKILLS_DIR`：它的契约是「装到临时根、不碰真实安装根」，
  任何指向真实安装根的环境变量都不参与；要校验某个已装副本，用 `verify --root <该副本目录>`。

---

## 开发

```bash
# 查看打包内容清单
npm pack --dry-run

# 在隔离目录验证安装行为
TEST_AGENT_SKILLS_DIR=/tmp/sandbox node bin/test-agent-skills.mjs install
TEST_AGENT_SKILLS_DIR=/tmp/sandbox node bin/test-agent-skills.mjs list
TEST_AGENT_SKILLS_DIR=/tmp/sandbox node bin/test-agent-skills.mjs uninstall
```

## 发布

本仓库**不代你执行发布**。发布到公共 registry 需要你自己的 npm 登录态：

```bash
npm login          # 由用户自行执行
npm publish        # 由用户自行执行
```

---

## License

[MIT](./LICENSE)
