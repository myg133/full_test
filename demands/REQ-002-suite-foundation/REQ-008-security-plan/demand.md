# REQ-008 —— 安全能力域：`security-plan` skill（OWASP 全套 + 依赖扫描）

- **需求编号**: REQ-008
- **原编号**: `REQ-002.8`（架构文档 §8 的编号映射：REQ-002.8 = `security-plan` skill，依赖 **002.2 + 002.4**）
- **优先级**: P1
- **状态**: 契约已定稿（验收判据 29 条 / AC-001~AC-029；决策 D98~D126）
- **上游依据**: `architecture-design.md` §8（拆分表 + 依赖表 + 批次表 B3）；
  `project-layout.md` §2.2 / §3.1 / §3.3（目录契约与 `suite.json` 封闭字段集）；
  `case-schema.md`（cases.json v2）；`dimensions.json`（含 `security`）；`methods.json`（M2.1~M2.3）

> 本文件是**契约**，不是说明材料。实现者按这里的规则交付，验收脚本按这里的规则判定。
> 判据见 `acceptance.md`（AC-001~AC-029）；决策记录见 `decisions.md`（D98 起）。

---

## 0. 背景与边界

### 0.1 缺口具体长什么样

已交付的 5 个 skill（`qa-toolchain` / `regression-plan` / `test-case-design` / `test-execute` / `test-report`）
把**功能测试**这条链路拉通了：**能设计用例 → 能选样 → 能执行 → 能出报告 → 能沉淀缺陷**。

**安全能力域**至今是空的：

| 环节 | 状态 | 缺口 |
|---|---|---|
| 安全上下文梳理 | ❌ 无 | 资产 / 信任边界 / 入口点没人梳理 |
| 威胁建模（OWASP + STRIDE） | ❌ 无 | 没有威胁清单 ⇒ 谈不上安全覆盖 |
| 权限矩阵 | ❌ 无 | 越权缺口靠人肉看 |
| 从威胁派生安全用例 | ❌ 无 | 威胁到可执行用例之间没有工序 |
| 依赖扫描接入 | ❌ 无 | 扫描器装了，但结果没人接进威胁模型 |
| 安全用例**执行** | ⚠️ **属后续 REQ** | `security` 执行器**未实现**（`test-execute/executors/index.json` 的 `not_implemented`） |

### 0.2 本 REQ 只负责**规划**，不负责**执行**

⚠️ 这是本 REQ 最容易被走样的一处边界，先说清楚：

- `test-execute/executors/index.json` 的 `not_implemented` = `["ui", "load", "security"]`，
  其 note 原文写着「需求 F2 的 executor 枚举还包含 ui / load / security（**分别属后续 REQ**）。本 REQ 只交付 api 与 mock」。
- `run-suite.mjs` 的**执行器查找在 dry-run 分支之前** ⇒ 对 `executor=security` 的套件，
  `--dry-run` 会**先抛错**「执行器 "security" 尚未实现」，**根本到不了 dry-run 分支**。

⇒ **本 REQ 交付的是「安全测试的规划」**：威胁模型 + 权限矩阵 + 安全用例集 + 套件配置。
**执行**属后续 REQ（注册 `security` 执行器）。判据里凡写「可被消费」的地方，
一律指**加载层**可解析（`loadSuite()` / `loadCases()` / `selectCases()` + 过 `validate-cases.mjs`），
**不要求**执行器能跑 —— 判据正文里已逐条点明「加载层」三个字。

### 0.3 环境硬约束（不可协商，直接决定「不做什么」）

| 约束 | 后果 |
|---|---|
| 仅 PyPI 镜像与 npmmirror 可达；**GitHub releases 不可达** | `nuclei` / `trivy` / `osv-scanner` 等单二进制工具**装不上** ⇒ **不得写进工具清单** |
| npmmirror 的**二进制镜像 404** | 纯 JS 工具可装；预编译二进制不可得 |
| Docker daemon 未运行 | 无容器化隔离 |
| 工具装不上必须**显式报 `failed` / `unavailable`**，不得静默跳过 | 见 F7 |

⇒ **依赖扫描由 agent 用已交付的 `qa-toolchain`（`bin/qa`）跑 bandit / npm audit**，
`security-plan` **自己一个扫描器都不跑**（零第三方依赖、不联网、保持纯函数化可测）。

---

## 1. 目标

1. 交付 **`security-plan` skill**（第 7 个 skill）：读**安全上下文** → 产出
   **威胁模型** + **权限矩阵** + **安全用例集** + **安全套件配置**。
2. 威胁模型覆盖 **OWASP A01~A10 十类**；某类确实不适用时**显式记 `not_applicable` + 非空理由 + 一条未决问题**，
   **不许静默跳过**（静默跳过 = 假的「已经覆盖了」）。
3. 四类实战补充（**文件上传 / SSRF / XXE / 反序列化**）**逐类显式判定**（有威胁 / 不适用+理由）。
4. 每条威胁**至少派生 1 条**安全用例；用例能被 `test-execute` 的**加载层**解析。
5. 全程**只读**输入、**只写**自己的输出目录、**幂等**（同一输入两次，除 `meta.generated_at` 外逐字相同）。

---

## 2. 功能项 F1~F8

### F1 输入契约

#### F1.1 命令行

```
node skills/security-plan/scripts/make-security-plan.mjs \
  --context <安全上下文.json> \
  [--cases <功能用例集 cases.json>] \
  [--scan <扫描结果.json>] \
  [--environment <环境名>] \
  [--requirement <需求编号>] \
  --out-dir <目标项目根>
```

| 参数 | 必需 | 语义 |
|---|---|---|
| `--context` | **是** | 安全上下文 JSON（形状见 F1.2） |
| `--cases` | 否 | 功能套件用例集（**攻击面枚举的补充输入**） |
| `--scan` | 否 | 依赖扫描结果（形态见 F7.2） |
| `--environment` | 否 | 套件 `environment` 字段取值；缺省时取 `<out-dir>/test-assets/environments/` 下**按文件名排序的第一个**环境 |
| `--requirement` | 否 | 套件 `requirement` 字段取值；缺省时取上下文的 `service.name` |
| `--out-dir` | **是** | 目标**项目根**；产物落在 `<out-dir>/test-assets/security/` 下 |

#### F1.2 安全上下文 JSON（字段集由本 REQ 定）

```json
{
  "schema_version": 1,
  "service": { "name": "order-api", "description": "订单服务" },
  "assets": [
    { "id": "AS-1", "name": "用户口令哈希", "sensitivity": "critical", "description": "…" },
    { "id": "AS-2", "name": "订单数据", "sensitivity": "high", "description": "…" },
    { "id": "AS-3", "name": "访问日志", "sensitivity": "medium", "description": "…" }
  ],
  "trust_boundaries": [
    { "id": "TB-1", "name": "公网 ↔ 应用", "from": "互联网", "to": "应用网关",
      "controls": ["TLS 终止", "WAF 规则"] },
    { "id": "TB-2", "name": "应用 ↔ 数据层", "from": "应用进程", "to": "数据库",
      "controls": ["参数化查询"] }
  ],
  "entry_points": [
    { "id": "EP-1", "name": "登录接口", "kind": "http",
      "asset_refs": ["AS-1"], "boundary_refs": ["TB-1"], "description": "POST /api/login" },
    { "id": "EP-2", "name": "订单详情接口", "kind": "http",
      "asset_refs": ["AS-2"], "boundary_refs": ["TB-1"], "description": "GET /api/orders/{id}" },
    { "id": "EP-3", "name": "日志写入", "kind": "file",
      "asset_refs": ["AS-3"], "boundary_refs": ["TB-2"], "description": "写访问日志" }
  ],
  "roles": [
    { "id": "ROLE-1", "name": "匿名访客" },
    { "id": "ROLE-2", "name": "登录用户" },
    { "id": "ROLE-3", "name": "管理员" }
  ],
  "resources": [
    { "id": "RES-1", "name": "订单", "asset_refs": ["AS-2"] },
    { "id": "RES-2", "name": "用户账号", "asset_refs": ["AS-1"] }
  ]
}
```

**结构层约束**（违反 ⇒ 报错退出 rc=1，见 F1.4）：

| 位置 | 约束 |
|---|---|
| 根 | 必须是对象 |
| `schema_version` | 可选；若存在必须是 `1` |
| `service` | 必须是对象；`service.name` **必填**且非空字符串 |
| `assets` | **必填**，非空数组；每项 `id`（合 `^AS-\d{1,3}$`、文件内唯一）、`name`（非空）、`sensitivity`（枚举 `critical` / `high` / `medium` / `low`）、`description`（可选非空字符串） |
| `trust_boundaries` | **必填**，非空数组；每项 `id`（合 `^TB-\d{1,3}$`、唯一）、`name`（非空）、`controls`（**必填**数组，元素为非空字符串，可为空数组）、`from` / `to`（可选非空字符串） |
| `entry_points` | **必填**，非空数组；每项 `id`（合 `^EP-\d{1,3}$`、唯一）、`name`（非空）、`kind`（非空字符串，自由取值）、`asset_refs`（**必填非空**数组，每项 ∈ `assets[].id`）、`boundary_refs`（**必填非空**数组，每项 ∈ `trust_boundaries[].id`）、`description`（可选） |
| `roles` | **必填**，非空数组；每项 `id`（合 `^ROLE-\d{1,3}$`、唯一）、`name`（非空） |
| `resources` | **必填**，非空数组；每项 `id`（合 `^RES-\d{1,3}$`、唯一）、`name`（非空）、`asset_refs`（**必填非空**数组，每项 ∈ `assets[].id`） |

⚠️ **`roles` / `resources` 为什么也是必填**：F4 的权限矩阵是「角色 × 资源 × 动作」，
角色与资源必须**有出处**（来自上下文），不能由实现凭空捏造 —— 否则矩阵就是自说自话。

#### F1.3 `--cases` 输入

可选。形状是上游 **cases.json v2**（`schema_version: 2`，顶层 7 字段封闭）。
用途仅限**攻击面枚举的补充输入**（从功能用例里看出还有哪些输入面）。
本 skill **不消费**它的用例 id（不复用、不改写），但**产出的安全用例 id 不得与它的 id 冲突**（见 F5.3）。

#### F1.4 两层划分：用法错 vs 输入非法

| 情形 | 退出码 | 说明 |
|---|---|---|
| 缺必需参数（`--context` / `--out-dir`）、参数不认识的开关 | **2** | 调用方式错误（与「输入非法」分开，与上游 `validate-cases.mjs` / `run-suite.mjs` 的口径一致） |
| 参数给了但**内容非法**（缺字段 / 类型错 / 枚举越界 / id 重复 / id 格式错 / 引用悬空 / `--scan` 形态无法识别） | **1** | stderr **点名是什么坏了**（含字段名与出错值）；**不得产出任何产物**（F1.5） |

> **内容非法 ⇒ rc=1 且不留半份产物**：判据 AC-005~AC-008 检查的是**输出目录的实况**，
> 不是「实现有没有打印错误」。一个「先建目录再报错」的实现同样判红。

#### F1.5 产物落位与「已存在即报错」

```
<out-dir>/test-assets/security/
├── threat-model.json
├── matrix.json
└── suites/
    └── SEC-<编号>-<短名>/
        ├── cases.json
        └── suite.json
```

- 只写 `<out-dir>/test-assets/security/`（其余一律**只读**）。
- 若 `<out-dir>/test-assets/security/` 下**已存在** `threat-model.json`、`matrix.json`
  或任何 `suites/*` 目录 ⇒ **报错退出 rc=1**，**不得覆盖**（「产物已存在即报错」）。

---

### F2 威胁模型（`test-assets/security/threat-model.json`）

#### F2.1 顶层结构

```json
{
  "schema_version": 1,
  "meta": { "service": "order-api", "generated_at": "…", "threat_count": 12, "context_ref": "context.json" },
  "assets": [ { "id": "AS-1", "name": "…", "sensitivity": "critical" } ],
  "trust_boundaries": [ { "id": "TB-1", "name": "…", "controls": ["…"] } ],
  "entry_points": [ { "id": "EP-1", "name": "…", "kind": "http" } ],
  "threats": [ … ],
  "owasp_coverage": { "A01": { … }, … },
  "supplements": { "file_upload": { … }, "ssrf": { … }, "xxe": { … }, "deserialization": { … } },
  "scan": { "status": "provided", "tool": "bandit", "source_file": "bandit.json", "finding_count": 2 },
  "scan_findings": [ … ],
  "open_questions": [ … ]
}
```

- `assets` / `trust_boundaries` / `entry_points` 三段与**输入上下文**逐条对应（**集合相等**：不增、不减、不改 id）。
- `meta` 的字段集**开放**（额外说明字段不构成违规）。

#### F2.2 威胁条目字段集（**封闭 12 个**）

| 字段 | 类型 | 约束 |
|---|---|---|
| `id` | string | **必填**，合 `^TH-\d+$`，文件内唯一 |
| `name` | string | **必填**，非空 |
| `category` | string | **必填**，枚举（STRIDE 六类）：`spoofing` / `tampering` / `repudiation` / `information_disclosure` / `denial_of_service` / `elevation_of_privilege` |
| `owasp` | string | **必填**，枚举 `A01`~`A10` |
| `asset_refs` | string[] | **必填非空**，每项 ∈ 上下文的 `assets[].id` |
| `boundary_refs` | string[] | **必填非空**，每项 ∈ 上下文的 `trust_boundaries[].id` |
| `entry_point_refs` | string[] | **必填非空**，每项 ∈ 上下文的 `entry_points[].id` |
| `severity` | string | **必填**，枚举 `critical` / `high` / `medium` / `low` |
| `source` | string | **必填**，枚举 `model` / `scan` / `model+scan` |
| `scan_refs` | string[] | **必填**（可为空数组），元素 ∈ `scan_findings[].id`；`source` 含 `scan` ⇔ 本数组非空 |
| `supplement_refs` | string[] | **必填**（可为空数组），元素 ∈ {`file_upload`, `ssrf`, `xxe`, `deserialization`} |
| `rationale` | string | **必填**，非空（说清为什么这条威胁成立） |

---

### F3 OWASP 覆盖完整性（**诚实性红线**）

#### F3.1 十类必须有交代

`owasp_coverage` 的键集**恰为** `A01`~`A10`（10 个，不多不少）。每一类的取值二选一：

```json
"A01": { "status": "covered", "threat_refs": ["TH-3", "TH-7"] },
"A02": { "status": "not_applicable", "reason": "本服务不存储口令、不做加密运算、无密钥管理环节", "open_question_ref": "Q-1" }
```

| 规则 | 说明 |
|---|---|
| `status` | 枚举 `covered` / `not_applicable` |
| `covered` ⇒ `threat_refs` | **非空**数组，且**恰为**该类的全部威胁 id（每项 ∈ `threats[].id` 且**被引用威胁的 `owasp` 必须等于该类**；反过来，该类的每条威胁都必须出现在这个数组里） |
| `not_applicable` ⇒ `reason` | **非空**字符串 |
| `not_applicable` ⇒ `open_question_ref` | 指向 `open_questions[]` 里**存在**的一条（其 `category` 字段等于该 OWASP 类） |
| **不许静默跳过** | 既没有 `covered` 声明、也没有 `not_applicable` 声明 ⇒ 违规（假的「已经覆盖了」） |

⚠️ **契约不指定「哪一类必须不适用」**：适用性判断属于实现（它看得见服务形态），
契约只强制**交代完整 + 理由非空 + 留了未决问题**。这既避免把实现方的判断写死，
也避免用「十类都必须硬造一条威胁」来掩盖「这项目真的没有加密环节」。

#### F3.2 未决问题（`open_questions[]`）

```json
{ "id": "Q-1", "category": "A02", "question": "本服务是否真的不涉及任何密码学环节？", "reason": "…" }
```

- `id` 必填、唯一、非空；`category` ∈ `A01`~`A10` 或四个补充类键；`question` 与 `reason` 非空。
- **只存在于 `threat-model.json`**（见 F5.4 的说明：cases.json 的 `open_questions` 是 v2 形状，
  它的 `requirement_refs` 必须指向**真实存在**的需求条目，而「不适用的类」没有威胁、也就没有需求条目 ——
  硬塞会造出悬空引用）。

#### F3.3 四类实战补充

`supplements` 的键集**恰为** 4 个：`file_upload` / `ssrf` / `xxe` / `deserialization`。
取值形状与 `owasp_coverage` **同构但少一项**：取值二选一
（`covered` + `threat_refs` / `not_applicable` + `reason`），**不要求** `open_question_ref`
（补充类不是 OWASP 类，不进 OWASP 覆盖表；若给了则必须指向 `open_questions[]` 里存在的一条）。
外加两条：`covered` 时，被引用威胁的 `supplement_refs` **必须含该键**，
且 `threat_refs` **恰为** `supplement_refs` 含该键的全部威胁 id。

**不强制**每个项目都有这四类威胁，但**必须逐类显式判定**。

---

### F4 权限矩阵（`test-assets/security/matrix.json`）

```json
{
  "schema_version": 1,
  "meta": { "generated_at": "…" },
  "roles": [ { "id": "ROLE-1", "name": "匿名访客" } ],
  "resources": [ { "id": "RES-1", "name": "订单" } ],
  "entries": [
    { "role": "ROLE-1", "resource": "RES-1", "action": "read", "decision": "deny",
      "basis": "expected", "threat_ref": null, "note": "未登录不可读" },
    { "role": "ROLE-2", "resource": "RES-2", "action": "read", "decision": "allow",
      "basis": "gap", "threat_ref": "TH-7", "note": "只校验登录未校验归属，可越权读他人账号" }
  ]
}
```

| 字段 | 约束 |
|---|---|
| `roles` / `resources` | 与上下文对应段**集合相等**（id 集合相同、条数相同） |
| `entries` | **非空**数组 |
| `entries[].role` / `entries[].resource` | 必须 ∈ `roles[].id` / `resources[].id`（**不悬空**） |
| `entries[].action` | 非空字符串 |
| `entries[].decision` | 枚举 `allow` / `deny` |
| `entries[].basis` | 枚举 `expected` / `gap` |
| `entries[].threat_ref` | `null` 或 ∈ `threats[].id` |
| `entries[].note` | 可选字符串 |

**覆盖要求**：`(role, resource)` 的**每个组合**至少有一条 `entries` 记录。

**允许缺口口径**（`basis`）：

| `basis` | 含义 | 约束 |
|---|---|---|
| `expected` | 该决策是**预期行为** | `threat_ref` 必须为 `null` |
| `gap` | **本应拒绝却允许**的缺口 | `decision` 必须为 `allow`；`threat_ref` 必须**非空**且指向一条 `category == "elevation_of_privilege"`（越权类）的威胁 |

**双向对应**：每条 `category == "elevation_of_privilege"` 的威胁，**必须**被至少一条 `basis == "gap"` 的条目引用。
（越权类威胁必须有对应的矩阵缺口，否则「威胁」落不到矩阵上，等于悬空。）

---

### F5 从威胁派生安全用例

#### F5.1 派生规则

- 每条威胁**至少派生 1 条**安全用例；每条用例的 `requirement_refs` 指向**该威胁**对应的需求条目。
- **不得重复派生**：同一威胁下的用例 `title` 必须**互不相同**，`steps` 不得完全相同。

#### F5.2 产物 cases.json 的顶层字段集（**封闭 7 个**）

```json
{
  "schema_version": 2,
  "meta": { "source": "security-plan", "generated_at": "…", "case_count": 12 },
  "requirements": [
    { "id": "R-1", "title": "TH-1 登录凭据可被暴力猜测", "source_ref": "threat-model.json#/threats/TH-1", "testable": true }
  ],
  "open_questions": [],
  "coverage_matrix": [
    { "requirement": "R-1", "methods_applied": ["M2.1"], "skipped": [], "dimensions": ["security"] }
  ],
  "defects": [],
  "cases": [
    { "id": "TC-001", "title": "登录接口对连续失败不锁定账号", "requirement_refs": ["R-1"],
      "dimension": "security", "priority": "P0", "method": ["M2.1"], "status": "active",
      "preconditions": [], "steps": [ { "action": "连续用错误口令调用登录接口 10 次", "expected": "第 10 次仍返回可用响应且无锁定提示" } ],
      "data": {}, "tags": ["security", "TH-1"] }
  ]
}
```

| 规则 | 说明 |
|---|---|
| 顶层字段集 | **恰好 7 个**：`schema_version` / `meta` / `requirements` / `open_questions` / `coverage_matrix` / `defects` / `cases`。**多一个即违规** |
| `schema_version` | 必须是 `2`（走 v2 严格模式） |
| `requirements[]` | 每条 `id` 唯一（形如 `R-<序号>`）、`title` 非空、`source_ref` **恰为** `threat-model.json#/threats/<TH-id>`、`testable` 布尔 |
| `requirements` 与威胁 | **一一覆盖**：每条威胁**至少**有一条 requirement；每条 requirement 的 `source_ref` 指向**真实存在**的威胁 |
| `open_questions` | 必须是数组（本 REQ 固定为 `[]`，见 F3.2 的说明） |
| `coverage_matrix` | 每条 `requirement` ∈ `requirements[].id` 且**文件内唯一**；**每个** requirement 都必须在 `coverage_matrix` 里出现一次；`methods_applied` 非空且每个方法号 ∈ **方法库实际存在**的方法；`dimensions` 非空且每个 ∈ `dimensions.json` 的维度 id，且**必须含 `security`** |
| `defects` | 必须是数组（本 REQ 固定为 `[]`） |
| `cases[]` | 每条：`id`（合 `^TC-\d{3}$`、**跨全部套件全局唯一**）、`title`（非空）、`requirement_refs`（**非空**数组，每项 ∈ `requirements[].id` ⇒ **不悬空**）、`dimension`（**必须 `security`**）、`priority`（枚举 `P0`~`P3`）、`method`（非空数组，每个方法号 ∈ 方法库实际存在的方法 —— **这条是本 REQ 的契约要求，由门用独立复算器判**，上游 `validate-cases.mjs` 只查方法号的**格式** `^M\d+\.\d+$`、不查它在方法库里是否存在）、`status`（**必须恒为 `active`**）、`steps`（非空数组，每步 `action` 与 `expected` 非空）、`tags`（数组） |

⚠️ **`status` 恒为 `active`**（不是四值枚举）：

1. 上游 `validate-cases.mjs` 对**非 `active`** 的 `status` **硬拦**（缺 `revision` ⇒ FAIL，
   且 `revision.change` 还必须非空）—— 刚被派生出来的安全用例**没有前序版本**，
   声称它「被改过 / 已废弃」在语义上就是**假的**。
2. `blocked` 是**执行阶段**的判定（预期非字符串 ⇒ 执行时判 `blocked`），
   **规划阶段无权判 `blocked`**。

⇒ 安全用例集的 `status` 只能是 `active`，且**不得**带 `revision`。

⚠️ **「顶层封闭 7 个」由本 REQ 的门来判，不是上游校验器判**：
`validate-cases.mjs` 在 v2 严格模式下会把**缺失**的顶层字段升级为 ERROR，
但**不拦多余的顶层字段**（它没有「顶层未知字段」这道检查）——
所以「封闭」是**契约要求**，必须由验收门用独立复算器核。

#### F5.3 用例 id 的分配

- 形如 `^TC-\d{3}$`（**三位**数字；`TC-1001` 不合法）。
- **跨全部 security 套件全局唯一**。
- **不得**与 `--cases` 输入集里已有的 id 冲突（输入集占用的号必须避开）。
- 具体编号由实现分配，契约**不指定**（见 `acceptance.md` §0.6 的诚实声明）。

#### F5.4 威胁 ↔ 用例的关联靠 `source_ref`，不靠 id 后缀

⚠️ 架构文档 §8 的威胁模型示例写的 `TC-SEC-001` 与上游 `validate-cases.mjs` 的
`^TC-\d{3}$` **硬拦**冲突 ⇒ **以校验器为准**：用例 id 一律 `TC-\d{3}`。
关联链是：

```
cases[].requirement_refs → requirements[].id → requirements[].source_ref
                          → "threat-model.json#/threats/TH-n" → threats[].id
cases[].tags 含 "security" 与该威胁的 id（冗余但便于按威胁分批跑）
```

#### F5.5 方法与维度

- `cases[].method[]` ⊆ **方法库实际存在**的方法（`references/methods.json`：
  `M1.1`~`M1.6` + `M2.1` 威胁建模(STRIDE) / `M2.2` 攻击面枚举 / `M2.3` 模糊测试）。
  ⚠️ 架构文档写的「M4.2（安全）」**不存在**（陈旧）—— 安全方法就是 M2.1~M2.3。
  ⚠️ **「方法号必须存在于 `references/methods.json`」是本 REQ 的契约要求，由门用独立复算器判** ——
  上游 `validate-cases.mjs` L398 对 `cases[].method[]` **只查格式**（元素须匹配 `^M\d+\.\d+$`），
  **不查该方法是否真的在方法库里**；`check-methods.mjs` 校验的是「方法库自身」与「设计方法说明文档」的一致性，
  **不校验任意一份 cases.json**。⇒ 判据正文里**不许**写成「上游校验器会拦」。
- `cases[].dimension` = `security`（`references/dimensions.json` 是维度的**唯一来源**，其中已含 `security`）。

---

### F6 套件与目录落位

- 目录：`<out-dir>/test-assets/security/suites/SEC-<编号>-<短名>/`，目录名匹配 `^SEC-\d{3}-[a-z0-9][a-z0-9-]*$`。
- 每个套件目录**必有** `cases.json` 与 `suite.json`。
- `suite.json` 的 `suite` 字段值**必须与目录名完全一致**（上游第 8 项强制）。
- `suite.json` 的**顶层字段集封闭**（9 个允许字段）：
  `suite` / `requirement` / `scope` / `environment` / `cases_file` / `executor` / `base_url_from` / `tags` / `report`。
  ⚠️ **不许有 `threat_model` 字段**（上游 `verify-layout.mjs` 对表外字段一律判 FAIL）。
  其中 `suite` / `requirement` / `scope` / `environment` / `cases_file` / `executor` **必填非空**。
- `scope` = `security`；`executor` = `security`（枚举合法；上游校验器**不强制**两者配对，但本 REQ 写死）。
- `environment` 必须指向 `<out-dir>/test-assets/environments/` 里**真实存在**的环境（否则上游判「悬空引用」）。
- `cases_file` 指向**真实存在**的文件（相对套件目录解析）。
- **「可被消费」= 加载层可解析**（见 §0.2）：`loadSuite()` 成功 + `loadCases()` 成功
  + `selectCases()` 能按 `suite.json.tags` 选出用例 + 产物 `cases.json` 过 `validate-cases.mjs`（退出码 0）。
  ⚠️ **不要求** `run-suite.mjs --dry-run` 跑通（`security` 执行器未实现 ⇒ 它会先抛错），
  **更不要求**执行器能跑（执行属后续 REQ）。

⚠️ **环境 `driver` 会覆盖 `suite.json` 的 `executor`**（上游 `resolveDriverName()` 的优先级：
环境配置的 `driver` → `suite.json` 的 `executor`）。环境的 `driver` 字段**可选**，
枚举只有 `api` / `mock`（**没有 `security`**）。
⇒ 对 `scope=security` 的套件，**环境应当不写 `driver`** ——
写了就会**误配对**到 `api` / `mock` 执行器（「能跑通」是**假象**：
那是用功能执行器跑安全用例）。
本条是**契约正文里的边界说明**，**不作为判据**（判据只到加载层）。

---

### F7 依赖扫描接入（**职责边界**）

#### F7.1 谁来跑扫描器

- **本 skill 自己不跑扫描器**（零第三方依赖、不联网、保持纯函数化可测）。
- 扫描由 agent 用**已交付的 `qa-toolchain`**（`bin/qa`）跑 bandit / npm audit，**把结果喂进来**（`--scan`）。
- 工具装不上（环境不可达）⇒ agent **显式**传一份「扫描状态 JSON」（见 F7.2 的第三种形态），
  **不得**静默跳过。

#### F7.2 `--scan` 输入的三种合法形态

| 形态 | 判别特征 | 语义 |
|---|---|---|
| **bandit 结果** | 根是对象且 `results` 是数组 | `scan.tool = "bandit"`；finding 数 = `results.length` |
| **npm audit 结果** | 根是对象且 `vulnerabilities` 是对象 | `scan.tool = "npm-audit"`；finding 数 = `vulnerabilities` 的键数 |
| **扫描状态** | 根是对象且 `status` ∈ {`unavailable`, `failed`} | `scan.status` = 该值；`reason` **必填非空**；finding 数 = 0 |

⇒ 三者都识别不出来 ⇒ **输入非法** ⇒ rc=1（AC-008）。

#### F7.3 产物里的扫描声明

```json
"scan": { "status": "provided", "tool": "bandit", "source_file": "bandit.json", "finding_count": 2 },
"scan_findings": [
  { "id": "SCAN-1", "severity": "high", "summary": "Possible hardcoded password", "threat_refs": ["TH-9"] }
]
```

| 规则 | 说明 |
|---|---|
| `scan.status` | 枚举 `provided` / `not_provided` / `unavailable` / `failed`，**永远存在** |
| `not_provided` ⇔ | 没有传 `--scan` |
| `unavailable` / `failed` ⇔ | 传了「扫描状态」形态的 `--scan`（此时 `scan_findings` 必须为空数组） |
| `provided` ⇔ | 传了 bandit / npm audit 结果（此时 `scan_findings` **非空**） |
| `scan_findings` 条数 | **等于**输入扫描结果的 finding 数（一条输入 finding ⇒ 一条 `scan_finding`） |
| `scan_findings[].id` | 形如 `SCAN-<序号>`，文件内唯一 |
| `scan_findings[].threat_refs` | **非空**数组，每项 ∈ `threats[].id` |
| 被引用威胁 | 其 `source` 必须含 `scan`，且 `scan_refs` 必须含该 finding 的 id |
| **未提供扫描时** | **不得**出现 `source` 含 `scan` 的威胁；**不得**声称「已做依赖扫描」 |

⚠️ **「未提供扫描 ⇒ 显式声明」是硬要求**：静默跳过 = 假的「已经覆盖了依赖风险」。

---

### F8 诚实性红线

1. **威胁集合必须与输入可对账** —— 不得凭空造威胁（每条威胁都要锚定真实的资产 + 信任边界 + 入口点，
   并给出非空 `rationale`）；不得漏掉输入里的资产 / 边界 / 入口点（每个都要被至少一条威胁引用）。
2. **`unresolved` / `not_applicable` 一律必须带非空理由** —— 理由为空 = 没说实话。
3. **不得凭空造「已覆盖」** —— 声明 `covered` 就必须有真实威胁支撑；
   **声明与事实矛盾**（说 `not_applicable` 却有该类威胁）也是违规。
4. **不许静默跳过** —— OWASP 十类、四类实战补充，都必须有交代。
5. **只写 `--out-dir`** —— 其余目录一律只读；输入文件的 sha256 前后必须一致。
6. **幂等** —— 同一输入两次，除 `meta.generated_at` 外**逐字相同**。
7. **产物已存在即报错** —— 不得覆盖已有产物。

---

## 3. 明确不做的事（**不许越界**）

- ❌ **不执行**安全用例 —— 执行属 `test-execute` 侧的 `security` 执行器（**后续 REQ**）。
- ❌ **不新增/不改** `test-execute` 的任何文件（**含 `skills/test-execute/executors/`**）——
  注册 `security` 执行器会破 REQ-004 的门；执行器注册表自己写明「分别属后续 REQ」。
- ❌ **不推进轮次状态机**、**不改** `cycle.json`（照 REQ-007 的先例）。
- ❌ **不做**渗透测试 / 漏洞利用 / 真实攻击 —— 本 REQ 只做**规划**。
- ❌ **不安装工具**（属 `qa-toolchain`）、**不把不可达的工具写进清单**
  （GitHub releases 不可达 ⇒ `nuclei` / `trivy` / `osv-scanner` 等单二进制工具**不得**进清单）。
- ❌ **不联网**。
- ❌ **不改**既有 5 个 skill 的任何文件（REQ-010/011/006/002A/002B 的门必须原样继续全绿）。
- ❌ **不生成**功能用例（属 `test-case-design`）、**不跑**用例（属 `test-execute`）。
- ❌ **不改** `bin/verify-suite.mjs` 的组合门场景（登记为遗留项，见 `status.md`）。

---

## 4. 交付物形状

```
skills/security-plan/
├── SKILL.md                              # frontmatter: name: security-plan / description 非空
├── skill-meta.json                       # name / version / requires
├── references/
│   ├── security-context-schema.md        # F1 输入契约
│   ├── threat-model-format.md            # F2 / F3 产物契约
│   ├── matrix-format.md                  # F4 产物契约
│   └── derivation-rules.md               # F5 / F6 派生与落位规则
└── scripts/
    ├── make-security-plan.mjs            # 入口（可执行，shebang `#!/usr/bin/env node`）
    ├── check-security-plan.mjs           # 自检器（可执行，shebang 同上）
    ├── selftest-security-plan.mjs        # 单元自测
    └── lib/                              # ≥ 3 个非空的 .mjs 模块
```

`skill-meta.json` 的 `requires` 必须含：

| 依赖 | 理由 |
|---|---|
| `test-case-design` | 消费方法库（M2.1~M2.3）、维度库（含 `security`）与目录契约 |
| `qa-toolchain` | 扫描器由 `bin/qa` 跑（bandit / npm audit），结果喂进 `--scan` |

⚠️ **不含 `test-execute`**：架构文档 §8 的依赖表里 REQ-002.8 依赖 **002.2 + 002.4**，
不含 002.5b；且 `security` 执行器未实现，宣称依赖 `test-execute` 会是**假依赖**。

---

## 5. 验收

- 判据：**29 条**（AC-001~AC-029），分 7 组；正文见 `acceptance.md`。
- 验收门：`verify-acceptance.sh`（sha256 钉在 `manifest.json`；`QA008_SCRIPT_SHA` 不匹配即 `0 PASS / 1 FAIL` 退出）。
- 三态：**PASS / FAIL / 不可判定**（不可判定 ≠ 通过，退出码一律非 0）。
