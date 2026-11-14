# REQ-012 追溯性矩阵

- 需求：REQ-012「压测能力域 A 阶段：`load-profile` skill 的 **runner 适配**（负载模型 → 压测计划，**零请求**）」
- 分支：`feature/REQ-012`
- 判据条数：29（AC-001 ~ AC-029）
- 决策号范围：D156~D184
- 需求契约（只读）：`BA/demands/REQ-002-suite-foundation/REQ-012-load-runner/`
  （`demand.md` 功能契约 / `acceptance.md` 判据集 / `decisions.md` 决策记录 / `PROBE-FACTS.md` 勘察事实）
- 交付位置：
  - `skills/load-profile/scripts/plan-load-run.mjs`（主入口：负载模型 + 套件 + 环境 ⇒ 压测计划）
  - `skills/load-profile/scripts/check-load-run.mjs`（产物自洽校验器，**有行为护栏**）
  - `skills/load-profile/scripts/lib/runner.mjs`（runner 适配契约：参数映射 / 形态 / 边界）
  - `skills/load-profile/scripts/lib/plan.mjs`（读入 / 校验 / 计划构造 / 产物侧自检）
  - `skills/load-profile/references/runner-adapters.md`（适配契约文档）
  - `README.md`（新增 `load-profile` 的 runner 适配入口一节，两个新脚本名都在）
  - `feature-meta/load-runner/`（本 REQ 的交付侧追溯件四件套）

> 下表逐条给出交付位置与自验方式。判据条数与决策号范围与 `acceptance.md` / `decisions.md` 一致。
> 自验的**真实输出**见 `verification-report.md`。

| AC | 交付位置 | 自验方式 | 对应决策 | 结论 |
|---|---|---|---|---|
| AC-001 两个新入口脚本形状合法，校验器**有行为护栏** | `scripts/plan-load-run.mjs` + `scripts/check-load-run.mjs` | 查存在/非空/首行 shebang/可执行位/`node --check`；**实跑**校验器：合法根 rc=0，篡改副本（`-t 60`→`61`）rc=1（不得 0 或 2） | D156 / D157 | PASS |
| AC-002 REQ-009 既有 14 个文件**逐字未改** | `skills/load-profile/`（本 REQ 只**新增**文件，不改既有内容） | 对 §0.8.1 基线表的 14 个文件逐个算 sha256 并比对 | D158 | PASS |
| AC-003 README 两处都在，且提到两个新脚本 | `README.md`（新增「`load-profile` 的 runner 适配入口」一节） | 取 README 的 skill 清单集合与 `skills/` 下含 `SKILL.md` 的目录名集合比对；核 `load-profile` 在表格与安装树里都在；核两个脚本名都在 | D159 | PASS |
| AC-004 计划产物**三层字段集封闭**（4 / 12 / 4）与枚举合法 | `lib/plan.mjs`（`PLAN_TOP_FIELDS` / `PLAN_SCENARIO_FIELDS` / `PLAN_INVOCATION_FIELDS` + `inspectPlanDocs`） | 逐计划核顶层键集恰为 4 个、`schema_version == 1`、场景条目键集封闭、invocation 键集封闭、三处枚举取值合法、整数合法、无 `cases_file` | D160 | PASS |
| AC-005 用法错误必须判 **rc=2** | `scripts/plan-load-run.mjs`（`parseArgs` + `UsageError`） | 四种用法错误各跑一次（缺 `--load-dir` / 缺 `--out-dir` / 未知参数 / 多余位置参数）：退出码均为 2，且不留 `plans/` | D161 | PASS |
| AC-006 模型 / 套件 / 环境必须**读全** | `lib/plan.mjs`（`loadSide` / `validateModel`） | 四份变体（V4 缺环境文件 / V5 缺 `base_url` / V6 引用漂移 / V7 引用悬空）各跑一次：rc=1、stderr 点名坏点、**不留** `plans/` | D162 | PASS |
| AC-007 模型**内容**必须合法 | `lib/plan.mjs`（`validateModel`）+ `lib/runner.mjs`（`parseTarget`） | 三份变体（V1 并发 0 / V2 `target` 形态错 / V3 `runner` 越界）各跑一次：rc=1、stderr 点名坏点、**不留** `plans/` | D163 | PASS |
| AC-008 非法输入 ⇒ **不留半份产物** | `scripts/plan-load-run.mjs`（校验 → 自检 → 建目录三段严格有序） | 十份变体各跑一次（每次独立副本）：跑完后 `plans/` **不存在** | D164 | PASS |
| AC-009 `argv` 必须**完整可跑** | `lib/runner.mjs`（`buildUrl` / `buildLoadtestArgv`） | 逐条核 argv 是非空字符串数组、`argv[0]` 是工具名、**恰好一个**完整绝对 URL、URL == `base_url` 去尾斜杠 + 目标路径、`base_url` 字段逐字等于环境文件；另跑尾斜杠环境变体（字段带斜杠、URL 不带） | D165 | PASS |
| AC-010 方法与路径必须**分离** | `lib/runner.mjs`（`parseTarget` / 方法取值） | 逐条核 `-m` 恰好一次且值为大写方法、方法与 `target`（或 `args.method`）一致、路径字符串只出现在 URL 元素里 | D166 | PASS |
| AC-011 多段画像必须**保真** | `lib/plan.mjs`（`buildPlans`：每段一条 invocation） | 逐场景核 invocation 条数 == steps 条数、`step_index == i`、时长与并发逐字相等（**不合并**） | D167 | PASS |
| AC-012 `--cores 1` **恒定钉死** | `lib/runner.mjs`（`buildLoadtestArgv`） | 逐条核 `--cores` 恰好一次且下一个元素恰为 `"1"` | D168 | PASS |
| AC-013 计划文件必须与**套件一一对应** | `lib/plan.mjs`（`buildPlans` 按套件目录遍历） | 核计划文件名集合 == 套件目录名集合 + `.json`、`suite` 字段一致、`environment` 与 `suite.json` 一致、场景 id 序列逐项等于引用件顺序、`plans/` 下无 `suite.json` | D169 | PASS |
| AC-014 `-t` / `-c` 必须逐字映射 | `lib/runner.mjs`（`buildLoadtestArgv`） | 逐条核 `-t` / `-c` 各恰好一次，取值分别 == 该条 invocation 的时长 / 并发的字符串形态 | D170 | PASS |
| AC-015 `args.timeout_s`（秒）→ `-d`（毫秒） | `lib/runner.mjs`（`Math.round(timeout_s * 1000)`） | 逐条核有 `timeout_s` ⇒ `-d` 恰好一次且取值为 `String(Math.round(timeout_s*1000))`（夹具 `10` ⇒ `"10000"`）；无 `timeout_s` ⇒ 不出现 `-d` | D171 | PASS |
| AC-016 `--rps` / `-k` 必须逐字映射 | `lib/runner.mjs`（`buildLoadtestArgv`） | 逐条核有 `rps` ⇒ `--rps` 恰好一次且取值相等；`keepalive == true` ⇒ `-k` 恰好一次；否则**都不给** | D172 | PASS |
| AC-017 `args` 的**未知键必须拒绝** | `lib/runner.mjs`（`assertArgsKeys`，按 runner 分白名单） | V8 跑一次：rc=1、stderr 点名该键、**不留** `plans/`；并核产物里**不出现** `args` 键 | D173 | PASS |
| AC-018 `python` runner 必须**自陈完整命令** | `lib/runner.mjs`（`buildPythonArgv`） | V9（缺 `command`）/ V9b（字符串命令）各跑一次：rc=1、stderr 点名 `command`、**不留** `plans/`；主跑产物逐条核 argv 前缀 == 自陈命令（占位符替换后）、含该段时长与并发、无残留占位符、多段 argv 互不相同 | D174 | PASS |
| AC-019 不得出现任何**压测结论** | `lib/plan.mjs`（`scanForbidden`） | 递归扫全部计划产物任意层级：键名与禁表述一个都不许出现 | D175 | PASS |
| AC-020 阈值的**二态**必须与模型一致 | `lib/plan.mjs`（`buildPlans` + `validateModel`） | 逐场景核 `provided` ⇒ 两个阈值键都在且逐字相等；`not_provided` ⇒ 两个键都不存在；`thresholds_status` 只取两值 | D176 | PASS |
| AC-021 未决问题必须**字段齐全**且「无来源必留痕」 | `lib/plan.mjs`（`validateModel` + `buildPlans`） | 逐条核键集恰为 3 个、`id` 合 `^OQ-\d{3}$` 且计划文件内唯一、`topic` 取值合法、`question` 非空；逐场景核 `not_provided` 必有 `thresholds` 主题、`provided` 必无、无对应用例必有 `coverage` 主题；条目数与 `id` / `topic` 与模型逐字相等 | D177 | PASS |
| AC-022 **零请求** | `scripts/plan-load-run.mjs`（全程只读文件 + 只写 `plans/`） | 验收门用两个桩服务计数（跑完全部调用后**都是 0**）；扫产物任意层级无执行痕迹键；跑完项目根下无 `runs` / `evidence` / `.test-artifacts` | D178 | PASS |
| AC-023 只写 `test-assets/load/plans/` | `scripts/plan-load-run.mjs`（写盘只落在 `plans/`） | 跑前跑后对项目根下（除 `plans/` 外）取文件集合 + 内容 sha256 指纹并比对；核 `report.json` 未被改写 | D179 | PASS |
| AC-024 不得改输入 | `lib/plan.mjs`（`loadSide` 只读） | 跑前跑后对每个模型 / 套件 / 环境文件算 sha256 并比对 | D180 | PASS |
| AC-025 幂等：两份计划**逐字相同** | `lib/plan.mjs`（构造过程不写任何时间戳 / 随机 id / 宿主路径） | 同一输入跑两次（两个不同项目根）：相对路径集合相等 + 每个同名文件内容 sha256 相同 | D181 | PASS |
| AC-026 产物已存在 ⇒ 报错退出，**不得覆盖** | `scripts/plan-load-run.mjs`（`assertWritable`） | 同一项目根第二次跑：rc=1、stderr 点名「产物已存在」、既有产物**逐字未变** | D182 | PASS |
| AC-027 交付侧记账必须与实际一致 | `feature-meta/load-runner/`（四件套）+ `feature-meta/load-profile/` 与包内根 `feature-meta/manifest.json` **逐字未动** | 核四件套齐全非空、子目录 `manifest.json` 的 `req == "REQ-012"`、根 `manifest.json` 的 `req` 仍是 `REQ-006`、既有四个子目录四件套未被动；追溯矩阵编号集合 == 判据集合；三份 md 的判据条数取值唯一、决策号取值唯一 | D183 | PASS |
| AC-028 **既有契约一个都不许被打破** | 本 REQ 只**新增**文件（不改既有脚本 / 不改 `test-execute`） | 单独进程实跑上游 `verify-layout.mjs`（对含 `plans/` 的项目根 rc=0、0 FAIL）、REQ-009 的验收门（快跑 rc=0、0 FAIL）、组合门（rc=0）、其余同级门（快跑模式）；核 `not_implemented` 仍含 `load` | D184 | PASS |
| AC-029 交付红线：内部运行时字样 **0**，`feature-meta` **不入 npm 包** | `skills/load-profile/**` 与 `feature-meta/**` 的全部文件内容 | 扫内部运行时字样（0 命中）；实跑 `npm pack --dry-run --json` 取真实打包清单，核无 `feature-meta/` 条目 | D184 / D158 / D183 | PASS |

---

# REQ-013 追溯性矩阵（负载级执行与判定链 · B 阶段）

- 需求：**REQ-013**「压测能力域 B 阶段：`load-profile` skill 的**负载级执行与判定链**（**只打本地桩**）」
- 分支：`feature/REQ-013`
- 判据条数：41（AC-001 ~ AC-041）
- 决策号范围：D185~D210
- 需求契约（只读）：`BA/demands/REQ-002-suite-foundation/REQ-013-load-exec/`
  （`demand.md` 功能契约 / `acceptance.md` 判据集 / `decisions.md` 决策记录 / `PROBE-FACTS.md` 勘察事实）
- 交付位置：
  - `skills/load-profile/scripts/run-load-test.mjs`（主入口：计划 ⇒ 起桩 ⇒ 执行 ⇒ 判定 ⇒ 写产物）
  - `skills/load-profile/scripts/check-load-test.mjs`（产物自洽校验器，**只读**、**有行为护栏**）
  - `skills/load-profile/scripts/lib/stub.mjs`（本地桩服务：只监听回环、自带计数与注入）
  - `skills/load-profile/scripts/lib/load-exec.mjs`（执行器 + 判定器 + 反解层 + 写入纪律）
  - `skills/load-profile/references/load-exec-contract.md`（B 阶段契约文档）
  - `skills/load-profile/SKILL.md`（**追加**一节：B 阶段入口与「只打本地桩」边界）
  - `feature-meta/load-runner/`（本 REQ 的交付侧追溯件四件套）

> 下表逐条给出交付位置与自验方式。判据条数与决策号范围与 `acceptance.md` / `decisions.md` 一致。
> 自验的**真实输出**见 `verification-report.md`。

| AC | 交付位置 | 自验方式 | 对应决策 | 结论 |
|---|---|---|---|---|
| AC-001 结果产物落点与文件名（**不得**叫 `suite.json`） | `lib/load-exec.mjs`（`runSuite` 的落盘点） | 核 `results/<套件名>.json` 存在、文件名 == 套件名、`results/` 下无 `suite.json` | D186 | PASS |
| AC-002 结果产物**顶层字段集封闭 8 个** | `lib/load-exec.mjs`（`TOP_KEYS` + `runSuite` 构造） | 取产物顶层键集合与封闭集**双向相等** | D204 | PASS |
| AC-003 顶层标量取值（`schema_version` / `suite` / `environment` / `generated_at`） | `lib/load-exec.mjs`（`runSuite`） | 逐字段比对 + ISO-8601 往返解析 | D204 | PASS |
| AC-004 `results_sha256` 可被独立复算 | `lib/load-exec.mjs`（`computeResultsSha` / `canonicalJson`） | 剔除 `generated_at` 与 `results_sha256` 后**独立重算** sha256 并比对 | D208 | PASS |
| AC-005 `execution` 段形状（6 必填 + 1 条件） | `lib/load-exec.mjs`（`runSuite` 的 `execution` 段） | 键集合 + 类型检查 + `cli` 条件存在性（api 模式**必须缺席**） | D200 / D201 | PASS |
| AC-006 `scenarios` 的长度与顺序 | `lib/load-exec.mjs`（`runScenario` 逐场景推进） | 与计划**按位置**逐字段比对（顺序错了也判红） | D190 | PASS |
| AC-007 场景条目的字段集与条件字段 | `lib/load-exec.mjs`（`runScenario` 的场景条目） | 键集合 + `thresholds` / `thresholds_source` 的条件存在性 + 逐字比对 | D188 / D204 | PASS |
| AC-008 invocation 条目的字段集与逐字保真 | `lib/load-exec.mjs`（`runScenario` 的 invocation 条目） | 键集合（`python` runner 恰好 8 键）+ `step_index == 下标` + `argv` 逐元素相等 | D200 / D203 | PASS |
| AC-009 客户端侧观测存在且有请求完成 | `lib/load-exec.mjs`（`mapApiResult` / `parseCliStdout`） | `observed` 恰好 10 键、`total_requests > 0`、分位 4 键均为 number | D198 | PASS |
| AC-010 桩**确实收到了请求**（真的发了） | `lib/stub.mjs`（`handle` 计数）+ `lib/load-exec.mjs` | 每条 `loadtest` runner 的 invocation 的 `stub_observed.requests > 0` | D198 | PASS |
| AC-011 两侧请求数的差**有界** | `lib/load-exec.mjs`（两段观测分开存） | 逐条算 `abs(桩侧 - 客户端侧) <= concurrency + 5`（**不判等式**） | D198 | PASS |
| AC-012 URL **只换 origin**，path 与 query 逐字保留 | `lib/load-exec.mjs`（`runInvocation` 的 origin 替换） | 核 origin == 桩地址、host 是回环、path + query 与计划逐字相同 | D194 | PASS |
| AC-013 顺序执行且**无时间重叠** | `lib/load-exec.mjs`（`runScenario` 顺序推进）+ `lib/stub.mjs`（绝对时序） | 逐对比较前一条的 `last_at_ms` ≤ 后一条的 `first_at_ms` | D190 | PASS |
| AC-014 桩侧观测是**本次增量**（不是累计） | `lib/stub.mjs`（`resetObservations`）+ `lib/load-exec.mjs`（每条 invocation 前重置） | 从第 3 条起，本次增量 < 前面各条之和 | D209 / D196 | PASS |
| AC-015 桩**只监听回环地址** | `lib/stub.mjs`（`STUB_HOST` + `listen(0, '127.0.0.1')`） | 核 `execution.stub.origin` 的 host 是回环地址 | D187 | PASS |
| AC-016 阈值判定条数与键的对应 | `lib/load-exec.mjs`（`judgeThresholds`） | 每条 invocation 的判定条数 == 该场景阈值键数、键集合相等、无阈值场景为空数组 | D188 | PASS |
| AC-017 阈值判定条目的字段集与取值保真 | `lib/load-exec.mjs`（`judgeThresholds`） | 恰好 5 键 + 枚举封闭 3 值 + `reason` 非空 + 阈值逐字 | D195 | PASS |
| AC-018 `max_concurrency` **恒判「不可判定」** | `lib/load-exec.mjs`（`judgeThresholds` 的专门分支） | 核 `verdict == "undetermined"`、`observed == null`、`reason` 点名该键 | D189 | PASS |
| AC-019 默认桩下延迟类与错误率类判「不可判定」 | `lib/load-exec.mjs`（`judgeThresholds` 的 `stubIsDefault` 分支） | 默认桩下四个键逐条核 `undetermined` + `reason` 非空 | D199 | PASS |
| AC-020 默认桩下 `throughput_rps` **仍可判** | `lib/load-exec.mjs`（`judgeThresholds` 的吞吐分支） | 核 `verdict ∈ {met, not_met}` 且 `observed == observed.effective_rps` | D199 | PASS |
| AC-021 延迟分位映射**正确** | `lib/load-exec.mjs`（`judgeThresholds` 的分位取值） | 判 `met`/`not_met` 时 `observed == observed.percentiles[key]`；判 `undetermined` 时为 `null` | D198 | PASS |
| AC-022 错误率映射**正确** | `lib/load-exec.mjs`（`mapApiResult` 重算 + `judgeThresholds`） | **重算** `total_errors / total_requests` 并比对（不用抄的数） | D198 | PASS |
| AC-023 汇总判定**不掩盖失败** | `lib/load-exec.mjs`（`aggregateVerdict` + `undetermined_keys` 汇总） | 核三类计数之和 == 总数、计数与逐条对得上、任一 `not_met` ⇒ 套件不得判 `met`、**联合口径**（错误率 `not_met` ⇒ 吞吐不得判 `met`） | D190 / D197 | PASS |
| AC-024 产物**不得**出现生产容量表述 | `lib/load-exec.mjs`（措辞与限定语） | 全文扫描禁表述（生产 / 容量达标 / 可承载 / 上线 / production）+ 必须出现「本地桩」或 `127.0.0.1` | D205 | PASS |
| AC-025 判定用词**不与用例级混用** | `lib/load-exec.mjs`（判定枚举封闭 3 值） | 扫全部字符串值与键名：无 `passed` / `failed` / `blocked` / `skipped`，无用例级文件名 | D191 | PASS |
| AC-026 API 模式标 `api_equivalent` 且**实际执行参数可核** | `lib/load-exec.mjs`（`reverseArgv` + `executed_params`） | 独立反解 `argv` 并与 `executed_params` 逐键比对（`maxSeconds` / `concurrency` / `method` / `requestsPerSecond` / `agentKeepAlive` / `timeout`） | D200 / D202 | PASS |
| AC-027 CLI 模式**逐字执行**且**能力降级如实标注** | `lib/load-exec.mjs`（`parseCliStdout` + `execution.cli` 段） | 核 `cli_verbatim`、`execution.cli` 恰好 2 键、无 `executed_params`、`error_codes` 只有 `"-1"` 桶、4 个分位均为 number | D201 / D192 | PASS |
| AC-028 **只写** `results/`，输入只读 | `lib/load-exec.mjs`（落盘只落在 `results/`） | 跑前跑后对项目根（除 `results/` 外）取文件集合 + 内容 sha256 指纹并比对 | D186 / D191 | PASS |
| AC-029 产物已存在 ⇒ **报错不覆盖** | `lib/load-exec.mjs`（`runSuite` 的存在性检查） | 同一项目根第二次跑：rc=1、既有产物 sha256 **逐字未变** | D186 | PASS |
| AC-030 结构级幂等（**不承诺数值幂等**） | `lib/load-exec.mjs`（无随机 id / 理由文本不含观测数值） | 同一输入跑两次（两个不同输出目录），按 6 类归一化（数值 / 时间戳 / 桩端口 / 项目根路径 / `results_sha256` / 直方图桶键集）后**逐字相同** | D207 | PASS |
| AC-031 用法错误 ⇒ 退出码 `2` | `scripts/run-load-test.mjs`（`parseArgs` + `UsageError`） | 三种用法错误（缺 `--load-dir` / 未知参数 / 多余位置参数）各跑一次：退出码均 2，且**不留** `results/` | D210 | PASS |
| AC-032 输入非法 ⇒ 退出码 `1` 且**点名** | `lib/load-exec.mjs`（`validatePlan` / `reverseArgv` / `assertLoopbackUrl`） | 四类非法夹具各跑一次：rc=1、stderr 点名坏点、**不留** `results/` | D194 / D210 | PASS |
| AC-033 工具不可用 ⇒ 明确报错且**不产产物** | `lib/load-exec.mjs`（`resolveTool`，**执行前**检查） | 挪走 `.tools/` 后跑：rc=1、stderr 点名缺 `loadtest` 与怎么装（`qa install`）、**不留** `results/` | D206 | PASS |
| AC-034 证据目录与 sha256 清单**可复算** | `lib/load-exec.mjs`（证据落盘 + `manifest.json`） | 核每个 `step_index` 一个子目录、恰好 3 个文件、清单里的 sha256 **独立复算一致** | D208 | PASS |
| AC-035 执行结束后**桩已停**（无残留） | `lib/stub.mjs`（`stop` 连同残留连接一起断开）+ `lib/load-exec.mjs`（`finally` 必停） | 跑完探该端口（应被拒）+ 进程表里查不到桩进程 | D196 | PASS |
| AC-036 交付包不含内部运行时字样 + B 阶段交付物齐备 + 校验器**有行为护栏** | `skills/load-profile/**` + `feature-meta/load-runner/**` | 扫交付包全文（0 命中）+ 五个交付物齐备 + 校验器对合法根 rc=0、对篡改副本 rc=1 | D187 / D185 | PASS |
| AC-037 追溯件四件套含本 REQ 的条目 | `feature-meta/load-runner/`（四件套） | 四个文件齐备且含 `REQ-013`；决策号并集 == 契约的 26 条（按行内最后一个 `REQ-\d+` 归属） | D185 | PASS |
| AC-038 `SKILL.md` **追加**了 B 阶段说明 | `skills/load-profile/SKILL.md`（**只追加**一节） | 核含 B 阶段入口 `run-load-test` 与「本地桩 / `127.0.0.1`」的边界表述；既有内容**逐字未改** | D185 | PASS |
| AC-039 注入错误后，错误码是**真实 HTTP 状态码** | `lib/load-exec.mjs`（API 模式**必设** `statusCallback`） | `--stub-error-rate 1` 跑一次：核 `error_rate == 1`、错误码键是 `"500"`（**不得**是 `"-1"`）、其计数 == `total_requests` | D200 | PASS |
| AC-040 桩行为**注入后**，延迟类与错误率类阈值**恢复可判** | `lib/load-exec.mjs`（`judgeThresholds` 的非默认桩分支） | `--stub-delay-ms 50` 跑一次（两个夹具）：核 `delay_ms == 50`、延迟三类与 `error_rate` 判 `met`/`not_met` 且 `observed` 是 number | D199 / D193 | PASS |
| AC-041 `python` runner 的 invocation 一律「不可判定」 | `lib/load-exec.mjs`（`runInvocation` 的 python 分支 + `judgeThresholds`） | 核 `observed` **缺席**、`verdict == "undetermined"`、判定为空数组、**仍有** `step_index` 证据子目录、`stub_observed.requests` 合法 | D203 | PASS |
