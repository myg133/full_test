# REQ-002.5b 验证报告

- 需求：REQ-002.5b 执行 skill 与证据链（第五轮修复：缺 path 规则对两类载体一视同仁 + 多问题并存时消息都点出）
- 分支：`feature/REQ-002.5B`｜基线 `ba07dc2`
- 验收：BA 的 `verify-acceptance.sh` → **23 PASS / 0 FAIL**；REQ-002A 回归 → **19 PASS / 0 FAIL**
- BA 的 13 场景探针（改动前后逐行对比）→ **S1~S13 行为完全一致**（status / error.type / 证据份数 / 复现步骤数）
- 自验：`qa-0025b.mjs` → **28 PASS**；`qa-round3.mjs` → **8 PASS**；`qa-round4.mjs` → **6 PASS**；`qa-round5.mjs`（本轮）→ **9 PASS / 0 FAIL**

## 第五轮改了什么（D25 / D26）

| 任务 | 落点 |
|---|---|
| D25 缺 path 规则对两类载体一视同仁 | `scripts/lib/suite-loader.mjs`（`resolveExecutionPlan()` 里对 `stepRequests` 也做 `hasRequestPath()` 检查；`incomplete` 结构改为 `carriers[]`，可同时列出多个缺 path 的载体；缺 path 的载体不参与冲突比对，也不被静默执行）、`scripts/lib/verdict.mjs`（新增 `incompleteCarriersText()`，消息点名是"用例级载体"还是"steps[i] 的请求载体"）、`scripts/run-suite.mjs`（沿用 `plan.incomplete` 分支：一个请求都不发） |
| D26 多问题并存时消息都点出 | `scripts/lib/verdict.mjs`（`no_mechanical_assertion` 分支在 message 后补"另外：…缺 path，也需要一并补上"；`incomplete` 分支在有并存冲突时补一句；判定顺序未改） |
| 文档同步 | `references/executor-spec.md`（§2.3 完整性检查改为两类载体都适用 + 一视同仁的说明、§6 补"多个问题并存时 type 取更根本的那个，message 会把其它问题一并点出"）、`SKILL.md`（硬约束第 5 条、可配置项段落、Failure handling 均补 step 级载体同样适用）、`executors/index.json`（`request_carrier` 同步） |

**与第四轮的关系**：第四轮 D23 只把"缺 path"这条规则落在**用例级载体**上，step 级载体缺 path 时
仍会带着默认的 `GET /` 参与冲突比对 —— 报出"steps[0]（GET /）与 GET /ok 冲突"，
而它根本没有冲突，是它自己没写全。按 D25，这条规则对两类载体一视同仁。

## 第四轮改了什么（D23）

| 任务 | 落点 |
|---|---|
| 载体缺 path 判 `incomplete_request_carrier` | `scripts/lib/suite-loader.mjs`（`hasRequestPath()`；`resolveExecutionPlan()` 里用例级载体缺 path 时**不参与冲突比对**，改为产出 `incomplete` 结构）、`scripts/lib/verdict.mjs`（`BLOCK_TYPES.INCOMPLETE_REQUEST_CARRIER` + 判定分支，消息指向"补 path"而非"冲突"）、`scripts/run-suite.mjs`（载体不完整时**一个请求都不发**，与冲突分支一致） |
| 文档同步 | `references/executor-spec.md`（§2.2 绑定表补一行、§2.3 拆成"先看载体写全了没 / 再比两边"两张表 + 两种修法对照表、§6 `error.type` 表补 `incomplete_request_carrier`）、`SKILL.md`（硬约束第 5 条、可配置项段落、Failure handling）、`executors/index.json`（`request_carrier` 补缺 path 的处置） |

**与第三轮的关系**：第三轮我把"缺 path 的载体"当成 `GET /` 参与冲突比对，于是报出
"用例级载体指向 GET /，steps[0]（GET /ok）指向不同的端点" —— 这是**误诊**：
调用方会去找一个根本不存在的冲突，而真正的问题是"载体没写路径"。
D23 把两者拆开：缺 path = **补齐**（`incomplete_request_carrier`），冲突 = **二选一**（`conflicting_request_carrier`）。

## 第三轮改了什么（D20 / D21 / D22）

| 任务 | 落点 |
|---|---|
| D20 载体冲突判 blocked | `scripts/lib/suite-loader.mjs`（`requestSignature` / `describeRequest`；`resolveExecutionPlan` 检测用例级载体与 step 级请求的 method+path 是否一致，不一致即产出 `conflict`）、`scripts/lib/verdict.mjs`（`BLOCK_TYPES.CONFLICTING_REQUEST_CARRIER` + 冲突分支，判 blocked 不判 passed）、`scripts/run-suite.mjs`（冲突时**一个请求都不发**） |
| D21 复现信息只记实际执行过的步骤 | `scripts/run-suite.mjs`（按执行器回报的 `steps[]` 反查计划里的动作，取代"回退到用例声明"的旧兜底）、`executors/http-core.mjs`（`describeRequest` 兜底：用例级载体那一次请求也要记进复现步骤） |
| D22 绑定规则写进契约（只改文档） | `references/executor-spec.md`（新增 §2.2 断言与响应的绑定规则、§2.3 载体优先级与冲突判定、§2.4 复现信息；§2.1 表格补冲突行；§3 / §6 交叉引用；修正已过期的 mock 契约说明）、`SKILL.md`（硬约束第 5、6 条 + 可配置项里的绑定规则表与书写约定）、`executors/index.json`（`request_carrier` / `assertion_binding` 两个可配置项） |

## 第二轮改了什么

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
| **用例级载体 + 不同端点的 step** | `blocked`（`conflicting_request_carrier`），证据 0 份 —— 不判 passed，不静默丢请求 |
| **用例级载体 + 同端点的 step** | 视为同一次请求 → `passed`，证据 1 份 == 复现步骤 1 步 |
| **用例级载体缺 path**（只有 query） | `blocked`（`incomplete_request_carrier`），证据 0 份 —— 消息指向"补 path"，不说成冲突 |
| **step 级载体缺 path**（`request:{method:GET}`） | `blocked`（`incomplete_request_carrier`），证据 0 份 —— 消息点名 `steps[0] 的请求载体` |
| **两类载体都缺 path** | `blocked`（`incomplete_request_carrier`），消息把两处都点出 |
| **无断言 + 载体缺 path** | `blocked`，type 仍 `no_mechanical_assertion`，message 补"另外：…缺 path，也需要一并补上" |
| **用例级载体缺 method**（有 path） | 合法（默认 GET）→ `passed`，不因此拒 |
| **复现信息与证据条数一致** | 多请求用例：证据 2 份 == 复现步骤 2 步；凭证缺失时回退到用例声明的步骤 |
| 单请求 + 叙述性 step 带断言 | `passed`（规则 4 保留：叙述性 step 的断言绑到那一次响应） |
| 多请求 + 叙述性 step 带断言 | `blocked`（`assertion_without_response`） |
| 轮次集成 | `stages.execute.runs[]` 含 run_id；重复 run_id 幂等（两项不重复） |
| 契约放开 | `executor=mock`、环境 `driver=mock`、`stages.execute.runs[]` 判合法；非法取值仍被拦 |
| 完整性自检 | 改执行器一个字节 → exit 1；改回 → exit 0（清单已随源码重新生成） |
| 打包 | `npm pack --dry-run` 含 test-execute 全部文件 |

## 累计修掉的实现缺陷

1. **载体冲突静默丢 step 级请求**（P0，D20）：用例级载体存在时，step 级请求被整体忽略，
   后一条断言被拿去判前一次响应 → 半个用例报 passed。现在判 `blocked`（`conflicting_request_carrier`），一个请求都不发。
2. **`reproduction.steps` 谎称执行过没跑的步骤**（P0，D21）：执行器没给复现步骤时回退到用例声明的步骤，
   而"用例想跑什么"不等于"实际跑了什么"。现在按执行器回报的步骤推导；一个请求都没执行时才回退到声明。
3. **用例级载体那一次请求在复现信息里丢失**（D21）：`action` 为空被过滤掉。现在用 `METHOD /path` 兜底描述。
4. **缺 path 的载体被误诊为"载体冲突"**（D23/D25）：把缺 path 的载体当成 `GET /` 去比对，
   报出"指向 GET / 与 GET /ok 冲突" —— 调用方会去找一个不存在的冲突。现在单独判
   `blocked`（`incomplete_request_carrier`），消息指向"补 path"；**用例级与 step 级载体一视同仁**（D25）。

## 已知限制与待上游处理

1. **载体冲突的裁定权在需求方**（D20）：冲突时实现只判 `blocked` 并说清两边指向哪里，
   不替需求方选"一次调用"还是"多次调用"—— 这是刻意的：猜错会让报告与用例意图不符。
2. **`ui` / `load` / `security` 三个执行器未实现**（属后续 REQ；注册表已用 `not_implemented` 声明）。
3. **`verify-integrity.mjs --update` 是维护者路径**，不是定制路径（已在 SKILL.md 与 executor-spec §8 警示）。
4. **复现命令不含鉴权头，只含环境变量名**（需求 D19 的已知限制）：带鉴权的用例不能照抄命令跑通。
5. **"证据份数 == 复现步骤数"不是全局恒等式**（需求 D24 的裁决）：判 blocked 且一个请求都没执行时
   （凭证缺失、载体冲突、载体不完整），`reproduction.steps` **回退到用例声明的步骤**（证据 0 份）。
   这是刻意的 —— 复现一个被阻塞的用例时，调用方恰恰需要知道"该跑哪些步骤"；
   置空会让复现信息变成空壳。该恒等式只在**执行过请求**时成立。实现与 D24 一致，未改动。
