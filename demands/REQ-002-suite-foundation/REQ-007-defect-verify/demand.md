# REQ-007 —— 缺陷复现能力域：`defect-verify` skill（R3 缺陷复现用例生成）

- **需求编号**: REQ-007
- **原编号**: `REQ-002.7`（架构文档 §8 的编号映射：REQ-002.7 = `defect-verify` skill，依赖 002.5b）
- **优先级**: P1
- **状态**: 契约已定稿（验收判据 29 条 / AC-001~AC-029；决策 D72~D96）
- **上游依据**: `architecture-design.md` §1.1（三轮模型与 R3 补环）/ §1.2（三轮产物差异表）/ §4.4（缺陷记录形状）/ §6（skill 清单）/ §8（拆分表）

> 本文件是**契约**，不是说明材料。实现者按这里的规则交付，验收脚本按这里的规则判定。
> 判据见 `acceptance.md`（AC-001~AC-029）；决策记录见 `decisions.md`（D72 起）。

---

## 0. 为什么是现在做这件事

前五个 skill 已经把 R1/R2 的链路拉通：**能设计用例 → 能选样 → 能执行 → 能出报告**。
R3（缺陷验证）这一环至今是空的 —— 架构文档 §1.1 把它列为**只补 R3** 的第三处补环：

> 每个确认的 bug 必须沉淀成可重跑的用例，否则同类缺陷反复出现。

### 0.1 缺口具体长什么样

R1/R2 执行完会产出失败用例，报告（`test-report`）会把它们列出来。但**从失败到"可重跑的复现用例"这一步没有工具**：

| 环节 | 状态 | 缺口 |
|---|---|---|
| R1 设计用例 | ✅ `test-case-design` | — |
| R2 回归选样 | ✅ `regression-plan` | — |
| 执行 + 留证 | ✅ `test-execute` | — |
| 出报告 | ✅ `test-report` | 报告里列了失败用例，但**没沉淀成可重跑的用例** |
| **R3 缺陷复现** | ❌ **无** | 缺陷单 → 复现用例集，**无人消费** |

### 0.2 本 REQ 的核心价值：把「缺陷」变成「用例」

报告里那 5 条失败用例，跑完就没了 —— 下个迭代没人记得它们测过什么，
同一个 bug 换个界面又复现一次。**缺陷复现用例生成**就是那道转化工序：

```
缺陷单(defects.json)  ──►  处置判定  ──►  复现用例集(defect-cases.json)  ──►  test-execute 直接跑
   BUG-001 …               reused/derived        TC-017 / TC-102 …               复现验证
                            unresolved
```

### 0.3 为什么"复用"和"派生"必须分清（**本 REQ 的核心逻辑**）

架构文档 §1.2 明确：R3 对用例集的影响是**只增不改**。这意味着：

- 缺陷**已经有对应用例**（`case_refs` 指到了，或特征匹配命中了）→ **复用**那条用例，
  **不得**再派生一条新的 —— 否则同一件事测两遍，还制造了两条要维护的用例；
- 缺陷**没有对应用例** → **派生** 1 条新的复现用例；
- 缺陷**信息不足**（说不出怎么复现）→ **判 `unresolved`** 并给出理由 ——
  **"显式说不知道"不是失败**，把不知道悄悄变成"复用"或"派生"才是失败（诚实性红线）。

---

## 1. 目标

1. 交付 **`defect-verify` skill**（第 6 个 skill）：读缺陷单 + 已有用例集 → 产出**缺陷复现用例集** `defect-cases.json`。
2. 每条缺陷**有且只有一个**处置结论：`derived`（派生新用例）/ `reused`（复用已有用例）/ `unresolved`（显式说不知道，并给理由）。
3. 产物**能被 `test-execute` 直接消费**（`suite.json` 的 `cases_file` 指向它即可），复现用例带 `defect-verify` 与缺陷 id 的 tag，便于按缺陷分批跑。
4. 全程**只读**输入、**只写**自己的输出目录、**幂等**（同一输入两次，除 `generated_at` 外逐字相同）。

---

## 2. 功能项 F1~F8

### F1 输入：缺陷单（`defects.json`）

上游只给了**单条**缺陷记录的形状（架构文档 §4.4），**文件级契约由本 REQ 定义**。

```json
{
  "schema_version": 1,
  "defects": [
    {
      "id": "BUG-001",
      "title": "满减券核销后实付金额多 0.01 元",
      "severity": "high",
      "description": "（可选）现象描述",
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
    }
  ]
}
```

#### F1.1 输入合法性的**两层划分**（D72 —— 本 REQ 最重要的一处裁定）

「报错退出」与「判 `unresolved`」是两件事，**必须分层**，否则契约自相矛盾：

| 层 | 含义 | 判定 | 违反的后果 |
|---|---|---|---|
| **结构层** | 字段**缺了/类型错了/枚举越界了** —— 这份输入**根本不是**一份合法的缺陷单 | **报错退出**（退出码 1），stderr **点名坏点**，**不得产出任何产物** | 判红（B 组） |
| **内容层** | 字段**在**，但**内容不足以派生**（说不出怎么复现） | **不报错**，走 F2 判定 → 处置 `unresolved` + 非空 `reason` | 判 `unresolved`（C 组） |

> ⚠️ **为什么不把内容层也做成报错**：`unresolved` 的存在意义就是"显式说不知道"。
> 一份缺了复现步骤的缺陷单是**真实存在的业务输入**（需求方还没查清），把它当"非法文件"拒收，
> 等于让工具对真实输入闭口不谈 —— 那就把「显式说不知道」退化成了「假装输入坏了」。

#### F1.2 结构层必填与类型约束（违反 → 报错退出，退出码 1）

| 位置 | 约束 |
|---|---|
| 根 | 必须是对象（不是数组 / 不是标量） |
| `defects` | 必须是数组 |
| `defects[i]` | 必须是对象 |
| `defects[i].id` | **必填**，非空字符串，匹配 `^BUG-\d{3,}$`，**文件内唯一** |
| `defects[i].title` | **必填**，非空字符串 |
| `defects[i].severity` | **必填**，枚举 `high` / `medium` / `low` |
| `defects[i].reproduction` | **若存在**必须是对象（`null` / 字符串 / 数组都非法） |
| `defects[i].status` | **若存在**必须是枚举 `open` / `fixed` / `wont_fix` / `not_reproducible` |
| `defects[i].reproducible` | **若存在**必须是 boolean |
| `defects[i].case_refs` | **若存在**必须是字符串数组（可为空数组） |
| `defects[i].cycle_id` / `run_id` / `evidence_path` / `description` | **若存在**必须是字符串 |
| `defects[i].root_cause` | **若存在**必须是字符串或 `null` |

#### F1.3 内容层（不报错；由 F2 判定）

以下任一成立 ⇒ 该缺陷**信息不足以派生** ⇒ 处置 `unresolved` + 非空 `reason`：

- `reproduction` **缺失**；
- `reproduction.command` 缺失或为空白串；
- `reproduction.steps` 缺失、不是数组、或为空数组；
- `reproduction.expected_failure` 缺失或为空白串。

> ⚠️ `reproduction` **整体缺失**属于内容层（不是结构层）：一份还没填复现步骤的缺陷单是真实输入。

#### F1.4 错误退出的纪律

- 退出码：**1**（输入非法）/ **2**（用法错误：缺参数、参数不认）
- stderr **必须点名是什么坏了**（例：`defects[1].id 格式非法: BUG-XYZ` / `defects[0].severity 越界: critical`）
- **不得产出半份产物**：`defect-cases.json` **只要存在**就算留下了半份产物（**0 字节也算**，按**存在性**判定，不按「非空」判定）

---

### F2 派生规则（本 REQ 的核心逻辑）

对**每一条**缺陷单，按下列顺序判定，产出且**只产出一个**处置结论。

#### F2.1 判定顺序（D75）

```
① case_refs 非空？
   ├─ 是 → 查用例集：全部命中 ⇒ reused
   │        任一未命中 ⇒ unresolved（理由点名那个 id）
   └─ 否 → ② 信息充分吗？（F1.3）
            ├─ 否 ⇒ unresolved（理由说明缺什么）
            └─ 是 → ③ 特征匹配
                     ├─ 命中 ⇒ reused
                     └─ 未命中 ⇒ derived（派生 1 条新用例）
```

> ⚠️ **顺序的含义**：`reused` 不需要 `reproduction`，所以只要 `case_refs` 命中就直接复用，
> 即使缺陷单的复现信息不全；**信息充分性只是"派生分支"的前置**。

#### F2.2 `case_refs` 分支

- `case_refs` **非空** → 逐个在**传入的用例集**（`cases.json`）里找；
- **全部找到** → 处置 `reused`，`reused_case_refs` 记下每条用例的 **suite + case_id**；
- **任一找不到** → 处置 `unresolved`，`reason` **点名那个找不到的 id**；
  **不得部分复用**（D73：一条缺陷要么复用成功，要么说不知道 —— 半条复用等于假装复用了）。

#### F2.3 特征匹配分支（`case_refs` 为空时）

- **特征（指纹）** = `归一化(command)` + `\0` + `归一化(steps 序列)`
- **归一化口径（D74，写死，实现与门用同一套）**：
  1. Unicode **NFKC** 规范化；
  2. 去首尾空白；
  3. 连续空白（`\s+`）压缩成**单个空格**；
  4. 剥掉**成对包裹**的引号（`"…"` / `'…'` / `“…”` / `‘…’`）；
  5. 去**末尾**标点（`。．.!！?？;；,，`）；
  6. 再去首尾空白。
  - `归一化(steps 序列)` = 各步归一化后用 `\x01` 连接。
- **匹配规则**：某条已有用例与缺陷单的 **steps 指纹逐项相等**，**且**
  （两侧 **command 指纹相等** **或** 两侧 command **其一为空**）⇒ **命中**。
  - 用例侧的 command 取该用例的 `reproduction.command`（**若该用例带这个额外字段**）；不带则为空（D96）。
- **命中** → 处置 `reused`（记 `source_suite` / `source_case_id`），**不得再新建用例**；
- **未命中** → 处置 `derived`，**派生 1 条**复现用例。

#### F2.4 处置结论集合

`{derived, reused, unresolved}` —— **`unresolved` 不是失败**，是"显式说不知道"（诚实性红线，见 F6）。

---

### F3 复现用例的形状

产物里的复现用例 = **REQ-002A 的 v2 用例字段** + 4 个额外字段。

#### F3.1 `id`

- 格式硬约束：`^TC-\d{3}$`（三位数字，`TC-1001` **不合法**）
- `reused` 的用例**沿用原 id**（如 `TC-017`）
- `derived` 的新用例走**扩展编号段 `TC-101` ~ `TC-999`**（`TC-001`~`TC-100` 留给原套件，
  避免与被引用用例撞号）；扩展段共 **899** 个号位
- 扩展段**已被输入用例集占用**（如 `TC-101` 已存在）→ **顺延**到下一个空闲号（D82）
- 扩展段**用尽** → 该缺陷改判 `unresolved` 并给理由（D81）

#### F3.2 字段集

| 字段 | `derived` 取值 | `reused` 取值 |
|---|---|---|
| `id` | 扩展段新号 | **原 id**（逐字沿用） |
| `title` | `复现 <BUG-id>：<缺陷 title>` | 原用例的 `title`（沿用） |
| `requirement_refs` | 该缺陷对应的 `R-<n>` | 该缺陷对应的 `R-<n>`（**改写**，见 D76） |
| `dimension` | `functional` | 原用例的 `dimension` |
| `priority` | `P0` | 原用例的 `priority` |
| `method` | `["M1.1"]`（**缺省约定**，见下） | 原用例的 `method` |
| `status` | `active` | `active`（D77） |
| `preconditions` | `[]` | 原用例的 `preconditions` |
| `steps` | 由 `reproduction.steps` 派生（见 F3.3） | **原用例的 `steps`（逐字沿用）** |
| `data` | `{"command": <reproduction.command>, "expected_failure": <reproduction.expected_failure>}` | 原用例的 `data` |
| `tags` | `["defect-verify", "<BUG-id>"]` | 原用例的 `tags` ∪ `["defect-verify", "<BUG-id>"]`（去重，原 tags 在前） |
| `defect_refs` | `["<BUG-id>"]` | `["<BUG-id>"]` |
| `origin` | `"derived"` | `"reused"` |
| `source_case_id` | `null` | 原用例的 `id` |
| `source_suite` | `null` | 传入的 suite 标识 |

- `defect_refs` / `origin` / `source_case_id` / `source_suite` 是**额外字段** —— 上游
  `validate-cases.mjs` **不拦** cases[] 的额外字段，`test-execute` 的 `loadCases()` 也**容忍**（已核实）。
- ⚠️ **`method: ["M1.1"]` 是缺省约定，不是宣称做过完整方法学**：
  复现用例的目标是"把已知缺陷重跑一遍"，不是重新做一遍测试设计。
  这个约定必须写进 `references/derivation-rules.md`，并注明它是缺省值。

#### F3.3 `steps` 的派生（`derived`）

- 每一步的 `action` = `reproduction.steps[i]` 的**原文**（逐字，不改写）
- 每一步的 `expected` = `reproduction.expected_failure` 的**文本**（人读形态；不要求机械可判定的断言对象）
- `steps` 至少 1 条（`reproduction.steps` 非空是派生的前提）

> ⚠️ 这里的 `expected` 记的是**缺陷的失败现象**（= `expected_failure` 原文）——
> 复现用例的语义是「确认这个失败仍然发生」，不是「确认缺陷不发生」。

#### F3.4 `requirement_refs` 不得悬空（D76）

产物文档的 `requirements[]` **只含缺陷条目**（每个缺陷一条）：

```json
"requirements": [
  { "id": "R-1", "title": "缺陷 BUG-001 的复现要求", "source_ref": "defects.json#/defects/0", "testable": true }
]
```

- `id` 用 `R-1`、`R-2`…**按缺陷在输入中的顺序**
- `source_ref` 指向缺陷单里的位置：`defects.json#/defects/<下标>`
- **复现用例的 `requirement_refs` 一律指向"它所复现的那个缺陷"的 `R-<n>`**（`reused` 与 `derived` 同）——
  本轮文档的主题是**缺陷**，复用的原用例自己的需求条目归属原套件，不搬进本轮。
- ⇒ `requirement_refs` **非空且不悬空**（硬约束 8）

---

### F4 产物形状与落位

#### F4.1 `defect-cases.json` = `cases.json` v2 的**超集**

顶层字段集**封闭**（7 个）：

| 字段 | 类型 | 约束 |
|---|---|---|
| `schema_version` | number | `2` |
| `meta` | object | `source`（非空字符串）/ `generated_at`（ISO-8601）/ `case_count`（number）/`defect_count`（number）/`cycle_id`（string）/`suite`（string）；**`meta` 的字段集开放**（可另带说明字段） |
| `requirements` | object[] | 每个缺陷一条（见 F3.4） |
| `open_questions` | object[] | 数组（可为空） |
| `coverage_matrix` | object[] | 每个**被覆盖**的需求条目一条（`requirement` / `methods_applied` 含 `M1.1` / `dimensions` 含 `functional` / `skipped`）；**未被覆盖的（`unresolved` 缺陷）不列** —— 让它出现在"未覆盖需求条目"清单里，那才是诚实的 |
| `defects` | object[] | **本 REQ 新增段**，见 F4.2 |
| `cases` | object[] | 复现用例（见 F3） |

#### F4.2 `defects[]` 每条（字段集**封闭**，严格照 F4 规格）

| 字段 | 必填 | 说明 |
|---|---|---|
| `id` | 是 | 缺陷 id（逐字取自输入） |
| `title` | 是 | 逐字取自输入 |
| `severity` | 是 | 逐字取自输入 |
| `status` | 是 | 逐字取自输入；输入缺 `status` 时取 `"open"` |
| `disposition` | 是 | `derived` / `reused` / `unresolved`（有且只有一个） |
| `reason` | **条件** | `disposition == "unresolved"` 时**必填且非空** |
| `reused_case_refs` | **条件** | `disposition == "reused"` 时**必填**，数组，每项 `{suite, case_id}` |
| `derived_case_id` | **条件** | `disposition == "derived"` 时**必填**（非空字符串） |
| `source_cycle_id` | 条件 | 输入带 `cycle_id` 时逐字搬运 |

- `disposition == "derived"` ⇒ **有** `derived_case_id`、**无** `reused_case_refs`、**无** `reason`
- `disposition == "reused"` ⇒ **有** `reused_case_refs`、**无** `derived_case_id`、**无** `reason`
- `disposition == "unresolved"` ⇒ **有** `reason`、**无** `reused_case_refs`、**无** `derived_case_id`

#### F4.3 落位与可执行性

- **落位**：`test-assets/cycles/<R3 轮次目录>/defect-cases.json`（与 `cycle.json` 同级）。
  理由：它是**本轮产物**，不是某个套件的用例集；目录契约 §1「没写的自由项校验器一律不拦」⇒ **不违约**。
- **可执行性**：`suite.json` 的 `cases_file` **相对 suite.json 所在目录**解析，
  指向 `defect-cases.json` ⇒ `test-execute` 可**直接消费**（硬约束 5）。
- **R3 轮次的 `suite.json` 由项目侧提供，本 skill 不生成**（D89）：生成它需要往轮次目录之外写，
  与 F7「只写自己的输出目录」冲突。契约把它**写死成固定形状**，验收按形状核对：

  ```json
  {
    "suite": "<套件标识>",
    "requirement": "<需求标识>",
    "scope": "functional",
    "environment": "<环境名>",
    "cases_file": "<相对路径，指向 defect-cases.json>",
    "executor": "api",
    "base_url_from": "<环境名>",
    "tags": { "include": ["defect-verify"] },
    "report": { "format": ["json"], "output_dir": ".test-artifacts/<套件标识>" }
  }
  ```

  - 顶层字段集**封闭**（**9 个**，即上例的 9 个字段）—— 不得出现表外字段（硬约束 5）
  - `cases_file` 相对 **suite.json 所在目录**解析，必须能落到 `defect-cases.json`
  - `tags.include` 可写 `["defect-verify"]`（跑全部）或 `["<BUG-id>"]`（按缺陷分批跑）——
    `selectCases` 按**任意字符串** tag 做包含匹配（硬约束 4）

#### F4.4 工具的命令行契约

```bash
node skills/defect-verify/scripts/make-defect-cases.mjs \
  --defects <defects.json> \
  --cases <cases.json> \
  --suite <suite-id> \
  --cycle-dir <R3 轮次目录> \
  [--out-dir <目录>]
```

| 参数 | 必填 | 说明 |
|---|---|---|
| `--defects` | 是 | 缺陷单文件 |
| `--cases` | 是 | 已有用例集（`cases.json`，schema v2） |
| `--suite` | 是 | 已有用例集所属的套件标识（写进 `reused_case_refs[].suite` / `source_suite`） |
| `--cycle-dir` | 是 | R3 轮次目录（读 `cycle.json`；**默认输出目录**） |
| `--out-dir` | 否 | 产物输出目录，**默认 = `--cycle-dir`** |

- 产物：**只写** `<out-dir>/defect-cases.json` 一个文件
- 退出码：`0` 成功 / `1` 输入非法或违反写入纪律 / `2` 用法错误
- 配套校验器：`node skills/defect-verify/scripts/check-defect-cases.mjs <defect-cases.json>`（自洽校验，退出码 0/1/2）

---

### F5 轮次契约

- R3 轮次 `cycle.json`：`round == "R3"`、`round_type == "defect-verify"`、
  `trigger == {"type": "defect", "ref": "<BUG-id>"}`（`trigger` 是允许字段，硬约束 6）
- **轮次目录名 == `cycle_id`**（目录契约 §1）
- `trigger.ref` 必须 ∈ 输入缺陷 id 集合（D79）—— 否则轮次与缺陷单对不上，属输入非法 → 报错退出
- 本 REQ **不负责推进轮次状态**（那是 `cycle-state.mjs` 的活，已支持 R3 + defect-verify，硬约束 8）；
  但工具**只读** `cycle.json`，**不得改写**它（逐字节未变）

---

### F6 诚实性红线

1. 输出里缺陷 id 的**集合必须等于**输入的缺陷 id 集合（不多、不少、不重、不漏）
2. 每条缺陷**必须有且只有一个**处置结论
3. `unresolved` **必须**给非空 `reason`；**不得**把"信息不足"悄悄变成"复用"或"派生"
4. **不得凭空造缺陷**：输出的缺陷条目里不得出现输入没有的 id（用例的 `defect_refs` 同理）
5. **不得重复派生**：已有对应用例的缺陷**不得**再产一条新用例（否则"同类缺陷反复出现"的病根还在）；
   一个缺陷**最多**一条 `derived` 用例
6. **不得修改输入**：缺陷单、已有用例集**逐字节未变**
7. **幂等**：同一输入两次运行，产物除 `meta.generated_at` 外**逐字相同**（D83）

---

### F7 写入权

- **只写自己的输出目录**（`--out-dir` 指定，默认为 `--cycle-dir`）；**不得**写进输入所在目录
- 输出目录的判定（D78，**按产物文件与目录内容**，不是"目录非空就报错"）：

  | 情形 | 判定 |
  |---|---|
  | `<out-dir>/defect-cases.json` **已存在** | **报错退出**（不得覆盖别人的东西） |
  | `<out-dir>` 不存在 | **创建** |
  | `<out-dir>` 存在，且含**除 `cycle.json` 之外**的任何文件 | **报错退出**（防止把产物写进不相干的目录） |
  | `<out-dir>` 存在且只含 `cycle.json`（`--out-dir` 省略、默认 = `--cycle-dir` 时） | **允许**（轮次目录本来就有 `cycle.json`） |

- **输入目录逐字节未变**：缺陷单与用例集所在目录，跑完前后 sha256 一致，且**不得**留下散落文件

---

### F8 交付物与组合门

- 新 skill `skills/defect-verify/`（**第 6 个 skill**），形态照 `skills/regression-plan/`：

  ```
  skills/defect-verify/
  ├── SKILL.md                    # frontmatter: name: defect-verify + 非空 description
  ├── skill-meta.json             # {name:"defect-verify", version:"0.1.0", requires:{...}}
  ├── references/
  │   ├── defect-input-schema.md  # 缺陷单格式（F1）
  │   └── derivation-rules.md     # 派生规则 + 编号约定 + 归一化口径（F2/F3）
  └── scripts/
      ├── make-defect-cases.mjs   # 主入口
      ├── check-defect-cases.mjs  # 校验器
      └── lib/                    # ≥3 个模块
  ```

- `skill-meta.json`：`name: "defect-verify"`、`version: "0.1.0"`、
  `requires` **含** `test-case-design`（消费用例集）与 `test-execute`（执行复现用例）
- `bin/verify-suite.mjs`：**新增组合场景 `scenarioDefectVerify`**，照 `scenarioReport` 的形 ——
  **真的跑** `make-defect-cases.mjs` 并**断言产出**（不是只查目录存在）
- `README.md`：安装树 + skill 表格**两处**都要补 `defect-verify`
- `feature-meta/defect-verify/`：追溯件四件套（`status.md` / `traceability.md` / `verification-report.md` / `manifest.json`）
- **零第三方依赖**（只用 node 内置）、**不联网**

---

## 3. 交付物清单（实现方）

| 路径 | 说明 |
|---|---|
| `skills/defect-verify/SKILL.md` | 入口说明 |
| `skills/defect-verify/skill-meta.json` | 版本与依赖声明 |
| `skills/defect-verify/references/defect-input-schema.md` | 缺陷单格式（F1） |
| `skills/defect-verify/references/derivation-rules.md` | 派生规则与编号约定（F2/F3） |
| `skills/defect-verify/scripts/make-defect-cases.mjs` | 主入口 |
| `skills/defect-verify/scripts/check-defect-cases.mjs` | 校验器 |
| `skills/defect-verify/scripts/lib/*.mjs` | ≥3 个模块 |
| `bin/verify-suite.mjs` | 新增 `scenarioDefectVerify` |
| `README.md` | 安装树 + skill 表格两处 |
| `feature-meta/defect-verify/{status,traceability,verification-report}.md` + `manifest.json` | 追溯件四件套 |

---

## 4. 本 REQ 明确**不做**的事

| 不做 | 理由 |
|---|---|
| 不推进轮次状态机 | `cycle-state.mjs` 已支持 `--round R3 --round-type defect-verify`（硬约束 8） |
| 不改写 `cycle.json` | 单一写入者原则（架构文档 §3.2） |
| 不生成 R3 轮次的 `suite.json` | 生成它要往轮次目录外写，与 F7 冲突（D89）；契约写死形状即可 |
| 不产出缺陷验证报告 | 报告能力是 `test-report`（REQ-010）的职责 |
| 不修改缺陷状态 | 架构文档 §1.2：R3「是否产 bug = 更新已有 bug 状态」，但**改 bug 状态属于缺陷管理系统**，不在本 REQ |
| 不联网、不引第三方依赖 | 与既有 5 个 skill 一致 |

---

## 5. 决策索引

契约歧义的裁定见 `decisions.md`（**D72 ~ D96**，25 条）。其中影响实现行为的关键几条：

| 决策号 | 一句话 |
|---|---|
| D72 | 输入合法性**两层划分**：结构层非法 → 报错退出；内容层不足 → `unresolved` |
| D73 | `case_refs` **部分命中 ⇒ 整条改判 `unresolved`**（不得部分复用） |
| D74 | 特征匹配的**归一化口径**写死（NFKC / 压缩空白 / 剥引号 / 去尾标点） |
| D75 | 判定顺序：`case_refs` 优先；信息充分性只是派生分支的前置 |
| D76 | 输出 `requirements[]` 只含缺陷条目；复现用例的 `requirement_refs` 一律指向该缺陷的 `R-<n>` |
| D77 | 复现用例的 `status` 一律 `active`；原用例为 `deprecated` ⇒ 改判 `unresolved` |
| D78 | F7「输出目录非空」的判定口径（按产物文件 + 目录内容） |
| D79 | `cycle.json` 的 `trigger.ref` 必须 ∈ 输入缺陷 id 集合；工具只读不改写 |
| D80 | `defects[]` 条目字段集**严格照 F4 规格**，不额外加字段 |
| D81/D82 | 扩展编号段 `TC-101`~`TC-999`；占用则顺延；用尽 ⇒ `unresolved` |
| D89 | `suite.json` 由项目侧提供，契约写死形状 |
