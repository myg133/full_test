# REQ-002.5a 验收报告

- **需求**：REQ-002.5a 轮次状态推进器（状态写入权收口到脚本）
- **交付分支**：`feature/REQ-002.5A`
- **交付 commit**：`e7cef81`（主体）+ `5ce4c51`（追加：skip-scope 补 at/by）+ 补丁 commit（缺陷 4 修复，见第 5 节）
- **验收方**：BA（`ba-local-ba-20261109161500`）
- **验收方式**：机械验收脚本 + 契约↔实现变异测试 + 独立 QA 子 agent

---

## 1. 验收结论

**通过**（第 5 节的 P0 缺陷 4 修复完成后）。

| 项 | 结果 |
|---|---|
| AC 验收脚本 | 22 PASS / 0 FAIL（`verify-acceptance.sh`，AC-001~021） |
| REQ-002B 契约↔实现变异回归 | 41 PASS / 0 FAIL（`verify-regression-002b.sh`） |
| 独立 QA 子 agent | 见第 4 节 |
| 既有需求回归（REQ-002A / REQ-002B） | 无回归 |
| 分发链路 | 新文件已进 npm 包 |

## 2. 交付清单

| 文件 | 行数 | 职责 |
|---|---|---|
| `skills/test-case-design/scripts/lib/state-machine.mjs` | 317 | **状态机规则单一来源**：轮次/阶段/scope/round 枚举、转移表、终态判定、`status`↔`history` 一致性判定、history 四字段、`scopes_skipped` 四字段 |
| `skills/test-case-design/scripts/cycle-state.mjs` | 795 | 状态推进器：`init` / `show` / `advance` / `skip-scope` / `set-stage`。原子写（临时文件 + rename）、失败零副作用、幂等、`--json`、退出码 0/1/2 |
| `skills/test-case-design/references/state-machine.md` | 226 | 状态推进契约：枚举、完整转移表、全部子命令与参数、原子性与副作用规则、"状态文件只由脚本写"硬约束、常见错误与修法 |
| `skills/test-case-design/scripts/verify-layout.mjs` | 795 | 删掉自带的状态机实现改为 import 共享模块；补 4 处契约↔实现缺口；强制项 14 → 18 条 |
| `skills/test-case-design/references/project-layout.md` | 339 | 新增 §4.2 `cycle.json` 字段表；各"必须"标注是否被校验器拦截；§6.1 错误表、§6.3 检查表同步 |
| `skills/test-case-design/SKILL.md` | 118 | 补 `verify-layout.mjs` / `cycle-state.mjs` / `references/project-layout.md` / `references/state-machine.md` 四个入口 + 写入权硬约束；补 schema v2 输出契约（缺陷 4） |

## 3. 本 REQ 修复的既有缺陷

| # | 缺陷 | 定性 | 修法 |
|---|---|---|---|
| 1 | `cycle.json` 的 `requirement` 是校验器必填，但契约文档 §4 从未写过 `cycle.json` 字段表 | **文档缺口**（校验器是对的，REQ-002B demand.md F4 有定义） | 补 `project-layout.md` §4.2 字段表 |
| 2 | 环境 `name` 与文件名不一致未被拦截（契约 §3.2 明确要求"完全一致"） | **实现缺口** | 校验器加交叉校验 |
| 3 | `history` 每条缺 `at`/`from`/`to`/`by` 全部未被拦截（契约 §4.3 明确要求） | **实现缺口** | 共享模块加 `checkCycleState()`，校验器与推进器共用 |
| 4 | `SKILL.md` 的 Output contract 未同步 schema v2 → **REQ-002A 的全部强制在真实使用路径上空转** | **文档缺口（P0）** | 补 v2 输出契约 + 校验器加 v2 骨架生成 |

### 缺陷 4 详述（本轮最严重）

REQ-002A 的强制规则是"缺字段报 WARN，显式声明 `schema_version: 2` 才升级为 ERROR"。而 `SKILL.md` 从未告诉 agent 要声明 `schema_version: 2`，其 Output contract 列的 `cases[]` 字段仍是 v1 形态。

**实测**：按 SKILL.md 的 Output contract 造用例集 → 校验器只报 4 条 WARN → **exit 0 通过**。

即 `open_questions`（歧义暴露）、`coverage_matrix`（跳过留痕）、`cases[].method`（方法声明）、`cases[].status`（生命周期）四项强制，**在 agent 的实际使用路径上一条都没生效**。REQ-002A 的立项理由（"强制必须落在脚本上"）因此落空。

**根因**：REQ-001 时代的 SKILL.md 在 REQ-002A 引入 v2 后未同步，而 REQ-002A 的 14 条 AC 里没有一条检查"SKILL.md 与 schema 是否一致"。

## 4. 独立 QA 验收

> 待填：QA 子 agent 的独立结论、AC 逐条结果表、10 个怀疑项的逐条结论、其发现的额外缺陷。

## 5. 补丁轮次

| 轮次 | commit | 内容 | 触发 |
|---|---|---|---|
| 主体 | `e7cef81` | 状态推进器 + 共享状态机模块 + 契约文档修复 + 缺陷 1/2/3 | BA 首轮派单 + 追加缺陷 2/3 |
| 追加 | `5ce4c51` | `skip-scope` 记录补 `at`/`by`（审计链完整性） | BA 裁决 D13 |
| 补丁 | 待填 | 缺陷 4 修复：SKILL.md v2 输出契约 + 校验器 v2 骨架生成 | BA 独立发现（P0） |

## 6. 本 REQ 建立的两道防线（长期资产）

这个套件此前**没有任何自动化回归测试**，连续两次返工都靠手工逐条验证 —— 而缺陷 2、3、4 正是手工验收阶段漏掉的。

| 资产 | 位置 | 作用 |
|---|---|---|
| AC 验收脚本 | `REQ-002.5a-state-advance/verify-acceptance.sh` | 22 条 AC 全机械化，一条命令跑完 |
| 契约↔实现变异回归 | `REQ-002B-project-layout/verify-regression-002b.sh` | 41 例：逐条破坏契约声明的"必须"，看校验器是否真拦。**这类缺陷只能靠变异测试挖出来** |

## 7. 方法论沉淀（留给后续 REQ）

「**契约 ↔ 实现 ↔ 文档三者的双向一致性**」必须机械化验证，不能靠人读：

- 契约文档写了"必须" → 校验器必须拦（变异测试覆盖）
- 校验器拦了 → 契约文档必须写（否则执行者按文档办事被拒）
- 文档/契约改了 → SKILL.md 必须同步（否则 agent 产出走错形态）

三个缺口（缺陷 1、2、3、4）分别落在这三条链路上。**后续每个新增契约的 REQ，都应同时提供一份变异回归脚本。**
