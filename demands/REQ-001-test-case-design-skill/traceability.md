# 追溯性矩阵：REQ-001 测试用例设计 Skill + npm 交付包

- **验收人**: QA（独立于实现者）
- **验收日期**: 2026-11-09
- **被测对象**: `feature/REQ-001` 分支（worktree `<REPO_ROOT>/feature-REQ-001`）
- **基线**: develop @ 04589d5

## 验收结论

| AC | 验收点 | 实现位置 | 测试位置 | 结论 |
|----|--------|---------|---------|------|
| AC-001 | npm 包可构建与安装 | `package.json`、`bin/internal-rt-test-agent-skills.mjs` | `npm pack` → `npm install <tgz>` → `npx ... install` → `ls <tmp>/skills/` | PASS |
| AC-002 | 幂等安装不破坏既有条目 | `bin/internal-rt-test-agent-skills.mjs`（install 幂等 + 锁条目 upsert） | 连续 3 次 install；`jq .skills \| keys`；既有条目 diff | PASS |
| AC-003 | skill 结构合规（lint） | `skills/test-case-design/` | `lint-skill.js skills/test-case-design` → exit 0 | PASS |
| AC-004 | SKILL.md frontmatter 语义合规 | `skills/test-case-design/SKILL.md` | 逐条核对 6 项 | PASS |
| AC-005 | 校验脚本检出全部六类缺陷 | `scripts/validate-cases.mjs` | 自造 7 个反例（b1/b2/b3/b4/b5/b5b/b6），逐个 exit=1 | PASS |
| AC-006 | 合规用例集退出 0 并输出覆盖统计 | `scripts/validate-cases.mjs` | 自造 valid.json（2 需求/1 可测/4 用例）→ exit 0，输出含未覆盖 R-2 | PASS |
| AC-007 | 渲染脚本产出追溯矩阵 | `scripts/render-report.mjs` | valid.json → exit 0，输出 3 章节，R-1 已覆盖 / R-2 未覆盖 | PASS |
| AC-008 | 脚本零依赖且跨平台 | `scripts/*.mjs` | grep 无 python3/bash//tmp/grep/sed；import 仅 `node:fs` `node:path` `node:process` | PASS |
| AC-009 | 安装不产生副作用 | `bin/internal-rt-test-agent-skills.mjs` | `~/.bashrc` `~/.zshrc` `~/.profile` mtime+sha 前后一致 | PASS |
| AC-010 | uninstall 只移除本包 skill | `bin/internal-rt-test-agent-skills.mjs`（uninstall） | 隔离根 uninstall → 本包 skill 移除，他人 skill 与锁条目保留 | PASS |
| AC-011 | eval 对比不劣于 baseline | `skills/test-case-design/`（全部） | 双轨 eval：with-skill 44 用例 vs baseline 49 用例；token 0.56×；详见 `eval-report.md` | PASS |
| AC-012 | npm 包不发布到公共 registry | `package.json`（无 private、无 publish 脚本） | git 历史无 publish；`npm whoami` 仍为 ENEEDAUTH | PASS |

## 未覆盖

无 12 条 AC 全部通过。

## 与 AC 的两点偏差说明

1. **AC-002 的"既有条目与安装前完全一致"**：实际比对结果为**内容一致、JSON 缩进格式变化**（单行 compact → 多行 pretty）。条目字段值（source / sourceType / sourceUrl / skillPath / skillFolderHash / installedAt / updatedAt）逐字段相同，`diff` 仅显示格式差异。判定为 PASS——AC 的意图是"既有条目不被破坏"，格式重排不构成破坏。

2. **AC-012 的解读**：验收标准写的是「`private` 为 `true` **或** 发布流程明确留给用户手动执行」。实现走的是后一条分支——`package.json` 未设 `private`（最终要能发布），README 中明确写明 `npm login` / `npm publish` 由用户自行执行，仓库内无任何 publish 脚本或自动化。判定为 PASS。

## 验证命令留痕

```bash
# lint
node <HOST_RUNTIME_DIR>/.builtin-skills/skill-creator/scripts/lint-skill.js skills/test-case-design
# → ✓ All checks passed (exit 0)

# 校验器反例矩阵（自造，非实现者提供的夹具）
for f in b1 b2 b3 b4 b5 b5b b6; do node scripts/validate-cases.mjs $f.json; done
# → 全部 exit=1，分别报出：重复ID / 缺title / 悬空引用R-99 / 非法枚举 / steps空 / 缺expected / JSON语法错误

# npm 端到端
npm pack && npm install --prefix <consumer> <tgz>
INTERNAL_RT_SKILLS_DIR=<root> npx --prefix <consumer> internal-rt-test-agent-skills install   # ×3，exit 全 0
INTERNAL_RT_SKILLS_DIR=<root> npx --prefix <consumer> internal-rt-test-agent-skills list
INTERNAL_RT_SKILLS_DIR=<root> npx --prefix <consumer> internal-rt-test-agent-skills uninstall
```

## 遗留风险

1. **LICENSE 选用 MIT**：仓库无既有许可证，实现者选了 MIT。属项目级决策，需用户确认（改动量约 2 行）。
2. **同名 skill 冲突策略**：`install` 会覆盖同名的非 npm 来源 skill 目录并改写其锁条目；`uninstall` 则跳过不动。AC 未覆盖该场景，当前行为为"npm 包优先"。
3. **`derived` 字段缺失**：eval 发现 baseline 自发使用 `requirements[].derived` 标注隐含需求，skill schema 无此概念。已记入 `eval-report.md` 改进建议 1，留待后续 REQ。
