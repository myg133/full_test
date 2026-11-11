# REQ-002.5b 验证报告

- 需求：REQ-002.5b 执行 skill 与证据链（第二轮修复）
- 分支：`feature/REQ-002.5B`｜基线 `881426e`
- 验收：BA 的 `verify-acceptance.sh` → **19 PASS / 0 FAIL**；REQ-002A 回归 → **19 PASS / 0 FAIL**
- 自验：`/tmp/qa-0025b/qa-0025b.mjs` → **27 PASS / 0 FAIL**

## 本轮改了什么

| 任务 | 落点 |
|---|---|
| 1 多步逐步执行、逐步判定 | `scripts/lib/suite-loader.mjs`（`resolveExecutionPlan` / `stepRequest`）、`scripts/lib/assertion.mjs`（`collectAssertions` 移入）、`scripts/lib/verdict.mjs`（`bindAssertions` + 判定顺序）、`executors/http-core.mjs`（`executePlan`）、`executors/{api,mock}.mjs`（改用共享执行器）、`scripts/run-suite.mjs`（逐步证据落盘 + 逐步复现） |
| 2 `cycle-state.mjs --run` | `test-case-design/scripts/cycle-state.mjs`（`set-stage --run` → `stages.<stage>.runs[]`，幂等）、`test-case-design/scripts/lib/state-machine.mjs`（`runs` 类型检查）、`test-case-design/references/{project-layout,state-machine}.md`、`skills/test-execute/scripts/lib/cycle.mjs` |
| 3 REQ-002B 放开 mock 驱动 | `test-case-design/scripts/verify-layout.mjs`（`executor` 枚举 +`mock`、环境 `driver` 字段与枚举、schema 容忍 `driver`）、`test-case-design/references/project-layout.md`（§3.1 schema 模板 / §3.2 字段表 / §3.3 枚举） |
| 4 README 补 `test-execute` | `README.md`（"包含的 Skill"表 + 首期能力域） |
| 5 文档与裁决对齐 | `skills/test-execute/SKILL.md`、`references/executor-spec.md`（§2.1 多步语义、接口 `steps[]`、D19 限制）、`references/evidence-chain.md`（多步证据目录）、`executors/index.json`（`multi_step` 可配置项）、`examples/offline/**` |

## 关键验证结果

| 项 | 结果 |
|---|---|
| 多步：首步成立、次步不成立 | `failed`，证据 2 份（`step-1-response.json` / `step-2-response.json`） |
| 多步：两步都成立 | `passed`，证据 2 份 |
| 断言所在 step 不可执行 | `blocked`（`assertion_without_response`），不是 passed |
| 轮次集成 | `stages.execute.runs[]` 含 run_id；重复 run_id 幂等（两项不重复） |
| 契约放开 | `executor=mock`、环境 `driver=mock`、`stages.execute.runs[]` 判合法；非法取值仍被拦 |
| 完整性自检 | 改执行器一个字节 → exit 1；改回 → exit 0（清单已随源码重新生成） |
| 打包 | `npm pack --dry-run` 含 test-execute 全部文件 |

## 本轮修掉的实现缺陷

1. **多步只跑第一步**（P0）：断言被拿第一个响应当判据 → 首步成立次步不成立会报 passed。
   现在逐步执行、断言绑定到所在 step 的响应。
2. **执行错误被"无响应"掩盖**：凭证缺失时错误类型被报成 `assertion_without_response`。
   现在判定顺序为「执行错误 → 计划层不可绑定 → 运行时无响应 → 逐条判定」。
3. **轮次追溯无处安放**：run_id 塞在 `artifacts` 里不可查 → 改为 `stages.execute.runs[]`（经 `cycle-state.mjs --run`）。

## 已知限制与待上游处理

1. **规则 4 与规则 5 的重叠处**（需求 D12/D13 的措辞冲突）：用例只解析出**一次**请求时，
   所有断言都针对这同一次响应（规则 4）；此时若某条断言所在 step 不可执行，
   实现按规则 4 判（拿这唯一响应去判，通常 `failed` 而非 `blocked`）。
   多请求时规则 5 生效（`blocked`）。实现选择已在 `executor-spec.md` §2.1 写明。
2. **`ui` / `load` / `security` 三个执行器未实现**（属后续 REQ；注册表已用 `not_implemented` 声明）。
3. **`verify-integrity.mjs --update` 是维护者路径**，不是定制路径（已在 SKILL.md 与 executor-spec §8 警示）。
4. **复现命令不含鉴权头，只含环境变量名**（需求 D19 的已知限制）：带鉴权的用例不能照抄命令跑通。
