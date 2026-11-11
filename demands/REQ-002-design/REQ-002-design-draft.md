# 设计：测试方法体系与目录接口契约（REQ-002 草案）

- **日期**: 2026-11-11
- **作者**: BA (local-ba)
- **状态**: 草案，待与用户对齐
- **前序**: REQ-001 已交付 `test-case-design` skill（npm 包 `test-agent-skills@0.1.0`）

---

## 0. 设计出发点：REQ-001 实测暴露的问题

REQ-001 的 eval 对比（同一份优惠券核销需求）得出三组数字：

| | baseline（裸模型）×3 | with-skill |
|---|---|---|
| 用例数 | 62 / 56 / 48（均值 55） | 29 |
| 需求条目 | 18 / 18 / 12 | 12 |
| 步骤数 | 90 / 120 / 109（均值 106） | 47 |
| JSON 内结构化假设 | 10 / 7 / 5 条 | **0 条** |
| 行为点漏覆盖 | — | 漏「用户最多用 1 张券」「实付金额非负」 |

**三个结论：**

1. **skill 让产出变少了。** 不是模型能力不足，是 SKILL.md 第 5 步"逐维度问适用吗"把模型精力导向**论证维度适用性**，而不是**铺开用例**。
2. **核心卖点没落地。** skill 主张"显式暴露需求歧义"，但未决问题只写进人读的 `report.md`，机器可读的 `cases.json` 里一条都没有。裸模型反而把假设放进了 `meta.assumptions`。
3. **方法论层性价比低。** with-skill 比 baseline 多花 1.8× token，却产出更少。`references/design-methods.md` 教的等价类/边界值/判定表，模型本来就会。

**因此 REQ-002 的设计目标不是"加更多方法"，而是：让方法可被稳定调用、让歧义强制结构化、让真实测试有目录契约。**

---

## 1. 设计一：测试方法体系

### 1.1 核心转变：从"方法清单"到"方法目录"

现有 `design-methods.md` 是**线性清单**：6 种方法 + 一张选型速查表。问题是模型看到清单会**挑 2–3 种**（SKILL.md 第 4 步原话），其余跳过——这是用例变少的直接原因。

新设计：**方法库 + 强制调用规则**。

- 方法库按**测试层级**分层，每层标注**是否必选**；
- 规则从"选方法"改为"**先过必选层，再按特征补可选层**"；
- 每条用例记录 `method` 字段——**用哪条方法生成的**成为可审计信息。

### 1.1.1 方法库的交付形态：运行时工作区契约（Q1 澄清后修正）

**修正说明**：初稿把方法库理解成"npm 包里的一个目录"，那是**打包布局**问题，与用户关心的不是一回事。用户要的是：**agent 使用这个 skill 时，工作目录该怎么组织**——这必须由 skill 定义成契约。

因此方法库在 skill 中的形态是：

```
skills/test-case-design/
├── SKILL.md
├── methods/                      # 方法库（skill 自带，agent 运行时拷入工作区）
│   ├── catalog.json              # 机器可读：方法定义 + 特征触发规则 + 分层
│   └── M0.md M1.md M2.md ...     # 各方法详解（按层组织）
├── references/
│   ├── case-schema.md
│   ├── coverage-dimensions.md
│   └── method-catalog.md         # 速查表（给模型看的精简视图）
└── scripts/
    ├── validate-cases.mjs
    └── render-report.mjs
```

**运行时工作区契约**——agent 每次执行本 skill，必须建立并按槽位落盘：

```text
<run-root>/                       # 每次设计任务的工作区（调用方指定，agent 不自行决定位置）
├── RUN.md                       # 本次运行元信息：需求来源、方法库版本与摘要、时间、调用参数
├── methods/
│   └── catalog.json             # 本次生效的方法库快照（从 skill 包拷贝；项目可覆盖裁剪）
├── inputs/
│   └── requirement.md           # 需求原文（只读输入；文件来源则记原路径）
├── outputs/
│   ├── cases.json               # 用例集（schema v2，含 open_questions / coverage_matrix）
│   ├── report.md                # 追溯矩阵 + 覆盖汇总（render-report.mjs 输出 + 人工补充）
│   └── coverage-matrix.json     # 方法 × 条目 覆盖矩阵（机器可读）
└── .state/                      # 中间产物，不进 Git
```

**契约条款（写进 SKILL.md，模型必须遵守）：**

| 条款 | 内容 |
|---|---|
| C1 | agent 不自行决定工作目录位置——由调用方给出 `run-root`；未给出时在当前工作目录下建 `./.qa-run/<需求标识>/` |
| C2 | 产出**只写** `outputs/`；`inputs/` 只读；`methods/catalog.json` 是本次方法库的**快照**（可被项目覆盖，不反向污染 skill 包） |
| C3 | `RUN.md` 必须记录方法库快照的哈希与条目数——事后可复现"当时用的是哪版方法" |
| C4 | `coverage-matrix.json` 是 `cases.json` 的一部分，**必须**一并产出——它与 cases 强耦合，拆开就会失真 |
| C5 | 定稿后由调用方决定是否**晋升**到项目资产目录（见 §2.2）；skill 本身不做晋升，只在 `RUN.md` 里给出建议路径 |

**为什么要有"快照"**：方法库会演进。若 agent 每次直接读 skill 包里的最新版，一次设计任务中途方法库变了（另一 agent 升级了包），产出会不自洽。快照让每次运行自洽，也让 `RUN.md` 里的哈希能定位到"当时那版方法"。

**方法库可被项目覆盖**：项目可以提供自己的 `methods/catalog.json`（增删方法、调整触发规则），覆盖 skill 默认版本。这让方法库从"教模型的教材"变成"**项目可配置的测试策略**"——这才是它在工程里的正确位置。

### 1.2 方法分层

```
Layer 0 — 必选基线（每条需求条目都要过，6 条）
├── M0.1 正常路径（happy path）
├── M0.2 边界值（上下界各一格 + 界值）
├── M0.3 异常/无效输入
├── M0.4 状态/生命周期非法迁移
├── M0.5 幂等（重复提交 / 重放 / 多次触发）
└── M0.6 服务端校验（绕过前端直接构造请求）

Layer 1 — 规则型补强（需求结构命中即必选）
├── M1.1 判定表（多条件组合）
├── M1.2 状态迁移图（对象有生命周期）
├── M1.3 场景法（端到端流程）
└── M1.4 故障注入（依赖外部系统）

Layer 2 — 规模型补强（参数多时）
├── M2.1 正交实验
├── M2.2 组合/成对覆盖
└── M2.3 桩件桩（stub/mock）契约验证

Layer 3 — 白盒补充（需要源码时）
├── M3.1 语句覆盖
├── M3.2 判定/条件覆盖
├── M3.3 MC/DC 判定覆盖
└── M3.4 路径覆盖（圈复杂度定向）

Layer 4 — 专项测试（非功能）
├── M4.1 性能（负载/压力/稳定性/容量）
├── M4.2 安全（认证授权/注入/越权/敏感数据）
├── M4.3 可靠性（容错/降级/恢复/混沌）
├── M4.4 易用性/兼容性/可访问性
└── M4.5 数据质量（精度/舍入/脏数据）
```

**关键设计点：Layer 0 是密度保底。** 每条需求条目至少过 6 条基线方法，不允许因为"感觉不适用"而跳过。

**6 条基线的选取依据**（其中两条来自实测对比）：

| 基线 | 为什么必选 | 实测依据 |
|---|---|---|
| M0.1 正常路径 | 基线，无它无从判断功能是否工作 | — |
| M0.2 边界值 | 最易出 `<` vs `<=` 类缺陷 | baseline 三轮都覆盖 |
| M0.3 异常输入 | 无效等价类最易漏 | baseline 三轮都覆盖 |
| M0.4 非法迁移 | 状态类缺陷集中在"应被拒绝的迁移" | baseline 覆盖，with-skill 漏 |
| **M0.5 幂等** | 重复提交/重放导致的重复扣减是高频高危 | baseline 三轮都主动补了幂等用例 |
| **M0.6 服务端校验** | 只测前端不可点不够，必须构造请求直打服务端 | baseline 明确有"绕过前端"用例；这是资深测试人员的加固动作 |

**M0.5 / M0.6 提为必选的理由**：REQ-001 的 eval 里，baseline 三轮**都自发补了**幂等用例和绕过前端的服务端校验——说明这是资深测试的默认动作，而 with-skill 恰恰在这里欠密。把它固化进 Layer 0 是有实测支撑的，不是凭空加严。

**但这需要"带理由的跳过"机制**（见 §1.3.1）：纯只读查询接口没有幂等语义，M0.5 应当允许跳过——但必须显式声明"只读接口无幂等语义"，而非静默不写。

### 1.3 方法 → 需求特征的映射规则

方法库的价值在于**自动选型**，不是让模型自己想。规则以可判定的形式给出：

| 需求特征（可判定） | 触发方法 | 层级 |
|---|---|---|
| 出现数值范围 / 长度限制 / 数量上限 | M0.2 边界值 | 必选 |
| 出现"必须/至少/最多/不超过" | M0.2 + M0.3 | 必选 |
| 出现 ≥2 个条件决定同一结果 | M1.1 判定表 | 必选 |
| 出现状态词（未/已/中/完成/取消/锁定） | M1.2 状态迁移 | 必选 |
| 出现"流程/步骤/提交/支付/审批" | M1.3 场景法 | 必选 |
| 出现外部依赖（第三方/异步/队列/支付） | M1.4 故障注入 | 必选 |
| 参数 ≥3 且互相独立 | M2.1 正交 | 建议 |
| 能拿到源码/接口契约 | M3.x 白盒 | 可选 |
| 出现时间/金额/数量/性能指标 | M4.1 + M4.5 | 视范围 |
| 出现登录/权限/角色/租户 | M4.2 安全 | 必选 |

**规则执行序（SKILL.md 里写死）：**

```
1. 拆需求条目（原子化）
2. 对每个条目，扫描特征表 → 得出必选方法集合
3. 执行 Layer 0 全部（基线，不看特征）
4. 执行特征命中的 Layer 1/4 方法
5. 整体检查参数规模 → 决定 Layer 2
6. 有源码 → Layer 3
7. 汇总：每条方法 × 每个条目 × 命中与否 → 覆盖矩阵
```

第 7 步是关键的**收敛机制**：产出"方法 × 条目"矩阵，未命中的格子必须显式标注原因（不适用 / 超出范围 / 已由其他用例覆盖）。这样既保证不漏，又不会无脑铺满。

### 1.3.1 机制保障：编号本身不构成约束

**必须承认**：SKILL.md 里的自然语言步骤对模型是**软约束**。REQ-001 实测已经证明——SKILL.md 第 5 步写了"按覆盖维度清单补齐"，模型照样少产一半用例。写成 "M0.1–M0.6" 编号并不会让模型自动执行。

所以编号只解决**可审计**（事后能查），不解决**强制**（事前能拦）。强制必须落在脚本上：

| 机制 | 位置 | 作用 |
|---|---|---|
| 编号 `M0.x` | `cases[].method` | 事后可审计：这条用例哪来的 |
| `coverage_matrix` | 用例集顶层 | 事后可查：哪条需求漏了哪条方法 |
| **校验器拦截** | `validate-cases.mjs` | **事前能拦**：基线未覆盖 → 退出码 1，不许交付 |

校验器的判定逻辑（这是 REQ-002 的硬门禁）：

```
for 每个可测试条目 R:
    M0.1 ~ M0.4 每条方法:
        若 coverage_matrix[R].methods_applied 未包含该方法:
            → 报 ERROR："R-n 未应用基线方法 M0.x"
            → 若该方法确实不适用，要求显式声明：
              coverage_matrix[R].skipped.push({method:"M0.x", reason:"..."})
            → reason 为空或缺失 → 仍判 ERROR
```

**关键在于 `skipped` 必须带非空 reason**——这让"跳过"从一个隐性决定变成一个显式、可被 review 发现的决定。REQ-001 里模型少产用例的根因正是"跳过"完全不留痕迹。

同理 `open_questions[]` 的 `severity: "blocking"` 项，若既没挂用例也没声明 `coverage: "deferred"` 且无 reason，校验器同样拦截。

### 1.4 schema 变更：方法可审计

```json
{
  "id": "TC-001",
  "method": ["M0.1", "M0.2"],
  "requirement_refs": ["R-3"],
  "dimension": "boundary",
  ...
}
```

`method` 字段引用方法库编号，让"这条用例怎么来的"可追溯，也让校验器能检查"某条目是否跑过 Layer 0"。

### 1.5 方法库放哪

**不放进 skill 的 references。** 理由：

- 方法库会持续增长（专项测试方法细分），放 SKILL.md 同级 references 会让 skill 体积膨胀、token 成本上升；
- 方法库是**知识资产**，应该独立版本化、独立复用（比如未来"接口测试执行"skill 也要用方法库）；
- 建议独立成 npm 包的一个子目录，skill 通过 `references/` 引用或直接打包共享：

```
test-agent-skills/
└── skills/
    └── test-case-design/
        ├── SKILL.md
        ├── methods/                      # 方法库（skill 自带）
        │   ├── catalog.json              # 机器可读：方法定义 + 特征触发规则 + 分层
        │   └── M0.md M1.md M2.md M3.md M4.md
        ├── references/
        │   ├── method-catalog.md         # 速查（给模型看的精简视图）
        │   ├── case-schema.md
        │   └── coverage-dimensions.md
        └── scripts/
            ├── validate-cases.mjs
            └── render-report.mjs
```

`catalog.json` 是机器可读的，校验器可以直接读它做覆盖检查——这是"方法可审计"的技术基础。方法库放在 skill 内（而非跨 skill 共享包），因为它同时承担**运行时工作区契约**的角色——agent 每次运行都要把它拷进 `run-root/methods/`（见 §1.1.1）。

---

## 2. 设计二：真实测试的目录接口契约

### 2.1 两层目录的区别

必须分清两层，它们解决不同问题：

| | 运行时工作区（§1.1.1） | 项目资产目录（本节） |
|---|---|---|
| 生命周期 | 一次设计任务 | 长期，跟随项目 |
| 内容 | 本次运行的输入与产出 | 定稿后的测试资产 + 环境配置 |
| 版本控制 | 一般不进 Git | **进 Git** |
| 由谁决定位置 | 调用方 | 项目 |

运行时工作区是**过程**，项目资产目录是**沉淀**。设计任务结束后，调用方决定是否把 `outputs/` 晋升到项目资产目录。

### 2.2 解决什么问题

REQ-001 只管"设计"不管"执行"。真实使用时，用例集需要和**环境、配置、数据、脚本、报告**关联起来。否则：

- 同一个用例集在不同环境跑，配置散落各处；
- 环境切换靠改代码；
- 执行产物（报告、日志、截图）污染仓库；
- 多个 skill（设计→执行→报告）之间没有稳定的交接格式。

### 2.3 项目资产目录契约

沿用 agent-workspace 的**可见名 vs 隐藏名**规则：

- 要进 Git 的用**可见名**；
- 纯本地产物用 `.` 前缀。

```text
<project-root>/
├── <asset-root>/                   # 测试资产根目录（名称待定，见 §5 Q3）
│   ├── README.md                 # 目录契约说明（人读）
│   ├── environments/             # 环境定义
│   │   ├── local.json
│   │   ├── staging.json
│   │   └── _schema.json           # 环境配置 schema
│   ├── suites/                   # 用例集（每个需求一个）
│   │   └── REQ-001-coupon/
│   │       ├── cases.json         # test-case-design 产出
│   │       ├── open-questions.md  # 未决问题（人读 + 可选）
│   │       └── suite.json         # 执行配置
│   ├── contracts/                # 接口契约 / mock 定义
│   └── tools/                    # 执行脚本
│       └── run-suite.mjs
└── .test-artifacts/              # 执行产物（不进 Git，本地）
    ├── REQ-001-coupon/
    │   ├── report.html
    │   ├── results.json
    │   └── logs/
    └── cache/
```

**目录名与产物策略（已定）**：

- 资产根目录 = **`test-assets/`**（用户决策）——与代码自带的 `tests/`（单元测试代码）语义区分清楚，且明确这是"资产"而非可执行测试；
- 执行产物 = **`.test-artifacts/`，不进 Git**，由 `.gitignore` 排除（用户决策）。产物靠 CI 归档或本地留存。

### 2.3 环境配置 schema

配置格式统一为 **JSON**（用户决策）。理由：校验器零依赖只需 `JSON.parse`，不需要手写 YAML 解析器；且用例集本身也是 JSON，两端同构。

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

**关键设计点：凭证只走环境变量引用**，配置文件里不存明文。这让配置文件可以安全进 Git。

**JSON 无注释的补偿**：`_schema.json` 承担"文档"职责（字段说明写在 schema 的 `description` 里），配置文件本身保持纯 JSON。

### 2.4 用例集与执行的接口

`suite.json` 声明"这组用例怎么跑"：

```json
{
  "suite": "REQ-001-coupon",
  "requirement": "REQ-001",
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

### 2.5 目录契约的强制手段

契约不能只靠文档说，要**可校验**。新增脚本：

```
scripts/verify-layout.mjs
```

职责：
1. 检查 `test-assets/` 下必需目录存在；
2. 检查每个 `suite.json` 的字段完整、引用路径存在；
3. 检查 `environments/*.json` 符合 `_schema.json`（`JSON.parse` + 字段校验，零依赖）；
4. 检查环境配置里**没有明文凭证**（扫描 `password`/`secret`/`token` 字段的值是否形似明文——注意与 `*_env` 引用式字段区分）；
5. 检查 `.test-artifacts/` 在 `.gitignore` 中。

退出码 0/1，与现有 `validate-cases.mjs` 同一套约定。

### 2.6 与 skill 的分工

| Skill | 职责 | 产物落点 |
|---|---|---|
| `test-case-design` | 需求 → 用例集 | `test-assets/suites/<REQ>/cases.json` |
| `api-test-execute`（后续） | 用例集 → 执行结果 | `.test-artifacts/<REQ>/` |
| `test-report`（后续） | 结果 → 报告/缺陷单 | `.test-artifacts/<REQ>/report.html` |

**设计用例集是唯一的交接契约**——上游写、下游读，中间不需要人肉转换。这也是 REQ-001 里 `cases.json` schema 必须稳定的原因。

---

## 3. 设计三：skill 契约改造（修 REQ-001 暴露的缺陷）

### 3.1 `open_questions[]` 进 schema（核心修复）

```json
{
  "meta": { "source": "...", "generated_at": "...", "case_count": 44 },
  "requirements": [ ... ],
  "cases": [ ... ],
  "open_questions": [
    {
      "id": "Q1",
      "question": "「连续发送 3 次后需等待 5 分钟」中，第 3 次发送本身是否允许？",
      "requirement_refs": ["R-4"],
      "interpretations": [
        { "reading": "第 3 次允许发出，随后进入冷却", "impact": "单周期最多 3 封邮件" },
        { "reading": "第 3 次即被拒", "impact": "单周期最多 2 封邮件" }
      ],
      "affected_cases": ["TC-017", "TC-024"],
      "severity": "blocking"
    }
  ]
}
```

**校验器强制**：
- 每条 `open_questions` 必须有 `id` / `question` / `interpretations`（≥2 条）/ `requirement_refs`（非空且存在）/ `severity`；
- `affected_cases` 必须存在于 `cases[]`；
- `severity: "blocking"` 的问题必须挂至少一条用例或显式标记 `coverage: "deferred"`（说明为何不写用例）。

**"歧义只写在人读报告"这个缺陷被消灭。** 这也顺带补上 REQ-001 的 eval 发现——baseline 把假设放 JSON 里，with-skill 反而没放。

### 3.2 `method` + `coverage_matrix` 进 schema

```json
"coverage_matrix": [
  {
    "requirement": "R-3",
    "methods_applied": ["M0.1", "M0.2", "M0.5", "M4.5"],
    "skipped": [
      { "method": "M0.4", "reason": "该条目为纯计算无状态流转" },
      { "method": "M0.6", "reason": "无服务端接口，为内部函数" }
    ],
    "baseline_covered": true,
    "dimensions": ["functional", "boundary", "data"]
  }
]
```

校验器检查：**每个可测试条目都必须覆盖 Layer 0 全部 6 条基线方法**（`M0.1`–`M0.6`）；未覆盖的必须在 `skipped` 里带**非空 reason** 显式声明。这是防"用例变少"的机制性保障——不靠模型自觉，靠脚本拦。

### 3.3 精简 SKILL.md 正文

- 方法论细节从正文移出，SKILL.md 只留**方法目录入口 + 调用规则 + 工作区契约**；
- 方法详解进 `methods/M0.md`~`M4.md`，速查进 `references/method-catalog.md`；
- 目标：SKILL.md 正文从 90 行压到 70 行以内，references 总 token 占用下降。

### 3.4 新增 skill 的分工（避免一个大 skill 塞所有能力）

按 skill-creator 的"一个 skill 一个明确能力"原则：

```
test-case-design      需求 → 用例集（已交付，需改造）
api-test-execute      用例集 → 接口执行结果
ui-test-execute       用例集 → UI E2E 结果
test-report           结果 → 报告 / 缺陷单
```

接口与 UI 执行分离，因为依赖与失败模式完全不同；报告单列，因为它消费的是"执行结果"而非"用例集"。

---

## 4. 落地顺序：两条线并行

用户决策：schema 改造与目录契约**并行推进**。

两条线文件所有权互斥，可由两个 Dev 子 agent 同时做：

| 线 | 阶段 | 内容 | 产出 | 独占文件 |
|---|------|------|------|----------|
| **A** | A1 | `open_questions[]` + `method` + `coverage_matrix` 进 schema，校验器强制 | schema v2 | `scripts/validate-cases.mjs`、`scripts/render-report.mjs` |
| | A2 | 方法库 `catalog.json` + M0–M4 详库 + 速查表 | 方法库 | `methods/`、`references/method-catalog.md` |
| | A3 | SKILL.md 重写（工作区契约 + 调用规则） | skill 改造 | `SKILL.md`、`references/case-schema.md`、`references/coverage-dimensions.md` |
| **B** | B1 | 项目资产目录契约 + 环境配置 schema | 目录契约 | `references/project-layout.md`（新 skill 资产时） |
| | B2 | `verify-layout.mjs` 校验脚本 | 契约校验器 | `scripts/verify-layout.mjs` |

**交叉点与规避**：

- 两线都要改 `scripts/` 目录 → **A 线只碰 `validate-cases.mjs` / `render-report.mjs`，B 线只碰 `verify-layout.mjs`**，文件名不重叠；
- 两线都要引用 schema → **A 线先落 schema v2 定义，B 线的 `verify-layout.mjs` 依赖 `cases.json` 的存在性与基本字段，不校验 v2 新字段**（避免 B 依赖未完成的 A）；
- 合并顺序：**A 线先合，B 线后合**（B 的文档需引用最终 schema）。

### 4.1 REQ-002 验收要点（预览）

| AC | 内容 |
|---|---|
| AC-001 | 用例集含 `open_questions[]`，每项含 ≥2 种解读与影响，且 `affected_cases` 均存在 |
| AC-002 | 校验器拦截"歧义只写在报告、JSON 里没有"的情况 |
| AC-003 | 校验器拦截"可测试条目未覆盖 6 条基线方法且无 skipped reason"的情况 |
| AC-004 | `skipped` 中 reason 为空 → 判失败（"跳过"必须可被 review 发现） |
| AC-005 | 运行时工作区契约：agent 按 §1.1.1 建立 run-root 并按槽位落盘 |
| AC-006 | `RUN.md` 记录方法库快照哈希与条目数，可复现 |
| AC-007 | `catalog.json` 机器可读，校验器直接读它判定基线方法集合 |
| AC-008 | 项目资产目录符合契约，`verify-layout.mjs` 退出码 0 |
| AC-009 | 环境配置无明文凭证（校验器扫描拦截） |
| AC-010 | 回归：REQ-001 的 eval 用例集在 schema v2 下仍能通过校验 |

**AC-010 特别说明**：schema 演进不能破坏既有产物。REQ-001 产出的 44 条用例集（`/tmp/aw-eval/with-skill/cases.json` 格式）必须仍能通过 v2 校验器——为此 v2 的新字段需要**向后兼容策略**：缺 `open_questions` 时校验器给 WARN 而非 ERROR，除非显式声明 `schema_version: 2`。

---

## 5. 决策点（已全部对齐）

| # | 问题 | 决策 |
|---|------|------|
| Q1 | 方法库放哪 | ✅ **不是打包位置问题，而是 skill 定义的运行时工作区契约**（§1.1.1）。方法库随 skill 分发，运行时拷入 `run-root/methods/` 作快照，项目可覆盖裁剪 |
| Q2 | Layer 0 几条 | ✅ **6 条**：正常/边界/异常/非法迁移/**幂等**/**服务端校验**。后两条来自实测——baseline 三轮都自发补了，with-skill 恰恰欠密 |
| Q3 | 项目资产目录名 | ✅ **`test-assets/`** |
| Q4 | 执行产物是否进 Git | ✅ **不进 Git**，`.test-artifacts/` 由 `.gitignore` 排除 |
| Q5 | 环境与执行配置格式 | ✅ **JSON**（校验器只需 `JSON.parse`，与用例集同构） |
| Q6 | 落地顺序 | ✅ **两项并行**（§4 已给出文件所有权划分与合并顺序） |
| Q7 | LICENSE 协议 | ⏸ **暂不决定，先不发布**（npm 包保持未发布状态） |

### 5.1 决策带来的连带影响

| 决策 | 连带影响 |
|---|---|
| 配置用 JSON | 校验器零依赖成立（无 YAML 解析器）；代价是配置文件无注释，字段说明需放在 `_schema.json` 的 `description` 里 |
| 资产目录 `test-assets/` | skill 产出的 `cases.json` 建议落点为 `test-assets/suites/<REQ-slug>/cases.json`；运行时工作区（§1.1.1）与项目资产目录是**两级**，晋升由调用方决定 |
| 产物不进 Git | `verify-layout.mjs` 需检查 `.gitignore` 含 `.test-artifacts/`；CI 需负责归档产物 |
| Layer 0 = 6 条 | 用例量预计上升（REQ-001 with-skill 每条目 2.6 条 → 目标 ≥6 条）；**必须配套"带 reason 的跳过"机制**，否则纯只读需求会被迫造无用例 |
| 不发布 | npm 包保持本地 tarball 状态；后续改动不影响已装 skill（`~/.agents/skills/` 里的副本需手动同步） |

### 5.2 Q7 遗留的处理方式

用户选择"暂不决定，先不发布"。因此：

- `package.json` 维持现状（`license: "MIT"` 字段存在但不发布）；
- **不执行** `npm publish`；
- 后续 skill 改造完成后，用 `npm pack` 产 tarball 供本地安装验证；
- `~/.agents/skills/` 里的已装副本在 skill 改造后需要**手动重新安装**（`node bin/test-agent-skills.mjs install`），这属于安装器的正常行为，不是 bug。
