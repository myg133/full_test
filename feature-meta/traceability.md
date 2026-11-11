# REQ-002.5b 追溯性矩阵

- 需求：REQ-002.5b（执行 skill 与证据链）
- 分支：`feature/REQ-002.5B`
- 验收脚本：`/tmp/qa-0025b/qa-0025b.mjs`（自验用，不进仓库）

| AC | 交付位置 | 自验方式 | 结论 |
|---|---|---|---|
| AC-001 skill 目录结构完整 | `skills/test-execute/{SKILL.md,scripts,references,executors/index.json}` | 目录与 frontmatter 检查 | PASS |
| AC-002 注册表声明可配置项与边界 | `skills/test-execute/executors/index.json`（`configurable[]` / `not_supported[]`） | 注册表检查 | PASS |
| AC-003 执行器不可被 agent 修改 | `skills/test-execute/SKILL.md` 硬约束第 1 条 | 文案可辨识性检查 | PASS |
| AC-004 断言完全可配置 | `skills/test-execute/scripts/lib/verdict.mjs`、`executors/*.mjs`（无期望值字面量） | 源码扫描 + 改断言行为验证 | PASS |
| AC-004b 断言对象形态可校验可判定 | `skills/test-case-design/scripts/validate-cases.mjs`、`scripts/lib/assertion.mjs` | 校验 + 执行 | PASS |
| AC-004c 不可判定判 blocked | `scripts/lib/verdict.mjs`（`BLOCK_TYPES.NO_ASSERTION`） | 执行 + 理由检查 | PASS |
| AC-004d 非法断言对象被拦 | `skills/test-case-design/scripts/validate-cases.mjs`（`validateAssertionObject`） | 四例逐个校验 | PASS |
| AC-004e 旧用例集行为不变 | 同上（放宽分支只对对象生效） | 与放宽前脚本对拍 | PASS |
| AC-005 判定口径由外壳统一 | `scripts/lib/verdict.mjs` 唯一模块 | 源码扫描 | PASS |
| AC-006 凭证缺失判 blocked | `scripts/lib/suite-loader.mjs`（`resolveCredentials`）+ `verdict.mjs` | 执行验证 | PASS |
| AC-007 产物无凭证明文 | `scripts/lib/redaction.mjs`（凭证字面量通道） | 全产物扫描 | PASS |
| AC-008 证据链结构完整 | `scripts/run-suite.mjs`（meta/results 产出） | 字段清单检查 | PASS |
| AC-009 指纹与防篡改 | `scripts/lib/fingerprint.mjs`、`scripts/verify-evidence.mjs` | 篡改 + 删除 | PASS |
| AC-010 清单指纹发现 results.json 被改 | `scripts/lib/fingerprint.mjs`（`resultsFingerprint`） | 改 status | PASS |
| AC-011 计数不可造假 | `scripts/verify-evidence.mjs` §5 | 改 cases_total | PASS |
| AC-012 轮次状态经脚本写 | `scripts/lib/cycle.mjs`（调 `cycle-state.mjs`）、`scripts/run-suite.mjs` | 轮次状态检查 + 执行器无 cycle.json 路径 | PASS（`runs[]` 见遗留项） |
| AC-013 脱敏在写入前 + 留痕 | `scripts/lib/redaction.mjs`、`run-suite.mjs`（先脱敏再落盘） | 证据内容 + meta.redaction | PASS |
| AC-014 离线可跑 | `executors/mock.mjs`（内置 `node:http` 桩服务） | init → 执行 → verify-evidence 全 exit 0 | PASS |
| AC-015 零依赖 + 可移植 | 全部脚本仅用 `node:` 内置模块 | `package.json` + 源码扫描 | PASS |
| AC-016 完整性自检 | `scripts/verify-integrity.mjs` + `executors/manifest.json` | 改一个字节 | PASS |
| AC-017 `--json` 与退出码语义 | `scripts/lib/cli.mjs` + 各脚本 | 三种情形 | PASS |
| AC-018 失败用例有复现信息 | `executors/api.mjs` / `executors/mock.mjs`（`reproduction`） | 失败用例检查 | PASS |
