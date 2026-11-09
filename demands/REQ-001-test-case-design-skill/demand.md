# 需求：测试用例设计 Skill（首期）+ npm 交付包

- **需求编号**: REQ-001
- **优先级**: P0
- **状态**: 已就绪

## 需求描述

### 背景与动机

本项目（Full Test）的终局目标是构建一套**完整的测试 Agent Skill 套件**，用于替代独立测试人员。

独立测试人员的日常职责可拆为若干能力域：

| 能力域 | 首期是否覆盖 |
|--------|------------|
| 需求 → 测试用例设计 | ✅ **本 REQ** |
| 接口测试执行 | ❌ 后续 REQ |
| UI 端到端测试执行 | ❌ 后续 REQ |
| 缺陷报告与质量报告 | ❌ 后续 REQ |

首期选择「需求 → 测试用例设计」作为切入口，原因是它是整条测试链路的**上游**：用例设计质量决定了后续所有执行类测试的覆盖率上限，且它是纯文档/分析工作，对运行环境无依赖，能最快跑通"Agent 替代人工"的完整闭环。

被测对象类型暂不限定，做通用框架——这决定了 skill 不能假设被测系统是 REST API、Web UI 还是 CLI。

### 目标

交付一个可被 Agent 直接加载的 skill，使 Agent 能：

1. 解析需求文本，提取**可测试点**并建立需求条目 → 验收点映射；
2. 应用系统化测试设计方法（等价类、边界值、判定表、状态迁移、正交）生成用例，而非凭直觉罗列；
3. 按固定 schema 输出结构化用例集，可被机器消费；
4. 产出**追溯矩阵**，证明每个需求条目都被用例覆盖。

### 交付形态

以 **npm 包**交付，安装到用户级 skill 目录 `~/.agents/skills/`。

采用 npm 交付而非仓库内目录的原因：

- 用户级安装意味着 skill 对所有项目生效，符合"通用框架"定位；
- npm 携带版本与更新通道，用户一条命令即可升级；
- npm 包可携带 CLI 与脚本依赖，解决"skill 装到别处后找不到 node_modules"的问题。

### 范围边界

**在范围内**：
- skill 本体（SKILL.md + references/ + scripts/）
- npm 包（package.json + CLI + 安装器 + 锁文件协同）
- 校验与渲染脚本
- lint 通过 + 与 baseline 的对比评估

**不在范围内**：
- 接口/UI 测试执行 skill（后续 REQ）
- 缺陷单与测试报告生成 skill（后续 REQ）
- npm 包公开发布到 registry（需用户 `npm login`，由用户自行执行）
- 被测系统的接入、CI 流水线改造

## 功能要求

### F1 skill：test-case-design

单个 skill 目录 `test-case-design/`，结构：

```
test-case-design/
├── SKILL.md
├── references/
│   ├── design-methods.md      # 测试设计方法论详解
│   ├── case-schema.md         # 用例 JSON schema 与字段语义
│   └── coverage-dimensions.md # 覆盖维度清单
└── scripts/
    ├── validate-cases.mjs     # 用例集校验（确定性）
    └── render-report.mjs      # 渲染 Markdown 用例表 + 追溯矩阵
```

**SKILL.md** 必须声明：
- frontmatter：`name: test-case-design`（与目录同名、kebab-case）、`description` 含 What + When + Near misses + 明确触发语气；
- 正文：Inputs to collect → Procedure → Output contract → Failure handling → Examples，正文 ≤ 500 行；
- **不写** README 式背景介绍、功能导览、重复的触发条件列表。

**Procedure** 必须覆盖以下步骤，且每步说明"为什么这么做"：

1. 收集需求输入（用户粘贴 / 文件路径 / 需求文档），信息不足时先问而不是假设；
2. 拆分需求为原子条目 `R-1, R-2, ...`，每条记录原文摘录与来源位置；
3. 判定每条是否为可测试点，非可测试项（如背景叙述）单独归类，不强行生成用例；
4. 为每个可测试点选择适用的设计方法（方法选择依据见 `references/design-methods.md`）；
5. 按覆盖维度清单补齐（功能/边界/异常/权限/数据/并发/性能/兼容，见 `references/coverage-dimensions.md`）；
6. 按 `references/case-schema.md` 产出用例 JSON；
7. 运行 `scripts/validate-cases.mjs` 校验，校验不通过则修复后重跑；
8. 运行 `scripts/render-report.mjs` 产出可读报告与追溯矩阵；
9. 汇报覆盖情况，**明确列出未被覆盖的需求条目与未决问题**（需求本身的歧义要暴露，不能靠猜）。

### F2 用例 JSON schema

用例集为**单个 JSON 文件**，结构：

```json
{
  "meta": {
    "source": "需求来源标识",
    "generated_at": "ISO-8601",
    "case_count": 0
  },
  "requirements": [
    { "id": "R-1", "title": "需求条目标题", "source_ref": "原文摘录或位置", "testable": true }
  ],
  "cases": [
    {
      "id": "TC-001",
      "title": "用例标题",
      "requirement_refs": ["R-1"],
      "dimension": "functional",
      "priority": "P0",
      "preconditions": [],
      "steps": [{ "action": "操作", "expected": "预期结果" }],
      "data": {},
      "tags": []
    }
  ]
}
```

字段约束（由 `validate-cases.mjs` 强制）：

| 字段 | 约束 |
|------|------|
| `cases[].id` | 必填，全局唯一，匹配 `^TC-\d{3}$` |
| `cases[].title` | 必填非空 |
| `cases[].requirement_refs` | 必填非空数组，且每项必须存在于 `requirements[].id` |
| `cases[].dimension` | 必填，枚举见 `references/coverage-dimensions.md` |
| `cases[].priority` | 必填，枚举 `P0/P1/P2/P3` |
| `cases[].steps` | 必填，至少 1 条；每条含非空 `action` 与 `expected` |
| `cases[].preconditions` | 可选数组 |
| `cases[].data` / `cases[].tags` | 可选 |

### F3 校验脚本 `scripts/validate-cases.mjs`

纯 Node.js，**零第三方依赖**，只读 JSON 文件并校验。

**必须能检出并以非 0 退出码报告**：

1. 用例 ID 重复；
2. 缺少必填字段；
3. `requirement_refs` 引用不存在的需求条目 ID；
4. `dimension` / `priority` 取值非法；
5. `steps` 为空，或步骤缺 `action` / `expected`；
6. JSON 语法错误。

**必须输出**：需求条目总数、可测试条目数、用例总数、按覆盖维度的用例数分布、**未被任何用例覆盖的需求条目 ID 列表**。

退出码约定：`0` = 校验通过；`1` = 校验失败（列出全部问题）。

### F4 渲染脚本 `scripts/render-report.mjs`

纯 Node.js，零第三方依赖。读用例 JSON，输出 Markdown：

1. 用例总览表（ID / 标题 / 关联需求 / 维度 / 优先级）；
2. **追溯矩阵**：需求条目 → 覆盖它的用例 ID 列表 → 覆盖状态；
3. 未覆盖需求条目清单。

### F5 npm 包

- 包名 `internal-rt-test-agent-skills`（`registry.npmmirror.com` 与 `registry.npmjs.org` 均未被占用，已核查）；
- `bin/internal-rt-test-agent-skills` 提供 CLI，至少支持 `install` / `uninstall` / `list`；
- `install` 把 `skills/` 下各 skill 复制到 `~/.agents/skills/<name>/`，**幂等**（重复执行不产生重复目录、不报错）；
- `install` 同步更新 `~/.agents/skills/.skill-lock.json`：新增 `sourceType: "npm"` 的条目，**保留其他 skill 的既有条目不变**；
- 支持环境变量 `INTERNAL_RT_SKILLS_DIR` 覆盖安装根目录（便于测试隔离，避免污染真实 skill 目录）；
- `package.json` 的 `files` 字段显式声明打包内容。

### F6 安装行为约束

- 安装**不修改**用户 shell 配置（不改 `.bashrc` / `.zshrc` / PATH）；
- 安装**不执行**被安装 skill 的任何代码；
- `uninstall` 只移除本包安装的 skill，不碰用户其他 skill；
- `~/.agents/skills` 本身是 git 仓库，安装产生的变更以**工作区文件变更**形式体现，不自动 commit、不自动 push。

## 非功能要求

- **性能**：校验与渲染脚本对 500 条用例的用例集，单次执行 < 2 秒。
- **安全**：脚本零第三方依赖，不执行需求文本或用例文本中的任何内容，不发起网络请求。
- **可移植**：脚本纯 Node.js 内置模块，Windows / macOS / Linux 均可运行，不依赖 bash、python3、`/tmp`。
- **可维护**：skill 目录内不得出现 `README.md` / `CHANGELOG.md` / `INSTALLATION.md` / `install.sh` / `.env` 等对模型无用的文件。
- **质量门禁**：`lint-skill.js` 退出码 0；eval 对比中 with-skill 不劣于 baseline。
