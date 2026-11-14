# 负载级执行与判定链契约 —— `load-profile` skill 的 **B 阶段**

> 本文是 `load-profile` skill **B 阶段**（负载级执行 + 阈值判定）的契约：
> **压测计划 ⇒ 真的跑起来（只打本地桩）⇒ 判定结论 + 负载级证据**。
>
> 上游（A 阶段）见 `runner-adapters.md`（负载模型 → 压测计划，**零请求**）。
> 契约来源：`BA/demands/REQ-002-suite-foundation/REQ-013-load-exec/`
> （`demand.md` 功能契约 F1~F10 / `acceptance.md` 判据 AC-001~AC-041 / `decisions.md` 决策 D185~D210）。

---

## 0. 一句话与三条硬边界

**一句话**：消费 REQ-012 的 `plans/<套件名>.json`，把每条 `invocations[]` **真的跑起来**
（**只打本地桩服务**），并按计划里逐字携带的 `thresholds` 给出**判定结论**。

| 边界 | 内容 |
|---|---|
| **只打本地桩** | 目标地址**必须**是回环地址；非回环 ⇒ **rc=1 + 点名**（**绝不**打任何真实服务） |
| **只写自己的目录** | 只写 `<out-dir>/test-assets/load/results/`；输入（计划 / 模型 / 环境）一律**只读** |
| **结论只在本地桩上成立** | 产物里**不得**出现「生产环境容量达标」这类表述；**必须**出现「本地桩 / `127.0.0.1`」的限定 |

---

## 1. 两个入口

| 入口 | 作用 | 用法 |
|---|---|---|
| `scripts/run-load-test.mjs` | **主入口**：读计划 ⇒ 起桩 ⇒ 执行 ⇒ 判定 ⇒ 写产物 | `node scripts/run-load-test.mjs --load-dir <项目根> --out-dir <项目根> --suite <套件名> [--mode api\|cli] [--stub-delay-ms <N>] [--stub-error-rate <R>]` |
| `scripts/check-load-test.mjs` | **产物自洽校验器**（**只读**） | `node scripts/check-load-test.mjs <项目根> --suite <套件名>` |

| 参数 | 必填 | 默认 | 约束 |
|---|---|---|---|
| `--load-dir` | ✅ | — | 项目根（**只读**输入在其下） |
| `--out-dir` | ✅ | — | 项目根（**只写**产物在其下） |
| `--suite` | ✅ | — | 套件名；必须有同名 `plans/<套件名>.json` |
| `--mode` | ❌ | `api` | 枚举 `api` / `cli` |
| `--stub-delay-ms` | ❌ | `0` | 整数 ≥ 0 |
| `--stub-error-rate` | ❌ | `0` | 数值 ∈ [0, 1] |

**退出码**（两个入口一致）：

| 情形 | 退出码 |
|---|---|
| 执行完成，判定产物已写出（**哪怕不达标**） | `0` |
| 输入非法 / 工具不可用 / 目标非回环 / 产物已存在 / 判定链自身出错 | `1` |
| 用法错误（参数缺失 / 未知参数 / 多余位置参数 / 参数取值越界） | `2` |

⚠️ **「跑完但不达标」也是 `0`** —— 达标与否是**产物里的判定**，不是退出码。
⚠️ **判定不得依赖进程退出码**（桩中途挂掉时压测工具仍然 rc=0 ⇒ 只看退出码 = 假绿）。

---

## 2. 输入（**只读**）

| # | 输入 | 位置 |
|---|---|---|
| 1 | 压测计划 | `<load-dir>/test-assets/load/plans/<套件名>.json` |
| 2 | 负载模型 | `<load-dir>/test-assets/load/scenarios/*.json`（**只用于核对**） |
| 3 | 环境 | `<load-dir>/test-assets/environments/<环境名>.json` 的 `base_url`（**只用于记录「原本要打哪」**） |

- 阈值**只**来自计划里逐字携带的 `thresholds`；模型只用于核对（不一致 ⇒ rc=1 + 点名）。
- `test-assets/load/report.json` **不读也不改**。
- **先校验、后建目录**：输入非法 ⇒ `results/` **一个都不许出现**（0 字节空目录也算存在）。

---

## 3. 桩服务（`scripts/lib/stub.mjs`）

**形态**：**每套件一个独立桩实例**，**端口 0**（随机分配），**由执行器托管起停**。

| # | 规定 |
|---|---|
| 1 | **只监听 `127.0.0.1`** ⇒ 物理上不可能被外部访问 |
| 2 | **按 path 计数**（path 不含 query）+ **延迟直方图**（按 ms 桶，**聚合**，不存全量样本） |
| 3 | **每条 invocation 前重置计数** ⇒ 桩侧观测是**本次增量**，不是累计 |
| 4 | **记录绝对时序**：相对**桩启动**的毫秒偏移（首/末请求到达时刻）⇒ 可机械核「顺序执行、无重叠」 |
| 5 | **支持注入**：延迟（`--stub-delay-ms`）与错误率（`--stub-error-rate`）⇒ 响应码按注入比例取 200 / 500 |
| 6 | **默认行为**：`delay_ms = 0`、`error_rate = 0`、响应码恒 200 |
| 7 | **观测端点**：`GET /__stub/observations`（**只读**观测面）；`POST /__stub/reset`（重置观测） |
| 8 | **收尾必停**：正常结束、异常结束、**被中断**三条路径都停桩 |
| 9 | **收尾必须让进程能退出**：停桩时**连同残留连接一起断开**（keep-alive 空闲连接会拖住 `close()`） |
| 10 | **配置面封闭**：只有「延迟注入」「错误率注入」「响应码」「重置观测」四项，**不含任何真实业务逻辑** |

⚠️ 桩侧「延迟」= **服务端处理耗时**（含注入延迟），与客户端 RTT **语义不同** ⇒ 两段观测**分开存**。

---

## 4. 执行（两种模式）

### 4.1 `api` 模式（默认）

| # | 规定 |
|---|---|
| 1 | 执行器 **import** `loadtest` 包 ⇒ 拿**结构化 `Result`**，**不解析 stdout** |
| 2 | **必须反解**计划的 `argv` ⇒ API 选项（见 §4.3） |
| 3 | 反解**只接受 REQ-012 的规范形态**；规范外 ⇒ **rc=1 + 点名**（不猜参数） |
| 4 | `--cores 1` ⇒ API 路径**天然等价**（无 cluster 层）⇒ 语义不随机器核数变 |
| 5 | **必须显式覆盖**每个相关 API 选项并**显式禁 `proxy`**（防 `.loadtestrc` 渗透，见 §4.4） |
| 6 | **必须设置 `statusCallback`**（不设 ⇒ HTTP 错误状态码全塌成 `-1` ⇒ 错误码分类能力丢失） |
| 7 | 产物标 `execution.mode = "api_equivalent"`，并记录**实际执行参数**（`executed_params`） |

### 4.2 `cli` 模式（`--mode cli` 显式声明）

| # | 规定 |
|---|---|
| 1 | **逐字** spawn 计划里的 `argv`（命令行形态**不改一个字符**；URL 的 origin 按 §4.5 换） |
| 2 | **解析 stdout**（已知文本形态）；**解析不出来 ⇒ rc=1 + 点名**，**不得**编造数值 |
| 3 | 产物标 `execution.mode = "cli_verbatim"`，并标 `execution.cli = {error_code_resolution: "unavailable", percentile_source: "stdout_text"}` |
| 4 | `min_latency_ms` **记 `null`**（CLI 的 stdout 没有最小延迟 ⇒ 不许编造） |
| 5 | **能力弱于 api 模式**（无按状态码分类）⇒ 这是**已声明的取舍**，不是缺陷 |

### 4.3 argv → API 选项（**反解层**）

REQ-012 的**规范形态**（`runner-adapters.md` §4.1）与 `loadtest` API 的选项名**不是一套名字**：

| argv | API 选项 | 单位 | 缺省时的产物取值 |
|---|---|---|---|
| `-t <秒>` | `maxSeconds` | 秒 | —（必有） |
| `-c <并发>` | `concurrency` | 个 | —（必有） |
| `--cores 1` | —— | —— | API 路径**天然等价** |
| `-m <METHOD>` | `method` | —— | —（必有） |
| `--rps <值>` | `requestsPerSecond` | 每客户端 rps | `null` |
| `-k` | `agentKeepAlive` | 布尔 | `false` |
| `-d <毫秒>` | `timeout` | **毫秒**（单请求） | `null` |
| 位置参数（URL） | `url` | —— | origin 换成桩地址（§4.5） |

⚠️ `timeout` 的 API 单位就是**毫秒**（与 `-d` 同单位）⇒ 反解**无换算风险**。

### 4.4 防 `.loadtestrc` 渗透

`loadtest` 的 API 路径**也会**无条件读宿主目录下的 `.loadtestrc`
（可改 `concurrency` / `requestsPerSecond` / `method` / `headers` / `timeout` / **`proxy`** …）
⇒ 同一份计划在不同宿主目录下会跑出不同结果（幂等性破），`proxy` 还会让流量**打到桩之外**。

**两道防线**：

1. **显式覆盖**：每个相关选项都由反解结果显式给出（不依赖任何配置文件的值）；
2. **干净的工作目录**：执行器建一个**空的**临时目录（沙箱）并把压测工具的 cwd 指到那里
   ⇒ 工具读不到 `.loadtestrc`（`proxy` 因此**显式禁用**），跑完即删。

另加一道**自证**：跑完核对 `Result.concurrency` 与反解出的并发是否一致，不一致 ⇒ **rc=1 + 点名**。

### 4.5 URL 只换 origin

- **只替换 origin**（协议 + 主机 + 端口 → 桩地址）；**path 与 query 逐字保留**；
- 替换后**必须**校验 host 是**回环地址**（`127.0.0.0/8` 或 `::1`）；不通过 ⇒ **rc=1 + 点名**；
- **计划里的 URL 的 host 也必须是回环地址**（否则拒绝执行 ⇒ 绝不打真实服务）；
- 产物记录**替换前后的 URL**（origin 与 path 都逐字）。

### 4.6 `python` runner

| # | 规定 |
|---|---|
| 1 | **照常执行**：逐字 spawn 计划里自陈的命令（**不解析它的输出**） |
| 2 | 该 invocation 的 `observed` **缺席**；`verdict == "undetermined"`；每条阈值判定 `verdict == "undetermined"` 且 `reason` 点名「输出形态无契约」 |
| 3 | 该 invocation **仍然产生证据**（证据目录里必须有它的 `step_index` 子目录） |
| 4 | 其 `stub_observed.requests` **可以是 0**（自陈命令未必打桩） |
| 5 | ⚠️ **已知限制**：自陈命令由计划给定，本 REQ **不校验**它是否只打本地桩 ⇒ 如实登记为已知限制 |

### 4.7 执行顺序

**顺序执行**：场景顺序 == 计划顺序；场景内 invocation 顺序 == 数组顺序；**不并发**。
⇒ 可机械核：同套件内，前一条 invocation 的 `stub_observed.last_at_ms` ≤ 后一条的 `stub_observed.first_at_ms`。

---

## 5. 观测采集

| # | 规定 |
|---|---|
| 1 | **主观测量取客户端侧**（`Result`）：延迟分位 / 吞吐 / 错误数 |
| 2 | **桩侧观测**作为**辅助证据**落进产物，**不参与阈值判定** |
| 3 | **两侧请求数不做等式判定**（客户端侧比桩侧**少约等于并发数**：在途请求）⇒ 判据只判**上界** |
| 4 | 桩侧延迟**聚合**存储（直方图 + 计数 + 合计 + 极值），**不存全量样本** |

---

## 6. 阈值判定

### 6.1 阈值键白名单（**封闭 6 个**，不得增删）

`p50_latency_ms` / `p95_latency_ms` / `p99_latency_ms` / `error_rate` / `throughput_rps` / `max_concurrency`

模型 `thresholds_status == "not_provided"` ⇒ **无 `thresholds` 键** ⇒ **不产阈值判定**（只产执行事实）。

### 6.2 阈值键 → 观测量映射（**封闭**）

| 阈值键 | 观测量 | 达标口径 | `undetermined` 的情形 |
|---|---|---|---|
| `p50_latency_ms` | `observed.percentiles["50"]` | 观测 ≤ 阈值 | 默认桩 · `observed` 缺席 |
| `p95_latency_ms` | `observed.percentiles["95"]` | 观测 ≤ 阈值 | 同上 |
| `p99_latency_ms` | `observed.percentiles["99"]` | 观测 ≤ 阈值 | 同上 |
| `error_rate` | `observed.total_errors / observed.total_requests` | 观测 ≤ 阈值 | 默认桩 · `total_requests == 0` |
| `throughput_rps` | `observed.effective_rps` | 观测 ≥ 阈值 | `observed` 缺席 |
| `max_concurrency` | **无对应观测量** | — | **恒 `undetermined`** |

⚠️ **不许拿 `concurrency`（打算并发多少）或 `clients`（客户端数）冒充「实际并发」**。

### 6.3 判定枚举（**封闭 3 值**）

| 值 | 含义 |
|---|---|
| `met` | 有对应观测量、观测存在、且达标 |
| `not_met` | 有对应观测量、观测存在、且不达标 |
| `undetermined` | **无对应观测量** 或 **观测不存在** 或 **观测没有代表性**（必须**点名原因**） |

⚠️ `undetermined` **既不是达标也不是不达标** —— 判据不许把它算进达标，也不许算成失败。

### 6.4 三条判定口径

| # | 口径 |
|---|---|
| 1 | **默认桩**（`delay_ms == 0` 且 `error_rate == 0`）⇒ 延迟类 / 错误率类阈值**判 `undetermined`**（**不是 `met`**）；`throughput_rps` **仍可判** |
| 2 | **桩行为被注入** ⇒ 延迟类 / 错误率类阈值**恢复可判**（`met` / `not_met`） |
| 3 | **联合口径**：`error_rate` 判 `not_met` ⇒ 同一次 invocation 的 `throughput_rps` **不得**单独判 `met`（⇒ 判 `undetermined`，并点名「联合口径」） |

⚠️ 理由（`reason`）文本**不含观测数值** ⇒ 同一输入两次跑的结构**逐字一致**（幂等，见 §8）。

---

## 7. 输出产物

```
<out-dir>/test-assets/load/
├── plans/<套件名>.json            ← REQ-012 的产物（本 REQ 只读）
└── results/
    ├── <套件名>.json              ← 本 REQ 的判定产物（每套件一个）
    └── evidence/<套件名>/
        ├── manifest.json          ← 逐个证据文件的 sha256
        └── <场景标识>/            ← 场景标识 = 该场景的 `scenario_id`（唯一，不用下标）
            └── <step_index>/      ← 每条 invocation 一个子目录
                ├── result.json    ← 该次执行的原始结果
                ├── stdout.txt     ← 该次执行的 stdout 原文
                └── stub-observations.json ← 桩侧观测快照
```

⚠️ 结果产物**绝不能叫 `suite.json`**（上游对 `suite.json` 的顶层字段集封闭）。
⚠️ 证据落点**必须按场景分层**（`step_index` 是**每个场景内**从 0 开始的 ⇒ 扁平落点会互相覆盖）。

### 7.1 顶层（**封闭 8 个**）

`schema_version`（固定 `1`）/ `suite` / `environment` / `generated_at`（ISO-8601）/
`execution` / `scenarios`（非空，顺序 == 计划顺序）/ `verdict` / `results_sha256`

`results_sha256` = 对**剔除 `generated_at` 与 `results_sha256` 两个字段**后的整个内容算的 sha256
（**规范化序列化**：排序键 + 紧凑分隔符；第三方可独立复算）。

### 7.2 `execution`（**封闭 6 必填 + 1 条件**）

`mode` / `started_at` / `finished_at` / `duration_ms` / `tool`（`name` / `version` / `resolved_from`）/
`stub`（`origin` / `delay_ms` / `error_rate` / `status`）
\+ **条件键** `cli`（**仅** `cli_verbatim` 模式存在；`api_equivalent` 模式**必须缺席**）

### 7.3 场景条目（**封闭 8 个 + 2 个条件**）

`scenario_id` / `scenario_name` / `runner` / `target` / `base_url` / `thresholds_status` /
`invocations` / `verdict`
\+ **条件** `thresholds` / `thresholds_source`（`provided` 时**都存在**且逐字取自计划；`not_provided` 时**都不存在**）

### 7.4 invocation 条目（**封闭 10 个；`python` runner 为 8 个**）

`step_index` / `duration_s` / `concurrency` / `argv`（**逐字**取自计划）/
`executed_url` / `executed_params`（**api 模式**：封闭 6 个；cli 模式与 `python` runner **缺席**）/
`observed`（**api / cli 模式**：封闭 10 个；`python` runner **缺席**）/ `stub_observed` /
`thresholds`（判定条目数组；无阈值时为空数组）/ `verdict`

### 7.5 `observed`（**封闭 10 个**）

`total_requests` / `total_errors` / `error_codes`（状态码 → 次数；cli 模式只有 `"-1"` 一个桶）/
`error_rate`（`total_requests == 0` ⇒ `null`）/ `mean_latency_ms` / `effective_rps`（**只留一个**，不写 `rps` 别名）/
`percentiles`（封闭 4 键 `"50"` / `"90"` / `"95"` / `"99"`）/ `max_latency_ms` /
`min_latency_ms`（**cli 模式为 `null`**）/ `elapsed_seconds`

### 7.6 `stub_observed`（**封闭 9 个**）

`requests` / `errors` / `error_rate`（`requests == 0` ⇒ `null`）/ `mean_ms` / `min_ms` / `max_ms` /
`histogram_ms`（ms 桶 → 次数，**聚合**）/ `first_at_ms` / `last_at_ms`（相对**桩启动**的毫秒偏移）

### 7.7 阈值判定条目（**封闭 5 个**）

`key` / `threshold`（逐字取自计划）/ `observed`（**无观测量 ⇒ `null`**；判 `undetermined` 时也是 `null`）/
`verdict` / `reason`（**必填非空**；`undetermined` 时**必须**点名原因）

### 7.8 `verdict`（**封闭 6 个**）

`suite` / `invocations_total` / `invocations_met` / `invocations_not_met` / `invocations_undetermined` /
`undetermined_keys`（逐个出现过的不可判定阈值键，去重、逐字）

⚠️ **汇总不得掩盖失败**：任一 invocation 判 `not_met` ⇒ 套件级**不得**判 `met`。

---

## 8. 写入纪律与幂等

| # | 口径 |
|---|---|
| 1 | **只写** `<out-dir>/test-assets/load/results/`（含 `evidence/`）—— 不碰 `plans/` / `scenarios/` / `suites/` / `environments/` |
| 2 | **先校验、后建目录**：输入非法 ⇒ `results/` 一个都不许出现 |
| 3 | **产物已存在 ⇒ 报错退出，不覆盖**（判定产物与证据目录都查） |
| 4 | **输入只读**：计划 / 模型 / 环境文件一律不改写 |
| 5 | **幂等（结构级）**：同一输入两次跑 ⇒ 产物的**结构、键集、判定口径**一致；**数值与结论允许抖动**（压测是随机过程） |
| 6 | **不做「跑到过关为止」的重试**：单次观测就是结论 |

---

## 9. 诚实性红线

| # | 红线 |
|---|---|
| 1 | **不得**出现「生产环境容量达标」「本服务可承载 N 并发」这类表述 |
| 2 | **必须**出现「在本地桩上」的限定（`execution.stub.origin` 与文档措辞） |
| 3 | **不得**把 `undetermined` 说成「达标」或「不达标」（枚举封闭） |
| 4 | **不得**把桩侧计数当成「客户端完成的请求数」（两段观测**分开存**） |
| 5 | **不得**把「默认桩」下的延迟 / 错误率说成「达标」（判 `undetermined`） |
| 6 | **不得**在 API 模式把执行说成「跑了计划里那条命令」（标 `api_equivalent`） |
| 7 | **不得**在工具不可用时产出任何判定（rc=1，不写产物） |

---

## 10. 证据链与指纹

- 每次 invocation 的**原始结果**落进 `evidence/<套件>/<场景>/<step>/result.json`；
- 该次执行的 **stdout 原文**落进同目录的 `stdout.txt`；
- **桩侧观测快照**落进同目录的 `stub-observations.json`；
- 证据目录含 `manifest.json`，**逐个列出**每个证据文件的 sha256（可被第三方独立复算）；
- 结果产物顶层 `results_sha256`（口径见 §7.1）。

---

## 11. 已知限制（如实登记）

| # | 限制 |
|---|---|
| 1 | **结论只在本地桩上成立** ⇒ 不代表任何真实服务的容量 |
| 2 | **默认桩的延迟 / 错误率没有代表性** ⇒ 这两类阈值在默认桩下判「不可判定」；想要可判的延迟结论必须用 `--stub-delay-ms` 注入 |
| 3 | **`max_concurrency` 没有对应观测量** ⇒ 恒判「不可判定」 |
| 4 | **`python` runner 的输出形态无契约** ⇒ 一律判「不可判定」 |
| 5 | **`python` runner 的自陈命令是否只打本地桩，本 REQ 不校验**（命令由计划给定） |
| 6 | **桩侧与客户端侧的请求数天然不相等**（在途请求）⇒ 只判上界，不判等式 |
| 7 | **桩侧延迟与服务端处理耗时语义不同**，与客户端 RTT 不可混用 |

---

## 12. 判定规则在哪

- `references/load-exec-contract.md` —— **本文**（B 阶段契约）。
- `references/runner-adapters.md` —— A 阶段契约（`argv` 规范形态 / `args` 白名单 / 计划字段集）。
- `references/profile-rules.md` —— 阈值键白名单与画像规则。
- `scripts/check-load-test.mjs` —— 产物自洽校验器（拿已产出的产物复核一份）。
