# REQ-010 追溯性矩阵

- 需求：REQ-010「报告能力域：`test-report` skill（执行报告 + 回归对账）」
- 分支：`feature/REQ-010`
- 交付位置：
  - `skills/test-report/`（skill：test-report）
    - `SKILL.md`（入口：三层结论与诚实性红线）
    - `skill-meta.json`（版本与依赖声明，`requires` 含 `test-execute`）
    - `references/report-schema.md`（`report.json` 字段契约 + `report_sha256` 规范化口径）
    - `references/report-rules.md`（三层结论 / 回归对账 / 诚实性红线）
    - `scripts/make-report.mjs`（主入口：产出 `report.json` + `report.md`）
    - `scripts/check-report.mjs`（自洽校验器）
    - `scripts/lib/`（fingerprint / canonical / artifacts / analyze / render / cli 六个内部模块）
  - `bin/verify-suite.mjs`（组合门新增「执行产物 → test-report → 三层结论」这条链路）
  - `README.md`（安装树与 skill 表格补 `test-report`；组合门说明补第三条链路）
  - `feature-meta/test-report/`（本 REQ 的交付侧追溯件）
- 验收脚本（BA 的资产，本 REQ 未改动）：
  `BA/demands/REQ-002-suite-foundation/REQ-010-test-report/verify-acceptance.sh`
  的 sha256 钉版值：`6bb2a8096d14cc4573ec2fdfb3f35242037d7716b3ecc92bad8667b1d17c50bb`
- 需求文档（只读）：`BA/demands/REQ-002-suite-foundation/REQ-010-test-report/`
  （`acceptance.md` 判据集 29 条 / `decisions.md` D48~D71）
- 决策号范围：D48~D71

> 本 REQ 的验收判据集共 29 条判据（AC-001~AC-029），下表逐条给出交付位置与自验方式。

| AC | 交付位置 | 自验方式 | 结论 |
|---|---|---|---|
| AC-001 test-report skill 存在且结构合法 | `skills/test-report/SKILL.md`、`skills/test-report/skill-meta.json`、`skills/test-report/references/report-schema.md`、`skills/test-report/references/report-rules.md`、`skills/test-report/scripts/make-report.mjs`、`skills/test-report/scripts/check-report.mjs` | 查目录与六个文件真实存在且非空；frontmatter 含 `name: test-report` 与非空 `description`；两个脚本首行是 `#!/usr/bin/env node`、可执行且过 `node --check` | PASS |
| AC-002 每个 skill 都声明版本与依赖 | `skills/test-report/skill-meta.json`（及其余四个 skill 既有的 `skill-meta.json`） | 逐 skill 核对 `name`（等于目录名且与 frontmatter 一致）、`version` 为 `<数字>.<数字>.<数字>`、`requires` 的值形如 `>=<x.y.z>`；并核 `test-report` 的 `requires` 含 `test-execute` | PASS |
| AC-003 README 的 skill 清单与实际目录一致 | `README.md`（安装树 + skill 表格两处） | 取 README 的 skill 清单集合（表格首格 ∪ `skills/<name>` 路径 ∪ 安装树条目）与 `skills/` 下含 `SKILL.md` 的目录名集合比对，两边相等 | PASS |
| AC-004 新产物不得打破既有目录契约 | `skills/test-report/`（不触碰 `skills/test-case-design/` 的任何文件） | 造满足 REQ-002B 契约的最小项目，在轮次目录内放 `report/`，跑 `verify-layout.mjs` 断言退出码 0 且无 FAIL 级问题；错误位置探针结论为「位置不受约束」 | PASS |
| AC-005 计数必须由 results.json 重算 | `skills/test-report/scripts/lib/analyze.mjs`（`recountCases`） | 跑 `make-report.mjs --artifacts`，把报告的五个计数与从 `results.json` 逐条重算的值比对；并断言报告的 `cases.total` 不等于 `meta.json` 的自述值 | PASS |
| AC-006 状态分布必须与 results.json 逐条一致 | `skills/test-report/scripts/lib/analyze.mjs`（`recountCases` + `failures` 组装） | 逐条遍历 `results.json` 分类累加与报告比对；并断言 `failures[].case_id` 集合等于 `status ∈ {failed, blocked}` 的 id 集合 | PASS |
| AC-007 证据文件必须实查 | `skills/test-report/scripts/lib/analyze.mjs`（`inspectEvidence`） | 逐条遍历 `results.json` 的 `evidence[]` 做文件系统实查；断言 `missing_paths` 点名缺失路径、`files_present`/`files_missing` 计数正确、`findings[]` 有 `kind=missing_evidence` 且点名该路径、证据层为 `fail` | PASS |
| AC-008 报告必须绑定输入产物的指纹 | `skills/test-report/scripts/lib/fingerprint.mjs` + `lib/analyze.mjs`（`source.results_sha256` / `source.evidence_manifest_sha256`） | 把报告里的两个指纹与「从 `results.json` 按证据链契约口径重算」的值比对（不是抄 `meta.json`） | PASS |
| AC-009 输入缺失或非法时必须报错退出 | `skills/test-report/scripts/lib/artifacts.mjs` + `scripts/make-report.mjs` | 产物目录不存在 / `meta.json` 非合法 JSON / `results.json` 根节点非数组三种情形各跑一次：退出码非 0、不留半份报告、错误信息点名坏在哪 | PASS |
| AC-010 report_sha256 必须可从报告自身重算 | `skills/test-report/scripts/lib/canonical.mjs` + `references/report-schema.md` §4 | 按 F3.2 的规范化口径剔除 `generated_at` 与 `report_sha256` 后重算并与报告里的值比对；同时查 schema 文档写明了该口径 | PASS |
| AC-011 report.md 的数字必须与 report.json 逐字相等 | `skills/test-report/scripts/lib/render.mjs`（`renderDigest` + 正文渲染） | 抽 md 的 `report-digest` 摘要行，逐键与 `report.json` 同名路径比对；查 12 个必需键齐全；正文关键数字按 F4.2 词表呈现且与摘要一致 | PASS |
| AC-012 overall == pass 的自洽不变式 | `skills/test-report/scripts/lib/analyze.mjs`（`deriveVerdict`）+ `scripts/check-report.mjs` | 断言 `overall=pass` 时 `failed`/`blocked` 必为 0、证据层必为 `pass`、给计划时对账层与影响面完整性同时满足 | PASS |
| AC-013 report.json 的必填字段集必须完整 | `skills/test-report/references/report-schema.md` §2 + `scripts/check-report.mjs` | 逐字段查路径、类型与枚举；并查 schema 文档**列出**了全部必填字段名与 `kind` 枚举 | PASS |
| AC-014 漏跑必须逐条点名 | `skills/test-report/scripts/lib/analyze.mjs`（`reconcile` 的 `selected_missing`）+ `lib/render.mjs`（明细渲染） | 把 `selected_missing` 与「计划 `selected[]` 减去实际出现的 `case_id`」比对；并断言 md 逐字出现漏跑的用例 id | PASS |
| AC-015 漏跑必须导向失败结论 | `skills/test-report/scripts/lib/analyze.mjs`（`deriveVerdict`） | 断言 `selected_missing` 非空时对账层为 `fail` 且 `overall != pass` | PASS |
| AC-016 needs_review 非空时不得判回归通过 | `skills/test-report/scripts/lib/analyze.mjs`（`deriveVerdict` 的 `needs_review_planned > 0 → incomplete`）+ `lib/render.mjs`（待复核明细名单逐条点名 id） | 断言两个待复核计数都是数字、对账层不为 `pass`；md 的「待复核明细」名单**逐条点名**待复核用例 id（`TC-003`），且该 id 与「待复核」出现在同一行或紧邻 2 行内（待复核语境） | PASS |
| AC-017 判不了的变更必须呈现且不得判通过 | `skills/test-report/scripts/lib/analyze.mjs`（`reconcile` 原样搬运 `undecidable_changes`）+ `lib/render.mjs` | 断言条目数、变更 id、原因逐字等于计划；影响面完整性为 `false`；`overall != pass`；md 点名变更 id | PASS |
| AC-018 未提供计划时不得编造回归层结论 | `skills/test-report/scripts/lib/analyze.mjs`（`reconcile(null)` → `null`）+ `lib/render.mjs`（不渲染对账段、正文不写「回归」二字） | 不给 `--regression-plan` 跑一次：断言 `regression` 段为 `null`、对账层为 `not_applicable`、md 正文无断言对账状态的措辞 | PASS |
| AC-019 blocked 不得计入 passed | `skills/test-report/scripts/lib/analyze.mjs`（`recountCases` 的四分支互斥） | 断言 `blocked` 与 `passed` 各自等于重算值（互不吞并），且存在 blocked 时 `overall != pass` | PASS |
| AC-020 证据链不自洽不得出可信结论 | `skills/test-report/scripts/lib/analyze.mjs`（`inspectEvidence` 的 sha256 实算比对） | 篡改证据文件内容（不改 `results.json` 的 sha256）后跑一次：断言证据层为 `fail`、`overall != pass`、`findings[]` 有 `evidence_mismatch` 且点名被篡改的路径、md 出现该 message 的关键片段 | PASS |
| AC-021 meta 计数与 results.json 不符必须被发现 | `skills/test-report/scripts/lib/analyze.mjs`（`checkCounts`） | 断言 `findings[]` 有 `kind=count_mismatch` 且 message 点名计数、同时含 meta 记的值与重算值；断言 `cases.*` 仍按 `results.json` 重算 | PASS |
| AC-022 失败用例的复现信息必须逐字搬运 | `skills/test-report/scripts/lib/analyze.mjs`（`failures[].reproduction` 原样赋值） | 把报告里该条 `reproduction` 的 `command` 与 `steps` 与产物逐字比对；并断言 md 出现 `reproduction.command` 原文 | PASS |
| AC-023 报告不得出现输入产物里没有的数字或 id | `skills/test-report/scripts/lib/analyze.mjs` + `lib/render.mjs` | 断言 id 溯源（json 侧与 md 侧）、`cases` 段键集封闭（只 6 个键）、回归层数字逐字段可重算、顶层只有 `schema_version` 一个数字型叶子字段 | PASS |
| AC-024 同一输入两次出报告必须逐字相同 | `skills/test-report/scripts/make-report.mjs`（`generated_at` 之外无随机量、无输出路径入报告） | 同一输入跑两次、输出到两个目录：断言两份 `report.json` 与两份 `report.md` 除 `generated_at` 外逐字相同 | PASS |
| AC-025 输出路径约定 + 只写自己的目录 | `skills/test-report/scripts/make-report.mjs`（默认 `<run_dir>/report/`、`--out-dir` 生效） | 断言默认输出目录下有两份报告；`--out-dir` 生效；输入产物目录除 `report/` 外逐字未变；输出到目录外时输入目录无散落文件 | PASS |
| AC-026 零第三方依赖 + 不联网 | `skills/test-report/scripts/`（含 `lib/` 全部模块） | 扫描全部 `.mjs`：无非 `node:` 内置模块的 import/require（含动态 import）、无网络调用、相对 import 只指向本 skill 内 | PASS |
| AC-027 不得修改输入产物的任何既有文件 | `skills/test-report/scripts/lib/artifacts.mjs`（只读）+ `lib/analyze.mjs` | 跑前跑后各算一次产物目录的逐文件 sha256 并比对；同时查 `meta.json` / `results.json` 内容未被改写 | PASS |
| AC-028 交付侧记账必须与实际一致 | `feature-meta/test-report/status.md`、`feature-meta/test-report/traceability.md`、`feature-meta/test-report/verification-report.md`、`feature-meta/test-report/manifest.json` | 查四件套齐全非空；追溯矩阵行数与判据条数相等且编号集合恰为 AC-001~AC-029；三份 md 各恰一处记载判据条数与决策号范围；本 REQ 的 manifest 的 `req` 为 REQ-010；既有追溯件逐字未变 | PASS |
| AC-029 组合门必须覆盖第 5 个 skill | `bin/verify-suite.mjs`（`scenarioReport`） | 跑组合门：临时根装齐 5 个 skill、依赖图校验通过、跨 skill 组合场景实跑、**至少一条场景真的经过 `test-report`**（执行产物 → `make-report.mjs` → 断言报告里的三层结论）、版本错配时报版本问题 | PASS |
