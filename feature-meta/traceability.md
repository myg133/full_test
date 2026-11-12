# REQ-006 追溯性矩阵

- 需求：REQ-006「安全 / 压力 / 可观测性覆盖维度 + M2.x 安全测试方法段」
- 分支：`feature/REQ-006`
- 交付位置：`skills/test-case-design/`
  - `references/methods.json`（方法库，唯一来源）
  - `references/dimensions.json`（覆盖维度枚举，唯一来源）
  - `references/design-methods.md`（方法说明，人读）
  - `references/coverage-dimensions.md`（维度清单，人读）
  - `references/case-schema.md`（用例集契约 schema v2）
  - `scripts/check-methods.mjs`（方法使用与维度适用性核验器）
  - `scripts/validate-cases.mjs`（用例集结构校验器）
  - `SKILL.md`（skill 入口）
- 验收脚本（BA 的资产，本 REQ 未改动）：
  `BA/demands/REQ-002-suite-foundation/REQ-006-security-stress-observability/verify-acceptance.sh`
  （**层结论只写在文末「自验命令与实测结果」表里，一层一处** —— 见 D25 ⑬）
- 回归：`REQ-002A`、`REQ-002B`（实测结论同样见文末该表）
- 需求文档（只读）：`BA/demands/REQ-002-suite-foundation/REQ-006-security-stress-observability/`
  （`acceptance.md` 42 条判据 / `decisions.md` D1~D31）

> 编号说明：`AC-0xx` 是 BA 验收脚本的编号（`AC-003b` 是 D6 增补的子判据，同样计入 42 条）。
> 方法库规模：共 9 种方法（M1.1~M1.6 通用方法 + M2.1~M2.3 安全方法），覆盖维度共 11 个维度。

| AC | 交付位置 | 自验方式 | 结论 |
|---|---|---|---|
| AC-001 方法库存在且结构合法 | `references/methods.json`（`schema_version` + `methods[9]`）、`scripts/check-methods.mjs`（`validateMethodsLibrary`） | `check-methods.mjs --methods ... --selftest` + 独立核对方法条数 ≥9、每条有 `id`/`name`/`applies_when`/`required_outputs` 且 `required_outputs` 非空 | PASS |
| AC-002 方法库与说明文档一致 | `references/design-methods.md`、`scripts/check-methods.mjs`（`compareDocWithLibrary`，入口 `--doc ... --check-doc`） | 方法 id / 名称 / 适用信号三方比对；独立核对说明文档提到每个方法 `id`（含 M2.x 三条） | PASS |
| AC-003 声称用了方法但无产出 → 被发现 | `references/methods.json`（`required_outputs`）、`scripts/check-methods.mjs`（`evaluateRequiredOutputs` → `METHOD_OUTPUT_MISSING`） | 造缺 `boundary` 产出的用例集 → 退出码 1，输出同行含 `M1.2` 与 `R-1` | PASS |
| AC-004 方法确实应用了 → 不误报 | 同上（`evaluateRequiredOutputs` 的 `state==='ok'` 分支） | 补 3 条 `boundary` 用例且 `expected` 互不相同 → 不再报"缺少必需产出" | PASS |
| AC-003b `distinct_expected` 谓词真的生效 | `references/methods.json`（M1.2 的 `min_cases_by_dimension` 子字段 `distinct_expected`）、`scripts/check-methods.mjs`（`checkDistinctExpected`） | 3 条 `boundary` 用例 `expected` 全相同 → 退出码 1，报"期望取值不具区分度" | PASS |
| AC-005 适用性检查能发现漏用方法 | `scripts/check-methods.mjs`（`METHOD_MISSING`，WARN 不阻断） | 需求含强边界信号但未声明 M1.2 → 输出点名 `METHOD_MISSING` 与 `M1.2`，退出码仍 0 | PASS |
| AC-006 跳过必须写理由 | `scripts/validate-cases.mjs`（`skipped[]` 的 `reason` 校验）、`scripts/check-methods.mjs`（`skipped[]` 的 reason 校验） | 跳方法 `{"method":"M1.4"}` / 跳维度 `{"method":"dimension:concurrency"}` 两种写法各缺 `reason` → 两脚本均退出码 1 且点名缺 reason | PASS |
| AC-007 `--json` 输出与退出码语义 | `scripts/check-methods.mjs`（`buildJsonOutput` / `finish`） | 合法集 / 有 ERROR 的集 / 用法错误三种情形各跑 `--json` → stdout 可 `JSON.parse`，退出码 0 / 1 / 2 | PASS |
| AC-008 判不了就说"判不了" | `scripts/check-methods.mjs`（`evaluateRequiredOutputs` 返回 `state==='undecidable'` → `addUndecidable`） | `steps[].expected` 为人读字符串 → 落 `undecidable`，既不报通过也不报失败 | PASS |
| AC-009 零依赖 + 可移植 | `scripts/check-methods.mjs`、`scripts/validate-cases.mjs`（只用 `node:` 内置模块） | 源码扫描：无 `child_process` / `python3` / `bash` / 硬编码 `/tmp` | PASS |
| AC-010 REQ-002A 回归不受影响 | `scripts/validate-cases.mjs`（仅 `skipped[].method` 一处向后兼容放宽，D11） | 跑 REQ-002A 回归脚本 → 全部判据通过（结论见文末自验表） | PASS |
| AC-011 本 REQ 的验收脚本自身要被验收 | `scripts/check-methods.mjs` / `scripts/validate-cases.mjs`（被 BA 脚本注入变异） | 由 BA 的验收脚本注入变异并比对失败项集合（AC-026 是其强化形态） | PASS |
| AC-012 SKILL.md 把方法选择落在脚本上 | `SKILL.md`（第 4/5/7/8 步：`check-methods.mjs` 调用示例、可复制调用序列、ERROR/WARN/无法判定三类后果） | 检索 `SKILL.md` 是否含 `check-methods.mjs` 调用示例与三类结论说明 | PASS |
| AC-013 `--json` 输出结构自洽 | `scripts/check-methods.mjs`（`addVerdict` / `addUndecidable` / `buildJsonOutput`） | 三分类互斥 + `summary.*` 计数与数组长度一致 + `undecidable` 的 verdict 不得为 `satisfied` + 每个 (需求×方法) 都有结论 | PASS |
| AC-014 验收场景的样本本身必须合法 | `references/case-schema.md`（schema v2 定义）、`scripts/validate-cases.mjs` | 验收脚本造的样本逐个过 `validate-cases.mjs`：`d.json` 被拦，其余样本通过 | PASS |
| AC-015 维度适用性检查能被测出 | `scripts/check-methods.mjs`（`DIMENSION_MISSING` / `METHOD_SUSPECT`） | 两个场景各造一份用例集 → 输出出现对应类型名 | PASS |
| AC-016 `cases[].method[]` / `methods_applied[]` 只接受方法编号 | `scripts/validate-cases.mjs`（`METHOD_PATTERN` 校验，两处）、`references/case-schema.md` | 两个场景各跑一次 → 均退出码 1，且报错点名 `cases[0].method[0]` / `coverage_matrix[0].methods_applied[0]` | PASS |
| AC-017 跳过缺 reason 的文案区分方法/维度 | `scripts/validate-cases.mjs`（`skippedTargetLabel` / `skipTargetKind`） | 场景 A 输出含 `M1.4` 且含"方法"、场景 B 含 `concurrency` 且含"维度"，同行成立且不含"跳过方法" | PASS |
| AC-018 `skipped[].dimension` 旧写法判非法并指路 | `scripts/validate-cases.mjs`（legacy 探测分支）、`scripts/check-methods.mjs`（legacy 探测 + 正确写法提示） | 两脚本对同一份文件均退出码 1；`check-methods` 输出出现 `dimension:` 提示 | PASS |
| AC-019 未知维度名（拼错）→ ERROR | `scripts/validate-cases.mjs`（`DIMENSIONS.includes(dimName)` → `fail`）、`scripts/check-methods.mjs`（同名判定 → ERROR）、`references/dimensions.json`（枚举唯一来源，D16） | 两脚本均退出码 1 且都点名 `concurrancy` | PASS |
| AC-020 维度枚举单一来源 | `scripts/validate-cases.mjs`（`loadDimensionIds()` 从 `references/dimensions.json` 读，读不到即报错退出）、`references/dimensions.json` | 副本加一个新维度 → 副本退出码 0、原目录退出码 1（两者不同）；源码检索不到硬编码的维度数组 | PASS |
| AC-021 维度清单文档与库一致 | `references/coverage-dimensions.md`、`references/dimensions.json`、`scripts/check-methods.mjs`（`compareDimensionsDocWithLibrary`，入口 `--dimensions-doc ... --check-dimensions-doc`） | md 表格取值集合 == json id 集合；副本删一行 → 检查退出码 ≠0 且点名被删的 id | PASS |
| AC-022 新增契约自身要被验收 | `scripts/validate-cases.mjs`、`scripts/check-methods.mjs` | 正反对消 2/2 + 数据级变异 2/2（删 `dimensions.json` 报错退出；加未登记维度被对照检查点名） | PASS |
| AC-023 四个谓词分支真的生效 | `references/methods.json`（`required_outputs` 四种 kind）、`scripts/check-methods.mjs`（`evaluateRequiredOutputs`） | 四份样本各只违反一个谓词 → 四份均退出码 1，报"缺少必需产出"且点名 `M1.4`/`M1.5`/`M1.3`/`M1.6` | PASS |
| AC-024 M0.x/M4.x 判"无法判定" | `scripts/check-methods.mjs`（未登记编号 → `addUndecidable`，不判 satisfied）、`references/case-schema.md`（编号分段说明） | `--json` 输出里 `undecidable` 含 `M0.1`、其 verdict status 为 `undecidable`、`errors` 不含 `M0.1` | PASS |
| AC-025 check-methods 侧跳过文案也区分方法/维度 | `scripts/check-methods.mjs`（`跳过的维度 X` / `跳过的方法 X` 标签） | 场景 A 含 `M1.4`+"方法"、场景 B 含 `concurrency`+"维度"（同行），且 B 不含"跳过方法" | PASS |
| AC-026 变异体 100% 被检出 | `scripts/check-methods.mjs`、`scripts/validate-cases.mjs`（被 BA 脚本在副本上注入 28 个变异） | 28 个变异体逐个注入 → 全部被测出；变异后还原，失败项集合回到基线 | PASS |
| AC-027 实现里的注释不得与实现相反 | `scripts/validate-cases.mjs`（"维度名不在枚举内"分支的注释口径 = ERROR，与 `fail(...)` 实现一致） | 注释里不再出现"只报 WARN"字样；对应实现分支确为 `fail` | PASS |
| AC-028 `feature-meta/` 不得张冠李戴 | `feature-meta/status.md`、`feature-meta/traceability.md`、`feature-meta/verification-report.md`、`feature-meta/manifest.json` | `feature-meta/` 目录与四件套齐全（缺一即 FAIL）；每份追溯文件的**首行**必须自证是 `REQ-006`，且 `REQ-006` 出现次数**多于**任何其它 REQ 编号（主体性：只留 token 的骨架、或整份改讲别的 REQ → FAIL）；`manifest.json` 的 `req` == `REQ-006` 且 `branch` 里有且只有一个 REQ 编号且为 `REQ-006`；`demand_dir` 非空且解析后与本 REQ 需求目录同一路径 | PASS |
| AC-029 ERROR 必须真的标成 ERROR | `scripts/check-methods.mjs`（`SEVERITY_ERROR`、人读输出的"ERROR 明细"/"WARN 明细"两节与"结论:"行） | 人读输出含 `ERROR 明细` 标题 + "N 个 ERROR" + `WARN 明细` 标题，且错误条数 == `--json` 的 `summary.errors` | PASS |
| AC-030 `--help` 属用法错误 | `scripts/check-methods.mjs`（`parseArgs` 未知参数 → 退出码 2 + 用法说明）、`scripts/validate-cases.mjs`（`--help`/`-h`/未知参数 → 退出码 2 + 用法说明） | 两脚本跑 `--help` 均 rc=2 且输出含"用法" | PASS |
| AC-031 独立的 `distinct_expected` 谓词种类必须真的被核验 | `scripts/check-methods.mjs`（`evaluateRequiredOutputs` 的 `kind === 'distinct_expected'` 分支）、`references/methods.json`（谓词种类表） | 副本的 `methods.json` 加一个用独立 kind 的方法 → 2 条 `boundary` 用例 `expected` 全相同 → 退出码 ≠ 0 且输出含"区分度"；`expected` 互不相同 → 退出码 0 | PASS |
| AC-032 `dimension:` 前缀的适用范围（文档必须与实现一致） | `references/case-schema.md`（`dimension:` 只在 `skipped[]` 里的声明）、`scripts/validate-cases.mjs` | 文档含 `dimension:` + `skipped` + "只/仅"限定说明，且无"任何方法字段"式放宽措辞；正反对消：`skipped[].method` 写 `dimension:concurrency` → 接受，`cases[].method` 写 `dimension:concurrency` → 拒绝（退出码 1） | PASS |
| AC-033 清单必须声明「以 `dimensions.json` 为准」，不一致时以库为准 | `references/coverage-dimensions.md`（唯一来源声明）、`scripts/check-methods.mjs`（维度库 ↔ 清单对照检查 `compareDimensionsDocWithLibrary`） | 文档含 `dimensions.json` + "为准" + "唯一来源"，且无"以本清单为准/需要人工同步"式措辞；副本的 `dimensions.json` 加一个清单里没有的维度 → 对照检查退出码 ≠ 0 且点名该维度 | PASS |
| AC-034 `feature-meta/` 里的判据条数 / 决策号 / 验收数字必须与实际一致 | `feature-meta/status.md`、`feature-meta/traceability.md`、`feature-meta/verification-report.md` | 三份文件里每一处「N 条判据」的 N == `acceptance.md` 的 `### AC-` 实际条数；每一处「D1~D<n>」的 n == `decisions.md` 里的最大决策号；`verification-report.md` 主验收行的 P+F == 判据条数且 F == 0；每份文件各自至少一处「N 条判据」与「D1~D<n>」；`verification-report.md` 里恰好一处「验收脚本 sha256」且 == 当前验收脚本文件的 sha256；追溯链声明的方法条数 / 方法 id 区间 / 「11 个维度」与实现实际一致；**追溯矩阵里以 `AC-` 开头的行抽出的编号集合 == `acceptance.md` 的 `### AC-` 集合**（集合相等）且每行**恰好 4 个非空单元**；**`status.md` 的实现清单非空、且清单里每个路径在被验目录真实存在**；**`verification-report.md` 的三层（主验收 / REQ-002A / REQ-002B）各恰好一行、结论形如「N PASS / 0 FAIL」，「能力」结论表 ≥3 行数据**；**三份追溯件的层结论（主验收 / REQ-002A / REQ-002B）各恰好一处，且归属主验收的那一处必须与主验收脚本同行（D25 ⑬）** | PASS |
| AC-035 三个新维度在枚举里齐全且字段完整 | `references/dimensions.json`（`security` / `stress` / `observability` 三项） | 查枚举文件实际内容：三个 id 齐全 + 每个 7 个字段逐个非空（`skip_reason_required` 为 true）+ 三个 `applies_when` 集合两两不同 | PASS |
| AC-036 每个维度在清单文档里都有非空的逐维度检查清单小节 | `references/coverage-dimensions.md`（`### security（安全）` / `### stress（压力）` / `### observability（可观测性）` 三节）、`references/dimensions.json` | 把清单文档切成小节 → 枚举里每个维度 id 都有同名小节且正文非空；删掉某节 → 该维度假小节判红 | PASS |
| AC-037 方法库收录 M2.x 段且脚本真认它 | `references/methods.json`（M2.1 / M2.2 / M2.3）、`scripts/check-methods.mjs`（`methodById` 认登记条目） | 查库：M2. 段 ≥1 条且 7 个字段逐个非空（含非空 `not_applies_when`）；实跑脚本：声明某个 M2.x → 输出不含"未在方法库中登记" | PASS |
| AC-038 M2.x 的必需产出必须可机械核验 | `references/methods.json`（M2.x 的 `required_outputs`）、`references/dimensions.json`（被引用维度 id 的实际集合） | 每条 M2.x 的 `required_outputs` 非空 + `kind` 在白名单内 + 引用维度的 id 在枚举里真实存在；改成不存在的维度 → 该谓词判红 | PASS |
| AC-039 声明用了 M2.x 但用例集里没有对应产出 → 被发现 | `scripts/check-methods.mjs`（`evaluateRequiredOutputs` → `METHOD_OUTPUT_MISSING`） | 只声明某个 M2.x 且仅 1 条 `functional` 用例 → 退出码 1，输出同行含该 M2.x 与需求条目编号 | PASS |
| AC-040 Layer 0 段不得被收进方法库且分类提示必须还在 | `references/methods.json`（无 `M0.` / `M4.` 条目）、`scripts/check-methods.mjs`（`LAYER0_SEGMENT` 与 `numberingHint`） | 查库无 Layer 0 条目；实跑声明 `M0.1` → 判"无法判定"且提示仍含"Layer 0 必选测试点段"字样 | PASS |
| AC-041 交付侧记账里的「N 种方法」必须与方法库实际条数一致 | `references/methods.json`（方法库实际条数）、`feature-meta/status.md`、`feature-meta/traceability.md`、`feature-meta/verification-report.md` | 逐处比对三份追溯件里的「N 种方法」与库实际条数；把某处改成旧值 → 本条判红 | PASS |

## 补充：自验命令与实测结果

| 命令 | 结果 |
|---|---|
| `bash BA/demands/REQ-002-suite-foundation/REQ-006-security-stress-observability/verify-acceptance.sh feature-REQ-006/skills/test-case-design` | **42 PASS / 0 FAIL** |
| `bash BA/demands/REQ-002-suite-foundation/REQ-002A-schema-v2/verify-regression-002a.sh feature-REQ-006/skills/test-case-design` | **19 PASS / 0 FAIL** |
| `bash BA/demands/REQ-002-suite-foundation/REQ-002B-project-layout/verify-regression-002b.sh feature-REQ-006/skills/test-case-design` | **41 PASS / 0 FAIL** |
