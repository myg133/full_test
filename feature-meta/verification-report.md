# REQ-002.4 验证报告

- 需求：REQ-002.4「测试套件基座 — `.tools` 工具链自举机制」
- 分支：`feature/REQ-002.4`（基线 `develop`）
- 实现：`bin/qa`（启动器）、`bin/qa-impl.mjs`（实现）、`skills/qa-toolchain/`（说明书 SKILL.md + 契约 references/tools-chain-contract.md）
- 改动：`package.json` 仅新增 `bin.qa` 注册（`dependencies` 保持为空）

## 1. 自验方式

在 `/tmp/qa-0024/` 下构造测试项目（不进仓库），用独立脚本把 15 条 AC 固化成
48 项机械检查后跑通：

```bash
bash /tmp/qa-0024/acceptance.sh
```

结果：**PASS=51 FAIL=0**（逐条明细见 `feature-meta/traceability.md`）。

## 2. 关键实测记录

| 事项 | 实测结果 |
|---|---|
| Python 工具安装 | `uv pip install --no-deps pyflakes==3.2.0`（`VIRTUAL_ENV` 指向 `.tools/.venv`）→ `.tools/.venv/bin/pyflakes` |
| 系统隔离（负向） | `python3 -c "import pyflakes"` → `ModuleNotFoundError` ✅ |
| Node 工具安装 | `bun add js-yaml@4.1.0`（cwd=`.tools/node`）→ `.tools/node/node_modules/.bin/js-yaml` |
| 系统隔离（负向） | `command -v js-yaml` → 无输出 ✅ |
| 同名冲突 | 系统 `/usr/bin/semver`=7.8.5，`.tools/` 副本=7.7.2；`qa run semver -- --help` 输出 `SemVer 7.7.2` ✅ |
| 幂等 | 二次 `qa install` 输出「已安装，跳过」，`state.json` 逐字节未变 ✅ |
| 失败显式 | 来源不可达的 binary 工具 → 安装退出码 1，`qa doctor` 状态 `unavailable` ✅ |
| 清单进 Git | `.tools/*` + `!.tools/manifest.json` → `git check-ignore -q .tools/manifest.json` 退出码 1（未忽略）；`git status -uall` 列出清单 ✅ |
| 反例验证 | 写成 `.tools/` 时 `git check-ignore -q .tools/manifest.json` 退出码 0（被忽略）→ 证明必须用 `.tools/*` ✅ |
| 分发链路（AC-016） | `npm pack --dry-run` 清单含 `bin/qa`、`bin/qa-impl.mjs`、`skills/qa-toolchain/SKILL.md`、`skills/qa-toolchain/references/tools-chain-contract.md` ✅ |

## 3. 已知限制

1. **Windows 不支持**：POSIX 路径与 `.venv/bin` 布局假设，未做 Windows 适配。
2. **binary 路线只支持直链单文件**：不支持压缩包解压。
3. **契约文档的分发链路**：初版放在包根 `references/`，但 `package.json` 的 `files`
   白名单是 `skills/ bin/ README.md LICENSE`，该目录**不会进 npm 包**（REQ-002B 同款坑）。
   已改为方案 A：契约文档随 `skills/qa-toolchain/` 这个 skill 分发（`skills/` 在白名单里），
   并用 `npm pack --dry-run` 逐文件核对确认全部进包。
4. **`bin/qa` 是启动器**：实现拆到 `bin/qa-impl.mjs`，因为无扩展名文件在
   Node 18（按 CJS 加载）与 Node 22+（按包的 `type: module` 加载）下模块语义不同，
   启动器用动态 `import()` 抹平差异。

## 4. 需求文档内部不一致之处（已按 F1b/F1/F6 + acceptance.md 为准处理）

| 位置 | 表述 | 处理 |
|---|---|---|
| demand.md 范围边界 | 「自举脚本 `scripts/qa`」 | 按 F1b 与 AC-001 用 `bin/qa` |
| architecture-design.md §5.1 | 入口在 `.tools/bin/qa`、状态在 `state/installed.json` | 按 F1b / F1 / F6 与 AC-013 用包级 `bin/qa` 与 `.tools/state.json` |
| architecture-design.md §5.1 | 「`.gitignore` 只需排除四条」 | 按 F1 与 AC-014 用 `.tools/*` + `!.tools/manifest.json` |
| demand.md F2 示例 | `install.uv` 写 `"pip install ..."`（不含运行时名），`install.bun` 写 `"bun add ..."`（含运行时名） | 实现两种写法都接受（前导运行时名不重复拼接） |

## 5. 请 QA 关注

- 交叉验证时用 `git check-ignore -q`（不带 `-v`）判断是否被忽略：带 `-v` 时
  命中否定规则也会打印该规则并返回 0，容易误判。
- `qa doctor` 的退出码在有任一工具非 `ok` 时为 1；`qa list` 恒为 0。
