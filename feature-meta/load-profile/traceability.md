# REQ-009 追溯性矩阵

- 需求：REQ-009「压测能力域：`load-profile` skill（负载模型 + runner 适配）」
- 分支：`feature/REQ-009`
- 判据条数：29（AC-001 ~ AC-029）
- 决策号范围：D127~D155
- 需求契约（只读）：`BA/demands/REQ-002-suite-foundation/REQ-009-load-profile/`
  （`demand.md` 功能契约 / `acceptance.md` 判据集 / `decisions.md` 决策记录 / `status.md` 终审裁定）
- 交付位置：
  - `skills/load-profile/`（skill：load-profile）
    - `SKILL.md`（入口：容量目标 → 负载模型 → 压测套件）
    - `skill-meta.json`（版本与依赖声明，`requires` 恰为 `test-case-design` 与 `qa-toolchain`）
    - `references/load-context-schema.md`（输入契约、封闭字段集、阈值成对规则、两层退出码）
    - `references/load-scenario-format.md`（负载模型本体封闭 14 个 + 引用件封闭 3 个 + 套件落位）
    - `references/profile-rules.md`（负载画像 / 阈值 / 链路存在性对账 / 幂等与写入权）
    - `scripts/make-load-profile.mjs`（主入口）
    - `scripts/check-load-profile.mjs`（产物自洽校验器）
    - `scripts/lib/`（catalog / cli / io / context / reconcile / product / validate 七个内部模块）
  - `bin/verify-suite.mjs`（组合门新增 `scenarioLoadProfile`）
  - `README.md`（安装树与 skill 表格两处补 `load-profile`；组合门说明补第 8 条链路）
  - `feature-meta/load-profile/`（本 REQ 的交付侧追溯件四件套）

> 下表逐条给出交付位置与自验方式。判据条数与决策号范围与 `acceptance.md` / `decisions.md` 一致。
> 自验的**真实输出**见 `verification-report.md`。

| AC | 交付位置 | 自验方式 | 对应决策 | 结论 |
|---|---|---|---|---|
| AC-001 `load-profile` skill 存在且结构合法 | `skills/load-profile/`（SKILL.md、skill-meta.json、references×3、scripts×2、lib×7） | 逐个文件查存在且非空；frontmatter 的 `name` 取值 == `load-profile`、`description` 非空；两个脚本**各自**首行 shebang、可执行、`node --check` 通过；`scripts/lib/` 非空 `.mjs` ≥ 3 | D127 | PASS |
| AC-002 每个 skill 都声明版本与依赖 | `skills/load-profile/skill-meta.json`（其余 7 个 skill 的既有声明未改动） | 逐 skill 核 `name` == 目录名 == frontmatter 的 `name`、`version` 形如 `<数字>.<数字>.<数字>`、`requires` 的值形如 `>=<x.y.z>`；并核 `load-profile` 的 `requires` 键集合**恰为** `test-case-design` 与 `qa-toolchain`，**不含** `test-execute` | D128 | PASS |
| AC-003 README 的 skill 清单与实际目录一致（两处都在） | `README.md`（安装树代码块 + skill 表格两处） | 取 README 的 skill 清单集合（表格首格 ∪ `skills/<name>` 路径 ∪ 安装树条目）与 `skills/` 下含 `SKILL.md` 的目录名集合**双向**比对；并分别核 `load-profile` 在表格与安装树里都出现 | D129 | PASS |
| AC-004 新产物不得打破既有目录契约 | 产物落位 `test-assets/load/**`（`scripts/make-load-profile.mjs` 的写盘纪律） | 把产物放进满足上游前置条件的最小项目根，实跑上游 `verify-layout.mjs`，按相对路径 grep 该 load 套件的判定行：全 `[OK]`、无 `[FAIL]`；环境文件缺失 ⇒ 不可判定（前置不满足） | D130 | PASS |
| AC-005 上下文的必填字段与顶层封闭集必须校验 | `skills/load-profile/scripts/lib/context.mjs` | 三种变体（删 `workloads` / `workloads` 改成字符串 / 顶层加 `load_scenario`）各跑一次：退出码均为 1、stderr 点名坏点、输出目录里**不存在** `test-assets/load/` | D131 | PASS |
| AC-006 workload 的引用必须完整（不悬空），且 `target` 格式合法 | `skills/load-profile/scripts/lib/context.mjs` | 两种变体（`environment` 改成 `prod` / `target` 缺空格与前导 `/`）各跑一次：退出码均为 1、stderr 点名坏值（`prod` / `target`）、**无** `test-assets/load/` | D132 | PASS |
| AC-007 workload 的 `id` 必须唯一且格式合法 | `skills/load-profile/scripts/lib/context.mjs` | 两种变体（`id` 重复成 `WL-001` / `id` 改成 `WL-1`）各跑一次：退出码均为 1、stderr 点名坏值、**无** `test-assets/load/` | D132 | PASS |
| AC-008 枚举必须合法，且 `thresholds` 与 `thresholds_source` 必须成对 | `skills/load-profile/scripts/lib/context.mjs` + `scripts/lib/validate.mjs` | 三个变体（`profile.type = ramp` / 删 `thresholds_source` / `tool.runner = jmeter`）各跑一次：退出码均为 1、stderr 点名；合法原文跑一次退出码 0；再遍历产物核 `profile.type` / `tool.runner` / `tool.runtime` / `thresholds` 键的枚举合法 | D133 / D134 | PASS |
| AC-009 负载模型的顶层字段集封闭 14 个，且内层字段集封闭 | `skills/load-profile/scripts/lib/product.mjs`（构造）+ `scripts/lib/validate.mjs`（自检） | 逐场景核顶层键集恰为 14 个（条件字段按有无判）、`schema_version == 1`、`profile` 恰为 `{type, steps}`、`steps[]` 恰为 `{duration_s, concurrency}`、`tool` 恰为 `{runner, runtime}`、`traceability` 恰为 3 个；`report.json` 顶层恰为 5 个 | D135 | PASS |
| AC-010 梯度与阈值必须逐字可追溯到输入 | `skills/load-profile/scripts/lib/product.mjs`（逐字拷贝输入值） | 逐场景比对 `target` / `environment` / `service` / `profile`（含步序）/ `tool` / `args` / `thresholds` / `thresholds_source` 与输入对应值：键序无关、值逐字相等；输入没有 `args` 时产物**不得**有 `args` 键 | D136 | PASS |
| AC-011 `thresholds_status` 二态必须与输入一致（键的有无） | `skills/load-profile/scripts/lib/product.mjs` | 逐场景核 `thresholds_status` 只取 `provided` / `not_provided`；输入有来源 ⇒ 两个阈值键都在；输入没有 ⇒ 两个键**都不在** | D137 | PASS |
| AC-012 场景文件名必须合命名约定，且与体内 `name` 一致 | `skills/load-profile/scripts/lib/product.mjs`（文件名 = `<name>.json`） | 列出 `scenarios/` 的文件名：基名合 `^[a-z0-9][a-z0-9-]*$`、去掉 `.json` 等于体内 `name`、只有 `.json` 后缀 | D138 | PASS |
| AC-013 每个容量目标恰好一个场景模型 | `skills/load-profile/scripts/lib/product.mjs`（按 workload 一一派生） | 场景条数 == workload 条数；场景 `id` 集合与 workload `id` 集合**双向相等**；场景 `id` 文件内唯一 | D139 | PASS |
| AC-014 不得凭空造阈值（不加键、不改值） | `skills/load-profile/scripts/lib/product.mjs` + `scripts/lib/validate.mjs` | 逐场景核 `provided` 的 `thresholds` 键集与每个值逐字等于输入（不多键、不改值）；`not_provided` 的场景**不得**有 `thresholds` 键 | D140 | PASS |
| AC-015 套件目录名必须合规，且套件必须按环境分组 | `skills/load-profile/scripts/lib/product.mjs`（`buildProducts` 的分组与编号） | 列 `suites/` 目录：恰 2 个、目录名合 `^LOAD-\d{3}-<短名>$`、`suite` 字段 == 目录名、套件内场景环境相同且等于套件环境、同一 workload 不出现在两个套件、短名 == 该套件第一个场景的 `name` | D141 / D144 | PASS |
| AC-016 `suite.json` 的顶层字段集与取值必须合法 | `skills/load-profile/scripts/lib/product.mjs`（`suiteDoc` 只写 6 个必填字段） | 逐套件核顶层键集 ⊆ 上游 9 个允许字段（**无** `load_scenario`）、六个必填都在且非空、`scope == "load"`、`executor == "load"`、`cases_file == "scenario.json"`、`environment` 在 `test-assets/environments/` 下有同名文件 | D142 | PASS |
| AC-017 套件级 `scenario.json` 必须是引用，且与本体不得漂移 | `skills/load-profile/scripts/lib/product.mjs`（`refDoc` 只放 `{path,id,name}`） | 逐套件核顶层键集恰为 3 个、`schema_version == 1`、`suite` == 目录名、`scenarios` ≥1 项、元素键集恰为 `{path,id,name}`、每个 `path` 解析后真实存在且落在 `scenarios/` 下、每个 `id`/`name` 与本体**逐字相等** | D143 | PASS |
| AC-018 产物必须能被上游 `test-execute` 的加载层消费 | `skills/load-profile/scripts/make-load-profile.mjs`（产出上游可解析的 `suite.json`） | 单独进程实跑上游 `suite-loader.mjs` 的 `loadSuite()`：不抛错，且返回的 `config.scope == "load"`、`config.executor == "load"`、`cases_file` 解析到真实存在的文件 | D145 | PASS |
| AC-019 场景模型 ↔ 套件的双向覆盖完整性 | `skills/load-profile/scripts/lib/validate.mjs`（`inspectProducts`） | 按引用件收集每个套件引用到的本体 id：每个容量目标**恰好**被 1 个套件引用、每个套件 ≥1 个引用、每个场景 ≥1 次被引用、无引用不存在模型的孤儿套件、每套件引用集合 == 其环境下的 workload id 集合 | D146 | PASS |
| AC-020 边界红线：环境不得有 `driver`、`executor` 必须是 `load`、不得产出 `cases.json`、不得产生执行产物 | `skills/load-profile/scripts/lib/product.mjs`（不写环境文件、不写 `cases.json`）+ `scripts/lib/validate.mjs` | 读每个套件指向的环境文件查有没有 `driver` 键（**没有**）；逐套件核 `executor == "load"`；查套件目录里没有 `cases.json`；查 `<out-dir>` 下没有 `runs` / `evidence` 目录 | D147 / D148 | PASS |
| AC-021 没有指标来源 ⇒ 不写阈值，且必须留未决问题 | `skills/load-profile/scripts/lib/product.mjs`（派生 `topic=thresholds` 未决问题） | 逐场景核 `not_provided` 的场景 `open_questions` 里 ≥1 条 `topic == "thresholds"` 且 `question` 非空；`provided` 的场景**不得**有 `topic == "thresholds"` 的条目 | D149 | PASS |
| AC-022 不得把「未压测」写成「已通过」 | `skills/load-profile/scripts/lib/validate.mjs`（`scanForbiddenKeys`） | 递归扫全部产物 JSON 的**任意层级**：键名 `status` / `result` / `verdict` / `executed` / `passed` / `outcome` / `conclusion` 一个都不许出现（`thresholds_status` 这类不算） | D135 | PASS |
| AC-023 未决问题必须字段齐全、id 唯一，且「无对应用例」必须留痕 | `skills/load-profile/scripts/lib/product.mjs` + `scripts/lib/validate.mjs` | 逐场景与 `report.json` 核：每条未决问题键集恰为 `{id,topic,question}`、`id` 合 `^OQ-\d{3}$` 且文件内唯一、`topic` ∈ 4 值、`question` 非空；`case_refs` 为空的场景必留 ≥1 条 `topic == "coverage"` | D149 | PASS |
| AC-024 与功能用例集只做链路存在性对账；不派生用例、不扩方法库 | `skills/load-profile/scripts/lib/reconcile.mjs`（归一化 + `case_refs`） | 用归一化规则独立复算每个 workload 的期望 `case_refs` 并与产物**恰等**比对（含 `{id}` 占位符归一化后的匹配）；核 `traceability.workload_id` / `requirement_refs` 逐字相等；扫全部产物没有 `method` 字段、没有 `cases.json` | D150 / D155 | PASS |
| AC-025 幂等：两份产物必须逐字相同 | `skills/load-profile/scripts/lib/product.mjs`（产物不含任何时间戳字段） | 同一输入跑两次（两个不同 `--out-dir`）：相对路径集合相等 + 每个同名文件 sha256 相同（逐字 diff 为空） | D151 | PASS |
| AC-026 只写自己的目录 | `scripts/make-load-profile.mjs`（写入范围只有 `<out-dir>/test-assets/load/`） | 跑前跑后对 `<out-dir>` 下除 `test-assets/load/` 外的一切取指纹：文件集合与内容逐字未变；环境文件 / 轮次文件 sha256 与夹具一致 | D152 | PASS |
| AC-027 不得改输入 | `scripts/make-load-profile.mjs`（输入只读） | 跑前跑后对 `--context` / `--cases` 各算一次 sha256：完全一致 | D152 | PASS |
| AC-028 产物已存在即报错，且不得覆盖 | `scripts/make-load-profile.mjs`（`assertWritable`） | 同一 out-dir 连跑两次：第二次退出码为 1、stderr 点名「产物已存在」、既有产物**逐字未变** | D153 | PASS |
| AC-029 交付侧记账必须与实际一致 | `feature-meta/load-profile/`（四件套）+ 包内根 `feature-meta/manifest.json` **逐字未动** | 核四件套齐全非空、子目录 `manifest.json` 的 `req == "REQ-009"`、根 `manifest.json` 的 `req` 仍是 `REQ-006`、既有四个子目录四件套未被动；追溯矩阵行数 == 判据条数、编号集合 == 判据编号集合；三份 md 的判据条数取值唯一、决策号取值唯一 | D154 | PASS |
