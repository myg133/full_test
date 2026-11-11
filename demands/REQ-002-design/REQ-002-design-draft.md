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

### 1.2 方法分层

```
Layer 0 — 必选基线（每条需求条目都要过）
├── M0.1 正常路径（happy path）
├── M0.2 边界值（上下界各一格 + 界值）
├── M0.3 异常/无效输入
└── M0.4 状态/生命周期非法迁移

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
└── M4.5 数据质量（精度/精度舍入/脏数据）
```

**关键设计点：Layer 0 是密度保底。** 这直接修 REQ-001 暴露的"用例变少"——每条需求条目至少过 4 条基线方法，不允许因为"感觉不适用"而跳过。

**4 这个数字不是拍脑袋来的。** 实测 baseline 三轮的"每条目平均用例数"为 3.4 / 3.1 / 4.0，with-skill 为 2.6。Layer 0 定 4 条基线大致落在裸模型的自然密度上——既不比裸模型更严（避免用例膨胀），也不像 with-skill 那样欠密（2.6 条时确实漏了「最多 1 张券」「实付非负」）。

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

**必须承认**：SKILL.md 里的自然语言步骤对模型是**软约束**。REQ-001 实测已经证明——SKILL.md 第 5 步写了"按覆盖维度清单补齐"，模型照样少产一半用例。写成 "M0.1–M0.4" 编号并不会让模型自动执行。

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
├── skills/
│   ├── test-case-design/       # 设计 skill
│   │   ├── references/
│   │   │   ├── method-catalog.md   # 方法目录（速查 + 选型规则）
│   │   │   ├── case-schema.md
│   │   │   └── coverage-dimensions.md
│   └── ...（后续能力域）
└── shared/
    └── test-methods/           # 方法库（跨 skill 共享）
        ├── catalog.json        # 机器可读：方法定义 + 特征规则
        └── methods/*.md        # 各方法的详细说明
```

`catalog.json` 是机器可读的，校验器可以直接读它做覆盖检查——这是"方法可审计"的技术基础。

---

## 2. 设计二：真实测试的目录接口契约

### 2.1 解决什么问题

REQ-001 只管"设计"不管"执行"。真实使用时，用例 JSON 需要和**环境、配置、数据、脚本、报告**关联起来。否则：

- 同一个用例集在不同环境跑，配置散落各处；
- 环境切换靠改代码；
- 执行产物（报告、日志、截图）污染仓库；
- 多个 skill（设计→执行→报告）之间没有稳定的交接格式。

### 2.2 目录契约

沿用 agent-workspace 的**可见名 vs 隐藏名**规则：

- 要进 Git 的用**可见名**；
- 纯本地产物用 `.` 前缀。

```text
<project-root>/
├── testcase/                     # 测试资产（进 Git）
│   ├── README.md                 # 目录契约说明（人读）
│   ├── environments/             # 环境定义
│   │   ├── local.yaml
│   │   ├── staging.yaml
│   │   └── _schema.yaml           # 环境配置 schema
│   ├── suites/                   # 用例集（每个需求一个）
│   │   └── REQ-001-coupon/
│   │       ├── cases.json         # test-case-design 产出
│   │       ├── open-questions.md  # 未决问题（人读 + 可选）
│   │       └── suite.yaml         # 执行配置
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

### 2.3 环境配置 schema

`environments/_schema.yaml` 定义结构，`environments/*.yaml` 填值：

```yaml
name: staging
base_url: https://staging.example.com
timeout_ms: 5000
retries: 0
credentials:
  # 引用方式，不落明文
  username_env: STAGING_USER
  password_env: STAGING_PASS
headers:
  X-Test-Run: "${run_id}"
verify_tls: false
data_fixtures:
  - path: testcase/fixtures/users.json
    cleanup: true
```

**关键设计点：凭证只走环境变量引用**，配置文件里不存明文。这让配置文件可以安全进 Git。

### 2.4 用例集与执行的接口

`suite.yaml` 声明"这组用例怎么跑"：

```yaml
suite: REQ-001-coupon
requirement: REQ-001
environment: staging
cases_file: cases.json
executor: api
base_url_from: environment.base_url
tags:
  include: ["P0", "P1"]
  exclude: []
report:
  format: ["html", "json"]
  output_dir: .test-artifacts/REQ-001-coupon
```

### 2.5 目录契约的强制手段

契约不能只靠文档说，要**可校验**。新增脚本：

```
scripts/verify-layout.mjs
```

职责：
1. 检查 `testcase/` 下必需目录存在；
2. 检查每个 `suite.yaml` 的字段完整、引用路径存在；
3. 检查 `environments/*.yaml` 符合 `_schema.yaml`（零依赖手写校验）；
4. 检查环境配置里**没有明文凭证**（扫描 `password`/`secret`/`token` 字段的值是否形似明文）；
5. 检查 `.test-artifacts/` 在 `.gitignore` 中。

退出码 0/1，与现有 `validate-cases.mjs` 同一套约定。

### 2.6 与 skill 的分工

| Skill | 职责 | 产物落点 |
|---|---|---|
| `test-case-design` | 需求 → 用例集 | `testcase/suites/<REQ>/cases.json` |
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
    "methods_applied": ["M0.1", "M0.2", "M4.5"],
    "baseline_covered": true,
    "dimensions": ["functional", "boundary", "data"]
  }
]
```

校验器检查：**每个可测试条目都必须跑过 Layer 0 全部 4 条基线方法**（`M0.1`–`M0.4`）。这是防"用例变少"的机制性保障——不靠模型自觉，靠脚本拦。

### 3.3 精简 SKILL.md 正文

- 方法论细节从正文移出，SKILL.md 只留**方法目录入口 + 调用规则 + 契约**；
- references/ 从 3 个拆成：`method-catalog.md`（速查）、`case-schema.md`、`coverage-dimensions.md`，另加 `shared/test-methods/` 详库；
- 目标：SKILL.md 正文从 90 行压到 60 行以内，references 总 token 占用下降。

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

## 4. 落地顺序建议

| 阶段 | 内容 | 产出 | 依赖 |
|---|---|---|---|
| **S1** | `open_questions[]` + `method` + `coverage_matrix` 进 schema，校验器强制 | skill 改造 + schema v2 | 无 |
| **S2** | 方法库 `catalog.json` + 分层方法详库 | `shared/test-methods/` | S1 |
| **S3** | `testcase/` 目录契约 + `verify-layout.mjs` + 环境配置 schema | 目录契约 | S1（用例集落点） |
| **S4** | `api-test-execute` skill（首个执行类） | 接口执行 | S1+S3 |
| **S5** | `test-report` skill | 报告/缺陷单 | S4 |

S1 优先级最高——它修的是 REQ-001 已验证存在的缺陷（歧义未结构化），且成本最低（改 schema + 校验器，不动方法库）。

---

## 5. 待你对齐的决策点

| # | 问题 | 我的建议 | 影响 |
|---|------|---------|------|
| Q1 | 方法库放 skill 内还是独立共享包？ | 独立共享（`shared/test-methods/`），skill 只带速查表 | 决定 S2 的目录结构与打包方式 |
| Q2 | Layer 0 必选基线定 4 条够不够？ | 4 条（正常/边界/异常/非法迁移），偏严 | 太严→用例膨胀；太松→回到 REQ-001 的漏覆盖 |
| Q3 | 目录契约根目录叫 `testcase/` 还是 `tests/`？ | `testcase/`（避免与代码自带的 `tests/` 单元测试目录冲突） | 目录名一旦定下难改 |
| Q4 | 执行产物目录 `.test-artifacts/` 是否进 Git？ | 不进，只进 `.gitignore` | 决定团队协作方式 |
| Q5 | 环境配置用 YAML 还是 JSON？ | YAML（人写友好），校验器手写零依赖解析 | 已有 `js-yaml` 依赖顾虑 |
| Q6 | REQ-002 是否就要落 schema v2，还是先只做目录契约？ | 先做 schema v2（修缺陷优先） | 决定 S1/S3 的先后 |
| Q7 | LICENSE 协议仍是 MIT？ | 待你确认（REQ-001 遗留） | 阻塞 npm 发布 |
