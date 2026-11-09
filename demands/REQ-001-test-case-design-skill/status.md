# 状态：REQ-001 测试用例设计 Skill（首期）+ npm 交付包

- **状态**: 已完成
- **更新者**: ba-local-ba-20261109161500
- **更新时间**: 2026-11-09 16:50

## 状态历史

| 时间 | 从 | 到 | 操作者 | 备注 |
|------|----|----|--------|------|
| 2026-11-09 16:12 | — | 草稿 | ba-local-ba-20261109161500 | 创建需求文档 |
| 2026-11-09 16:15 | 草稿 | 已就绪 | ba-local-ba-20261109161500 | 12 条 AC 全部可机械验证，判定已就绪 |
| 2026-11-09 16:19 | 已就绪 | 进行中 | ba-local-ba-20261109161500 | 认领 REQ-001，派 2 个 Dev 子 agent 并行实现 |
| 2026-11-09 16:41 | 进行中 | 待验证 | ba-local-ba-20261109161500 | 实现完成（143bbc0 + 6c30209），eval 双轨对比通过 |
| 2026-11-09 16:45 | 待验证 | 已验证 | qa | QA 独立验收 12/12 PASS，发现 eval 报告 token 归属错误 |
| 2026-11-09 16:50 | 已验证 | 已完成 | ba-local-ba-20261109161500 | 订正 eval 报告，合并 develop（0881aaf），post-merge 验证通过 |

## 阻塞项

（无）

## 交付位置

- **npm 包**: `internal-rt-test-agent-skills@0.1.0`（包根在 develop 分支，即 `code/` worktree）
- **skill 安装目标**: `~/.agents/skills/test-case-design/`
- **安装命令**: `npm install -g internal-rt-test-agent-skills && internal-rt-test-agent-skills install`
- **发布**: 未执行（需用户 `npm login` 后自行 `npm publish`）

## 范围外备忘

- 接口测试 / UI 测试 / 缺陷报告三个能力域留待后续 REQ，本 REQ 未预留其代码骨架。
- npm publish 需用户 `npm login` 后自行执行。

## 后续 REQ 候选（来自 eval 与 QA 发现）

1. schema 增加 `requirements[].derived` 字段（标注隐含需求）
2. `design-methods.md` 补"服务端校验加固"套路
3. `design-methods.md` 补"并发度设计"指引（并发次数需足够高才有意义）
4. `design-methods.md` 补精度/舍入类需求的样本选取指引（进位/舍去/极小值三方向）
5. schema 增加正式的 `notes` 字段（替代权宜的 `data.备注`）
6. 安装器增加同名非本包 skill 的冲突保护（当前会覆盖目录并删除用户自有文件）
7. `package.json` 补 `private: true` 或移除 `publishConfig.access: "public"`
8. 后续能力域：接口测试执行 skill / UI 端到端测试执行 skill / 缺陷报告与质量报告 skill
