# 派生与落位规则（威胁 → 用例 → 套件）

> 契约来源：需求 F5 / F6、决策 D107 / D108 / D109 / D110 / D124 / D125。

## 1. 威胁 ↔ 用例的关联链

```
cases[].requirement_refs → requirements[].id → requirements[].source_ref
                          → "threat-model.json#/threats/TH-n" → threats[].id
cases[].tags 含 "security" 与该威胁的 id（冗余但便于按威胁分批跑）
```

⚠️ 关联**靠 `source_ref`**，不靠 id 后缀：上游 `validate-cases.mjs` 的 `^TC-\d{3}$`
是硬拦，`TC-SEC-001` 不合法。

## 2. 产物 `cases.json`（顶层字段集**封闭 7 个**）

```json
{
  "schema_version": 2,
  "meta": { "source": "security-plan", "generated_at": "…", "case_count": 12 },
  "requirements": [
    { "id": "R-1", "title": "TH-9 越权读取他人账号", "source_ref": "threat-model.json#/threats/TH-9", "testable": true }
  ],
  "open_questions": [],
  "coverage_matrix": [
    { "requirement": "R-1", "methods_applied": ["M2.1"], "skipped": [], "dimensions": ["security"] }
  ],
  "defects": [],
  "cases": [
    { "id": "TC-004", "title": "…", "requirement_refs": ["R-1"],
      "dimension": "security", "priority": "P0", "method": ["M2.1"], "status": "active",
      "preconditions": [], "steps": [ { "action": "…", "expected": "…" } ],
      "data": {}, "tags": ["security", "TH-9"] }
  ]
}
```

| 规则 | 说明 |
|---|---|
| 顶层字段集 | **恰好 7 个**：`schema_version` / `meta` / `requirements` / `open_questions` / `coverage_matrix` / `defects` / `cases`。**多一个即违规** |
| `schema_version` | 必须是 `2` |
| `requirements[]` | `id` 文件内唯一（形如 `R-<序号>`）、`title` 非空、`source_ref` **恰为** `threat-model.json#/threats/<TH-id>`、`testable` 布尔 |
| `requirements` 与威胁 | **一一覆盖**：每条威胁**至少**一条 requirement；每条 requirement 指向**真实存在**的威胁 |
| `open_questions` | 必须是数组（本 REQ 固定为 `[]`） |
| `coverage_matrix` | 每条 `requirement` ∈ `requirements[].id` 且文件内唯一；**每个** requirement 都必须出现一次；`methods_applied` 非空且每个方法号 ∈ **方法库实际存在**的方法；`dimensions` 非空且必须含 `security` |
| `defects` | 必须是数组（本 REQ 固定为 `[]`） |
| `cases[]` | `id` 合 `^TC-\d{3}$`、**跨全部套件全局唯一**；`title` 非空；`requirement_refs` 非空且不悬空；`dimension` **必须 `security`**；`priority` ∈ `P0`~`P3`；`method` 非空且每个方法号 ∈ 方法库实际存在的方法；`status` **必须恒为 `active`**；`steps` 非空且每步 `action` 与 `expected` 非空；`tags` 是数组 |

⚠️ **「顶层封闭 7 个」上游不拦**：`validate-cases.mjs` 在 v2 严格模式下把**缺失**的顶层字段
升级为 ERROR，但**不拦多余顶层字段** —— 它没有「顶层未知字段」这道检查。
⚠️ **方法号的存在性上游也不查**：上游只查格式 `^M\d+\.\d+$`。
⚠️ **`status` 恒为 `active`**：上游对非 `active` 的 `status` **硬拦**（缺 `revision` ⇒ FAIL）；
且「刚派生的用例」声称「被改过 / 已废弃」在语义上是假的；`blocked` 是**执行阶段**的判定。

## 3. 派生规则

- **每条威胁至少派生 1 条安全用例**；同一威胁下的用例 `title` **互不相同**、`steps` 不完全相同。
- 本实现的派生策略：
  - 篡改 / 信息泄露 / 拒绝服务类威胁除「攻击路径」用例外，再派生一条「畸形输入与边界值」用例
    （方法 M2.3 模糊测试）—— 两条用例的标题与步骤都不同，不是复制。
- **方法号**：
  - 每条威胁都用 `M2.1`（威胁建模 STRIDE）；
  - 篡改 / 信息泄露 / 身份伪造类再加 `M2.2`（攻击面枚举）；
  - 涉及 XXE / 反序列化 / 拒绝服务再加 `M2.3`（模糊测试）。
  - 方法号的**唯一来源**是 `skills/test-case-design/references/methods.json`
    （`M1.1`~`M1.6` + `M2.1`/`M2.2`/`M2.3`）。架构稿里写的「M4.2（安全）」**不存在**（陈旧）。
- **优先级**：critical / high ⇒ `P0`；medium ⇒ `P1`；low ⇒ `P2`。
- **`tags`**：`security` + 威胁 id + `owasp-<类>` + （若有）`supplement-<类>`。

### `steps[].expected` 写什么

`expected` 写的是**安全期望**（被拒绝 / 被限流 / 不泄漏 / 有留痕）：
执行时观察到相反行为即判 failed。**规划阶段不臆断「当前一定是坏的」**。

## 4. 用例 id 的分配

- 形如 `^TC-\d{3}$`（三位数字）；
- **跨全部 security 套件全局唯一**；
- **不得**与 `--cases` 输入集里已有的 id 冲突（输入集占用的号必须避开）；
- 本实现从 `TC-001` 起向上扫描，取第一个未被占用（输入集或已分配）的号。

## 5. 套件落位

```
<out-dir>/test-assets/security/suites/SEC-<编号>-<短名>/
├── cases.json
└── suite.json
```

- 目录名匹配 `^SEC-\d{3}-[a-z0-9][a-z0-9-]*$`；
- **本实现按 OWASP 类分组**：一个类一个套件（分组维度由实现决定，契约不写死）；
- `suite.json` 的 `suite` 字段值**必须与目录名完全一致**；
- `suite.json` 顶层字段集**封闭 9 个**：
  `suite` / `requirement` / `scope` / `environment` / `cases_file` / `executor` /
  `base_url_from` / `tags` / `report`。
  ⚠️ **不许有 `threat_model` 字段**（上游 `verify-layout.mjs` 对表外字段一律判 FAIL）。
- `scope` = `security`；`executor` = `security`；
- `environment` 必须指向 `<out-dir>/test-assets/environments/` 里**真实存在**的环境；
- `cases_file` 指向**真实存在**的文件（相对套件目录解析）。

## 6. 「可被消费」= **加载层**可解析

1. `loadSuite(<suite.json>)` 成功；
2. `loadCases(<cases_file>)` 成功；
3. `selectCases(cases, suite.json.tags)` 能按 tags 选出用例；
4. 产物 `cases.json` 过 `validate-cases.mjs`（退出码 0）。

⚠️ **不要求** `run-suite.mjs --dry-run` 跑通：`security` 执行器**未实现**
（`test-execute/executors/index.json` 的 `not_implemented`），且执行器查找在 dry-run
分支**之前** ⇒ `--dry-run` 会**先抛错**。安全用例的**执行属后续 REQ**。

⚠️ **环境不要写 `driver`**：上游 `resolveDriverName()` 的优先级是
「**环境配置的 `driver`** → `suite.json` 的 `executor`」，而环境的 `driver` 枚举只有
`api` / `mock`（**没有 `security`**）⇒ 写了会误配对到功能执行器，
「能跑通」是**假象**。

## 7. 写盘纪律

- **只写** `<out-dir>/test-assets/security/`；其余目录一律只读；输入文件 sha256 前后一致；
- **产物已存在即报错**（`threat-model.json` / `matrix.json` / 任何 `suites/*` 目录存在 ⇒ rc=1，不覆盖）；
- **幂等**：同一输入两次，除 `meta.generated_at` 外**逐字相同**；
- **非法输入不留半份产物**：校验全部通过之后才建目录写盘。
