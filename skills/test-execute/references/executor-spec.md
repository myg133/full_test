# 执行器接口契约（executor-spec）

本文件是**契约**，不是说明材料。读者是要在本项目里执行用例的人（或要扩展执行器能力的维护者）：
你按这里的规则写用例配置，`executors/` 下的实现按这里的规则跑。

配套文件：

- `executors/index.json` —— **执行器注册表**：每个驱动支持哪些可配置项、不支持哪些（定制边界的唯一声明处）
- `executors/api.mjs` —— 真实 HTTP 驱动
- `executors/mock.mjs` —— 离线 mock 驱动（内置 HTTP 桩服务）
- `executors/mock-endpoints.json` —— mock 端点集（数据，不是代码）
- `scripts/lib/verdict.mjs` —— 判定逻辑的**单一来源**
- `references/evidence-chain.md` —— 产物与指纹契约

---

## 0. 分层：观察与判定分开

```text
执行器：跑 → 报告"我看到了什么"（observed）
执行外壳：读断言 → 比对 observed → 得出 status（passed / failed / blocked / skipped）
```

**执行器不判定"通过"的语义。** 否则每个执行器各写一套比较逻辑，判定口径必然漂移；
而且判定逻辑被写死在代码里，正是需求 F4 要消灭的东西 —— 那样需求方就永远无法调整"什么算通过"。

判定规则是**数据**：写在用例 `steps[].expected` 里的断言对象。判定因此可以被 review、被 diff、被需求方改。

---

## 1. 执行器接口

```text
executor = {
  name: string,          // 如 "api" / "mock"
  version: string,
  start?(context) -> { base_url? }   // 可选：启动钩子（mock 驱动在这里起桩服务）
  run(case, context) -> {
    observed: object,    // 执行器实际观察到什么（状态码 / 响应体 / 响应头 / 时长…）
    evidence: [{ path, media_type, content }],
    reproduction?: { steps: string[], command?: string, expected?: string },
    error?: { type: string, message: string }
  },
  stop?(context) -> void             // 可选：结束钩子
}
```

### `context`

| 字段 | 含义 |
|---|---|
| `run_id` | 本次执行标识 |
| `base_url` | 目标根地址（mock 驱动时是内置桩服务地址） |
| `timeout_ms` | 单请求超时（用例级 > 环境级 > 默认 30000） |
| `retries` | 失败重试次数（只对网络错误与超时重试） |
| `headers` | 环境配置里的附加请求头 |
| `resolved_credentials` | 已解析的凭证值表（键是环境变量名） |
| `variables` | 前面用例 `extract` 出来的值，供 `${名称}` 引用 |
| `evidence_dir` | 该用例的证据目录 |
| `case` | 用例对象 |
| `request` | 该用例解析出的请求配置（见 §3） |
| `auth` | 该用例的鉴权配置（见 §5） |

### 返回值

- `observed`：**只报告观察结果**，不含任何判定。状态码放 `observed.status_code`，响应头放 `observed.headers`（键名小写），
  响应体放 `observed.body`（能解析成 JSON 就是对象，否则是文本）。
- `evidence[]`：证据条目。`path` 是相对该用例证据目录的文件名（如 `response.json`），
  `content` 是**内容本体**（字符串或 JSON 对象）。
  **执行器不落盘** —— 落盘由执行外壳做，因为脱敏必须发生在写入之前（见 `references/evidence-chain.md` §5）。
- `reproduction`：复现信息。失败与阻塞的用例必须有 `steps`（照抄用例步骤即可）；
  能给出复现命令的驱动还应给 `command`（凭证以**环境变量名**出现，不含明文）。
- `error`：出错时的错误描述 `{type, message}`。`type` 决定判定结果（见 §6）。

---

## 2. 断言载体：`steps[].expected` 的两种形态

同一字段，两种形态（REQ-002.5b 决定，REQ-002A 向后兼容扩展）：

```jsonc
{ "action": "提交订单", "expected": { "path": "$.status", "op": "equals", "expected": "ok" } }  // 机械可判定
{ "action": "查询订单", "expected": "订单状态为已支付" }                                        // 人读，不可机械判定
```

| 字段 | 必填 | 语义 |
|---|---|---|
| `path` | 是 | 被检路径（见下表） |
| `op` | 是 | 判定操作（见 §4） |
| `expected` | 条件 | 比较值；`op` 为 `exists` / `not_exists` 时不需要；`matches` 时是正则串；`type` 时是类型名 |

| `path` 形态 | 指向 |
|---|---|
| `$status` | HTTP 状态码 |
| `$header.X-Trace-Id` | 响应头（键名大小写不敏感） |
| `$.data.orderId` | 响应体字段（JSONPath 风格，`$.items[0].id` 也支持） |
| `$` | 整个响应体 |

**一条用例至少有一条 `steps[].expected` 是断言对象，才算可机械判定。**
全是字符串的用例执行时判 `blocked`（`error.type = no_mechanical_assertion`），**不得判 `passed`**。

---

## 3. 请求配置（`request`）

| 字段 | 含义 |
|---|---|
| `method` | HTTP 方法，缺省 `GET` |
| `path` | 路径，可带 `?query`；可含 `${变量}` 占位符 |
| `query` | 查询参数对象 |
| `headers` | 请求头对象 |
| `body` | 请求体（对象会被序列化成 JSON） |

**载体优先级**：`case.request` → `case.data.request` → `case.steps[].request`。
都没有时，从步骤描述里回退解析 `METHOD /path` 形式（例如 `action` 写成 `"GET /ok"` 就能直接驱动执行）。
显式配置优先于回退解析。

`${变量}` 占位符来自前序用例的 `extract`：

```jsonc
{ "extract": [{ "name": "orderId", "path": "$.data.orderId" }] }        // 前一条用例
{ "request": { "method": "GET", "path": "/orders/${orderId}" } }       // 后一条用例
```

---

## 4. 判定操作（`op`）

| `op` | 成立条件 |
|---|---|
| `equals` | 实际值与期望值相等（数值按数值比，其余严格比） |
| `not_equals` | 不相等 |
| `contains` | 字符串 → 子串；数组 → 含该元素；对象 → 含该键或序列化后包含 |
| `not_contains` | 上者的否定 |
| `matches` | 实际值匹配期望值给定的正则 |
| `exists` | 路径存在（取值不为 `undefined`） |
| `not_exists` | 路径不存在 |
| `type` | 实际值的类型名是期望值（`string` / `number` / `boolean` / `object` / `array` / `null`） |
| `gt` / `gte` / `lt` / `lte` | 两侧都是数值时按数值比较 |

---

## 5. 鉴权（`auth`）

| 形态 | 含义 |
|---|---|
| `{"type": "none"}` | 不鉴权 |
| `{"type": "bearer", "env": "TOKEN_ENV"}` | `Authorization: Bearer <值>` |
| `{"type": "basic", "username_env": "U", "password_env": "P"}` | `Authorization: Basic <base64>` |
| `{"type": "header", "header": "X-Api-Key", "env": "KEY_ENV"}` | 自定义头 |

**只引用环境变量名，不含明文。** 真实值在运行时从进程环境变量读。
读不到时该用例判 `blocked`（`error.type = credential_missing`），**不是 `failed`** ——
环境缺失和用例失败是两回事，混为一谈会让报告失真。

证据与复现命令里出现的是**环境变量名**（如 `${TOKEN_ENV}`），不是真实值。

---

## 6. `error.type` 与判定的对应

| `error.type` | 判定 | 含义 |
|---|---|---|
| `credential_missing` | `blocked` | 环境变量没设 |
| `environment_missing` | `blocked` | 环境缺失 |
| `request_spec_missing` | `blocked` | 用例没有声明请求，不知道该打哪 |
| `no_mechanical_assertion` | `blocked` | 该用例没有可机械判定的断言 |
| `timeout` | `failed` | 请求超时 |
| `network_error` | `failed` | 网络错误 |
| `assertion_failed` | `failed` | 有断言不成立 |
| `executor_error` | `failed` | 执行器异常 |

---

## 7. 驱动清单

### `api` —— 真实 HTTP 驱动

- 打环境配置里的 `base_url`。
- 零第三方依赖（`node` 内置 `fetch`）。
- 可配置：`request` / `assertions` / `extract` / `auth` / `timeout_ms` / `retries`。
- 不支持：浏览器自动化、截图、多部分表单上传、压测并发、安全扫描。

### `mock` —— 离线 mock 驱动

- **内置 HTTP 桩服务**（`node:http`），执行外壳在选中它时自动启动，
  `base_url` 注入为 `http://127.0.0.1:<随机端口>`，用完关闭。
  **调用方不需要在环境配置里写地址。**
- 端点集固定（定义在 `executors/mock-endpoints.json`）：

| 端点 | 响应 |
|---|---|
| `GET /ok` | 200 `{"status":"ok"}` |
| `GET /created` | 201 `{"status":"created"}` |
| `GET /notfound` | 404 `{"status":"not_found"}` |
| `GET /error` | 500 `{"status":"error"}` |
| `GET /echo` | 200 回显 `{method, path, query, body}`（**不回显请求头**） |
| `GET /token` | 200 `{"token":"secret-value","id":1}` —— 专门用来测脱敏 |
| `GET /slow?ms=N` | 延迟 N 毫秒后返回 200 —— 用来测 timeout |

未列出的路径 → 404 `{"status":"not_found"}`。

- 桩服务的行为**与断言无关**：把断言从期望 404 改成期望 200，桩仍然返回 404 ——
  这样"判定随断言变化"才验得出来。如果桩跟着断言变，判定就永远成立，机制反而验不了。
- 可配置：`request` / `assertions` / `extract` / `auth` / `timeout_ms` / `retries`。
- 不支持：自定义响应体、自定义响应状态码、浏览器自动化、截图、压测并发、安全扫描。
  需要新的响应场景 → **提需求**，不要改执行器源码。

### 怎么选中驱动

| 方式 | 例子 | 说明 |
|---|---|---|
| 环境配置声明 `driver` | `test-assets/environments/mock.json` 里写 `"driver": "mock"` | 优先级最高 |
| `suite.json` 的 `executor` 字段 | `"executor": "mock"` | REQ-002B 的目录契约里 `executor` 枚举目前是 `api` / `ui` / `load` / `security` |

> **待对齐项**：两种写法都能选中 mock，但 `suite.json.executor = "mock"` 与
> 环境配置里的 `driver` 字段都超出 REQ-002B 现行的目录契约，
> `verify-layout.mjs` 会把它们判成违规取值。契约侧的放开由 REQ-002B 的维护方处理
> （`suite.json` 的 `executor` 枚举与环境配置的字段基线两处）。
> 在契约放开之前，本 skill 两种写法都接受，`verify-layout.mjs` 的报错可预期。

`ui` / `load` / `security` 属后续 REQ，本 skill 不交付：选中时执行外壳直接报错并列出已注册的驱动。

---

## 8. 扩展执行器的正确姿势

1. **先想清楚能不能用配置表达。** 换请求方式、加断言、改字段名、加鉴权、改超时 —— 全都有配置项。
2. **配置表达不了**：提需求，说明"要什么、为什么配置表达不了"。
3. **维护者改实现时**：改完重新生成完整性清单：
   ```
   node scripts/verify-integrity.mjs --update
   ```
   `--update` 是维护者路径，**不是**定制路径。agent 改完执行器顺手 `--update`，
   等于把污染洗成"正常" —— 改动必须进版本库、可追溯。
4. **改完自检**：
   ```
   node scripts/verify-integrity.mjs
   ```
   退出码 0 表示执行器实现与随包清单一致。
