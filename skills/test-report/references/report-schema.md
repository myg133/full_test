# `report.json` 字段契约

> 产出脚本：`scripts/make-report.mjs`；校验脚本：`scripts/check-report.mjs`。
> 产物落在输出目录（默认 `<run_dir>/report/`）：`report.json`（机器读）+ `report.md`（人读）。
>
> ⚠️ 本文件是**契约**，不是说明材料：字段名固定，便于机械核验。
> 判据引用的是本清单（**不得**"schema 里没写就不查"）。

---

## 1. 顶层结构

```jsonc
{
  "schema_version": 1,                 // 固定 1
  "generated_at": "2026-11-13T00:00:00Z", // 幂等自验时**唯一允许变动**的字段
  "source": { /* 这次执行的来源与绑定指纹 */ },
  "cases": { /* 从 results.json 重算的计数 */ },
  "verdict": { /* 三层结论 + 总体结论 */ },
  "failures": [ /* 每条 failed / blocked 用例 */ ],
  "evidence": { /* 证据实查结论 */ },
  "regression": { /* 回归对账；未提供计划时为 null */ },
  "report_sha256": "<64 位十六进制>"     // 对本文件内容算（**排除** generated_at 与本字段）
}
```

顶层**只允许** `schema_version` 这一个数字型叶子字段；除此之外顶层出现任何数字型叶子字段
（如 `total: 42`）都是「凭空捏造」，判红。

## 2. 必填字段清单（完整）

| 字段路径 | 类型 | 说明 |
|---|---|---|
| `schema_version` | number | 固定 `1` |
| `generated_at` | string | ISO-8601 生成时间戳（幂等自验时唯一允许变动的字段） |
| `source.artifacts` | string | 执行产物目录路径 |
| `source.run_id` | string | 取自 `meta.run_id` |
| `source.suite` | string | 取自 `meta.suite` |
| `source.requirement` | string | 取自 `meta.requirement` |
| `source.environment` | string | 取自 `meta.environment` |
| `source.started_at` | string | 取自 `meta.started_at` |
| `source.finished_at` | string | 取自 `meta.finished_at` |
| `source.results_sha256` | string | **重算**的结果指纹（64 位十六进制），非抄 `meta` |
| `source.evidence_manifest_sha256` | string | **重算**的证据清单指纹（64 位十六进制），非抄 `meta` |
| `source.regression_plan` | string \| null | 回归计划文件路径；未提供计划时为 `null` |
| `cases.total` | number | `results.json` 的条数 |
| `cases.passed` | number | `status == "passed"` 的条数 |
| `cases.failed` | number | `status == "failed"` 的条数 |
| `cases.blocked` | number | `status == "blocked"` 的条数（**绝不**计入 passed） |
| `cases.skipped` | number | `status == "skipped"` 的条数 |
| `cases.duration_ms_total` | number | 各条用例 `duration_ms` 之和 |
| `verdict.case_layer` | string | 枚举 `pass` / `fail` / `incomplete` |
| `verdict.evidence_layer` | string | 枚举 `pass` / `fail` / `unknown` |
| `verdict.regression_layer` | string | 枚举 `pass` / `fail` / `incomplete` / `not_applicable` / `unknown` |
| `verdict.overall` | string | 枚举 `pass` / `fail` / `incomplete` |
| `failures[]` | array | 每条 failed / blocked 用例一项 |
| `failures[].case_id` | string | 用例 id |
| `failures[].title` | string | 用例标题 |
| `failures[].status` | string | `failed` 或 `blocked` |
| `failures[].error` | object \| null | `{type, message}`，逐字取自产物 |
| `failures[].reproduction` | object \| null | `{steps, command, expected}`，**逐字**取自产物 |
| `failures[].evidence` | array | 该用例的证据条目，逐字取自产物 |
| `evidence.files_present` | number | 实查**存在**的证据条目份数 |
| `evidence.files_missing` | number | 实查**缺失**的证据条目份数 |
| `evidence.missing_paths` | string[] | 缺失的证据路径（相对产物目录） |
| `evidence.findings` | array | 证据层发现，每条 `{kind, message}` |
| `evidence.findings[].kind` | string | 枚举 `missing_evidence` / `evidence_mismatch` / `count_mismatch` / `fingerprint_mismatch` |
| `evidence.findings[].message` | string | 非空，且**必须点名**（缺失路径 / 被改的证据路径 / 哪个计数 + meta 值 + 实际值） |
| `regression` | object \| null | 未提供计划时为 `null` |
| `regression.selected_planned` | number | 计划 `selected[]` 的条数 |
| `regression.selected_executed` | number | 计划 `selected[]` 与实际出现的 `case_id` 的交集条数 |
| `regression.selected_missing` | string[] | 计划 `selected[]` 减去实际出现的 `case_id`（**逐条点名**） |
| `regression.needs_review_planned` | number | 计划 `needs_review[]` 的条数（**数字**，不是数组） |
| `regression.needs_review_executed` | number | 计划 `needs_review[]` 与实际出现的 `case_id` 的交集条数（**数字**，不是数组） |
| `regression.undecidable_changes` | array | 原样搬运自计划，每项 `{change_id, reason}` |
| `regression.undecidable_changes[].change_id` | string | 变更 id |
| `regression.undecidable_changes[].reason` | string | 非空，与计划**逐字**一致 |
| `regression.impact_complete` | boolean | 取自 `plan.summary.impact_complete` |
| `report_sha256` | string | 64 位十六进制；见 §4 的规范化口径 |

## 3. `cases` 段与 `regression` 段的键集是**封闭**的

- `cases` 段**只允许** 6 个键：`total` / `passed` / `failed` / `blocked` / `skipped` / `duration_ms_total`；
- `regression` 段**只允许** 7 个键：`selected_planned` / `selected_executed` / `selected_missing` /
  `needs_review_planned` / `needs_review_executed` / `undecidable_changes` / `impact_complete`。

多出任何一个键都是「报告里出现了算不出来的数字」，判红。

## 4. `report_sha256` 的规范化口径

`report_sha256` = 对**剔除 `generated_at` 与 `report_sha256` 两个字段后的整个 `report.json`**
做下述规范化后取 sha256：

1. **对象**：键名按**码位升序**排序后拼接（`{"k":v,...}`，无空白分隔符）；
2. **数组**：**保持原顺序**（`[v,v,...]`）；
3. **字符串**：JSON 转义形式；**数字 / 布尔 / null**：JSON 字面量形式；
4. 结果按 **UTF-8** 编码取 sha256，输出小写十六进制。

等价伪代码（实现口径）：

```js
function stableStringify(value) {
  if (value === null) return 'null';
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(',')}]`;
  if (typeof value === 'object') {
    const keys = Object.keys(value).sort();               // 码位升序
    return `{${keys.map((k) => `${JSON.stringify(k)}:${stableStringify(value[k])}`).join(',')}}`;
  }
  return JSON.stringify(value);                            // 数字 / 布尔 / 字符串的 JSON 形式
}
const payload = { ...report };
delete payload.generated_at;
delete payload.report_sha256;
const report_sha256 = sha256Hex(stableStringify(payload));
```

**自指问题**：指纹不能把自己算进去 —— 所以 `report_sha256` 本身与 `generated_at` 一起被排除在外。
这也是「同一份输入两次出报告，除 `generated_at` 外逐字相同（含 `report_sha256`）」能成立的前提。

## 5. `report.md` 的渲染契约

- `report.md` 是 `report.json` 的**渲染**，不是独立内容：md 里的每个数字必须与 json **逐字相等**；
- md 含**恰好一行**机器可读摘要：

  ```text
  <!-- report-digest: cases.total=5; cases.passed=2; ... -->
  ```

  - 单行，以 `<!-- report-digest: ` 开头、以 ` -->` 结尾，键值对之间用 `; `（分号 + 空格）分隔；
  - 每个键是 `report.json` 的**点号路径**（如 `cases.total` / `verdict.overall` / `regression.selected_missing`），
    其值与 json 中**同名路径**的值**逐字相等**（数组用逗号连接其元素，顺序敏感）；
  - 必须**至少**覆盖这 12 个键：
    `cases.total` / `cases.passed` / `cases.failed` / `cases.blocked` / `cases.skipped` /
    `verdict.case_layer` / `verdict.evidence_layer` / `verdict.regression_layer` / `verdict.overall` /
    `source.results_sha256` / `source.evidence_manifest_sha256` / `report_sha256`；
- md 必须**点名**（不许只写"有 1 条漏跑"）：漏跑的用例 id、失败与阻塞的用例 id 与错误摘要、
  判不了的变更 id 与原因；
- md 正文的关键数字按「**标签 + 数字**」呈现，标签取自下表的固定词汇：

  | 指标 | 允许的标签（任一） |
  |---|---|
  | 用例总数 | `用例总数` / `共计` / `总计` / `合计` |
  | 通过数 | `通过` |
  | 失败数 | `失败` |
  | 阻塞数 | `阻塞` / `阻断` |
  | 跳过数 | `跳过` |
  | 漏跑条数 | `漏跑` / `未执行` / `未跑` |
  | 待复核条数 | `待复核` / `需复核` / `人工复核` |
  | 判不了条数 | `判不了` / `无法判定` / `不可判定` |

  数字**紧跟**标签，标签与数字之间**不得出现字母或数字**（否则 id 自带的数字会被误读成计数）；
  单位 `条` / `个` / `项` 可省略。
  例：`用例总数：5`、`通过 2 条`、`漏跑 1 条（TC-006）`。

  ⚠️ 裸标签 `总数` **不在词表里** —— 它会与「证据总数 4 份」这类措辞撞车。
