# REQ-004（原 REQ-002.5b）独立验收报告：执行 skill 与证据链

> 验收方：独立验收代理（未参与开发）
> 验收对象：`feature/REQ-002.5B` worktree 的 `skills/test-execute/` 及其对 `skills/test-case-design/` 的向后兼容扩展
> 验收日期：2026-11-11
> 验收方式：**自建独立验收工程 + 变异测试**，未把 BA 的 `verify-acceptance.sh` 的结论当作前提

---

## 1. 结论

| 项 | 数值 |
|---|---|
| 我方独立断言总数 | **49** |
| 通过 | **48** |
| **失败** | **1**（`C24`：skipped 用例仍然真实发请求并落证据） |
| 交付物 AC 条目（AC-001 ~ AC-024，含 004b/c/d/e 共 29 条） | 独立判定 **29 PASS / 0 FAIL** |
| 变异测试（13 条） | 我方 harness **13/13 测出差异**；BA 脚本仅 **6/13**，**7 条假 PASS** |
| **是否建议合并** | **有条件合并** —— 见 §6 的 P0/P1 |

**一句话结论**：交付物的**核心机制（判定口径唯一、多步逐步判定、歧义显式拒、证据链指纹与防篡改、凭证边界、脱敏、轮次状态写入权收口）实测成立，29 条 AC 全部独立验过且全部通过；但存在 **1 个 P0（废弃/阻塞用例仍被打到目标系统）+ 1 个 P1（传输层错误时证据与复现信息双双失真）**，且 **BA 的验收脚本有 7 处假 PASS**，其中 AC-013（脱敏）属于**完全空测**——把脱敏整个删掉，脚本依然报 23 PASS / 0 FAIL。

---

## 2. 验收方法与环境

### 2.1 我自建的验收工程（全部在 `/tmp`，不碰仓库）

```
/tmp/req004-verify/
├── proj/                      # 自建项目（mock 驱动，离线可跑）
│   ├── test-assets/environments/{mock,mock-auth,mock-nocred}.json
│   └── suites/{MAIN,AMBIG,CRED,NOCRED}/{suite.json,cases.json}
├── harness/check.mjs          # 49 条独立断言（每个变异体跑同一套）
├── mutate.mjs / muts*.mjs     # 13 条变异
├── baseline.json              # 基线结果
└── final-mutations.json       # 变异结果
```

用例覆盖：一次请求多断言、多步两步都成立、多步首步成立次步不成立、断言绑错 step、
叙述性 step 带断言、全字符串 expected、无可执行 step、空 steps、载体冲突、
用例级载体缺 path、step 级载体缺 path、凭证缺失、凭证存在、`/token` 敏感字段。

### 2.2 关键事实核对（交付分支未被改动）

```
$ cd feature-REQ-002.5B && git status --short     # 空
$ cd feature-REQ-002.5B && git status --ignored --short   # 空
```
所有变异都做在 `/tmp/req004-verify/mut/*/skills/` 的副本上。唯一一次在交付 worktree 内产生的
产物（离线示例的 `.test-artifacts/`）已删除并复核。

---

## 3. 逐条 AC 的独立判定

> 每条写明**我实际做的操作**与**观察到的输出摘要**。

### AC-001 `test-execute` 目录结构完整 —— PASS
- 操作：逐个 `test -e` 检查 `SKILL.md` / `references` / `scripts` / `executors/index.json`；用 node 解析 SKILL.md 的 frontmatter。
- 观察：`SKILL.md` / `scripts` / `references` / `executors/index.json` / `examples/offline` 全部存在；frontmatter 有 `name: test-execute` 与 770 字符的 `description`。

### AC-002 执行器注册表声明可配置项与边界 —— PASS
- 操作：解析 `executors/index.json`，逐个执行器核对 `configurable[]` 是否含 `request/assertions/extract/auth/timeout_ms/retries`，并检查 `not_supported[]`。
- 观察：`mock` 的 configurable = request, assertions, extract, auth, timeout_ms, retries, multi_step, request_carrier, assertion_binding（6 项必需全在），`not_supported` 7 项；`api` 同样 6 项必需全在，`not_supported` 5 项；`not_implemented` = ui/load/security。

### AC-003 执行器实现不可被 agent 修改（硬约束） —— PASS
- 操作：在 SKILL.md 检索禁止性约束。
- 观察：第 19/21/23 行三处明确写有「agent **不得修改执行器实现**（`executors/` 目录下的全部文件…）」「**不得改写、不得编辑、不得改动它们，也不得把它们复制到项目里再改**」「改一个字节会被 `scripts/verify-integrity.mjs` 发现」。约束可辨识、非泛泛而谈。

### AC-004 断言规则完全可配置，判定不写在执行器里 —— PASS
- 操作 (a)：`grep -rn "passed|failed|blocked|skipped"` 扫 `executors/*.mjs`；阅读 `http-core.mjs` / `api.mjs` / `mock.mjs`。
- 操作 (b)：造两条用例，同一个端点 `/notfound`，只改断言里的期望值：`{"path":"$status","op":"equals","expected":404}` 与 `...expected:200}`。
- 观察 (a)：`executors/` 下**零**状态判定字样；执行器只回 `observed`。端点表在 `mock-endpoints.json`（数据文件），且 `mock.mjs:19-21` 明确声明「桩服务的响应**与断言无关**」——不是用例级期望值字面量。
- 观察 (b)：`TC-404 passed err=null` / `TC-200 failed err=assertion_failed`。**判定随断言变化而变化，同一份执行器源码未改一字。**

### AC-004b 断言对象形态可用 —— PASS
- 操作：`validate-cases.mjs` 校验混合用例集（一个断言对象 + 一个普通字符串 expected）；再执行该套件看判定。
- 观察：校验 `exit=0`（仅 1 条 WARN：open_questions 为空）；执行后该用例 `passed`，按断言对象判定。

### AC-004c 不可机械判定 → blocked（不得 passed） —— PASS
- 操作：全部 `steps[].expected` 为普通字符串的用例。
- 观察：`status=blocked`，`error.type=no_mechanical_assertion`，消息「缺少可机械判定的断言…判 blocked（不得判 passed）」，`evidence=0`。

### AC-004d 断言对象字段缺失 / op 非法被拦 —— PASS
- 操作：造 4 个用例集（缺 path / 缺 op / op=`equalsx` / op=`equals` 缺 expected），分别跑 `validate-cases.mjs`。
- 观察：**4 例全部 exit=1**，且逐条点名字段：
  - `cases[0].steps[0].expected: 缺少必填字段 path（被检路径…）`
  - `cases[0].steps[0].expected: 缺少必填字段 op（允许值: equals / not_equals / …）`
  - `cases[0].steps[0].expected: op 取值非法: "equalsx"，允许值: …`
  - `cases[0].steps[0].expected: op "equals" 缺少必填字段 expected（比较值）`

### AC-004e 旧用例集行为不变（向后兼容） —— PASS
- 操作：取 `dc175e4`（本 REQ 之前）的 `validate-cases.mjs` 与新版**对拍**同一批旧格式用例集，比对退出码与完整 stdout。
- 观察：`legacy-v1.json`、`legacy-full-v1.json`、`legacy-emptyexpected.json` 三例 **old_exit == new_exit 且输出逐字相同（SAME）**。
  差异只出现在「expected 是对象」的样本上——那正是本 REQ 的新特性（旧版一律报「缺少必填字段 expected」，新版报更具体的字段错误，仍是 exit=1）。

### AC-005 判定口径由执行外壳统一 —— PASS
- 操作：`grep -rn "passed|failed|blocked|skipped"` 扫 `executors/*.mjs`；检索 `STATUS` 常量定义处。
- 观察：`executors/` 下零命中；`STATUS` / `STATUS_VALUES` 只在 `scripts/lib/verdict.mjs:23,31` 定义。`run-suite.mjs` 只**消费** `verdict.status`，不自行判定。

### AC-006 凭证读不到 → blocked 而非 failed —— PASS
- 操作：环境配置 `credentials.username_env = "QA_MISSING_VAR_XYZ"`，且用例 `auth` 也指向该变量；执行。
- 观察：`status=blocked`，`error.type=credential_missing`，`cases_failed=0`（**不是** failed）。消息「读不到凭证 → 该用例判 blocked，不是 failed」。

### AC-007 产物中不含凭证明文 —— PASS
- 操作：`QA_USER='qa-user-SECRET-8899' QA_PASS='qa-pass-SECRET-7766'` 执行带 basic 鉴权的用例；递归扫产物目录所有文件搜两个明文值。
- 观察：用例 `passed`（凭证**确实被用上了**，见下方）；两个明文值在产物中**零出现**。证据里的 `auth_mode` 是 `basic (env: QA_USER, QA_PASS)`——只含变量名。

### AC-008 证据链结构完整 —— PASS
- 操作：读 `meta.json` / `results.json` 逐字段核对。
- 观察：`meta.json` 含 `run_id/suite/scope/requirement/environment/started_at/finished_at/duration_ms/agent/executor/tool_versions/cases_total/cases_passed/cases_failed/cases_blocked/cases_skipped`（全在）+ `evidence_manifest_sha256/results_sha256/redaction`；`results.json` 每条含 `case_id/status/started_at/finished_at/duration_ms/evidence[]/reproduction/error`。

### AC-009 sha256 指纹与防篡改 —— PASS
- 操作：`verify-evidence.mjs` 跑基线 → 篡改证据文件 1 字节 → 删除证据文件 → 各跑一次。
- 观察：基线 `exit=0`；篡改后 `exit=1`，报「证据文件被改动: evidence/TC-PASS-1/step-1-response.json（记录 b0aeda22b94b…，实际 dcf218e3ed58…）」+「字节数不符」；删除后 `exit=1`，报「证据文件丢失: evidence/TC-MS-PASS/step-2-response.json」。
- 附加自查：用 node `crypto` 独立重算每个证据文件的 sha256，与 `results.json` 记录**逐条一致**。

### AC-010 `results.json` 被改能发现 —— PASS
- 操作：把 `results.json` 里首条的 `status` 从 passed 改成 failed。
- 观察：`exit=1`，报「results.json 与 meta.json 记录的清单指纹不符（results_sha256）：results.json 的判定内容（用例状态/错误/复现信息）被改动过」，同时命中证据清单指纹不符与两条计数造假。

### AC-011 计数不可造假 —— PASS
- 操作：把 `meta.json` 的 `cases_total` 改成 99。
- 观察：`exit=1`，报「meta.json 的 cases_total 与 results.json 的实际条数不符（记录 99，实际 11）：计数造假」。

### AC-012 与轮次状态集成（状态只经 `cycle-state.mjs` 写） —— PASS
- 操作 (a)：`cycle-state.mjs init` 建轮次 → `set-stage --stage execute --status in_progress --artifacts … --run RUN-A` → 重复同 run_id → 换 run_id。
- 操作 (b)：`run-suite.mjs --cycle <轮次目录>` 跑完整执行，再读 `cycle.json`。
- 操作 (c)：`grep -rn "cycle.json"` 扫 `executors/` 与 `scripts/`；去注释后复查。
- 观察 (a)：`stages.execute = {"status":"in_progress","artifacts":["art/1"],"runs":["RUN-A"]}`；重复写同 run_id → `changed:false` 且 `runs` 仍为 `["RUN-A"]`（**幂等**）；换 run_id → `["RUN-A","RUN-B"]`，无重复项。
- 观察 (b)：`stages.execute.runs = ["RUN-A","RUN-B","CYCLE-RUN-1"]`，含本次 `run_id`。
- 观察 (c)：`executors/` 与 `scripts/` 全部文件中，`cycle.json` 字样**只出现在注释里**；去注释后零命中；`executors/` 下无任何写盘调用。
- 关联：**状态写入权收口有行为级护栏** —— 把 `cycle-state.mjs` 移走后再跑 `--cycle`，`cycle.json` **不被任何人写入**（我方 `C25` 断言）。

### AC-013 脱敏在写入前完成，且留痕 —— PASS（交付物侧）
- 操作：打 `/token`（响应体含 `{"token":"secret-value","id":1}`）；先确认「凭证被用上、用例真的发了请求」（证据文件存在、`status=passed`），再看产物内容与 `meta.json`。
- 观察：证据文件内容为 `"token": "[REDACTED:field]"`（**明文在落盘前就被替换**，不是事后清洗）；`meta.redaction = {"rules_applied":["field"],"redacted_fields":1}`；全产物 `grep secret-value` = 0 个文件。

### AC-014 离线可跑（mock 执行器自证） —— PASS
- 操作：跑交付物自带的 `examples/offline`（`init` → 执行 → `verify-evidence` → `verify-integrity`），全程不连外网。
- 观察：`run-suite` exit=0，6 条用例 → 通过 4 / 失败 1（故意）/ 阻塞 1（故意）；`verify-evidence` `ok:true, problems:0`，counts 与 meta 一致；`verify-integrity` `ok:true`。
- 退出码口径（D18）核对：有 failed 用例时 `run-suite` 仍 exit=0；加 `--strict` 后 exit=1（`strict(failed)=1`、`strict(blocked)=1`、非 strict=0）—— 符合「退出码只说流程成败」。

### AC-015 零依赖 + 可移植 —— PASS
- 操作：`node -e` 读 `package.json` 的 `dependencies`；`grep -rn -E 'child_process|python3|/bin/bash'` 与 `grep -rn '/tmp'` 扫 `scripts/`（含 `lib/`）+ `executors/`。
- 观察：`dependencies` 与 `devDependencies` 均为 `{}`；`child_process/python3/bash` **零命中**；硬编码 `/tmp` **零命中**；无 `execSync/spawnSync`（仅 `RegExp.exec`）。轮次推进用 `node:worker_threads` 在同进程内跑 `cycle-state.mjs`（`scripts/lib/cycle.mjs`），不派生外部进程。

### AC-016 执行器完整性自检 —— PASS
- 操作：基线 → 改 `executors/mock.mjs` 一个字节 → 再加一个 `EXTRA.mjs` → 还原。
- 观察：基线 `exit=0`（5 个文件）；改字节后 `exit=1`，报「执行器实现被改动: mock.mjs（清单 887113a13b46…，实际 d841ced59c79…）」；新增文件后 `exit=1`，报「执行器目录出现清单里没有的文件: EXTRA.mjs（可能被手工添加）」；还原后 `exit=0`。

### AC-017 `--json` 输出与退出码语义 —— PASS
- 操作：成功 / 校验失败（suite.json 缺必填字段）/ 用法错误（无参、两个位置参数）三种情形各跑一次带 `--json`。
- 观察：成功 `exit=0`、校验失败 `exit=1`、用法错误 `exit=2`；**四种情形的 stdout 全部可 `JSON.parse`**。`verify-evidence.mjs` / `verify-integrity.mjs` 同样遵守 0/1/2 且 `--json` 恒为合法 JSON。

### AC-018 失败用例必须有复现信息 —— PASS
- 操作：检查失败用例的 `reproduction`。
- 观察：`TC-FAIL-1` 的 `reproduction.steps=["GET /notfound"]` 非空，`reproduction.command` 非空（curl 形式，凭证以 `${ENV}` 出现）。

### AC-019 多步用例逐步执行、逐步判定 —— PASS
- 操作：一条用例两个可执行 step（`GET /ok` 断言成立 + `GET /notfound` 断言不成立）。
- 观察：`status=failed`（**不是 passed**）；证据 **2 份**（`step-1-response.json` / `step-2-response.json`）；错误消息定位到 `steps[1]`。

### AC-020 多步用例各步断言都成立 → passed —— PASS
- 操作：两条 step（`GET /ok` 断言 `ok` + `GET /created` 断言 `created`）。
- 观察：`status=passed`，证据 2 份。
- 与 AC-019 配对才能证明判定**落在正确的步骤上**：另加一条反向用例（首步断言写成 `created`），结果为 `failed`——说明**没有**拿某一个响应去判所有断言。

### AC-021 载体冲突判 blocked —— PASS
- 操作：用例级载体 `request={method:GET,path:/ok}` + 两条不同端点的 step（`GET /ok` / `GET /notfound`）。
- 观察：`status=blocked`，`error.type=conflicting_request_carrier`，消息点名「用例级请求载体指向 GET /ok，steps[1]（GET /notfound）指向不同的端点…判 blocked（不得判 passed），也不会静默丢掉其中一边的请求」；`evidence=0`（一个请求都没发）。

### AC-022 `reproduction.steps` 如实 —— PASS
- 操作：用例级载体 `GET /ok` + `steps[]` 两条同端点步骤；比对「证据文件数」与「`reproduction.steps` 长度」。
- 观察：`evidence=1`、`reproduction.steps=["GET /ok"]`，**1 == 1**。
- 交叉验证（我方 `C19`）：对**所有**执行过请求的用例逐条比对，步骤数与证据份数**全部相等**；且「声明了但没跑的 step」（叙述性 step）不出现在 `reproduction.steps` 里。

### AC-023 用例级载体缺 path → `incomplete_request_carrier` —— PASS
- 操作：`request={"query":{"a":"1"}}`（无 path）+ `steps:[{action:"GET /ok"}]`。
- 观察：`status=blocked`，`error.type=incomplete_request_carrier`（**不是** `conflicting_request_carrier`），消息「用例级请求载体没有写明 path（method 可省略，默认 GET；当前读到 method=GET）—— 请补上 path…判 blocked」。

### AC-024 step 级载体缺 path → `incomplete_request_carrier` —— PASS
- 操作：用例级载体 `GET /ok` + `steps[1].request={"method":"GET"}`（无 path）。
- 观察：`status=blocked`，`error.type=incomplete_request_carrier`，消息点名「**steps[1] 的请求载体**没有写明 path…请补上 path」。规则对两类载体一视同仁 ✓。

### AC-004c 附带核对（多问题并存，D26/D27）
- 观察：载体缺 path **且**无可机械断言的用例 → `error.type=no_mechanical_assertion`（更根本），消息里额外补一句「另外：…载体没有写明 path，也需要一并补上」；载体缺 path **且**冲突并存 → type 取 `incomplete_request_carrier`，消息里附上冲突说明。

---

## 4. 变异测试结果表

**方法**：先确认基线能拦住，再把契约里的「必须」逐条破坏，确认**能测出差异**。
**测不出差异 = 假护栏 = 必须报出来的缺陷。**
变异只在 `/tmp/req004-verify/mut/*/skills/` 的副本上做，交付分支零改动。

| # | 变异内容 | 注入位置 | 我方 harness 是否测出差异 | 测出的断言（摘要） | BA 脚本是否测出差异 |
|---|---|---|---|---|---|
| M1 | 执行器只执行第一个 step | `executors/http-core.mjs` | ✅ 是 | `TC-MS-PASS`→failed、证据 1 份（期望 2）、`TC-MS-FAIL`→blocked（期望 failed） | ✅ 是（AC-019/020 FAIL） |
| M2 | `bindAssertions` 把所有断言绑到**第一个**响应 | `scripts/lib/verdict.mjs` | ✅ 是 | `TC-MS-PASS`→failed、`TC-MS-FAIL`→passed（期望 failed）、失败位置不再指向 steps[1] | ✅ 是（AC-019/020 FAIL） |
| M3 | 载体冲突**静默忽略 step** | `scripts/lib/suite-loader.mjs` | ✅ 是 | `TC-CONFLICT`→**passed**、歧义套件里出现 passed | ✅ 是（AC-021 FAIL） |
| M4 | `reproduction.steps` 回退到「用例声明的 steps」 | `scripts/run-suite.mjs` | ✅ 是 | `TC-NARR-1` 步骤数 2 / 证据 1 → 不再一一对应 | ✅ 是（AC-022 FAIL） |
| M5 | `blocked` 降级成 `passed` | `scripts/lib/verdict.mjs` | ✅ 是 | 6 条断言翻转（conflict/incomplete/allstring 全变 passed） | ✅ 是（AC-021/023/024 FAIL） |
| M6 | 去掉执行器完整性自检 | `scripts/verify-integrity.mjs` | ✅ 是 | 篡改执行器后仍 exit=0 | ✅ 是（AC-016 FAIL） |
| M7 | **去掉脱敏** | `scripts/lib/redaction.mjs` | ✅ 是 | 证据里出现 `secret-value` 明文；`meta.redaction={rules_applied:[],redacted_fields:0}` | ❌ **否 —— 假 PASS（23/0）** |
| M8 | 去掉 `--run` 的幂等判断 | `test-case-design/scripts/cycle-state.mjs` | ✅ 是 | `runs=["RUN-QA-1","RUN-QA-1"]` | ❌ **否 —— 假 PASS（23/0）** |
| M9 | 载体冲突被**误诊**成 `incomplete_request_carrier` | `scripts/lib/verdict.mjs` | ✅ 是 | `C5.conflict` 失败（type 与期望不符） | ❌ **否 —— 假 PASS（23/0）** |
| M10 | 成功路径退出码返回 1（应为 0） | `scripts/run-suite.mjs` | ✅ 是 | `C23.exit0` 失败 | ❌ **否 —— 假 PASS（23/0）** |
| M11 | 执行外壳**绕过** `cycle-state.mjs` 直接写 `cycle.json` | `scripts/run-suite.mjs` | ✅ 是 | 去注释后仍见 `cycle.json` 字样；推进器缺席时 `runs[]` 仍被写入 | ❌ **否 —— 假 PASS（23/0）** |
| M12 | 在 `scripts/lib/` 里引入 `child_process` | `scripts/lib/cycle.mjs` | ✅ 是 | `grep` 命中 `node:child_process` | ❌ **否 —— 假 PASS（23/0）** |
| M13 | mock `/token` 不再返回敏感字段（**把脱敏场景掏空**） | `executors/mock-endpoints.json` | ✅ 是 | 脱敏断言与留痕断言同时失败 | ❌ **否 —— 假 PASS（23/0）** |

**统计**：我方 harness **13/13** 测出差异（无假护栏）；BA 验收脚本 **6/13**，**7 条假 PASS**。

### 4.1 我方 harness 自身的诚实性自检
变异过程中发现并修正了**我自己 harness 里的一个假护栏**：`C22`（外部依赖检查）原先把 `grep` 当成 `node` 的参数执行，导致该断言恒真。修正为直接调用 `grep` 后重跑基线与全部变异（表内数据均为修正后的结果）。修正后基线仍为 48 PASS / 1 FAIL。

---

## 5. BA 验收脚本（`verify-acceptance.sh`）质量评估

### 5.1 总体
- 基线运行：**23 PASS / 0 FAIL**（对着未改动的交付物）。
- 13 条变异中**只测出 6 条**，7 条报全绿。**「全绿」在这个脚本上不足以作为验收结论。**

### 5.2 逐项假 PASS 风险

| 风险等级 | 位置 | 问题 | 实证 |
|---|---|---|---|
| **P0** | `verify-acceptance.sh:577-593`（AC-013） | **场景空测 / 恒真**。D13 场景**没有设置 `driver: "mock"`**（D7/D19/D21/D22/D23/D24 都设了），于是走 `api` 驱动打 `http://127.0.0.1:9` → `network_error` → **0 个证据文件、`/token` 从未被请求**。判定条件 `LEAK==0 && meta 含 "rules_applied"` 于是**恒真**。 | **M7（把脱敏整个删掉）→ 脚本仍报 23 PASS / 0 FAIL。** 手工复现：`{"case_id":"TC-001","status":"failed","evidence":0,"error":"network_error"}`、证据文件数 0、`meta.redaction={"rules_applied":[],"redacted_fields":0}` → LEAK=0 且含 rules_applied → PASS |
| P1 | `:404-408`（AC-021） | 只断言 `status == "blocked"`，**不校验 `error.type`**。AC-021 原文要求「原因指向载体冲突」；D23/D25 的全部价值就是「缺 path 是补齐、冲突是二选一」不能混。 | **M9（冲突被误诊成 incomplete）→ 23/0 全绿** |
| P1 | `:646-661`（AC-017） | `RC1`（成功路径退出码）**被采集但从未断言**；且「校验失败 → exit 1」这一情形**从未被构造**（`RC3` 是 RC1 的重复且未使用）。AC-017 原文要求 0/1/2 三种退出码都验。 | **M10（成功路径 exit 改为 1）→ 23/0 全绿** |
| P1 | `:612-618`（AC-012b） | `grep -c -E "writeFile.*cycle\.json\|writeFileSync.*cycle\.json" "$TE"/executors/*.mjs "$EX"/*.mjs` —— **单行正则**且**漏扫 `scripts/lib/`**。现实写法（路径先存变量、写入在另一行）完全绕过。 | **M11（绕过 cycle-state 直接写 cycle.json）→ 23/0 全绿** |
| P1 | `:668-670`（AC-015） | 同上：`grep` 只扫 `$EX/*.mjs` 与 `executors/*.mjs`，**漏掉 `$EX/lib/*.mjs`**（那里正是引入外部依赖最自然的位置）；且**未检查 `bash`/`grep`/`sed`**（AC-015 原文要求查这些）。 | **M12（在 `scripts/lib/` 引入 `child_process`）→ 23/0 全绿** |
| P2 | `:186-203`（`detect_mock`） | **与 D16 冲突**。D16 明确写「契约必须写死一种…原验收脚本用『三种启用方式自适应探测』，是验收方不该有的自由度」。脚本至今仍保留 env-driver / executor-enum / cli-flag 三路探测 —— 意味着「只支持命令行 `--executor mock`」的实现也能过 AC-014，而 `run-suite.mjs` 根本不支持该参数。 | 代码即证据 |
| P2 | `:229-234`（AC-014） | 只判「存在产物目录 + 探测到某种启用方式」，**不判执行退出码、不判证据链完整、不判用例结果**。`run_suite()` 只看目录存不存在就返回 0。 | 代码即证据 |
| P2 | `:562-575`（AC-006） | 只判 `status == "blocked"`，**不判 `error.type == credential_missing`**（AC-006 原文要求「`results.json` 里 `error.type` 表明是环境/凭证缺失」）。任何原因导致的 blocked 都能过。 | 代码即证据 |
| P2 | `:582-590`（AC-013） | 即便场景修好，`grep -q "rules_applied"` 查的是**键名**而非值；`rules_applied: []`（一条都没脱敏）也能通过。 | 代码即证据 |
| P2 | 多处 | 大量 `grep -l/-c` 关键词检索（AC-003/AC-005/AC-012b/AC-015）都是**关键词命中**而非结构化断言：措辞一变就漏判，且命中也不代表行为成立。 | 代码即证据 |

### 5.3 做得好的地方（避免只写负面）
- AC-019/AC-020 **锚定到具体用例的具体状态行**（`TC-003`/`TC-004` 的 status + 证据条数），且能同时区分「只跑首步」与「拿首响应判所有断言」两种坏形态 —— 我方 M1/M2 都被它抓住。
- AC-021/022/023/024 的场景 JSON 写得很具体，AC-023/AC-024 **校验到了 `error.type` 的具体取值**。
- AC-009/010/011 的四类篡改是**真实行为测试**（改字节/删文件/改 results/改计数，且含「还原后应回到 exit 0」），我方 M1（删证据检测）也被它抓到。
- AC-007 场景**显式先断言「凭证确实被用上了」**（status≠blocked 且证据文件数>0），避免了 AC-013 那种空测 —— 同一份脚本里的 AC-013 恰好犯了 AC-007 自己避免的错。

### 5.4 建议的最小修法
1. AC-013 的 D13 场景补 `o.driver="mock"`（与 D7/D19 等一致），并把断言改为「证据文件数 ≥ 1 **且** 证据里含 `token` 字段 **且** 产物中搜不到 `secret-value`」，另加 `redacted_fields > 0`。
2. AC-021/AC-006 补 `error.type` 断言。
3. AC-017 补断言 `RC1 == 0`，并新增一条「suite.json 非法 → exit 1」的构造。
4. AC-012b/AC-015 的检索范围补上 `$EX/lib/*.mjs`，并改为**去注释后**检索 `cycle.json` / `child_process`。
5. `detect_mock` 按 D16 收敛为单一启用方式（环境配置 `driver` 字段）。
6. 增补两类当前**完全没有覆盖**的场景：`skipped` 用例不得发请求；传输层错误（超时/网络错误）时已执行步骤的证据不得丢失。

---

## 6. 缺陷清单

### P0-1 · `skipped` 用例（deprecated / 自身标记 blocked）**仍然真实发出请求并落证据**
- **触发条件**：用例集里有 `status: "deprecated"` 或 `status: "blocked"` 的用例。**每条这样的用例都会照常发一次 HTTP 请求。**
- **影响**：
  1. 对 `api` 驱动连真实系统时，**废弃用例会打到生产/预发**，可能产生真实副作用（写数据、触发退款等）—— 而判定的却是「skipped，不执行」。
  2. 证据链自相矛盾：判 `skipped` 的用例在 `evidence/<case_id>/` 下有真实响应文件，`reproduction.steps` 也照实记了它。
- **证据**：
  - `scripts/run-suite.mjs:298-362`：生命周期（`deprecated` / `blocked`）**只在 `decide()` 里处理**（`scripts/lib/verdict.mjs:168-173`），而 `decide()` 在**第 364 行**才被调用 —— 请求在第 353 行 `driver.run(...)` 就已经发出去了。
  - 实测：基线 MAIN 套件里 `TC-SKIP-DEPRECATED` 与 `TC-SKIP-BLOCKEDCASE` 均 `status=skipped`，但 `evidence.length == 1`，且 `evidence/TC-SKIP-DEPRECATED/step-1-response.json` 真实存在。
  - 契约违反：`references/evidence-chain.md:102` 明确写 `skipped` = 「**不执行**：用例已废弃（`status: deprecated`）或用例自身被标记为 `blocked`」；`scripts/lib/verdict.mjs:13` 同样写着「skipped = 不执行」。
- **复现**：
  ```
  # 用例集里放一条 status: "deprecated" 的用例，任何带 step.action="GET /x" 的都行
  node skills/test-execute/scripts/run-suite.mjs <suite.json> --project-root <proj> --json
  # 观察：results.json 里该条 status="skipped"，但 evidence 数组非空、evidence/<id>/ 下有响应文件
  ```
- **建议修法**：在 `run-suite.mjs` 的用例循环里，**在调用 `driver.run` 之前**先判生命周期：`deprecated` / `blocked` 直接置 `execution = { observed:null, evidence:[], reproduction:null, error:null }`，让 `decide()` 给出 `skipped`；同时 `reproduction.steps` 走「一个请求都没执行」的声明回退分支。
- **验收脚本盲区**：BA 脚本从未构造 `deprecated` / `blocked` 用例 → 该缺陷对 BA 脚本**完全不可见**。

### P0-2 · BA 验收脚本 AC-013（脱敏）**完全空测**，删掉脱敏仍报全绿
- **触发条件**：任意实现（含「脱敏被整个删掉」）跑 BA 的 `verify-acceptance.sh`。
- **影响**：**AC-013 的验收结论无效** —— 「脱敏在写入前完成，且留痕」这条安全类 AC 从未被真正验证过。
- **证据**：见 §5.2 第一行（机制 + M7 实证 + 手工复现）。
- **建议修法**：见 §5.4 第 1 条。

### P1-1 · 传输层错误（超时/网络错误）时，**已执行步骤的证据被丢弃，复现信息反而回退成「声明的步骤」**
- **触发条件**：多步用例的第 N 步超时或网络错误（前面的步骤已成功）。
- **影响**：证据链**说的与实际做的彻底不一致**：
  - `evidence` = **0 份**（已成功的那一步的响应证据被整段丢弃，事后无法复盘）；
  - `reproduction.steps` = **用例声明的全部步骤**（声称跑了 N 步，实际只跑了 N-1 步）；
  - `reproduction.command` = `null`（没有任何可复制的命令）。
- **证据**：
  - 根因：`executors/http-core.mjs:344` `if (!outcome.ok) return { error: outcome.error };` —— **提前 return，丢掉了已累积的 `steps`（含各自 evidence 内容）与 `commands`**。
  - 实测（`timeout_ms=300`，step2 = `GET /slow?ms=3000`）：
    ```
    status: failed
    error: {"type":"timeout","message":"请求超时（超过 300 毫秒）"}
    evidence: 0
    reproduction: {"steps":["GET /ok","GET /slow?ms=3000"],"command":null,"expected":null}
    证据目录文件数: 0
    ```
  - 契约违反：`references/evidence-chain.md:93` —— 「`steps` 只写**实际执行过**的步骤（**与证据份数一一对应**）；**一个请求都没执行时**（判 `blocked`）才回退到用例声明的步骤」。此处既不是 blocked，也不是「一个请求都没执行」。
  - 同章 §3.1 —— 「多步用例的证据条目数应等于它实际发出的请求数 —— **少一份就说明有请求没跑**」。
- **复现**：
  ```
  # 用例：step0 = GET /ok（断言成立）；step1 = GET /slow?ms=3000；用例 timeout_ms = 300
  node skills/test-execute/scripts/run-suite.mjs <suite.json> --project-root <proj> --json
  # 观察：status=failed，evidence 长度 0，reproduction.steps 长度 2
  ```
- **建议修法**：`http-core.mjs` 的 `executePlan` 遇到失败时**不要提前丢弃**：`return { steps, observed: last?.observed ?? null, evidence: flatEvidence, error, reproduction: { steps: executedActions, command: commands.join('\n') } }`，把已执行的部分连同 error 一起交回；判定层照常判 `failed`。
- **验收脚本盲区**：BA 脚本的失败用例只用「断言不成立」制造，从不构造传输层错误 → 该缺陷**对 BA 脚本不可见**。

### P1-2 · BA 脚本 AC-021 不校验 `error.type` → 「冲突被误诊成缺 path」判全绿
- 证据：M9 → 23/0；`verify-acceptance.sh:404-408` 只比 `status`。
- 建议：`[ "$S21" = "blocked" ] && [ "$T21" = "conflicting_request_carrier" ]`。

### P1-3 · BA 脚本 AC-017 从不断言成功路径退出码 0，也未覆盖 exit 1
- 证据：M10 → 23/0；`verify-acceptance.sh:651-657` 里 `RC1` 采集后未参与判定，`RC3` 是无用重复。
- 建议：断言 `RC1 -eq 0`；新增「suite.json 缺必填字段 → exit 1 且 stdout 可 JSON.parse」的构造。

### P1-4 · BA 脚本 AC-012b / AC-015 的检索漏掉 `scripts/lib/` 且是单行正则
- 证据：M11（绕过推进器直写 `cycle.json`）、M12（在 `lib/` 引入 `child_process`）→ 均 23/0。
- 建议：检索范围补 `$EX/lib/*.mjs`；对 `cycle.json` 采用「去注释后再检索」的方式；对 `child_process` 采用 `import` 语句级检索。

### P2-1 · `run-suite.mjs` 的驱动生命周期没有 `finally` → 任何未预期异常都会让进程**永不退出**
- **触发条件**：`driver.start()` 成功之后、`driver.stop()` 之前发生任何未捕获异常（例如判定层抛错）。
- **影响**：内置 mock 服务一直监听，**进程打印完 JSON 错误后仍不退出**（CI 里表现为挂死作业，而不是一条红色构建）。
- **证据**：
  - 源码：`scripts/run-suite.mjs:282-293`（`driver.start()`）与 `:460-466`（`driver.stop()`）之间**没有 `try/finally`**；`decide()`（第 364 行）、`redactor.redactJson`、写盘等都在保护范围之外。
  - 实测（用一个会让判定层抛错的变异体触发）：stdout 已输出 `{"ok":false,"error":"Cannot read properties of undefined (reading 'step_index')","exit_code":1}`，但 `timeout 8 node run-suite.mjs …` 返回 **124**（8 秒后仍在运行）。`ps` 可见 `node …/run-suite.mjs …` 常驻。
- **建议修法**：把 `driver.start()` 之后的全部逻辑包进 `try { … } finally { await driver.stop?.() }`；并在 `main()` 末尾显式 `process.exit(exitCode)` 作为兜底。

### P2-2 · `meta.cycle.runs_recorded` 与 `stage_status` 是**硬编码**，推进失败也照写 `true`
- **触发条件**：`--cycle` 指向的轮次不存在 / `cycle-state.mjs` 推进失败。
- **影响**：证据链的轮次段**谎报**「本次执行标识已记入 `stages.execute.runs[]`」与「阶段状态 in_progress」，而实际 `ok:false`、`exit_code:1`、run_id **根本没记进去**。这正是本 REQ 要消灭的「证据链说的与实际做的不一致」。
- **证据**（实测，`--cycle /tmp/…/no-such-cycle`）：
  ```
  payload.cycle = { "ok": false, "exit_code": 1, "stage_status": "in_progress",
                    "run_id": "CYC-FAIL", "runs_recorded": true, … }
  exit_code = 0        # 轮次推进失败却仍然 exit 0
  轮次目录是否被创建：未创建（好）
  ```
  源码：`scripts/run-suite.mjs:487-498`，`runs_recorded: true` 与 `stage_status: 'in_progress'` 是字面量。
- **建议修法**：`runs_recorded: advanced.ok`、`stage_status: advanced.ok ? 'in_progress' : null`；并在 `advanced.ok === false` 时把退出码置 1（或至少把 `cycle.ok=false` 提升为 `problems` 里的条目，让 `--strict`/退出码能反映出来）。

### P2-3 · BA 脚本 AC-006 只判 `status == blocked`，不判 `error.type`
- 与 AC-006 原文「`results.json` 里 `error.type` 表明是环境/凭证缺失」不符；任何原因导致的 blocked 都能过。

### P2-4 · BA 脚本 `detect_mock` 三路自适应探测，与 D16 的「契约必须写死一种」冲突
- 含义：验收方保留了「实现方自己选启用方式」的自由度，与决策记录直接矛盾；且 `cli-flag` 分支对应的 `--executor mock` 参数 `run-suite.mjs` 根本不支持。

### P2-5 · BA 脚本 AC-015 未检查 `bash` / `grep` / `sed`（AC-015 原文要求检查这些）

### P2-6 · `bindAssertions()` 在「歧义显式拒」之前被调用
- `scripts/lib/verdict.mjs:192` 先 `bindAssertions(plan, execution)`，第 214/237 行才判 `incomplete` / `conflict`。若绑定逻辑对「零请求的计划」处理不当，异常会**绕过**「歧义显式拒」分支直抛（我方 M2 初版就触发了这条路径，见 §4.1 与 P2-1）。
- **建议修法**：把 `bindAssertions` 移到 `incomplete` / `conflict` 判定之后。

---

## 7. 我**没有**验到的部分（明确列出，不假装全覆盖）

1. **`api` 驱动对真实系统的行为**：只用 mock 驱动 + 本地端口测过；未对任何真实/外部系统发过请求（按约束也不应依赖外网）。鉴权只验了 `basic`，**未验 `bearer` / `header` 两种模式**（BA 脚本的 AC-007 场景用了 bearer）。
2. **`extract` 跨用例变量串联（`${name}`）**：未专门构造用例验证「前一条用例 extract 的值供后一条引用」。D14 明确说 `${name}` 只跨用例不跨 step，这条路径我没有独立验证。
3. **`retries` 的实际重试次数**：只确认了配置项存在，未验证「网络错误时真的重试 N 次」。
4. **断言 op 枚举的完整性**：只验了 `equals` / `exists`。`not_equals` / `contains` / `not_contains` / `matches` / `type` / `gt` / `gte` / `lt` / `lte` / `$header.*` / `$.a[0].b` 等**未逐个验证**。
5. **超时与重试在真实慢服务下的行为**：只用 mock 的 `/slow?ms=N` 触发过一次超时（P1-1），没有覆盖「重试后成功」「重试耗尽」等组合。
6. **`verify-layout.mjs` 的完整契约**：只验证了「环境配置允许 `driver` 字段、`suite.json` 允许 `executor: "mock`」这一处 D16 相关的放宽；**没有**跑完整的 REQ-002B 目录契约回归（我的测试项目本身触发了 2 个 FAIL，是我造的项目不完整所致，不是交付物问题）。
7. **REQ-002A 回归脚本整体**：我只做了 `validate-cases.mjs` 新旧版本的**对拍**，**没有**执行 `verify-regression-002a.sh` 全文（BA 脚本会调用它并报全绿）。
8. **`test-case-design/references/{project-layout,state-machine}.md` 与实现的文档一致性**：只做源码级阅读，未做逐条文档-代码对拍。
9. **`demand.md` 中未被 `acceptance.md` 覆盖的条款**（如 F1~F9 功能编号的完整映射）：以 acceptance.md 的 29 条为验收入口，demand.md 未逐条对账。
10. **并发 / 大规模用例集 / 超大响应体 / 循环引用等极端输入**：未测。
11. **Windows（win32）行为**：未测（SKILL.md 有平台说明章节）。
12. **证据链自校验的规模化表现**（大量证据文件时的指纹计算开销）：未测。
13. **合并到 `develop` 后的集成回归**：本 REQ 与 REQ-002.5a / 002B 的交叉影响，只验了「`cycle-state.mjs --run` 幂等」「`verify-layout` 接受 mock」两处。
14. **BA 脚本在「实现方只支持命令行 `--executor mock`」时的行为**：只做了代码阅读推断（`run-suite.mjs` 不接受该参数），未构造该实现实测。

---

## 8. 附：本次验收用到的关键路径

| 用途 | 路径 |
|---|---|
| 我方独立断言 harness | `/tmp/req004-verify/harness/check.mjs`（49 条） |
| 自建测试工程 | `/tmp/req004-verify/proj/`（MAIN / AMBIG / CRED / NOCRED 四个套件） |
| 变异定义 | `/tmp/req004-verify/muts.mjs`（M1-M8）、`muts2.mjs`（M9/M10/M12/M13）、`muts3.mjs`（M11） |
| 变异执行器 | `/tmp/req004-verify/final-sweep.mjs` → `final-mutations.json` |
| 基线结果 | `/tmp/req004-verify/baseline.json`（48 PASS / 1 FAIL） |
| BA 脚本对变异体的结果 | `/tmp/req004-verify/ba-mut.log`、`mut2.log` |
