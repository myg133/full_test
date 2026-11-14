# REQ-008 开发状态

- 需求：REQ-008「安全能力域：`security-plan` skill（OWASP 全套 + 依赖扫描）」
- 分支：`feature/REQ-008`
- 状态：**开发完成（待需求方跑验收门）**
- 判据条数：**29**（AC-001~AC-029）
- 决策号范围：**D98~D126**（29 条，本 REQ 自己的决策记录）
- 需求文档（只读）：`BA/demands/REQ-002-suite-foundation/REQ-008-security-plan/`
  （`demand.md` 功能契约 / `acceptance.md` 判据集 / `decisions.md` 决策记录 / `status.md` 终审裁定）

## 交付清单（本次新增/改动的文件）

| 路径 | 说明 |
|---|---|
| `skills/security-plan/SKILL.md` | skill 入口：威胁模型 → 权限矩阵 → 安全用例；三条硬约束 |
| `skills/security-plan/skill-meta.json` | 版本与依赖声明（`requires` 含 `test-case-design` 与 `qa-toolchain`） |
| `skills/security-plan/references/security-context-schema.md` | 输入契约：字段集、结构层约束、两层退出码 |
| `skills/security-plan/references/threat-model-format.md` | 威胁模型产物契约：威胁 12 字段、OWASP 十类、四类补充、扫描三形态 |
| `skills/security-plan/references/threat-derivation.md` | 威胁派生规则：规则表、关键词表、扫描发现分类、矩阵判定口径 |
| `skills/security-plan/references/matrix-format.md` | 权限矩阵产物契约与决策表 |
| `skills/security-plan/references/derivation-rules.md` | 用例派生与落位规则：封闭 7 个、方法库、id 分配、套件落位、加载层口径 |
| `skills/security-plan/scripts/make-security-plan.mjs` | 主入口：安全上下文（+ 可选用例集 / 扫描结果）→ 威胁模型 + 权限矩阵 + 安全用例集 + 套件配置 |
| `skills/security-plan/scripts/check-security-plan.mjs` | 产物自洽校验器（对照产物契约逐项复算） |
| `skills/security-plan/scripts/selftest-security-plan.mjs` | 派生规则的单元自测（含验收夹具造不出来的分支） |
| `skills/security-plan/scripts/lib/cli.mjs` | 命令行参数解析（用法错 rc=2） |
| `skills/security-plan/scripts/lib/io.mjs` | 输入读取 / 产物原子写入 / 错误类型（rc=1 与 rc=2） |
| `skills/security-plan/scripts/lib/catalog.mjs` | 枚举常量 + 方法库 / 维度库装载（**唯一来源**：test-case-design） |
| `skills/security-plan/scripts/lib/context.mjs` | 安全上下文的结构层校验与归一化 + 功能用例集摘要读取 |
| `skills/security-plan/scripts/lib/scan.mjs` | 扫描结果三种合法形态的解析与严重度映射 |
| `skills/security-plan/scripts/lib/threats.mjs` | 威胁派生（规则集 + 扫描接入 + 覆盖声明反推） |
| `skills/security-plan/scripts/lib/matrix.mjs` | 权限矩阵派生与矩阵自洽校验 |
| `skills/security-plan/scripts/lib/cases.mjs` | 用例派生（id 分配 / 方法选择 / 步骤模板 / 套件分组） |
| `skills/security-plan/scripts/lib/product.mjs` | 产物装配与写盘纪律（产物已存在即报错） |
| `bin/verify-suite.mjs` | 组合门新增 `scenarioSecurityPlan`（**实跑**并从产物反推断言） |
| `README.md` | 安装树 + skill 表格**两处**补 `security-plan`；组合门说明补第五条链路 |
| `feature-meta/security-plan/` | 本 REQ 的交付侧追溯件四件套 |

> 本 REQ **未改动**既有 6 个 skill 的任何文件，未改动 `test-execute`（含 `executors/`），
> 未改动包内根 `feature-meta/manifest.json`，未改动 `package.json`。

## 核心设计

- **覆盖状态从威胁集合反推**：`owasp_coverage` / `supplements` 的 `covered` ⇔ 该类**确有**威胁，
  `not_applicable` ⇒ 该类**没有**威胁 + 非空理由 + 一条未决问题 ⇒ 「判不适用却造了该类威胁」
  这种自相矛盾**结构上不可能出现**。
- **十类 OWASP / 四类实战补充逐类有交代**：不静默跳过；不适用必须写清**检查了什么**。
- **威胁只锚定真实对象**：每条威胁锚定 ≥1 资产 + ≥1 信任边界 + ≥1 入口点，`rationale` 非空；
  上下文的每个资产 / 边界 / 入口**都不得漏**（有覆盖兜底规则）。
- **越权缺口双向对应由构造保证**：越权类威胁只在「有普通业务角色 **且** 有凭据类资源」时产生，
  这两个条件同时成立时矩阵必然产出至少一条指向它的 `gap` 条目。
- **只做规划，不执行**：`security` 执行器未实现 ⇒ 本 skill 不碰 `test-execute`，
  「可被消费」只证到**加载层**（`loadSuite` / `loadCases` / `selectCases` + 上游 `validate-cases.mjs`）。
- **不跑扫描器**：扫描由 agent 用已交付的 `qa-toolchain` 跑 bandit / npm audit 后把结果喂进 `--scan`；
  工具装不上 ⇒ 显式传「扫描状态」JSON；没传 ⇒ `scan.status = "not_provided"`（显式声明，不静默跳过）。
- **只读 + 幂等**：输入逐字节未变；只写 `<out-dir>/test-assets/security/`；产物已存在即报错退出。

## 自验结论（真实输出见 `verification-report.md`）

| 自验项 | 结论 |
|---|---|
| ① 夹具主跑 | 威胁 11 条；OWASP 十类 covered 7 / 不适用 3（各带非空理由 + 未决问题）；四类补充 covered 1 / 不适用 3；扫描 2 条发现全部映射到威胁；矩阵 12 条（缺口 1 条）；安全用例 18 条（id `TC-004`~`TC-021`，跨套件唯一且不与输入集冲突） |
| ② 幂等 | 两次跑（两个 out-dir）产物除 `meta.generated_at` 外**逐字相同**（threat-model 14277 vs 14277 字节；矩阵 3394 vs 3394 字节；7 个套件的 cases.json / suite.json 全部逐字相同） |
| ③ 只读 | 三份输入 sha256 跑前跑后一致；输入目录与 out-dir 顶层条目跑前跑后一致（out-dir 之外无新增文件） |
| ④ 加载层可消费 | 上游 `loadSuite` / `loadCases` / `selectCases` 全部成功且 selected == total（7 个套件）；上游 `validate-cases.mjs` 对 7 个 `cases.json` 退出码**均为 0**；`check-security-plan.mjs` 退出码 0 |
| ⑤ 非法输入 | 13 种非法上下文/扫描变体全部 rc=1、stderr 点名坏点、**不留半份产物**；3 种用法错全部 rc=2 |
| ⑥ 覆盖诚实性 | 十类 / 四类逐类有交代；覆盖状态由威胁反推 ⇒ 无「判不适用却有该类威胁」；单元自测 95 条断言全过 |
| ⑦ 组合门 | `node bin/test-agent-skills.mjs verify` 真跑：临时根装齐 7 个 skill、依赖图校验通过、**5 条**组合场景实跑全过（含新增 `scenarioSecurityPlan`） |
| ⑧ 上游连带约束 | README 双向比对通过；7 个 skill 的 `skill-meta.json` 形状与 frontmatter 一致性通过；`npm pack --dry-run` 7 个 skill 目录、`feature-meta` 0 条；`package.json` 未变；包内根 `feature-meta/manifest.json` 的 `req` 仍是 `REQ-006`；既有 6 个 skill 零改动；全包无特定字样 |
| ⑨ 验收门 | **未跑**（需求侧在维护门；并发跑会产生无因果关系的 FAIL 键） |
