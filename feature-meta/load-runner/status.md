# REQ-012 交付进度与自测报告 —— `load-profile` 的 **runner 适配**（负载模型 → 压测计划，**零请求**）

> 需求编号：**REQ-012** · 决策号范围：**D156~D184** · 判据条数：29（AC-001 ~ AC-029）
> 需求契约（**只读**）：`BA/demands/REQ-002-suite-foundation/REQ-012-load-runner/`
> （`demand.md` 功能契约 / `acceptance.md` 判据集 / `decisions.md` 决策记录 / `PROBE-FACTS.md` 勘察事实 / `verify-acceptance.sh` 验收门）

---

## 1. 交付边界复核

| 边界 | 落实情况 |
|---|---|
| **不新增 skill 目录** | ✅ 仍在 `skills/load-profile/`（架构 §8 的 REQ-002.9 就是这个 skill） |
| **只写** `test-assets/load/plans/` | ✅ 入口只写 `<out-dir>/test-assets/load/plans/`；模型 / 套件 / 环境 / `report.json` 一律只读 |
| **不改** REQ-009 的既有 14 个文件 | ✅ 只**新增**文件（2 个入口 + 2 个 lib 模块 + 1 份参考文档），既有 14 个文件 sha256 与基线逐字一致 |
| **不改** `test-execute` | ✅ `not_implemented` 仍含 `load`（本 REQ **不实现**执行器） |
| **不装工具** | ✅ 只在文档里**声明** `loadtest` 的依赖（由工具链管），入口不装、不 spawn |
| **不发任何请求** | ✅ 全程只有文件读写；验收门用两个桩服务计数证实**请求数为 0** |
| **不做阈值判定** | ✅ 阈值**逐字携带**（供人看），产物里**没有任何**「已达标 / 未达标」的结论 |
| **不改** REQ-009 的追溯件 | ✅ `feature-meta/load-profile/` 四件套与包内根 `feature-meta/manifest.json` **逐字未动**；本 REQ 的追溯件另起 `feature-meta/load-runner/` |

## 2. 交付物清单

| 文件 | 作用 |
|---|---|
| `skills/load-profile/scripts/plan-load-run.mjs` | **主入口**（可执行、shebang、`node --check` 通过）：负载模型 + 套件 + 环境 ⇒ 压测计划 |
| `skills/load-profile/scripts/check-load-run.mjs` | **产物自洽校验器**（可执行、shebang、`node --check` 通过）：复核计划与模型逐字一致，**篡改计划 ⇒ rc=1** |
| `skills/load-profile/scripts/lib/runner.mjs` | runner 适配契约：枚举与白名单、`target` 拆分、URL 拼法、`loadtest` / `python` 两种 argv 构造 |
| `skills/load-profile/scripts/lib/plan.mjs` | 读入（只读）/ 输入校验 / 计划构造 / 产物侧自检 / 键序无关的深比较 |
| `skills/load-profile/references/runner-adapters.md` | 适配契约文档：参数映射表、两种 runner 形态、写入纪律、诚实性红线、边界 |
| `README.md` | 新增「`load-profile` 的 runner 适配入口」一节（两个新脚本名都在）；skill 清单与安装树**未动** |
| `feature-meta/load-runner/` | 本 REQ 的追溯件四件套（`status.md` / `traceability.md` / `verification-report.md` / `manifest.json`） |

## 3. 关键实现取舍（与契约口径一致）

| # | 取舍 | 落点 |
|---|---|---|
| 1 | 「多段不合并」：`profile.steps[]` 每段一条 invocation，`step_index == 下标` | `lib/plan.mjs`（`buildPlans`） |
| 2 | `--cores 1` **恒定钉死**（默认半核会让 rps / maxRequests 按核分摊 ⇒ 语义随机器变） | `lib/runner.mjs`（`buildLoadtestArgv`） |
| 3 | `timeout_s`（**秒**）→ `-d`（**毫秒**、**单请求**超时）用 `Math.round(×1000)` 换算 | `lib/runner.mjs` |
| 4 | `args` 未知键**拒绝**（按 runner 分白名单，跨 runner 的键同样拒绝），rc=1 且**点名该键** | `lib/runner.mjs`（`assertArgsKeys`） |
| 5 | `python` runner **必须自陈完整 argv 数组**；字符串命令拒绝；未知 `{...}` 占位符拒绝；**不编造**默认命令 | `lib/runner.mjs`（`buildPythonArgv`） |
| 6 | URL = `base_url` **去尾部 `/`** + 目标路径；场景条目的 `base_url` **字段**仍逐字等于环境文件（含尾斜杠） | `lib/runner.mjs`（`buildUrl`） |
| 7 | 「先校验、后建目录」：校验与产物自检全在落盘之前，非法输入时 `plans/` **一个都不许出现** | `scripts/plan-load-run.mjs` |
| 8 | 产物**不含**任何生成时间戳 / 随机 id / 宿主路径 ⇒ 幂等 = 两份产物**逐字相同** | `lib/plan.mjs`（构造过程） |
| 9 | 阈值**二态**用**键的有无**表达（`not_provided` ⇒ 连 `thresholds_source` 都没有）；缺口用未决问题**留痕** | `lib/plan.mjs`（`buildPlans`） |
| 10 | 校验器**有行为护栏**：从模型重算期望计划并与产物逐字比对（**键序无关**）+ 结构自检 ⇒ 篡改计划必判红 | `scripts/check-load-run.mjs` + `lib/plan.mjs` |
| 11 | 未决问题**承载自模型**（条目数相等、`id` / `topic` 逐字相等），措辞属实现方判断（但必须非空） | `lib/plan.mjs`（`buildPlans`） |

## 4. 自验结论（真实输出摘要）

验收门**快跑**与**完整模式**、上游门回归、组合门的**真实输出**见 `verification-report.md`。

三条要点：

1. 验收门**快跑**：29 条判据全 PASS、0 FAIL、rc=0；
2. 验收门**完整模式**：正控**全部检出**、负控**未检出**、29 条判据全 PASS、0 FAIL；
3. 上游门回归（REQ-009 / 010 / 011 / 007 / 008 / 006 + 002A / 002B）与组合门**全绿**，既有场景结论**逐字未变**。

## 5. 存疑项（**未自改判据**，请需求方回查契约原文后拍板）

| # | 判据 / 条款 | 我的读法 | 冲突点 | 我按的口径实现 |
|---|---|---|---|---|
| 1 | `acceptance.md` AC-002 + D158 + `demand.md` F9（`SKILL.md` **逐字未改**） vs. 派工单 §2 第 5 项 / §4（「`SKILL.md` **只增补** runner 适配这一节」） | AC-002 判的是 **`skills/load-profile/SKILL.md` 整个文件的 sha256** ⇒ **任何**增补都会让该条判红 | 「增补一节」与「逐字未改」**不能同时成立** | 按**契约**口径实现：**SKILL.md 一字未动**（sha256 与基线一致）；runner 适配的说明全部落在**新增**的 `references/runner-adapters.md`（并在 README 里新增入口一节） |
| 2 | `demand.md` F3.2「`open_questions` **逐字等于**模型」 vs. 同节的口径分歧留痕 + `acceptance.md` AC-021 ⑧（`id` / `topic` 逐字、**措辞自由**） | 契约正文已明确取「措辞自由」这一边（两处裁决 + 更晚的 §10.2） | 若严格逐字，AC-021 ⑧ 与判据说明冲突 | 按 **AC-021 ⑧**：条目数相等、`id` / `topic` 逐字相等、`question` 文字**自由**（实现上直接承载模型的原文 —— 既自由又不丢信息） |
| 3 | AC-021 ⑤⑦（`not_provided` 必留 `thresholds` 主题、无对应用例必留 `coverage` 主题） vs. AC-021 ⑧（条目数与模型相等） | 若模型**没带**对应主题的未决问题，「补一条」会违反 ⑧，「不补」会违反 ⑤⑦ | 两条判据在「模型缺该主题」时互斥 | 模型**缺**该主题 ⇒ **输入非法，rc=1**（点名缺哪个主题），**不**私自往计划里塞一条（那会破坏 ⑧）。模型带了就**逐条承载** |

## 6. 我**没有验到**、也**不必**做的（**不许声称**）

1. **未验真实压测工具能否跑** —— 本 REQ **不执行**；只保证 argv 形态正确、参数名真实存在（`loadtest` 由工具链管，本 REQ 不装）；
2. **未验压测结果、阈值达标与否** —— 属后续阶段（本 REQ **一个请求都不发**）；
3. **未验任何真实服务的容量表现** —— 不存在这个事实；
4. **未在非 GNU/Linux 环境验过** —— 本机是 Linux，`sha256sum` / `stat -c` 等 GNU 工具未做跨平台适配；
5. **未做并发跑门测试** —— 验收纪律要求「一次只跑一个门」（并发会产生无因果关系的失败键）。

---

# REQ-013 交付进度与自测报告 —— `load-profile` 的 **负载级执行与判定链**（只打本地桩）

> 需求编号：**REQ-013** · 决策号范围：**D185~D210** · 判据条数：41（AC-001 ~ AC-041）
> 需求契约（**只读**）：`BA/demands/REQ-002-suite-foundation/REQ-013-load-exec/`

| 项 | 状态 |
|---|---|
| 交付物 7 项 | ✅ 全部交付（执行入口 / 校验器 / 桩 / 执行器+判定器 / 契约文档 / SKILL.md 追加节 / 追溯件四件套） |
| 验收门（快跑） | ✅ 41 PASS / 0 FAIL，rc=0 |
| 验收门（完整模式） | ✅ 41/41 变异体全部检出、负控未检出，rc=0（真实输出见 `verification-report.md`） |
| 只打本地桩 | ✅ 计划 URL 与执行 URL 双重回环校验；桩只监听 `127.0.0.1`、端口 0、生命周期由执行器托管 |
| 不覆盖上游 | ✅ A 阶段（REQ-012）文件与契约、其它 skill、`bin/`、`package.json`、`README.md`、`LICENSE` 全部未改 |
| 追溯件 | ✅ `verification-report.md` / `traceability.md` / `feature.json` / `feature-meta.json` 四个文件都有；`traceability.md` 里 REQ-013 的决策号并集 == D185~D210 全集 |
| `manifest.json` | ⚠️ **刻意未改**：REQ-012 的验收门 AC-027 钉死 `feature-meta/load-runner/manifest.json` 的 `req == "REQ-012"` ⇒ 改动会打破上游门；REQ-013 的记账放在本 REQ 的四件套与本节 |

⚠️ `feature-meta/load-runner/manifest.json` 的 `req` 仍为 `REQ-012`（**刻意保留**，见上表末行）；
REQ-013 的交付位置与判据映射见 `traceability.md` 的 REQ-013 一节与 `feature.json` / `feature-meta.json`。
