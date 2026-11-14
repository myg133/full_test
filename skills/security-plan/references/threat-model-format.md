# 威胁模型产物格式（`threat-model.json`）

> 契约来源：需求 F2 / F3、决策 D102 / D103 / D104 / D113 / D114。

## 1. 顶层结构

```json
{
  "schema_version": 1,
  "meta": { "service": "order-api", "generated_at": "…", "threat_count": 12,
            "context_ref": "context.json", "functional_case_count": 3 },
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

- `assets` / `trust_boundaries` / `entry_points` 三段与**输入上下文逐条对应**（**集合相等**：不增、不减、不改 id）。
- `meta` 的字段集**开放**（额外说明字段不构成违规）。

## 2. 威胁条目（字段集**封闭 12 个**）

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

⚠️ `category` 用 **STRIDE 六类**、`owasp` 用 A01~A10：两个维度各管一件事，不重复。

## 3. OWASP 覆盖完整性（诚实性红线）

`owasp_coverage` 的键集**恰为** `A01`~`A10`（10 个，不多不少）。每一类的取值二选一：

```json
"A01": { "status": "covered", "threat_refs": ["TH-9"] },
"A02": { "status": "not_applicable", "reason": "…", "open_question_ref": "Q-1" }
```

| 规则 | 说明 |
|---|---|
| `status` | 枚举 `covered` / `not_applicable` |
| `covered` ⇒ `threat_refs` | **非空**数组，且**恰为**该类的全部威胁 id（被引用威胁的 `owasp` 必须等于该类；反过来该类的每条威胁都必须出现在这个数组里） |
| `not_applicable` ⇒ `reason` | **非空**字符串 |
| `not_applicable` ⇒ `open_question_ref` | 指向 `open_questions[]` 里**存在**的一条（其 `category` 等于该 OWASP 类） |
| **不许静默跳过** | 既没有 `covered` 声明、也没有 `not_applicable` 声明 ⇒ 违规（假的「已经覆盖了」） |

⚠️ **契约不指定「哪一类必须不适用」**：适用性判断属于实现（它看得见服务形态），
契约只强制**交代完整 + 理由非空 + 留了未决问题**。

### 本实现的判定口径

- 覆盖状态**一律从威胁集合反推**（有该类威胁 ⇒ covered；没有 ⇒ not_applicable）。
  ⇒ 结构上不可能出现「判 not_applicable 却有该类威胁」的自相矛盾。
- 「不适用」的理由说明**检查了什么**（例如「已检查 assets / entry_points / resources
  的名称与说明，未命中任何密码学关键词」），不是一句套话。

## 4. 未决问题（`open_questions[]`）

```json
{ "id": "Q-1", "category": "A02", "question": "本服务是否真的不涉及任何密码学环节？", "reason": "…" }
```

- `id` 必填、唯一、非空；`category` ∈ `A01`~`A10` 或四个补充类键；`question` 与 `reason` 非空。
- **只存在于 `threat-model.json`**：cases.json 的 `open_questions` 是 v2 形状，
  它的 `requirement_refs` 必须指向**真实存在**的需求条目，而「不适用的类」没有威胁、
  也就没有需求条目 —— 硬塞会造出悬空引用。

## 5. 四类实战补充

`supplements` 的键集**恰为** 4 个：`file_upload` / `ssrf` / `xxe` / `deserialization`。
取值与 `owasp_coverage` **同构但少一项**：

- `covered` ⇒ `threat_refs` 非空，且**恰为** `supplement_refs` 含该键的全部威胁 id；
- `not_applicable` ⇒ `reason` **非空**（不要求 `open_question_ref`）。

**不强制**每个项目都有这四类威胁，但**必须逐类显式判定**。

## 6. 扫描接入（职责边界）

### 谁来跑扫描器

**本 skill 自己一个扫描器都不跑**（零第三方依赖、不联网）。
扫描由 agent 用已交付的 `qa-toolchain`（`bin/qa`）跑 bandit / npm audit，
把结果**喂进来**（`--scan`）。工具装不上 ⇒ agent **显式**传一份「扫描状态 JSON」。

### `--scan` 的三种合法形态

| 形态 | 判别特征 | 语义 |
|---|---|---|
| **bandit 结果** | 根是对象且 `results` 是数组 | `scan.tool = "bandit"`；finding 数 = `results.length` |
| **npm audit 结果** | 根是对象且 `vulnerabilities` 是对象 | `scan.tool = "npm-audit"`；finding 数 = `vulnerabilities` 的键数 |
| **扫描状态** | 根是对象且 `status` ∈ {`unavailable`, `failed`} | `scan.status` = 该值；`reason` **必填非空**；finding 数 = 0 |

三者都识别不出来 ⇒ **输入非法** ⇒ 退出码 1。

### 产物里的扫描声明

| 规则 | 说明 |
|---|---|
| `scan.status` | 枚举 `provided` / `not_provided` / `unavailable` / `failed`，**永远存在** |
| `not_provided` ⇔ | 没有传 `--scan` |
| `unavailable` / `failed` ⇔ | 传了「扫描状态」形态（此时 `scan_findings` 必须为空数组） |
| `provided` ⇔ | 传了 bandit / npm audit 结果（此时 `scan_findings` **非空**） |
| `scan_findings` 条数 | **等于**输入扫描结果的 finding 数 |
| `scan_findings[].id` | 形如 `SCAN-<序号>`，文件内唯一 |
| `scan_findings[].threat_refs` | **非空**数组，每项 ∈ `threats[].id` |
| 被引用威胁 | 其 `source` 必须含 `scan`，且 `scan_refs` 必须含该 finding 的 id |
| **未提供扫描时** | **不得**出现 `source` 含 `scan` 的威胁；**不得**声称「已做依赖扫描」 |

⚠️ 「未提供扫描 ⇒ 显式声明」是硬要求：静默跳过 = 假的「已经覆盖了依赖风险」。
