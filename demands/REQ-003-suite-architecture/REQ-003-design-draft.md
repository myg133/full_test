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

### 4.5 证据的生命周期

| 阶段 | 位置 | 进 Git? |
|---|---|---|
| 执行产生 | `.test-artifacts/` | ❌ |
| 归档（附到 bug 单） | `test-assets/cycles/<cycle>/evidence/` 或 CI 制品 | 视密级定 |
| 复现验证后清理 | 按保留策略 | — |

**默认不进 Git**——证据可能含敏感数据（token、真实用户 ID）。若需要随仓库留存，必须先脱敏（`meta.json` 里的 `redaction` 字段声明脱敏项）。

---

## 5. 工具链与 `.tools` 目录

### 5.1 `.tools` 与"可见名"规则的协调

agent-workspace 规范：**要进 Git 的目录用可见名，纯本地状态才用 `.` 前缀**。

`.tools/` 是要进 Git 的（团队共享工具），但用了 `.` 前缀——这是**有意的例外**，理由：

- `.tools/` 是**工具**（工具链配置 + 脚本），不是**资产**（用例、环境）；
- 与 `test-assets/` 语义区分；
- 隐藏名让 IDE 和 `ls` 默认不展开，减少干扰。

**结论**：`.tools/` 进 Git，但需在项目 README 中显式声明此例外。`.gitignore` 内只忽略其内部的依赖与缓存目录。

### 5.2 工具目录结构

```text
<project-root>/.tools/
├── README.md                 # 工具清单 + 调用约定
├── pyproject.toml            # uv 依赖声明
├── uv.lock                   # 锁文件（进 Git，保证可复现）
├── package.json              # bun 依赖声明
├── bun.lock                  # 锁文件
├── bin/                      # 胶水脚本（薄封装，团队自维护）
│   ├── run-suite.py          # 功能测试执行器
│   ├── run-security.py       # 安全测试执行器
│   ├── run-load.mjs          # 压测执行器（调 loadtest）
│   ├── collect-evidence.py   # 证据采集与摘要
│   └── verify-layout.mjs     # 目录契约校验
├── python/
│   └── qatest/               # 自研 Python 包
│       ├── __init__.py
│       ├── runner.py
│       ├── evidence.py
│       └── assertions.py
└── js/
    └── loadrunner.mjs        # 压测封装
```

### 5.3 工具选型

| 用途 | 工具 | 运行时 | 理由 |
|---|---|---|---|
| 压测 | `loadtest@8.2.1` | **bun** | ab 兼容 + `--rps` 强制速率 + WebSocket；**本机实测 bun TCP 模式 42,255 rps vs node HTTP 模式 2,907 rps（快 14.5×）** |
| HTTP 执行 | `httpx` | uv | 现代 async HTTP 客户端，uv 装极快 |
| 数据校验 | `pydantic` | uv | schema 校验与序列化 |
| 报告渲染 | `jinja2` | uv | HTML 报告模板 |
| 静态安全扫描 | `bandit` / `semgrep` | uvx | 免安装，`uvx bandit` 直接跑 |
| 依赖漏洞 | `trivy` / `osv-scanner` | 单二进制 | 单文件、跨平台 |
| 目录契约校验 | 自研 | **bun**（`.mjs`） | 零依赖、跨平台 |
| 编排胶水 | 自研 | uv (Python) | httpx + pydantic 生态更顺 |

**压测运行时必须锁版本**。`run.json` 需记录：

```json
{
  "tool_versions": {
    "loadtest": "8.2.1",
    "bun": "1.4.4",
    "node": "26.10.0"
  },
  "command": ["bun", "run", "node_modules/loadtest/bin/loadtest.js", "http://...", "--cores", "1", "--tcp"]
}
```

压测结论（rps、延迟分位）只有在**工具版本 + 运行时版本 + 完整命令行**三者都可追溯时才有意义。bun 与 node 之间 14.5× 的差距就是最好的例证——换运行时不换记录，结论就废了。

### 5.4 调用约定

**统一入口，禁止直接调第三方工具**：

```bash
# 功能测试
uv run --project .tools/bin run-suite.py --suite REQ-001-coupon --env staging

# 压测
bun run .tools/bin/run-load.mjs --scenario checkout --env staging

# 安全静态扫描（免安装）
uvx bandit -r src/ -f json
```

**为什么坚持统一入口**：

1. **参数一致性**——每次都手写 `-c 100 --rps 200 -k`，迟早有人漏参数导致结果不可比；
2. **证据自动落盘**——直接调工具不会有证据，证据是执行器的责任；
3. **参数可追溯**——`run.json` 记录完整命令行 + 工具版本，结果可复现；
4. **单点适配**——换工具只改胶水脚本，用例与配置不动。

### 5.5 "单二进制优先"的取舍

用户原则是"尽量使用单二进制程序"。但实测下来：

- **完全单二进制做不到**——HTTP 执行、证据采集、报告生成都需要胶水逻辑；
- **可行的折中**：**第三方工具优先单二进制**（trivy、osv-scanner、nuclei 这类装了就完事），**胶合逻辑用 uv/bun 托管**（依赖锁进仓库，环境可复现）。

具体清单：

| 类型 | 工具 | 形态 |
|---|---|---|
| 第三方独立工具 | `trivy`、`osv-scanner`、`nuclei` | 单二进制 |
| 第三方库 | `httpx`、`pydantic`、`jinja2` | uv/bun 管理 |
| 压测 | `loadtest` | npm，bun 运行 |
| 自研胶水 | runner / evidence / verify | uv (Python) + bun (JS) |

### 5.6 环境自举

首次使用：

```bash
cd .tools
uv sync                      # 装 Python 依赖（按 uv.lock）
bun install                  # 装 JS 依赖（按 bun.lock）
```

**两条纪律**：

- `uv.lock` / `bun.lock` **必须进 Git**——否则依赖漂移，测试结果不可比；
- 工具版本记进 `run.json`（`tool_versions` 字段），保证结果可追溯。

---

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

## 7. 待确认项

| # | 问题 | 我的建议 |
|---|------|---------|
| Q1 | "loast" 确认是 npm `loadtest` 吗？ | 是（npm 上 `loast` 是 Lighthouse API 专用工具，与压测无关） |
| Q2 | 压测运行时用 bun 还是 node？ | **bun**（实测 TCP 模式 62k vs node 19k rps） |
| Q3 | 证据默认是否进 Git？ | **不进**（可能含敏感数据）；归档走 CI 制品或脱敏后入库 |
| Q4 | 安全测试做到哪层——只测本应用，还是含依赖扫描？ | 含依赖扫描（trivy/osv-scanner），但作为独立子项而非用例 |
| Q5 | `.tools/` 用 `.` 前缀的例外是否接受？ | 接受（工具 vs 资产的语义区分），需在 README 声明 |
| Q6 | REQ-002 是否扩到包含 R2/R3/安全/压测？ | **不扩**——REQ-002 只做 R1 改造（地基），其余按 §6 顺序分 REQ |
| Q7 | 轮次状态由谁写——BA 还是执行者？ | 执行者写轮次状态，BA 写用例生命周期状态（§3.2） |
