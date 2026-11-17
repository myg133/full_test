# `report.json` 字段契约

> 产出脚本：`scripts/make-report.mjs`；校验脚本：`scripts/check-report.mjs`。
> 产物落在输出目录（默认 `<项目根>/reports/<run_id>/`）：`report.json`（机器读）+ `report.md`（人读）。
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
  "evidence": { /* 证据实查结论 + 内联视图 files[] */ },
  "regression": { /* 回归对账；未提供计划时为 null */ },
  "redaction": { /* 脱敏自陈：规则 + 如实计数 */ },
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
| `source.artifacts` | string | 执行产物目录路径（**相对项目根**，如 `.test-artifacts/run-0001`） |
| `source.run_id` | string | 取自 `meta.run_id` |
| `source.suite` | string | 取自 `meta.suite` |
| `source.requirement` | string | 取自 `meta.requirement` |
| `source.environment` | string | 取自 `meta.environment` |
| `source.started_at` | string | 取自 `meta.started_at` |
| `source.finished_at` | string | 取自 `meta.finished_at` |
| `source.results_sha256` | string | **重算**的结果指纹（64 位十六进制），非抄 `meta` |
| `source.evidence_manifest_sha256` | string | **重算**的证据清单指纹（64 位十六进制），非抄 `meta` |
| `source.regression_plan` | string \| null | 回归计划文件路径（**相对项目根**）；未提供计划时为 `null` |
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
| `evidence.files` | array | **内联视图**：每一份**实查存在**的证据文件一条（含 passed / skipped 用例的）；按 `path` 排序 |
| `evidence.files[].case_id` | string | 该证据所属用例 id |
| `evidence.files[].step` | string | 步序号（从 `evidence/<case_id>/step-N-*.json` 的文件名解析；解析不出为 `""`） |
| `evidence.files[].path` | string | **相对项目根**的路径（如 `.test-artifacts/run-0001/evidence/TC-001/step-1-response.json`） |
| `evidence.files[].sha256` | string | **实算**的**原文件**字节指纹（64 位十六进制），不是抄 `results.json` |
| `evidence.files[].bytes` | number | 原文件字节数 |
| `evidence.files[].media_type` | string | 从证据条目抄（`results.json` 的 `media_type`）；缺失则按扩展名推断 |
| `evidence.files[].content` | string | **脱敏后的原始文本**（非空；脱敏器没动过就与原文件**逐字相同**） |
| `evidence.files[].content_sha256` | string | 对 `content`（UTF-8 字节）算的 sha256（64 位十六进制） |
| `redaction` | object | 脱敏自陈段；字段集**恰好** 3 个键 |
| `redaction.rules_applied` | string[] | **实际启用**的规则名（逐条非空）；规则是代码里装着的，**不是**本次命中的 |
| `redaction.redacted_fields` | number | 敏感**字段名**规则命中的**替换次数**（≥0；**如实**计数，不虚报） |
| `redaction.redacted_values` | number | 值模式与绝对路径规则命中的**替换次数**（≥0；**如实**计数，不虚报） |
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
| `report_sha256` | string | 64 位十六进制；见 §5 的规范化口径 |

## 3. `cases` 段与 `regression` 段的键集是**封闭**的

- `cases` 段**只允许** 6 个键：`total` / `passed` / `failed` / `blocked` / `skipped` / `duration_ms_total`；
- `regression` 段**只允许** 7 个键：`selected_planned` / `selected_executed` / `selected_missing` /
  `needs_review_planned` / `needs_review_executed` / `undecidable_changes` / `impact_complete`。

多出任何一个键都是「报告里出现了算不出来的数字」，判红。

## 4. `evidence.files[]`（证据内联）与 `redaction` 段

### 4.1 内联视图的形状

`evidence.files[]` 是「**实查 + 内联**」的权威视图：**每一份实查存在的证据文件一条**
（含 passed / skipped 用例的证据，不只失败用例的），按 `path` 排序。每条的字段集**恰好** 8 个：

| 键 | 类型 | 契约 |
|---|---|---|
| `case_id` | string | 该证据所属用例 id |
| `step` | string | 步序号（从文件名 `step-N-*.json` 解析；解析不出为 `""`） |
| `path` | string | **相对项目根**的路径（**不是**相对产物目录） |
| `sha256` | string | **实算**的**原文件**字节指纹（64 位十六进制）—— 不是抄 `results.json` |
| `bytes` | number | 原文件字节数 |
| `media_type` | string | 抄 `results.json` 的 `media_type`；缺失则按扩展名推断 |
| `content` | string | **脱敏后的原始文本**（非空、**完整**，不截断、不摘要） |
| `content_sha256` | string | 对 `content`（UTF-8 字节）算的 sha256（64 位十六进制） |

⚠️ **缺失的证据文件不进 `files[]`**（没有内容可内联）—— 仍由 `evidence.files_missing` /
`evidence.missing_paths` / `evidence.findings[]` **照旧点名**。

⚠️ `failures[].evidence[]` 的语义**不变**（逐字取自产物，路径相对产物目录）——
它是「产物自述」；`evidence.files[]` 是「实查事实」，两个视图并存。

### 4.2 `sha256` 与 `content_sha256` 的关系

- `sha256` = **原文件**的字节指纹（证据层判定用的就是它）；
- `content_sha256` = **内联内容**（脱敏后）的指纹，**可从 `content` 直接重算**；
- 两者**相等** ⇒ 该文件**不含任何敏感内容**，脱敏器**一个字都没动**
  （`content` 与原文件**逐字相同**）—— 这条不变量是「脱敏器不误伤」的机械证明；
- 两者**不等** ⇒ 内容被**脱敏**过（敏感字段名 / 凭证字面量被替换成占位符），
  **不是**证据被改过 —— 证据层判定用的仍是原文件的实查指纹。

⇒ `report.md` 正文必须有一段说明这两者的关系（哪两个字段、为什么不等于、不是「证据被改」）。

### 4.3 脱敏规则与 `redaction` 段

| 类别 | 规则 | 占位符 |
|---|---|---|
| R1 | 敏感**字段名**（`password` / `passwd` / `pwd` / `token` / `secret` / `api_key` / `apikey` / `access_key` / `private_key` / `authorization` / `cookie` / `credential` / `credentials` / `session` 等，大小写与分隔符不敏感）⇒ **整值替换** | `[REDACTED:field]` |
| R2 | 敏感**值模式**：① 内嵌 JSON 形态（`"password":"xxx"`）；② `Bearer <token>`；③ URL 里的 `user:pass@host`；④ 独立的长十六进制串（≥32 位） | `[REDACTED:secret]` |
| R3 | 落在**项目根**下的绝对路径 ⇒ 换成**相对项目根**的路径 | 相对路径本身 |
| 豁免（键名） | **追踪 / 业务标识**键（`trace_id` / `x-trace-id` / `request_id` / `x-request-id` / `span_id` / `correlation_id` / `id` / `uuid`）下的值**原样保留** | —— |
| 豁免（值） | **本报告自身算出的指纹**（D221）：`meta.results_sha256` / `meta.evidence_manifest_sha256` / `results[]` 里各 `evidence[].sha256` / **重算**出的 results 与 manifest 指纹 / **实存证据文件**的字节指纹 ⇒ 即便命中 R2④ 也**原样保留、不计数** | —— |

⚠️ **豁免是按键名判定的**（结构化遍历），不是「一律放过长 hex」——
非豁免键（如 `cache_key`）下的长 hex 仍被 R2④ 脱敏。

⚠️ **值层面的豁免只对 R2④ 开口**（D221）：内嵌 JSON 口令 / `Bearer` / URL userinfo
**照旧被抹**（真凭证优先）—— 已知指纹若出现在这三种形态里，仍会被替换。

⚠️ **被测目标的地址、端口与业务账号逐字保留**（它们是被测对象标识，不是凭证）。

⚠️ R1 **按完整键名**匹配，不得误伤业务字段：`page.secrets.view`（业务权限点）与
`DEMO_TEST_TOKEN`（环境变量引用）**逐字保留**。

⚠️ `redaction` 段的两个计数**如实**填（**只在值真的变了时**才计一次）：
产物里没有敏感内容时两个计数都是 `0`；`rules_applied` 列出**实际启用**的规则
（规则是代码里装着的，不是本次命中的）。

## 5. `report_sha256` 的规范化口径

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

## 6. `report.md` 的渲染契约

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
- md 必须**内联证据内容**（不只列文件名）：`evidence.files[]` 里每一份的 `content`
  都要出现在 md 正文里（代码块内）—— 只读 md 就能读到证据原文；
- md 必须有一段说明 `sha256` 与 `content_sha256` 的关系：**两者不等是因为脱敏**，
  **不是**「证据被改」；并说明证据层判定用的仍是原文件的实查指纹；
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
