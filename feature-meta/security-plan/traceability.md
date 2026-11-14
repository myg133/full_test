# REQ-008 追溯性矩阵

- 需求：REQ-008「安全能力域：`security-plan` skill（OWASP 全套 + 依赖扫描）」
- 分支：`feature/REQ-008`
- 判据条数：**29**（AC-001~AC-029）
- 决策号范围：**D98~D126**
- 需求文档（只读）：`BA/demands/REQ-002-suite-foundation/REQ-008-security-plan/`
  （`demand.md` 功能契约 / `acceptance.md` 判据集 / `decisions.md` 决策记录 / `status.md` 终审裁定）
- 交付位置：
  - `skills/security-plan/`（skill：security-plan）
    - `SKILL.md`（入口：威胁模型 → 权限矩阵 → 安全用例）
    - `skill-meta.json`（版本与依赖声明，`requires` 含 `test-case-design` 与 `qa-toolchain`）
    - `references/security-context-schema.md`（输入契约与两层退出码）
    - `references/threat-model-format.md`（威胁模型产物契约）
    - `references/threat-derivation.md`（威胁派生规则 + 关键词表 + 扫描发现分类 + 矩阵判定口径）
    - `references/matrix-format.md`（权限矩阵产物契约与决策表）
    - `references/derivation-rules.md`（用例派生与落位规则）
    - `scripts/make-security-plan.mjs`（主入口）
    - `scripts/check-security-plan.mjs`（产物自洽校验器）
    - `scripts/selftest-security-plan.mjs`（派生规则单元自测）
    - `scripts/lib/`（cli / io / catalog / context / scan / threats / matrix / cases / product 九个内部模块）
  - `bin/verify-suite.mjs`（组合门新增 `scenarioSecurityPlan`）
  - `README.md`（安装树与 skill 表格两处补 `security-plan`；组合门说明补第五条链路）
  - `feature-meta/security-plan/`（本 REQ 的交付侧追溯件四件套）

> 下表逐条给出交付位置与自验方式。判据条数与决策号范围与 `acceptance.md` / `decisions.md` 一致。
> 自验的**真实输出**见 `verification-report.md`。

| AC | 交付位置 | 自验方式 | 结论 |
|---|---|---|---|
| AC-001 `security-plan` skill 存在且结构合法 | `skills/security-plan/`（SKILL.md、skill-meta.json、五份 references、三个脚本、`scripts/lib/` 九个模块） | 逐个文件查存在且非空；frontmatter 的 `name` 取值 == `security-plan`、`description` 非空；三个脚本**各自**首行 shebang、可执行、`node --check` 通过；`scripts/lib/` 非空 `.mjs` ≥ 3 | PASS |
| AC-002 每个 skill 都声明版本与依赖 | `skills/security-plan/skill-meta.json`（其余 6 个 skill 的既有声明未改动） | 逐 skill 核 `name` == 目录名 == frontmatter 的 `name`、`version` 形如 `<数字>.<数字>.<数字>`、`requires` 的值形如 `>=<x.y.z>`；并核 `security-plan` 的 `requires` **同时**含 `test-case-design` 与 `qa-toolchain` 且**不含** `test-execute` | PASS |
| AC-003 README 的 skill 清单与实际目录一致（且两处都在） | `README.md`（安装树代码块 + skill 表格两处） | 取 README 的 skill 清单集合与 `skills/` 下含 `SKILL.md` 的目录名集合**双向**比对；并分别核 `security-plan` 在表格与安装树里都出现 | PASS |
| AC-004 新产物不得打破既有目录契约 | 产物落位 `test-assets/security/**`（`scripts/make-security-plan.mjs` 的写盘纪律） | 把产物放进满足上游契约的最小项目根，跑 `verify-layout.mjs`：退出码 0、0 条 FAIL；错误位置探针（`threat-model.json` 挪到 `test-assets/` 根）结论 = **位置不受约束**（校验器只递归找 `suite.json`） | PASS |
| AC-005 上下文的必填字段与类型必须校验（结构层） | `skills/security-plan/scripts/lib/context.mjs` | 五种变体（删 `assets` / `trust_boundaries` 改字符串 / 删 `entry_points[0].name` / 删 `roles` / `resources` 改对象）各跑一次：退出码均为 1、stderr 点名字段名、输出目录**无** `threat-model.json` / `matrix.json` / `suites/` | PASS |
| AC-006 上下文的引用必须完整（不悬空） | `skills/security-plan/scripts/lib/context.mjs`（`checkRefs()`） | 三种变体（`asset_refs` 指到 `AS-999` / `boundary_refs` 指到 `TB-999` / `resources[0].asset_refs` 改空数组）各跑一次：退出码均为 1、stderr 点名坏值、**无**产物 | PASS |
| AC-007 上下文的 id 必须唯一且格式合法 | `skills/security-plan/scripts/lib/context.mjs`（`checkId()`） | 两种变体（`assets[1].id` 改成 `AS-1` 重复 / `entry_points[0].id` 改成 `EP-XYZ`）各跑一次：退出码均为 1、stderr 点名坏点、**无**产物 | PASS |
| AC-008 枚举必须合法，且 `--scan` 的三种形态都要能识别 | `skills/security-plan/scripts/lib/context.mjs`（`sensitivity` 枚举）+ `scripts/lib/scan.mjs` | ① 越界 `sensitivity`、② 空 `kind`、③ 无法识别的扫描文件各跑一次：退出码均为 1、stderr 点名；④ bandit / ⑤ npm audit / ⑥ 扫描状态三种合法形态各跑一次：退出码均为 0 | PASS |
| AC-009 威胁模型的资产 / 信任边界 / 入口点三段必须与输入逐条对应 | `skills/security-plan/scripts/lib/product.mjs`（`buildThreatModel()` 直接抄上下文三段） | 取产物三段的 id 集合与上下文对应段**双向**比对：集合相等、条数相等；`sensitivity` / `controls` / `kind` 逐条一致 | PASS |
| AC-010 威胁字段齐全、id 唯一且枚举合法 | `skills/security-plan/scripts/lib/threats.mjs`（`THREAT_FIELDS` 封闭 12 个） | 遍历产物 `threats[]`：字段集恰为 12 个、`id` 合 `^TH-\d+$` 且唯一、`category` ∈ STRIDE 六类、`owasp` ∈ A01~A10、`severity` 四级、`source` 三态、`source` 含 `scan` ⇔ `scan_refs` 非空 | PASS |
| AC-011 OWASP A01~A10 十类每类都必须有交代 | `skills/security-plan/scripts/lib/threats.mjs`（覆盖状态**从威胁集合反推**） | 产物 `owasp_coverage` 键集恰为 A01~A10；每类 `status` ∈ {covered, not_applicable}；covered ⇒ `threat_refs` 非空且恰为该类全部威胁；不存在既无 covered 也无 not_applicable 的类 | PASS |
| AC-012 判 `not_applicable` 必须带非空理由并留一条未决问题 | `skills/security-plan/scripts/lib/threats.mjs`（`buildClassReasons()` + `openQuestions[]`） | 遍历 `status == "not_applicable"` 的项：`reason` 非空、`open_question_ref` 指向存在的未决问题且其 `category` 等于该类；`open_questions[]` 的 `id` 唯一、`question` 与 `reason` 非空 | PASS |
| AC-013 四类实战补充必须逐类显式判定 | `skills/security-plan/scripts/lib/threats.mjs`（`supplement_refs` + `supplements`） | `supplements` 键集恰为四类；每类有 `status`；covered ⇒ `threat_refs` 非空且被引用威胁的 `supplement_refs` 含该键且**恰为**全部含该键的威胁；not_applicable ⇒ `reason` 非空 | PASS |
| AC-014 扫描发现必须映射成威胁，且「未做扫描」必须显式声明 | `skills/security-plan/scripts/lib/scan.mjs` + `scripts/lib/threats.mjs`（扫描接入段） | ① 主跑：`scan.status == "provided"`、`scan.tool == "bandit"`、`scan_findings` 恰好 2 条且每条 `threat_refs` 非空、被引用威胁 `source` 含 `scan` 且 `scan_refs` 含该 finding；② 不传 `--scan`：`scan.status == "not_provided"`、`scan_findings` 为空、无 `source` 含 `scan` 的威胁；③ 扫描状态形态：`scan.status == "unavailable"`、`scan_findings` 为空 | PASS |
| AC-015 矩阵的形状与引用必须成立 | `skills/security-plan/scripts/lib/matrix.mjs` | 产物 `roles` / `resources` 的 id 集合与上下文**完全相等**；`entries` 非空；每条 `role` / `resource` 不悬空；`action` 非空、`decision` ∈ 两值、`basis` ∈ 两值；每个 `(role, resource)` 组合至少一条 | PASS |
| AC-016 允许缺口必须对应到一条越权类威胁（双向） | `skills/security-plan/scripts/lib/matrix.mjs`（`buildEntry()` + `checkMatrix()`） | 每个 `gap` 条目 `decision == "allow"`、`threat_ref` 指向 `category == "elevation_of_privilege"` 的威胁；`expected` 条目 `threat_ref` 为 `null`；每条越权类威胁都被至少一条 `gap` 引用 | PASS |
| AC-017 每条威胁至少派生 1 条安全用例，且不得重复派生 | `skills/security-plan/scripts/lib/cases.mjs`（`deriveSuites()`） | 汇总全部套件的 `cases[]`，由 `requirement_refs → source_ref` 反推覆盖的威胁：每条威胁至少 1 条用例；同一威胁下的用例 `title` 互不相同、`steps` 不完全相同 | PASS |
| AC-018 用例 `id` 必须合 `^TC-\d{3}$`、全局唯一、且不与输入用例集冲突 | `skills/security-plan/scripts/lib/cases.mjs`（`allocateCaseId()`） | 遍历全部套件的用例 `id`：每个合 `^TC-\d{3}$`、跨套件互不重复、与输入用例集的 `TC-001`/`TC-002`/`TC-003` 无冲突 | PASS |
| AC-019 `requirements[].source_ref` 必须指向真实威胁，`requirement_refs` 不悬空 | `skills/security-plan/scripts/lib/cases.mjs` + `scripts/check-security-plan.mjs` | 每条 `source_ref` 恰为 `threat-model.json#/threats/<TH-id>` 且该威胁真实存在；`requirements[].id` 文件内唯一；每条用例 `requirement_refs` 非空且不悬空；每条威胁至少被一条 requirement 覆盖 | PASS |
| AC-020 产物 `cases.json` 的顶层字段集封闭 7 个，且用例字段齐全 | `skills/security-plan/scripts/lib/cases.mjs`（`CASES_TOP_LEVEL_FIELDS`）+ `scripts/check-security-plan.mjs` | 顶层键集**恰好** 7 个；`schema_version == 2`；`open_questions` / `defects` / `coverage_matrix` 是数组；覆盖矩阵的 `requirement` 不悬空且文件内唯一、每个 requirement 恰好出现一次；每条用例 `dimension == "security"`、`priority` ∈ P0~P3、`method` 非空且每个方法号 ∈ 方法库实际存在的方法、`status` 恒为 `active` 且不带 `revision`、`steps` 每步 `action` 与 `expected` 非空、`tags` 是数组 | PASS |
| AC-021 `tags` 必须含 `security` 与该威胁的 id | `skills/security-plan/scripts/lib/cases.mjs`（tags 组装）+ `scripts/check-security-plan.mjs` | 遍历全部套件的用例 `tags`：每条含 `security`，且含它 `requirement_refs` 经 `source_ref` 反推出的威胁 id | PASS |
| AC-022 套件目录名必须合规，且 `suite` 字段与目录名一致 | `skills/security-plan/scripts/lib/cases.mjs`（`deriveSuites()` 的 `SEC-<编号>-<短名>`） | 列出 `suites/` 下每个目录：至少 1 个、目录名合 `^SEC-\d{3}-[a-z0-9][a-z0-9-]*$`、每个目录同时有 `cases.json` 与 `suite.json`、`suite.json` 的 `suite` 与目录名逐字相等 | PASS |
| AC-023 `suite.json` 的顶层字段集封闭且取值合法 | `skills/security-plan/scripts/lib/product.mjs`（`buildSuiteDocument()`） | 顶层键集 ⊆ 9 个允许字段（**无 `threat_model`**）；六个必填字段存在且非空；`scope == "security"`、`executor == "security"`；`environment` 在 `environments/` 下有同名文件；`cases_file` 指向的文件真实存在 | PASS |
| AC-024 产物必须能被 `test-execute` 的**加载层**消费 | `skills/security-plan/scripts/lib/product.mjs`（产物形状）+ 上游 `skills/test-execute/scripts/lib/suite-loader.mjs` | 每个套件跑 `loadSuite` + `loadCases` + `selectCases`：均不抛错，且 `selectCases` 选出的条数 == 该套件 `cases[]` 条数；再对每个 `cases.json` 跑上游 `validate-cases.mjs`：退出码均为 0（**不要求** `--dry-run` 跑通） | PASS |
| AC-025 威胁集合必须与输入可对账（不悬空、也不漏） | `skills/security-plan/scripts/lib/threats.mjs`（引用校验 + 覆盖兜底） | 遍历每条威胁的三个引用数组：非空且每一项 ∈ 上下文对应段；统计上下文的每个资产 / 每条边界 / 每个入口被多少条威胁引用：**三个都 ≥ 1** | PASS |
| AC-026 不得凭空造威胁，也不得凭空声称「已覆盖」 | `skills/security-plan/scripts/lib/threats.mjs`（`rationale` 非空 + 覆盖状态反推） | 每条威胁 `rationale` 非空、同时锚定 ≥1 个真实资产 + ≥1 条真实边界 + ≥1 个真实入口；每个 `covered` 声明的 `threat_refs` 非空且每一项 ∈ `threats[].id` | PASS |
| AC-027 覆盖声明与事实必须一致（缺口必须显式） | `skills/security-plan/scripts/lib/threats.mjs`（覆盖状态**从威胁反推**⇒ 结构上不可能矛盾） | 逐类核对：`covered` ⇒ `threat_refs` **恰为**该类全部威胁 id；`not_applicable` ⇒ 该类**没有任何**威胁 | PASS |
| AC-028 幂等、只写自己的目录、不得改输入 | `skills/security-plan/scripts/lib/product.mjs`（`assertWritable()` / `writeProducts()`）+ `scripts/make-security-plan.mjs` | ① 幂等：同一输入跑两次（两个不同 out-dir），产物除 `meta.generated_at` 外**逐字相同**；② 只读输入：三份输入的 sha256 跑前跑后一致，输入目录无新增文件；③ 只写 out-dir：out-dir 之外无新增文件；④ 产物已存在即报错：预置占位 `threat-model.json` 再跑 ⇒ 退出码 1 且占位内容逐字未变 | PASS |
| AC-029 交付侧记账必须与实际一致 | `feature-meta/security-plan/status.md`、`feature-meta/security-plan/traceability.md`、`feature-meta/security-plan/verification-report.md`、`feature-meta/security-plan/manifest.json` | 查四件套齐全且非空；本矩阵行数 == 判据条数且编号集合恰为 AC-001~AC-029；三份 md 各恰一处记载判据条数与决策号范围（取值唯一）；`manifest.json` 的 `req` 为 `REQ-008`；既有追溯件（根四件套 + `test-report/` + `regression-plan/` + `defect-verify/`）齐全且非空，包内根 `feature-meta/manifest.json` 的 `req` 仍是 `REQ-006` | PASS |
