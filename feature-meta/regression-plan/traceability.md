# REQ-011 追溯性矩阵

- 需求：REQ-011「R2 回归轮：`regression-plan` skill + 套件层组合门」
- 分支：`feature/REQ-011`
- 交付位置：
  - `skills/regression-plan/`（skill：regression-plan）
    - `SKILL.md`（入口：影响面判定落在脚本上）
    - `skill-meta.json`（版本与依赖声明）
    - `references/regression-plan-schema.md`（`regression-plan.json` 字段契约）
    - `references/impact-rules.md`（影响面判定规则）
    - `scripts/plan-regression.mjs`（主脚本：产计划）
    - `scripts/check-plan.mjs`（校验器：查计划自洽）
    - `scripts/lib/`（io / cli / changelog / impact / plan 五个内部模块）
  - `bin/verify-suite.mjs`（套件层组合门）、`bin/test-agent-skills.mjs`（安装器的 `verify` 子命令）
  - `skills/test-case-design/skill-meta.json`、`skills/test-execute/skill-meta.json`、
    `skills/qa-toolchain/skill-meta.json`（版本与依赖声明）
  - `README.md`（第 4 个 skill 的说明与组合门用法）
  - `feature-meta/regression-plan/`（本 REQ 的交付侧追溯件）
- 验收脚本（BA 的资产，本 REQ 未改动）：
  `BA/demands/REQ-002-suite-foundation/REQ-011-regression-plan/verify-acceptance.sh`
- 需求文档（只读）：`BA/demands/REQ-002-suite-foundation/REQ-011-regression-plan/`
  （`acceptance.md` 判据集 28 条 / `decisions.md` D35~D44）
- 验收脚本的 sha256 钉版值：`54efde3477e68f1aa70e9bdd4770873d0cd7a4216d8638f846c5daac69e5bd4a`

> 本 REQ 的验收判据集共 28 条判据（AC-001~AC-028），下表逐条给出交付位置与自验方式。

| AC | 交付位置 | 自验方式 | 结论 |
|---|---|---|---|
| AC-001 regression-plan skill 存在且结构合法 | `skills/regression-plan/SKILL.md`、`skills/regression-plan/scripts/plan-regression.mjs`、`skills/regression-plan/scripts/check-plan.mjs`、`skills/regression-plan/references/regression-plan-schema.md`、`skills/regression-plan/references/impact-rules.md` | 查目录与五个文件真实存在且非空；frontmatter 含 `name: regression-plan` 与非空 `description`；两个脚本过 `node --check` | PASS |
| AC-002 每个 skill 都声明版本与依赖 | `skills/test-case-design/skill-meta.json`、`skills/test-execute/skill-meta.json`、`skills/qa-toolchain/skill-meta.json`、`skills/regression-plan/skill-meta.json` | 逐 skill 核对 `name`（等于目录名且与 frontmatter 一致）、`version` 为 `<数字>.<数字>.<数字>`、`requires` 的值形如 `>=<x.y.z>`；并核 `test-execute` 的 requires 含 `test-case-design` | PASS |
| AC-003 README 的 skill 清单与实际目录一致 | `README.md` | 取 README 提到的 skill 名集合与 `skills/` 下含 `SKILL.md` 的目录名集合比对，须完全相等 | PASS |
| AC-004 新产物不得打破既有目录契约 | `skills/regression-plan/scripts/plan-regression.mjs`（产物写到轮次目录内） | 在合法项目的轮次目录内放 `regression-plan.json` 后跑 `skills/test-case-design/scripts/verify-layout.mjs`，退出码 0 且无 FAIL 级问题 | PASS |
| AC-005 不得凭空造用例 | `skills/regression-plan/scripts/lib/plan.mjs` | 计划里的 `case_id` 逐个回查输入用例集的 `cases[].id` | PASS |
| AC-006 命中需求条目的用例必须在 selected | `skills/regression-plan/scripts/lib/impact.mjs` | 对命中需求条目**且未被方法挡住**的 active 用例，逐个断言出现在 `selected` | PASS |
| AC-007 命中维度的用例必须在 selected | `skills/regression-plan/scripts/lib/impact.mjs`、`skills/regression-plan/scripts/lib/changelog.mjs` | 显式 `@dim:` 路径与 `applies_when` 信号词路径分别断言；两条路径用不同维度，堵掉一条不掩盖另一条 | PASS |
| AC-008 显式引用用例的变更条目必须把该用例选进来 | `skills/regression-plan/scripts/lib/changelog.mjs`、`skills/regression-plan/scripts/lib/impact.mjs` | 取变更条目的 `case_refs`，断言对应用例出现在 `selected` | PASS |
| AC-009 不在影响面内的用例不得进 selected | `skills/regression-plan/scripts/lib/impact.mjs` | 独立重算影响面，取不满足者与 `selected` 的 id 集合求交集，须为空 | PASS |
| AC-010 selected 等于按计划自记 basis 重算的并集 | `skills/regression-plan/scripts/lib/plan.mjs` | 以计划记录的 `requirement_refs` / `case_refs` / `dimensions` 为数据独立重算，与 `selected`、`needs_review` 逐项相等 | PASS |
| AC-011 每条选样都必须有可解释的来源 | `skills/regression-plan/scripts/lib/impact.mjs` | 每条选样的 `reason` 非空、`change_refs` 非空且都存在于 `changes[].id`；来源标记逐个对上输入与库里的事实 | PASS |
| AC-012 判不了的变更必须显式列出 | `skills/regression-plan/scripts/lib/impact.mjs`（`findUndecidable`） | 无显式引用且正文未命中任何维度/方法信号的条目须出现在 `undecidable_changes[]` 且 `reason` 非空 | PASS |
| AC-013 判不了的变更不得让任何用例进 selected | `skills/regression-plan/scripts/lib/impact.mjs` | 断言没有任何 `selected` 条目的 `change_refs` 含判不了条目的 id | PASS |
| AC-014 坏引用必须报错，不得静默 | `skills/regression-plan/scripts/plan-regression.mjs`（`verifyReferences`） | 三份坏 changelog（`@R-99` / `@TC-999` / `@dim:not-a-real-dimension`）实跑：退出码 1（非 0 非 2）且输出点名那个 id 或维度名；三类坏引用是同一类（引用指向的实体在权威来源里不存在） | PASS |
| AC-015 摘要数字与影响面完整声明 | `skills/regression-plan/scripts/lib/plan.mjs` | `summary` 的四个数字与对应集合长度逐字相等；`impact_complete` 与判不了条数不矛盾 | PASS |
| AC-016 非 active 的用例不得进 selected | `skills/regression-plan/scripts/lib/impact.mjs` | 输入里 `status != active` 的用例 id 不得出现在 `selected` 的 id 集合中 | PASS |
| AC-017 方法 not_applies_when 命中的用例必须进 needs_review | `skills/regression-plan/scripts/lib/impact.mjs`（`blockedBy`） | 用了被挡住方法且落在影响面内的用例须在 `needs_review`，且不在 `selected` | PASS |
| AC-018 三个集合必须两两互斥 | `skills/regression-plan/scripts/lib/impact.mjs` | `selected` 与 `needs_review` 的 id 集合求交集，须为空 | PASS |
| AC-019 不得修改输入用例集 | `skills/regression-plan/scripts/plan-regression.mjs` | 跑前跑后各算一次用例集 sha256，须完全相同 | PASS |
| AC-020 同一输入两次跑输出逐字相同（除时间戳） | `skills/regression-plan/scripts/lib/plan.mjs` | 两次跑到两个不同临时目录，排除时间戳字段后逐行比对，须完全相同 | PASS |
| AC-021 安装器提供组合校验子命令并把包装到临时根校验依赖图 | `bin/test-agent-skills.mjs`（`verify` 子命令）、`bin/verify-suite.mjs` | `--help` 列出该子命令；`--root <临时目录>` 跑它后临时根里出现全部 skill 目录；把某条 `requires` 改成不可能满足的版本后退出码非 0 | PASS |
| AC-022 组合门必须实跑跨 skill 组合场景 | `bin/verify-suite.mjs`（两个组合场景） | 临时根里实跑：offline 夹具结果为 4 passed / 1 failed / 1 blocked / 0 skipped；轮次初始化 → 带轮次执行 → `cycle.json` 的 execute 阶段为 `in_progress` 且 `stages.execute.runs[]` 记入本次 run_id | PASS |
| AC-023 依赖不满足时必须报版本问题 | `bin/verify-suite.mjs`（`checkGraph`） | 退出码非 0；输出点名出问题的 skill、给出要求与实际两个版本值；输出里不出现下游业务错的特征串 | PASS |
| AC-024 组合门必须隔离，不得改动真实安装根 | `bin/verify-suite.mjs` | 跑组合门前后各算一次真实安装根下各 skill 目录的 sha256 清单，须完全相同 | PASS |
| AC-025 选样核心逻辑必须被变异体测出差异 | `skills/regression-plan/scripts/lib/impact.mjs`、`skills/regression-plan/scripts/lib/plan.mjs` | 在副本上依次注入 8 个结构合法的变异（忽略 case_refs / 忽略维度信号 / 不做方法检查 / 忽略 status / 丢弃判不了条目 / 静默坏引用 / 摘要写死 / 塞进不存在的用例 id），每个变异至少让一条判据判红，还原后回到基线 | PASS |
| AC-026 追溯件必须与实际一致且不得改写 REQ-006 的追溯件 | `feature-meta/regression-plan/status.md`、`feature-meta/regression-plan/traceability.md`、`feature-meta/regression-plan/verification-report.md`、`feature-meta/regression-plan/manifest.json` | 四件套存在且非空；根目录 `feature-meta/manifest.json` 的 req 仍是 REQ-006；追溯矩阵行数与判据条数相等且编号集合一致；三份 md 各恰有一处条数声明；决策号集合与 `decisions.md` 实际集合一致；manifest 的 req 与 demand_dir 有效 | PASS |
| AC-027 零第三方依赖 + 可移植（不联网） | `skills/regression-plan/scripts/**`、`bin/verify-suite.mjs` | 扫这些文件的 import/require 与网络调用构造：只允许 node: 内置模块与相对路径，不得出现网络请求构造 | PASS |
| AC-028 SKILL.md 必须把影响面判定落在脚本上 | `skills/regression-plan/SKILL.md` | 查两个脚本的可执行调用序列、禁用措辞、以及三类后果（确定重跑 / 需人工复核 / 判不了）与「判不了不得当成没影响」的表述 | PASS |
