# 验收标准：REQ-002A 测试套件基座 — Schema v2 与用例生命周期

> 每条 AC 必须可机械验证。

### AC-001: v2 新字段校验生效
- **前置条件**: 存在 `scripts/validate-cases.mjs`（已升级）
- **测试步骤**: 构造含 `open_questions[].interpretations` 仅 1 条的用例集，执行校验
- **预期结果**: 退出码 1，报错中含 `open_questions[0].interpretations` 路径与"至少 2 条"语义
- **类型**: 功能

### AC-002: interpretations 条目字段完整性
- **前置条件**: 同上
- **测试步骤**: 构造 `interpretations[0].reading` 为空字符串的用例集，执行校验
- **预期结果**: 退出码 1，报错定位到 `open_questions[0].interpretations[0].reading`
- **类型**: 功能

### AC-003: open_questions 引用完整性
- **前置条件**: 同上
- **测试步骤**: 构造 `requirement_refs: ["R-99"]`（requirements 中无 R-99）与 `affected_cases: ["TC-999"]`（cases 中无 TC-999）
- **预期结果**: 退出码 1，两处悬空引用分别报错
- **类型**: 功能

### AC-004: blocking + deferred 必须给理由
- **前置条件**: 同上
- **测试步骤**: 构造 `severity: "blocking"`、`coverage: "deferred"`、`defer_reason` 缺失或空的用例集
- **预期结果**: 退出码 1，报错指向 `defer_reason`
- **类型**: 功能

### AC-005: coverage_matrix 校验
- **前置条件**: 同上
- **测试步骤**: 构造 4 类反例——`requirement` 悬空引用、`methods_applied` 为空数组、`skipped[].reason` 为空、`skipped[].method` 格式非法
- **预期结果**: 4 次执行退出码均为 1，各自定位到对应路径
- **类型**: 功能

### AC-006: 用例生命周期状态校验
- **前置条件**: 同上
- **测试步骤**: 构造 `status: "unknown-status"`（非法枚举）、`status: "deprecated"` 但 `revision` 缺失、`revision.change` 为空
- **预期结果**: 3 次执行退出码均为 1，分别报出枚举非法 / revision 缺失 / change 为空
- **类型**: 功能

### AC-007: coverage_matrix 条目唯一性
- **前置条件**: 同上
- **测试步骤**: 构造同一 `requirement` 在 `coverage_matrix` 中出现两次
- **预期结果**: 退出码 1，报错指出重复的需求条目 ID
- **类型**: 功能

### AC-008: 向后兼容 — REQ-001 既有产物仍通过
- **前置条件**: 存在 REQ-001 产出的既有用例集（schema v1 结构，无 `open_questions` / `coverage_matrix` / `method` / `status`）
- **测试步骤**: 对该用例集执行校验
- **预期结果**: **退出码 0**；缺失字段只报 WARN，不报 ERROR
- **类型**: 兼容性

### AC-009: 显式声明 v2 后严格校验
- **前置条件**: 同 AC-008 的用例集，但顶层加 `"schema_version": 2`
- **测试步骤**: 执行校验
- **预期结果**: **退出码 1**，缺失 `open_questions` / `coverage_matrix` / `method` 被报为 ERROR 而非 WARN
- **类型**: 功能

### AC-010: 覆盖统计排除 deprecated
- **前置条件**: 用例集含 2 条 `active` 用例（引用 R-1）与 1 条 `deprecated` 用例（引用 R-2）
- **测试步骤**: 执行校验并查看覆盖统计
- **预期结果**: R-1 标记为已覆盖；**R-2 出现在未覆盖清单中**（deprecated 不算覆盖）
- **类型**: 功能

### AC-011: 渲染脚本输出新增章节
- **前置条件**: 用例集含 `open_questions` 与 `coverage_matrix`
- **测试步骤**: 执行 `node scripts/render-report.mjs <file>`
- **预期结果**:
  - 退出码 0
  - 输出含 5 个部分：用例总览 / 追溯矩阵 / 未覆盖清单 / **未决问题** / **覆盖矩阵**
  - 未决问题章节逐条含 question、各解读及影响、受影响用例 ID
  - 覆盖矩阵章节含已应用方法与跳过方法及原因
- **类型**: 功能

### AC-012: 性能与可移植性不退化
- **前置条件**: 500 条用例的用例集
- **测试步骤**:
  1. 计时执行校验与渲染
  2. `grep -nE "python3|bash |/tmp/|grep |sed "` 扫两个脚本
  3. 检查 import 语句
- **预期结果**:
  - 校验与渲染各 < 2 秒
  - grep 无命中
  - import 仅 `node:` 内置模块，无第三方依赖
- **类型**: 性能

### AC-013: 错误诊断可定位
- **前置条件**: 构造一个同时含 3 处不同类型错误的用例集
- **测试步骤**: 执行校验，查看错误输出
- **预期结果**: 3 条错误分别指向 3 个不同的 JSON 路径，均含具体字段名与问题说明；不是笼统的"格式错误"
- **类型**: 可用性

### AC-014: schema 文档同步
- **前置条件**: 读 `references/case-schema.md`
- **测试步骤**: 核对文档是否描述了 v2 全部新增字段（`open_questions[]` / `cases[].method` / `cases[].status` / `cases[].revision` / `coverage_matrix[]`）及其必填性与向后兼容规则
- **预期结果**: 5 项全部有明确描述，且文档中的示例 JSON 能通过校验器
- **类型**: 功能
