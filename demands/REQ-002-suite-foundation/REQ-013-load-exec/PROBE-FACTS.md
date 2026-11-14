# REQ-013 勘察事实（第一手实测，2026-11-14）

> **纪律**：以下每条都是**本机实测**或**读 `loadtest@8.2.1` 真实源码**得到的，不是文档记忆、不是推测。
> 标「实测」的是本机跑出来的；标「源码」的是读源码得到的；标「推论」的是从实测事实推导的（**推论不作为契约依据，只作为岔路候选**）。
> **别重复调研**。
>
> **实测环境**：`node v26.13.1` / `python3 3.14.10` / `loadtest@8.2.1`（装在 `~/.local/share/agent-runtime-data/tmp/req013/lt/`）
> / 勘察工装在 `~/.local/share/agent-runtime-data/tmp/req013/probe/`（`stub.mjs` 桩 · `drive-api.mjs` / `drive-api2.mjs` API 驱动 · `t-concurrency.mjs` · `t-stub-dies.mjs`）。

---

## A. 范围与已拍板边界（继承）

| # | 事实 |
|---|---|
| A1 | **只打本地桩服务，绝不打真实服务**（需求方 2026-11-14 拍板）⇒ 结论只能是「**在本地桩上**」的压测结论 |
| A2 | **产物里不得出现「生产环境容量达标」这类表述**（诚实性红线，与 REQ-009 同款） |
| A3 | **输出面必须新造**（REQ-012 勘察 H2/H3）：压测是**负载级**证据，与 `test-execute` 的**用例级**证据链结构性不兼容 ⇒ 另立契约，且**不与** `test-execute` 的 `verdict.mjs` 混用 |
| A4 | **输入面已存在**（REQ-012 勘察 H1）：REQ-009 的 `report.json`（负载模型）＋ REQ-012 的 `plans/*.json`（命令清单）⇒ B 阶段**不必新造输入契约** |

---

## B. `loadtest@8.2.1` 的**执行面**事实（**REQ-012 未勘察过的部分**）

> ⚠️ REQ-012 勘察的是「**CLI 参数**面」；本组勘察的是「**执行与结果**面」—— 两面结论不同。

| # | 事实 | 出处 |
|---|---|---|
| **B1** | ⭐ **CLI 没有 JSON 输出选项**：`bin/loadtest.js` 的 `stdio.getopt` 参数表里**没有任何** `--json` / `--output` / `--file`；结果只能 `showResults()` **打印成文本**到 stdout | 源码 `bin/loadtest.js` + `lib/result.js:128` |
| **B2** | ⭐ **但包提供 API**：`index.js` 导出 `{loadTest, startServer}`；`loadTest(options, callback)` 的回调**直接给结构化 `Result` 对象** ⇒ **不必解析 stdout** | 源码 `index.js` / `lib/loadtest.js:36` / `index.d.ts` |
| **B3** | ⭐ **API 的选项名与 CLI 的选项名不是一套**：API 用 `maxSeconds` / `concurrency` / `requestsPerSecond` / `agentKeepAlive` / `timeout`；CLI 用 `-t` / `-c` / `--rps` / `-k` / `-d` | 源码 `lib/options.js:20-46` vs `bin/loadtest.js` 的 getopt 表 |
| **B4** | ⭐ **API 路径没有 `cores` 概念**：`cores` 是 CLI 的 **cluster 分 worker** 机制（`bin/loadtest.js` 的 `runTask(options.cores, …)` → `cluster.fork()`）；`--cores 1` 时**不 fork**（`lib/cluster.js:14`），API 路径则**根本没有这个层** ⇒ **API 天然等价于 `--cores 1`** | 源码 `lib/cluster.js:13-23` |
| **B5** | ⭐⭐ **不设 `statusCallback` ⇒ HTTP 错误状态码全部塌成 `-1`**：`createResult()` 在 `statusCallback` 与 `contentInspector` **都没设**时返回 `null` ⇒ `finishRequest()` 走 `errorCode = '-1'` 分支 ⇒ 真实状态码（500/404/…）**全部混成一个桶** | 源码 `lib/httpClient.js:196-206, 233-234, 244-247` |
| **B6** | ⭐⭐ **设了 `statusCallback` ⇒ 错误码按真实状态码分类**：实测 `statusCallback` 一设，`errorCodes` 从 `{"-1": N}` 变成 `{"500": N}`；回调**每个请求**都被调用一次 | 实测 + 源码 `lib/httpClient.js:244` |
| **B7** | ⭐⭐ **CLI 路径无法获得 B6 的能力**：CLI 的 getopt 表里**没有** `statusCallback` ⇒ 走 CLI 只能拿到 `-1` 桶 ⇒ **错误码分类能力是 API 路径独有的** | 源码 `bin/loadtest.js` |
| **B8** | ⚠️ **更正 REQ-012 勘察 C12 的一个错误**：`errors` 这个字段名**不存在**；真实字段名是 **`errorCodes`**（按状态码 → 次数）。`errors` 是 REQ-012 勘察文档的笔误 ⇒ REQ-013 的契约必须用 `errorCodes` | 源码 `lib/result.js:25` / `lib/latency.js:27` |
| **B9** | `Result` 对象的**实测字段全集**（23 个）：`accumulatedMs` / `agent` / `clients` / `concurrency` / `cores` / `effectiveRps` / `elapsedSeconds` / `errorCodes` / `histogramMs` / `instanceIndex` / `maxLatencyMs` / `maxRequests` / `maxSeconds` / `meanLatencyMs` / `minLatencyMs` / `percentiles` / `requestsPerSecond` / `rps` / `startTimeMs` / `stopTimeMs` / `totalErrors` / `totalRequests` / `totalTimeSeconds` / `url` | 实测（`Object.keys(result).sort()`） |
| **B10** | `percentiles` 实测是 `{50: <number>, 90: <number>, 95: <number>, 99: <number>}`；**分位键恒为这 4 个**（`50/90/95/99`），`false` 初始值只在**没有任何请求**时残留 | 实测（4 次运行，`percentiles_types` 全 `number`） |
| **B11** | `effectiveRps` 与 `rps` 是**同一个值**（`rps` 是 backwards-compatibility 别名）⇒ 用哪个都行，但**产物里只能留一个**（避免「两个名字同一数字」的糊账） | 源码 `lib/result.js:62-63` |
| **B12** | ⚠️ **API 也会读 `.loadtestrc`**：`processOptions()` 里无条件 `loadConfig()`（confinode）⇒ 即便走 API，**宿主目录下的 `.loadtestrc` 仍会渗进配置**（`concurrency` / `requestsPerSecond` / `method` / `headers` / `timeout` / `proxy` …）⇒ **执行器必须防这一手**（显式覆盖每个相关字段 + 拒绝 `proxy`） | 源码 `lib/options.js:19, 20-45` + `lib/config.js` |
| **B13** | `options.timeout` 的单位是**毫秒**（单请求超时）⇒ 与 REQ-012 的 `-d <秒×1000>` **同单位** ⇒ 反解无换算风险 | 源码 `lib/options.js:44` / `bin/loadtest.js` 的 `-d` 描述 |

---

## C. **执行实测**（本机真跑，桩 + loadtest）

> 桩（`stub.mjs`）：node 内置 `http`，监听 `127.0.0.1`，支持**请求计数** / **延迟注入**（`?delay_ms=`）/ **错误注入**（`?status=`）/ 观测端点 `/__stats`（含按 ms 桶的**直方图**聚合）。

| # | 事实 | 实测数据 |
|---|---|---|
| **C1** | ⭐⭐ **客户端侧与桩侧的请求数天然不相等，差额 ≈ 并发数**：loadtest `totalRequests=14376` vs 桩侧 `total=14386`，**差 10**，而本次并发正是 **10** | 3s / 10 并发实测 |
| **C2** | ⇒ **不能用「桩侧计数 == loadtest totalRequests」做等式判定**；差异来自**在途请求**（桩已收、客户端已被取消）⇒ 判定只能允许**有界偏差**或分别记录两侧 | 由 C1 直接得出（**实测**） |
| **C3** | ⭐ **两侧的「延迟」语义不同**：桩侧量的是**服务端处理耗时**（实测注入 50ms ⇒ 桩侧 max 51.7ms、loadtest 侧 mean 55ms）；loadtest 侧量的是**客户端 RTT**（注入 50ms + 约 5ms 往返开销）⇒ **不可混为一谈** | 注入 50ms 实测 |
| **C4** | ⭐⭐ **全部失败时 `effectiveRps` 依然很高**：桩不存在（连接被拒）⇒ `totalRequests=11504` / `totalErrors=11504` / `effectiveRps=5752` ⇒ **`throughput_rps` 单独判会得出「吞吐很高」** ⇒ **必须与 `error_rate` 联合判** | 连接被拒实测 |
| **C5** | ⭐⭐ **桩中途挂掉 ⇒ loadtest **不抛错、退出码仍是 0**：跑动中 `SIGKILL` 桩 ⇒ 驱动进程 rc=0、`totalErrors=13573` / `totalRequests=21751`（62% 错误）⇒ **判定不能只看进程退出码** | `t-stub-dies.mjs` 实测 |
| **C6** | ⭐ **连接层错误统一是 `-1`**（`errorCodes: {"-1": N}`）；与 B6 合并后：`-1` = 连接失败桶，真实状态码 = HTTP 错误桶 | 实测（连接被拒 / 桩被 kill 两组） |
| **C7** | **两套独立桩实例并发跑 ⇒ 计数零交叉**：桩1 `total=6551`（只含 `/api/v1/a`）、桩2 `total=6086`（只含 `/api/v1/b`），两个驱动 rc=0 ⇒ **「每实例独立桩 + 端口 0 随机分配」天然隔离** | `t-concurrency.mjs` 实测 |
| **C8** | **桩进程会残留**：手工 `node stub.mjs &` 起桩 ⇒ 跑完后桩进程**仍存活**（实测 2 个残留 `node stub.mjs`）⇒ **桩的生命周期必须由执行器管**（起停 + 收尾），不能靠人工 | `ps` 实测 |
| **C9** | **桩侧延迟若逐条存储 ⇒ 产物爆炸**：首版桩把每次延迟存进数组 ⇒ 1.4 万次请求产出**十万级字符**的观测输出 ⇒ 观测**必须聚合**（直方图 / 分位数），不能存全量样本 | 首版实测（输出被截断） |
| **C10** | **API 路径跑完进程**及时退出**（无子进程残留）**：`maxSeconds=3` ⇒ 墙钟 3009ms 后进程结束；`maxRequests` 模式下亦然 ⇒ **API 路径不产生需要 kill 的子进程**（与「spawn CLI 需清理」相反） | 实测（`wall_ms` 与退出） |
| **C11** | **小样本也能算出分位**：`maxRequests=5` ⇒ `percentiles={50:2, 90:10, 95:10, 99:10}`，全为 number ⇒ 「样本太少 ⇒ 分位不可用」**不成立**（至少 1 个请求即有值） | 实测 |

---

## D. **上游既有契约**的事实（不重复调研）

| # | 事实 | 出处 |
|---|---|---|
| **D1** | REQ-012 的 `argv` **规范形态是封闭且可机械反解的**：`["loadtest","-t",<秒>,"-c",<并发>,"--cores","1",<完整绝对 URL>,"-m",<METHOD>]` + 可选 `["--rps",V]` `["-k"]` `["-d",<毫秒>]`（各至多一次、按此顺序） | REQ-012 `references/runner-adapters.md` §4.1 |
| **D2** | REQ-012 的 `argv` 里的 URL = **环境文件的 `base_url` 去尾斜杠 + 路径** ⇒ 指向**真实服务地址** ⇒ **B 阶段必须把 origin 换成桩地址**（path 逐字保留） | 同上 §4.2 |
| **D3** | REQ-012 的 `args` **白名单**：`loadtest` runner 只认 `rps` / `keepalive` / `timeout_s` / `method`；`python` runner 只认 `command`；**未知键拒绝**（rc=1 + 点名） | 同上 §4.3 |
| **D4** | ⚠️⭐ **负载模型里没有任何地方能表达「桩的行为」（延迟/错误注入）**：REQ-009 场景顶层**封闭 14 键**，无桩行为字段；`args` 是开放键值但被 D3 的白名单限死 ⇒ **B 阶段若要「不造假桩」，桩行为配置必须另辟来源**（**这是新发现的契约缺口**） | REQ-009 `acceptance.md` AC-009 + REQ-012 §4.3 |
| **D5** | `python` runner 的 `args.command` 只钉了**命令形态**，**没钉输出形态** ⇒ B 阶段拿到 `python` 命令的 stdout **无契约可依** ⇒ **只能判「不可判定」**（除非本 REQ 另行约定输出契约） | REQ-012 §5 |
| **D6** | ⭐ **`test-report` 的 `report.json` 顶层是封闭的**（`schema_version` / `generated_at` / `source` / `cases` / `verdict` / `failures` / `evidence` / `regression` / `report_sha256`），且 `cases` / `regression` 段**键集封闭**、顶层**只允许 `schema_version` 一个数字型叶子字段** ⇒ **负载级结论塞不进 `report.json`** ⇒ REQ-013 的产物**必须独立**（改 REQ-010 的 schema 属改上游契约 ⇒ 越界） | REQ-010 `references/report-schema.md` §1、§3 |
| **D7** | `qa-toolchain` 的清单里**已有 `loadtest`**：`kind=node` / `spec=loadtest@8.2.1` / `install={"bun":"bun add {spec}"}` / `verify={"command":"loadtest --version"}`；执行时 **PATH 前缀** = `.tools/bin` · `.tools/.venv/bin` · `.tools/node/node_modules/.bin` | REQ-003 `references/tools-chain-contract.md` L75-81, L185-186 |
| **D8** | ⇒ **本机当前 `loadtest` 不在 PATH**（实测 `which loadtest` 为空）⇒ **执行器必须先确认工具可用**（`qa doctor` / `verify`），不可用 ⇒ **明确报错**，不得假装压过 | 实测 `which loadtest` |
| **D9** | `qa-toolchain` 的 `node` 路线装到 **`.tools/node/node_modules/`** ⇒ **模块路径可解析**（`.tools/node/node_modules/loadtest/index.js`）⇒ **API 路径可用绝对路径 `import`**（不依赖 PATH） | 同上（由 L38-39 的目录树推得） |

---

## E. **阈值键 → 观测量**的映射（**可机械核**的部分）

> REQ-009 阈值键白名单**封闭 6 个**：`p50_latency_ms` / `p95_latency_ms` / `p99_latency_ms` / `error_rate` / `throughput_rps` / `max_concurrency`。

| 阈值键 | 观测量（`Result` 字段） | 判定口径 | 可机械核 |
|---|---|---|---|
| `p50_latency_ms` | `percentiles["50"]` | 观测 ≤ 阈值 ⇒ 达标 | ✅ |
| `p95_latency_ms` | `percentiles["95"]` | 同上 | ✅ |
| `p99_latency_ms` | `percentiles["99"]` | 同上 | ✅ |
| `error_rate` | `totalErrors / totalRequests` | 观测 ≤ 阈值 ⇒ 达标 | ✅（`totalRequests == 0` ⇒ **不可判定**） |
| `throughput_rps` | `effectiveRps` | 观测 ≥ 阈值 ⇒ 达标 | ⚠️ **必须与 `error_rate` 联合判**（见 C4：全失败时 throughput 反而高） |
| `max_concurrency` | **无对应观测量** | — | ❌ ⇒ **判「不可判定」**（REQ-012 勘察 H5 已预警） |

⚠️ **`max_concurrency` 的处置**（REQ-012 H5 给的两条路：换工具 / 判不可判定）：
`Result` 里与并发相关的只有**配置值** `concurrency` 与**客户端数** `clients`（实测 `clients == concurrency == 10`），
**都不是「实际达到的并发」**（它们是「打算并发多少」）；
真实并发取决于**服务端并行处理能力**，而**桩的服务端处理耗时不可从客户端侧推断** ⇒
**换工具也未必解决**（除非工具直接报服务端并发度）⇒ 倾向**判「不可判定」**。

---

## F. 本组勘察**新发现**的缺口（**必须在契约里落定，否则实现方只能猜**）

| # | 缺口 | 影响 |
|---|---|---|
| **F1** | **桩行为配置无来源**（D4）：延迟注入 / 错误注入 / 响应形态 —— **没有契约位置** | 不解决 ⇒ 桩恒 200/0 延迟 ⇒ 阈值判定在判一个「假世界」（H6 的红线） |
| **F2** | **argv（CLI 形态）→ API 选项（另一套名字）需要一层反解**（B3/D1） | 不解决 ⇒ 执行器要么解析 stdout（脆弱）要么「反解不完整 ⇒ 语义悄悄变了」 |
| **F3** | **执行的是 API 等价物，不是 argv 里那个命令**（B2/B4） | 不解决 ⇒ 产物里的 `argv` 与**真实执行的东西**不一致 ⇒ 不可证伪 ⇒ **诚实性问题** |
| **F4** | **`.loadtestrc` 渗透风险**（B12） | 不解决 ⇒ 同一份计划在不同宿主目录下跑出不同结果 ⇒ 幂等性破 |
| **F5** | **`python` runner 的输出形态无契约**（D5） | 不解决 ⇒ `python` 场景的判定只能恒为「不可判定」 |
| **F6** | **桩进程生命周期归属**（C8） | 不解决 ⇒ 桩残留 ⇒ 端口占用 ⇒ 后续套件起不来 |
| **F7** | **判定不得依赖进程退出码**（C5/C4） | 不解决 ⇒ 桩挂了也「成功」⇒ 假绿 |
| **F8** | ⭐⭐ **REQ-003 的 `qa-toolchain` 契约文档里，样例清单的 `verify.match` 大小写与 `loadtest` 的真实输出不匹配**：实测 `loadtest --version` 输出 **`Loadtest version: 8.2.1`**（**大写 L**），而文档样例写 `"match": "loadtest"`（**小写**）⇒ 按样例抄 ⇒ `qa install` 报「验证未通过」、`qa doctor` 判 `failed`（实测 rc=1）⇒ **工具被误判为不可用** ⇒ 直接阻塞 D206 | 改用 `"match": "Loadtest"` ⇒ `qa doctor` 全绿（实测 rc=0）。**这是上游样例的一处笔误**，机制本身没问题 |
| **F9** | **工具链装得上**：`bun 1.4.4` 可用；`node <交付包>/bin/qa install --project <项目根>` ⇒ `loadtest@8.2.1` 落到 `.tools/node/node_modules/loadtest/`（含 `.bin/loadtest`），耗时 ~1s | 实测（F8 的修正版） |

---

## G. 待裁定的岔路（**需求方拍板，不由实现方猜**）

| # | 岔路 | 候选项（勘察已给出事实依据） |
|---|---|---|
| **G1** | 是否新增 skill 目录 | 仍在 `load-profile` 内加第二个入口 / 新增独立 skill（**D5/D6 说明产物形态与用例级完全不同，但 skill 归属是另一回事**） |
| **G2** | 负载级产物的落点与命名 | `test-assets/load/results/<套件>.json` 及其它候选 |
| **G3** | 桩服务归属 | 进交付包（`skills/` 下）/ 只作过程件 / 两者分工 |
| **G4** | 阈值来源 | 直接吃 REQ-009 的 `report.json`（模型里逐字携带的 `thresholds`）/ 独立配置 |
| **G5** | `max_concurrency` 的处置 | 换工具 / 判「不可判定」/ 换键（**E 组已给出：无可用观测量 ⇒ 换工具也未必解决**） |
| **G6** | 判定粒度 | 按 invocation 判 / 按 suite 判 / 两者都要 |
| **G7** | 与 `test-execute` 的边界 | 是否允许同一套件里混用例级与负载级（**D6 说明 `report.json` 装不下 ⇒ 天然分家**） |
| **G8** | ⭐ **执行方式**（F2/F3） | (a) **API 驱动**（结构化 `Result` + 可设 `statusCallback` + 天然单 worker）· (b) **spawn CLI**（只能拿 `-1` 桶 + 要解析 stdout）· (c) 两者都支持 |
| **G9** | ⭐ **桩行为配置的来源**（F1） | (a) **独立桩配置文件**（新增契约位置）· (b) 扩展 `args` 白名单（**改 REQ-012 上游契约 ⇒ 越界**）· (c) 执行器内建默认（⇒ 恒 0 延迟 / 0 错误 ⇒ 判「假世界」） |
| **G10** | ⭐ **桩的 origin 替换规则**（D2） | 只换 origin 保留 path / 换整条 URL / 其它 |
| **G11** | ⭐ **「不可判定」的判定集合** | 哪些情形判不可判定（`max_concurrency` · `python` runner · `totalRequests==0` · 桩缺失 …） |
| **G12** | ⭐ **桩的归属与生命周期**（F6/C7/C8） | 每套件一个独立桩实例（端口 0）/ 每场景一个 / 由执行器统一托管 |

---

## H. **别重复调研**清单

- `loadtest` 的 **CLI 参数表** ⇒ REQ-012 `PROBE-FACTS.md` C 组已全（**别再读一遍**）；
- `loadtest` 的 **源码获取方式** ⇒ `npm pack loadtest@8.2.1` 解包即可（B/C 组的结论都出自这里）；
- REQ-009 的**负载模型字段集** ⇒ REQ-012 F 组（F1/F2/F7）已给；
- REQ-012 的 **argv 规范形态 / args 白名单 / 写入纪律** ⇒ REQ-012 `runner-adapters.md`（D1/D2/D3 已转述）；
- `test-execute` 的**用例级证据链** ⇒ REQ-012 E 组（E5/E6/E7）已给；
- `test-report` 的 **`report.json` schema** ⇒ D6 已转述，**别再全读**。
