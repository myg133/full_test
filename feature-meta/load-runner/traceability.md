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
