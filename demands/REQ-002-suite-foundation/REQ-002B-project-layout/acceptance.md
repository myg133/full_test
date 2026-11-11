# 验收标准：REQ-002B 项目目录契约与校验

> 每条 AC 必须可机械验证。测试项目放 `/tmp/qa-002b/` 下构造，不污染真实仓库。

### AC-001: 合法项目通过校验
- **前置条件**: 在 `/tmp/qa-002b/proj/` 构造符合契约的完整项目（`test-assets/` 全目录 + `environments/` + `suites/` + `cycles/` + `.gitignore` 含 `.test-artifacts/`）
- **测试步骤**: `node skills/test-case-design/scripts/verify-layout.mjs /tmp/qa-002b/proj`
- **预期结果**: 退出码 0，输出全部 `[OK]`，无 `[FAIL]`
- **类型**: 功能

### AC-002: 缺必需目录被拦截
- **前置条件**: 删除 `test-assets/environments/`
- **测试步骤**: 同上
- **预期结果**: 退出码 1，报错指出缺失的目录路径
- **类型**: 功能

### AC-003: 环境配置不符合 schema 被拦截
- **前置条件**: 在合法项目上改 `environments/staging.json`：删掉必填 `base_url`、把 `timeout_ms` 改成字符串、加一个 schema 未定义的顶层字段
- **测试步骤**: 同上
- **预期结果**: 退出码 1，三类错误分别报出
- **类型**: 功能

### AC-004: 明文凭证被拦截
- **前置条件**: 在 `environments/staging.json` 的 `credentials` 下加 `"password": "hunter2"`（明文）；另一例把 `username_env` 的值改成含空格与特殊字符的字符串
- **测试步骤**: 同上
- **预期结果**: 两次均退出码 1，分别报出「明文凭证」与「非法环境变量名」
- **类型**: 安全

### AC-005: suite.json 字段与枚举校验
- **前置条件**: 在合法项目上把某个 `suite.json` 的 `scope` 改成 `perf`（非法）、删掉 `executor`、`cases_file` 指向不存在的文件
- **测试步骤**: 同上
- **预期结果**: 退出码 1，三类错误分别报出（含文件路径 + 字段名）
- **类型**: 功能

### AC-006: suite 目录名一致性
- **前置条件**: 把 `suites/REQ-001-coupon/suite.json` 的 `suite` 改成 `REQ-002-other`
- **测试步骤**: 同上
- **预期结果**: 退出码 1，报错指出 `suite` 与目录名不一致
- **类型**: 功能

### AC-007: cycle.json 枚举与跳过理由
- **前置条件**: 把 `cycle.json` 的 `status` 改成 `finished`（非法）、把 `scopes_skipped[].reason` 清空
- **测试步骤**: 同上
- **预期结果**: 退出码 1，两类错误分别报出
- **类型**: 功能

### AC-008: cycle 状态与 history 一致性
- **前置条件**: 把 `cycle.json` 的 `status` 改成 `completed`，但 `history` 最后一条的 `to` 仍是 `in_progress`
- **测试步骤**: 同上
- **预期结果**: 退出码 1，报错指出状态与 history 不一致
- **类型**: 功能

### AC-009: cycles/index.json 悬空引用
- **前置条件**: 在 `cycles/index.json` 里加一个 `id: "R9-NOPE"`，但 `cycles/` 下无对应目录
- **测试步骤**: 同上
- **预期结果**: 退出码 1，报错指出悬空的 cycle id
- **类型**: 功能

### AC-010: .test-artifacts 必须被 gitignore
- **前置条件**: 从项目 `.gitignore` 移除 `.test-artifacts/` 行
- **测试步骤**: 同上
- **预期结果**: 退出码 1，报错指出 `.test-artifacts/` 未被忽略
- **类型**: 功能

### AC-011: report.output_dir 必须在 .test-artifacts 下
- **前置条件**: 把某 `suite.json` 的 `report.output_dir` 改成 `./reports/xxx`（不在 `.test-artifacts/` 下）
- **测试步骤**: 同上
- **预期结果**: 退出码 1，报错指出产物目录位置违规
- **类型**: 功能

### AC-012: 性能、零依赖、可移植、幂等
- **前置条件**: 构造含 100 个 suite 的项目
- **测试步骤**:
  1. 计时执行校验
  2. `grep -nE "python3|bash |/tmp/|grep |sed "` 扫脚本
  3. 检查 import
  4. 记录校验前后项目目录的文件 mtime 与内容哈希，重复执行两次后比对
- **预期结果**:
  - 校验 < 3 秒
  - grep 无命中
  - import 仅 `node:` 内置模块
  - 两次执行结果一致，且**项目文件未被脚本修改**（幂等）
- **类型**: 性能

### AC-012b: 产物可被分发（关键回归）
- **前置条件**: 仓库处于 `feature/REQ-002B` 分支
- **测试步骤**:
  1. `npm pack --dry-run` 查看 tarball 包含清单
  2. 确认 `package/skills/test-case-design/scripts/verify-layout.mjs` 与 `package/skills/test-case-design/references/project-layout.md` **都在清单中**
  3. 确认清单中**没有**包根的 `scripts/`、`references/` 目录（原设计的错误位置）
- **预期结果**: 两个新文件都出现在 tarball 清单里；包根不再有游离的 `scripts/` `references/` 目录
- **类型**: 功能

### AC-013: 契约文档完整
- **前置条件**: 读 `skills/test-case-design/references/project-layout.md`
- **测试步骤**: 核对文档是否覆盖 6 项
- **预期结果**: 6 项全部有明确说明——目录结构与职责 / 三种 scope 的异同 / 环境与执行配置字段语义 / 轮次状态机与阶段 / 哪些进 Git 哪些不进 / 常见错误与修法
- **类型**: 功能
