# 证据链契约（evidence-chain）

本文件是**契约**，不是说明材料。读者是要在本项目里执行用例、交付执行结果的人：
你按这里的规则产出产物，`scripts/verify-evidence.mjs` 按这里的规则判定"这份结果有没有被改过"。

配套文件：

- `references/executor-spec.md` —— 执行器接口、断言操作、mock 端点集
- `scripts/run-suite.mjs` —— 执行外壳（产出产物）
- `scripts/verify-evidence.mjs` —— 证据链校验器（判定产物可信度）
- `scripts/redact.mjs` —— 脱敏（独立使用时的检查/补做入口）
- `scripts/lib/fingerprint.mjs` —— 指纹算法的**单一来源**（执行外壳与校验器共用）

---

## 0. 为什么要有证据链

"跑了 44 条，通过 41 条"对需求方没有任何证明力：跑的环境对不对？失败的用例怎么复现？证据会不会被改过？

产物落 `.test-artifacts/`（本地、不进 Git），之后会被复制进制品库、贴进缺陷单、附到报告里。
一旦某条证据被替换或某条结果被改写，没有指纹就永远查不出来。
有了指纹，"这份报告可信吗"变成一条命令的事。

---

## 1. 目录结构

```text
.test-artifacts/<run_id>/
├── meta.json            # 本次执行的元信息
├── results.json         # 逐条用例的结果
├── evidence/
│   └── TC-003/
│       └── response.json
└── logs/
    └── runner.log
```

| 目录 / 文件 | 职责 |
|---|---|
| `meta.json` | 谁跑的、什么时候、哪个环境、跑了多少条、指纹是多少、脱敏做了什么 |
| `results.json` | 逐条用例的判定结果、时间、证据清单、复现信息、错误 |
| `evidence/<用例 ID>/` | 该用例的原始证据（**已脱敏**） |
| `logs/runner.log` | 执行过程日志（**已脱敏**） |

`run_id` 是本次执行的唯一标识，**同时是目录名**。默认取 `<套件名>-<时间戳>-<随机串>`。
同一 `run_id` 重复执行时，执行外壳会先清掉上一次的 `evidence/` 与 `logs/`，再重新产出 —— 幂等，不相互污染。

---

## 2. `meta.json` 字段表

| 字段 | 类型 | 必填 | 语义 |
|---|---|---|---|
| `run_id` | string | 是 | 本次执行的唯一标识，同时是目录名 |
| `suite` | string | 是 | 套件标识（来自 `suite.json`） |
| `scope` | string | 是 | 范围（`functional` / `security` / `load`） |
| `requirement` | string | 是 | 关联需求编号 |
| `environment` | string | 是 | **环境名**，不是 `base_url` —— 避免把内网地址散到产物里 |
| `started_at` / `finished_at` | string | 是 | ISO-8601 时间戳 |
| `duration_ms` | number | 是 | 本次执行总耗时（毫秒） |
| `agent` | string | 是 | 谁执行的 |
| `executor` | object | 是 | `{name, version}` —— 实际跑的驱动 |
| `executor_source` | string | 否 | 驱动从哪来（`suite.json.executor` / `environment.driver`） |
| `target` | object | 否 | `{driver, base_url?, source}` —— `base_url` 只在内置桩服务时写（本地地址不外泄）；走真实环境时只写环境名 |
| `tool_versions` | object | 是 | 执行过程中用到的工具与版本（空对象也要写） |
| `cases_total` | number | 是 | 用例总数 |
| `cases_passed` | number | 是 | 通过数 |
| `cases_failed` | number | 是 | 失败数 |
| `cases_blocked` | number | 是 | 阻塞数（环境缺失、缺可机械判定的断言等） |
| `cases_skipped` | number | 是 | 跳过数（用例已废弃等） |
| `evidence_manifest_sha256` | string | 是 | 证据清单指纹（见 §4） |
| `results_sha256` | string | 是 | 结果指纹（见 §4） |
| `redaction` | object | 是 | `{rules_applied: [], redacted_fields: N}` —— 脱敏留痕 |
| `cases_file` | string | 否 | 用例集路径（相对项目根） |
| `cycle` | object\|null | 否 | 轮次推进结果（见 §6） |

---

## 3. `results.json` 字段表

`results.json` 的根节点是**数组**，每个元素是一条用例的结果。

| 字段 | 类型 | 必填 | 语义 |
|---|---|---|---|
| `case_id` | string | 是 | 用例 ID（如 `TC-003`） |
| `title` | string | 是 | 用例标题 |
| `requirement_refs` | string[] | 是 | 覆盖哪些需求条目 |
| `status` | string | 是 | `passed` / `failed` / `blocked` / `skipped` |
| `started_at` / `finished_at` | string | 是 | ISO-8601 时间戳 |
| `duration_ms` | number | 是 | 该用例耗时（毫秒） |
| `evidence` | object[] | 是 | `{path, sha256, bytes, media_type}`；`path` 相对产物目录 |
| `reproduction` | object | 是 | `{steps: [], command, expected}` —— 失败/阻塞时必填 |
| `error` | object\|null | 是 | `{type, message}` —— 失败/阻塞时必填 |

`status` 的四种取值：

| 取值 | 语义 |
|---|---|
| `passed` | 全部断言成立 |
| `failed` | 有断言不成立 / 执行报错 / 超时 |
| `blocked` | 无法判定：缺少可机械判定的断言、凭证或环境缺失、驱动无法启动 |
| `skipped` | 不执行：用例已废弃（`status: deprecated`）或用例自身被标记为 `blocked` |

> **不可判定判 `blocked`，绝不判 `passed`。** 执行器"跑完了没报错"不等于"通过"；
> 把不可判定的用例算作通过，等于把"没测"记成"测过且通过"。宁可漏报通过，不可虚报通过。

---

## 4. 指纹算法

三种指纹，全部用 sha256（`node:crypto`）。规范化序列化定义在 `scripts/lib/fingerprint.mjs`，
执行外壳与校验器共用同一份实现 —— 两份实现一旦漂移，校验器就会对同一份产物给出不同结论。

### 4.1 单文件指纹

每个证据文件算一次 sha256 与字节数，写进 `results.json` 的 `evidence[]`：

```json
{ "path": "evidence/TC-003/response.json", "sha256: "<64 位十六进制>", "bytes": 512, "media_type": "application/json" }
```

### 4.2 证据清单指纹 `evidence_manifest_sha256`

对 `results.json` 中**全部 evidence 条目（路径 + sha256）**再算一次的总指纹。
规范化序列化：每条证据拼成 `路径 + "\u0000" + sha256 + "\n"`，按 `results.json` 的顺序连接，取 sha256。

用途：发现 `results.json` 的证据条目被改过（换了路径、换了指纹、删了条目）。

### 4.3 结果指纹 `results_sha256`

对 `results.json` 的**判定内容**算一次的总指纹。规范化序列化：每条结果拼成

```text
case_id + "\u0000" + status + "\u0000" + error.type + "\u0000" + error.message
        + "\u0000" + reproduction.command + "\u0000" + reproduction.steps 连接串 + "\n"
```

之后再接上该条结果的证据条目行（同 §4.2）。

用途：发现"把 `failed` 改成 `passed`"这类**只改判定不改证据**的改写 ——
这种改写不会动证据条目，只有结果指纹能发现它。

### 4.4 计数

`meta.json` 的五个计数必须与 `results.json` 的实际条数与状态分布相符。计数与实际不符 → 判"计数造假"。

---

## 5. 脱敏

### 5.1 时机

脱敏在**写入产物之前**完成：产物里存的应当已经是脱敏后的内容。
执行外壳把证据内容先脱敏、再落盘、再算指纹 —— 所以指纹算的是**脱敏后**的文件，二者永远对得上。

### 5.2 规则

两类规则，外加"凭证字面量"通道：

| 规则 | 命中什么 | 替换成 |
|---|---|---|
| 敏感字段名 | 键名归一化后命中敏感词表（`password` / `token` / `secret` / `authorization` / `idcard` / `phone` / …） | `[REDACTED:field]` |
| 值模式正则 | JWT、Bearer 令牌、连接串（含账号密码）、身份证号、手机号、信用卡号 | `[REDACTED:<规则名>]` |
| 凭证字面量 | 运行时从环境变量读到的凭证值在文本里出现 | `[REDACTED:credential]` |

规则可用 `scripts/redact.mjs --config <规则文件>` 扩展（与内置规则合并）。

### 5.3 留痕

`meta.json` 的 `redaction` 段记录：

```json
"redaction": { "rules_applied": ["field"], "redacted_fields": 1 }
```

- `rules_applied[]`：被启用过的规则名（让人知道"这里被处理过"，而不是让人以为原文如此）
- `redacted_fields`：被脱敏的字段计数

### 5.4 不参与脱敏的字段

`sha256` / `evidence_manifest_sha256` / `results_sha256` / `bytes` / `media_type` / `duration_ms` / `run_id`
**不参与脱敏** —— 指纹类字段一旦被脱敏，证据链自校验必然失败。

---

## 6. 轮次状态集成

执行批次要记进轮次状态，但**状态文件只能由脚本写**：

```console
node ../test-case-design/scripts/cycle-state.mjs set-stage <轮次目录> \
  --stage execute --status in_progress --artifacts .test-artifacts/<run_id>
```

`run-suite.mjs --cycle <轮次目录>` 会自动做这件事（在独立线程里调用推进器，本脚本不碰 `cycle.json`）。

**关于 `stages.execute.runs[]`**：需求 F7 提到把 `run_id` 记进 `stages.execute.runs[]`，
但 REQ-002.5a 的 `cycle-state.mjs` 的 `set-stage` 目前只支持 `--status` 与 `--artifacts`，
**没有写 `runs[]` 的参数**（该字段也不在 REQ-002B 的 `cycle.json` 字段表里）。
本 skill 不越权改 REQ-002.5a 的已验收交付，因此运行标识落在契约支持的
`stages.execute.artifacts`（产物路径列表，元素即 `.test-artifacts/<run_id>`，含 `run_id`）。
后续若要给 `cycle-state.mjs` 加 `--run` 参数，`stages.execute.runs[]` 即可自然落地。

---

## 7. 校验器判定什么

`scripts/verify-evidence.mjs <run_dir>`：

| 情况 | 判定 |
|---|---|
| 证据文件缺失 | 报"证据文件丢失" |
| 证据文件内容被改动（sha256 不符） | 报"证据文件被改动"，并给出记录值与实际值的前缀 |
| 证据文件字节数不符 | 报"字节数不符" |
| `results.json` 的证据条目被改 | 报"results.json 与 meta.json 记录的证据清单指纹不符" |
| `results.json` 的判定内容被改（含 `status` 被改写） | 报"results.json 与 meta.json 记录的清单指纹不符" |
| `meta.json` 的计数与实际条数/分布不符 | 报"计数造假" |
| 全部一致 | 退出码 0 |

退出码：`0` = 自洽，`1` = 校验失败，`2` = 调用方式错误。

---

## 8. 常见错误与修法

| 报错关键字 | 原因 | 修法 |
|---|---|---|
| `证据文件丢失` | 产物拷贝时漏了证据文件 | 重新执行，别手工补文件 |
| `证据文件被改动` | 证据内容被编辑过 | 重新执行；产物是证据，不是草稿 |
| `清单指纹不符` | `results.json` 被改写 | 重新执行；**不要手改结果去凑** |
| `计数造假` | `meta.json` 的计数与实际条数不符 | 重新执行 |
| `证据链校验失败` 出现在刚跑完就验 | 产物目录写了一半就中断 | 重跑 |
