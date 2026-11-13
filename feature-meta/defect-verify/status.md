# REQ-007 开发状态

- 需求：REQ-007「缺陷复现能力域：`defect-verify` skill（R3 缺陷复现用例生成）」
- 分支：`feature/REQ-007`
- 状态：**开发完成（待需求方跑验收门）**
- 判据条数：**29**（AC-001~AC-029）
- 决策号范围：**D72~D97**（26 条，本 REQ 自己的决策记录）
- 需求文档（只读）：`BA/demands/REQ-002-suite-foundation/REQ-007-defect-verify/`
  （`demand.md` F1~F8 / `acceptance.md` 29 条判据 / `decisions.md` D72~D97）

## 交付清单（本次新增/改动的文件）

| 路径 | 说明 |
|---|---|
| `skills/defect-verify/SKILL.md` | skill 入口：三类处置结论 + 产物形状 + 硬约束 |
| `skills/defect-verify/skill-meta.json` | 版本与依赖声明（`requires` 含 `test-case-design` 与 `test-execute`） |
| `skills/defect-verify/references/defect-input-schema.md` | 缺陷单格式：字段约束 + 两层合法性划分 + 轮次契约 |
| `skills/defect-verify/references/derivation-rules.md` | 派生规则、归一化口径、编号约定、共享场景裁定、诚实性红线、写入权 |
| `skills/defect-verify/scripts/make-defect-cases.mjs` | 主入口：读缺陷单 + 用例集 + 轮次目录 → 产 `defect-cases.json` |
| `skills/defect-verify/scripts/check-defect-cases.mjs` | 产物自洽校验器（对照 `references/derivation-rules.md` 的形状契约） |
| `skills/defect-verify/scripts/selftest-defect-cases.mjs` | 派生规则的单元自测（**含验收夹具造不出的共享场景**） |
| `skills/defect-verify/scripts/lib/cli.mjs` | 命令行参数解析 |
| `skills/defect-verify/scripts/lib/io.mjs` | 输入读取 / 产物原子写入 / 错误类型（退出码 1 与 2） |
| `skills/defect-verify/scripts/lib/normalize.mjs` | 归一化口径与特征匹配（实现侧的唯一来源） |
| `skills/defect-verify/scripts/lib/validate-defects.mjs` | 结构层校验：缺陷单 / 用例集 / R3 轮次契约 |
| `skills/defect-verify/scripts/lib/derive.mjs` | 处置判定（reused / derived / unresolved） |
| `skills/defect-verify/scripts/lib/product.mjs` | 产物装配（`defects[]` / `cases[]` / `coverage_matrix[]` / 共享合并） |
| `bin/verify-suite.mjs` | 组合门新增 `scenarioDefectVerify`（**实跑**并从产物反推断言） |
| `README.md` | 安装树 + skill 表格**两处**补 `defect-verify`；组合门说明补第四条链路 |
| `feature-meta/defect-verify/` | 本 REQ 的交付侧追溯件四件套 |

> 本 REQ **未改动**既有 5 个 skill 的任何文件，也未改动包内根 `feature-meta/manifest.json`。

## 核心设计

- **处置结论有且只有一个**：`reused`（复用已有用例）/ `derived`（派生 1 条新用例）/
  `unresolved`（显式说不知道 + 非空理由）。`unresolved` **不是失败**。
- **判定顺序固定**：`case_refs` 优先（先按 id 去重）→ 信息充分性（只是派生分支的前置）→ 特征匹配。
- **归一化口径写死**：NFKC → 去首尾空白 → 压缩空白 → 剥成对引号 → 去末尾标点 → 再去首尾空白；
  steps 指纹用 `\x01` 连接；用例侧 command 取该用例的 `reproduction.command`（不带则为空）。
- **共享场景**：多条缺陷引用同一条已有用例时，产物里该用例**只出现一次**，
  `defect_refs` / `tags` / `requirement_refs` 含**全部**引用它的缺陷；每条缺陷各自独立判 `reused`。
- **诚实性**：输出缺陷 id 集合 == 输入缺陷 id 集合；`unresolved` 必带理由；不得凭空造缺陷；不得重复派生。
- **只读 + 幂等**：缺陷单 / 用例集 / `cycle.json` 逐字节未变；只写 `<out-dir>/defect-cases.json`；
  产物已存在即报错退出；同一输入两次除 `meta.generated_at` 外逐字相同。

## 自验结论（真实输出见 `verification-report.md`）

| 自验项 | 结论 |
|---|---|
| §0 夹具主跑 | 缺陷 5 条（复用 2 / 派生 1 / 未决 2）；复现用例 3 条；与基线真值表逐项一致 |
| 幂等 | 两次运行除 `meta.generated_at` 外**逐字相同**（5003 字节 = 5003 字节） |
| 只读 | 缺陷单与用例集的 sha256 跑前跑后一致；输入目录无散落文件 |
| 可执行性 | `run-suite.mjs --dry-run` 退出码 0，计划 3 条 == 产物 `cases.length`；按 `BUG-005` 分批计划 1 条 |
| 非法输入 | 11 种变体全部 rc=1、stderr 点名坏点、**无** `defect-cases.json` |
| 共享场景 | 共享用例只出现一次；`defect_refs`/`tags`/`requirement_refs` 含两条缺陷且不悬空 |
| 单元自测 | 17 条断言全过（`selftest-defect-cases.mjs`） |
| 组合门 | 4 条组合场景全过（含 `scenarioDefectVerify`） |
| 目录契约 | `verify-layout.mjs` 退出码 0、0 FAIL；错误位置探针结论 = 位置不受约束 |

## 遗留项（登记，不自行扩大契约）

| 编号 | 遗留项 | 说明 |
|---|---|---|
| L-01 | 「扩展编号段用尽 ⇒ 改判 `unresolved`」的分支造不出（需 899 条已占用用例） | 契约既定边界；实现已按规则落地（`derive.mjs` 的 `allocateId()` 返回 `null` 即改判） |
| L-04 | 可消费性用 `--dry-run` 判，不真发请求 | 契约既定边界：复现是否成功属 R3 轮次**执行阶段**的事 |
| L-05 | 共享场景未被验收夹具覆盖 | 实现侧已按契约落地，并在 `references/derivation-rules.md` §5 写明裁定，附单元自测 `scripts/selftest-defect-cases.mjs`（T1 / T3） |

> ⚠️ 验收脚本由**需求方**跑（并发跑会产生无因果关系的失败键）：
> `QA007_SCRIPT_SHA=961ed0db… bash verify-acceptance.sh <REPO_ROOT>/feature-REQ-007`。
