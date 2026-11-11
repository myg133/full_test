# 用例 JSON Schema 与字段语义

用例集是**单个 JSON 文件**，由 `scripts/validate-cases.mjs` 强制校验。

当前版本：**schema v2**。v2 在 v1 基础上新增未决问题、覆盖矩阵与用例生命周期三组字段；
未声明 `"schema_version": 2` 的旧用例集（v1 结构）仍可校验通过，详见「向后兼容规则」。

## 顶层结构

```json
{
  "schema_version": 2,
  "meta": {
    "source": "需求来源标识",
    "generated_at": "2026-11-11T10:20:00+08:00",
    "case_count": 3
  },
  "requirements": [
    { "id": "R-1", "title": "需求条目标题", "source_ref": "原文摘录或位置", "testable": true },
    { "id": "R-2", "title": "另一条需求条目", "source_ref": "原文摘录或位置", "testable": true }
  ],
  "open_questions": [
    {
      "id": "Q1",
      "question": "「连续发送 3 次后需等待 5 分钟」中，第 3 次发送本身是否允许？",
      "requirement_refs": ["R-1"],
      "interpretations": [
        { "reading": "第 3 次允许发出，随后进入冷却", "impact": "单周期最多下发 3 封邮件" },
        { "reading": "第 3 次即被拒", "impact": "单周期最多下发 2 封邮件" }
      ],
      "affected_cases": ["TC-001", "TC-003"],
      "severity": "blocking",
      "coverage": "cases"
    }
  ],
  "coverage_matrix": [
    {
      "requirement": "R-1",
      "methods_applied": ["M0.1", "M0.2", "M0.5", "M4.5"],
      "skipped": [{ "method": "M0.4", "reason": "该条目为纯计算无状态流转" }],
      "dimensions": ["functional", "boundary", "data"]
    },
    {
      "requirement": "R-2",
      "methods_applied": ["M0.1"],
      "skipped": [],
      "dimensions": ["functional"]
    }
  ],
  "cases": [
    {
      "id": "TC-001",
      "title": "用例标题",
      "requirement_refs": ["R-1"],
      "dimension": "functional",
      "priority": "P0",
      "method": ["M0.1", "M4.5"],
      "status": "active",
      "preconditions": [],
      "steps": [{ "action": "操作", "expected": "预期结果" }],
      "data": {},
      "tags": []
    },
    {
      "id": "TC-002",
      "title": "已废弃的用例",
      "requirement_refs": ["R-2"],
      "dimension": "functional",
      "priority": "P1",
      "method": ["M0.1"],
      "status": "deprecated",
      "revision": {
        "previous_status": "active",
        "change": "需求条款被删除，该用例不再有对应需求条目",
        "changed_at": "2026-11-11",
        "triggered_by": "CHANGELOG-2.3"
      },
      "steps": [{ "action": "操作", "expected": "预期结果" }]
    },
    {
      "id": "TC-003",
      "title": "因门槛调整而修改的用例",
      "requirement_refs": ["R-1"],
      "dimension": "boundary",
      "priority": "P0",
      "method": ["M0.2", "M0.5"],
      "status": "modified",
      "revision": {
        "previous_status": "active",
        "change": "changelog 提到门槛改为 199，期望值相应调整",
        "changed_at": "2026-11-11",
        "triggered_by": "CHANGELOG-2.3"
      },
      "steps": [{ "action": "操作", "expected": "预期结果" }]
    }
  ]
}
```

> 上例中 `R-2` 出现在「未覆盖需求条目」清单里是**刻意**的：唯一引用它的 `TC-002` 已被
> `deprecated`，废弃用例不计入覆盖。用来演示废弃语义，不是示例写错。

## 顶层字段总览

| 字段 | 类型 | v2 必填 | 语义 |
|------|------|------|------|
| `schema_version` | number | 否 | 写 `2` 表示本文件声明遵守 v2 契约；缺省时按 v1 宽松规则校验 |
| `meta` | object | 否 | 报告抬头元信息，不参与覆盖计算 |
| `requirements` | object[] | 是 | 需求条目数组 |
| `open_questions` | object[] | 是¹ | 未决问题清单（v2 新增） |
| `coverage_matrix` | object[] | 是¹ | 需求条目 → 方法覆盖矩阵（v2 新增） |
| `cases` | object[] | 是 | 用例数组 |

¹ 「必填」指声明了 `"schema_version": 2` 时必填；未声明时缺失只报 WARN（见「向后兼容规则」）。

## `meta`

| 字段 | 类型 | 语义 |
|------|------|------|
| `source` | string | 需求来源标识（文档名、链接、需求单号），让人能回溯到原始需求 |
| `generated_at` | string | 生成时间，ISO-8601 |
| `case_count` | number | 用例总数，与 `cases` 数组长度一致（不一致只报 WARN） |

`meta` 用于报告抬头，不参与覆盖计算。

## `requirements[]`（需求条目）

| 字段 | 类型 | 必填 | 语义 |
|------|------|------|------|
| `id` | string | 是 | 需求条目 ID，约定 `R-<序号>`，全局唯一 |
| `title` | string | 建议 | 条目标题，追溯矩阵里显示 |
| `source_ref` | string | 建议 | 原文摘录或位置（章节号、页码、引用句） |
| `testable` | boolean | 建议 | 是否可测试点；`false` 表示背景叙述等不生成用例 |

`id` 必须存在且唯一——`cases[].requirement_refs`、`open_questions[].requirement_refs`、
`coverage_matrix[].requirement` 都通过它建立追溯关系。`title` / `source_ref` 缺失不影响校验，
但追溯矩阵的可读性会下降。

## `open_questions[]`（未决问题，v2 新增）

未决问题是「需求本身有多种合理解读、需求方尚未裁定」的地方。
**只列一种解读等于已经替需求方做了裁定**，因此 `interpretations` 至少 2 条是硬要求。

| 字段 | 类型 | 必填 | 约束 | 语义 |
|------|------|------|------|------|
| `id` | string | 是 | 匹配 `^Q\d+$`，全局唯一 | 未决问题编号，`Q1` 起递增 |
| `question` | string | 是 | 非空 | 问题描述：把歧义本身说清楚 |
| `requirement_refs` | string[] | 是 | 非空数组，每项必须存在于 `requirements[].id` | 这个歧义牵涉哪些需求条目 |
| `interpretations` | object[] | 是 | **至少 2 条**，每条含非空 `reading` 与 `impact` | 各条合理解读及其后果 |
| `affected_cases` | string[] | 否 | 每项必须存在于 `cases[].id` | 受该歧义影响的用例 |
| `severity` | string | 是 | `blocking` / `non-blocking` | 不裁定会不会导致返工 |
| `coverage` | string | 是 | `cases` / `deferred` | 用例是否已覆盖该歧义 |
| `defer_reason` | string | 条件 | `coverage: "deferred"` 时必填且非空 | 延后裁定的理由 |

### `interpretations[]`

```json
{ "reading": "第 3 次允许发出，随后进入冷却", "impact": "单周期最多下发 3 封邮件" }
```

- `reading`：一种合理解读怎么读需求。
- `impact`：按这种解读，行为/期望结果会有什么不同。两条解读的 `impact` 不同才说明它们真的互相冲突。

## `coverage_matrix[]`（覆盖矩阵，v2 新增）

覆盖矩阵回答「每个需求条目用了哪些测试方法、跳过了哪些方法、为什么跳过」。
**跳过不留痕**是用例产出变少却无人察觉的根因，因此 `skipped[].reason` 为空即校验失败。

| 字段 | 类型 | 必填 | 约束 | 语义 |
|------|------|------|------|------|
| `requirement` | string | 是 | 必须存在于 `requirements[].id`；全局唯一 | 需求条目 ID |
| `methods_applied` | string[] | 是 | 非空数组，元素匹配 `^M\d+\.\d+$` | 该条目已应用的方法编号 |
| `skipped` | object[] | 否 | 每项含合法 `method` 与**非空 `reason`** | 跳过的方法及原因 |
| `dimensions` | string[] | 否 | 数组 | 该条目覆盖到的维度 |

### `skipped[]`

```json
{ "method": "M0.4", "reason": "该条目为纯计算无状态流转" }
```

- `method`：被跳过的方法编号，格式同 `methods_applied`。
- `reason`：为什么跳过。必须是具体理由（"不适用"不算），否则等于没留痕。

> 方法编号格式 `^M\d+\.\d+$`（如 `M0.1`、`M4.5`）。当前阶段只校验格式，
> 不校验该编号是否真实存在于方法库中。

## `cases[]`（用例）

| 字段 | 类型 | 必填 | 约束 | 语义 |
|------|------|------|------|------|
| `id` | string | 是 | 匹配 `^TC-\d{3}$`，全局唯一 | 用例编号，`TC-001` 起递增 |
| `title` | string | 是 | 非空 | 一句话说清这条用例验证什么 |
| `requirement_refs` | string[] | 是 | 非空数组，每项必须存在于 `requirements[].id` | 这条用例覆盖哪些需求条目（可多选） |
| `dimension` | string | 是 | 8 个枚举值之一 | 覆盖维度，见 `coverage-dimensions.md` |
| `priority` | string | 是 | `P0` / `P1` / `P2` / `P3` | 缺陷漏掉的代价分级 |
| `method` | string[] | 是² | 元素匹配 `^M\d+\.\d+$` | 这条用例用了哪些测试方法（v2 新增） |
| `status` | string | 是² | `active` / `deprecated` / `modified` / `blocked` | 用例生命周期状态（v2 新增） |
| `revision` | object | 条件 | `status` 非 `active` 时必填，且 `change` 非空 | 修订记录（v2 新增） |
| `preconditions` | string[] | 否 | 数组 | 前置条件（环境、账号、数据状态） |
| `steps` | object[] | 是 | 至少 1 条，每条含非空 `action` 与 `expected` | 执行步骤 |
| `data` | object | 否 | 对象 | 用例数据（入参、期望值、样本集） |
| `tags` | string[] | 否 | 数组 | 自由标签，便于按标签筛选 |

² 声明 `"schema_version": 2` 时必填；未声明时缺失只报 WARN，并按 `status: active` 处理。

### `steps[]`

```json
{ "action": "在登录页输入用户名 alice 与密码 12345678", "expected": "页面跳转到工作台并显示 alice" }
```

- `action`：可执行的动作描述。写清输入什么、点哪里、调用什么接口。
- `expected`：**可判定**的结果。避免"显示正常""功能可用"这类无法判断通过与否的表述；写清看到什么、返回什么值、什么状态。

### `status`（生命周期，v2 新增）

| 取值 | 语义 | 是否计入覆盖 |
|------|------|------|
| `active` | 现行有效用例 | 是 |
| `deprecated` | 已废弃（需求变了或被删除），保留痕迹但不再执行 | **否** |
| `modified` | 相对上一版本被修改过，细节见 `revision` | 是 |
| `blocked` | 被外部因素阻塞（如环境不可用、依赖未就绪） | 是 |

`deprecated` 的用例在报告的用例总览表里仍会列出并标注，但**不计入"已覆盖"**：
它覆盖的需求条目仍会出现在「未覆盖需求条目」清单中，防止"把废弃当覆盖"来粉饰覆盖率。

### `revision`（修订记录，v2 新增）

`status` 非 `active` 时必填，`change` 必须非空——否则「这条用例为什么变了」就无从回答。

| 字段 | 类型 | 必填 | 语义 |
|------|------|------|------|
| `previous_status` | string | 否 | 变更前的状态，取值同 `status` |
| `change` | string | 是 | 改了什么，为什么改（不能为空） |
| `changed_at` | string | 否 | 变更日期，ISO-8601 |
| `triggered_by` | string | 否 | 变更触发源，如 `CHANGELOG-2.3`、需求单号 |

## 向后兼容规则

`schema_version` 决定严格程度。**缺省（v1 结构）走宽松模式**：

| 情况 | 未声明 `schema_version` | 声明 `"schema_version": 2` |
|------|------|------|
| 完全没有 `open_questions` 字段 | WARN | **ERROR** |
| 完全没有 `coverage_matrix` 字段 | WARN | **ERROR** |
| `cases[].method` 缺失 | WARN | **ERROR** |
| `cases[].status` 缺失 | WARN（按 `active` 处理） | **ERROR** |

要点：

- 宽松的是「**缺字段**」这一件事。字段一旦存在，**内容非法一律 ERROR**，两种模式都一样。
- 所以 v1 用例集（无 `open_questions` / `coverage_matrix` / `method` / `status`）仍然退出码 0，
  只是带一批 WARN；一旦补上 `"schema_version": 2`，同一份文件就会因缺字段而退出码 1。
- `cases[].status` 缺失按 `active` 处理，因此不影响覆盖统计。
- `schema_version` 写成 2 以外的数字（除 1 外）：报一条 WARN，按 v1 宽松规则校验。
- `schema_version: 1` 表示显式声明 v1，按宽松规则校验，不报 WARN。

## 编号约定

- 需求条目：`R-1`、`R-2`、`R-3`…… 按需求原文顺序编号，条目被删除后不复用旧号（避免历史引用错位）。
- 用例：`TC-001`、`TC-002`…… 连续编号，与需求条目编号相互独立。
- 未决问题：`Q1`、`Q2`…… 连续编号。
- 用例只属于一个覆盖维度；一条需求条目被多个维度覆盖时，拆成多条用例，各自 `requirement_refs` 指回同一条目。

## 覆盖与追溯

- 一条需求条目被覆盖 = 至少一条**非 `deprecated`** 用例的 `requirement_refs` 含它的 `id`。
- 未被任何用例引用的需求条目出现在报告的"未覆盖"清单里，`validate-cases.mjs` 与 `render-report.mjs` 都会输出。
- `testable: false` 的条目同样计入未覆盖清单——它是"显式判定为不覆盖"，报告里靠 `可测试` 列区分，避免把"判定不可测"和"漏设计"混为一谈。
- `coverage_matrix` 是覆盖的**方法视角**：追溯矩阵回答"有没有用例"，覆盖矩阵回答"用了哪些方法、跳过了什么"。两者互补，缺一不可。

## 校验命令

```
node scripts/validate-cases.mjs cases.json
```

退出码 0 = 通过，1 = 失败（逐条列出问题），2 = 用法错误。
每条问题都带具体 JSON 路径（如 `open_questions[0].interpretations[1].reading 不能为空`），可直接定位。

通过时输出需求条目总数、可测试条目数、用例总数（含状态分布）、按维度分布、未覆盖需求条目 ID 列表、
未决问题数（含 blocking 数）、覆盖矩阵条目数（含带跳过声明的条目数）。

## 渲染命令

```
node scripts/render-report.mjs cases.json
```

输出 Markdown 报告，五部分：用例总览 / 追溯矩阵 / 未覆盖需求条目 / 未决问题 / 覆盖矩阵。
