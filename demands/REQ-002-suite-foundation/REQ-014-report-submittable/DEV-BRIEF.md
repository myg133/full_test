# REQ-014 · Dev 派单

> **契约**：`BA/demands/REQ-002-suite-foundation/REQ-014-report-submittable/`
> （`demand.md` / `acceptance.md`（20 条判据）/ `decisions.md`（D211~D218）/ `verify-acceptance.sh`）
> **验收门 sha256**：`d07e810e904f7ad30c0fc567039881ea45e175936f342449069ab01e70142091`
> **被验包根**：你的 worktree 根（`skills/` `bin/` `README.md` `LICENSE` `package.json` `feature-meta/`）

---

## 1. 为什么有这活（用户实机反馈）

用户在 `/home/myg133/Projects/Anchnet/YF-test/` 做功能测试，跑完发现三件事：

1. **报告落在提交不了的地方** —— 工具默认输出到 `<run_dir>/report/`，而 `run_dir` 在
   `.test-artifacts/` 下，**该目录被项目 `.gitignore` 忽略**；
2. **报告提交后证据全丢** —— `report.json` 里证据是**路径引用**，指向被忽略的目录；
3. **报告里有明文口令与本机绝对路径** —— `reproduction.command` 里
   `"password":"PlainTextPwd123"` 没脱敏；`source.artifacts` 是绝对路径。

用户拍板：输出到 `<项目根>/reports/<run_id>/` + **证据内容内联进 `report.json`** +
**报告内一律脱敏**。

---

## 2. 你要交付什么

**只改 `skills/test-report/`** 下的文件（+ 必要的 `references/` 文档）。
**不许**改 `test-execute` / 其他 skill、不许改 `feature-meta/`、不许改 `package.json` 的版本号。

### 2.1 三件事

| # | 做什么 | 判据 |
|---|---|---|
| ① | **输出位置**：默认输出到 `<项目根>/reports/<run_id>/`；`--project-root` 显式指定；从 run_dir 形态 `<root>/.test-artifacts/<id>` 反推；两条都不成立 ⇒ **报错退出 rc=1 并点名 `--project-root`（不许猜）**；`--out-dir` 仍能完全覆盖 | AC-001~AC-005 |
| ② | **证据内联**：`report.json` 新增 `evidence.files[]`，每条 **8 个键**（`case_id`/`step`/`path`/`sha256`/`bytes`/`media_type`/`content`/`content_sha256`）；`content` = **脱敏后的原始文本**（不是解析后对象）；`path` **相对项目根**；`sha256` 是**实算**的原文件指纹；md 里也要**内联内容** | AC-006~AC-011 |
| ③ | **一律脱敏**：敏感**字段名**整值替换 → `[REDACTED:field]`；**值模式**（内嵌 JSON 口令 / `Bearer xxx` / `user:pass@` / 长 hex）→ `[REDACTED:secret]`；**绝对路径** → 相对项目根；报告新增 `redaction` 段（`rules_applied` / `redacted_fields` / `redacted_values`）**如实计数** | AC-012~AC-017 |

### 2.2 两条最容易做错的

**① `content` 必须是「脱敏后的原始文本」，不是「解析后重新序列化」。**
理由：这样无敏感内容的文件才能满足 **`content_sha256 == sha256`（严格相等）** ——
这条不变量既是「脱敏器不误伤」的机械证明（AC-011），也让读者能一眼看出「文件没被动过」。
⇒ 做法：**先按原始字节读入 → 尝试解析 → 脱敏 → 如果脱敏后与脱敏前等价，就保留原始文本不动**。

**② `failures[].evidence[]` 保持既有语义不变**（逐字取自产物）。
本 REQ 只做**增量**：新加的 `evidence.files[]` 才是「实查 + 内联」的权威视图。
不要顺手改 `failures[]` 的形状 —— 那会牵连 REQ-010 的 AC-013。

---

## 3. 关键决策（不可自行推翻；有问题回来问）

| 决策 | 内容 |
|---|---|
| D211 | 默认输出改到项目根，**显式取代** REQ-010 的 AC-025 ① |
| D212 | 项目根三段式定位，**不猜** |
| D213 | `content` 用脱敏后的**原始文本**（字节级保真） |
| D214 | **被测 IP / 端口 / 用户名保留**（是被测对象标识与业务账号，不是凭证）；已登记遗留项 L-02 |
| D215 | `failures[].evidence[]` **不改** |
| D216 | `redaction` 计数**如实**填；产物无敏感内容时写 0，**不许虚报** |
| D217 | **不改 `test-execute`**（根因在产物生成侧，已登记遗留项 L-01）；报告侧做纵深防御 |
| D218 | **不跨 skill import** —— 脱敏器在 `test-report` 内**自包含**实现（REQ-010 的 AC-026 硬判据：相对 import 只许指向本 skill 内） |

---

## 4. 参考实现（scratch，**不入交付包**）

门已按 D65 自测过（D88：参考实现只放 scratch）。**它是一份能跑通 20/20 的参考实现**：

```
~/.local/share/mavis-data/tmp/req014/refimpl/make-report.mjs
```

它的工作方式是「现有实现 + 后处理」：调 `lib/analyze.mjs` 造基础报告 ⇒ 改输出位置 ⇒
扫描并内联证据 ⇒ 全报告脱敏 ⇒ 重算 `report_sha256` ⇒ 渲染 md 并追加证据段。

**你可以参考它的思路，但不要照抄**：交付实现应当是**原生实现**（把能力做进
`lib/` 里，而不是在入口做后处理）—— 后处理式实现会让 `report_sha256` 的口径、
md 的渲染、幂等性都更难保证。

⚠️ 参考实现里的脱敏器是**最小可用版**，正式实现至少要覆盖：
字段名名单（大小写与分隔符不敏感）、内嵌 JSON 形态、`Bearer`、URL userinfo、长 hex，
并且**逐条**给出规则名（`redaction.rules_applied`）。

---

## 5. 怎么自测

```bash
# ① 单元自测（你自己写，放 scripts/ 下，并在 SKILL.md 里登记）
cd <worktree>/skills/test-report && node scripts/selftest-<你的名字>.mjs

# ② 验收门（快跑）
G=/home/myg133/Projects/full_test/BA/demands/REQ-002-suite-foundation/REQ-014-report-submittable/verify-acceptance.sh
export QA014_SCRIPT_SHA=d07e810e904f7ad30c0fc567039881ea45e175936f342449069ab01e70142091
export QA014_WORK_ROOT=~/.local/share/mavis-data/tmp/req014/dev-quick
export REQ014_NO_MUT=1
bash "$G" <你的 worktree 根>

# ③ 验收门（完整模式，含变异体）—— **交付前必须跑**
export QA014_WORK_ROOT=~/.local/share/mavis-data/tmp/req014/dev-full
unset REQ014_NO_MUT
bash "$G" <你的 worktree 根>
```

**门的目标数字**：**20 PASS / 0 FAIL / 0 不可判定** + 变异体 **7/7 检出** + **负控未检出**。

⚠️ **不要用旧 sha**：门改过（自测时修了 5 处门侧缺陷），以本派单里的 sha 为准。
门 sha 不匹配 ⇒ 门直接判红并中止（这是设计，不是 bug）。

---

## 6. 硬约束

1. **零第三方依赖、不联网**（沿用 REQ-010 AC-026）；
2. **相对 import 只许指向本 skill 内**（同上）；
3. **只读**消费输入产物，**绝不**写输入产物目录里的任何文件（含证据原文件）；
4. **不产出半份报告**：输入非法 / 项目根定位失败 ⇒ rc=1 且**不留下** `report.json` / `report.md`（0 字节也算存在）；
5. **幂等**：同一输入两次出报告，除 `generated_at` 外**逐字相同**；
6. **`report_sha256` 口径照 `lib/canonical.mjs`**（剔除 `generated_at` 与 `report_sha256`，
   键名码位升序、数组保序、无空白、UTF-8 sha256）—— 你新增了字段，**必须重算**；
7. **不许把被测的证据内容截断 / 摘要** —— `content` 必须是完整原文（脱敏后）。

---

## 7. 交付

1. 改动落在 **develop 的 feature worktree**（`feature/REQ-014`），**提交**（格式：
   `[feat] {描述} (关联: REQ-014) [session: mvs_744b60ef3d984cffbcd54448ac77bd8c]`）；
2. 提交前跑 **① ② ③** 三项自测，把**真实输出**贴回来；
3. `git show --stat HEAD` + `git status --short` 贴回来；
4. 更新 `skills/test-report/SKILL.md`：
   - 「入口命令」小节写清**新的默认输出位置**与 `--project-root`；
   - 「硬约束」小节补上「证据内联」「报告内脱敏」两条；
   - 目录树补上新增的 `scripts/` 文件；
5. 更新 `skills/test-report/references/report-schema.md`：
   - 补 `evidence.files[]` 的 8 个字段契约；
   - 补 `redaction` 段的 3 个字段契约；
   - 写清 `sha256` 与 `content_sha256` 的关系；
6. **不许**改 `acceptance.md` / `decisions.md` / `verify-acceptance.sh`（那是契约，门归 BA）。

---

## 8. 有疑问怎么办

- 契约有歧义 ⇒ **问**，别猜（这正是 D212 的同一条纪律）；
- 你认为某条判据**不可满足**或**恒真** ⇒ **说出来并给出证据**，别硬凑一个假实现
  （本仓有过「把正确实现判红」的教训，见 REQ-013 的 AC-014 修订）；
- 想改契约 ⇒ 先说，**由 BA 改**，你只改被验交付物。
