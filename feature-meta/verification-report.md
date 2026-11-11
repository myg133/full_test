# REQ-005 验证报告

- 需求：REQ-005「测试方法库（数据化）+ test-case-design SKILL.md 重写」
- 分支：`feature/REQ-005`
- 交付位置：`skills/test-case-design/`
- 需求文档（只读）：`BA/demands/REQ-002-suite-foundation/REQ-005-method-library/`
  （`acceptance.md` 35 条判据 / `decisions.md` D1~D25 / `verify-acceptance.sh`）
- 验收脚本与判据文档均为 **BA 的资产**，本 REQ 全程未改动。

## 一、怎么验的

三层验证，全部由脚本判定，不靠人工目测：

| 层 | 命令 | 结果 |
|---|---|---|
| 主验收（35 条判据） | `bash BA/demands/REQ-002-suite-foundation/REQ-005-method-library/verify-acceptance.sh feature-REQ-005/skills/test-case-design` | **35 PASS / 0 FAIL** |
| 上游基线回归（REQ-002A） | `bash BA/demands/REQ-002-suite-foundation/REQ-002A-schema-v2/verify-regression-002a.sh feature-REQ-005/skills/test-case-design` | **19 PASS / 0 FAIL** |
| 上游基线回归（REQ-002B） | `bash BA/demands/REQ-002-suite-foundation/REQ-002B-project-layout/verify-regression-002b.sh feature-REQ-005/skills/test-case-design` | **41 PASS / 0 FAIL** |

**钉版本**：上表三条结论由 `BA/demands/REQ-002-suite-foundation/REQ-005-method-library/verify-acceptance.sh`
的下列这个版本跑出（D25 ⑤）。脚本一改，下面的 sha256 就对不上，AC-034 立即判红 ——
「跑的是哪一版脚本出的结论」从此由脚本判定，不再只靠人工记着钉版。

- 验收脚本 sha256: 87b56add34ed1dd328e645f1745cf493fbab6645bf62cbf1ec4a47340ee8b211

主验收耗时约 3 分钟（AC-026 会在 skill 副本上注入 19 个变异体，并**嵌套跑一遍完整验收**，
比对"失败的 AC 键集合"是否发生变化）—— 跑得久是正常的。

三条回归的作用各不相同：
- **REQ-002A** 证明本 REQ 对 `validate-cases.mjs` 的改动**没有改变旧语义**
  （唯一例外是 D11 放开的 `skipped[].method` 的 `dimension:` 前缀）。
- **REQ-002B** 证明项目布局契约（`cycle-state.mjs` / `verify-layout.mjs` / `references/project-layout.md`）
  未被本 REQ 的改动波及。
- **主验收** 证明本 REQ 新增的能力（方法使用核验、维度适用性、单一来源枚举）真的生效。

## 二、验出了什么

主验收 35 条判据全部通过，逐类要点：

| 能力 | 验证结论 |
|---|---|
| 方法使用从"声明"变"可核验事实" | 声明 `M1.2` 但缺 `boundary` 产出 → 退出码 1 并点名该方法与该需求条目；补齐产出后不再误报；取值全相同时被"期望取值不具区分度"抓出 |
| 三分类互斥（ERROR / WARN / 无法判定） | ERROR 与 WARN 不落在同一条 (需求, 方法)；`undecidable` 的结论**绝不是** `satisfied`；`M0.x`/`M4.x` 判"无法判定"而非默认通过（虚报类红线） |
| 判据覆盖完整性 | 每个 (需求条目 × 方法) 组合都有结论，漏判会被抓出 |
| 覆盖维度单一来源 | 副本加第 9 个维度 → 副本认、原目录不认（证明读的是文件不是硬编码）；删掉 `dimensions.json` → 明确报错退出，不静默降级到内置列表 |
| 文档与库一致 | 方法说明与 `methods.json` 对照、维度清单与 `dimensions.json` 对照，两侧都能单独从命令行触发 |
| 跳过项契约 | 缺 reason → 两脚本都拦；文案按实际跳过对象分词（跳方法说"方法"、跳维度说"维度"）；legacy 写法两脚本都判非法并指路；拼错的维度名两脚本都报 ERROR 并点名 |
| 验收护栏自检 | 19 个变异体（含 6 个"护栏漏测"漏洞与 3 个虚报类）**全部被测出**，还原后失败项集合回到基线 |
| 一致性口径 | 两个脚本 `--help` 都是退出码 2 且给出用法；`feature-meta/` 归属本 REQ、`demand_dir` 指向真实存在的目录；实现注释与实现分支同口径 |

## 三、历轮改了什么

### 本轮（第八轮）：追溯链钉版 —— 把验收脚本的 sha256 记进验证报告

本轮**只改 `feature-meta/` 里的两份文件**，方法库本体与验收脚本一行未动
（验收脚本是 BA 的资产，D25 ② 冻结期内不得改）。

| # | 问题 | 改法 | 落点 |
|---|---|---|---|
| 1 | 独立验收第四轮发现护栏漏洞 A39：**删掉整个 `feature-meta/` 目录后，验收仍全绿** —— 护栏在"找不到被护对象"时自我豁免（判"不适用"），追溯链整段删掉照样放行 | BA 侧已按 D25 ④⑤ 改好验收脚本：四件套缺任一即 FAIL（不再有"不适用"分支），且要求追溯链记下**当前**验收脚本的 sha256 | `BA/demands/REQ-002-suite-foundation/REQ-005-method-library/verify-acceptance.sh`（BA 侧资产，本轮未改） |
| 2 | 追溯链没有记下"这批结论是哪一版脚本跑出来的" —— D25 ② 记录过 BA 在验收跑批中改了 3 次脚本而钉版没同步，此前"钉版本"只靠人工纪律 | 验证报告里记下当前验收脚本的 sha256（**恰好一处**），脚本一改即判红 | `feature-meta/verification-report.md` |
| 3 | 追溯矩阵里 AC-028 / AC-034 的判据形式措辞落后于 BA 侧收紧后的判据 | 按 BA 侧新措辞同步这两行；其余行、判据条数、决策号一律不动 | `feature-meta/traceability.md` |

**这一轮的实质**：把"钉版本"从**人工纪律**变成**脚本判定** ——
「跑的是哪一版脚本出的结论」不再由写报告的人自己记着，而是报告里的 sha256 与当前脚本文件比对。

### 第七轮：元数据数字同步到当前 + 追溯矩阵补齐

本轮**只改 `feature-meta/` 里的三份文件**，方法库本体与脚本一行未动。

| # | 问题 | 改法 | 落点 |
|---|---|---|---|
| 1 | 三份文件里的判据条数 / 决策号 / 验收数字**全部陈旧**（写的是上一轮的判据条数、上一轮的决策号上限、上一轮的主验收通过数），且**没有任何判据守这个** | 把**每一处**「N 条判据」「D1~D<n>」改成当前实际值：35 条判据 / D1~D25；主验收结果改成 35 PASS / 0 FAIL | `feature-meta/{status,traceability,verification-report}.md` |
| 2 | 追溯矩阵只覆盖到 AC-030，判据已扩到 AC-034 —— **追溯链断在 AC-031** | 按现有行格式补齐 AC-031~AC-034 四行（AC 编号 \| 交付位置 \| 自验方式 \| 结论） | `feature-meta/traceability.md` |

**为什么要专门做这一轮**：这些数字原先**只靠"写的人记得更新"** —— 没人核过，也就等于没写。
本轮 BA 侧补了 **AC-034** 把它们纳入机械核验：三份文件里每一处「N 条判据」必须等于
`acceptance.md` 的实际条数（35）、每一处「D1~D<n>」必须等于 `decisions.md` 的最大决策号（D25）、
主验收行的 `P + F` 必须等于判据条数且 `F == 0`。
**以后数字对不对由脚本查，不由人记** —— 这正是本项目一直在消灭的那类"看着像已验、其实没验"。

### 第五轮：元数据与一致性四处

第五轮只修**元数据与一致性**四处，方法库本体未动（本体已通过 BA 侧独立验收，0 缺陷）。

| # | 问题 | 改法 | 落点 |
|---|---|---|---|
| 1 | 注释与实现相反（AC-027）："维度名不在枚举内"的注释仍写"只报 WARN"，而实现已是 `fail(...)`（ERROR） | 把 3 处提到"只报 WARN"的注释全部改成与实现一致的描述（ERROR 口径 + 为什么这么定：拼错的跳过声明从来不会生效，报 WARN 会让"校验通过"与"该维度实际没被跳过"同时成立） | `skills/test-case-design/scripts/validate-cases.mjs` |
| 2 | `feature-meta/` 三个文件是别的 REQ 的内容（AC-028①） | 三个文件全部重写为本 REQ 的真实内容：`status.md`（开发状态）、`traceability.md`（AC-001~AC-034 逐条追溯矩阵）、`verification-report.md`（本文件） | `feature-meta/{status,traceability,verification-report}.md` |
| 3 | `manifest.json` 的 `demand_dir` 指向不存在的目录（AC-028② / D20） | 改为真实路径 `BA/demands/REQ-002-suite-foundation/REQ-005-method-library` | `feature-meta/manifest.json` |
| 4 | `--help` 退出码口径不一致（AC-030）：`validate-cases.mjs` 把 `--help` 当用例集路径 → rc=1，而脚本头声明"2 = 调用方式错误" | `validate-cases.mjs` 识别 `--help` / `-h` / 未知参数 → 退出码 2 并打印用法说明（与 `check-methods.mjs` 口径一致） | `skills/test-case-design/scripts/validate-cases.mjs` |

**注释即陷阱**：问题 1 的实现本来就对、注释说反了。后来人照注释"修回去"就制造回归 ——
这类"契约与实现分叉"正是本项目一直在消灭的东西，所以注释也在修复范围内。

## 四、已知限制

1. **`M0.x` / `M4.x` 判"无法判定"**（D8 / D10）：架构稿 Layer 0 的必选测试点（正常路径 / 边界值 /
   异常输入 / 非法迁移 / 幂等 / 服务端校验 / 数据质量）**不在本方法库内**，
   `check-methods.mjs` 无法核验它们的产出，故判"无法判定"而非通过。
   把 Layer 0 纳入方法库需要为 7 个必选测试点各自定义 `required_outputs`，属另一个 REQ 的范围。
2. **适用性检查是启发式的**（WARN 类）：`METHOD_MISSING` / `METHOD_SUSPECT` / `DIMENSION_MISSING`
   依据的是需求文本里的信号词匹配，属**主观适用性存疑**而非可机械判定的事实，
   因此只报 WARN、不阻断退出码，但必须在报告里说明。
3. **维度枚举改动的收敛期**：新增维度必须改 `references/dimensions.json`（唯一来源），
   文档侧由脚本对照保证一致；改完仍需跑一次对照检查确认没漏。
4. **判据与实现的边界**：方法库能证明"声明的方法有对应产出"，但**证明不了产出的质量**
   （用例本身好不好、断言是否有意义）—— 那是人工评审与后续执行侧的职责。
