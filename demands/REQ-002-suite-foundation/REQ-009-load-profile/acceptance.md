# REQ-009 验收判据 —— `load-profile`（压测能力域：负载模型 + runner 适配）

> 本文件是**契约**，不是说明材料。实现者按这里的规则交付，验收脚本按这里的规则判定。
> 判据条数：**29 条**（AC-001 ~ AC-029）。条数**不增不减不改号**。
> 决策记录见 `decisions.md`（D127 ~ D155）。功能契约见 `demand.md`（F1~F8）。

---

## §0 公共夹具规格（判据的公共前置）

验收脚本自造以下夹具，**全部落在临时目录**（`$WORK`），**不得**写进被验包。
夹具内容与 `demand.md` F1.2 / F1.3 / F2 / F3 的形状一致。

### §0.1 压测上下文夹具 `$FX/inputs/context.json`

服务形态：**订单服务**（`order-api`）；两个目标环境 `local` / `staging`；
**4 条容量目标**，其中 **1 条故意不给指标来源**（`WL-002`），
**1 条故意在功能用例集里没有对应用例**（`WL-004`）。

```json
{
  "schema_version": 1,
  "service": { "name": "order-api", "description": "订单服务" },
  "environments": [
    { "name": "local", "base_url": "http://127.0.1:8080" },
    { "name": "staging", "base_url": "https://staging.example.com" }
  ],
  "workloads": [
    {
      "id": "WL-001",
      "name": "checkout",
      "target": "POST /api/v1/checkout",
      "environment": "local",
      "profile": {
        "type": "ramp-up",
        "steps": [ { "duration_s": 60, "concurrency": 10 }, { "duration_s": 120, "concurrency": 20 } ]
      },
      "thresholds": { "p95_latency_ms": 800, "error_rate": 0.01 },
      "thresholds_source": "需求 REQ-005 性能指标",
      "tool": { "runner": "loadtest", "runtime": "bun" },
      "args": { "rps": 100, "keepalive": true, "timeout_s": 10 },
      "requirement_refs": ["R-1"]
    },
    {
      "id": "WL-002",
      "name": "order-query",
      "target": "GET /api/v1/orders",
      "environment": "local",
      "profile": { "type": "constant", "steps": [ { "duration_s": 300, "concurrency": 5 } ] },
      "tool": { "runner": "loadtest", "runtime": "bun" },
      "requirement_refs": ["R-2"]
    },
    {
      "id": "WL-003",
      "name": "checkout-staging",
      "target": "POST /api/v1/checkout",
      "environment": "staging",
      "profile": { "type": "spike", "steps": [ { "duration_s": 30, "concurrency": 50 } ] },
      "thresholds": { "p95_latency_ms": 1200 },
      "thresholds_source": "需求 REQ-007 性能指标",
      "tool": { "runner": "python", "runtime": "python" },
      "requirement_refs": ["R-1"]
    },
    {
      "id": "WL-004",
      "name": "health-check",
      "target": "GET /api/v1/health",
      "environment": "local",
      "profile": { "type": "soak", "steps": [ { "duration_s": 600, "concurrency": 2 } ] },
      "thresholds": { "p95_latency_ms": 200 },
      "thresholds_source": "需求 REQ-008 性能指标",
      "tool": { "runner": "loadtest", "runtime": "bun" },
      "requirement_refs": ["R-2"]
    }
  ],
  "open_questions": []
}
```

⚠️ **夹具刻意留的三个「诚实性触发点」**：

| 触发点 | 期望行为 |
|---|---|
| `WL-002` **没有** `thresholds` / `thresholds_source` | 产物 `thresholds_status == "not_provided"`，**不得**有阈值键，且必须留一条 `topic == "thresholds"` 的未决问题 |
| `WL-004` 的 `target` 在功能用例集里**没有**对应用例 | 产物的 `traceability.case_refs == []`，且必须留一条 `topic == "coverage"` 的未决问题 |
| `WL-001` 与 `WL-003` 的 `target` **相同**但环境不同 | 二者**必须**落在**不同**套件（按环境分组），且 `case_refs` 都是 `["TC-001"]` |

### §0.2 功能用例集夹具 `$FX/inputs/cases.json`（供 `--cases` 用）

cases.json v2（顶层 7 字段封闭），**3 条**用例：

| `id` | `title` | `requirement_refs` | `steps[].action` |
|---|---|---|---|
| `TC-001` | 下单成功返回订单号 | `["R-1"]` | `POST /api/v1/checkout` |
| `TC-002` | 按订单号查询订单 | `["R-2"]` | `GET /api/v1/orders/{id}` |
| `TC-003` | 查询用户资料 | `["R-2"]` | `GET /api/v1/users/{id}/profile` |

每条另有：`dimension: "functional"`、`priority` / `method: ["M1.1"]` / `status: "active"`、
`preconditions: []`、`data: {}`、`steps[].expected` 为普通字符串、`tags: ["functional"]`。
用例集自身 `requirements[]` = `R-1` / `R-2`；`open_questions: []`；
`coverage_matrix` 两条；`defects: []`；`schema_version: 2`。

⚠️ **`TC-002` 的 action 带路径占位符**（`{id}`）⇒ 对账规则必须**归一化**（F4.3 / D150）
⇒ 它**必须**能匹配 `WL-002` 的 `target`（`GET /api/v1/orders`）。

### §0.3 上下文**非法变体**（供 B 组实跑）

八份变体（**各自独立**，都基于 §0.1 的原文）：

| # | 变体 | 坏在哪 |
|---|---|---|
| V1 | 删掉顶层 `workloads` | 必填字段缺失 |
| V2 | 顶层加一个 `load_scenario` 字段 | 顶层字段集封闭违规 |
| V3 | `workloads[0].environment` 改成 `prod` | 引用悬空（`prod` ∉ `environments[]`） |
| V4 | `workloads[1].id` 改成 `WL-001` | id 重复 |
| V5 | `workloads[0].profile.type` 改成 `ramp` | 枚举越界（合法值只有 5 个） |
| V6 | 删掉 `workloads[2].thresholds_source` | 阈值与来源**不成对** |
| V7 | `workloads[0].target` 改成 `POST api/v1/checkout` | `target` 格式错（缺空格与前导 `/`） |
| V8 | `workloads[1].id` 改成 `WL-1` | id 格式错（不是三位数字） |

⚠️ **变体的判定口径**：八份**全部** rc=1（输入非法）、stderr **点名坏点**、
**不得**留下半份产物（`<out-dir>/test-assets/load/` **不存在** —— 存在性判定，0 字节也算）。

### §0.4 最小项目根 `$FX/proj`

```
$FX/proj/
├── .gitignore                                  # 含 ".test-artifacts/"（上游检查 13）
└── test-assets/
    ├── environments/
    │   ├── _schema.json                        # 上游检查 2 要求（环境配置 schema）
    │   ├── local.json                          # 被 WL-001/002/004 引用
    │   └── staging.json                        # 被 WL-003 引用
    └── cycles/
        ├── index.json                          # 上游检查 12 要求
        └── R1-REQ-009/
            └── cycle.json                      # 上游检查 9/10/11
```

`environments/local.json`：

```json
{
  "name": "local",
  "base_url": "http://127.0.1:8080",
  "timeout_ms": 3000,
  "retries": 0,
  "credentials": { "token_env": "TEST_TOKEN" }
}
```

`environments/staging.json`（同名同形，`name` 必须 == 文件名）：

```json
{
  "name": "staging",
  "base_url": "https://staging.example.com",
  "timeout_ms": 5000,
  "retries": 0,
  "credentials": { "token_env": "TEST_TOKEN_STAGING" }
}
```

`environments/_schema.json`：

```json
{ "type": "object", "properties": { "name": { "type": "string" }, "base_url": { "type": "string" } }, "required": ["name", "base_url"] }
```

`cycles/R1-REQ-009/cycle.json`：

```json
{
  "cycle_id": "R1-REQ-009",
  "requirement": "REQ-009",
  "status": "planned",
  "round": "R1",
  "round_type": "new-requirement",
  "scopes": ["functional", "load"],
  "stages": {},
  "history": [ { "at": "2026-11-14T09:00:00+08:00", "from": "planned", "to": "planned", "by": "ba" } ],
  "scopes_skipped": []
}
```

`cycles/index.json`：

```json
{ "cycles": [ { "id": "R1-REQ-009", "status": "planned", "round": "R1" } ] }
```

⚠️ **前置条件清单（验收脚本必须预置，缺一不可）**：

| # | 前置条件 | 谁需要它 |
|---|---|---|
| P1 | `test-assets/environments/local.json` **存在** | `WL-001` / `WL-002` / `WL-004` 引用的环境 |
| P2 | `test-assets/environments/staging.json` **存在** | `WL-003` 引用的环境 |
| P3 | 两个环境文件**都不得**有 `driver` 字段 | AC-020（状态判据） |
| P4 | `test-assets/environments/_schema.json` 存在 | 上游校验器能跑起来 |
| P5 | `test-assets/cycles/{index.json,R1-REQ-009/cycle.json}` 存在 | 上游校验器能跑起来 |
| P6 | `.gitignore` 含 `.test-artifacts/` | 上游校验器能跑起来 |

⚠️ **P1/P2 是 F6 校验层判据（AC-004 / AC-019）的【前置条件】**：
**缺了它们 ⇒ 那两条判「不可判定」（前置不满足），不算实现违约、不判 FAIL**
（`demand.md` F6.1 三分支 / `decisions.md` D130 / D146）。
⚠️ **P3 是 AC-020 的前置条件**：环境里**不得**有 `driver`（上游只拦非法枚举，`driver: "api"`
合法 ⇒ 上游**放行** ⇒ 这条**由门判**）。

### §0.5 主跑命令

```
node skills/load-profile/scripts/make-load-profile.mjs \
  --context $FX/inputs/context.json \
  --cases   $FX/inputs/cases.json \
  --out-dir <项目根副本>
```

**产物落点**（F1.1 / D127）：

```
<项目根副本>/test-assets/load/
├── report.json
├── scenarios/
│   ├── checkout.json
│   ├── checkout-staging.json
│   ├── health-check.json
│   └── order-query.json
└── suites/
    ├── LOAD-001-checkout/
    │   ├── scenario.json
    │   └── suite.json
    └── LOAD-002-checkout-staging/
        ├── scenario.json
        └── suite.json
```

### §0.6 基线真值表（夹具跑出来的**唯一**正确结论）

⚠️ **诚实声明（先读这一段）**：本表只固定**可机械核**的那部分真值。
**场景怎么分组、套件目录叫什么、未决问题怎么措辞、报告清单怎么组织**，
在契约里**已经写死**（F3.1 / F3.2 / D141 / D143 / D144），因此它们是**可核**的；
但**未决问题的具体文字**属实现方的判断（契约只要求「非空 + 主题正确」），本表**不**规定。

| # | 字段 | 真值 | 来源 |
|---|---|---|---|
| 1 | 产物根 | `<out-dir>/test-assets/load/` | F1.1 |
| 2 | 场景模型**条数** | **恰好 4** | AC-013 |
| 3 | 场景 `id` 集合 | **恰等于** `{WL-001, WL-002, WL-003, WL-004}` | AC-013 |
| 4 | 场景文件名集合 | **恰等于** `{checkout.json, order-query.json, checkout-staging.json, health-check.json}` | AC-012 |
| 5 | 场景顶层字段集 | **恰为 14 个**：`schema_version`/`id`/`name`/`service`/`target`/`environment`/`profile`/`thresholds`/`thresholds_source`/`thresholds_status`/`tool`/`args`/`traceability`/`open_questions` | F2.1 |
| 6 | 场景 `profile` / `tool` / `target` / `environment` | **逐字等于**输入对应值 | AC-010 |
| 7 | `WL-001` 场景的 `thresholds` | **逐字等于** `{"p95_latency_ms": 800, "error_rate": 0.01}` | AC-010 / AC-014 |
| 8 | `WL-001` 场景的 `thresholds_source` | **逐字等于** `"需求 REQ-005 性能指标"` | AC-010 |
| 9 | `WL-002` 场景的 `thresholds_status` | **`not_provided`** | AC-011 |
| 10 | `WL-002` 场景 | **不得**有 `thresholds` / `thresholds_source` 键 | AC-011 / AC-014 |
| 11 | `WL-003` 场景的 `thresholds` | **逐字等于** `{"p95_latency_ms": 1200}` | AC-010 |
| 12 | `WL-004` 场景的 `thresholds_status` | `provided`（它**有**来源） | AC-011 |
| 13 | 场景 `traceability.workload_id` | **逐字等于**对应 workload 的 `id` | AC-024 |
| 14 | 场景 `traceability.requirement_refs` | **逐字等于**输入 workload 的 `requirement_refs` | AC-024 |
| 15 | `WL-001` 场景的 `traceability.case_refs` | **恰等于** `["TC-001"]` | AC-024 |
| 16 | `WL-002` 场景的 `traceability.case_refs` | **恰等于** `["TC-002"]`（`{id}` 占位符归一化后匹配） | AC-024 |
| 17 | `WL-003` 场景的 `traceability.case_refs` | **恰等于** `["TC-001"]` | AC-024 |
| 18 | `WL-004` 场景的 `traceability.case_refs` | **恰等于** `[]` | AC-024 |
| 19 | 套件目录**数** | **恰好 2** | AC-015 |
| 20 | 套件目录名集合 | **恰等于** `{LOAD-001-checkout, LOAD-002-checkout-staging}` | AC-015 |
| 21 | `LOAD-001` 的场景顺序 | `checkout` → `order-query` → `health-check`（= 输入 workload 顺序） | AC-015 / D144 |
| 22 | `LOAD-002` 的场景 | `checkout-staging` | AC-015 |
| 23 | 每个 `suite.json` 的 `scope` / `executor` | 均为 **`load`** | AC-016 |
| 24 | 每个 `suite.json` 的 `suite` | **等于**所在目录名 | AC-016 |
| 25 | 每个 `suite.json` 的 `cases_file` | **`scenario.json`**（相对套件目录） | AC-016 |
| 26 | 每个 `suite.json` 的 `environment` | `LOAD-001` ⇒ `local`；`LOAD-002` ⇒ `staging` | AC-016 |
| 27 | 每个 `suite.json` 的顶层字段集 | ⊆ 上游 9 个允许字段，**无 `load_scenario`** | AC-016 |
| 28 | 套件级 `scenario.json` 顶层字段集 | **恰为 3 个**：`schema_version`/`suite`/`scenarios` | AC-017 |
| 29 | 套件级 `scenario.json` 的 `scenarios[]` 元素 | 恰为 3 个字段 `path`/`id`/`name` | AC-017 |
| 29b | 场景 ↔ 套件的覆盖 | 每个 workload **恰好**被一个套件引用；每个套件**≥1** 个引用；每个场景**≥1** 次被引用；无孤儿套件 | AC-019 |
| 30 | 引用件 `id` / `name` | **逐字等于**本体文件里的 `id` / `name` | AC-017 |
| 31 | `WL-002` 场景的 `open_questions` | **≥1 条** `topic == "thresholds"` | AC-021 |
| 32 | `WL-004` 场景的 `open_questions` | **≥1 条** `topic == "coverage"` | AC-023 |
| 33 | 其余场景的 `open_questions` | 可为空数组；**不得**有 `topic == "thresholds"` 的条目 | AC-021 |
| 34 | `report.json` 顶层字段集 | **恰为 5 个**：`schema_version`/`service`/`suites`/`scenarios`/`open_questions` | AC-009 |
| 35 | 全部产物 JSON 的**任意层级** | **不得**出现压测结论键（`status`/`result`/`verdict`/`executed`/`passed`/`outcome`/`conclusion`） | AC-022 |
| 36 | 全部产物 | **不得**出现 `cases.json`；**不得**出现 `method` 字段 | AC-020 / AC-024 |
| 37 | 幂等 | 同一输入跑两次（两个不同 out-dir），两份产物**逐字相同** | AC-025 |
| 38 | 输入只读 | `--context` / `--cases` 的 sha256 跑前跑后**一致** | AC-027 |
| 39 | 只写自己的目录 | `<out-dir>` 下除 `test-assets/load/` 外一切**逐字未变** | AC-026 |
| 40 | 产物已存在即报错 | 同一 out-dir 第二次跑 ⇒ **rc=1** 且既有产物**逐字未变** | AC-028 |

---

## A 组：交付物形状（AC-001 ~ AC-004）

### AC-001: `load-profile` skill 存在且结构合法
- **前置条件**: 被验包目录
- **测试步骤**: ① 检查 `skills/load-profile/` 存在；② `SKILL.md` 存在且 YAML frontmatter 含 `name: load-profile` 与**非空** `description`（取 frontmatter 的**值**再判空 —— 块标量 `|` 取其缩进块；普通标量剥掉首尾引号，`""` / `''` 判空）；③ `skill-meta.json`、`references/load-context-schema.md`、`references/load-scenario-format.md`、`references/profile-rules.md`、`scripts/make-load-profile.mjs`、`scripts/check-load-profile.mjs` 存在且**非空**；④ `scripts/lib/` 下 `.mjs` 模块 **≥ 3 个**且非空；⑤ 两个脚本**各自**（不是两个合起来满足其一）首行是 `#!/usr/bin/env node`、文件**可执行**、且 `node --check` 通过；任一项不满足 → 判红并**点名是哪一项**
- **预期结果**: 五项全满足
- **判据形式**: 查**绝对事实**（文件真实存在且非空）；探针：把 `description` 改成 `""` → 本条判红；删掉 `references/profile-rules.md` → 本条判红；把某个脚本 `chmod -x` → 本条判红
- **类型**: 功能

### AC-002: 每个 skill 都声明版本与依赖（`skill-meta.json`）
- **前置条件**: 被验包目录
- **测试步骤**: 对 `skills/` 下**每一个**含 `SKILL.md` 的目录，检查存在 `skill-meta.json`；解析它必须有 `name`（非空且等于目录名）、`version`（形如 `<数字>.<数字>.<数字>`）、`requires`（对象；值为形如 `>=<x.y.z>` 或 `<x.y.z>` 的约束）；并检查 `name` 与该 skill 的 SKILL.md frontmatter `name` 一致（frontmatter 取**值**再比对）；**并**检查 `load-profile` 的 `requires` 的**键集合恰为** `{test-case-design, qa-toolchain}`
- **预期结果**: 每个 skill 都有合法声明；**`load-profile.requires` 必须恰好是 `test-case-design` 与 `qa-toolchain` 两个键**（各为 `>=0.1.0` 形态），且**不得含 `test-execute`**（架构 §8：REQ-002.9 依赖 002.4；且 `load` 执行器未实现 ⇒ 那是**假依赖**）；任一不满足 → 判红并点名
- **判据形式**: 查绝对事实；探针：把 `load-profile.requires` 里的 `qa-toolchain` 删掉 → 本条判红；加上 `test-execute` → 本条判红
- **类型**: 功能

### AC-003: README 的 skill 清单与实际目录一致（且 `load-profile` 两处都在）
- **前置条件**: 被验包目录 + `README.md`
- **测试步骤**: ① 取 `skills/` 下全部含 `SKILL.md` 的目录名集合 S；② 取 `README.md` 的 **skill 清单**（表格首格 ∪ `skills/<name>` 路径 ∪ 安装树条目）集合 R；③ 检查 S == R；④ 检查 `load-profile` 出现在 **skill 表格**里；⑤ 检查 `load-profile` 出现在 **安装树代码块**里
- **预期结果**: ①集合完全相等；②③④⑤全满足；README 漏写或多写任一 skill → 判红并点名；`load-profile` 漏在任一处 → 判红并点名**漏在哪一处**
- **判据形式**: 查绝对事实（与目录实际内容比对），不查「README 里说了几个」
- **类型**: 可用性

### AC-004: 新产物不得打破既有目录契约（**上游校验器对该套件的真实结论**）
- **前置条件**: 被验包里的 `skills/test-case-design/scripts/verify-layout.mjs` + §0.4 的最小项目根（含 **P1~P6** 全部前置条件）
- **测试步骤**: ① 在项目根副本里放上**本 REQ 的压测产物**（`test-assets/load/**`）；② **实跑** `node <被验包>/skills/test-case-design/scripts/verify-layout.mjs <项目根>`，拿**真实输出**；③ 先核**前置条件**：被 workload 引用的每个环境文件是否存在；④ 按**相对路径** grep 该 load 套件的 `suite.json`（形如 `test-assets/load/suites/<目录名>/suite.json`）相关判定行
- **预期结果**: **三分支**（`demand.md` F6.1 / D130）：
  - ①**被引用的环境文件不存在**（前置条件不满足）⇒ 判**不可判定**（**不算实现违约、不判 FAIL**）；
  - ②环境文件存在、上游对该套件报了**其它**问题（字段缺失 / 枚举非法 / `cases_file` 指向的文件不存在 / `suite` 字段与目录名不一致 / `cases_file` 越出项目根 …）⇒ **判 FAIL**；
  - ③环境文件存在、上游对该套件**全 `[OK]`** ⇒ **判 PASS**
- **判据形式**: 查绝对事实（**实跑**上游校验器，按相对路径 grep 真实输出）；**不判**上游对**整个项目根**的 rc=0（整体 rc 还额外要求 `environments/_schema.json` / `cycles/` / `.gitignore` —— 那些不在本 REQ 的写入范围内，拿它当判据 = 永远判红的假判据）；探针：把某个套件的 `cases_file` 改成不存在的文件 → 本条判红
- **⚠️ 上游模块缺失 ⇒ 判【不可判定】**（不是实现违约）：被验包里**没有** `skills/test-case-design/scripts/verify-layout.mjs` ⇒ 本条判**不可判定** —— 实现的产物可能完全正确，只是被验包里没装上游那个 skill；**不可判定 ≠ 通过 ⇒ 退出码仍非 0**
- **说明**: 上游用 `listFiles(test-assets)` **递归**找所有 `suite.json` ⇒ load 套件**自动**受那套强制约束（字段完整 / 枚举合法 / `suite` 名与目录名一致 / `cases_file` 存在且不越出项目根 / `environment` 同名文件存在）
- **类型**: 兼容性

---

## B 组：输入解析与校验（AC-005 ~ AC-008）

> 以下各条的前置：`node skills/load-profile/scripts/make-load-profile.mjs --context <变体> --out-dir <空的输出目录副本>`
> 「输出目录副本」= §0.4 项目根的副本，**跑前**其 `test-assets/load/` 不存在。

### AC-005: 上下文的必填字段与顶层封闭集必须校验
- **前置条件**: §0.1 上下文 + **变体 V1**（删掉 `workloads`）+ **变体 V2**（顶层加 `load_scenario`）+ **变体 V1b**（把 `workloads` 改成字符串）
- **测试步骤**: 三种变体各跑一次，检查退出码、stderr、输出目录
- **预期结果**: 三种情形**退出码均为 1**（输入非法）；stderr **点名是什么坏了**（含字段名，如 `workloads` / `load_scenario`）；输出目录里**不得**出现 `test-assets/load/`（**存在性**判定，0 字节也算）
- **判据形式**: 查绝对事实（真实退出码 + 产物目录实况）；探针：让实现在解析失败时仍写出空的 `test-assets/load/scenarios/` → 本条判红
- **类型**: 功能

### AC-006: workload 的引用必须完整（不悬空），且 `target` 格式必须合法
- **前置条件**: **变体 V3**（`workloads[0].environment` = `prod`，不在 `environments[]` 内）+ **变体 V7**（`target` = `POST api/v1/checkout`）
- **测试步骤**: 两种变体各跑一次，检查退出码、stderr、输出目录
- **预期结果**: 两种情形**退出码均为 1**；stderr **点名**坏点（含那个不存在的环境名 `prod` / 点名 `target`）；**不得**留下 `test-assets/load/`
- **判据形式**: 查绝对事实；探针：让实现不查悬空引用（把 `prod` 当成真实环境写进产物）→ 本条判红
- **类型**: 功能

### AC-007: workload 的 `id` 必须唯一且格式合法
- **前置条件**: **变体 V4**（`workloads[1].id` = `WL-001`，与 `workloads[0].id` **重复**）+ **变体 V8**（`workloads[1].id` = `WL-1`，**不是三位数字**）
- **测试步骤**: 两种变体各跑一次，检查退出码、stderr、输出目录
- **预期结果**: 两种情形**退出码均为 1**；stderr **点名**坏点（重复时点名那个重复的 id，格式错时点名那个 id）；**不得**留下 `test-assets/load/`
- **判据形式**: 查绝对事实；探针：让实现不查唯一性 → 本条判红
- **类型**: 功能

### AC-008: 枚举必须合法，且 `thresholds` 与 `thresholds_source` 必须**成对**
- **前置条件**: **变体 V5**（`profile.type` = `ramp`，合法值只有 `constant`/`ramp-up`/`ramp-down`/`spike`/`soak`）+ **变体 V6**（删掉 `thresholds_source`，只留 `thresholds`）+ **变体 V8b**（把 `tool.runner` 改成 `jmeter`）+ **合法**的 §0.1 原文
- **测试步骤**: ① 三个变体各跑一次（检查退出码与 stderr）；② 合法原文跑一次（检查退出码）；③ **产物侧**：遍历 §0.5 主跑产物的每个场景，核 `profile.type` ∈ 5 值、`tool.runner` ∈ {`loadtest`,`python`}、`tool.runtime` ∈ {`bun`,`python`,`node`}、`thresholds` 的键 ∈ 6 值白名单
- **预期结果**: ①三个变体**退出码均为 1**，stderr 点名（越界字段名与越界值 / 点名 `thresholds_source`）；②**合法原文退出码为 0**；③三个变体**不得**留下 `test-assets/load/`；④**产物里的枚举取值必须合法** —— 任何越界取值 ⇒ 判红（输入侧拦不住的，产物侧要拦）
- **判据形式**: 查绝对事实；探针：让实现接受任意 `profile.type` → V5 判红；让实现接受「有阈值没来源」→ V6 判红；把产物里的 `tool.runner` 改成 `jmeter` → ④ 判红
- **说明**: 「成对规则」是「没有指标来源就不该有阈值」（架构 §2.3 L191）的**结构化**落点：只给阈值不给来源 = 凭空拍阈值 ⇒ 在**输入层**就拒。③是**产物侧**的同一组枚举 —— 输入层被绕过时，产物层仍要拦
- **类型**: 功能

---

## C 组：负载模型（AC-009 ~ AC-014）

### AC-009: 负载模型的顶层字段集**封闭 14 个**，且内层字段集封闭
- **前置条件**: §0.5 主跑产物
- **测试步骤**: 取 `test-assets/load/scenarios/*.json` 每个文件的顶层键集；再逐个核 `profile` / `tool` / `traceability` 的键集；并核 `report.json` 的顶层键集
- **预期结果**: ①每个场景顶层键集**恰好**是 {`schema_version`,`id`,`name`,`service`,`target`,`environment`,`profile`,`thresholds`,`thresholds_source`,`thresholds_status`,`tool`,`args`,`traceability`,`open_questions`}（其中 `thresholds` / `thresholds_source` 是**条件字段**，按 AC-011 判有无）—— **多一个即违规**（如 `meta` / `status` / `note`）；②`schema_version == 1`；③`profile` 键集**恰为** {`type`,`steps`}，`steps[]` 元素键集**恰为** {`duration_s`,`concurrency`}；④`tool` 键集**恰为** {`runner`,`runtime`}；⑤`traceability` 键集**恰为** {`workload_id`,`requirement_refs`,`case_refs`}；⑥`report.json` 顶层键集**恰为** {`schema_version`,`service`,`suites`,`scenarios`,`open_questions`}；⑦`traceability.requirement_refs` / `case_refs` 与 `open_questions` 都是数组
- **判据形式**: 查绝对事实（逐字段核）；探针：让实现在场景顶层加一个 `note` → 本条判红（**注意**：上游对 `cases_file` 指向的文件**只校验存在、不校验内容** ⇒ 这一条**全部由门判**）
- **类型**: 功能

### AC-010: 梯度与阈值必须**逐字可追溯**到输入
- **前置条件**: 同上 + §0.1 上下文
- **测试步骤**: 逐个场景核 `target` / `environment` / `service` / `profile` / `tool` / `args` 与对应 workload 的值（**键序无关，值逐字**）；再核 `profile.steps[]` 的**顺序**
- **预期结果**: ①每个场景的 `target` / `environment` / `tool` 与对应 workload **逐字相等**；②`service` == 输入 `service.name`；③`profile`（含 `steps` 的**每一项的顺序**与每一项的 `duration_s` / `concurrency`）**逐字相等**；④`thresholds` 与 `thresholds_source`（存在时）**逐字等于**输入；⑤输入有 `args` 时产物的 `args` **逐字相等**（输入没有则产物**不得**有 `args` 键）
- **判据形式**: 查绝对事实（逐字段字面比对）；探针：让实现把并发从 10 改成 50 → 本条判红；让实现把 `p95_latency_ms` 从 800 改成 500 → 本条判红
- **类型**: 追溯

### AC-011: `thresholds_status` 二态必须与输入一致（键的**有无**）
- **前置条件**: 同上
- **测试步骤**: 逐个场景看 `thresholds_status`，再核 `thresholds` / `thresholds_source` 两个键的**存在性**
- **预期结果**: ①输入 workload **有** `thresholds` + `thresholds_source` ⇒ 产物 `thresholds_status == "provided"` 且**两个键都存在**；②输入 workload **没有**它们 ⇒ 产物 `thresholds_status == "not_provided"` 且**两个键都不存在**；③`thresholds_status` 只允许这两个取值
- **判据形式**: 查绝对事实；探针：让实现在无来源时写 `thresholds_status: "provided"`（还带上拍出来的阈值）→ 本条判红
- **说明**: 「没有指标来源就不拍阈值」用**键的有无**表达 ⇒ 结构性保证，不是口头承诺（D137）
- **类型**: 诚实性

### AC-012: 场景文件名必须合命名约定，且与体内 `name` 一致
- **前置条件**: §0.5 主跑产物
- **测试步骤**: 列出 `test-assets/load/scenarios/` 下每个文件名；逐个核正则与体内 `name`
- **预期结果**: ①文件名的**基名**（去 `.json`）匹配 `^[a-z0-9][a-z0-9-]*$`；②**文件名去 `.json` 必须等于**文件内的 `name` 字段；③场景文件**只有** `.json` 后缀
- **判据形式**: 查绝对事实（文件系统实况）；探针：把 `checkout.json` 改名为 `Checkout_v2.json`（同时同步引用件里的 `path`，保证引用仍可解析）→ 本条判红
- **说明**: 上游**不校验**场景文件名 ⇒ 这条**由门判**（D138）
- **类型**: 功能

### AC-013: 每个容量目标**恰好**一个场景模型
- **前置条件**: 同上 + §0.1 上下文
- **测试步骤**: 汇总 `scenarios/*.json` 的 `id` 集合与条数，与上下文 `workloads` 的 `id` 集合与条数比对
- **预期结果**: ①场景条数 **== 4**（== workload 条数）；②场景 `id` 集合**恰等于** `{WL-001, WL-002, WL-003, WL-004}`（**不多**不少**）；③场景 `id` 文件内**唯一**
- **判据形式**: 查绝对事实（集合运算）；探针：让实现在 `scenarios/` 里多造一个 `zzz.json` → 本条判红；让实现漏掉一条容量目标 → 本条判红
- **类型**: 诚实性

### AC-014: 不得凭空造阈值（**不加键、不改值**）
- **前置条件**: 同上
- **测试步骤**: 逐个场景核 `thresholds` 的键集与值，与输入 workload 对照
- **预期结果**: ①`thresholds_status == "provided"` 的场景：`thresholds` 的**键集**与每个值都**逐字等于**输入（**不得**多一个键如 `p99_latency_ms`，**不得**改一个值如把 800 改成 500）；②`thresholds_status == "not_provided"` 的场景：**不得**存在 `thresholds` 键（AC-011 已核键的有无，此处再核「值也没有」）
- **判据形式**: 查绝对事实（键集 + 值字面比对）；探针：让实现把 `p95_latency_ms` 从 800 改成 500 → 本条判红；让实现在 `not_provided` 的场景里补一个 `p95_latency_ms: 1000` → 本条判红
- **类型**: 诚实性

---

## D 组：套件落位（AC-015 ~ AC-017）

### AC-015: 套件目录名必须合规，且套件必须按**环境**分组
- **前置条件**: §0.5 主跑产物
- **测试步骤**: 列出 `test-assets/load/suites/` 下每个目录；逐个核目录名正则；再核「目录名 ↔ 套件内场景 ↔ 环境」的对应关系
- **预期结果**: ①**恰好 2 个**套件目录；②每个目录名匹配 `^LOAD-\d{3}-[a-z0-9][a-z0-9-]*$`；③每个目录的 `suite.json` 的 `suite` 字段**完全等于**目录名（大小写敏感）；④每个套件内的**全部**场景的 `environment` **相同**，且等于该套件 `suite.json` 的 `environment`；⑤**同一个 workload 不得**出现在两个套件里；⑥不同 `environment` 的 workload **不得**在同一个套件里；⑦套件目录名的短名部分 == 该套件内**第一个**场景的 `name`（顺序 = 输入 workload 顺序）
- **判据形式**: 查绝对事实（文件系统实况 + 集合运算）；探针：把目录改成 `LOAD-1-checkout`（编号不是三位）→ 本条判红；把 `WL-003` 的场景挪进 `LOAD-001` → 本条判红（违反 ⑥）
- **说明**: 上游**不校验**套件目录名（只校验 `suite.json` 的 `suite` 字段 == 目录名）⇒ 这条**由门判**（D141 / D144）
- **类型**: 功能

### AC-016: `suite.json` 的顶层字段集与取值必须合法
- **前置条件**: 同上
- **测试步骤**: 取每个套件 `suite.json` 的顶层键集与各字段值
- **预期结果**: ①顶层键集 ⊆ 上游 9 个允许字段 {`suite`,`requirement`,`scope`,`environment`,`cases_file`,`executor`,`base_url_from`,`tags`,`report`} —— **出现表外字段（含 `load_scenario`）即违规**；②`suite` / `requirement` / `scope` / `environment` / `cases_file` / `executor` **六个必填**都存在且为非空字符串；③`scope == "load"`；④`executor == "load"`；⑤`cases_file` **恰为** `scenario.json`；⑥`environment` 在 `<out-dir>/test-assets/environments/` 下有**同名 `.json` 文件**
- **判据形式**: 查绝对事实（逐字段核 + 文件系统核）；探针：让实现写 `load_scenario: "scenarios/checkout.json"` → 本条判红（**上游也会拦**：上游 `suite.json` 顶层字段集封闭 9 个）；把 `executor` 改成 `api` → 本条判红（**上游不拦**：上游只校枚举、不校配对 ⇒ 由门判）
- **类型**: 功能

### AC-017: 套件级 `scenario.json` 必须是**引用**，且与本体**不得漂移**
- **前置条件**: 同上
- **测试步骤**: 取每个套件 `scenario.json` 的顶层键集与 `scenarios[]` 每个元素的键集；逐个把 `path` 相对**套件目录**解析，检查目标文件存在；再把 `id` / `name` 与本体文件里的 `id` / `name` 比对
- **预期结果**: ①顶层键集**恰为** {`schema_version`,`suite`,`scenarios`}；②`schema_version == 1`；③`suite` **等于**所在目录名；④`scenarios` 是数组且**≥1 项**，元素键集**恰为** {`path`,`id`,`name`}；⑤每个 `path` 解析后**真实存在**，且落在 `test-assets/load/scenarios/` 下；⑥每个元素的 `id` / `name` 与本体文件里的 `id` / `name` **逐字相等**（**不漂移**）；⑦套件内引用的场景集合 == 该套件应含的场景集合
- **判据形式**: 查绝对事实（路径解析 + 字面比对）；探针：让实现在引用件里写 `id: "WL-999"`（与本体对不上）→ 本条判红；让实现把 `path` 写成不存在的路径 → 本条判红
- **类型**: 功能

---

## E 组：可消费与边界（AC-018 ~ AC-020）

### AC-018: 产物必须能被上游 `test-execute` 的**加载层**消费
- **前置条件**: §0.5 主跑产物 + 被验包里的 `skills/test-execute/scripts/lib/suite-loader.mjs`
- **测试步骤**: **单独进程**实跑上游加载层：对每个 load 套件，用 `loadSuite(<suite.json>)` 解析，断言**不抛错**（拿**真实退出码**与**真实返回值**；**不许**自己解析 JSON 冒充）
- **预期结果**: 每个 load 套件的 `loadSuite()` 调用**都不抛错**，且返回的 `config` 里 `scope == "load"`、`executor == "load"`、`cases_file` 解析到**真实存在**的文件
- **判据形式**: 查绝对事实（**实跑**上游加载层的真实退出码）；探针：让 `suite.json` 缺一个必填字段 → ①判红
- **⚠️ 口径（不许含糊）**: 本条判的是「**能不能被消费**」= **加载层**可解析，**不是**「能不能跑起来」。
  `load` 执行器**未实现**（`test-execute/executors/index.json` 的 `not_implemented`）⇒
  **本条不要求** `run-suite.mjs --dry-run` 跑通，**更不要求**执行器能跑；
  **也不要求** `loadCases()` 能消费 `cases_file`（上游 `loadCases()` 硬要求 `doc.cases` 是数组 ⇒
  `scenario.json` **不能**做成 cases 形态）。
- **⚠️ 上游模块缺失 ⇒ 判【不可判定】**（不是实现违约）：被验包里**没有** `skills/test-execute/scripts/lib/suite-loader.mjs` ⇒ 本条判**不可判定**；**不可判定 ≠ 通过 ⇒ 退出码仍非 0**
- **类型**: 一致性

### AC-019: 场景模型 ↔ 套件的**双向覆盖完整性**
- **前置条件**: §0.5 主跑产物 + §0.1 上下文
- **测试步骤**: ① 把 `scenarios/` 下每个场景模型按 `id` 建索引；② 遍历每个 load 套件的 `scenario.json` 的 `scenarios[]`，把每个引用**解析到的本体 id** 收集起来（按套件分组）；③ 用②的引用集合与上下文 `workloads` 的 `id` 集合做**双向**比对；④ 统计每个场景模型被几个套件引用
- **预期结果**: ①**每个 workload（容量目标）恰好被一个套件引用**（不悬空、也不被两个套件重复引用）；②**每个 load 套件至少引用一个场景模型**（不得有空引用件）；③**每个场景模型至少被一个套件引用**（**不得有孤儿场景**：生成了却没人引用）；④**不得有孤儿套件**（引用了**不存在**的场景模型）；⑤每个套件引用的 id 集合 **恰等于** 该套件 `environment` 下应有的 workload id 集合
- **判据形式**: 查绝对事实（双向集合运算 + 计数）；探针：删掉 `LOAD-002-checkout-staging` 整个目录（`WL-003` 落空、`checkout-staging.json` 变成孤儿场景）→ 本条判红；把某个套件的 `scenarios[]` 清成空数组 → 本条判红；把某个场景的 id 改成别的 → 本条判红
- **说明**: 本条管的是「**场景模型 ↔ 套件**」的覆盖完整性；**AC-013** 管的是「**场景模型 ↔ 容量目标**」的一一对应 —— 两条各管各的，不互相遮蔽。本条**天然不许恒真**：删一个套件、让某个 workload 落空、留一个孤儿场景，都必须真红
- **⚠️ 本条是纯产物侧判据，不依赖上游模块** ⇒ 上游模块缺失时**不受影响**（仍照常判定）；「上游模块缺失 ⇒ 不可判定」的口径只落在 **AC-004**（上游校验器）与 **AC-018**（上游加载层）两条上
- **类型**: 诚实性

### AC-020: 边界红线：环境不得有 `driver`、`executor` 必须是 `load`、不得产出 `cases.json`、不得产生执行产物
- **前置条件**: §0.5 主跑产物（+ `<out-dir>/test-assets/environments/` 下的环境文件）
- **测试步骤**: ① 对每个 load 套件，取它 `suite.json` 的 `environment`，读 `<out-dir>/test-assets/environments/<env>.json`，查**有没有 `driver` 键**；② 核每个套件的 `executor == "load"`；③ 在每个 load 套件目录里查**有没有 `cases.json`**；④ **查文件系统**：跑完之后 `<out-dir>` 下**不得**出现名为 `runs` 或 `evidence` 的**目录/文件**（上游执行器的产物落点；`.test-artifacts/` 下的执行产物）
- **预期结果**: ①被 load 套件指向的环境文件**不得**有 `driver` 键（**上游只拦非法枚举**：`driver: "load"` 被拦，而 `driver: "api"` **合法 ⇒ 上游放行** ⇒ **这条由门判**）；②`executor` 全部为 `load`（上游**放行** `executor: "api"` ⇒ **由门判**）；③load 套件目录里**不得**有 `cases.json`；④`<out-dir>` 下**不得**出现 `runs` / `evidence` 目录或文件（**外部可观测证据**：本 REQ 只做规划、不发压 ⇒ 不该有执行产物）
- **判据形式**: 查绝对事实（文件系统扫描 + 字面核）；探针：往环境文件加 `driver: "api"`（上游放行）→ 本条判红；把 `executor` 改成 `api` → 本条判红；让实现跑出一个 `.test-artifacts/runs/` 目录 → 本条判红
- **说明**: ①②的根因是上游 `resolveDriverName()` 的优先级「**环境 `driver`** → `suite.json.executor`」
  ⇒ 环境一旦写了合法枚举的 `driver`，`executor=load` 就被覆盖 ⇒ 压测套件被当功能用例跑 ⇒ **假象**。
  ④的落点选**文件系统**而不是「门源码长什么样」—— 后者会被「换个写法就绕过」钻空子，
  且让判据依赖被验对象之外的文本 ⇒ 不是绝对事实
- **类型**: 一致性

---

## F 组：诚实性（AC-021 ~ AC-024）

### AC-021: 没有指标来源 ⇒ 不写阈值，且**必须留未决问题**
- **前置条件**: §0.5 主跑产物
- **测试步骤**: 逐个场景看 `thresholds_status` 与它的 `open_questions[]`
- **预期结果**: ①`thresholds_status == "not_provided"` 的场景（夹具里是 `WL-002`）：`open_questions[]` 里**至少 1 条** `topic == "thresholds"`，且该条的 `question` **非空**；②`thresholds_status == "provided"` 的场景：`open_questions[]` 里**不得**有 `topic == "thresholds"` 的条目（没有缺口就不该留缺口）；③`not_provided` 的场景**不得**有 `thresholds` / `thresholds_source` 键（AC-011 已核，此处复核）
- **判据形式**: 查绝对事实；探针：让实现在无来源时既不写阈值、也**不留**未决问题 → 本条判红；让实现在有来源时乱留一条 thresholds 未决问题 → 本条判红
- **类型**: 诚实性

### AC-022: 不得把「未压测」写成「已通过」
- **前置条件**: §0.5 主跑产物
- **测试步骤**: 遍历**全部**产物 JSON（`scenarios/*.json` / 套件级 `scenario.json` / `suite.json` / `report.json`）的**任意层级**，查有没有压测结论键
- **预期结果**: ①**任何层级**都**不得**出现键名 `status` / `result` / `verdict` / `executed` / `passed` / `outcome` / `conclusion`（精确匹配键名 —— `thresholds_status` 这类**不是** `status`）；②**不得**出现值为 `true` 且键名形如 `passed` / `executed` / `ok` 的结论；③产物里**不得**有任何「压测已完成/已通过」的表述字段
- **判据形式**: 查绝对事实（全产物递归键名扫描）；探针：让实现在场景里写 `status: "passed"` → 本条判红
- **说明**: 本 REQ **不发压** ⇒ 任何「已通过」的结论都是**假的**。封闭字段集（F2.1 / D135）已排除大部分，但本条**独立**扫一遍，避免实现从别处塞一个结论字段进来
- **类型**: 诚实性

### AC-023: 未决问题必须字段齐全、id 唯一，且「无对应用例」必须留痕
- **前置条件**: §0.5 主跑产物
- **测试步骤**: 遍历所有场景与 `report.json` 的 `open_questions[]`；再找 `traceability.case_refs` 为空的场景
- **预期结果**: ①每条未决问题的键集**恰为** {`id`,`topic`,`question`}；②`id` 匹配 `^OQ-\d{3}$` 且**同一文件内唯一**；③`topic` ∈ {`thresholds`,`coverage`,`runner`,`other`}；④`question` **非空**（去首尾空白后仍非空）；⑤`traceability.case_refs` 为**空数组**的场景（夹具里是 `WL-004`）的 `open_questions[]` 里**至少 1 条** `topic == "coverage"`
- **判据形式**: 查绝对事实；探针：让实现在 `WL-004` 场景里不留 coverage 未决问题 → 本条判红；让实现把未决问题的 `id` 写成 `OQ-1` → 本条判红
- **说明**: 「无对应用例」必须显式 —— 那条被压链路**没有回归护栏**，压测结论**没有对照**，这是必须写在纸面上的事实
- **类型**: 诚实性

### AC-024: 与功能用例集只做**链路存在性**对账；不派生用例、不扩方法库
- **前置条件**: §0.5 主跑产物 + §0.1 上下文 + §0.2 用例集
- **测试步骤**: ① 用**归一化规则**（取 action 的「方法 + 空格 + 路径」并**删掉路径中所有 `{...}` 占位符段**）独立算出每个 workload 期望的 `case_refs`；② 与产物里的 `traceability.case_refs` 比对；③ 核 `traceability.workload_id` / `requirement_refs` 与输入逐字相等；④ 扫全部产物查有没有 `method` 字段
- **预期结果**: ①`case_refs` **恰等于**期望集合：`WL-001` → `["TC-001"]`、`WL-002` → `["TC-002"]`、`WL-003` → `["TC-001"]`、`WL-004` → `[]`（**多一个、少一个都违规**）；②`traceability.workload_id` **逐字等于**对应 workload 的 `id`；③`traceability.requirement_refs` **逐字等于**输入 workload 的 `requirement_refs`；④全部产物**不得**出现 `method` 字段（若出现，则该方法号必须是 `skills/test-case-design/references/methods.json` 里**真实存在**的编号 —— 该库共 9 个：`M1.1`~`M1.6` + `M2.1`/`M2.2`/`M2.3`；**库里没有压测方法**）；⑤产物里**不得**有 `cases.json`
- **判据形式**: 查绝对事实（独立复算 + 集合运算）；探针：让实现在 `case_refs` 里塞一个不存在的用例 id → 本条判红；让实现漏掉 `WL-002` 的 `TC-002`（没做占位符归一化）→ 本条判红
- **说明**: 上游 `validate-cases.mjs` 对 `cases[].method[]` **只查格式**、**不查方法号是否真的在方法库里** ⇒
  「方法号存在性」由**本 REQ 的门**用独立复算器判（同 REQ-008 的 D125）
- **类型**: 追溯

---

## G 组：追溯与写入权（AC-025 ~ AC-029）

### AC-025: 幂等：两份产物必须**逐字相同**
- **前置条件**: §0.1 + §0.2 + §0.4
- **测试步骤**: 同一输入跑两次（两个**不同**的 `--out-dir` 副本），把两份 `test-assets/load/` 目录下的**全部文件**逐个比对（内容 sha256 + 相对路径集合）
- **预期结果**: ①两份产物的**相对路径集合完全相等**；②每个同名文件的**内容逐字相同**（sha256 相同）；③**不得**出现任何生成时间戳 / 随机 id / 宿主路径之类的非确定性内容
- **判据形式**: 查绝对事实（文件系统指纹）；探针：让实现在产物里写 `meta.generated_at` 或用随机数当 id → 本条判红
- **说明**: 产物**不含**生成时间戳字段（顶层封闭 14 个，D135）⇒ 幂等就是「逐字相同」，不需要「排除某字段」这种易错操作
- **类型**: 一致性

### AC-026: 只写自己的目录
- **前置条件**: §0.4 项目根副本
- **测试步骤**: 跑前对 `<out-dir>` 下**除** `test-assets/load/` 以外的**一切**（文件集合 + 每个文件内容 sha256）取指纹；跑后再取一次；比对
- **预期结果**: ①`<out-dir>` 下**除** `test-assets/load/` 外**不得**出现任何**新增**文件；②既有文件的 sha256 **全部未变**；③**不得**写 `test-assets/environments/`（**不得**创建/修改环境文件）、**不得**写 `test-assets/cycles/`、**不得**写 `.gitignore`
- **判据形式**: 查绝对事实（目录指纹）；探针：让实现在生成产物时顺手改写 `environments/local.json` → 本条判红
- **类型**: 写入权

### AC-027: 不得改输入
- **前置条件**: §0.1 + §0.2
- **测试步骤**: 跑前对 `context.json` / `cases.json` 各算一次 sha256，跑完再算一遍
- **预期结果**: 两个输入文件的 sha256 **跑前跑后完全一致**
- **判据形式**: 查绝对事实；探针：让实现在生成产物时顺手改写 `cases.json`（比如补 case_refs）→ 本条判红
- **类型**: 写入权

### AC-028: 产物已存在即报错，且**不得覆盖**
- **前置条件**: §0.5 的主跑（第一次跑成功后的**同一个** out-dir）
- **测试步骤**: 在**同一个** out-dir 上**再跑一次**（输入不变），检查退出码、stderr 与既有产物
- **预期结果**: ①第二次跑**退出码为 1**（**不得**是 0）；②stderr **点名**「产物已存在」；③既有产物（第一次跑的 `test-assets/load/` 全部文件）**逐字未变**（**不得**覆盖 / 合并 / 部分更新）
- **判据形式**: 查绝对事实（文件系统指纹 + 真实退出码）；探针：让实现直接覆盖已存在的产物 → 本条判红
- **类型**: 写入权

### AC-029: 交付侧记账必须与实际一致
- **前置条件**: 被验包目录 + `feature-meta/load-profile/` 追溯件
- **测试步骤**: 逐项核 ① `feature-meta/load-profile/` 的四件套；② 该子目录 `manifest.json` 的 `req`；③ 根 `feature-meta/manifest.json` 的 `req`；④ 既有四个子目录各自的四件套；⑤ `traceability.md` 的追溯矩阵行数与编号集合；⑥ 三份 md 的判据条数与决策号范围记载
- **预期结果**: **六项全满足**；任一不符 → 判红并点名
  ① `feature-meta/load-profile/` 的四件套（`status.md` / `traceability.md` / `verification-report.md` / `manifest.json`）**齐全且非空**
  ② `feature-meta/load-profile/manifest.json` 的 `req` 是 `REQ-009`
  ③ 包内**根** `feature-meta/manifest.json` 必须**存在且非空**，且其 `req` 仍是 `REQ-006`（**不得**被改写成 `REQ-009` —— 本 REQ 的追溯件在 `feature-meta/load-profile/` 子目录里）
  ④ `feature-meta/test-report/`、`feature-meta/regression-plan/`、`feature-meta/defect-verify/`、`feature-meta/security-plan/` 各自的四件套必须**齐全且非空**，**不得**被改写或删除
  ⑤ `feature-meta/load-profile/traceability.md` 的追溯矩阵**行数 == 判据条数**、且矩阵里的**编号集合 == 判据编号集合**（两者都**动态取** `acceptance.md` 的实际条数与编号，**不写死**）
  ⑥ 三份 md（`status.md` / `traceability.md` / `verification-report.md`）的**判据条数取值唯一**、**决策号取值唯一且恰好等于实际决策号集合**
- **判据形式**: 查绝对事实（追溯件的实际内容 vs 契约的实际内容）
- **记载口径**: 判据条数在 md 里的**写法**必须能被抽取 —— 接受两种写法：「**29 条判据**」或「**判据条数：29**」（可带 `**` 等 markdown 强调符号）；两种写法抽出来的数字**取值集合**都必须恰好是 {29}（出现第二个不同取值即判红）。决策号范围的写法同理：接受 `D127~D155` 或逐个列出 `D127`…`D155`；⚠️ md 里**不得**出现本 REQ 之外的决策号（否则取值集合会多出它）。⚠️ 「取值唯一」指的是**范围字面量本身**：文件里出现的**每一个范围**展开后的决策号集合都必须**恰好**等于实际集合 —— 不能靠同一文件**别处**提到某个决策号把一个更小的范围**掩盖**掉
- **类型**: 追溯

---

## 判据类型分布

| 组 | 条数 | 范围 | 类型分布 |
|---|---|---|---|
| A 交付物形状 | 4 | AC-001 ~ AC-004 | 功能×2 / 可用性×1 / 兼容性×1 |
| B 输入解析与校验 | 4 | AC-005 ~ AC-008 | 功能×4 |
| C 负载模型 | 6 | AC-009 ~ AC-014 | 功能×2 / 诚实性×3 / 追溯×1 |
| D 套件落位 | 3 | AC-015 ~ AC-017 | 功能×3 |
| E 可消费与边界 | 3 | AC-018 ~ AC-020 | 一致性×2 / 诚实性×1 |
| F 诚实性 | 4 | AC-021 ~ AC-024 | 诚实性×3 / 追溯×1 |
| G 追溯与写入权 | 5 | AC-025 ~ AC-029 | 一致性×1 / 写入权×3 / 追溯×1 |
| **合计** | **29** | AC-001 ~ AC-029 | **功能 11 / 诚实性 7 / 一致性 3 / 追溯 3 / 写入权 3 / 可用性 1 / 兼容性 1** |

> 条数守恒核对：4 + 4 + 6 + 3 + 3 + 4 + 5 = **29**；
> 类型分布合计 11 + 7 + 3 + 3 + 3 + 1 + 1 = **29**。
> （AC-010 记为**追溯**；AC-019 记为**诚实性**；AC-025 记为**一致性**；AC-022 记为**诚实性**。）

---

## 验收纪律（对本 REQ 的验收方与实现者同样适用）

1. **一次只跑一个门** —— 并发跑门会产生无因果关系的失败键，污染判定。
2. **变异必须结构合法** —— 崩溃/语法错造成的判红是**假检出**，不计入检出率。
3. **变异注入后必须自证生效**（注入前后 sha256 比对 + 产物与基线不同）。
4. **判定「是否被检出」只看目标判据是否出现在新增失败键集合里**
   （新增失败键 = 变异运行的失败键 **减去** 基线失败键），**不能只看「比基线多」**，
   **更不能用对称差**（对称差把「基线红、变异后绿」也算成变化）。
5. **基线失败键只取 `^FAIL` 行** —— `PASS` / `UNDEC` 行里也有 AC 编号，混进来会让基线键集合
   变成**全集**，此后任何变异的「新增失败键」都恒为空或恒等于全集，**整套检测沦为橡皮章**。
6. **不可判定标「不可判定」**，不得判 passed。
7. **任何「脚本全绿」的结论必须钉 sha256**（验收脚本自身 sha + 被验实现指纹）。
8. **不许把不可满足的判据写成判据** —— 例如「`run-suite.mjs --dry-run` 跑通」
   （`load` 执行器未实现 ⇒ 必然抛错）。
9. **不许写「上游会拦」而上游其实不拦**（实测：`driver: "api"` 上游放行、`executor: "api"` 上游放行、
   场景内容上游**一条都不管**、套件目录名上游不校 ⇒ 这四条**全部由门判**）。
10. **不许判上游对整个项目根 rc=0**（那些前置条件不在本 REQ 的写入范围内 ⇒ 永远判红的假判据）；
    环境文件缺失 ⇒ **不可判定**，不算实现违约。
