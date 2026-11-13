# REQ-007 追溯性矩阵

- 需求：REQ-007「缺陷复现能力域：`defect-verify` skill（R3 缺陷复现用例生成）」
- 分支：`feature/REQ-007`
- 判据条数：**29**（AC-001~AC-029）
- 决策号范围：**D72~D97**
- 需求文档（只读）：`BA/demands/REQ-002-suite-foundation/REQ-007-defect-verify/`
  （`acceptance.md` 判据集 / `decisions.md` 决策记录）
- 交付位置：
  - `skills/defect-verify/`（skill：defect-verify）
    - `SKILL.md`（入口：三类处置结论 + 产物形状 + 硬约束）
    - `skill-meta.json`（版本与依赖声明，`requires` 含 `test-case-design` 与 `test-execute`）
    - `references/defect-input-schema.md`（缺陷单格式 + 两层合法性划分 + 轮次契约）
    - `references/derivation-rules.md`（派生规则 + 归一化口径 + 编号约定 + 共享场景裁定）
    - `scripts/make-defect-cases.mjs`（主入口）
    - `scripts/check-defect-cases.mjs`（产物自洽校验器）
    - `scripts/selftest-defect-cases.mjs`（派生规则单元自测，含共享场景）
    - `scripts/lib/`（cli / io / normalize / validate-defects / derive / product 六个内部模块）
  - `bin/verify-suite.mjs`（组合门新增 `scenarioDefectVerify`）
  - `README.md`（安装树与 skill 表格两处补 `defect-verify`；组合门说明补第四条链路）
  - `feature-meta/defect-verify/`（本 REQ 的交付侧追溯件）

> 下表逐条给出交付位置与自验方式。判据条数与决策号范围与 `acceptance.md` / `decisions.md` 一致。

| AC | 交付位置 | 自验方式 | 结论 |
|---|---|---|---|
| AC-001 defect-verify skill 存在且结构合法 | `skills/defect-verify/`（SKILL.md、skill-meta.json、两份 references、两个脚本、`scripts/lib/` 六个模块） | 逐个文件查存在且非空；frontmatter 的 `name` 取值 == `defect-verify`、`description` 非空；两个脚本**各自**首行 shebang、可执行、`node --check` 通过；`scripts/lib/` 非空 `.mjs` ≥ 3 | PASS |
| AC-002 每个 skill 都声明版本与依赖 | `skills/defect-verify/skill-meta.json`（其余 5 个 skill 的既有声明未改动） | 逐 skill 核 `name` == 目录名 == frontmatter 的 `name`、`version` 形如 `<数字>.<数字>.<数字>`、`requires` 的值形如 `>=<x.y.z>`；并核 `defect-verify` 的 `requires` **同时**含 `test-case-design` 与 `test-execute` | PASS |
| AC-003 README 的 skill 清单与实际目录一致（两处） | `README.md`（安装树代码块 + skill 表格两处） | 取 README 的 skill 清单集合（表格首格 ∪ `skills/<name>` 路径 ∪ 安装树条目）与 `skills/` 下含 `SKILL.md` 的目录名集合**双向**比对；并分别核 `defect-verify` 在表格与安装树里都出现 | PASS |
| AC-004 新产物不得打破既有目录契约 | 产物落位 `test-assets/cycles/<R3 轮次>/defect-cases.json`（`scripts/make-defect-cases.mjs` 的写盘纪律） | 造满足 REQ-002B 契约的最小项目并放入产物，跑 `verify-layout.mjs`：退出码 0、0 条 FAIL；错误位置探针（产物挪到 `test-assets/` 根）结论 = **位置不受约束**（校验器不查该位置） | PASS |
| AC-005 缺陷单的必填字段必须校验（结构层） | `skills/defect-verify/scripts/lib/validate-defects.mjs` | 四种变体（缺 `id` / 缺 `title` / 缺 `severity` / `reproduction` 改成字符串）各跑一次：退出码均为 1、stderr 点名字段名、输出目录**无** `defect-cases.json` | PASS |
| AC-006 输入非法时必须报错退出，且不留半份产物 | `skills/defect-verify/scripts/lib/io.mjs`（先校验后写盘 + 原子写） | 三种非法缺陷单（根是数组 / `defects` 不是数组 / 文件不是合法 JSON）各跑一次：退出码均为 1、stderr 点名、**无**产物（按存在性判定） | PASS |
| AC-007 缺陷 id 必须唯一且格式合法 | `skills/defect-verify/scripts/lib/validate-defects.mjs` | 两种变体（`defects[1].id` 改成 `BUG-001` 重复 / `defects[0].id` 改成 `BUG-XYZ`）各跑一次：退出码均为 1、stderr 点名坏点、**无**产物 | PASS |
| AC-008 `severity`（与 `status`）的枚举必须合法 | `skills/defect-verify/scripts/lib/validate-defects.mjs` | 两种变体（`severity=critical` / `status=reopened`）各跑一次：退出码均为 1、stderr 点名字段与越界值、**无**产物 | PASS |
| AC-009 `case_refs` 命中即复用；找不到即改判 `unresolved` | `skills/defect-verify/scripts/lib/derive.mjs`（`decide()` 的 `case_refs` 分支 + `dedupeIds()`） | 夹具跑一次：`BUG-001` → `reused` 且 `reused_case_refs` 恰为 `[{suite,TC-017}]`、无 `derived_case_id`、无 `reason`；`BUG-002` → `unresolved` 且理由**含 `TC-099`**、无 `reused_case_refs`、无 `derived_case_id`；产物里没有以 `BUG-001` 为 `defect_refs` 的派生用例。另由单元自测 T1/T2 覆盖去重与部分命中 | PASS |
| AC-010 特征匹配命中即复用（不得新建用例） | `skills/defect-verify/scripts/lib/normalize.mjs`（`featureMatches()`）+ `lib/derive.mjs` | 夹具跑一次：`BUG-003` → `reused`，`reused_case_refs` 恰为 `[{suite,TC-021}]`，无 `derived_case_id`；产物里没有以 `BUG-003` 为 `defect_refs` 的派生用例 | PASS |
| AC-011 未命中才派生 | `skills/defect-verify/scripts/lib/derive.mjs`（特征匹配未命中分支） | 夹具跑一次：`BUG-005` → `derived`，`derived_case_id` 非空且等于产物里那条用例的 `id`；该用例 `origin == "derived"`、`defect_refs` 含 `BUG-005`；无 `reused_case_refs`、无 `reason` | PASS |
| AC-012 复现信息不足必须判 `unresolved` 并给非空理由 | `skills/defect-verify/scripts/lib/derive.mjs`（`missingReproductionInfo()`） | 夹具跑一次：`BUG-004` → `unresolved`，理由非空且说明缺什么（不含 `TC-099`）；无 `reused_case_refs`、无 `derived_case_id`；产物 `cases[]` 里没有引用 `BUG-004` 的用例 | PASS |
| AC-013 派生的新用例必须落在扩展编号段且不撞号 | `skills/defect-verify/scripts/lib/product.mjs`（`allocateId()`：从 `TC-101` 起向上扫描） | 夹具的输入用例集**故意占用 `TC-101`** ⇒ 派生用例落在 `TC-102`；断言其 `id` 不与输入用例集的任何 `id` 相同、且在产物内唯一（单元自测 T4） | PASS |
| AC-014 处置结论必须互斥且完备 | `skills/defect-verify/scripts/lib/product.mjs`（`defects[]` 装配）+ `scripts/check-defect-cases.mjs` | 逐条核：`defects[]` 条目数 == 输入缺陷数；每条 `disposition` ∈ 三值；每条**有且只有一个**结论字段；每条的字段集恰是封闭的那几个（`id`/`title`/`severity`/`status`/`disposition` + 条件字段）；顶层字段集恰为 7 个 | PASS |
| AC-015 复现用例的 `id` 必须合 `^TC-\d{3}$` | `skills/defect-verify/scripts/lib/product.mjs`（扩展段分配）+ `scripts/check-defect-cases.mjs` | 遍历产物 `cases[]` 的每个 `id` 核正则与唯一性；共享场景下同一用例只出现一次（单元自测 T3） | PASS |
| AC-016 复现用例的必填字段齐全且 `requirement_refs` 不悬空 | `skills/defect-verify/scripts/lib/product.mjs`（`requirements[]` 与 `coverage_matrix[]` 装配） | 遍历产物 `cases[]` 核 `id`/`title`/`requirement_refs`/`dimension`/`priority`/`method`/`status`/`steps`/`tags`；每项 `requirement_refs` ∈ `requirements[].id`；`coverage_matrix[]` 的 `requirement` ∈ `requirements[].id`，且每个有对应用例的需求条目都在里面 | PASS |
| AC-017 `defect_refs` / `origin` / `source_case_id` / `source_suite` 必须齐全 | `skills/defect-verify/scripts/lib/product.mjs`（`buildReusedCase()` / `buildDerivedCase()`） | 遍历产物 `cases[]` 核四个字段；`origin == "reused"` ⇒ `source_case_id` 非空且 ∈ 输入用例 id 集合、`source_suite` 非空；`origin == "derived"` ⇒ 两者为 `null` | PASS |
| AC-018 `tags` 必须含 `defect-verify` 与该缺陷的 id | `skills/defect-verify/scripts/lib/product.mjs`（tags 组装：原 tags ∪ `defect-verify` ∪ 缺陷 id） | 遍历产物 `cases[]` 核 `tags` 含 `defect-verify`，且含它 `defect_refs` 里的**每一个**缺陷 id | PASS |
| AC-019 产物必须能被 `test-execute` 直接消费 | 产物形状 + `skills/defect-verify/references/derivation-rules.md`（`suite.json` 的固定形状） | 拿产物当 `cases_file` 让 `run-suite.mjs --dry-run` 真跑：退出码 0、计划 3 条 == 产物 `cases.length`；再把 `tags.include` 换成 `["BUG-005"]` 跑一次：计划 1 条 == 引用 `BUG-005` 的用例数 | PASS |
| AC-020 输出的缺陷 id 集合必须等于输入的缺陷 id 集合 | `skills/defect-verify/scripts/lib/product.mjs`（`defects[]` 与 `requirements[]` 同序装配） | 比对产物 `defects[].id` 集合与输入集合（相等、无重复）；核 `requirements[]` 条目数 == 输入缺陷数，且 `requirements[i].id == R-<i+1>`、`source_ref == defects.json#/defects/<i>` | PASS |
| AC-021 `unresolved` 必须带非空理由 | `skills/defect-verify/scripts/lib/derive.mjs`（`decide()` 的两条 unresolved 分支都必填 `reason`） | 遍历产物 `defects[]` 里 `unresolved` 的条目：每条 `reason` 存在且非空；且一条 `unresolved` 不带 `derived_case_id` / `reused_case_refs` | PASS |
| AC-022 不得凭空造缺陷 | `skills/defect-verify/scripts/lib/product.mjs`（`defects[]` 与 `cases[].defect_refs` 都只取自输入缺陷 id） | 扫描产物 `defects[].id`、`cases[].defect_refs[]`、`requirements[].source_ref`：前两者 ⊆ 输入缺陷 id 集合，后者形如 `defects.json#/defects/<i>` 且下标在范围内 | PASS |
| AC-023 不得重复派生 | `skills/defect-verify/scripts/lib/derive.mjs`（命中即复用、不新建）+ `lib/product.mjs` | 统计每个缺陷在产物里的派生用例条数 ≤ 1；`BUG-001` 与 `BUG-003`（复用）一条派生用例都没有；产物内用例 `id` 互不重复 | PASS |
| AC-024 同一输入两次必须逐字相同（除 `generated_at`） | `skills/defect-verify/scripts/lib/product.mjs`（无随机量、无时间戳）+ `scripts/make-defect-cases.mjs` | 同一输入跑两次、输出到两个不同目录：两份产物把 `meta.generated_at` 替换成占位后**逐字相同**（5003 字节 = 5003 字节） | PASS |
| AC-025 不得修改输入（缺陷单 + 已有用例集） | `skills/defect-verify/scripts/lib/io.mjs`（只读）+ `scripts/make-defect-cases.mjs` | 跑前跑后各算一次两份输入的 sha256 并比对（一致）；并查输入所在目录没有新增文件（跑前跑后都只有 `defects.json` 与 `cases.json`） | PASS |
| AC-026 只写自己的目录 | `skills/defect-verify/scripts/make-defect-cases.mjs`（`assertWritableOutDir()` + 只写一个文件） | 产物落在 `<out-dir>/defect-cases.json`；`cycle.json` 跑前跑后 sha256 一致；输入目录无散落文件；覆盖保护：预先放占位产物再跑一次 ⇒ 报错退出且占位内容未被改写；项目里没有别处出现 `defect-cases.json` | PASS |
| AC-027 R3 轮次契约必须成立，且工具不得改写 `cycle.json` | `skills/defect-verify/scripts/lib/validate-defects.mjs`（`validateCycleDocument()`） | 主跑一次后 `cycle.json` 的 sha256 前后一致；两种变体（`round` 改成 `R2` / `trigger.ref` 改成 `BUG-999`）各跑一次 ⇒ 退出码均为 1、stderr 点名坏点、**无**产物 | PASS |
| AC-028 组合门必须真的跑过 `defect-verify` | `bin/verify-suite.mjs`（`scenarioDefectVerify`：造夹具 → 实跑 `make-defect-cases.mjs` → 从产物反推断言） | 跑组合门：临时根装齐 6 个 skill、依赖图校验通过、4 条组合场景实跑全过；**从临时根的产物反推**：存在非空 `defect-cases.json`，其 `defects[]` 每条有且只有一个 `disposition`、derived 有对应用例、reused 有 `reused_case_refs`、`cases[]` 的 id 唯一；另把 `requires.test-execute` 改成 `>=99.0.0` ⇒ verify 非 0 退出并报**版本问题** | PASS |
| AC-029 交付侧记账必须与实际一致 | `feature-meta/defect-verify/status.md`、`feature-meta/defect-verify/traceability.md`、`feature-meta/defect-verify/verification-report.md`、`feature-meta/defect-verify/manifest.json` | 查四件套齐全且非空；本矩阵行数 == 判据条数且编号集合恰为 AC-001~AC-029；三份 md 各恰一处记载判据条数与决策号范围（取值唯一）；`manifest.json` 的 `req` 为 `REQ-007`；既有追溯件（根四件套 + `test-report/` + `regression-plan/`）逐字未变 | PASS |
