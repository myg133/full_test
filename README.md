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

### Skill 之间的版本配套

每个 skill 根级有一份 `skill-meta.json`，声明自己的版本与对别的 skill 的依赖：

```json
{ "name": "test-execute", "version": "0.1.0", "requires": { "test-case-design": ">=0.1.0" } }
```

`test-execute` 对 `test-case-design` 是**硬跨 skill 依赖**（轮次推进走的是
`test-case-design/scripts/cycle-state.mjs`），`regression-plan` 消费它的维度库与方法库。

### 组合门（`verify`）

```bash
node bin/test-agent-skills.mjs verify --root /tmp/verify-root
```

把包装到**临时根**（不碰真实安装根），校验 skill 之间的**版本配套**，
再**实跑**跨 skill 组合场景：`test-execute` 的 offline 夹具（4 passed / 1 failed / 1 blocked / 0 skipped）
与「轮次初始化 → 带轮次执行 → execute 阶段推进」这条硬跨 skill 依赖链路。

依赖版本不满足时，组合门报**版本问题**（点名哪个 skill、要求什么、实际什么），
而不是让下游报业务错。

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
