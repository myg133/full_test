# 验收标准：REQ-002.5b 执行 skill 与证据链

> 每条 AC 必须可机械验证。测试样例放 `/tmp/qa-0025b/` 下构造，不污染真实仓库。
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
- **类型**: 功能

### AC-013: 脱敏在写入前完成，且留痕
- **前置条件**: 一个响应体里含敏感字段（如 `token` / `phone` / `idCard`）的 mock 场景
- **测试步骤**: 执行；检查 `evidence/` 下的原始产物内容、`meta.json` 的 `redaction` 段
- **预期结果**: 证据文件中敏感值已被替换（不可见明文）；`meta.json` 含 `redaction.rules_applied[]` 与 `redaction.redacted_fields` 计数
- **类型**: 安全

### AC-014: 离线可跑 —— mock 执行器自证机制成立
- **前置条件**: 无外网
- **测试步骤**: 只用内置 mock 执行器跑通一个完整套件（`init` → 执行 → `verify-evidence.mjs`）
- **预期结果**: 全流程 exit 0，产出完整证据链，**不依赖任何外部服务**
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
- **类型**: 功能

### AC-018: 失败用例必须有复现信息
- **前置条件**: 一个会失败的用例
- **测试步骤**: 执行后检查该条用例的 `reproduction`
- **预期结果**: `reproduction.steps` 非空，且 `command`（若该执行器能给出）非空
- **类型**: 功能
