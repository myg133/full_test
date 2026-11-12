# REQ-011 状态 —— R2 回归轮 `regression-plan` skill + 套件层组合门

- **状态**: 进行中
- **认领**: 未认领（待派 Dev，worktree `feature-REQ-011`）
- **分支**: `feature/REQ-011`（未创建）
- **依赖**: REQ-006（维度库/方法库，唯一来源）、REQ-004（`test-execute` + 跨 skill 依赖路径）、REQ-002.5a（`cycle-state.mjs`）、REQ-002A（schema v2）、REQ-002B（目录契约）、REQ-003（`qa-toolchain`，组合门一并安装）
- **下游**: REQ-010（`test-report` 要消费 `regression-plan.json` → 本 REQ 的输出形状是它的输入契约）

## 进度

| 项 | 状态 |
|---|---|
| 需求文档 | 完成（`demand.md`） |
| 决策记录 | 完成（D35~D44） |
| 验收标准 | 完成（AC-001~AC-028，共 **28 条**，自包含） |
| 验收脚本 | 完成（干跑通过：快跑 28/0、完整模式 28/0、AC-025 变异体 8/8） |
| 实现 | 待派 Dev |
| 独立验收 | 未开始 |
| 收口 | 未开始 |

## 下一步

1. **写验收脚本** `verify-acceptance.sh`（28 条判据 + 8 个变异体）
2. **干跑**（派工前的前置条件）：先用一份**模拟实现**跑穿 25 条 → 修掉脚本自身的恒红缺陷 → 再用**真实实现**跑一遍确认变异体 8/8 可检出
3. **登记开单**（`req-registry.md` 的 REQ-011 行 → 进行中）+ 认领 + 建 worktree/分支
4. **派工 Dev**：实现 `skills/regression-plan/` + 套件层组合门（`bin/test-agent-skills.mjs` 的组合校验子命令 + 四个 skill 的 `skill-meta.json`）
5. **BA 侧复跑**：主验收 + 上游三条回归（REQ-006 主验收 / 002A / 002B）
6. **独立验收**：验收方自造探针攻 25 条判据
7. **收口**：合并 develop → 登记表 → 需求状态 → 重装已装副本 → 回收 worktree → 巡检

## 验收判据版本

| 项 | 值 |
|----|----|
| 验收脚本 | `verify-acceptance.sh`（本目录） |
| 当前 sha256 | `54efde3477e68f1aa70e9bdd4770873d0cd7a4216d8638f846c5daac69e5bd4a` |
| 契约判据 | `acceptance.md`（AC-001~AC-028，共 **28 条**） |
| 决策记录 | `decisions.md`（D35~D44；本 REQ 链自 D35 起） |
| 被验对象 | `<package>/skills/regression-plan/` + `<package>/bin/` |

**任何"脚本全绿的结论都必须钉版本** —— 同一批变异体在不同版本的脚本上结论可以不同（D34）。

## 与既有 REQ 的关系

- 本 REQ **不改** `test-case-design` 的任何文件 → REQ-006 的 42 条判据必须**原样继续全绿**，作为上游回归。
- 本 REQ **不改** `code/feature-meta/` 根目录的三份文件（REQ-006 的追溯链）→ 本 REQ 的追溯件写进 `code/feature-meta/regression-plan/` 子目录（D39 ③）。
- REQ-006 的主验收脚本与 002A / 002B 两条回归**继续是门禁**，本 REQ 不取代它们。

## 状态历史

| 时间 | 状态 | 交付 | 说明 |
|---|---|---|---|
| 2026-11-12 22:0x | 进行中 | 需求文档 | **REQ-011 建单**：需求文档 + 决策 D35~D40 + 判据集 25 条（AC-001~AC-025） |
