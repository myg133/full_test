# REQ-002.5b 追溯性矩阵

- 需求：REQ-002.5b（执行 skill 与证据链）｜第三轮：载体冲突判 blocked（D20）+ 复现信息如实（D21）+ 绑定规则写进契约（D22）
- 分支：`feature/REQ-002.5B`
- 验收脚本（BA 的资产）：`BA/demands/REQ-002-suite-foundation/REQ-002.5b-test-execute/verify-acceptance.sh` → **21 PASS / 0 FAIL**
- REQ-002A 回归：`BA/demands/REQ-002-suite-foundation/REQ-002A-schema-v2/verify-regression-002a.sh` → **19 PASS / 0 FAIL**
- 自验脚本（自用，不进仓库）：`/tmp/qa-0025b/qa-0025b.mjs` → **28 PASS / 0 FAIL**；`/tmp/qa-0025b/qa-round3.mjs`（本轮行为探针）→ **8 PASS / 0 FAIL**

> 编号说明：`AC-0xx` 是 BA 验收脚本的编号；`AC-Qxx` 是我自加的检查项（避免与 BA 编号撞号）。

| AC | 交付位置 | 自验方式 | 结论 |
|---|---|---|---|
| AC-001 skill 目录结构完整 | `skills/test-execute/{SKILL.md,scripts,references,executors/index.json}` | 目录与 frontmatter 检查 | PASS |
| AC-002 注册表声明可配置项与边界 | `executors/index.json`（`configurable[]`（含 `multi_step`）/ `not_supported[]`） | 注册表检查 | PASS |
| AC-003 执行器不可被 agent 修改 | `SKILL.md` 硬约束第 1 条（「agent 不得修改执行器实现」） | 文案可辨识性检查 | PASS |
| AC-004 断言完全可配置 | `scripts/lib/verdict.mjs`、`executors/*.mjs`（无期望值字面量） | 源码扫描 + 改断言行为验证 | PASS |
| AC-004b 断言对象形态可校验可判定 | `test-case-design/scripts/validate-cases.mjs`、`scripts/lib/assertion.mjs` | 校验 + 执行 | PASS |
| AC-004c 不可判定判 blocked | `verdict.mjs`（`BLOCK_TYPES.NO_ASSERTION`） | 执行 + 理由检查 | PASS |
| AC-004d 非法断言对象被拦 | `validate-cases.mjs`（`validateAssertionObject`） | 四例逐个校验 | PASS |
| AC-004e 旧用例集行为不变 | 同上（放宽分支只对对象生效） | 与放宽前脚本对拍 | PASS |
| AC-005 判定口径由外壳统一 | `scripts/lib/verdict.mjs` 唯一模块 | 源码扫描 | PASS |
| AC-006 凭证缺失判 blocked | `suite-loader.mjs`（`resolveCredentials`）+ `verdict.mjs`（错误优先于"无响应"） | 执行验证 | PASS |
| AC-007 产物无凭证明文 | `scripts/lib/redaction.mjs`（凭证字面量通道） | 全产物扫描 | PASS |
| AC-008 证据链结构完整 | `run-suite.mjs`（meta/results 产出） | 字段清单检查 | PASS |
| AC-009 指纹与防篡改 | `lib/fingerprint.mjs`、`verify-evidence.mjs` | 篡改 + 删除 | PASS |
| AC-010 清单指纹发现 results.json 被改 | `lib/fingerprint.mjs`（`resultsFingerprint`） | 改 status | PASS |
| AC-011 计数不可造假 | `verify-evidence.mjs` §5 | 改 cases_total | PASS |
| AC-012 轮次状态经脚本写 | `lib/cycle.mjs`（调 `cycle-state.mjs --run`）、`test-case-design/scripts/cycle-state.mjs` | `stages.execute.runs[]` 含 run_id + 执行器无 cycle.json 路径 | PASS |
| AC-013 脱敏在写入前 + 留痕 | `lib/redaction.mjs`、`run-suite.mjs`（先脱敏再落盘） | 证据内容 + meta.redaction | PASS |
| AC-014 离线可跑 | `executors/mock.mjs`（内置 `node:http` 桩服务） | 执行 → verify-evidence 全 exit 0 | PASS |
| AC-015 零依赖 + 可移植 | 全部脚本仅用 `node:` 内置模块 | `package.json` + 源码扫描 | PASS |
| AC-016 完整性自检 | `verify-integrity.mjs` + `executors/manifest.json` | 改一个字节 | PASS |
| AC-017 `--json` 与退出码语义 | `lib/cli.mjs` + 各脚本 | 三种情形 | PASS |
| AC-018 失败用例有复现信息 | `executors/http-core.mjs`（`executePlan` 的 reproduction） | 失败用例检查 | PASS |
| **AC-019 多步逐步判定** | `lib/suite-loader.mjs`（`resolveExecutionPlan`）、`lib/verdict.mjs`（`bindAssertions`）、`executors/http-core.mjs`（`executePlan`） | 两步用例首步成立次步不成立 → failed，证据 2 份（`step-1-` / `step-2-`） | PASS |
| **AC-020 多步全通过** | 同上 | 两步都成立 → passed，证据 2 份 | PASS |
| **AC-021 载体冲突判 blocked** | `lib/suite-loader.mjs`（`resolveExecutionPlan` 的 conflict 判定）、`lib/verdict.mjs`（`BLOCK_TYPES.CONFLICTING_REQUEST_CARRIER`）、`scripts/run-suite.mjs`（冲突时不发请求） | 用例级载体 `GET /ok` + step `GET /notfound` → blocked（非 passed），证据 0 份 | PASS |
| **AC-022 复现信息如实** | `scripts/run-suite.mjs`（按执行器回报的步骤推导 `reproduction.steps`）、`executors/http-core.mjs`（`describeRequest` 兜底） | 用例级载体 + 同端点 step → 非 blocked，证据份数 == `reproduction.steps` 长度 | PASS |
| AC-Q01（自加）断言所在 step 不可执行 | `verdict.mjs`（`BLOCK_TYPES.ASSERTION_WITHOUT_RESPONSE`） | 三步用例（第三步无请求载体）→ blocked，非 passed | PASS |
| AC-Q02（自加）REQ-002B 放开 mock | `test-case-design/scripts/verify-layout.mjs`（枚举 + `driver`）、`references/project-layout.md` | `executor=mock` + 环境 `driver` + `runs[]` 判合法；非法值仍被拦 | PASS |
| AC-Q03（自加）`set-stage --run` 幂等 | `test-case-design/scripts/cycle-state.mjs` | 重复 run_id → `runs[]` 两项不重复 | PASS |
| AC-Q04（自加）复现步骤与证据条数一致 | `scripts/run-suite.mjs`（`executedActions` 推导） | 多请求用例：证据 2 份 == 复现步骤 2 步；凭证缺失时回退到声明的步骤 | PASS |
| AC-Q05（自加）绑定规则的两条既有行为未被破坏 | `lib/verdict.mjs`（`bindAssertions`） | 单请求 + 叙述性 step → passed；多请求 + 叙述性 step → blocked | PASS |
