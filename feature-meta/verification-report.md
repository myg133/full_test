# REQ-006 验证报告

- 需求：REQ-006「安全 / 压力 / 可观测性覆盖维度 + M2.x 安全测试方法段」
- 分支：`feature/REQ-006`
- 交付位置：`skills/test-case-design/`
- 需求文档（只读）：`BA/demands/REQ-002-suite-foundation/REQ-006-security-stress-observability/`
  （`acceptance.md` 42 条判据 / `decisions.md` D1~D31 / `verify-acceptance.sh`）
- 验收脚本与判据文档均为 **BA 的资产**，本 REQ 全程未改动。

## 一、怎么验的

三层验证，全部由脚本判定，不靠人工目测：

| 层 | 命令 | 结果 |
|---|---|---|
| 主验收（42 条判据） | `bash BA/demands/REQ-002-suite-foundation/REQ-006-security-stress-observability/verify-acceptance.sh feature-REQ-006/skills/test-case-design` | **42 PASS / 0 FAIL** |
| 上游基线回归（REQ-002A） | `bash BA/demands/REQ-002-suite-foundation/REQ-002A-schema-v2/verify-regression-002a.sh feature-REQ-006/skills/test-case-design` | **19 PASS / 0 FAIL** |
| 上游基线回归（REQ-002B） | `bash BA/demands/REQ-002-suite-foundation/REQ-002B-project-layout/verify-regression-002b.sh feature-REQ-006/skills/test-case-design` | **41 PASS / 0 FAIL** |

**钉版本**：上表三条结论由本 REQ 的验收脚本的下列这个版本跑出（D25 ⑤）。脚本一改，下面的
摘要值就对不上，AC-034 立即判红 ——「跑的是哪一版脚本出的结论」从此由脚本判定，不再只靠人工记着钉版。

- 验收脚本 sha256: 20dc3e71dd6a401fddf998e04035a7995552b20b15aeedc07213a7d5255f3760

主验收耗时约 10 分钟（AC-026 会在 skill 副本上注入 28 个变异体，并**嵌套跑一遍完整验收**，
比对"失败的 AC 键集合"是否发生变化）—— 跑得久是正常的。

三条回归的作用各不相同：
- **REQ-002A** 证明本 REQ 对 `validate-cases.mjs` 的改动**没有改变旧语义**
  （本 REQ 只同步了方法编号的注释，编号格式正则与判定行为一字未改）。
- **REQ-002B** 证明项目布局契约（`cycle-state.mjs` / `verify-layout.mjs` / `references/project-layout.md`）
  未被本 REQ 的改动波及。
- **主验收** 证明本 REQ 新增的能力（三个覆盖维度 + M2.x 方法段 + 编号段文案与分类）真的生效。

## 二、验出了什么

主验收 42 条判据全部通过，逐类要点：

| 能力 | 验证结论 |
|---|---|
| 覆盖维度从 8 项扩到 11 个维度 | 枚举里 `security` / `stress` / `observability` 齐全，每个 7 个字段逐项非空；三个 `applies_when` 信号集合两两不同（相同即等于同一个问题问两遍，跳过理由要求翻倍且零增量） |
| 维度清单文档与枚举同步 | 三个新维度在清单文档里都有**非空**的逐维度检查清单小节（只有标题没有正文同样判红）；清单表格取值集合 == 枚举 id 集合 |
| 方法库收录 M2.x 段（共 9 种方法） | M2.1 威胁建模（STRIDE）/ M2.2 攻击面枚举 / M2.3 模糊测试逐条字段齐全（含非空 `not_applies_when`）；脚本实跑认这些编号，不再报"未在方法库中登记" |
| M2.x 的必需产出可机械核验 | 谓词 `kind` 在白名单内，引用的维度 id 在枚举里真实存在 —— 引用一个不存在的维度等于该谓词**永远不可满足**，本条点名判红 |
| 声明用了 M2.x 但没有对应产出 → 被发现 | 只声明 M2.x 而用例集里没有该方法的必需产出 → 退出码 1 并点名该方法与该需求条目 |
| Layer 0 段仍被挡住 | 方法库里没有 `M0.` / `M4.` 条目；`M0.1` 仍判"无法判定"而非通过；未登记提示里的"Layer 0 必选测试点段"分类提示原样保留（编号段被粗暴放宽时这个提示会静默消失） |
| 交付侧记账与方法库同步 | 三份追溯件里的「N 种方法」逐处等于方法库实际条数；追溯矩阵逐条覆盖 42 条判据，每行恰好 4 个非空单元；实现清单覆盖被验目录里的每一个交付文件 |
| 验收护栏自检 | 28 个变异体（含新维度被删、清单小节被删、谓词引用不存在的维度、编号段被粗暴放宽、方法数陈旧、Layer 0 段被收进方法库）**全部被测出**，还原后失败项集合回到基线 |

## 三、本轮改了什么

| # | 问题 | 改法 | 落点 |
|---|---|---|---|
| 1 | 维度清单里没有"安全 / 压力 / 可观测性"这一问 —— agent 逐维度问一遍却在清单里**没有这一问**，等于合规地判定"已覆盖" | 维度枚举新增 3 项（各带完整适用信号与跳过理由要求），清单文档补 3 行表格 + 3 节逐维度检查清单 | `skills/test-case-design/references/dimensions.json`、`skills/test-case-design/references/coverage-dimensions.md` |
| 2 | 现有的方法全是通用功能测试方法，装不下安全测试的方法内核 | 方法库新增 M2.x 段（M2.1 / M2.2 / M2.3），每种方法带可机械核验的必需产出 | `skills/test-case-design/references/methods.json`、`skills/test-case-design/references/design-methods.md` |
| 3 | 编号侧文案与实际不符（库里已有两段，提示仍说"只收录 M1.x"） | 编号段常量与提示文案改成 M1.x/M2.x 两段；Layer 0 段的分类判定与提示字样保持独立 | `skills/test-case-design/scripts/check-methods.mjs` |
| 4 | 交付侧记账记的是上一轮的方法数、维度数与判据条数 | 三份追溯件按当前规模重写（判据条数、决策号、方法数、维度数、方法区间、追溯矩阵行数），并重钉验收脚本摘要值 | `feature-meta/{status,traceability,verification-report}.md`、`feature-meta/manifest.json` |

**这一轮的实质**：把"该问的问题"与"该用的方法"两处缺口都补上，并且让**新增的部分同样可被机械核验** ——
维度字段逐项查、清单小节非空查、M2.x 谓词引用的维度真实存在查、声明了 M2.x 却没产出直接判红。

## 四、已知限制

1. **`M0.x` / `M4.x` 判"无法判定"**（D8 / D10）：架构稿 Layer 0 的必选测试点（正常路径 / 边界值 /
   异常输入 / 非法迁移 / 幂等 / 服务端校验 / 数据质量）**不在本方法库内**，
   `check-methods.mjs` 无法核验它们的产出，故判"无法判定"而非通过。
   把 Layer 0 纳入方法库需要为 7 个必选测试点各自定义 `required_outputs`，属另一个 REQ 的范围。
2. **适用性检查是启发式的**（WARN 类）：`METHOD_MISSING` / `METHOD_SUSPECT` / `DIMENSION_MISSING`
   依据的是需求文本里的信号词匹配，属**主观适用性存疑**而非可机械判定的事实，
   因此只报 WARN、不阻断退出码，但必须在报告里说明。
3. **安全维度与方法不替代漏洞扫描**：M2.x 产出的是**用例**（怎么设计安全测试），
   不做 `npm audit` / `bandit` 这类工具链扫描，也不做渗透操作指引 —— 那是 `qa-toolchain` 与执行侧的职责。
4. **压测执行不在本 skill 内**：本 REQ 只新增"压力"这个**覆盖维度**（极限下行为是否仍然正确），
   发压、吞吐统计与容量拐点判定属执行侧，独立成 skill。
5. **判据与实现的边界**：方法库能证明"声明的方法有对应产出"，但**证明不了产出的质量**
   （用例本身好不好、断言是否有意义）—— 那是人工评审与后续执行侧的职责。
