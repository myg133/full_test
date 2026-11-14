# REQ-009 交付进度与自测报告 —— `load-profile`（压测能力域：负载模型 + runner 适配）

> 需求编号：**REQ-009**（原编号 `REQ-002.9`）· 决策号 **D127~D155**（29 条）· 判据条数：29（AC-001 ~ AC-029）
> 需求契约（**只读**）：`BA/demands/REQ-002-suite-foundation/REQ-009-load-profile/`
> （`demand.md` 功能契约 / `acceptance.md` 判据集 / `decisions.md` 决策记录 / `status.md` 终审裁定 / `verify-acceptance.sh` 验收门）

---

## 1. 交付边界复核

| 边界 | 落实情况 |
|---|---|
| **只新增** `skills/load-profile/` | ✅ 14 个文件（SKILL.md / skill-meta.json / references×3 / scripts×2 / lib×7） |
| **不改**既有 7 个 skill | ✅ `skills/` 下其余 7 个目录**零改动**（`git status` 可核） |
| **不改**包内根 `feature-meta/manifest.json` | ✅ **逐字未动**（其 `req` 仍是 REQ-006） |
| **组合门**只**新增**场景 | ✅ `bin/verify-suite.mjs` 新增 `scenarioLoadProfile`，既有 4 个场景一字未改 |
| README **两处** | ✅ skill 清单表 + 安装树代码块 |
| 追溯件四件套 | ✅ `feature-meta/load-profile/`（本文件 + traceability.md + verification-report.md + manifest.json） |

**不做的事**（写进 `SKILL.md` 的「边界」段）：不发压、不实现 `load` 执行器、不写 `cases.json`、
不派生用例、不扩方法库、不写 `method` 字段、不创建/修改环境配置、不改轮次状态、
不写包内根 `feature-meta/manifest.json`、不联网、不装工具。

## 2. 交付物清单

| 文件 | 作用 |
|---|---|
| `skills/load-profile/SKILL.md` | skill 入口（frontmatter: `name: load-profile` + 非空 description） |
| `skills/load-profile/skill-meta.json` | 版本与依赖声明（`requires` 恰为 `test-case-design` + `qa-toolchain`） |
| `skills/load-profile/references/load-context-schema.md` | 压测上下文格式（顶层封闭 5、workload 封闭 10、阈值成对规则、两层退出码） |
| `skills/load-profile/references/load-scenario-format.md` | 负载模型本体（封闭 14）与套件级引用件（封闭 3）的产物契约 |
| `skills/load-profile/references/profile-rules.md` | 负载画像 / 阈值 / 链路存在性对账规则 |
| `skills/load-profile/scripts/make-load-profile.mjs` | 主入口（可执行、shebang、`node --check` 通过） |
| `skills/load-profile/scripts/check-load-profile.mjs` | 产物自洽校验器（可执行、shebang、`node --check` 通过） |
| `skills/load-profile/scripts/lib/catalog.mjs` | 枚举与字段集基线（单一来源） |
| `skills/load-profile/scripts/lib/cli.mjs` | 命令行参数解析（用法错 ⇒ rc=2） |
| `skills/load-profile/scripts/lib/io.mjs` | 输入读取 / 产物写入 / 错误类型（rc=1 与 rc=2 分档） |
| `skills/load-profile/scripts/lib/context.mjs` | 上下文输入层校验（封闭集 / 枚举 / 引用 / 阈值成对） |
| `skills/load-profile/scripts/lib/reconcile.mjs` | 链路存在性对账（action 归一化 + case_refs） |
| `skills/load-profile/scripts/lib/product.mjs` | 产物构造与落盘（场景 / 套件 / 计划清单） |
| `skills/load-profile/scripts/lib/validate.mjs` | 产物侧自检（落盘前 + 落盘后共用一份实现） |
| `bin/verify-suite.mjs` | 组合门新增 `scenarioLoadProfile`（实跑 + 从产物反推断言） |
| `README.md` | skill 清单表 + 安装树代码块两处补 `load-profile`；组合门说明补第 8 条链路 |

## 3. 关键实现取舍（与契约口径一致）

| # | 取舍 | 落点 |
|---|---|---|
| 1 | 「没有指标来源」= `thresholds_status` 二态 + **阈值键的有无** + 必留 `topic=thresholds` 未决问题 | `lib/product.mjs`（`buildScenarioDoc`）+ `lib/context.mjs`（成对规则） |
| 2 | 阈值与来源**成对**：只给一个 ⇒ 输入层 rc=1（不做「补一个默认值」的宽容处理） | `lib/context.mjs`（`checkWorkload`） |
| 3 | 套件级 `scenario.json` 用 **`scenarios` 数组**（元素 `{path,id,name}`），**不用** `load_scenario` | `lib/product.mjs`（`buildProducts`） |
| 4 | `suite.json` 只写上游允许的 **6 个必填字段**，**不写**任何 scope 专属字段 | `lib/product.mjs`（`suiteDoc`） |
| 5 | 产物**不含**任何生成时间戳 ⇒ 幂等 = 两份产物**逐字相同** | 全部产物构造处均不写时间字段 |
| 6 | 未决问题 id 在**整套产物里全局唯一**（按容量目标顺序分配）⇒ 任何文件里都能唯一定位一条缺口 | `lib/product.mjs`（`makeQuestion` 的全局序号） |
| 7 | 「先校验、后建目录」⇒ 输入非法时 `test-assets/load/` **一个都不许出现** | `scripts/make-load-profile.mjs`（校验 → 自检 → 落盘三段严格有序） |
| 8 | 落盘前再跑一遍**产物侧自检** ⇒ 产物不合法就**不落盘**（不产生半份产物） | `lib/validate.mjs`（`assertProductInvariants`） |

## 4. 自验结论（真实输出摘要）

快跑（`REQ009_NO_MUT=1`）与完整模式（变异体套件）的真实输出见 `verification-report.md`；
组合门（`node bin/test-agent-skills.mjs verify`）的真实输出也记在同一份文件里。

三条要点：

1. 验收门**快跑**：29 条判据全 PASS、0 FAIL、rc=0；
2. 验收门**完整模式**：正控**全部检出**、负控**未检出**、29 条判据全 PASS、0 FAIL；
3. 组合门：既有 4 个场景**未受影响**，新增的第 8 条场景（`load-profile`）通过。

## 5. 我**没有验到**的部分（不猜、不当通过）

1. **未在非 GNU/Linux 环境验过** —— 本机是 Linux，`sha256sum` / `stat -c` 等 GNU 工具未做跨平台适配。
2. **未验「压测套件真的能跑起来」** —— `load` 执行器**未实现**（`test-execute/executors/index.json`
   的 `not_implemented` 含 `load`），本 REQ 只证到**加载层**可消费；`run-suite.mjs --dry-run`
   在本 REQ 的口径里**不要求**跑通（那是永远判红的假判据）。
3. **未验真实环境文件缺失时的分支** —— 上游校验器对该套件判 `[FAIL]`；按契约那属于
   「前置条件不满足 ⇒ 不可判定」，本 REQ 不写环境文件 ⇒ **判不了**。
4. **未验 `qa-toolchain` 装 `loadtest@8.2.1` 的链路** —— 本 REQ **不装工具**（`requires` 只是声明性依赖）。
5. **未做并发跑门测试** —— 验收纪律要求「一次只跑一个门」（并发会产生无因果关系的失败键）。
6. **组合门场景用的是组合门自造的最小夹具**（不是验收门那份）—— 两份夹具形状一致但**不是同一份文件**。
