# REQ-011 —— R2 回归轮：`regression-plan` skill + 套件层组合门

- **需求编号**: REQ-011
- **优先级**: P1
- **状态**: 草稿
- **原编号**: `REQ-002.6`（架构文档 §8 的编号映射；本 REQ 在登记表里占的是顺延后的号）

## 0. 为什么是现在做这件事

REQ-006 收口后，套件的状态是：**能设计用例、能执行用例，但两截是断的**。

| 环节 | 状态 | 缺口 |
|---|---|---|
| 设计（R1） | ✅ `test-case-design`（11 维度 / 9 方法 / 42 条判据） | — |
| 执行 | ✅ `test-execute`（证据链 + sha256 指纹） | — |
| **回归选样（R2）** | ❌ **无** | changelog 改了 3 行，600 条用例跑哪 60 条？**没人能回答** |
| **报告** | ❌ **无** | 执行产出了 `results.json` / `meta.json` / 证据链，但**没有任何 skill 消费它们出报告**（`render-report.mjs` 是**用例集**报告，覆盖率/追溯矩阵，不是执行报告） |
| 缺陷复现（R3） | ❌ 无 | 排在后面（REQ-007） |

架构文档 §1.1 把 R2 的「变更影响分析 + 用例选择」称为 **"测试自动化"与"测试智能"的分界线**。
这句话现在仍然成立，但它的另一半常被忽略：**这套智能必须建立在"用例集里有什么"之上**，
而 REQ-006 刚刚把「覆盖维度」与「测试方法」从散文变成了**可机械核验的枚举**（`dimensions.json` 11 项 / `methods.json` 9 种）。
它们目前是**静态库** —— 没有任何 skill 在运行时消费它们。

本 REQ 交付 **`regression-plan` skill**，让这套库第一次成为运行时依赖：
R2 的影响面判定 =「变更条目命中了哪些维度 / 哪些方法 / 哪些需求条目 / 哪些用例」。

同时交付 **套件层组合门**，理由见 §1.2。

## 1. 目标

1. 交付 `regression-plan` skill：读 changelog + 已有用例集 → 产出 `regression-plan.json`（哪些用例要重跑、哪些要人工复核、哪些变更判不了）。
2. 交付套件层组合门：把包装到临时根后，**实跑跨 skill 组合场景**，并校验 skill 之间的版本配套。

### 1.1 为什么「影响面」必须可证伪

R2 的产出是**一份选样结论**。选样错了有两种方向，后果完全不同：

| 方向 | 后果 | 容忍度 |
|---|---|---|
| **多选**（多跑了不该跑的用例） | 多花时间 | 可容忍 |
| **漏选**（该跑的没跑） | 回归漏测 → 缺陷逃逸 | **不可容忍** |

所以本 REQ 的判定口径是：**「该出现在 selected 里的必须出现在」是硬要求；「不该出现在 selected 里的不得出现在」也要查**（防止用一个粗放的口径把 600 条全选出来糊弄过去）。

### 1.2 为什么必须同时做套件层组合门

`test-execute/scripts/lib/cycle.mjs:20` 在运行时解析 `../../../test-case-design/scripts/cycle-state.mjs`
—— **test-execute 对 test-case-design 存在硬跨 skill 依赖**。

登记表已登记该风险（「安装副本的**组合可用性**没纳入任何验收」）：版本错配会让轮次推进**静默失效**，
下游报的是业务错（"缺少必填字段 expected"），agent 会照着去改自己的用例 → 死循环。

**实测（2026-11-12，BA 侧手工验证，当前已装副本）**：
- `test-execute` 的 offline 套件 → 4 passed / 1 failed（故意）/ 1 blocked（故意），与 README 预期一致；
- `cycle-state.mjs init` → `run-suite.mjs --cycle` → execute 阶段推进为 `in_progress`，产物路径与 run_id 已写入 `cycle.json`。

即：**当前这套副本是配套的**，但**这条结论没有任何自动化护栏**。
本 REQ 要落地 4 个 skill（新增 `regression-plan`），错配面比 3 个 skill 时更大 —— 组合门必须先于或伴随第 4 个 skill 落地。

## 2. 功能项

### F1 `regression-plan` skill 的位置与入口

- 目录：`<package>/skills/regression-plan/`
- `SKILL.md`（frontmatter 含 `name` / `description`）+ `references/` + `scripts/`
- **零第三方依赖**（只用 `node:` 内置模块），与既有 skill 一致

### F2 输入契约

| 输入 | 形态 | 说明 |
|---|---|---|
| changelog | Markdown 文件 | 按 **二级及以下标题**切分成变更条目；每条自动编号 `C-1`、`C-2`… |
| 已有用例集 | `cases.json`（schema v2） | 需求条目 / 用例 / 维度 / 方法 / 生命周期状态 |
| 维度库 | `test-case-design/references/dimensions.json` | **唯一来源**，不硬编码维度清单 |
| 方法库 | `test-case-design/references/methods.json` | **唯一来源**，不硬编码方法清单 |

**changelog 里的引用标记**（显式、可解析）：

| 标记 | 含义 | 指向 |
|---|---|---|
| `@R-<n>` | 需求条目引用 | `cases.json` 的 `requirements[].id` |
| `@TC-\d{3}` | 用例引用 | `cases.json` 的 `cases[].id` |
| `@dim:<维度名>` | 维度引用 | `dimensions.json` 的维度 id |

### F3 影响面判定（核心）

**变更条目的影响面** = 下列三条**可复算**的来源之并集：

| 来源 | 判定方式 | 记录到 `reason` 的形式 |
|---|---|---|
| 需求条目命中 | 条目文本含 `@R-<n>` | `requirement_ref:R-<n>` |
| 用例命中 | 条目文本含 `@TC-\d{3}` | `case_ref:TC-\d{3>` |
| 维度命中 | 条目文本含 `@dim:<维度名>`，**或**条目正文命中该维度的 `applies_when` 信号词 | `dim_ref:security` / `dim_signal:认证→security` |

**用例被选中的条件**（`selected`）：

```
affected(case) = 需求命中 ∨ 用例命中 ∨ 维度命中
method_blocked(case) = ∃ 变更条目, ∃ case.method 中的方法 m
                       : 该变更条目的正文命中 m.not_applies_when 的某一条
selected(case)  = affected(case) ∧ ¬method_blocked(case)
needs_review(case) = affected(case) ∧ method_blocked(case)
```

**为什么维度信号走"隐式命中"**：架构文档 §1.2 说 R2 要"变更影响分析"，而人写 changelog 时不会为每条都打 `@dim:` 标签。
信号词命中是**可解释、可复核**的（命中了哪个词 → 记进 `reason`），且其偏差方向是**多选**（多跑），属可容忍方向（§1.1）。

**为什么 `not_applies_when` 走"隐式命中"**：该方法在本次变更场景下**不适用** → 影响面**判不了** → 按本套件一贯的诚实纪律
（"判不了就说判不了"，见 REQ-006 AC-008 / D27），进 `needs_review` 交给人，**不得**静默当成"不受影响"。

### F4 输出契约：`regression-plan.json`

写到**轮次目录**内（与 `cycle.json` 同级）：`test-assets/cycles/<cycle_id>/regression-plan.json`

```jsonc
{
  "schema_version": 1,
  "cycle_id": "R2-CHANGELOG-2.3",
  "source": { "changelog": "CHANGELOG-2.3.md", "cases": "test-assets/suites/REQ-001-coupon/cases.json" },
  "changes": [
    { "id": "C-1", "title": "修复优惠券叠加的边界错误", "requirement_refs": ["R-3"], "case_refs": [], "dimensions": [] }
  ],
  "selected":     [ { "case_id": "TC-012", "reason": "requirement_ref:R-3", "change_refs": ["C-1"] } ],
  "needs_review": [ { "case_id": "TC-020", "reason": "method_not_applies:M2.1", "change_refs": ["C-2"] } ],
  "undecidable_changes": [ { "change_id": "C-3", "reason": "无显式引用，且正文未命中任何维度/方法信号" } ],
  "summary": { "total_cases": 44, "selected": 12, "needs_review": 3, "undecidable_changes": 1, "impact_complete": false }
}
```

**`selected` / `needs_review` / `undecidable_changes` 三个集合必须两两互斥**；
`summary` 的每个数字必须与对应集合的长度**逐字相等**。

### F5 诚实性要求（本 REQ 的红线）

1. **不得凭空造用例**：输出的 `case_id` 必须真实存在于输入用例集。
2. **引用不存在必须报错**：changelog 里的 `@R-99` / `@TC-999` 在输入里找不到 → **报错退出（退出码 1）**，不得静默忽略（静默忽略 = 悄悄漏测）。
3. **判不了必须显式**：既无显式引用、正文也未命中任何维度/方法信号的变更条目 → 进 `undecidable_changes[]`，且**不得**让任何用例因它进 `selected`。
4. **影响面不完整必须声明**：`summary.impact_complete` 在存在 `undecidable_changes` 时必须为 `false`（不得报"影响面完整"）。
5. **不得写输入**：`cases.json` 是只读输入，跑完不得被修改。

### F6 轮次状态（跨 skill 依赖）

R2 轮次状态（`cycle.json` / `cycles/index.json`）**只由 `test-case-design/scripts/cycle-state.mjs` 写**
（硬约束，REQ-002.5a）。`regression-plan` **不得**自己实现轮次状态写入，**不得**直接编辑 `cycle.json`。

- R2 的 `round_type` = `regression`（`cycle-state.mjs` 允许值之一：`new-requirement` / `regression` / `defect-verify`）
- 变更影响分析落在 `design` 阶段（阶段集合固定：`clarify` / `design` / `data` / `execute` / `triage` / `report`）

### F7 套件层组合门

**7.1 每个 skill 必须声明版本与依赖** —— 根级 `skill-meta.json`：

```jsonc
{ "name": "test-execute", "version": "0.1.0", "requires": { "test-case-design": ">=0.1.0" } }
```

⚠️ **位置选择**：放**根级**（`skills/<name>/skill-meta.json`）而不是 `references/` 下 ——
因为 REQ-006 的 AC-034 ⑮ 子判据要求「实现清单必须覆盖被验目录里真实存在的每一个文件」，
而它的**基准范围**限定为 `references/` `scripts/` `SKILL.md`（D25 ⑫ F2 的口径）。
根级文件**不在登记口径内** → 新增它**不会**让 REQ-006 的 42 条判据判红，
也**不需要**改动 REQ-006 已验收的 `feature-meta/status.md` 实现清单（那会断掉"合并物 == 被独立验收物"链）。

**7.2 安装器新增组合校验子命令** —— `bin/test-agent-skills.mjs verify`：

1. 把包装到**临时根**（不碰真实安装根 `~/.agents`）
2. 校验**依赖图**：每个 skill 的 `requires` 是否被满足（版本比较）
3. **实跑跨 skill 组合场景**（不得只检查文件存在）：
   - `test-execute` 的 offline 夹具 → 断言 4 passed / 1 failed / 1 blocked（与 README 预期一致）
   - `cycle-state.mjs init` → `run-suite.mjs --cycle` → 断言 `cycle.json` 的 execute 阶段已推进
   —— 这条链路**经过 `test-execute/scripts/lib/cycle.mjs` → `test-case-design/scripts/cycle-state.mjs`**，
   正是那条**硬跨 skill 依赖**
4. 依赖不满足 → **报版本问题**（点名：哪个 skill、要求什么、实际什么），**不得**让下游报业务错
5. 退出码：`0` 全通过 / `1` 有问题 / `2` 用法错误

### F8 交付侧记账

- `code/feature-meta/regression-plan/{status,traceability,verification-report}.md`（**新增子目录**）
- ⚠️ **不动** `code/feature-meta/` 根目录的三份文件（那是 REQ-006 的 test-case-design 追溯链，
  AC-034 逐字核对其判据条数 / 决策号 / 验收数字）→ REQ-011 单独开子目录，**互不打架**
- `README.md` 补第 4 个 skill 的说明（记账必须与实际一致）

## 3. 非目标（明确不做）

1. **不做执行**：R2 只产出计划；执行仍是 `test-execute` 的事。
2. **不做漏洞扫描 / 压测执行**：安全与压测的**执行**能力域分别属 REQ-008 / REQ-009。
   本 REQ 只让 R2 的选样能识别 security / stress 维度的影响面。
3. **不改 `test-case-design` 的既有文件**：不动 `dimensions.json` / `methods.json` / `check-methods.mjs` /
   `project-layout.md` / `verify-layout.mjs` / `SKILL.md`。
   → REQ-006 的 42 条判据必须**原样继续全绿**（作为本 REQ 的上游回归）。
4. **不改 R3 / 报告能力域**：R3 属 REQ-007，报告属 REQ-010。
5. **不做用例内容的自动改写**：R2 的"调整测试用例"这一步**不由本 REQ 自动完成** ——
   `regression-plan.json` 只声明"这条用例需要被改"，**改**的动作留给 R1 的设计流程。
   本 REQ **只读** `cases.json`，绝不写。
6. **不升 npm 包版本**：沿用 0.1.0（与 REQ-001 / 002.4 / 005 一致）。

## 4. 判据要点（25 条）

判据集 = **AC-001~AC-025**，自包含于本目录的 `acceptance.md`（每条含前置条件 / 测试步骤 / 预期结果 / 判据形式 / 类型）。

| 组 | 条数 | 内容 |
|---|---|---|
| A 交付物形状 | 4 | skill 存在与结构 / `skill-meta.json` / README 记账 / 目录契约不被新产物打破 |
| B 选样正确性 | 7 | 不造 id / 需求命中 / 维度命中 / 用例命中 / 不多选 / **按 basis 重算自洽** / reason 可解释 |
| C 诚实性 | 4 | 不可判定显式 / 不假装覆盖 / 坏引用报错 / 摘要与影响面完整声明 |
| D 生命周期与方法适用性 | 3 | 非 active 不入选 / `not_applies_when` → `needs_review` / 集合互斥 |
| E 写入权与幂等 | 2 | 不写输入 / 两次跑逐字相同 |
| F 套件层组合门 | 4 | 子命令存在 / 实跑跨 skill 场景 / 版本问题报告 / 临时根隔离 |
| G 变异体 | 1 | 选样核心逻辑必须被变异体测出差异 |

**每条判据都必须能判红**：G 组用变异体证明 B 组的护栏不是恒真；其余各组用"改坏实现 → 本条判红"证明。

## 5. 验收方式

- **主验收**：`verify-acceptance.sh`（本目录），对**被验 skill 目录**跑；退出码 0 = 全通过
- **上游回归**（必须一起跑，任一红即 REQ-011 不通过）：
  - REQ-006 主验收（42 条）—— 证明**没碰坏 test-case-design**
  - REQ-002A 回归（19 条）、REQ-002B 回归（41 条）
- **独立验收**：由独立验收方自造探针攻击 25 条判据（不是复用 BA 的脚本结论）

## 6. 与既有 REQ 的关系

| REQ | 关系 |
|---|---|
| REQ-006 | **上游**。REQ-006 的 42 条判据是本 REQ 的上游回归；REQ-011 **不改** `test-case-design` 的任何文件 |
| REQ-005 | REQ-006 的上游（方法库）；本 REQ 消费 `methods.json` 但不改它 |
| REQ-004 | `test-execute` 的来源；本 REQ 的组合门要实跑它的 offline 夹具与 `--cycle` 路径 |
| REQ-003 | `qa-toolchain`；本 REQ 的组合门会把它一并装进临时根并校验其 `skill-meta.json` |
| REQ-002A / 002B | 上游回归（schema v2 / 目录契约） |
| REQ-002.5a | `cycle-state.mjs` 的来源；本 REQ 的轮次写入只经它 |
| REQ-010（待建） | **下游**。`test-report` 要消费 `regression-plan.json` → 本 REQ 的输出形状是 REQ-010 的输入契约 |
| REQ-007 / 008 / 009 | 并行能力域，不在本 REQ 范围 |

## 7. 决策号

本 REQ 的决策号自 **D35** 起（承接 REQ-006 的 D1~D31、REQ-004 的 D32~D34）。

⚠️ **既有事实登记**：REQ-002.5a / REQ-004 / REQ-005 / REQ-006 四条决策链**各自从 D1 重开**，
号段互有重叠（例：REQ-004 的 D30 与 REQ-006 的 D30 是两条不同的决策）。
即**"决策号全局唯一"这一说法在本仓并不成立** —— 唯一性只在**单个 REQ 目录内**成立。
本 REQ 沿用"从 D35 起"的写法以避免进一步扩大重叠；跨 REQ 检索 D 号会歧义 —— 登记为遗留项。
