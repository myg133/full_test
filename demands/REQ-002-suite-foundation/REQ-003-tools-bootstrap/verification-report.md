# REQ-003 独立验收报告 —— `.tools` 工具链自举机制

> 编号说明：本 REQ 原编号 `REQ-002.4`，因 `aw.py` 的 worktree/分支命名规范要求三位扁平号，
> 已改为 `REQ-003`（原号作废、不再复用）。下文提到分支 `feature/REQ-002.4` 均为改号前的历史名称。

- **验收对象**：`feature-REQ-003` 分支（`feature/REQ-003`，HEAD `6a4dc41`）
  - `bin/qa`（薄启动器）、`bin/qa-impl.mjs`（主实现，1580 行）
  - `skills/qa-toolchain/SKILL.md`
  - `skills/qa-toolchain/references/tools-chain-contract.md`
- **验收人**：独立验收方（未采信开发者自验结论，未使用 BA 的 `verify-acceptance.sh` 作为判定依据）
- **验收日期**：2026-11-11
- **测试工作区**：`/tmp/qa-verify-0024/`（全部临时产物在 `/tmp`，未写入仓库；交付分支只读，`git status` 干净、未 commit/merge/push）
- **基线镜像**：`/tmp/qa-verify-0024/impl`（交付物副本，md5 与分支内一致：`ac49b475c2e9121fed446882f7a52a79`）

---

## 1. 结论

| 维度 | 计数 | 说明 |
|---|---|---|
| AC-001 ~ AC-016 独立判定 | **16 PASS / 0 FAIL** | 全部用自建断言实测，未用 BA 脚本 |
| 独立 harness 断言总数 | 94 | 93 条 AC 相关断言 PASS + 1 条附加安全探测**命中缺陷** |
| 变异测试 | **5 条变异 × 2 项断言 = 14 PASS / 0 FAIL** | 5 条护栏**全部是真护栏**，基线能拦、变异能测出差异 |
| BA 验收脚本 | 16 PASS / 0 FAIL（对未变异基线） | 但存在 **2 项假 PASS** + 4 项改进点 |

**是否建议合并：有条件合并。**

- 核心机制成立：四种状态真实可达且互不串、D1 分界按根因执行、版本锁定/路径越界/白名单/`doctor` 只读/**5 条护栏经变异测试证明全部有效**（不是假护栏）。
- 合并前**必须**处理 **P1-1**（`entry` 字段路径穿越 → `qa run` 可执行 `.tools/` 之外的任意文件）与 **BA-001 / BA-002**（BA 脚本两项假 PASS，会让后续回归漏网）。
- P2 项可作为跟进项，但 **BA-001（AC-014 自证式）** 与 **BA-002（AC-013 假 PASS）** 建议同批修复，否则 BA 脚本的"16 PASS"不能作为回归防线。

---

## 2. 逐条 AC 独立判定

> 每条都记录**我实际做的操作**与**观察到的输出摘要**。测试项目一律造在 `/tmp/qa-verify-0024/work/` 下。
> 断言脚本：`/tmp/qa-verify-0024/t_core.mjs`（日志 `/tmp/qa-verify-0024/run3.log`）。

### AC-001 `bin/qa` 在包内且可执行 —— PASS
- 操作：`cd /tmp/qa-verify-0024/impl && npm pack --dry-run`；`node bin/qa --help`。
- 观察：pack 清单含 `bin/qa`、`bin/qa-impl.mjs`；`--help` 退出码 0，输出含 `init / list / doctor / install / run / which / isolation` 全部 7 个子命令；`bin/qa` 权限位 `-rwxr-xr-x`。

### AC-002 `qa list` 列出清单与状态 —— PASS
- 操作：清单声明 `pyflakes`（python）+ `semver`（node），`qa --project <P> list`。
- 观察：退出码 0；表格两行分别为 `missing pyflakes python pyflakes==3.2.0 -` 与 `missing semver node semver@7.7.2 -`。

### AC-003 `qa doctor` 区分四种状态 + D1 分界 —— PASS
- 操作：本地端口造三种源（① 起过又关掉的死端口 ② 活着的 404 服务 ③ 活着的 500 服务，均由**独立进程**提供，避免父进程事件循环阻塞导致误判），外加 `node` 路线"包名不存在"的真失败；`missing` 用另一个只体检不安装的项目取。
- 观察（`qa doctor` 原文锚定到 `[status] tool` 行）：

```
[ok] pyflakes（python, pyflakes==3.2.0）
[failed] broken（node, broken@1.0.0）  —— 安装命令失败（退出码 1）：error: No version matching "1.0.0" found for specifier "broken"
[unavailable] unreachable-xyz（binary, 1.0.0）  —— 下载源不可达（http://127.0.0.1:41677/tool-linux-amd64）：fetch failed
[failed] notfound-xyz（binary, 1.0.0）  —— 下载源返回 HTTP 404（http://127.0.0.1:42523/tool-linux-amd64）
[unavailable] err500-xyz（binary, 1.0.0）  —— 下载源返回 HTTP 500（http://127.0.0.1:34293/tool-linux-amd64）
[missing] semver（node, semver@7.7.2）  —— 未安装
```
- 判定：四种状态全部可达且**互不串**；D1 分界精确成立——**连接被拒 → unavailable**，**404 → failed**，**5xx → unavailable**；sha256 不匹配 → **failed**（单独场景实测）；doctor 退出码非 0。

### AC-004 版本锁定强制 —— PASS
- 操作：清单 `spec` 分别取 `bandit>=1.7`、`bandit@latest`、`bandit^1.7`、`bandit==1.7.*`、`bandit==latest`、`semver@latest`、`semver@^7`、`semver@>=7`、binary `latest`/`>=1.0`/`^1.0`，各跑一次 `qa install`。
- 观察：全部退出码 ≠ 0，报错含「版本未锁定」；且**未创建 `.tools/.venv`**（校验发生在安装流程之前，清单不进入安装）。

### AC-005 安装路径不得越界 —— PASS
- 操作：11 种越界向量（`--user` / `--system` / `--prefix` / `--root` / `--target 外部` / `sudo` / `--prefix=` / `..` / 外部绝对路径 / `~` / `-g`）逐个 `qa install`；并在前后对真实 `~/.local/lib` 做目录树 md5 比对。
- 观察：全部退出码 ≠ 0 且报「安装路径越界」；**真实 `~/.local` 前后 md5 完全一致**（`b22018…` 不变）；未创建 `.venv`。
- 反向不误杀：`--target {tools}/pylibs`（指向 `.tools/` 内部）**未被拒**（这条说明校验不是"见 target 就杀"）。

### AC-006 Python 工具装进 `.venv` 且不污染系统 —— PASS
- 操作：`qa install`（`pyflakes==3.2.0`，`uv pip install --no-deps`，`VIRTUAL_ENV` 指向 `.tools/.venv`）；随后跑**系统** `python3 -c "import pyflakes"` 与 `command -v pyflakes`。
- 观察：`.tools/.venv` 存在、`.tools/.venv/bin/pyflakes` 生成；系统侧 import 失败（退出码非 0）、`command -v pyflakes` 无输出。

### AC-007 Node 工具装进 `.tools/node` 且不污染系统 —— PASS
- 操作：`qa install`（`semver@7.7.2`，`bun add`）；`command -v js-yaml/semver` 与 `npm ls -g --depth=0`。
- 观察：`.tools/node/node_modules/.bin/semver` 生成；系统全局 npm 包清单前后**逐字相同**（`mmx-cli / node-gyp / nopt / npm / pnpm / pyright / semver@7.8.5`）。

### AC-008 `qa which` 指向 `.tools/` 内路径 —— PASS
- 操作：`qa which semver`。
- 观察：退出码 0，输出 `/tmp/qa-verify-0024/work/p6/.tools/node/node_modules/.bin/semver`（在 `.tools/` 之下）。

### AC-009 `qa run` 是白名单式的 —— PASS（**但见 P1-1**）
- 操作：① PATH 前置一个会留痕（`touch marker`）的假可执行 `eviltool`，跑 `qa run eviltool -- --version`；② 跑系统真实命令 `qa run ls -- -la`。
- 观察：两次均退出码 ≠ 0、报「工具 "x" 不在清单中……白名单式，不接受任意命令」，且**留痕文件未生成**（命令确实没被执行）。
- **限定条件**：白名单只约束"名字"，不约束"被执行的二进制在哪儿"——清单里写 `entry: "../../evil.sh"` 就能执行 `.tools/` 之外的任意文件（P1-1）。

### AC-010 `qa run` 执行的是 `.tools/` 里那份 —— PASS
- 操作：本机系统 `/usr/bin/semver` = **7.8.5**，`.tools/` 内装 **7.7.2**；跑 `qa run semver -- --help`。
- 观察：输出 `SemVer 7.7.2`，且运行行 `[run] semver -> /tmp/.../.tools/node/node_modules/.bin/semver --help` —— 确认跑的是 `.tools/` 副本，不是系统那份。
- 附带观察（符合契约）：`qa run semver -- --version` 时 semver CLI 自身退出码为 1，`qa run` 如实透传退出码 1。

### AC-011 工具不可用不得静默跳过 —— PASS
- 操作：清单放一个 binary 工具，URL 指向死端口；`qa install` 后 `qa doctor`。
- 观察：`install` 退出码 1、`doctor` 退出码 1；状态行 `[unavailable] unreachable-xyz（binary, 1.0.0）  —— 下载源不可达（…）：fetch failed`；输出中**无"跳过"字样**；失败原因写进了 `state.json`（`status: unavailable` + `reason`）。

### AC-012 安装幂等 —— PASS
- 操作：装好后对 `state.json` 取 md5，再跑一次 `qa install`，再次取 md5 并比对。
- 观察：二次退出码 0，输出「[skip] pyflakes pyflakes==3.2.0 已安装，跳过（幂等，不重复下载）」；`state.json` **逐字节未变**（md5 相同，`writeState` 剥掉 `updated_at` 后比较）。

### AC-013 `state.json` 记录版本与来源 —— PASS
- 操作：读 `<PROJ>/.tools/state.json`。
- 观察：`pyflakes` 条目含 `name:"pyflakes"`、`version:"3.2.0"`、`spec:"pyflakes==3.2.0"`（与清单一致）、`source:"uv"`、`source_detail.source`（索引地址）、`installed_at`（ISO 时间）、`checksum`、`size_bytes`、`status:"ok"`。
- 限定：`source_detail.source` 的取值来源见 **P2-1**（可能与实际抓取源不符）。

### AC-014 `.gitignore` 精确忽略、manifest 进 Git —— PASS
- 操作：造含 `.tools/.venv/x` 的项目 → `git init && git add -A` → `git check-ignore -v .tools/.venv/x` / `git check-ignore .tools/manifest.json` / `git status --porcelain -uall`。
- 观察：`.venv/x` 被忽略（命中 `.tools/*` 规则）；`manifest.json` **未被忽略**且出现在待提交列表。
- 反例验证（证明这条规则确实关键）：把 `.gitignore` 写成 `.tools/` 后，`git status -uall` 中**确实看不到 manifest.json**（静默丢失）——与 D4 一致。
- 交付物侧另测：`qa init` 生成的 `.gitignore` 含 `.tools/*` + `!.tools/manifest.json`，**不含** `.tools/`；重复 `qa init` 幂等（输出「未重复写入」）。

### AC-015 零依赖 + 退出码语义 —— PASS
- 操作：正则扫描 `bin/qa-impl.mjs` 的 `from '…'` 导入；读 `package.json` 的 `dependencies`；分别触发四类退出码。
- 观察：全部导入均为 `node:` 内置或相对路径（第三方依赖数 = 0）；`package.json` 无 `dependencies`；退出码：**0**（`qa list` 正常）、**1**（`qa doctor` 有不可用项 / 清单缺失）、**2**（未知子命令、缺参数）、**1**（清单非法）。

### AC-016 全部交付文件进 npm 包 —— PASS
- 操作：`npm pack --dry-run` 全量清单逐文件核对。
- 观察：`bin/qa`、`bin/qa-impl.mjs`、`skills/qa-toolchain/SKILL.md`、`skills/qa-toolchain/references/tools-chain-contract.md` **全部在包内**。

### 附加探测（不属于 AC，命中缺陷）
- **P1-1**：`entry` 路径穿越 —— 详见 §5-P1-1。

---

## 3. 变异测试结果表

> 方法：每条变异先在**未变异的基线**上确认"能拦住"，再把变异注入 `/tmp` 的副本（交付分支未动），确认"能测出差异"。
> 变异脚本：`/tmp/qa-verify-0024/t_mutate.mjs`（日志 `result-mut.json`）。

| # | 变异内容（破坏契约哪条"必须"） | 基线是否拦住 | 变异后是否测出差异 | 证据摘要 |
|---|---|---|---|---|
| M1 | 删掉**版本锁定检查**（`validateManifest` 的 spec 校验 + `cmdInstall` 的 `parseSpecVersion` 守卫，两处都删） | ✅ 拦住：退出码 ≠ 0，报「版本未锁定」，且 `.venv` 未生成 | ✅ 测出：变异体真的执行了 `uv pip install --no-deps pyflakes>=3.2`，装成并 verify 通过 | 基线 `[error] 工具 bandit 版本未锁定` → 变异 `[ok] pyflakes 3.2. 已安装并通过验证` |
| M2 | 删掉**安装路径越界检查**（两处都删），清单改成 `pip install --no-deps --target /tmp/qa-verify-0024/pollute {spec}` | ✅ 拦住：退出码 ≠ 0，报「安装路径越界」，`.tools/` 之外零写入 | ✅ 测出：变异体把包真装到了 `/tmp/qa-verify-0024/pollute/`（`six.py` + `six-1.17.0.dist-info/`），即写出 `.tools/` | 基线 `安装路径越界` → 变异 `pip install --no-deps --target /tmp/.../pollute six==1.17.0` 成功（污染已清理） |
| M3 | 删掉 **`qa run` 白名单**（找不到清单项时不再拒绝，改为从 `PATH` 解析可执行文件） | ✅ 拦住：退出码 ≠ 0、报「不在清单」、**无执行痕迹** | ✅ 测出：变异体执行了 PATH 里的 `eviltool`，留痕文件被创建 | 基线 `[error] 工具 "eviltool" 不在清单中` → 变异 `eviltool` 实际执行（marker 生成） |
| M4 | 把 **`.gitignore` 规则**写坏：`GITIGNORE_RULES` 改成 `['.tools/', '!.tools/manifest.json']`（D4 明令禁止的写法） | ✅ 拦住：`qa init` 写的是 `.tools/*` + 例外规则；清单未被忽略、能进 Git | ✅ 测出：变异体写出的 `.tools/` 让 `git check-ignore .tools/manifest.json` 命中、清单静默消失 | 基线清单进 Git → 变异清单被忽略 |
| M5 | 让 **`qa doctor` 触发安装**（违反 D3） | ✅ 拦住：`doctor` 后 `.tools/` 树逐项比对无变化、未生成 `.venv`/`state.json` | ✅ 测出：变异体 doctor 生成了 `.venv` 与 `state.json` | 基线 `doctor` 后树不变 → 变异 `doctor` 改动状态 |

**结论：5 条护栏全部为"真护栏"**——每条都能被独立检出，没有假护栏。M2 的污染被限制在 `/tmp`（`HOME` 隔离 + 指定 `--target` 目录），事后已删除；真实 `~/.local`、`/usr`、全局 npm 目录前后逐字比对无变化。

---

## 4. BA 验收脚本质量评估（含假 PASS 风险）

脚本：`BA/demands/REQ-002-suite-foundation/REQ-003-tools-bootstrap/verify-acceptance.sh`（279 行）。

### 4.1 总体评价
- **写得比一般验收脚本好**：AC-003 已按要求改成"逐工具锚定状态行"（`has_state()` 用 `^\[$2\] $3(（|$)` 匹配 `[status] tool` 行），而不是全文 grep；404/不可达用本地端口造、不依赖外网；AC-005/AC-011 都先确认"清单合法"再测"装不上"路径；对未变异基线跑出 **16 PASS / 0 FAIL**，与开发者自验结论一致。
- **但它的检验力有盲区**：我拿 5 个突变体 + 2 个额外突变体反测它，**有 2 处明确的假 PASS**（BA-001 / BA-002），另有一处 grep 脆弱（BA-003）。

### 4.2 反测结果（BA 脚本 × 变异体）

| 变异体 | BA 脚本结果 | 评价 |
|---|---|---|
| M1 去版本锁定 | **FAIL AC-004** → 14 PASS / 2 FAIL | ✅ 有检验力 |
| M2 去越界检查 | **FAIL AC-005** → 14 PASS / 2 FAIL | ✅ 有检验力 |
| M3 去白名单 | **FAIL AC-009**（+ AC-006/012 连累）→ 12 PASS / 4 FAIL | ✅ 有检验力 |
| M4 写坏 `.gitignore` | **16 PASS / 0 FAIL** | ❌ **假 PASS（BA-001）** |
| M5 doctor 触发安装 | **FAIL AC-003** → 15 PASS / 1 FAIL | ⚠️ 抓到，但是"顺带"抓的（因为 doctor 把 missing 工具装成了 ok），脚本里**没有**针对 D3 的只读断言 |
| 追加：包里去掉 `bin/qa` | 14 FAIL，但 **AC-016 仍 PASS** | ❌ **假 PASS（BA-003）** |
| 追加：安装失败（索引不可达）时的 state.json | **AC-013 仍 PASS** | ❌ **假 PASS（BA-002）** |

### 4.3 逐条假 PASS 细节

**BA-001（严重）—— AC-014 是"自证式"测试，对交付物零检验力**
- 机制：`verify-acceptance.sh:31` 的 `mkproj()` **自己**写 `.gitignore`（`.tools/*` + `!.tools/manifest.json`），全程**从不调用 `qa init`**，也不读取交付物里 `GITIGNORE_RULES` 的任何产物。
- 实证：把交付物的 `GITIGNORE_RULES` 改成契约明令禁止的 `['.tools/', '!.tools/manifest.json']`（清单会静默不进 Git，正是 D4 要防的事故），BA 脚本仍 **16 PASS / 0 FAIL**。
- 后果：**D4 决策在 BA 验收里零覆盖**；`.gitignore` 写错这种"静默丢清单"的事故不会被任何 AC 拦住。
- 修法：AC-014 改为「先 `qa init` 生成 `.gitignore`，再用 `git check-ignore` 验证清单未被忽略 + `.venv` 被忽略」，不要在脚本里手写规则。

**BA-002（严重）—— AC-013 在"安装其实失败"时仍判 PASS**
- 机制：`verify-acceptance.sh:172-173` 只 grep **键名/子串**：`grep -q "pyflakes" && grep -q "3.2.0" && grep -qi "installed_at" && grep -qi "source"`。而失败条目里 `spec` 含 `3.2.0`、`installed_at` 键存在（值为 `null`）、`source` 为 `"uv"`。
- 实证：装一个**装不上**的工具（索引指向死端口 → `status: unavailable`），其 `state.json` 为 `version: null, installed_at: null, status: "unavailable"`，BA 的 AC-013 断言**依然成立** → 判 PASS。
- 后果：AC-013 名义上验收"记录版本与来源"，实际只验收"JSON 里有这几个键"。
- 修法：改为解析 JSON 后断**字段值**：`tools.<name>.version === "3.2.0"`、`tools.<name>.installed_at` 为非空 ISO 时间、`status === "ok"`。

**BA-003（中）—— AC-016 的 `grep -q "bin/qa"` 会被 `bin/qa-impl.mjs` 命中**
- 机制：`verify-acceptance.sh:262-264` 逐个 `grep -q "$f"`，`f="bin/qa"` 是子串匹配。
- 实证：把 `bin/qa` 从包里拿掉（只剩 `bin/qa-impl.mjs`）→ BA 报 14 FAIL，但 **AC-016 依旧 PASS**。
- 修法：改成 `grep -qE "(^|[[:space:]])bin/qa$"`（行尾锚定）或直接解析 `npm pack --json` 的 `files[].path`。

**BA-004（中）—— 缺 D3（`doctor` 只读）的专门断言**
- 脚本只检查 `doctor` 的**退出码**（AC-015），从不断言"doctor 前后 `.tools/` 内容不变"。M5 变异体是靠 AC-003 的"missing 必须可达"顺带抓到的——如果变异体装完后仍报 missing，BA 脚本就抓不到。
- 修法：加一条"doctor 前后 `.tools/` 目录树 md5 相同、且未生成 `.venv`/`state.json`"。

**BA-005（中）—— 结果强依赖环境网络，"16 PASS" 不可无条件复现**
- 实证：把 `UV_DEFAULT_INDEX` 指向一个不可达端口（模拟 pypi 不可达）后重跑 BA 脚本 → **11 PASS / 5 FAIL**（AC-003/006/008/012/015 挂）。
- 根因：`uv` 默认走 `pypi.org`（**不读** `/etc/pip.conf`，也不认 `PIP_INDEX_URL`；本机上 `pypi.org` 时通时不通，实测 `curl` 出现 000 与 200 两种结果）。BA 脚本不固定索引源、不提示如何配置。
- 另外 AC-011 用的仍是 `https://github.com/...`（外网域名），与 D1 要求的"用本地端口、不依赖外网"不一致——**AC-003 已经改成本地端口了，AC-011 没跟上**。
- 修法：AC-011 同样改本地端口；脚本开头检查/设置 `UV_DEFAULT_INDEX` 与 `npm_config_registry`，并在索引不可达时给出明确的"环境不满足"提示而不是混入 AC 失败。

**BA-006（轻）—— AC-002 仍是全文 grep**
- `verify-acceptance.sh:58-59` 用 `grep -qi "missing"` 全文匹配，没有像 AC-003 那样锚定到"具体工具那一行的状态"。当前实现下不误判，但一旦输出里出现别的含 `missing` 的字样就会假 PASS。
- 修法：与 AC-003 共用 `has_state()` 式的行锚定。

### 4.4 对"AC-003 重写是否锚定到真实状态行"的专门回答
**是的，锚定到位。** `has_state()`（第 100 行）用正则 `^\[$2\] $3(（|$)` 匹配 `[status] tool` 行；AC-003 的四个断言（ok/failed/unavailable/missing）与边界断言（`failed notfound-xyz` 且 **不是** `unavailable notfound-xyz`）全部锚在具体工具名上，**不是全文 grep**，因此别的原因串里出现 "failed"/"unavailable" 不会造成假 PASS。这部分我认为是本次重写的**正确方向**。
唯一遗留：AC-003 的 `missing` 仍取自另一个项目（`p3m`），四个状态从不在同一次 doctor 输出里出现——不影响正确性，但降低了"一次体检给出四种结论"的可读性。

---

## 5. 缺陷清单

### P0
**无。** 未发现会导致"工具链装错版本 / 污染系统 / 静默吞掉失败"级别的缺陷。

### P1

#### P1-1 `qa run` / `qa which` 可执行 `.tools/` 之外的任意文件（`entry` 字段路径穿越未拦截）
- **触发条件**：清单条目里 `entry` 含上级目录，例如 `"entry": "../../evil.sh"`。
- **影响**：`qa run <name>` 直接执行 `.tools/` 之外的任意可执行文件；`qa which` 也把它当成"隔离副本"报出来。AC-009 的"白名单式"语义被绕过——被白名单放行的是**名字**，但真正被执行的文件不受任何约束。
- **根因**：`bin/qa-impl.mjs:660-679` 的 `resolveExecutable()` 直接 `path.join(root, 'bin', entryName)`，**没有 `isInsideTools()` 校验**；`validateManifest()`（第 520-583 行）校验了 `name` 的字符集，却**完全没校验可选字段 `entry` / `module`**。
- **复现步骤**（实测，已确认）：

```bash
mkdir -p /tmp/poc/.tools && cd /tmp/poc
printf '#!/bin/sh\necho "PWNED: 任意命令被执行"\n' > evil.sh && chmod +x evil.sh
cat > .tools/manifest.json <<'JSON'
{"version":1,"tools":[{"name":"innocent","kind":"binary","spec":"1.0.0","purpose":"p",
 "required_by":["QA"],"entry":"../../evil.sh",
 "install":{"url":"http://127.0.0.1:1/x"},"verify":{"command":"true","match":""}}]}
JSON
node <包根>/bin/qa --project /tmp/poc run innocent -- x
# 实际输出：[run] innocent -> /tmp/poc/evil.sh x
#           PWNED: 任意命令被执行，路径在 .tools/ 之外      （退出码 0）
node <包根>/bin/qa --project /tmp/poc which innocent
# 实际输出：/tmp/poc/evil.sh                              （退出码 0）
node <包根>/bin/qa --project /tmp/poc isolation
# 实际输出：[fail] innocent 的可执行入口在 .tools/ 之外      （退出码 1）← 只有 isolation 拦得住
```
- **建议修法**：
  1. `validateManifest()` 增加对 `entry` / `module` 的合法性校验：禁止路径分隔符、`..`、绝对路径、波浪号（与 `name` 同级对待）。
  2. `resolveExecutable()` 返回前统一加 `isInsideTools(path, root)` 断言，越界即返回 `null`（→ 状态 `failed`，原因写明"入口路径越界"）。
  3. `cmdRun()` 在执行前再做一次 `isInsideTools()` 兜底，越界直接 `EXIT_FAIL`。
  4. 补一条 AC：`qa run` 拒绝执行 `.tools/` 之外的入口。

### P2

#### P2-1 `state.json` 上报的"来源"可能与实际抓取源不一致（证据链失真）
- **触发条件**：只设 `PIP_INDEX_URL`（例如指向公司镜像），不设 `UV_DEFAULT_INDEX`。
- **实测**：`resolveSource()`（`bin/qa-impl.mjs:743-751`）把 `PIP_INDEX_URL` 当来源上报：
  `[install]   来源：https://mirrors.aliyun.com/pypi/simple`；
  但 `uv 0.12.20` **不认 `PIP_INDEX_URL`**，实测 `uv -v` 仍然请求 `https://pypi.org/simple/<pkg>/`（也不读 `/etc/pip.conf`）。
- **影响**：写入 `state.json.source_detail.source` 的来源地址可能根本没被使用过——与 F6"可追溯：报告里能说清用的是哪个版本的工具"的可追溯意图相悖。
- **建议修法**：`resolveSource()` 只采信 uv 真正支持的环境变量（`UV_DEFAULT_INDEX` / `UV_INDEX_URL`），或由 `qa` 显式把索引地址通过 `--index-url` 传给 uv；同时在契约 §8 里把"索引源"改成"uv 认的环境变量"，并明确 `PIP_INDEX_URL` 不生效。

#### P2-2 `install` 模板允许执行任意可执行文件（契约未约束命令本身）
- **触发条件**：`install.uv` 写成非包管理器的命令，如 `"sh -c ..."`。
- **实测**：`checkInstallBoundary()` 只检查"写到哪儿"（路径/标志），不检查"跑什么"；这类命令不会被拒。
- **影响**：契约 F2 硬规则 1 的本意是"不污染系统"，但"命令本身不受限"让"只装包管理器"这条隐含约束落空。与 P1-1 同源。
- **建议修法**：契约里补一句"install 模板的第一个 token 必须是该 kind 的包管理器（uv / bun / npm / pip）"，或在校验器里限定可执行文件名集合。

#### P2-3 BA 脚本：AC-014 自证式、AC-013 假 PASS、AC-016 grep 脆弱、缺 D3 断言、结果依赖外网
- 见 §4.3 的 **BA-001 ~ BA-006**（BA-001/BA-002 定级 P1，其余 P2）。
- **建议修法**：AC-014 改为用 `qa init` 产出的规则做验证；AC-013 改为解析 JSON 断字段值；AC-016 用行尾锚定或 `npm pack --json`；新增"doctor 只读"断言；AC-011 从 GitHub 外网改成本地端口。

#### P2-4 环境可复现性：`uv` 默认走 `pypi.org`，本机时通时不通
- **实测**：`uv -v` 显示请求 `https://pypi.org/simple/...`；本机 `curl https://pypi.org/simple/` 在验收期间出现过 000（不可达）与 200（可达）两种结果。同一时段 `uv pip install` 一次失败（被正确判为 `unavailable`）、一次成功。
- **影响**：BA 脚本的"16 PASS"依赖当时的外网状态；开发者自验报告里"16 PASS / 0 FAIL"在另一台机器/另一时段不一定复现。
- **建议修法**：在 SKILL.md 与契约里明确 python 路线需设 `UV_DEFAULT_INDEX`（或 `UV_INDEX_URL`），并在 `qa doctor` 里把"索引不可达"作为环境级结论显式报出。

---

## 6. 我**没有**验到的部分（明确声明，不假装全覆盖）

1. **Windows 行为**：契约声明"Windows 未支持"，本机为 Linux，我没有在 Windows 上验证"明确报错、不假装支持"这一条。
2. **macOS 可移植性**：契约声明 Linux/macOS 可移植，我只在本机（Linux 7.2.8 / Node v26.10.0 / Python 3.14.7 / uv 0.12.20 / bun）验证。
3. **Node 18 / Node 20 上的 `bin/qa` 启动器语义**：只在本机 Node 26 验证；`bin/qa` 注释声称用动态 `import()` 抹平 CJS/ESM 差异，但**我没有在 Node 18/20 上实测**该抹平确实成立（`package.json` 声明 `engines.node >=18`，这是分发面上的风险点）。
4. **`binary` 路线的 sha256 正常路径**：只测了"不匹配 → failed"，没测"匹配 → ok"（需自建带正确 sha256 的本地下载源，我没搭）。
5. **binary 路线的压缩包**：契约声明不支持（已知限制），未测。
6. **`install.sha256` 与 `state.json.checksum` 的语义区分**：只读了契约说明，未做端到端交叉验证。
7. **真实 npm 包安装后的端到端链路**：只做了 `npm pack --dry-run` 的清单核对，**没有** `npm install <tarball>` 后再跑 `qa`（即"装到用户机器上真能用"这一层没验）。
8. **并发/竞态**：没测两个 `qa install` 并发跑同一个项目、也没测 `qa install` 中途被 Ctrl-C 后的状态一致性。
9. **缓存策略**："优先本地缓存 → 镜像源 → 官方源"这条需求描述里的三级策略，我只验了后两级（实际实现是 `uv`/`bun` 各自管缓存，`qa` 层没有显式的"本地缓存优先"逻辑），**没有**逐级验证缓存命中行为。
10. **`qa isolation` 的完整判定矩阵**：只跑了 python/node/binary 三类各一个正常样例 + 一个越界样例，没穷举"系统同名工具存在"等分支的组合。
11. **BA 脚本在"网络完全不可达"下的行为**：我用死端口模拟了 PyPI 不可达（得到 11 PASS/5 FAIL），但**没有**把 npm 镜像也同时掐掉（npmmirror 可达是前提），也没测 GitHub 域名 DNS 完全失败时的 AC-011。
12. **开发者自验脚本 `/tmp/qa-0024/acceptance.sh`**（开发报告里提到的 51 项自验）：该文件在 `/tmp` 且已被清理，**我没有复现**开发者自验的数据，只独立跑了自己造的断言。
13. **skill 文档的可执行性**：`SKILL.md` / 契约文档是给"另一个模型"执行的规约，我只核对了它与实现的一致性（条目字段、`failed/unavailable` 分界表、`exit code` 表、`.gitignore` 写法），**没有**做"让一个模型照着文档造清单"的端到端可用性实验。

---

## 7. 验收证据索引（全部在 `/tmp/qa-verify-0024/`）

| 文件 | 内容 |
|---|---|
| `t_core.mjs` | 独立验收 harness（94 项断言，含 AC-001~AC-016 与附加安全探测） |
| `run3.log` | harness 最终运行日志（94 PASS / 0 FAIL，其中 1 条为"缺陷命中"） |
| `t_mutate.mjs` / `result-mut.json` | 变异测试脚本与结果表（5 条变异 × 2 项断言） |
| `ba-verify.sh` | BA 验收脚本副本（未改动） |
| `ba_mutants.log` | BA 脚本 × 各突变体的反测记录 |
| `impl/` | 交付物副本（基线） |
| `mutfull/` | m4 / m5 / m6 突变体副本（m6 = 去掉 `bin/qa`） |
| `snap/before.txt` / `snap/after.txt` | 真实系统（`~/.local`、`pip3 list`、全局 npm）前后快照 |
