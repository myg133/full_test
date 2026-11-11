# REQ-005 验收标准 —— 测试方法库（数据化）+ SKILL.md 重写

> 用法: `verify-acceptance.sh <test-case-design-dir>`
> 退出码: 0 = 全部通过; 1 = 有 AC 未通过
> 说明: 本 REQ 的验收脚本**自身也要被验收**（AC-011）—— 验收脚本会注入变异，
>       确认每条护栏都真的拦得住，而不是恒真。

### AC-001: `methods.json` 存在且结构合法
- **前置条件**: 无
- **测试步骤**: `node scripts/check-methods.mjs --methods references/methods.json --selftest`
- **预期结果**: 退出码 0；6 种方法齐全（等价类/边界值/判定表/状态迁移/正交/场景）；每种都有 `id` / `name` / `applies_when` / `required_outputs`
- **判据形式**: **不只依赖实现的 `--selftest`**（那是实现自己验自己）—— 验收方独立查 `methods.json`：方法数 ≥ 6、**每条**都有那 4 个字段、**每条 `required_outputs` 非空**、每条有非空 `id`
- **类型**: 功能

### AC-002: 方法库与说明文档一致
- **前置条件**: `references/methods.json` 与 `references/design-methods.md` 并存
- **测试步骤**: 脚本比对两者的方法 id / 名称 / 适用信号
- **预期结果**: 不一致时退出码 1 并点名不一致的方法与字段
- **判据形式**: `--check-doc` 是实现自己比自己，验收方**再独立查一遍**：说明文档里必须**提到每个方法的 `id`**（这是"文档跟着数据走"的可判形式）
- **类型**: 功能

### AC-003: 声称用了方法但没有对应产出 → 被发现
- **前置条件**: 一条需求条目，`coverage_matrix[].methods_applied = ["M1.2"]`（边界值），但该条目下**没有** `boundary` 维度的用例
- **测试步骤**: `node scripts/check-methods.mjs cases.json`
- **预期结果**: 报出该条目"声明使用 M1.2 但缺少必需产出"，退出码 1
- **判据形式**: 输出里 `M1.2` 与 `R-1` 必须**同一行**出现 —— 只查"输出里有两个词"可能命中的是别处的提及
- **类型**: 功能
- **说明**: **这是本 REQ 的核心 AC**。它对应的失败模式是"方法使用只是声明"

### AC-004: 方法确实应用了 → 不误报
- **前置条件**: 同一条目，补上 3 条 `boundary` 用例，断言的 `expected` 取值互不相同
- **测试步骤**: 同上
- **预期结果**: 该条目不再报"缺少必需产出"
- **类型**: 功能
- **说明**: 与 AC-003 是一对，一起才能证明判据既**能拦住**又**不误伤**

### AC-003b: `distinct_expected` 谓词必须真的生效（取值全相同 → 被发现）
- **前置条件**: 同一条目，补上 3 条 `boundary` 用例，断言的 `expected` 取值**全部相同**（如都是 `7`）
- **测试步骤**: 同上
- **预期结果**: 退出码 1，报出"该维度下的期望取值不具区分度"
- **类型**: 功能
- **说明**: 与 AC-004 是一对。AC-004 的场景取值**互不相同**，判据恒成立 —— 它查不出 `distinct_expected` 这个谓词到底有没有被实现。本条用"取值全相同"把它逼出来

### AC-005: 适用性检查能发现漏用方法
- **前置条件**: 一条需求条目含"长度 8-20 位"这类**强边界信号**，但 `methods_applied` 里没有 `M1.2`
- **测试步骤**: 同上
- **预期结果**: 报 `METHOD_MISSING`（WARN）；退出码仍为 0（WARN 不阻断）
- **判据形式**: 输出必须点名类型 `METHOD_MISSING`（F3 定死的类型名）**且**提到 `M1.2` —— 只查 "M1.2" 可能命中别处的提及
- **类型**: 功能

### AC-006: 跳过维度必须写理由
- **前置条件**: `coverage_matrix[].skipped[]` 里有一条跳过项，`reason` 缺失。**两种写法各测一次**：
  - 跳过**方法**：`{"method":"M1.4"}`（缺 reason）
  - 跳过**维度**：`{"method":"dimension:concurrency"}`（缺 reason，见 D7 —— 维度跳过也用 `method` 字段记）
- **测试步骤**: 同上
- **预期结果**: 两种写法都退出码 1，且点名该跳过项缺 reason
- **判据形式**: 输出必须点名跳过的对象 **且**提到 `reason` —— 只查一个关键词可能命中别处的提及
- **类型**: 功能

### AC-007: `--json` 输出与退出码语义
- **前置条件**: 合法用例集 / 有 ERROR 的用例集 / 用法错误
- **测试步骤**: 三种情形各跑一次 `--json`
- **预期结果**: stdout 均可 `JSON.parse`；退出码 `0` / `1` / `2`
- **类型**: 功能

### AC-008: 判不了就说"判不了"
- **前置条件**: 一条用例的 `steps[].expected` 是**普通字符串**（人读），且该方法要求 `distinct_expected`
- **测试步骤**: 同上
- **预期结果**: 该项报"**无法判定**"，**不得**报"通过"、**不得**报"失败"
- **类型**: 功能
- **说明**: 延续"宁可漏报通过，不可虚报通过"

### AC-009: 零依赖 + 可移植
- **前置条件**: 源码级检查
- **测试步骤**: 检查 `dependencies`；检索 `child_process` / `python3` / `bash` / 硬编码 `/tmp`
- **预期结果**: 无上述依赖
- **类型**: 非功能

### AC-010: REQ-002A 回归不受影响
- **前置条件**: 无
- **测试步骤**: 跑 REQ-002A 的变异回归脚本与本 REQ 的验收脚本
- **预期结果**: REQ-002A 回归全绿
- **类型**: 回归

### AC-011: 本 REQ 的验收脚本自身要被验收
- **前置条件**: 一份能跑的验收脚本
- **测试步骤**: 对 `check-methods.mjs` 注入变异（去掉 `min_cases_by_dimension` 判定 / 把 ERROR 降成 WARN / 跳过 `distinct_expected` 检查），看验收脚本能否测出差异
- **预期结果**: 每条变异都能被验收脚本测出差异
- **类型**: 回归
- **说明**: 沿用 REQ-002A/002B/002.5a 的"验收脚本本身也要被验收"纪律

### AC-012: SKILL.md 把方法选择落在脚本上
- **前置条件**: 无
- **测试步骤**: 检索 `SKILL.md`
- **预期结果**: 含 `check-methods.mjs` 的调用示例、可复制调用序列、ERROR/WARN 的后果说明
- **类型**: 功能

---


### AC-013: `--json` 输出结构自洽（三分类互斥 + 计数一致 + 判不了不等于通过）
- **前置条件**: 按 F5.1 定的 JSON 输出契约，跑一个**同时含 ERROR 与"无法判定"**的用例集
- **测试步骤**: `node scripts/check-methods.mjs cases.json --json`，检查输出 JSON 的结构自洽性
- **预期结果**:
  1. `summary.errors` / `summary.warnings` / `summary.undecidable` **分别等于**对应数组的长度
  2. **三分类互斥** —— 同一条 `(requirement, method)` 不得同时出现在 `errors` 与 `warnings`
  3. 落在 `undecidable` 的组合，其 `verdicts[].status` **不得是 `satisfied`**（判不了 ≠ 通过）
  4. `verdicts[].status` 只能取约定的五个值；同一条 `(requirement, method)` 只能有一个 `verdict`
  5. **覆盖完整性** —— 每个 `(需求条目 × 方法)` 组合都必须有结论。只给"有问题"的组合写结论 = **漏判**
- **类型**: 功能
- **说明**: F5.1 把字段名定死就是为了让这条可判。契约不写死，"判不了到底算不算通过"就会变成实现方与验收方各写各的理解 —— 那正是这套 skill 要消灭的分叉。第 5 条（覆盖完整性）是补上的（D9）—— 此前只查 status 合法与不重复，**漏判**测不出来

### AC-014: 验收场景的样本本身必须合法
- **前置条件**: 本 REQ 验收脚本造出的各个场景样本（`a.json` / `b.json` / `b2.json` / `c.json` / `d.json` / `e.json`）
- **测试步骤**: 用 REQ-002A 的 `validate-cases.mjs` 逐个校验这些样本
- **预期结果**:
  - `d.json`（AC-006 的**反例**：跳过的维度**故意缺 `reason`**）必须被 REQ-002A **拦截**（退出码非 0）
  - 其余样本（`a` / `b` / `b2` / `c` / `e`）**全部校验通过**（退出码 0）
- **类型**: 回归
- **说明**: 场景样本用了**结构化断言对象**形式的 `expected`。若样本本身就通不过 REQ-002A 的校验器，那"check-methods 报了错"可能只是因为**输入非法**，而不是因为判据生效 —— 测出来的结论是假的。**拿非法输入测出来的结论不算数**。
  `d.json` 是**故意的反例**（它要测的正是"跳过项缺 reason 会被发现"），所以对它的正确期望是**被拦截**，而不是通过

### AC-015: 维度适用性检查能被测出（F4 的 `DIMENSION_MISSING` / `METHOD_SUSPECT`）
- **前置条件**: 两个场景。①需求条目命中某维度的强适用信号，但该条目下**一条用例都没有** → 应报 `DIMENSION_MISSING`（WARN）。②声明了 `M1.2`（边界值分析），但需求文本**不含**任何边界信号，**而必需产出齐备**（3 条 boundary 用例、取值互不相同）→ 应报 `METHOD_SUSPECT`（WARN）
- **测试步骤**: 同上，分别跑两个用例集
- **预期结果**: 两个场景都报出对应的类型名。**不校验退出码** —— 场景 1 的构造（声明了 M1.1 却零用例）必然同时存在一条真实 ERROR，实际退出码是 1；场景 2 的退出码是 0。WARN 本身不阻断，但同一份用例集里若还有别的 ERROR，整体退出码就是 1
- **判据形式**: 输出里必须出现 `DIMENSION_MISSING` 与 `METHOD_SUSPECT` 字样
- **类型**: 功能
- **说明**（D9）: F4 的这段检查此前**没有任何 AC 直接测** —— 把整段代码删掉，15 条 AC 仍全绿。实现方写了、验收没测 → 下次重构就会悄悄删掉。**没有验收保护的代码等于不存在**
- **场景 2 的两个前提**（缺一个都测不到 `METHOD_SUSPECT`）:
  1. 需求标题**不含** `M1.2` 的适用信号词（长度/范围/上限/下限/最多/至少/不超过/不少于/位数/数量/阈值/到期/间隔）—— 否则判的是"适用"而不是"存疑"
  2. **必需产出必须齐备** —— 实现的判定顺序是「产出缺失 → ERROR（更根本）→ 才轮到适用性存疑」（与 D26/D27 同一条原则），产出也缺时报的是 `missing_output`，走不到 `METHOD_SUSPECT` 分支

### AC-016: `cases[].method[]` 与 `methods_applied[]` 只接受方法编号（D12）
- **前置条件**: 一份 schema v2 用例集。场景 1：`cases[0].method = ["dimension:concurrency"]`。场景 2：`coverage_matrix[0].methods_applied = ["dimension:concurrency"]`
- **测试步骤**: 跑 `node scripts/validate-cases.mjs <用例集>`，两个场景各一次
- **预期结果**: 两个场景都退出码 1，且报错分别点名 `cases[0].method[0]` 与 `coverage_matrix[0].methods_applied[0]`
- **判据形式**: 输出里必须出现该**具体 JSON 路径**（`cases[0].method[0]` / `coverage_matrix[0].methods_applied[0]`）—— 只查 "dimension:concurrency" 可能命中别处的提及
- **类型**: 功能
- **说明**（D12）: `dimension:` 前缀**只允许出现在 `coverage_matrix[].skipped[].method`**（D7/D11 定的唯一例外）。这条 AC 钉住"只放宽这一处"的边界 —— D11 放宽了 `skipped[].method`，若有人顺手把 `cases[].method[]` 或 `methods_applied[]` 也放宽，`dimension:` 前缀就会渗进"用了哪些方法"的语义里（那两处记的是**方法编号**，不是跳过声明）。契约已写在 `case-schema.md` §`skipped[]`，本条补的是**验收保护**

### AC-017: 跳过项缺 `reason` 的报错文案要区分"方法"与"维度"（D13）
- **前置条件**: 两份用例集。场景 A：`skipped = [{"method":"M1.4"}]`（缺 reason，跳过的是**方法**）。场景 B：`skipped = [{"method":"dimension:concurrency"}]`（缺 reason，跳过的是**维度**）
- **测试步骤**: 跑 `node scripts/validate-cases.mjs <用例集>`，两个场景各一次
- **预期结果**: 两个场景都退出码 1。**场景 A 的报错必须说"方法"**（如"跳过的方法必须写明 reason"），**场景 B 的报错必须说"维度"**（如"跳过的维度必须写明 reason"）。两者都**必须点名被跳过的那个对象**（A 点名 `M1.4`、B 点名 `concurrency`）—— 有多条跳过时，agent 需要知道该改哪一条
- **判据形式**: 场景 A 的输出含 `M1.4` **且**含"方法"二字；场景 B 的输出含 `concurrency` **且**含"维度"二字，且**不含**"跳过方法"（那正是要修的措辞错误）
- **同行约束**: ⚠️ **必须同行**：判据要求"方法编号/维度名"与"方法/维度"二字出现在**同一行** —— 脚本输出末尾有"按维度分布:"这类汇总行，只查"输出里出现过 维度"会被那行蒙混过关（恒真判据比不判还糟）。（D21 修正：初版未做同行约束，实测变异体「文案回退成跳过方法」可从汇总行蒙混过关）
- **类型**: 可用性
- **说明**（D13）: `skipped[].method` 有两种形态（方法编号 / 维度标识），报错文案却一律写"跳过方法" —— 跳维度时文案与事实不符。agent 靠报错文案判断怎么改，文案说错就会改错地方。**点名对象**同属此处：文案只说"跳过方法"而不说是哪一条，等于让 agent 自己回去数

### AC-018: `skipped[].dimension` 旧写法在两个脚本里都判非法，且指明正确写法（D14）
- **前置条件**: 一份 schema v2 用例集，`coverage_matrix[0].skipped = [{"dimension":"concurrency","reason":"无并发语义"}]`（**只有** `dimension` 字段，没有 `method`）
- **测试步骤**: ①跑 `node scripts/validate-cases.mjs <用例集>` ②跑 `node scripts/check-methods.mjs <用例集>`
- **预期结果**: **两个脚本都退出码 1**（结论一致，都判非法）。且 `check-methods.mjs` 的报错必须**指出正确写法** —— 输出里出现 `dimension:` 前缀的示例（如 `dimension:concurrency`）或明确提示"应写成 method 字段"
- **判据形式**: ① `validate-cases` 退出码 ≠ 0；② `check-methods` 退出码 ≠ 0 **且**输出里出现 `dimension:`（正确写法的提示）
- **类型**: 功能
- **说明**（D14）: 实测当前 `check-methods.mjs` **静默接受**这个写法并让该维度跳过**真实生效** —— 而 `validate-cases.mjs` 判它非法。**两个脚本对同一份文件给出相反结论**，且宽松的那个让非法写法静默生效 = 虚报。`check-methods.mjs` 是本 REQ 新增文件、从未发布，无兼容负担。注意：**不能只是删掉兼容分支**（那样报错会变成"既没有 method 也没有 dimension"，对写了 legacy 写法的 agent 仍然指错路），必须保留探测并**报出正确写法**

### AC-019: 未知维度名（拼错）→ ERROR，且两个脚本都点名（D15）
- **前置条件**: 一份 schema v2 用例集，`coverage_matrix[0].skipped = [{"method":"dimension:concurrancy","reason":"拼错了"}]`（`concurrancy` 是 `concurrency` 的错拼）
- **测试步骤**: ①跑 `node scripts/validate-cases.mjs <用例集>` ②跑 `node scripts/check-methods.mjs <用例集>`
- **预期结果**: **两个脚本都退出码 1**（不是 WARN、不是退出码 0），且**都点名那个拼错的名字** `concurrancy`
- **判据形式**: ①退出码 ≠ 0 且输出含 `concurrancy`；②退出码 ≠ 0 且输出含 `concurrancy`
- **类型**: 功能
- **说明**（D15）: 实测当前 `validate-cases.mjs` 只报 WARN、退出码 0「校验通过」；`check-methods.mjs` **一个字都不提** —— 该跳过**静默失效**。维度名不在枚举内是**可机械判定的事实**（按 D2 的三分法归 ERROR，不归 WARN）。**前置依赖 D16**：判定"拼错"要有唯一依据，故枚举必须先单一来源化，否则两个脚本依据的枚举不同，判据不可靠

### AC-020: 维度枚举单一来源 —— `validate-cases.mjs` 不再自带副本（D16）
- **前置条件**: 把 skill 目录**复制一份**到临时目录，在副本的 `references/dimensions.json` 里**加一个第 9 个维度**（如 `audit`），并造一份用了该维度的用例集（`cases[0].dimension = "audit"`）
- **测试步骤**: ①跑**副本**的 `validate-cases.mjs` ②跑**原目录**的 `validate-cases.mjs` ③源码检查：检索 `validate-cases.mjs` 里是否还有那 8 个维度的硬编码数组
- **预期结果**:
  1. **副本**退出码 0（认这个新维度 —— 它是从文件读出来的）
  2. **原目录**退出码 1（不认 —— 原库的 `dimensions.json` 里没有 `audit`）
  3. 源码里**不存在**硬编码的维度枚举数组（否则副本也认不了、原目录也会误认）
- **判据形式**: ①与②的退出码**必须不同**（都 0 = 还在读硬编码；都 1 = 根本没读文件）；③源码检索不到那 8 个维度 id 组成的字面量数组
- **类型**: 功能
- **说明**（D16）: 实测**分叉当下已经存在**：给 `dimensions.json` 加第 9 个维度后，`validate-cases` 判 `cases[].dimension="audit"` **非法**（它读的是硬编码常量）、`check-methods` **照常认** → 同一份用例集两个脚本结论相反。而"加维度"是方法库最常见的演进动作。**三份副本（硬编码常量 / `dimensions.json` / `coverage-dimensions.md` 表格）→ 一份**，分叉这个类别直接消失。读不到库时必须**明确报错退出**，不得静默降级到内置列表（静默降级 = 又一份真相）

### AC-021: 维度清单文档与库一致（D16）
- **前置条件**: `references/coverage-dimensions.md` 的维度表格 与 `references/dimensions.json` 并存
- **测试步骤**: ①比对 md 表格里的取值集合与 json 的 `id` 集合 ②把 md 表格删掉一行，在**副本**上跑文档一致性检查
- **预期结果**: ①两集合**完全相等**（不多不少）②副本上的检查退出码 ≠ 0 并**点名**被删掉的那个维度 id
- **判据形式**: ①集合相等用脚本独立比对（不依赖实现自报）；②必须**点名**具体 id
- **对照入口（契约）**: 维度清单的对照检查必须**可从命令行单独触发**（不依赖跑一遍用例集）。方法侧已有 `--doc <说明文档> --check-doc` 入口，维度侧需有**对应的一个**（如 `--dimensions-doc <维度清单.md> --check-dimensions-doc`，或把维度清单纳入 `--check-doc`）。**入口名由实现自定，但"能单独触发"是契约** —— 否则 agent 无法在交付前自查
- **类型**: 功能
- **说明**（D16）: `coverage-dimensions.md` 是 SKILL.md 明确让 agent 读的清单（SKILL.md:42）。它与库分叉 = agent 照文档写的维度名被校验器拒绝，而 agent 无从知道该信哪个文件。方法侧早有 `--check-doc` 对照机制，**维度侧缺** —— 补上。同时该文档里"改动其中一处必须同步另一处"这句**手工契约**要改成"以 dimensions.json 为准，由脚本对照保证一致"

### AC-022: 本轮新增契约自身要被验收（正反对消 + 数据级变异）
- **前置条件**: 无
- **测试步骤**: ①**正反对消**：造一份**合法**用例集（`skipped[].method = "dimension:concurrency"`，且需求文本**故意命中** concurrency 的适用信号），分别跑 `validate-cases.mjs` 与 `check-methods.mjs` —— 两者都**不得**因该跳过项报错，且 `check-methods` **不得**报 `DIMENSION_MISSING`（说明跳过真实生效）②**数据级变异 1**：在 skill **副本**里删掉 `references/dimensions.json`，跑副本的 `validate-cases.mjs` ③**数据级变异 2**：在 skill **副本**里给 `dimensions.json` 加一个文档里没有的维度（如 `audit`），跑副本的维度清单对照检查
- **预期结果**:
  1. 正反对消 2/2 —— 合法写法被接受、跳过真实生效
  2. 变异 1：`validate-cases.mjs` **明确报错**（退出码非 0，且码 2 或输出点名 `dimensions.json`）—— **不得**静默降级到内置列表后照常通过
  3. 变异 2：维度清单对照检查退出码非 0 **且点名** `audit`
- **判据形式**: 4 个子判据（2 个正反 + 2 个变异）**全部**满足才算通过
- **类型**: 回归
- **说明**（D9）: AC-016~AC-021 是本轮新增的契约，**新写的判据同样可能恒真** —— 若 `check-methods` 对任何 `skipped` 项都报错，AC-018 照样绿；若 `dimensions.json` 被删了它照常读硬编码兜底，AC-020 照样绿。本条用两种手段证伪：**正反对消**（合法写法必须被接受）＋ **数据级变异**（改数据而非改代码，因此不依赖实现内部变量名）


### AC-023: 四个谓词分支必须真的生效（`has_dimension` / `dimension_pair_present` / `min_assertions_per_case` / `min_cases_total`）
- **前置条件**: 四份用例集，**每份故意违反对应谓词**：
  - 场景 1（`has_dimension`，M1.4 状态迁移要求 exception 维度）：声明 M1.4，但条目下**没有** exception 维度用例
  - 场景 2（`dimension_pair_present`，M1.5 正交要求 functional + data 同时覆盖）：声明 M1.5，但**没有** data 维度用例
  - 场景 3（`min_assertions_per_case`，M1.3 判定表要求每例 ≥2 条断言）：声明 M1.3，但每条用例**只有 1 条**断言
  - 场景 4（`min_cases_total`，M1.6 场景法要求 ≥2 条用例）：声明 M1.6，但条目下**只有 1 条**用例
  - ⚠️ **每份样本必须只违反一个谓词**（D21 修正）：同一个方法上的**其它**谓词必须**满足**，
    否则被测谓词失效时另一个谓词仍会报错、"缺少必需产出"照样出现 → 测不出目标谓词。
    具体地：场景 1 给 **2 条** functional 用例（满足 `min_cases_total(min=2)`）、
    场景 2 给 **4 条** functional 用例（满足 `min_cases_total(min=4)`）、
    场景 3 给 2 条 functional 用例且两条的 `expected` **互不相同**（满足 `min_cases_by_dimension(min=2)` + `distinct_expected`）、
    场景 4 给 1 条 functional 用例（满足 `min_cases_by_dimension(min=1)`）
- **测试步骤**: 跑 `node scripts/check-methods.mjs <用例集>`，四份各一次
- **预期结果**: 四份都**退出码 1**，且都报出"缺少必需产出"（`METHOD_OUTPUT_MISSING`），且**点名对应的方法编号**（`M1.4`/`M1.5`/`M1.3`/`M1.6`）
- **判据形式**: 每份的输出里必须**同一行**出现该方法编号与"缺少必需产出"；退出码 ≠ 0
- **类型**: 功能
- **说明**（D17）: 独立验收实测 —— 这四个谓词分支**没有任何 AC 触达**（验收样本只用了 M1.1/M1.2），把任一分支置空后验收脚本仍 **23 PASS / 0 FAIL**。**方法库里的每个谓词都必须有判据**，否则它随时会被悄悄删掉

### AC-024: M0.x / M4.x 判"无法判定"，**不得**默认通过（虚报类红线）
- **前置条件**: 一份用例集，`coverage_matrix[0].methods_applied = ["M0.1"]`（Layer 0 必选测试点段编号，**不在设计方法库内**），`cases[0].method = ["M0.1"]`
- **测试步骤**: 跑 `node scripts/check-methods.mjs <用例集> --json`，检查输出 JSON
- **预期结果**:
  1. `undecidable` 数组里**有** `M0.1` 这条
  2. `verdicts` 里 `M0.1` 的 `status` 是 `undecidable`，**绝不是** `satisfied`
  3. `errors` 数组里**没有** `M0.1`（它不是"产出缺失"，是"判不了"）
  4. `summary.undecidable` ≥ 1
- **判据形式**: ①`undecidable` 含 `M0.1` ②`verdicts` 中 `M0.1` 的 status == `undecidable` ③`satisfied` 里**不含** `M0.1`
- **类型**: 功能
- **说明**（D17 / D8 / D10）: 独立验收实测 —— 把 `M0.1` 从"无法判定"改成 `satisfied`（**假绿灯**）后，验收脚本仍 **23 PASS / 0 FAIL**。这是**虚报类**规则却**完全没有 AC**，违反 D9。本条是"宁可漏报通过，不可虚报通过"这条底线的直接护栏

### AC-025: `check-methods.mjs` 的跳过文案也要区分方法/维度（D13 的另一侧）
- **前置条件**: 两份用例集。场景 A：`skipped = [{"method":"M1.4"}]`（缺 reason）。场景 B：`skipped = [{"method":"dimension:concurrency"}]`（缺 reason）
- **测试步骤**: 跑 `node scripts/check-methods.mjs <用例集>`，两份各一次
- **预期结果**: 两份都**退出码 1**（缺 reason 是 ERROR）。场景 A 的报错说"方法"并点名 `M1.4`；场景 B 的报错说"维度"并点名 `concurrency`，且**不得**出现"跳过方法"
- **判据形式**: A 的输出含 `M1.4` 且含"方法"；B 的输出含 `concurrency` 且含"维度"；B 的输出**不含**"跳过方法"
- **同行约束**: ⚠️ **必须同行**：判据要求"方法编号/维度名"与"方法/维度"二字出现在**同一行** —— 脚本输出末尾有"按维度分布:"这类汇总行，只查"输出里出现过 维度"会被那行蒙混过关（恒真判据比不判还糟）。（D21 修正：初版未做同行约束，实测变异体「文案回退成跳过方法」可从汇总行蒙混过关）
- **类型**: 可用性
- **说明**（D17 / D13）: 独立验收实测 —— 把 `check-methods` 的文案改回统一说"跳过方法"后，验收脚本仍 23/0（`validate-cases` 侧的文案由 AC-017 覆盖，**`check-methods` 侧此前是裸奔的**）。D13 要求"两脚本措辞口径一致"，本条补齐缺的那一半

### AC-026: 变异体必须 100% 被检出（合并前硬门槛）
- **前置条件**: 被验 skill 目录的**副本**（绝不原地改被验对象）
- **测试步骤**: 逐个注入下列变异，**每个都在副本上做**，然后**跑本验收脚本**，看脚本的判定是否与基线不同
- **判定的可比口径**: 取「**失败的 AC 键集合**」（从输出的 `FAIL` 行里抽出 `AC-xxx`）。
  变异后该集合与基线**不同**（对称差非空）= 被测出；完全相同 = **逃逸**。
  （只看退出码会漏：脚本崩溃时退出码也是 1；只比输出全文会太脆。
  ⚠️ 不能只比"基线之上**多出**"：基线本来就红的 AC 被变异弄坏时集合没变 → 会被误判成逃逸，
  所以用**对称差**，两侧都算。（D22 修正））
- **必须覆盖的变异清单**（**19 个，每个都必须被测出，漏一个即本条 FAIL**）:
  1. `check-methods`：`min_cases_by_dimension` 判定失效（kind 字符串保留，只让分支永不命中）
  2. `check-methods`：ERROR 不再阻断（退出码恒 0）
  3. `check-methods`：`distinct_expected` **子字段**谓词失效
  4. `check-methods`：`dimension_pair_present` 判定失效（**分支置空，kind 字符串保留**）
  5. `check-methods`：`has_dimension` 判定失效（同上）
  6. `check-methods`：`min_assertions_per_case` 判定失效（同上）
  7. `check-methods`：`min_cases_total` 判定失效（同上）
  8. `check-methods`：M0.x/M4.x 由"无法判定"改成默认通过 ← **虚报类**
  9. `check-methods`：维度适用性检查不再报出 `DIMENSION_MISSING`
  10. `check-methods`：`verdicts` 漏判（不覆盖每个 需求×方法 组合）
  11. `check-methods`：`undecidable` 误判成 `satisfied` ← **虚报类**
  12. `check-methods`：文案回退成"跳过方法"
  13. `validate-cases`：删掉 `skipped[].method` 的 `dimension:` 前缀放宽
  14. `validate-cases`：拼错维度名 ERROR 降回 WARN
  15. `validate-cases`：读不到 `dimensions.json` 改成静默降级到内置列表
  16. `validate-cases`：文案统一回"跳过方法"
  17. `validate-cases`：放宽 `cases[].method[]` 接受 `dimension:` 前缀
  18. `validate-cases`：放宽 `coverage_matrix[].methods_applied[]` 接受 `dimension:` 前缀
  19. `check-methods`：ERROR 的**严重级别标签**被改成 WARN
- **预期结果**: **19/19 全部被测出**
- **判据形式**: 逐个变异记录"被测出/未被测出"；**未被测出的个数必须为 0**；
  变异清单长度必须 ≥ 19（防止清单被悄悄删短）；变异后必须确认**还原干净**（再跑一次基线，失败项集合回到基线）
- **类型**: 回归
- **说明**（D17 / D21）: 独立验收第二轮实测 **24 个变异体只检出 18 个、逃逸 6 个** —— 本条把那份清单固化为**合并前的硬门槛**。
  变异注入有三条纪律：① **必须保持语法正确**（把变异做成语法错误 → 脚本崩溃 → 退出码非 0 → 被"测出"，但那是假检出；独立验收第一版就踩了这个坑，BA 复现时才发现）
  ② **必须让分支真的失效而非让 kind 字符串消失**（改 kind 字符串会让库结构校验失败 → 同样是被"崩溃"测出，不是真检出）
  ③ **被测对象是"验收脚本的判定"而不是"实现的输出"** —— 逃逸的根因是**验收样本没覆盖那条规则**，
  只比实现的输出变没变会把"护栏漏测"误判成"没问题"（D17 的原案就是这么错的，D21 纠正）
  ④（脚本实现约束）变异后若被验脚本**抛异常栈**，判为**假检出不计入** —— 测出的是崩溃，不是护栏失效

### AC-027: 实现里的注释不得与实现相反
- **前置条件**: `scripts/validate-cases.mjs`
- **测试步骤**: 检索该文件里关于"维度名不在枚举内"的注释，比对其对应实现分支用的是 `fail`（ERROR）还是 `warn`（WARN）
- **预期结果**: 注释描述的严重度与实现**一致**
- **判据形式**: 注释里若出现"只报 WARN"字样，则实现分支**必须**用 `warn`；反之实现用 `fail` 时注释**不得**再说"只报 WARN"
- **类型**: 可用性
- **说明**（D19）: 独立验收实测 —— D15 已把该分支改为 ERROR，但注释仍写「维度名不在 8 个覆盖维度枚举内时**只报 WARN**…报 ERROR 会把'名字不认识'和'格式非法'混为一谈」。**实现对了、注释说反了** → 后来人照注释"修回去"即制造回归。注释即陷阱，这类"注释与实现分叉"正是本项目一直在消灭的东西

### AC-028: `feature-meta/` 不得张冠李戴（追溯链不得断）
- **前置条件**: `feature-meta/` 下的 `status.md` / `traceability.md` / `verification-report.md` / `manifest.json`
- **测试步骤**: ①逐个检查前三份文件里的**需求编号与分支名**是否属于本 REQ ②检查 `manifest.json` 的 `demand_dir` 是否指向**真实存在**的目录
- **预期结果**: ①三份文件里的需求编号与分支名都是 `REQ-005` / `feature/REQ-005`（不得是别的 REQ 的）②`demand_dir` 指向的目录**存在**
- **判据形式**: ①检索前三份文件里是否出现**其它** REQ 编号（`REQ-003`/`REQ-004` 等）②`ls <demand_dir>` 成功
- **类型**: 可用性
- **说明**（D19 / D20）: 独立验收实测 —— `feature-meta/` 三个文件**全是别的 REQ 的内容**（status.md 是 REQ-003、traceability.md 与 verification-report.md 是 REQ-004，其"23 PASS / 0 FAIL"是 **REQ-004** 的验收数）；`manifest.json` 的 `demand_dir` 写 `BA/demands/REQ-005`，该路径**不存在**。拿别的 REQ 的验证报告当本 REQ 的交差 = **虚报的另一种形态**；追溯链断掉则无法回查本 REQ 到底验了什么

### AC-029: ERROR 必须真的标成 ERROR（不得被降级成 WARN）
- **前置条件**: `scripts/check-methods.mjs`；一份**确实存在产出缺失**的用例集（验收脚本自带的 `a.json`）
- **测试步骤**: 跑 `node scripts/check-methods.mjs <用例集>`（**人读输出**，不带 `--json`），
  再跑一次 `--json` 取 `summary.errors` 做计数核对
- **预期结果**:
  1. 人读输出里有 `ERROR 明细` 这一节（产出确实缺失 → 这一节的标题必须是 ERROR）
  2. `结论:` 那一行里，错误计数标成 ERROR（即 `N 个 ERROR`）
  3. 人读输出里有 `WARN 明细` 这一节
  4. 人读输出里的错误条数 == `--json` 的 `summary.errors`
- **判据形式**: 四个子判据（`ERROR 明细` 标题存在 / `结论:` 行含 `个 ERROR` / `WARN 明细` 标题存在 /
  错误计数 == JSON `summary.errors`）**全部**满足才算通过
- **类型**: 功能
- **说明**（D21）: AC-026 的变异清单第 19 条「ERROR 的严重级别标签被改成 WARN」**此前没有任何 AC 护栏** ——
  改完之后验收脚本照样全绿。后果不是"退出码变了"（退出码由 `errors.length` 决定，仍是 1），
  而是**输出骗人**：agent 看到 "WARN 明细" 就以为可以放过，而契约要求"ERROR 必须修、WARN 必须说明"。
  这是 **D9 的第四次应验**（实现写了、验收没测 → 随时会被悄悄改回去）。
  ⚠️ 判据查的是**人读输出**而不是 `--json`：`--json` 的 findings 字段把 `severity` 裁掉了
  （`errors[]` / `warnings[]` 两个数组本身已经表达了严重度，JSON 里再放一份是冗余）——
  查 JSON 会得到**假阴性**（BA 侧第一版就是这么写的，实测才发现）

### AC-030: `--help` 属用法错误 —— 两个脚本都必须退出码 2 并给出用法（D19 第②项）
- **前置条件**: `scripts/check-methods.mjs` 与 `scripts/validate-cases.mjs`
- **测试步骤**: 分别跑 `node scripts/check-methods.mjs --help` 与 `node scripts/validate-cases.mjs --help`
- **预期结果**: 两个都**退出码 2**（= 调用方式错误），且输出里都含「用法」
- **判据形式**: 两个脚本各自满足「rc == 2 且输出含"用法"」，**两条都满足**才算通过
- **类型**: 可用性
- **说明**（D19 / D21）: D19 列的三项 P2 里，只有①（注释与实现相反）和③（feature-meta 张冠李戴）有 AC 护栏，
  ②（`--help` 退出码口径）**此前完全没有 AC** —— 实测两个脚本对同一个 `--help` 给出不同结论：
  `check-methods` rc=2（用法错误），`validate-cases` rc=1（把 `--help` 当成用例集文件路径 →
  "无法读取用例集文件"）。两个脚本的脚本头都声明「2 = 调用方式错误」，所以 `validate-cases` 的 rc=1 是错的。
  **又一次 D9**：实现写了、验收没测 → 随时会被改回去
