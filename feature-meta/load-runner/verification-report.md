# REQ-012 交付验证报告 —— `load-profile` 的 runner 适配

> 需求编号：**REQ-012** · 决策号范围：**D156~D184** · 判据条数：29（AC-001 ~ AC-029）
> 验收门：`BA/demands/REQ-002-suite-foundation/REQ-012-load-runner/verify-acceptance.sh`
> （sha256 `fc42d99774bc2f668aaaa9cb4da828765fd860855d35a13e1ba8a832743ff293`，**未改动**）
> 被验包：`<REPO_ROOT>/feature-REQ-012`

---

## 1. 自测（实现方自跑，真实输出）

> 说明：下方代码块中的**工作目录路径**含内部运行时字样，已做**中性化占位**处理（写 `<工作目录>`）；
> 其余各行均为逐字真实输出。

### 1.1 主跑（夹具 ⇒ 计划）

```console
$ node skills/load-profile/scripts/plan-load-run.mjs --load-dir <项目根> --out-dir <项目根>
产物已生成: <项目根>/test-assets/load/plans
  压测计划 2 个: LOAD-001-checkout, LOAD-002-checkout-staging
  invocation 合计 5 条（每个 profile 段一条，不合并）
rc=0
```

计划内容与契约 §0.6「基线真值表」逐字对齐（截取关键行）：

```console
$ node -e '...'   # 打印计划里的 argv
WL-001 step0: loadtest -t 60 -c 10 --cores 1 http://127.0.0.1:<P1>/api/v1/checkout -m POST --rps 100 -k -d 10000
WL-001 step1: loadtest -t 120 -c 20 --cores 1 http://127.0.0.1:<P1>/api/v1/checkout -m POST --rps 100 -k -d 10000
WL-002 step0: loadtest -t 300 -c 5 --cores 1 http://127.0.0.1:<P1>/api/v1/orders -m GET
WL-004 step0: loadtest -t 600 -c 2 --cores 1 http://127.0.0.1:<P1>/api/v1/health -m GET
WL-003 step0: python -m mylab --duration 30 --concurrency 50
```

### 1.2 非法输入变体（十份：rc=1 + 点名坏点 + **不留 `plans/`**）

```console
[V1]  rc=1 无plans :: 输入非法: 负载模型 order-query.json 的 profile.steps[0] 的 concurrency 必须是 ≥1 的整数（实际 0）
[V2]  rc=1 无plans :: 输入非法: target 的路径部分必须以 / 开头，实际是 "api/v1/checkout"（target="POST api/v1/checkout"）
[V3]  rc=1 无plans :: 输入非法: 负载模型 health-check.json 的 tool.runner 取值非法: "jmeter"（只允许 loadtest / python）
[V4]  rc=1 无plans :: 输入非法: 环境 "staging" 的环境文件不存在: …/environments/staging.json（base_url 取不到 ⇒ 不能拼 URL）
[V5]  rc=1 无plans :: 输入非法: 环境 local 的文件里没有非空的 base_url（base_url 是 URL 的唯一来源）
[V6]  rc=1 无plans :: 输入非法: 套件 LOAD-001-checkout 的 scenario.json 的 scenarios[0] 的 id 与模型漂移（引用 "WL-999"，模型 "WL-001"）
[V7]  rc=1 无plans :: 输入非法: 套件 LOAD-001-checkout 的 scenario.json 的 scenarios[0] 的 path 解析不到文件: …/scenarios/nope.json（引用不得悬空）
[V8]  rc=1 无plans :: 输入非法: args 里有未知的键 "concurrency"（runner=loadtest 只认 rps / keepalive / timeout_s / method）—— 未知键一律拒绝，不静默忽略也不透传
[V9]  rc=1 无plans :: 输入非法: 负载模型 checkout-staging.json 是 python runner，但 args 里没有 command —— 必须自陈完整命令（完整 argv 数组）；本工具不许为 python runner 编造默认命令
[V9b] rc=1 无plans :: 输入非法: 负载模型 checkout-staging.json 的 args.command 必须是**非空 argv 数组**（字符串命令要分词 ⇒ 分词歧义 ⇒ 不接受）
```

### 1.3 用法错误（rc=2）、幂等、产物已存在、尾斜杠、只写 `plans/`

```console
=== 缺 --load-dir      rc=2  无plans
=== 缺 --out-dir       rc=2
=== 未知参数          rc=2
=== 多余位置参数      rc=2
=== 幂等（两个不同根） diff -r plans1 plans2 ⇒ 无差异（逐字相同）
=== 产物已存在        rc=1 :: 状态非法: 产物已存在: …/test-assets/load/plans（本工具不覆盖既有产物 —— 请先人工处理，或换一个 --out-dir）
=== 尾斜杠环境变体    rc=0
WL-001 base_url字段= "http://127.0.0.1:<P1>/" argvURL= http://127.0.0.1:<P1>/api/v1/checkout
WL-002 base_url字段= "http://127.0.0.1:<P1>/" argvURL= http://127.0.0.1:<P1>/api/v1/orders
WL-004 base_url字段= "http://127.0.0.1:<P1>/" argvURL= http://127.0.0.1:<P1>/api/v1/health
=== 只写 plans/（跑前跑后指纹，排除 plans/）
before=b1ea32131d33b941cc98433b91627c1f33a43138ab57a322f4ad16e6dd16fcbe  -
after =b1ea32131d33b941cc98433b91627c1f33a43138ab57a322f4ad16e6dd16fcbe  -
新增文件只有：./test-assets/load/plans/LOAD-001-checkout.json、./test-assets/load/plans/LOAD-002-checkout-staging.json
```

### 1.4 校验器的**行为护栏**（合法 ⇒ 0；篡改 ⇒ 1；键序打乱 ⇒ 0）

```console
=== 校验器（合法）      压测计划自洽: …/test-assets/load/plans                    rc=0
=== 篡改 -t 60→61 后校验  压测计划不自洽（1 处）:
- LOAD-001-checkout.scenarios[0].invocations[0].argv[2]: 取值不同（期望 "60"，实际 "61"）   rc=1
=== 键序打乱（负控）     压测计划自洽: …/test-assets/load/plans                    rc=0
```

---

## 2. 验收门 —— 快跑（`REQ012_NO_MUT=1`）

## 2. 验收门 —— 快跑（`REQ012_NO_MUT=1`）

命令（工作目录路径已中性化占位）：

```console
R=BA/demands/REQ-002-suite-foundation/REQ-012-load-runner
P=<REPO_ROOT>/feature-REQ-012
SHA=fc42d99774bc2f668aaaa9cb4da828765fd860855d35a13e1ba8a832743ff293
REQ012_NO_MUT=1 QA012_WORK_ROOT=<工作目录>/quick QA012_SCRIPT_SHA=$SHA bash $R/verify-acceptance.sh $P
```

真实输出摘要（逐条结论 29 行全 PASS）：

```console
PASS AC-001 满足
PASS AC-002 满足
PASS AC-003 满足
PASS AC-004 满足
PASS AC-005 满足
PASS AC-006 满足
PASS AC-007 满足
PASS AC-008 满足
PASS AC-009 满足
PASS AC-010 满足
PASS AC-011 满足
PASS AC-012 满足
PASS AC-013 满足
PASS AC-014 满足
PASS AC-015 满足
PASS AC-016 满足
PASS AC-017 满足
PASS AC-018 满足
PASS AC-019 满足
PASS AC-020 满足
PASS AC-021 满足
PASS AC-022 满足
PASS AC-023 满足
PASS AC-024 满足
PASS AC-025 满足
PASS AC-026 满足
PASS AC-027 满足
PASS AC-028 满足
PASS AC-029 满足
被验包只读自检: 全树指纹未变 ✓

结论: 29 PASS / 0 FAIL
验收脚本 sha256: fc42d99774bc2f668aaaa9cb4da828765fd860855d35a13e1ba8a832743ff293
判据条数（动态取 acceptance.md 的 `### AC-`）: 29
变异体套件: 已跳过（REQ012_NO_MUT=1）—— 不可判定，不计入通过；检出率结论以完整模式为准
门自身 stderr 的 bash 错误行: 0
```

退出码：`0`。

---

## 3. 验收门 —— 完整模式（变异体套件）

命令（**不设** `REQ012_NO_MUT`；每次跑门给**独立**的 `QA012_WORK_ROOT`）：

```console
QA012_WORK_ROOT=<工作目录>/full QA012_SCRIPT_SHA=$SHA bash $R/verify-acceptance.sh $P
```

真实输出（变异体套件部分，逐字）：

```console
基线失败键: []（基线全绿）
检测口径: 新增失败键 = 变异运行的失败键 减去 基线失败键（整行精确排除；「消失的失败键」不算检出）
变异体 计划顶层多一个 note 字段: 已检出（目标 AC-004 出现在新增失败键集合里；新增=[AC-001 AC-004]）
变异体 场景条目少一个必填字段（删 profile_type）: 已检出（目标 AC-004 出现在新增失败键集合里；新增=[AC-001 AC-004]）
变异体 invocation 元素多一个键: 已检出（目标 AC-004 出现在新增失败键集合里；新增=[AC-001 AC-004]）
变异体 计划顶层出现 cases_file: 已检出（目标 AC-004 出现在新增失败键集合里；新增=[AC-001 AC-004]）
变异体 -t 的值被改（60→61）: 已检出（目标 AC-014 出现在新增失败键集合里；新增=[AC-001 AC-014]）
变异体 -d 的值被改（10000→10，秒当毫秒）: 已检出（目标 AC-015 出现在新增失败键集合里；新增=[AC-001 AC-015]）
变异体 --rps 被删掉: 已检出（目标 AC-016 出现在新增失败键集合里；新增=[AC-001 AC-016]）
变异体 -k 被删掉: 已检出（目标 AC-016 出现在新增失败键集合里；新增=[AC-001 AC-016]）
变异体 --cores 1 被改成 --cores 2: 已检出（目标 AC-012 出现在新增失败键集合里；新增=[AC-001 AC-009 AC-012]）
变异体 URL 里丢掉 base_url（只留路径）: 已检出（目标 AC-009 出现在新增失败键集合里；新增=[AC-001 AC-009 AC-010]）
变异体 多段画像被合并成一条 invocation: 已检出（目标 AC-011 出现在新增失败键集合里；新增=[AC-001 AC-011]）
变异体 -m POST 被改成 -m GET: 已检出（目标 AC-010 出现在新增失败键集合里；新增=[AC-001 AC-010 AC-018]）
变异体 计划里出现 status: passed: 已检出（目标 AC-019 出现在新增失败键集合里；新增=[AC-001 AC-004 AC-019]）
变异体 无来源的场景被补上阈值: 已检出（目标 AC-020 出现在新增失败键集合里；新增=[AC-001 AC-020]）
变异体 阈值数值被改（凭空改阈值）: 已检出（目标 AC-020 出现在新增失败键集合里；新增=[AC-001 AC-020]）
变异体 无来源场景的未决问题被清空: 已检出（目标 AC-021 出现在新增失败键集合里；新增=[AC-001 AC-021]）
变异体 无对应用例场景的未决问题被清空: 已检出（目标 AC-021 出现在新增失败键集合里；新增=[AC-001 AC-021]）
变异体 同一计划文件里未决问题 id 重复: 已检出（目标 AC-021 出现在新增失败键集合里；新增=[AC-001 AC-021]）
变异体 python 场景的 argv 残留占位符: 已检出（目标 AC-018 出现在新增失败键集合里；新增=[AC-001 AC-018]）
变异体 一个计划文件被删掉: 已检出（目标 AC-013 出现在新增失败键集合里；新增=[AC-001 AC-013]）
变异体 计划文件被改名成 suite.json: 已检出（目标 AC-013 出现在新增失败键集合里；新增=[AC-001 AC-009 AC-011 AC-013 AC-028]）
变异体 计划里出现执行痕迹键 latency: 已检出（目标 AC-022 出现在新增失败键集合里；新增=[AC-001 AC-004 AC-022]）
变异体 环境文件被改写（改 base_url）: 已检出（目标 AC-024 出现在新增失败键集合里；新增=[AC-001 AC-009 AC-023 AC-024]）
变异体 删掉 skills/load-profile/SKILL.md: 已检出（目标 AC-002 出现在新增失败键集合里；新增=[AC-002 AC-003 AC-028]）
变异体 profile-rules.md 末尾被加了一行: 已检出（目标 AC-002 出现在新增失败键集合里；新增=[AC-002]）
变异体 README 里的 load-profile 被删掉: 已检出（目标 AC-003 出现在新增失败键集合里；新增=[AC-003 AC-028]）
变异体 README 里的 plan-load-run.mjs 被删掉: 已检出（目标 AC-003 出现在新增失败键集合里；新增=[AC-003]）
变异体 feature-meta/load-runner/traceability.md 被删掉: 已检出（目标 AC-027 出现在新增失败键集合里；新增=[AC-027]）
变异体 feature-meta/load-runner/manifest.json 的 req 被改成 REQ-006: 已检出（目标 AC-027 出现在新增失败键集合里；新增=[AC-027]）
变异体 feature-meta/load-profile/status.md 被改写: 已检出（目标 AC-027 出现在新增失败键集合里；新增=[AC-027]）
变异体 plan-load-run.mjs 被删掉: 已检出（目标 AC-001 出现在新增失败键集合里；新增=[AC-001 AC-004 AC-005 AC-006 AC-007 AC-008 AC-009 AC-010 AC-011 AC-012 AC-013 AC-014 AC-015 AC-016 AC-017 AC-018 AC-019 AC-020 AC-021 AC-022 AC-023 AC-024 AC-025 AC-026]）
变异体 plan-load-run.mjs 被去掉可执行位: 已检出（目标 AC-001 出现在新增失败键集合里；新增=[AC-001]）
变异体 test-execute 的 not_implemented 里 load 被删掉: 已检出（目标 AC-028 出现在新增失败键集合里；新增=[AC-028]）
变异体 交付物里出现内部运行时字样: 已检出（目标 AC-029 出现在新增失败键集合里；新增=[AC-029]）
变异体 package.json 的 files 里加了 feature-meta: 已检出（目标 AC-029 出现在新增失败键集合里；新增=[AC-029]）
负控 负控：把计划 JSON 的键序打乱（内容逐字不变）: 未检出（新增失败键为空）—— 符合预期，探测器不是恒真
变异体套件: 检出 35/35（有效变异体）

结论: 29 PASS / 0 FAIL
变异体套件: 检出 35/35（有效变异体）
门自身 stderr 的 bash 错误行: 0
```

- 退出码：`0`；门自身 stderr：**0 行 bash 错误**。
- **正控 35/35 全部检出**；**负控（键序打乱）未检出** ⇒ 探测器不是恒真。
- ⚠️ 注意：多数产物型变异体的「新增失败键」里带 `AC-001` ——
  这是**本实现的校验器确实有行为护栏**的直接证据（篡改计划 ⇒ 校验器判红 ⇒ AC-001 的③项判红）。

---

## 4. 上游门回归与组合门

**一次只跑一个门**（每个门独立工作目录，顺序执行）：

```console
######## REQ-009 ########
REQ009 rc=0
结论: 29 PASS / 0 FAIL
######## REQ-010 ########
REQ010 rc=0
结论: 29 PASS / 0 FAIL
######## REQ-011 ########
REQ011 rc=0
结论: 28 PASS / 0 FAIL / 0 不可判定
######## REQ-007 ########
REQ007 rc=0
结论: 29 PASS / 0 FAIL
######## REQ-008 ########
REQ008 rc=0
结论: 29 PASS / 0 FAIL
######## REQ-006 ########
REQ006 rc=0
结论: 42 PASS / 0 FAIL
######## REQ-002A ########
REQ002A rc=0
结论: 19 PASS / 0 FAIL
######## REQ-002B ########
REQ002B rc=0
结论: 41 PASS / 0 FAIL
```

组合门（`node bin/test-agent-skills.mjs verify`）真实输出（**临时根路径已中性化占位**；其余逐字）：

```console
[ok] 已装到临时根的 skill（8 个）: defect-verify, load-profile, qa-toolchain, regression-plan, security-plan, test-case-design, test-execute, test-report
[ok] 依赖图校验通过（8 个 skill 的版本声明与 requires 全部满足）
[ok] 组合场景: test-execute 的 offline 夹具 → 4/1/1/0（与该夹具 README 的预期一致）
[ok] 组合场景: 轮次 execute 阶段已推进（in_progress），本次 run_id 已记入 stages.execute.runs[]
[ok] 组合场景: test-report 的报告链路（make-report.mjs 读 test-execute 的执行产物）→ verdict.case_layer=fail、verdict.evidence_layer=pass、verdict.regression_layer=not_applicable、verdict.overall=fail；cases.total=6、cases.passed=4、cases.failed=1、cases.blocked=1、cases.skipped=0（与执行产物逐字一致）
[ok] 组合场景: defect-verify 的复现用例链路（make-defect-cases.mjs 读缺陷单 + 已有用例集）→ 缺陷 2 条（复用 1 / 派生 1 / 未决 0）、复现用例 2 条（id 唯一：TC-001 / TC-101）
[ok] 组合场景: security-plan 的规划链路（make-security-plan.mjs 读安全上下文 + 功能用例集 + 依赖扫描结果）→ 威胁 11 条（OWASP 十类：已覆盖 7 类 / 不适用 3 类）、扫描发现 2 条全部映射到威胁、权限矩阵 12 条（允许缺口 1 条）、套件 7 个 / 安全用例 18 条（id 跨套件唯一且不与输入集冲突）；产物可被上游加载层消费且过上游用例集校验器
[ok] 组合场景: load-profile 的规划链路（make-load-profile.mjs 读压测上下文 + 功能用例集）→ 负载模型 4 个（阈值二态与键的有无一致、无来源的 1 个已留未决问题）、压测套件 2 个（按环境分组、引用不漂移、覆盖双向完整）、产物可被上游加载层消费且不含任何压测结论字段
[ok] 组合门全部通过
```

退出码：`0`。**既有 8 个 skill 的场景结论逐字未变**（含 `load-profile` 那条 —— 本 REQ **没动**它的实现）。

---

## 5. 交付前的自查

| 项 | 命令 | 结果 |
|---|---|---|
| 全部脚本语法 | `node --check skills/load-profile/scripts/*.mjs skills/load-profile/scripts/lib/*.mjs` | 全部通过（无输出） |
| 脚本可执行位 | `ls -l skills/load-profile/scripts/*.mjs` | 两个新入口均为 `-rwxr-xr-x`（既有两个未动） |
| REQ-009 既有 14 文件 | `sha256sum skills/load-profile/{SKILL.md,skill-meta.json,references/*,scripts/make-load-profile.mjs,scripts/check-load-profile.mjs,scripts/lib/*}` | 与 `acceptance.md` §0.8.1 基线**逐字一致**（AC-002 PASS） |
| 交付红线 | `npm pack --dry-run --json` | 打包清单里**无** `feature-meta/` 条目（AC-029 PASS） |

---

## 6. 我**没有验到**的部分

- 见 `status.md` §6（压测工具能否跑 / 压测结果 / 真实服务容量 / 跨平台 / 并发跑门）。
- **未跑**验收方的外部探针 —— 那些探针验的是**门**，不是本实现；门本身未改动（sha256 与需求方给的钉版一致）。
- **未验**「把计划真的交给 `loadtest` 跑」—— 本 REQ **不执行**，且**不许**声称「已验证压测可跑」。

---

# REQ-013 交付验证报告 —— `load-profile` 的 **负载级执行与判定链**（只打本地桩）

> 需求编号：**REQ-013** · 决策号范围：**D185~D210** · 判据条数：41（AC-001 ~ AC-041）
> 验收门：`BA/demands/REQ-002-suite-foundation/REQ-013-load-exec/verify-acceptance.sh`
> （sha256 `e4743970c04defb76aeb8b060d27ecff0078e78e0ee92f5a07e574af00eb6f0f`，**未改动**）
> 被验包：`<REPO_ROOT>/feature-REQ-013`
> 需求契约（**只读**）：`BA/demands/REQ-002-suite-foundation/REQ-013-load-exec/`

---

## 1. 交付边界复核

| 边界 | 落实情况 |
|---|---|
| **只打本地桩** | ✅ 计划里的 URL 与替换后的执行 URL **都**校验回环（非回环 ⇒ rc=1 + 点名）；桩**只监听 `127.0.0.1`**、端口 0 |
| **绝不打真实服务** | ✅ 计划 URL 的 host 非回环即拒绝执行（`bad-url` 夹具 ⇒ rc=1，stderr 点名 `example.com` 与「回环」） |
| **判定不依赖退出码** | ✅ 判定只看观测量；桩中途挂掉不会让判定变绿（退出码只区分「跑完了」与「执行器自身出错」） |
| **默认桩下不凭空判达标** | ✅ 延迟三类与 `error_rate` 判 `undetermined`；`throughput_rps` 仍可判 |
| **`max_concurrency` 恒不可判定** | ✅ 不拿 `concurrency` / `clients` 冒充实际并发 |
| **`python` runner 一律不可判定** | ✅ `observed` 缺席、判定为空数组，**但照常执行并留下证据** |
| **只写 `results/`** | ✅ 输入（计划 / 模型 / 环境）只读；跑前跑后项目根（除 `results/` 外）指纹不变 |
| **先校验、后建目录** | ✅ 四类非法夹具与工具缺失场景**都不留** `results/` |
| **产物已存在不覆盖** | ✅ 第二次跑 rc=1、既有产物 sha256 逐字未变 |
| **桩不留残留** | ✅ 桩由执行器托管起停（异常路径也停），停时连同残留连接一起断开 |
| **不改上游** | ✅ A 阶段的计划 / 契约、`test-execute` / `test-report`、其它 skill、`bin/`、`package.json`、`README.md`、`LICENSE` **一律未改** |
| **交付包不含内部运行时字样** | ✅ `skills/` `bin/` `README.md` `LICENSE` 全文 0 命中 |
| **不装工具** | ✅ 只**检查**工具可用性；不可用 ⇒ rc=1 + 点名缺什么与怎么装 |

---

## 2. 交付物清单

| 文件 | 作用 |
|---|---|
| `skills/load-profile/scripts/run-load-test.mjs` | **主入口**：读计划 ⇒ 起桩 ⇒ 执行 ⇒ 判定 ⇒ 写负载级产物与证据（退出码 0 / 1 / 2） |
| `skills/load-profile/scripts/check-load-test.mjs` | **产物自洽校验器**（只读、**有行为护栏**）：复核产物与计划一致、证据清单 sha256 可复算 |
| `skills/load-profile/scripts/lib/stub.mjs` | **本地桩服务**：只监听回环、自带计数 / 延迟直方图 / 延迟与错误注入、生命周期由执行器托管 |
| `skills/load-profile/scripts/lib/load-exec.mjs` | **执行器 + 判定器**：argv 反解层、工具解析、`.loadtestrc` 渗透防护、阈值判定、写入纪律、产物自洽校验 |
| `skills/load-profile/references/load-exec-contract.md` | **B 阶段契约文档**（两个入口 / 桩 / 反解层 / 判定映射 / 产物形状 / 已知限制） |
| `skills/load-profile/SKILL.md` | **追加**一节「B 阶段：负载级执行与判定链（**只打本地桩**）」（既有内容**逐字未改**） |
| `feature-meta/load-runner/` | 本 REQ 的追溯件四件套（`verification-report.md` / `traceability.md` / `feature.json` / `feature-meta.json`）+ `status.md` 的一节 |

---

## 3. 关键实现取舍（与契约口径一致）

| # | 取舍 | 落点 |
|---|---|---|
| 1 | **API 模式 = 语义等价执行**：跑的是 argv 的**语义等价物**（API 选项名与 CLI 不是一套）⇒ 产物标 `api_equivalent` 并记 `executed_params`（反解结果，可被第三方独立反解核对） | `lib/load-exec.mjs`（`reverseArgv` / `runInvocation`） |
| 2 | **反解只接受规范形态**：规范外 ⇒ rc=1 + 点名（不猜参数） | `lib/load-exec.mjs`（`reverseArgv`） |
| 3 | **`.loadtestrc` 渗透防护两道防线**：显式覆盖每个相关选项 + **在空的沙箱目录里跑**（工具读不到 `.loadtestrc` ⇒ `proxy` 显式禁用）；另加一道自证（跑完核对 `Result.concurrency`） | `lib/load-exec.mjs`（`createSandbox` / `runSuite`） |
| 4 | **`statusCallback` 必设**：不设 ⇒ HTTP 错误状态码全塌成 `-1` ⇒ 错误码分类能力丢失 | `lib/load-exec.mjs`（`runApiInvocation`） |
| 5 | **联合口径**：错误率判 `not_met` ⇒ 同一次 invocation 的吞吐**不判 `met`**（判 `undetermined` 并点名「联合口径」） | `lib/load-exec.mjs`（`judgeThresholds`） |
| 6 | **理由文本不含观测数值** ⇒ 同一输入两次跑的结构**逐字一致**（幂等只承诺结构级） | `lib/load-exec.mjs`（`judgeThresholds`） |
| 7 | **桩侧与客户端侧分两段存**：桩侧是辅助证据，**不参与阈值判定**；两侧请求数**不做等式判定**（只判上界） | `lib/load-exec.mjs`（`observed` / `stub_observed`） |
| 8 | **沉降期**：压测工具收尾时还有在途请求 ⇒ 留 150ms 让它们落到**本次**窗口（否则会被算到下一条 invocation 头上） | `lib/load-exec.mjs`（`runScenario`） |
| 9 | **CLI 模式能力降级如实标注**：错误码只有 `-1` 桶、分位来自 stdout 文本、最小延迟**记 `null`**（不编造） | `lib/load-exec.mjs`（`parseCliStdout`） |

---

## 4. 自测（实现方自跑，真实输出）

### 4.1 验收门 —— 快跑模式（只跑基线，不跑变异体）

```console
$ QA013_NO_MUT=1 QA013_WORK_ROOT=<工作根> bash verify-acceptance.sh <REPO_ROOT>/feature-REQ-013
...
结论: 41 PASS / 0 FAIL
门自身 stderr 的 bash 错误行: 0
被验包只读自检: 全树指纹未变 ✓
```

### 4.2 验收门 —— 完整模式（基线 + 41 个变异体 + 负控）

> 见 §5（完整模式的真实输出）。

### 4.3 手工自测（本地夹具 ⇒ 产物）

```console
$ node skills/load-profile/scripts/run-load-test.mjs --load-dir <项目根> --out-dir <项目根> --suite LOAD-001-checkout
产物已生成: <项目根>/test-assets/load/results/LOAD-001-checkout.json
  证据目录: <项目根>/test-assets/load/results/evidence/LOAD-001-checkout
  执行模式: api_equivalent（桩: http://127.0.0.1:<随机端口>）
  invocation 合计 5 条；套件判定: undetermined
  不可判定阈值键: p95_latency_ms, error_rate, max_concurrency
  ⚠️ 以上结论**只在本地桩上**成立，不代表任何真实服务的容量。
rc=0
```

产物要点（默认桩 ⇒ 本 REQ 最核心的红线）：

| 项 | 实测 |
|---|---|
| `p95_latency_ms` / `error_rate` 判定 | `undetermined`（**不是** `met`），`observed == null`，`reason` 点名「本次桩未注入延迟与错误」 |
| `throughput_rps` 判定 | `met`，`observed == observed.effective_rps`（默认桩下**仍可判**） |
| `max_concurrency` 判定 | `undetermined`，`observed == null`，`reason` 点名该键无对应观测量 |
| `python` runner 的 invocation | `observed` **缺席**、恰好 8 键、判定 `undetermined`、**仍有** `step_index` 证据子目录 |
| 桩侧观测 | 每条 invocation **本次增量**（`first_at_ms` / `last_at_ms` 相对桩启动 ⇒ 顺序执行、无重叠可核） |

---

## 5. 验收门 —— 完整模式的真实输出

```console
$ QA013_WORK_ROOT=<工作根> bash verify-acceptance.sh <REPO_ROOT>/feature-REQ-013
工具前置: 使用已装好的 loadtest（<已装好的 loadtest 目录>）

— 跑判据（独立复算器 judge.mjs —— 零 import 被验包）
PASS AC-001 满足
...
PASS AC-041 满足
被验包只读自检: 全树指纹未变 ✓

— 变异体套件（正控 + 负控；检测口径 = 新增失败键）
基线失败键: []（基线全绿）
检测口径: 新增失败键 = 变异运行的失败键 减去 基线失败键（整行精确排除；「消失的失败键」不算检出）
变异体 ac002（结果产物顶层多一个键）: 已检出（目标 AC-002 出现在新增失败键集合里）
变异体 ac003（schema_version 写成字符串）: 已检出（目标 AC-003 出现在新增失败键集合里）
...
变异体 ac001（results/ 下多出一个 suite.json）: 已检出（目标 AC-001 出现在新增失败键集合里）
变异体 ac036（SKILL.md 里出现内部运行时字样）: 已检出（目标 AC-036 出现在新增失败键集合里）
变异体 ac037（追溯件里漏掉一条决策号）: 已检出（目标 AC-037 出现在新增失败键集合里）
变异体 ac038（SKILL.md 删掉 B 阶段入口说明）: 已检出（目标 AC-038 出现在新增失败键集合里）
负控 负控：只改结果产物的 generated_at 取值（语义不变）: 未检出（新增失败键为空）—— 符合预期，探测器不是恒真
变异体套件: 检出 41/41（有效变异体）

———— 逐条结论 ————
PASS AC-001 满足
...
PASS AC-041 满足

结论: 41 PASS / 0 FAIL
验收脚本 sha256: e4743970c04defb76aeb8b060d27ecff0078e78e0ee92f5a07e574af00eb6f0f
判据条数（动态取 acceptance.md 的 `AC-` 标题行）: 41
决策号（动态取 decisions.md 的 `D` 标题行）: 26 条 [D185 D186 ... D210]
门自身 stderr 的 bash 错误行: 0
rc=0
```

| 指标 | 快跑模式 | 完整模式 |
|---|---|---|
| 判据结论 | **41 PASS / 0 FAIL** | **41 PASS / 0 FAIL** |
| 退出码 | `0` | `0` |
| 变异体 | 跳过（`QA013_NO_MUT=1`） | **41 个有效变异体，检出 41/41，逃逸 0，无效 0** |
| 负控 | —— | **未检出**（新增失败键为空 ⇒ 探测器不是恒真） |
| 被验包只读自检 | 全树指纹未变 ✓ | 全树指纹未变 ✓ |
| 门自身 stderr 的 bash 错误行 | 0 | 0 |

---

## 6. 已知限制（如实登记）

| # | 限制 |
|---|---|
| 1 | **结论只在本地桩上成立** ⇒ 不代表任何真实服务的容量 |
| 2 | **默认桩的延迟 / 错误率没有代表性** ⇒ 这两类阈值在默认桩下判「不可判定」；想要可判的延迟结论必须用 `--stub-delay-ms` 注入 |
| 3 | **`max_concurrency` 没有对应观测量** ⇒ 恒判「不可判定」 |
| 4 | **`python` runner 的输出形态无契约** ⇒ 一律判「不可判定」（不解析其 stdout） |
| 5 | **`python` runner 的自陈命令是否只打本地桩，本 REQ 不校验**（命令由计划给定）—— 契约 F4.5 ⑤ 已登记为遗留项 |
| 6 | **桩侧与客户端侧的请求数天然不相等**（在途请求）⇒ 只判上界，不判等式 |
| 7 | **桩侧延迟是服务端处理耗时**，与客户端 RTT 语义不同 ⇒ 不可混用 |

## 7. 契约缺陷上报

> 角色分离：**发现契约问题只上报，不自改契约**。

| # | 观察 | 处理 |
|---|---|---|
| 1 | 契约 §3.3 的期望性质第 15 条写「各 invocation 的 `stub_observed.requests` 之和 ≥ 桩侧总请求数」——「桩侧总请求数」在本 REQ 里**没有对应字段**（桩侧观测按契约是每次 invocation 的**本次增量**，F3 ③）⇒ 该句的「桩侧总请求数」只能理解为「各次增量之和」，措辞易误读 | **未自改契约**；实现按「本次增量」口径执行（判据 AC-014 用的是可判别口径：从第 3 条起本次增量 < 前面各条之和） |
| 2 | 契约 §3.3 的期望性质第 6 条写「每条 invocation 的 `observed.total_requests > 0`」——而 WL-003（`python` runner）**按契约没有 `observed`**（F7.5 / AC-041）⇒ 该条对 `python` 场景不成立 | **未自改契约**；实现按「`loadtest` runner 的 invocation 才有 `observed`」执行 |
