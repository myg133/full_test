# REQ-009 —— 压测能力域：`load-profile` skill（负载模型 + runner 适配，第 8 个 skill）

> 本文件是**需求契约正文**。验收判据见 `acceptance.md`（AC-001 ~ AC-029，29 条）。
> 决策记录见 `decisions.md`（D127 ~ D155，29 条）。验收门见 `verify-acceptance.sh`。

---

## 0. 背景与边界

### 0.1 缺口具体长什么样

当前包里有 7 个 skill（`test-case-design` / `test-execute` / `qa-toolchain` / `regression-plan` /
`test-report` / `defect-verify` / `security-plan`），**没有**做压测**规划**的能力：

- `test-case-design` 的维度库有 `performance` / `stress`（REQ-006 交付），但那是**用例设计侧**
  （指标是否达标 / 压到极限时行为是否仍然正确），**不产出负载模型**；
- `test-execute` 的执行器清单里 `load` 在 `not_implemented` 里 ⇒ **不能发压**；
- 架构 §5.6 明写：`load-profile` skill「**生成负载模型 → 由执行器适配**」，
  `load-scenario.json` 加一个 `runner` 字段（`loadtest` / `python`）区分即可，**skill 本身不绑定工具**。

⇒ 本 REQ 补上这一段：**容量目标 → 负载模型 → 压测套件（规划侧产物）**。

### 0.2 本 REQ 只负责**规划**，不负责**执行**

- `skills/test-execute/executors/index.json` 的 `not_implemented` = `["ui", "load", "security"]`
  ⇒ **`load` 执行器未实现**；
- ⇒ 本 REQ **不发压**、不统计 TTFT/TPS、不判定容量拐点；那是**执行侧后续 REQ**；
- ⇒ 本 REQ **不要求** `run-suite.mjs --dry-run` 跑通（`load` 执行器未实现 ⇒ 必然抛错 ⇒
  写进判据就是**永远不可满足的假判据**）。

### 0.3 交付边界（不许越界）

| # | 边界 | 说明 |
|---|---|---|
| 1 | **只新增 `skills/load-profile/`** | 不改 `test-execute`，不改既有 7 个 skill 的任何文件 |
| 2 | `skill-meta.json` 的 `requires` | **恰为** `{test-case-design: ">=0.1.0", qa-toolchain: ">=0.1.0"}`，**不含** `test-execute`（架构 §8：REQ-002.9 依赖 002.4 = 工具链） |
| 3 | 包内根 `feature-meta/manifest.json` | **逐字未动**（仍是 REQ-006 原样）；本 REQ 的追溯件写进 `feature-meta/load-profile/` 子目录 |
| 4 | **写入范围** | 只写 `<out-dir>/test-assets/load/`；**不写** `test-assets/environments/`（环境是**别人的**）、不写 `test-assets/cycles/`、不改输入 |
| 5 | **工具边界** | **不装工具**（`loadtest` 由 `qa-toolchain` 管，架构 §5.5 声明 `required_by: ["REQ-002.9"]`）、**不执行 runner**、**不联网** |
| 6 | **不造用例** | 压测套件**不写 `cases.json`**；用例设计归 REQ-006（架构 §2.3 L77：压测用例**不是**「步骤 → 预期」形态） |
| 7 | **不扩方法库** | 方法库（`methods.json`）归 `test-case-design` 管辖；本 REQ **不新增**压测方法（库里没有压测方法） |

---

## 1. 目标

交付一个 **`load-profile` skill**：读一份**压测上下文**（容量目标 + 负载画像 + 阈值及其来源）
与一份**可选**的功能用例集，产出

1. **负载模型本体**：`test-assets/load/scenarios/<场景>.json`（字段集封闭）；
2. **压测套件**：`test-assets/load/suites/LOAD-<编号>-<短名>/{scenario.json, suite.json}`
   —— 其中套件级 `scenario.json` 是**引用件**，本体在 `scenarios/`（架构 §2.2 目录树）；
3. **压测计划清单**：`test-assets/load/report.json`（套件 ↔ 场景映射 + 未决问题）。

并且保证三件事：

- **可被上游加载层消费**（上游 `loadSuite()` 真实调用不抛错；上游 `verify-layout.mjs` 对该套件
  的判定行全 `[OK]`）；
- **诚实**：没有指标来源就**不写阈值**，并留下未决问题；**不把「未压测」写成「已通过」**；
- **可追溯**：每个场景都能追回它的容量目标、需求条目与功能用例。

---

## 2. 功能项 F1~F8

### F1 输入契约

#### F1.1 命令行

```
node skills/load-profile/scripts/make-load-profile.mjs \
  --context <压测上下文.json> \
  [--cases <功能用例集.json>] \
  --out-dir <项目根>
```

| 参数 | 必填 | 说明 |
|---|---|---|
| `--context` | 是 | 压测上下文 JSON（字段集见 F1.2） |
| `--cases` | 否 | 功能用例集（cases.json v2），用于**链路存在性对账**（F4.3） |
| `--out-dir` | 是 | 项目根；产物写到 `<out-dir>/test-assets/load/` |

**用法错 vs 输入非法（两层，退出码不同）**：

| 情形 | 退出码 | 说明 |
|---|---|---|
| 参数缺失 / 未知参数 / `--out-dir` 指向的文件 | **2** | **用法错** |
| 上下文 JSON 不存在 / 不是合法 JSON / 字段集非法 / 枚举越界 / 引用悬空 | **1** | **输入非法** |
| 成功 | **0** | |

⚠️ 输入非法时**不得留下半份产物**（`test-assets/load/` 不得出现 —— 存在性判定，0 字节也算）。

#### F1.2 压测上下文 JSON（顶层字段集**封闭 5 个**）

| 字段 | 类型 | 必填 | 约束 |
|---|---|---|---|
| `schema_version` | number | 是 | 必须 `== 1` |
| `service` | object | 是 | 封闭 2：`name`（非空 string）、`description`（string，可选） |
| `environments` | array | 是 | ≥1 项；元素封闭 2：`name`（`^[a-z0-9][a-z0-9-]*$`）、`base_url`（非空 string） |
| `workloads` | array | 是 | ≥1 项；元素见 F1.3 |
| `open_questions` | array | 否 | 默认 `[]`；元素封闭 3（见 F2.4） |

**顶层出现表外字段 ⇒ 输入非法（rc=1）**（如 `load_scenario` / `cases` / `thresholds` 直接写在顶层）。

#### F1.3 workload 条目（字段集**封闭 10 个**）

| 字段 | 类型 | 必填 | 约束 |
|---|---|---|---|
| `id` | string | 是 | `^WL-\d{3}$`；**文件内唯一** |
| `name` | string | 是 | `^[a-z0-9][a-z0-9-]*$`（= 场景短名 = 场景文件名去扩展名） |
| `target` | string | 是 | `^(GET\|POST\|PUT\|DELETE\|PATCH\|HEAD\|OPTIONS) /.*$`（方法 + 空格 + 路径） |
| `environment` | string | 是 | 必须在 `environments[]` 内（**不悬空**） |
| `profile` | object | 是 | 封闭 2（见 F1.5） |
| `thresholds` | object | **条件** | 见 F1.4 |
| `thresholds_source` | string | **条件** | 见 F1.4 |
| `tool` | object | 是 | 封闭 2（见 F1.6） |
| `args` | object | 否 | 开放键值，原样透传到产物 |
| `requirement_refs` | array | 否 | string 数组（需求条目引用），默认 `[]` |

**id 重复 / id 格式错 / `name` 格式错 / `target` 格式错 ⇒ 输入非法（rc=1），且 stderr 点名坏点。**

#### F1.4 `thresholds` 与 `thresholds_source` 的**成对规则**（不得凭空拍阈值）

| 情形 | 判定 |
|---|---|
| 两个都**不存在** | 合法 ⇒ 该容量目标**没有指标来源** ⇒ 产物按 F2.3 走 `not_provided` 分支 |
| 两个都**存在** | 合法 ⇒ `thresholds_source` 必须是非空 string；`thresholds` 必须 ≥1 键，键 ∈ 白名单 |
| **只给一个** | **输入非法（rc=1）** —— 「有阈值却没来源」是凭空拍；「有来源却没阈值」是自相矛盾 |

`thresholds` 的键白名单（**封闭**）：`p50_latency_ms` / `p95_latency_ms` / `p99_latency_ms` /
`error_rate` / `throughput_rps` / `max_concurrency`。
值类型：延迟 / 吞吐 / 并发 = number ≥ 0；`error_rate` = number 且 ∈ `[0, 1]`。
**键之外**的键 ⇒ 输入非法（rc=1）。

#### F1.5 `profile`（封闭 2）

- `type` ∈ `constant` / `ramp-up` / `ramp-down` / `spike` / `soak`（**5 个**）；
- `steps`：数组，≥1 项；每项封闭 2：`duration_s`（整数 ≥ 1）、`concurrency`（整数 ≥ 1）。

#### F1.6 `tool`（封闭 2）

- `runner` ∈ `loadtest` / `python`（架构 §5.6 明写这两个取值）；
- `runtime` ∈ `bun` / `python` / `node`。

`runner` 只是**声明**用哪个 runner —— 本 REQ **不装**它、**不跑**它、**不联网**（F7）。

#### F1.7 上下文里的 `environments[]` 是「**目标环境清单**」，不是「要写的环境文件」

`load-profile` 的写入范围只有 `test-assets/load/`（§0.3 第 4 条）⇒ **不创建**环境文件。
产物 `suite.json` 的 `environment` 指向的环境文件由**项目**提供。

⚠️ **「被引用的环境文件存在」是 F6 校验层判据的【前置条件】**（不是实现违约，也不是「集成条件问题」
这种含糊说法）：

- 前置条件**不满足**（环境文件不存在）⇒ F6 校验层那条判**不可判定**（前置不满足），
  **不算实现违约、不判 FAIL**；
- 前置条件**满足**但上游对该套件报了**其它**问题 ⇒ **判 FAIL**（那才是本 REQ 的责任）。

⇒ 门在跑上游校验器**之前**先自己核「被 workload 引用的每个环境文件是否都存在」；
不存在 ⇒ 走不可判定分支。判据正文见 F6 与 `acceptance.md` 的 AC-019（三分支写死）。

---

### F2 负载模型本体（`test-assets/load/scenarios/<场景>.json`）

#### F2.1 顶层字段集**封闭 14 个**

| # | 字段 | 类型 | 必填 | 约束 |
|---|---|---|---|---|
| 1 | `schema_version` | number | 是 | `== 1` |
| 2 | `id` | string | 是 | `^WL-\d{3}$`；与输入 workload 的 `id` **逐字相等** |
| 3 | `name` | string | 是 | `^[a-z0-9][a-z0-9-]*$`；**等于文件名去扩展名** |
| 4 | `service` | string | 是 | = 输入 `service.name` |
| 5 | `target` | string | 是 | 逐字等于输入 workload 的 `target` |
| 6 | `environment` | string | 是 | 逐字等于输入 workload 的 `environment` |
| 7 | `profile` | object | 是 | 封闭 2；**逐字等于**输入 workload 的 `profile` |
| 8 | `thresholds` | object | **条件** | 有来源时存在；**逐字等于**输入 |
| 9 | `thresholds_source` | string | **条件** | 有来源时存在；**逐字等于**输入 |
| 10 | `thresholds_status` | string | 是 | ∈ `provided` / `not_provided` |
| 11 | `tool` | object | 是 | 封闭 2；**逐字等于**输入 |
| 12 | `args` | object | 否 | **逐字等于**输入 workload 的 `args`（输入没有则不写这个键） |
| 13 | `traceability` | object | 是 | 封闭 3：`workload_id` / `requirement_refs` / `case_refs` |
| 14 | `open_questions` | array | 是 | 数组（可为空数组） |

**表外字段一律违规**（如 `meta` / `status` / `result` / `verdict` / `executed` / `passed`）。

⚠️ **产物里的枚举取值也必须合法**（`profile.type` ∈ 5 值 / `tool.runner` ∈ 2 值 /
`tool.runtime` ∈ 3 值 / `thresholds` 键 ∈ 6 值白名单）—— 输入层被绕过时，产物层仍要拦
（AC-008 的产物侧条款）。

#### F2.2 `traceability`（封闭 3）

- `workload_id`：逐字等于输入 workload 的 `id`；
- `requirement_refs`：string 数组，逐字等于输入 workload 的 `requirement_refs`（缺省则 `[]`）；
- `case_refs`：string 数组 —— 按 F4.3 的对账规则算出的功能用例 id 集合（**恰等**，不多不少）。

#### F2.3 阈值二态（诚实性的机器可读载体）

| `thresholds_status` | 条件 | 必须 |
|---|---|---|
| `provided` | 输入有 `thresholds` + `thresholds_source` | `thresholds` 与 `thresholds_source` **两个键都存在**且**逐字等于**输入；`open_questions` 里**不得**有 `topic == "thresholds"` 的条目 |
| `not_provided` | 输入**没有**阈值 | **不得**存在 `thresholds` 键、**不得**存在 `thresholds_source` 键；`open_questions` 里**必须**有 ≥1 条 `topic == "thresholds"` |

⇒ 「没有指标来源就不拍阈值」是**结构性**保证（键的有无），不是一句承诺。

#### F2.4 未决问题条目（封闭 3）

| 字段 | 约束 |
|---|---|
| `id` | `^OQ-\d{3}$`；**文件内唯一** |
| `topic` | ∈ `thresholds` / `coverage` / `runner` / `other` |
| `question` | 非空 string |

#### F2.5 场景文件名约定

`scenarios/<name>.json`，`<name>` 合 `^[a-z0-9][a-z0-9-]*$`，
且**文件名去掉 `.json` 必须等于**文件内的 `name` 字段。

---

### F3 压测套件落位（`test-assets/load/suites/LOAD-<编号>-<短名>/`）

#### F3.1 套件划分规则（**多对一**：多个场景 → 一个套件）

1. 按 `environments[]` 的**出现顺序**给每个环境分配套件编号 `001`、`002`、…；
2. **同一 `environment` 的所有 workload 归入同一个套件**；
3. 套件目录名 = `LOAD-<三位编号>-<该套件第一个场景的 name>`；
4. 一个场景只属于**一个**套件（一个 workload 不重复出现在多个套件里）。

⚠️ 套件目录名规则（`LOAD-<编号>-<短名>`）**上游不校验**（上游只校验 `suite.json` 的 `suite`
字段 == 所在目录名）⇒ **由本 REQ 的门判**。

#### F3.2 套件级 `scenario.json`（**引用件**，顶层封闭 3）

| 字段 | 类型 | 约束 |
|---|---|---|
| `schema_version` | number | `== 1` |
| `suite` | string | **等于**所在目录名 |
| `scenarios` | array | ≥1 项；元素封闭 3（见下） |

元素（封闭 3）：

| 字段 | 类型 | 约束 |
|---|---|---|
| `path` | string | 相对**套件目录**解析的路径，必须指向**真实存在**的 `scenarios/<name>.json` |
| `id` | string | 必须**等于**本体文件的 `id` |
| `name` | string | 必须**等于**本体文件的 `name` |

⇒ `id` / `name` 两个快照字段是**防漂移**用的：本体改了身份而引用没改 ⇒ 漂移 ⇒ 判红。

⚠️ `load_scenario` 这个名字**不能**出现在 `suite.json` 里（上游 `suite.json` 顶层字段集封闭 9 个），
但**可以**出现在 `scenario.json` 里 —— 本 REQ 选用的引用字段名是 `scenarios`（数组），
**不是** `load_scenario`（见 `decisions.md` D138）。

#### F3.3 `suite.json`（顶层 ⊆ 上游 9 个允许字段）

| 字段 | 值 |
|---|---|
| `suite` | **等于**所在目录名 |
| `requirement` | 非空 string（需求编号，如 `REQ-009`） |
| `scope` | `load` |
| `environment` | 该套件的 environment 名 |
| `cases_file` | `scenario.json`（相对套件目录） |
| `executor` | `load` |
| `base_url_from` / `tags` / `report` | 可选 |

⚠️ **出现上游 9 个以外的字段（含 `load_scenario`）⇒ 违规**（上游 `verify-layout.mjs`
对 `suite.json` 的顶层字段集是封闭的，**上游会拦**）。
⚠️ `scope` / `executor` 的**配对关系上游不强制**（上游只各自校验枚举合法性 ⇒
`executor: "api"` 上游**放行**）⇒ **`executor` 必须是 `load` 这条由本 REQ 的门判**。

---

### F4 引用与本体的对账

#### F4.1 引用可解析

引用件里每个 `path` 解析后必须**真实存在**，且落在 `test-assets/load/scenarios/` 下。

#### F4.2 引用与本体不得漂移

引用件的 `id` / `name` 必须**逐字等于**本体文件里的 `id` / `name`。

#### F4.3 与功能用例集的**链路存在性**对账（只对账，**不派生用例**）

对每个 workload：

1. 取输入用例集 `cases[].steps[].action`；
2. 把每个 action **归一化**：取「方法 + 空格 + 路径」，并**删掉路径中所有 `{...}` 占位符段**
   （如 `GET /api/v1/orders/{id}` → `GET /api/v1/orders`）；
3. 归一化结果**等于** workload 的 `target` 的用例 id，**按用例出现顺序去重**后即 `case_refs`；
4. `case_refs` **必须恰等**该集合（多一个、少一个都违规）；
5. 若 `case_refs` 为空 ⇒ 该场景的 `open_questions` **必须**有 ≥1 条 `topic == "coverage"`
   （说明「该负载目标在功能用例集里没有对应用例」）。

⇒ 对账**只回答「这条被压链路在功能用例集里有没有对应用例」**，**不派生任何用例**，
**不写 `cases.json`**（架构 §2.3 L77：压测用例不是「步骤 → 预期」形态，硬套进 `cases.json` 会让它变形）。

#### F4.4 场景模型 ↔ 套件的**双向覆盖完整性**

1. 每个 workload（容量目标）**恰好**被一个套件引用；
2. 每个 load 套件**至少**引用一个场景模型；
3. 每个场景模型**至少**被一个套件引用（**不得有孤儿场景**）；
4. **不得有孤儿套件**（引用了不存在的场景模型）。

⚠️ 本条与 **F4.3**（内容契约 / 对账口径）、与套件划分规则（F3.1）**分工不同**：
F4.3 管「引用与本体对不对」，F4.4 管「**覆盖完整不完整**」。

---

### F5 诚实性红线

| # | 红线 | 机器可读的载体 |
|---|---|---|
| 1 | **没有指标来源 ⇒ 不写阈值** | `thresholds_status == "not_provided"` ⇒ 无 `thresholds` 键、无 `thresholds_source` 键（F2.3） |
| 2 | **不得凭空拍阈值** | 有来源时 `thresholds` **逐字等于**输入；输入没有的键不得出现在产物里 |
| 3 | **不得把「未压测」写成「已通过」** | 产物**不得**出现任何压测结论字段（`status` / `result` / `verdict` / `executed` / `passed`）—— 顶层字段集封闭（F2.1）已覆盖 |
| 4 | **缺口必须显式** | 无来源 / 无对应用例 ⇒ 必须留未决问题（F2.4） |

---

### F6 可被消费（判到**哪一层**，写死）

| 层 | 判法 | 谁来判 |
|---|---|---|
| **加载层** | 上游 `loadSuite()` **真实调用**解析该 load 套件的 `suite.json` ⇒ **不抛错** | 门（单独进程实跑上游加载层，拿真实退出码） |
| **校验层** | 上游 `verify-layout.mjs` 的输出里，**该 load 套件的 `suite.json` 路径相关的判定行必须全是 `[OK]`、不得出现任何以该路径开头的 `[FAIL]`** | 门（按相对路径 grep 真实输出） |

#### F6.1 校验层判据的**三分支**（写死，不许笼统写「上游说 OK 就算 OK」）

**前置条件**：`<out-dir>/test-assets/environments/<每个被 workload 引用的环境名>.json` **都存在**
（夹具必须预置，见 `acceptance.md` §0.4）。

| 情形 | 判定 | 理由归属 |
|---|---|---|
| ① **被引用的环境文件不存在**（前置条件**不满足**） | 该判据判 **不可判定**（前置不满足）—— **不算实现违约、不判 FAIL** | 环境文件**不由本 REQ 写**（写入范围只有 `test-assets/load/`），缺它是**前置条件**没满足 |
| ② 环境文件存在，但上游对该套件报了**其它**问题（字段缺失 / 枚举非法 / `cases_file` 指向的文件不存在 / `suite` 字段与目录名不一致 / `cases_file` 越出项目根 …） | **判 FAIL** | 这些才是本 REQ 的责任 |
| ③ 环境文件存在，上游对该套件**全 `[OK]`** | **判 PASS** | — |

⇒ 门在跑上游校验器**之前**先自己核「被 workload 引用的每个环境文件是否都存在」；
不存在 ⇒ 直接走分支 ①（**不**因为上游报 `[FAIL]` 而判红）。

⚠️ **上游模块缺失 ⇒ 判【不可判定】**（不是实现违约，不可判定 ≠ 通过 ⇒ 退出码仍非 0）：
被验包里没装上游那个 skill（`verify-layout.mjs` / `suite-loader.mjs`）时，AC-004 / AC-018 判**不可判定**。

⚠️ **不判**「`verify-layout.mjs` 对整个项目根 rc=0」—— 上游整体 rc 还额外要求
`environments/_schema.json` 存在、环境 `credentials` 齐全、`test-assets/cycles/`（`cycle.json` +
`index.json`）、`.gitignore` 忽略 `.test-artifacts/` ⇒ 那些**不在本 REQ 的写入范围**内
⇒ 拿整体 rc 当判据 = **永远判红的假判据**。

⚠️ **不判** `run-suite.mjs --dry-run` 跑通（`load` 执行器未实现 ⇒ 必然抛错）。
⚠️ **不判** `loadCases()` 能消费 `cases_file` —— 上游 `loadCases()` 硬要求 `doc.cases` 是数组
⇒ `scenario.json` **不能**做成 cases 形态（F4.3 同源）。

---

### F7 工具边界

- 产物里**只出现** `tool.runner` / `tool.runtime` 两个**声明**字段；
- **不装工具**（`loadtest@8.2.1` 由 `qa-toolchain` 装，架构 §5.5 已声明 `required_by: ["REQ-002.9"]`）；
- **不执行 runner**、**不联网**、不读环境里的工具；
- `runner` 取值必须落在 `{loadtest, python}` 内（架构 §5.6）。

---

### F8 幂等 / 只写自己的目录 / 不改输入

| # | 口径 |
|---|---|
| 1 | **幂等**：同一输入跑两次（两个不同 `--out-dir`）⇒ 两份产物**逐字相同**（产物**不含**生成时间戳字段 ⇒ 幂等就是逐字相同） |
| 2 | **只写自己的目录**：`<out-dir>` 下**除** `test-assets/load/` 以外的一切（文件集合与内容）**逐字未变** |
| 3 | **不改输入**：`--context` / `--cases` 指向的文件 sha256 跑前跑后**一致** |
| 4 | **产物已存在即报错**：`<out-dir>/test-assets/load/` 已存在（非空）⇒ **rc=1** 且**不覆盖**既有产物 |

---

## 3. 明确不做的事（**不许越界**）

1. **不发压**（不跑 runner、不统计 TTFT/TPS/吞吐、不判容量拐点）；
2. **不实现 `load` 执行器**（`test-execute/executors/index.json` 的 `not_implemented` 不动）；
3. **不写 `cases.json`**、不派生用例（用例设计归 REQ-006）；
4. **不扩方法库**（`methods.json` 里没有压测方法；产物里**不写** `method` 字段 ——
   若写了，则该方法号必须是方法库里**真实存在**的编号）；
5. **不创建/修改环境配置**、不改轮次状态（`cycle.json`）、不写 `feature-meta/manifest.json`；
6. **不碰 `test-execute` / `test-case-design` / 既有 7 个 skill 的任何文件**；
7. **不联网**、**不装工具**；
8. **不要求上游执行器能跑** —— `load` 执行器未实现 ⇒ `run-suite.mjs --dry-run` 必然抛错；
   **本 REQ 的门也不得要求它跑通**（门只实跑上游的**加载层**与**目录校验器**，两者都不碰执行器）。
   ⚠️ 该条的**外部可观测证据**写进 **AC-020 ④**：门跑完之后 `<out-dir>` 下**不得**出现
   `runs` / `evidence` 目录或文件（执行器的产物落点）—— 落点是**文件系统**，不是「门源码长什么样」。
   ⚠️ 另有**需求方收口核对项**（不占判据条数）：需求方在审门阶段用**反向探针**实跑 ——
   把 `executor`（或 `scope`）写成非 `load` 的套件喂给门，门**不得**因为
   「执行器未实现 / 执行器不存在」而报错或误判（见 `status.md` 的收口核对清单）。

---

## 4. 交付物形状

```
skills/load-profile/
├── SKILL.md                       # frontmatter: name: load-profile + 非空 description
├── skill-meta.json                # {name, version, requires:{test-case-design, qa-toolchain}}
├── references/
│   ├── load-context-schema.md     # 上下文 JSON 字段集
│   ├── load-scenario-format.md    # 负载模型本体 + 引用件的字段集
│   └── profile-rules.md           # 负载画像 / 阈值 / 对账规则
└── scripts/
    ├── make-load-profile.mjs      # 入口（可执行、shebang、node --check 通过）
    ├── check-load-profile.mjs     # 自检脚本（可执行、shebang、node --check 通过）
    └── lib/                       # ≥3 个非空 .mjs 模块
```

包内根 `feature-meta/manifest.json` **逐字未动**；本 REQ 的追溯件写进 `feature-meta/load-profile/`
（`status.md` / `traceability.md` / `verification-report.md` / `manifest.json` 四件套）。

---

## 5. 验收

见 `acceptance.md`（29 条，AC-001 ~ AC-029，7 组）。
门：`verify-acceptance.sh`（三态 PASS/FAIL/不可判定；sha 钉版；变异体套件；退出码 0/1/2）。
