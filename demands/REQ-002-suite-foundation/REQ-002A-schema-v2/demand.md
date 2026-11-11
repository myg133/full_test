# 需求：测试套件基座 — Schema v2 与用例生命周期

- **需求编号**: REQ-002A
- **所属 Epic**: REQ-002 suite-foundation
- **优先级**: P0
- **状态**: 已就绪

## 需求描述

### 背景

REQ-001 交付了 `test-case-design` skill（npm 包 `test-agent-skills@0.1.0`）。REQ-001 的 eval 对比（同一份需求，baseline 裸模型跑 3 次 vs with-skill 跑 1 次）暴露了三个已验证存在的缺陷：

| 缺陷 | 实测证据 |
|---|---|
| **产出变少** | baseline 62/56/48 条（均值 55），with-skill 29 条；逐行为点对比漏掉「用户最多用 1 张券」与「实付金额非负」 |
| **核心卖点未落地** | skill 主张"显式暴露需求歧义"，但未决问题只写进人读的 `report.md`；机器可读的 `cases.json` 里 `open_questions` 字段不存在、`pending_ruling` 标注 0 条。而 baseline 三次都把 5–10 条假设放进了 `meta.assumptions` |
| **缺少用例生命周期** | R2 回归轮要"调整测试用例"，但 `cases[]` 是静态的，无状态字段——改完丢失痕迹，无法回答"这条用例为什么变了" |

### 目标

本 REQ 只做一件事：**让 skill 的产出契约变成可强制、可审计、可迭代的机器可读格式**。

**这不是做测试，是做"做测试的规约"**——交付物是给另一个模型执行的 schema 与校验器，不是测试用例。

### 范围边界

**在范围内**：
- `cases.json` schema v2：`open_questions[]` / `method` / `coverage_matrix[]` / 用例生命周期状态
- `validate-cases.mjs` 升级：强制新契约
- `render-report.mjs` 升级：输出 v2 新增维度
- `references/case-schema.md` 更新
- 向后兼容策略

**不在范围内**（属 REQ-002B / 后续子 REQ）：
- 方法库 `catalog.json` 与 M0–M4 详库（002.2）
- `SKILL.md` 重写与运行时工作区契约（002.2）
- `test-assets/` 目录契约与 `verify-layout.mjs`（002.3）
- `.tools` 自举机制（002.4）
- 执行器、证据链、回归/缺陷/安全/压测 skill（002.5+）

## 功能要求

### F1 schema v2 新增字段

#### F1.1 `open_questions[]`（顶层数组）

```json
{
  "id": "Q1",
  "question": "「连续发送 3 次后需等待 5 分钟」中，第 3 次发送本身是否允许？",
  "requirement_refs": ["R-4"],
  "interpretations": [
    { "reading": "第 3 次允许发出，随后进入冷却", "impact": "单周期最多下发 3 封邮件" },
    { "reading": "第 3 次即被拒", "impact": "单周期最多下发 2 封邮件" }
  ],
  "affected_cases": ["TC-017", "TC-024"],
  "severity": "blocking",
  "coverage": "cases"
}
```

| 字段 | 必填 | 约束 |
|---|---|---|
| `id` | 是 | 唯一，匹配 `^Q\d+$` |
| `question` | 是 | 非空 |
| `requirement_refs` | 是 | 非空数组，每项须存在于 `requirements[].id` |
| `interpretations` | 是 | **至少 2 条**，每条含非空 `reading` 与 `impact` |
| `affected_cases` | 否 | 每项须存在于 `cases[].id` |
| `severity` | 是 | 枚举 `blocking` / `non-blocking` |
| `coverage` | 是 | 枚举 `cases` / `deferred`；`deferred` 时须填 `defer_reason` |

**`interpretations` ≥ 2 条是硬要求**——只列一种解读等于已经替需求方做了裁定，这正是要消灭的行为。

#### F1.2 `cases[].method`（字符串数组）

取值来自方法库编号（`M0.1` 等，格式 `^M\d+\.\d+$`）。REQ-002A 阶段方法库尚未落地（属 002.2），故本阶段校验器**只校验格式**，不校验编号是否存在于某个库。

#### F1.3 `coverage_matrix[]`（顶层数组）

```json
{
  "requirement": "R-3",
  "methods_applied": ["M0.1", "M0.2", "M0.5", "M4.5"],
  "skipped": [
    { "method": "M0.4", "reason": "该条目为纯计算无状态流转" }
  ],
  "dimensions": ["functional", "boundary", "data"]
}
```

| 字段 | 必填 | 约束 |
|---|---|---|
| `requirement` | 是 | 须存在于 `requirements[].id` |
| `methods_applied` | 是 | 非空数组，元素须匹配方法编号格式 |
| `skipped` | 否 | 数组，每项含 `method` + **非空 `reason`** |
| `dimensions` | 否 | 数组 |

**`skipped[].reason` 为空 → 校验失败。** 这是防止"跳过不留痕"的关键——REQ-001 的用例变少，根因正是跳过完全不可见。

#### F1.4 用例生命周期状态

```json
{
  "id": "TC-017",
  "status": "active",
  "revision": {
    "previous_status": "active",
    "change": "changelog 提到门槛改为 199，期望值相应调整",
    "changed_at": "2026-11-11",
    "triggered_by": "CHANGELOG-2.3"
  }
}
```

- `status` 枚举：`active` / `deprecated` / `modified` / `blocked`
- `revision` 可选，但 `status` 非 `active` 时**必填**，且须含非空 `change`
- `deprecated` 的用例**不参与覆盖统计**（不算作"已覆盖"）

### F2 校验器升级（`scripts/validate-cases.mjs`）

**必须检出并以退出码 1 报告**：

| # | 缺陷类型 | 判定 |
|---|---|---|
| 1 | `open_questions[].interpretations` 少于 2 条 | ERROR |
| 2 | `open_questions[].interpretations[].reading` 或 `.impact` 为空 | ERROR |
| 3 | `open_questions[].requirement_refs` 悬空引用 | ERROR |
| 4 | `open_questions[].affected_cases` 悬空引用 | ERROR |
| 5 | `severity: "blocking"` 且 `coverage: "deferred"` 但 `defer_reason` 为空 | ERROR |
| 6 | `coverage_matrix[].requirement` 悬空引用 | ERROR |
| 7 | `coverage_matrix[].methods_applied` 为空 | ERROR |
| 8 | `coverage_matrix[].skipped[].reason` 为空或缺失 | ERROR |
| 9 | `cases[].method` 元素格式非法 | ERROR |
| 10 | `cases[].status` 取值非法 | ERROR |
| 11 | `cases[].status` 非 `active` 但 `revision` 缺失或 `change` 为空 | ERROR |
| 12 | 同一需求条目在 `coverage_matrix` 中出现多次 | ERROR |

**向后兼容规则（关键）**：

| 情况 | 判定 |
|---|---|
| 完全没有 `open_questions` 字段 | **WARN**（不是 ERROR）——REQ-001 产出的既有用例集必须仍能通过 |
| 没有 `coverage_matrix` 字段 | **WARN** |
| `cases[].method` 缺失 | **WARN** |
| `cases[].status` 缺失 | **WARN**，按 `active` 处理 |
| 显式声明 `"schema_version": 2` | 上述 WARN 全部升级为 **ERROR**——声明了 v2 就要守 v2 的规矩 |

**通过时的输出**（在现有基础上增加）：

```
需求条目总数: N
可测试条目数: N
用例总数: N（active: N / deprecated: N / blocked: N）
按维度分布: ...
未覆盖需求条目: ...
未决问题数: N（blocking: N）
覆盖矩阵条目数: N（其中带跳过声明: N）
```

### F3 渲染脚本升级（`scripts/render-report.mjs`）

在现有三部分（用例总览 / 追溯矩阵 / 未覆盖清单）之外增加：

- **未决问题章节**：逐条列出 `question` / 各解读及其影响 / 受影响用例 ID / severity
- **覆盖矩阵章节**：需求条目 → 已应用方法 / 跳过方法及原因

`deprecated` 状态的用例在总览表中标注，但**不计入"已覆盖"**。

### F4 文档更新

`references/case-schema.md` 需完整描述 v2 schema：新增字段、语义、必填性、向后兼容规则。

## 非功能要求

- **性能**：500 条用例的用例集，校验 < 2 秒（REQ-001 实测 63ms，不得劣化到秒级）
- **零依赖**：脚本只用 `node:` 内置模块
- **可移植**：不含 bash / python3 / `/tmp` / grep / sed
- **诊断质量**：每个报错要能定位到具体路径（如 `open_questions[0].interpretations[1].reading`），不能只说"格式错误"
- **向后兼容**：REQ-001 产出的既有用例集在无 `schema_version` 声明时仍能通过校验（退出码 0，最多 WARN）

## 验收要点

见 `acceptance.md`（12 条 AC）。
