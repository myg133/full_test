# 验收标准：REQ-011 —— R2 回归轮 `regression-plan` skill + 套件层组合门

> 判据集：**26 条**（AC-001~AC-026），**自包含**于本文件。
> 被验对象：`<package>/skills/regression-plan/`（skill 本体） + `<package>/bin/`（套件层组合门）。
> 判据形式统一为「**可证伪 + 查绝对事实**」：每条都要能指出"改坏什么 → 本条判红"。
> **不可判定时不判通过** —— 找不到被护对象、读不到输入、依赖缺失，一律判红，不许自我豁免。

## 0. 被验对象与命令行契约

**skill 目录**（记作 `$RP`）：`<package>/skills/regression-plan/`

| 路径 | 作用 |
|---|---|
| `$RP/SKILL.md` | skill 入口（frontmatter 含 `name` / `description`） |
| `$RP/references/regression-plan-schema.md` | `regression-plan.json` 的字段契约 |
| `$RP/references/impact-rules.md` | 影响面判定规则（F3） |
| `$RP/scripts/plan-regression.mjs` | 主脚本：产计划 |
| `$RP/scripts/check-plan.mjs` | 校验器：查计划自洽性 |
| `$RP/scripts/lib/*.mjs` | 内部模块（路径可自由，判据不依赖内部命名） |

**CLI 契约**（判据按此调用；实现可加参数，但**不得删改**以下语义）：

```console
node scripts/plan-regression.mjs --changelog <file> --cases <file> --cycle-dir <dir> \
     [--dimensions <file>] [--methods <file>] [--json]
#   → 在 <dir> 内写 regression-plan.json；退出码 0 = 成功 / 1 = 输入或引用非法 / 2 = 用法错误

node scripts/check-plan.mjs --plan <file> --cases <file> --changelog <file> \
     [--dimensions <file>] [--methods <file>] [--json]
#   → 退出码 0 = 计划自洽 / 1 = 查出问题 / 2 = 用法错误
```

**输入样例（判据用的最小夹具）**：
- 用例集 `cases.json`：schema v2，含 2 个需求条目（`R-1` / `R-2`）、6 条用例，维度取自 `dimensions.json`，方法取自 `methods.json`
- changelog：3 个变更条目 —— 一条带 `@R-1`、一条带 `@dim:security`、一条**无引用无信号**（用于 AC-012/013）

**库文件默认值**：未显式传 `--dimensions` / `--methods` 时，必须回落到**同包内**
`../test-case-design/references/{dimensions,methods}.json`（相对 `$RP`）——
即**库的唯一来源是 test-case-design 里的那两份**，不是 regression-plan 自己的副本。

---

## A 组：交付物形状（AC-001~AC-004）

### AC-001: `regression-plan` skill 存在且结构合法
- **前置条件**: 被验包目录
- **测试步骤**: ① 检查 `skills/regression-plan/` 存在；② 检查 `SKILL.md` 存在且 YAML frontmatter 含 `name: regression-plan` 与非空 `description`；③ 检查 `references/regression-plan-schema.md`、`references/impact-rules.md`、`scripts/plan-regression.mjs`、`scripts/check-plan.mjs` 四个文件存在且非空；④ 检查两个脚本的 shebang 或首行可被 `node` 直接执行
- **预期结果**: 四项全满足；任一缺失 → 判红并点名缺哪个
- **判据形式**: 查**绝对事实**（文件真实存在且非空），不查"文档里说有"
- **类型**: 功能

### AC-002: 每个 skill 都声明版本与依赖（`skill-meta.json`）
- **前置条件**: 被验包目录
- **测试步骤**: 对 `skills/` 下**每一个**含 `SKILL.md` 的目录，检查存在 `skill-meta.json`；解析它必须有 `name`（非空且等于目录名）、`version`（形如 `<数字>.<数字>.<数字>`）、`requires`（对象；值为形如 `>=<x.y.z>` 或 `<x.y.z>` 的约束）；并检查 `name` 与该 skill 的 SKILL.md frontmatter `name` 一致
- **预期结果**: 每个 skill 都有合法声明；`test-execute` 的 `requires` **必须**包含 `test-case-design`（它是硬跨 skill 依赖，见 demand.md §1.2）
- **判据形式**: 查绝对事实；探针：删掉某个 skill 的 `skill-meta.json` → 本条判红；把 `test-execute` 的 `requires` 删掉 → 本条判红
- **类型**: 功能

### AC-003: README 的 skill 清单与实际目录一致
- **前置条件**: 被验包目录 + `README.md`
- **测试步骤**: 取 `skills/` 下全部含 `SKILL.md` 的目录名集合 S；取 `README.md` 中提到的 skill 名集合 R；检查 S == R
- **预期结果**: 两个集合完全相等；README 漏写或多写任一 skill → 判红并点名
- **判据形式**: 查绝对事实（与目录实际内容比对），不查"README 里说了几个"
- **类型**: 可用性

### AC-004: 新产物不得打破既有目录契约
- **前置条件**: `test-case-design` 的 `scripts/verify-layout.mjs` + 一个合法的 `test-assets/` 项目
- **测试步骤**: ① 造一个满足 REQ-002B 契约的最小项目；② 在其轮次目录 `test-assets/cycles/R2-CHANGELOG-2.3/` 里放一个 `regression-plan.json`；③ 跑 `verify-layout.mjs`；④ 断言退出码为 0 且无 FAIL 级问题
- **预期结果**: 校验器**不因**多了 `regression-plan.json` 而判红（新增产物不得破坏既有契约）
- **判据形式**: 查绝对事实（实跑校验器的退出码）；探针：把 `regression-plan.json` 放到**错误位置**（如 `test-assets/` 根）→ 本条判红（若校验器本就不查该位置，则本条应判"位置不受约束"，不得要求实现去管它）
- **类型**: 兼容性

---

## B 组：选样正确性（AC-005~AC-011）

> 以下各条的公共前置：用 §0 的最小夹具跑 `plan-regression.mjs` 得到一份计划 `P`。
> 夹具必须覆盖：6 条用例分布在 2 个需求条目、至少 2 个维度、至少 2 种方法、至少 1 条 `status != active` 的用例。

### AC-005: 不得凭空造用例
- **前置条件**: 计划 `P` + 输入 `cases.json`
- **测试步骤**: 取 `P.selected` 与 `P.needs_review` 里全部 `case_id`，逐个在输入 `cases.json` 的 `cases[].id` 里找
- **预期结果**: 全部命中；出现输入里不存在的 id → 判红并点名
- **判据形式**: 查绝对事实（输入用例集的实际 id 集合）
- **类型**: 功能

### AC-006: 命中需求条目的用例必须在 `selected`
- **前置条件**: 同上；夹具含一条带 `@R-1` 的变更条目
- **测试步骤**: 取 `P.changes` 里 `requirement_refs` 含 `R-1` 的变更条目 C；对输入里每条 `requirement_refs` 含 `R-1` 且 `status == active` 的用例 u，断言 u 出现在 `P.selected`
- **预期结果**: 全部出现在 `selected`；漏一条 → 判红并点名漏了哪个
- **判据形式**: 查绝对事实（输入用例集的实际用例）；探针：把实现改成"只选显式引用的用例" → 本条判红
- **类型**: 功能

### AC-007: 命中维度的用例必须在 `selected`（显式与隐式两条路径）
- **前置条件**: 同上；夹具含一条带 `@dim:security` 的变更条目，**以及**一条正文命中 `security` 维度 `applies_when` 信号词的变更条目
- **测试步骤**: ① 对显式 `@dim:` 引用的维度 D，取输入里 `dimension == D` 且 `status == active` 的用例，断言全在 `selected`；② 对信号词命中的维度 D'，同样断言
- **预期结果**: 两条路径都不得漏；任一漏 → 判红并点名是显式路径还是信号路径
- **判据形式**: 查绝对事实；探针：去掉隐式信号路径的实现 → 本条判红（**只堵显式路径的实现在此判红**）
- **类型**: 功能

### AC-008: 显式引用用例的变更条目必须把该用例选进来
- **前置条件**: 夹具含一条带 `@TC-00x` 的变更条目
- **测试步骤**: 取 `P.changes` 里 `case_refs` 含该 id 的变更条目 C；断言该用例出现在 `P.selected`（或其 `status != active` → 已在 AC-016 处理）
- **预期结果**: 必须出现；否则判红
- **判据形式**: 查绝对事实；探针：实现忽略 `case_refs` → 本条判红
- **类型**: 功能

### AC-009: 不在影响面内的用例不得进 `selected`
- **前置条件**: 同上；夹具含至少 1 条与任何变更条目都无关联的用例
- **测试步骤**: 独立重算影响面：对每条用例 u，判定 `affected(u)` =（其 `requirement_refs` 命中任一变更条目的 `requirement_refs`）∨（其 id 被任一变更条目 `case_refs` 引用）∨（其 `dimension` 命中任一变更条目的受影响维度集）；取不满足 `affected` 的用例集合 X；断言 X 与 `P.selected` 的 `case_id` 集合**无交集**
- **预期结果**: 无交集；有交集 → 判红并点名是哪条用例被多选了
- **判据形式**: 查绝对事实（由输入独立重算）；探针：实现把全部用例都选进来 → 本条判红
- **类型**: 功能

### AC-010: `selected` 必须等于「按计划自记的 basis 重算的并集」
- **前置条件**: 计划 `P` + 输入 `cases.json` + 维度库 + 方法库
- **测试步骤**: 以 `P.changes` 里**记录的** `requirement_refs` / `case_refs` / 受影响维度集为数据，独立重算 `selected` 集与 `needs_review` 集（判据自带实现，不复用被验代码）；逐个 `case_id` 与 `P.selected` / `P.needs_review` 比对（**集合相等**，不是包含关系）
- **预期结果**: 两个集合**逐项相等**；多出或缺少都判红并点名差集
- **判据形式**: 查绝对事实（重算结果 vs 计划内容）；探针：实现的选样口径与判据口径不一致（例如漏算维度信号）→ 本条判红
- **类型**: 功能
- **说明**: 这条是本 REQ 的**核心自洽判据** —— 它把"影响面判定"从"实现说了算"变成"可被独立重算"。

### AC-011: 每条选样都必须有可解释的来源
- **前置条件**: 计划 `P`
- **测试步骤**: 对 `P.selected` 与 `P.needs_review` 的每一条：① `reason` 非空；② `change_refs` 非空且每项都存在于 `P.changes[].id`；③ `reason` 里的来源标记必须**能被独立对上** —— 即 `reason` 中出现的需求条目 id / 用例 id / 维度名 / 信号词，必须确实是对应变更条目与输入/库里的事实
- **预期结果**: 全部可对上；`reason` 为空、指向不存在的变更、或引用了输入里没有的 id → 判红并点名
- **判据形式**: 查绝对事实；探针：把所有 `reason` 清空 → 本条判红
- **类型**: 可用性

---

## C 组：诚实性（AC-012~AC-015）

### AC-012: 判不了的变更必须显式列出
- **前置条件**: 夹具含一条**无显式引用、正文也未命中任何维度/方法信号**的变更条目
- **测试步骤**: 断言该条目出现在 `P.undecidable_changes[]`，且该项的 `change_id` 与 `reason` 非空
- **预期结果**: 必须出现；否则判红
- **判据形式**: 查绝对事实；探针：实现把这类条目悄悄丢掉 → 本条判红
- **类型**: 功能
- **说明**: 这是本套件一贯的诚实纪律在 R2 上的落点 —— **判不了就说判不了**（对齐 REQ-006 的 AC-008 / D27）。

### AC-013: 判不了的变更不得让任何用例进 `selected`
- **前置条件**: 同上
- **测试步骤**: 取该判不了条目的正文，按 `P.changes` 记录的维度集与方法集重算：若它本应命中某维度/方法，则该情形必须由实现显式处理；断言**不存在**任何一条 `selected` 条目的 `change_refs` 包含该判不了条目的 id
- **预期结果**: 不得有任何选样条目引用它；一旦出现 → 判红
- **判据形式**: 查绝对事实（计划内容）；探针：实现把判不了条目当成"影响全部用例" → 本条判红
- **类型**: 功能

### AC-014: 坏引用必须报错，不得静默
- **前置条件**: 两份坏 changelog —— 一条含 `@R-99`（输入里无此需求条目），一条含 `@TC-999`（输入里无此用例）
- **测试步骤**: 分别跑 `plan-regression.mjs`，断言**退出码为 1**（非 0 非 2），且输出里点名了那个不存在的 id
- **预期结果**: 两份都判红（验收侧：被判红 = 实现正确地把坏引用当成错误）；若任一份退出码为 0 或 2 → 判红
- **判据形式**: 查绝对事实（真实退出码）；探针：实现把坏引用静默忽略 → 本条判红
- **类型**: 功能
- **说明**: 静默忽略 = 悄悄漏测，必须报错拦住。

### AC-015: 摘要数字与影响面完整声明
- **前置条件**: 计划 `P`
- **测试步骤**: 断言 ① `summary.total_cases` == 输入 `cases.json` 的 `cases[]` 长度；② `summary.selected` == `P.selected` 长度；③ `summary.needs_review` == `P.needs_review` 长度；④ `summary.undecidable_changes` == `P.undecidable_changes` 长度；⑤ 当 `P.undecidable_changes` 非空时 `summary.impact_complete` 必须为 `false`；当其为空时必须为 `true`
- **预期结果**: 五项全满足；任一不符 → 判红并点名哪一项
- **判据形式**: 查绝对事实（计划内容自比 + 与输入比）；探针：把 `summary.selected` 改成别的数 → 本条判红
- **类型**: 功能

---

## D 组：生命周期与方法适用性（AC-016~AC-018）

### AC-016: 非 `active` 的用例不得进 `selected`
- **前置条件**: 夹具含至少 1 条 `status != active` 的用例，且该用例**确实**落在影响面内（否则本条测不到）
- **测试步骤**: 断言输入里 `status != active` 的用例 id **不出现在** `P.selected` 的 `case_id` 集合中
- **预期结果**: 不得出现；出现 → 判红并点名
- **判据形式**: 查绝对事实（输入用例集的生命周期状态）；探针：实现不区分生命周期 → 本条判红
- **类型**: 功能

### AC-017: 方法 `not_applies_when` 命中的用例必须进 `needs_review`
- **前置条件**: 夹具含一条变更条目，其正文**逐字包含**某方法 `not_applies_when` 里的某一条短语；且输入里至少 1 条用例用了该方法并落在影响面内
- **测试步骤**: ① 取该方法 m 与该变更条目 C；② 断言所有"用了 m 且落在影响面内"的用例出现在 `P.needs_review`；③ 断言这些用例**不**出现在 `P.selected`
- **预期结果**: 全部在 `needs_review` 且不在 `selected`；漏判或错判 → 判红并点名
- **判据形式**: 查绝对事实（方法库实际内容 + 计划内容）；探针：实现忽略 `not_applies_when` → 本条判红
- **类型**: 功能
- **说明**: 方法在本次变更场景下不适用 → **影响面判不了** → 交给人复核，不得静默当成"不受影响"。

### AC-018: 三个集合必须两两互斥
- **前置条件**: 计划 `P`
- **测试步骤**: 取 `P.selected` / `P.needs_review` 的 `case_id` 集合 S1 / S2；断言 S1 ∩ S2 == ∅
- **预期结果**: 交集为空；有交集 → 判红并点名是哪条用例同时在两边
- **判据形式**: 查绝对事实；探针：实现把 needs_review 的用例同时放进 selected → 本条判红
- **类型**: 功能

---

## E 组：写入权与幂等（AC-019~AC-020）

### AC-019: 不得修改输入用例集
- **前置条件**: 一份 `cases.json`（跑前记 sha256）
- **测试步骤**: 跑 `plan-regression.mjs` 前后各算一次该文件的 sha256，比对
- **预期结果**: 两个 sha256 **完全相同**；不同 → 判红
- **判据形式**: 查绝对事实（文件指纹）；探针：实现"顺手"改写用例状态 → 本条判红
- **类型**: 功能
- **说明**: R2 只出计划，**不改用例**（用例修订属 R1 的设计流程，见 demand.md §3）。

### AC-020: 同一输入两次跑，输出必须逐字相同（除时间戳）
- **前置条件**: 同一份 changelog + 同一份 `cases.json`
- **测试步骤**: 跑两次到**两个不同的临时目录**；把两份 `regression-plan.json` 逐行比对，**排除**时间戳字段（`generated_at` 之类）后必须完全相同
- **预期结果**: 除时间戳外完全相同；有其他差异 → 判红并给出 diff
- **判据形式**: 查绝对事实（两份输出实比）；探针：实现用随机数或依赖遍历顺序 → 本条判红
- **类型**: 可靠性

---

## F 组：套件层组合门（AC-021~AC-024）

### AC-021: 安装器提供组合校验子命令，且它把包装到临时根并校验依赖图
- **前置条件**: 被验包目录（含 `bin/test-agent-skills.mjs` 与 `skills/`）
- **测试步骤**: ① 断言安装器有组合校验子命令（`verify` 或等价名；实现自定，但 `--help` 里必须列出）；② 用 `--root <临时目录>` 跑它；③ 断言临时目录里出现了**全部** skill 目录；④ 断言它对每个 `skill-meta.json` 的 `requires` 做了校验（把某个 `requires` 改成不可能满足的版本 → 必须判红）
- **预期结果**: 四项全满足；子命令不存在、没装全、或依赖图没校验 → 判红并点名
- **判据形式**: 查绝对事实（实跑子命令 + 临时目录实际内容）；探针：子命令只检查文件存在、不实跑 → 由 AC-022 兜住
- **类型**: 功能

### AC-022: 组合门必须**实跑**跨 skill 组合场景
- **前置条件**: 同上
- **测试步骤**: 在临时根里 ① 跑 `test-execute` 的 offline 夹具（`skills/test-execute/examples/offline/`），断言用例结果为 **4 passed / 1 failed / 1 blocked / 0 skipped**（与该夹具 README 的预期一致）；② 跑 `cycle-state.mjs init`（`round_type=regression`）→ 跑 `run-suite.mjs --cycle <轮次目录>` → 断言该轮次 `cycle.json` 的 `execute` 阶段状态已推进、且 `stages.execute.runs[]` 里记入了本次 `run_id`
- **预期结果**: 两项都成立；任一不成立 → 判红并给出实际结果
- **判据形式**: 查**绝对事实**（实跑结果 + `cycle.json` 的实际内容）；探针：把 `test-execute/scripts/lib/cycle.mjs` 的 `CYCLE_STATE_SCRIPT` 路径改错 → 组合门必须判红
- **类型**: 功能
- **说明**: 这一条**经过 `test-execute/scripts/lib/cycle.mjs` → `test-case-design/scripts/cycle-state.mjs`** —— 那条硬跨 skill 依赖。这是"组合可用性"第一次有自动化护栏。

### AC-023: 依赖不满足时必须报**版本问题**
- **前置条件**: 同上；某 skill 的 `requires` 指向一个不可能满足的版本
- **测试步骤**: 跑组合门，断言 ① 退出码非 0；② 输出里**点名**了出问题的 skill 名；③ 输出里同时出现"要求（期望）"与"实际"两个版本值；④ 输出里**不出现**下游业务错的特征串（如"缺少必填字段""expected"）
- **预期结果**: 四项全满足；只说"失败了"不说版本 → 判红；出现业务错特征串 → 判红
- **判据形式**: 查绝对事实（实跑输出）；探针：实现只打印"依赖不满足"不含版本 → 本条判红
- **类型**: 可用性
- **说明**: 登记表登记的实测形态：版本错配时下游报的是业务错，agent 会照着去改自己的用例 → 死循环。

### AC-024: 组合门必须隔离，不得改动真实安装根
- **前置条件**: 真实安装根（如 `~/.agents`）存在且有本包的 skill
- **测试步骤**: 跑组合门前后各算一次**真实安装根**下各 skill 目录的 sha256 清单（目录名 + 文件相对路径 + 文件 sha256），比对
- **预期结果**: 两份清单**完全相同**；有任何变化 → 判红并点名改了哪个文件
- **判据形式**: 查绝对事实（真实安装根的实际指纹）；探针：实现图省事直接用真实根当临时根 → 本条判红
- **类型**: 安全

---

## G 组：变异体（AC-025）

### AC-025: 选样核心逻辑必须被变异体测出差异
- **前置条件**: 被验 skill 目录的**副本**（绝不在原地改被验对象）
- **测试步骤**: 在副本上依次注入下列**结构合法**的变异，每个变异都必须让**至少一条**判据判红；变异后还原必须回到基线（基线 = 全绿）
  1. 选样时忽略 `case_refs`（只按需求/维度选）
  2. 选样时忽略维度信号命中（只按显式 `@dim:` 与需求选）
  3. 选样时不做 `not_applies_when` 检查（永远不产生 `needs_review`）
  4. 选样时忽略 `status`（`deprecated` 的用例也选进来）
  5. 判不了的变更条目被悄悄丢弃（不进 `undecidable_changes`）
  6. 坏引用（`@R-99`）被静默忽略（不报错）
  7. `summary.selected` 写成固定值（不随明细变）
  8. `selected` 里塞进输入里不存在的用例 id
- **预期结果**: 8/8 变异全部被判出（"至少一条判据判红"），且每个变异还原后回到基线；任一变异**逃逸**（全绿）→ 判红并点名是哪个变异
- **判据形式**: 查绝对事实（真实跑出来的判红键）；探针：把实现里某条分支改成恒真 → 本条判红
- **类型**: 功能
- **说明**: 变异必须是**结构合法**的改动 —— 语法错误/崩溃导致的判红是**假检出**，不计入。

---

## H 组：交付侧追溯（AC-026）

### AC-026: 本 REQ 的追溯件必须与实际一致，且不得改写 REQ-006 的追溯件
- **前置条件**: 被验包目录 + `feature-meta/` 目录
- **测试步骤**:
  ① `feature-meta/regression-plan/` 下的四件套（`status.md` / `traceability.md` / `verification-report.md` / `manifest.json`）**存在且非空**，缺一即判红
  ② `feature-meta/manifest.json`（**根目录**那一份）的 `req` 必须仍是 `REQ-006` —— 本 REQ **不得改写** REQ-006 的追溯件（若被改成 `REQ-011` 或缺失 → 判红）
  ③ `feature-meta/regression-plan/traceability.md` 里以 `| AC-0` 开头的**追溯矩阵行数**必须 == 25，且其 AC 编号集合恰好等于 `AC-001`~`AC-025`（多一行、少一行、或出现集合外的编号 → 判红）
  ④ 三份 md 追溯件里**恰好各有一处**「25 条判据」，且该数字 == `acceptance.md` 里 `### AC-` 的实际条数（**上游回归的数字写的是「N PASS / 0 FAIL」形态，不受影响**）
  ⑤ 三份 md 追溯件里写明的**决策号范围**必须与本 REQ `decisions.md` 的实际 D 号集合一致（应为 `D35~D40`；集合不符 → 判红）
  ⑥ `feature-meta/regression-plan/manifest.json` 的 `req` == `REQ-011`，且 `demand_dir` 指向的目录**真实存在**
- **预期结果**: 六项全满足；任一不符 → 判红并点名是哪一项
- **判据形式**: 查**绝对事实**（追溯件的实际内容 + `acceptance.md` / `decisions.md` 的实际条数与编号）；
  探针：把追溯件里的判据条数改成 42 → 本条判红；把根目录 `manifest.json` 的 `req` 改成 `REQ-011` → 本条判红；删掉追溯矩阵的一行 → 本条判红
- **类型**: 可用性
- **说明**: 追溯链上的数字如果**没人核**，它就只是"看着像已验"——
  这正是 REQ-005 的 D25 ⑬⑭ F-A 与 REQ-006 的 AC-034 要消灭的东西。
  ② 是本 REQ 的**自我约束**：REQ-006 的四件套已被独立验收钉版，本 REQ 改写它就会断掉那条链（见 D39 ③）。

---


| 项 | 命令 |
|---|---|
| 主验收 | `bash verify-acceptance.sh <package-dir>` |
| 上游回归（必须全绿） | REQ-006 主验收、REQ-002A 回归、REQ-002B 回归 |

- 主验收退出码 `0` = 全通过；`1` = 有 FAIL
- 判据条数：**26**（AC-001~AC-026）
- 任何"脚本全绿的结论"**必须钉版本**（记 `verify-acceptance.sh` 的 sha256）——
  同一批变异体在不同版本的脚本上结论可以不同（D34）。
- **独立验收**由验收方自造探针攻击本判据集，不复用本脚本的结论。
