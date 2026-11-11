# REQ-002.5a 验收报告

- **需求**：REQ-002.5a 轮次状态推进器（状态写入权收口到脚本）
- **交付分支**：`feature/REQ-002.5A`
- **交付 commit**：`e7cef81`（主体）+ `5ce4c51`（追加：skip-scope 补 at/by）+ 补丁 commit（缺陷 4 修复，见第 5 节）
- **验收方**：BA（`ba-local-ba-20261109161500`）
- **验收方式**：机械验收脚本 + 契约↔实现变异测试 + 独立 QA 子 agent

---

## 1. 验收结论

**通过。**

| 项 | 结果 |
|---|---|
| AC 验收脚本 | **28 PASS / 0 FAIL**（`verify-acceptance.sh`，AC-001~027） |
| REQ-002B 契约↔实现变异回归 | **41 PASS / 0 FAIL**（`verify-regression-002b.sh`） |
| 独立 QA 子 agent | 判定 PARTIAL，挖出 P1~P6 —— 全部已修并复验（见第 4 节） |
| 既有需求回归（REQ-002A / REQ-002B） | 无回归。`validate-cases.mjs` 改动为纯增量，Dev 做了改前/改后**逐字节对拍**（5 例 stdout+stderr+退出码完全一致） |
| 分发链路 | `npm pack` 15 个文件，三个新文件（`cycle-state.mjs` / `lib/state-machine.mjs` / `state-machine.md`）齐全 |
| 已安装副本 | `~/.agents/skills/test-case-design/` 11 个文件到位，**28 PASS / 0 FAIL** |
| 合并 | `dc175e4`（`--no-ff`） |
| 工作区巡检 | `aw.py verify` 0 FAIL / 0 WARN；`doctor` 0 FAIL / 1 WARN（watcher 未装，环境限制）；`audit` 干净 |

**已装副本与包根两种形态的验收结果一致（均 28 PASS）** —— 验收脚本据此修正了 AC-016 的判据（已装副本下没有 `package.json`，依赖检查改由 import 检查覆盖）。


## 2. 交付清单

| 文件 | 行数 | 职责 |
|---|---|---|
| `skills/test-case-design/scripts/lib/state-machine.mjs` | 317 | **状态机规则单一来源**：轮次/阶段/scope/round 枚举、转移表、终态判定、`status`↔`history` 一致性判定、history 四字段、`scopes_skipped` 四字段 |
| `skills/test-case-design/scripts/cycle-state.mjs` | 795 | 状态推进器：`init` / `show` / `advance` / `skip-scope` / `set-stage`。原子写（临时文件 + rename）、失败零副作用、幂等、`--json`、退出码 0/1/2 |
| `skills/test-case-design/references/state-machine.md` | 226 | 状态推进契约：枚举、完整转移表、全部子命令与参数、原子性与副作用规则、"状态文件只由脚本写"硬约束、常见错误与修法 |
| `skills/test-case-design/scripts/verify-layout.mjs` | 795 | 删掉自带的状态机实现改为 import 共享模块；补 4 处契约↔实现缺口；强制项 14 → 18 条 |
| `skills/test-case-design/references/project-layout.md` | 339 | 新增 §4.2 `cycle.json` 字段表；各"必须"标注是否被校验器拦截；§6.1 错误表、§6.3 检查表同步 |
| `skills/test-case-design/SKILL.md` | 118 | 补 `verify-layout.mjs` / `cycle-state.mjs` / `references/project-layout.md` / `references/state-machine.md` 四个入口 + 写入权硬约束；补 schema v2 输出契约（缺陷 4） |

## 3. 本 REQ 修复的既有缺陷

| # | 缺陷 | 定性 | 修法 |
|---|---|---|---|
| 1 | `cycle.json` 的 `requirement` 是校验器必填，但契约文档 §4 从未写过 `cycle.json` 字段表 | **文档缺口**（校验器是对的，REQ-002B demand.md F4 有定义） | 补 `project-layout.md` §4.2 字段表 |
| 2 | 环境 `name` 与文件名不一致未被拦截（契约 §3.2 明确要求"完全一致"） | **实现缺口** | 校验器加交叉校验 |
| 3 | `history` 每条缺 `at`/`from`/`to`/`by` 全部未被拦截（契约 §4.3 明确要求） | **实现缺口** | 共享模块加 `checkCycleState()`，校验器与推进器共用 |
| 4 | `SKILL.md` 的 Output contract 未同步 schema v2 → **REQ-002A 的全部强制在真实使用路径上空转** | **文档缺口（P0）** | 补 v2 输出契约 + 校验器加 v2 骨架生成 |

### 缺陷 4 详述（本轮最严重）

REQ-002A 的强制规则是"缺字段报 WARN，显式声明 `schema_version: 2` 才升级为 ERROR"。而 `SKILL.md` 从未告诉 agent 要声明 `schema_version: 2`，其 Output contract 列的 `cases[]` 字段仍是 v1 形态。

**实测**：按 SKILL.md 的 Output contract 造用例集 → 校验器只报 4 条 WARN → **exit 0 通过**。

即 `open_questions`（歧义暴露）、`coverage_matrix`（跳过留痕）、`cases[].method`（方法声明）、`cases[].status`（生命周期）四项强制，**在 agent 的实际使用路径上一条都没生效**。REQ-002A 的立项理由（"强制必须落在脚本上"）因此落空。

**根因**：REQ-001 时代的 SKILL.md 在 REQ-002A 引入 v2 后未同步，而 REQ-002A 的 14 条 AC 里没有一条检查"SKILL.md 与 schema 是否一致"。

## 4. 独立 QA 验收

**独立 QA 子 agent 判定：PARTIAL（有条件通过）。**

QA 独立于我的验收脚本，自建 fixture、转移表 5×5 穷举 25/25、故障注入测原子性、41+10 项变异测试，结论：

- **20 条 AC 全部通过**（我这边 22 项检查亦全绿）
- 核心设计意图基本达成：规则单一来源（源码层）、单文件原子写（故障注入 4 连 + SIGKILL×20 无残留）、失败零副作用（15 条失败路径逐一 sha256 比对）、幂等、零依赖、可移植、并发安全
- **但发现 6 个 AC 之外的缺陷**，其中 2 个直击"推进器与校验器行为一致、状态写入权可信收口"这个核心意图

### QA 发现的缺陷与裁决

| # | 级别 | 缺陷 | BA 裁决 | 复验 |
|---|---|---|---|---|
| P1 | 高 | `index.json` 与 `cycle.json` 非原子更新；index 写失败时 cycle 已改，**重试走幂等分支不补同步 → 永久脱同步，校验器还完全不报警** | **本 REQ 必修**。采纳 QA 三条修法：失败回滚 cycle + 幂等分支也同步 index + 校验器加 index↔cycle 一致性检查（兜底） | ✅ AC-022 PASS |
| P2 | 中 | 推进器与校验器对同一份坏文件报告不一致 —— `show`/`advance` 只调 `checkCycleState`，漏 `checkScopesSkipped`；推进器还会把坏文件继续写下去 | **本 REQ 必修**。这正是 AC-011 的判据。单一来源不只是"规则写在一处"，还包括"用哪套规则做准入判断"也一致 | ✅ AC-023 PASS |
| P3 | 中 | 契约文档写"必须/类型"，校验器不拦 —— 9 处逃逸（`stages.<name>.status` 缺失/类型错、artifacts/scopes/scopes_skipped/trigger/round 类型错、suite.json 多余字段） | **本 REQ 修**。根因是 `typeof body.status === 'string' &&` 这种写法只在已是字符串时才检查 | ✅ AC-024 / AC-025 PASS |
| P4 | 中 | `SKILL.md` 未覆盖 `init` 与 `skip-scope` 两个最常用入口 —— agent 只读 SKILL.md 答不出"我要开始一轮测试该敲什么" | **本 REQ 修**。约 5 行改动，与缺陷 4 的 SKILL.md 修改合并 | ✅ AC-026 PASS |
| P5 | 低 | `--json` 在 usage 错误时 stdout 不是合法 JSON（`parseArgs` 在 `context.json` 赋值前执行） | **本 REQ 修**。成本极低 | ✅ AC-027 PASS |
| P6 | 低 | `project-layout.md` 标题写"14 项"实际 22 行 | **本 REQ 修**。纯文档 | ✅ 已改为 22 项 |

对应新增 AC-022 ~ AC-027。

### BA 侧验收脚本自身的三次修正（记录在案）

本轮 BA 的验收脚本自身出过 **4 个 bug**，都曾造成假失败或假通过 —— 与 Dev 的实现无关：

| # | Bug | 后果 | 修正 |
|---|---|---|---|
| 1 | `V2MISS` 初值写成字符串 `"0"` 而非空串 | `[ -z "$V2MISS" ]` 恒假 → **AC-020 恒 FAIL** | 改为 `V2MISS=""` |
| 2 | AC-023/024 用 `\|\|` 判断校验器结果 | 把"校验器拦住了"当成失败 → **8 例真实拦截被报成逃逸** | 改 `&&`（退出码 0 = 放行 = 逃逸） |
| 3 | AC-023 把轮次建在 `test-assets/cycles/` 之外 | 校验器只报「test-assets/ 缺失」，**fail 原因不是注入的缺陷**，信号无效 | 改用 `make_project` 造合法项目 |
| 4 | AC-016 假设 `<skill-dir>/../..` 有 `package.json` | **已装副本形态下恒 FAIL** | 区分包根/已装副本两种形态；已装副本改由 import 检查覆盖依赖 |

第 2、3 条是 Dev 发现的（它把自己的实现放到 BA 脚本的副本上跑，发现"8 例全被拦下但脚本报逃逸"，进而定位到我的判据取反）。**这说明验收脚本本身也需要被验收** —— 它的失败不能直接当成交付不合格。


### QA 指出的 BA 侧盲区（已修正）

QA 指出：**"本 REQ 已经建了验收脚本，但它目前只覆盖 AC 明写的场景，恰好漏掉了 P2/P3 这两类'契约↔实现漂移'。"** —— 说得对。我的 AC-011 只测了 `status↔history` 场景，没测 `scopes_skipped` 场景；契约类型逃逸也完全没覆盖。已补入 AC-022~027 并在验收脚本中实现。

### QA 未能验证的项（如实记录）

1. **真实 agent 行为** —— 只能静态判读 SKILL.md 的信息是否足以让 agent 答出三问，无法在真实模型上跑端到端。REQ-001 那类"模型自信绕过契约"的行为风险未实测。
2. **新版本安装后可用性** —— QA 验收时 `~/.agents/skills/test-case-design/` 仍是 develop(REQ-002B) 版，未含新文件。安装流程在合并后由 BA 执行并验证。
3. **Windows 行为** —— `renameSync` 的原子性在 NTFS 下与 POSIX 有差异，本次仅在 Linux 实测。
4. **index ↔ cycle 一致性契约缺口** —— 原契约未声明二者必须一致，本 REQ 已补上该条契约与校验。


## 5. 补丁轮次

| 轮次 | commit | 内容 | 触发 |
|---|---|---|---|
| 主体 | `e7cef81` | 状态推进器 + 共享状态机模块 + 契约文档修复 + 缺陷 1/2/3 | BA 首轮派单 + 追加缺陷 2/3 |
| 追加 | `5ce4c51` | `skip-scope` 记录补 `at`/`by`（审计链完整性） | BA 裁决 D13 |
| 补丁 | `7179d6d` | 缺陷 4（P0：SKILL.md 同步 v2 + 校验器 `--init` 骨架生成）+ P1~P6 | BA 独立发现缺陷 4 + 独立 QA 的 P1~P6 |
| 合并 | `dc175e4` | `--no-ff` 合入 develop | — |

## 6. 本 REQ 建立的两道防线（长期资产）

这个套件此前**没有任何自动化回归测试**，连续两次返工都靠手工逐条验证 —— 而缺陷 2、3、4 正是手工验收阶段漏掉的。

| 资产 | 位置 | 作用 |
|---|---|---|
| AC 验收脚本 | `REQ-002.5a-state-advance/verify-acceptance.sh` | 22 条 AC 全机械化，一条命令跑完 |
| 契约↔实现变异回归 | `REQ-002B-project-layout/verify-regression-002b.sh` | 41 例：逐条破坏契约声明的"必须"，看校验器是否真拦。**这类缺陷只能靠变异测试挖出来** |

## 7. 方法论沉淀（留给后续 REQ）

「**契约 ↔ 实现 ↔ 文档三者的双向一致性**」必须机械化验证，不能靠人读：

- 契约文档写了"必须" → 校验器必须拦（变异测试覆盖）
- 校验器拦了 → 契约文档必须写（否则执行者按文档办事被拒）
- 文档/契约改了 → SKILL.md 必须同步（否则 agent 产出走错形态）

三个缺口（缺陷 1、2、3、4）分别落在这三条链路上。**后续每个新增契约的 REQ，都应同时提供一份变异回归脚本。**
