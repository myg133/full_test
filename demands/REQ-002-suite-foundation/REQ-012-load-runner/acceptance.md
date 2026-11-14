# REQ-012 验收判据 —— `load-profile` runner 适配（负载模型 → 压测计划，**零请求**）

> 本文件是**契约**，不是说明材料。实现者按这里的规则交付，验收脚本按这里的规则判定。
> 判据条数：**29 条**（AC-001 ~ AC-029）。条数**不增不减不改号**。
> 决策记录见 `decisions.md`（D156 ~ D184）。功能契约见 `demand.md`（F1~F8）。

---

## §0 公共夹具规格（判据的公共前置）

验收脚本自造以下夹具，**全部落在临时目录**（`$WORK`），**不得**写进被验包。
夹具内容与 REQ-009 的产物形状一致（REQ-009 的契约见
`../REQ-009-load-profile/acceptance.md`）。

⚠️ **本 REQ 的入口只读 §0.3 / §0.4**；§0.1 / §0.2 是**来源说明**（REQ-012 的入口**不读**这两个文件），
保留它们是为了让「四容量目标的由来」可被复核。

### §0.1 压测上下文（**来源**，入口不读）

沿用 REQ-009 的四容量目标形态（订单服务 `order-api`；两个目标环境 `local` / `staging`）：

| `id` | `name` | `target` | `environment` | `profile` | 阈值来源 | `tool.runner` | `args` |
|---|---|---|---|---|---|---|---|
| WL-001 | checkout | `POST /api/v1/checkout` | local | `ramp-up`：`[60s@10c, 120s@20c]` | 有（`p95_latency_ms:800` + `error_rate:0.01`，来源「需求 REQ-005 性能指标」） | `loadtest` | `{rps:100, keepalive:true, timeout_s:10}` |
| WL-002 | order-query | `GET /api/v1/orders` | local | `constant`：`[300s@5c]` | **无**（⇒ `not_provided`） | `loadtest` | 无 |
| WL-003 | checkout-staging | `POST /api/v1/checkout` | staging | `spike`：`[30s@50c]` | 有（`p95_latency_ms:1200`，来源「需求 REQ-007 性能指标」） | `python` | `{command:["python","-m","mylab","--duration","{duration_s}","--concurrency","{concurrency}"]}` |
| WL-004 | health-check | `GET /api/v1/health` | local | `soak`：`[600s@2c]` | 有（`p95_latency_ms:200`，来源「需求 REQ-008 性能指标」） | `loadtest` | 无 |

⚠️ 三个**诚实性触发点**（本 REQ 必须如实继承）：

| 触发点 | 期望行为 |
|---|---|
| WL-002 **没有**指标来源 | 计划里该场景**不得**有阈值键，且**必须**携带 `topic == "thresholds"` 的未决问题 |
| WL-004 的 `traceability.case_refs == []`（无对应用例） | 计划里该场景**必须**携带 `topic == "coverage"` 的未决问题 |
| WL-001 与 WL-003 的 `target` **相同**但环境不同 | 二者落在**不同**套件（`LOAD-001` / `LOAD-002`） |

### §0.2 功能用例集（**来源**，入口不读）

cases.json v2，**3 条**用例：`TC-001`（`POST /api/v1/checkout`）· `TC-002`（`GET /api/v1/orders/{id}`）·
`TC-003`（`GET /api/v1/users/{id}/profile`）。
⇒ WL-001 / WL-003 的 `case_refs == ["TC-001"]`；WL-002 的 `case_refs == ["TC-002"]`（占位符归一化后）；WL-004 的 `case_refs == []`。

### §0.3 **已产出的 load 模型**（入口真正读的东西）

`$FX/proj/test-assets/load/`：

```
test-assets/load/
├── report.json                                   # REQ-009 的清单（本 REQ **不读**、不改）
├── scenarios/
│   ├── checkout.json          # WL-001
│   ├── checkout-staging.json  # WL-003
│   ├── health-check.json      # WL-004
│   └── order-query.json       # WL-002
└── suites/
    ├── LOAD-001-checkout/
    │   ├── scenario.json      # 引用件：3 个场景
    │   └── suite.json
    └── LOAD-002-checkout-staging/
        ├── scenario.json      # 引用件：1 个场景
        └── suite.json
```

**场景本体**（`scenarios/<name>.json`，顶层字段集 = REQ-009 的封闭 14 个）：

```json
// scenarios/checkout.json
{
  "schema_version": 1,
  "id": "WL-001",
  "name": "checkout",
  "service": "order-api",
  "target": "POST /api/v1/checkout",
  "environment": "local",
  "profile": { "type": "ramp-up", "steps": [ { "duration_s": 60, "concurrency": 10 }, { "duration_s": 120, "concurrency": 20 } ] },
  "thresholds": { "p95_latency_ms": 800, "error_rate": 0.01 },
  "thresholds_source": "需求 REQ-005 性能指标",
  "thresholds_status": "provided",
  "tool": { "runner": "loadtest", "runtime": "bun" },
  "args": { "rps": 100, "keepalive": true, "timeout_s": 10 },
  "traceability": { "workload_id": "WL-001", "requirement_refs": ["R-1"], "case_refs": ["TC-001"] },
  "open_questions": []
}
```

| 文件 | `id` | `environment` | `profile.type` | `steps` | `thresholds_status` | `tool.runner` | `args` |
|---|---|---|---|---|---|---|---|
| `checkout.json` | WL-001 | local | `ramp-up` | `[60s@10c, 120s@20c]` | `provided` | `loadtest` | `{rps:100, keepalive:true, timeout_s:10}` |
| `order-query.json` | WL-002 | local | `constant` | `[300s@5c]` | **`not_provided`**（**无** `thresholds` / **无** `thresholds_source` 键） | `loadtest` | **无 `args` 键** |
| `checkout-staging.json` | WL-003 | staging | `spike` | `[30s@50c]` | `provided` | **`python`** | `{command:["python","-m","mylab","--duration","{duration_s}","--concurrency","{concurrency}"]}` |
| `health-check.json` | WL-004 | local | `soak` | `[600s@2c]` | `provided` | `loadtest` | **无 `args` 键** |

`order-query.json` 的 `open_questions` = `[{ "id": "OQ-001", "topic": "thresholds", "question": "订单查询链路没有指标来源，未拍延迟/错误率阈值。" }]`；
`health-check.json` 的 `open_questions` = `[{ "id": "OQ-002", "topic": "coverage", "question": "健康检查链路在功能用例集里没有对应用例。" }]`；
其余两个场景的 `open_questions` = `[]`。

**套件引用件**（`suites/<套件名>/scenario.json`，顶层封闭 3）：

```json
// suites/LOAD-001-checkout/scenario.json
{
  "schema_version": 1,
  "suite": "LOAD-001-checkout",
  "scenarios": [
    { "path": "../../scenarios/checkout.json",      "id": "WL-001", "name": "checkout" },
    { "path": "../../scenarios/order-query.json",   "id": "WL-002", "name": "order-query" },
    { "path": "../../scenarios/health-check.json",  "id": "WL-004", "name": "health-check" }
  ]
}
```

**套件执行配置**（`suites/<套件名>/suite.json`，顶层 ⊆ REQ-009 的 9 个允许字段）：

```json
// suites/LOAD-001-checkout/suite.json
{
  "suite": "LOAD-001-checkout",
  "requirement": "REQ-009",
  "scope": "load",
  "environment": "local",
  "cases_file": "scenario.json",
  "executor": "load"
}
```

`LOAD-002-checkout-staging/` 同形，`environment` = `"staging"`，引用件里只有 `checkout-staging`（`path` = `../../scenarios/checkout-staging.json`）。

### §0.4 最小项目根与环境

```
$FX/proj/
├── .gitignore                                  # 含 ".test-artifacts/"（上游检查项）
└── test-assets/
    ├── environments/
    │   ├── _schema.json                        # 上游检查项
    │   ├── local.json                          # base_url = http://127.0.0.1:<P1>
    │   └── staging.json                        # base_url = http://127.0.0.1:<P2>
    └── cycles/
        ├── index.json
        └── R1-REQ-012/cycle.json
```

- `<P1>` / `<P2>` = 验收脚本启动的**两个桩服务端口**（见 §0.4.1）。
- `environments/local.json`：`{ "name": "local", "base_url": "http://127.0.0.1:<P1>", "timeout_ms": 3000, "retries": 0, "credentials": { "token_env": "TEST_TOKEN" } }`
- `environments/staging.json`：`{ "name": "staging", "base_url": "http://127.0.0.1:<P2>", "timeout_ms": 5000, "retries": 0, "credentials": { "token_env": "TEST_TOKEN_STAGING" } }`
- `environments/_schema.json`：`{ "type": "object", "properties": { "name": { "type": "string" }, "base_url": { "type": "string" } }, "required": ["name", "base_url"] }`
- `cycles/R1-REQ-012/cycle.json`：`{ "cycle_id": "R1-REQ-012", "requirement": "REQ-012", "status": "planned", "round": "R1", "round_type": "new-requirement", "scopes": ["functional", "load"], "stages": {}, "history": [ { "at": "2026-11-14T09:00:00+08:00", "from": "planned", "to": "planned", "by": "ba" } ], "scopes_skipped": [] }`
  ⚠️ **`history` 不可为空**（上游 `state-machine.mjs`：`history` 为空 ⇒ 判 FAIL）⇒ 空 history 会让 AC-028 ① 的
  「上游对整个项目根 rc=0」**永远不满足**（假判据）⇒ 夹具**必须**带至少一条状态变更留痕（形态同 REQ-009 的夹具）。
- `cycles/index.json`：`{ "cycles": [ { "id": "R1-REQ-012", "status": "planned", "round": "R1" } ] }`

#### §0.4.1 桩服务（**零请求**的可观测证据）

验收脚本在判定前启动**两个**本地 HTTP 桩（`127.0.0.1`，随机端口 `<P1>` / `<P2>`），
每个桩把收到的**每一个请求**追加一行到自己的日志文件。
跑完全部被验调用后，两个日志文件都必须**为空** ⇒ 一次请求都没发（AC-022）。

⚠️ 桩服务**只用于计数**，本 REQ 的入口**不得**连它；被验实现若连了 ⇒ 计数 > 0 ⇒ 判红。

#### §0.4.2 尾斜杠 `base_url` 的**环境变体**（需求方 Q8 裁定）

⚠️ **为什么要有它**：Q8 裁定「`base_url` **去尾部 `/`** + 路径直接拼接」，
但 §0.4 的两个环境文件 `base_url` **都不带**尾斜杠 ⇒ **该细则等于没被测**。
⇒ 夹具**另造一份项目根副本**（其余内容与 §0.4 相同，只改 `environments/local.json`）：

```
$FX/proj-slash/
└── test-assets/environments/local.json
    { "name": "local", "base_url": "http://127.0.0.1:<P1>/", "timeout_ms": 3000, "retries": 0, "credentials": { "token_env": "TEST_TOKEN" } }
```

| # | 期望（AC-009 ④⑤） | 说明 |
|---|---|---|
| 1 | 场景条目的 `base_url` **字段** == `http://127.0.0.1:<P1>/`（**含尾斜杠，逐字**） | 字段**逐字承载**环境文件的值 |
| 2 | `argv` 里的 URL == `http://127.0.0.1:<P1>/api/v1/checkout`（**不含** `//`） | URL **去尾部 `/`** 后拼路径 |

⚠️ 该变体**只跑一次主跑**（不参与 §0.6 的「计划文件恰好 2 份」基线 —— 它的落点与主跑一致），
判定**并入 AC-009**（第 ⑦ 项）⇒ **不新增判据条数**。

### §0.5 主跑命令

```
node skills/load-profile/scripts/plan-load-run.mjs \
  --load-dir <项目根> \
  --out-dir  <项目根>
```

⚠️ `--load-dir` 与 `--out-dir` **指向同一个项目根**是**最自然**的用法（读 `test-assets/load/`，
写 `test-assets/load/plans/`）。产物落点：

```
<项目根>/test-assets/load/plans/
├── LOAD-001-checkout.json
└── LOAD-002-checkout-staging.json
```

⚠️ **计划文件的名字绝不能叫 `suite.json`**（上游对 `suite.json` 的顶层字段集封闭 ⇒ 同名会被当成套件）。
⚠️ `test-assets/load/plans/` 这个新目录**对上游 `verify-layout.mjs` 无影响**（上游只递归找 `suite.json`，
且不拦 `test-assets/` 下的未知子目录）⇒ 上游对该项目根的判定仍是 **0 FAIL、rc=0**
（`[OK]` 的**条数**随上游版本变化，**不写死**）。

### §0.6 基线真值表（夹具跑出来的**唯一**正确结论）

⚠️ **诚实声明**：本表只固定**可机械核**的那部分真值。
**未决问题的具体文字**属实现方的判断（契约只要求「非空 + 主题正确」），本表**不**规定。

| # | 字段 | 真值 | 来源 |
|---|---|---|---|
| 1 | 计划文件**条数** | **恰好 2** | AC-013 |
| 2 | 计划文件名集合 | **恰等于** `{LOAD-001-checkout.json, LOAD-002-checkout-staging.json}` | AC-013 |
| 3 | 计划顶层字段集 | **恰为 4 个**：`schema_version`/`suite`/`environment`/`scenarios` | AC-004 |
| 4 | `schema_version` | `1` | AC-004 |
| 5 | 场景条目字段集 | **恰为 10 个必填 + 2 个条件**：`scenario_id`/`scenario_name`/`runner`/`runtime`/`target`/`base_url`/`profile_type`/`invocations`/`thresholds_status`/`open_questions` + 条件 `thresholds`/`thresholds_source` | AC-004 |
| 6 | `invocations[]` 元素字段集 | **恰为 4 个**：`step_index`/`duration_s`/`concurrency`/`argv` | AC-004 |
| 7 | `LOAD-001` 的 `scenarios[]` | **3 项**，顺序 = `checkout` → `order-query` → `health-check`（= 引用件顺序） | AC-013 |
| 8 | `LOAD-002` 的 `scenarios[]` | **1 项**（`checkout-staging`） | AC-013 |
| 9 | 每个计划的 `suite` | **等于**文件���去 `.json` **等于**套件目录名 | AC-013 |
| 10 | 每个计划的 `environment` | `LOAD-001` ⇒ `local`；`LOAD-002` ⇒ `staging`（= 套件 `suite.json` 的 `environment`） | AC-013 |
| 11 | 每个场景条目的 `base_url` | **逐字等于**环境文件里的 `base_url` | AC-009 |
| 12 | `checkout` 的 `invocations` | **2 条**（多段保真，**不许合并**） | AC-011 |
| 13 | `checkout` 的 `argv` | ① `["loadtest","-t","60","-c","10","--cores","1","http://127.0.0.1:<P1>/api/v1/checkout","-m","POST","--rps","100","-k","-d","10000"]`<br>② `["loadtest","-t","120","-c","20","--cores","1","http://127.0.0.1:<P1>/api/v1/checkout","-m","POST","--rps","100","-k","-d","10000"]` | AC-009/010/011/012/014/015/016 |
| 14 | `order-query` 的 `invocations` | **1 条**，`argv` = `["loadtest","-t","300","-c","5","--cores","1","http://127.0.0.1:<P1>/api/v1/orders","-m","GET"]`（**无** `--rps`/`-k`/`-d`，因为模型无 `args`） | 同上 |
| 15 | `health-check` 的 `invocations` | **1 条**，`argv` = `["loadtest","-t","600","-c","2","--cores","1","http://127.0.0.1:<P1>/api/v1/health","-m","GET"]` | 同上 |
| 16 | `checkout-staging` 的 `invocations` | **1 条**，`argv` = `["python","-m","mylab","--duration","30","--concurrency","50"]`（**自陈命令** + 占位符替换；**不得**执行） | AC-018 |
| 17 | `checkout` 的 `thresholds` | **逐字等于** `{"p95_latency_ms": 800, "error_rate": 0.01}` | AC-020 |
| 18 | `order-query` 的场景条目 | **不得**有 `thresholds` / `thresholds_source` 键 | AC-020 |
| 19 | `order-query` 的未决问题 | **≥1 条** `topic == "thresholds"`（`question` 非空） | AC-021 |
| 20 | `health-check` 的未决问题 | **≥1 条** `topic == "coverage"` | AC-021 |
| 21 | `checkout` / `checkout-staging` 的未决问题 | **不得**有 `topic == "thresholds"` 的条目 | AC-021 |
| 22 | 全部计划产物 | **不得**出现压测结论键（`status`/`result`/`verdict`/`executed`/`passed`/`outcome`/`conclusion`），**不得**出现「已压测/已达标/已通过」表述 | AC-019 |
| 23 | 桩服务请求计数 | **两个桩都是 0** | AC-022 |
| 24 | 幂等 | 同一输入跑两次（两个不同项目根）⇒ 两份 `plans/` 目录树**逐字相同** | AC-025 |
| 25 | 只写自己的目录 | 项目根下**除** `test-assets/load/plans/` 外一切**逐字未变** | AC-023 |
| 26 | 输入只读 | 模型 / 套件 / 环境文件 sha256 跑前跑后**一致** | AC-024 |
| 27 | 产物已存在即报错 | 同一项目根第二次跑 ⇒ **rc=1** 且既有 `plans/` **逐字未变** | AC-026 |
| 28 | 未知 `args` 键 | **rc=1** + stderr 点名该键 + **不留** `plans/` | AC-017 |
| 29 | `python` runner 缺自陈命令 | **rc=1** + stderr 点名 `command` + **不留** `plans/` | AC-018 |
| 30 | 用法错误 | **rc=2** | AC-005 |

### §0.7 非法输入**变体**（供 B / D 组实跑）

每份变体 = §0.3 / §0.4 的项目根**副本** + 一处改动。判定口径：
**rc=1**（`python` 缺命令 / 未知 `args` 键两条亦然）、stderr **点名坏点**、**不得**留下 `plans/` 目录。

| # | 变体 | 坏在哪 | 目标判据 |
|---|---|---|---|
| V1 | `scenarios/order-query.json` 的 `profile.steps[0].concurrency` 改成 `0` | 并发必须是 ≥1 的整数 | AC-007 |
| V2 | `scenarios/checkout.json` 的 `target` 改成 `POST api/v1/checkout` | `target` 必须形如 `METHOD /path` | AC-007 |
| V3 | `scenarios/health-check.json` 的 `tool.runner` 改成 `jmeter` | `runner` 枚举越界 | AC-007 |
| V4 | 删掉 `environments/staging.json` | 环境文件不存在 ⇒ `base_url` 取不到 | AC-006 |
| V5 | `environments/local.json` 删掉 `base_url` 键 | 环境文件没有 `base_url` | AC-006 |
| V6 | `suites/LOAD-001-checkout/scenario.json` 里第一条引用的 `id` 改成 `WL-999` | 引用与本体**漂移** | AC-006 |
| V7 | `suites/LOAD-001-checkout/scenario.json` 里第一条引用的 `path` 改成 `../../scenarios/nope.json` | 引用指向**不存在的**场景 | AC-006 |
| V8 | `scenarios/checkout.json` 的 `args` 加一个未知键 `"concurrency": 5` | `args` 未知键 ⇒ 拒绝 | AC-017 |
| V9 | `scenarios/checkout-staging.json` 的 `args` 删掉 `command` 键 | `python` runner 缺自陈命令 | AC-018 |
| V9b | `scenarios/checkout-staging.json` 的 `args.command` 改成**字符串** `"python -m mylab"` | 自陈命令必须是**完整 argv 数组**（字符串 ⇒ 分词歧义） | AC-018 |

⚠️ **用法错误**另测（AC-005）：① 不传 `--load-dir`；② 不传 `--out-dir`；③ 传未知参数 `--dry-run`；
④ 多传一个位置参数。**四种都必须是 rc=2**。

---

## A 组：交付物形状（AC-001 ~ AC-004）

### AC-001: 两个新入口脚本形状合法，且**校验器有行为护栏**
- **前置条件**: 被验包目录
- **测试步骤**:
  ① `skills/load-profile/scripts/plan-load-run.mjs` 与 `skills/load-profile/scripts/check-load-run.mjs`
     **各自**存在、**非空**、首行 `#!/usr/bin/env node`、**可执行**（权限位含 `x`）、`node --check` 通过；
  ② **实跑**校验器：`node skills/load-profile/scripts/check-load-run.mjs <§0.5 的项目根>`
     ⇒ 退出码必须为 **0**；
  ③ 把该项目根**复制一份**，在副本里篡改一个计划（例如把某条 `argv` 的 `-t` 值从 `60` 改成 `61`），
     再**实跑**校验器 ⇒ 退出码必须为 **1**（**不得**是 0，**也不得**是 2 —— 2 是用法错，说明它压根没在校验）。
- **预期结果**: ①⑤项全满足；②rc=0；③rc=1。任一不满足 → 判红并**点名是哪一项**
- **判据形式**: 查**绝对事实**（文件真实存在/权限/真实退出码）；探针：把 `plan-load-run.mjs` `chmod -x` → 本条判红；
  把 `check-load-run.mjs` 换成「永远 exit 0」的脚本 → ③不成立 → 本条判红
- **⚠️ 口径**：校验器**必须被实跑**并对篡改计划判红 —— 「存在且非空 + `node --check` 通过」**不算**行为护栏
  （REQ-011 的 `check-plan.mjs` 从未被门执行过 ⇒ 改坏了不会被红 ⇒ 那是遗留项，本 REQ 不许重犯）
- **类型**: 功能

### AC-002: REQ-009 既有 14 个文件**逐字未改**
- **前置条件**: 被验包目录 + §0.8 的指纹基线表
- **测试步骤**: 对 `skills/load-profile/` 下 §0.8 列出的 **14 个**文件逐个算 sha256，与基线表比对
- **预期结果**: **14 个** sha256 **全部一致**（不多不少：新增文件**不在**本表内，不判红）；任一不一致 → 判红并**点名是哪个文件**
- **判据形式**: 查绝对事实（sha256 逐字比对）；探针：往 `references/profile-rules.md` 末尾加一行 → 本条判红
- **说明**: REQ-009 的门对 `skills/load-profile/` **只检查既有文件「存在且非空」** ⇒ **新增**文件不会让 REQ-009 的门判红；
  但**改**既有文件的内容，本 REQ 必须拦（SPEC §1.2 第 3 条：「既有 14 文件一个都不许改」）
- **类型**: 兼容性

### AC-003: README **两处**都在，且必须提到两个新脚本
- **前置条件**: 被验包目录 + `README.md`
- **测试步骤**: ① 取 `skills/` 下全部含 `SKILL.md` 的目录名集合 S；② 取 `README.md` 的 skill 清单
  （表格首格 ∪ `skills/<name>` 路径 ∪ 安装树条目）集合 R；③ 核 S == R；
  ④ 核 `load-profile` 出现在 **skill 表格**里；⑤ 核 `load-profile` 出现在 **安装树代码块**里；
  ⑥ 核 README 全文出现 `plan-load-run.mjs` 与 `check-load-run.mjs` **两个名字**（各至少一次）
- **预期结果**: ①集合完全相等；②~⑤全满足；⑥两个名字都在。任一不满足 → 判红并**点名漏在哪一处**
- **判据形式**: 查绝对事实（与目录实际内容比对），不查「README 里说了几个」
- **类型**: 可用性

### AC-004: 计划产物的**字段集封闭**（三层）与枚举取值合法
- **前置条件**: §0.5 主跑产物
- **测试步骤**: 取每个 `plans/*.json` 的顶层键集；再逐个取 `scenarios[]` 元素键集与 `invocations[]` 元素键集；
  并核各处枚举取值
- **预期结果**:
  ① 每个计划顶层键集**恰为** {`schema_version`,`suite`,`environment`,`scenarios`}；
  ② `schema_version == 1`；
  ③ `scenarios[]` 是**非空数组**，元素键集**恰为**
     {`scenario_id`,`scenario_name`,`runner`,`runtime`,`target`,`base_url`,`profile_type`,`invocations`,`thresholds_status`,`open_questions`}
     **加**条件字段 `thresholds` / `thresholds_source`（有无按 AC-020 判）；
  ④ `invocations[]` 是**非空数组**，元素键集**恰为** {`step_index`,`duration_s`,`concurrency`,`argv`}；
  ⑤ `runner` ∈ {`loadtest`,`python`}、`runtime` ∈ {`bun`,`python`,`node`}、
     `profile_type` ∈ {`constant`,`ramp-up`,`ramp-down`,`spike`,`soak`}（**产物侧**也要拦，输入层被绕过时产物层仍要拦）；
  ⑥ `duration_s` / `concurrency` 是**整数 ≥ 1**；`step_index` 是**整数 ≥ 0**；
  ⑦**特别地**：三层字段集里**不得**出现 `cases_file` 之类会被上游 `suite.json` 语义混淆的字段
  （`cases_file` 是上游 `suite.json` 的字段，计划里再出现会与上游语义混淆）
- **判据形式**: 查绝对事实（逐字段核）；探针：让实现在计划顶层加一个 `note` → 本条判红
- **类型**: 功能

---

## B 组：输入解析与校验（AC-005 ~ AC-008）

### AC-005: 用法错误必须判 **rc=2**（与「输入非法」分层）
- **前置条件**: 被验包 + §0.5 的项目根
- **测试步骤**: 四种用法错误各跑一次（缺 `--load-dir` / 缺 `--out-dir` / 未知参数 `--dry-run` / 多一个位置参数），
  检查退出码
- **预期结果**: 四种情形**退出码均为 2**（**不得**是 0，也**不得**是 1）；且**不得**留下 `plans/` 目录
- **判据形式**: 查绝对事实（真实退出码 + 产物目录实况）；探针：让实现把用法错当输入非法（rc=1）→ 本条判红
- **说明**: F1 的两层退出码（2 = 用法错 / 1 = 输入非法）**必须**可区分 ⇒ 需求方能一眼看出「调用方式写错了」还是「数据有问题」
- **类型**: 功能

### AC-006: 模型 / 套件 / 环境必须**读全**，引用不得悬空、不得漂移
- **前置条件**: §0.7 的 **V4 / V5 / V6 / V7** 四份变体
- **测试步骤**: 四种变体各跑一次，检查退出码、stderr、输出目录
- **预期结果**: 四种情形**退出码均为 1**；stderr **点名坏点**（V4/V5 点名环境名或 `base_url`；
  V6 点名漂移的 `id`（`WL-999`）；V7 点名解析不到的文件）；**不得**留下 `plans/` 目录
- **判据形式**: 查绝对事实；探针：让实现在环境文件缺失时仍把 `base_url` 猜成 `""` → 本条判红
- **类型**: 功能

### AC-007: 模型**内容**必须合法（画像 / 目标 / 枚举）
- **前置条件**: §0.7 的 **V1 / V2 / V3** 三份变体
- **测试步骤**: 三种变体各跑一次，检查退出码、stderr、输出目录
- **预期结果**: 三种情形**退出码均为 1**；stderr **点名坏点**（V1 点名 `concurrency`；V2 点名 `target`；
  V3 点名 `runner` 与越界值 `jmeter`）；**不得**留下 `plans/` 目录
- **判据形式**: 查绝对事实；探针：让实现接受 `concurrency: 0` → V1 判红
- **类型**: 功能

### AC-008: 非法输入 ⇒ **不留半份产物**（先校验、后建目录）
- **前置条件**: §0.7 的 **V1 ~ V9b 全部十份**变体
- **测试步骤**: 十份变体各跑一次（每次用**独立**的项目根副本），跑完后检查
  `<项目根>/test-assets/load/plans/` 是否存在（**存在性**判定，**0 字节的空目录也算存在**）
- **预期结果**: 十种情形**全部**满足：`<项目根>/test-assets/load/plans/` **不存在**
- **判据形式**: 查绝对事实（文件系统实况）；探针：让实现在校验前先 `mkdir plans/` → 本条判红
- **说明**: 「先校验、后建目录」是 F6 的硬约束 —— 半份产物会让 B 阶段误以为「已经跑过」
- **类型**: 写入权

---

## C 组：计划形态（AC-009 ~ AC-013）

### AC-009: `argv` 必须**完整可跑**（工具名 + 完整绝对 URL + 结构合法）
- **前置条件**: §0.5 主跑产物
- **测试步骤**: 逐条 `invocations[]` 的 `argv` 逐元素核：
  ① 是**非空字符串数组**（无空元素、无非字符串元素）；
  ② `argv[0]` 是**工具名**（`runner == "loadtest"` ⇒ `argv[0] == "loadtest"`；
     `runner == "python"` ⇒ `argv[0]` == 自陈命令 `args.command` 的第 0 个元素）；
  ③ `argv` 里**恰好一个**元素是**完整绝对 URL**（以 `http://` / `https://` / `ws://` / `wss://` 开头）；
     ⚠️ **作用域（BA 自查修订）**：本项**只对 `runner == "loadtest"` 的场景**成立 ——
     `python` runner 的 argv 由**自陈命令**决定（夹具里的命令**不含 URL**）⇒ 字面判据对它**不可满足**；
     `python` 侧的对应要求是「**若** argv 里出现了绝对 URL，则**恰好一个**且逐字等于 `base_url`（去尾部 `/`）+ 目标路径」；
  ④ 该 URL **逐字等于** `base_url`（去尾部 `/`）+ 目标路径（见 AC-010）；
  ⑤ 场景条目的 `base_url` 字段**逐字等于**环境文件里的 `base_url`；
  ⑥ `loadtest` runner 的 `argv` 结构**恰为**
     `["loadtest", "-t", <duration_s>, "-c", <concurrency>, "--cores", "1", <url>, "-m", <METHOD>]`
     后可依次跟 `["--rps", <rps>]`、`["-k"]`、`["-d", <timeout_ms>]`
     ⇒ **不得**出现表外选项、**不得**出现第二个位置参数
  ⑦ **另跑 §0.4.2 的尾斜杠环境变体**（`base_url` 带尾部 `/`）⇒
     场景条目的 `base_url` **字段**逐字等于 `http://127.0.0.1:<P1>/`（**含尾斜杠**），
     而 `argv` 里的 URL 必须是 `http://127.0.0.1:<P1>/api/v1/checkout`（**不得**出现 `//`）
- **预期结果**: ①~⑦全满足；任一不满足 → 判红并点名（哪个场景、哪条 invocation、哪个元素）
- **判据形式**: 查绝对事实（逐元素核）；探针：让实现在 URL 里漏掉 `base_url`（只留路径）→ 本条判红
- **说明**: `loadtest` 的 URL 是**唯一位置参数**（多一个 ⇒ `Too many arguments`）⇒ URL 必须**完整绝对**
  （PROBE-FACTS C3/C4）
- **类型**: 功能

### AC-010: 方法与路径必须**分离**
- **前置条件**: 同上
- **测试步骤**: 逐条 `argv` 核（⚠️ **作用域（BA 自查修订）**：①~④ 的**结构性要求只对 `runner == "loadtest"` 的场景**成立 ——
  `python` runner 的 argv 由**自陈命令**决定（夹具里的命令**不含 `-m`**）⇒ 字面判据对它**不可满足**；
  `python` 侧见 AC-018 ③）：
  ① `-m` **恰好出现一次**；② `-m` 的下一个元素 == 方法（大写）；
  ③ 方法 == `target` 的方法（`target` 形如 `METHOD /path`，取空格前那段，**转大写**）；
  ④ 若模型的 `args.method` 存在，则 `-m` 的值 == `args.method`（**大写**）；
  ⑤ **路径**（`target` 里空格后的那段，以 `/` 开头）**只**出现在那个绝对 URL 元素里，
     `argv` 的**其它**元素**不得**包含该路径字符串（**本项对两种 runner 都适用**）
- **预期结果**: ①~⑤全满足；任一不满足 → 判红并点名
- **判据形式**: 查绝对事实（逐元素核）；探针：让实现在 URL 之外再带一个路径元素 ⇒ 或把 `-m POST` 改成 `-m GET` → 本条判红
- **类型**: 功能

### AC-011: 多段画像必须**保真**（每段一条 invocation，不许合并）
- **前置条件**: §0.5 主跑产物 + §0.3 的模型
- **测试步骤**: 对每个场景，把计划里的 `invocations[]` 与模型的 `profile.steps[]` **逐项**比对
- **预期结果**:
  ① `invocations` 的**条数** == `steps` 的**条数**；
  ② 第 i 条的 `step_index` == **i**（0 起，**顺序不排序、不归并**）；
  ③ 第 i 条的 `duration_s` / `concurrency` **逐字等于** `steps[i]` 的同名值；
  ④ **不得**把多段**合并**成一条（合并 ⇒ 条数变少 ⇒ ①即红）
- **判据形式**: 查绝对事实（逐项比对）；探针：让实现把 ramp-up 的两段合并成一条（取第一段）→ 本条判红
- **说明**: 合并 = 丢梯度 = 失真（G3 裁定「每 step 一条 invocation」）
- **类型**: 诚实性

### AC-012: `--cores 1` 必须**恒定钉死**
- **前置条件**: 同上（只对 `runner == "loadtest"` 的场景）
- **测试步骤**: 逐条 `loadtest` runner 的 `argv` 核：`--cores` 出现**恰好一次**，且其**下一个元素**恰为 `"1"`
- **预期结果**: 全部满足；出现 `--cores 2`、删掉 `--cores`、或 `--cores` 后面跟别的值 ⇒ 判红并点名
- **判据形式**: 查绝对事实；探针：让实现在多核机器上按默认半核生成 ⇒ 本条判红
- **说明**: `loadtest` 的 `maxRequests` / `rps` 会**按核分摊**（PROBE-FACTS C14/D8）⇒ 不钉 `--cores 1`
  则语义随机器变（同一份计划在不同机器上不是同一次压测）
- **类型**: 一致性

### AC-013: 计划文件必须与**套件一一对应**
- **前置条件**: §0.5 主跑产物 + §0.3 的套件
- **测试步骤**: ① 列 `plans/` 下的文件名集合 P；② 列 `suites/` 下的套件目录名集合 S；
  ③ 核 P == { `<套件名>.json` : 套件名 ∈ S }；④ 每个计划的 `suite` == 文件名去 `.json` == 套件目录名；
  ⑤ 每个计划的 `environment` == 该套件 `suite.json` 的 `environment`；
  ⑥ 每个计划的 `scenarios[]` 的 `scenario_id` 序列**逐项等于**该套件引用件里的场景顺序；
  ⑦ `plans/` 下**不得**出现 `suite.json`（同名会被上游当成套件）
- **预期结果**: ①~⑦全满足；任一不满足 → 判红并点名（缺哪个、多哪个、顺序差在哪）
- **判据形式**: 查绝对事实（集合运算 + 逐项比对）；探针：删掉一个计划文件 → 本条判红；把计划文件改名成 `suite.json` → ⑦判红
- **类型**: 功能

---

## D 组：参数映射（AC-014 ~ AC-018）

### AC-014: `-t` / `-c` 必须逐字映射该段的时长与并发
- **前置条件**: §0.5 主跑产物 + §0.3 的模型
- **测试步骤**: 逐条 `loadtest` runner 的 `argv` 核：① `-t` 出现**恰好一次**，其下一个元素 ==
  该条 invocation 的 `duration_s` 的**字符串形态**；② `-c` 出现**恰好一次**，其下一个元素 ==
  该条 invocation 的 `concurrency` 的**字符串形态**
- **预期结果**: 全部满足；把 `-t 60` 改成 `-t 61`、或把 `-c 10` 改成 `-c 50` ⇒ 判红并点名
- **判据形式**: 查绝对事实（相邻元素比对）；探针：让实现把并发写成 `-c 10.0` ⇒ 判红
- **类型**: 功能

### AC-015: `args.timeout_s`（**秒**）必须换算成 `-d`（**毫秒**）
- **前置条件**: §0.5 主跑产物（`checkout` 的 `args.timeout_s == 10`）
- **测试步骤**: 逐条 `loadtest` runner 的 `argv` 核：① 若该场景的模型 `args` 有 `timeout_s`，
  则 `-d` 出现**恰好一次**，其下一个元素 == `String(Math.round(timeout_s * 1000))`；
  ② 若模型的 `args` **没有** `timeout_s`，则 `argv` 里**不得**出现 `-d`
- **预期结果**: 夹具里 `timeout_s == 10` ⇒ **`-d` 的下一个元素必须是 `"10000"`**；
  出现 `-d 10`（**秒当毫秒**）⇒ 判红并点名
- **判据形式**: 查绝对事实（相邻元素 + 换算复算）；探针：让实现直接透传 `10` ⇒ 本条判红
- **说明**: `-d` 是**单请求**超时（毫秒），不是压测总时长（PROBE-FACTS C10/D6）—— 这是本 REQ 最易错的一处
- **类型**: 功能

### AC-016: `--rps` / `-k` 必须逐字映射
- **前置条件**: §0.5 主跑产物 + §0.3 的模型
- **测试步骤**: 逐条 `loadtest` runner 的 `argv` 核：
  ① 模型 `args` 有 `rps` ⇒ `--rps` 出现**恰好一次**，其下一个元素 == `String(rps)`；无 ⇒ **不得**出现 `--rps`；
  ② 模型 `args` 的 `keepalive == true` ⇒ `-k` 出现**恰好一次**；`keepalive` 缺失或 `false` ⇒ **不得**出现 `-k`
- **预期结果**: 夹具里 `checkout` ⇒ `--rps 100` 与 `-k` **都在**；`order-query` / `health-check` ⇒ **都不在**
- **判据形式**: 查绝对事实；探针：让实现漏掉 `-k` ⇒ 本条判红；让实现在没有 rps 时也写 `--rps 0` ⇒ 本条判红
- **类型**: 功能

### AC-017: `args` 的**未知键必须拒绝**（rc=1，点名该键）
- **前置条件**: §0.7 的 **V8**（`args` 里多一个未知键 `"concurrency": 5`）
- **测试步骤**: 跑 V8，检查退出码、stderr、输出目录
- **预期结果**: ①退出码 == **1**；②stderr **点名那个未知键**（`concurrency`）；
  ③**不得**留下 `plans/` 目录；④**不得**「静默忽略未知键」（若产物里出现了该键 ⇒ 同样判红）
- **判据形式**: 查绝对事实（真实退出码 + stderr + 文件系统）；探针：让实现忽略未知键并照常出计划 → ①判红
- **说明**: 「静默忽略」= 悄悄丢参数 = 压出来的不是你想压的（G4 裁定：**诚实优先于宽容**）
- **类型**: 诚实性

### AC-018: `python` runner 必须**自陈完整命令**
- **前置条件**: §0.5 主跑产物 + §0.3 的模型（`checkout-staging` 的 `args.command`）+ §0.7 的 **V9 / V9b**
- **测试步骤**:
  ① 跑 V9（`args` 里没有 `command`）⇒ 检查退出码、stderr、输出目录；
  ② 跑一个**变体 V9b**（`args.command` 是一个**字符串** `"python -m mylab"` 而不是**数组**）
  ⇒ 检查退出码、stderr、输出目录；
  ③ 对主跑产物里 `runner == "python"` 的场景，核每条 `invocations[].argv`：
     a. 以自陈命令（占位符 `{duration_s}` / `{concurrency}` **替换为该段取值**后）为**前缀**；
     b. **含有**恰好等于 `String(duration_s)` 的元素与恰好等于 `String(concurrency)` 的元素；
     c. **不得**残留 `{duration_s}` / `{concurrency}` 占位符；
     d. 该场景有 ≥2 段时，各条 `argv` **互不相同**
- **预期结果**: ①③rc=1 + stderr 点名 `command` + **不留** `plans/`；②rc=1 + stderr 点名 `command`
  （**必须是数组**：字符串命令要分词 ⇒ 分词歧义 ⇒ 不接受）；③a~d全满足
- **判据形式**: 查绝对事实（真实退出码 + stderr + 逐元素比对）；探针：让实现在 `python` runner 上**编造**一条默认命令
  （模型里没有 `command` 也照样出计划）→ ①判红
- **说明**: 没有事实支撑的命令 = 凭空造（G6 裁定：契约钉死「必须自陈完整」这一条，不钉死具体命令形态）
- **类型**: 诚实性

---

## E 组：诚实性与边界（AC-019 ~ AC-022）

### AC-019: 不得出现任何**压测结论**（键名与表述）
- **前置条件**: §0.5 主跑产物
- **测试步骤**: 遍历**全部**计划产物的**任意层级**（`plans/*.json`），查键名与字符串值
- **预期结果**:
  ①**任何层级**都**不得**出现键名 `status` / `result` / `verdict` / `executed` / `passed` / `outcome` / `conclusion`
  （**精确匹配键名** —— `thresholds_status` 这类**不是** `status`）；
  ②**不得**出现值为 `true` 且键名形如 `passed` / `executed` / `ok` 的结论；
  ③**不得**出现「已压测」「已达标」「已通过」「压测完成」「压测结果」这类**表述**（作为字符串值或键名的一部分）
- **判据形式**: 查绝对事实（全产物递归扫描）；探针：让实现在计划里写 `status: "passed"` ⇒ 本条判红
- **说明**: 本 REQ **一个请求都不发** ⇒ 任何「已通过」都是**假的**
- **类型**: 诚实性

### AC-020: 阈值的**二态**必须与模型一致（键的**有无** + 逐字相等）
- **前置条件**: §0.5 主跑产物 + §0.3 的模型
- **测试步骤**: 逐个场景核 `thresholds_status` 与 `thresholds` / `thresholds_source` 三个键
- **预期结果**:
  ①模型 `thresholds_status == "provided"` ⇒ 计划里 `thresholds_status == "provided"` 且
     `thresholds` 与 `thresholds_source` **两个键都存在**且**逐字等于**模型；
  ②模型 `thresholds_status == "not_provided"` ⇒ 计划里 `thresholds_status == "not_provided"` 且
     **两个键都不存在**；
  ③`thresholds_status` 只允许 `provided` / `not_provided` 两个取值
- **判据形式**: 查绝对事实（键的存在性 + 值字面比对）；探针：让实现在 `not_provided` 的场景里补一个
  `p95_latency_ms: 1000` ⇒ 本条判红
- **类型**: 诚实性

### AC-021: 未决问题必须**字段齐全**且「无来源必留痕」
- **前置条件**: §0.5 主跑产物 + §0.3 的模型
- **测试步骤**: 遍历每个场景条目的 `open_questions[]`（⚠️ 该字段是 **F3.2 的必填字段**，
  值为模型对应场景 `open_questions` 的**承载**；契约缺陷已按需求方 §10.1 修掉）
- **预期结果**:
  ①每条未决问题的键集**恰为** {`id`,`topic`,`question`}；
  ②`id` 匹配 `^OQ-\d{3}$`，且**同一计划文件内唯一**（⚠️ **按计划文件（套件级）判定** ⇒
  **跨场景**的 `id` 也必须唯一 —— 需求方 §10.1 裁定）；
  ③`topic` ∈ {`thresholds`,`coverage`,`runner`,`other`}；④`question` **非空**（去首尾空白后仍非空）；
  ⑤模型 `thresholds_status == "not_provided"` 的场景 ⇒ 计划里**至少 1 条** `topic == "thresholds"`；
  ⑥模型 `thresholds_status == "provided"` 的场景 ⇒ 计划里**不得**有 `topic == "thresholds"` 的条目；
  ⑦模型 `traceability.case_refs == []` 的场景 ⇒ 计划里**至少 1 条** `topic == "coverage"`；
  ⑧**承载一致性**：计划里该场景的 `open_questions[]` 与模型对应场景的 `open_questions[]`
     **条目数相等**，且**逐条**的 `id` 与 `topic` **逐字等于**模型同一条目
     （⚠️ `question` 的**文字不要求逐字相等** —— 需求方 Q5 裁定「措辞属实现方判断」；
     **严格逐字**的口径见 `demand.md` F3.2 的「口径分歧留痕」⇒ 改这一处即可）
- **判据形式**: 查绝对事实；探针：让实现在 `order-query` 场景既不写阈值、也**不留**未决问题 ⇒ ⑤判红
- **说明**: 「没有指标来源就不拍阈值」与「没有回归护栏就必须写在纸面上」——两个缺口都必须**显式**
- **⚠️ ⑤⑦ 与 ⑧ 的互斥情形（需求方 2026-11-14 裁定；对应 Dev 存疑项 3）**:
  若**模型自身**就缺该主题的未决问题（如 `thresholds_status == "not_provided"` 却没带 `topic == "thresholds"` 的条目），
  则 ⑤/⑦ 与 ⑧ **不可能同时满足** —— 凭空造一条会破坏 ⑧ 的「条目数相等 + `id`/`topic` 逐字」。
  ⇒ **唯一自洽解**：实现 **rc=1（输入非法）+ stderr 点名缺哪个主题**，且**不生成任何计划**（不留 `plans/`）。
  ⚠️ **不许**往计划里塞一条自造条目来「凑」⑤/⑦ —— 那是凭空造，违反诚实性原则（F7）。
- **类型**: 诚实性

### AC-022: **零请求**（不得产生任何 HTTP 调用 / 网络痕迹）
- **前置条件**: §0.4.1 的两个桩服务 + §0.5 主跑 + §0.7 全部变体的运行
- **测试步骤**: ① 跑完主跑与全部变体后，读两个桩服务的请求日志；
  ② 扫全部计划产物的任意层级，查「执行痕迹」键名
- **预期结果**:
  ①两个桩的请求计数**都是 0**（日志为空）；
  ②计划产物里**不得**出现执行痕迹键（`executed`/`started_at`/`finished_at`/`timestamp`/`duration_ms`/
     `elapsed`/`latency`/`bytes`/`status_code`/`response`/`responses`/`samples`/`metrics`/`result_rows`）；
  ③跑完之后项目根下**不得**出现 `runs` / `evidence` / `.test-artifacts` 目录或文件（执行器的产物落点）
- **判据形式**: 查绝对事实（**桩服务计数** + 文件系统 + 全产物递归扫描）；探针：让实现在生成计划后顺手
  `fetch(base_url)` 一下 ⇒ ①判红（桩计数 > 0）
- **说明**: 本 REQ **不 spawn 压测工具、不联网、不打桩**（SPEC §1.2 第 1 条）——「不执行」必须有**外部证据**，
  不能靠「源码里没写 spawn」这种可被绕过的自查
- **类型**: 一致性

---

## F 组：写入权与幂等（AC-023 ~ AC-026）

### AC-023: 只写 `test-assets/load/plans/`
- **前置条件**: §0.4 项目根副本
- **测试步骤**: 跑前对项目根下**除** `test-assets/load/plans/` 以外的**一切**（文件集合 + 每个文件内容 sha256）
  取指纹；跑后再取一次；比对
- **预期结果**:
  ①项目根下**除** `test-assets/load/plans/` 外**不得**出现任何**新增**文件或目录；
  ②既有文件的 sha256 **全部未变**（尤其 `test-assets/load/scenarios/`、`test-assets/load/suites/`、
  `test-assets/environments/`、`test-assets/cycles/`、`.gitignore`）；
  ③**不得**改写 REQ-009 的 `test-assets/load/report.json`
- **判据形式**: 查绝对事实（目录指纹）；探针：让实现在生成产物时顺手改写 `environments/local.json` ⇒ 本条判红
- **类型**: 写入权

### AC-024: 不得改输入
- **前置条件**: §0.3 / §0.4 的模型、套件与环境文件
- **测试步骤**: 跑前对**每个**模型文件、**每个**套件文件、**每个**环境文件算 sha256，跑完再算一遍
- **预期结果**: 全部 sha256 **跑前跑后完全一致**（一个都不许变）
- **判据形式**: 查绝对事实；探针：让实现在生成计划时顺手往场景里补一个字段 ⇒ 本条判红
- **类型**: 写入权

### AC-025: 幂等：两份计划必须**逐字相同**
- **前置条件**: §0.3 / §0.4 的项目根**两份副本**
- **测试步骤**: 同一输入跑两次（两个**不同**的项目根），把两份 `test-assets/load/plans/` 目录下的
  **全部文件**逐个比对（相对路径集合 + 内容 sha256）
- **预期结果**:
  ①两份产物的**相对路径集合完全相等**；②每个同名文件的**内容逐字相同**（sha256 相同）；
  ③**不得**出现任何生成时间戳 / 随机 id / 宿主路径之类的非确定性内容
- **判据形式**: 查绝对事实（文件系统指纹）；探针：让实现在计划里写 `generated_at` 或用随机数当 id ⇒ 本条判红
- **类型**: 一致性

### AC-026: 产物已存在 ⇒ 报错退出，**不得覆盖**
- **前置条件**: §0.5 主跑（第一次跑成功后的**同一个**项目根）
- **测试步骤**: 在**同一个**项目根上**再跑一次**（输入不变），检查退出码、stderr 与既有产物
- **预期结果**:
  ①第二次跑**退出码为 1**（**不得**是 0）；②stderr **点名**「产物已存在」；
  ③既有产物（第一次跑的 `plans/` 全部文件）**逐字未变**（**不得**覆盖 / 合并 / 部分更新）
- **判据形式**: 查绝对事实（文件系统指纹 + 真实退出码）；探针：让实现直接覆盖已存在的计划 ⇒ 本条判红
- **类型**: 写入权

---

## G 组：追溯与兼容性（AC-027 ~ AC-029）

### AC-027: 交付侧记账必须与实际一致（**新增**追溯件，不许动 REQ-009 的）
- **前置条件**: 被验包目录 + `feature-meta/`
- **测试步骤**: ① 核 `feature-meta/load-runner/` 的**四件套**（`status.md` / `traceability.md` /
  `verification-report.md` / `manifest.json`）齐全且非空；② 核该子目录 `manifest.json` 的 `req`；
  ③ 核包内**根** `feature-meta/manifest.json` 存在且非空、其 `req` 仍是 `REQ-006`（**不得**被改写）；
  ④ 核 `feature-meta/load-profile/` 的四件套**逐字未变**（sha256 与 §0.8 的基线一致）——
  **不得**被改写、合并或删除；⑤ 核 `feature-meta/load-runner/traceability.md` 的追溯矩阵
  **编号集合** == `acceptance.md` 的实际 `### AC-` 编号集合（**动态取**，不写死）；
  ⑥ 核三份 md（`status.md` / `traceability.md` / `verification-report.md`）的**判据条数取值唯一**
  且等于实际条数、**决策号取值唯一**且恰好等于实际决策号集合
- **预期结果**: 六项全满足；任一不符 → 判红并点名
- **判据形式**: 查绝对事实（追溯件的实际内容 vs 契约的实际内容）
- **⚠️ 口径（决策号核对必须做**两道**）**：
  ①**每一个范围字面量自身**展开后的集合必须 == 实际决策号集合（**逐个字面量各算各的**）；
  ②文件里出现的**决策号并集**必须 == 实际决策号集合；③**不得**出现本 REQ 之外的决策号。
  ⚠️ ①若先把所有字面量并成一个大 set 再比，就退化成 ② ⇒ 等于没加 ①
  （「写 `D156~D182`、同文件别处补一句 `D183`/`D184`」就能逃逸 —— REQ-007 的 F-01 同类漏洞）
- **类型**: 追溯

### AC-028: **既有契约一个都不许被打破**
- **前置条件**: 被验包目录（含 `skills/test-case-design/scripts/verify-layout.mjs`、
  `bin/test-agent-skills.mjs`）+ 本门所在目录的**同级** `REQ-*/verify-acceptance.sh`
- **测试步骤**:
  ① **实跑**上游 `verify-layout.mjs <§0.5 的项目根>`（该根已含 `test-assets/load/{scenarios,suites,plans}`）
  ⇒ 拿**真实输出**与**真实退出码**；
  ② **实跑** REQ-009 的验收门（`../REQ-009-load-profile/verify-acceptance.sh`，快跑模式）跑本被验包；
  ③ **实跑**组合门（`node bin/test-agent-skills.mjs verify --root <临时根>`）；
  ④ **实跑**其余**存在**的同级门（快跑模式），逐个看输出；
  ⑤ 核 `skills/test-execute/executors/index.json` 的 `not_implemented` **仍含 `load`**
  （本 REQ **不实现**执行器 ⇒ `load` 仍必须留在 `not_implemented` 里）
- **预期结果**:
  ①上游校验器对整个项目根 **rc=0** 且输出里 **0 FAIL**（`test-assets/load/plans/` 这个新目录
  **对上游无影响**；若计划文件被取名 `suite.json` ⇒ 上游会把它当套件 ⇒ 必红）；
  ②REQ-009 的门 **rc=0** 且 **0 FAIL**（REQ-009 的门对既有文件只查「存在且非空」⇒ 新增文件不会让它变红）；
  ③组合门 **rc=0**；
  ④其余同级门里，**凡失败输出提到** `load-profile` / `plan-load-run` / `check-load-run` / `load/plans`
  的 ⇒ 判红（那才是本 REQ 造成的回归）；不相关的既有失败**不计入**本条；
  ⑤`not_implemented` 仍含 `load`（**不得**把它实现掉）
- **⚠️ 上游模块缺失 ⇒ 判【不可判定】**（不是实现违约，不可判定 ≠ 通过 ⇒ 退出码仍非 0）：
  被验包里**没有** `skills/test-case-design/scripts/verify-layout.mjs` ⇒ ①判不可判定；
  REQ-009 的门文件**不存在** ⇒ ②判不可判定
- **判据形式**: 查绝对事实（**实跑**上游与同级门，拿真实退出码）；探针：把计划文件改名成 `suite.json` ⇒ ①判红
- **类型**: 兼容性

### AC-029: 交付红线：内部运行时字样 **0**，`feature-meta` **不入 npm 包**
- **前置条件**: 被验包目录
- **测试步骤**:
  ① 扫 `skills/load-profile/**` 与 `feature-meta/**` 的**全部文件内容**，查内部运行时字样
  （`internal-rt` / `agent-runtime-data` / `.local/share/internal-rt` / 内部临时目录路径形态）；
  ② **实跑** `npm pack --dry-run --json`（在本包目录内），取**真实**打包清单，查有没有 `feature-meta/` 开头的条目
- **预期结果**:
  ①**0 处**命中内部运行时字样（**任何一处**命中即判红并点名文件与行号）；
  ②打包清单里**没有**任何 `feature-meta/` 开头的文件
- **判据形式**: 查绝对事实（文件内容扫描 + **真实** `npm pack` 清单）；
  探针：往 `skills/load-profile/SKILL.md` 里写一行含 `internal-rt` 的注释 ⇒ ①判红；
  往 `package.json` 的 `files` 里加 `"feature-meta"` ⇒ ②判红
- **说明**: 交付物里**不得**出现内部运行时字样（那是要被清掉的东西）；`feature-meta/` 是**开发期**追溯件，
  **不进 npm 包**（包内根 `feature-meta/manifest.json` 是 REQ-006 的原样文件）
- **类型**: 兼容性

---

## §0.8 指纹基线表（AC-002 / AC-027 用）

基线取自 REQ-009 交付后的 `develop`（REQ-009 合并提交 `710bcb6`）。
⚠️ **本表是「不许改既有 14 文件」的机械落点** —— 实现方**新增**文件不受本表约束。

### §0.8.1 `skills/load-profile/` 的 14 个文件

| # | 相对路径 | sha256 |
|---|---|---|
| 1 | `SKILL.md` | `d3a1a0f23ada7b1aaedcb156890ace74bf4db1fdc90848280cb30c9850e0a932` |
| 2 | `skill-meta.json` | `61f81e6af56c3047004cf4c155cce557c3140adcf5edd245984d89ea6fb62611` |
| 3 | `references/load-context-schema.md` | `d49dfbfae925c2f06295f656621a32a4a3738df5ac41a2cac97a255072a40d20` |
| 4 | `references/load-scenario-format.md` | `d583ac564f896f419fec466e70c800c1010730a3143b5462912c3ad913dfb3d8` |
| 5 | `references/profile-rules.md` | `dbe90fbc7702157c625eb1a18bb9986b9149408f811b69a4123046ce58f2b30a` |
| 6 | `scripts/make-load-profile.mjs` | `e20ab6d53d27f366375f1aa8e29714ec52ee794978642060fd8613cf45567582` |
| 7 | `scripts/check-load-profile.mjs` | `5cf6224cff1427e5b1dc90373ce80381e989d0822e3dc831b49c17f80ea8586c` |
| 8 | `scripts/lib/catalog.mjs` | `da8e9c7f1591ac8ae92234315f9b8a4bdd65973e7c829194f19d68bb71eefbeb` |
| 9 | `scripts/lib/cli.mjs` | `7c67117b9199bc5415b8de52172570e375683728af9e72e7fac92ace8e9b19ca` |
| 10 | `scripts/lib/context.mjs` | `560bb810864ebb5d1564c455445aa22f1ad8eae59089b5575e8d2a3f33580044` |
| 11 | `scripts/lib/io.mjs` | `0a387e5686fea98d158f58ee5d02273dc6f420296206e7ef97322e4e11f8849c` |
| 12 | `scripts/lib/product.mjs` | `74c332f8872b476ae86517b76857ce3239b65d85aad7c4605aa84be37e33466e` |
| 13 | `scripts/lib/reconcile.mjs` | `91fb5c28a8f6834b832f6bc931f680e595719a731d6ed3943779fa0e3b8f2100` |
| 14 | `scripts/lib/validate.mjs` | `45bb862f1411280acddbaf64046f6cd1517ecc386de63eaa86b8a9110b0ef5ff` |

### §0.8.2 `feature-meta/load-profile/` 的 4 个文件（REQ-009 的追溯件，**不许动**）

| # | 相对路径 | sha256 |
|---|---|---|
| 1 | `manifest.json` | `356f08a49ce65e633161fa651d7fd78d763606b195b8663d4fd212e8d665c4c5` |
| 2 | `status.md` | `c8582cfb52c1f1231207fe85e043aa0ca204102f9c90401a80cecb499bf5b306` |
| 3 | `traceability.md` | `35aad0e338fe9cab17f6ff868fda6d2b3f6e950c184eeda4303924b842eeb8d3` |
| 4 | `verification-report.md` | `c1c6163f3c48616231be47bef434de6a392ec6d47f3605a6291389b1c6e2f043` |

---

## 判据类型分布

| 组 | 条数 | 范围 | 类型分布（**每条只记一个主责类型**） |
|---|---|---|---|
| A 交付物形状 | 4 | AC-001 ~ AC-004 | 功能×2 / 兼容性×1 / 可用性×1 |
| B 输入解析与校验 | 4 | AC-005 ~ AC-008 | 功能×3 / 写入权×1 |
| C 计划形态 | 5 | AC-009 ~ AC-013 | 功能×4 / 诚实性×1 |
| D 参数映射 | 5 | AC-014 ~ AC-018 | 功能×3 / 诚实性×2 |
| E 诚实性与边界 | 4 | AC-019 ~ AC-022 | 诚实性×3 / 一致性×1 |
| F 写入权与幂等 | 4 | AC-023 ~ AC-026 | 写入权×3 / 一致性×1 |
| G 追溯与兼容性 | 3 | AC-027 ~ AC-029 | 追溯×1 / 兼容性×2 |
| **合计** | **29** | AC-001 ~ AC-029 | **功能 12 / 诚实性 6 / 兼容性 3 / 写入权 4 / 一致性 2 / 可用性 1 / 追溯 1** |

> 条数守恒核对：4 + 4 + 5 + 5 + 4 + 4 + 3 = **29**；
> 类型分布合计 12 + 6 + 3 + 4 + 2 + 1 + 1 = **29** ✓
>
> 逐条归属：AC-001 功能 · AC-002 兼容性 · AC-003 可用性 · AC-004 功能 · AC-005 功能 ·
> AC-006 功能 · AC-007 功能 · AC-008 写入权 · AC-009 功能 · AC-010 功能 · AC-011 诚实性 ·
> AC-012 一致性 · AC-013 功能 · AC-014 功能 · AC-015 功能 · AC-016 功能 · AC-017 诚实性 ·
> AC-018 诚实性 · AC-019 诚实性 · AC-020 诚实性 · AC-021 诚实性 · AC-022 一致性 ·
> AC-023 写入权 · AC-024 写入权 · AC-025 一致性 · AC-026 写入权 · AC-027 追溯 ·
> AC-028 兼容性 · AC-029 兼容性

---

## 验收纪律（对本 REQ 的验收方与实现者同样适用）

1. **一次只跑一个门** —— 并发跑门会产生无因果关系的失败键，污染判定。
2. **变异必须结构合法** —— 崩溃/语法错造成的判红是**假检出**，不计入检出率。
3. **变异注入后必须自证生效**（注入前后 sha256 比对 + 可观测状态与基线不同）。
4. **判定「是否被检出」只看目标判据是否出现在新增失败键集合里**
   （新增失败键 = 变异运行的失败键 **减去** 基线失败键），**不能只看「比基线多」**，
   **更不能用对称差**（对称差把「基线红、变异后绿」也算成变化）。
5. **基线失败键只取 `^FAIL` 行** —— `PASS` / `UNDEC` 行里也有 AC 编号，混进来会让基线键集合
   变成**全集**，此后任何变异的「新增失败键」都恒为空或恒等于全集，**整套检测沦为橡皮章**。
6. **不可判定标「不可判定」**，不得判 passed。
7. **任何「脚本全绿」的结论必须钉 sha256**（验收脚本自身 sha + 被验实现指纹）。
8. **不许把不可满足的判据写成判据** —— 例如「`loadtest` 真跑一遍」（本 REQ **不执行** ⇒ 必然不满足）。
9. **不许写「上游会拦」而上游其实不拦** —— 上游对 `plans/` **无影响**、对 `suite.json` 的字段集**封闭**；
   除此之外的计划内容**上游一条都不管** ⇒ **全部由门判**。
10. **不许判上游对整个项目根 rc=0 之外的任何东西**（上游整体 rc 还额外要求
    `environments/_schema.json` / `cycles/` / `.gitignore` —— 本 REQ 的夹具**已预置**这三项，
    所以「整个项目根 rc=0」在本 REQ 是**可满足**的判据，与 REQ-009 不同）。
