# REQ-013 验收判据 —— `load-profile` **负载级执行与判定链**（只打本地桩）

> 本文件是**契约**，不是说明材料。实现者按这里的规则交付，验收脚本按这里的规则判定。
> 判据条数：**41 条**（AC-001 ~ AC-041）。条数**不增不减不改号**。
> 决策记录见 `decisions.md`（**D185 ~ D210**）· 功能契约见 `demand.md`（F1~F10）· 勘察事实见 `PROBE-FACTS.md`。
>
> ⚠️ **条数变更留痕**：原定 **38 条**（AC-001~AC-038）⇒ 需求方自查时补 **3 条**（AC-039~AC-041）⇒ 现 **41 条**。
> 补的理由见 **I 组开头的说明**（三处判据缺口）· 决策号**未变**（D185~D210 仍 26 条）。

---

## §0 公共夹具规格（判据的公共前置）

验收脚本自造以下夹具，**全部落在临时目录**（`$WORK`），**不得**写进被验包。

### §0.1 完整夹具（`$FX/proj`）

目录结构与内容**逐字**规定见 `demand.md` §3.1 ~ §3.2（含 `.tools/manifest.json`、`.gitignore`、
`test-assets/environments/local.json`、`test-assets/load/{scenarios,suites,plans}/`）。

⚠️ **夹具里 `duration_s` 故意取小值（2 秒）** ⇒ 判据跑得完；**与 REQ-012 夹具的真实值不同是有意的**。

⚠️ **工具前置**：`loadtest@8.2.1` 必须已装到 `$FX/proj/.tools/node/node_modules/loadtest/`（含 `.bin/loadtest`）。
安装方式：`node <交付包>/bin/qa install --project $FX/proj`（REQ-003 的 `qa-toolchain`）。
⚠️ **`verify.match` 必须写 `"Loadtest"`（大写 L）** —— 真实输出是 `Loadtest version: 8.2.1`（实测）。
⚠️ **门本身不装工具**（与 REQ-009 / REQ-012 的纪律一致）⇒ 工具缺失时门**必须明确报错**（AC-033）。

### §0.2 计划产物（入口真正读的东西）

`$FX/proj/test-assets/load/plans/LOAD-001-checkout.json` 的**逐字**内容见 `demand.md` §3.2
（**4 个场景**：WL-001 两段 · WL-002 一段 · **WL-003（`python` runner）** 一段 · WL-004 一段；
WL-001 有 4 个阈值键，其余三个场景无阈值）。

⚠️ **WL-003 是 `python` runner**：它的自陈命令**无副作用**（只 `sleep` + 不发请求）⇒ 夹具安全；
它的阈值判定**一律「不可判定」**（D203 / AC-041）。

### §0.3 期望产物（只列**必须成立的性质**，不列数值）

⚠️ **数值随宿主而变**（压测是随机过程，D207）⇒ 判据**不许**断言具体数值，只断言**结构与口径**。
完整的 15 条期望性质见 `demand.md` §3.3。

### §0.4 最小夹具（`$FX/mini`）

用于**只关心单次执行**的判据（避免整门跑两遍完整夹具）：

- `test-assets/environments/local.json`（同 §0.1）；
- `test-assets/load/plans/LOAD-900-mini.json`：**1 个场景 / 1 条 invocation**（`duration_s: 1` / `concurrency: 2`），
  `thresholds` 含**全部 4 个键**（含 `max_concurrency`），`thresholds_status: "provided"`；
- 同样需要 `.tools/`（`loadtest` 已装）。

### §0.5 非法夹具（`$FX/bad-*`）

用于 AC-032 的几类输入非法场景，**每类一个目录**，逐条列在下表：

| 夹具 | 破坏点 |
|---|---|
| `$FX/bad-nosuite` | `--suite` 指向**不存在**的计划 |
| `$FX/bad-threshold` | 计划的阈值里出现**白名单外**的键（如 `p42_latency_ms`） |
| `$FX/bad-argv` | 计划的 `argv` **不是** REQ-012 规范形态（如 `--cores 4`，或缺 `--cores`） |
| `$FX/bad-url` | 计划的 `argv` 里 URL 的 host **不是**回环地址（如 `http://example.com/x`） |

---

## §1 判据清单

> 每条给出：**判**（判什么）· **核**（怎么机械核）· **变异**（能把它打红的改动方向 —— 供验收门自造变异体套件）。
> ⚠️ **判据不许恒真**（每条都必须能被上面的「变异」打红）· **不许不可满足**（实现方做得到）。

### A 组 —— 产物形状与封闭（AC-001 ~ AC-008）

#### AC-001 结果产物的落点与文件名

- **判**：执行成功后，`$OUT/test-assets/load/results/LOAD-001-checkout.json` **存在**；
  文件名去 `.json` **等于**套件名；**不得**出现 `suite.json`（REQ-012 勘察 ⑦ 的同款红线）。
- **核**：文件存在性 + 文件名检查 + `results/` 下**没有** `suite.json`。
- **变异**：把落点改到 `results/<suite>-result.json` / 改成 `suite.json` / 写到 `test-assets/load/` 根下。

#### AC-002 结果产物的顶层字段集**封闭 8 个**

- **判**：结果产物的顶层键**恰好**是
  `schema_version` / `suite` / `environment` / `generated_at` / `execution` / `scenarios` / `verdict` / `results_sha256`
  —— **多一个少一个都判红**（D204）。
- **核**：读 JSON 的顶层键集合，与规定集合**双向相等**。
- **变异**：多写一个 `status` 键 / 少写 `environment` / 把 `results_sha256` 改名。

#### AC-003 顶层标量字段的取值

- **判**：`schema_version == 1`；`suite` **逐字**等于计划的 `suite`；`environment` **逐字**等于计划的 `environment`；
  `generated_at` 是**合法 ISO-8601**（能被 `new Date(x).toISOString()` 往返解析）。
- **核**：逐字段比对 + ISO 解析。
- **变异**：`schema_version` 写成 `"1"` / `suite` 写成别的 / `generated_at` 写 `"2026/11/14"`。

#### AC-004 `results_sha256` 可被独立复算

- **判**：`results_sha256` == 对**剔除 `generated_at` 与 `results_sha256` 两个字段后的整个文件内容**算的 sha256
  （64 位小写十六进制）—— 与 REQ-010 的 `report_sha256` 同款口径。
- **核**：门**自己**剔除两个字段、序列化、算 sha256，与产物里的值比对。
- **变异**：算 sha256 时没剔除 `generated_at` / 剔错了字段 / 用了文件原文（含 `results_sha256` 自己）。

#### AC-005 `execution` 段的形状与取值

- **判**：`execution` **恰好 6 必填键**（`mode` / `started_at` / `finished_at` / `duration_ms` / `tool` / `stub`）
  **+ 1 条件键**（`cli`：**仅** `cli_verbatim` 模式存在，`api_equivalent` 模式**必须缺席**）；
  `mode` ∈ {`api_equivalent`, `cli_verbatim`}；`tool` **恰好 3 键**（`name` / `version` / `resolved_from`）；
  `stub` **恰好 4 键**（`origin` / `delay_ms` / `error_rate` / `status`）；`duration_ms` 是 **≥ 0 的整数**。
- **核**：键集合检查 + 类型检查 + 条件存在性检查。
- **变异**：`api` 模式也写 `cli` 段 / `tool` 里多一个 `path` 键 / `mode` 写成 `"api"`。

#### AC-006 `scenarios` 的长度与顺序

- **判**：`scenarios` 长度 **== 计划里的场景数**；**顺序逐字**相同；每个元素的 `scenario_id` / `scenario_name`
  / `runner` / `target` / `base_url` / `thresholds_status` **逐字**取自计划的对应场景。
- **核**：逐元素与计划**按位置**比对（不是集合比对 —— 顺序错了也要判红）。
- **变异**：把场景按 `scenario_id` 排序 / 漏掉一个场景 / `base_url` 改成桩地址（**必错**：它是**原环境的** base_url）。

#### AC-007 场景条目的字段集与条件字段

- **判**：场景条目**恰好 8 键**（`scenario_id` / `scenario_name` / `runner` / `target` / `base_url` /
  `thresholds_status` / `invocations` / `verdict`）+ **条件 2**（`thresholds` / `thresholds_source`）；
  `thresholds_status == "provided"` ⇒ 两个条件键**都存在**且**逐字**等于计划里的；
  `thresholds_status == "not_provided"` ⇒ 两个条件键**都不存在**。
- **核**：键集合 + 条件存在性 + 逐字比对。
- **变异**：`not_provided` 的场景也写一个空的 `thresholds: {}` / `provided` 的场景漏写 `thresholds_source`。

#### AC-008 invocation 条目的字段集与逐字保真

- **判**：invocation 条目**恰好 10 键**（`step_index` / `duration_s` / `concurrency` / `argv` /
  `executed_url` / `executed_params` / `observed` / `stub_observed` / `thresholds` / `verdict`）；
  ⚠️ **`python` runner 的条目恰好 8 键**（`observed` 缺席 —— 无输出契约；`executed_params` 缺席 —— 不走 API 反解）
  —— 与 AC-041 ① 是**同一件事**，不是额外例外；
  `step_index` == 它在数组里的**下标**；`duration_s` / `concurrency` / `argv` **逐字**等于计划的对应值
  （`argv` **逐元素**相等，**不改一个字符**）。
- **核**：键集合 + 下标检查 + 逐字比对（含 `argv` 的数组逐元素相等）。
- **变异**：把 `argv` 里的 `--cores 1` 改成 `--cores 2`（**改了计划 ⇒ 判红**）/ `step_index` 写错 / `argv` 少一个元素。

### B 组 —— 执行真实性（AC-009 ~ AC-015）

#### AC-009 客户端侧观测存在且有请求完成

- **判**：每条 `loadtest` runner 的 invocation，`observed` **存在**（**恰好 10 键**，F7.7）且
  `observed.total_requests > 0`；`observed.percentiles` **恰好 4 键**（`"50"` / `"90"` / `"95"` / `"99"`），
  值**均为 number**；`observed.error_rate` 是 number（`total_requests > 0` ⇒ 不为 `null`）。
- **核**：字段集合 + 类型 + `> 0`。
- **变异**：`observed` 缺席 / `total_requests` 写 0 / `percentiles` 少了 `"99"` / `percentiles` 的值写成字符串。

#### AC-010 桩**确实收到了请求**（真的发了）

- **判**：每条 **`loadtest` runner** 的 invocation，`stub_observed.requests > 0` ⇒ 请求**真的到达了桩**（不是「假执行」）。
  ⚠️ **`python` runner 的 invocation 豁免本条**（自陈命令未必打桩，F4.5 ④）。
- **核**：`> 0` 检查（只对 `runner == "loadtest"` 的场景）。
- **变异**：桩没起 / 执行器没真跑（直接写死产物）⇒ `requests == 0` ⇒ 判红。

#### AC-011 两侧请求数的差**有界**（不是随便一个数）

- **判**：对每条 invocation，`abs(stub_observed.requests - observed.total_requests) ≤ concurrency + 5`。
  依据：实测客户端侧比桩侧**少约等于并发数**（在途请求：桩已收、客户端已被取消，D198 / C1）。
- **核**：逐条算差值比上界。
- **变异**：把 `stub_observed.requests` 写成一个远大于真实值的数（如 `999999`）⇒ 差值越界 ⇒ 判红。
  ⚠️ **注意**：两侧**恰好相等**是**允许**的（本判据只判上界）—— 实现方不必刻意制造差值。

#### AC-012 URL 只换 origin，path 与 query 逐字保留

- **判**：每条 invocation 的 `executed_url`：
  ① **origin**（协议 + 主机 + 端口）**等于** `execution.stub.origin`；
  ② **host 是回环地址**（`127.0.0.0/8` 或 `::1`）；
  ③ **path + query** **逐字**等于计划 `argv` 里那个 URL 的 path + query。
- **核**：用 URL 解析后逐段比对。
- **变异**：连 path 一起换掉（压的就不是计划里那条链路）/ 用了环境里的真实地址 / 换成一个非回环地址。

#### AC-013 顺序执行且**无时间重叠**

- **判**：同套件内，按 invocation 顺序，前一条的 `stub_observed.last_at_ms` **≤** 后一条的 `stub_observed.first_at_ms`
  ⇒ 顺序执行、无并发重叠。
  ⚠️ **只在双方都观测到过请求时**才比较（`requests > 0`）—— `python` runner 不发请求 ⇒ 它的
  `first_at_ms` / `last_at_ms` 恒为 `0` ⇒ 与它比较必然「重叠」⇒ 那是**假阳性**，不是缺陷。
  ⚠️ 本条澄清由**需求方复算器**的假阳性倒逼得出（复算器曾跨场景比较、且与零观测的 python 条目比较）。
- **核**：逐对比较两个时间戳（跳过未观测到请求的那一条）。
- **变异**：并发执行所有 invocation（时间窗重叠）⇒ 判红。

#### AC-014 桩侧观测是**本次增量**（不是累计）

- **判**：**从第 3 条起**（即下标 ≥ 2），本次增量必须**小于**前面各条之和：
  对每个下标 i ≥ 2，`stub_observed[i].requests < sum(stub_observed[0..i-1].requests)`。
  ⇒ 证明每条记的是**本次**的增量，而不是从套件开始累计的总数。
  ⚠️ **为什么不是「从第 2 条起」**：两次 invocation 的请求数**同量级**（实测 8404 与 9490），
  「第 2 条 ≥ 第 1 条」对**任何正确实现**都成立 ⇒ 那样的判据**不可满足**（会把正确实现判红）。
- **核**：逐条累加比较（只对下标 ≥ 2 的条目）。
- **变异**：桩不重置计数 ⇒ 第 3 条的 requests ≈ 前面之和（≥）⇒ 判红。

#### AC-015 桩**只监听回环地址**

- **判**：`execution.stub.origin` 的 host ∈ 回环地址（`127.0.0.0/8` 或 `::1`）⇒ 桩物理上不可能被外部访问。
- **核**：host 判定。
- **变异**：桩监听 `0.0.0.0`（origin 会显示 `0.0.0.0` 或外部可达地址）⇒ 判红。

### C 组 —— 判定语义（AC-016 ~ AC-023）

#### AC-016 阈值判定条数与键的对应

- **判**：每条 invocation 的 `thresholds` **数组长度 == 该场景的阈值键数**；
  键集合**逐字相等**；无阈值的场景（WL-002 / WL-004）⇒ **空数组** `[]`。
- **核**：长度 + 集合比对。
- **变异**：漏判一个键 / 多判一个键 / 把 `undetermined` 的键直接省掉。

#### AC-017 阈值判定条目的字段集与取值保真

- **判**：每条判定条目**恰好 5 键**（`key` / `threshold` / `observed` / `verdict` / `reason`）；
  `key` 与 `threshold` **逐字**取自计划的阈值；`reason` 是**非空字符串**；
  `verdict` ∈ {`met`, `not_met`, `undetermined`}（**封闭 3 值**，**不得**出现 `passed` / `failed` / `ok`）。
- **核**：键集合 + 枚举检查 + 非空检查 + 逐字比对。
- **变异**：把 `undetermined` 写成 `"unknown"` / `reason` 留空 / `verdict` 写成 `"passed"`。

#### AC-018 `max_concurrency` **恒判「不可判定」**

- **判**：阈值里含 `max_concurrency` 时，它的判定条目 `verdict == "undetermined"`、`observed == null`、
  `reason` **非空**且**点名**该键无对应观测量。
- **核**：三条同时检查 + `reason` 里出现 `max_concurrency` 字样。
- **变异**：拿 `concurrency` 或 `clients` 冒充实际并发判 `met` / 拿它判 `not_met` / `observed` 填了个数。

#### AC-019 默认桩下延迟类与错误率类判「不可判定」

- **判**：桩行为为**默认**（`execution.stub.delay_ms == 0` 且 `execution.stub.error_rate == 0`）时，
  `p50_latency_ms` / `p95_latency_ms` / `p99_latency_ms` / `error_rate` 四者的判定条目
  `verdict == "undetermined"`，且 `reason` **非空**。
- **核**：条件成立 ⇒ 四条逐条检查。
- **变异**：把默认桩下的 p95 判成 `met`（**凭空判达标**，本 REQ 最核心的红线）。

#### AC-020 默认桩下 `throughput_rps` **仍可判**

- **判**：同上条件下，`throughput_rps` 的判定条目 `verdict ∈ {met, not_met}`（**不得** `undetermined`），
  且 `observed` 是 **number** 且 **等于** `observed.effective_rps`。
- **核**：枚举检查 + 数值相等。
- **变异**：把吞吐也判成 `undetermined`（过度保守 ⇒ 判定链形同虚设）/ `observed` 与 `effective_rps` 不等。

#### AC-021 延迟分位映射**正确**（不是随便一个数）

- **判**：当 `p50/p95/p99_latency_ms` 的判定为 `met` 或 `not_met` 时，其 `observed` **逐字等于**
  `observed.percentiles["50"|"95"|"99"]`；判 `undetermined` 时 `observed == null`。
- **核**：逐键比对数值。
- **变异**：把 p95 的观测填成 p99 的值 / 填成 `mean_latency_ms` / `undetermined` 时填了个数。

#### AC-022 错误率映射**正确**

- **判**：`error_rate` 的判定条目 `observed`（当为 `met`/`not_met`）**等于** `observed.error_rate`，
  且 `observed.error_rate` **等于** `observed.total_errors / observed.total_requests`
  （**重新算**，不是抄一个数）；当 `total_requests == 0` 时 `observed.error_rate` 必须是 `null`。
- **核**：门自己重算并比对（允许浮点误差 ≤ 1e-9）。
- **变异**：`error_rate` 写成一个随手编的数 / 分子分母颠倒。

#### AC-023 汇总判定**不掩盖**失败

- **判**：
  ① `verdict.invocations_met + invocations_not_met + invocations_undetermined == verdict.invocations_total`；
  ② `invocations_total` == 结果产物里 invocation 的**总条数**；
  ③ 若**存在**任一 invocation 判 `not_met` ⇒ `verdict.suite != "met"`；
  ④ `verdict.undetermined_keys` **包含**全部出现过 `undetermined` 的阈值键（去重、逐字）。
- **核**：逐条算术与集合比对。
- **变异**：汇总写 `met` 而有条 `not_met` / 计数对不上 / `undetermined_keys` 漏键。

### D 组 —— 诚实性（AC-024 ~ AC-027）

#### AC-024 产物**不得**出现生产容量表述

- **判**：结果产物**全文**（含所有字符串值与键名）**不得**出现下列字样：
  「生产」「生产环境」「容量达标」「可承载」「上线」「production」「production-ready」；
  且**必须**出现「本地桩」或 `127.0.0.1` 之一（**限定语**）。
  ⚠️ **单独的 `capacity` 不在禁词表** —— 来源标记（如 `thresholds_source = "capacity-targets"`）是**出处**，
  不是「容量达标」这类表述；禁它会**误伤契约自身的夹具**。
- **核**：全文正则扫描（大小写不敏感）+ 限定语存在性检查。
- **变异**：在 `verdict` 里写一句「生产环境容量达标」。

#### AC-025 判定用词**不与用例级混用**

- **判**：产物里**不得**出现取值 `passed` / `failed` / `blocked` / `skipped` 的判定字段
  （本 REQ 的判定枚举是 `met` / `not_met` / `undetermined`，F6.3）；
  且**不得**出现 `results.json` / `meta.json` / `cases.json` / `case_id` / `verdict.mjs` 这些**用例级**文件名/键名。
- **核**：扫描 JSON 的所有字符串值与键名。
- **变异**：写一个 `status: "passed"` 字段 / 把用例级 `results.json` 当产物名。

#### AC-026 API 模式标 `api_equivalent` 且**实际执行参数可核**

- **判**：`--mode api`（默认）跑完后：
  ① `execution.mode == "api_equivalent"`；
  ② 每条 invocation 有 `executed_params`（**恰好 6 键**：`maxSeconds` / `concurrency` / `requestsPerSecond` /
  `agentKeepAlive` / `timeout` / `method`）；
  ③ `executed_params` 与 `argv` **反解一致**：`maxSeconds` == `-t` 的值、`concurrency` == `-c` 的值、
  `method` == `-m` 的值、`requestsPerSecond` == `--rps` 的值（无则 `null`）、`agentKeepAlive` == 是否有 `-k`、
  `timeout` == `-d` 的值（无则 `null`）。
- **核**：门**自己**按 REQ-012 的规范形态反解 `argv`，与 `executed_params` 逐键比对。
- **变异**：反解时把 `-d` 的秒当毫秒 / 漏反解 `--rps` / `mode` 写成 `"api"`（**冒充逐字执行**）。

#### AC-027 CLI 模式**逐字执行**且**能力降级如实标注**

- **判**：`--mode cli` 跑完后：
  ① `execution.mode == "cli_verbatim"`；
  ② `execution.cli` 存在且**恰好 2 键**：`error_code_resolution == "unavailable"`、`percentile_source == "stdout_text"`；
  ③ 每条 invocation **没有** `executed_params`（CLI 模式**必须缺席**）；
  ④ `observed.error_codes` **只有 `"−1"` 这一个桶**（用 ASCII 的 `-1`）；
  ⑤ `observed.percentiles` 的 4 个键**均为 number**（从 stdout 文本解析得来）。
- **核**：用 §0.4 的**最小夹具**跑一次（避免整门跑两遍完整夹具），逐条检查。
- **变异**：CLI 模式却标成 `api_equivalent` / 不标能力降级 / 凭 stdout 解析不出分位就**编一个数**。

### E 组 —— 写入纪律与幂等（AC-028 ~ AC-030）

#### AC-028 **只写** `results/`，输入只读

- **判**：跑完后，`plans/` / `scenarios/` / `suites/` / `environments/` 下**每个文件**的 sha256
  与跑前**逐字相同**（**一个都没被改**）；且 `results/` 之外**没有**新增任何文件。
- **核**：跑前跑后各算一遍目录树 sha256 并比对。
- **变异**：执行器顺手把 `thresholds` 写回计划文件 / 在 `scenarios/` 里落个临时文件。

#### AC-029 产物已存在 ⇒ **报错不覆盖**

- **判**：`results/<套件>.json` 已存在时再跑一次 ⇒ **退出码 1**、**原文件 sha256 不变**（逐字未改）。
- **核**：跑第二次，检查退出码与 sha256。
- **变异**：直接覆盖写 / 追加写。

#### AC-030 结构级幂等（**不承诺数值幂等**）

- **判**：同一输入跑两次（**两个不同的输出目录**）⇒ 两份产物的**结构**逐字相同：
  把所有**数值型叶子**替换成占位 `"#"`、把所有**时间戳**替换成占位后，两份文件的**剩余部分逐字相同**
  （键集合、键序、字符串值一律逐字相同）。
  ⚠️ **归一化清单（共 6 类，缺一类本判据就不可满足）**：
  ① 数值型叶子 · ② 时间戳 · ③ **桩的随机端口**（`execution.stub.origin` 里的端口）
  · ④ **项目根绝对路径**（出现在 `execution.tool.resolved_from` 等处）
  · ⑤ **`results_sha256`**（它是易变内容的摘要）· ⑥ **直方图的 ms 桶键集**（`histogram_ms` 的键）。
  ⇒ 前 4 类是「每跑必变」；后 2 类是「内容变了摘要就变」「观测样本变了桶集就变」。
- **核**：门自己做归一化后比对。
- **变异**：第二次跑多写了一个键 / 改变了键的顺序（⇒ 结构不一致）⇒ 判红。
⚠️ **注意**：本判据**不**要求两份产物的数值相同（压测是随机过程，D207）。

### F 组 —— 入口行为与退出码（AC-031 ~ AC-033）

#### AC-031 用法错误 ⇒ 退出码 `2`

- **判**：以下三种**分别**触发时，退出码**都是 `2`**（且**不产出**任何产物）：
  ① 缺 `--load-dir`；② 传了未知参数 `--bogus`；③ 传了多余的位置参数 `extra`。
- **核**：逐个跑，检查退出码 == 2 且 `results/` 不存在。
- **变异**：把用法错误当成输入非法（rc=1）/ 直接当成功（rc=0）。

#### AC-032 输入非法 ⇒ 退出码 `1` 且**点名**

- **判**：§0.5 的四类非法夹具**逐一**触发时，退出码**都是 `1**，且**stderr 点名**了出问题的那个键/文件：
  ① `bad-nosuite` ⇒ 点名套件名或「不存在」；② `bad-threshold` ⇒ **点名** `p42_latency_ms`；
  ③ `bad-argv` ⇒ 点名 argv 不合规（点出**哪个**不合规）；④ `bad-url` ⇒ 点名该 URL 非回环。
  另：**四种情形都不得产出任何 `results/` 文件**。
- **核**：逐个跑，检查退出码 + stderr 含关键词 + `results/` 不存在。
- **变异**：静默忽略非法输入继续跑 / 只报「失败」不点名。

#### AC-033 工具不可用 ⇒ 明确报错且**不产产物**

- **判**：把 `$FX/mini/.tools/` 挪走（工具不可用）后跑 ⇒ **退出码 `1`**、
  **stderr 明确点名缺什么**（含 `loadtest` 字样）与**怎么装**（含 `qa install` 字样）；
  且**没有**任何 `results/` 产物（**不得**产出「达标」或任何判定）。
- **核**：挪走 `.tools` 后跑，检查退出码 + stderr 关键词 + 产物不存在。
- **变异**：工具缺失时改用内置假执行器「假装压过」/ 产出空产物 / 只报一句「失败」。

### G 组 —— 桩与证据链（AC-034 ~ AC-035）

#### AC-034 证据目录与 sha256 清单**可复算**

- **判**：`evidence/<套件名>/` 下：
  ① 每个 `step_index` 一个子目录（目录名 == 该 invocation 的 `step_index`，**逐字**）；
  ② 每个子目录里**恰好 3 个文件**：`result.json` / `stdout.txt` / `stub-observations.json`；
  ③ `manifest.json` **逐个列出**该目录下每个证据文件的 sha256（64 位小写十六进制），且**门自己复算一致**。
- **核**：目录结构检查 + 复算 sha256。
- **变异**：不写 `manifest.json` / sha256 算的是 `generated_at` 之前的内容 / 少列一个文件。

#### AC-035 执行结束后**桩已停**（无残留）

- **判**：执行结束后，`execution.stub.origin` 的**端口**再也**连不上**（连接被拒绝）⇒ 桩已停；
  且产物写出后**没有**桩进程残留（进程表里查不到该桩）。
- **核**：跑完后用一次 TCP 连接探该端口（应被拒），并检查进程表。
- **变异**：桩不随执行器退出而停（进程残留）⇒ 判红。

### H 组 —— 交付红线与交付物（AC-036 ~ AC-038）
#### AC-036 交付包不含 "internal-rt" 字样

- **判**：交付包内容（`skills/` `bin/` `README.md` `LICENSE`）**0 命中** "internal-rt"（大小写不敏感）。
- **核**：对交付包做全文扫描（`npm pack --dry-run` 的条目集合逐个扫）。
- **变异**：在 SKILL.md 或某个脚本里写了 "internal-rt"。

#### AC-037 追溯件四件套**含本 REQ 的条目**

- **判**：`feature-meta/load-runner/` 四件套（`verification-report.md` / `traceability.md` /
  `feature.json` / `feature-meta.json`）存在，且**包含** REQ-013 的条目（`REQ-013` 字样出现）；
  `traceability.md` 里 REQ-013 的**决策号并集** == `decisions.md` 里 **D185~D210** 的实际集合。
  ⚠️ **REQ-012 已交付的既有件**（`status.md` / `manifest.json` 等）**保留不动**，本判据**不要求**删改它们。
  ⚠️ **决策号提取口径**：`traceability.md` 里同时有 REQ-012 的 D156~D184 ⇒ 归属**按行内最后一个 `REQ-\d+` 判定**
  （整文件抓会得到超集）。
- **核**：文件存在性 + 关键字扫描 + 决策号集合比对（按行归属提取）。
- **变异**：没写追溯件 / 追溯件里漏了 D185~D210 中的某几条 / 引用了不存在的决策号。

#### AC-038 SKILL.md **追加**了 B 阶段说明

- **判**：`skills/load-profile/SKILL.md` **包含** B 阶段入口命令（`run-load-test`）
  与**只打本地桩**的边界表述（含「本地桩」或 `127.0.0.1`）。
- **核**：关键字扫描。
- **变异**：只写了入口没写边界 / 完全没写。

---

### I 组 —— 注入生效与 runner 覆盖（AC-039 ~ AC-041）

> 本组是**需求方在审门清单自查时补的判据**（2026-11-14）——
> 原 38 条**漏了三处**：① `statusCallback` 漏设**判不出来**（默认桩全是 200 ⇒ 错误码塌成 `-1` 也看不出来）；
> ② 「注入后阈值**恢复可判**」这半句（D199 后半句）**没有判据覆盖**；
> ③ `python` runner（D203）**整条决策没有任何判据覆盖** ⇒ 属「假决策」。
> ⚠️ 补这三条时**同时修了 AC-010 的适用范围**（`python` runner 豁免「桩必须收到请求」）。

#### AC-039 注入错误后，错误码是**真实 HTTP 状态码**（不是 `-1`）

- **判**：用 §0.4 的最小夹具加 `--stub-error-rate 1` 跑一次（桩**全部**返回 500）⇒
  ① `execution.stub.error_rate == 1`；
  ② 每条 `loadtest` invocation 的 `observed.error_codes` 的键是 **`"500"`**（**不得**是 `"-1"`），
  且该键的计数 **==** `observed.total_requests`；
  ③ `observed.error_rate == 1`。
- **核**：三条同时检查；**`-1` 出现即判红**。
- **变异**：**漏设 `statusCallback`** ⇒ 所有 HTTP 错误码塌成 `"-1"` ⇒ 判红（B5/B6 的实测依据）。

#### AC-040 桩行为**注入后**，延迟类与错误率类阈值**恢复可判**

- **判**：用 §0.4 的最小夹具加 `--stub-delay-ms 50` 跑一次（桩注入 50ms 延迟）⇒
  ① `execution.stub.delay_ms == 50`；
  ② `p50/p95/p99_latency_ms` 三者的判定条目 `verdict ∈ {met, not_met}`（**不得** `undetermined`），
  且 `observed` 是 number；
  ③ `error_rate` 的判定条目 `verdict ∈ {met, not_met}`（**不得** `undetermined`）。
  ⚠️ 与 AC-019 **不矛盾**：AC-019 判的是**默认桩**下判 `undetermined`；本条判的是**注入后**判可判。
- **核**：条件检查（`stub.delay_ms == 50` ⇒ 执行三条）+ 枚举检查。
- **变异**：注入后仍判 `undetermined`（**过度保守 ⇒ 判定链永远无效**）/ 注入没生效却写成 50。

#### AC-041 `python` runner 的 invocation 一律「不可判定」

- **判**：夹具里 `runner == "python"` 的场景（WL-003）的那条 invocation：
  ① `observed` **不存在**（键**缺席**）；
  ② `verdict == "undetermined"`；
  ③ 它的 `thresholds` 是**空数组**（该场景无阈值）；
  ④ 它**仍然有证据**：证据目录里存在**以它的 `step_index` 命名的子目录**（含 `result.json` / `stdout.txt` /
  `stub-observations.json`）；
  ⑤ 其 `stub_observed.requests` **允许为 0**（自陈命令未必打桩，F4.5 ④）。
- **核**：逐条检查 ①~④；⑤ 只检查「键存在且类型合法」。
- **变异**：给 python invocation 编一个 `observed`（**凭空造观测量**）/ 判定成 `met` / 跳过不执行（证据目录缺它的子目录）。

---

## §2 验收门（`verify-acceptance.sh`）的硬要求

> **门是交付物，必须被当作被验对象对待**（D65 方法论）：**先自测门，再派 Dev**。

| # | 要求 | 说明 |
|---|---|---|
| 1 | **两种模式**：**快跑**（只跑基线，不跑变异体）与**完整模式**（基线 + 全部变异体） | 与 REQ-012 同款 |
| 2 | **变异体套件**：每个可被打红的判据**至少一个**变异体；门**自己**跑一遍变异体 ⇒ 必须**全部检出**（否则门自己有缺陷） | 与 REQ-012 同款 |
| 3 | **负控**：一个**无害**改动 ⇒ 必须**检不出**（否则门是橡皮章） | 与 REQ-012 同款 |
| 4 | **变异必须自证生效**：注入前后做**指纹比对**，没生效即判红 | REQ-012 的教训（指纹语义归一化曾掩盖真实检出） |
| 5 | **并发隔离**：多个变异体**不得**并发跑 ⇒ 每路独立 `QA013_WORK_ROOT` | REQ-012 的教训（并发 ⇒ 无因果关系的额外 FAIL 键） |
| 6 | **不得自证**：判据**不许**靠「查被验物源码的字面量」自证 | 诚实纪律 |
| 7 | **不可判定必须显式**：判据判不了时**必须**标「不可判定」并**判红退出**（rc=1），**不得**判 passed | 诚实纪律 |
| 8 | **sha 前置检查**：门对自己的 sha 做前置检查（`QA013_SCRIPT_SHA` 环境变量），不匹配即 `0 PASS / 1 FAIL` 退出 | REQ-012 同款 |
| 9 | **只读**：门**不得**修改被验包（只读检查 + 在临时目录里造夹具） | REQ-012 同款 |
| 10 | **输出格式**：`PASS` / `FAIL` 行 + 一行 `结论: N PASS / M FAIL` | REQ-012 同款 |

**判据条数守恒**：**41 条**（AC-001 ~ AC-041）。**决策号守恒**：**26 条**（D185 ~ D210）。
