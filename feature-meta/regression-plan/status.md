# REQ-011 开发状态

- 需求：REQ-011「R2 回归轮：`regression-plan` skill + 套件层组合门」
- 分支：`feature/REQ-011`
- 状态：**开发完成（待 QA 交叉验证）**
- 实现：
  - `skills/regression-plan/`（skill：regression-plan）—— R2 回归选样（产计划，不执行）
  - `bin/verify-suite.mjs` + `bin/test-agent-skills.mjs`（子命令 `verify`）—— 套件层组合门
  - 四个 skill 根级各一份 `skill-meta.json` —— 版本与依赖声明
- 规模：新增 1 个 skill、1 个套件层组合门子命令、4 份版本声明、3 份交付侧追溯件；
  本 REQ 的验收判据集共 28 条判据（AC-001~AC-028）。
- 实现清单（本次新增/改动的交付文件）：
  - `skills/regression-plan/SKILL.md` —— skill 入口（影响面判定落在脚本上）
  - `skills/regression-plan/skill-meta.json` —— 版本与依赖声明
  - `skills/regression-plan/references/regression-plan-schema.md` —— `regression-plan.json` 字段契约
  - `skills/regression-plan/references/impact-rules.md` —— 影响面判定规则
  - `skills/regression-plan/scripts/plan-regression.mjs` —— 主脚本（产出计划）
  - `skills/regression-plan/scripts/check-plan.mjs` —— 校验器（查计划自洽）
  - `skills/regression-plan/scripts/lib/io.mjs` —— 输入读取与库文件定位（库的唯一来源回落）
  - `skills/regression-plan/scripts/lib/cli.mjs` —— 命令行参数解析
  - `skills/regression-plan/scripts/lib/changelog.mjs` —— 变更日志切分与引用标记抽取
  - `skills/regression-plan/scripts/lib/impact.mjs` —— 影响面判定（核心公式）
  - `skills/regression-plan/scripts/lib/plan.mjs` —— 计划组装
  - `skills/test-case-design/skill-meta.json` —— 版本与依赖声明
  - `skills/test-execute/skill-meta.json` —— 版本与依赖声明（含硬跨 skill 依赖）
  - `skills/qa-toolchain/skill-meta.json` —— 版本与依赖声明
  - `bin/verify-suite.mjs` —— 套件层组合门（临时根 / 依赖图 / 跨 skill 场景实跑）
  - `bin/test-agent-skills.mjs` —— 安装器新增 `verify` 子命令
  - `README.md` —— 补第 4 个 skill 的说明与组合门用法
  - `feature-meta/regression-plan/status.md` —— 本文件（交付侧追溯件）
  - `feature-meta/regression-plan/traceability.md` —— 判据 → 交付位置追溯矩阵
  - `feature-meta/regression-plan/verification-report.md` —— 分层验收结论
- 核心变更：
  - **选样口径** —— 影响面 = 需求命中 ∨ 用例命中 ∨ 维度命中（显式 `@dim:` 或维度 `applies_when`
    信号词）；方法 `not_applies_when` 被变更正文命中 → 该用例进 `needs_review`（判不了，交给人复核）；
    `selected` / `needs_review` / `undecidable_changes` 三个集合两两互斥；
    生命周期状态只作用于 `selected`。
  - **诚实性** —— 坏引用（`@R-99` / `@TC-999` / `@dim:<不存在>`）报错退出并点名那个 id，
    不静默忽略；判不了的变更条目显式列出且不让任何用例因它进 `selected`；
    `summary.impact_complete` 声明影响面是否完整；输入用例集只读。
  - **套件层组合门** —— 把包装到**临时根** → 校验 `requires` 版本配套 → **实跑**跨 skill 场景
    （offline 夹具 4 passed / 1 failed / 1 blocked / 0 skipped；轮次初始化 → 带轮次执行 →
    execute 阶段推进并记入 `stages.execute.runs[]`）；依赖版本不满足时报**版本问题**
    （点名哪个 skill、要求什么、实际什么），不让下游报业务错；组合门不碰真实安装根。
- 自验：
  - 主验收 `BA/demands/REQ-002-suite-foundation/REQ-011-regression-plan/verify-acceptance.sh`
    → **28 PASS / 0 FAIL**（快跑与完整模式一致；完整模式含 AC-025 的 8 个变异体全部检出）
  - 上游回归（REQ-006 主验收 / REQ-002A / REQ-002B）→ 全绿
- 需求文档（只读）：`BA/demands/REQ-002-suite-foundation/REQ-011-regression-plan/`
  （`acceptance.md` 判据集 28 条 / `decisions.md` D35~D47 / `verify-acceptance.sh`，
  sha256 钉版值 `8fc6117d3294cddd313898dbcf91e3243487535450dae1b503d5f809630c4a9c`）
- 上游基线：REQ-006（`test-case-design`）、REQ-004（`test-execute`）、REQ-003（`qa-toolchain`）；
  本 REQ **不改** `test-case-design` 的任何既有文件（只新增根级版本声明）。
