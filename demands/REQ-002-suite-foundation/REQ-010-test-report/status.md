# REQ-010 状态 —— 报告能力域 `test-report` skill

- **状态**: 进行中
- **认领**: 未认领（待派 Dev，worktree `feature-REQ-010`）
- **分支**: `feature/REQ-010`（未创建）
- **依赖**: REQ-004（`test-execute` 产物契约 + 证据链）、REQ-011（`regression-plan.json`）、REQ-006（`test-case-design`）、REQ-002.5a（`cycle-state.mjs`）、REQ-002A（schema v2）、REQ-002B（目录契约）
- **下游**: REQ-007（R3 缺陷复现要消费报告里的失败清单）

## 进度

| 项 | 状态 |
|---|---|
| 需求文档 | 完成（`demand.md`：三层结论模型 / 输出契约 / 回归对账 / 诚实性红线） |
| 决策记录 | 完成（D48~D70，共 **23 条**） |
| 验收标准 | 完成（AC-001~AC-029，共 **29 条**，自包含） |
| 验收脚本 | **完成**（2018 行；29 条判据 + 4 正控 + 1 负控变异体 + sha 钉版 + 三态） |
| 门的自测 | **完成**（D65：先自测门、再派 Dev）—— 门侧缺陷 **10 处**全修（3 处评审发现 + 7 处自测发现）；7 个探针全绿 |
| 实现 | 待派 Dev |
| 独立验收 | 未开始 |
| 收口 | 未开始 |

## 下一步

1. **写验收脚本** `verify-acceptance.sh`（29 条判据 + 变异体套件 + 夹具自造）
2. **写模拟实现**（BA 侧 `/tmp` 下）并干跑，确认门能跑通
3. **自测门**（D65）：自造探针攻击自己的门 —— 至少覆盖「变异体注入」「逃逸形态」「假阳性形态」
4. **登记开单**（`req-registry.md` 的 REQ-010 行 → 进行中）+ 认领 + 建 worktree/分支
5. **派工 Dev**：实现 `skills/test-report/` + 组合门扩展到第 5 个 skill + 落地 `feature-meta/test-report/`
6. **独立验收**：验收方自造探针攻 29 条判据
7. **收口**：合并 develop → 登记表 → 需求状态 → 重装已装副本 → 回收 worktree → 巡检

## 验收判据版本

| 项 | 值 |
|----|----|
| 验收脚本 | `verify-acceptance.sh`（本目录，**2018 行**，D65 自测已过） |
| 当前 sha256 | `daf495a24c4a6180bb19d09036d2fe6da429663cda6e070cde0b0dea261b64a4` |
| 契约判据 | `acceptance.md`（AC-001~AC-029，共 **29 条**） |
| 决策记录 | `decisions.md`（D48~D70） |
| 被验对象 | `<package>/skills/test-report/` + `<package>/bin/verify-suite.mjs` |

## 关键设计要点（供 Dev 参考）

- **三层结论**：用例层 / 流程层（证据链）/ 回归层（对账），任一不过 `overall` 不得为 `pass`（D48/D49）
- **`blocked` 绝不计入 `passed`**（对齐 REQ-004 诚实纪律）
- **报告自带指纹 + 绑定输入产物两个指纹**（D51）
- **md 是 json 的渲染**，数字逐字相等（D50）
- **计数从 `results.json` 重算**，不信 `meta.json` 自述（D56）；但两者不符必须**显示**并判 `evidence_layer=fail`（AC-021）
- **证据必须实查**（D55）；**指纹必须重算**（D64）
- **只读消费产物**，只写自己的输出目录（D57）
- **幂等**：除 `generated_at` 外逐字相同（D58）
- **回归对账可选**：不给计划不编造（D52）；`needs_review` 非空 → 回归层不得 pass（D53）；`impact_complete=false` → overall 不得 pass（D54）
- **不得假定 `cycle_id` == 轮次目录名**（D61，承接 REQ-011 L-4）
- **证据层结论结构化**：`evidence.findings[]`（`kind` + `message`）承载证据层的每一条发现（D69）——
  md 散文不承担这个责任（AC-007 / AC-020 / AC-021 全部基于 `findings[]` 判定）
- **md 必须带 `report-digest` 摘要行**（12 个必需键）—— md 数字比对的唯一落点（D66）
- **组合门必须装齐 5 个 skill**（D62）
