# 压测上下文格式（`load-context.json`）

> 输入契约的唯一说明。**顶层与内层的字段集都是封闭的** —— 多写一个字段就是违规。

## 1. 命令行

```console
node scripts/make-load-profile.mjs \
  --context <压测上下文.json> \
  [--cases <功能用例集.json>] \
  --out-dir <项目根>
```

| 参数 | 必填 | 说明 |
|---|---|---|
| `--context` | 是 | 压测上下文 JSON（格式见下） |
| `--cases` | 否 | 功能用例集（cases.json v2），用于**链路存在性**对账 |
| `--out-dir` | 是 | **项目根**（不是产物目录）；产物固定落在 `<out-dir>/test-assets/load/` |

### 两层退出码

| 情形 | 退出码 | 说明 |
|---|---|---|
| 参数缺失 / 未知参数 / `--out-dir` 指向文件 | **2** | **用法错** |
| 上下文不存在 / 不是合法 JSON / 字段集非法 / 枚举越界 / 引用悬空 / 阈值不成对 | **1** | **输入非法** |
| 产物已存在（`<out-dir>/test-assets/load/` 非空） | **1** | 状态非法，**不覆盖**既有产物 |
| 成功 | **0** | |

⚠️ 输入非法时**不得留下半份产物**：`test-assets/load/` **不得出现**（存在性判定，0 字节的空目录也算）。
⇒ 实现上必须**先校验、后建目录**。

## 2. 顶层字段集（封闭 5 个）

| 字段 | 类型 | 必填 | 约束 |
|---|---|---|---|
| `schema_version` | number | 是 | 必须 `== 1` |
| `service` | object | 是 | 封闭 2：`name`（非空 string）、`description`（string，可选） |
| `environments` | array | 是 | ≥1 项；元素封闭 2（见 §3） |
| `workloads` | array | 是 | ≥1 项；元素见 §4 |
| `open_questions` | array | 否 | 默认 `[]`；元素封闭 3（见 §6） |

**顶层出现表外字段 ⇒ 输入非法（rc=1）** —— 例如把 `load_scenario` / `cases` / 顶层 `thresholds` 直接写在顶层。

> 顶层**不许**放 `thresholds`：阈值属于**每条容量目标**（不同目标的阈值不同），放顶层会让「哪个目标的阈值」无从判定。

## 3. `environments[]`（目标环境清单）

元素字段集**封闭 2**：

| 字段 | 类型 | 必填 | 约束 |
|---|---|---|---|
| `name` | string | 是 | `^[a-z0-9][a-z0-9-]*$` |
| `base_url` | string | 是 | 非空 |

⚠️ 这里的 `environments[]` 是「**要打哪些环境**」的清单，**不是**「要写的环境文件」。
本 skill 的写入范围只有 `test-assets/load/` ⇒ **不创建、不修改**环境文件（环境是项目的资产）。
产物 `suite.json` 的 `environment` 指向的环境文件**由项目提供**；文件不在 ⇒ 上游校验层那条判据**不可判定**（前置条件不满足），不是本 skill 的违约。

## 4. `workloads[]`（容量目标）

元素字段集**封闭 10 个**：

| 字段 | 类型 | 必填 | 约束 |
|---|---|---|---|
| `id` | string | 是 | `^WL-\d{3}$`；**文件内唯一** |
| `name` | string | 是 | `^[a-z0-9][a-z0-9-]*$`；= 场景短名 = 场景文件名去扩展名；**文件内唯一** |
| `target` | string | 是 | `^(GET\|POST\|PUT\|DELETE\|PATCH\|HEAD\|OPTIONS) /.*$`（方法 + 空格 + 路径） |
| `environment` | string | 是 | 必须在 `environments[]` 内（**不悬空**） |
| `profile` | object | 是 | 封闭 2（见 §5） |
| `thresholds` | object | **条件** | 见 §7（成对规则） |
| `thresholds_source` | string | **条件** | 见 §7（成对规则） |
| `tool` | object | 是 | 封闭 2（见 §5） |
| `args` | object | 否 | 开放键值，**原样透传**到产物 |
| `requirement_refs` | array | 否 | string 数组（需求条目引用），默认 `[]` |

`id` 重复 / `id` 格式错 / `name` 格式错 / `name` 重复 / `target` 格式错 / `environment` 悬空 ⇒ **输入非法（rc=1）**，且 stderr **点名坏点**（字段名 + 坏值）。

> `name` 必须唯一：场景文件名就是 `<name>.json` ⇒ 两个容量目标同名 ⇒ 文件名撞车。

## 5. `profile` 与 `tool`（各封闭 2）

`profile`：

| 字段 | 类型 | 必填 | 约束 |
|---|---|---|---|
| `type` | string | 是 | ∈ `constant` / `ramp-up` / `ramp-down` / `spike` / `soak`（**5 个**） |
| `steps` | array | 是 | ≥1 项；元素封闭 2：`duration_s`（整数 ≥ 1）、`concurrency`（整数 ≥ 1） |

`tool`：

| 字段 | 类型 | 必填 | 约束 |
|---|---|---|---|
| `runner` | string | 是 | ∈ `loadtest` / `python` |
| `runtime` | string | 是 | ∈ `bun` / `python` / `node` |

⚠️ `runner` 只是**声明**用哪个 runner：本 skill **不装**它、**不跑**它、**不联网**。
`runner` 与 `runtime` 是两件事（`loadtest` 的运行时是 `bun`，`python` runner 的运行时是 `python`）。

## 6. `open_questions[]`（未决问题）

元素字段集**封闭 3**：

| 字段 | 类型 | 约束 |
|---|---|---|
| `id` | string | `^OQ-\d{3}$`；**文件内唯一** |
| `topic` | string | ∈ `thresholds` / `coverage` / `runner` / `other` |
| `question` | string | 非空 |

上下文里给的未决问题会进 `report.json`（压测计划清单）。
**派生**的未决问题（没有指标来源 / 没有对应用例）由本 skill 生成，规则见 `profile-rules.md`。

## 7. `thresholds` 与 `thresholds_source` 的**成对规则**

| 情形 | 判定 |
|---|---|
| 两个都**不存在** | 合法 ⇒ 该容量目标**没有指标来源** ⇒ 产物走 `not_provided` 分支（**不写阈值键** + 留一条 `topic=thresholds` 的未决问题） |
| 两个都**存在** | 合法 ⇒ `thresholds_source` 必须是非空 string；`thresholds` 必须 ≥1 键，键 ∈ 白名单 |
| **只给一个** | **输入非法（rc=1）** —— 「有阈值却没来源」是凭空拍；「有来源却没阈值」是自相矛盾 |

`thresholds` 的键白名单（**封闭 6**）：

`p50_latency_ms` / `p95_latency_ms` / `p99_latency_ms` / `error_rate` / `throughput_rps` / `max_concurrency`

值类型：延迟 / 吞吐 / 并发 = number ≥ 0；`error_rate` = number 且 ∈ `[0, 1]`。**键之外**的键 ⇒ 输入非法（rc=1）。

## 8. 最小示例

```json
{
  "schema_version": 1,
  "service": { "name": "order-api", "description": "订单服务" },
  "environments": [
    { "name": "local", "base_url": "http://127.0.0.1:8080" },
    { "name": "staging", "base_url": "https://staging.example.com" }
  ],
  "workloads": [
    {
      "id": "WL-001",
      "name": "checkout",
      "target": "POST /api/v1/checkout",
      "environment": "local",
      "profile": {
        "type": "ramp-up",
        "steps": [ { "duration_s": 60, "concurrency": 10 }, { "duration_s": 120, concurrency: 20 } ]
      },
      "thresholds": { "p95_latency_ms": 800, "error_rate": 0.01 },
      "thresholds_source": "需求 REQ-005 性能指标",
      "tool": { "runner": "loadtest", "runtime": "bun" },
      "args": { "rps": 100, "keepalive": true, "timeout_s": 10 },
      "requirement_refs": ["R-1"]
    },
    {
      "id": "WL-002",
      "name": "order-query",
      "target": "GET /api/v1/orders",
      "environment": "local",
      "profile": { "type": "constant", "steps": [ { "duration_s": 300, "concurrency": 5 } ] },
      "tool": { "runner": "loadtest", "runtime": "bun" },
      "requirement_refs": ["R-2"]
    }
  ],
  "open_questions": []
}
```

⚠️ `WL-002` 刻意**没有**阈值与来源 ⇒ 产物里**不许**出现 `thresholds` / `thresholds_source` 两个键，
并且**必须**留一条 `topic == "thresholds"` 的未决问题。
