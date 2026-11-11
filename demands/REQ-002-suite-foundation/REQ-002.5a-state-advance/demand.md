# 需求：测试套件基座 — 轮次状态推进器（写入权收口）

- **需求编号**: REQ-002.5a
- **所属 Epic**: REQ-002 suite-foundation（对应设计文档中的 `002.5` 拆分后的一半）
- **优先级**: P0
- **状态**: 已就绪

## 需求描述

### 背景

REQ-002A 定义了用例生命周期字段（`status` / `revision`），REQ-002B 定义了轮次状态机契约（`cycle.json` 的状态枚举、`status` 与 `history` 的一致性规则）。**但两者都只定义了状态长什么样，没有定义谁来推进状态。**

现状是：agent 直接手改 `cycle.json`。而契约第 4.3 节写得很清楚——

> `cycle.json` 的 `status` **必须等于** `history` 数组最后一条的 `to`。改状态时必须同时追加一条 `history` 记录，**两处要同一次改动完成**。

"同一次改动完成"靠 agent 自觉，这是靠不住的。REQ-001 的实测已经证明了这个失败模式：

| 现象 | 实测结果 |
|---|---|
| 模型漏产用例 | baseline 3 次 = 62/56/48 条，with-skill 仅 29 条，且宣称"覆盖完整" |
| 模型绕过机器契约 | with-skill 的未决问题只写进人读 `report.md`，JSON 里 `open_questions` **0 条** |

模型不是"忘了"，是**自信地走了人读路径**。同理，模型会凭印象把 `status` 改成 `completed` 而漏写 `history`、或干脆跳过状态推进。REQ-002A 的教训是：**强制必须落在脚本上**，SKILL.md 的自然语言对模型只是软约束。

而且这个底座不稳，后面全塌：REQ-002.5b（执行 + 证据链）、REQ-002.6（R2 回归）、REQ-002.7（R3 缺陷验证）都要读写轮次状态与用例状态。状态是脏的，证据链就不可信；证据链不可信，报告就没有价值。

### 目标

**把状态写入权从 agent 手里收口到脚本。**

agent 只能提交"推进意图"（"这一轮开始了"、"这一轮完成了"），由脚本负责：校验前置状态是否合法 → 原子写入 → 留痕。agent 不再直接编辑状态文件。

**这不是做测试，是做"测试轮次状态怎么被合法推进"的规约。**

### 范围边界

**在范围内**：

- 轮次状态机的**可执行定义**（转移表、枚举、终态规则）
- `scripts/cycle-state.mjs` 状态推进器
- 状态机规则的**单一来源模块** `scripts/lib/state-machine.mjs`，供 `verify-layout.mjs` 复用
- `references/state-machine.md` 状态推进契约文档
- **修复 `references/project-layout.md` §4 缺失 `cycle.json` 字段表**（见下方"已确认的既有缺陷"）
- `SKILL.md` 补齐脚本调用入口（`verify-layout.mjs` / `cycle-state.mjs`）

**不在范围内**：

- **MCP 适配层** —— 用户决策：暂不评估，只做 CLI 状态机。理由：本客户端当前无 MCP 工具（`tool_search` 零命中），做成核心依赖等于交付一个跑不起来的东西；skill 套件的核心优势是"拿过来就能干"。
- **用例生命周期流转**（`cases[].status` 的批量流转、`coverage_matrix` 同步）—— 归 REQ-002.6（R2 回归的用例选择），那里才需要完整能力。本 REQ 只保证 `cycle.json` 侧的状态正确。
- 执行器、证据采集 —— 属 REQ-002.5b。
- `.tools/` 自举 —— 属 REQ-002.4。

## 已确认的既有缺陷（本 REQ 必须修）

本 REQ 开发期间，BA 对 REQ-002B 已交付的 `verify-layout.mjs` 做了一轮**契约 ↔ 实现一致性变异测试**：把契约文档声明的每一条"必须"逐个破坏，看校验器是否真的拦。共发现 3 个缺陷，**全部属于"文档写了必须、校验器没拦"**，直接违反契约文档第 1 节的承诺：

> 凡是本文件没写的自由项，校验器一律不拦；凡是本文件写了"必须"的，**校验器一定会拦**。

### 缺陷 1：契约文档漏写 `cycle.json` 字段表（文档缺口）

**现象**：`scripts/verify-layout.mjs` 第 496 行要求 `cycle.json` 必须含非空字符串 `requirement`，但 `references/project-layout.md` §4「轮次状态机与阶段」**从未写过 `cycle.json` 的字段表**，只讲了状态机与一致性规则。

**实测**：按契约文档构造的合法 `cycle.json`（只写 `cycle_id` / `round` / `round_type` / `status` / `scopes` / `scopes_skipped` / `stages` / `history`）被校验器判 FAIL：

```
[FAIL] test-assets/cycles/R1-REQ-001/cycle.json: requirement 缺少必填字段（或不是非空字符串）
```

**定性**：校验器是对的 —— REQ-002B 的 `demand.md` F4 明确定义了 `cycle.json` 含 `"requirement": "REQ-001"`。**是契约文档漏了**。

**修法**：在 `references/project-layout.md` §4 补齐 `cycle.json` 的字段表（至少含 `cycle_id` / `requirement` / `round` / `round_type` / `status` / `scopes` / `scopes_skipped` / `stages` / `history` / `trigger`），并保证"按文档构造的合法 `cycle.json` 能通过 `verify-layout.mjs`"（AC-014）。

### 缺陷 2：环境 `name` 与文件名不一致未被拦截（实现缺口）

**契约要求**（§3.2 字段表首行）：

> `name` | string | 是 | 环境标识。**必须与文件名（不含 `.json`）完全一致**

**实测**：把 `environments/local.json` 的 `name` 改成 `"other"`（文件名不变），校验器**放行**，exit 0。

**原因**：实现里没有"文件名 ↔ `name` 字段"的交叉校验。`verify-layout.mjs` 第 337 行的 `envNames.add(basename(file, '.json'))` 是给 `suite.json` 的 `environment` 悬空引用检查用的，不是 name 一致性检查。

**修法**：加一条 —— 环境文件的 `name` 必须等于其 basename（不含 `.json`），否则 FAIL（AC-017）。

### 缺陷 3：`history` 每条记录缺 `at` / `from` / `to` / `by` 全部未被拦截（实现缺口）

**契约要求**（§4.3）：

> `history` 至少一条记录，**每条含 `at` / `from` / `to` / `by`**，其中 `from` 与 `to` 取值同 `status` 枚举。

**实测**（四例全部放行，exit 0）：

| 变异 | 实际 |
|---|---|
| `history[0]` 删掉 `by` | 放行 ✗ |
| `history[0]` 删掉 `at` | 放行 ✗ |
| `history[0]` 删掉 `from` | 放行 ✗ |
| `history[0]` 删掉 `to` | 放行 ✗ |

对照：`history` 为空数组 → 拦 ✓；`history[0].from` 填非法枚举 → 拦 ✓。说明现有实现只校验了"最后一条是 object"和"from/to 枚举合法"，**没有校验四个必填字段是否齐备**。

**修法**：每条 history 记录必须含 `at` / `from` / `to` / `by` 且为非空字符串；缺任一 → FAIL。`from` / `to` 继续受 `status` 枚举约束（AC-018）。

### 为什么三个都要在本 REQ 修

1. 缺陷 1 会直接卡住 REQ-002.5b 的执行链路（按文档造的轮次跑不起来）。
2. 缺陷 2、3 是"契约说了必须、校验器没拦" —— **跟没写是一回事**。本 REQ 的核心目的正是把强制真正落到脚本上，留着不管，REQ-002.5b 会把不合规状态直接固化成证据链。
3. 三个缺陷的共同根源是同一个：REQ-002B 交付时缺少"契约 ↔ 实现双向一致性"的机械验证。修复它们的同时，本 REQ 建立 `verify-acceptance.sh`（见 F8），把这条防线常态化。

## 功能要求

### F1 状态机定义（单一来源）

轮次状态枚举（沿用 REQ-002B 契约）：

`planned` / `in_progress` / `completed` / `blocked` / `cancelled`

**转移表**：

| 当前状态 | 允许转移到 |
|---|---|
| `planned` | `in_progress`、`cancelled` |
| `in_progress` | `completed`、`blocked`、`cancelled` |
| `blocked` | `in_progress`、`cancelled` |
| `completed` | ——（终态） |
| `cancelled` | ——（终态） |

阶段状态枚举（沿用契约）：`pending` / `in_progress` / `done` / `blocked` / `skipped`。

**单一来源要求**：转移表、枚举、终态判定、`status`↔`history` 一致性规则**只允许存在一份**，存放在 `scripts/lib/state-machine.mjs`。`verify-layout.mjs` 必须改为 import 该模块，不得自带第二份实现。

> 这是本 REQ 最容易被做漏的一条。两份实现漂移的后果是：`cycle-state.mjs` 认为合法的状态，`verify-layout.mjs` 判 FAIL；反之亦然。agent 会开始"绕过脚本手改文件"，收口就白做了。

### F2 推进器 `skills/test-case-design/scripts/cycle-state.mjs`

纯 Node.js，零第三方依赖，只用 `node:` 内置模块。

**用法**：

```bash
node scripts/cycle-state.mjs <子命令> <参数...> [--json]
```

`--json` 输出机器可读 JSON（给 agent 解析），缺省输出人读文本。

**子命令**：

| 子命令 | 作用 | 关键参数 |
|---|---|---|
| `init` | 创建新轮次骨架 | `--cycle-id` `--round` `--round-type` `--requirement` `--scope`（可重复）`--by` |
| `show` | 读当前状态：status、history、stages、**允许的下一步状态** | 轮次目录 |
| `advance` | 推进轮次状态 | `--to <状态>` `--by <agent>` `[--reason <文本>]` |
| `skip-scope` | 记录本轮跳过的 scope | `--scope <scope>` `--reason <文本>` |
| `set-stage` | 设置阶段状态 | `--stage <名称>` `--status <状态>` `[--artifacts a,b]` |

**示例**：

```bash
node scripts/cycle-state.mjs advance test-assets/cycles/R1-REQ-001 --to in_progress --by dev-agent-1
node scripts/cycle-state.mjs skip-scope test-assets/cycles/R1-REQ-001 --scope load --reason "需求未给性能指标，无阈值可依"
node scripts/cycle-state.mjs show test-assets/cycles/R1-REQ-001 --json
```

### F3 推进的原子性与副作用规则

1. **原子写**：写临时文件 + `rename` 替换。中途失败不得产生半写的 `cycle.json`（不得出现 JSON 解析不了的中间态）。
2. **失败不留痕**：校验不通过时，**目标文件不得被修改**（不得追加半条 history，不得留下临时文件）。
3. **一致性由脚本保证**：`advance` 成功后，`status` 必然等于 `history` 最后一条的 `to` —— 因为这两处在同一次写入里完成。
4. **每次推进必留痕**：`history` 新增一条 `{at, from, to, by}`，`from` = 推进前状态，`to` = 推进后状态。`reason` 非空时写入该条记录。
5. **跳过必留痕**：`skip-scope` 的 `--reason` 为空或缺失 → 拒绝，退出码 1，文件不修改。（与 REQ-002A 的 `coverage_matrix[].skipped[].reason` 同一原则。）

### F4 `init` 的初始记录

`init` 创建 `cycle.json`，`status` = `planned`，并写一条 `history`：

```json
{ "at": "<ISO8601>", "from": "planned", "to": "planned", "by": "<agent>", "event": "created" }
```

契约要求 `history` 至少一条记录，而 `from`/`to` 都必须取自 `status` 枚举，所以初始记录只能是 `planned → planned`。用额外的 `event: "created"` 字段与后续的真实转移区分开。

### F5 契约文档 `skills/test-case-design/references/state-machine.md`

面向人与 agent，说明：

- 状态枚举与**完整转移表**（哪些能转、哪些是终态）
- 推进器的全部子命令与参数
- 原子性与副作用规则
- **"状态文件只由脚本写"这条硬约束**：agent 不得直接编辑 `cycle.json` / `cycles/index.json`，必须走 `cycle-state.mjs`
- 常见错误与修法（非法转移、跳过没写理由、status 与 history 不一致）

### F6 修复 `references/project-layout.md` §4

补齐 `cycle.json` 的**字段表**（至少含 `cycle_id` / `requirement` / `round` / `round_type` / `status` / `scopes` / `scopes_skipped` / `stages` / `history` / `trigger`），并说明每个字段的必填性、类型、语义。

同时在该文件里指明：状态的推进由 `scripts/cycle-state.mjs` 负责，不手改。

> 修完后必须能复现本 REQ 开头的那个缺陷已经消失：**按文档构造的合法 `cycle.json` 必须通过 `verify-layout.mjs`**。

### F7 `SKILL.md` 补齐入口

`SKILL.md` 当前**完全没有提到** `verify-layout.mjs` 与 `references/project-layout.md` —— agent 根本不知道它们存在。本 REQ 必须补上：

- `verify-layout.mjs` 的调用时机与用法
- `cycle-state.mjs` 的调用时机与用法
- "状态文件只由脚本写"的硬约束

> 这是 REQ-002B 开发阶段由 worker 主动指出的已知缺口（"agent 不知道去用它"）。不补，脚本等于不存在。本 REQ 只做**最小增量**，REQ-002.2 整体重写 `SKILL.md` 时再整合。

### F8 验收脚本 `BA/demands/.../REQ-002.5a-state-advance/verify-acceptance.sh`

本 REQ 的 18 条 AC 全部机械化，由 `verify-acceptance.sh` 逐条执行。

**背景**：这个套件至今**没有任何自动化回归测试**，连续两次返工（REQ-002A、REQ-002B）都是靠手工逐条验证。手工验证 18 条 AC 必然漏判 —— 本 REQ 的缺陷 2、3 正是手工验收阶段漏掉、靠变异测试才挖出来的。

**用法**：

```bash
bash BA/demands/REQ-002-suite-foundation/REQ-002.5a-state-advance/verify-acceptance.sh <skill-dir>
```

`<skill-dir>` 指向含 `SKILL.md` 的 skill 目录。退出码 `0` = 全过，`1` = 有 AC 未通过。

**约束**：只读 skill 目录，测试样例一律造在临时目录里，不污染仓库。

## 非功能要求

- **零依赖**：只用 `node:` 内置模块，`package.json` 的 `dependencies` 保持为空
- **可移植**：不含 bash / python3 / grep / sed，不写死 `/tmp` 路径
- **退出码语义统一**：`0` 成功 / `1` 校验失败或非法转移 / `2` 调用方式错误（与 `verify-layout.mjs` 一致）
- **诊断质量**：每条报错要含具体文件路径 + 字段路径 + 问题说明 + **合法的下一步动作**
- **幂等**：重复执行同一命令不产生额外副作用（`advance` 到当前状态应报"已在该状态"而非静默追加 history）
- **agent 友好**：`--json` 输出必须是合法 JSON，可被 agent 直接解析

## 验收要点

见 `acceptance.md`（18 条 AC）。

## 依赖说明

- **前置**：REQ-002A（schema v2）、REQ-002B（目录契约与 `verify-layout.mjs`）—— 均已完成
- **后续**：REQ-002.5b（执行 + 证据链）、REQ-002.6（R2 回归）、REQ-002.7（R3）
- **并行**：无。本 REQ 要改 `SKILL.md` 与 `verify-layout.mjs`，与 REQ-002.2 文件所有权重叠，**必须串行**（002.5a 先，002.2 后）
