# REQ-012 勘察事实（第一手实测，2026-11-14）

> **纪律**：以下每条都是**实测/读源码**得到的，不是文档记忆。
> 标「实测」的是本机跑出来的；标「源码」的是读 `loadtest@8.2.1` 的真实源码得到的。
> **别重复调研**。

---

## A. 范围决策（需求方 2026-11-14 已拍板）

| 项 | 裁定 |
|---|---|
| 分两步走 | **REQ-012 = A 阶段**「规划产物可被真实压测工具消费」；**REQ-013 = B 阶段**「负载级执行与判定链」 |
| 执行目标 | **只打本地桩服务，绝不打真实服务**（B 阶段的硬约束；A 阶段不执行任何请求，但契约要预留该约束位） |

---

## B. 架构定位（`BA/demands/REQ-002-suite-foundation/architecture-design.md`）

| # | 事实 | 出处 |
|---|---|---|
| B1 | 架构 §8 需求清单里 **`REQ-002.9` = `load-profile` skill（负载模型 + runner 适配）**，依赖 002.4 | `architecture-design.md` L733 |
| B2 | 架构 L628 原文：「建议 `load-profile` skill **生成负载模型 → 由执行器适配**：`load-scenario.json` 加一个 `runner` 字段（`loadtest` / `python`）区分即可，**skill 本身不绑定工具**」 | 同上 |
| B3 | 架构 §8 的子 REQ 清单（002.1~002.10）**全部已交付**（映射到 REQ-002A/002B/002.5a/002.5b/REQ-005~REQ-011）⇒ **架构里没有为「load 执行器」单列条目** | 同上 L723~L740 |
| B4 | ⇒ **REQ-012 是 `load-profile` skill 的延续**（补 REQ-002.9 描述里「runner 适配」那半边），**不是新 skill** ⇒ 改 `skills/load-profile/`，不新增 skill 目录 | 由 B1+B2+B3 推导 |

---

## C. `loadtest@8.2.1` 真实参数（**源码级**，非记忆）

> 取得方式：`npm pack loadtest@8.2.1` 解包，读 `bin/loadtest.js` + `lib/options.js` + `lib/result.js`。

| # | 事实 |
|---|---|
| C1 | 包存在、bin = `loadtest`（+ `testserver-loadtest`），`engines.node >= 16`，依赖 `agentkeepalive` / `confinode` / `https-proxy-agent` / `stdio` / `testing` / `websocket` |
| C2 | **CLI 参数表（`bin/loadtest.js` 的 `stdio.getopt` 逐字）**：`-t`=maxSeconds 秒 · `-n`=maxRequests 请求数 · `-c`=concurrency 并发 · `-d`=timeout **单请求毫秒** · `-T`=contentType · `-C`=cookies(multiple) · `-H`=headers(multiple) · `-P`=postBody · `-p`=postFile · `-A`=patchBody · `-a`=patchFile · `--data`=data · `-m`=method · `-u`=putFile · `-R`=requestGenerator · `-r`=recover · `-s`=secureProtocol · `-k`=keepalive · `-V`=version · `--proxy` · `--rps` · `--index` · `--insecure` · `--key` · `--cert` · `--quiet` · `--cores` · `--tcp` · `--agent`(deprecated) · `--debug`(deprecated) |
| C3 | **URL 是唯一位置参数**（`options.args[0]`）；多于一个 ⇒ `Too many arguments` 报错退出 ⇒ **适配器必须拼出完整 URL**（`base_url` + path） |
| C4 | **URL 必须是** `http://` / `https://` / `ws://` / `wss://` 开头，否则 `Invalid URL` 抛错 |
| C5 | **`-t`（maxSeconds）与 `-n`（maxRequests）都能单独驱动**：`lib/options.js` 里「两个都没给 ⇒ `maxSeconds = 10`」；`lib/loadtest.js` 里 `maxSeconds` 起 `setTimeout` 停表 |
| C6 | **`--rps` 是「每个客户端」的 rps**（`options.js` 里 `requestsPerSecond`；`bin/loadtest.js` 里 `options.rps = shareOption(options.rps, workerId, options.cores)` —— 多核时按核数分摊） |
| C7 | **`-c` 并发与 `--rps` 可并存**（README 原文示例：`loadtest -c 10 --rps 200 URL`） |
| C8 | `keepalive` 来源：`options.keepalive \|\| options.agent \|\| options.agentKeepAlive \|\| configuration.agentKeepAlive` |
| C9 | `method` 默认 `GET`；可接受 `GET/POST/PUT/DELETE/PATCH`（及小写） |
| C10 | `timeout` 是**单请求超时**（毫秒），不是压测总时长 ⇒ 与 `duration_s` **不是一回事**，映射时不能混 |
| C11 | **配置文件**：`.loadtestrc`（`confinode` 加载）⇒ 键名与 CLI 同名（`concurrency` / `requestsPerSecond` / `agentKeepAlive` / `method` / `headers` / `maxRequests` / `maxSeconds` / `cookies` / `contentType` / `timeout` / `secureProtocol` / `insecure` / `recover` / `proxy` / `quiet` / `indexParam` / `requestGenerator`） |
| C12 | **结果形态**（`lib/result.js`）：`totalRequests` / `totalErrors` / `meanLatencyMs` / `effectiveRps`（另有别名 `rps` = backwards compatibility）/ `percentiles`（含 `50`/`90`/`95`/`99` 等键）/ `errors`（按状态码分布）/ `elapsedSeconds` |
| C13 | `percentiles` 的键是**百分数字符串**（`'50'` / `'95'` / `'99'`…），不是 `p95_latency_ms` 那种形态 |
| C14 | **多核**：`--cores` 默认 `getHalfCores()`；`bin/loadtest.js` 里 `options.maxRequests` 与 `options.rps` 都经 `shareOption(..., workerId, cores)` **按核分摊** |
| C15 | 支持 **WebSocket**（`ws://`/`wss://`），但 `ws` + `requestsPerSecond` ⇒ 抛错 |

---

## D. 适配器的核心技术矛盾（**这是 REQ-012 的设计核心**）

| # | 矛盾 | 事实依据 | 后果 |
|---|---|---|---|
| D1 | **多段画像 vs 单段 CLI** | 我们的 `profile.steps[]` 是**多段**（ramp-up = 60s@10c + 120s@20c）；`loadtest` 的 `-t`/`-c` 是**单段** | **一个 step 一条命令**（多次调用），或**降级成单段**（丢信息 ⇒ 不行） |
| D2 | **并发 vs RPS 是两个维度** | `profile.steps[].concurrency` 是并发；`args.rps` 是速率 | 二者**分别映射**到 `-c` 与 `--rps`，**不能互相替代** |
| D3 | **URL 缺 base_url** | 场景里只有 `target`（`"POST /api/v1/checkout"` 形态）与 `environment`（环境**名**）；完整 URL 要环境文件里的 `base_url` | 适配器**必须读** `test-assets/environments/<env>.json` 的 `base_url`（**只读**，不改） |
| D4 | **`target` 含方法** | `target` = `"METHOD /path"`（REQ-009 已钉） | 方法 ⇒ `-m`；路径 ⇒ URL 的 path 部分 |
| D5 | **`args` 是开放键值、原样透传**（REQ-009 `load-context-schema.md` L73） | 「RPS 之类的 runner 参数走 `args`」 | 适配器要把 `args` **映射到具体工具参数**；**未知键怎么办**是契约要定的（拒绝？还是透传？） |
| D6 | **`timeout_s` ≠ `-d`** | `args.timeout_s` 是**秒**；`-d` 是**毫秒**且是**单请求**超时 | **单位换算 + 语义澄清**（秒→毫秒）——极易搞错，契约必须钉死 |
| D7 | **`python` runner 是什么** | REQ-009 钉 `tool.runner ∈ {loadtest, python}`、`tool.runtime ∈ {bun, python, node}` | `python` runner 的**命令形态**没有统一事实 ⇒ 契约要么钉死一种、要么要求由 `args` 声明 |
| D8 | **多核分摊会改语义** | `--cores` 默认半核；`maxRequests`/`rps` 按核分摊 | 适配器若显式给 `-c`/`--rps`，语义随核数变 ⇒ **要么显式钉 `--cores 1`**，要么在产物里**记下**核数影响 |

---

## E. 上游 `test-execute` 的既有事实（不重复调研）

| # | 事实 |
|---|---|
| E1 | `executors/index.json` 的 `not_implemented = ["ui","load","security"]`；**`load` 至今未实现** |
| E2 | `run-suite.mjs` 选中未实现的执行器 ⇒ **抛错并列出已注册的执行器**（不静默、不假装） |
| E3 | `resolveDriverName` 优先级：**环境 `driver` > `suite.executor`** ⇒ 环境写合法枚举的 `driver` 会**覆盖** `executor`（REQ-009 AC-020 判的就是这个） |
| E4 | 执行器契约 `references/executor-spec.md`：**观察与判定分离**（执行器只报 observed，不判 passed/failed）；判定规则是**数据**（`steps[].expected` 里的断言对象） |
| E5 | 证据链是**用例级**：`meta.json`（`cases_total` / `cases_passed` …）+ `results.json`（逐条 `case_id`/`status`）+ `evidence/<用例 ID>/` |
| E6 | `verdict.mjs` 的 `status` 枚举固定四值：`passed` / `failed` / `blocked` / `skipped` |
| E7 | ⇒ **压测是负载级**（一条链路 × N 并发 × T 时长，无单条用例、无断言）⇒ **与 E5/E6 的用例级证据链结构性不兼容** ⇒ 这正是 B 阶段要另立契约的原因 |

---

## F. REQ-009 侧的既有契约（REQ-012 不得推翻）

| # | 事实 | 出处 |
|---|---|---|
| F1 | 场景顶层**封闭 14 个**：`schema_version`/`id`/`name`/`service`/`target`/`environment`/`profile`/`thresholds`/`thresholds_source`/`thresholds_status`/`tool`/`args`/`traceability`/`open_questions` | REQ-009 `acceptance.md` AC-009 |
| F2 | `profile` 封闭 2：`type`（5 值）+ `steps`；`steps[]` 元素封闭 2：`duration_s`（整数 ≥1）+ `concurrency`（整数 ≥1）；**顺序逐字保留**，不排序不归并 | REQ-009 `references/profile-rules.md` §1 |
| F3 | `profile.type` ∈ `constant`/`ramp-up`/`ramp-down`/`spike`/`soak` | 同上 |
| F4 | `tool` 封闭 2：`runner` ∈ {`loadtest`,`python`} + `runtime` ∈ {`bun`,`python`,`node`} | REQ-009 `load-context-schema.md` |
| F5 | `args`：**开放键值，原样透传**；RPS 之类的 runner 参数走 `args` | 同上 L73 + `profile-rules.md` L24 |
| F6 | 产物根 `<out-dir>/test-assets/load/`；顶层 `report.json`（封闭 5）+ `scenarios/` + `suites/` | REQ-009 §0.5 / AC-009 ⑥ |
| F7 | `thresholds` 键白名单 6 个：`p50_latency_ms`/`p95_latency_ms`/`p99_latency_ms`/`error_rate`/`throughput_rps`/`max_concurrency` | REQ-009 `profile-rules.md` |
| F8 | `target` 形态 = `"METHOD /path"`（大写方法 + 空格 + 路径） | REQ-009 夹具 + AC-006 V7 |
| F9 | REQ-009 **明确不做**：不装工具、不执行 runner、不联网、不写 `cases.json`、不扩方法库、不创建/修改环境配置 | REQ-009 `demand.md` F1.7 |
| F10 | `qa-toolchain` 的工具声明形态（`.tools/manifest.json` 的 `kind`/`spec`/`verify`）与 `loadtest@8.2.1` 的样例 | `skills/qa-toolchain/references/tools-chain-contract.md` L75~L81 |

---

## G. 待裁定的设计岔路（**需求方拍板，不由实现方猜**）

| # | 岔路 | 可选项 |
|---|---|---|
| G1 | **产物形态**：适配结果长什么样？ | (a) 每套件一个**命令清单** JSON（`{runner, invocations:[{argv, duration_s, concurrency}]}`）· (b) 可执行 shell 脚本 · (c) 两者都要 |
| G2 | **落点**：写在哪？ | (a) `test-assets/load/plans/`（load 能力域内）· (b) 独立目录 |
| G3 | **多段怎么落**：多段画像怎么表达成单段工具调用？ | (a) 每 step 一条 invocation（**无损**）· (b) 合并成一条（**有损**） |
| G4 | **`args` 未知键**怎么处理？ | (a) 拒绝（rc=1）· (b) 忽略并记未决问题 · (c) 透传 |
| G5 | **多核**：`--cores` 钉不钉？ | (a) 钉 `--cores 1`（语义确定）· (b) 跟随默认并在产物里记录 |
| G6 | **`python` runner**：命令形态怎么定？ | (a) 契约钉死一种具体形态 · (b) 要求由 `args` 显式声明完整命令 |
| G7 | **是否要门**：REQ-012 要不要独立验收门 + 判据？ | (a) 要（沿用 REQ-009 模式）· (b) 简化 |

---

## H. B 阶段（REQ-013）的边界勘察（**顺手做掉，开单时不用重查**）

| # | 事实 |
|---|---|
| H1 | **B 阶段的输入面已存在**：REQ-009 的 `report.json` 顶层 5 键 = `schema_version`/`service`/`suites`/`scenarios`/`open_questions`；`suites[]` 元素 = `{suite, requirement, environment, scenarios:[{id,name,path}]}`；`scenarios[]` 元素 = `{id,name,path,environment,suite,thresholds_status}`；`open_questions[]` = `{id,topic,question}` ⇒ **B 阶段不必新造输入契约** |
| H2 | **B 阶段的输出面必须新造**：压测是**负载级**（PROBE-FACTS E7）⇒ 与 `test-execute` 的**用例级**证据链（`meta.json` 的 `cases_*` 计数 / `results.json` 的逐条 `case_id` / `evidence/<用例 ID>/`）**结构性不兼容** ⇒ B 阶段**不能**把压测结果塞进 `results.json` |
| H3 | ⇒ B 阶段必须**另立一套负载级产物与判定契约**（如 `test-assets/load/results/<套件>.json` + 阈值判定 + 证据目录），并**明确不与** `test-execute` 的 `verdict.mjs` 混用 |
| H4 | **阈值判定的现实**：loadtest 的结果形态（PROBE-FACTS C12/C13）是 `percentiles.{'50','95','99'}` + `meanLatencyMs` + `effectiveRps` + `errors`（按状态码）⇒ **与 REQ-009 的阈值键白名单**（`p95_latency_ms`/`error_rate`/`throughput_rps`/`max_concurrency`…）**可以机械映射** ⇒ B 阶段的判定器**有事实支撑**，不是凭空设计 |
| H5 | ⚠️ 但 `max_concurrency` **不是** loadtest 的输出项（它不报实际达到的最大并发）⇒ 该阈值键在 B 阶段**可能无对应观测量** ⇒ **要么 B 阶段换工具、要么该键在 B 阶段判「不可判定」**（不得凭空判达标） |
| H6 | B 阶段**只打本地桩服务**（需求方 2026-11-14 裁定）⇒ 桩服务要能**观测**（请求计数 / 延迟分布），否则「压了」不可证 ⇒ B 阶段的桩必须自带计数与延迟注入能力（参考 `test-execute/executors/mock-endpoints.json` 的 `/slow?ms=N` 思路） |
| H7 | B 阶段**不发真实流量** ⇒ 结论只能是「**在本地桩上**的压测结论」⇒ 产物里**不得**出现「生产环境容量达标」这类表述（诚实性红线，与 REQ-009 同款） |

---

## I. 潜在破坏点的实测排除（REQ-012 开工前必查）

| # | 事实 | 实测方式 | 结果 |
|---|---|---|---|
| I1 | ⭐ **`test-assets/load/plans/` 新目录对上游 `verify-layout.mjs` 无影响** | 造一个含 `test-assets/load/{scenarios,suites,plans}` + `environments/` + `cycles/` + `.gitignore` 的项目根，实跑 `node skills/test-case-design/scripts/verify-layout.mjs <根>` | **`结论: 0 FAIL / 8 OK`**，rc=0；上游**只递归找 `suite.json`**（plans/ 下没有 ⇒ 不被当成套件），且**不拦 `test-assets/` 下的未知子目录** ⇒ REQ-012 的落点裁定 G2（`test-assets/load/plans/`）**不破坏上游契约** |
| I2 | 上游对 `suite.json` 的**顶层字段集封闭**（`SUITE_ALLOWED_FIELDS` 9 个）⇒ REQ-012 的**计划产物不得叫 `suite.json`**（否则会被当成套件且字段集违规） | 读 `verify-layout.mjs` L481 | ⇒ 计划文件名必须是 `plans/<套件名>.json`（**不是** `suite.json`） |
| I3 | REQ-009 的门对 `skills/load-profile/` **只检查既有文件「存在且非空」** ⇒ REQ-012 **新增**文件到该目录**不会**让 REQ-009 的门判红 | 读 REQ-009 `verify-acceptance.sh` AC-001 段（L1238~L1243） | ⇒ REQ-012 可安全新增 `plan-load-run.mjs` / `check-load-run.mjs` / `lib/` 模块 / `references/` |
| I4 | 但 REQ-009 的门**也检查脚本的可执行位与首行 shebang** ⇒ REQ-012 的新脚本**必须**同样合规（`#!/usr/bin/env node` + 可执行 + `node --check` 通过），否则会被 REQ-009 的门判红 | 同上 | ⇒ 新脚本的**首行必须是 shebang**、**权限 755** |

## J. REQ-012 交付物对既有门的实测兼容性（**已坐实，不用等 Dev 才发现**）

| # | 事实 | 实测方式 | 结果 |
|---|---|---|---|
| J1 | ⭐ **REQ-012 新增 `plan-load-run.mjs` / `check-load-run.mjs` 不会让 REQ-009 的门判红** | 造一个模拟包（复制 `code/` 的 skills+bin+README+LICENSE+package.json，**新增**两个 755 + shebang 的脚本），实跑 REQ-009 的门 | **AC-001 PASS**（结构合法）、**AC-002 PASS**（`requires` 仍恰为两个键）⇒ 其它 27 条亦全绿 ⇒ **29 PASS / 0 FAIL** |
| J2 | ⚠️ REQ-009 门的 **AC-029** 判 `feature-meta/` 下**四件套齐全非空** ⇒ **模拟包必须带 `feature-meta/`**（第一次模拟包漏了 ⇒ AC-029 FAIL，**与 REQ-012 无关**） | 同上（补上 `feature-meta/` 后复跑） | ⇒ **REQ-012 交付时必须带 `feature-meta/load-runner/` 四件套**，否则 REQ-009 的门会因「REQ-009 的追溯件缺失」而判红（虽非 REQ-012 的错，但**合并后**就是红的） |
| J3 | ⇒ **REQ-012 的交付面必须包含 `feature-meta/load-runner/` 四件套**（`status.md` / `traceability.md` / `verification-report.md` / `manifest.json`），且**不得删改** REQ-009 的 `feature-meta/load-profile/` 四件套与其它三个 skill 的追溯件 | 由 J2 推导 | |

## K. 「交付红线」的口径澄清（**需求方自己查过一次，别再重复纠结**）

| # | 事实 | 实测 |
|---|---|---|
| K1 | ⭐ **红线针对【交付包】**，即 `package.json` 的 `files` 列出的 `skills/` `bin/` `README.md` `LICENSE` —— **交付包内该字样必须 0 命中** | `git grep -c 'internal-rt' develop -- skills bin README.md LICENSE` ⇒ **无输出 = 0 命中**（REQ-009 交付包达标 ✓） |
| K2 | **BA 契约目录（`BA/demands/**`）是该字样的历史命中区** —— REQ-009 的契约目录有 **10 处**命中（`status.md` 的临时路径引用、`decisions.md` 的实测路径等）⇒ **同一先例，不算违规** | `grep -rn 'internal-rt' BA/demands/REQ-002-suite-foundation/REQ-009-load-profile/` ⇒ **10 处** |
| K3 | ⇒ **REQ-012 的处置**：① 交付包（`skills/` `bin/` `README.md` `LICENSE`）必须 **0 命中**；② BA 契约目录**沿用 REQ-009 先例，不必清零**（过程文件，记录的是实测路径）；③ `feature-meta/` **不入 npm 包**（`files` 未含它）⇒ 也不在交付包口径内，但 REQ-009 仍清零了它 —— 属**更严**，可参照 | 三条实测 |
| K4 | ⚠️ **需求方自己的判断错误留痕**：曾用 `git grep 'internal-rt' develop -- BA/` 得 0 命中 ⇒ 误以为「整个 BA 目录零命中」⇒ 后续差点对 BA 侧提出不必要的中性化要求。**真实情况**：REQ-009 契约目录 10 处命中。**教训**：先例要**实测**再引用，别凭一次查询下结论 | 自查纠正 |
