# 测试设计方法

方法的作用是让用例生成不靠直觉：每种方法对应一类系统性遗漏。

**这份文档只负责讲清"方法是什么"。判断"某条需求到底用没用方法、用得对不对"一律走脚本**
（`scripts/check-methods.mjs`）——自然语言只是软约束，脚本的退出码才是硬门槛。

> **唯一来源**：`references/methods.json`。
> 本文档是它的**人读说明**，两者的方法 id / 名称 / 适用信号必须一致；
> 不一致时以 JSON 为准，并由 `node scripts/check-methods.mjs --methods references/methods.json --doc references/design-methods.md --check-doc` 报错。
> 维度侧的同类数据在 `references/dimensions.json`。

---

## 1. 怎么用这份方法库

### 1.1 三步走

1. **拆条目**：把需求拆成原子条目 `R-1, R-2, ...`（见 `SKILL.md` 第 2 步）。
2. **选方法**：对照下面的**适用信号**挑方法，把选中的方法编号写进 `coverage_matrix[].methods_applied[]`。
3. **核验**：跑 `scripts/check-methods.mjs`，按脚本给的结论改或说明。

**第 3 步不能省。** `methods_applied[]` 只是一个字符串列表，写上 `"M0.2"` 不等于真的做了边界值分析——
本套件的做法是让脚本到**用例集本身**里找该方法的必需产出，找不到就报错。

### 1.2 三类结论各自的后果

| 结论 | 含义 | 后果 |
|---|---|---|
| `ERROR` | 产出确实缺失（可机械判定的事实） | **必须修**，退出码 1 |
| `WARN` | 适用性存疑（主观判断） | 退出码 0，但**必须在报告里说明**，不得静默忽略 |
| 无法判定 | 证据不足（如 `steps[].expected` 是人读字符串） | 单独一类，**既不算通过也不算失败**，必须写进报告 |

判不了 ≠ 通过。**没有证据的"通过"比失败更危险**——所以脚本在证据不足时报"无法判定"，不报"满足"。

### 1.3 判定依据：方法的必需产出

每种方法在方法库里声明 `required_outputs`（可机械判定的谓词）。脚本对每条**可测试需求条目**
逐个核验这些谓词，谓词不满足即 `ERROR`。

支持的谓词种类（就这几种，不做通用表达式——通用表达式等于让模型写代码）：

| `kind` | 含义 |
|---|---|
| `min_cases_by_dimension` | 该需求条目下，指定维度的用例数 ≥ `min` |
| `distinct_expected` | 上述用例的 `steps[].expected`（断言对象的 `expected` 值）至少有 `min` 个不同取值 |
| `has_dimension` | 该需求条目下存在指定维度的用例 |
| `min_assertions_per_case` | 该需求条目下每条用例的断言数 ≥ `min` |
| `min_cases_total` | 该需求条目下用例总数 ≥ `min` |
| `dimension_pair_present` | 该需求条目下同时存在覆盖指定两个维度的用例（两个维度各至少一条） |

`min_cases_by_dimension` 还可以带 `distinct_expected: true`（等价于再加一条 `distinct_expected` 谓词），
`distinct_min` 可指定区分度下限（默认 2）。

---

## 2. 方法一览

| 编号 | 方法 | 一句话 | 典型维度 |
|---|---|---|---|
| `M0.1` | 等价类划分 | 输入域切成等价类，每类取一个代表值 | functional、exception |
| `M0.2` | 边界值分析 | 边界及内外各一格 | boundary |
| `M0.3` | 判定表 | 条件组合与动作成表，最少用例覆盖全部规则 | functional、permission |
| `M0.4` | 状态迁移 | 状态 × 事件，合法与非法迁移都要测 | functional、exception |
| `M0.5` | 正交实验 | 少量组合覆盖各参数的两两组合 | functional、data、compatibility |
| `M0.6` | 场景法 | 主成功流程 + 备选/扩展流程 | functional、exception |

---

## 3. 各方法详解

### M0.1 等价类划分

- **id**: `M0.1`
- **name**: 等价类划分
- **aliases**: 等价类、等价类划分法、EP、Equivalence Partitioning
- **purpose**: 把输入域划分成处理逻辑相同的若干等价类，每个等价类取一个代表值做用例。
- **applies_when**: 输入、取值、参数、字段、格式、必填、长度、范围、数量、类型、枚举、允许、禁止
- **not_applies_when**: 无输入域的纯展示需求、输出完全固定的只读查询
- **required_outputs**:
  - `min_cases_by_dimension`：`functional` 维度用例数 ≥ 1
  - `min_assertions_per_case`：每条用例的断言数 ≥ 1
- **typical_dimensions**: functional、exception
- **anti_patterns**:
  - 只写有效等价类，无效等价类一条不写
  - 一个用例同时塞多个等价类的输入，代表值不可辨认
  - 等价类用例与边界值用例重复（等价类不取临界点）

**步骤**
1. 找出需求里的所有输入条件（长度、格式、范围、必填性、取值集合）。
2. 对每个条件划分有效等价类与无效等价类。
3. 每个等价类至少一条用例；无效类通常各一条（错误码可能因等价类不同而不同）。

**示例**："密码长度 8–20 位" → 有效类 {8–20 位}，无效类 {少于 8 位, 多于 20 位}。

**注意**：无效等价类容易被漏。每个无效类至少一条用例，否则"错误提示不一致"这类缺陷查不出来。

---

### M0.2 边界值分析

- **id**: `M0.2`
- **name**: 边界值分析
- **aliases**: 边界值、边界值法、BVA、Boundary Value Analysis
- **purpose**: 取边界及其邻近值做用例，重点测边界内外各一格。
- **applies_when**: 长度、范围、上限、下限、最多、至少、不超过、不少于、位数、数量、阈值、到期、间隔
- **not_applies_when**: 无明确边界的业务流程
- **required_outputs**:
  - `min_cases_by_dimension`：`boundary` 维度用例数 ≥ 3，且期望取值至少有 2 种（`distinct_expected`）
- **typical_dimensions**: boundary
- **anti_patterns**:
  - 只测边界值本身，没有内外一格
  - 所有边界用例的期望结果完全相同，看不出区分度
  - 把多个不相邻的边界混在一张用例里，出错时定位不到具体边界

**步骤**
1. 找出每个边界（上界、下界、临界点、时间点）。
2. 对每个边界取：边界值、边界内一格、边界外一格。
3. 多个相邻边界时，只测紧邻边界的那一格（最易漏）。

**示例**："长度 8–20" → 7（拒绝）、8（接受）、20（接受）、21（拒绝）。若还有"最多 3 个附件"，则 3 和 4 各一条，不必要求 20 与 21 同时出现。

**注意**：边界常出现在"刚好满足"的位置，因为该处的分支条件写成了 `<` 而非 `<=`。

---

### M0.3 判定表

- **id**: `M0.3`
- **name**: 判定表
- **aliases**: 判定表法、决策表、Decision Table
- **purpose**: 把条件组合与动作列成表，用尽量少的用例覆盖全部规则。
- **applies_when**: 必须同时、如果、否则、当、取决于、任一、所有、组合、规则、条件
- **not_applies_when**: （无）
- **required_outputs**:
  - `min_cases_by_dimension`：`functional` 维度用例数 ≥ 2，且期望取值至少有 2 种（`distinct_expected`）
  - `min_assertions_per_case`：每条用例的断言数 ≥ 2（一次响应上要多条断言）
- **typical_dimensions**: functional、permission
- **anti_patterns**:
  - 只覆盖一条规则，其余规则没有对应用例
  - 把不可能成立的组合硬凑成用例
  - 一条用例只断言一个动作，规则没有整体验证

**步骤**
1. 列出所有条件（输入）与所有动作（输出）。
2. 构造全组合表，标出哪些组合不可能出现（用 × 标注并给出理由）。
3. 合并等价规则：动作相同、条件只在一个变量上不同的组合可合并。
4. 选一组覆盖所有规则（且覆盖必要的边界组合）的用例集。

**示例**："密码必须含字母和数字" → 条件 {含字母, 含数字}，组合 (是,否)/(否,是) 非法，(否,否) 非法，(是,是) 合法。

**注意**：判定表容易在"不可能组合"上花时间。标注不可能组合并写清理由，比硬凑用例更有价值。

---

### M0.4 状态迁移

- **id**: `M0.4`
- **name**: 状态迁移
- **aliases**: 状态迁移法、状态机、State Transition
- **purpose**: 枚举状态与触发事件，验证合法迁移、非法迁移与被忽略的事件。
- **applies_when**: 状态、生命周期、流转、迁移、锁定、解锁、生效、失效、撤销、取消、提交后、关闭、开启
- **not_applies_when**: （无）
- **required_outputs**:
  - `has_dimension`：存在 `exception` 维度的用例（应被拒绝的非法迁移）
  - `min_cases_total`：该需求条目下用例总数 ≥ 2
- **typical_dimensions**: functional、exception
- **anti_patterns**:
  - 只测合法迁移，不测应被拒绝的非法迁移
  - 漏掉初始状态与终态
  - 状态名与需求原文对不上，读者无法回溯

**步骤**
1. 画出状态图：状态、触发事件、迁移条件。
2. 枚举所有状态-事件组合，标出合法迁移、非法迁移、被忽略的事件。
3. 用例 = 合法迁移（正向）+ 非法迁移（异常维度）。
4. 特别关注初始状态、终态、以及状态回退是否允许。

**示例**："连续 5 次输错锁定 15 分钟" → 状态 {正常, 计数 1–4, 锁定, 计时中}；非法迁移"锁定状态下输对密码"应被忽略或报错。

**注意**：多数状态迁移缺陷出现在"应该被拒绝的迁移"上，别只测合法路径。

---

### M0.5 正交实验

- **id**: `M0.5`
- **name**: 正交实验
- **aliases**: 正交、正交表、正交实验法、Orthogonal Array、OA
- **purpose**: 参数多且互相独立时，用少量组合覆盖各参数的两两组合。
- **applies_when**: 参数、组合、矩阵、多种、多个、各、排列
- **not_applies_when**: （无）
- **required_outputs**:
  - `dimension_pair_present`：同时存在 `functional` 与 `data` 两个维度的用例
  - `min_cases_total`：该需求条目下用例总数 ≥ 4
- **typical_dimensions**: functional、data、compatibility
- **anti_patterns**:
  - 直接做全组合，用例数爆炸
  - 用正交表代替业务规则校验（规则型需求仍要判定表）
  - 组合行数不足以覆盖各参数的两两组合

**步骤**
1. 列出参数与每个参数的取值水平。
2. 选择合适的正交表（3 水平 4 因素、4 水平 5 因素等）。
3. 按正交表生成用例组合。
4. 补上业务上不可行或特别危险的组合。

**示例**：登录方式（密码/短信/第三方）× 设备（手机/PC）× 角色（普通/管理员），用 L4 正交表得到 4 条覆盖所有两两组合的用例，而不是 8 条全组合。

**注意**：正交表覆盖的是参数组合，不是业务规则；规则型需求仍然要靠判定表。

---

### M0.6 场景法

- **id**: `M0.6`
- **name**: 场景法
- **aliases**: 场景法、用例法、Scenario、Use Case
- **purpose**: 沿主成功流程加备选/扩展流程组织用例，覆盖端到端行为。
- **applies_when**: 流程、端到端、下单、注册、登录、支付、审批、异步、回调、任务
- **not_applies_when**: （无）
- **required_outputs**:
  - `min_cases_by_dimension`：`functional` 维度用例数 ≥ 1
  - `min_cases_total`：该需求条目下用例总数 ≥ 2
- **typical_dimensions**: functional、exception
- **anti_patterns**:
  - 只写主成功流程，备选与扩展流程一个没有
  - 备选流程没有对应到异常维度用例
  - 步骤顺序颠倒、中途换环境这类组合完全没覆盖

**步骤**
1. 画出主成功场景（basic flow）。
2. 列出所有备选场景与扩展场景（分支、异常、超时、重试）。
3. 把备选场景转成异常维度用例。
4. 用状态迁移保证场景之间的时间顺序合理。

**注意**：场景法容易漏掉"步骤顺序颠倒"和"中途换环境"这类组合，可在场景完成后用边界值或判定表补一轮。

---

## 4. 跳过必须留痕

`coverage_matrix[].skipped[]` 里跳过任何方法或维度，**必须写明 `reason`**：

```jsonc
{ "requirement": "R-1",
  "methods_applied": ["M0.1"],
  "skipped": [
    { "method": "M0.4", "reason": "该条目为纯计算无状态流转" },
    { "dimension": "concurrency", "reason": "该条目无共享资源，无并发语义" }
  ],
  "dimensions": ["functional"] }
```

- `method` 形式：跳过某个**方法**。
- `dimension` 形式：跳过某个**覆盖维度**。
- 两种形式都必须带非空 `reason`；缺 `reason` 是 `ERROR`（跳过不留痕是用例变少却无人察觉的根因）。
- 跳过**不等于**免检：被跳过的方法不再核验产出，被跳过的维度不再报"缺用例"，但跳过声明本身必须站得住。

## 5. 覆盖维度

8 个维度（`functional` / `boundary` / `exception` / `permission` / `data` / `concurrency` / `performance` / `compatibility`）
的适用信号与跳过理由要求在 `references/dimensions.json`，人读清单见 `references/coverage-dimensions.md`。
维度的适用性同样由脚本核验：有强适用信号却一条用例都没有 → `WARN`（`DIMENSION_MISSING`）。

## 6. 编号说明

- 本库用 `M0.1`–`M0.6` 标识上表 6 种方法。`coverage_matrix[].methods_applied[]` 与 `cases[].method[]`
  都引用这里的编号。
- 方法库里没有登记的编号（例如其它设计稿里出现过的 `M4.5`）**无法核验**——脚本会把它列为"无法判定"，
  而不是默认通过。

## 7. 常见反模式

- **只测顺利路径**：主流程之外什么都不写。至少用边界值法 + 状态迁移各扫一遍。
- **用例标题写"验证 XXX 功能"**：标题应写清验证了什么具体行为，报告里才读得懂差异。
- **预期写"符合预期"**：不可判定，执行时无法判断通过与否。
- **一条用例覆盖十个需求条目**：`requirement_refs` 塞满会让追溯矩阵失真，每条用例聚焦 1–2 个条目。
- **为了凑覆盖率给不可测项编用例**：把 `testable` 置 false 并在报告里说明，比造假更有价值。
