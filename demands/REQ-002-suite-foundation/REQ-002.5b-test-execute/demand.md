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

**凭证边界（硬规则）**：环境配置里只有 `*_env` 字段名，**执行器负责在运行时从进程环境变量读取真实值**。真实凭证值不得出现在任何配置文件、任何产物文件、任何日志里。执行器读不到环境变量时，该用例判为 `blocked`（不是 `failed`）—— 环境缺失和用例失败是两回事，混为一谈会让报告失真。

### F3 执行器接口

```
executor = {
  name: string,          // 如 "api"
  version: string,
  run(case, context) -> {
    observed: object,    // 执行器实际观察到什么（状态码 / 响应体 / 响应头 / 提取值…）
    evidence: [{ path, media_type, bytes? }],
    reproduction?: { steps: string[], command?: string, expected?: string },
    error?: { type: string, message: string }
  }
}
```

`context` 提供：`base_url` / `timeout_ms` / `headers` / `resolved_credentials` / `run_id` / `evidence_dir` / `case`。

**执行器返回 `observed`（观察结果），不返回 `status`（判定结果）。** 判定由执行外壳按用例的 `assertions` 做 —— 这是刻意的分层：

```
执行器：跑 → 报告"我看到了什么"（observed）
执行外壳：读 assertions → 比对 observed → 得出 status（passed/failed/blocked/skipped）
```

**接口的三条约束**：

1. **执行器不判定"通过"的语义。** 否则每个执行器各写一套比较逻辑，判定口径必然漂移 —— 而且判定逻辑被写死在代码里（正是 F4 要消灭的东西）。执行器只负责"观察"，判定规则是**数据**（`assertions`），由执行外壳统一执行。
2. **执行器不得自行写 `.test-artifacts/` 以外的文件**。
3. **执行器必须产出可复现信息** —— 失败用例至少要有 `reproduction.steps`（照抄用例的 steps 即可）。做不到复现的失败等于没测。

### F4 执行器不可被 agent 定制 —— 用配置吸收需求，而不是放开源码

**问题（用户亲历的真实故障模式）**：此前交付的一个 skill 用 Python 写 CLI，agent 拿到 skill 后**直接改那个 Python 源文件**来满足自己的需要。结果是工具实现被污染 —— 后续所有使用者拿到的都是被改过的工具，而改动不进版本库、无法追溯、无法回归。

**为什么这是本 REQ 的头号风险**：本 REQ 交付的第一个「agent 可能会想去改」的可执行组件就是执行器。而执行器看起来特别"该改" —— 换一种请求方式、加一种断言、改一个字段名，每个看起来都只有几行。agent 的直觉会是"改脚本比配配置快"。

**约束（三条，缺一不可）**：

1. **执行器实现是 skill 的组成部分，agent 不得修改。** 改写进 `SKILL.md` 的硬约束段（与"状态文件只由脚本写"并列，同一类不可协商项）。
2. **定制需求必须能被配置表达 —— 这是根治，不是禁止。** 如果 agent 想改代码，多半是因为"配置表达不了我要的东西"。所以执行器的**断言规则必须完全可配置**，而不是把判定逻辑写死在代码里：

   | 可配置项 | 含义 |
   |---|---|
   | `request` | 请求构造（方法 / 路径 / body 模板 / 头） |
   | `assertions[]` | 判定规则（状态码 / JSON 路径 / 值 / 正则 / 类型），每条含 `path` / `op` / `expected` / `on_fail` |
   | `extract[]` | 从响应提取值，供后续用例引用 |
   | `auth` | 鉴权方式（引用环境变量，不含明文） |
   | `timeout_ms` / `retries` | 超时与重试 |

   用例的 `expected` 应当落到 `assertions` 里，**而不是散落在执行器代码里**。
3. **执行器注册表 `executors/index.json`** 声明每个执行器**支持哪些可配置项、不支持哪些**，让 agent 明确知道定制边界在哪。遇到注册表未声明的需求，走"提需求"而不是"改代码"。

**为什么第 2 条是关键**：只写"不许改代码"而不给替代路径，agent 只会换个方式硬改（复制一份脚本到项目里、改了不回去）。给出**能用的配置能力**，改代码的动机自然消失。

**顺带收益**：`assertions` 可配置让"通过/失败"的判定口径不再藏在代码里，而是数据 —— 这与 F3「判定由执行外壳统一做」配合，判定规则本身也可被 review、被 diff。

**配套完整性自检**：`scripts/verify-integrity.mjs` 对本 skill 目录内的执行器实现算指纹，与随包发布的 `executors/manifest.json` 比对。agent 改了执行器源码 → 一条命令发现。**这条只覆盖执行器**；把 skill 全部文件的完整性校验推广到整个套件（安装器在锁文件里记 sha256）另立 REQ。

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
node scripts/cycle-state.mjs set-stage <轮次目录> --stage execute --status in_progress --artifacts .test-artifacts/<run_id>
node scripts/cycle-state.mjs set-stage <轮次目录> --stage triage --status in_progress
```

- 每次执行批次把 `run_id` 记进 `cycle.json` 的 `stages.execute.runs[]`
- 执行**不得**直接改 `cycle.json`（REQ-002.5a 的写入权收口）

### F8 产物脱敏

执行产物可能含敏感数据（响应体里的 token、手机号、身份证、数据库连接串）。

- `scripts/redact.mjs` 按规则脱敏：敏感字段名清单 + 值模式正则（配置化，默认规则内置）
- 脱敏在**写入产物前**进行 —— 产物里存的应该已经是脱敏后的
- 脱敏必须留痕：`meta.json` 记 `redaction: { rules_applied: [...], redacted_fields: N }`，让人知道"这里被处理过"，而不是让人以为原文如此
- **脱敏后**的产物才可进制品库

### F9 离线可跑

执行器必须有**不依赖外网**的实现，否则这个 skill 无法被验证：

- `mock` 执行器：内置一个本地 HTTP 服务（node 内置 `node:http`），按用例的 `expected` 决定返回什么，用它验证"证据链机制本身"是否成立
- `api` 执行器：真实 HTTP 调用（node 内置 `fetch`，零第三方依赖）

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
