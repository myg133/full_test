# 设计：测试流程、三范围、轮次状态、证据链、工具链（REQ-003 草案）

- **日期**: 2026-11-11
- **作者**: BA (local-ba)
- **状态**: 草案，待与用户对齐
- **前序**: REQ-001 已交付 `test-case-design`；REQ-002 设计定稿（schema v2 + `test-assets/` 目录契约）
- **性质**: 本文是**套件整体架构**的设计，覆盖 REQ-002 之后的全部能力域

---

## 0. 用户输入与本设计的回应

| 用户输入 | 本设计的回应 |
|---|---|
| 轮次：R1 需求→用例→数据→测试(留证)→bug→报告；R2 changelog→用例→调整→测试→bug→报告 | 确认三轮模型，补三处缺口（§1）；把"留证"升级为**证据链**（§4） |
| 范围：功能 / 安全 / 压测 | 三者**形态不同**，不能共用用例 schema。分三个目录子树（§2） |
| 压测用 loadtest | 已核实：npm `loadtest@8.2.1`，ab 兼容 + `--rps`。**bun 下可跑且性能更优**（§5.3） |
| 安全做全套 | OWASP Top 10 全覆盖 + 专项扩展（§2.3） |
| 证据要能反馈真实复现流程 | 每条用例的**每一步**都要有可归档证据 + 机器可读复现描述（§4） |
| 工具放测试项目根 `.tools` 目录 | ✅ 采纳，但需与"可见名/隐藏名"规则协调（§5.1） |
| Python 用 uv/uvx；JS/TS 用 bun/deno；尽量单二进制 | ✅ 全部采纳，形成工具契约（§5） |

---

## 1. 测试流程：三轮 + 补三环

### 1.1 完整轮次模型

```text
R1 新需求测试                          R2 回归测试                    R3 缺陷验证
─────────────────────────────         ─────────────────────         ─────────────────
读需求文档                             读 changelog                   读缺陷单
  ↓                                     ↓                              ↓
【补】需求歧义澄清 ←── 新增            【补】变更影响分析 ←── 新增      缺陷复现用例生成
  ↓                                     ↓                              ↓
确定测试方法                           读测试用例集                   （复用 R1/R2 用例）
  ↓                                     ↓                              ↓
创建测试用例                           【补】用例选择 ←── 新增           执行验证
  ↓                                     ↓                              ↓
准备测试数据                           调整测试用例                    留证
  ↓                                     ↓                              ↓
执行测试（留证）                       执行测试（留证）                 生成 bug 列表（更新）
  ↓                                     ↓                              ↓
生成 bug 列表                          生成 bug 列表                   测试报告（更新）
  ↓                                     ↓                              ↓
创建测试报告                           创建测试报告                    ↓
```

**三处补环的理由**：

1. **需求歧义澄清（仅 R1）**——不澄清就建用例，所有预期都建立在猜测上。歧义清单是交付物。
2. **变更影响分析 + 用例选择（仅 R2）**——changelog 改了 3 行，600 条用例跑哪 60 条？这是回归测试的核心难题，也是"测试自动化"与"测试智能"的分界线。
3. **缺陷复现用例生成（仅 R3）**——每个确认的 bug 必须沉淀成可重跑的用例，否则同类缺陷反复出现。

### 1.2 三轮的产物差异

| | R1 | R2 | R3 |
|---|---|---|---|
| 输入 | 需求文档 | changelog + 已有用例集 | 缺陷单 |
| 核心产物 | `cases.json`（新建） | `regression-plan.json` + 用例修订 | `defect-cases.json`（复现用例） |
| 对用例集的影响 | 全新 | **可能修改/废弃/新增** | 只增不改 |
| 报告 | 完整测试报告 | 回归测试报告（回归通过率 + 影响面） | 缺陷验证报告 |
| 是否产 bug | 是 | 是 | 更新已有 bug 状态 |

---

## 2. 三个测试范围如何进入目录契约

### 2.1 核心判断：形态不同，不能塞进同一棵树

| 范围 | 驱动源 | 用例形态 | 执行方式 |
|---|---|---|---|
| 功能 | 需求条目 | `cases.json`（步骤 → 预期） | 逐步执行 + 断言 |
| 安全 | 威胁模型 / 攻击面 | `security-plan.json` + `cases.json` | 探测式执行 + 攻击载荷 |
| 压测 | 容量目标 | `load-scenario.json`（负载模型） | 并发压测 + 指标采集 |

**关键约束**：压测用例**不是**"步骤 → 预期"形态。它是"多少并发、什么梯度、观察哪个指标、阈值多少"。硬套进 `cases.json` 会让它变形，且执行器无法复用。

### 2.2 目录结构

```text
<project-root>/
├── test-assets/                    # 测试资产（进 Git）
│   ├── README.md
│   ├── environments/               # 环境定义（三范围共用）
│   │   ├── _schema.json
│   │   ├── local.json
│   │   └── staging.json
│   ├── suites/                     # 功能测试：需求驱动
│   │   └── REQ-001-coupon/
│   │       ├── cases.json
│   │       └── suite.json
│   ├── security/                   # 安全测试：威胁驱动
│   │   ├── threat-model.json       # 资产、信任边界、威胁清单
│   │   ├── matrix.json             # 权限矩阵
│   │   └── suites/
│   │       └── SEC-001-authz/
│   │           ├── cases.json
│   │           └── suite.json
│   ├── load/                       # 压测：容量驱动
│   │   ├── scenarios/
│   │   │   └── checkout.json       # 负载模型
│   │   └── suites/
│   │       └── LOAD-001-checkout/
│   │           ├── scenario.json   # 指向 scenarios/
│   │           └── suite.json
│   ├── contracts/                  # 接口契约 / mock 定义
│   └── cycles/                     # 轮次状态（见 §3）
│       ├── index.json              # 所有轮次的索引
│       └── R1-REQ-001/
│           └── cycle.json
├── .tools/                         # 工具链（见 §5）
└── .test-artifacts/                # 执行产物 + 证据（不进 Git）
    └── R1-REQ-001/
        ├── runs/
        └── evidence/
```

### 2.3 三套 schema 的差异

**功能用例**（沿用 REQ-002 schema v2）：`requirements[]` / `cases[]` / `open_questions[]` / `coverage_matrix[]`

**安全测试**：威胁模型先行，用例从威胁派生

```json
// security/threat-model.json
{
  "scope": { "service": "checkout-api", "boundaries": ["public", "internal", "db"] },
  "assets": [
    { "id": "AS-1", "name": "用户优惠券资产", "sensitivity": "high" }
  ],
  "trust_boundaries": [
    { "id": "TB-1", "from": "public", "to": "internal", "controls": ["authn", "authz"] }
  ],
  "threats": [
    {
      "id": "TH-1",
      "name": "横向越权：用他人券 ID 核销",
      "category": "broken-access-control",
      "owasp": "A01:2021",
      "asset_refs": ["AS-1"],
      "boundary_refs": ["TB-1"],
      "cases": ["TC-SEC-001", "TC-SEC-002"]
    }
  ]
}
```

**OWASP Top 10 全覆盖**（2021 版）作为威胁分类骨架：

| ID | 类别 | 对应用例族 |
|---|---|---|
| A01 | 失效访问控制 | 越权、IDOR、权限提升 |
| A02 | 加密失效 | 明文传输、弱哈希、密钥硬编码 |
| A03 | 注入 | SQL/NoSQL/LDAP/命令/模板注入 |
| A04 | 不安全设计 | 缺少限流、缺业务逻辑防护 |
| A05 | 安全配置错误 | 目录暴露、调试模式、默认口令 |
| A06 | 易受攻击组件 | 依赖 CVE |
| A07 | 认证失效 | 暴力破解、会话固定、token 泄露 |
| A08 | 数据完整性失效 | 反序列化、不安全上传 |
| A09 | 日志监控失效 | 关键操作无审计 |
| A10 | SSRF | 外部 URL 抓取 |

外加 REQ-002 方法库里的 **M4.2**（安全）细项，以及 OWASP 之外的四类实战补充：**文件上传、SSRF、XXE、反序列化**——这四类在通用扫描器里覆盖最差，但实际漏洞占比不低。

**压测场景**：

```json
// load/scenarios/checkout.json
{
  "target": "POST /api/v1/checkout",
  "environment": "staging",
  "profile": {
    "type": "ramp-up",
    "steps": [
      { "duration_s": 60,  "concurrency": 10 },
      { "duration_s": 120, "concurrency": 50 },
      { "duration_s": 300, "concurrency": 100 }
    ]
  },
  "thresholds": {
    "p95_latency_ms": 800,
    "error_rate": 0.01
  },
  "thresholds_source": "需求 REQ-005 性能指标",
  "tool": { "runner": "loadtest", "runtime": "bun" },
  "args": { "rps": 100, "keepalive": true, "timeout_s": 10 }
}
```

**`thresholds_source` 是必填字段**——没有指标来源就不该有阈值，凭空拍的阈值会让压测结论毫无意义（对应 REQ-002 的 `skipped-with-reason` 机制）。

### 2.4 三个范围共用什么

| 共用项 | 说明 |
|---|---|
| `environments/` | 环境定义、凭证引用、超时、fixture |
| `contracts/` | 接口契约 / mock 定义（功能与安全测试都要用） |
| `cycles/` | 轮次状态（§3） |
| `suite.json` 格式 | 三个范围的 suite.json 结构一致，只是 `executor` 字段不同 |
| 证据格式 | 三个范围的证据落同一套目录与命名（§4） |

**统一 `suite.json` 是刻意的**——执行器按 `executor` 分派，但外围（环境解析、证据落盘、结果汇总）完全复用。

---

## 3. 轮次状态管理

### 3.1 状态机

```text
                ┌─────────────────────────────────────┐
                │                                     │
                ▼                                     │
  ┌──────────┐      ┌──────────┐      ┌──────────┐  │  ┌──────────┐
  │ planned  │─────▶│ in_progress│─────▶│ completed│──┴─▶│ cancelled│
  └──────────┘      └──────────┘      └──────────┘     └──────────┘
                          │
                          ▼
                    ┌──────────┐
                    │ blocked  │──▶ in_progress
                    └──────────┘
```

**流转规则**：

| 从 | 到 | 触发条件 | 谁能改 |
|---|---|---|---|
| planned | in_progress | 执行者开始工作 | 执行者 |
| in_progress | completed | 全部阶段完成 | 执行者 |
| in_progress | blocked | 遇到外部阻塞（等环境、等权限、等需求方裁定） | 执行者 |
| blocked | in_progress | 阻塞解除 | 执行者 |
| planned/in_progress | cancelled | 需求取消 / 范围调整 | BA（需求所有者） |

### 3.2 单一写入者原则

沿用 agent-workspace 的硬规则：**状态只有一个写入者**。

| 状态对象 | 写入者 | 其他角色 |
|---|---|---|
| `cycle.json` 的轮次状态 | **执行者**（该轮次的负责 agent） | BA 可取消 |
| `cases[].status`（active/deprecated/modified） | BA（需求所有者） | Dev 只提议，不直接改 |
| `requirements[].status` | BA | — |
| `cases.json` 内容 | BA（设计阶段） | Dev 不改 |

这与 REQ-001 的规范一致——`status.md` 只有 BA 能改。映射过来：**用例集的"生命周期状态"归 BA，执行轮次状态归执行者**。

### 3.3 cycle.json 结构

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
    "clarify":   { "status": "done", "artifacts": ["clarifications.json"], "at": "2026-11-11T10:00:00+08:00" },
    "design":    { "status": "done", "artifacts": ["test-assets/suites/REQ-001-coupon/cases.json"] },
    "data":      { "status": "done" },
    "execute":   { "status": "in_progress", "runs": ["run-001", "run-002"] },
    "triage":    { "status": "pending" },
    "report":    { "status": "pending" }
  },
  "trigger": { "type": "requirement", "ref": "REQ-001" },
  "history": [
    { "at": "2026-11-11T09:30:00+08:00", "from": "planned", "to": "in_progress", "by": "dev-agent-1" }
  ]
}
```

**`scopes_skipped` 是这一层最关键的设计**——它让"这轮没做压测"从隐性空白变成显式声明，和 REQ-002 的 `coverage_matrix[].skipped` 同源。

### 3.4 三轮如何串起来

```text
R1-REQ-001/cycle.json
    ├─ design 阶段产出 → test-assets/suites/REQ-001-coupon/cases.json
    └─ execute 阶段产生 → .test-artifacts/R1-REQ-001/runs/run-001/

R2-CHANGELOG-2.3/cycle.json
    ├─ trigger: { type: "changelog", ref: "CHANGELOG-2.3.md" }
    ├─ impact 阶段产出 → regression-plan.json（哪些用例要重跑、哪些要改）
    └─ 执行结果 → .test-artifacts/R2-CHANGELOG-2.3/runs/

R3-BUG-007/cycle.json
    ├─ trigger: { type: "defect", ref": "BUG-007" }
    └─ 从 R1/R2 的 cases.json 派生复现用例
```

**`cycles/index.json`** 提供全局视图：

```json
{
  "cycles": [
    { "id": "R1-REQ-001", "round": "R1", "status": "completed", "cases_total": 44, "cases_passed": 41, "bugs_found": 3 },
    { "id": "R2-CHANGELOG-2.3", "round": "R2", "status": "in_progress", "cases_total": 18, "cases_passed": 12 }
  ]
}
```

---

## 4. 证据链：让 bug 能被真实复现

### 4.1 为什么这是硬需求

用户的原话："需要留证，才能反馈给开发真实的复现流程。"

一个没有证据的 bug 单——"优惠券核销，实付金额不对"——开发只能靠猜。带证据的 bug 单——完整的请求、响应、时间戳、环境、复现步骤——开发能直接复现，**这是 AI 替代测试人员的核心价值之一**：机器天然能留下结构化、无遗漏的证据，而人类测试常常只截一张图。

### 4.2 证据目录结构

```text
.test-artifacts/<cycle_id>/
├── runs/
│   └── run-001/
│       ├── run.json              # 本次执行元信息
│       ├── results.json          # 全部用例的执行结果
│       └── report.md             # 本轮报告
└── evidence/
    └── <case_id>/
        ├── meta.json             # 证据元数据（核心）
        ├── request.json          # 实际发出的请求
        ├── response.json         # 实际响应
        ├── response-headers.txt
        ├── console.log           # 客户端日志
        ├── screenshot.png        # UI 范围
        └── attachments/          # 其他
```

### 4.3 证据元数据 schema

```json
{
  "case_id": "TC-017",
  "cycle_id": "R1-REQ-001",
  "run_id": "run-001",
  "requirement_refs": ["R-4"],
  "status": "failed",
  "severity": "high",
  "started_at": "2026-11-11T10:23:41.882+08:00",
  "duration_ms": 1247,
  "environment": {
    "name": "staging",
    "base_url": "https://staging.example.com",
    "run_id_header": "X-Test-Run: run-001"
  },
  "request_summary": "POST /api/v1/coupons/redeem",
  "steps": [
    {
      "index": 1,
      "action": "以用户 A 身份提交 100 元券核销 80 元订单",
      "expected": "抵扣 80 元，实付 0 元",
      "actual": "抵扣 80 元，实付 0.01 元",
      "matched": false,
      "evidence_refs": ["request.json", "response.json"]
    }
  ],
  "artifacts": [
    { "kind": "request", "path": "request.json", "sha256": "..." },
    { "kind": "response", "path": "response.json", "sha256": "..." },
    { "kind": "screenshot", "path": "screenshot.png", "sha256": "..." }
  ],
  "reproduction": {
    "preconditions": ["staging 环境可用", "测试账号 A/B 各一个", "A 持有一张面额 100 元的券"],
    "steps": [
      "1. 以 A 登录，构造商品总额 80 元的订单",
      "2. 在结算页选择面额 100 元的券并提交核销",
      "3. 观察实付金额显示 0.01 元（预期 0 元）"
    ],
    "observed": "实付 0.01 元",
    "expected": "实付 0 元",
    "minimal_repro": "curl -X POST https://staging.example.com/api/v1/coupons/redeem -H 'Authorization: Bearer <A_TOKEN>' -d '{\"coupon_id\":\"<ID>\",\"order_amount\":80}'"
  },
  "related": {
    "known_bug": null,
    "suspected_root_cause": "疑似金额计算走了分为单位路径，与分为元混用"
  }
}
```

**三个关键字段**：

- `reproduction.steps` — 人类可读，直接贴进 bug 单
- `reproduction.minimal_repro` — 机器可读的最小复现（curl / 脚本），开发能一键跑
- `artifacts[].sha256` — 证据完整性校验，防止证据被质疑时无法自证

### 4.4 证据与 bug 的绑定

```json
// bug 列表（results.json 汇总或独立 defects.json）
{
  "id": "BUG-001",
  "title": "满减券核销后实付金额多 0.01 元",
  "severity": "high",
  "cycle_id": "R1-REQ-001",
  "run_id": "run-001",
  "case_refs": ["TC-017"],
  "evidence_path": ".test-artifacts/R1-REQ-001/evidence/TC-017",
  "status": "open",
  "reproducible": true,
  "root_cause": null
}
```

**契约要求**：每条 `status: failed` 的用例，必须有对应的 `evidence/<case_id>/meta.json`，且 `meta.steps[].actual` 非空。否则视为"未留证"，报告生成时必须显式列出，不能悄悄算作普通失败。

### 4.5 证据的生命周期与归档（用户决策：不进 Git，脱敏进制品库）

| 阶段 | 位置 | 进 Git? |
|---|---|---|
| 执行产生 | `.test-artifacts/` | ❌ |
| **脱敏** | 原地生成脱敏副本 | ❌ |
| **归档** | **CI 制品库**（脱敏后） | ❌（制品库存储） |
| 复现验证后清理 | 按保留策略 | — |

**脱敏规则**（由 `collect-evidence.py` 执行，规则写在 `.tools/manifest.json` 的 `redaction` 段）：

| 敏感类型 | 处理 |
|---|---|
| Authorization / Cookie / Token 头 | 值替换为 `<redacted:token>` |
| 手机号 / 邮箱 / 身份证 | 保留前 3 位 + 后 2 位，中间掩码 |
| 用户 ID / 订单号 | 哈希为稳定假名（同值映射到同假名，便于跨证据对照） |
| URL 中的 query 参数 | 全部剥离 |
| 响应体中的业务字段 | 按字段名白名单剥离 |

**脱敏必须可审计**——`meta.json` 记录 `redaction` 段：

```json
{
  "redaction": {
    "applied_at": "2026-11-11T10:31:00+08:00",
    "rules_version": "1.0",
    "fields_redacted": [
      { "path": "request.headers.Authorization", "type": "token", "count": 1 },
      { "path": "response.body.data.phone", "type": "phone", "count": 1 }
    ],
    "pseudonym_map_ref": ".test-artifacts/.../pseudonyms.json"
  }
}
```

**制品库归档**：

- 归档物 = 脱敏后的 `evidence/` + `results.json` + `report.md`；
- 归档命名建议：`<project>-<cycle_id>-<run_id>-<timestamp>.tar.gz`；
- **制品库需配置访问控制**——即使脱敏，测试数据仍可能透露业务逻辑；
- `meta.json` 的 `sha256` 在归档后仍有效，可校验制品完整性。

**为什么脱敏后仍不入 Git**：

1. 证据体积大（截图、响应体），会让仓库膨胀；
2. 二进制文件（截图）进 Git 不可维护；
3. 脱敏规则会演进，历史证据用新规则解读可能出错；
4. 制品库天然支持版本、过期、访问控制——Git 不具备这些。

**反例：什么该进 Git**——用例集本身（`cases.json`）、环境配置（脱敏后）、报告的**结论摘要**（不含原始证据）。这些是"资产"，证据是"过程"。

---

## 5. 工具链与 `.tools` 目录

### 5.1 `.tools` 的定位（用户决策）

> "`.tools` 的设计是，测试过程中用到的依赖程序，如果环境中不存在，则安装到 `.tools` 里。不污染系统环境。"

**这是一个"按需自举 + 环境隔离"机制**，不是简单的依赖目录。三个属性：

| 属性 | 含义 | 实现 |
|---|---|---|
| **按需** | 只有测试真正要用到的工具才装 | `manifest.json` 声明依赖，执行前检测 |
| **不污染系统** | 不 `npm i -g`、不 `pip install` 到系统 site-packages | 本地目录 + 绝对路径调用 |
| **可复现** | 同一项目在任何机器上跑出同结果 | 版本锁定 + `run.json` 记录 |

**与"可见名"规则的协调**：`agent-workspace` 规范要求"要进 Git 的目录用可见名，纯本地状态才用 `.` 前缀"。`.tools/` 是**混合体**——配置与锁文件进 Git，下载的二进制与虚拟环境不进。

```text
<project-root>/.tools/
├── README.md                 # 工具清单 + 调用约定（进 Git）
├── manifest.json             # 依赖声明：工具、版本、检测方式、安装方式（进 Git）
├── pyproject.toml            # uv 依赖（进 Git）
├── uv.lock                   # 锁文件（进 Git）
├── package.json              # bun 依赖（进 Git）
├── bun.lock                  # 锁文件（进 Git）
├── bin/                      # 胶水脚本（进 Git）
│   ├── qa                    # ★ 统一入口 + 自举器
│   ├── run-suite.py
│   ├── run-security.py
│   ├── run-load.mjs
│   ├── collect-evidence.py
│   └── verify-layout.mjs
├── python/qatest/            # 自研 Python 包（进 Git）
├── js/loadrunner.mjs         # 自研 JS 胶水（进 Git）
│
├── .venv/                    # uv 虚拟环境（★ 不进 Git）
├── node/node_modules/        # bun 依赖（★ 不进 Git）
├── downloads/                # 单二进制工具（★ 不进 Git）
└── state/installed.json      # 已安装记录（★ 不进 Git）
```

`.gitignore` 只需排除四条：`.venv/`、`node/node_modules/`、`downloads/`、`state/`。

### 5.2 自举机制

`manifest.json` 声明每个工具的"怎么找、怎么装、怎么跑"：

```json
{
  "tools": {
    "loadtest": {
      "kind": "npm",
      "version": "8.2.1",
      "runtime": "bun",
      "detect": { "type": "command", "cmd": "loadtest", "version_flag": "--version" },
      "install": { "type": "npm", "cmd": ["bun", "add", "--no-save", "loadtest@8.2.1"], "cwd": "node" },
      "run": { "cmd": ["bun", "run", "node_modules/loadtest/bin/loadtest.js"] }
    },
    "bandit": {
      "kind": "uvx",
      "version": "1.9.4",
      "detect": { "type": "uvx", "pkg": "bandit", "version_flag": "--version" },
      "install": { "type": "uvx", "pkg": "bandit==1.9.4" },
      "run": { "cmd": ["uvx", "bandit"] }
    },
    "httpx": {
      "kind": "uv",
      "version": "0.28.1",
      "detect": { "type": "python", "module": "httpx" },
      "install": { "type": "uv", "cmd": ["uv", "sync", "--frozen"] },
      "run": { "cmd": ["uv", "run", "--frozen"] }
    }
  }
}
```

**`bin/qa` 统一入口的执行序**：

```
1. 读 manifest.json
2. 对每个需要的工具：
   a. detect → 系统已有且版本匹配 → 直接用系统的
   b. 否则 → install 到 .tools/（本地副本），记入 state/installed.json
3. 用解析出的绝对路径执行
4. 把「用了哪个工具、哪个版本、哪条命令」写进 run.json
```

**为什么不直接用 `uvx` / `bunx` 裸调**：

- `uvx` 每次都要解析依赖、每次都可能拿到新版本 → 结果不可复现；
- `uv sync --frozen` 用锁文件 → 版本确定，第二次跑零网络开销；
- 系统已有且版本匹配时才复用 → 尊重用户已有环境，不重复安装。

### 5.3 实测结论（本机，2026-11-11）

| 机制 | 实测结果 |
|---|---|
| `uv sync`（`UV_PROJECT_ENVIRONMENT=.venv`） | ✅ 装到 `.tools/.venv`，系统 `python3 -c "import httpx"` 仍报 `ModuleNotFoundError` → **未污染** |
| `bun install`（cwd=`node/`） | ✅ 31 包装到 `.tools/node/node_modules`，`command -v loadtest` 无输出 → **未污染** |
| `uvx bandit --version` | ✅ `bandit 1.9.4` 正常返回 |
| `uvx semgrep` | ⚠️ 能下载依赖（拉了 cryptography、pydantic-core），Python 3.14 下兼容性待最终验证 |
| bun 本地安装的 postinstall | ⚠️ `bun install` 报 `Blocked 1 postinstall` → 需在 manifest 里显式声明信任或改用免 postinstall 的包 |

### 5.4 ⚠️ 硬约束：分发通道只有 PyPI 与 npm 两条

实测（本机）：

| 通道 | 可达性 | 影响 |
|---|---|---|
| `pypi.tuna.tsinghua.edu.cn` | ✅ 200 | `uvx` / `uv sync` 可用 |
| `registry.npmmirror.com` | ✅ 200 | `bun install` 可用 |
| `github.com/.../releases/download/` | ❌ 返回 `Not Found`（9 字节） | **单二进制直下不可用** |
| `registry.npmmirror.com/-/binary/{trivy,semgrep,k6,vegeta}` | ❌ 全部 404 | 二进制镜像路径不可用 |
| Docker daemon | ❌ `inactive`，无 `/var/run/docker.sock` | **容器通道不可用** |

**结论**：**只有 PyPI 与 npm 两条分发通道可用**。

**直接影响工具选型**：

> 优先选**能在 PyPI 或 npm 上分发**的工具（`uvx` / `bun add` 即可拿到）；单二进制工具与容器化工具在本机不可用。

安全工具的具体影响：

| 工具 | 分发方式 | 本机可用性 |
|---|---|---|
| `bandit`（Python 静态扫描） | PyPI → `uvx bandit` | ✅ 实测 1.9.4 |
| `semgrep`（跨语言静态扫描） | PyPI → `uvx semgrep` | ⚠️ 能装，Python 3.14 兼容性待验 |
| `nuclei`（扫描器生态最全） | GitHub releases | ❌ 不可用 |
| `trivy` / `osv-scanner`（依赖漏洞） | GitHub releases | ❌ 不可用 |
| `pip-audit`（PyPI 依赖漏洞） | PyPI → `uvx pip-audit` | ⏳ 待验，**这是依赖漏洞扫描的可行替代** |
| `npm audit`（npm 依赖漏洞） | 内置于 npm | ✅ 走 npmmirror |

**因此"安全测试含依赖扫描"这一决策的实现路径是**：`bandit`（源码静态扫描）+ `pip-audit` / `npm audit`（依赖漏洞），而非 `nuclei` / `trivy`。若未来环境恢复 GitHub 访问，manifest 支持新增二进制工具即可，无需改设计。

### 5.5 工具选型（据实测修正）

| 用途 | 工具 | 运行时 | 状态 |
|---|---|---|---|
| 压测 | `loadtest@8.2.1` | **bun** | ✅ 实测 42,255 rps（bun TCP）vs 2,907（node HTTP），**快 14.5×** |
| HTTP 执行 | `httpx` | uv | ✅ 实测本地安装不污染系统 |
| 数据校验 | `pydantic` | uv | ✅ |
| 报告渲染 | `jinja2` | uv | ✅ |
| Python 静态安全扫描 | `bandit` | uvx | ✅ 实测 1.9.4 |
| 跨语言静态扫描 | `semgrep` | uvx | ⚠️ Python 3.14 兼容性待验 |
| Python 依赖漏洞 | `pip-audit` | uvx | ⏳ 待验（替代 trivy） |
| npm 依赖漏洞 | `npm audit` | 内置 | ✅ 走 npmmirror |
| 目录契约校验 | 自研 | **bun**（`.mjs`） | ✅ 零依赖跨平台 |
| 编排胶水 | 自研 | uv (Python) | httpx + pydantic 生态 |

### 5.6 关于 Python 压测工具

用户原本倾向 Python 侧的压测工具（Locust 一类）。对比后仍推荐 `loadtest`，但**两者可共存**：

| | `loadtest`（bun） | Locust（Python/uv） |
|---|---|---|
| 复杂业务流（登录→下单→支付） | ❌ 只能靠 `-P/-H` 参数化，流程受限 | ✅ 场景用 Python 写，任意编排 |
| 分布式压测 | ❌ | ✅ master/worker |
| 实时监控 UI | ❌ | ✅ Web UI |
| 简单单接口压测 | ✅ 极简，一行命令 | 需写场景文件 |
| 依赖 | npm（bun 本地装） | Python（uv 本地装） |

**结论**：单接口/单端点压测（容量摸底、找拐点）用 `loadtest`；**多步骤业务流程压测**（真实下单链路）需要 Locust 或自研脚本。

由于本项目定位是"通用框架"，建议 `load-profile` skill **生成负载模型 → 由执行器适配**：`load-scenario.json` 加一个 `runner` 字段（`loadtest` / `python`）区分即可，skill 本身不绑定工具。

### 5.7 调用约定

**统一入口，禁止直接调第三方工具**：

```bash
# 功能测试
.tools/bin/qa run --suite REQ-001-coupon --env staging

# 压测
.tools/bin/qa load --scenario checkout --env staging

# 安全扫描（自动自举 bandit）
.tools/bin/qa scan --env staging
```

**为什么坚持统一入口**：

1. **参数一致性**——每次都手写 `-c 100 --rps 200 -k`，迟早有人漏参数导致结果不可比；
2. **证据自动落盘**——直接调工具不会有证据，证据是执行器的责任；
3. **自举透明**——用户不需要知道工具装没装、装在哪，入口负责；
4. **参数可追溯**——`run.json` 记录完整命令行 + 工具版本 + 运行时版本，结果可复现；
5. **单点适配**——换工具只改 manifest 与胶水，用例与配置不动。

### 5.8 "单二进制优先"的取舍

用户原则是"尽量使用单二进制程序"。结合实测，调整为：

> **第三方工具优先"单一分发单元"**——能 `uvx` 拿到就 `uvx`，能 `bun add` 拿到就 `bun add`，都是零全局污染的一次性获取。
>
> **胶合逻辑用 uv/bun 托管**——依赖锁进仓库，环境可复现。

完全单二进制做不到：HTTP 执行、证据采集、报告生成都需要胶水逻辑。且本机 GitHub 不可达，单二进制路径本就受限——**PyPI/npm 分发在当前网络环境下反而是"最接近单二进制"的可行形态**（一次获取、零全局污染）。

### 5.9 环境自举

首次使用：

```bash
.tools/bin/qa doctor          # 检查缺什么，报告将要安装什么
.tools/bin/qa bootstrap       # 按 manifest 装齐（只装本地副本）
```

**两条纪律**：

- `uv.lock` / `bun.lock` **必须进 Git**——否则依赖漂移，测试结果不可比；
- 工具版本记进 `run.json` 的 `tool_versions`，保证结果可追溯。

## 6. 套件 skill 清单（修订）

| skill | 轮次 | 范围 | 状态 |
|---|---|---|---|
| `test-case-design` | R1 | 功能 | ✅ 已交付，待 REQ-002 改造 |
| `regression-plan` | R2 | 功能 | ⏳ 待建 |
| `defect-verify` | R3 | 全部 | ⏳ 待建 |
| `security-plan` | R1/R2 | 安全 | ⏳ 待建（OWASP 全套） |
| `load-profile` | R1/R2 | 压测 | ⏳ 待建（loadtest + bun） |
| `test-report` | 全部 | 全部 | ⏳ 待建（消费所有轮次产出） |
| `test-execute` | R1/R2/R3 | 功能+安全 | ⏳ 待建（执行 + 证据采集） |

**依赖顺序**：

```text
test-case-design (R1 用例)
      ↓
test-execute (执行 + 证据) ──→ test-report
      ↑                              ↑
regression-plan (R2) ───────────────┘
defect-verify (R3)
security-plan (安全用例) ──┘
load-profile (压测场景) ──┘
```

---

## 7. 决策状态（已对齐）

| # | 问题 | 决策 |
|---|------|------|
| Q1 | 压测工具 | ✅ **npm `loadtest`**（本机实测可跑，bun TCP 模式 42,255 rps） |
| Q2 | 压测运行时 | ✅ **bun**（比 node 快 14.5×） |
| Q3 | 证据是否进 Git | ✅ **不进 Git，脱敏后进制品库**（见 §4.5） |
| Q4 | 安全测试是否含依赖扫描 | ✅ **含**（受分发通道限制，依赖扫描用 `pip-audit` + `npm audit` 替代 trivy/osv-scanner，见 §5.4） |
| Q5 | `.tools/` 命名 | ✅ **特殊名称 `.tools/` 单独标识**（工具 vs 资产的语义区分，见 §5.1） |
| Q6 | REQ-002 范围 | ✅ **扩展**——含 R1 改造 + R2/R3 + 安全 + 压测（见 §8） |
| Q7 | 轮次状态写入者 | ✅ 执行者写轮次状态，BA 写用例生命周期状态（§3.2） |

## 8. REQ-002 扩展后的拆分

用户决策 REQ-002 扩展到覆盖全部能力域。但**7 个 skill 一次性做完不现实**——schema 还没稳定就并行分叉必然返工（这正是 REQ-001 eval 暴露的风险模式）。

建议：**REQ-002 作为一个 Epic**，内部拆成子 REQ，共享同一套 schema v2 与目录契约：

| 子 REQ | 内容 | 依赖 | 产出 |
|---|---|---|---|
| **REQ-002.1** | schema v2（`open_questions` / `method` / `coverage_matrix` / 用例生命周期状态）+ 校验器强制 | — | skill 改造 + 校验器 |
| **REQ-002.2** | 方法库（`catalog.json` + M0–M4 详库）+ SKILL.md 重写（运行时工作区契约） | 002.1 | 方法库 + skill 本体 |
| **REQ-002.3** | 目录契约（`test-assets/` + `environments/` + `cycles/`）+ `verify-layout.mjs` | 002.1 | 目录契约 + 校验器 |
| **REQ-002.4** | `.tools` 自举机制（`manifest.json` + `bin/qa` + 统一入口） | 002.3 | 工具链 |
| **REQ-002.5** | `test-execute` skill + 证据链（`meta.json` / `reproduction` / sha256） | 002.1, 002.4 | 执行 + 证据 |
| **REQ-002.6** | `regression-plan` skill（R2：变更影响分析 + 用例选择） | 002.1, 002.2 | R2 能力 |
| **REQ-002.7** | `defect-verify` skill（R3：复现用例生成） | 002.5 | R3 能力 |
| **REQ-002.8** | `security-plan` skill（OWASP 全套 + 依赖扫描） | 002.2, 002.4 | 安全能力 |
| **REQ-002.9** | `load-profile` skill（负载模型 + runner 适配） | 002.4 | 压测能力 |
| **REQ-002.10** | `test-report` skill（消费所有轮次产出） | 002.5, 002.6 | 报告能力 |

**并行批次划分**（文件所有权互斥）：

| 批次 | 子 REQ | 可并行理由 |
|---|---|---|
| B1 | 002.1 + 002.3 | 002.1 改 `validate-cases.mjs`，002.3 新增 `verify-layout.mjs`，文件不重叠 |
| B2 | 002.2 + 002.4 | 002.2 改 `SKILL.md`/`methods/`，002.4 改 `.tools/`，不重叠 |
| B3 | 002.5 + 002.6 + 002.8 + 002.9 | 四个新 skill，各自独立目录 |
| B4 | 002.7 + 002.10 | 依赖 B3 完成 |

**关键约束**：002.1 必须最先完成并合并——它是所有后续子 REQ 的 schema 依赖。

## 9. 遗留风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| **GitHub 不可达** | 单二进制安全工具（nuclei/trivy）不可用 | 已用 `bandit` + `pip-audit` + `npm audit` 替代；manifest 支持未来新增 |
| **semgrep 在 Python 3.14 下兼容性未知** | 跨语言静态扫描可能不可用 | 已在 manifest 中锁 `requires-python`；不可用则降级为仅 bandit |
| **bun 阻止 postinstall** | 部分需要编译的 npm 包装不上 | manifest 显式声明信任；优先选纯 JS 包 |
| **Docker daemon 未运行** | 容器化压测/扫描不可用 | 当前设计不依赖 Docker |
| **用例量可能膨胀** | Layer 0 = 6 条基线，每条目 ≥6 条用例 | 已配套 `skipped-with-reason` 机制；用 eval 实测密度对比裸模型 |
