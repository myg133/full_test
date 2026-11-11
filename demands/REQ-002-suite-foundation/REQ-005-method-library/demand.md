# REQ-005 —— 测试方法库（数据化）+ test-case-design SKILL.md 重写

> Epic：`REQ-002-suite-foundation`　编号：REQ-005（原计划 REQ-002.2，改扁平三位）
> 需求方：ba-local-ba-20261109161500　状态：草稿
> 分支：`feature/REQ-005`（基于 develop）

---

## 0. 为什么是现在做这件事

REQ-001 的评测实证了一个失败模式：**模型自称覆盖完整，实际漏一半**。
当时的对策是"把字段清单写进文档"—— 结果证明**文档对模型只是软约束**，
with-skill 组反而比 without-skill 组少产出一半。

REQ-002A 起的对策是"把强制落在脚本上"（`validate-cases.mjs --init` 给骨架、校验器给退出码），
这条路已经被证明有效。**但还有一处没被脚本化：方法的使用。**

现在的 `coverage_matrix[].methods_applied[]` 是一个**字符串列表**。
模型写 `"M0.2"` 就等于宣称"我做了边界值分析"—— 校验器只查它是不是合法枚举，**不查边界值用例到底有没有**。
把 `methods_applied` 从 `["M0.1"]` 改成 `["M0.1", "M0.2"]` 不需要任何真实产出。

**这和"字段齐备"是同一类漏洞，只是更深一层**：字段是结构层面的，方法使用是**语义层面**的。
本 REQ 就是把方法使用从"声明"变成"可被机械核验的事实"。

---

## 1. 目标

把 `references/design-methods.md`（现在的散文方法库）升级为：

1. **数据化的方法库** —— 每种方法的适用信号、必需产出、常见反模式都是**结构化数据**，不是散文；
2. **可机械核验的"方法已应用"** —— 脚本能根据**用例集本身**判断"这条需求条目上，方法 M 的必需产出确实存在"；
3. **SKILL.md 重写** —— 方法选择不再是"读文档照做"，而是"跑脚本拿结论"，和 `validate-cases.mjs` 一样是硬门槛。

---

## 2. 功能项

### F1 方法库数据化

新增 `references/methods.json`（**数据，不是代码**），每种方法一个条目：

```jsonc
{
  "schema_version": 1,
  "methods": [
    {
      "id": "M1.2",
      "name": "边界值分析",
      "aliases": ["边界值", "BVA"],
      "purpose": "取边界及其邻近值，重点测边界内外一格",
      "applies_when": ["取值范围", "长度限制", "数量限制", "时间点", "阈值"],
      "not_applies_when": ["无明确边界的业务流程"],
      "required_outputs": [ /* 见 F2 */ ],
      "typical_dimensions": ["boundary"],
      "anti_patterns": ["只测边界值本身，没有内外一格"]
    }
  ]
}
```

**编号分段（重要）**：方法编号**分两段**，不要混用 ——

| 编号段 | 含义 | 归属 |
|--------|------|------|
| `M0.x` / `M4.x` | Layer 0 的**必选测试点**（测什么：正常路径 / 边界值 / 异常输入 / 非法迁移 / 幂等 / 服务端校验 / 数据质量） | 架构稿 `schema-v2-design.md`；**不在本方法库内** |
| `M1.x` | **测试设计方法**（怎么测：等价类 / 边界值分析 / 判定表 / 状态迁移 / 正交 / 场景法） | **本 REQ 的 `methods.json`** |

`methods.json` **只收录 `M1.x`**。用��里出现 `M0.x` / `M4.x`（比如照着 `case-schema.md` 的示例写 `method: ["M0.1","M4.5"]`）时，
`check-methods.mjs` 报**"无法判定"**（该编号不在设计方法库内），**不得默认通过**。
理由见 `decisions.md` 的 D8 —— 两套编号同号不同义会让核验结果错乱。

**硬要求**：`methods.json` 是**唯一来源** —— `references/design-methods.md` 改为**从数据生成的说明文档**
（手写解释 + 指向 JSON），两者的方法 id / 名称 / 适用信号必须一致，由脚本校验（AC-002）。

### F2 「方法已应用」可机械核验

每个方法声明 `required_outputs`（**可机械判定的谓词**，作用于用例集）：

```jsonc
"required_outputs": [
  {
    "kind": "min_cases_by_dimension",
    "dimension": "boundary",
    "min": 3,
    "distinct_expected": true
  }
]
```

支持的谓词种类（**第一批只做这些，不做通用表达式**——通用表达式等于让模型写代码，失控）：

| `kind` | 含义 |
|---|---|
| `min_cases_by_dimension` | 该需求条目下，指定维度的用例数 ≥ `min`。**子字段 `distinct_expected: true`** 表示这些用例的 `steps[].expected`（断言对象的 `expected` 值）必须**互不相同**（见 D6） |
| `has_dimension` | 该需求条目下存在指定维度的用例 |
| `min_assertions_per_case` | 用例的断言数 ≥ `min`（判定表类方法：一次响应上要多条断言） |
| `min_cases_total` | 该需求条目下用例总数 ≥ `min` |
| `dimension_pair_present` | 存在同时覆盖指定两个维度的用例（正交类方法） |

**判定必须保守**：脚本**判不了就报"无法判定"**，不许悄悄当通过。
（延续本套件的一贯原则：**没有证据的"通过"比失败更危险**。）

> ⚠️ `distinct_expected` **不是独立的 kind**，而是 `min_cases_by_dimension` 的**子字段**
> （`{"kind":"min_cases_by_dimension","dimension":"boundary","min":3,"distinct_expected":true}`）。
> 裁决与理由见同目录 `decisions.md` 的 D6 —— 本表早期版本把它列成独立 kind，与 F2 的示例 JSON
> 说法不一致，**契约不唯一就会让实现与验收各写各的**，故钉死为子字段。

### F3 方法适用性检查

对每条**可测试**需求条目：

- 该条目命中某方法的 `applies_when` 强信号，但 `methods_applied` 里没有它 → 报 `METHOD_MISSING`（**WARN**，不阻断：适用性判断本身有主观性）
- `methods_applied` 里声明了某方法，但该条目**没有任何** `applies_when` 命中 → 报 `METHOD_SUSPECT`（WARN）
- `coverage_matrix[].skipped[]` 里跳过某方法**必须写 reason**（已有规则，保持）

### F4 覆盖维度适用性检查

现在 `coverage-dimensions.md` 的 8 个维度（功能/边界/异常/权限/数据/并发/性能/兼容）也是散文。
同样数据化为 `references/dimensions.json`：每个维度声明 `applies_when` 与 `skip_reason` 要求。

脚本检查：
- 有强适用信号的维度，该需求条目下**一条用例都没有** → 报 `DIMENSION_MISSING`（WARN）
- 跳过某维度**必须**在 `coverage_matrix[].skipped[]` 里带 reason（ERROR）。
  **写法**：元素结构仍以 REQ-002A 为准（只有 `method` + `reason`），
  维度跳过用 `method` 字段记 `"dimension:<维度名>"`（如 `{"method":"dimension:concurrency","reason":"..."}`）——
  见 `decisions.md` 的 D7
- 用例的 `dimension` 取值必须在这 8 个枚举内（已有规则，保持）

### F5 新增脚本 `scripts/check-methods.mjs`

```bash
node scripts/check-methods.mjs cases.json            # 人类可读报告
node scripts/check-methods.mjs cases.json --json      # 机器可读
node scripts/check-methods.mjs --methods <路径> --dimensions <路径>   # 换方法库/维度库
```

- 退出码：`0` = 无 ERROR（可能有 WARN）；`1` = 有 ERROR；`2` = 用法错误
- **`--json` 时 stdout 只有 JSON**（含用法错误场景），风格与 `cycle-state.mjs` 一致
  （注意：`validate-cases.mjs` **本身没有** `--json` 模式，别拿它当参照）
- **零依赖**：纯 Node.js，不引第三方包

#### F5.1 `--json` 输出契约（**字段名定死**，验收按此判）

契约不写死，验收就写不稳 —— "判不了"到底算不算通过，双方只能各写各的理解。所以字段名在此定死：

```jsonc
{
  "ok": true,                       // 无 ERROR 即为 true（WARN 与"无法判定"不影响它）
  "command": "check-methods",
  "exit_code": 0,                   // 0 = 无 ERROR；1 = 有 ERROR；2 = 用法错误
  "summary": { "errors": 0, "warnings": 1, "undecidable": 1 },
  "errors":   [ { "type": "...", "requirement": "R-1", "method": "M0.2", "message": "..." } ],
  "warnings": [ { "type": "...", "requirement": "R-1", "method": "M0.2", "message": "..." } ],
  "undecidable": [ { "requirement": "R-1", "method": "M0.2", "reason": "..." } ],
  "verdicts": [
    { "requirement": "R-1", "method": "M0.2",
      "status": "satisfied" | "missing_output" | "undecidable" | "suspect" | "not_applicable",
      "message": "..." }
  ]
}
```

三条硬约束：

1. **三分类互斥** —— 同一条 `(requirement, method)` 不得同时出现在 `errors` 与 `warnings`；
   `summary` 的三个计数必须分别等于对应数组的长度
2. **`undecidable` 不算满足** —— 对应的 `verdicts[].status` 必须是 `"undecidable"`，
   **不得**是 `"satisfied"`。"判不了"既不算通过也不算失败，但**绝不等于通过**
3. **`verdicts` 必须覆盖每一条 (需求条目 × 方法) 组合** —— 没有结论的组合等于漏判

> 这条与 D2 一致：**没有证据的"通过"比失败更危险**。若实现方觉得某条 JSON 字段不合适，
> **先来改需求**，不要在实现里自行发挥 —— 契约与实现分叉，本套件会立刻失效。

### F6 `test-case-design` SKILL.md 重写

当前 SKILL.md 的方法部分（第 4 步）只说"选适用的设计方法，选择依据见 `references/design-methods.md`" ——
**这是软约束**。重写后：

- 方法选择与维度适用性**一律走 `check-methods.mjs`**，SKILL.md 给出**可复制的完整调用序列**
- 明确写清三类结论各自的后果：`ERROR` 必须修；`WARN` 必须**在报告里说明**（不得静默忽略）
- 保留 REQ-001 实证得出的硬约束（`schema_version: 2`、骨架生成、退出码语义）

---

验收标准见同目录 `acceptance.md`（AC-001 ~ AC-015）。

## 4. 不做什么（明确排除）

- **不做**方法推荐引擎（"这条需求我建议你用 M0.3"）—— 那是模型的活，脚本只管**核验声称**
- **不做**通用表达式引擎（`required_outputs` 不允许写任意表达式）—— 通用表达式等于让模型写代码
- **不改** `cases.json` 的 schema（不新增字段）—— 方法核验只读现有字段
- **不改** REQ-002A 的校验**职责** —— `validate-cases.mjs` 的职责不变，`check-methods.mjs` 是**另一个脚本**。
  **例外一（唯一一处格式放宽，D11）**：允许 `validate-cases.mjs` 对 `skipped[].method` 的格式检查**向后兼容地放宽**，
  接受 `dimension:<维度名>` 前缀 —— 否则 D7 的"维度跳过"写出来根本交不出去（契约与实现分叉）。
  放宽带向后兼容：旧用例集行为完全不变，REQ-002A 回归 19/0 必须保持
  **例外二（唯一一处数据来源变更，D16）**：允许 `validate-cases.mjs` 的**覆盖维度枚举**改为从
  `references/dimensions.json` 读取（删掉硬编码的 `DIMENSIONS` 数组）—— 否则维度枚举存在三份副本
  （硬编码常量 / `dimensions.json` / `coverage-dimensions.md` 表格）且零对照检查，**分叉当下已经存在**：
  库一加维度，`validate-cases` 判非法而 `check-methods` 判合法，同一份用例集两个脚本结论相反。
  语义不变：仍是那 8 个维度的同一份枚举，只是**唯一来源**从代码常量改为数据文件。
  读不到 / 解析失败 → 明确报错退出（码 2），**绝不静默降级**到内置列表（静默降级 = 又一份真相）。
  旧用例集行为完全不变，REQ-002A 回归 19/0 必须保持
- **不做**"自动生成用例" —— 本 REQ 只核验，不生成

---

## 5. 决策记录

### D1 方法使用从"声明"变成"可核验的事实"
`methods_applied[]` 是字符串列表，改一下就能声称用了方法。本 REQ 让"用了 M0.2"这件事
必须能在**用例集本身**里找到对应产出。

### D2 核验失败时区分 ERROR / WARN / 无法判定，三者不得混同
- **ERROR**：产出确实缺失（可机械判定的事实）→ 退出码 1
- **WARN**：适用性存疑（主观判断）→ 退出码 0，但报告里必须列出
- **无法判定**：证据不足（如 `expected` 是人读字符串）→ **单独一类**，既不算通过也不算失败

### D3 `required_outputs` 只用有限种谓词，不做通用表达式
通用表达式 = 让模型写代码 = 失控，且无法静态校验谓词本身是否合法。

### D4 方法库与说明文档双轨，但以 JSON 为准
散文保留（帮助理解），但**校验依据只有 JSON**；两者不一致时以 JSON 为准并报错（AC-002）。
理由：散文给人读，JSON 给机器读，机器不能读散文。
