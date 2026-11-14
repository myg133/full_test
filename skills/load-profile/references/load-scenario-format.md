# 负载模型产物格式

> 三件产物：**负载模型本体**（`scenarios/`）、**套件级引用件**（套件目录里的 `scenario.json`）、
> **执行配置**（套件目录里的 `suite.json`）、以及**压测计划清单**（`report.json`）。
> 字段集**全是封闭的** —— 上游对 `cases_file` 指向的文件**只校验存在、不校验内容**，
> 所以这些契约**全部由本 skill 自己守**。

## 1. 负载模型本体 —— `test-assets/load/scenarios/<name>.json`

顶层字段集**封闭 14 个**（其中 2 个是条件字段）：

| # | 字段 | 类型 | 必填 | 约束 |
|---|---|---|---|---|
| 1 | `schema_version` | number | 是 | `== 1` |
| 2 | `id` | string | 是 | `^WL-\d{3}$`；与输入 workload 的 `id` **逐字相等** |
| 3 | `name` | string | 是 | `^[a-z0-9][a-z0-9-]*$`；**等于文件名去扩展名** |
| 4 | `service` | string | 是 | = 输入 `service.name` |
| 5 | `target` | string | 是 | **逐字等于**输入 workload 的 `target` |
| 6 | `environment` | string | 是 | **逐字等于**输入 workload 的 `environment` |
| 7 | `profile` | object | 是 | 封闭 2（`type` / `steps`）；**逐字等于**输入（**含步序**） |
| 8 | `thresholds` | object | **条件** | 有来源时存在；**逐字等于**输入（不加键、不改值） |
| 9 | `thresholds_source` | string | **条件** | 有来源时存在；**逐字等于**输入 |
| 10 | `thresholds_status` | string | 是 | ∈ `provided` / `not_provided` |
| 11 | `tool` | object | 是 | 封闭 2（`runner` / `runtime`）；**逐字等于**输入 |
| 12 | `args` | object | 否 | **逐字等于**输入 workload 的 `args`（输入没有则**不写这个键**） |
| 13 | `traceability` | object | 是 | 封闭 3（见 §2） |
| 14 | `open_questions` | array | 是 | 数组（可为空数组） |

**表外字段一律违规**（如 `meta` / `status` / `result` / `verdict` / `executed` / `passed` / `note`）。

⚠️ 产物里的**枚举取值也必须合法**：`profile.type` ∈ 5 值、`tool.runner` ∈ 2 值、
`tool.runtime` ∈ 3 值、`thresholds` 的键 ∈ 6 值白名单 —— 输入层被绕过时，产物层仍要拦。

### 文件名约定

- 场景文件名 = `scenarios/<name>.json`，`<name>` 合 `^[a-z0-9][a-z0-9-]*$`；
- **文件名去掉 `.json` 必须等于**文件内的 `name` 字段；
- 场景文件**只有** `.json` 后缀。

### 阈值二态（诚实性的机器可读载体）

| `thresholds_status` | 条件 | 必须 |
|---|---|---|
| `provided` | 输入有 `thresholds` + `thresholds_source` | `thresholds` 与 `thresholds_source` **两个键都存在**且逐字等于输入；`open_questions` 里**不得**有 `topic == "thresholds"` 的条目 |
| `not_provided` | 输入**没有**阈值 | **不得**存在 `thresholds` 键、**不得**存在 `thresholds_source` 键；`open_questions` 里**必须**有 ≥1 条 `topic == "thresholds"` |

⇒ 「没有指标来源就不拍阈值」是**结构性**保证（键的有无），不是一句承诺。

## 2. `traceability`（封闭 3）

| 字段 | 类型 | 约束 |
|---|---|---|
| `workload_id` | string | 逐字等于输入 workload 的 `id` |
| `requirement_refs` | array | string 数组；逐字等于输入 workload 的 `requirement_refs`（缺省则 `[]`） |
| `case_refs` | array | string 数组 —— 链路存在性对账算出的功能用例 id 集合（**恰等**，不多不少） |

## 3. 未决问题条目（封闭 3）

| 字段 | 约束 |
|---|---|
| `id` | `^OQ-\d{3}$`；**文件内唯一** |
| `topic` | ∈ `thresholds` / `coverage` / `runner` / `other` |
| `question` | 非空 string |

未决问题的 id 在**整套产物里全局唯一**（按容量目标顺序分配）⇒ 同一个 id 在任何文件里都能唯一定位一条缺口。
`report.json` 里的未决问题按同样规则重新连续编号，保证**文件内**唯一。

## 4. 套件 —— `test-assets/load/suites/LOAD-<编号>-<短名>/`

### 划分规则（**多对一**）

1. 按 `environments[]` 的**出现顺序**给每个环境分配套件编号 `001`、`002`、…；
2. **同一 `environment` 的所有容量目标归入同一个套件**；
3. 套件目录名 = `LOAD-<三位编号>-<该套件第一个场景的 name>`；
4. 一个场景只属于**一个**套件。

目录名必须合 `^LOAD-\d{3}-[a-z0-9][a-z0-9-]*$`；短名取**第一个**场景的 `name`（顺序 = 输入 workload 顺序）。

### 套件级 `scenario.json`（**引用件**，顶层封闭 3）

| 字段 | 类型 | 约束 |
|---|---|---|
| `schema_version` | number | `== 1` |
| `suite` | string | **等于**所在目录名 |
| `scenarios` | array | ≥1 项；元素封闭 3（见下） |

元素（封闭 3）：

| 字段 | 类型 | 约束 |
|---|---|---|
| `path` | string | 相对**套件目录**解析，必须指向**真实存在**的 `scenarios/<name>.json` |
| `id` | string | 必须**等于**本体文件的 `id` |
| `name` | string | 必须**等于**本体文件的 `name` |

⇒ `id` / `name` 是**防漂移锚点**：本体改了身份而引用没改 ⇒ 漂移 ⇒ 判红。
引用字段名取 **`scenarios`（数组）**，不取 `load_scenario`（单值）—— 一个套件可以对多个场景。

### `suite.json`（顶层 ⊆ 上游 9 个允许字段）

| 字段 | 值 |
|---|---|
| `suite` | **等于**所在目录名 |
| `requirement` | 非空 string（需求编号，如 `REQ-009`） |
| `scope` | `load` |
| `environment` | 该套件的环境名（**必须是上下文里声明过的**环境，不悬空） |
| `cases_file` | `scenario.json`（相对套件目录） |
| `executor` | `load` |
| `base_url_from` / `tags` / `report` | 可选 |

⚠️ **出现上游 9 个以外的字段（含 `load_scenario`）⇒ 违规**。
⚠️ 上游**只**校 `scope` / `executor` 各自的枚举合法性，**不强制配对** ⇒ 「配对」由本 skill 保证。

### 覆盖完整性（双向）

1. 每个容量目标**恰好**被一个套件引用；
2. 每个套件**至少**引用一个场景模型；
3. 每个场景模型**至少**被一个套件引用（**无孤儿场景**）；
4. **无孤儿套件**（引用了不存在的场景模型）。

## 5. 压测计划清单 —— `test-assets/load/report.json`

顶层字段集**恰为 5 个**：

| 字段 | 类型 | 说明 |
|---|---|---|
| `schema_version` | number | `== 1` |
| `service` | object | 输入的 `service` 原样（`name` / `description`） |
| `suites` | array | 套件 ↔ 场景映射：`{suite, requirement, environment, scenarios:[{id,name,path}]}` |
| `scenarios` | array | 场景索引：`{id, name, path, environment, suite, thresholds_status}` |
| `open_questions` | array | 全部未决问题（派生 + 上下文给的） |

## 6. 产物里**不许**出现的东西

- **压测结论字段**（任意层级）：`status` / `result` / `verdict` / `executed` / `passed` / `outcome` / `conclusion`
  —— 本 skill **不发压** ⇒ 「已通过」是假的；
- **`method` 字段**：负载模型**不是**测试用例，用例方法（`M1.x` / `M2.x`）对它不适用；
- **`cases.json`**：压测用例不是「步骤 → 预期」形态，硬套进 `cases.json` 会让它变形；
- **生成时间戳**：产物**不含**任何时间戳 / 随机 id / 宿主路径 ⇒ 幂等就是「两份产物逐字相同」。
