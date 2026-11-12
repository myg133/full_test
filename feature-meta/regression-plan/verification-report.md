# REQ-011 验证报告

- 需求：REQ-011「R2 回归轮：`regression-plan` skill + 套件层组合门」
- 分支：`feature/REQ-011`
- 交付物：`skills/regression-plan/`（skill）、`bin/verify-suite.mjs` + `bin/test-agent-skills.mjs`（组合门）、
  四个 skill 根级的 `skill-meta.json`、`README.md`、`feature-meta/regression-plan/`
- 验收判据集共 28 条判据（AC-001~AC-028）；决策号范围 D35~D46。
- 验收脚本（BA 的资产，本 REQ 未改动）：
  `BA/demands/REQ-002-suite-foundation/REQ-011-regression-plan/verify-acceptance.sh`
  的 sha256 钉版值：`f21124bb8d4f5cd873b03ec8bac3551b6d3fc647a8fcf7d9220b025510961d79`
  —— 本报告的结论与该指纹绑定（同一批变异体在不同版本的脚本上结论可以不同）。

## 一、分层验收结论

| 层次 | 命令 | 结论 |
|---|---|---|
| 主验收（快跑模式） | `bash BA/demands/REQ-002-suite-foundation/REQ-011-regression-plan/verify-acceptance.sh .`（`REQ011_NO_MUT=1`） | 28 PASS / 0 FAIL |
| 主验收（完整模式） | `bash BA/demands/REQ-002-suite-foundation/REQ-011-regression-plan/verify-acceptance.sh .` | 28 PASS / 0 FAIL（含 AC-025 的 8 个变异体全部检出） |
| 上游基线回归（REQ-006） | `bash BA/demands/REQ-002-suite-foundation/REQ-006-security-stress-observability/verify-acceptance.sh skills/test-case-design` | 42 PASS / 0 FAIL |
| 上游基线回归（REQ-002A） | `bash BA/demands/REQ-002-suite-foundation/REQ-002A-schema-v2/verify-regression-002a.sh skills/test-case-design` | 19 PASS / 0 FAIL |
| 上游基线回归（REQ-002B） | `bash BA/demands/REQ-002-suite-foundation/REQ-002B-project-layout/verify-regression-002b.sh skills/test-case-design` | 41 PASS / 0 FAIL |

> 上游三条回归的意义：本 REQ **不改** `test-case-design` 的任何既有文件（只在其根级新增一份版本声明），
> 上游判据必须**原样继续全绿**。

## 二、能力结论

| 能力 | 结论 | 依据 |
|---|---|---|
| R2 选样（确定哪些用例要重跑） | 通过 | `plan-regression.mjs` 产出 `regression-plan.json`；`selected` 与按 basis 独立重算的结果逐项相等（AC-010） |
| R2 复核（哪些用例要人工复核） | 通过 | 方法 `not_applies_when` 被变更正文命中 → 进 `needs_review`，且与 `selected` 互斥（AC-017 / AC-018） |
| R2 诚实性（哪些变更判不了） | 通过 | 判不了条目显式列出、`impact_complete` 声明为 false、坏引用报错退出并点名 id（AC-012 ~ AC-015） |
| 只读输入 + 幂等 | 通过 | 用例集 sha256 跑前跑后不变；两次跑除时间戳外逐字相同（AC-019 / AC-020） |
| 套件层组合门 | 通过 | 装到临时根、校验版本配套、实跑 offline 夹具（4/1/1/0）与轮次推进链路（AC-021 ~ AC-024） |
| 版本错配的报告形态 | 通过 | 报的是版本问题（点名 skill / 要求 / 实际），不是下游业务错（AC-023） |
| 零依赖可移植 | 通过 | 只用 node: 内置模块、不联网（AC-027） |

## 三、边界与遗留

- **AC-026 ② 的自我约束**：根目录 `feature-meta/manifest.json` 仍是 REQ-006 的那份，本 REQ 的追溯件
  写在 `feature-meta/regression-plan/` 子目录，两条追溯链互不覆盖。
- **库的唯一来源**：维度库与方法库只有 `skills/test-case-design/references/` 下的那两份；
  `regression-plan` 不另存副本，未显式传 `--dimensions` / `--methods` 时回落到那两份。
- **轮次状态写入权**：`cycle.json` / `cycles/index.json` 只由
  `skills/test-case-design/scripts/cycle-state.mjs` 写，`regression-plan` 与组合门都不直接编辑它。
- **待 QA 交叉验证**：本报告的结论由开发侧自验得出，独立验收方仍需自造探针复核。
