# runner 适配契约 —— 负载模型 → 压测工具可消费的命令清单

> 本文是 `load-profile` skill 的 **runner 适配**那一半的契约：
> **负载模型 + 套件 + 环境 ⇒ 压测计划（命令清单）**。
>
> **只产出计划，一个请求都不发**：不 spawn 压测工具、不联网、不打桩、不判阈值达标。
> 压测**执行**与**判定链**属后续阶段（负载级执行器尚未实现，`test-execute` 的
> `not_implemented` 里仍含 `load`）。

---

## 1. 两个入口

| 入口 | 作用 | 用法 |
|---|---|---|
| `scripts/plan-load-run.mjs` | **主入口**：读负载模型 + 套件 + 环境 ⇒ 产出压测计划 | `node scripts/plan-load-run.mjs --load-dir <项目根> --out-dir <项目根>` |
| `scripts/check-load-run.mjs` | **产物自洽校验器**：复核计划与模型一致 | `node scripts/check-load-run.mjs <项目根>` |

退出码（两者一致）：

| 情形 | 退出码 |
|---|---|
| 成功 / 自洽 | `0` |
| 输入非法 / 违反写入纪律 / 校验不通过 | `1` |
| 用法错误（参数缺失 / 未知参数 / 多余位置参数） | `2` |

---

## 2. 输入（**只读**）

| # | 输入 | 位置 |
|---|---|---|
| 1 | 负载模型本体 | `<load-dir>/test-assets/load/scenarios/*.json` |
| 2 | 套件引用件 | `<load-dir>/test-assets/load/suites/<套件名>/scenario.json`（`path` 相对**套件目录**解析） |
| 3 | 套件执行配置 | `<load-dir>/test-assets/load/suites/<套件名>/suite.json`（取 `environment`） |
| 4 | 环境 | `<load-dir>/test-assets/environments/<环境名>.json` 的 `base_url` |

`test-assets/load/report.json` **不读也不改**。

**引用不得悬空、不得漂移**：引用件的 `path` 必须解析到 `scenarios/` 下真实存在的文件，
其 `id` / `name` 必须与模型**逐字相等**；套件 `suite.json` 的 `environment` 必须在
`environments/` 下有**同名**文件，且该文件有**非空**的 `base_url`（`base_url` 是 URL 的唯一来源）。

---

## 3. 输出（每个套件一个）

```
<out-dir>/test-assets/load/plans/
└── <套件名>.json
```

### 3.1 顶层字段集（**封闭 4 个**）

| 字段 | 约束 |
|---|---|
| `schema_version` | `== 1` |
| `suite` | == 文件名去 `.json` == 套件目录名 |
| `environment` | == 该套件 `suite.json` 的 `environment` |
| `scenarios` | 非空数组；**顺序 == 引用件里的场景顺序** |

### 3.2 场景条目字段集（**10 个必填 + 2 个条件**）

`scenario_id` / `scenario_name` / `runner` / `runtime` / `target` / `base_url` /
`profile_type` / `invocations` / `thresholds_status` / `open_questions`
（+ 模型 `provided` 时才有的 `thresholds` / `thresholds_source`）。

- `runner` ∈ {`loadtest`, `python`}、`runtime` ∈ {`bun`, `python`, `node`}、
  `profile_type` ∈ {`constant`, `ramp-up`, `ramp-down`, `spike`, `soak`}（**逐字**取自模型）；
- `base_url` **逐字等于**环境文件里的 `base_url`（**含**尾斜杠）；
- `open_questions` **必填**（可以为空数组）：条目数与模型相等，每条的 `id` 与 `topic`
  **逐字等于**模型同一条目，`question` 的**文字**属实现方判断（但必须非空）；
- `thresholds` / `thresholds_source`：模型 `provided` 时**逐字**携带；`not_provided` 时**两个键都不存在**。

### 3.3 invocation 元素字段集（**封闭 4 个**）

| 字段 | 约束 |
|---|---|
| `step_index` | 整数 ≥ 0；**等于**它在数组里的下标 |
| `duration_s` | 整数 ≥ 1；**逐字等于** `profile.steps[step_index].duration_s` |
| `concurrency` | 整数 ≥ 1；**逐字等于** `profile.steps[step_index].concurrency` |
| `argv` | **非空字符串数组**；**完整可跑** |

⚠️ **每个 step 一条 invocation**（**不许合并**）：合并 = 丢梯度 = 失真。

---

## 4. 参数映射 —— `loadtest` runner

| 模型字段 | → argv | 备注 |
|---|---|---|
| `profile.steps[i].duration_s` | `-t <秒>` | 整数秒 |
| `profile.steps[i].concurrency` | `-c <并发>` | 整数 |
| —— | `--cores 1` | **恒定钉死**（`--cores` 默认半核，且 `rps` / `maxRequests` 都按核分摊 ⇒ 不钉则语义随机器变） |
| `target` 的方法 | `-m <METHOD>` | **大写**；`args.method` 存在时**用它**（覆盖 `target` 的方法） |
| `base_url` + `target` 的路径 | 位置参数（**完整绝对 URL**） | URL 是 `loadtest` 的**唯一**位置参数（多于一个 ⇒ `Too many arguments`） |
| `args.rps` | `--rps <值>` | 每客户端 rps |
| `args.keepalive`（`true`） | `-k` | `false` / 缺失 ⇒ **不给** |
| `args.timeout_s` | `-d <值×1000>` | **秒 → 毫秒**；`-d` 是**单请求**超时（**不是**压测总时长） |
| `args.<未知键>` | **拒绝** | rc=1，**点名该键** |

### 4.1 `argv` 的规范形态

```
["loadtest", "-t", <duration_s>, "-c", <concurrency>, "--cores", "1", <完整绝对 URL>, "-m", <METHOD>]
  可依次跟：["--rps", <rps>]  ["-k"]  ["-d", <timeout_ms>]
```

三组可选参数**按上表顺序**出现，**至多各一次**。

### 4.2 URL 的拼法（尾斜杠细则）

- 场景条目的 `base_url` **字段** = 环境文件里的值（**逐字**，**含**尾部 `/`）；
- `argv` 里的 URL = `base_url` **去掉尾部 `/`** + `target` 的路径（以 `/` 开头）
  ⇒ URL 里**不得**出现 `//`。

例：环境文件 `base_url = "http://127.0.0.1:8080/"` ⇒ 字段是 `http://127.0.0.1:8080/`，
而 URL 是 `http://127.0.0.1:8080/api/v1/checkout`。

### 4.3 `args` 的已知键白名单

| `runner` | 允许的 `args` 键 |
|---|---|
| `loadtest` | `rps` / `keepalive` / `timeout_s` / `method` |
| `python` | `command` |

⚠️ **跨 runner 的键同样拒绝**（`loadtest` 场景里的 `command`、`python` 场景里的 `rps` …）
⇒ 键的含义是「这个 runner 认不认」，不是「模型里有没有」。
**静默忽略 = 悄悄丢参数 = 压出来的不是你想压的** ⇒ 未知键一律**拒绝**（rc=1 + 点名该键）。

---

## 5. `python` runner

`tool.runner == "python"` ⇒ **必须**由 `args.command` **显式**给出完整命令。

1. `args.command` 必须是**完整 argv 数组**（**非空字符串数组**）。
   ⚠️ **字符串命令不接受**（字符串要分词 ⇒ 分词歧义）⇒ rc=1。
2. 命令里允许出现占位符 `{duration_s}` / `{concurrency}`，**必须**被该段的取值替换；
   出现**其它** `{...}` 占位符 ⇒ rc=1（点名）。
3. 计划里该场景的 `invocations[].argv`：
   - 以自陈命令（占位符替换后）为**前缀**；
   - **含有**恰好等于 `String(duration_s)` 与 `String(concurrency)` 的元素
     （自陈命令没带占位符时，把该段的取值补在末尾 —— 值来自模型，不是编造）；
   - **不得**残留占位符；
   - 该场景有 ≥2 段时，各条 `argv` **互不相同**（多段保真）。

⚠️ **不许**为 `python` runner 编造一条默认命令 —— 没有事实支撑的命令 = 凭空造。

---

## 6. 写入纪律

| # | 口径 |
|---|---|
| 1 | **只写** `<out-dir>/test-assets/load/plans/` |
| 2 | **先校验、后建目录**：输入非法 ⇒ `plans/` **一个都不许出现**（0 字节的空目录也算存在） |
| 3 | **产物已存在 ⇒ 报错退出，不覆盖**（判的是 `plans/` 目录本身，不是整个 `test-assets/load/` —— 读入侧本来就有 `scenarios/` 与 `suites/`） |
| 4 | **幂等**：同一输入两次跑（两个不同项目根）⇒ 两份 `plans/` **逐字相同**（**不含**生成时间戳 / 随机 id / 宿主路径） |
| 5 | **输入只读**：模型 / 套件 / 环境文件一律不改写 |

---

## 7. 诚实性

| # | 红线 | 载体 |
|---|---|---|
| 1 | **不得**把「未压测」写成「已通过」 | 计划里**任意层级**都不得出现 `status` / `result` / `verdict` / `executed` / `passed` / `outcome` / `conclusion`（`thresholds_status` **不算** `status`） |
| 2 | **不得**出现「已压测 / 已达标 / 已通过 / 压测完成 / 压测结果」这类表述 | 同上（字符串值与键名都扫） |
| 3 | **没有指标来源 ⇒ 不写阈值** | `thresholds_status == "not_provided"` ⇒ **无** `thresholds` 键、**无** `thresholds_source` 键 |
| 4 | **缺口必须显式** | `not_provided` ⇒ 必留 `topic == "thresholds"` 的未决问题；无对应用例 ⇒ 必留 `topic == "coverage"` 的未决问题 |
| 5 | **零请求** | 跑完不得有任何 HTTP 调用；不得有执行痕迹键（`executed` / `started_at` / `finished_at` / `timestamp` / `duration_ms` / `elapsed` / `latency` / `bytes` / `status_code` / `response` / `responses` / `samples` / `metrics` / `result_rows`）；不得出现 `runs` / `evidence` / `.test-artifacts` |

⚠️ 阈值**可以携带**（供人看，逐字来自模型），但**绝不**产出任何「已达标 / 未达标」的结论。

---

## 8. 边界（明确不做）

1. **不发任何请求**（不 spawn 压测工具、不联网、不打桩、不执行 `python` 自陈命令）；
2. **不装工具**（`loadtest` 由工具链管，本 skill 只**声明**依赖）；
3. **不实现 `load` 执行器**（`test-execute` 的 `not_implemented` 里仍含 `load`）；
4. **不做阈值判定**（阈值可携带，但**绝不产出结论**）；
5. **不写 `cases.json`**、不派生用例；
6. **不改**负载模型 / 套件 / 环境文件（**只读**）；
7. **不要求**压测工具真能跑 —— 本阶段只保证 **argv 形态正确、参数名真实存在**；
   「复制即可跑」的可执行性属后续阶段的验证范围。
