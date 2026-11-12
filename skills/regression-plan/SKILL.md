---
name: regression-plan
description: |
  Plan the R2 regression selection from a changelog plus an existing test case set: split the changelog into change entries, decide each entry's impact surface against the requirement items, cases, coverage dimensions and test methods it actually references, and emit a machine-checkable regression-plan.json that says which cases must be re-run, which cases need human review, and which changes cannot be decided.
  Use this skill when the user asks to "做回归选样"、"回归跑哪些用例"、"变更影响分析"、"这个变更要重跑哪些用例"、"regression plan"、"impact analysis", or when a changelog exists and a case set is already there but nobody can say which cases the change touches.
  It answers "which cases does this change affect, and why" — it does NOT execute the cases (that is test-execute), it does NOT design new cases (that is test-case-design), and it never rewrites the case set.
---

# 回归选样（R2）

把一份变更日志变成**一份可复算的选样结论**：哪些用例要重跑、哪些要人工复核、哪些变更判不了。

**影响面判定一律走脚本。** 本 skill 没有「按经验估影响面」这种用法 ——
判定口径只有一份，就是 `scripts/plan-regression.mjs` 里的那套公式（见 `references/impact-rules.md`）。

## 怎么用

```console
# 1) 产计划：在轮次目录内写 regression-plan.json（与 cycle.json 同级）
node scripts/plan-regression.mjs \
  --changelog CHANGELOG-2.3.md \
  --cases test-assets/suites/REQ-001-coupon/cases.json \
  --cycle-dir test-assets/cycles/R2-CHANGELOG-2.3

# 2) 校验计划是否与输入自洽（重算一遍并逐项比对）
node scripts/check-plan.mjs \
  --plan test-assets/cycles/R2-CHANGELOG-2.3/regression-plan.json \
  --cases test-assets/suites/REQ-001-coupon/cases.json \
  --changelog CHANGELOG-2.3.md
```

可选参数：`--dimensions <file>` / `--methods <file>`（不传则回落到同包内
`test-case-design/references/` 下的那两份 —— 库的唯一来源在那里，本 skill 不另存副本）、
`--json`（把计划打到 stdout）。

退出码：`0` 成功 / `1` 输入或引用非法 / `2` 用法错误。

## 三类后果各是什么

| 集合 | 含义 | 谁来处理 |
|---|---|---|
| `selected` | **确定重跑** —— 落在影响面内、且它所用的方法在本次变更场景下适用 | 直接交给 `test-execute` 排期 |
| `needs_review` | **需人工复核** —— 落在影响面内，但它所用的方法在本次变更场景下**不适用**（方法库的 `not_applies_when` 被变更正文命中），影响面判不了 | 人工判一次：这条用例到底该不该跑 |
| `undecidable_changes` | **判不了** —— 变更条目既无显式引用，正文也未命中任何维度/方法信号 | 人工补引用或补上下文后重跑本脚本 |

> ⚠️ **判不了的变更条目不得当成没有影响**：它只是「本脚本判不了」，不是「没有影响」。
> 它会让 `summary.impact_complete` 变成 `false` —— 看到这个字段为 `false`，
> 就说明影响面**不完整**，不能当成「影响面已覆盖」往下走。

## 硬约束

- **只读输入**：用例集（`cases.json`）与变更日志一律不改；R2 只出计划，改用例属设计流程的事。
- **引用不存在即报错**：变更日志里的 `@R-<n>` / `@TC-<nnn>` / `@dim:<name>` 在输入或库里找不到，
  脚本**报错退出（退出码 1）并点名那个 id** —— 不静默忽略（静默忽略 = 悄悄漏测）。
- **不造用例**：输出里的 `case_id` 必须真实存在于输入用例集。
- **两个集合互斥**：一条用例要么在 `selected`，要么在 `needs_review`，不会同时在两边。
- **轮次状态不由本 skill 写**：`cycle.json` / `cycles/index.json` 只由
  `test-case-design/scripts/cycle-state.mjs` 推进，本 skill 不碰它们。
- **零第三方依赖、不联网**：只用 Node.js 内置模块。

## 判定规则在哪

- `references/impact-rules.md` —— 影响面判定的规则与公式（需求条目 / 用例 / 维度三条命中路径、
  方法不适用如何变成「需人工复核」、生命周期状态如何参与）。
- `references/regression-plan-schema.md` —— `regression-plan.json` 的字段契约。
