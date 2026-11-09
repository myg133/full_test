# 验收标准：测试用例设计 Skill（首期）+ npm 交付包

> 每条 AC 必须可机械验证。括号内为验证方式。

### AC-001: npm 包可构建与安装
- **前置条件**: 仓库处于 `feature/REQ-001` 分支，npm 可用
- **测试步骤**:
  1. 在包根执行 `npm pack`，产出 `.tgz`
  2. 在隔离目录执行 `INTERNAL_RT_SKILLS_DIR=<tmp> npm install <tgz>`
  3. 执行 `INTERNAL_RT_SKILLS_DIR=<tmp> npx internal-rt-test-agent-skills install`
  4. 执行 `ls <tmp>/skills/`
- **预期结果**:
  - `npm pack` 退出码 0，生成 tarball
  - `install` 退出码 0
  - `<tmp>/skills/` 下出现 `test-case-design/` 目录，含 `SKILL.md`、`references/`、`scripts/`
  - `<tmp>/.skill-lock.json` 新增 `test-case-design` 条目且 `sourceType` 为 `"npm"`
- **类型**: 功能

### AC-002: 幂等安装不破坏既有条目
- **前置条件**: `<tmp>` 已存在 `.skill-lock.json`，含至少一条其他 skill 的既有条目（如 `my-other-skill`）；已安装过一次
- **测试步骤**:
  1. 再次执行 `install`
  2. 执行第二次 `install`
  3. 读取 `<tmp>/.skill-lock.json`
- **预期结果**:
  - 两次 `install` 退出码均为 0，无重复目录、无报错
  - `test-case-design` 条目只有一条
  - `my-other-skill` 条目内容与安装前完全一致（未被覆盖或删除）
- **类型**: 功能

### AC-003: skill 结构合规（lint）
- **前置条件**: skill 目录已生成
- **测试步骤**: `node <skill-creator>/scripts/lint-skill.js skills/test-case-design`
- **预期结果**: 退出码 0，输出 `✓ All checks passed`
- **类型**: 功能

### AC-004: SKILL.md frontmatter 语义合规
- **前置条件**: 读取 `skills/test-case-design/SKILL.md`
- **测试步骤**: 人工 + 脚本检查以下 6 点
- **预期结果**:
  1. `name` 为 `test-case-design`，与目录名一致，kebab-case
  2. `description` 同时包含：能力说明（What）、具体触发短语（When，如 `"写测试用例"`）、明确的不触发场景（Near misses）
  3. 正文包含 `Inputs to collect` / `Procedure` / `Output contract` / `Failure handling` 四个章节
  4. 正文不含 `## When to use` 标题（触发条件只在 frontmatter）
  5. 正文行数 ≤ 500
  6. `references/` 下 3 个文件均存在且被 SKILL.md 正确引用（无断链）
- **类型**: 功能

### AC-005: 校验脚本检出全部六类缺陷
- **前置条件**: 存在 `scripts/validate-cases.mjs`
- **测试步骤**: 准备 6 个反例 JSON 文件并逐一执行 `node scripts/validate-cases.mjs <file>`
  1. 两条用例 `id` 均为 `TC-001`（重复 ID）
  2. 用例缺 `title` 字段
  3. `requirement_refs: ["R-99"]` 但 `requirements` 中无 `R-99`
  4. `dimension: "unknown-dim"`
  5. `steps: []`；另一例 step 缺 `expected`
  6. JSON 语法错误（缺右括号）
- **预期结果**: 6 次执行退出码均为 1，且 stderr/stdout 中能定位到对应缺陷类型（重复 ID / 缺字段 / 悬空引用 / 非法枚举 / 空步骤 / 语法错误）
- **类型**: 功能

### AC-006: 校验脚本对合规用例集退出 0 并输出覆盖统计
- **前置条件**: 准备合规用例集：2 条需求条目（`R-1` 可测试、`R-2` 不可测试）、4 条用例，其中 `R-2` 无用例覆盖
- **测试步骤**: `node scripts/validate-cases.mjs <valid.json>`
- **预期结果**:
  - 退出码 0
  - 输出包含：需求条目总数 2、可测试条目数 1、用例总数 4
  - 输出按维度的用例数分布
  - 输出未覆盖需求条目列表，且列表中包含 `R-2`
- **类型**: 功能

### AC-007: 渲染脚本产出追溯矩阵
- **前置条件**: 同 AC-006 的用例集
- **测试步骤**: `node scripts/render-report.mjs <valid.json>`
- **预期结果**:
  - 退出码 0
  - 输出 Markdown，含 3 个部分：用例总览表、追溯矩阵（需求条目 → 用例 ID 列表）、未覆盖清单
  - 追溯矩阵中 `R-1` 行列出其覆盖用例 ID；`R-2` 行标记为未覆盖
- **类型**: 功能

### AC-008: 脚本零依赖且跨平台
- **前置条件**: 检查两个脚本的源码与依赖声明
- **测试步骤**:
  1. `grep -n "require\|import" scripts/*.mjs` 检查导入
  2. `grep -nE "python3|bash |/tmp/|grep |sed " scripts/*.mjs` 检查平台相关调用
- **预期结果**:
  - 仅导入 `node:` 内置模块，无第三方依赖
  - 无 python3 / bash / `/tmp/` / grep / sed 调用
- **类型**: 可移植性

### AC-009: 安装不产生副作用
- **前置条件**: 记录用户 shell 配置文件与 PATH 的状态
- **测试步骤**: 执行 `install`，然后检查 `~/.bashrc`、`~/.zshrc`、`~/.profile` 的修改时间与内容
- **预期结果**: 三个文件均未被修改；安装过程不新增 PATH 条目；不执行被安装 skill 的任何脚本
- **类型**: 安全

### AC-010: uninstall 只移除本包 skill
- **前置条件**: `<tmp>` 中同时存在 `test-case-design`（本包安装）与 `my-other-skill`（用户自有）
- **测试步骤**: 执行 `uninstall`
- **预期结果**:
  - 退出码 0
  - `test-case-design` 目录被移除
  - `my-other-skill` 目录完好保留
  - `.skill-lock.json` 中 `test-case-design` 条目被移除，`my-other-skill` 条目保留
- **类型**: 功能

### AC-011: eval 对比不劣于 baseline
- **前置条件**: skill 已通过 lint；准备一段真实需求文本作为 eval prompt
- **测试步骤**: 按 skill-creator 流程并行跑两个后台 worker——producer 加载 skill 处理该 prompt，baseline 不加载 skill 处理同一 prompt；对比两份产出
- **预期结果**:
  - with-skill 产出通过 `validate-cases.mjs` 校验（退出码 0）
  - 对比结论：with-skill 明确不劣于 baseline，且在"需求条目覆盖追溯"与"结构化程度"两项上优于 baseline
  - with-skill 的 token 消耗未超过 baseline 的 2 倍
- **类型**: 质量

### AC-012: npm 包不发布到公共 registry
- **前置条件**: 仓库处于本 REQ 的 feature 分支
- **测试步骤**: 检查 `package.json` 与 git 历史，确认无 publish 动作
- **预期结果**: 未执行 `npm publish`；`package.json` 中 `private` 字段为 `true` 或发布流程明确留给用户手动执行
- **类型**: 安全
