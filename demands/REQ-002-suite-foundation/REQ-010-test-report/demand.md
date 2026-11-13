# REQ-010 —— 报告能力域：`test-report` skill（执行报告 + 回归对账）

- **需求编号**: REQ-010
- **优先级**: P1
- **状态**: 草稿
- **原编号**: `REQ-002.10`（架构文档 §8 的编号映射）

## 0. 为什么是现在做这件事

REQ-011 收口后，套件的能力链是：**能设计用例 → 能选样 → 能执行 → ❌ 没人出报告**。

| 环节 | 状态 | 缺口 |
|---|---|---|
| 设计（R1） | ✅ `test-case-design`（11 维度 / 9 方法 / 42 条判据） | — |
| 回归选样（R2） | ✅ `regression-plan`（28 条判据，`regression-plan.json`） | — |
| 执行 | ✅ `test-execute`（证据链 + sha256 指纹 + 脱敏） | — |
| **报告** | ❌ **无** | 执行产出了 `meta.json` / `results.json` / `evidence/`，但**没有任何 skill 消费它们** |
| 缺陷复现（R3） | ❌ 无 | 排在后面（REQ-007） |

现有的 `test-case-design/scripts/render-report.mjs` **不是**执行报告 ——
它读的是**用例集**（`cases.json`），出的是覆盖率与追溯矩阵（设计侧视角）。
**执行侧的产物至今无人消费**：`meta.json` 里那五个计数、每条用例的 `reproduction`、
证据目录、指纹、`redaction` 留痕，全部要靠人自己去翻目录看。

REQ-011 又把这条链拉长了一节：`regression-plan.json` 说"这 60 条要重跑"，
执行产物说"我跑了 58 条"。**这两个数对不上意味着回归漏测 —— 而没有任何工具会发现它。**

### 0.1 报告的价值不在"好看"，在"可核验"

一份报告如果只是把 `results.json` 换个格式贴出来，它的信息量等于零。
它的价值来自三件事，且每一件都必须**可机械核验**：

1. **可信度**：这份产物有没有被改过 → 证据链校验结论必须进报告；
2. **对账**：计划要跑的和实际跑的对不对得上 → 漏跑的必须点名；
3. **可复现**：失败的那条怎么复现 → `reproduction` 必须落到报告里，且**逐字**。

### 0.2 为什么报告本身也要有指纹

REQ-004 已经确立了"产物即证据"的纪律（`results_sha256` / `evidence_manifest_sha256`）。
但**报告本身**是新的产物 —— 一份可以被事后编辑的报告，等于没有报告。
所以报告必须：

- 自带 `report_sha256`（对自身内容算，排除 `generated_at`）；
- **绑定**输入产物的 `results_sha256` 与 `evidence_manifest_sha256`（可核对"这份报告对应哪一次执行"）；
- 报告里的每个数字都必须能从输入产物**重算**出来（不许手写）。

## 1. 目标

1. 交付 **`test-report` skill**（第 5 个 skill）：读执行产物 → 产出**执行报告**（`report.json` + `report.md`）。
2. 报告支持**回归对账**：给定时消费 `regression-plan.json`，把"计划要重跑的"与"实际跑了/没跑"逐条对账，**漏跑必须点名**。
3. 报告的每个数字、每条结论都**可从输入产物重算**，且报告自带指纹、绑定输入产物指纹。

### 1.1 三层结论不得混为一谈（核心）

一次执行的结果有三层，**任何一层没过，整体结论就不能是"通过"**：

| 层 | 问什么 | 数据来源 | 不过的样子 |
|---|---|---|---|
| **用例层** | 跑的那些用例判定如何 | `results.json` 的 `status` 分布 | 有 `failed` / 有 `blocked` |
| **流程层** | 这份产物本身可信吗 | `verify-evidence.mjs` 的结论 + `meta.json` 的指纹 | 证据链不自洽（被改过/丢失/计数造假） |
| **回归层**（可选） | 该跑的有没有都跑 | `regression-plan.json` ∩ `results.json` | `selected` 里有没跑的、判不了条目未处理 |

**混为一谈的后果**：把 `blocked`（不可判定）算成"全通过"，是把"没测"记成"测过且通过"——
这与 REQ-004 的诚实纪律（不可判定判 `blocked` 绝不判 `passed`）和 REQ-011 的 D45 口径直接冲突。

### 1.2 为什么"回归对账"是本 REQ 的独有价值

没有 `regression-plan.json` 时，执行报告只是"这次跑了什么"；
**有了**它，报告才能回答"该跑的有没有都跑"：

| 情形 | 报告必须说什么 |
|---|---|
| `selected` 里的用例全跑了 | 回归覆盖完整 |
| `selected` 里有没跑的 | **点名哪些没跑**（漏测 —— 回归漏测是缺陷逃逸的直接原因） |
| `needs_review` 里的用例跑了 | 标注"这批是待人工复核的用例"（它们的结论不等于回归通过） |
| `undecidable_changes` 非空 | **影响面不完整** —— 有变更判不了，**不得**给出"回归通过"结论 |
| `impact_complete: false` | 同上，且必须显示判不了的条目与原因 |

⚠️ **不给 `--regression-plan` 时，报告不得编造回归层结论**（更不得显示"回归层：未提供计划"以外的任何暗示）。

## 2. 功能项

### F1 `test-report` skill 的位置与入口

- 位置：`skills/test-report/`（第 5 个 skill）
- 结构：`SKILL.md` / `skill-meta.json` / `references/report-schema.md` / `references/report-rules.md` / `scripts/make-report.mjs` / `scripts/check-report.mjs` / `scripts/lib/*`
- 入口命令：
  ```bash
  node skills/test-report/scripts/make-report.mjs --artifacts <run_dir> [--regression-plan <file>] [--out-dir <dir>]
  ```
  - `--artifacts`：执行产物目录（`.test-artifacts/<run_id>/`），必填；
  - `--regression-plan`：回归计划文件，可选；
  - `--out-dir`：报告输出目录，默认 `<run_dir>/report/`。
- 校验入口：`node skills/test-report/scripts/check-report.mjs <report.json>`（自洽校验器）

### F2 输入契约（只读消费）

| 输入 | 必填 | 来源 | 报告怎么用 |
|---|---|---|---|
| `<run_dir>/meta.json` | 是 | `test-execute` 的执行外壳 | 计数、指纹、环境、脱敏留痕、轮次推进结果 |
| `<run_dir>/results.json` | 是 | 同上 | 逐条用例判定、复现信息、错误 |
| `<run_dir>/evidence/` | 是（目录） | 同上 | **逐条核对证据文件是否存在**（不信 `results.json` 的自述） |
| `<run_dir>/logs/runner.log` | 否 | 同上 | 可选引用 |
| `regression-plan.json` | 否 | `regression-plan` skill | 回归对账 |
| `cases.json` | 否 | 用例集 | 补 `needs_review` 之外的上下文（可选） |

**硬约束**：
1. **只读** —— 报告 skill **绝不写**输入产物目录里的任何既有文件（`meta.json` / `results.json` / `evidence/` / `logs/` 一律不改）。
2. **不校验证据链就不出"可信"结论** —— 报告必须**实跑** `verify-evidence.mjs`（或复算其判定），把结论写进报告；不得假设产物可信。
3. **计数以 `results.json` 实际内容重算**，不信 `meta.json` 的自述；两者不符 → 报告必须显示"计数不符"（这正是 REQ-004 校验器要抓的"计数造假"）。

### F3 输出契约：`report.json`

顶层结构（字段名固定，便于机械核验）：

```jsonc
{
  "schema_version": 1,
  "generated_at": "2026-11-13T00:00:00Z",   // 幂等自验时唯一允许变动的字段
  "source": {
    "artifacts": "<run_dir 路径>",
    "run_id": "<meta.run_id>",
    "suite": "<meta.suite>",
    "requirement": "<meta.requirement>",
    "environment": "<meta.environment>",
    "started_at": "<meta.started_at>",
    "finished_at": "<meta.finished_at>",
    "results_sha256": "<meta.results_sha256>",
    "evidence_manifest_sha256": "<meta.evidence_manifest_sha256>",
    "regression_plan": "<路径或 null>"
  },
  "cases": {
    "total": 0, "passed": 0, "failed": 0, "blocked": 0, "skipped": 0,
    "duration_ms_total": 0
  },
  "verdict": {
    "case_layer": "pass|fail|incomplete",   // 用例层
    "evidence_layer": "pass|fail|unknown",  // 流程层（证据链）
    "regression_layer": "pass|fail|not_applicable|unknown", // 回归层
    "overall": "pass|fail|incomplete"       // 总体结论（见 F3.1）
  },
  "failures": [ /* 每条 failed/blocked 用例：case_id / title / status / error / reproduction / evidence */ ],
  "evidence": { "files_present": 0, "files_missing": 0, "missing_paths": [] },
  "regression": {                        // 未提供计划时为 null
    "selected_planned": 0, "selected_executed": 0, "selected_missing": [],
    "needs_review_planned": 0, "needs_review_executed": 0,
    "undecidable_changes": [ { "change_id": "...", "reason": "..." } ],
    "impact_complete": true
  },
  "report_sha256": "<64 位十六进制>"       // 对本文件内容算（排除 generated_at 与本字段）
}
```

### F3.1 总体结论 `overall` 的推导（机械可核验）

| 条件 | `overall` |
|---|---|
| 三层全部 `pass`（或回归层 `not_applicable`） | `pass` |
| 用例层有 `failed`，或流程层 `fail`，或回归层 `fail` | `fail` |
| 其余（用例层有 `blocked`、流程层 `unknown`、回归层 `unknown`、或影响面不完整） | `incomplete` |

**硬约束**：`overall` **不得**是 `pass`，当且仅当以下任一成立：
- 有任何用例 `status == "failed"`；
- 证据链校验不通过（`evidence_layer != "pass"`）；
- 提供了回归计划但 `selected` 有漏跑（`regression_layer == "fail"`）；
- 提供了回归计划但 `impact_complete == false`（有判不了的变更）。

⚠️ **`blocked` 一律导向 `incomplete`，绝不导向 `pass`**（对齐 REQ-004 的诚实纪律）。
⚠️ **`overall == "pass"` 时，`failed` / `blocked` 计数必须都是 0**（自洽不变式）。

### F4 `report.md`（人读）与 `report.json` 的一致性

- `report.md` 是 `report.json` 的**渲染**，不是独立内容。
- **硬约束**：md 里的每个数字必须与 `report.json` **逐字相等**（计数、结论、漏跑条数、判不了条数）。
- md 必须**点名**（不许只写"有 2 条漏跑"）：漏跑的用例 id、失败的用例 id 与错误摘要、判不了的变更 id 与原因。
- md 必须显示报告绑定的输入指纹（`results_sha256` 前缀）+ 报告自身指纹（`report_sha256`）。

#### F4.1 机器可读摘要行（`report-digest`）

「数字逐字相等」若没有**可机械抽取的落点**，就只能靠人眼比对 —— 那等于没有约束（D50）。因此 `report.md` 必须含**一行**机器可读摘要：

```
<!-- report-digest: cases.total=5; cases.passed=2; cases.failed=1; ... -->
```

- 格式：**单行**，以 `<!-- report-digest: ` 开头、以 ` -->` 结尾；键值对之间用 `; `（分号 + 空格）分隔。
- 每个键是 `report.json` 里的**点号路径**（如 `cases.total` / `verdict.overall` / `regression.selected_missing`），其值与 `report.json` 中**同名路径**的值**逐字相等**（数组用逗号连接其元素，顺序敏感）。
- 必须**至少**覆盖这 12 个键：`cases.total` / `cases.passed` / `cases.failed` / `cases.blocked` / `cases.skipped` / `verdict.case_layer` / `verdict.evidence_layer` / `verdict.regression_layer` / `verdict.overall` / `source.results_sha256` / `source.evidence_manifest_sha256` / `report_sha256`。
- md **正文**里出现的关键数字（总数 / 各状态数 / 漏跑条数 / 待复核条数 / 判不了条数）必须与摘要一致。

摘要行是 md 的**渲染契约**，也是验收脚本唯一的数字比对落点（AC-011）。

### F5 回归对账的判定（可选层）

给定 `regression-plan.json`：

| 对账项 | 判定 |
|---|---|
| `selected_missing` | `plan.selected[].case_id` 减去 `results.json` 里**实际出现过**的 `case_id`（含 `skipped` —— skipped 表示"判了不执行"，算**执行过判定**但不算"跑通"） |
| `needs_review_executed` | `plan.needs_review[].case_id` 与实际结果 id 集合的**交集条数**（**数字**，不是数组） |
| `undecidable_changes` | 原样取自计划，且 `reason` 必须非空 |
| `impact_complete` | 取自 `plan.summary.impact_complete` |

**硬约束**：
1. **漏跑必须点名**（`selected_missing` 列出每个 `case_id`），且 `selected_missing` 非空 → `regression_layer = "fail"`。
2. `needs_review` 里的用例**即使全通过**，也不得让 `regression_layer` 变成 `pass` —— 它们**需要人工复核**，不是"回归通过"。判法：`needs_review_planned > 0` 时 `regression_layer` 至少是 `incomplete`。
3. `impact_complete == false` → `regression_layer` 至少是 `incomplete`，且 `overall` 不得是 `pass`。
4. **计划里的 `case_id` 若不在本次执行产物里**，一律算 `selected_missing`（漏跑），不得因为"用例集里没有"就放过。
5. **未提供 `--regression-plan` 时**，`regression` 段为 `null`、`regression_layer = "not_applicable"`，且 md 里**不得**出现"回归通过/回归完整"这类措辞。

### F6 诚实性要求（本 REQ 的红线）

1. **不可判定不虚报通过**：`blocked` 用例计入 `blocked`，**绝不**计入 `passed`；`overall` 不得为 `pass`。
2. **证据不自洽不出可信结论**：证据链校验失败时 `evidence_layer = "fail"`，`overall` 不得为 `pass`；md 必须显示校验失败的具体原因。
3. **计数以重算为准**：`meta.json` 的五个计数与 `results.json` 实际分布不符 → 报告必须显示"计数不符"并判 `evidence_layer = "fail"`。
4. **证据文件必须实查**：报告要**逐条核对** `evidence/` 下的文件是否存在（`results.json` 说了有不算数）；缺失必须列出路径。
5. **不编造**：报告里的每个数字都能从输入产物重算；`reproduction` 逐字取自 `results.json`，**不得改写或摘要失真**。
6. **报告自身可核**：自带 `report_sha256`，且**绑定**输入产物的两个指纹。

### F7 写入权与幂等

1. **写自己的**：报告只写 `--out-dir`（默认 `<run_dir>/report/`），**绝不改**输入产物的既有文件。
2. **幂等**：同一份产物 + 同一份计划，两次出报告，**除 `generated_at` 外逐字相同**（含 `report_sha256`）。
3. **不覆盖**：目标文件已存在时**覆盖**（同一次执行重出报告是正常操作），但**不得**覆盖输入产物目录里的任何既有文件。
4. **零第三方依赖 + 不联网**：只用 Node 内置模块（`node:crypto` / `node:fs` / `node:path`）；不得 `fetch`、不得 import 任何非 `node:` 模块。

### F8 套件层组合门（承接 REQ-011）

- `test-report` 加入 `skill-meta.json` 的版本配套体系（`requires` 声明对 `test-execute` 的依赖 —— 它消费执行产物的格式）。
- REQ-011 交付的组合门（`bin/test-agent-skills.mjs verify`）**必须自动覆盖第 5 个 skill**（临时根装齐 5 个 skill、跨 skill 组合场景实跑、版本错配报版本问题）。
- REQ-011 的 28 条判据必须**原样继续全绿**（上游回归）。

## 3. 非目标（明确不做）

1. **不做用例集报告**：`test-case-design/scripts/render-report.mjs` 已覆盖覆盖率与追溯矩阵（设计侧），本 REQ 只做**执行侧**报告，不合并、不重写、不替代它。
2. **不做缺陷复现（R3）**：R3 属 REQ-007；本 REQ 只把 `reproduction` **如实搬运**到报告里，不实现复现调度。
3. **不改执行产物格式**：产物契约属 REQ-004；本 REQ **只读消费**，不改 `meta.json` / `results.json` / `evidence-chain.md` 的任何字段语义。
4. **不做报告的分发/上传**：不推制品库、不贴缺陷单、不发通知。
5. **不做压力/安全域报告**：属 REQ-008 / REQ-009。
6. **不做用例内容的改写**：`regression-plan.json` 只说"这条要改"，**改**的动作留给设计流程（对齐 REQ-011 非目标 5）。
7. **不升 npm 包版本**：沿用 0.1.0。

## 4. 判据要点

> 判据条数与分组在 `acceptance.md` 中固化；本节只列要点，**每条判据必须能证伪**。

- **A 形状**：`test-report` skill 存在且结构合法；`skill-meta.json` 声明版本与依赖；README 清单一致；不破坏既有目录契约。
- **B 解析正确**：从产物重算的计数/状态分布正确；`evidence/` 实查正确；指纹绑定正确。
- **C 一致性**：`report.json` 与 `report.md` 的数字逐字相等；报告内自洽（`report_sha256` 可重算）。
- **D 回归对账**：漏跑点名、`needs_review` 不被当成通过、判不了条目呈现、`impact_complete=false` 时不得判通过。
- **E 诚实性**：`blocked` 不算通过；证据链不自洽不出可信结论；计数不符被抓住；不编造数字。
- **F 可复现/幂等**：同一输入两次出报告逐字相同；输出路径约定；零第三方依赖 + 不联网。
- **G 写入权**：不改输入产物；只写自己的输出目录。
- **H 追溯**：交付侧记账与判据集一致；REQ-011 的追溯件不被改写。

## 5. 验收方式

- 验收脚本：`BA/demands/REQ-002-suite-foundation/REQ-010-test-report/verify-acceptance.sh`
- **一次只跑一个门**（并发跑门会产生无因果关系的失败键）。
- 必须包含**变异体套件**（至少 4 个变异体），证明"实现改错了会被抓住"：
  ① 把 `blocked` 计入 `passed`；② 漏跑不点名（`selected_missing` 恒空）；③ `overall` 在有 failed 时仍给 `pass`；④ 报告数字与产物不符。
- 变异体注入后必须**自证生效**（注入前后 sha256 比对），且**结构合法**（崩溃导致的判红是假检出，不计入）。
- 上游回归：REQ-011 主验收（28 条）、REQ-006 主验收（42 条）、REQ-002A（19 条）、REQ-002B（41 条）必须**原样继续全绿**。

## 6. 与既有 REQ 的关系

| REQ | 关系 |
|---|---|
| REQ-004（`test-execute`） | **上游**：本 REQ 消费它的产物（`meta.json` / `results.json` / `evidence/` / 指纹 / 脱敏） |
| REQ-011（`regression-plan`） | **上游**：本 REQ 消费它的 `regression-plan.json` 做回归对账。⚠️ REQ-011 已裁定 `cycle_id` 与轮次目录名**解耦**（L-4），本 REQ **不得**假定二者一致 |
| REQ-006（`test-case-design`） | **上游回归**：本 REQ 不改 `test-case-design` 的任何文件 → 其 42 条判据必须原样全绿 |
| REQ-002A / 002B | **上游回归**：schema v2 / 目录契约 |
| REQ-002.5a（`cycle-state.mjs`） | `meta.cycle` 段的来源（报告如实呈现，不改写） |
| REQ-007（R3 缺陷复现） | **下游/平行**：R3 消费报告里的失败清单做复现；本 REQ 不实现复现 |
| REQ-008 / REQ-009 | **平行**：压力 / 安全域报告，不在本 REQ 范围 |

## 7. 决策号

本 REQ 的决策号自 **D48** 起（承接 REQ-011 的 D35~D47 —— 全仓已用最大号为 D47）。
