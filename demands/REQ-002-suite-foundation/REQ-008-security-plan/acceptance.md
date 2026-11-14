# REQ-008 验收判据 —— `security-plan`（安全能力域：OWASP 全套 + 依赖扫描）

> 本文件是**契约**，不是说明材料。实现者按这里的规则交付，验收脚本按这里的规则判定。
> 判据条数：**29 条**（AC-001 ~ AC-029）。条数**不增不减不改号**。
> 决策记录见 `decisions.md`（D98 起）。功能契约见 `demand.md`（F1~F8）。

---

## §0 公共夹具规格（判据的公共前置）

验收脚本自造以下夹具，**全部落在临时目录**（`$WORK`），**不得**写进被验包。
夹具内容与 `demand.md` F1.2 / F2 / F4 的形状一致。

### §0.1 安全上下文夹具 `$FX/inputs/context.json`

服务形态：**订单服务**，对外提供登录与订单查询，内部写访问日志；
**没有任何密码学环节**（不存口令明文、不做加解密、无密钥管理）⇒ `A02` 天然不适用。

```json
{
  "schema_version": 1,
  "service": { "name": "order-api", "description": "订单服务" },
  "assets": [
    { "id": "AS-1", "name": "用户口令哈希", "sensitivity": "critical", "description": "口令散列" },
    { "id": "AS-2", "name": "订单数据", "sensitivity": "high", "description": "订单明细" },
    { "id": "AS-3", "name": "访问日志", "sensitivity": "medium", "description": "审计日志" }
  ],
  "trust_boundaries": [
    { "id": "TB-1", "name": "公网到应用", "from": "互联网", "to": "应用网关", "controls": ["TLS 终止", "WAF 规则"] },
    { "id": "TB-2", "name": "应用到数据层", "from": "应用进程", "to": "数据库", "controls": ["参数化查询"] }
  ],
  "entry_points": [
    { "id": "EP-1", "name": "登录接口", "kind": "http", "asset_refs": ["AS-1"], "boundary_refs": ["TB-1"], "description": "POST /api/login" },
    { "id": "EP-2", "name": "订单详情接口", "kind": "http", "asset_refs": ["AS-2"], "boundary_refs": ["TB-1"], "description": "GET /api/orders/{id}" },
    { "id": "EP-3", "name": "日志写入", "kind": "file", "asset_refs": ["AS-3"], "boundary_refs": ["TB-2"], "description": "写访问日志" }
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

**3 个资产 / 2 条信任边界 / 3 个入口点 / 3 个角色 / 2 个资源** —— 满足 F1.2 的最小规模要求。

⚠️ **「显式不适用类」怎么进夹具**：**不通过输入字段告诉实现答案**。
本夹具的 `service` / `assets` 里**没有**任何密码学相关资产（无口令明文、无密钥、无加解密资产），
所以「`A02` 确实不适用」是**实现方从上下文读出来的判断**，不是夹具塞进去的结论。
契约**不指定**哪一类必须不适用（见 F3.1 与 D103）——
判据只要求「十类**每类都有交代**」+「不适用必须带非空理由 + 一条未决问题」。

### §0.2 功能用例集夹具 `$FX/inputs/cases.json`（供 `--cases` 用）

cases.json v2（顶层 7 字段封闭），**3 条**用例：

| `id` | `title` | `requirement_refs` | `steps[].action` | `tags` |
|---|---|---|---|---|
| `TC-001` | 登录成功返回令牌 | `["R-1"]` | `POST /api/login` | `["auth"]` |
| `TC-002` | 查询订单详情 | `["R-2"]` | `GET /api/orders/{id}` | `["order"]` |
| `TC-003` | 导出访问日志 | `["R-3"]` | `GET /api/audit/logs` | `["audit"]` |

每条另有：`dimension: "functional"`、`priority: "P0"`、`method: ["M1.1"]`、`status: "active"`、
`preconditions: []`、`data: {}`、`steps[].expected` 为普通字符串。
用例集自身 `requirements[]` = `R-1`/`R-2`/`R-3`；`open_questions: []`；`coverage_matrix` 三条；`defects: []`。

⚠️ **`TC-001`~`TC-003` 是故意占用的号**：产出侧的安全用例 id 不得与之冲突（AC-018）。

### §0.3 扫描结果夹具 `$FX/inputs/`

三份，**分别**用于三种合法形态（AC-008）+ 主跑：

**① `$FX/inputs/bandit.json`（主跑用）** —— bandit 结果：

```json
{
  "results": [
    {
      "filename": "app/handlers/upload.py",
      "test_id": "B301",
      "test_name": "blacklist",
      "issue_severity": "HIGH",
      "issue_confidence": "HIGH",
      "issue_text": "Possible hardcoded password: 'secret123'",
      "line_number": 42
    },
    {
      "filename": "app/handlers/xml.py",
      "test_id": "B320",
      "test_name": "bad_telemetry",
      "issue_severity": "MEDIUM",
      "issue_confidence": "MEDIUM",
      "issue_text": "Consider possible security implications of xml parsing",
      "line_number": 17
    }
  ],
  "errors": []
}
```

⇒ **2 条 finding** ⇒ 产物 `scan_findings` **恰好 2 条**，`scan.status == "provided"`，`scan.tool == "bandit"`。

**② `$FX/inputs/npm-audit.json`** —— npm audit 结果：

```json
{
  "auditReportVersion": 2,
  "vulnerabilities": {
    "lodash": {
      "name": "lodash",
      "severity": "high",
      "range": "<4.17.21",
      "via": [{ "title": "Prototype Pollution", "url": "https://github.com/advisories/GHSA-x5cx-7h7x-2h4r" }]
    }
  },
  "metadata": { "vulnerabilities": { "info": 0, "low": 0, "moderate": 0, "high": 1, "critical": 0 } }
}
```

⇒ **1 条 finding** ⇒ `scan.tool == "npm-audit"`。

**③ `$FX/inputs/scan-unavailable.json`** —— 扫描状态（工具装不上时）：

```json
{
  "tool": "bandit",
  "status": "unavailable",
  "reason": "bandit 未就绪：PyPI 镜像不可达，uv/pip 均安装失败（见 qa doctor 结论）"
}
```

⇒ `scan.status == "unavailable"`，`scan_findings` **必须为空数组**。

### §0.4 最小项目根 `$FX/proj`

```
$FX/proj/
├── .gitignore                       # 含 ".test-artifacts/"（上游检查 13 要求）
└── test-assets/
    ├── environments/
    │   ├── _schema.json             # 上游检查 2 要求（环境配置 schema）
    │   └── local.json               # 环境定义（name 必须 == 文件名）
    └── cycles/
        ├── index.json               # 上游检查 12 要求
        └── R1-REQ-001/
            └── cycle.json           # 轮次状态（上游检查 9/10/11）
```

`environments/local.json`：

```json
{
  "name": "local",
  "base_url": "http://127.0.0.1:8080",
  "timeout_ms": 5000,
  "retries": 0,
  "credentials": { "username_env": "ORDER_API_USER", "password_env": "ORDER_API_PASS" }
}
```

⇒ 套件的 `environment` 取 `local`（`<out-dir>/test-assets/environments/` 下**按文件名排序的第一个**）。

⚠️ **这份环境定义里**不得**有 `driver` 字段** —— 理由不是「省事」，而是**不让结论变成假象**：

- 上游 `resolveDriverName()` 的优先级是「**环境配置的 `driver`** → `suite.json` 的 `executor`**」；
- 环境的 `driver` 字段**可选**，枚举只有 `api` / `mock`（**没有 `security`**）；
- 环境**不写** `driver` ⇒ 取 `suite.json` 的 `executor` = `security`
  ⇒ 「`security` 执行器未实现」才是**真实**的状态；
- 反之，若环境写了 `driver: "api"`，执行器查找会命中 `api`
  ⇒ `run-suite.mjs --dry-run` **能跑通** —— 但那是**用功能执行器跑安全用例**，
  属于**误配对**，「能跑通」是**假象**，用它做判据会得出假绿。

⇒ 夹具必须**不写** `driver`，让「执行器未实现」保持真实；
判据只到**加载层**（AC-024），**不出现**任何 `--dry-run` 的表述。

### §0.5 主跑命令

```
node skills/security-plan/scripts/make-security-plan.mjs \
  --context $FX/inputs/context.json \
  --cases   $FX/inputs/cases.json \
  --scan    $FX/inputs/bandit.json \
  --out-dir <项目根副本>
```

**产物落点**（F1.5）：

```
<项目根副本>/test-assets/security/
├── threat-model.json
├── matrix.json
└── suites/
    └── SEC-<编号>-<短名>/
        ├── cases.json
        └── suite.json
```

### §0.6 基线真值表（夹具跑出来的**唯一**正确结论）

⚠️ **诚实声明（先读这一段）**：本表只固定**可机械核**的那部分真值。
**威胁的具体条数、每条威胁的内容、每条威胁归到哪个 OWASP 类、套件怎么分组、用例编号怎么分配**，
都属于**实现方的判断**（契约要求它「有交代、有理由、不凭空」，但**不指定**它的判断结果）。
把这些写死成真值，就等于把实现的判断抄进契约 —— 那是假判据。

| # | 字段 | 真值 | 来源 |
|---|---|---|---|
| 1 | 产物根 | `<out-dir>/test-assets/security/` | F1.5 |
| 2 | `threat-model.json` 存在 | 是 | F2 |
| 3 | `threat-model.json` 顶层字段集 | 含 `schema_version` / `meta` / `assets` / `trust_boundaries` / `entry_points` / `threats` / `owasp_coverage` / `supplements` / `scan` / `scan_findings` / `open_questions` | F2.1 |
| 4 | `assets` 段 id 集合 | **恰等于** `{AS-1, AS-2, AS-3}` | F2.1 |
| 5 | `trust_boundaries` 段 id 集合 | **恰等于** `{TB-1, TB-2}` | F2.1 |
| 6 | `entry_points` 段 id 集合 | **恰等于** `{EP-1, EP-2, EP-3}` | F2.1 |
| 7 | `threats[]` 条数 | **≥ 1**（由实现决定；每条字段齐全、id 合 `^TH-\d+$`） | F2.2 |
| 8 | `owasp_coverage` 键集 | **恰等于** `{A01…A10}`（10 个） | F3.1 |
| 9 | `owasp_coverage` 每项 `status` | ∈ `{covered, not_applicable}`；**十类每类都有交代** | F3.1 |
| 10 | `supplements` 键集 | **恰等于** `{file_upload, ssrf, xxe, deserialization}`（4 个） | F3.3 |
| 11 | `supplements` 每项 `status` | ∈ `{covered, not_applicable}`；**四类逐类有交代** | F3.3 |
| 12 | `scan.status` | `"provided"`（主跑喂了 bandit 结果） | F7.3 |
| 13 | `scan.tool` | `"bandit"` | F7.3 |
| 14 | `scan_findings` 条数 | **恰好 2**（= 输入 `results.length`） | F7.3 |
| 15 | `scan_findings[].threat_refs` | 每条**非空**且指向真实威胁 | F7.3 |
| 16 | `matrix.json` 存在 | 是 | F4 |
| 17 | `matrix.json` 的 `roles` id 集合 | **恰等于** `{ROLE-1, ROLE-2, ROLE-3}` | F4 |
| 18 | `matrix.json` 的 `resources` id 集合 | **恰等于** `{RES-1, RES-2}` | F4 |
| 19 | `matrix.json` 的 `entries` 条数 | **≥ 6**（3 角色 × 2 资源，每个组合至少一条） | F4 |
| 20 | `entries[].basis == "gap"` 的条目 | `decision == "allow"` ∧ `threat_ref` 指向 `category == "elevation_of_privilege"` 的威胁 | F4 |
| 21 | `elevation_of_privilege` 威胁数 | **≥ 1**（上下文里 `ROLE-2` 可读 `RES-2` 却只校验登录 ⇒ 有越权缺口） | F4 |
| 22 | 套件目录数 | **≥ 1**；每个目录名匹配 `^SEC-\d{3}-[a-z0-9][a-z0-9-]*$` | F6 |
| 23 | 每个套件的 `cases.json` 顶层字段集 | **恰好 7 个**：`schema_version` / `meta` / `requirements` / `open_questions` / `coverage_matrix` / `defects` / `cases` | F5.2 |
| 24 | 每个套件的 `cases.json` 的 `schema_version` | `2` | F5.2 |
| 25 | 全部套件的 `cases[]` 总条数 | **≥ `threats[]` 条数**（每条威胁至少 1 条用例） | F5.1 |
| 26 | 全部套件的用例 `id` | 每个合 `^TC-\d{3}$`；**跨套件全局唯一**；**不与** `{TC-001, TC-002, TC-003}` 冲突 | F5.3 |
| 27 | 用例 `dimension` | 全部 `security` | F5.5 |
| 28 | 用例 `method[]` | 每个 ∈ 方法库实际存在的方法（`M1.1`~`M1.6` / `M2.1`~`M2.3`） | F5.5 |
| 29 | 用例 `tags` | 每条含 `security` 与其需求条目对应的威胁 id | F5.4 |
| 30 | `requirements[].source_ref` | 每条**恰为** `threat-model.json#/threats/<TH-id>`，且该威胁真实存在 | F5.4 |
| 31 | 每个套件的 `suite.json` 顶层字段集 | ⊆ 9 个允许字段（`suite` / `requirement` / `scope` / `environment` / `cases_file` / `executor` / `base_url_from` / `tags` / `report`），**无 `threat_model`** | F6 |
| 32 | 每个套件的 `suite.json` 的 `scope` / `executor` | 均为 `security` | F6 |
| 33 | 每个套件的 `suite.json` 的 `suite` | **等于**所在目录名 | F6 |
| 34 | 每个套件的 `suite.json` 的 `environment` | 指向真实存在的环境文件（夹具里是 `local`） | F6 |
| 35 | 每个套件的 `suite.json` 的 `cases_file` | 指向真实存在的文件 | F6 |
| 36 | 幂等 | 同一输入跑两次（两个不同 out-dir），产物**除 `meta.generated_at` 外逐字相同** | F8.6 |
| 37 | 输入只读 | 输入文件 sha256 跑前跑后**一致** | F8.5 |

---

## A 组：交付物形状（AC-001 ~ AC-004）

### AC-001: `security-plan` skill 存在且结构合法
- **前置条件**: 被验包目录
- **测试步骤**: ① 检查 `skills/security-plan/` 存在；② `SKILL.md` 存在且 YAML frontmatter 含 `name: security-plan` 与**非空** `description`（取 frontmatter 的**值**再判空 —— 块标量 `|` 取其缩进块；普通标量剥掉首尾引号，`""` / `''` 判空）；③ `skill-meta.json`、`references/security-context-schema.md`、`references/threat-model-format.md`、`references/matrix-format.md`、`references/derivation-rules.md`、`scripts/make-security-plan.mjs`、`scripts/check-security-plan.mjs` 存在且**非空**；④ `scripts/lib/` 下 `.mjs` 模块 **≥ 3 个**且非空；⑤ 两个脚本**各自**（不是两个合起来满足其一）首行是 `#!/usr/bin/env node`、文件**可执行**、且 `node --check` 通过；任一项不满足 → 判红并**点名是哪一项**
- **预期结果**: 五项全满足
- **判据形式**: 查**绝对事实**（文件真实存在且非空）；探针：把 `description` 改成 `""` → 本条判红；删掉 `references/matrix-format.md` → 本条判红；把某个脚本 `chmod -x` → 本条判红
- **类型**: 功能

### AC-002: 每个 skill 都声明版本与依赖（`skill-meta.json`）
- **前置条件**: 被验包目录
- **测试步骤**: 对 `skills/` 下**每一个**含 `SKILL.md` 的目录，检查存在 `skill-meta.json`；解析它必须有 `name`（非空且等于目录名）、`version`（形如 `<数字>.<数字>.<数字>`）、`requires`（对象；值为形如 `>=<x.y.z>` 或 `<x.y.z>` 的约束）；并检查 `name` 与该 skill 的 SKILL.md frontmatter `name` 一致（frontmatter 取**值**再比对 —— 剥首尾引号、支持块标量；不得用「取第一个 token」的裸正则）
- **预期结果**: 每个 skill 都有合法声明；**`security-plan` 的 `requires` 必须同时含 `test-case-design`（消费方法库 / 维度库 / 目录契约）与 `qa-toolchain`（扫描器由 `bin/qa` 跑，结果喂进 `--scan`）**，且**不得含 `test-execute`**（REQ-002.8 依赖 002.2 + 002.4 不含 002.5b；且 `security` 执行器未实现 ⇒ 那是**假依赖**）；任一不满足 → 判红并点名
- **判据形式**: 查绝对事实；探针：删掉某个 skill 的 `skill-meta.json` → 本条判红；把 `security-plan.requires` 里的 `qa-toolchain` 删掉 → 本条判红
- **说明**: 架构文档 §8 的依赖表里 REQ-002.8 依赖 **002.2 + 002.4**（002.2 = 方法库 ⇒ 落在 `test-case-design`；002.4 = `.tools` 自举 ⇒ 落在 `qa-toolchain`），**不含** 002.5b（`test-execute`）；且 `security` 执行器未实现，宣称依赖它是**假依赖**（D121）
- **类型**: 功能

### AC-003: README 的 skill 清单与实际目录一致（且 `security-plan` 两处都在）
- **前置条件**: 被验包目录 + `README.md`
- **测试步骤**: ① 取 `skills/` 下全部含 `SKILL.md` 的目录名集合 S；② 取 `README.md` 的 **skill 清单**（表格首格 ∪ `skills/<name>` 路径 ∪ 安装树条目）集合 R；③ 检查 S == R；④ 检查 `security-plan` 出现在 **skill 表格**里；⑤ 检查 `security-plan` 出现在 **安装树代码块**里
- **预期结果**: ①集合完全相等；②③④⑤全满足；README 漏写或多写任一 skill → 判红并点名；`security-plan` 漏在任一处 → 判红并点名**漏在哪一处**
- **判据形式**: 查绝对事实（与目录实际内容比对），不查"README 里说了几个"
- **类型**: 可用性

### AC-004: 新产物不得打破既有目录契约
- **前置条件**: 被验包里的 `skills/test-case-design/scripts/verify-layout.mjs` + §0.4 的最小项目根
- **测试步骤**: ① 在项目根副本里放上**本 REQ 的安全产物**（`test-assets/security/**`）；② 跑 `verify-layout.mjs <项目根>`；③ 断言退出码为 0 且无 FAIL 级问题；④ **错误位置探针**：把 `threat-model.json` 复制到契约外（如 `test-assets/threat-model.json`）再跑一次，记录校验器的结论
- **预期结果**: ①~③成立；④的结论必须是**明确**的二选一：**位置不受约束**（校验器不查该位置，退出码仍 0 ⇒ **不得**要求实现去管 `threat-model.json` 的位置）或**位置受约束**（校验器判红）。**不接受没有输出任何结论**。本条**不**对「二选一本身」判红（那是事实，不是对错）—— 本条判红的是「①~③不成立」或「④得不出明确结论**
- **判据形式**: 查绝对事实（实跑校验器的退出码）；探针：把产物放到错误位置 → 按④的结论判读
- **说明**: 上游校验器用 `listFiles(test-assets)` **递归**找所有 `suite.json` ⇒ security 套件**自动**受那 22 项强制约束（字段完整 / 枚举合法 / `environment` 存在 / `cases_file` 存在 / `suite` 名与目录名一致 / `report.output_dir` 前缀）
- **类型**: 兼容性

---

## B 组：输入解析与校验（AC-005 ~ AC-008）

> 以下各条的前置：`node skills/security-plan/scripts/make-security-plan.mjs --context <夹具或变体> [--scan <夹具>] --out-dir <空的输出目录副本>`
> 「输出目录副本」= §0.4 项目根的副本，**跑前**其 `test-assets/security/` 不存在。

### AC-005: 上下文的必填字段与类型必须校验（结构层）
- **前置条件**: §0.1 上下文 + 五份**变体**副本：① 删掉 `assets`；② 把 `trust_boundaries` 改成字符串；③ 删掉 `entry_points[0].name`；④ 删掉 `roles`；⑤ 把 `resources` 改成对象
- **测试步骤**: 五种变体各跑一次，检查退出码、stderr、输出目录
- **预期结果**: 五种情形**退出码均为 1**（输入非法）；stderr **点名是什么坏了**（含字段名，如 `assets` / `trust_boundaries` / `entry_points[0].name` / `roles` / `resources`）；输出目录里**不得**出现 `threat-model.json` / `matrix.json` / `suites/`（**存在性**判定，0 字节也算）
- **判据形式**: 查绝对事实（真实退出码 + 产物目录实况）；探针：让实现在解析失败时仍写出空的 `threat-model.json` → 本条判红
- **类型**: 功能

### AC-006: 上下文的引用必须完整（不悬空）
- **前置条件**: 两份**变体**上下文：① 把 `entry_points[0].asset_refs` 改成 `["AS-999"]`（资产不存在）；② 把 `entry_points[1].boundary_refs` 改成 `["TB-999"]`（边界不存在）；③ 把 `resources[0].asset_refs` 改成 `[]`（空）
- **测试步骤**: 三种变体各跑一次，检查退出码、stderr、输出目录
- **预期结果**: 三种情形**退出码均为 1**；stderr **点名**坏点（含那个不存在的 id 或「为空」）；**不得**留下 `threat-model.json` / `matrix.json` / `suites/`
- **判据形式**: 查绝对事实；探针：让实现不查悬空引用（把 `AS-999` 当成真实资产写进产物）→ 本条判红
- **类型**: 功能

### AC-007: 上下文的 id 必须唯一且格式合法
- **前置条件**: 两份**变体**上下文：① 把 `assets[1].id` 改成 `AS-1`（与 `assets[0].id` **重复**）；② 把 `entry_points[0].id` 改成 `EP-XYZ`（**格式错**）
- **测试步骤**: 两种变体各跑一次，检查退出码、stderr、输出目录
- **预期结果**: 两种情形**退出码均为 1**；stderr **点名**坏点（重复时点名那个重复的 id，格式错时点名那个 id）；**不得**留下 `threat-model.json` / `matrix.json` / `suites/`
- **判据形式**: 查绝对事实；探针：让实现不查唯一性 → 本条判红
- **类型**: 功能

### AC-008: 枚举必须合法，且 `--scan` 的三种形态都要能识别
- **前置条件**: ① 变体上下文：把 `assets[0].sensitivity` 改成 `secret`；② 变体上下文：把 `entry_points[0].kind` 改成空字符串；③ 变体扫描文件：`{"foo": 1}`（三种形态都识别不出来）；④ **合法**的 `bandit.json`；⑤ **合法**的 `npm-audit.json`；⑥ **合法**的 `scan-unavailable.json`
- **测试步骤**: ①~③各跑一次（检查退出码与 stderr）；④~⑥各跑一次（检查退出码）
- **预期结果**: ①~③**退出码均为 1**，stderr 点名（越界字段名与越界值 / 「无法识别」）；④~⑥**退出码均为 0**（三种合法形态都要被接受）；①~③**不得**留下 `threat-model.json` / `matrix.json` / `suites/`
- **判据形式**: 查绝对事实；探针：让实现只认 bandit 一种形态 → ⑤ 判红；让实现接受任意 sensitivity 字符串 → ① 判红
- **类型**: 功能

---

## C 组：威胁模型（AC-009 ~ AC-014）

### AC-009: 威胁模型的资产 / 信任边界 / 入口点三段必须与输入逐条对应
- **前置条件**: §0.5 主跑产物
- **测试步骤**: 取产物 `threat-model.json` 的 `assets` / `trust_boundaries` / `entry_points` 三段，与 §0.1 上下文对应段比对
- **预期结果**: 三段的 **id 集合**与上下文对应段**完全相等**（不多、不少、不改 id）；条数相等；`assets[].sensitivity` 与上下文一致；`trust_boundaries[].controls` 与上下文一致（数组）；`entry_points[].kind` 与上下文一致
- **判据形式**: 查绝对事实（集合运算）；探针：让实现凭空加一条 `AS-9` 资产 → 本条判红
- **类型**: 诚实性

### AC-010: 威胁字段齐全、id 唯一且枚举合法
- **前置条件**: 同上
- **测试步骤**: 遍历产物 `threats[]` 的每个条目，逐字段核对
- **预期结果**: 每条威胁的字段集**恰为** F2.2 的 **12 个**（封闭）；`id` 合 `^TH-\d+$` 且文件内**唯一**；`name` 非空；`category` ∈ STRIDE 六类；`owasp` ∈ `A01`~`A10`；`severity` ∈ `critical`/`high`/`medium`/`low`；`source` ∈ `model`/`scan`/`model+scan`；`asset_refs` / `boundary_refs` / `entry_point_refs` / `scan_refs` / `supplement_refs` 都是数组；`rationale` 非空；`source` 含 `scan` ⇔ `scan_refs` 非空
- **判据形式**: 查绝对事实（逐字段核）；探针：让实现把 `category` 写成 `XSS` → 本条判红
- **类型**: 功能

### AC-011: OWASP A01~A10 十类**每类都必须有交代**
- **前置条件**: 同上
- **测试步骤**: 取产物 `owasp_coverage` 的键集与每项取值
- **预期结果**: ①键集**恰为** `A01`~`A10`（10 个，不多不少）；②每一项都有 `status` ∈ {`covered`, `not_applicable`}；③`covered` ⇒ `threat_refs` **非空**且每项 ∈ `threats[].id`，**被引用威胁的 `owasp` 等于该类**，且**该类的每条威胁都在 `threat_refs` 里**；④**不存在**「既没有 covered 声明、也没有 not_applicable 声明」的类
- **判据形式**: 查绝对事实（集合运算 + 逐类核）；探针：让实现静默跳过 `A07`（既不声明也不造威胁）→ 本条判红
- **说明**: 契约**不指定**哪一类必须不适用 —— 只要求**交代完整**。见 §0.6 的诚实声明与 D103
- **类型**: 诚实性

### AC-012: 判 `not_applicable` 必须带非空理由并留一条未决问题
- **前置条件**: 同上
- **测试步骤**: 遍历产物 `owasp_coverage` 里 `status == "not_applicable"` 的项；再遍历产物 `open_questions[]`
- **预期结果**: ①每一项的 `reason` **存在**且**非空**（去掉首尾空白后仍非空）；②每一项的 `open_question_ref` **存在**，指向 `open_questions[]` 里一条**存在**的条目，且那条的 `category` 等于该 OWASP 类；③`open_questions[]` 的每条 `id` 唯一、`question` 与 `reason` 非空
- **判据形式**: 查绝对事实；探针：让实现把 `A02` 判成不适用但 `reason` 写空串 → 本条判红；让实现判了不适用却**不留**未决问题 → 本条判红
- **类型**: 诚实性

### AC-013: 四类实战补充（文件上传 / SSRF / XXE / 反序列化）必须逐类显式判定
- **前置条件**: 同上
- **测试步骤**: 取产物 `supplements` 的键集与每项取值；再核对被引用威胁的 `supplement_refs`
- **预期结果**: ①键集**恰为** `{file_upload, ssrf, xxe, deserialization}`；②每一项都有 `status` ∈ {`covered`, `not_applicable`}；③`covered` ⇒ `threat_refs` **非空**且每项 ∈ `threats[].id`，**被引用威胁的 `supplement_refs` 含该键**，且 **`supplement_refs` 含该键的每条威胁都在 `threat_refs` 里**；④`not_applicable` ⇒ `reason` **非空**
- **判据形式**: 查绝对事实；探针：让实现完全不判 `ssrf`（键缺失）→ 本条判红；让实现判 `covered` 但被引用威胁的 `supplement_refs` 里没有该键 → 本条判红
- **类型**: 诚实性

### AC-014: 扫描发现必须映射成威胁，且「未做扫描」必须显式声明
- **前置条件**: §0.5 主跑（喂了 `bandit.json`）+ 另两次跑：① 不传 `--scan`；② 传 `scan-unavailable.json`
- **测试步骤**: ① 主跑：取 `scan` / `scan_findings` / `threats[]`；② 不传 `--scan` 跑一次：取 `scan` / `scan_findings` / 威胁的 `source`；③ 传 `scan-unavailable.json` 跑一次：取 `scan` / `scan_findings`
- **预期结果**:
  - ①`scan.status == "provided"`、`scan.tool == "bandit"`；`scan_findings` **恰好 2 条**，每条 `id` 形如 `SCAN-<序号>` 且唯一、`threat_refs` **非空**且每项 ∈ `threats[].id`；每个被引用威胁的 `source` 含 `scan` 且 `scan_refs` 含该 finding 的 id
  - ②`scan.status == "not_provided"`；`scan_findings` **为空数组**；**不得**存在 `source` 含 `scan` 的威胁
  - ③`scan.status == "unavailable"`；`scan_findings` **为空数组**
- **判据形式**: 查绝对事实；探针：让实现在没喂扫描时写 `scan.status == "provided"` → 本条判红；让实现不把扫描发现映射成威胁 → 本条判红
- **类型**: 诚实性

---

## D 组：权限矩阵（AC-015 ~ AC-016）

### AC-015: 矩阵的形状与引用必须成立
- **前置条件**: §0.5 主跑产物
- **测试步骤**: 取产物 `matrix.json` 的 `roles` / `resources` / `entries`，逐条核对
- **预期结果**: ①`roles` 的 id 集合与上下文 `roles` **完全相等**；②`resources` 的 id 集合与上下文 `resources` **完全相等**；③`entries` **非空**；④每条 `entries[].role` ∈ `roles[].id`、`entries[].resource` ∈ `resources[].id`（**不悬空**）；⑤`action` 非空；⑥`decision` ∈ {`allow`, `deny`}；⑦`basis` ∈ {`expected`, `gap`}；⑧**每个** `(role, resource)` 组合**至少**有一条 `entries`
- **判据形式**: 查绝对事实（集合运算 + 组合覆盖核）；探针：让实现漏掉 `(ROLE-3, RES-2)` 这一格 → 本条判红
- **类型**: 功能

### AC-016: 允许缺口必须对应到一条越权类威胁（双向）
- **前置条件**: 同上
- **测试步骤**: ① 遍历 `entries[]` 里 `basis == "gap"` 的条目；② 遍历 `threats[]` 里 `category == "elevation_of_privilege"` 的条目
- **预期结果**: ①每个 `gap` 条目的 `decision == "allow"`；其 `threat_ref` **非空**且 ∈ `threats[].id`，且**那条威胁的 `category == "elevation_of_privilege"`**；②`basis == "expected"` 的条目**不得**带 `threat_ref`；③**每条** `elevation_of_privilege` 威胁都被**至少一条** `gap` 条目引用
- **判据形式**: 查绝对事实（双向集合运算）；探针：让实现把 `gap` 条目的 `threat_ref` 指向一条 `tampering` 威胁 → 本条判红；让实现有一条越权威胁却不在矩阵里体现 → 本条判红
- **类型**: 诚实性

---

## E 组：用例派生（AC-017 ~ AC-021）

### AC-017: 每条威胁至少派生 1 条安全用例，且不得重复派生
- **前置条件**: §0.5 主跑产物（遍历**全部** security 套件的 `cases.json`）
- **测试步骤**: ① 汇总所有套件的 `cases[]`；② 由每条用例的 `requirement_refs` → `requirements[].source_ref` 反推它覆盖的威胁；③ 统计每条威胁被覆盖的用例条数；④ 统计同一威胁下用例 `title` 与 `steps` 的重复情况
- **预期结果**: ①每条威胁被**至少 1 条**用例覆盖；②同一威胁下的用例 `title` **互不相同**，`steps` **不得**完全相同；③每条用例的 `requirement_refs` **非空**
- **判据形式**: 查绝对事实（聚合 + 集合运算）；探针：让实现漏掉一条威胁（它没有对应用例）→ 本条判红；让实现把同一条威胁复制成两条一样的用例 → 本条判红
- **类型**: 功能

### AC-018: 用例 `id` 必须合 `^TC-\d{3}$`、全局唯一、且不与输入用例集冲突
- **前置条件**: 同上 + §0.2 的功能用例集
- **测试步骤**: 遍历**全部** security 套件的 `cases[]` 的每个 `id`；再取 §0.2 输入集的 id 集合
- **预期结果**: ①每个 `id` 都匹配 `^TC-\d{3}$`（**三位**数字，`TC-1001` 不合法）；②**跨全部套件** `id` 互不重复；③**没有任何** `id` 与输入用例集的 `{TC-001, TC-002, TC-003}` 冲突
- **判据形式**: 查绝对事实（集合运算）；探针：让实现派生出 `TC-SEC-001` → 本条判红；让实现复用输入集的 `TC-001` → 本条判红
- **说明**: 架构文档 §8 的威胁模型示例写的 `TC-SEC-001` 与上游 `validate-cases.mjs` 的 `^TC-\d{3}$` **硬拦**冲突 ⇒ **以校验器为准**
- **类型**: 功能

### AC-019: `requirements[].source_ref` 必须指向真实威胁，`requirement_refs` 不悬空
- **前置条件**: 同上
- **测试步骤**: 遍历每个套件的 `requirements[]` 与 `cases[]`
- **预期结果**: ①每条 `requirements[].source_ref` **恰为** `threat-model.json#/threats/<TH-id>` 形式，且 `<TH-id>` ∈ 产物 `threats[].id`；②`requirements[].id` 文件内唯一；③每条用例的 `requirement_refs` **非空**且每项 ∈ 该文件 `requirements[].id`（**不悬空**）；④**每条威胁**至少被一条 `requirements[]` 覆盖
- **判据形式**: 查绝对事实（正则抽取 + 集合运算）；探针：让实现把 `source_ref` 写成 `threat-model.json#/threats/TH-999` → 本条判红
- **类型**: 追溯

### AC-020: 产物 `cases.json` 的顶层字段集封闭 7 个，且用例字段齐全
- **前置条件**: 同上
- **测试步骤**: 取每个套件 `cases.json` 的顶层键集；再遍历 `cases[]` 逐字段核对
- **预期结果**: ①顶层键集**恰好**是 {`schema_version`, `meta`, `requirements`, `open_questions`, `coverage_matrix`, `defects`, `cases`} —— **多一个即违规**；②`schema_version == 2`；③`open_questions` / `defects` / `coverage_matrix` 都是数组；④每个 `coverage_matrix[].requirement` ∈ `requirements[].id` 且文件内唯一，且**每个** requirement 都恰好在 `coverage_matrix` 里出现一次；⑤每条用例：`id` / `title` 非空、`dimension` **== `security`**、`priority` ∈ `P0`~`P3`、`method` **非空**且每个方法号 ∈ **方法库实际存在**的方法、`status` **恒为 `active`**（**不得**是 `deprecated` / `modified` / `blocked`，**不得**带 `revision`）、`steps` 非空且每步 `action` 与 `expected` 非空、`tags` 是数组
- **判据形式**: 查绝对事实（逐字段核 + 集合运算）；探针：让实现在顶层加一个 `threats` 段 → 本条判红（**注意**：上游 `validate-cases.mjs` 不拦多余顶层字段，这一条**由门判**）；让实现把 `dimension` 写成 `functional` → 本条判红；造一条 `status: "modified"` 的用例 → 本条判红
- **说明（两处口径，不许写假话）**:
  - **方法库的**唯一来源**是 `skills/test-case-design/references/methods.json`（`M1.1`~`M1.6` + `M2.1`~`M2.3`）；架构文档写的「M4.2（安全）」**不存在**（陈旧）。
    ⚠️ **「方法号必须存在于方法库里」是本 REQ 的契约要求，由门用独立复算器判** ——
    上游 `validate-cases.mjs` L398 对 `cases[].method[]` **只查格式**（元素须匹配 `^M\d+\.\d+$`），
    **不查该方法是否真的在方法库里**；`check-methods.mjs` 校验的是「方法库自身」与「设计方法说明文档」的一致性，
    **不校验任意一份 cases.json**。
  - **`status` 恒为 `active`**：上游 `validate-cases.mjs` L426-443 对**非 `active`** 的 `status`
    **硬拦**（缺 `revision` ⇒ FAIL，且 `revision.change` 还必须非空）。刚被派生出来的安全用例**没有前序版本**，
    声称它「被改过 / 已废弃」在语义上就是**假的**；`blocked` 更是**执行阶段**的判定，
    **规划阶段无权判 `blocked`**。
- **类型**: 功能

### AC-021: `tags` 必须含 `security` 与该威胁的 id
- **前置条件**: 同上
- **测试步骤**: 遍历全部套件的 `cases[]`，逐条看 `tags`
- **预期结果**: 每条用例的 `tags` 数组**含** `"security"`；且**含**它 `requirement_refs` 所对应威胁的 id（由 `requirements[].source_ref` 反推）
- **判据形式**: 查绝对事实；探针：让实现漏掉威胁 id 的 tag → 本条判红（执行侧就分不出按威胁分批跑）
- **类型**: 功能

---

## F 组：套件落位与可执行（AC-022 ~ AC-024）

### AC-022: 套件目录名必须合规，且 `suite` 字段与目录名一致
- **前置条件**: §0.5 主跑产物
- **测试步骤**: 列出 `<out-dir>/test-assets/security/suites/` 下的每个目录，逐个核对
- **预期结果**: ①**至少 1 个**套件目录；②每个目录名匹配 `^SEC-\d{3}-[a-z0-9][a-z0-9-]*$`；③每个目录里**同时**有 `cases.json` 与 `suite.json`；④`suite.json` 的 `suite` 字段值**完全等于**目录名（大小写敏感）
- **判据形式**: 查绝对事实（文件系统实况）；探针：把目录改成 `SEC-1-authz`（编号不是三位）→ 本条判红
- **类型**: 功能

### AC-023: `suite.json` 的顶层字段集封闭且取值合法
- **前置条件**: 同上
- **测试步骤**: 取每个套件 `suite.json` 的顶层键集与各字段值
- **预期结果**: ①顶层键集 ⊆ 9 个允许字段 {`suite`, `requirement`, `scope`, `environment`, `cases_file`, `executor`, `base_url_from`, `tags`, `report`} —— **出现表外字段（含 `threat_model`）即违规**；②`suite` / `requirement` / `scope` / `environment` / `cases_file` / `executor` **六个必填**都存在且为非空字符串；③`scope == "security"`；④`executor == "security"`；⑤`environment` 在 `<out-dir>/test-assets/environments/` 下有**同名 `.json` 文件**；⑥`cases_file` 指向的文件**真实存在**（相对套件目录解析）
- **判据形式**: 查绝对事实（逐字段核 + 文件系统核）；探针：让实现写 `threat_model: "threat-model.json"` → 本条判红
- **说明**: 上游 `verify-layout.mjs` 对表外字段**一律判 FAIL**（`SUITE_ALLOWED_FIELDS` 恰 9 个，无 `threat_model`）
- **类型**: 功能

### AC-024: 产物必须能被 `test-execute` 的**加载层**消费
- **前置条件**: §0.5 主跑产物 + 被验包里的 `skills/test-execute/scripts/lib/suite-loader.mjs` 与 `skills/test-case-design/scripts/validate-cases.mjs`
- **测试步骤**: ① 对每个套件：用 `loadSuite(<suite.json>)` 解析（**必须不抛错**）；用 `loadCases(<suite.json>.cases_file 解析结果>)` 解析（**必须不抛错**）；用 `selectCases(cases, suite.tags)` 按 `suite.json.tags` 选出用例，断言选出的条数 == 该套件 `cases[]` 的条数（当 `tags.include` 为空或全部命中时）；② 对每个套件的 `cases.json` 跑 `node validate-cases.mjs <file>`，断言**退出码为 0**
- **预期结果**: ①每一步都不抛错，且 `selectCases` 选出的用例集合 ⊆ 该套件的 `cases[]`；②`validate-cases.mjs` 退出码为 0（无 ERROR；上游对 `open_questions` 为空只记 **WARN**，不阻断退出码）
- **判据形式**: 查绝对事实（**实跑**上游加载层与校验器的真实退出码）；探针：让产物的 `cases.json` 缺 `cases` 数组或用例 `id` 非字符串 → ① 判红
- **⚠️ 口径（不许含糊）**: 本条判的是「**能不能被消费**」= **加载层**可解析，
  **不是**「能不能跑起来」。`security` 执行器**未实现**（`test-execute/executors/index.json` 的 `not_implemented`），
  且 `run-suite.mjs` 的执行器查找在 dry-run 分支**之前** ⇒ 对 `executor=security` 的套件
  `run-suite.mjs --dry-run` 会**先抛错**「执行器 "security" 尚未实现」。
  ⇒ **本条不要求** `--dry-run` 跑通，**更不要求**执行器能跑；**安全用例的执行属后续 REQ**。
- **类型**: 一致性

---

## G 组：诚实性与覆盖（AC-025 ~ AC-029）

### AC-025: 威胁集合必须与输入可对账（不悬空、也不漏）
- **前置条件**: §0.5 主跑产物 + §0.1 上下文
- **测试步骤**: ① 遍历每条威胁的 `asset_refs` / `boundary_refs` / `entry_point_refs`，逐项核；② 统计上下文的每个资产 / 边界 / 入口点被多少条威胁引用
- **预期结果**: ①每条威胁的三个引用数组都**非空**，且每一项都 ∈ 上下文对应段的 id（**不悬空**）；②上下文的**每个**资产、**每条**信任边界、**每个**入口点都**至少**被一条威胁引用（**不漏**）
- **判据形式**: 查绝对事实（双向集合运算）；探针：让实现漏掉 `AS-3`（访问日志资产一条威胁都没引）→ 本条判红
- **类型**: 诚实性

### AC-026: 不得凭空造威胁，也不得凭空声称「已覆盖」
- **前置条件**: 同上
- **测试步骤**: ① 遍历每条威胁的 `rationale`；② 遍历 `owasp_coverage` / `supplements` 里 `status == "covered"` 的项
- **预期结果**: ①每条威胁的 `rationale` **非空**；②每条威胁都**同时**锚定了至少 1 个真实资产 + 1 条真实信任边界 + 1 个真实入口点（AC-025 已逐项核）；③每个 `covered` 声明的 `threat_refs` **非空**且每项 ∈ `threats[].id`（**不得**声明了覆盖却指不出威胁）
- **判据形式**: 查绝对事实；探针：让实现写 `rationale: ""` → 本条判红；让实现声明 `A05` 已覆盖但 `threat_refs` 为空 → 本条判红
- **类型**: 诚实性

### AC-027: 覆盖声明与事实必须一致（缺口必须显式）
- **前置条件**: 同上
- **测试步骤**: 遍历 `owasp_coverage` 与 `supplements` 的每一项，核对其 `status` 与威胁集合的事实
- **预期结果**: ①`status == "covered"` ⇒ `threat_refs` **恰为**该类的全部威胁 id（`owasp` 等于该类 / `supplement_refs` 含该键）；②`status == "not_applicable"` ⇒ 该类**没有任何**威胁（自相矛盾即违规）
- **判据形式**: 查绝对事实（双向集合运算）；探针：让实现把 `A02` 判成 `not_applicable` 却仍造了一条 `owasp == "A02"` 的威胁 → 本条判红
- **说明**: 本条只核「**声明与威胁事实是否一致**」。「不适用必须带非空理由 + 留一条未决问题」由 **AC-012**（OWASP 类）与 **AC-013**（四类实战补充）核；「十类/四类每类都必须有交代（不许静默跳过）」由 **AC-011** / **AC-013** 核 —— 三条各管各的，不互相遮蔽
- **类型**: 诚实性

### AC-028: 幂等、只写自己的目录、不得改输入
- **前置条件**: §0 全部夹具
- **测试步骤**: ① **幂等**：同一输入跑两次（输出到两个不同目录），两份产物**逐字**比对（**排除** `meta.generated_at`）；② **只读输入**：跑前对 `context.json` / `cases.json` / `bandit.json` 各算一次 sha256，跑完再算一遍；③ **只写 out-dir**：检查 `<out-dir>` 之外（尤其是输入文件所在目录）没有新增文件；④ **产物已存在即报错**：把 `<out-dir>/test-assets/security/threat-model.json` 预置为一个占位文件，再跑一次 → 必须**报错退出**（退出码 1）且**不得**覆盖（占位内容逐字未变）
- **预期结果**: ①~④全满足；④若被覆盖或未报错退出 → 判红
- **判据形式**: 查绝对事实（文件系统指纹）；探针：让实现在生成产物时顺手改写 `cases.json` → ② 判红；让实现直接覆盖已存在的产物 → ④ 判红
- **类型**: 写入权

### AC-029: 交付侧记账必须与实际一致
- **前置条件**: 被验包目录 + `feature-meta/security-plan/` 追溯件
⑥ 包内**既有**追溯件（`feature-meta/manifest.json` + `feature-meta/test-report/`、`feature-meta/regression-plan/`、`feature-meta/defect-verify/` 的四件套）必须**齐全且非空**，且 `feature-meta/manifest.json` 的 `req` 仍是 `REQ-006`（**不得**被改写成 `REQ-008` —— REQ-008 的追溯件在 `feature-meta/security-plan/`）
- **预期结果**: 六项全满足；任一不符 → 判红并点名
- **判据形式**: 查绝对事实（追溯件的实际内容 vs 契约的实际内容）
- **记载口径**: 判据条数在 md 里的**写法**必须能被抽取 —— 接受两种写法：
  「**29 条判据**」或「**判据条数：29**」（可带 `**` 等 markdown 强调符号）。
  两种写法抽出来的数字**取值集合**都必须恰好是 {29}（出现第二个不同取值即判红）。
  决策号范围的写法同理：接受 `D98~D126` 或逐个列出 `D98`…`D126`；
  ⚠️ md 里**不得**出现本 REQ 之外的决策号（如别处的 `D65`），否则取值集合会多出它。
  ⚠️ **「取值唯一」指的是范围字面量本身**：文件里出现的**每一个范围**（如 `D98~D125`）
  展开后的决策号集合都必须**恰好**等于实际集合 —— 不能靠同一文件**别处**提到 `D126`
  把一个更小的范围**掩盖**掉（那等于追溯范围少报而门判不出）。
- **类型**: 追溯

---

## 判据类型分布

| 组 | 条数 | 范围 | 类型分布 |
|---|---|---|---|
| A 交付物形状 | 4 | AC-001 ~ AC-004 | 功能×2 / 可用性×1 / 兼容性×1 |
| B 输入解析与校验 | 4 | AC-005 ~ AC-008 | 功能×4 |
| C 威胁模型 | 6 | AC-009 ~ AC-014 | 诚实性×5 / 功能×1 |
| D 权限矩阵 | 2 | AC-015 ~ AC-016 | 功能×1 / 诚实性×1 |
| E 用例派生 | 5 | AC-017 ~ AC-021 | 功能×4 / 追溯×1 |
| F 套件落位与可执行 | 3 | AC-022 ~ AC-024 | 功能×2 / 一致性×1 |
| G 诚实性与覆盖 | 5 | AC-025 ~ AC-029 | 诚实性×3 / 写入权×1 / 追溯×1 |
| **合计** | **29** | AC-001 ~ AC-029 | **功能 14 / 诚实性 9 / 追溯 2 / 一致性 1 / 写入权 1 / 可用性 1 / 兼容性 1** |

> 条数守恒核对：4 + 4 + 6 + 2 + 5 + 3 + 5 = **29**；
> 类型分布合计 14 + 9 + 2 + 1 + 1 + 1 + 1 = **29**。
> （AC-028 同时覆盖幂等与写入权，类型记为**写入权**；AC-024 明确落在**加载层**，类型记为**一致性**。）

---

## 验收纪律（对本 REQ 的验收方与实现者同样适用）

1. **一次只跑一个门** —— 并发跑门会产生无因果关系的失败键，污染判定。
2. **变异必须结构合法** —— 崩溃/语法错造成的判红是**假检出**，不计入检出率。
3. **变异注入后必须自证生效**（注入前后 sha256 比对）。
4. **判定"是否被检出"只看目标判据是否出现在新增失败键集合里**
   （新增失败键 = 变异运行的失败键 **减去** 基线失败键），**不能只看"比基线多"**，
   **更不能用对称差**（对称差把"基线红、变异后绿"也算成变化）。
5. **基线失败键只取 `^FAIL` 行** —— `PASS` / `UNDEC` 行里也有 AC 编号，混进来会让基线键集合
   变成**全集**，此后任何变异的"新增失败键"都恒为空或恒等于全集，**整套检测沦为橡皮章**。
6. **不可判定标「不可判定」**，不得判 passed。
7. **任何"脚本全绿"的结论必须钉 sha256**（验收脚本自身 sha + 被验实现指纹）。
8. **不许把不可满足的判据写成判据** —— 例如「`run-suite.mjs --dry-run` 跑通」（`security` 执行器未实现）。
