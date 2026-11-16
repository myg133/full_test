# REQ-013 —— 压测能力域 B 阶段：`load-profile` skill 的 **负载级执行与判定链**

> **版本**：**契约版**（2026-11-14）。
> 判据见 `acceptance.md`（AC-xxx）· 决策见 `decisions.md`（**D185~D210，共 26 条**）· 勘察事实见 `PROBE-FACTS.md`。
> ⚠️ **本文是契约，不是说明材料**：字段名固定、枚举固定，便于机械核验。
> ⚠️ **判据引用的是本文的清单**（**不得**「schema 里没写就不查」）。

---

## 0. 背景与边界

### 0.1 缺口具体长什么样

REQ-009（压测能力域）交了「负载模型」；REQ-012（A 阶段）交了「runner 适配」——
把负载模型翻译成**真实压测工具能消费的命令清单**（`test-assets/load/plans/<套件名>.json`）。

⇒ **两半拼起来仍然不压测**：命令清单交出去了，**没人执行它**；执行了也**没人按阈值判定**。
本 REQ 补的就是这两件事。

```
  容量目标 ──REQ-009──▶ 负载模型(report.json) ──REQ-012──▶ 命令清单(plans/*.json)
                                                                     │
                                                        本 REQ ▼    │ 执行 + 判定
                                                          负载级产物 + 阈值判定结论
```

### 0.2 本 REQ **只打本地桩服务**

**需求方 2026-11-14 拍板**：B 阶段**只打本地桩服务，绝不打真实服务**。

由此产生四条硬约束：

1. **结论的适用范围** —— 本 REQ 产出的一切结论都只是「**在本地桩上**」的压测结论。
   产物 / 报告 / 正文里**不得**出现「生产环境容量达标」「本服务可承载 N 并发」这类表述（D205）。
2. **桩服务必须可观测** —— 桩**自带请求计数**与**延迟注入能力**（否则「压了」不可证）（D187 / D209）。
3. **桩服务不得是「假服务」** —— 恒返回 200、恒 0 延迟 ⇒ 延迟类与错误率类阈值**没有代表性**
   ⇒ 本 REQ 对这两类阈值**判「不可判定」**（D199），**不得**判「达标」。
4. **目标地址必须被校验** —— 只允许**回环地址**；非回环 ⇒ **rc=1 + 点名**（D194）。

### 0.3 交付边界（不许越界）

| 边界 | 内容 |
|------|------|
| **只打本地桩** | 目标地址**必须**指向回环地址；**任何**指向非回环地址的目标**必须被拒绝** |
| **不改 `test-execute`** | 不写 `cases.json`、不碰 `results.json` / `meta.json`、**不与** `verdict.mjs` 混用（D191） |
| **不改 `test-report`** | 负载级结论**不塞进** `report.json`（其顶层封闭 ⇒ 装不下）（D191） |
| **不改 REQ-009 的既有文件** | 负载模型侧只读不改 |
| **不改 REQ-012 的既有文件** | 计划侧只读不改；本 REQ **消费**它 |
| **不改 REQ-012 的契约** | **不扩** `args` 白名单、**不加**计划顶层字段、**不改** `argv` 规范形态（D192 约束 1） |
| **不发真实流量** | 不连公网、不连内网真实服务、不碰任何非桩地址 |
| **不装工具** | `loadtest` 由 `qa-toolchain`（REQ-003）负责；本 skill 只**检查可用性**（D206） |

---

## 1. 目标

1. **执行**：消费 REQ-012 的 `plans/<套件名>.json`，把每条 `invocations[]` **真的跑起来**（真的发请求），
   并把每次执行的**原始结果**落成**负载级**证据。
2. **判定**：对每个阈值键给出**判定结论**（`met` / `not_met` / `undetermined`），
   对**无对应观测量**或**没有代表性**的阈值键**显式判 `undetermined`**（D195 / D199）。
3. **可证伪**：留下**可核验的证据**（原始结果 + 桩侧观测 + sha256 清单），使「压了没有、压得对不对」**可被第三方独立复核**（D208）。
4. **诚实**：产物与结论**不得超出「本地桩上」这个范围**；`undetermined` **必须**显式呈现且**点名原因**。

---

## 2. 功能项 F1~F10

### F1 入口与用法

| 入口 | 作用 | 用法 |
|---|---|---|
| `scripts/run-load-test.mjs` | **主入口**：读计划 ⇒ 起桩 ⇒ 执行 ⇒ 判定 ⇒ 写产物 | `node scripts/run-load-test.mjs --load-dir <项目根> --out-dir <项目根> --suite <套件名> [--mode api\|cli] [--stub-delay-ms <N>] [--stub-error-rate <R>]` |
| `scripts/check-load-test.mjs` | **产物自洽校验器**：复核结果产物与计划/模型一致 | `node scripts/check-load-test.mjs <项目根> --suite <套件名>` |

**参数规则**：

| 参数 | 必填 | 默认 | 约束 |
|---|---|---|---|
| `--load-dir` | ✅ | — | 项目根（**只读**输入在其下） |
| `--out-dir` | ✅ | — | 项目根（**只写**产物在其下） |
| `--suite` | ✅ | — | 套件名；必须**有同名** `plans/<套件名>.json` |
| `--mode` | ❌ | `api` | 枚举 `api` / `cli`（D192） |
| `--stub-delay-ms` | ❌ | `0` | 整数 ≥ 0 |
| `--stub-error-rate` | ❌ | `0` | 数值 ∈ [0, 1] |

**退出码**（两个入口一致，D210）：

| 情形 | 退出码 |
|---|---|
| 执行完成，判定产物已写出 | `0` |
| 输入非法 / 工具不可用 / 目标非回环 / 判定链自身出错 | `1` |
| 用法错误（参数缺失 / 未知参数 / 多余位置参数） | `2` |

⚠️ **「跑完但不达标」也是 `0`** —— 达标与否是**产物里的判定**，不是退出码（D197 / D210）。

### F2 输入（**只读**）

| # | 输入 | 位置 |
|---|---|---|
| 1 | 压测计划 | `<load-dir>/test-assets/load/plans/<套件名>.json`（REQ-012 产物） |
| 2 | 环境 | `<load-dir>/test-assets/environments/<环境名>.json` 的 `base_url`（**只读**，用于记录「原本要打哪」） |
| 3 | 负载模型 | `<load-dir>/test-assets/load/scenarios/*.json`（**只读**，用于取 `thresholds` 与 `open_questions`） |

**读取纪律**：
- 计划里每个场景的 `thresholds` / `thresholds_source` **逐字携带**模型的对应字段 ⇒ 本 REQ **以计划为准**，
  模型只用于**核对**（不一致 ⇒ rc=1 + 点名）；
- **不读也不改** `test-assets/load/report.json`（REQ-012 契约同款纪律）。

### F3 桩服务

**形态**：**每套件一个独立桩实例**，**端口 0**（随机分配），由执行器**托管起停**（D196）。

| # | 规定 | 出处 |
|---|---|---|
| 1 | **只监听回环地址**（`127.0.0.1`）⇒ 物理上不可能被外部访问 | D187 |
| 2 | **按 path 计数**（path 不含 query），并记录**延迟直方图**（按 ms 桶，**聚合**，不存全量样本） | D209 / C9 |
| 3 | **每条 invocation 前重置计数**（桩支持「重置观测」接口）⇒ 每条 invocation 的桩侧观测是**本次增量**，不是累计 | F7.8 |
| 4 | **记录绝对时序**：桩启动以来的毫秒偏移；每次重置后记录**首个请求到达时刻**与**末个请求到达时刻** ⇒ 可机械核「顺序执行、无重叠」 | F7.8 / D209 |
| 5 | **支持注入**：延迟（`--stub-delay-ms`）与错误率（`--stub-error-rate`）⇒ 响应码按注入比例取 200 / 500 | D193 |
| 6 | **默认行为**：`delay_ms = 0`、`error_rate = 0`、响应码恒 200 | D193 |
| 7 | **观测端点**：桩暴露一个**只读观测接口**，返回计数 / 错误数 / 延迟直方图 / 合计 / 极值 / 时序 | D209 |
| 8 | **收尾必停**：正常结束、异常结束、**被中断**（SIGINT/SIGTERM）三条路径都**必须**停桩 | D196 |
| 9 | **收尾必须让进程能退出**：停桩时**连同残留连接一起断开**（keep-alive 的空闲连接会拖住 `close()`） | D196 |
| 10 | 桩的**配置面封闭**：只有「延迟注入」「错误率注入」「响应码」「重置观测」四项；**不含**任何真实业务逻辑 | D187 |

### F4 执行（**两种模式**）

#### F4.1 `api` 模式（默认）

| # | 规定 | 出处 |
|---|---|---|
| 1 | 执行器 **import** `loadtest` 包（模块路径解析见 F4.3）⇒ 拿**结构化 `Result`**，**不解析 stdout** | B2 |
| 2 | **必须反解**计划的 `argv` ⇒ API 选项：`maxSeconds` / `concurrency` / `requestsPerSecond` / `agentKeepAlive` / `timeout` / `url` / `method` | D200 |
| 3 | 反解**只接受 REQ-012 的规范形态**（`-t` `-c` `--cores 1` URL `-m`，后接可选 `--rps` / `-k` / `-d`）；**规范外 ⇒ rc=1 + 点名** | D200 / D1 |
| 4 | `--cores 1` ⇒ API 路径**天然等价**（无 cluster 层）⇒ **不得**因机器核数不同而改变语义 | B4 |
| 5 | **必须显式覆盖**每个相关 API 选项（防 `.loadtestrc` 渗透）并**显式禁用** `proxy` | D202 |
| 6 | **必须设置 `statusCallback`**（否则 HTTP 错误状态码全塌成 `-1`，错误码分类能力丢失） | B5 / B6 |
| 7 | 产物标 `execution.mode = "api_equivalent"`，并记录**实际执行参数** | D200 |

#### F4.2 `cli` 模式（`--mode cli` 显式声明）

| # | 规定 | 出处 |
|---|---|---|
| 1 | **逐字** spawn 计划里的 `argv`（**不改一个字符**）⇒ 执行的就是计划里那条命令 | D201 |
| 2 | **解析 stdout**（已知文本形态）；**解析不出来 ⇒ rc=1 + 点名**，**不得**编造数值 | D201 |
| 3 | 产物标 `execution.mode = "cli_verbatim"`，并标 `error_code_resolution = "unavailable"`（只有 `-1` 桶）、`percentile_source = "stdout_text"` | D201 |
| 4 | CLI 模式**必须**清理子进程（超时 / 异常路径都要收尾） | D201 |
| 5 | ⚠️ **本模式的能力弱于 api 模式**（无按状态码分类）⇒ 这是**已声明的取舍**，不是缺陷 | D192 / B7 |

#### F4.3 工具解析与可用性检查（**前置**）

| # | 规定 | 出处 |
|---|---|---|
| 1 | `api` 模式：按顺序找 `loadtest` 模块 —— ① `<项目根>/.tools/node/node_modules/loadtest/index.js` ② `NODE_PATH` / `import.meta.resolve` 可解析的 `loadtest` | D9 / D206 |
| 2 | `cli` 模式：`loadtest` 可执行文件 —— ① `<项目根>/.tools/node/node_modules/.bin/loadtest` ② `PATH` | D206 / D8 |
| 3 | **不可用 ⇒ rc=1 + 明确报错**（点名缺什么、怎么装），**不得**产出任何判定产物、**不得**「假装压过了」 | D206 |
| 4 | 产物记录工具的 `name` / `version` / `resolved_from` | D208 |

#### F4.4 执行顺序与 URL 替换

| # | 规定 | 出处 |
|---|---|---|
| 1 | **顺序执行**：场景顺序 == 计划里的顺序；场景内的 invocation 顺序 == 数组顺序；**不并发**<br>⇒ **可核**：同套件内，前一条 invocation 的 `stub_observed.last_at_ms` ≤ 后一条的 `stub_observed.first_at_ms`（**无时间重叠**） | D190 |
| 2 | **URL 只换 origin**（协议 + 主机 + 端口 → 桩地址）；**path 与 query 逐字保留** | D194 |
| 3 | 替换后**必须**校验 host 是**回环地址**（`127.0.0.0/8` 或 `::1`）；**不通过 ⇒ rc=1 + 点名** | D194 |
| 4 | 产物记录**替换前后的 URL**（origin 与 path 都逐字） | D194 / D208 |

#### F4.5 `python` runner 的执行

| # | 规定 | 出处 |
|---|---|---|
| 1 | **照常执行**：逐字 spawn 计划里自陈的命令（**不解析它的输出**） | D203 |
| 2 | 该 invocation 的 `observed` **缺席**；`verdict == "undetermined"`；若有阈值，则每条判定的 `verdict == "undetermined"` 且 `reason` **点名**「输出形态无契约」 | D203 / D195 |
| 3 | 该 invocation **仍然产生证据**（证据目录里必须有它的 `step_index` 子目录） | D208 |
| 4 | 该 invocation 的 `stub_observed.requests` **可以是 0**（自陈命令**未必**打桩）⇒ **不适用**「桩必须收到请求」这条要求 | D198 |
| 5 | ⚠️ **已知限制**：自陈命令由计划给定，本 REQ **不校验**它是否只打本地桩 ⇒ **如实登记为已知限制**（见 `dispatch/req-registry.md` 遗留项表） | A1 |

### F5 观测采集

| # | 规定 | 出处 |
|---|---|---|
| 1 | **主观测量取客户端侧**（`Result`）：延迟分位 / 吞吐 / 错误数 | D198 |
| 2 | **桩侧观测**作为**辅助证据**落进产物，**不参与阈值判定** | D198 |
| 3 | **两侧请求数不做等式判定**（实测客户端侧比桩侧**少约等于并发数**：在途请求） | D198 / C1 |
| 4 | 桩侧延迟**聚合**存储（直方图 + 计数 + 合计 + 极值），**不存全量样本** | D209 / C9 |

### F6 阈值判定

#### F6.1 阈值来源与键集

- 阈值**只**来自计划里逐字携带的 `thresholds`（D188）；键集**封闭 6 个**（REQ-009 白名单，**不得增删**）：
  `p50_latency_ms` / `p95_latency_ms` / `p99_latency_ms` / `error_rate` / `throughput_rps` / `max_concurrency`。
- 模型 `thresholds_status == "not_provided"` ⇒ **无 `thresholds` 键** ⇒ 本 REQ **不产阈值判定**，只产执行事实（D188）。

#### F6.2 阈值键 → 观测量映射（**封闭**）

| 阈值键 | 观测量 | 达标口径 | `undetermined` 的情形 |
|---|---|---|---|
| `p50_latency_ms` | `observed.percentiles["50"]` | 观测 ≤ 阈值 | 默认桩（D199）· `observed` 缺席 |
| `p95_latency_ms` | `observed.percentiles["95"]` | 观测 ≤ 阈值 | 同上 |
| `p99_latency_ms` | `observed.percentiles["99"]` | 观测 ≤ 阈值 | 同上 |
| `error_rate` | `observed.total_errors / observed.total_requests` | 观测 ≤ 阈值 | 默认桩（D199）· `total_requests == 0` |
| `throughput_rps` | `observed.effective_rps` | 观测 ≥ 阈值 | `observed` 缺席 |
| `max_concurrency` | **无对应观测量** | — | **恒 `undetermined`**（D189） |

⚠️ **不许拿 `concurrency`（打算并发多少）或 `clients`（客户端数）冒充「实际并发」**（D189）。

#### F6.3 判定枚举（**封闭 3 值**）

| 值 | 含义 |
|---|---|
| `met` | 有对应观测量、观测存在、且达标 |
| `not_met` | 有对应观测量、观测存在、且不达标 |
| `undetermined` | **无对应观测量** 或 **观测不存在** 或 **观测没有代表性**（必须**点名原因**） |

⚠️ `undetermined` **既不是达标也不是不达标**（D195）——
**判据不许把它算进达标**（那是凭空判达标），也**不许**把它算成失败（那是凭空判不达标）。

⚠️ **判定不得依赖进程退出码**（D197）——
桩中途挂掉时 loadtest **rc 仍是 0**（实测 C5）⇒ 只看退出码 = **假绿**。

⚠️ **`throughput_rps` 必须与 `error_rate` 联合看**（C4：全部失败时 `effective_rps` 依然 5752）
⇒ `error_rate` 判 `not_met` 时，同一次 invocation 的 `throughput_rps` **不得**单独判 `met`
（**联合口径**：错误率不达标 ⇒ 该 invocation 的吞吐**不得**报「达标」）。

### F7 输出产物

#### F7.1 落点

```
<out-dir>/test-assets/load/
├── plans/<套件名>.json            ← REQ-012 的产物（本 REQ 只读）
└── results/
    ├── <套件名>.json              ← 本 REQ 的判定产物（每套件一个）
    └── evidence/<套件名>/
        ├── manifest.json          ← 逐个证据文件的 sha256
        └── <场景标识>/            ← 场景标识 = 该场景的 `scenario_id`（如 WL-001；**唯一**，不用下标）
            └── <step_index>/      ← 每条 invocation 一个子目录
                ├── result.json    ← 该次执行的原始结果（api：Result 选定字段；cli：解析结果）
                ├── stdout.txt     ← 该次执行的 stdout 原文（两种模式都写）
                └── stub-observations.json ← 桩侧观测快照
```

⚠️ **为什么证据落点必须按场景分层**：`step_index` 是**每个场景内**从 0 开始的（4 个场景 ⇒ 扁平落点会出现 3 个
都叫 `0` 的目录 ⇒ **互相覆盖**）⇒ 故落点为 `evidence/<套件名>/<场景标识>/<step_index>/`。
⚠️ 分层用 **`scenario_id`**（不是下标）⇒ 目录名**自解释**且天然唯一。

⚠️ **结果产物绝不能叫 `suite.json`**（REQ-012 勘察 ⑦ 的同款红线：上游对 `suite.json` 的顶层字段集封闭）。

#### F7.2 结果产物顶层（**封闭 8 个**）

| 字段 | 类型 | 说明 |
|---|---|---|
| `schema_version` | number | 固定 `1` |
| `suite` | string | == 文件名去 `.json` == 计划的 `suite` |
| `environment` | string | == 计划的 `environment` |
| `generated_at` | string | ISO-8601 生成时间戳（**幂等自验时唯一允许变动的字段**，D207） |
| `execution` | object | 执行元信息（F7.3） |
| `scenarios` | array | 非空；**顺序 == 计划里的场景顺序** |
| `verdict` | object | 套件级汇总判定（F7.6） |
| `results_sha256` | string | 对本文件内容算的 sha256（**排除** `generated_at` 与 `results_sha256` 两个字段） |

**任何未登记的顶层键 ⇒ 判红**（D204）。

#### F7.3 `execution` 段（**封闭 6 必填 + 1 条件**）

| 字段 | 类型 | 说明 |
|---|---|---|
| `mode` | string | `api_equivalent` / `cli_verbatim` |
| `started_at` | string | ISO-8601 |
| `finished_at` | string | ISO-8601 |
| `duration_ms` | integer ≥ 0 | 墙钟耗时 |
| `tool` | object | 封闭 3 个：`name` / `version` / `resolved_from` |
| `stub` | object | 封闭 4 个：`origin` / `delay_ms` / `error_rate` / `status` |
| `cli` | object \| **缺席** | **条件键**：**仅** `cli_verbatim` 模式存在（封闭 2 个：`error_code_resolution` / `percentile_source`）；`api_equivalent` 模式**必须缺席** |

#### F7.4 场景条目（**封闭 8 个 + 2 个条件**）

| 字段 | 类型 | 说明 |
|---|---|---|
| `scenario_id` | string | **逐字**取自计划 |
| `scenario_name` | string | **逐字**取自计划 |
| `runner` | string | `loadtest` / `python`（**逐字**取自计划） |
| `target` | string | **逐字**取自计划 |
| `base_url` | string | **逐字**取自计划（**原环境的** `base_url`） |
| `thresholds_status` | string | `provided` / `not_provided`（**逐字**取自计划） |
| `invocations` | array | 非空；**顺序 == 计划里的顺序** |
| `verdict` | string | 场景级判定（`met` / `not_met` / `undetermined`） |
| `thresholds` | object | **条件**：计划里有才有，**逐字**取自计划 |
| `thresholds_source` | string | **条件**：计划里有才有，**逐字**取自计划 |

#### F7.5 invocation 条目（**封闭 10 个；`python` runner 为 8 个**）

| 字段 | 类型 | 说明 |
|---|---|---|
| `step_index` | integer ≥ 0 | **逐字**取自计划 |
| `duration_s` | integer ≥ 1 | **逐字**取自计划 |
| `concurrency` | integer ≥ 1 | **逐字**取自计划 |
| `argv` | array | **逐字**取自计划（**不改一个字符**） |
| `executed_url` | string | 实际请求的 URL（origin 已换成桩） |
| `executed_params` | object \| 缺席 | **api 模式**：封闭 6 个（`maxSeconds` / `concurrency` / `requestsPerSecond` / `agentKeepAlive` / `timeout` / `method`）；**cli 模式**与 **`python` runner** **缺席**（后者不走 API 反解） |
| `observed` | object \| 缺席 | 客户端侧观测（F7.7）；`python` runner **缺席**（无输出契约，D203）⇒ 该条目**共 9 键** |
| `stub_observed` | object | 桩侧观测（F7.8） |
| `thresholds` | array | 逐个阈值键的判定（F7.9）；**无阈值时为空数组** |
| `verdict` | string | 本条 invocation 的判定（`met` / `not_met` / `undetermined`） |

#### F7.6 `verdict` 段（**封闭 6 个**）

| 字段 | 类型 | 说明 |
|---|---|---|
| `suite` | string | `met` / `not_met` / `undetermined` |
| `invocations_total` | integer ≥ 0 | invocation 总数 |
| `invocations_met` | integer ≥ 0 | 判 `met` 的条数 |
| `invocations_not_met` | integer ≥ 0 | 判 `not_met` 的条数 |
| `invocations_undetermined` | integer ≥ 0 | 判 `undetermined` 的条数 |
| `undetermined_keys` | array | **逐个**出现过的不可判定阈值键（去重、**逐字**），如 `["max_concurrency"]` |

⚠️ **汇总不得掩盖失败**：任一 invocation 判 `not_met` ⇒ 套件级**不得**判 `met`（D190）。

#### F7.7 `observed` 段（**封闭 10 个**）

| 字段 | 类型 | 说明 |
|---|---|---|
| `total_requests` | integer ≥ 0 | 客户端侧完成的请求数 |
| `total_errors` | integer ≥ 0 | 客户端侧的错误数 |
| `error_codes` | object | 状态码 → 次数（**cli 模式只有 `"-1"` 一个桶**） |
| `error_rate` | number | `total_errors / total_requests`（`total_requests == 0` ⇒ `null`） |
| `mean_latency_ms` | number | 客户端侧观测均值 |
| `effective_rps` | number | 客户端侧有效吞吐（**注意**：`rps` 是同值别名，**只留一个**，B11） |
| `percentiles` | object | 封闭 4 键：`"50"` / `"90"` / `"95"` / `"99"` |
| `max_latency_ms` | number | — |
| `min_latency_ms` | number \| null | — ⚠️ **`cli` 模式为 `null`**（CLI 的 stdout 只有 50/90/95/99/100% 分位，**没有最小延迟** ⇒ 不得编造） |
| `elapsed_seconds` | number | — |

#### F7.8 `stub_observed` 段（**封闭 9 个**）

| 字段 | 类型 | 说明 |
|---|---|---|
| `requests` | integer ≥ 0 | 桩**本次**收到的请求数（**可能比 `total_requests` 多**，D198） |
| `errors` | integer ≥ 0 | 桩**本次**返回的错误响应数 |
| `error_rate` | number | `errors / requests`（`requests == 0` ⇒ `null`） |
| `mean_ms` | number | 桩侧处理耗时均值 |
| `min_ms` | number | — |
| `max_ms` | number | — |
| `histogram_ms` | object | ms 桶 → 次数（**聚合**，D209） |
| `first_at_ms` | integer ≥ 0 | **本次**首个请求到达时刻（相对**桩启动**的毫秒偏移） |
| `last_at_ms` | integer ≥ 0 | **本次**末个请求到达时刻（同一基准） |

#### F7.9 阈值判定条目（**封闭 5 个**）

| 字段 | 类型 | 说明 |
|---|---|---|
| `key` | string | 阈值键（**逐字**取自阈值白名单） |
| `threshold` | number | 阈值值（**逐字**取自计划里的阈值） |
| `observed` | number \| null | 对应观测量；**无观测量 ⇒ `null`** |
| `verdict` | string | `met` / `not_met` / `undetermined` |
| `reason` | string | **必填非空**；`undetermined` 时**必须**点名原因 |

### F8 写入纪律

| # | 口径 |
|---|---|
| 1 | **只写** `<out-dir>/test-assets/load/results/`（含 `evidence/`）—— **不碰** `plans/` / `scenarios/` / `suites/` / `environments/` |
| 2 | **先校验、后建目录**：输入非法 ⇒ `results/` **一个都不许出现**（0 字节空目录也算存在） |
| 3 | **产物已存在 ⇒ 报错退出，不覆盖** |
| 4 | **输入只读**：计划 / 模型 / 环境文件一律不改写 |
| 5 | **不覆盖别人的产物**：本次只写 `<套件名>.json` 与 `evidence/<套件名>/` |
| 6 | **幂等（结构级）**：同一输入两次跑 ⇒ 产物的**结构、键集、判定口径**一致；**数值与结论允许抖动**（D207）—— **不承诺**逐字相同 |
| 7 | **不做「跑到过关为止」的重试**：单次观测就是结论（D207） |

### F9 诚实性

| # | 红线 | 载体 |
|---|---|---|
| 1 | **不得**出现「生产环境容量达标」「本服务可承载 N 并发」「压测通过（生产）」这类表述 | 结果产物与 `report.md` 同款扫描 |
| 2 | **必须**出现「**在本地桩上**」的限定 | `execution.stub.origin` + 文档措辞 |
| 3 | **不得**把 `undetermined` 说成「达标」或「不达标」 | `verdict` 枚举封闭 |
| 4 | **不得**把桩侧计数当成「客户端完成的请求数」 | 两段观测**分开存**（F7.7 / F7.8） |
| 5 | **不得**把「默认桩」下的延迟 / 错误率说成「达标」 | D199：判 `undetermined` |
| 6 | **不得**在 API 模式把执行说成「跑了计划里那条命令」 | D200：`api_equivalent` 标注 |
| 7 | **不得**在工具不可用时产出任何判定 | D206：rc=1，不写产物 |

### F10 交付物形状与追溯件

| # | 交付物 | 位置 |
|---|---|---|
| 1 | 执行入口 | `skills/load-profile/scripts/run-load-test.mjs` |
| 2 | 产物自洽校验器 | `skills/load-profile/scripts/check-load-test.mjs` |
| 3 | 桩服务 | `skills/load-profile/scripts/lib/stub.mjs`（**进交付包**，D187） |
| 4 | 执行器 / 判定器 | `skills/load-profile/scripts/lib/load-exec.mjs` |
| 5 | 契约文档 | `skills/load-profile/references/load-exec-contract.md`（**新文件**） |
| 6 | SKILL.md | **必须追加一节**说明 B 阶段入口与边界（**既有内容逐字不改**，只**追加**，不删改原有段落） |
| 7 | 追溯件 | `feature-meta/load-runner/` 四件套**追加**本 REQ 的条目（**不覆盖** REQ-012 的内容） |

⚠️ **交付红线**：交付包（`skills/` `bin/` `README.md` `LICENSE`）**不得出现 「内部运行时字样」 字样**。

---

## 3. 夹具规格（判据的公共前置，详见 `acceptance.md` §0）

> **本节是判据的公共前置**：判据用的夹具**逐字**规定在此，需求方与实现方**各自独立造**，
> 造完**必须逐字一致**（一致 ⇒ 契约无歧义）。

### 3.1 压测上下文（**来源**，入口不读）

```
<项目根>/
├── .gitignore                     ← 含 ".tools/*" 与 "!.tools/manifest.json" 两行
├── .tools/
│   ├── manifest.json              ← 工具清单（**逐字**见 3.1.1）；安装产物不进夹具
│   └── node/node_modules/loadtest/  ← **安装产物**（验收前置，见 3.1.2）
└── test-assets/
    ├── environments/local.json    ← base_url = "http://127.0.0.1:8080/"
    └── load/
        ├── scenarios/
        │   ├── checkout.json      ← 场景 WL-001
        │   ├── order-query.json   ← 场景 WL-002（thresholds not_provided）
        │   └── health-check.json  ← 场景 WL-004（thresholds not_provided）
        ├── suites/LOAD-001-checkout/
        │   ├── suite.json         ← environment = "local"
        │   └── scenario.json      ← 引用 checkout + order-query + health-check
        └── plans/LOAD-001-checkout.json  ← REQ-012 的产物（入口真正读的东西）
```

#### 3.1.1 `.tools/manifest.json`（**逐字**）

```json
{
  "version": 1,
  "tools": [
    {
      "name": "loadtest",
      "kind": "node",
      "spec": "loadtest@8.2.1",
      "purpose": "压测 runner",
      "required_by": ["REQ-002.9"],
      "install": { "bun": "bun add {spec}" },
      "verify": { "command": "loadtest --version", "match": "Loadtest" }
    }
  ]
}
```

⚠️ **`match` 必须是 `"Loadtest"`（大写 L）** —— `loadtest --version` 的真实输出是 `Loadtest version: 8.2.1`
（实测）⇒ 写成小写 `"loadtest"` ⇒ `qa doctor` 判 `failed`（实测）⇒ 工具被判「不可用」⇒ D206 会拒绝执行。
（REQ-003 文档里的样例清单用的是小写，**属上游样例的一处笔误**，见 `PROBE-FACTS.md` F8。）

#### 3.1.2 验收前置（**不是夹具的一部分**，但**必须先满足**）

`loadtest` **必须已安装**到 `<项目根>/.tools/node/node_modules/loadtest/`（含 `.bin/loadtest`），
安装方式：`node <交付包>/bin/qa install --project <项目根>`（REQ-003 的 `qa-toolchain`）。

⚠️ **门本身不装工具**（与 REQ-009 / REQ-012 的「不装工具」纪律一致）⇒ 工具缺失时门**必须明确报错**（AC-033）。

### 3.2 计划产物（**逐字**规定）

`<项目根>/test-assets/load/plans/LOAD-001-checkout.json`：

```jsonc
{
  "schema_version": 1,
  "suite": "LOAD-001-checkout",
  "environment": "local",
  "scenarios": [
    {
      "scenario_id": "WL-001", "scenario_name": "checkout", "runner": "loadtest", "runtime": "node",
      "target": "POST /api/v1/checkout", "base_url": "http://127.0.0.1:8080/",
      "profile_type": "ramp-up",
      "invocations": [
        { "step_index": 0, "duration_s": 2, "concurrency": 4,
          "argv": ["loadtest","-t","2","-c","4","--cores","1","http://127.0.0.1:8080/api/v1/checkout","-m","POST"] },
        { "step_index": 1, "duration_s": 2, "concurrency": 8,
          "argv": ["loadtest","-t","2","-c","8","--cores","1","http://127.0.0.1:8080/api/v1/checkout","-m","POST"] }
      ],
      "thresholds_status": "provided",
      "thresholds": { "p95_latency_ms": 200, "error_rate": 0.01, "throughput_rps": 1, "max_concurrency": 16 },
      "thresholds_source": "capacity-targets",
      "open_questions": []
    },
    {
      "scenario_id": "WL-002", "scenario_name": "order-query", "runner": "loadtest", "runtime": "node",
      "target": "GET /api/v1/orders", "base_url": "http://127.0.0.1:8080/",
      "profile_type": "constant",
      "invocations": [
        { "step_index": 0, "duration_s": 2, "concurrency": 2,
          "argv": ["loadtest","-t","2","-c","2","--cores","1","http://127.0.0.1:8080/api/v1/orders","-m","GET"] }
      ],
      "thresholds_status": "not_provided",
      "open_questions": [ { "id": "OQ-001", "topic": "thresholds", "question": "订单查询的延迟阈值尚未确定。" } ]
    },
    {
      "scenario_id": "WL-003", "scenario_name": "checkout-staging", "runner": "python", "runtime": "python",
      "target": "POST /api/v1/checkout", "base_url": "http://127.0.0.1:8080/",
      "profile_type": "spike",
      "invocations": [
        { "step_index": 0, "duration_s": 1, "concurrency": 2,
          "argv": ["python","-c","import sys,time;time.sleep(0.05)","1","2"] }
      ],
      "thresholds_status": "not_provided",
      "open_questions": [ { "id": "OQ-003", "topic": "thresholds", "question": "staging 环境的压测阈值尚未确定。" } ]
    },
    {
      "scenario_id": "WL-004", "scenario_name": "health-check", "runner": "loadtest", "runtime": "node",
      "target": "GET /api/v1/health", "base_url": "http://127.0.0.1:8080/",
      "profile_type": "constant",
      "invocations": [
        { "step_index": 0, "duration_s": 2, "concurrency": 1,
          "argv": ["loadtest","-t","2","-c","1","--cores","1","http://127.0.0.1:8080/api/v1/health","-m","GET"] }
      ],
      "thresholds_status": "not_provided",
      "open_questions": [ { "id": "OQ-002", "topic": "coverage", "question": "健康检查是否需要单独压测尚未确认。" } ]
    }
  ]
}
```

⚠️ **夹具里的 `duration_s` 故意取小值（2 秒）** ⇒ 判据跑得完；**与 REQ-012 夹具的真实值不同是有意的**。

### 3.3 期望产物（**只列必须成立的性质，不列数值**）

⚠️ **数值随宿主而变**（压测是随机过程，D207）⇒ 判据**不许**断言具体数值，只断言**结构与口径**：

| # | 性质 |
|---|---|
| 1 | `results/LOAD-001-checkout.json` 存在，顶层**恰好 8 键**（F7.2） |
| 2 | `scenarios` 长度 == 4，顺序 == 计划顺序；`scenario_id` 逐字 == 计划的 |
| 3 | 场景 WL-001 的 `invocations` 长度 == 2（**不合并**，D190），`step_index` == 0 / 1 |
| 4 | 场景 WL-002 / WL-004 的 `thresholds` **不存在**，`thresholds_status == "not_provided"` |
| 5 | 每条 invocation 的 `executed_url` 的 **origin == `execution.stub.origin`**，**path 逐字** == 计划的 URL 的 path |
| 6 | 每条 invocation 的 `observed.total_requests > 0`（桩可达 ⇒ 一定有请求完成） |
| 7 | `observed.percentiles` 恰含 `"50"` / `"90"` / `"95"` / `"99"` 四键，值均为 **number** |
| 8 | WL-001 的 `max_concurrency` 判定条目 `verdict == "undetermined"` 且 `observed == null` 且 `reason` 非空（D189） |
| 9 | WL-001 的 `p95_latency_ms` / `error_rate` 判定条目 `verdict == "undetermined"`（默认桩，D199），`reason` 非空 |
| 10 | WL-001 的 `throughput_rps` 判定条目 `verdict == "met"`（默认桩下吞吐仍可判） |
| 11 | `verdict.undetermined_keys` 含 `"max_concurrency"` |
| 12 | `evidence/LOAD-001-checkout/` 下有 `manifest.json`，列出每个证据文件的 sha256 |
| 13 | `results_sha256` 可被第三方**复算**一致 |
| 14 | **顺序执行可核**：同套件内前一条 invocation 的 `stub_observed.last_at_ms` ≤ 后一条的 `stub_observed.first_at_ms`（无重叠） |
| 15 | **桩侧观测是本次增量**：各 invocation 的 `stub_observed.requests` 之和 ≥ 桩侧总请求数，且**没有哪条**等于累计值（即不是累计口径） |
| 16 | **`python` 场景（WL-003）**：该 invocation 的 `observed` **缺席**、`verdict == "undetermined"`；其 `thresholds` 为**空数组**（该场景无阈值）；**它仍然被执行了**（证据目录里必须有它的 `step_index` 子目录） |

---

## 4. 明确不做的事（**不许越界**）

1. **不打真实服务**（只打回环地址上的桩）。
2. **不做容量结论**（不产出「生产能扛多少」的结论）。
3. **不改 `test-execute`**、**不改 `test-report`**（不把负载级结果塞进 `report.json`）。
4. **不改 REQ-012 / REQ-009 的既有文件与契约**（不扩 `args` 白名单、不加计划字段、不改 `argv` 形态）。
5. **不重做 A 阶段**（不改计划产出逻辑，只消费）。
6. **不凭空判达标**（`undetermined` 就写 `undetermined`）。
7. **不造假桩**（桩行为无代表性 ⇒ 对应阈值判 `undetermined`，不判 `met`）。
8. **不新造 `python` runner 的输出契约**（D203）。
9. **不做多轮重试取中位**（D207）。
10. **不把负载级产物混进用例级证据链**（D191）。

---

## 5. 验收

判据见 `acceptance.md`（**AC-001~AC-0NN**）· 验收门 `verify-acceptance.sh`。
**条数守恒**：判据与决策的编号一旦发布即**不增删、不改号**。
