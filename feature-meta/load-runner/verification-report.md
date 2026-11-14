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

（见下节真实输出）

---

## 3. 验收门 —— 完整模式（变异体套件）

（见下节真实输出）

---

## 4. 上游门回归与组合门

（见下节真实输出）

---

## 5. 我**没有验到**的部分

- 见 `status.md` §6（压测工具能否跑 / 压测结果 / 真实服务容量 / 跨平台 / 并发跑门）。
- **未跑**验收方的外部探针 —— 那些探针验的是**门**，不是本实现；门本身未改动（sha256 与需求方给的钉版一致）。
