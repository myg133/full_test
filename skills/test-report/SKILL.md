---
name: test-report
description: 把一次测试执行的产物（meta.json / results.json / evidence/）与可选的回归计划（regression-plan.json）汇总成可机械核验的执行报告（report.json + report.md），给出用例层 / 证据层 / 计划对账层三层结论，点名漏跑的用例与判不了的变更，并绑定输入产物的指纹。
---

# test-report —— 执行报告 + 回归对账

## 这个 skill 解决什么

执行环节产出了 `meta.json` / `results.json` / `evidence/`，但**没有任何工具消费它们**：
五个计数对不对、证据文件在不在、失败那条怎么复现、回归计划要求重跑的用例有没有漏跑 —— 全靠人翻目录。

本 skill **只读**消费执行产物，产出两份东西：

| 产物 | 给谁看 | 契约 |
|---|---|---|
| `report.json` | 机器 | 固定字段集，每个数字都能从输入重算，自带 `report_sha256` |
| `report.md` | 人 | `report.json` 的渲染，数字**逐字相等**，带一行机器可读摘要 |

## 入口命令

```bash
# 基本用法（报告落在 <项目根>/reports/<run_id>/）
node scripts/make-report.mjs --artifacts <run_dir>

# 项目根显式指定（产物目录不在 <root>/.test-artifacts/<id> 形态时**必须**给）
node scripts/make-report.mjs --artifacts <run_dir> --project-root <项目根>

# 带回归计划（做回归对账）
node scripts/make-report.mjs --artifacts <run_dir> --regression-plan <regression-plan.json>

# 指定输出目录（完全覆盖默认输出目录）
node scripts/make-report.mjs --artifacts <run_dir> --regression-plan <plan.json> --out-dir <dir>
```

| 参数 | 必填 | 说明 |
|---|---|---|
| `--artifacts <run_dir>` | 是 | 执行产物目录（含 `meta.json` / `results.json` / `evidence/`） |
| `--project-root <dir>` | 见下 | 项目根；**不给**则要求产物目录呈 `<root>/.test-artifacts/<id>` 形态（否则报错退出 rc=1） |
| `--regression-plan <file>` | 否 | 回归计划文件；**不给就不做回归对账**，也不编造回归层结论 |
| `--out-dir <dir>` | 否 | 报告输出目录，默认 `<项目根>/reports/<run_id>/` |

### 输出位置（报告要能**直接提交进仓库**）

- **默认输出目录 = `<项目根>/reports/<run_id>/`**（`<run_id>` 取自 `meta.json` 的 `run_id`，不自己编）；
- 产物区 `.test-artifacts/` 通常被 `.gitignore` 忽略 ⇒ 报告**不再**落在那里；
- **项目根三段式定位，不猜**（D212）：
  ① `--project-root` 显式指定 → ② 从 run_dir 形态 `<root>/.test-artifacts/<id>` 反推（root = 上两级）
  → ③ 两条都不成立 ⇒ **报错退出 rc=1**，stderr 点名 `--project-root`；
- ⚠️ 项目根**总是**需要：`--out-dir` **只覆盖输出目录**，**不豁免**项目根定位
  （报告里的 `source.artifacts` 必须相对项目根，没有项目根就产不出合规报告）；
- ⚠️ 输入合法性**先于**项目根定位：输入非法时报错点名**是什么坏了**
  （`产物目录` / `meta.json` / `results.json`），不会被「无法推断项目根」抢先。

自洽校验器：

```bash
node scripts/check-report.mjs <report.json>
```

退出码：`0` = 报告已产出 / `1` = 输入缺失或非法（**不产出半份报告**）/ `2` = 用法错误。

### 自测

```bash
node scripts/selftest-report-submittable.mjs
```

覆盖项目根三段式定位、证据内联、脱敏规则（含追踪标识豁免）、不变量与幂等；
退出码 `0` = 全过 / `1` = 有用例失败。

## 输入契约（只读消费）

| 输入 | 必填 | 报告怎么用 |
|---|---|---|
| `<run_dir>/meta.json` | 是 | 运行标识、套件、需求、环境、时间戳；它的**计数与指纹只用来对账** |
| `<run_dir>/results.json` | 是 | **逐条重算**用例计数、失败与阻塞清单、复现信息 |
| `<run_dir>/evidence/` | 是 | **逐条实查**证据文件是否存在、指纹是否一致；**内联**每份实存证据的**内容** |
| `regression-plan.json` | 否 | 回归对账：计划选样 vs 实际执行 |

**硬约束**：

1. **只读** —— 绝不写输入产物目录里的任何既有文件；
2. **计数以 `results.json` 重算为准** —— 不抄 `meta.json` 的自述；两者不符 → 报告必须显示"计数不符"；
3. **证据必须实查** —— `results.json` 说了有不算数，文件实况才算数；
4. **指纹必须重算** —— 报告绑定的两个指纹是从 `results.json` 重算的，不是抄 `meta.json`；
5. **只写自己的输出目录** —— 默认 `<项目根>/reports/<run_id>/`；
6. **证据内容内联** —— `report.json` 的 `evidence.files[]` 装**实查存在的每一份证据文件**
   （含 passed / skipped 用例的），每条**恰好 8 个键**；`content` 是**脱敏后的原始文本**
   （脱敏器没动过就与原文件**逐字相同**），`sha256` 与 `content_sha256` 可分别重算
   ⇒ **只读 `report.json` 就能拿到全部证据内容**，报告单独提交也不丢证据；
7. **报告内一律脱敏** —— 敏感**字段名**的值换成 `[REDACTED:field]`，凭证**值模式**
   （内嵌 JSON 口令 / `Bearer <token>` / URL `user:pass@` / 长 hex）换成 `[REDACTED:secret]`，
   落在项目根下的**绝对路径**换成相对路径；计数在 `redaction` 段里**如实**自陈；
   ⚠️ **被测目标的地址、端口与业务账号逐字保留**（它们是被测对象标识，不是凭证）；
   ⚠️ **追踪 / 业务标识豁免**：`trace_id` / `x-trace-id` / `request_id` / `x-request-id` /
   `span_id` / `correlation_id` / `id` / `uuid` 这些**键名**下的值**原样保留** ——
   「长得像 hash」不是可靠的凭证信号，业务标识与 token 同形。

## 三层结论（不得混为一谈）

| 层 | 问什么 | 数据来源 | 不过的样子 |
|---|---|---|---|
| 用例层 | 跑的那些用例判定如何 | `results.json` 的 `status` 分布 | 有 failed / blocked |
| 证据层 | 这份产物本身可信吗 | 证据实查 + 计数重算 + 指纹重算 | 证据缺失 / 被改 / 计数造假 / 指纹不符 |
| 对账层（计划） | 该跑的有没有都跑 | `regression-plan.json` ∩ `results.json` | 有漏跑 / 有待复核 / 有变更判不了 |

**任一层不过，`overall` 就不为 `pass`。** `blocked`（不可判定）计入 `blocked`，**绝不**计入 `passed`。

判定规则详见 `references/report-rules.md`，字段契约详见 `references/report-schema.md`。

## 诚实性红线

- 不可判定不虚报通过：`blocked` 不算 `passed`，`overall` 不为 `pass`；
- 证据不自洽不出可信结论：证据层 `fail`；
- 计数不符必须被发现并**点名**是哪个计数、meta 记的是多少、实际是多少；
- 证据层结论必须**结构化**：`evidence.findings[]` 逐条给 `kind` 与 `message`，md 逐条渲染；
- 不编造：报告里的每个数字都能从输入重算；`reproduction` **逐字**搬运（敏感内容按脱敏规则替换）；
- 脱敏**不掩盖事实**：脱敏不得影响证据层判定，也不得让「文件没被动过」变得不可判定
  （内容不含敏感内容 ⇒ `content_sha256 == sha256` **严格相等**）；
- 脱敏计数**如实**：`redaction` 段的两个计数就是实际发生的替换次数，不虚报也不漏报；
- 报告自身可核：自带 `report_sha256`，并绑定输入产物的两个指纹；
- 幂等：同一输入两次出报告，除 `generated_at` 外**逐字相同**。

## 与其它 skill 的边界

- `test-case-design/scripts/render-report.mjs` 是**设计侧**报告（覆盖率 / 追溯矩阵，读的是用例集）；
  本 skill 只做**执行侧**报告，两者**不合并、不重写、不替代**；
- `test-execute` 是**上游**：本 skill 消费它的产物格式（`skill-meta.json` 里 `requires` 声明了这层依赖）；
- `regression-plan` 是**上游**：本 skill 消费它的 `regression-plan.json` 做对账。

## 目录

```
skills/test-report/
├── SKILL.md
├── skill-meta.json                 # 版本与依赖声明（requires: test-execute）
├── references/
│   ├── report-schema.md            # report.json 字段契约 + report_sha256 规范化口径
│   └── report-rules.md             # 三层结论 / 回归对账 / 诚实性红线
└── scripts/
    ├── make-report.mjs             # 主入口
    ├── check-report.mjs            # 自洽校验器
    ├── selftest-report-submittable.mjs  # 单元自测（项目根定位 / 证据内联 / 脱敏 / 不变量 / 幂等）
    └── lib/                        # fingerprint / canonical / artifacts / analyze / render / cli
        ├── redaction.mjs           # 报告内脱敏（R1 字段名 / R2 值模式 / R3 绝对路径 / D219 豁免名单）
        ├── project-root.mjs        # 项目根三段式定位（D212，不猜）
        └── evidence-inline.mjs     # 证据内容内联（F2：8 键、相对项目根、双指纹）
```
