# 验收标准：REQ-002.5a 轮次状态推进器（写入权收口）

> 每条 AC 必须可机械验证。测试项目放 `/tmp/qa-0025a/` 下构造，不污染真实仓库。
> 记 `SK=<skill 目录>`，命令一律以 `node $SK/scripts/...` 形式给出。

### AC-001: `show` 读出当前状态与允许的下一步
- **前置条件**: 用 `init` 造一个 `planned` 状态的轮次 `test-assets/cycles/R1-REQ-001/`
- **测试步骤**: `node $SK/scripts/cycle-state.mjs show test-assets/cycles/R1-REQ-001 --json`
- **预期结果**: 退出码 0；输出为合法 JSON；含当前 `status`=`planned`；含 `history` 数组；含**允许的下一步状态列表**，且该列表恰为 `in_progress` 与 `cancelled`
- **类型**: 功能

### AC-002: 合法推进同时更新 status 与 history
- **前置条件**: 轮次处于 `planned`
- **测试步骤**: `node $SK/scripts/cycle-state.mjs advance test-assets/cycles/R1-REQ-001 --to in_progress --by dev-agent-1`
- **预期结果**: 退出码 0；重读文件，`status`=`in_progress`；`history` 新增且仅新增一条 `{from:"planned", to:"in_progress", by:"dev-agent-1"}`；`history` 最后一条的 `to` 等于 `status`
- **类型**: 功能

### AC-003: 非法转移被拒绝且文件零改动
- **前置条件**: 轮次处于 `planned`
- **测试步骤**: 记录文件 sha256；`node $SK/scripts/cycle-state.mjs advance test-assets/cycles/R1-REQ-001 --to completed --by dev-agent-1`
- **预期结果**: 退出码 1；报错指出 `planned → completed` 是非法转移并列出合法的下一步状态；**文件 sha256 与推进前完全一致**（history 未被追加半条）
- **类型**: 功能

### AC-004: `blocked → in_progress` 允许解除阻塞
- **前置条件**: 轮次处于 `blocked`（由 `advance --to blocked` 造出）
- **测试步骤**: `node $SK/scripts/cycle-state.mjs advance test-assets/cycles/R1-REQ-001 --to in_progress --by dev-agent-1`
- **预期结果**: 退出码 0；`status`=`in_progress`；`history` 最后一条 `to`=`in_progress`
- **类型**: 功能

### AC-005: 终态不可离开
- **前置条件**: 轮次分别处于 `completed` 与 `cancelled`
- **测试步骤**: 对两者分别执行 `advance --to in_progress`
- **预期结果**: 两次均退出码 1，报错说明终态不可离开；文件均未修改
- **类型**: 功能

### AC-006: `skip-scope` 强制非空理由
- **前置条件**: 合法轮次
- **测试步骤**: 先 `skip-scope --scope load`（不带 `--reason`），再 `--reason ""`
- **预期结果**: 两次均退出码 1，报错指出理由不能为空；`scopes_skipped` 未被写入；文件未修改
- **类型**: 功能

### AC-007: `skip-scope` 正常写入
- **前置条件**: 合法轮次
- **测试步骤**: `node $SK/scripts/cycle-state.mjs skip-scope test-assets/cycles/R1-REQ-001 --scope load --reason "需求未给性能指标，无阈值可依"`
- **预期结果**: 退出码 0；`scopes_skipped` 含一条 `{scope:"load", reason:"需求未给性能指标，无阈值可依"}`
- **类型**: 功能

### AC-008: `set-stage` 写入阶段状态
- **前置条件**: 合法轮次
- **测试步骤**: `node $SK/scripts/cycle-state.mjs set-stage test-assets/cycles/R1-REQ-001 --stage design --status done`
- **预期结果**: 退出码 0；`stages.design.status`=`done`
- **类型**: 功能

### AC-009: `init` 造出契约合法的新轮次
- **前置条件**: 目标目录不存在
- **测试步骤**: `node $SK/scripts/cycle-state.mjs init test-assets/cycles/R1-REQ-002 --cycle-id R1-REQ-002 --round R1 --round-type new-requirement --requirement REQ-002 --scope functional --by dev-agent-1`
- **预期结果**: 退出码 0；生成 `cycle.json`；`status`=`planned`；`history` 恰一条且 `from`=`to`=`planned`；`cycle_id` 与目录名一致；`requirement`=`REQ-002`
- **类型**: 功能

### AC-010: 原子写 —— 写入后是合法 JSON 且无残留临时文件
- **前置条件**: 合法轮次
- **测试步骤**: 执行一次 `advance`；检查轮次目录内文件列表与 `cycle.json` 的 JSON 解析
- **预期结果**: `cycle.json` 可被 `JSON.parse` 成功；轮次目录内**无临时文件残留**（无 `.tmp` / `.bak` / 以 `.` 开头的半写文件）
- **类型**: 可靠性

### AC-011: 状态机规则单一来源（推进器与校验器行为一致）
- **前置条件**: 合法轮次
- **测试步骤**: 手改 `cycle.json` 的 `status` 为 `completed` 而 `history` 最后一条 `to` 仍为 `in_progress`；分别跑 `node $SK/scripts/verify-layout.mjs <project-root>` 与 `node $SK/scripts/cycle-state.mjs show <轮次目录>`
- **预期结果**: 两者**都**报出「status 与 history 不一致」这一类问题；`verify-layout.mjs` 退出码 1。**判据是两者报告一致，不是只有校验器报错**
- **类型**: 一致性

### AC-012: 校验器复用共享状态机模块（无第二份实现）
- **前置条件**: 源码级检查
- **测试步骤**: 在 `skills/test-case-design/scripts/` 下检索状态转移表、`completed`/`cancelled` 终态判定、以及 `status`↔`history` 一致性判定的实现位置
- **预期结果**: 这些规则的实现**只出现在** `skills/test-case-design/scripts/lib/state-machine.mjs` 一处；`verify-layout.mjs` 通过 import 复用，不得自带第二份转移表或终态判定
- **类型**: 一致性

### AC-013: 契约文档补齐 `cycle.json` 字段表（原缺陷修复）
- **前置条件**: 源码级检查
- **测试步骤**: 检查 `skills/test-case-design/references/project-layout.md` 的轮次章节是否含 `cycle.json` 字段表，且字段表覆盖 `cycle_id` 与 `requirement`
- **预期结果**: 字段表存在；`cycle_id` 与 `requirement` 均在其中，且标注必填
- **类型**: 文档

### AC-014: 按文档构造的 `cycle.json` 能通过校验（原缺陷回归验证）
- **前置条件**: 构造一个**只按 `project-layout.md` 文档字段表填写**的 `cycle.json`（含 `requirement`），项目其余部分合法
- **测试步骤**: `node $SK/scripts/verify-layout.mjs <project-root>`
- **预期结果**: 退出码 0；**不再出现**「requirement 缺少必填字段」的错误
- **类型**: 回归

### AC-015: `SKILL.md` 含全部脚本入口与写入权硬约束
- **前置条件**: 源码级检查
- **测试步骤**: 检查 `skills/test-case-design/SKILL.md` 是否提到 `verify-layout.mjs`、`cycle-state.mjs`、`references/project-layout.md`、`references/state-machine.md`，且包含"状态文件只由脚本写"类约束
- **预期结果**: 四者均被提及；写入权约束存在且可辨识
- **类型**: 文档

### AC-016: 零依赖 + 可移植 + agent 友好
- **前置条件**: 源码级与打包级检查
- **测试步骤**: 检查 `package.json` 的 `dependencies`；在源码中检索 `bash`/`python3`/`grep`/`sed`/`/tmp` 调用；对 `show` 跑 `--json`
- **预期结果**: `dependencies` 为空或不存在；无上述外部命令与硬编码路径；`--json` 输出可被 `JSON.parse` 成功
- **类型**: 非功能
