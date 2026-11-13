# REQ-010 开发状态

- 需求：REQ-010「报告能力域：`test-report` skill（执行报告 + 回归对账）」
- 分支：`feature/REQ-010`
- 状态：**开发完成（待 QA 交叉验证）**
- 实现：
  - `skills/test-report/`（skill：test-report）—— 执行报告 + 回归对账（只读消费执行产物）
  - `bin/verify-suite.mjs` —— 组合门扩展：新增一条**真的经过 `test-report`** 的组合场景
  - `skills/test-report/skill-meta.json` —— 版本与依赖声明（`requires` 含 `test-execute`）
  - `README.md` —— 补第 5 个 skill 的说明与组合门用法
  - `feature-meta/test-report/` —— 本 REQ 的交付侧追溯件四件套
- 规模：新增 1 个 skill（6 个文件 + 6 个内部库模块）、1 条组合场景、1 份版本声明、
  4 份交付侧追溯件；本 REQ 的验收判据集共 29 条判据（AC-001~AC-029）。
- 实现清单（本次新增/改动的交付文件）：
  - `skills/test-report/SKILL.md` —— skill 入口（三层结论与红线）
  - `skills/test-report/skill-meta.json` —— 版本与依赖声明
  - `skills/test-report/references/report-schema.md` —— `report.json` 字段契约 + `report_sha256` 规范化口径
  - `skills/test-report/references/report-rules.md` —— 三层结论 / 回归对账 / 诚实性红线
  - `skills/test-report/scripts/make-report.mjs` —— 主入口（产出 `report.json` + `report.md`）
  - `skills/test-report/scripts/check-report.mjs` —— 自洽校验器
  - `skills/test-report/scripts/lib/fingerprint.mjs` —— 指纹算法（sha256）
  - `skills/test-report/scripts/lib/canonical.mjs` —— 规范化序列化与报告自身指纹
  - `skills/test-report/scripts/lib/artifacts.mjs` —— 输入读取与校验（只读消费）
  - `skills/test-report/scripts/lib/analyze.mjs` —— 分析核心（重算 + 三层结论）
  - `skills/test-report/scripts/lib/render.mjs` —— `report.md` 渲染
  - `skills/test-report/scripts/lib/cli.mjs` —— 命令行参数解析
  - `bin/verify-suite.mjs` —— 组合门新增「执行产物 → test-report → 三层结论」场景
  - `README.md` —— 安装树与 skill 表格补 `test-report`；组合门说明补第三条链路
  - `feature-meta/test-report/status.md` —— 本文件（交付侧追溯件）
  - `feature-meta/test-report/traceability.md` —— 判据 → 交付位置追溯矩阵
  - `feature-meta/test-report/verification-report.md` —— 分层验收结论
  - `feature-meta/test-report/manifest.json` —— 本 REQ 的交付侧元数据
- 核心变更：
  - **三层结论不得混为一谈** —— 用例层（`results.json` 的 status 分布）/ 证据层（证据实查 +
    计数重算 + 指纹重算）/ 对账层（计划选样 vs 实际执行，可选层）分别给结论；
    任一层不过，`overall` 就不为 `pass`。
  - **计数一律重算** —— 五个计数从 `results.json` 逐条重算，**不抄** `meta.json` 的自述；
    两者不符 → 出一条 `count_mismatch` 并判证据层 `fail`。
  - **证据必须实查** —— 逐条核对 `evidence/` 下的文件是否存在、指纹是否一致；
    缺失 / 被改 / 计数造假 / 指纹不符都进 `evidence.findings[]`（结构化，不靠散文）。
  - **回归对账是可选层** —— 不给 `--regression-plan` 时 `regression` 段为 `null`、
    对账层为 `not_applicable`，正文**不写**任何断言对账状态的措辞；给了计划则漏跑逐条点名，
    `needs_review` 非空与 `impact_complete == false` 都不让 `overall` 为 `pass`。
  - **报告自身可核** —— 自带 `report_sha256`（按固定规范化口径，排除 `generated_at` 与自身），
    并绑定输入产物的两个**重算**指纹；md 是 json 的渲染，带一行机器可读摘要。
  - **只读输入 + 幂等** —— 绝不改输入产物里的任何既有文件；同一输入两次出报告除
    `generated_at` 外逐字相同。
- 自验：
  - 主验收 `BA/demands/REQ-002-suite-foundation/REQ-010-test-report/verify-acceptance.sh`
    → **29 PASS / 0 FAIL**（快跑与完整模式一致；完整模式含 4 个变异体全部检出、负控未检出）
  - 上游回归（REQ-011 主验收 / REQ-006 主验收 / REQ-002A / REQ-002B）→ 全绿
- 需求文档（只读）：`BA/demands/REQ-002-suite-foundation/REQ-010-test-report/`
  （`acceptance.md` 判据集 29 条 / `decisions.md` D48~D71 / `verify-acceptance.sh`，
  sha256 钉版值 `6bb2a8096d14cc4573ec2fdfb3f35242037d7716b3ecc92bad8667b1d17c50bb`）
- 上游基线：REQ-004（`test-execute`）、REQ-011（`regression-plan`）、REQ-006（`test-case-design`）；
  本 REQ **不改**既有 4 个 skill 的任何文件。
- ⚠️ 前置状态说明：根 `feature-meta/manifest.json` 在 BA 分配本 REQ 的提交
  （`d2be4ff`）里被从 REQ-006 改写成了 REQ-010，与 AC-028「根目录那份仍须是 REQ-006」的
  判据前提冲突；本 REQ 已把它恢复到 `develop` 的逐字内容（REQ-006），
  详见 `feature-meta/test-report/verification-report.md` 的「遗留与裁定请求」。
