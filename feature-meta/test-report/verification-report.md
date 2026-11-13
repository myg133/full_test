# REQ-010 验证报告

- 需求：REQ-010「报告能力域：`test-report` skill（执行报告 + 回归对账）」
- 分支：`feature/REQ-010`
- 交付物：`skills/test-report/`（skill）、`bin/verify-suite.mjs`（组合门扩展）、
  `skills/test-report/skill-meta.json`（版本与依赖声明）、`README.md`、`feature-meta/test-report/`
- 验收判据集共 29 条判据（AC-001~AC-029）；决策号范围 D48~D70。
- 验收脚本（BA 的资产，本 REQ 未改动）：
  `BA/demands/REQ-002-suite-foundation/REQ-010-test-report/verify-acceptance.sh`
  的 sha256 钉版值：`9b6ae5cf493e8284b563ab8dc3ee62d017de743dc1263159651c9d030b9cf2e9`
  —— 本报告的结论与该指纹绑定（同一批变异体在不同版本的脚本上结论可以不同）。

## 一、分层验收结论

| 层次 | 命令 | 结论 |
|---|---|---|
| 主验收（快跑模式） | `REQ010_NO_MUT=1 QA010_SCRIPT_SHA=9b6ae5cf… bash BA/demands/REQ-002-suite-foundation/REQ-010-test-report/verify-acceptance.sh .` | `结论: 29 PASS / 0 FAIL`（退出码 0） |
| 主验收（完整模式） | `QA010_SCRIPT_SHA=9b6ae5cf… bash BA/demands/REQ-002-suite-foundation/REQ-010-test-report/verify-acceptance.sh .` | `结论: 29 PASS / 0 FAIL`（退出码 0）；`变异体套件: 检出 4/4（有效变异体）`；负控 M0 `未检出` |
| 上游基线回归（REQ-011） | `REQ011_NO_MUT=1 QA011_SCRIPT_SHA=8fc6117d… bash BA/demands/REQ-002-suite-foundation/REQ-011-regression-plan/verify-acceptance.sh .` | `结论: 28 PASS / 0 FAIL / 0 不可判定`（退出码 0） |
| 上游基线回归（REQ-006） | `bash BA/demands/REQ-002-suite-foundation/REQ-006-security-stress-observability/verify-acceptance.sh skills/test-case-design` | `结论: 42 PASS / 0 FAIL`（退出码 0） |
| 上游基线回归（REQ-002A） | `bash BA/demands/REQ-002-suite-foundation/REQ-002A-schema-v2/verify-regression-002a.sh skills/test-case-design` | `结论: 19 PASS / 0 FAIL`（退出码 0） |
| 上游基线回归（REQ-002B） | `bash BA/demands/REQ-002-suite-foundation/REQ-002B-project-layout/verify-regression-002b.sh skills/test-case-design` | `结论: 41 PASS / 0 FAIL`（退出码 0） |

> 上游四条回归的意义：本 REQ **不改**既有 4 个 skill 的任何文件，
> 只在组合门里**新增**一条组合场景 —— 上游判据必须**原样继续全绿**。

## 二、能力结论

| 能力 | 结论 | 依据 |
|---|---|---|
| 用例层结论（重算而非抄） | 通过 | 五个计数从 `results.json` 逐条重算，与 `meta.json` 的自述不符时报「计数不符」（AC-005 / AC-006 / AC-021） |
| 证据层结论（实查而非转述） | 通过 | 逐条实查 `evidence/`；缺失 / 被改 / 计数造假 / 指纹不符都进结构化的 `findings[]`（AC-007 / AC-020） |
| 对账层结论（可选且不编造） | 通过 | 漏跑逐条点名、`needs_review` 不判通过、判不了的变更原样呈现；不给计划时整层为 `not_applicable`（AC-014 ~ AC-018） |
| 报告自身可核 | 通过 | `report_sha256` 可按 F3.2 口径重算；报告绑定输入产物的两个重算指纹（AC-008 / AC-010） |
| md 是 json 的渲染 | 通过 | `report.md` 带单行机器可读摘要，12 个必需键逐字相等；正文关键数字按 F4.2 词表呈现（AC-011） |
| 只读输入 + 幂等 | 通过 | 输入产物的逐文件 sha256 跑前跑后一致；两次出报告除 `generated_at` 外逐字相同（AC-024 / AC-025 / AC-027） |
| 套件层组合门覆盖第 5 个 skill | 通过 | 装齐 5 个 skill、依赖图校验通过；新增场景**真的跑过** `test-report`（执行产物 → 报告 → 断言三层结论）（AC-029） |
| 零依赖可移植 | 通过 | 只用 `node:` 内置模块、不联网（AC-026） |

## 三、遗留与裁定请求

### 3.1 根 `feature-meta/manifest.json` 的归属冲突（**需裁定**）

- **现象**：BA 分配本 REQ 的提交（`d2be4ff [BA] 分配 REQ-010 → ba-local-ba`）把根目录的
  `feature-meta/manifest.json` 从 REQ-006 改写成了 REQ-010（`req`/`branch`/`agent_id`/
  `session_id`/`owner`/`created_at`/`demand_dir` 七个字段全改，且丢了结尾换行）。
- **冲突**：AC-028 的判据正文写的是「根 `feature-meta/manifest.json` 的 `req` **仍是 REQ-006**」，
  且要求既有追溯件**逐字未变** —— 该前提在派工时**已经不成立**（是分配提交造成的，不是实现造成的）。
- **本 REQ 的处置**：把该文件恢复到 `develop` 的**逐字内容**（REQ-006 那份），
  即 `git checkout develop -- feature-meta/manifest.json`；恢复后与 `develop` 与真包 `code/` 逐字一致。
  REQ-010 自己的归属信息**没有丢** —— 落在 `feature-meta/test-report/manifest.json`（`req` 为 REQ-010）。
- **需要裁定的点**：若认为「分配提交改写根 manifest」才是应当保留的状态（即 AC-028 的前提该随
  分配提交一起更新），则本 REQ 应当被要求**回退**这一步：
  `git checkout d2be4ff -- feature-meta/manifest.json`，并由 BA 侧调整 AC-028 的措辞。
  本 REQ 不自行改判据、也不自行决定该文件的归属。

### 3.2 `report/` 落位无契约约束（遗留项）

AC-004 的错误位置探针结论是「位置不受约束（校验器不查该位置 → 本条判绿，不得要求实现去管它）」。
本 REQ **不**为 `report/` 的落位追加任何约束（契约未改），按上游 REQ-002B 的目录契约原样通过。
