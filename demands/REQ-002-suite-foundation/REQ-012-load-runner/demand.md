# REQ-012 —— 压测能力域 A 阶段：`load-profile` skill 的 **runner 适配**

> 本文件是**需求契约正文**。验收判据见 `acceptance.md`（AC-001 ~ AC-029，29 条）。
> 决策记录见 `decisions.md`（D156 ~ D184，29 条）。验收门见 `verify-acceptance.sh`。

---

## 0. 背景与边界

### 0.1 缺口具体长什么样

REQ-009 已经交付了 `load-profile` skill，产出**负载模型**（`test-assets/load/scenarios/*.json`）、
**压测套件**（`test-assets/load/suites/LOAD-<编号>-<短名>/{scenario.json,suite.json}`）与
**压测计划清单**（`test-assets/load/report.json`）。

但架构 §5.6 的原话是「建议 `load-profile` skill **生成负载模型 → 由执行器适配**」——
**适配的那半边还没做**：

- 负载模型里只有 `target`（`"POST /api/v1/checkout"` 这种形态）与 `environment`（环境**名**），
  **没有**任何工具能直接吃的参数；
- `args` 是**开放键值、原样透传**（REQ-009 `load-context-schema.md` L73），**没人**把它映射成
  真实压测工具的 CLI 参数；
- `profile.steps[]` 是**多段**（ramp-up = 60s@10c + 120s@20c），而 `loadtest` 的 `-t`/`-c` 是**单段**；
- 环境里的 `base_url` 与 `target` 的路径**还没被拼成完整 URL**。

⇒ 本 REQ 补上这一段：**负载模型 + 套件 + 环境 → 工具可执行的压测计划（命令清单）**。

### 0.2 本 REQ **只产出计划**，**一个请求都不发**

- `skills/test-execute/executors/index.json` 的 `not_implemented` = `["ui","load","security"]`
  ⇒ **`load` 执行器仍未实现**；
- ⇒ 本 REQ **不 spawn 压测工具、不联网、不打桩、不判阈值达标**；
- ⇒ 本 REQ **不要求**「`loadtest` 真跑一遍」（那必然不满足 ⇒ 写进判据就是**永远判红的假判据**）；
- ⇒ **零请求**必须有**外部可观测证据**（桩服务请求计数），不能靠「源码里没写 spawn」这种可被绕过的自查。

### 0.3 交付边界（不许越界）

| # | 边界 | 说明 |
|---|---|---|
| 1 | **不新增 skill 目录** | 这是 `load-profile` skill 的延续（架构 §8：REQ-002.9 = `load-profile`）；新增 `skills/load-profile/scripts/plan-load-run.mjs` 等 |
| 2 | **只写** `<out-dir>/test-assets/load/plans/` | 其余一切（模型 / 套件 / 环境 / 轮次 / README 以外的文件）**只读** |
| 3 | **不改** REQ-009 的既有 **14 个**文件的内容 | 新增文件**可以**；改内容**不行**（指纹基线见 `acceptance.md` §0.8） |
| 4 | **不改** `test-execute` | `load` 仍是 `not_implemented`（本 REQ **不实现**执行器） |
| 5 | **不装工具** | `loadtest@8.2.1` 由 `qa-toolchain` 管；本 REQ 只**声明**依赖 |
| 6 | **不写** `cases.json`、不派生用例 | 沿用 REQ-009 |
| 7 | **不做阈值判定** | 阈值可以**携带**（供人看），但**绝不产出任何「已达标/未达标」的结论** |
| 8 | **不改** REQ-009 的追溯件 | 本 REQ 的追溯件写进**新**子目录 `feature-meta/load-runner/`（见 F9） |

---

## 1. 目标

在 `skills/load-profile/` 内新增 **runner 适配器**，产出：

1. **压测计划**（主产物）：`<out-dir>/test-assets/load/plans/<套件名>.json`，
   每个套件一个，里面是**每段一条**的**完整可跑 argv**；
2. **产物自洽校验器**：复核计划与模型一致。

并且保证五件事：

- **不合并**：多段画像**每段一条 invocation**（合并 = 丢梯度 = 失真）；
- **不换算错**：`timeout_s`（**秒**）→ `-d`（**毫秒**）必须 ×1000；
- **不瞎猜**：`args` 的**未知键必须拒绝**；`python` runner **必须自陈完整命令**；
- **不假装**：`python` runner **不许**被编造出一条默认命令；
- **不发压**：计划里**不得**有结论键；**不得**有「已压测/已达标」表述。

---

## 2. 功能项 F1~F8

### F1 入口与用法

```
node skills/load-profile/scripts/plan-load-run.mjs \
  --load-dir <含 test-assets/load/ 的项目根> \
  --out-dir  <项目根>
```

| 参数 | 必填 | 说明 |
|---|---|---|
| `--load-dir` | 是 | 读入侧项目根（含 `test-assets/load/` 与 `test-assets/environments/`） |
| `--out-dir` | 是 | 写出侧项目根（产物写到 `<out-dir>/test-assets/load/plans/`） |

- 两个参数**都指向同一个项目根**是**最自然**的用法（读 `test-assets/load/`，写 `test-assets/load/plans/`）；
- **零第三方依赖**，只用 Node 内置模块；
- **两层退出码**（**必须可区分**）：

| 情形 | 退出码 | 例子 |
|---|---|---|
| 成功 | **0** | |
| **用法错误**（参数缺失 / 未知参数 / 多余位置参数） | **2** | 忘了 `--out-dir` |
| **输入非法**或**违反写入纪律** | **1** | 模型非法 / 未知 `args` 键 / 产物已存在 |

### F2 输入（**只读**）

| # | 输入 | 位置 | 要求 |
|---|---|---|---|
| 1 | **负载模型本体** | `<load-dir>/test-assets/load/scenarios/*.json` | REQ-009 产物，字段集封闭 14 个 |
| 2 | **套件引用件** | `<load-dir>/test-assets/load/suites/*/scenario.json` | 顶层封闭 3；`path` 相对**套件目录**解析 |
| 3 | **套件执行配置** | `<load-dir>/test-assets/load/suites/*/suite.json` | 顶层 ⊆ 上游 9 个允许字段 |
| 4 | **环境** | `<load-dir>/test-assets/environments/<环境名>.json` 的 `base_url` | **只读**，不改不建 |

⚠️ 入口**只读**这四类；`test-assets/load/report.json` 本 REQ **不读也不改**。

### F3 输出（**本 REQ 的核心交付形态**）

`<out-dir>/test-assets/load/plans/<套件名>.json`，**每个套件一个**（文件名 == 套件目录名 + `.json`）。

#### F3.1 顶层字段集**封闭 4 个**

| 字段 | 类型 | 约束 |
|---|---|---|
| `schema_version` | number | `== 1` |
| `suite` | string | **等于**文件��去 `.json` **等于**套件目录名 |
| `environment` | string | **等于**该套件 `suite.json` 的 `environment` |
| `scenarios` | array | ≥1 项；元素见 F3.2；**顺序 == 引用件里的场景顺序** |

⚠️ **不得**出现 `cases_file` 之类会被上游 `suite.json` 语义混淆的字段。

#### F3.2 `scenarios[]` 元素字段集**封闭 9 必填 + 2 条件**

| 字段 | 类型 | 约束 |
|---|---|---|
| `scenario_id` | string | **等于**模型的 `id` |
| `scenario_name` | string | **等于**模型的 `name` |
| `runner` | string | ∈ {`loadtest`,`python`}（**逐字等于**模型的 `tool.runner`） |
| `runtime` | string | ∈ {`bun`,`python`,`node`}（**逐字等于**模型的 `tool.runtime`） |
| `target` | string | **逐字等于**模型的 `target` |
| `base_url` | string | **逐字等于**环境文件的 `base_url` |
| `profile_type` | string | ∈ {`constant`,`ramp-up`,`ramp-down`,`spike`,`soak`}（**逐字等于**模型的 `profile.type`） |
| `invocations` | array | ≥1 项；元素见 F3.3 |
| `thresholds_status` | string | ∈ {`provided`,`not_provided`}（**逐字等于**模型的） |
| `thresholds` | object | **条件**：模型 `provided` 时存在且**逐字等于**模型；模型 `not_provided` 时**不得存在** |
| `thresholds_source` | string | **条件**：同上 |

⚠️ **阈值可以携带，但绝不带任何判定结论。**

#### F3.3 `invocations[]` 元素字段集**封闭 4 个**

| 字段 | 类型 | 约束 |
|---|---|---|
| `step_index` | number | 整数 ≥ 0；**等于**它在数组里的下标 |
| `duration_s` | number | 整数 ≥ 1；**逐字等于** `profile.steps[step_index].duration_s` |
| `concurrency` | number | 整数 ≥ 1；**逐字等于** `profile.steps[step_index].concurrency` |
| `argv` | array | **非空字符串数组**；**完整可跑**（见 F4） |

⚠️ **每个 step 一条 invocation**（**不许合并**）。

⚠️ 计划产物里**不得**出现任何压测结论键
（`status` / `result` / `verdict` / `executed` / `passed` / `outcome` / `conclusion`
—— **注意 `thresholds_status` 不算 `status`**）。

### F4 参数映射（`loadtest` runner）

| 模型字段 | → argv | 备注 |
|---|---|---|
| `profile.steps[i].duration_s` | `-t <秒>` | 整数秒 |
| `profile.steps[i].concurrency` | `-c <并发>` | 整数 |
| —— | `--cores 1` | **恒定钉死**（裁定 G5） |
| `target` 的方法 | `-m <METHOD>` | **大写** |
| `base_url` + `target` 的路径 | 位置参数（**完整绝对 URL**） | `loadtest` 的 URL 是**唯一**位置参数 |
| `args.rps` | `--rps <值>` | 每客户端 rps |
| `args.keepalive`（`true`） | `-k` | `false` / 缺失 ⇒ **不给** |
| `args.timeout_s` | `-d <值×1000>` | **秒 → 毫秒**；`-d` 是**单请求**超时 |
| `args.method` | `-m <值>` | **覆盖** `target` 的方法 |
| `args.<未知键>` | **拒绝** | rc=1，**点名该键** |

#### F4.1 `argv` 的**规范形态**（`loadtest` runner）

```
["loadtest", "-t", <duration_s>, "-c", <concurrency>, "--cores", "1", <完整绝对 URL>, "-m", <METHOD>]
  可依次跟：["--rps", <rps>]  ["-k"]  ["-d", <timeout_s×1000>]
```

- 三组可选参数**按上表顺序**出现，**至多各一次**；
- URL = `base_url`（**去掉尾部 `/`**）+ `target` 的路径（以 `/` 开头）；
- 方法 = `target` 的方法（**大写**），若 `args.method` 存在则**用它**（**大写**）；
- ⚠️ **本 REQ 不执行该命令** ⇒ 参数顺序对工具的**可接受性**属 B 阶段（REQ-013）验证范围；
  本 REQ 保证**形态正确、参数名真实存在**（PROBE-FACTS C2）。

#### F4.2 `args` 的**已知键白名单**（白名单之外 ⇒ **拒绝**，rc=1 + 点名）

| `runner` | 允许的 `args` 键 |
|---|---|
| `loadtest` | `rps` / `keepalive` / `timeout_s` / `method` |
| `python` | `command`（见 F5） |

⚠️ **跨 runner 的键同样拒绝**（`loadtest` 场景里的 `command`、`python` 场景里的 `rps` …）
⇒ 键的含义是「这个 runner 认不认」，不是「模型里有没有」。

### F5 `python` runner（裁定 G6）

`tool.runner == "python"` ⇒ **必须**由 `args` 显式声明完整命令，否则 **rc=1** 并点名缺哪个键。

1. `args.command` 必须是**完整 argv 数组**（**非空字符串数组**）。
   ⚠️ **不许**是字符串命令（字符串要分词 ⇒ 分词歧义 ⇒ 不接受）⇒ 判 rc=1。
2. 命令里**允许**出现占位符 `{duration_s}` / `{concurrency}`，**必须**被该段的取值替换；
   出现**其它** `{...}` 占位符 ⇒ rc=1（点名）。
3. 计划里该场景的 `invocations[].argv`：
   - 以自陈命令（占位符替换后）为**前缀**；
   - **含有**恰好等于 `String(duration_s)` 与 `String(concurrency)` 的元素；
   - **不得**残留占位符；
   - 该场景有 ≥2 段时，各条 `argv` **互不相同**（多段保真）。

⚠️ **不许**为 `python` runner 编造一条默认命令 —— 没有事实支撑的命令 = 凭空造。

### F6 写入纪律（沿用 REQ-009 的硬约束）

| # | 口径 |
|---|---|
| 1 | **只写** `<out-dir>/test-assets/load/plans/` |
| 2 | **先校验、后建目录**：输入非法 ⇒ **`plans/` 一个都不许出现**（**0 字节的空目录也算存在**） |
| 3 | **产物已存在 ⇒ 报错退出，不覆盖**（判的是 **`plans/` 目录本身**，不是整个 `test-assets/load/` —— 因为读入侧本来就有 `scenarios/` 与 `suites/`） |
| 4 | **幂等**：同一输入两次跑（两个不同项目根）⇒ 两份 `plans/` **逐字相同**（**不含**生成时间戳 / 随机 id / 宿主路径） |
| 5 | **输入只读**：模型 / 套件 / 环境文件一律不改写 |

### F7 诚实性

| # | 红线 | 机器可读的载体 |
|---|---|---|
| 1 | **不得把「未压测」写成「已通过」** | 计划里**不得**出现任何压测结论键（`status`/`result`/`verdict`/`executed`/`passed`/`outcome`/`conclusion`），**任意层级**都不得 |
| 2 | **不得**出现「已压测/已达标/已通过/压测结果」这类表述 | 同上（字符串值与键名都扫） |
| 3 | **没有指标来源 ⇒ 不写阈值** | `thresholds_status == "not_provided"` ⇒ **无** `thresholds` 键、**无** `thresholds_source` 键 |
| 4 | **缺口必须显式** | `not_provided` ⇒ **必须**留 `topic == "thresholds"` 的未决问题；无对应用例 ⇒ **必须**留 `topic == "coverage"` 的未决问题 |
| 5 | **零请求** | 跑完不得有任何 HTTP 调用（**桩服务请求计数 == 0**）；不得有执行痕迹字段；不得出现 `runs`/`evidence`/`.test-artifacts` |

⚠️ **未决问题的**措辞**由实现方自定**（契约只要求「非空 + 主题正确」）；
但**主题**与**条数**必须对得上（`not_provided` 必有 `thresholds` 主题，`provided` 必无）。

### F8 校验器

```
node skills/load-profile/scripts/check-load-run.mjs <项目根>
```

- 复核 `plans/*.json` 与 `scenarios/` / `suites/` **一致**（条数、顺序、`argv` 参数与模型逐字对得上）；
- 复核无结论键、无半份产物、三层字段集封闭；
- 退出码同 F1（`0` 通过 / `1` 校验失败 / `2` 用法错误）。

⚠️ **校验器必须有行为护栏**：验收门会**实跑**它，并验证「篡改计划 ⇒ 它判红（rc=1）」——
**只查「存在且非空 + `node --check` 通过」不算**（REQ-011 的 `check-plan.mjs` 从未被门执行过 ⇒
改坏了不会被红 ⇒ 那是遗留项，本 REQ 不许重犯）。

### F9 交付物形状与追溯件

```
skills/load-profile/
├── SKILL.md                       # ⚠️ 既有文件：逐字未改（指纹见 acceptance.md §0.8）
├── skill-meta.json                # ⚠️ 既有文件：逐字未改
├── references/
│   ├── load-context-schema.md     # ⚠️ 既有文件：逐字未改
│   ├── load-scenario-format.md    # ⚠️ 既有文件：逐字未改
│   ├── profile-rules.md           # ⚠️ 既有文件：逐字未改
│   └── runner-adapters.md         # 【新增】适配契约：参数映射表 / runner 形态 / 边界
└── scripts/
    ├── make-load-profile.mjs      # ⚠️ 既有文件：逐字未改
    ├── check-load-profile.mjs     # ⚠️ 既有文件：逐字未改
    ├── plan-load-run.mjs          # 【新增】主入口（shebang + 755 + node --check）
    ├── check-load-run.mjs         # 【新增】校验器（shebang + 755 + node --check）
    └── lib/                       # 既有 7 个 .mjs 逐字未改；【新增】模块按需（零第三方依赖）
```

追溯件（**四件套**）：`feature-meta/load-runner/{status.md, traceability.md, verification-report.md, manifest.json}`。

⚠️ **为什么是新子目录**：REQ-009 的门判 `feature-meta/load-profile/` 四件套的
`manifest.json` 的 `req` 必须是 `REQ-009`、且 `traceability.md` 的编号集合必须等于 REQ-009 的判据集合
⇒ **改写它就会让 REQ-009 的门判红** ⇒ 本 REQ 的追溯件**另起** `feature-meta/load-runner/`。

---

## 3. 夹具规格（判据的公共前置，详见 `acceptance.md` §0）

> 本节是**摘要**；逐字内容以 `acceptance.md` §0 为准。

### 3.1 压测上下文（**来源**，入口不读）

沿用 REQ-009 的四容量目标形态（订单服务 `order-api`；环境 `local` / `staging`）：

| `id` | `name` | `target` | `environment` | `profile` | 阈值来源 | `tool.runner` | `args` |
|---|---|---|---|---|---|---|---|
| WL-001 | checkout | `POST /api/v1/checkout` | local | `ramp-up`：`[60s@10c, 120s@20c]` | 有 | `loadtest` | `{rps:100, keepalive:true, timeout_s:10}` |
| WL-002 | order-query | `GET /api/v1/orders` | local | `constant`：`[300s@5c]` | **无** | `loadtest` | 无 |
| WL-003 | checkout-staging | `POST /api/v1/checkout` | staging | `spike`：`[30s@50c]` | 有 | **`python`** | `{command:[...]}` |
| WL-004 | health-check | `GET /api/v1/health` | local | `soak`：`[600s@2c]` | 有 | `loadtest` | 无 |

### 3.2 已有 load 模型（**入口真正读的东西**）

- `test-assets/load/scenarios/`：**4 个**场景本体（`checkout` / `order-query` / `checkout-staging` / `health-check`）；
- `test-assets/load/suites/LOAD-001-checkout/`：引用 **3 个**场景（local）+ `suite.json`；
- `test-assets/load/suites/LOAD-002-checkout-staging/`：引用 **1 个**场景（staging）+ `suite.json`。

⚠️ 两个套件的 `tool.runner` **分别是** `loadtest` 与 `python` ⇒ 覆盖两种 runner 形态。
⚠️ `python` 那个套件**带** `args.command`；另备一份**不带**的非法变体（V9）与一份**字符串**形态的非法变体（V9b）。

### 3.3 环境与项目根

- `test-assets/environments/{_schema,local,staging}.json`：`local` / `staging` 的 `base_url`
  指向验收脚本启动的**两个本地桩服务**（端口 `<P1>` / `<P2>`）⇒ **零请求**可被计数证实；
- `test-assets/cycles/{index.json,R1-REQ-012/cycle.json}` + `.gitignore`（含 `.test-artifacts/`）
  —— 上游 `verify-layout.mjs` 的前置条件，**必须**预置。

### 3.4 期望计划产物

```
<项目根>/test-assets/load/plans/
├── LOAD-001-checkout.json          # 3 个场景条目（checkout / order-query / health-check）
└── LOAD-002-checkout-staging.json  # 1 个场景条目（checkout-staging，python runner）
```

逐条真值见 `acceptance.md` §0.6（基线真值表）。

---

## 4. 明确不做的事（**不许越界**）

1. **不发任何请求**（不 spawn 压测工具、不联网、不打桩、不执行 `python` 自陈命令）；
2. **不装工具**（`loadtest@8.2.1` 由 `qa-toolchain` 管）；
3. **不改** REQ-009 的既有 14 个文件的内容；
4. **不改** `test-execute`（`load` 仍是 `not_implemented`）；
5. **不做阈值判定**（阈值可携带，**绝不产出结论**）；
6. **不写** `cases.json`、不派生用例；
7. **不新增** skill 目录；
8. **不要求** `loadtest` 真能跑（那是 B 阶段的事）—— 但也**不许**在交付物里声称「已验证压测可跑」
   （那是不存在的事实）。

---

## 5. 验收

见 `acceptance.md`（**29 条**，AC-001 ~ AC-029，**7 组**）。
门：`verify-acceptance.sh`（三态 PASS/FAIL/不可判定；sha 钉版；变异体套件；退出码 0/1/2）。
