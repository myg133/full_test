# `regression-plan.json` 字段契约

> 产出脚本：`scripts/plan-regression.mjs`；校验脚本：`scripts/check-plan.mjs`。
> 产物落在**轮次目录内**（调用方给的 `--cycle-dir`，与 `cycle.json` 同级）。

## 顶层结构

```jsonc
{
  "schema_version": 1,                  // 固定 1
  "cycle_id": "R2-CHANGELOG-2.3",       // 轮次标识 = 回归轮次(R2) + 变更集标识（变更日志文件名去扩展名），**由输入决定，不取输出目录名**
  "generated_at": "2026-11-13T00:00:00Z",// 生成时间戳（幂等自验时唯一允许变动的字段）
  "source": {
    "changelog": "CHANGELOG-2.3.md",    // 输入来源（命令行给的原样路径）
    "cases": "test-assets/suites/REQ-001-coupon/cases.json"
  },
  "changes": [ /* 变更条目及其影响面 */ ],
  "selected": [ /* 确定重跑的用例 */ ],
  "needs_review": [ /* 需人工复核的用例 */ ],
  "undecidable_changes": [ /* 判不了的变更条目 */ ],
  "summary": { /* 与上面三个集合的长度逐字相等 */ }
}
```

## `changes[]` —— 变更条目及其影响面

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | string | `C-1`、`C-2`…（按 changelog 出现顺序） |
| `title` | string | 该条目的标题文本 |
| `requirement_refs` | string[] | 正文里的 `@R-<n>`（去重，保持出现顺序） |
| `case_refs` | string[] | 正文里的 `@TC-<nnn>`（去重，保持出现顺序） |
| `dimensions` | string[] | 该条目命中的**全部**维度（显式 + 信号词），按维度库顺序 |
| `explicit_dimensions` | string[] | 仅显式 `@dim:<name>` 命中的维度 |
| `signal_dimensions` | `{dimension, signal}[]` | 信号词命中的维度与命中的那个词 |
| `method_hits` | string[] | 正文逐字命中 `not_applies_when` 的方法 id |

## `selected[]` / `needs_review[]` —— 用例归属

| 字段 | 类型 | 说明 |
|---|---|---|
| `case_id` | string | 用例 id（必须真实存在于输入用例集） |
| `reason` | string | 可解释的来源标记（非空）：`requirement_ref:` / `case_ref:` / `dim_ref:` / `dim_signal:` / `method_not_applies:` |
| `change_refs` | string[] | 支撑该归属的变更条目 id（非空，且都存在于 `changes[].id`） |

- `selected` = 确定重跑；`needs_review` = 需人工复核（方法在本次场景下不适用）。
- 两个集合**互斥**：一条用例不会同时出现在两边。
- `reason` 必须指向**该用例自己**的命中路径：`case_ref:` 指向本用例、`requirement_ref:` 只在
  本用例确实引用该需求条目时给出、`dim_ref:` / `dim_signal:` 指向本用例所用的维度。

## `undecidable_changes[]` —— 判不了的变更条目

| 字段 | 类型 | 说明 |
|---|---|---|
| `change_id` | string | 变更条目 id |
| `reason` | string | 非空，说明为什么判不了 |

这类条目**不得**出现在任何 `selected` 条目的 `change_refs` 里。

## `summary`

| 字段 | 说明 |
|---|---|
| `total_cases` | 输入用例集 `cases[]` 的长度 |
| `selected` | `selected[]` 的长度 |
| `needs_review` | `needs_review[]` 的长度 |
| `undecidable_changes` | `undecidable_changes[]` 的长度 |
| `impact_complete` | `undecidable_changes` 为空时 `true`，否则 `false`（判不了 ≠ 没影响） |

每个数字都与对应集合的长度**逐字相等**。

## 不变式（校验脚本逐条查）

1. 输出的 `case_id` 全部存在于输入用例集；
2. `selected` / `needs_review` 与按输入+库重算的结果**逐项相等**；
3. `undecidable_changes` 与重算结果相等；
4. `summary` 的每个数字与对应集合长度相等，`impact_complete` 与判不了条数不矛盾；
5. `selected` ∩ `needs_review` = ∅；
6. 同一输入两次跑，除 `generated_at` 外**逐字相同**（含写到不同轮次目录的情形 —— `cycle_id` 由输入决定）。
