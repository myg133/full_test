# REQ-002.4 追溯性矩阵

> 需求：`BA/demands/REQ-002-suite-foundation/REQ-002.4-tools-bootstrap/demand.md`
> 验收：`BA/demands/REQ-002-suite-foundation/REQ-002.4-tools-bootstrap/acceptance.md`
> 分支：`feature/REQ-002.4`　实现：`bin/qa`（启动器）+ `bin/qa-impl.mjs`（实现）+ `skills/qa-toolchain/`（说明书 + 契约文档）

| AC | 需求条款 | 实现位置 | 验证方式 | 结论 |
|---|---|---|---|---|
| AC-001 | F1b / F3 | `bin/qa`、`bin/qa-impl.mjs:printHelp` | `npm pack --dry-run` 看清单；`node bin/qa --help` 退出码 0 且列出全部子命令 | PASS |
| AC-002 | F2 / F3 | `bin/qa-impl.mjs:cmdList` | `qa list --project <PROJ>`：两个工具都在输出里，状态 `missing` | PASS |
| AC-003 | F5 | `bin/qa-impl.mjs:cmdDoctor`、`computeStatus` | `qa doctor`：输出同时出现 `[ok]` / `[missing]` / `[failed]` / `[unavailable]`，退出码 1 | PASS |
| AC-004 | F2 硬规则 2 | `bin/qa-impl.mjs:parseSpecVersion`、`cmdInstall` | `spec: "bandit>=1.7"` → 拒绝安装，退出码 1，报「版本未锁定」 | PASS |
| AC-005 | F2 硬规则 1 | `bin/qa-impl.mjs:checkInstallBoundary` | `install: {uv: "pip install --user {spec}"}` → 拒绝安装，退出码 1，报「安装路径越界」，未创建 `.venv` | PASS |
| AC-006 | F4 | `bin/qa-impl.mjs:ensurePythonVenv`、`performInstall`（python 分支） | `.tools/.venv/` 存在；系统 `python3 -c "import pyflakes"` 失败 | PASS |
| AC-007 | F4 | `bin/qa-impl.mjs:ensureNodeDir`、`performInstall`（node 分支） | `.tools/node/` 存在；系统 `command -v js-yaml` 无输出 | PASS |
| AC-008 | F3 | `bin/qa-impl.mjs:cmdWhich`、`resolveExecutable` | `qa which pyflakes` 输出路径在 `<PROJ>/.tools/` 之下，退出码 0 | PASS |
| AC-009 | F3 约束 1 | `bin/qa-impl.mjs:cmdRun` | `qa run <非清单工具>` → 退出码 2，报「不在清单中」，副作用标记文件未生成 | PASS |
| AC-010 | F3 约束 2 / F4 | `bin/qa-impl.mjs:isolatedEnv`、`cmdRun` | 系统有 `/usr/bin/semver`(7.8.5)，`.tools/` 装 7.7.2：`qa which` 指向 `.tools/`，`qa run semver -- --help` 输出 `SemVer 7.7.2` | PASS |
| AC-011 | F5 | `bin/qa-impl.mjs:installBinary`、`performInstall`、`recordFailure` | 来源不可达的 binary 工具 → 安装退出码 1，doctor 状态 `unavailable`（非 `ok`、非跳过），错误说明原因 | PASS |
| AC-012 | F3 / 非功能 | `bin/qa-impl.mjs:cmdInstall`（幂等分支）、`writeState` | 重复 `qa install` 退出码 0，输出「已安装，跳过」，`state.json` 逐字节未变 | PASS |
| AC-013 | F6 | `bin/qa-impl.mjs:cmdInstall`（写 state）、`writeState` | `state.json` 条目含 `name` / `version`(3.2.0，与 spec 一致) / `source` / `installed_at` | PASS |
| AC-014 | F1 | `bin/qa-impl.mjs:cmdInit`（写 `.gitignore` 规则） | `git check-ignore -q .tools/.venv/x` → 忽略；`git check-ignore -q .tools/manifest.json` → 未忽略；`git status -uall` 列出清单。反例：写成 `.tools/` 时清单被忽略 | PASS |
| AC-015 | 非功能 | `bin/qa`、`bin/qa-impl.mjs`（仅 `node:` 内置模块）；`package.json`（`bin` 注册，dependencies 空） | 源码检索无第三方依赖；退出码 0 / 1 / 2 三态实测 | PASS |
| AC-016 | 分发链路 | `package.json` 的 `files` 白名单含 `skills/`；契约文档置于 `skills/qa-toolchain/references/tools-chain-contract.md` | `npm pack --dry-run` 逐项核对：`bin/qa`、`bin/qa-impl.mjs`、`skills/qa-toolchain/SKILL.md`、契约文档全部在 tarball 清单里 | PASS |

> **AC-016 备注**：`feature-meta/*.md` 是仓库工作元数据（与其它 REQ 一致，不进 npm 包），
> 不是交付物；AC-016 点名的三类交付物（入口、实现文件、契约文档）全部在包内。
> 契约文档**未**放在包根 `references/`——该目录不在 `files` 白名单里，放那里会重演
> REQ-002B 的"工作区有、用户机器上没有"。

## 非功能要求对照

| 要求 | 实现 | 结论 |
|---|---|---|
| 零依赖 | `bin/qa-impl.mjs` 只 import `node:fs` / `node:path` / `node:crypto` / `node:child_process` / `node:url`；`package.json` 的 `dependencies` 为空 | PASS |
| 可移植 | Linux / macOS（POSIX 路径假设）；Windows 明确不支持（契约文档 §8 已标注） | PASS（Windows 不支持，已标注） |
| 幂等 | 幂等分支 + `writeState` 内容无变化时不落盘 | PASS |
| 不污染系统 | 安装路径全部指向 `.tools/`；`checkInstallBoundary` 静态拦截越界命令 | PASS |
| 退出码语义 | 0 / 1 / 2，见契约文档 §4 | PASS |
| 可观测 | 安装输出「装了什么 / 从哪来 / 命令 / 耗时 / 产物大小」 | PASS |
