# 需求：测试套件基座 — 执行 skill 与证据链

- **需求编号**: REQ-002.5b
- **所属 Epic**: REQ-002 suite-foundation（对应设计文档中 `002.5` 的执行部分）
- **优先级**: P0
- **状态**: 草稿
- **前置**: REQ-002.5a（轮次状态推进器 —— 执行必须把轮次状态写对，证据链才可信）

## 需求描述

### 背景

REQ-002A 产出用例集，REQ-002.5a 产出状态推进器。中间那一环空着：**没有人去执行这些用例，也没有人对"执行结果"负责**。

"执行"这个动作本身不难，难的是**执行结果的可信度**。一个测试套件如果只能说"跑了 44 条，通过 41 条"，那它对需求方没有任何证明力 —— 凭什么信？跑的环境对不对？失败的用例怎么复现？证据会不会被改过？

替代独立测试人员的核心价值不只是"多跑几个用例"，而是**交付一份可被追溯、可被复现、可被质疑的证据**。没有证据链的测试报告，本质上是一份自我声明。

REQ-001 的实测也给了反面警示：模型会**自信地走人读路径**。REQ-002A 发现未决问题只写进了给人看的 `report.md`，机器可读的 JSON 里是 0 条。同样的风险在执行环节更大 —— 模型可能把"跑过"写成"通过"、把"跳过了"写成"通过"、把旧截图当成新证据。**这些必须靠结构化的证据格式 + 可机械校验的指纹挡掉，不能靠自觉。**

### 目标

交付一个 `test-execute` skill：读取执行配置 → 调度可插拔执行器 → 采集证据 → 产出**带证据链**的执行结果 → 推进轮次状态。

**这不是做测试，是做"执行怎么被做、结果怎么被证明"的规约。**

### 范围边界

**在范围内**：

- `test-execute` skill（`skills/test-execute/`）
- 执行器接口定义 + 一个参考实现（HTTP API）+ 一个离线 mock 实现
- 证据链结构：`meta.json` / `results.json` / `evidence/` / 复现信息 / sha256 指纹
- 证据完整性校验脚本 `scripts/verify-evidence.mjs`
- 产物脱敏脚本 `scripts/redact.mjs`
- 与 `cycle-state.mjs` 的集成（执行批次写进轮次状态）

**不在范围内**：

- UI 自动化执行器（属后续；本 REQ 只定义接口，UI 属于实现方）
- 安全扫描、压测执行器（属 REQ-002.8 / REQ-002.9）
- 测试报告生成与聚合（属 REQ-002.10；本 REQ 只产出结构化结果）
- R2 回归的用例选择（属 REQ-002.6）
- `.tools/` 工具链自举（属 REQ-002.4；但本 REQ 不得因此假设 `.tools/` 已存在）
- 真实业务系统的对接（本 REQ 的执行对象是自带的 mock 服务）

## 功能要求

### F1 skill 边界

| 维度 | test-execute | 不属于它 |
|---|---|---|
| 输入 | `suite.json`（执行配置）+ 用例集 + 环境定义 | 需求原文 |
| 产出 | `.test-artifacts/<run_id>/` 下的证据链 | 用例集、报告 |
| 写状态 | 经 `cycle-state.mjs` 写轮次状态 | 直接编辑 `cycle.json` |
| 判定 | 「这条用例在这次执行里是什么结果」 | 「这条用例该��不该存在」 |

**执行器不得直接编辑 `cycle.json`** —— 与 REQ-002.5a 的写入权收口一致，状态只能由 `cycle-state.mjs` 写。

### F2 执行配置来源

沿用 REQ-002B 已定义的契约，本 REQ 不新增配置格式：

```json
{
  "suite": "REQ-001-coupon",
  "requirement": "REQ-001",
  "scope": "functional",
  "environment": "local",
  "cases_file": "cases.json",
  "executor": "api"
}
```

- `environment` → `test-assets/environments/<name>.json`
- `cases_file` → 相对套件目录的用例集（REQ-002A 的 v2 格式）
- `executor` 枚举 `api` / `ui` / `load` / `security`

**mock 执行器的启用方式（2026-11-11 补充）**：REQ-002.5a 的验收发现 `executor` 枚举不含 `mock`，而离线可跑（见 F9）要求有它。两种改法：

| 改法 | 做法 | 代价 |
|---|---|---|
| A | `executor` 枚举扩为 `api` / `ui` / `load` / `security` / `mock` | 要同步改 REQ-002B 的契约（`references/project-layout.md` §3.3 的枚举表 + `verify-layout.mjs` 的枚举基线） |
| B | `suite.json` 的 `executor` 保持 REQ-002B 契约的四个值不变，mock 的启用由**环境配置**决定（如 `environments/mock.json` 声明 `"driver": "mock"`） | 要同步改 REQ-002B 的 `environments` 封闭字段集（`_schema.json` 模板 + 文档 + 校验器顶层基线） |
| C | `suite.json` 完全不改，由命令行覆盖（`run-suite.mjs <suite.json> --executor mock`） | 零契约改动；但 mock 只存在于 CLI 入口，将来别的 skill 想复用就没有配置级的表达 |

**倾向 B**：mock 是"环境"的固有属性（一个环境 = 一套驱动 + 一个地址），不是套件的属性。方案 C 虽然零改动，但把 mock 降级成命令行玩具 —— 而"离线可跑"是要长期存在的核心能力（每个新执行器都要能脱离真实系统被验证）。

> 无论选哪个，**`suite.json` 的既有字段语义都不得改变** —— REQ-002B 已验收，动了就是回归。

**凭证边界（硬规则）**：环境配置里只有 `*_env` 字段名，**执行器负责在运行时从进程环境变量读取真实值**。真实凭证值不得出现在任何配置文件、任何产物文件、任何日志里。执行器读不到环境变量时，该用例判为 `blocked`（不是 `failed`）—— 环境缺失和用例失败是两回事，混为一谈会让报告失真。

### F3 执行器接口

```
executor = {
  name: string,          // 如 "api"
  version: string,
  run(case, context) -> {
    observed: object,    // 执行器实际观察到什么（状态码 / 响应体 / 响应头 / 提取值…）
    steps: [             // 多步用例：每个可执行 step 的观察结果（D12）
      { step_index: number, observed: object, evidence: [{ path, media_type, content }] }
    ],
    evidence: [{ path, media_type, content }],
    reproduction?: { steps: string[], command?: string, expected?: string },
    error?: { type: string, message: string }
  }
}
```

`context` 提供：`base_url` / `timeout_ms` / `headers` / `resolved_credentials` / `run_id` / `evidence_dir` / `case`。

> **证据条目带 `content` 而不是 `bytes`**（D17）：F8 要求"脱敏在**写入前**完成"。
> 若执行器自己落盘，就来不及先脱敏。所以**执行器不落盘**，把内容本体交回执行外壳，
> 由外壳按"脱敏 → 写盘 → 算指纹"的顺序处理。`bytes` 由外壳写盘时填。

**执行器返回 `observed`（观察结果），不返回 `status`（判定结果）。** 判定由执行外壳按用例的 `assertions` 做 —— 这是刻意的分层：

```
执行器：跑 → 报告"我看到了什么"（observed）
执行外壳：读 assertions → 比对 observed → 得出 status（passed/failed/blocked/skipped）
```

**接口的四条约束**：

1. **执行器不判定"通过"的语义。** 否则每个执行器各写一套比较逻辑，判定口径必然漂移 —— 而且判定逻辑被写死在代码里（正是 F4 要消灭的东西）。执行器只负责"观察"，判定规则是**数据**（`assertions`），由执行外壳统一执行。
2. **执行器不得自行写 `.test-artifacts/` 以外的文件**。
3. **执行器必须产出可复现信息** —— 失败用例至少要有 `reproduction.steps`（照抄用例的 steps 即可）。做不到复现的失败等于没测。
4. **多步用例逐步执行、逐步判定**（D12/D13/D14）——
   - 一个用例的**每个可执行 step**（有 `step.request`，或 `action` 能解析成 `METHOD /path`）都要发一次请求；
   - **每条断言绑定到它所属 step 的响应**（`steps[].expected` 属于它自己那一行）；
   - 所在 step 不可执行时，该用例判 `blocked`（`assertion_without_response`），**不得判 `passed`**；
   - 步骤之间不做隐式数据串联（`${name}` 仍只跨用例）。

   > **为什么这条是硬约束**：验收实证过原实现只跑第一个 step、却把后续 step 的断言
   > 拿第一个响应当判据 —— 结果"首步成立次步不成立"的用例报 `passed`（半个用例报通过），
   > "两步都成立"的用例反而报 `failed`。这正是本套件要消灭的那类虚报，
   > 出现在最核心的执行环节，后果是整个证据链失去可信度。

### F4 执行器不可被 agent 定制 —— 用配置吸收需求，而不是放开源码

**问题（用户亲历的真实故障模式）**：此前交付的一个 skill 用 Python 写 CLI，agent 拿到 skill 后**直接改那个 Python 源文件**来满足自己的需要。结果是工具实现被污染 —— 后续所有使用者拿到的都是被改过的工具，而改动不进版本库、无法追溯、无法回归。

**为什么这是本 REQ 的头号风险**：本 REQ 交付的第一个「agent 可能会想去改」的可执行组件就是执行器。而执行器看起来特别"该改" —— 换一种请求方式、加一种断言、改一个字段名，每个看起来都只有几行。agent 的直觉会是"改脚本比配配置快"。

**约束（三条，缺一不可）**：

1. **执行器实现是 skill 的组成部分，agent 不得修改。** 改写进 `SKILL.md` 的硬约束段（与"状态文件只由脚本写"并列，同一类不可协商项）。
2. **定制需求必须能被配置表达 —— 这是根治，不是禁止。** 如果 agent 想改代码，多半是因为"配置表达不了我要的东西"。所以执行器的**断言规则必须完全可配置**，而不是把判定逻辑写死在代码里：

   | 可配置项 | 含义 |
   |---|---|
   | `request` | 请求构造（方法 / 路径 / body 模板 / 头） |
   | `assertions[]` | 判定规则（状态码 / JSON 路径 / 值 / 正则 / 类型） |
   | `extract[]` | 从响应提取值，供后续用例引用 |
   | `auth` | 鉴权方式（引用环境变量，不含明文） |
   | `timeout_ms` / `retries` | 超时与重试 |

   **断言的载体 —— `steps[].expected` 的类型扩展**（见下方「断言载体决策」）：机械断言是**数据**，写在用例集里，由执行外壳统一执行。

   用例的 `expected` 应当落到可机械判定的断言上，**而不是散落在执行器代码里**。
3. **执行器注册表 `executors/index.json`** 声明每个执行器**支持哪些可配置项、不支持哪些**，让 agent 明确知道定制边界在哪。遇到注册表未声明的需求，走"提需求"而不是"改代码"。

**为什么第 2 条是关键**：只写"不许改代码"而不给替代路径，agent 只会换个方式硬改（复制一份脚本到项目里、改了不回去）。给出**能用的配置能力**，改代码的动机自然消失。

**顺带收益**：`assertions` 可配置让"通过/失败"的判定口径不再藏在代码里，而是数据 —— 这与 F3「判定由执行外壳统一做」配合，判定规则本身也可被 review、被 diff。

**配套完整性自检**：`scripts/verify-integrity.mjs` 对本 skill 目录内的执行器实现算指纹，与随包发布的 `executors/manifest.json` 比对。agent 改了执行器源码 → 一条命令发现。**这条只覆盖执行器**；把 skill 全部文件的完整性校验推广到整个套件（安装器在锁文件里记 sha256）另立 REQ。

#### 断言载体决策：`steps[].expected` 的类型扩展（向后兼容）

**问题**：REQ-002A 的 `steps[].expected` 是**非空字符串**（人读的"可判定结果"，如"页面跳转到工作台并显示 alice"）。执行器无法机械判定一个自然语言字符串 —— 那"判定"就只剩执行器自己说了算，正是 D2 要消灭的东西。

**三个候选**：

| 方案 | 做法 | 否决理由 |
|---|---|---|
| 用例集加 `assertions[]` 字段（schema v3） | 新增用例级字段 | 引入新字段即需升版，REQ-002A 刚定下的兼容策略要再走一遍；且 `expected`（人读）与 `assertions`（机械）并存易互相矛盾 |
| 断言独立成 `assertions.json` | 与用例集平行的文件，按 `case_id` 关联 | 两份文件要维护对应关系，agent 极易只改一份 → 判定与用例脱节 |
| **执行时由 agent 从 `expected` 推导断言** | 断言作为执行产物落进证据链 | 判定口径在**执行时**才定，需求方 review 的是结果而非判定依据；agent 推导偏宽松时无人可查 —— 与"替代独立测试人员"的目标相反 |

**决定：扩展 `steps[].expected` 的类型** —— 它可以是字符串（人读），也可以是**结构化断言对象**（机械）。这是同一字段的自然延伸，不引入任何新字段。

```json
{ "action": "提交订单", "expected": { "path": "$.status", "op": "equals", "expected": "ok" } }
{ "action": "查询订单", "expected": "订单状态为已支付" }
```

**断言对象的结构**：

| 字段 | 必填 | 语义 |
|---|---|---|
| `path` | 是 | 被检路径。`$` 开头表示 JSONPath 风格的响应体路径（如 `$.data.orderId`）；`$status` 表示 HTTP 状态码；`$header.X-Trace-Id` 表示响应头 |
| `op` | 是 | 判定操作。枚举：`equals` / `not_equals` / `contains` / `not_contains` / `matches`（正则）/ `exists` / `not_exists` / `type` / `gt` / `gte` / `lt` / `lte` |
| `expected` | 否 | 比较值。`op` 为 `exists` / `not_exists` 时不需要；`op` 为 `matches` 时为正则字符串；`op` 为 `type` 时为类型名（`string` / `number` / `boolean` / `object` / `array` / `null`） |

**判定规则**：

- 一条用例**至少有一条 step 的 `expected` 是断言对象** → 该用例**可机械判定**
- 一条用例的所有 step 的 `expected` 都是字符串 → 该用例**不可机械判定**，执行时判 `blocked`（理由："缺少可机械判定的断言"），**不得判 passed**

> **为什么"不可判定"必须判 blocked 而不是 passed**：这正是 REQ-001 暴露的失败模式 —— 模型说"覆盖完整"实际漏了一半。同理，执行器"跑完了没报错"不等于"通过"。把不可判定的用例算作通过，等于把"没测"记成"测过且通过"。**宁可漏报通过，不可虚报通过。**

**对 REQ-002A 的向后兼容扩展**（必须一并交付）：

- `scripts/validate-cases.mjs` 的 `steps[].expected` 校验从"必须是非空字符串"放宽为"非空字符串 **或** 合法的断言对象"
- 断言对象出现时，其 `path` / `op` / `expected` 的合法性必须校验（`op` 必须在枚举内）
- **旧文件行为完全不变** —— 纯字符串 `expected` 的用例集仍按原规则校验通过
- `references/case-schema.md` 补 `expected` 的两种形态与语义

**归属说明**：这是对 REQ-002A 交付物的**向后兼容扩展**（不引入新字段、不升版本号、旧行为不变），在本 REQ 一并交付，避免另立 REQ 的协调成本。

### F5 证据链结构

```
.test-artifacts/<run_id>/
├── meta.json            # 本次执行的元信息
├── results.json         # 逐条用例的结果
├── evidence/
│   └── TC-003/
│       ├── response.json
│       └── screenshot.png
└── logs/
    └── runner.log
```

**`meta.json` 必填字段**：

| 字段 | 语义 |
|---|---|
| `run_id` | 本次执行的唯一标识，同时是目录名 |
| `suite` / `scope` / `requirement` | 来自 `suite.json` |
| `environment` | 环境名（**不是** base_url，避免把内网地址散到产物里） |
| `started_at` / `finished_at` / `duration_ms` | 时间 |
| `agent` | 谁执行的 |
| `executor` | `{ name, version }` |
| `tool_versions` | 执行过程中用到的工具与版本（空对象也要写） |
| `cases_total` / `cases_passed` / `cases_failed` / `cases_blocked` / `cases_skipped` | 计数 |

**`results.json` 每条用例必填**：

| 字段 | 语义 |
|---|---|
| `case_id` / `title` / `requirement_refs` | 用例标识与追溯 |
| `status` | `passed` / `failed` / `blocked` / `skipped` |
| `started_at` / `finished_at` / `duration_ms` | 时间 |
| `evidence[]` | `{ path, sha256, bytes, media_type }` |
| `reproduction` | 复现信息（失败/阻塞时必填） |
| `error` | `{ type, message }`（失败时必填） |

### F6 sha256 指纹与防篡改

- 每个证据文件算 sha256，写进 `results.json` 的 `evidence[]`
- `meta.json` 里再记一个 `evidence_manifest_sha256` = 对 `results.json` 中全部 evidence 条目（路径 + sha256）再算一次的总指纹
- `scripts/verify-evidence.mjs` 重算所有指纹并与记录比对，报告：
  - 指纹不匹配 → 证据文件被改动
  - 文件缺失 → 证据丢失
  - 清单指纹不匹配 → `results.json` 被改动
  - `cases_total` 与 `results.json` 条数不符 → 计数造假

**为什么需要**：产物落 `.test-artifacts/`（本地、不进 Git），会被复制进制品库、贴进缺陷单、附到报告里。一旦某条证据被替换或某条结果被改写，没有指纹就永远查不出来。有了指纹，"这份报告可信吗"变成一条命令的事。

### F7 与轮次状态集成

执行必须经 `cycle-state.mjs` 推进状态：

```bash
node scripts/cycle-state.mjs set-stage <轮次目录> --stage execute --status in_progress
node scripts/cycle-state.mjs set-stage <轮次目录> --stage execute --status in_progress --run <run_id>
node scripts/cycle-state.mjs set-stage <轮次目录> --stage triage --status in_progress
```

- 每次执行批次把 `run_id` 记进 `cycle.json` 的 `stages.execute.runs[]`
- 执行**不得**直接改 `cycle.json`（REQ-002.5a 的写入权收口）

> **`set-stage` 需要新增 `--run <run_id>` 参数**（D15）。
> `runs[]` 是"这个轮次跑了哪几次执行"的追溯信息，必须是数组、必须可查 ——
> 塞进 `artifacts` 里既不是数组也不可查，等于没有追溯。
> 由于"状态写入权只归脚本"是 REQ-002.5a 的核心，这个参数在 **`cycle-state.mjs` 里加**，
> 而不是让执行外壳直接改 `cycle.json`（那样收口就破功了）。
> `cycle.json` 的字段表（`references/project-layout.md`）同步补 `stages.execute.runs[]`。

### F8 产物脱敏

执行产物可能含敏感数据（响应体里的 token、手机号、身份证、数据库连接串）。

- `scripts/redact.mjs` 按规则脱敏：敏感字段名清单 + 值模式正则（配置化，默认规则内置）
- 脱敏在**写入产物前**进行 —— 产物里存的应该已经是脱敏后的
- 脱敏必须留痕：`meta.json` 记 `redaction: { rules_applied: [...], redacted_fields: N }`，让人知道"这里被处理过"，而不是让人以为原文如此
- **脱敏后**的产物才可进制品库

### F9 离线可跑

执行器必须有**不依赖外网**的实现，否则这个 skill 无法被验证：

- `mock` 执行器：内置一个本地 HTTP 服务（node 内置 `node:http`），由执行外壳自动启停，`base_url` 自动注入为 `http://127.0.0.1:<随机端口>`。调用方**不需要**配置地址 —— 否则"离线可跑"就变成了"还要自己先起服务"，谈不上拿过来就能跑。
- `api` 执行器：真实 HTTP 调用（node 内置 `fetch`，零第三方依赖）

**mock 服务的端点集固定**（验收要能确定性构造场景，所以这一组必须固定）：

| 端点 | 响应 |
|---|---|
| `GET /ok` | 200 `{"status":"ok"}` |
| `GET /created` | 201 `{"status":"created"}` |
| `GET /notfound` | 404 `{"status":"not_found"}` |
| `GET /error` | 500 `{"status":"error"}` |
| `GET /echo` | 200 回显 `{method, path, query, body}`（**不回显敏感请求头**） |
| `GET /token` | 200 `{"token":"secret-value","id":1}`（专用于测脱敏） |
| `GET /slow?ms=N` | 延迟 N 毫秒后返回 200（用于测超时） |

未列出的路径 → 404 `{"status":"not_found"}`。

mock 的 `base_url` 要记进 `meta.json`（读者才知道这次打的是本地 mock 还是真实环境），但 `environment` 字段仍写环境名。

**为什么必须有 mock**：证据链的验证不依赖被测系统。没有 mock 就没有"不接任何真实系统也能证明这套机制成立"的能力，也就没有回归测试。

## 非功能要求

- **零依赖**：只用 `node:` 内置模块（`fetch` / `node:http` / `node:crypto`），`package.json` 的 `dependencies` 保持为空
- **可移植**：不含 bash / python3 / grep / sed，不写死 `/tmp`
- **退出码语义统一**：`0` 成功 / `1` 校验失败或执行失败 / `2` 调用方式错误（与既有三个脚本一致）
- **不泄露凭证**：任何产物、日志、错误信息中不得出现环境变量的真实值（可机械验证）
- **幂等**：同一 `run_id` 重复执行不产生相互污染的产物
- **agent 友好**：`--json` 输出机器可读 JSON

## 验收要点

见 `acceptance.md`（待写，预计 16 条）。

## 依赖说明

- **前置**：REQ-002.5a（状态推进器 —— 本 REQ 依赖 `cycle-state.mjs` 的 `set-stage` 与 `stages.execute.runs[]`）
- **后续**：REQ-002.6（R2 回归）、REQ-002.7（R3 缺陷验证）、REQ-002.8（安全）、REQ-002.9（压测）、REQ-002.10（报告）
- **并行**：可与 REQ-002.8（安全）、REQ-002.9（压测）并行 —— 各自新建 skill 目录，文件所有权不重叠。**不可与 REQ-002.2 并行**（都可能改 `SKILL.md`；但本 REQ 改的是 `skills/test-execute/SKILL.md`，是独立文件，实际不冲突）
