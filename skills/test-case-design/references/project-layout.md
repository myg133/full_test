# 测试资产目录契约（project-layout）

本文件是**契约**，不是说明材料。读者是要在本项目里摆放测试资产的执行者：你按这里的规则摆放文件，校验脚本 `scripts/verify-layout.mjs`（本 skill 目录内）按这里的规则判定通过与否。凡是本文件没写的自由项，校验器一律不拦；凡是本文件写了"必须"的，校验器一定会拦。

校验器在本 skill 目录内：`node scripts/verify-layout.mjs [project-root]`，其中 `scripts/` 相对 skill 目录；在本仓库内等价于 `node skills/test-case-design/scripts/verify-layout.mjs [project-root]`。`project-root` 指向**被校验的项目根**，缺省取当前工作目录。退出码 `0` = 全部通过，`1` = 存在违规，`2` = 调用方式错误。

---

## 1. 目录结构与职责

```text
<project-root>/
├── test-assets/                    # 测试资产根目录（进 Git）
│   ├── README.md                   # 目录契约说明（人读）
│   ├── environments/               # 环境定义
│   │   ├── _schema.json            # 环境配置 schema（进 Git）
│   │   ├── local.json
│   │   └── staging.json
│   ├── suites/                     # 功能测试套件（按需求组织）
│   │   └── REQ-001-coupon/
│   │       ├── cases.json          # 用例集（REQ-002A 的产物格式）
│   │       └── suite.json          # 执行配置
│   ├── security/                   # 安全测试（按威胁面组织）
│   │   ├── threat-model.json
│   │   ├── matrix.json
│   │   └── suites/
│   │       └── SEC-001-authz/
│   │           ├── cases.json
│   │           └── suite.json
│   ├── load/                       # 压测（按容量目标组织）
│   │   ├── scenarios/
│   │   │   └── checkout.json
│   │   └── suites/
│   │       └── LOAD-001-checkout/
│   │           ├── scenario.json
│   │           └── suite.json
│   ├── contracts/                  # 接口契约 / mock 定义
│   └── cycles/                     # 轮次状态
│       ├── index.json
│       └── R1-REQ-001/
│           └── cycle.json
├── .tools/                         # 工具链（契约见 REQ-0024）
└── .test-artifacts/                # 执行产物（不进 Git）
```

| 目录 / 文件 | 职责 | 必备性 |
|---|---|---|
| `test-assets/` | 一切测试资产的根。执行者只在这里放"要进 Git 的测试资产" | 必备，缺失直接 FAIL |
| `test-assets/environments/` | 环境定义：`base_url`、超时、凭证引用、请求头、fixture 清单。环境名 = 文件名（不含 `.json`） | 必备，缺失直接 FAIL |
| `test-assets/environments/_schema.json` | 环境配置的 schema。它同时承担文档职责（字段说明写在 `description` 里） | 必备，缺失或不可解析直接 FAIL |
| `test-assets/suites/` | 功能测试套件，按需求编号分目录 | 可选（没有功能测试时允许不存在） |
| `test-assets/security/` | 安全测试资产：威胁模型 + 覆盖矩阵 + 套件 | 可选 |
| `test-assets/load/` | 压测资产：容量场景 + 套件 | 可选 |
| `test-assets/contracts/` | 接口契约、mock 定义 | 可选 |
| `test-assets/cycles/` | 轮次状态：每轮一个目录，内含 `cycle.json`；`index.json` 是全局视图 | 必备，缺失直接 FAIL |
| `.tools/` | 工具链（契约见 REQ-0024） | 可选，本契约不校验其内容 |
| `.test-artifacts/` | 执行产物落点：报告、日志、截图 | 目录本身可不存在，但**必须写进项目 `.gitignore`** |

**命名规则**

- 要进 Git 的资产一律用**可见名**：`test-assets/`、`environments/`、`suites/`、`cycle.json`。
- 纯本地产物用 `.` 前缀：`.test-artifacts/`、`.tools/`、`.local/`。
- 套件目录名 = 该目录 `suite.json` 的 `suite` 字段值，必须完全一致（大小写敏感）。
- 环境文件名 = 该文件 `name` 字段值，必须完全一致。
- 轮次目录名 = 该目录 `cycle.json` 的 `cycle_id` 字段值。

---

## 2. 三种 scope 的组织差异与共同点

### 共同点（不可协商）

1. **执行配置结构完全一致**：三种 scope 的 `suite.json` 字段集合、类型、含义都一样，只靠 `scope` 与 `executor` 两个字段区分。执行器外围逻辑必须能完全复用。
2. **共用环境定义**：三种 scope 都从 `test-assets/environments/` 取环境，`suite.json` 的 `environment` 指向环境名。
3. **共用轮次状态**：三种 scope 属于同一个轮次时，写在同一个 `cycle.json` 的 `scopes` 数组里；本轮不跑的 scope 写进 `scopes_skipped` 并给出理由。
4. **共用证据与产物落点**：所有执行产物落在 `.test-artifacts/` 下。
5. **`suite.json` 的顶层字段集是封闭的**：只允许 §3.3 字段表里的九个字段（`suite` / `requirement` / `scope` / `environment` / `cases_file` / `executor` / `base_url_from` / `tags` / `report`）。出现表外字段一律 FAIL，**包括 `load_scenario`、`threat_model` 这类 scope 专属字段**——scope 专属信息写在同目录的专属文件里，由 `cases_file` 指向或由执行器按 scope 约定推导。

### 差异

| scope | 套件位置 | 目录名约定 | 用例/场景文件 | executor | 附属资产 |
|---|---|---|---|---|---|
| `functional` | `test-assets/suites/<suite>/` | `REQ-<编号>-<短名>` | `cases.json` | `api` / `ui` | 无 |
| `security` | `test-assets/security/suites/<suite>/` | `SEC-<编号>-<短名>` | `cases.json` | `security` | `test-assets/security/threat-model.json`、`matrix.json`（威胁面级，套件级之上） |
| `load` | `test-assets/load/suites/<suite>/` | `LOAD-<编号>-<短名>` | `scenario.json` | `load` | `test-assets/load/scenarios/<场景>.json`（容量目标级） |

`scope` 与 `executor` 的常规配对：`functional`→`api`/`ui`，`security`→`security`，`load`→`load`。校验器只校验两者各自的枚举合法性，不强制配对关系；偏离常规配对时，在 `suite.json` 之外说明理由。

三种 scope 的 `cases_file` 指向的文件都必须真实存在——`load` 指向 `scenario.json`，同样是"相对套件目录"的文件。

---

## 3. 环境配置与执行配置的字段语义

### 3.1 `environments/_schema.json`（权威模板，直接复制）

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "测试环境配置",
  "type": "object",
  "required": ["name", "base_url", "timeout_ms", "credentials"],
  "additionalProperties": false,
  "properties": {
    "name": { "type": "string", "description": "环境标识，与文件名一致" },
    "base_url": { "type": "string", "description": "被测服务根地址" },
    "timeout_ms": { "type": "integer", "description": "单请求超时毫秒" },
    "retries": { "type": "integer", "description": "失败重试次数" },
    "credentials": {
      "type": "object",
      "description": "凭证引用，只允许环境变量名，禁止明文",
      "required": ["username_env"],
      "properties": {
        "username_env": { "type": "string", "description": "存放用户名的环境变量名" },
        "password_env": { "type": "string", "description": "存放密码的环境变量名" }
      },
      "additionalProperties": false
    },
    "headers": { "type": "object", "description": "附加请求头" },
    "verify_tls": { "type": "boolean", "description": "是否校验 TLS 证书" },
    "driver": { "type": "string", "enum": ["api", "mock"], "description": "用哪个执行器驱动跑这个环境（api = 真实 HTTP；mock = 内置离线桩服务）" },
    "data_fixtures": {
      "type": "array",
      "description": "执行前准备的数据集",
      "items": {
        "type": "object",
        "required": ["path"],
        "properties": {
          "path": { "type": "string", "description": "fixture 文件路径（相对项目根）" },
          "cleanup": { "type": "boolean", "description": "执行后是否清理" }
        }
      }
    }
  }
}
```

顶层 `additionalProperties: false` 是有意为之：顶层字段集合是封闭的（见下表），多出来的字段一律判为违规。校验器另有一份独立的顶层字段基线，即使项目把 schema 改松了，顶层多余字段照样会被拦下。

### 3.2 `environments/*.json` 字段语义

| 字段 | 类型 | 必填 | 语义与取值规则 |
|---|---|---|---|
| `name` | string | 是 | 环境标识。必须与文件名（不含 `.json`）完全一致（校验器会拦）；`suite.json` 的 `environment` 按这个名字引用 |
| `base_url` | string | 是 | 被测服务根地址。无尾斜杠要求，但同一环境的多个文件应保持一致 |
| `timeout_ms` | integer | 是 | 单请求超时毫秒。必须是整数；写字符串即违规 |
| `retries` | integer | 否 | 失败重试次数。缺省视为 0 |
| `credentials` | object | 是 | 凭证**引用**。必须含 `username_env`；只允许 `*_env` 字段 |
| `credentials.username_env` | string | 是 | 存放用户名的环境变量名 |
| `credentials.password_env` | string | 否 | 存放密码的环境变量名 |
| `headers` | object | 否 | 附加请求头。值可含 `${run_id}` 一类占位符，由执行器在运行时替换 |
| `verify_tls` | boolean | 否 | 是否校验 TLS 证书。本地自签环境常置 `false` |
| `driver` | string | 否 | 用哪个执行器驱动跑这个环境。枚举 `api`（真实 HTTP，打 `base_url`）/ `mock`（内置离线桩服务，地址由执行器自己起，不读 `base_url`）。不写则取 `suite.json` 的 `executor` |
| `data_fixtures` | array | 否 | 执行前准备的数据集。元素必含 `path`（相对项目根），可选 `cleanup` |

**凭证硬规则（不可协商）**

- `credentials` 下只允许 `*_env` 后缀的字段。出现 `password`、`token`、`secret`、`api_key` 之类字段 → 判为**明文凭证**，FAIL。
- 每个 `*_env` 字段的**值是环境变量名**，不是凭证本身。值必须匹配 `^[A-Z_][A-Z0-9_]*$`（大写字母或下划线开头）→ 否则判为**非法环境变量名**，FAIL。
- `password_env` 是合法字段名：它的值 `STAGING_PASS` 是环境变量名，不是密码。判断依据是**字段名是否以 `_env` 结尾**，不是字段名里有没有 "password"。
- 真实凭证值只允许出现在执行机的环境变量里，配置文件里只放变量名。

### 3.3 `suite.json` 字段语义

三种 scope 结构完全一致。

| 字段 | 类型 | 必填 | 语义与取值规则 |
|---|---|---|---|
| `suite` | string | 是 | 套件标识。必须与所在目录名完全一致 |
| `requirement` | string | 是 | 关联需求编号（如 `REQ-001`） |
| `scope` | string | 是 | 枚举 `functional` / `security` / `load` |
| `environment` | string | 是 | 环境名。必须在 `test-assets/environments/` 下有同名 `.json`，否则为悬空引用 |
| `cases_file` | string | 是 | 用例/场景文件路径，相对**本套件目录**。指向的文件必须存在，且不得越出项目根目录 |
| `executor` | string | 是 | 枚举 `api` / `ui` / `load` / `security` / `mock` |
| `base_url_from` | string | 否 | 指向环境配置的字段路径（如 `environment.base_url`）。不写则取环境配置的 `base_url` |
| `tags` | object | 否 | 标签过滤。`include` / `exclude` 均为字符串数组 |
| `report` | object | 否 | 报告产物配置 |
| `report.format` | string[] | 否 | 产物格式，如 `["html", "json"]` |
| `report.output_dir` | string | 否 | 产物目录。**必须以 `.test-artifacts/` 开头**，否则 FAIL |

`report` 整体可选；一旦出现 `report.output_dir`，就必须落在 `.test-artifacts/` 下。

**顶层字段集是封闭的**：上表九个字段构成 `suite.json` 的全部合法顶层字段。出现表外字段（尤其是 `load_scenario` / `threat_model` 这类 scope 专属字段）一律 FAIL（校验器会拦），见 §2.5 第 5 条。

---

## 4. 轮次状态机与阶段

### 4.1 轮次状态机

```text
planned ──▶ in_progress ──▶ completed
                │
                ├──▶ blocked ──▶ in_progress   （解除阻塞后回到进行中）
                └──▶ cancelled                   （本轮作废，不再恢复）
```

| 字段 | 枚举 | 语义 |
|---|---|---|
| `round` | `R1` / `R2` / `R3` | 轮次编号 |
| `round_type` | `new-requirement` / `regression` / `defect-verify` | 轮次类型 |
| `status` | `planned` / `in_progress` / `completed` / `blocked` / `cancelled` | 轮次状态 |
| `scopes[]` / `scopes_skipped[].scope` | `functional` / `security` / `load` | 本轮覆盖 / 跳过的范围 |

完整转移表、终态判定与推进器的用法见 `references/state-machine.md`。

### 4.2 `cycle.json` 字段表

`cycle.json` 是单个轮次的事实来源。字段如下（"校验器会拦"= `scripts/verify-layout.mjs` 一定会判 FAIL）：

| 字段 | 类型 | 必填 | 语义与取值规则 |
|---|---|---|---|
| `cycle_id` | string | 是 | 轮次标识。非空字符串；必须与所在轮次目录名完全一致（§1 命名规则，校验器会拦） |
| `requirement` | string | 是 | 关联需求编号（如 `REQ-001`）。非空字符串（校验器会拦） |
| `round` | string | 否 | 轮次编号。取值 `R1` / `R2` / `R3`，写了就必须合法（校验器会拦非法取值） |
| `round_type` | string | 否 | 轮次类型。取值 `new-requirement` / `regression` / `defect-verify`，写了就必须合法（校验器会拦非法取值） |
| `status` | string | 是 | 轮次当前状态。取值 `planned` / `in_progress` / `completed` / `blocked` / `cancelled`；**必须等于 `history` 最后一条的 `to`**（校验器会拦） |
| `scopes` | array | 否 | 本轮覆盖的范围。元素取值 `functional` / `security` / `load`，写了就必须合法（校验器会拦非法取值） |
| `scopes_skipped` | array | 否 | 本轮跳过的范围。元素为 `{scope, reason, at, by}`，**四个字段都必须是非空字符串**（校验器会拦）：`scope` 取值同 `scopes`；`reason` 是可被 review 发现的理由；`at` 是 ISO-8601 时间戳（什么时候跳过的）；`by` 是执行者标识（谁跳过的）。由 `scripts/cycle-state.mjs skip-scope` 写入 |
| `stages` | object | 否 | 阶段状态表。键为阶段名，值为 `{status, artifacts?, runs?}`（校验器会拦非法的阶段状态） |
| `stages.<name>.status` | string | 是（`stages` 存在时） | 阶段状态。取值 `pending` / `in_progress` / `done` / `blocked` / `skipped` |
| `stages.<name>.artifacts` | array | 否 | 该阶段的产物路径列表 |
| `stages.<name>.runs` | array | 否 | 该阶段记录过的**执行批次**（元素是一次执行的 run_id 字符串）。由 `scripts/cycle-state.mjs set-stage --run <run_id>` 写入；同一个 run_id 重复写入不产生重复项（幂等） |
| `history` | array | 是 | 状态变更留痕，**至少一条**；每条含 `at` / `from` / `to` / `by` 四个非空字符串（校验器会拦缺字段），其中 `from` 与 `to` 取值同 `status` 枚举（校验器会拦非法取值） |
| `trigger` | object | 否 | 触发来源，如 `{ "type": "requirement", "ref": "REQ-001" }` |

**状态不由手改**：轮次状态的推进、跳过记录、阶段状态一律通过 `scripts/cycle-state.mjs` 完成（见 `references/state-machine.md`）。`cycle.json` 的 `status` 与 `history` 由脚本在**同一次写入**里保证自洽——手改两处必然对不齐。

### 4.3 阶段

| 阶段 | 含义 | 产物落点 |
|---|---|---|
| `clarify` | 需求澄清 | 澄清记录（`artifacts`） |
| `design` | 用例设计 | `test-assets/<scope 目录>/<suite>/cases.json` |
| `data` | 数据准备 | fixture 路径与清理策略 |
| `execute` | 执行 | `runs[]` 记录执行批次（由 `set-stage --run` 写入）；产物落 `.test-artifacts/` |
| `triage` | 失败归因 | 缺陷与归因结论 |
| `report` | 报告 | 报告产物落 `.test-artifacts/` |

阶段状态枚举：`pending` / `in_progress` / `done` / `blocked` / `skipped`。

阶段的**键名**不限定为上表六项（允许额外的阶段），但每个阶段的 `status` 必须在枚举内。

### 4.4 状态与历史的一致性规则

- `cycle.json` 的 `status` **必须等于** `history` 数组最后一条的 `to`。改状态时必须同时追加一条 `history` 记录，两处要同一次改动完成。**校验器会拦**（`status "x" 与 history 最后一条的 to "y" 不一致`）。
- `history` 至少一条记录，**每条**含 `at` / `from` / `to` / `by`，四个字段都是非空字符串；其中 `from` 与 `to` 取值同 `status` 枚举。**校验器会拦**（`history[0].by 缺少必填字段`、`history[0].from 取值非法`）。
- `scopes_skipped[].reason` **不得为空**：跳过必须是可被 review 发现的可解释决定，空理由一律 FAIL。与用例集里"跳过必须写理由"是同一原则。**校验器会拦**。
- `scopes_skipped[]` 每条记录还须含 `at`（ISO-8601 时间戳）与 `by`（执行者标识），二者**不得为空**：跳过的决定要能被审计——半年后回看一条记录，得知道**谁在什么时候**跳过了它。**校验器会拦**。

### 4.5 `cycle.json` 与 `cycles/index.json`

`cycle.json` 是单个轮次的事实来源；`cycles/index.json` 是全局视图，只放摘要字段：

```json
{
  "cycles": [
    { "id": "R1-REQ-001", "round": "R1", "status": "completed", "cases_total": 44, "cases_passed": 41, "bugs_found": 3 }
  ]
}
```

- `index.json` 里每个 `id` **必须**在 `test-assets/cycles/` 下有同名目录，否则判为悬空引用。
- 反向不强制：`cycles/` 下有目录但 `index.json` 里没有对应条目，校验器不拦；但这属于漏维护，应补上。
- `index.json` 的 `round` / `status` 同样受枚举约束。
- **`index.json` 是 `cycle.json` 的派生视图**：条目里的 `id` / `round` / `status` 必须与对应轮次目录里的 `cycle.json` **一致**，不一致即 FAIL（校验器会拦）。理由：索引与轮次状态是两个视图，只写其一就会**静默脱同步**——轮次已经推进到 `in_progress`，索引还停在 `planned`，而校验器原本不查这种脱同步，于是谁也不会发现。
  - 索引由 `scripts/cycle-state.mjs` 在 `init` / `advance` 时自动同步；索引写失败时脚本会**回滚** `cycle.json`，保证"要么都写成功，要么都不变"。

---

## 5. 哪些进 Git、哪些不进

| 路径 | 进 Git | 理由 |
|---|---|---|
| `test-assets/**` | 是 | 用例、环境定义、执行配置、轮次状态都是资产，需要被 review 和追溯 |
| `test-assets/environments/*.json` | 是 | 但其中**只有环境变量名**，没有凭证值 |
| `.test-artifacts/**` | **否** | 执行产物（报告、日志、截图、原始响应）。必须写进项目根 `.gitignore` |
| `.tools/` | 否 | 工具链由 REQ-0024 的自举流程管理 |
| `.local/` | 否 | 本地中间产物 |

`.gitignore` 必须包含 `.test-artifacts/`。以下写法都算已忽略：`.test-artifacts/`、`.test-artifacts`、`.test-artifacts/**`、`/.test-artifacts/`。注释行与取反行（`!...`）不计入。

产物目录的命名规则：`<suite 名>` 或 `<轮次 id>/<suite 名>`，一律位于 `.test-artifacts/` 之下。

---

## 6. 常见错误与修法

### 6.1 报错 → 原因 → 修法

| 报错关键字 | 原因 | 修法 |
|---|---|---|
| `test-assets/ 缺失` | 项目根下没有测试资产根目录 | 新建 `test-assets/`；资产一律放这里，不要散落在仓库各处 |
| `test-assets/environments/ 缺失` | 环境定义目录不存在 | 新建该目录，至少放 `_schema.json` 与一个环境文件 |
| `_schema.json 缺失` / `JSON 语法错误` | schema 文件不在或写坏了 | 按 §3.1 模板重写；字段说明写在 `description` 里 |
| `X 缺少必填字段` | 必填字段缺失 | 对照 §3.2 / §3.3 的必填列补齐 |
| `X 类型错误：期望 integer，实际 string` | 把数值写成了字符串 | 改成真正的数字/布尔/数组，不要用字符串凑 |
| `X 是多余的字段（未在 schema 中定义）` | 顶层字段超出封闭集合 | 删掉该字段，或改用已定义字段承载语义 |
| `credentials.password 是明文凭证` | 把凭证值直接写进了配置 | 改成 `password_env: "<环境变量名>"`，真实值放执行机的环境变量里 |
| `credentials.username_env 的值是非法环境变量名` | 环境变量名不合规（小写、含空格、含特殊字符） | 改成大写字母/下划线形式的名字，如 `STAGING_USER` |
| `scope 取值非法` | scope 写了 `perf` 之类自造值 | 只能是 `functional` / `security` / `load` |
| `executor 取值非法` | executor 写了自造值 | 只能是 `api` / `ui` / `load` / `security` / `mock` |
| `environment "x" 在 ... 中不存在` | 悬空环境引用 | 补 `environments/x.json`，或把 `environment` 改成已存在的环境名 |
| `cases_file 指向的文件不存在` | 用例/场景文件缺失或路径相对目录搞错 | `cases_file` 相对**套件目录**解析；确认文件已落盘 |
| `suite "x" 与所在目录名 "y" 不一致` | 套件改名后没同步 | 让两者一致：改目录名或改 `suite` 字段 |
| `status 取值非法` | 用了 `finished` 之类自造状态 | 用 `planned` / `in_progress` / `completed` / `blocked` / `cancelled` |
| `status 缺少必填字段` | 轮次没写当前状态 | 用 `scripts/cycle-state.mjs advance` 推进（脚本会同时写 `status` 与 `history`） |
| `scopes_skipped[0].reason` 缺失或为空 | 跳过了范围但没写理由 | 写清"为什么这个范围本轮不跑"（如"需求未给任何性能指标，无阈值可依"） |
| `scopes_skipped[0].at` 缺少必填字段 | 跳过记录缺时间戳 | 用 `scripts/cycle-state.mjs skip-scope --by <agent>` 重新记录（脚本自动写 ISO-8601 时间戳） |
| `scopes_skipped[0].by` 缺少必填字段 | 跳过记录缺执行者 | 同上；"谁跳过的"不允许有默认值 |
| `status "x" 与 history 最后一条的 to "y" 不一致` | 只改了状态没追加 history | 追加一条 `history` 记录，其 `to` 等于新的 `status`；或直接用 `scripts/cycle-state.mjs advance` 走一次合法转移 |
| `history[0].by 缺少必填字段` | 状态变更留痕不完整 | 每条 history 都要有 `at` / `from` / `to` / `by`；用 `advance` 生成的记录天然齐备 |
| `cycle_id "x" 与轮次目录名 "y" 不一致` | 轮次目录改名后没同步 | 改目录名或改 `cycle_id`，两者必须一致 |
| `stages.design.status 缺少必填字段` | 阶段没写状态 | 补上阶段状态（`pending` / `in_progress` / `done` / `blocked` / `skipped`） |
| `stages.design.status 类型错误` | 阶段状态写成了数字等 | 改成字符串 |
| `cycles[0] 与 .../cycle.json 不一致` | 轮次索引与轮次状态脱同步 | 用 `scripts/cycle-state.mjs advance` 推进一次（脚本会自动同步索引） |
| `load_scenario 是多余的字段` | 把 scope 专属字段写进了 `suite.json` | 删掉该字段；scope 专属信息写在同目录的专属文件里，由 `cases_file` 指向 |
| `name "x" 与环境文件名 "y" 不一致` | 环境标识与文件名不一致 | 让 `name` 等于文件名（不含 `.json`） |
| `悬空的 cycle id` | `index.json` 指向了不存在的轮次目录 | 建目录并写 `cycle.json`，或删掉这条索引 |
| `.gitignore 未忽略 .test-artifacts/` | 执行产物会进 Git | 在项目根 `.gitignore` 加一行 `.test-artifacts/` |
| `report.output_dir "x" 不在 .test-artifacts/ 下` | 产物目录指向了会被提交的位置 | 改成 `.test-artifacts/<suite 名>` |

### 6.2 自检流程

1. 摆好资产后运行：`node scripts/verify-layout.mjs <project-root>`（`scripts/` 相对 skill 目录；仓库内为 `node skills/test-case-design/scripts/verify-layout.mjs <project-root>`）
2. 输出逐条列出 `[OK]` 与 `[FAIL]`；`[FAIL]` 行带**文件路径 + 字段路径 + 问题说明**，据此逐条修。
3. 结尾 `结论: N FAIL / M OK`；`N > 0` 表示退出码 1，必须修到 `N = 0` 才算交付。
4. 重复运行结果必须一致——校验器只读不写，不会改动你的文件。

### 6.3 校验器实际强制的 22 项

| # | 检查项 | 判定 |
|---|---|---|
| 1 | `test-assets/` 存在 | 缺失 → FAIL |
| 2 | `environments/_schema.json` 存在且可解析 | 缺失/JSON 错误 → FAIL |
| 3 | 每个 `environments/*.json`（除 `_schema.json`）符合 schema 与契约基线 | 缺字段/类型错/多余字段 → FAIL |
| 4 | `credentials` 下无明文凭证，`*_env` 值是合法环境变量名 | 违规 → FAIL |
| 5 | 每个 `suite.json` 字段完整、枚举合法 | → FAIL |
| 6 | `suite.json` 的 `environment` 在 `environments/` 中存在 | 悬空 → FAIL |
| 7 | `suite.json` 的 `cases_file` 指向的文件存在 | 缺失 → FAIL |
| 8 | `suite.json` 的 `suite` 与所在目录名一致 | 不一致 → FAIL |
| 9 | `cycle.json`（及 `index.json` 条目）的枚举值合法，`status` 必填 | → FAIL |
| 10 | `cycle.json` 的 `scopes_skipped[]` 每条含非空的 `scope` / `reason` / `at` / `by` | 缺字段 / reason 为空 → FAIL |
| 11 | `cycle.json` 的 `status` 与 `history` 最后一条 `to` 一致；`history` 每条含 `at` / `from` / `to` / `by` | 不一致 / 缺字段 → FAIL |
| 12 | `cycles/index.json` 中每个 `id` 在 `cycles/` 下有对应目录 | 悬空 → FAIL |
| 13 | `.test-artifacts/` 在项目 `.gitignore` 中 | 未忽略 → FAIL |
| 14 | `suite.json` 的 `report.output_dir` 以 `.test-artifacts/` 开头 | 否 → FAIL |
| 15 | 环境的 `name` 与环境文件名（不含 `.json`）一致 | 不一致 → FAIL |
| 16 | `cycle.json` 的 `cycle_id` 与轮次目录名一致 | 不一致 → FAIL |
| 17 | `cycle.json` 的字段类型正确（`round` / `round_type` / `scopes` / `scopes_skipped` / `stages` / `stages.*.status` / `stages.*.artifacts` / `trigger`） | 类型错 → FAIL |
| 18 | `cycle.json` 的 `stages.<name>.status` 存在且是合法阶段状态 | 缺失 / 类型错 / 非法枚举 → FAIL |
| 19 | `cycles/index.json` 条目与对应 `cycle.json` 的 `status` / `round` 一致（index 是派生视图） | 脱同步 → FAIL |
| 20 | `suite.json` 的顶层字段集封闭（无 `load_scenario` / `threat_model` 等 scope 专属字段） | 多余字段 → FAIL |
| 21 | `suite.json` 的 `scope` / `executor` 枚举合法 | 非法取值 → FAIL |
| 22 | `suite.json` 的 `tags` / `report` 子字段类型正确 | 类型错 → FAIL |

> 第 15~22 项是 REQ-002.5a 追加的检查（补齐原先"文档写了必须、校验器没拦"的缺口）。
> 第 9~11、17~18 项的判定规则来自 `scripts/lib/state-machine.mjs`（状态机单一来源），
> 推进器 `scripts/cycle-state.mjs` 做准入判断时调用的是同一套规则——两边报出的是同一类问题。

校验器**不**检查：`cases.json` 的用例内容（属 REQ-002A）、`contracts/` 的内容、`.tools/` 的内容、威胁模型与覆盖矩阵的结构、fixture 文件是否存在、`data_fixtures[].path` 是否可解析。这些项要么归别的 REQ，要么不属于本契约。
