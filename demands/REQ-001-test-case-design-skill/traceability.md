# 追溯性矩阵：REQ-001 测试用例设计 Skill + npm 交付包

- **验收人**: QA（独立于实现者）
- **验收日期**: 2026-11-09
- **被测对象**: `feature/REQ-001` 分支（worktree `<REPO_ROOT>/feature-REQ-001`）
- **基线**: develop @ 04589d5

## 验收结论

| AC | 验收点 | 实现位置 | 测试位置 | 结论 |
|----|--------|---------|---------|------|
| AC-001 | npm 包可构建与安装 | `package.json`、`bin/test-agent-skills.mjs` | `npm pack` → `npm install <tgz>` → `npx ... install` → `ls <tmp>/skills/` | PASS |
| AC-002 | 幂等安装不破坏既有条目 | `bin/test-agent-skills.mjs`（install 幂等 + 锁条目 upsert） | 连续 3 次 install；`jq .skills \| keys`；既有条目 diff | PASS |
| AC-003 | skill 结构合规（lint） | `skills/test-case-design/` | `lint-skill.js skills/test-case-design` → exit 0 | PASS |
| AC-004 | SKILL.md frontmatter 语义合规 | `skills/test-case-design/SKILL.md` | 逐条核对 6 项 | PASS |
| AC-005 | 校验脚本检出全部六类缺陷 | `scripts/validate-cases.mjs` | 自造 7 个反例（b1/b2/b3/b4/b5/b5b/b6），逐个 exit=1 | PASS |
| AC-006 | 合规用例集退出 0 并输出覆盖统计 | `scripts/validate-cases.mjs` | 自造 valid.json（2 需求/1 可测/4 用例）→ exit 0，输出含未覆盖 R-2 | PASS |
| AC-007 | 渲染脚本产出追溯矩阵 | `scripts/render-report.mjs` | valid.json → exit 0，输出 3 章节，R-1 已覆盖 / R-2 未覆盖 | PASS |
| AC-008 | 脚本零依赖且跨平台 | `scripts/*.mjs` | grep 无 python3/bash//tmp/grep/sed；import 仅 `node:fs` `node:path` `node:process` | PASS |
| AC-009 | 安装不产生副作用 | `bin/test-agent-skills.mjs` | `~/.bashrc` `~/.zshrc` `~/.profile` mtime+sha 前后一致 | PASS |
| AC-010 | uninstall 只移除本包 skill | `bin/test-agent-skills.mjs`（uninstall） | 隔离根 uninstall → 本包 skill 移除，他人 skill 与锁条目保留 | PASS |
| AC-011 | eval 对比不劣于 baseline | `skills/test-case-design/`（全部） | 双轨 eval：with-skill 44 用例 vs baseline 49 用例；token **1.80×**（未超 2× 上限）；详见 `eval-report.md` | PASS |
| AC-012 | npm 包不发布到公共 registry | `package.json`（无 private、无 publish 脚本） | git 历史无 publish；`npm whoami` 仍为 ENEEDAUTH | PASS |

## 未覆盖

12 条 AC 全部通过，但 **AC-011 的措辞与实测证据有两处偏差**（不影响放行，但需按实测表述）：

1. **AC-011 写「结构化程度优于 baseline」，实测为持平**：with-skill 44/44、baseline 49/49，双方每步都有 action+expected、都有 preconditions、可测试条目覆盖率均 100%。「优于」仅在**需求条目覆盖追溯**一项成立。
2. **AC-011 未规定 token 上限的具体口径**。实测 with-skill / baseline = **1.80×**（未超 2× 上限，余量约 10%）。初版 eval 报告误写为 0.56×，已订正——见 `eval-report.md` §3 订正记录。

## 与 AC 的两点偏差说明

1. **AC-002 的"既有条目与安装前完全一致"**：QA 独立实测确认——既有锁文件在安装前后**字节级无变化**（真实 `~/.agents/.skill-lock.json` 本身即为 2 空格 pretty 格式，安装器 `writeLock` 输出格式与之一致）。初版此处描述的"compact → pretty 格式变化"属多余顾虑，不成立。

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
TEST_AGENT_SKILLS_DIR=<root> npx --prefix <consumer> test-agent-skills install   # ×3，exit 全 0
TEST_AGENT_SKILLS_DIR=<root> npx --prefix <consumer> test-agent-skills list
TEST_AGENT_SKILLS_DIR=<root> npx --prefix <consumer> test-agent-skills uninstall
```

## 遗留风险

以下为 QA 独立验收阶段补充确认的风险，均**不阻断本次放行**：

1. **同名 skill 冲突：`install` 会覆盖同名的非本包 skill**（QA 实测确认）。用户本地若已有其他来源的同名 `test-case-design`，安装会替换其 `SKILL.md`、**删除**源中不存在的用户自有文件（`local-note.txt`），并改写其锁条目为 `sourceType: "npm"`。AC-002 的措辞只约束"其他 skill"（不同名），故不判 AC 失败，但属真实破坏性行为。→ 建议后续 REQ 加同名冲突保护（检测到同名且来源非 npm 时报错退出，而非覆盖）。
2. **误发布风险**：`package.json` 未设 `private: true`，且带 `publishConfig.access: "public"`，一次误操作 `npm publish` 即公开发布。AC-012 明确允许"发布流程留给用户手动执行"分支（README 已写明），故判 PASS。
3. **构建产物未忽略**：worktree 遗留未跟踪的 `test-agent-skills-0.1.0.tgz`，`.gitignore` 未忽略 `*.tgz`，后续 `git add -A` 会将其提交进仓库。→ 合并前清理。
4. **LICENSE 选用 MIT**：仓库无既有许可证，实现者选了 MIT。属项目级决策，需用户确认（改动量约 2 行）。
5. **`derived` 字段缺失**：eval 发现 baseline 自发使用 `requirements[].derived` 标注隐含需求，skill schema 无此概念。已记入 `eval-report.md` 改进建议 1，留待后续 REQ。

## 未验证项

- eval 未重跑（QA 按指示改为审查结论可信性，验证的是数据一致性与报告是否存在选择性呈现）。
- 未在真实 `~/.agents/skills/` 下安装（全程 `TEST_AGENT_SKILLS_DIR` 隔离，避免污染用户 git 仓库）。
- Windows / macOS 实际运行未验证（AC-008 为源码层静态核查：零第三方依赖、无平台相关调用）。
