---
name: test-case-design
description: |
  Turn a requirement document, PRD, or API spec into a machine-checkable test case set: split the text into atomic requirement items, generate cases with equivalence partitioning / boundary value analysis / decision table / state transition / orthogonal design, then emit case JSON plus a requirement-to-case traceability matrix.
  Use this skill when the user asks to "写测试用例"、"设计测试用例"、"拆测试点"、"补充边界用例"、"做需求覆盖分析"、"generate test cases", or pastes a requirement and asks what should be tested.
  Also use it to check an existing 用例集 for schema violations, requirement gaps, and "声称用了方法但其实没有对应产出" 的假覆盖。
  Do NOT use it for executing tests against a live system (接口压测、UI 自动化、跑测试脚本)、for writing 缺陷单 or 质量报告, or for code review — those are separate workflows.
---

# Test Case Design

把需求文本变成可校验的用例集，交付两样东西：用例 JSON（机器可消费）和追溯矩阵（证明每个需求条目都被覆盖）。

## Inputs to collect

先确认这些再动手；缺哪一项就用下面的追问补齐：

- **需求原文**：用户粘贴、文件路径或文档引用。只说"帮我写用例"却没给需求时，先要原文——没有原文就没有可拆解的条目，产出的用例集看起来完整，实际覆盖的是模型自己的臆测。
- **被测对象与交互方式**：REST API、Web UI、CLI、批处理任务、规则引擎……这决定步骤写"发起请求"还是"点击按钮"，也决定哪些覆盖维度适用。
- **需求条目与用例的编号起点**：`R-1`、`TC-001` 是否与既有资产冲突。
- **优先级口径**：P0 在这个团队代表什么（阻断主流程？资损？数据安全？）。各团队口径差异极大，照搬默认会让 P0 失去筛选意义。
- **范围边界**：本次覆盖哪些端/模块/角色；哪些明确不在本次范围。
- **环境前提**：预发环境、测试账号、依赖的外部系统——它决定 `preconditions` 与用例是否可执行。
- **已有材料**：历史用例、数据字典、接口契约，能对齐格式和命名就复用。

## Procedure

1. **收集并确认需求输入**（粘贴文本 / 文件 / 文档）。
   原因：需求原文是唯一事实来源；先确认它再拆条目，能避免后面整批返工。

2. **把需求拆成原子条目 `R-1, R-2, ...`**，每条记录 `title`、原文摘录（`source_ref`）与来源位置。
   原因：原子条目是覆盖的最小单位；条目太粗会掩盖缺口，太细则无法对应一句需求。带上原文摘录，后续被质疑"这条用例从哪来的"时可以直接回溯。

3. **判定每条是否可测试**，`testable` 置 false 的（背景叙述、目标声明、术语解释）单独归类，不强行生成用例。
   原因：给不可测项编用例只会制造覆盖率的假象，让真正的缺口被淹没。

4. **为每个可测试点选适用的设计方法**（等价类、边界值、判定表、状态迁移、正交、场景法）。
   **方法的适用信号、必需产出、常见反模式在 `references/methods.json`（唯一来源）**，人读说明见 `references/design-methods.md`。
   选完把方法编号写进 `coverage_matrix[].methods_applied[]`，**并在下一步用脚本核验**——方法"用没用"不是声明出来的，是脚本在用例集里找得到对应产出才算数。
   原因：凭直觉罗列用例容易只覆盖"顺利路径"；每种方法对应一类系统性遗漏，选方法等于决定这轮能发现哪类缺陷。而 `methods_applied` 只是个字符串列表，写上编号不产生任何用例，光靠自觉填等于没填。

5. **按覆盖维度清单补齐**：功能 / 边界 / 异常 / 权限 / 数据 / 并发 / 性能 / 兼容。维度取值与逐维度检查清单见 `references/coverage-dimensions.md`，各维度的适用信号与跳过理由要求在 `references/dimensions.json`。
   维度不适用的，在 `coverage_matrix[].skipped[]` 里写明维度与理由（跳过必须留痕），不要静默跳过。
   原因：维度清单是查漏网用的统一视角，每个维度都问一遍"这一条适用吗"，比凭经验想更容易发现被忽略的维度。

6. **先拿骨架，再填内容**：
   ```
   node scripts/validate-cases.mjs --init > cases.json
   ```
   `--init` 输出的是**字段齐备的 schema v2 骨架**（`schema_version` / `meta` / `requirements[]` / `open_questions[]` / `coverage_matrix[]` / `cases[]` 全部到位），骨架里的 `<...>` 是占位符，逐个替换成真实内容再往下填。
   原因：只把字段清单写进文档，仍然是在靠模型的自觉填全字段——而 REQ-001 的实测已经证死了这个失败模式（模型会自信地少写一半，然后宣称"覆盖完整"）。从骨架往里填，"字段齐备"才是结构保证而不是叮嘱。字段语义见 `references/case-schema.md`：编号 `TC-001` 递增，每条用例写清 `action` 与 `expected`，`requirement_refs` 指向它验证的条目。
   原因（续）：`expected` 写不出可判定结果的用例，等于没有验证点，后续执行时也无法判断通过与否。

7. **运行校验脚本**，不通过就修复后重跑：
   ```
   node scripts/validate-cases.mjs cases.json
   ```
   原因：JSON 里的错漏（ID 重复、悬空引用、枚举取值写错）靠肉眼看几乎必然漏掉；脚本的退出码是"能不能交付"的客观门槛。
   **注意**：`cases.json` 顶层必须写 `"schema_version": 2`。不写这一行，校验器按 v1 宽松规则处理，缺 `open_questions` / `coverage_matrix` / `cases[].method` / `cases[].status` **只报 WARN、退出码仍是 0**——强制就等于没有。声明了 `2`，同样情形一律升级为 ERROR（退出码 1）。

8. **核验方法使用与维度适用性**（必做，与第 7 步同样硬）：
   ```
   node scripts/check-methods.mjs cases.json
   ```
   原因：`methods_applied` 只是声明，脚本才会到用例集里找该方法的必需产出（"用了 M0.2"必须能在用例集里找到边界值用例）。这一步是"声明"变成"可核验事实"的唯一入口。
   **三类结论的后果**：
   - **ERROR**：产出确实缺失，是可机械判定的事实 → **必须修**，修完重跑直到退出码 0；
   - **WARN**：适用性存疑，是主观判断 → 退出码仍为 0，但**必须在报告里说明**（写清为什么这条不适用/为什么用这个方法），不得静默忽略；
   - **无法判定**：证据不足（例如 `steps[].expected` 是人读字符串，脚本无法比较期望取值） → 单独一类，**既不算通过也不算失败**，必须写进报告并说明缺什么证据。
   **判不了不等于通过**：把 `expected` 写成结构化断言对象（`{ "path": ..., "op": ..., "expected": ... }`，见 `references/case-schema.md`）才能让脚本真正核验取值区分度。

9. **渲染报告与追溯矩阵**：
   ```
   node scripts/render-report.mjs cases.json
   ```
   原因：追溯矩阵是向需求方证明"每条需求都有用例"的凭据，也是暴露覆盖缺口的唯一视图。

10. **汇报覆盖情况**：给出需求条目总数、可测试条目数、用例总数、维度分布，并明确列出**未被覆盖的需求条目 ID** 与**未决问题**（需求本身的歧义、缺失的前置条件、口径未确认的点），以及第 8 步的 WARN 与无法判定项。
    原因：发现需求缺陷是这套流程的主要价值之一；把歧义写成自己的假设会让缺陷永久消失，而假设一旦被下游当成需求，就再也找不回来了。

11. **项目同时携带 `test-assets/` 时**：按 `references/project-layout.md` 摆放测试资产，再跑 `node scripts/verify-layout.mjs <project-root>`；轮次状态用 `node scripts/cycle-state.mjs` 推进（详见下一节）。
    原因：布局与状态字段有独立的机器契约，靠肉眼看不出"字段齐了但取值非法"这类问题；而状态一旦与 `history` 对不齐，后面的证据链就不可信。

## Test assets and cycle state scripts

本 skill 还带了两条围绕用例集的契约脚本。**项目里有 `test-assets/` 时才需要用**；脚本只读或只写自己的状态文件，不会碰用例集。

| 脚本 | 何时调用 | 命令 |
|---|---|---|
| `scripts/validate-cases.mjs` | 产出用例集时（先拿骨架） / 交付前校验 | `node scripts/validate-cases.mjs --init > cases.json`；`node scripts/validate-cases.mjs cases.json` |
| `scripts/check-methods.mjs` | 选完方法、写完用例后 / 交付前核验方法使用与维度适用性 | `node scripts/check-methods.mjs cases.json`；`node scripts/check-methods.mjs cases.json --json` |
| `scripts/verify-layout.mjs` | 摆好测试资产（环境 / 套件 / 轮次目录）之后 | `node scripts/verify-layout.mjs <project-root>` |
| `scripts/cycle-state.mjs` | 推进轮次状态、记录跳过的 scope、设置阶段状态 | `node scripts/cycle-state.mjs <子命令> <轮次目录> [参数...] [--json]` |

## 方法与维度核验：`check-methods.mjs`

方法选择与维度适用性**一律走脚本**，不在这里凭文字判断。方法库（`references/methods.json`）是唯一来源，
本文档不重复方法规则，只讲怎么调。

**可直接复制的完整调用序列**：

```console
# 1) 先自检方法库与维度库本身（方法库被改过时跑一次即可）
node scripts/check-methods.mjs --methods references/methods.json --dimensions references/dimensions.json

# 2) 确认说明文档与方法库一致（改了 methods.json 就要跑）
node scripts/check-methods.mjs --methods references/methods.json --doc references/design-methods.md --check-doc

# 3) 核验用例集里"方法是否真的用了"（必做）
node scripts/check-methods.mjs cases.json

# 4) 机器可读结论（接入流水线时用；stdout 只有 JSON）
node scripts/check-methods.mjs cases.json --json
```

退出码语义与其它脚本一致：`0` = 无 ERROR（可能有 WARN 与无法判定），`1` = 有 ERROR（**必须修**），`2` = 调用方式错误。
`--json` 时 stdout 只有 JSON（含用法错误场景），字段契约见 `references/case-schema.md` 与需求 F5.1：
`ok` / `command` / `exit_code` / `summary{errors,warnings,undecidable}` / `errors[]` / `warnings[]` / `undecidable[]` / `verdicts[]`。

`verdicts[]` 覆盖每一条「需求条目 × 方法」组合，`status` 只取
`satisfied` / `missing_output` / `undecidable` / `suspect` / `not_applicable`。
**落在 `undecidable` 的组合，其 `status` 绝不是 `satisfied`**——判不了不等于通过。

`cycle-state.mjs` 的**五个子命令**（参数与状态转移表见 `references/state-machine.md`）：

| 子命令 | 作用 | 关键参数 |
|---|---|---|
| `init` | 创建新轮次骨架 | `--cycle-id` `--round` `--round-type` `--requirement` `--scope`（可重复） `--by` |
| `show` | 读当前状态：status / history / stages / **允许的下一步** | 轮次目录 |
| `advance` | 推进轮次状态 | `--to <状态>` `--by <agent>` `[--reason <文本>]` |
| `skip-scope` | 记录本轮跳过的 scope | `--scope <scope>` `--reason <文本>` `--by <agent>` |
| `set-stage` | 设置阶段状态 | `--stage <名称>` `--status <状态>` `[--artifacts a,b]` |

**可直接复制的完整调用序列**：

```console
# 1) 开一轮
node scripts/cycle-state.mjs init test-assets/cycles/R1-REQ-001 \
  --cycle-id R1-REQ-001 --round R1 --round-type new-requirement \
  --requirement REQ-001 --scope functional --by dev-agent-1

# 2) 开工
node scripts/cycle-state.mjs advance test-assets/cycles/R1-REQ-001 --to in_progress --by dev-agent-1

# 3) 推进阶段
node scripts/cycle-state.mjs set-stage test-assets/cycles/R1-REQ-001 --stage design --status done

# 4) 记录不跑的范围（必须给理由与执行者）
node scripts/cycle-state.mjs skip-scope test-assets/cycles/R1-REQ-001 \
  --scope load --reason "需求未给性能指标，无阈值可依" --by dev-agent-1

# 5) 收工
node scripts/cycle-state.mjs advance test-assets/cycles/R1-REQ-001 --to completed --by dev-agent-1 --reason "R1 全部用例执行完毕"

# 6) 随时查当前状态与下一步
node scripts/cycle-state.mjs show test-assets/cycles/R1-REQ-001 --json
```

配套文档：

- `references/project-layout.md` —— 目录契约与字段表（环境配置 / 执行配置 / `cycle.json`）。校验器怎么判，依据就是这份文件。
- `references/state-machine.md` —— 轮次状态转移表、终态、推进器全部子命令与原子性规则。
- `references/design-methods.md` —— 6 种方法的适用信号、必需产出与反模式（人读说明；判定依据是 `references/methods.json`）。
- `references/dimensions.json` —— 8 个覆盖维度的适用信号与跳过理由要求。

**硬约束：状态文件只由脚本写。** `cycle.json` 与 `cycles/index.json` **不得直接编辑**，状态推进一律走 `cycle-state.mjs`：它先校验前置状态合法性，再原子写入（临时文件 + rename），并让 `status` 与 `history` 在同一次写入里保持自洽；索引写失败时会回滚 `cycle.json`，不留"轮次已推进、索引没跟上"的脱同步。手改两处必然对不齐，而对不齐的状态会让后续轮次的证据链整条作废。

三个脚本的退出码语义一致：`0` = 成功，`1` = 校验失败或非法转移，`2` = 调用方式错误。**失败时目标文件不会被修改**，按报错里的文件路径与字段路径修完再重跑。`--json` 模式下 stdout 只有 JSON（agent 可直接 `JSON.parse`），包括用法错误这种场景。

## Output contract

- **用例集 JSON**（单个文件），**必须声明 `"schema_version": 2`**，结构与字段语义见 `references/case-schema.md`：
  - `schema_version`：`2`。**必须写这一行**——不写就按 v1 宽松规则校验，缺 `open_questions` / `coverage_matrix` / `cases[].method` / `cases[].status` 只报 WARN、退出码仍是 0，四项强制等于没生效；写上 `2`，同样情形一律升级为 ERROR（退出码 1）。
  - `meta`：`source`（需求来源标识）、`generated_at`（ISO-8601）、`case_count`（用例总数）
  - `requirements[]`：`id`、`title`、`source_ref`、`testable`
  - `open_questions[]`（v2）：`id`（`Q1` 起）、`question`、`requirement_refs[]`、`interpretations[{reading, impact}]`（**至少 2 条**——只列一种解读等于替需求方做了裁定）、`affected_cases[]`、`severity`（`blocking` / `non-blocking`）、`coverage`（`cases` / `deferred`，`deferred` 时须给 `defer_reason`）
  - `coverage_matrix[]`（v2）：`requirement`、`methods_applied[]`、`skipped[]`（**跳过方法或维度都必须写 reason**，空理由即 FAIL）、`dimensions[]`
  - `cases[]`：`id`、`title`、`requirement_refs[]`、`dimension`、`priority`、`method[]`（v2）、`status`（v2：`active` / `deprecated` / `modified` / `blocked`）、`revision`（`status` 非 `active` 时必填）、`preconditions[]`、`steps[{action, expected}]`、`data`、`tags[]`
- **Markdown 报告**（`render-report.mjs` 的 stdout）：用例总览表、追溯矩阵（需求条目 → 覆盖用例 ID → 覆盖状态）、未覆盖需求条目清单、未决问题、覆盖矩阵。
- **覆盖汇报**：未覆盖需求条目 ID 列表 + 未决问题列表 + `check-methods.mjs` 的 WARN 与无法判定项，三项都不能省略。

## Failure handling

- **校验脚本报错**：按它列出的问题逐条修 JSON，修完重跑再交付。连续两轮仍有同类错误，说明生成逻辑（例如维度映射、编号规则）有偏差，先回看 `references/case-schema.md` 与 `references/coverage-dimensions.md`，不要继续手改 JSON。
- **`check-methods.mjs` 报 ERROR**：声明了方法却没有对应产出，属实打实缺东西——**必须修**（补用例，或把方法从 `methods_applied` 里去掉并写进 `skipped[]` 加 reason），修完重跑直到退出码 0。
- **`check-methods.mjs` 报 WARN**：适用性存疑，脚本不替人拍板——**必须在报告里说明**为什么这样判断（漏用了方法就补上并说明依据；不适用就写进 `skipped[]` 带 reason），不得静默忽略。
- **`check-methods.mjs` 报无法判定**：证据不足（如 `expected` 写成了人读字符串），既不算通过也不算失败——写进报告，并把 `expected` 改成结构化断言对象，让脚本能真正核验。
- **需求有歧义或缺前置条件**：写进未决问题清单，列出你的两种以上可能理解与各自影响，请需求方裁定；不要自行选定一种然后当成既定事实。
- **需求条目拆不出来 / 粒度明显不对**：回到第 2 步重新拆，或请用户补充上下文。用例集对不上需求原文时，多半是条目拆错了，而不是用例写得少。
- **某个维度确实不适用**（如纯离线批处理任务没有并发语义）：在 `coverage_matrix[].skipped[]` 里写明维度与理由，让不覆盖成为显式决定而不是空白。
- **文件读不到 / JSON 语法错误**：原样把错误信息报给用户并停止，不要凭空修补一个损坏的用例集。
- **覆盖缺口过大**（多数可测试条目没有用例）：说明缺的是输入信息还是设计工作量，并给出补齐建议，而不是交付一个"结构合法但覆盖稀薄"的集合。

## Examples

输入（需求原文片段）：

> 用户密码最少 8 位，最多 20 位，必须同时包含字母和数字；连续 5 次输错锁定账号 15 分钟。

拆解与产出要点：

- 需求条目：`R-1` 密码长度 8–20 位；`R-2` 必须含字母与数字；`R-3` 连错 5 次锁定 15 分钟。
- `R-1` 用边界值法生成 `boundary` 维度用例：长度 7（拒绝）、8（接受）、20（接受）、21（拒绝）；`methods_applied` 写 `["M0.2"]`，期望结果各不相同。
- `R-2` 用等价类 + 判定表生成 `functional` 维度用例：纯数字、纯字母、字母+数字；规则组合用判定表覆盖"只有字母""只有数字""两者都有"。
- `R-3` 用状态迁移生成 `exception` 维度用例：错误次数 4→5 的迁移点、锁定后第 6 次输入、15 分钟到期后第 1 次输入。
- 交付前跑 `node scripts/validate-cases.mjs cases.json`、`node scripts/check-methods.mjs cases.json` 与 `node scripts/render-report.mjs cases.json`，把追溯矩阵里"未覆盖"一栏为空、且 `check-methods.mjs` 没有 ERROR 的结果，连同未决问题一起交给需求方；WARN 与无法判定项在报告里逐条说明。

## Windows (win32) platform notes

- 全部脚本都是纯 Node.js，直接用 `node scripts/validate-cases.mjs cases.json`、`node scripts/check-methods.mjs cases.json` 调用，PowerShell 与 cmd 下行为一致。
- 路径交给 Node 解析（脚本内部走 `path.resolve`），不要写死盘符或类 Unix 绝对路径。
- 临时文件放在当前工作目录下的子目录里（例如 `./tmp-cases/`），不要假定系统存在类 Unix 临时目录。
