# REQ-007 验收判据 —— `defect-verify`（R3 缺陷复现用例生成）

> 本文件是**契约**，不是说明材料。实现者按这里的规则交付，验收脚本按这里的规则判定。
> 判据条数：**29 条**（AC-001 ~ AC-029）。条数**不增不减不改号**。
> 决策记录见 `decisions.md`（D72 起）。功能契约见 `demand.md`（F1~F8）。

---

## §0 公共夹具规格（判据的公共前置）

验收脚本自造以下夹具，**全部落在临时目录**（`$WORK`），**不得**写进被验包。
夹具内容与 `demand.md` §0 的示例一致。

### §0.1 缺陷单夹具 `$FX/DEFECTS`（`defects.json`）

```json
{
  "schema_version": 1,
  "defects": [
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
      "root_cause": null,
      "reproduction": {
        "command": "curl -X POST https://api.example.com/coupon/redeem",
        "steps": ["以满减券下单", "触发核销"],
        "expected_failure": "实付金额比预期多 0.01 元"
      }
    },
    {
      "id": "BUG-002",
      "title": "订单列表接口偶发超时",
      "severity": "medium",
      "case_refs": ["TC-099"],
      "status": "open",
      "reproduction": {
        "command": "curl -X GET https://api.example.com/orders",
        "steps": ["查询订单列表"],
        "expected_failure": "请求超时"
      }
    },
    {
      "id": "BUG-003",
      "title": "优惠券核销后金额校验缺失",
      "severity": "medium",
      "status": "open",
      "reproduction": {
        "command": "curl -X POST https://api.example.com/coupon/redeem",
        "steps": ["以满减券下单", "触发核销"],
        "expected_failure": "实付金额与预期不一致"
      }
    },
    {
      "id": "BUG-004",
      "title": "支付回调缺陷（复现信息不足）",
      "severity": "low",
      "status": "open",
      "reproduction": { "command": "", "steps": [], "expected_failure": "" }
    },
    {
      "id": "BUG-005",
      "title": "导出报表偶发空文件",
      "severity": "low",
      "status": "open",
      "reproduction": {
        "command": "curl -X GET https://api.example.com/reports/export",
        "steps": ["触发报表导出", "下载导出文件"],
        "expected_failure": "导出文件为空"
      }
    }
  ]
}
```

五条缺陷**刻意**覆盖五条不同的分支：

| 缺陷 | 触发分支 | 期望处置 |
|---|---|---|
| `BUG-001` | `case_refs` 非空且**命中** `TC-017` | `reused` |
| `BUG-002` | `case_refs` 非空但 `TC-099` **不在**用例集里 | `unresolved`（理由点名 `TC-099`） |
| `BUG-003` | `case_refs` 为空，**特征匹配命中** `TC-021` | `reused` |
| `BUG-004` | `reproduction.steps` 为空 ⇒ **信息不足** | `unresolved`（理由说明缺什么） |
| `BUG-005` | `case_refs` 为空、特征**不命中**、信息充分 | `derived`（新用例 `TC-102`） |

### §0.2 已有用例集夹具 `$FX/CASES`（`cases.json`，schema v2）

**7 条用例**（编号刻意留空档，并**故意占用扩展段** `TC-101`）：

| `id` | `title` | `requirement_refs` | `steps[].action` | `tags` |
|---|---|---|---|---|
| `TC-001` | 健康检查通过 | `["R-1"]` | `GET /api/health` | `["smoke"]` |
| `TC-002` | 订单查询返回 500 | `["R-2"]` | `GET /api/orders` | `["order"]` |
| `TC-003` | 列表用例缺少断言 | `["R-2"]` | `GET /api/items` | `["order"]` |
| `TC-005` | 报表导出通过 | `["R-3"]` | `GET /api/reports` | `["report"]` |
| `TC-017` | 满减券核销用例 | `["R-4"]` | `以满减券下单` | `["coupon"]` |
| `TC-021` | 优惠券核销复现用例 | `["R-4"]` | `以满减券下单` → `触发核销` | `["coupon","regression"]` |
| `TC-101` | 已占用扩展段编号的用例 | `["R-3"]` | `占位导出` | `["report"]` |

每条用例另有：`dimension: "functional"`、`priority: "P0"`、`method: ["M1.1"]`、`status: "active"`、
`preconditions: []`、`data: {}`；`steps[].expected` 为普通字符串（如 `TC-001` 的 `状态码 200`）。

用例集自身的 `requirements[]` = `R-1`（健康检查）/ `R-2`（订单查询）/ `R-3`（报表导出）/ `R-4`（优惠券核销）；
`open_questions: []`；`coverage_matrix` 四条（每个 R 一条）。

⚠️ **`TC-101` 是故意的**：扩展段 `TC-101` 已被占用 ⇒ 派生的新用例必须**顺延**到 `TC-102`
（AC-013 的"不撞号"由此可判，而不是靠"碰巧没撞"）。

### §0.3 R3 轮次目录 `$FX/CYCLE`（目录名 `R3-DEMO`）

```
$FX/CYCLE/cycle.json
```

```json
{
  "cycle_id": "R3-DEMO",
  "round": "R3",
  "round_type": "defect-verify",
  "requirement": "REQ-DEMO",
  "scopes": ["functional"],
  "scopes_skipped": [],
  "status": "in_progress",
  "stages": { "clarify": { "status": "done" }, "design": { "status": "in_progress" } },
  "history": [{ "at": "2026-11-13T00:00:00+08:00", "from": "planned", "to": "in_progress", "by": "seed" }],
  "trigger": { "type": "defect", "ref": "BUG-001" }
}
```

- `cycle_id` **等于**目录名 `R3-DEMO`（目录契约 §1）
- `trigger.ref` = `BUG-001` ∈ 输入缺陷 id 集合（D79）

### §0.4 期望目录树（跑完一次之后）

```
$FX/proj/                                   # 项目根（AC-019 的套件目录挂在这里）
├── test-assets/
│   ├── cycles/
│   │   └── R3-DEMO/
│   │       ├── cycle.json                  # 逐字节未变（AC-027）
│   │       └── defect-cases.json           # ★ 本 REQ 的产物（AC-024/025/026）
│   └── environments/
│       └── mock.json                       # AC-019 的环境定义
└── suites/
    └── REQ-DEMO-coupon/
        └── suite.json                      # AC-019：cases_file 相对解析到 defect-cases.json
```

### §0.5 判据角色的互斥要求（否则判据会互斥或变异会逃逸）

1. **`BUG-001`（`case_refs` 命中）与 `BUG-003`（特征命中）都是 `reused`** —— 这是**故意的**：
   AC-009 判"**显式引用**命中即复用"，AC-010 判"**特征**命中即复用"，两条各管各的，不互斥。
   两者都能在产物里分辨（`BUG-001` 的 `source_case_id` 是 `TC-017`，`BUG-003` 的是 `TC-021`）。
2. **`BUG-002` 与 `BUG-004` 都是 `unresolved`** —— 也是**故意的**：
   AC-009② 判"`case_refs` 找不到 ⇒ `unresolved`"，AC-012 判"信息不足 ⇒ `unresolved`"，
   两条的理由内容不同（一个点名 `TC-099`，一个说明缺复现步骤）。
3. **只有 `BUG-005` 是 `derived`** —— AC-011（未命中才派生）与 AC-013（扩展编号段不撞号）
   只在它身上生效；**不得**让别的缺陷也派生，否则"派生"与"不撞号"两条判据会互相遮蔽。
4. **`BUG-005` 的复现步骤刻意与任何已有用例都不同**（`触发报表导出` / `下载导出文件`）——
   否则它会意外命中特征匹配（`TC-005` 的 `GET /api/reports`、`TC-101` 的 `占位导出` 都不匹配）。

### §0.6 基线真值表（夹具跑出来的**唯一**正确结论）

门与实现都以此为准。**期望值由门自己从夹具重算**，下列是写死给人看的对照：

| 字段 | 真值 | 来源 |
|---|---|---|
| `meta.case_count` | `3` | `cases.length` |
| `meta.defect_count` | `5` | `defects.length` |
| `meta.cycle_id` | `R3-DEMO` | 轮次目录的 `cycle.json` |
| `meta.suite` | `REQ-DEMO-coupon` | `--suite` |
| `requirements[]` | **5 条**，`R-1`~`R-5`，与缺陷**同序**（`R-1`↔`BUG-001` … `R-5`↔`BUG-005`） | 按缺陷顺序 |
| `requirements[i].source_ref` | `defects.json#/defects/<i>` | 按缺陷下标 |
| `coverage_matrix[]` | **3 条**（`R-1` / `R-3` / `R-5`）—— 只列**被覆盖**的需求条目 | 有对应用例的需求条目 |
| `defects[]` | **5 条**，与输入缺陷**同序** | 输入顺序 |
| `defects[].disposition` | `reused` / `unresolved` / `reused` / `unresolved` / `derived` | §0.1 的分支表 |
| `BUG-001.reused_case_refs` | `[{"suite":"REQ-DEMO-coupon","case_id":"TC-017"}]` | `case_refs` 命中 |
| `BUG-003.reused_case_refs` | `[{"suite":"REQ-DEMO-coupon","case_id":"TC-021"}]` | 特征命中 |
| `BUG-002.reason` | 非空，且**含 `TC-099`** | 点名找不到的 id |
| `BUG-004.reason` | 非空，且**不含** `TC-099`（它不是"找不到用例"，是"信息不足"） | 说明缺什么 |
| `BUG-005.derived_case_id` | **`TC-102`** | 扩展段顺延（`TC-101` 已被占用） |
| `cases[]` | **3 条**，顺序 = 缺陷顺序 | `TC-017` → `TC-021` → `TC-102` |
| `cases[].id` | `TC-017` / `TC-021` / `TC-102` | 同上 |
| `cases[].origin` | `reused` / `reused` / `derived` | 同上 |
| `cases[].source_case_id` | `TC-017` / `TC-021` / `null` | 同上 |
| `cases[].source_suite` | `REQ-DEMO-coupon` / `REQ-DEMO-coupon` / `null` | 同上 |
| `cases[].requirement_refs` | `["R-1"]` / `["R-3"]` / `["R-5"]` | 该缺陷的 `R-<n>`（D76） |
| `cases[].defect_refs` | `["BUG-001"]` / `["BUG-003"]` / `["BUG-005"]` | 同上 |
| `cases[].tags` | 含 `defect-verify` 与本条缺陷的 id | F3.2 |
| `cases[].steps`（`TC-102`） | 2 步，`action` = `触发报表导出` / `下载导出文件`，`expected` 均为 `导出文件为空` | F3.3 |
| 顶层字段集 | 恰好 7 个：`schema_version` / `meta` / `requirements` / `open_questions` / `coverage_matrix` / `defects` / `cases` | F4.1（封闭） |

⚠️ **`meta` 的字段集是开放的**（F4.1）：额外说明字段（如 `meta.note`）**不构成违规** ——
负控 M0 正是靠这一点做到"无害"。

⚠️ **`defects[]` 条目的字段集是封闭的**（F4.2）：多一个字段即违规。

---

## A 组：交付物形状（AC-001 ~ AC-004）

### AC-001: `defect-verify` skill 存在且结构合法
- **前置条件**: 被验包目录
- **测试步骤**: ① 检查 `skills/defect-verify/` 存在；② `SKILL.md` 存在且 YAML frontmatter 含 `name: defect-verify` 与**非空** `description`（取 frontmatter 的**值**再判空 —— 块标量 `|` 取其缩进块；普通标量剥掉首尾引号，`""` / `''` 判空）；③ `skill-meta.json`、`references/defect-input-schema.md`、`references/derivation-rules.md`、`scripts/make-defect-cases.mjs`、`scripts/check-defect-cases.mjs` 存在且**非空**；④ `scripts/lib/` 下 `.mjs` 模块 **≥ 3 个**且非空；⑤ 两个脚本**各自**（不是两个合起来满足其一）首行是 `#!/usr/bin/env node`、文件**可执行**、且 `node --check` 通过；任一项不满足 → 判红并**点名是哪一项**
- **预期结果**: 五项全满足
- **判据形式**: 查**绝对事实**（文件真实存在且非空）；探针：把 `description` 改成 `""` → 本条判红；删掉 `references/derivation-rules.md` → 本条判红；把某个脚本 `chmod -x` → 本条判红
- **类型**: 功能

### AC-002: 每个 skill 都声明版本与依赖（`skill-meta.json`）
- **前置条件**: 被验包目录
- **测试步骤**: 对 `skills/` 下**每一个**含 `SKILL.md` 的目录，检查存在 `skill-meta.json`；解析它必须有 `name`（非空且等于目录名）、`version`（形如 `<数字>.<数字>.<数字>`）、`requires`（对象；值为形如 `>=<x.y.z>` 或 `<x.y.z>` 的约束）；并检查 `name` 与该 skill 的 SKILL.md frontmatter `name` 一致（frontmatter 取**值**再比对 —— 剥首尾引号、支持块标量；不得用「取第一个 token」的裸正则）
- **预期结果**: 每个 skill 都有合法声明；**`defect-verify` 的 `requires` 必须同时含 `test-case-design`（消费用例集）与 `test-execute`（复现用例由它执行）**；任一不满足 → 判红并点名
- **判据形式**: 查绝对事实；探针：删掉某个 skill 的 `skill-meta.json` → 本条判红；把 `defect-verify.requires` 里的 `test-execute` 删掉 → 本条判红
- **类型**: 功能

### AC-003: README 的 skill 清单与实际目录一致（且 `defect-verify` 两处都在）
- **前置条件**: 被验包目录 + `README.md`
- **测试步骤**: ① 取 `skills/` 下全部含 `SKILL.md` 的目录名集合 S；② 取 `README.md` 的 **skill 清单**（表格首格 ∪ `skills/<name>` 路径 ∪ 安装树条目）集合 R；③ 检查 S == R；④ 检查 `defect-verify` 出现在 **skill 表格**里；⑤ 检查 `defect-verify` 出现在 **安装树代码块**里
- **预期结果**: ①集合完全相等；②③④⑤全满足；README 漏写或多写任一 skill → 判红并点名；`defect-verify` 漏在任一处 → 判红并点名**漏在哪一处**
- **判据形式**: 查绝对事实（与目录实际内容比对），不查"README 里说了几个"
- **类型**: 可用性

### AC-004: 新产物不得打破既有目录契约
- **前置条件**: `skills/test-case-design/scripts/verify-layout.mjs` + 一个合法的 `test-assets/` 项目
- **测试步骤**: ① 造一个满足 REQ-002B 契约的最小项目（含 `test-assets/cycles/R3-DEMO/cycle.json`）；② 在其 R3 轮次目录里放 `defect-cases.json`（本 REQ 的产物落位）；③ 跑 `verify-layout.mjs`；④ 断言退出码为 0 且无 FAIL 级问题；⑤ **错误位置探针**：把 `defect-cases.json` 放到错误位置（如 `test-assets/` 根）再跑一次，必须给出**明确结论**
- **预期结果**: ③④成立；⑤的结论必须是二选一且**明确**：位置**不受约束**（校验器不查该位置 → 本条判绿，**不得**要求实现去管它）或位置**受约束**（校验器判红 → 本条判红）。**不接受"没有输出任何结论"**
- **判据形式**: 查绝对事实（实跑校验器的退出码）；探针：把产物放到错误位置 → 按⑤的结论判读
- **类型**: 兼容性

---

## B 组：输入解析与缺陷单校验（AC-005 ~ AC-008）

> 以下各条的前置：`node skills/defect-verify/scripts/make-defect-cases.mjs --defects <夹具> --cases $FX/CASES --suite REQ-DEMO-coupon --cycle-dir $FX/CYCLE [--out-dir <输出目录>]`

### AC-005: 缺陷单的必填字段必须校验（结构层）
- **前置条件**: §0.1 的缺陷单 + 四份**变体**副本：① 删掉 `defects[0].id`；② 删掉 `defects[0].title`；③ 删掉 `defects[0].severity`；④ 把 `defects[0].reproduction` 改成字符串
- **测试步骤**: 四种变体各跑一次，检查退出码、stderr、输出目录
- **预期结果**: 四种情形**退出码均为 1**（输入非法；用法错 = 2 另行判定）；stderr **点名是什么坏了**（含字段名，如 `id` / `title` / `severity` / `reproduction`）；输出目录里**不得**出现 `defect-cases.json`（**存在性**判定，0 字节也算）
- **判据形式**: 查绝对事实（真实退出码 + 产物目录实况）；探针：让实现在解析失败时仍写出一个空的 `defect-cases.json` → 本条判红
- **类型**: 功能

### AC-006: 输入非法时必须报错退出，且不得留下半份产物
- **前置条件**: 三份**非法**缺陷单副本：① 根不是对象（`[]`）；② `defects` 不是数组（`{"defects":{}}`）；③ 整个文件不是合法 JSON
- **测试步骤**: 三种情形各跑一次，检查退出码、stderr、输出目录
- **预期结果**: 三种情形**退出码均为 1**；stderr **点名是什么坏了**（含 `defects` / 文件名）；输出目录里**不得**出现 `defect-cases.json`（**存在性**判定）
- **判据形式**: 查绝对事实；探针：让实现在解析失败时先建一个空的 `defect-cases.json` → 本条判红
- **类型**: 功能

### AC-007: 缺陷 id 必须唯一且格式合法
- **前置条件**: 两份变体缺陷单：① 把 `defects[1].id` 改成 `BUG-001`（**与 `defects[0].id` 重复**）；② 把 `defects[0].id` 改成 `BUG-XYZ`（**格式错**）
- **测试步骤**: 两种变体各跑一次，检查退出码、stderr、输出目录
- **预期结果**: 两种情形**退出码均为 1**；stderr **点名**坏点（重复时点名那个重复的 id，格式错时点名那个 id）；**不得**留下 `defect-cases.json`
- **判据形式**: 查绝对事实；探针：让实现不查唯一性 → 本条判红
- **类型**: 功能

### AC-008: `severity`（与 `status`）的枚举必须合法
- **前置条件**: 两份变体缺陷单：① 把 `defects[0].severity` 改成 `critical`；② 把 `defects[1].status` 改成 `reopened`
- **测试步骤**: 两种变体各跑一次，检查退出码、stderr、输出目录
- **预期结果**: 两种情形**退出码均为 1**；stderr **点名**是哪个字段越界、越界值是什么；**不得**留下 `defect-cases.json`
- **判据形式**: 查绝对事实；探针：让实现接受任意 severity 字符串 → 本条判红
- **类型**: 功能

---

## C 组：派生规则（AC-009 ~ AC-014）

### AC-009: `case_refs` 命中即复用；找不到即改判 `unresolved`
- **前置条件**: §0.1 的缺陷单 + §0.2 的用例集（`TC-017` **在**用例集里，`TC-099` **不在**）
- **测试步骤**: 跑一次主入口；取产物 `defects[]` 里 `BUG-001` 与 `BUG-002` 两条，逐字段核对
- **预期结果**:
  - `BUG-001.disposition == "reused"`；`reused_case_refs` 恰为 `[{"suite":"REQ-DEMO-coupon","case_id":"TC-017"}]`；`derived_case_id` **不存在**；`reason` **不存在**
  - `BUG-002.disposition == "unresolved"`；`reason` **非空**且**包含 `TC-099`**；**不得**有 `reused_case_refs` 或 `derived_case_id`
  - **产物里不得有**以 `BUG-001` 为 `defect_refs` 的 `origin == "derived"` 用例（命中即复用 ⇒ 不新建）
- **判据形式**: 查绝对事实（产物内容 vs 夹具重算）；探针：让实现在 `case_refs` 找不到时仍判 `reused` → 本条判红
- **类型**: 功能

### AC-010: 特征匹配命中即复用（不得新建用例）
- **前置条件**: 同上（`BUG-003` 的 `reproduction` 与 `TC-021` 的 steps 归一化后相等，且 `TC-021` 无 `reproduction.command`）
- **测试步骤**: 取产物 `defects[]` 里 `BUG-003` 那条；并扫描产物 `cases[]`
- **预期结果**: `disposition == "reused"`；`reused_case_refs` 恰为 `[{"suite":"REQ-DEMO-coupon","case_id":"TC-021"}]`；`derived_case_id` **不存在**；**产物里不得有**以 `BUG-003` 为 `defect_refs` 的 `origin == "derived"` 用例
- **判据形式**: 查绝对事实；探针：让实现在特征命中时仍派生新用例 → 本条判红
- **类型**: 功能

### AC-011: 未命中才派生
- **前置条件**: 同上（`BUG-005` 不命中任何已有用例）
- **测试步骤**: 取产物 `defects[]` 里 `BUG-005` 那条；取产物 `cases[]` 里 `defect_refs` 含 `BUG-005` 的那条
- **预期结果**: `disposition == "derived"`；`derived_case_id` **非空**且等于该用例的 `id`；该用例存在、`origin == "derived"`、`defect_refs` 含 `BUG-005`；**不得**有 `reused_case_refs`、**不得**有 `reason`
- **判据形式**: 查绝对事实；探针：让实现把 `BUG-005` 判成 `unresolved`（信息其实充分）→ 本条判红
- **类型**: 功能

### AC-012: 复现信息不足必须判 `unresolved` 并给非空理由
- **前置条件**: 同上（`BUG-004` 的 `reproduction.steps` 为空、`expected_failure` 为空）
- **测试步骤**: 取产物 `defects[]` 里 `BUG-004` 那条；并扫描产物 `cases[]`
- **预期结果**: `disposition == "unresolved"`；`reason` **非空**；**不得**有 `reused_case_refs` 或 `derived_case_id`；产物 `cases[]` 里**没有** `defect_refs` 含 `BUG-004` 的用例
- **判据形式**: 查绝对事实；探针：让实现在信息不足时仍派生一条用例（或悄悄判 `reused`）→ 本条判红
- **类型**: 诚实性

### AC-013: 派生的新用例必须落在扩展编号段且**不撞号**
- **前置条件**: 同上（输入用例集**已占用** `TC-101`）
- **测试步骤**: 取产物里 `origin == "derived"` 的用例；取输入用例集的全部 `id`
- **预期结果**: 派生用例的 `id` 匹配 `^TC-1[0-9][0-9]$`（扩展段 `TC-101`~`TC-999`）；其 `id` **不与输入用例集的任何 id 相同**；且**不与产物里其它用例的 id 相同**
- **判据形式**: 查绝对事实（集合运算）；探针：让实现固定从 `TC-101` 起编号（撞上已占用的号）→ 本条判红
- **说明**: "扩展段用尽 ⇒ 改判 `unresolved`"是契约规则（demand.md D81），但本夹具**造不出**用尽的情形
  （需要 899 条已占用用例）—— 本条只判**可机械核**的那部分；用尽分支登记为遗留项
- **类型**: 功能

### AC-014: 处置结论必须互斥且完备
- **前置条件**: 同上
- **测试步骤**: 取产物 `defects[]` 整段，逐条核对
- **预期结果**: ①条目数 == 输入缺陷数（5）；②每条 `disposition` ∈ {`derived`,`reused`,`unresolved`}；③每条**有且只有一个**结论字段：`derived` ⇒ 有 `derived_case_id` 无 `reused_case_refs` 无 `reason`；`reused` ⇒ 有 `reused_case_refs` 无 `derived_case_id` 无 `reason`；`unresolved` ⇒ 有非空 `reason` 无 `reused_case_refs` 无 `derived_case_id`；④`defects[]` 里每条的字段集**恰好**是 F4.2 规定的那几个（封闭）
- **判据形式**: 查绝对事实（逐条字段核）；探针：让实现给一条缺陷同时写 `derived_case_id` 与 `reused_case_refs` → 本条判红
- **类型**: 一致性

---

## D 组：复现用例形状与可执行（AC-015 ~ AC-019）

### AC-015: 复现用例的 `id` 必须合 `^TC-\d{3}$`
- **前置条件**: §0.1 + §0.2 的夹具
- **测试步骤**: 遍历产物 `cases[]` 的每个 `id`
- **预期结果**: 每个 `id` 都匹配 `^TC-\d{3}$`（**三位**数字，`TC-1001` 不合法）；`id` 在产物内**唯一**
- **判据形式**: 查绝对事实；探针：让实现派生出 `TC-1001` → 本条判红
- **类型**: 功能

### AC-016: 复现用例的必填字段齐全且 `requirement_refs` 不悬空
- **前置条件**: 同上
- **测试步骤**: 遍历产物 `cases[]`，逐条检查字段；再取产物 `requirements[]` 的 id 集合
- **预期结果**: 每条用例都有：`id`（非空字符串）、`title`（非空）、`requirement_refs`（**非空数组**，每项 ∈ `requirements[].id` ⇒ **不悬空**）、`dimension`（非空字符串）、`priority`（非空字符串）、`method`（非空数组）、`status`（非空字符串）、`steps`（**非空数组**，每步有非空 `action` 与非空 `expected`）、`tags`（数组）；另外：`coverage_matrix[]` 的每个 `requirement` ∈ `requirements[].id`，且**每个有对应用例的需求条目都在 `coverage_matrix` 里**
- **判据形式**: 查绝对事实（逐字段核 + 集合运算）；探针：让实现把 `requirement_refs` 指向不存在的 `R-9` → 本条判红
- **类型**: 功能

### AC-017: `defect_refs` / `origin` / `source_case_id` / `source_suite` 必须齐全
- **前置条件**: 同上
- **测试步骤**: 遍历产物 `cases[]`，逐条检查这 4 个字段；取输入缺陷 id 集合与输入用例 id 集合
- **预期结果**: 每条用例都有 `defect_refs`（**非空数组**，每项 ∈ **输入**缺陷 id 集合）、`origin`（∈ {`derived`,`reused`}）；`origin == "reused"` ⇒ `source_case_id` 非空且 ∈ **输入**用例 id 集合、`source_suite` 非空字符串；`origin == "derived"` ⇒ `source_case_id` 为 `null` 或不存在、`source_suite` 为 `null` 或不存在
- **判据形式**: 查绝对事实；探针：让实现在 `reused` 用例上写一个不存在的 `source_case_id` → 本条判红
- **类型**: 功能

### AC-018: `tags` 必须含 `defect-verify` 与该缺陷的 id
- **前置条件**: 同上
- **测试步骤**: 遍历产物 `cases[]`，逐条看 `tags`
- **预期结果**: 每条用例的 `tags` 数组**含** `"defect-verify"`；且**含**它 `defect_refs` 里的**每一个**缺陷 id
- **判据形式**: 查绝对事实；探针：让实现漏掉缺陷 id 的 tag → 本条判红（执行侧就分不出批跑）
- **类型**: 功能

### AC-019: 产物必须能被 `test-execute` 直接消费
- **前置条件**: §0.3 的轮次目录 + §0.4 的套件目录（`suite.json` 按 demand.md F4.3 的形状写，`cases_file` **相对 suite.json 所在目录**解析到 `defect-cases.json`）+ 被验包里的 `skills/test-execute/scripts/run-suite.mjs`
- **测试步骤**: ① 跑 `run-suite.mjs <suite.json> --dry-run`，检查退出码与"计划执行 N 条用例"里的 N；② 把 `suite.json` 的 `tags.include` 换成 `["BUG-005"]` 再跑一次，核对 N；③ 核对 `suite.json` 的**顶层字段集**恰为 F4.3 的 9 个字段
- **预期结果**: ①退出码 0 且 N == 产物 `cases.length`（3）；②N == 引用 `BUG-005` 的用例数（1）；③顶层字段集封闭且无表外字段
- **判据形式**: 查绝对事实（**实跑** `--dry-run` 的退出码与输出，不是查文件存在）；探针：让产物的 `cases[]` 结构不被 `loadCases` 接受（缺 `cases` 数组或 id 非字符串）→ 本条判红
- **说明**: 用 `--dry-run` 而不是真发请求 —— 本条判的是"**能不能被消费**"，不是"复现是否成功"
  （复现成功与否是 R3 轮次执行阶段的事，且依赖真实环境）
- **类型**: 功能

---

## E 组：诚实性（AC-020 ~ AC-023）

### AC-020: 输出的缺陷 id 集合必须等于输入的缺陷 id 集合
- **前置条件**: §0.1 的缺陷单（5 条）
- **测试步骤**: 取产物 `defects[]` 的 `id` 集合与输入 `defects[].id` 集合比对
- **预期结果**: 两个集合**完全相等**（不多、不少）；产物里**没有重复**的 id；`requirements[]` 的条目数 == 输入缺陷数，且 `requirements[i].id` 与 `requirements[i].source_ref` 按**缺陷顺序**一一对应（`R-<i+1>` ↔ `defects.json#/defects/<i>`）
- **判据形式**: 查绝对事实（集合运算）；探针：让实现漏掉一条缺陷 → 本条判红
- **类型**: 诚实性

### AC-021: `unresolved` 必须带非空理由
- **前置条件**: 同上（`BUG-002` 与 `BUG-004` 两条 `unresolved`）
- **测试步骤**: 遍历产物 `defects[]` 里 `disposition == "unresolved"` 的条目
- **预期结果**: 每条的 `reason` **存在**且**非空**（去掉首尾空白后仍非空）；一条 `unresolved` **不得**同时带 `derived_case_id` 或 `reused_case_refs`
- **判据形式**: 查绝对事实；探针：让实现写 `reason: ""` → 本条判红
- **类型**: 诚实性

### AC-022: 不得凭空造缺陷
- **前置条件**: 同上
- **测试步骤**: 扫描产物**全部**位置出现的缺陷 id：`defects[].id`、`cases[].defect_refs[]`、`requirements[]` 的 `source_ref` 里出现的缺陷下标
- **预期结果**: 这些 id **全部** ∈ 输入缺陷 id 集合；`requirements[]` 的 `source_ref` 形如 `defects.json#/defects/<i>` 且 `<i>` 落在输入下标范围内；`cases[].defect_refs[]` 的每一项都 ∈ 输入缺陷 id 集合
- **判据形式**: 查绝对事实（集合运算 + 正则抽取）；探针：让实现在产物里塞一个 `BUG-999` → 本条判红
- **类型**: 诚实性

### AC-023: 不得重复派生
- **前置条件**: 同上
- **测试步骤**: ① 统计每个缺陷在产物 `cases[]` 里作为 `defect_refs` 出现的**派生用例**条数；② 检查产物内所有用例 `id` 互不重复
- **预期结果**: ①每个缺陷**最多**一条 `origin == "derived"` 的用例；且 `BUG-001`（`case_refs` 命中）与 `BUG-003`（特征命中）**一条派生用例都没有**；②产物内用例 `id` 互不重复
- **判据形式**: 查绝对事实；探针：让实现在特征命中时**既复用又派生** → 本条判红
- **类型**: 诚实性

---

## F 组：幂等与只读（AC-024 ~ AC-026）

### AC-024: 同一输入两次必须逐字相同（除 `generated_at`）
- **前置条件**: §0.1 + §0.2 + §0.3 的夹具
- **测试步骤**: 跑两次主入口（输出到两个不同目录）；两份 `defect-cases.json` 逐字比对（**排除** `meta.generated_at`）
- **预期结果**: 除 `meta.generated_at` 外**逐字相同**
- **判据形式**: 查绝对事实；探针：让实现在产物里塞入随机值或当前时间 → 本条判红
- **类型**: 可复现性

### AC-025: 不得修改输入（缺陷单 + 已有用例集）
- **前置条件**: §0.1 + §0.2 的夹具
- **测试步骤**: 跑主入口**之前**，对 `defects.json` 与 `cases.json` 各算一次 sha256；跑完后再算一遍，逐个比对；并检查它们**所在目录**里没有新增文件
- **预期结果**: 两份输入的 sha256 **前后一致**；输入所在目录**没有**新增文件（跑完的目录内容与跑前逐字相同）
- **判据形式**: 查绝对事实（文件系统指纹）；探针：让实现在生成产物时顺手改写 `cases.json` → 本条判红
- **类型**: 写入权

### AC-026: 只写自己的目录
- **前置条件**: 同上 + §0.3 的轮次目录
- **测试步骤**: ① 跑主入口，检查产物落在 `<out-dir>/defect-cases.json`；② 检查 `cycle.json` **逐字节未变**；③ 检查**输入所在目录**里没有散落文件；④ **覆盖保护**：把 `<out-dir>/defect-cases.json` 预先放一个占位文件，再跑一次 → 必须**报错退出**（不得覆盖）；⑤ 检查除 `<out-dir>` 与轮次目录外，**项目里没有**别的位置出现 `defect-cases.json`
- **预期结果**: ①~⑤全满足；④若被覆盖（占位内容被改写）或未报错退出 → 判红
- **判据形式**: 查绝对事实（文件系统实况）；探针：让实现直接覆盖已存在的产物 → 本条判红
- **类型**: 写入权

---

## G 组：轮次与组合门（AC-027 ~ AC-029）

### AC-027: R3 轮次契约必须成立，且工具不得改写 `cycle.json`
- **前置条件**: §0.3 的轮次目录（`round: "R3"`、`round_type: "defect-verify"`、`trigger: {type:"defect", ref:"BUG-001"}`）+ 两份**变体**轮次目录：① `round` 改成 `R2`；② `trigger.ref` 改成 `BUG-999`（不在输入缺陷 id 集合里）
- **测试步骤**: ① 主跑一次，检查 `cycle.json` 的 sha256 **前后一致**；② 对变体①：跑一次 → 必须报错退出（退出码 1）且 stderr 点名；③ 对变体②：跑一次 → 必须报错退出（退出码 1）且 stderr 点名
- **预期结果**: ①`cycle.json` **逐字节未变**；②③退出码均为 1、stderr 点名坏点、**不得**留下 `defect-cases.json`
- **判据形式**: 查绝对事实（真实退出码 + 文件指纹）；探针：让实现读都不读 `cycle.json` → 变体②不会红 → 本条判红
- **类型**: 功能

### AC-028: 组合门必须真的跑过 `defect-verify`
- **前置条件**: 被验包目录 + 组合门（`bin/test-agent-skills.mjs verify` / `bin/verify-suite.mjs`）
- **测试步骤**: 跑组合门，检查：① 临时根**装齐全部 skill**（含 `defect-verify`）；② 依赖图校验通过；③ 跨 skill 组合场景**实跑**且**至少有一条场景真的经过 `defect-verify`** —— 判据从**临时根的产物**反推：必须存在**非空** `defect-cases.json`，且其 `defects[]` 与 `cases[]` 结构完整、处置结论自洽（每条缺陷有且只有一个 `disposition`；`derived` 的缺陷有对应用例；`reused` 的缺陷有 `reused_case_refs`）；输出文本里含 `defect-verify` / `make-defect-cases` 只作**辅助**证据，**不得单独**作为通过依据；④ 版本错配时**报版本问题**（不是下游业务错）
- **预期结果**: 四项全满足；漏装 `defect-verify` → 判红；组合场景没真跑（只是查文件存在）→ 判红；**组合场景里没有任何一条经过 `defect-verify`**（只装不跑）→ 判红
- **判据形式**: 查绝对事实（组合门的真实退出码与临时根的产物实况）；探针：让组合门漏装 `defect-verify` → 本条判红；探针：让组合门装了但**不跑任何经过它的场景** → 本条判红
- **类型**: 功能
- **说明**: ③ 的"增量"在"**真的跑过**" —— 「装齐 6 个」只是**装了**，不等于**用上了**

### AC-029: 交付侧记账必须与实际一致
- **前置条件**: 被验包目录 + `feature-meta/defect-verify/` 追溯件
- **测试步骤**: ① `feature-meta/defect-verify/` 下 `status.md` / `traceability.md` / `verification-report.md` / `manifest.json` 四件齐全且非空；② `traceability.md` 的**追溯矩阵行数**与本文件判据条数（**29**）相等，且编号集合恰为 AC-001~AC-029；③ 三份 md 记载的判据条数与决策号范围必须**取值唯一** —— 同一 md 里出现的判据条数**取值集合** == {实际条数}、决策号范围**取值集合** == {`decisions.md` 的实际 D 集合}；同一取值被重复引用**不算**多处记载，出现**第二个不同取值**才判红并点名；④ 决策号范围 == `decisions.md` 的实际 D 集合（**动态取**，不写死）；⑤ `feature-meta/defect-verify/manifest.json` 的 `req` 为 `REQ-007`；⑥ 包内**既有**追溯件（`feature-meta/` 根四件套、`feature-meta/test-report/`、`feature-meta/regression-plan/`）必须**逐字节未变**
- **预期结果**: 六项全满足；任一不符 → 判红并点名
- **判据形式**: 查绝对事实（追溯件的实际内容 vs 契约的实际内容）
- **记载口径**: 判据条数在 md 里的**写法**必须能被抽取 —— 接受两种写法：
  「**29 条判据**」或「**判据条数：29**」（可带 `**` 等 markdown 强调符号）。
  两种写法抽出来的数字**取值集合**都必须恰好是 {29}（出现第二个不同取值即判红）。
  决策号范围的写法同理：接受 `D72~D96` 或逐个列出 `D72`…`D96`；
  ⚠️ md 里**不得**出现本 REQ 之外的决策号（如别处的 `D65`），否则取值集合会多出它。
- **类型**: 追溯

---

## 判据类型分布

| 组 | 条数 | 范围 | 类型分布 |
|---|---|---|---|
| A 交付物形状 | 4 | AC-001 ~ AC-004 | 功能×2 / 可用性×1 / 兼容性×1 |
| B 输入解析与缺陷单校验 | 4 | AC-005 ~ AC-008 | 功能×4 |
| C 派生规则 | 6 | AC-009 ~ AC-014 | 功能×4 / 诚实性×1 / 一致性×1 |
| D 复现用例形状与可执行 | 5 | AC-015 ~ AC-019 | 功能×5 |
| E 诚实性 | 4 | AC-020 ~ AC-023 | 诚实性×4 |
| F 幂等与只读 | 3 | AC-024 ~ AC-026 | 可复现性×1 / 写入权×2 |
| G 轮次与组合门 | 3 | AC-027 ~ AC-029 | 功能×2 / 追溯×1 |
| **合计** | **29** | AC-001 ~ AC-029 | **功能 17 / 诚实性 5 / 写入权 2 / 一致性 1 / 可用性 1 / 兼容性 1 / 可复现性 1 / 追溯 1** |

> 条数守恒核对：4 + 4 + 6 + 5 + 4 + 3 + 3 = **29**；类型分布合计 17+5+2+1+1+1+1+1 = **29**。

---

## 验收纪律（对本 REQ 的验收方与实现者同样适用）

1. **一次只跑一个门** —— 并发跑门会产生无因果关系的失败键，污染判定。
2. **变异必须结构合法** —— 崩溃/语法错造成的判红是**假检出**，不计入检出率。
3. **变异注入后必须自证生效**（注入前后 sha256 比对），锚点必须逐字唯一命中 1 次。
4. **判定"是否被检出"只看目标判据是否出现在新增失败键集合里**
   （新增失败键 = 变异运行的失败键 **减去** 基线失败键），**不能只看"比基线多"**，
   **更不能用对称差**（对称差把"基线红、变异后绿"也算成变化）。
5. **基线失败键只取 `^FAIL` 行** —— `PASS` / `UNDEC` 行里也有 AC 编号，混进来会让基线键集合
   变成**全集**，此后任何变异的"新增失败键"都恒为空或恒等于全集，**整套检测沦为橡皮章**。
6. **不可判定标「不可判定」**，不得判 passed。
7. **任何"脚本全绿"的结论必须钉 sha256**（验收脚本自身 sha + 被验实现指纹）。
