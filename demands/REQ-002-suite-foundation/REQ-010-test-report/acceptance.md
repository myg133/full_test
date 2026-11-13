# REQ-010 验收判据 —— `test-report`（执行报告 + 回归对账）

> 本文件是**契约**，不是说明材料。实现者按这里的规则交付，验收脚本按这里的规则判定。
> 判据条数：**29 条**（AC-001 ~ AC-029）。条数**不增不减不改号**。
> 决策记录见 `decisions.md`（D48 起）。

---

## §0 公共夹具规格（判据的公共前置）

验收脚本自造以下夹具，**全部落在临时目录**（`$WORK`），不得写进被验包：

### §0.1 最小执行产物目录 `$FX/ART`（模拟一次执行）

```
$FX/ART/
├── meta.json
├── results.json
├── evidence/
│   ├── TC-001/step-1-response.json     # passed 用例的证据
│   ├── TC-002/step-1-response.json     # failed 用例的证据
│   ├── TC-003/step-1-response.json     # blocked 用例的证据
│   └── TC-005/step-1-response.json     # ⚠️ results.json 声称有、但**文件故意缺失**（用于 AC-007）
└── logs/
    └── runner.log
```

`meta.json` 必填字段（对齐 REQ-004 的 `references/evidence-chain.md`）：

| 字段 | 值 |
|---|---|
| `run_id` | `run-demo-0001` |
| `suite` | `REQ-DEMO-demo` |
| `scope` | `functional` |
| `requirement` | `REQ-DEMO` |
| `environment` | `mock-local` |
| `started_at` / `finished_at` | ISO-8601 |
| `duration_ms` | **725**（= 5 条用例 `duration_ms` 之和，见下注 ⚠️） |
| `agent` | `demo-agent` |
| `executor` | `{"name":"mock","version":"0.1.0"}` |
| `tool_versions` | `{}` |
| `cases_total` | **6** |
| `cases_passed` | **2** |
| `cases_failed` | **1** |
| `cases_blocked` | **1** |
| `cases_skipped` | **2** |
| `evidence_manifest_sha256` | 按 §0.4 算出的真值 |
| `results_sha256` | 按 §0.4 算出的真值 |
| `redaction` | `{"rules_applied":[],"redacted_fields":0}` |
| `cycle` | `null` |

⚠️ **夹具的计数刻意与实际不符**：实际 5 条用例（TC-001~TC-005），而 `meta.json` 写 `cases_total: 6`。
这是**故意的** —— 用于 AC-021（计数不符必须被抓）。AC-005/AC-006 用的真值是 **从 `results.json` 重算**的，不是 `meta.json` 的自述。

### §0.2 `results.json`（根节点是数组，5 条）

字段名严格对齐 REQ-004 的 `references/evidence-chain.md` §3（**不得自造别名**）：

| `case_id` | `status` | `title` | `requirement_refs` | `duration_ms` | `evidence[]` | `reproduction.steps` | `reproduction.command` | `error` |
|---|---|---|---|---|---|---|---|---|
| `TC-001` | `passed` | 健康检查通过 | `["R-1"]` | `120` | 1 份（`evidence/TC-001/step-1-response.json`） | `["GET /api/health"]` | `curl -X GET /api/health` | `null` |
| `TC-002` | `failed` | 订单查询返回 500 | `["R-1"]` | `340` | 1 份（`evidence/TC-002/step-1-response.json`） | `["GET /api/orders"]` | `curl -X GET /api/orders` | `{type:"assertion", message:"期望 200，实际 500"}` |
| `TC-003` | `blocked` | 列表用例缺少断言 | `["R-2"]` | `55` | 1 份（`evidence/TC-003/step-1-response.json`） | `["GET /api/items"]` | `curl -X GET /api/items` | `{type:"missing_assertion", message:"用例缺少可机械判定的断言"}` |
| `TC-004` | `skipped` | 已废弃用例 | `["R-2"]` | `0` | **空数组 `[]`** | **`[]`（空）** | `""` | `null` |
| `TC-005` | `passed` | 报表导出通过 | `["R-3"]` | `210` | 1 份（`evidence/TC-005/step-1-response.json`）—— ⚠️ **该文件故意不存在**（AC-007） | `["GET /api/reports"]` | `curl -X GET /api/reports` | `null` |

⚠️ **`duration_ms` 口径消歧**：`cases.duration_ms_total` 必须等于**各条用例 `duration_ms` 之和**（= `725`）。
本夹具刻意让 `meta.duration_ms` 也等于 `725` —— 这样「取 `meta.duration_ms`」与「自己求和」两种口径**结果相同**，
实现方选哪条路都不会判红。**不得**让这两个值不同（那会让一个正确的实现因口径不同被判红）。

每条结果另需：`started_at` / `finished_at`（ISO-8601）、`duration_ms`（整数）、`reproduction.expected`（字符串，可为 `""`）。
`evidence[]` 每项为 `{path, sha256, bytes, media_type}`，其中 `sha256`/`bytes` 是该证据文件的**真实**指纹
（`TC-005` 的 `sha256`/`bytes` 按**它本该有的内容**计算 —— 文件不存在 ⇒ 文件系统实查必然失败，这正是 AC-007 的源）。

⚠️ 除两处**故意的**不一致外，夹具必须自洽：① `meta.json` 的计数故意错（§0.1）；② `TC-005` 的证据文件故意缺失。
其余（如「证据份数 == `reproduction.steps` 长度」「`skipped` 的证据为空且步骤为空」）一律遵守上游契约 —— 
**夹具自身违约会让实现方在「报告没报的问题」和「夹具本来就不该出现的问题」之间分不清责任**。

### §0.3 回归计划 `$FX/PLAN`（`regression-plan.json`，schema_version 1）

严格对齐 REQ-011 的 `references/regression-plan-schema.md`（**字段名不得自造别名**：
`changes[].id`、`selected[].case_id`、`selected[].reason`、`needs_review[].case_id`、`undecidable_changes[].change_id`）：

```jsonc
{
  "schema_version": 1,
  "cycle_id": "R2-DEMO",              // 由输入派生，与轮次目录名解耦 —— **本 REQ 不得假定它等于目录名**
  "generated_at": "2026-11-13T00:00:00Z",
  "source": { "changelog": "CHANGELOG.md", "cases": "cases.json" },
  "changes": [
    { "id": "C-1", "title": "健康检查接口调整", "requirement_refs": [], "case_refs": ["TC-001"],
      "dimensions": [], "explicit_dimensions": [], "signal_dimensions": [], "method_hits": [] },
    { "id": "C-2", "title": "订单列表断言调整", "requirement_refs": ["R-1"], "case_refs": [],
      "dimensions": [], "explicit_dimensions": [], "signal_dimensions": [], "method_hits": ["M1.2"] },
    { "id": "C-3", "title": "文档措辞调整", "requirement_refs": [], "case_refs": [],
      "dimensions": [], "explicit_dimensions": [], "signal_dimensions": [], "method_hits": [] }
  ],
  "selected": [
    { "case_id": "TC-001", "reason": "case_ref:TC-001", "change_refs": ["C-1"] },
    { "case_id": "TC-002", "reason": "case_ref:TC-002", "change_refs": ["C-1"] },
    { "case_id": "TC-006", "reason": "case_ref:TC-006", "change_refs": ["C-1"] }   // ⚠️ 本次执行没跑它 ⇒ 漏跑
  ],
  "needs_review": [
    { "case_id": "TC-003", "reason": "method_not_applies:M1.2", "change_refs": ["C-2"] }
  ],
  "undecidable_changes": [
    { "change_id": "C-3", "reason": "无显式引用，且正文未命中任何维度/方法信号" }
  ],
  "summary": { "total_cases": 6, "selected": 3, "needs_review": 1, "undecidable_changes": 1, "impact_complete": false }
}
```

⚠️ `impact_complete: false`（有判不了的变更）⇒ 按 F3.1，**整体结论不得为 `pass`**（AC-017）。
⚠️ `selected[].case_refs` 的 `change_refs` 里的 `C-1` 必须真实存在于 `changes[].id`；`undecidable_changes` 的 `C-3` **不得**出现在任何 `selected`/`needs_review` 条目的 `change_refs` 里（上游不变式）。

### §0.4 指纹真值

`results_sha256` 与 `evidence_manifest_sha256` 按 REQ-004 的 `scripts/lib/fingerprint.mjs` 口径算：
- 证据清单指纹 = 每条证据拼 `路径 + "\0" + sha256 + "\n"`，按 `results.json` 顺序连接后取 sha256；
- 结果指纹 = 每条结果拼 `case_id + "\0" + status + "\0" + error.type + "\0" + error.message + "\0" + reproduction.command + "\0" + reproduction.steps.join(...) + "\n"`，再接该条结果的证据条目行。

**夹具里这两个值必须是按上述口径算出的真值**（脚本自算，不得写死字面量）。

### §0.5 判据角色的互斥要求（干跑实测补，否则判据会互斥或变异会逃逸）

1. **TC-003 既是 `blocked` 用例、又在 `needs_review` 里** —— 这是**故意的**：AC-016 判「`needs_review` 非空时 `regression_layer` 不得为 `pass`」，AC-019 判「`blocked` 不算通过」，两条各管各的，不互斥。
2. **TC-004 是 `skipped`** —— 它的 `evidence` 必须是**空数组**、且**不得**出现在 `selected` 里。
3. **TC-006 只在计划里、不在执行产物里** —— 这是漏跑用例的**唯一**来源；不得让 `selected` 里的其它用例也缺跑（否则「漏跑点名」这一条就分不清是漏了 TC-006 还是漏了别的）。

### §0.6 基线真值表（夹具跑出来的**唯一**正确结论）

门与实现都以此为准。**给了计划**时：

| 字段 | 真值 | 来源 |
|---|---|---|
| `cases.total` / `passed` / `failed` / `blocked` / `skipped` | `5` / `2` / `1` / `1` / `1` | 从 `results.json` 重算（**不是** `meta.json` 的 6/2/1/1/2） |
| `cases.duration_ms_total` | `725` | 各条用例 `duration_ms` 之和（`meta.duration_ms` 也是 `725`，两口径同值） |
| `verdict.case_layer` | `fail` | 有 failed |
| `verdict.evidence_layer` | `fail` | `findings` 非空（见下） |
| `verdict.regression_layer` | `fail` | `selected_missing` 非空 |
| `verdict.overall` | `fail` | F3.1：有 failed ⇒ fail |
| `failures[]` 的 case_id | `["TC-002","TC-003"]` | failed + blocked |
| `evidence.missing_paths` | `["evidence/TC-005/step-1-response.json"]` | 实查 |
| `evidence.files_present` / `files_missing` | `3` / `1` | 实查（口径见下方注） |
| `evidence.findings[]` 的 `kind` 集合 | 至少含 `missing_evidence` 与 `count_mismatch` | TC-005 缺失 + meta 计数不符 || `regression.selected_planned` / `selected_executed` | `3` / `2` | 计划 3 条，执行命中 2 条 |
| `regression.selected_missing` | `["TC-006"]` | 差集 |
| `regression.needs_review_planned` / `needs_review_executed` | `1` / `1` | TC-003 命中 |
| `regression.undecidable_changes` | 恰 1 条，`change_id == "C-3"`，`reason` 逐字等于计划里的 reason | 原样搬运 |
| `regression.impact_complete` | `false` | 取自计划 |

**不给计划**时：`regression == null`、`regression_layer == "not_applicable"`，其余同上。

⚠️ **`findings[]` 的条数不作判据**：本夹具实际有**两处**计数不符（`cases_total` 6≠5、`cases_skipped` 2≠1），
实现方可以合并成 1 条 `count_mismatch`（message 里同时出现 6/5/2/1），也可以拆成 2 条。
**门只判「至少含一条点名 `cases_total` 或"总数"、且同时含 `6` 与 `5` 的 `count_mismatch`」**（AC-021），
**不得**按条数判红（那是口径歧义，不是缺陷）。

⚠️ `files_present` 的口径：`results.json` 声称的证据条目里**实查存在**的份数（`TC-001` 1 份 + `TC-002` 1 份 + `TC-003` 1 份 = **3**），
`files_missing` = 声称的证据条目里**实查缺失**的份数（`TC-005` = **1**）。
⚠️ 这里刻意留了**口径分歧空间**：`TC-003`（blocked）的证据文件**存在**，所以无论按"声称条数"还是"实存条数"算，
`files_present` 都是 3 —— 唯一能让它变成 2 的口径是"排除 blocked/skipped 的证据"，本 REQ **不采用**那个口径。
（夹具把 `TC-003` 的证据文件造出来，就是为了消掉这个歧义；实现方不得自行改口径。）

---

## A 组：交付物形状（AC-001 ~ AC-004）

### AC-001: `test-report` skill 存在且结构合法
- **前置条件**: 被验包目录
- **测试步骤**: ① 检查 `skills/test-report/` 存在；② `SKILL.md` 存在且 YAML frontmatter 含 `name: test-report` 与**非空** `description`（取 frontmatter 的**值**再判空 —— 块标量 `|` 取其缩进块；普通标量剥掉首尾引号，`""` / `''` 判空）；③ `references/report-schema.md`、`references/report-rules.md`、`scripts/make-report.mjs`、`scripts/check-report.mjs` 四个文件存在且非空；④ 两个脚本首行是 `#!/usr/bin/env node` 或可被 `node` 直接执行，且 `node --check` 通过
- **预期结果**: 四项全满足；任一缺失 → 判红并点名缺哪个；`description` 为空值 → 判红
- **判据形式**: 查**绝对事实**（文件真实存在且非空）；探针：把 `description` 改成 `""` → 本条判红
- **类型**: 功能

### AC-002: 每个 skill 都声明版本与依赖（`skill-meta.json`）
- **前置条件**: 被验包目录
- **测试步骤**: 对 `skills/` 下**每一个**含 `SKILL.md` 的目录，检查存在 `skill-meta.json`；解析它必须有 `name`（非空且等于目录名）、`version`（形如 `<数字>.<数字>.<数字>`）、`requires`（对象；值为形如 `>=<x.y.z>` 或 `<x.y.z>` 的约束）；并检查 `name` 与该 skill 的 SKILL.md frontmatter `name` 一致
- **预期结果**: 每个 skill 都有合法声明；**`test-report` 的 `requires` 必须包含 `test-execute`**（它消费执行产物的格式，是硬依赖）；任一不满足 → 判红并点名
- **判据形式**: 查绝对事实；探针：删掉某个 skill 的 `skill-meta.json` → 本条判红；把 `test-report.requires` 里的 `test-execute` 删掉 → 本条判红
- **类型**: 功能

### AC-003: README 的 skill 清单与实际目录一致
- **前置条件**: 被验包目录 + `README.md`
- **测试步骤**: 取 `skills/` 下全部含 `SKILL.md` 的目录名集合 S；取 `README.md` 的 **skill 清单**（表格首格 ∪ `skills/<name>` 路径 ∪ 安装树条目）集合 R；检查 S == R
- **预期结果**: 两个集合完全相等；README 漏写或多写任一 skill → 判红并点名；**`test-report` 必须在清单里**
- **判据形式**: 查绝对事实（与目录实际内容比对），不查"README 里说了几个"
- **类型**: 可用性

### AC-004: 新产物不得打破既有目录契约
- **前置条件**: `test-case-design` 的 `scripts/verify-layout.mjs` + 一个合法的 `test-assets/` 项目
- **测试步骤**: ① 造一个满足 REQ-002B 契约的最小项目；② 在其轮次目录 `test-assets/cycles/R2-DEMO/` 里放一个报告目录 `report/`（含 `report.json` 与 `report.md`）；③ 跑 `verify-layout.mjs`；④ 断言退出码为 0 且无 FAIL 级问题
- **预期结果**: 校验器**不因**多了 `report/` 而判红（新增产物不得破坏既有契约）
- **判据形式**: 查绝对事实（实跑校验器的退出码）；**并给出错误位置探针的明确结论**：把 `report/` 放到错误位置（如 `test-assets/` 根）→ 若校验器**本就不查该位置**，必须输出「位置不受约束（校验器不查该位置 → 本条判绿，不得要求实现去管它）」这一结论；若校验器查了该位置则判红。**不接受"没有输出任何结论"**
- **类型**: 兼容性

---

## B 组：产物解析与重算（AC-005 ~ AC-009）

### AC-005: 计数必须由 `results.json` 重算，不得抄 `meta.json`
- **前置条件**: §0.1 的执行产物目录
- **测试步骤**: 跑 `make-report.mjs --artifacts $FX/ART`；取 `report.json` 的 `cases.total` / `cases.passed` / `cases.failed` / `cases.blocked` / `cases.skipped`，与**从 `results.json` 逐条重算**的分布逐个比对
- **预期结果**: 五个数字与重算结果**逐字相等**（夹具真值：`total=5, passed=2, failed=1, blocked=1, skipped=1`）；**不得**等于 `meta.json` 的自述（`meta` 写的是 6/2/1/1/2 —— 那是故意的错值）
- **判据形式**: 查绝对事实（`results.json` 的实际内容）；探针：把实现的计数改成直接读 `meta.json` 的五个计数 → 本条判红
- **类型**: 功能

### AC-006: 状态分布必须与 `results.json` 逐条一致
- **前置条件**: 同上
- **测试步骤**: 取 `report.json` 的四个状态计数，**逐条遍历** `results.json` 的每条结果，按 `status` 分类累加，与报告计数比对；并检查报告列出的失败/阻塞用例 id 集合与 `results.json` 中 `status ∈ {failed, blocked}` 的 id 集合**完全相等**
- **预期结果**: 逐条累加结果与报告数字相等；漏报或多报一条失败/阻塞用例 → 判红并点名
- **判据形式**: 查绝对事实；探针：让实现把 `blocked` 归到 `passed` → 本条判红
- **类型**: 功能

### AC-007: 证据文件必须实查（不信 `results.json` 的自述）
- **前置条件**: §0.1 的执行产物目录（`TC-005` 的证据文件**故意缺失**）
- **测试步骤**: 逐条遍历 `results.json` 的 `evidence[]`，检查每个 `path` 相对产物目录**真实存在**且 sha256 与记录一致；检查 `report.json` 的 `evidence.missing_paths`、`evidence.files_present`、`evidence.files_missing`、`evidence.findings[]`
- **预期结果**: `missing_paths` 必须**点名** `evidence/TC-005/step-1-response.json`；`files_missing == 1`、`files_present == 3`；`findings[]` 至少含一条 `kind == "missing_evidence"` 且其 `message` 非空、**点名该缺失路径**；`evidence_layer` 必须为 `fail`（不得判 `pass`）
- **判据形式**: 查绝对事实（文件系统实况）；探针：让实现只信 `results.json` 的自述、不查文件 → 本条判红
- **类型**: 功能

### AC-008: 报告必须绑定输入产物的指纹
- **前置条件**: 同上
- **测试步骤**: 取 `report.json` 的 `source.results_sha256` / `source.evidence_manifest_sha256`，与 `meta.json` 里记录的两个值比对；再与**从 `results.json` 按 §0.4 口径重算**的值比对
- **预期结果**: 四个值**全部相等**（meta 的记录值 == 重算值 == 报告里写的值）；报告不得只抄 `meta.json`（若 meta 的指纹与重算值不符，报告必须指出而不是跟着抄）
- **判据形式**: 查绝对事实；探针：把实现改成把 `source.results_sha256` 写成别的值 → 本条判红
- **类型**: 功能

### AC-009: 输入缺失或非法时必须报错退出，不得产出半份报告
- **前置条件**: ① 产物目录不存在；② `meta.json` 不是合法 JSON；③ `results.json` 根节点不是数组
- **测试步骤**: 三种情形各跑一次 `make-report.mjs`，检查退出码与输出目录
- **预期结果**: 三种情形**退出码均非 0**（用法错 = 2，输入非法 = 1），且**不得**留下半份报告（`report.json` / `report.md` 不存在或不含未完成内容）；错误信息要点名是什么坏了
- **判据形式**: 查绝对事实（真实退出码 + 产物目录实况）；探针：让实现在解析失败时仍写出一个空的 `report.json` → 本条判红
- **类型**: 功能

---

## C 组：报告内部一致性与可核（AC-010 ~ AC-013）

### AC-010: `report_sha256` 必须可从报告自身重算
- **前置条件**: §0.1 的执行产物目录
- **测试步骤**: 取 `report.json`，按 **demand.md F3.2 规定的规范化口径**（剔除 `generated_at` 与 `report_sha256` 两字段后，对剩余内容做**键名按码位升序**的稳定序列化：对象键排序、数组保序、无空白分隔符、数值用 JSON 表示、字符串用 JSON 转义）重算 sha256，与报告里的 `report_sha256` 比对
- **预期结果**: 两者**逐字相等**；口径必须**同时**写在 `references/report-schema.md` 里（否则无法核）；报告不得把自己算进去
- **判据形式**: 查绝对事实（可重算）；探针：让实现写死一个 `report_sha256` → 本条判红
- **类型**: 功能

### AC-011: `report.md` 的数字必须与 `report.json` 逐字相等
- **前置条件**: 同上（**须带 `--regression-plan $FX/PLAN`**，以覆盖全部数字类型）
- **测试步骤**: ① `report.md` 必须含**一行机器可读摘要**，格式为 `<!-- report-digest: key=value; key=value; ... -->`（单行、每个键值对之间用 `; ` 分隔）；② 摘要里的每个键都必须能在 `report.json` 里找到**同名路径**（点号路径，如 `cases.total` / `verdict.overall` / `regression.selected_missing`），且**值逐字相等**（数组用逗号连接其元素，顺序敏感）；③ 摘要必须**至少**覆盖这些键：`cases.total` / `cases.passed` / `cases.failed` / `cases.blocked` / `cases.skipped` / `verdict.case_layer` / `verdict.evidence_layer` / `verdict.regression_layer` / `verdict.overall` / `source.results_sha256` / `source.evidence_manifest_sha256` / `report_sha256`；④ md **正文**里出现的关键数字（总数 / 各状态数 / 漏跑条数 / 待复核条数 / 判不了条数）必须与摘要一致
- **预期结果**: ①②③④ 全满足；**任何**一个数字对不上、或摘要缺必需键 → 判红并点名是哪个键
- **判据形式**: 查绝对事实（两份产物的实际内容互比）；探针：让实现在 md 的摘要里写死一个计数 → 本条判红
- **说明**: 摘要行是 md 的**渲染契约**（D50）——"md 是 json 的渲染、数字逐字相等"若没有可机械抽取的落点，就只能靠人眼比对，那等于没有约束。

### AC-012: `overall == "pass"` 的自洽不变式
- **前置条件**: 同上
- **测试步骤**: 取 `report.json` 的 `verdict.overall`；若为 `pass`，检查 `cases.failed == 0`、`cases.blocked == 0`、`verdict.evidence_layer == "pass"`、且（若给了计划）`verdict.regression_layer ∈ {"pass","not_applicable"}` 且 `regression.impact_complete == true`
- **预期结果**: `overall == "pass"` 时上述条件**全部成立**；任一不成立 → 判红（自相矛盾的报告）
- **判据形式**: 查绝对事实；探针：让实现在有 `failed` 时仍给 `overall: "pass"` → 本条判红
- **类型**: 诚实性

### AC-013: `report.json` 的必填字段集必须完整
- **前置条件**: 同上
- **测试步骤**: ① `references/report-schema.md` 必须存在且非空，其中**必须列出** `demand.md` F3 声明的必填字段清单（**缺一个 → 判红**，不得"schema 里没写就不查"）；② 逐个检查 `report.json` 的**路径**存在、类型正确：`schema_version`（number）、`generated_at`（string）、`source.{artifacts,run_id,suite,requirement,environment,started_at,finished_at,results_sha256,evidence_manifest_sha256,regression_plan}`（string；`regression_plan` 未给计划时为 `null`）、`cases.{total,passed,failed,blocked,skipped,duration_ms_total}`（number）、`verdict.{case_layer,evidence_layer,regression_layer,overall}`（string 且取值在枚举内：`case_layer ∈ {pass,fail,incomplete}`、`evidence_layer ∈ {pass,fail,unknown}`、`regression_layer ∈ {pass,fail,incomplete,not_applicable,unknown}`、`overall ∈ {pass,fail,incomplete}`）、`failures[]` 每项含 `case_id`/`title`/`status`/`error`/`reproduction`/`evidence`、`evidence.{files_present,files_missing,missing_paths,findings}`（前两个 number，`missing_paths` 为 string[]，`findings` 为对象数组，每项含 `kind`（枚举 `missing_evidence`/`evidence_mismatch`/`count_mismatch`/`fingerprint_mismatch`）与非空 `message`）、`regression`（给计划时为对象，含 `selected_planned`/`selected_executed`/`needs_review_planned`/`needs_review_executed`（number）、`selected_missing`（string[]）、`undecidable_changes`（对象数组，每项含 `change_id`/`reason`）、`impact_complete`（boolean）；未给计划时为 `null`）、`report_sha256`（64 位 hex）；③ `references/report-schema.md` 里必须写明 `report_sha256` 的**规范化口径**（剔除 `generated_at` 与 `report_sha256` 后的稳定序列化方式），否则 AC-010 无法核
- **预期结果**: ①②③ 全满足；缺字段、类型错、枚举越界或 schema 未列出 F3 字段 → 判红并点名缺哪个
- **判据形式**: 查绝对事实（按 F3 的固定字段清单逐字段核 + schema 文档实查）；探针：让实现删掉 `verdict.evidence_layer` 字段 → 本条判红
- **类型**: 功能

---

## D 组：回归对账（AC-014 ~ AC-018）

> 以下各条的前置：`make-report.mjs --artifacts $FX/ART --regression-plan $FX/PLAN`

### AC-014: 漏跑必须逐条点名
- **前置条件**: §0.3 的计划（`selected` 含 `TC-001` / `TC-002` / **`TC-006`**，而执行产物里没有 `TC-006`）
- **测试步骤**: 取 `report.json` 的 `regression.selected_missing`，与「计划 `selected[].case_id` 减去执行产物 `results.json` 中实际出现的 `case_id`」的差集比对；并检查 `report.md` 里**点名**了 `TC-006`
- **预期结果**: 差集**恰好**是 `["TC-006"]`；`selected_missing` 非空时 `report.md` 必须逐字出现 `TC-006`（只写"有 1 条漏跑"不算）
- **判据形式**: 查绝对事实（两份产物的实际内容互比）；探针：让实现的 `selected_missing` 恒为空数组 → 本条判红
- **类型**: 功能

### AC-015: 漏跑必须导向失败结论
- **前置条件**: 同上
- **测试步骤**: 检查 `verdict.regression_layer` 与 `verdict.overall`
- **预期结果**: `selected_missing` 非空 → `regression_layer == "fail"` **且** `overall != "pass"`；两点缺一 → 判红
- **判据形式**: 查绝对事实；探针：让实现在漏跑时仍给 `overall: "pass"` → 本条判红
- **类型**: 诚实性

### AC-016: `needs_review` 非空时不得判回归通过
- **前置条件**: 同上（计划的 `needs_review` 含 `TC-003`，且 `TC-003` 在执行产物里、状态为 `blocked`）
- **测试步骤**: 检查 `verdict.regression_layer`、`regression.needs_review_planned`、`regression.needs_review_executed`
- **预期结果**: `needs_review_planned == 1`、`needs_review_executed == 1`；`regression_layer` **不得**为 `"pass"`（待人工复核 ≠ 回归通过）；`report.md` 必须显示这批待复核用例的 id（点名 `TC-003`）
- **判据形式**: 查绝对事实；探针：让实现在 `needs_review` 非空时仍给 `regression_layer: "pass"` → 本条判红
- **类型**: 诚实性

### AC-017: 判不了的变更必须呈现，且不得判通过
- **前置条件**: 同上（`undecidable_changes` 含 `C-3`，`impact_complete: false`）
- **测试步骤**: 检查 `regression.undecidable_changes` 的**条目数**与 `change_id`/`reason`（`reason` 必须非空且与计划一致）；检查 `regression.impact_complete`；检查 `verdict.overall`
- **预期结果**: `undecidable_changes` 恰有 1 条、`change_id == "C-3"`、`reason` 非空且逐字等于计划里的 reason；`impact_complete == false`；`overall != "pass"`（按 F3.1）；`report.md` 必须点名 `C-3`
- **判据形式**: 查绝对事实；探针：把实现的 `undecidable_changes` 写成空数组 → 本条判红
- **类型**: 诚实性

### AC-018: 未提供计划时不得编造回归层结论
- **前置条件**: 只有执行产物，**不给** `--regression-plan`
- **测试步骤**: 跑 `make-report.mjs --artifacts $FX/ART`；检查 `regression` 段、`verdict.regression_layer`，以及 `report.md` 的全文
- **预期结果**: `regression == null`；`regression_layer == "not_applicable"`；`report.md` 中**不得出现**「回归通过」「回归完整」「回归覆盖」等断言回归状态的措辞（不得出现 `regression_layer` 的其它取值）；`overall` 的推导**不得**依赖回归层
- **判据形式**: 查绝对事实（两份产物的实际内容）；探针：让实现在没给计划时也填一个 `regression` 段 → 本条判红
- **类型**: 诚实性

---

## E 组：诚实性（AC-019 ~ AC-023）

### AC-019: `blocked` 不得计入 `passed`
- **前置条件**: §0.1 的执行产物（`TC-003` 为 `blocked`）
- **测试步骤**: 检查 `cases.passed` 与 `cases.blocked`；检查 `verdict.overall`
- **预期结果**: `blocked == 1` 且 `passed == 2`（**不含** `TC-003`）；`overall != "pass"`（有 `blocked` → 只能是 `incomplete` 或 `fail`）
- **判据形式**: 查绝对事实；探针：让实现把 `blocked` 计入 `passed` → 本条判红（**这一条同时被 AC-006 覆盖，但两者的变异本体不同：AC-006 改的是分布，本条改的是结论**）
- **类型**: 诚实性

### AC-020: 证据链不自洽不得出可信结论
- **前置条件**: 把 `$FX/ART` 复制一份，在副本里把某个**证据文件的内容改掉**（`TC-002` 的 `evidence/TC-002/step-1-response.json`，**不改 `results.json` 里的 sha256**）⇒ 该证据的实算 sha256 与记录值不符
- **测试步骤**: 跑 `make-report.mjs --artifacts <被篡改的副本>`；检查 `verdict.evidence_layer`、`verdict.overall`、`report.json` 的 `evidence.findings[]`、`report.md`
- **预期结果**: `evidence_layer == "fail"`；`overall != "pass"`；`evidence.findings[]` 至少含一条 `kind ∈ {"evidence_mismatch","fingerprint_mismatch"}`，其 `message` **点名被篡改的证据路径**（含 `TC-002` 与该文件名）或点名"指纹不符"；`report.md` 必须出现该条 `message` 的**关键片段**（路径片段或 `kind` 名）—— 只写"证据链校验失败"**不算**
- **判据形式**: 查绝对事实（真实退出码 + 报告内容）；探针：让实现跳过证据链校验（假定产物可信）→ 本条判红
- **类型**: 诚实性

### AC-021: `meta.json` 计数与 `results.json` 不符必须被发现
- **前置条件**: §0.1 的夹具（**故意**：`meta` 写 6/2/1/1/2，实际是 5/2/1/1/1）
- **测试步骤**: 跑 `make-report.mjs --artifacts $FX/ART`；检查 `verdict.evidence_layer`、`evidence.findings[]`、`report.md`
- **预期结果**: `evidence.findings[]` 至少含一条 `kind == "count_mismatch"`，其 `message` **点名是哪个计数**（含 `cases_total` 或"总数"字样）**且同时含 meta 记的值 `6` 与重算真值 `5`**；`evidence_layer == "fail"`（或至少 `overall != "pass"`）；`report.md` 必须出现该条 `message` 的关键片段；但 `cases.*` 仍必须按 `results.json` 重算（AC-005 的真值 5/2/1/1/1）
- **判据形式**: 查绝对事实；探针：让实现完全无视 `meta` 的计数差异（既不报也不判失败）→ 本条判红
- **类型**: 诚实性

### AC-022: 失败用例的复现信息必须逐字搬运
- **前置条件**: §0.1 的执行产物（`TC-002` 为 `failed`）
- **测试步骤**: 取 `report.json` 的 `failures[]` 中 `TC-002` 的 `reproduction`，与 `results.json` 里 `TC-002` 的 `reproduction`（`command` 与 `steps`）**逐字**比对；检查 `report.md` 里是否出现该 `command`
- **预期结果**: `reproduction` 与产物**逐字相等**（不得摘要、不得改写、不得省略 `steps`）；`report.md` 必须出现 `reproduction.command` 的原文
- **判据形式**: 查绝对事实（两份产物的实际内容互比）；探针：让实现把 `reproduction.steps` 改写成摘要 → 本条判红
- **类型**: 一致性

### AC-023: 报告不得出现输入产物里没有的数字或 id
- **前置条件**: §0.1 的执行产物 + §0.3 的计划（**须带 `--regression-plan $FX/PLAN`**）
- **输入集合（判据自带，不从报告里取）**:
  - `IDS`（用例 id 集）= `results.json` 各条 `case_id` ∪ `plan.selected[].case_id` ∪ `plan.needs_review[].case_id` ∪ `plan.changes[].case_refs[]`
  - `CHANGE_IDS`（变更 id 集）= `plan.changes[].change_id` ∪ `plan.undecidable_changes[].change_id`
- **测试步骤**:
  - ① **id 溯源（json 侧）**：`report.json` 的 `failures[].case_id` 每一个必须 ∈ `IDS`；`regression.selected_missing[]` 每一个必须 ∈ `plan.selected[].case_id`；`regression.undecidable_changes[].change_id` 每一个必须 ∈ `CHANGE_IDS`
  - ② **id 溯源（md 侧）**：从 `report.md` **全文**抽取所有形如 `[A-Za-z][A-Za-z0-9]*-\d+` 的 token，凡**看起来是用例 id**（前缀与 `results.json`/`plan` 里出现的用例 id 前缀相同，如 `TC-`）的必须 ∈ `IDS`；凡**看起来是变更 id**（前缀与 `plan.changes[].id` 前缀相同，如 `C-`）的必须 ∈ `CHANGE_IDS`
  - ③ **数字可重算（用例层）**：`report.json` 的 `cases` 段**只允许** F3 声明的 6 个键 `total`/`passed`/`failed`/`blocked`/`skipped`/`duration_ms_total`；前 5 个必须逐字等于从 `results.json` 逐条重算的真值（`5/2/1/1/1`），`duration_ms_total` 必须等于各条 `duration_ms` 之和；出现第 7 个键 → 判红
  - ④ **数字可重算（回归层）**：`regression` 段内**每一个数字型字段**必须能由 `plan` 与 `results.json` 逐字段重算得出：`selected_planned` == `plan.selected.length`；`selected_executed` == |`plan.selected[].case_id` ∩ `results.json` 实际出现的 `case_id`|；`needs_review_planned` == `plan.needs_review.length`；`needs_review_executed` == |`plan.needs_review[].case_id` ∩ `results.json` 实际出现的 `case_id` 集|；`undecidable_changes.length` == `plan.undecidable_changes.length`；`impact_complete` == `plan.summary.impact_complete`；并检查 `selected_planned == selected_executed + selected_missing.length`
  - ⑤ **顶层不得有野生数字**：`report.json` 的**顶层**只允许**一个**数字型叶子字段 —— `schema_version`（值 `1`，F3 声明）；除此之外，顶层出现任何数字型叶子字段（如 `total: 42`）→ 判红并点名（**字符串**字段不受此限）
- **预期结果**: ①~⑤ 全满足；出现一个输入里没有的 id、或一个重算不上的数字、或一个野生数字字段 → 判红并点名（是哪个 id / 哪个字段）
- **判据形式**: 查绝对事实（集合运算 + 逐字段重算 + 顶层字段枚举）；探针：让实现在报告里写死一个 `total: 42` → 本条判红（`cases.total != 5`（③）**且**多出顶层数字字段（⑤）—— 两处同时命中）
- **类型**: 诚实性
- **说明**: 本条的增量在 ①②（**id 溯源**）与 ④（**回归层数字逐字段重算**）—— 这两处是"报告凭空捏造"的高发区；③④⑤ 覆盖用例层数字与顶层常量。不依赖「扫描 md 里的所有阿拉伯数字」那种粗口径（日期、时长等会误伤）。

---

## F 组：幂等与可复现（AC-024 ~ AC-026）

### AC-024: 同一输入两次出报告必须逐字相同
- **前置条件**: §0.1 的执行产物 + §0.3 的计划
- **测试步骤**: 跑两次 `make-report.mjs --artifacts $FX/ART --regression-plan $FX/PLAN`（输出到两个不同目录）；两份 `report.json` 与两份 `report.md` 逐字比对（**排除** `generated_at` 字段）
- **预期结果**: 除 `generated_at` 外**逐字相同**（含 `report_sha256` —— 它也必须相同，因为它排除 `generated_at`）；`report.md` 同理
- **判据形式**: 查绝对事实（两份产物的实际内容互比）；探针：让实现在报告里塞入随机值或时间戳 → 本条判红
- **类型**: 可复现性

### AC-025: 输出路径约定 + 只写自己的目录
- **前置条件**: 同上
- **测试步骤**: ① 默认输出：检查 `<run_dir>/report/report.json` 与 `report.md` 存在；② `--out-dir <其它目录>`：检查报告落在指定目录；③ 检查**输入产物目录**下**除 `report/` 外**没有新增/修改任何文件；④ 检查输出目录**不在**输入产物目录内时，不得在输入产物目录里留下任何散落文件
- **预期结果**: 四项全满足；报告写到输入产物目录之外时，输入产物目录必须**逐字未变**
- **判据形式**: 查绝对事实（文件系统实况）；探针：让实现把报告写到当前工作目录或输入产物根 → 本条判红
- **类型**: 功能

### AC-026: 零第三方依赖 + 不联网
- **前置条件**: 被验包目录
- **测试步骤**: 扫描 `skills/test-report/` 下全部 `.mjs`：① 不得有非 `node:` 内置模块的 `import` / `require`（**含动态 `import('x')` 表达式**）；② 不得出现 `fetch(`；③ 相对路径 import 只允许指向**本 skill 内**的文件
- **预期结果**: 三项全满足；任一命中 → 判红并点名文件与行
- **判据形式**: 查绝对事实（扫描实际源码）；探针：在 `skills/test-report/` 里插入 `await import('lodash-es')` → 本条判红
- **类型**: 可移植性

---

## G 组：写入权（AC-027）

### AC-027: 不得修改输入产物的任何既有文件
- **前置条件**: §0.1 的执行产物目录
- **测试步骤**: 跑 `make-report.mjs` **之前**，对 `$FX/ART` 下**除 `report/` 之外**的每个文件算 sha256；跑完后再算一遍，逐个比对；并检查 `meta.json` / `results.json` 的**内容**未被改写
- **预期结果**: 全部文件的 sha256 **前后一致**；任何一份被改 → 判红并点名是哪个文件
- **判据形式**: 查绝对事实（文件系统指纹）；探针：让实现在生成报告时顺手改写 `meta.json`（如补一个字段）→ 本条判红
- **类型**: 写入权

---

## H 组：追溯与套件层组合（AC-028 ~ AC-029）

### AC-028: 交付侧记账必须与实际一致
- **前置条件**: 被验包目录 + `feature-meta/test-report/` 追溯件
- **测试步骤**: ① `feature-meta/test-report/` 下 `status.md` / `traceability.md` / `verification-report.md` / `manifest.json` 四件齐全且非空；② `traceability.md` 的**追溯矩阵行数**与本文件判据条数（**29**）相等，且编号集合恰为 AC-001~AC-029；③ 三份 md 各**恰一处**记载判据条数与决策号范围；④ 决策号范围与 `decisions.md` 的实际 D 集合一致；⑤ `feature-meta/manifest.json` 的 `req` 为 `REQ-010`
- **预期结果**: 五项全满足；任一不符 → 判红并点名
- **判据形式**: 查绝对事实（追溯件的实际内容 vs 契约的实际内容）；**不得**改写 REQ-011 / REQ-006 的既有追溯件（`feature-meta/` 根目录四件套与 `feature-meta/regression-plan/` 子目录必须**逐字未变**）
- **类型**: 追溯

### AC-029: 组合门必须覆盖第 5 个 skill
- **前置条件**: 被验包目录 + REQ-011 交付的组合门（`bin/test-agent-skills.mjs verify`）
- **测试步骤**: 跑组合门，检查：① 临时根**装齐 5 个 skill**（含 `test-report`）；② 依赖图校验通过；③ 跨 skill 组合场景**实跑**并产出结果；④ 版本错配时**报版本问题**（不是下游业务错）
- **预期结果**: 四项全满足；漏装 `test-report` → 判红；组合场景没真跑（只是查文件存在）→ 判红
- **判据形式**: 查绝对事实（组合门的真实退出码与输出）；探针：让组合门漏装 `test-report` → 本条判红
- **类型**: 功能

---

## 判据类型分布

| 组 | 条数 | 范围 |
|---|---|---|
| A 交付物形状 | 4 | AC-001 ~ AC-004 |
| B 产物解析与重算 | 5 | AC-005 ~ AC-009 |
| C 内部一致性与可核 | 4 | AC-010 ~ AC-013 |
| D 回归对账 | 5 | AC-014 ~ AC-018 |
| E 诚实性 | 5 | AC-019 ~ AC-023 |
| F 幂等与可复现 | 3 | AC-024 ~ AC-026 |
| G 写入权 | 1 | AC-027 |
| H 追溯与套件层组合 | 2 | AC-028 ~ AC-029 |
| **合计** | **29** | AC-001 ~ AC-029 |

## 验收纪律（对本 REQ 的验收方与实现者同样适用）

1. **一次只跑一个门** —— 并发跑门会产生无因果关系的失败键，污染判定。
2. **变异必须结构合法** —— 崩溃/语法错造成的判红是**假检出**，不计入检出率。
3. **变异注入后必须自证生效**（注入前后 sha256 比对），锚点必须逐字唯一命中 1 次。
4. **判定"是否被检出"只看目标判据是否出现在新增失败键集合里**（对称差），不能只看"比基线多"。
5. **不可判定标「不可判定」**，不得判 passed。
6. **任何"脚本全绿"的结论必须钉 sha256**（验收脚本自身 sha + 被验实现指纹）。
