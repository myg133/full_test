# 需求：测试套件基座 — 项目目录契约与校验

- **需求编号**: REQ-002B
- **所属 Epic**: REQ-002 suite-foundation
- **优先级**: P0
- **状态**: 已就绪

## 需求描述

### 背景

REQ-001 只管"设计"不管"落地"。真实使用时，用例集需要和**环境、配置、数据、脚本、报告**关联起来，否则：

- 同一用例集在不同环境跑，配置散落各处；
- 环境切换靠改代码；
- 执行产物（报告、日志、截图）污染仓库；
- 多个 skill（设计→执行→报告）之间没有稳定的交接格式。

REQ-002A 解决"用例集本身长什么样"，本 REQ 解决"用例集放在哪、旁边有什么、怎么校验"。

### 目标

定义一套**项目级测试资产目录契约**，并提供可校验脚本强制执行。

**这不是做测试，是做"测试资产该放在哪"的规约。**

### 范围边界

**在范围内**：
- `test-assets/` 目录结构定义
- 环境配置 JSON schema（`environments/_schema.json`）
- 执行配置 `suite.json` 格式
- `scripts/verify-layout.mjs` 校验脚本
- `references/project-layout.md` 契约文档

**不在范围内**（属 REQ-002A / 其他子 REQ）：
- schema v2 的用例集字段（属 REQ-002A）
- `.tools/` 工具链自举（属 REQ-0024）
- 执行器与证据采集（属 REQ-0025）
- 实际创建 `test-assets/` 目录内容（本 REQ 只定义契约与校验器，不预置业务内容）

## 功能要求

### F1 目录结构契约

```text
<project-root>/
├── test-assets/                    # 测试资产根目录（进 Git）
│   ├── README.md                   # 目录契约说明（人读）
│   ├── environments/               # 环境定义
│   │   ├── _schema.json            # 环境配置 schema
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

**目录名已定**：`test-assets/`（用户决策）、`.test-artifacts/`（用户决策：不进 Git，只进 `.gitignore`）。

**可见名规则**：`test-assets/` 与 `.tools/`、`cycle.json` 等**要进 Git 的用可见名**；`.test-artifacts/`、`.local/` 等纯本地产物用 `.` 前缀。

### F2 环境配置格式（JSON）

`environments/_schema.json` 定义结构，`environments/*.json` 填值：

```json
{
  "name": "staging",
  "base_url": "https://staging.example.com",
  "timeout_ms": 5000,
  "retries": 0,
  "credentials": {
    "username_env": "STAGING_USER",
    "password_env": "STAGING_PASS"
  },
  "headers": { "X-Test-Run": "${run_id}" },
  "verify_tls": false,
  "data_fixtures": [
    { "path": "test-assets/fixtures/users.json", "cleanup": true }
  ]
}
```

**`_schema.json` 承担文档职责**（JSON 无注释，字段说明写在 schema 的 `description` 字段里）：

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "测试环境配置",
  "type": "object",
  "required": ["name", "base_url", "timeout_ms", "credentials"],
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

**凭证硬约束**：`credentials` 下只允许 `*_env` 字段（值为环境变量名），**禁止明文**。

### F3 执行配置 `suite.json`

```json
{
  "suite": "REQ-001-coupon",
  "requirement": "REQ-001",
  "scope": "functional",
  "environment": "staging",
  "cases_file": "cases.json",
  "executor": "api",
  "base_url_from": "environment.base_url",
  "tags": { "include": ["P0", "P1"], "exclude": [] },
  "report": {
    "format": ["html", "json"],
    "output_dir": ".test-artifacts/REQ-001-coupon"
  }
}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `suite` | 是 | 套件标识，与目录名一致 |
| `requirement` | 是 | 关联需求编号 |
| `scope` | 是 | 枚举 `functional` / `security` / `load` |
| `environment` | 是 | 须存在于 `environments/` |
| `cases_file` | 是 | 相对本目录的用例集路径 |
| `executor` | 是 | 枚举 `api` / `ui` / `load` / `security` |
| `base_url_from` | 否 | 指向环境配置的字段路径 |
| `tags` | 否 | `include` / `exclude` 标签过滤 |
| `report` | 否 | `format` 数组 + `output_dir` |

**三个范围的 `suite.json` 结构完全一致**，只靠 `scope` 与 `executor` 区分——这样执行器外围逻辑可完全复用。

### F4 轮次状态 `cycle.json`

```json
{
  "cycle_id": "R1-REQ-001",
  "round": "R1",
  "round_type": "new-requirement",
  "requirement": "REQ-001",
  "scopes": ["functional", "security"],
  "scopes_skipped": [
    { "scope": "load", "reason": "需求未给任何性能指标，无阈值可依" }
  ],
  "status": "in_progress",
  "stages": {
    "clarify": { "status": "done", "artifacts": ["clarifications.json"], "at": "2026-11-11T10:00:00+08:00" },
    "design":  { "status": "done", "artifacts": ["test-assets/suites/REQ-001-coupon/cases.json"] },
    "data":    { "status": "done" },
    "execute": { "status": "in_progress", "runs": ["run-001"] },
    "triage":  { "status": "pending" },
    "report":  { "status": "pending" }
  },
  "trigger": { "type": "requirement", "ref": "REQ-001" },
  "history": [
    { "at": "2026-11-11T09:30:00+08:00", "from": "planned", "to": "in_progress", "by": "dev-agent-1" }
  ]
}
```

**状态枚举**：

| 字段 | 枚举 |
|---|---|
| `round` | `R1` / `R2` / `R3` |
| `round_type` | `new-requirement` / `regression` / `defect-verify` |
| `scope`（在 `scopes` / `scopes_skipped` 中） | `functional` / `security` / `load` |
| `status`（轮次） | `planned` / `in_progress` / `completed` / `blocked` / `cancelled` |
| `status`（阶段） | `pending` / `in_progress` / `done` / `blocked` / `skipped` |

**`scopes_skipped[].reason` 为空 → 校验失败**（与 REQ-002A 的 `coverage_matrix[].skipped[].reason` 同一原则："跳过"必须可被 review 发现）。

> **后续修订（REQ-002.5a，2026-11-11）**：本 REQ 交付时 `scopes_skipped[]` 元素只有 `scope` 与 `reason` 两个字段。自 REQ-002.5a 起，每条跳过记录**增补 `at`（ISO8601 时间戳）与 `by`（执行者）两个审计字段**，四字段均为必填，校验器会拦缺失项。
>
> 也就是说，**照上面这段示例原样造出的 `cycle.json` 现在会被校验器判 FAIL**。历史示例保持原貌以备追溯；**活契约以 `skills/test-case-design/references/project-layout.md` §4.2 为准**。


`cycles/index.json` 提供全局视图：

```json
{
  "cycles": [
    { "id": "R1-REQ-001", "round": "R1", "status": "completed", "cases_total": 44, "cases_passed": 41, "bugs_found": 3 }
  ]
}
```

### F5 校验脚本 `skills/test-case-design/scripts/verify-layout.mjs`

**位置说明（重要）**：脚本必须放在 `skills/test-case-design/scripts/` 下，**不能放包根**。原因：`package.json` 的 `files` 字段只含 `skills/ bin/ README.md LICENSE`，且安装器 `discoverSkills()` 只扫描 `skills/` 下含 `SKILL.md` 的子目录——放包根的文件既进不了 npm 包，也装不进用户的 `~/.agents/skills/`。这是 REQ-002B 开发阶段实测发现并修正的（原设计误放在包根）。

同理，契约文档放 `skills/test-case-design/references/project-layout.md`。

纯 Node.js，零第三方依赖。校验以下各项，**任一失败则退出码 1 并逐条列出**：

| # | 检查项 | 判定 |
|---|---|---|
| 1 | `test-assets/` 存在 | 缺失 → ERROR |
| 2 | `environments/_schema.json` 存在且可解析 | 缺失/JSON 错误 → ERROR |
| 3 | 每个 `environments/*.json`（除 `_schema.json`）符合 schema | 字段缺失/类型错/多余字段 → ERROR |
| 4 | `credentials` 下无明文凭证 | 出现非 `*_env` 字段，或 `*_env` 值不是合法环境变量名 → ERROR |
| 5 | 每个 `suite.json` 字段完整、枚举合法 | → ERROR |
| 6 | `suite.json` 的 `environment` 在 `environments/` 中存在 | 悬空 → ERROR |
| 7 | `suite.json` 的 `cases_file` 指向的文件存在 | 缺失 → ERROR |
| 8 | `suite.json` 的 `suite` 与所在目录名一致 | 不一致 → ERROR |
| 9 | `cycle.json` 的枚举值合法 | → ERROR |
| 10 | `cycle.json` 的 `scopes_skipped[].reason` 非空 | → ERROR |
| 11 | `cycle.json` 的 `status` 与 `history` 最后一条 `to` 一致 | 不一致 → ERROR |
| 12 | `cycles/index.json` 中每个 `id` 在 `cycles/` 下有对应目录 | 悬空 → ERROR |
| 13 | `.test-artifacts/` 在项目 `.gitignore` 中 | 未忽略 → ERROR |
| 14 | `suite.json` 的 `report.output_dir` 以 `.test-artifacts/` 开头 | 否 → ERROR（产物必须落在不进 Git 的目录） |

**脚本用法**：

```bash
node scripts/verify-layout.mjs [project-root]
```

`project-root` 缺省时取当前工作目录。输出格式：

```
[OK]   test-assets/ 存在
[OK]   environments/local.json 符合 schema
[FAIL] suites/REQ-001-coupon/suite.json: environment "prod" 在 environments/ 中不存在
...
结论: 3 FAIL / 12 OK
```

### F6 契约文档 `skills/test-case-design/references/project-layout.md`

面向人与 agent 读，说明：
- 目录结构与各目录职责
- 三种 scope 的组织差异与共同点
- 环境配置与执行配置的字段语义
- 轮次状态机与阶段定义
- 哪些进 Git、哪些不进
- 常见错误与修法

## 非功能要求

- **性能**：100 个 suite 的项目，校验 < 3 秒
- **零依赖**：脚本只用 `node:` 内置模块
- **可移植**：不含 bash / python3 / `/tmp` / grep / sed
- **诊断质量**：每条报错要含具体文件路径 + 字段路径 + 问题说明
- **幂等**：重复运行不产生副作用、不修改任何文件

## 验收要点

见 `acceptance.md`（12 条 AC）。
