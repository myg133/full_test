---
name: defect-verify
description: |
  Turn a defect report into a re-runnable reproduction case set: read defects.json plus an existing case set, decide for every defect whether it is reused (an existing case already covers it), derived (one new reproduction case is created), or unresolved (the report does not say enough to reproduce it, and that is said out loud with a reason), and emit defect-cases.json that test-execute can consume directly.
  Use this skill when the user asks to "缺陷复现"、"把缺陷沉淀成用例"、"缺陷单转用例"、"defect verify"、"reproduction cases"、"R3 缺陷验证", or when a defect report exists and nobody can say which case reproduces it.
  It answers "which case reproduces this defect, and why" — it does NOT execute the cases (that is test-execute), it does NOT design cases from a requirement (that is test-case-design), and it never changes the defect report or the case set.
---

# 缺陷复现用例生成（R3）

把一份**缺陷单**变成一份**可重跑的复现用例集**：缺陷单（`defects.json`）──► 处置判定 ──► 复现用例集（`defect-cases.json`）。

**处置判定一律走脚本。** 每条缺陷**有且只有一个**结论：

| 结论 | 含义 | 什么时候 |
|---|---|---|
| `reused` | **复用**已有用例 | `case_refs` 指到了用例集里存在的用例；或特征匹配（归一化后的步骤指纹）命中已有用例 |
| `derived` | **派生** 1 条新用例 | 没有任何已有用例能复现它，而缺陷单的信息足够复现 |
| `unresolved` | **显式说不知道**（带理由） | `case_refs` 指到的用例找不到；或缺陷单说不出怎么复现 |

> ⚠️ `unresolved` **不是失败**。把「不知道」悄悄变成「复用」或「派生」才是失败 ——
> 「显式说不知道」是这个 skill 存在的意义的一半。

## 怎么用

```console
# 1) 产复现用例集：在 R3 轮次目录里写 defect-cases.json（与 cycle.json 同级）
node scripts/make-defect-cases.mjs \
  --defects test-assets/inputs/defects.json \
  --cases test-assets/suites/REQ-001-coupon/cases.json \
  --suite REQ-001-coupon \
  --cycle-dir test-assets/cycles/R3-REQ-001

# 2) 校验产物是否自洽（字段集封闭、结论互斥、引用不悬空）
node scripts/check-defect-cases.mjs \
  test-assets/cycles/R3-REQ-001/defect-cases.json

# 3) 派生规则的单元自测（含共享场景 —— 验收夹具造不出来的那条分支）
node scripts/selftest-defect-cases.mjs
```

`--out-dir` 可选（默认 = `--cycle-dir`）。退出码：`0` 成功 / `1` 输入非法或违反写入纪律 / `2` 用法错误。

## 产物长什么样

`defect-cases.json` = 用例集 schema v2 的**超集**（多一个 `defects[]` 段）：

```
{
  "schema_version": 2,
  "meta": { "source": …, "generated_at": …, "case_count": …, "defect_count": …, "cycle_id": …, "suite": … },
  "requirements": [ { "id": "R-1", "title": "缺陷 BUG-001 的复现要求", "source_ref": "defects.json#/defects/0", "testable": true } ],
  "open_questions": [],
  "coverage_matrix": [ { "requirement": "R-1", "methods_applied": ["M1.1"], "skipped": [], "dimensions": ["functional"] } ],
  "defects": [ { "id": "BUG-001", "title": …, "severity": …, "status": …, "disposition": "reused", "reused_case_refs": [ … ] } ],
  "cases":  [ { "id": "TC-017", …, "defect_refs": ["BUG-001"], "origin": "reused", "source_case_id": "TC-017", "source_suite": … } ]
}
```

- 复现用例的 `tags` 含 `defect-verify` 与它复现的**每一个**缺陷 id ⇒ 执行侧可以按缺陷分批跑
  （`suite.json` 的 `tags.include` 写 `["BUG-001"]` 即可）。
- `requirements[]` **只含缺陷条目**（`R-1`…`R-<n>`，按缺陷在输入中的顺序），
  复现用例的 `requirement_refs` 一律指向「它所复现的那个缺陷」的 `R-<n>` ⇒ **不悬空**。

## 硬约束

- **只读输入**：缺陷单、已有用例集、`cycle.json` 一律不改写（逐字节未变）。
- **只写自己的输出目录**：产物**只有** `<out-dir>/defect-cases.json` 一个文件；
  产物已存在 ⇒ 报错退出（不覆盖别人的东西）；输出目录里有 `cycle.json` 以外的任何文件 ⇒ 报错退出。
- **幂等**：同一输入两次运行，除 `meta.generated_at` 外逐字相同。
- **轮次状态不由本 skill 写**：`cycle.json` 只读不改；推进轮次是 `test-case-design/scripts/cycle-state.mjs` 的活。
- **不产** R3 轮次的 `suite.json`（由项目侧提供）、**不产**缺陷验证报告（那是 `test-report` 的职责）、
  **不改**缺陷状态（那属缺陷管理系统）。
- **零第三方依赖、不联网**：只用 Node.js 内置模块。

## 判定规则在哪

- `references/defect-input-schema.md` —— 缺陷单格式（字段、必填、枚举、两层合法性划分）。
- `references/derivation-rules.md` —— 派生规则、编号约定、归一化口径、共享场景的裁定。
- `scripts/check-defect-cases.mjs` —— 产物自洽校验器（拿已产出的产物复核一份）。
