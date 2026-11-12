# 影响面判定规则（R2 选样口径）

> 判定口径只有一份：`scripts/plan-regression.mjs`（及其 `scripts/lib/`）。
> 本文件是那份公式的**人读说明**，用于复核与解释，不是第二套判定。

## 一、变更条目的切分

- 按 changelog 里的**二级及以下标题**（`##` ~ `######`）切分成变更条目；
- 逐条自动编号 `C-1`、`C-2`…（编号按出现顺序，与正文顺序一致）；
- 条目的**正文** = 标题行 + 其后到下一个标题之前的全部行 —— 标记检索与信号词检索都在这个范围内；
- 一级标题（`#`）不切条目。

## 二、三条可复算的命中路径

变更条目的影响面 = 下列三条来源的**并集**：

| 来源 | 判定方式 | 记进 `reason` 的形式 |
|---|---|---|
| 需求条目命中 | 条目正文含 `@R-<n>` | `requirement_ref:R-<n>` |
| 用例命中 | 条目正文含 `@TC-<nnn>` | `case_ref:TC-<nnn>` |
| 维度命中（显式） | 条目正文含 `@dim:<维度名>` | `dim_ref:<维度名>` |
| 维度命中（隐式） | 条目正文命中该维度的 `applies_when` 信号词 | `dim_signal:<维度名>(<信号词>)` |

**维度为什么有隐式路径**：人写 changelog 时不会为每条都打 `@dim:` 标签。信号词命中是
**可解释、可复核**的（命中了哪个词 → 记进 `reason`），且它的偏差方向是「多选」（多跑），
属可容忍方向。

**`reason` 必须指向该用例自己的命中路径**：`case_ref:` 指向本用例自己；`requirement_ref:`
只在本用例确实引用该需求条目时给出；`dim_ref:` / `dim_signal:` 指向本用例所用的维度。
不得拿「变更条目里恰好出现的第一个引用」冒充命中路径 —— 那会让一条用例的 `reason`
指向另一条用例或另一条需求。

**维度库与方法库的唯一来源**是同包内 `test-case-design/references/` 下的那两份 JSON
（`dimensions.json` / `methods.json`）。本 skill **不另存副本**，也不硬编码维度清单或方法清单。

## 三、用例的归属

```text
affected(case)   = 需求命中 ∨ 用例命中 ∨ 维度命中（显式或信号词）
method_blocked   = ∃ 变更条目, ∃ case.method 中的方法 m
                   : 该变更条目的正文命中 m.not_applies_when 的某一条短语
selected(case)   = affected(case) ∧ ¬method_blocked(case) ∧ case.status == "active"
needs_review(case)= affected(case) ∧  method_blocked(case)
```

- **`method_blocked` 为什么是「隐式命中」**：该方法在本次变更场景下**不适用** →
  影响面**判不了** → 进 `needs_review` 交给人，**不得**静默当成「不受影响」。
  命中按**逐字包含**判定（变更正文里出现该短语即算命中）。
- **方法不适用是场景级事实**：只要**任意**一条变更条目命中了某方法的 `not_applies_when`，
  用了该方法的用例就被挡住 —— 哪怕那条变更条目本身不在该用例的影响面内。
- **生命周期状态只作用于 `selected`**：`status != "active"` 的用例不进 `selected`
  （它可能已废弃/已实现，重跑它没有意义）；但它若被方法挡住，仍会进 `needs_review`
  —— 「判不了就得说出来」，不能因为用例已废弃就悄悄丢掉。
- **两个集合互斥**：一条用例不会同时出现在 `selected` 与 `needs_review`。

## 四、判不了的变更条目

同时满足下面两条的变更条目 → 进 `undecidable_changes[]`：

1. 正文里既没有 `@R-<n>` / `@TC-<nnn>` / `@dim:<name>`；
2. 正文既未命中任何维度的 `applies_when` 信号词，也未命中任何方法的 `not_applies_when` 短语。

这类条目**不得**让任何用例进 `selected`，且必须显式列出并给出非空 `reason`；
存在这类条目时 `summary.impact_complete` 必为 `false`。

## 五、坏引用一律报错

变更正文里的 `@R-<n>` / `@TC-<nnn>` / `@dim:<name>` 在输入用例集或库里找不到时，
脚本**报错退出（退出码 1）并点名那个 id**。静默忽略 = 悄悄漏测，不可容忍。

## 六、两条「诚实」红线

1. **不得凭空造用例**：输出的 `case_id` 必须真实存在于输入用例集。
2. **不得假装覆盖**：影响面不完整时必须由 `summary.impact_complete = false` 声明出来，
   而不是让读者从别的字段推断。
