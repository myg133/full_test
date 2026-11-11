# REQ-002.5b 验证报告

- 需求：REQ-002.5b 执行 skill 与证据链
- 分支：`feature/REQ-002.5B`
- 自验脚本：`/tmp/qa-0025b/qa-0025b.mjs`（22 项检查，全部 PASS）

## 交付内容

| 路径 | 职责 |
|---|---|
| `skills/test-execute/SKILL.md` | skill 规约：硬约束、可配置项、判定口径、产物契约、退出码 |
| `skills/test-execute/references/evidence-chain.md` | 证据链契约：目录结构、字段表、指纹算法、脱敏留痕、轮次集成 |
| `skills/test-execute/references/executor-spec.md` | 执行器接口契约：observed/evidence/reproduction、断言操作、鉴权、mock 端点集、扩展姿势 |
| `skills/test-execute/scripts/run-suite.mjs` | 执行外壳：调度驱动、统一判定、脱敏落盘、算指纹、写产物、推进轮次 |
| `skills/test-execute/scripts/verify-evidence.mjs` | 证据链校验：指纹、证据存在性、计数一致性 |
| `skills/test-execute/scripts/redact.mjs` | 脱敏（独立使用时的检查/补做入口） |
| `skills/test-execute/scripts/verify-integrity.mjs` | 执行器实现完整性自检（对 `executors/manifest.json`） |
| `skills/test-execute/scripts/lib/verdict.mjs` | **status 判定的唯一模块** |
| `skills/test-execute/scripts/lib/assertion.mjs` | 断言对象解析与求值（不含判定） |
| `skills/test-execute/scripts/lib/redaction.mjs` | 脱敏规则与实现 |
| `skills/test-execute/scripts/lib/fingerprint.mjs` | 指纹算法的单一来源 |
| `skills/test-execute/scripts/lib/suite-loader.mjs` | 配置 / 环境 / 用例集加载、凭证解析、用例筛选 |
| `skills/test-execute/scripts/lib/cycle.mjs` | 调用 REQ-002.5a 的 `cycle-state.mjs`（不直接写 `cycle.json`） |
| `skills/test-execute/scripts/lib/cli.mjs` | 退出码与 `--json` 输出的共用骨架 |
| `skills/test-execute/executors/index.json` | 执行器注册表：可配置项与不支持项的边界声明 |
| `skills/test-execute/executors/api.mjs` | 真实 HTTP 驱动（`node` 内置 fetch） |
| `skills/test-execute/executors/mock.mjs` | 离线 mock 驱动（`node:http` 内置桩服务，端点集固定） |
| `skills/test-execute/executors/http-core.mjs` | 两个驱动共用的请求构造与发送 |
| `skills/test-execute/executors/mock-endpoints.json` | mock 端点集（数据） |
| `skills/test-execute/executors/manifest.json` | 执行器实现完整性清单 |
| `skills/test-execute/examples/offline/**` | 零配置离线示例项目 |
| `skills/test-case-design/scripts/validate-cases.mjs` | 向后兼容扩展：`steps[].expected` 支持断言对象 |
| `skills/test-case-design/references/case-schema.md` | 补 `expected` 的两种形态与判定规则 |

## 关键验证结果

| 项 | 结果 |
|---|---|
| 验收脚本 22 项 | 全部 PASS |
| mock 离线链路 | init → 执行 → verify-evidence 全 exit 0，不依赖外部服务 |
| 判定随断言变化 | 同一端点，断言 404 → passed、改 200 → failed（执行器源码零改动） |
| 证据防篡改 | 改证据字节 / 删证据 / 改 results.json / 改 meta 计数 → verify-evidence 逐一 exit 1 并点名 |
| 凭证边界 | 环境变量缺失 → blocked；产物全量扫描凭证明文零出现 |
| 完整性自检 | 改执行器一个字节 → exit 1；改回 → exit 0 |
| 打包 | `npm pack --dry-run` 含 test-execute 全部文件 |

## 已知遗留 / 待上游处理

1. **`stages.execute.runs[]`**：需求 F7 要求把 `run_id` 记进 `cycle.json` 的 `stages.execute.runs[]`，
   但 REQ-002.5a 的 `cycle-state.mjs` 的 `set-stage` 只支持 `--status` 与 `--artifacts`，
   且该字段不在 REQ-002B 的 `cycle.json` 字段表内。本 REQ 无权改 REQ-002.5a 的已验收交付，
   因此运行标识落在契约支持的 `stages.execute.artifacts`（元素含 `run_id`）。
   建议后续 REQ 给 `set-stage` 加 `--run <run_id>` 参数。
2. **`mock` 与 `driver` 的目录契约**：见 `references/executor-spec.md` §7 —— `suite.json.executor = "mock"`
   与环境配置的 `driver` 字段都超出 REQ-002B 现行契约，`verify-layout.mjs` 会判违规；
   契约侧的放开需由 REQ-002B 维护方处理（`suite.json` 的 `executor` 枚举 + 环境配置字段基线两处）。
3. **退出码口径**：`run-suite.mjs` 的退出码反映**执行流程**成败，不反映用例的通过/失败
   （用例结果看 `results.json` / `meta.json`）。需要"有失败用例就红"的场景用 `--strict`。
4. **`verify-integrity.mjs --update`** 是维护者路径（重新生成清单），不是定制路径；
   agent 改完执行器顺手 `--update` 等于把污染洗成正常，故在 SKILL.md 与引用文档里都写明了这一点。
