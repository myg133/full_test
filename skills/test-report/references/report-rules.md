# 报告的判定规则

> 本文件是**规则**，不是说明材料：实现照这里判定，判据照这里核。
> 字段契约见 `report-schema.md`。

---

## 一、三层结论（不得混为一谈）

一次执行的结果有三层，**任何一层没过，整体结论就不能是"通过"**：

| 层 | 问什么 | 数据来源 | 不过的样子 |
|---|---|---|---|
| **用例层** | 跑的那些用例判定如何 | `results.json` 的 `status` 分布 | 有 `failed` / 有 `blocked` |
| **流程层**（报告里叫「证据层」） | 这份产物本身可信吗 | 证据实查 + 计数重算 + 指纹重算 | 证据链不自洽（被改过 / 丢失 / 计数造假） |
| **对账层**（计划，可选） | 该跑的有没有都跑 | `regression-plan.json` ∩ `results.json` | 有漏跑 / 有待复核 / 有变更判不了 |

**混为一谈的后果**：把 `blocked`（不可判定）算成"全通过"，是把"没测"记成"测过且通过"。

### 1.1 用例层 `verdict.case_layer`

| 条件 | `case_layer` |
|---|---|
| `cases.failed > 0` | `fail` |
| `cases.failed == 0` 且 `cases.blocked > 0` | `incomplete` |
| 其余 | `pass` |

五个计数（`total` / `passed` / `failed` / `blocked` / `skipped`）**全部从 `results.json` 逐条重算**，
**不信 `meta.json` 的自述**。`meta.json` 的计数只用来**对账**（不符就出一条 `count_mismatch`）。

### 1.2 证据层 `verdict.evidence_layer`

| 条件 | `evidence_layer` |
|---|---|
| `evidence.findings` 非空 | `fail` |
| `evidence.findings` 为空 | `pass` |

`findings` 的四类 `kind`：

| `kind` | 什么时候报 | `message` 必须点名 |
|---|---|---|
| `missing_evidence` | 证据文件**缺失**（`results.json` 声称有、文件实况没有） | 缺失的路径 |
| `evidence_mismatch` | 证据文件**存在但内容与记录不符**（实算 sha256 ≠ 记录值，或字节数不符） | 被改的证据路径 + 记录值 + 实算值 |
| `count_mismatch` | `meta.json` 的某个计数与重算值不符 | 哪个计数 + meta 记的是多少 + 实际是多少 |
| `fingerprint_mismatch` | 重算的 `results_sha256` / `evidence_manifest_sha256` 与 `meta.json` 记录值不符 | 哪个指纹 + 记录值 + 重算值 |

`files_present` / `files_missing` 的口径：`results.json` **声称**的证据条目里，
实查**存在** / **缺失**的份数。`blocked` / `skipped` 用例的证据**同样计入**（不排除）。

### 1.3 对账层 `verdict.regression_layer`

**不给计划**时：`regression` 段为 `null`，`regression_layer == "not_applicable"`，
md 里**不得**出现任何断言回归状态的措辞（不给就不编造）。

**给了计划**时：

| 条件 | `regression_layer` |
|---|---|
| `selected_missing` 非空（有漏跑） | `fail` |
| `needs_review_planned > 0`（待人工复核） | 至少 `incomplete`（**不得**为 `pass`） |
| `impact_complete == false`（有变更判不了） | 至少 `incomplete` |
| 其余 | `pass` |

### 1.4 总体结论 `verdict.overall`

| 条件 | `overall` |
|---|---|
| 任一层是 `fail` | `fail` |
| 用例层 `incomplete` / 证据层 `unknown` / 对账层 `unknown` / 对账层 `incomplete` | `incomplete` |
| 三层全部 `pass`（或对账层 `not_applicable`） | `pass` |

**自洽不变式**：`overall == "pass"` ⇒ `cases.failed == 0` ∧ `cases.blocked == 0` ∧
`evidence_layer == "pass"` ∧（给计划时）`regression_layer ∈ {pass, not_applicable}` ∧
`regression.impact_complete == true`。

---

## 二、回归对账的判定

给定 `regression-plan.json`：

| 对账项 | 判定 |
|---|---|
| `selected_planned` | `plan.selected.length` |
| `selected_executed` | `plan.selected[].case_id` ∩ 实际出现的 `case_id` 的条数 |
| `selected_missing` | `plan.selected[].case_id` 减去实际出现的 `case_id`（**逐条点名**） |
| `needs_review_planned` | `plan.needs_review.length`（**数字**） |
| `needs_review_executed` | `plan.needs_review[].case_id` ∩ 实际出现的 `case_id` 的条数（**数字**） |
| `undecidable_changes` | 原样取自计划（`change_id` + `reason`，reason 逐字一致） |
| `impact_complete` | 取自 `plan.summary.impact_complete` |

### 2.1 `skipped` 怎么算

漏跑 = 计划 `selected[]` 减去执行产物 `results.json` 中**出现过**的 `case_id`。

`skipped` 的用例**出现过**（有判定记录）⇒ 算"执行过判定"，**不算漏跑**；
但它显然**不算跑通** —— 报告在失败 / 未通过清单里必须单独呈现。

### 2.2 漏跑必须导向失败

`selected_missing` 非空 ⇒ `regression_layer == "fail"` 且 `overall != "pass"`。
漏跑是回归漏测的直接原因（缺陷逃逸），不得因为"其它都过了"而放过。

### 2.3 `needs_review` 不是通过

计划里 `needs_review` 的用例语义是"这条用例在本次场景下**方法不适用**，需人工复核"。
它们跑通了也**不等于**对账通过 —— 把"待人工复核的用例全绿"报成"对账通过"，
是把"人还没看"记成"人看过且没问题"。

### 2.4 判不了的变更必须呈现

`undecidable_changes` 非空 ⇒ 影响面不完整（`impact_complete == false`）
⇒ `overall` 不得为 `pass`，且 md 必须点名变更 id 与原因。

---

## 三、诚实性红线

1. **不可判定不虚报通过**：`blocked` 计入 `blocked`，**绝不**计入 `passed`；`overall` 不得为 `pass`。
2. **证据不自洽不出可信结论**：证据层校验失败时 `evidence_layer == "fail"`，`overall` 不得为 `pass`；
   md 必须显示**具体原因**（逐条渲染 `findings`），笼统的"证据链校验失败"不算呈现。
3. **计数以重算为准**：`meta.json` 的五个计数与 `results.json` 实际分布不符 →
   报告必须显示"计数不符"（点名哪个计数、meta 值、实际值）并判 `evidence_layer == "fail"`；
   但 `cases.*` **仍然**按 `results.json` 重算（报告给出的数 vs 报告给出的评价，是两回事）。
4. **证据文件必须实查**：`results.json` 说了有不算数；缺失必须列出路径。
5. **不编造**：报告里的每个数字都能从输入产物重算；`reproduction` **逐字**取自 `results.json`，
   不得改写或摘要失真；报告里出现的每个用例 id / 变更 id 都必须来自输入。
6. **报告自身可核**：自带 `report_sha256`，且**绑定**输入产物的两个指纹。
7. **只读输入、只写自己的目录**：绝不改输入产物里的任何既有文件；只写 `--out-dir`（默认 `<run_dir>/report/`）。
8. **幂等**：同一份产物 + 同一份计划，两次出报告**除 `generated_at` 外逐字相同**（含 `report_sha256`）。

---

## 四、输入非法时的行为

| 情形 | 退出码 | 输出 |
|---|---|---|
| 产物目录不存在 / 不是目录 | `1` | 点名是哪个目录坏了 |
| `meta.json` 缺失 / 不是合法 JSON / 根节点不是对象 | `1` | 点名是哪个文件坏了 |
| `results.json` 缺失 / 不是合法 JSON / 根节点不是数组 | `1` | 点名是哪个文件坏了 |
| 回归计划文件缺失 / 不是合法 JSON | `1` | 点名是哪个文件坏了 |
| 命令行用法错（缺 `--artifacts`、未知参数） | `2` | 打印用法 |

**任何输入非法都不得产出半份报告** —— 校验与计算全部通过之后才落盘。
