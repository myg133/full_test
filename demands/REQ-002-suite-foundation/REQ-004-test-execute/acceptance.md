# 验收标准：REQ-004 执行 skill 与证据链

> 每条 AC 必须可机械验证。测试样例放 `/tmp/qa-004/` 下构造，不污染真实仓库。
> 记 `SK=<skill 目录>`，`EX=$SK/scripts`。

### AC-001: `test-execute` skill 目录结构完整
- **前置条件**: 无
- **测试步骤**: 检查 `skills/test-execute/` 下是否含 `SKILL.md`、`scripts/`、`references/`，以及 `executors/index.json`
- **预期结果**: 四者齐全；`SKILL.md` 有合法 frontmatter（`name` / `description`）
- **类型**: 功能

### AC-002: 执行器注册表声明可配置项与边界
- **前置条件**: 源码级检查
- **测试步骤**: 读 `executors/index.json`
- **预期结果**: 每个已注册执行器都声明了 `configurable[]`（可配置项清单）与 `not_supported[]`（明确不支持的定制）；清单里至少出现 `request` / `assertions` / `extract` / `auth` / `timeout_ms` / `retries`
- **类型**: 功能

### AC-003: 执行器实现不可被 agent 修改（硬约束）
- **前置条件**: 源码级检查
- **测试步骤**: 检查 `SKILL.md` 是否含明确的"不得修改执行器实现 / 不得改 skill 目录内的脚本"约束，且该约束可辨识（不是泛泛而谈）
- **预期结果**: 约束存在且可辨识
- **类型**: 文档

### AC-004: 断言规则完全可配置，判定不写在执行器里
- **前置条件**: 源码级检查 + 行为验证
- **测试步骤**: (a) 检索执行器实现里是否存在硬编码的"期望值/断言"字面量；(b) 构造一个断言里把期望状态码改成 404 的用例，执行后结果应变为 failed
- **预期结果**: (a) 执行器实现中**不含**用例级的期望值字面量；(b) 判定结果随断言变化而变化
- **类型**: 功能

### AC-004b: 断言载体 —— `steps[].expected` 支持结构化断言对象
- **前置条件**: 一个用例，其中一条 step 的 `expected` 是断言对象 `{"path":"$.status","op":"equals","expected":"ok"}`，另一条是普通字符串
- **测试步骤**: (a) 跑 `node skills/test-case-design/scripts/validate-cases.mjs` 校验该用例集；(b) 执行该套件，检查判定结果
- **预期结果**: (a) 校验通过；(b) 该用例**可机械判定**，按断言对象判定
- **类型**: 功能

### AC-004c: 不可机械判定的用例判 `blocked`，不得判 `passed`
- **前置条件**: 一个用例，其所有 step 的 `expected` 都是普通字符串
- **测试步骤**: 执行该套件，检查该用例的 `status` 与 `error`/`reproduction` 里的理由
- **预期结果**: `status` = `blocked`（**不是** `passed`）；理由明确指向"缺少可机械判定的断言"
- **类型**: 功能

### AC-004d: 断言对象字段缺失或 `op` 非法被校验器拦
- **前置条件**: 四例 —— 断言对象缺 `path`、缺 `op`、`op` 为 `"equalsx"`（不在枚举内）、`op` 为 `equals` 但缺 `expected`
- **测试步骤**: 分别造用例集，跑 `node skills/test-case-design/scripts/validate-cases.mjs`
- **预期结果**: 四例均退出码 1，报错点名具体字段
- **类型**: 功能

### AC-004e: 旧用例集行为不变（向后兼容）
- **前置条件**: REQ-002A 时期的用例集样本（`steps[].expected` 全为字符串）
- **测试步骤**: 跑 `validate-cases.mjs`；并跑 REQ-002A 的既有行为对拍（v1 兼容产物应 exit 0、显式声明 v2 但缺字段应 exit 1）
- **预期结果**: 旧样本仍按原规则校验，退出码与放宽前**完全一致**
- **类型**: 回归


### AC-005: 判定口径由执行外壳统一
- **前置条件**: 源码级检查
- **测试步骤**: 检索 `status`（`passed`/`failed`/`blocked`/`skipped`）的赋值位置
- **预期结果**: `status` 的判定逻辑只存在于执行外壳（单一模块），执行器实现中不出现 `passed` / `failed` 的判定分支
- **类型**: 一致性

### AC-006: 凭证边界 —— 读不到环境变量判 `blocked` 而非 `failed`
- **前置条件**: 环境配置里 `username_env` 指向一个**不存在**的环境变量
- **测试步骤**: 执行该套件
- **预期结果**: 该用例 `status` = `blocked`；`results.json` 里 `error.type` 表明是环境/凭证缺失；**不是** `failed`
- **类型**: 功能

### AC-007: 产物中不含凭证明文
- **前置条件**: 正常凭证的环境配置 + 一个执行成功的用例
- **测试步骤**: 递归扫描 `.test-artifacts/` 下所有文件（含 evidence、日志、meta.json、results.json），搜环境变量的真实值
- **预期结果**: 真实凭证值**零出现**
- **类型**: 安全

### AC-008: 证据链结构完整
- **前置条件**: 一次成功执行
- **测试步骤**: 检查 `.test-artifacts/<run_id>/` 下的 `meta.json` 与 `results.json`
- **预期结果**: `meta.json` 含 `run_id` / `suite` / `scope` / `requirement` / `environment` / `started_at` / `finished_at` / `duration_ms` / `agent` / `executor` / `tool_versions` / `cases_total` / `cases_passed` / `cases_failed` / `cases_blocked` / `cases_skipped`；`results.json` 每条含 `case_id` / `status` / `started_at` / `finished_at` / `duration_ms` / `evidence[]` / `reproduction`
- **类型**: 功能

### AC-009: sha256 指纹与防篡改
- **前置条件**: 一次成功执行
- **测试步骤**: 跑 `node $EX/verify-evidence.mjs <run_dir>`，确认通过；然后**篡改一个 evidence 文件**（改一个字节），再跑一次
- **预期结果**: 篡改前退出码 0；篡改后退出码 1，报错指出被改动的文件；删除某个 evidence 文件同样被报出
- **类型**: 安全

### AC-010: `meta.json` 的清单指纹能发现 `results.json` 被改
- **前置条件**: 一次成功执行
- **测试步骤**: 直接编辑 `results.json`（把某条 `status` 从 `passed` 改成 `failed`），再跑 `verify-evidence.mjs`
- **预期结果**: 退出码 1，报错指出 `results.json` 与清单指纹不符
- **类型**: 安全

### AC-011: 计数不可造假
- **前置条件**: 一次成功执行
- **测试步骤**: 把 `meta.json` 的 `cases_total` 改成与 `results.json` 条数不同的值，再跑 `verify-evidence.mjs`
- **预期结果**: 退出码 1，报错指出计数与实际条数不符
- **类型**: 功能

### AC-012: 与轮次状态集成 —— 状态只能经 `cycle-state.mjs` 写
- **前置条件**: 一个已 `init` 的轮次 + 一个 `suite.json`
- **测试步骤**: 执行一次套件；检查 `cycle.json` 的 `stages.execute.status` 与 `stages.execute.runs[]`；再检查执行过程中 `cycle.json` 是否被绕过脚本直接改写
- **预期结果**: `stages.execute.status` 被更新为 `in_progress`（或按阶段推进）；`runs[]` 含本次 `run_id`；**执行器代码中不含直接写 `cycle.json` 的路径**
- **落地方式**: `runs[]` 由 `cycle-state.mjs` 的新参数 `--run <run_id>` 写入（执行器与执行外壳**都不直接写 `cycle.json`**，D11 + D15）
- **类型**: 功能

### AC-013: 脱敏在写入前完成，且留痕
- **前置条件**: 一个响应体里含敏感字段（如 `token` / `phone` / `idCard`）的 mock 场景
- **测试步骤**: 执行；检查 `evidence/` 下的原始产物内容、`meta.json` 的 `redaction` 段
- **预期结果**: 证据文件中敏感值已被替换（不可见明文）；`meta.json` 含 `redaction.rules_applied[]` 与 `redaction.redacted_fields` 计数
- **前置条件（关键）**: 凭证必须在**执行之前**就位，且用例带鉴权真的发了请求。验收必须先确认"凭证被用上了"（用例不是 `blocked`、证据文件存在），再断言"产物里搜不到明文" —— 否则是空测，恒真
- **类型**: 安全

### AC-014: 离线可跑 —— mock 执行器自证机制成立
- **前置条件**: 无外网
- **测试步骤**: 只用内置 mock 执行器跑通一个完整套件（`init` → 执行 → `verify-evidence.mjs`）
- **预期结果**: 全流程 exit 0，产出完整证据链，**不依赖任何外部服务**
- **退出码口径**（D18）: 这里的 exit 0 指**执行流程**成功。用例级结果（有没有用例 `failed` / `blocked`）看 `results.json` / `meta.json`，不由退出码表达 —— 否则"跑通了"与"有用例失败"两个场景无法共用一个退出码
- **类型**: 功能

### AC-015: 零依赖 + 可移植
- **前置条件**: 源码级检查
- **测试步骤**: 检查 `package.json` 的 `dependencies`；检索执行器与脚本里的 `child_process` / `python3` / `bash` / `grep` / `sed` / 硬编码 `/tmp`
- **预期结果**: `dependencies` 为空；无上述外部依赖与硬编码路径
- **类型**: 非功能

### AC-016: 执行器完整性自检能发现 agent 改了执行器源码
- **前置条件**: 一次执行后，在 `executors/` 下改一个执行器实现的某个字节
- **测试步骤**: 跑 `node $EX/verify-integrity.mjs`
- **预期结果**: 退出码 1，报错指出被改动的执行器文件；改回后退出码 0
- **类型**: 安全

### AC-017: `--json` 输出与退出码语义一致
- **前置条件**: 合法套件
- **测试步骤**: 对成功、校验失败、调用方式错误三种情形各跑一次带 `--json` 的执行
- **预期结果**: 三种情形的 stdout 均可被 `JSON.parse` 成功；退出码分别为 `0` / `1` / `2`
- **退出码口径**（D18）: `0` = 执行流程成功（用例结果另看 `results.json`）；`1` = 执行流程失败（配置非法 / 驱动起不来 / 证据自校验不通过）；`2` = 用法错误。另设 `--strict`：有 `failed` 或 `blocked` 用例时退 1
- **类型**: 功能

### AC-018: 失败用例必须有复现信息
- **前置条件**: 一个会失败的用例
- **测试步骤**: 执行后检查该条用例的 `reproduction`
- **预期结果**: `reproduction.steps` 非空，且 `command`（若该执行器能给出）非空
- **类型**: 功能

### AC-019: 多步用例逐步执行、逐步判定（防"半个用例报通过"）
- **前置条件**: 一条用例含**两个可执行 step**，各自带断言对象；第 1 步断言成立、第 2 步断言**不成立**
- **测试步骤**: 执行后检查该用例的 `status`、证据条目数
- **预期结果**: 该用例判 `failed`；证据条目数 ≥ 2（**两个请求都真的发出了**）。**不得判 `passed`** —— 只跑第一步就报通过，是最危险的一类虚报
- **说明**: 断言绑定到它所属 step 的响应（D12/D13）。所在 step 不可执行时判 `blocked`，不得判 `passed`
- **类型**: 功能

### AC-020: 多步用例各步断言都成立时判通过
- **前置条件**: 一条用例含两个可执行 step，两个断言都成立
- **测试步骤**: 执行后检查该用例的 `status`、证据条目数
- **预期结果**: 该用例判 `passed`；证据条目数 ≥ 2
- **说明**: 与 AC-019 是一对 —— 两条一起才能证明判定**落在正确的步骤上**（既不漏判也不误判）
- **类型**: 功能

### AC-021: 载体冲突判 `blocked`（显式用例级载体 + 不同端点的 step）
- **前置条件**: 一条用例带 `request: {method: GET, path: /ok}`，`steps[]` 却是 `GET /ok` 与 `GET /notfound` 两条可执行步骤
- **测试步骤**: 执行后检查该用例的 `status`
- **预期结果**: 该用例判 `blocked`（原因指向载体冲突），**不得判 `passed`** —— 静默丢掉其中一个请求，正是「半个用例报通过」的另一个入口
- **理由**（D20）: "这是一次调用还是多次调用"是需求方的意图，实现不该替它猜。判 `blocked` 并要求澄清，与本套件"歧义要显式"一贯一致
- **类型**: 功能

### AC-022: `reproduction.steps` 如实（证据条数必须与复现步骤数一致）
- **前置条件**: 一条用例带 `request`（GET /ok），`steps[]` 声明两步同端点步骤 —— 按 D20 视为**同一次**请求
- **测试步骤**: 执行后比对「该用例的证据文件数」与「`reproduction.steps` 的长度」
- **预期结果**: 两者相等；用例非 `blocked` 时，`reproduction.steps` 里的每一步都必须对应一份真实证据；且两者的**路径序列逐项一致**（不只是条数相等 —— "条数对但内容指向别的步骤"同样是复现信息不实，独立验收 P2-2）
- **理由**（D21）: 复现信息是证据链三要素之一。说"跑了两步"却只有一份证据，证据链自身就不可信
- **类型**: 功能

### AC-023: 用例级载体缺 `path` 判 `incomplete_request_carrier`（不得误诊为"冲突"）
- **前置条件**: 一条用例带 `request: {query: {a: "1"}}`（**只有 query，没有 path**），`steps[]` 是 `GET /ok`
- **测试步骤**: 执行后检查该用例的 `status` 与 `error.type`
- **预期结果**: 判 `blocked`；`error.type` 为 `incomplete_request_carrier`（**不是** `conflicting_request_carrier` —— 缺路径与载体冲突是两种不同的修法：补齐 vs 二选一）
- **理由**（D23）: 错误信息要指向**真正**的问题。误诊会让调用方去找一个不存在的冲突
- **类型**: 功能

### AC-024: step 级载体缺 `path` 同样判 `incomplete_request_carrier`
- **前置条件**: 一条用例带 `request: {method: GET, path: /ok}`，`steps[]` 里有 `request: {method: GET}`（**缺 path**）
- **测试步骤**: 执行后检查该用例的 `status` 与 `error.type`
- **预期结果**: 判 `blocked`；`error.type` 为 `incomplete_request_carrier`（**不是** `conflicting_request_carrier` —— 缺 path 的 step 载体与用例级载体并不"冲突"，是它自己没写全）
- **理由**（D25）: "缺 path 是补齐，不是二选一"这条规则与载体在哪一层无关；只对用例级载体生效等于规则只写了一半
- **类型**: 功能

### AC-025: 判 `skipped` 的用例不得发出请求
- **前置条件**: 本地起一个**计数 HTTP 服务器**（记录收到的每一个请求路径），环境配置的 `base_url` 指向它、不设 `driver`（即走 `api` 驱动）。三条用例各带一条可执行 step：`TC-ACT`（`status: active`，`GET /ok`）、`TC-DEP`（`status: deprecated`，`GET /notfound`）、`TC-BLK`（`status: blocked`，`GET /created`）；后两条另带非空 `revision.change`
- **测试步骤**: 执行后检查 ①`results.json` 里各用例的 `status` 与证据条目数 ②计数服务器收到的请求路径列表
- **预期结果**:
  1. `TC-DEP` 判 `skipped`
  2. 计数服务器的请求列表里**不含** `/notfound`，也不含任何属于被判跳过用例的路径
  3. 所有 `status == skipped` 的用例，证据条目数 == 0
  4. **对照组**：`TC-ACT` 判 `passed`，且计数服务器**确实收到过** `GET /ok`
- **理由**（D28）: 判了 `skipped` 却真发请求，是"证据链说的与实际做的不一致"（D21）的另一个入口；比"虚报通过"更危险 —— 报告说这条没跑，**被测系统却已经被改了**。第 4 条是对照组：没有它，"什么都不发"也能让前三条判绿
- **刻意的覆盖边界**: 本条只判**不变式** —— 「凡是判了 `skipped` 的用例，一个请求都不许发」。它**不断言** `blocked` 状态的用例必须不执行：`case.status == "blocked"` 该不该执行，与 REQ-002A 的"`blocked` 计入覆盖"存在语义张力（见 decisions.md D32），执行层按"歧义显式拒"不替需求方裁定。因此实现方选择「`deprecated` 与 `blocked` 都跳过」或「`blocked` 也执行（并如实报告）」都能通过本条 —— 前提是**它判 skipped 的那些，用例确实没发请求**
- **配套要求**: 这个边界不靠本条兜底，靠 **AC-025b** 兜（见下）

### AC-025b: 两种「不执行」生命周期的处理必须一致（不能一个跳一个不跳）
- **前置条件**: 两条用例 —— 一条 `status: deprecated`（`GET /notfound`）、一条 `status: blocked`（`GET /created`）；用本地计数 HTTP 服务器记录收到的每个请求
- **测试步骤**: 执行后比对「被跳过（`skipped`）的条数」与「实际发出请求的条数」
- **预期结果**: `skipped` 的条数**只能是 0 或 2** —— 两条要么**都跳过**（0 请求），要么**都执行**（2 请求）。**skipped == 1 就是处理规则分叉，判 FAIL**
- **理由**（D25 的推广）: 独立验收实测：把生命周期清单里的 `blocked` 去掉（`deprecated` 跳过、`blocked` 执行），**AC-025 测不出来** —— 分叉处理仍然满足「判 skipped 的不许发请求」这个不变式。同一条语义规则对两种载体分叉生效，等于没有规则
- **不裁决什么**: 本条**不断言** `blocked` 该不该执行，只要求两个**一致** —— "该跳过还是该执行"是需要方裁定的语义，"不许分叉"是实现方的义务
- **类型**: 功能

### AC-026: 传输层错误时，已执行步骤的证据必须保留
- **前置条件**: mock 驱动。一条用例含两个可执行 step：第 1 步 `GET /ok`（成功），第 2 步 `GET /slow?ms=3000`（**超时**）；用例级 `timeout_ms: 300`
- **测试步骤**: 执行后检查该用例的 `status`、`error.type`、证据条目数、`reproduction.steps` 的长度
- **预期结果**:
  1. `status == failed`（超时是执行失败，不是环境缺失）
  2. `error.type == timeout`
  3. 证据条目数 ≥ 1 —— **第 1 步成功的响应必须留下**
  4. `reproduction.steps` 非空，且**证据条目数 == `reproduction.steps` 长度**（D21/D24：执行过请求时两者必须一致）
- **第 4 条的等价表述**: `reproduction.steps` 里的每一步都必须对应一份证据 —— 要么把超时这一步也留一份证据（失败记录本身也是观察结果），要么就不把它列进 `reproduction.steps`。**"列了但没证据"与"有证据但没列"都不行**
- **理由**（D29）: 实测当前实现里，执行器在请求失败时直接 `return { error }`，把**此前已成功的步骤全部丢弃** —— 第 1 步明明跑过、响应明明拿到了，证据却一份不剩；`reproduction.steps` 却仍列着两步。传输层错误不该抹掉已经发生的执行事实
- **类型**: 功能

### AC-026b: 复现步骤的路径序列必须与证据的请求路径序列一致
- **前置条件**: 同 AC-026 的场景（两 step：第 1 步成功、第 2 步超时）
- **测试步骤**: 取该用例 `reproduction.steps` 里每一步的**路径**，与 `evidence/<case_id>/` 下各证据文件里记录的 `request.path` 按顺序逐一比对
- **预期结果**: 两个序列**长度相等且逐项相同**
- **理由**: AC-026 第 4 条只查**条数**，查不出「条数对但内容错位」的情形 —— 证据明明是第 1 步的响应，`reproduction.steps` 里写的却是第 2 步（超时的那个）。独立验收实测：把复现步骤映射成"下一个请求"即可造出这种错位，**AC-026 测不出来**。证据链说的与实际做的不一致，整条链就不可信
- **类型**: 功能

### AC-027: 执行器生命周期必须收尾（异常路径也要停）
- **前置条件**: 复制一份 skill 目录，把 `scripts/lib/verdict.mjs` 的 `export function decide(` 改成**立即抛异常**（模拟判定层崩溃）；用 mock 驱动跑一条用例
- **测试步骤**: `timeout 20 node scripts/run-suite.mjs <suite.json> --json`，看退出码
- **预期结果**: 退出码 **≠ 124**（124 = 被 `timeout` 杀掉 = 挂死）；**且整段耗时 ≤ 15 秒**。进程必须在有限时间内结束
- **补充**: 光看退出码不够 —— "卡住 19 秒然后自己退出"也能让退出码不为 124，所以**必须加耗时上限**。这一条是实现方在修复后主动指出的判据漏洞，已补入
- **理由**（D30）: mock 驱动会起一个内置 HTTP 桩服务。执行外壳的 `driver.stop()` 只在正常路径上调用，没有 `finally` —— 任何异常都会跳过收尾，桩服务继续持有事件循环，**进程永不退出**。实测：判定层改成抛异常后，JSON 已输出（exit_code 1），进程却一直挂着直到被杀掉
- **类型**: 健壮性

### AC-028: `meta.cycle` 段不得谎报推进结果
- **前置条件**: 两个子场景。①`--cycle` 指向**不存在的轮次目录**（推进必然失败）②`--cycle` 指向**存在的轮次目录**（推进应当成功）
- **测试步骤**: 两次都跑 `--json`，检查 `cycle` 段与退出码
- **预期结果**:
  - ① `cycle.ok == false`；`cycle.runs_recorded == false`；`cycle.stage_status == null`（**状态未知**）；**退出码 == 1**；**顶层 `ok == false`**（"执行流程成功"含轮次推进成功）
    - ⚠️ `stage_status` 必须**锁死为 `null`**，不能只判"不等于 `in_progress`" —— `"pending"` 这类同样误导人的值也必须被挡住
  - ② `cycle.ok == true`；`cycle.runs_recorded == true`；`cycle.stage_status == "in_progress"`；**退出码 == 0**；顶层 `ok == true`
- **理由**（D31）: `meta.cycle` 段当前把 `stage_status` 与 `runs_recorded` **硬编码**成 `in_progress` / `true`，与同一段里的 `ok: false` 自相矛盾 —— 推进失败也照写"已记录"。轮次推进失败属于执行流程失败（用户要求把这次执行记进轮次，没记上就是没做完），按 D18 退出码应取 1；用例本身全通过不改变这一点。②是配对的**成功场景**，防止为了满足①而把字段一律写成 `false`
- **类型**: 功能
