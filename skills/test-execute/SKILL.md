---
name: test-execute
description: |
  Execute a test suite and produce a verifiable evidence chain: read an execution config (suite.json) plus a case set, dispatch a pluggable executor, judge each case against data-driven assertions, capture evidence with sha256 fingerprints, redact sensitive content before it is written, and advance the cycle state through cycle-state.mjs.
  Use this skill when the user asks to "跑测试用例"、"执行用例"、"执行套件"、"run the test suite"、"出执行报告/证据链", or when a test case set exists but nobody has run it yet.
  It answers "how was this executed, and how do I know the result is real" — not "what should be tested" (that is test-case-design).
  Do NOT use it for designing cases, for writing requirement documents, for UI automation implementation, or for load/security testing executors.
---

# Test Execute

把用例集跑起来，并产出一份**可被追溯、可被复现、可被质疑**的证据链。

没有证据链的测试报告本质上是自我声明："跑了 44 条，通过 41 条" —— 凭什么信？
本 skill 交付的是**执行怎么被做、结果怎么被证明**的规约与工具，不是业务测试场景。

## 硬约束（不可协商）

1. **执行器实现是 skill 的组成部分，agent 不得修改。**
   `executors/` 目录下的全部文件（`api.mjs` / `mock.mjs` / `http-core.mjs` / `index.json` / `mock-endpoints.json`）
   属于 skill 的实现，不是可定制项。**不要改它们，也不要把它们复制到项目里再改** ——
   改动不进版本库、无法追溯，后续所有使用者拿到的都是被改过的工具。
   改一个字节会被 `scripts/verify-integrity.mjs` 发现。

   > 需要新能力时的正确做法：**用配置表达**（见下面的「可配置项」），配置表达不了就**提需求**，
   > 由维护者改实现并重新生成 `executors/manifest.json`。不要自己动手改。

2. **轮次状态文件只由脚本写。**
   `cycle.json` 与 `cycles/index.json` **不得直接编辑**。状态推进一律走 REQ-002.5a 的 `cycle-state.mjs`：
   `run-suite.mjs` 内部也只调用它，自己不写 `cycle.json`。

3. **判定口径唯一。**
   `status` 的判定逻辑只存在于 `scripts/lib/verdict.mjs`。执行器只报告"观察到了什么"（`observed`），
   不得返回 `status`，不得出现通过/失败判定分支。判定规则是**数据**（用例 `steps[].expected` 里的断言对象），
   不是代码 —— 判定规则因此可以被 review、被 diff、被需求方调整。

4. **凭证值不进产物。**
   环境配置里只有 `*_env` 变量名，真实值运行时从进程环境变量读。产物、日志、错误信息里不得出现凭证明文。
   读不到环境变量时该用例判 `blocked`（**不是** `failed`）—— 环境缺失和用例失败是两回事。

## Inputs to collect

- **执行配置 `suite.json`**：`suite` / `requirement` / `scope` / `environment` / `cases_file` / `executor`
  （REQ-002B 的目录契约，本 skill 不新增配置格式）。
- **用例集**：`cases_file` 指向的文件，相对套件目录。用 REQ-002A 的 schema v2 格式。
- **环境定义**：`test-assets/environments/<environment>.json`（`base_url` / `timeout_ms` / `credentials` / `headers`）。
- **可机械判定的断言**：至少一条 `steps[].expected` 是断言对象。
- **轮次目录**（可选）：给了 `--cycle` 才推进轮次状态；不给就只产出产物。

## Procedure

1. **先看一眼要跑什么**（不发请求、不写产物）：
   ```
   node scripts/run-suite.mjs <suite.json> --dry-run
   ```
   原因：先确认"这次要测什么、哪些用例不可机械判定"，比跑完再解释便宜得多。

2. **校验用例集**（可选但推荐）：断言对象形态的用例集用 REQ-002A 的校验器确认：
   ```
   node ../test-case-design/scripts/validate-cases.mjs <cases.json>
   ```

3. **执行**：
   ```
   node scripts/run-suite.mjs <suite.json> [--cycle <轮次目录>] [--json]
   ```
   执行外壳会：读配置 → 启动驱动（mock 驱动会自动起一个本地桩服务并注入 `base_url`）→
   逐条执行 → 用断言判定 → 脱敏 → 落证据 → 算指纹 → 写 `meta.json` / `results.json` → 自校验。

4. **校验证据链**：
   ```
   node scripts/verify-evidence.mjs .test-artifacts/<run_id>
   ```
   退出码 0 表示"这份执行结果没被改过"；1 表示被改动过（哪一条都列出来）。

5. **看结果**：`meta.json` 的五个计数是结论，`results.json` 是逐条明细，
   `evidence/<用例 ID>/` 是原始证据，`reproduction` 是复现方式。

## 可配置项（定制的唯一入口）

执行器的断言规则**完全可配置**，不需要改一行代码。载体与含义：

| 可配置项 | 含义 | 载体 |
|---|---|---|
| `request` | 请求构造：方法 / 路径 / 查询 / 头 / 体 | `case.request`、`case.data.request` 或 `case.steps[].request`；都没有时从步骤描述里回退解析 `GET /path` 形式 |
| `assertions` | 判定规则：状态码 / JSON 路径 / 值 / 正则 / 类型 | 用例 `steps[].expected` 的**断言对象** `{path, op, expected}` |
| `extract` | 从响应取值，供后续用例用 `${name}` 引用 | `case.extract` 或 `case.data.extract` |
| `auth` | 鉴权方式（引用环境变量，不含明文） | `case.auth` 或 `case.data.auth` |
| `timeout_ms` | 单请求超时 | `case.timeout_ms` 或 `case.data.timeout_ms`（缺省取环境配置） |
| `retries` | 失败重试次数 | `case.retries` 或 `case.data.retries`（缺省取环境配置） |

断言对象的判定操作：`equals` / `not_equals` / `contains` / `not_contains` / `matches` /
`exists` / `not_exists` / `type` / `gt` / `gte` / `lt` / `lte`。
被检路径：`$status`（HTTP 状态码）、`$header.X-Trace-Id`（响应头）、`$.a.b[0].c`（响应体）、`$`（整个响应体）。

> **一条用例至少有一条 `steps[].expected` 是断言对象，才算可机械判定。**
> 全部是普通字符串的用例执行时判 `blocked`（理由：缺少可机械判定的断言），
> **不得判 `passed`** —— 执行器"跑完了没报错"不等于"通过"，把不可判定算成通过等于把"没测"记成"测过且通过"。

每个驱动支持哪些、不支持哪些，见 `executors/index.json`。遇到表里没有的需求，走"提需求"。

## Output contract

产物落在 `<项目根>/.test-artifacts/<run_id>/`（不进 Git，项目 `.gitignore` 要有 `.test-artifacts/`）：

```text
.test-artifacts/<run_id>/
├── meta.json          # 本次执行的元信息（谁 / 何时 / 哪个环境 / 计数 / 指纹 / 脱敏留痕）
├── results.json       # 逐条用例的结果（status / 时间 / 证据 / 复现 / 错误）
├── evidence/
│   └── TC-003/
│       └── response.json
└── logs/
    └── runner.log
```

`meta.json` 必填：`run_id` / `suite` / `scope` / `requirement` / `environment`（**环境名，不是 base_url**）/
`started_at` / `finished_at` / `duration_ms` / `agent` / `executor` / `tool_versions` /
`cases_total` / `cases_passed` / `cases_failed` / `cases_blocked` / `cases_skipped` /
`evidence_manifest_sha256` / `results_sha256` / `redaction`。

`results.json` 每条必填：`case_id` / `title` / `requirement_refs` / `status` /
`started_at` / `finished_at` / `duration_ms` / `evidence[]` / `reproduction` / `error`。

字段语义、指纹算法、脱敏留痕的完整契约见 `references/evidence-chain.md`；
执行器接口、断言操作、mock 端点集见 `references/executor-spec.md`。

## 退出码语义

| 码 | 含义 |
|---|---|
| 0 | 执行与证据链自校验通过 |
| 1 | 校验失败或执行失败（配置非法、驱动起不来、执行器异常、证据链自校验不通过） |
| 2 | 调用方式错误（缺参数、参数拼错、路径不存在） |

**退出码说的是执行流程本身成不成功，不等于"用例有没有通过"。**
用例的通过/失败/阻塞看 `results.json` 的 `status` 与 `meta.json` 的计数。
需要"有失败用例就让流水线红"的场景，加 `--strict`。

`--json` 模式下 stdout **只有 JSON**（成功 / 校验失败 / 用法错误三种情形都是），可以直接 `JSON.parse`。

## Failure handling

- **用例判 `blocked`**：先看 `error.type`。`credential_missing` = 环境变量没设（环境缺失，不是用例失败）；
  `no_mechanical_assertion` = 该用例的 `steps[].expected` 全是字符串，补断言对象；
  `environment_missing` / `request_spec_missing` = 配置缺项。
- **用例判 `failed`**：看 `error.message` 里的断言明细与 `evidence/` 下的原始响应；
  `reproduction.command` 是可复制的复现命令（凭证以环境变量名出现，不含明文）。
- **驱动起不来 / 未注册**：看 `executors/index.json`。`ui` / `load` / `security` 属后续 REQ，本 skill 只交付 `api` 与 `mock`。
- **证据链校验失败**：`verify-evidence.mjs` 会点名是"文件被改动"、"文件丢失"、"results.json 被改写"还是"计数造假"。
  **不要手改产物去凑**——重跑一次执行，拿到新的 `run_id`。
- **需求有歧义**：不要自己把断言改宽松来"让它过"。把歧义写进用例集的未决问题清单，请需求方裁定。

## Examples

离线跑通一条完整链路（不依赖任何外部服务）：

```console
# 1) 看要跑什么
node scripts/run-suite.mjs examples/offline/test-assets/suites/REQ-DEMO-demo/suite.json \
  --project-root examples/offline --dry-run

# 2) 执行（mock 驱动自动起本地桩服务）
node scripts/run-suite.mjs examples/offline/test-assets/suites/REQ-DEMO-demo/suite.json \
  --project-root examples/offline

# 3) 校验证据链
node scripts/verify-evidence.mjs examples/offline/.test-artifacts/<run_id>
```

改断言即改判定（判定不在代码里）：

```jsonc
// 之前：GET /notfound 期望 404 → passed
{ "path": "$status", "op": "equals", "expected": 404 }
// 之后：同一端点改成期望 200 → failed（同一份执行器源码，一个字没改）
{ "path": "$status", "op": "equals", "expected": 200 }
```

## Windows (win32) platform notes

- 全部脚本都是纯 Node.js，直接用 `node scripts/...` 调用，PowerShell 与 cmd 下行为一致。
- 路径交给 Node 解析（脚本内部走 `path.resolve`），不要写死盘符或类 Unix 绝对路径。
- 产物目录默认落在项目根的 `.test-artifacts/`，临时文件也在产物目录内，不要假定系统存在类 Unix 临时目录。
