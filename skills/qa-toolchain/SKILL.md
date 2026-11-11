---
name: qa-toolchain
description: |
  Bootstrap and manage the project-local `.tools/` toolchain: declarative manifest, isolated installs (Python venv / Node packages), idempotent re-installs, and explicit failure degradation.
  Use this skill when the user asks to "装测试工具"、"工具装不上"、"环境里没有这个工具"、"工具链体检"、"工具装没装上", or asks to run "qa install" / "qa doctor" / "qa list" / "qa which" / "qa run"; also use it when a capability-domain skill needs to declare a tool dependency (bandit / pip-audit / loadtest …) in `<project-root>/.tools/manifest.json`.
  Do NOT use it for designing test cases (use test-case-design), for executing test cases against a live system (use test-execute), or for writing 缺陷单 / 质量报告 — those are separate workflows.
---

# QA 工具链自举（`.tools/`）

`qa` 是**套件级**的统一入口（随 npm 包分发，命令名 `qa`），管理**项目级**的
`<project-root>/.tools/`：测试要用的工具按**声明式清单**装进项目自己的目录，
**不污染系统环境**；装不上时**显式报"不可用"**，而不是静默跳过。

完整契约（清单字段、状态语义、隔离规则、环境约束、已知限制）见
`references/tools-chain-contract.md`。

## 什么时候用这个 skill

- 某个能力域要用某个工具，但环境里没有 → 需要把它装进 `.tools/`。
- 需要确认"这个工具到底装没装上、装的是哪个版本"。
- 需要写 `<project-root>/.tools/manifest.json`（声明工具依赖）。
- 需要把某个工具标为"不可用 / 未覆盖"（而不是"未发现问题"）。

## 前提

- 命令可用：全局装过 npm 包就有 `qa`；在仓库里可用 `node <包根>/bin/qa`。
- 项目根有 `<project-root>/.tools/manifest.json`；没有就先 `qa init` 生成骨架
  （同时把 `.gitignore` 规则写好）。

## Procedure

1. **看清单与状态**
   ```bash
   qa list --project <项目根>
   ```
   状态只有四种：`ok` / `missing` / `failed` / `unavailable`。

2. **装工具（幂等）**
   ```bash
   qa install              # 装全部
   qa install bandit       # 只装一个
   ```
   已装且版本匹配 → 输出"已安装，跳过"，不重复下载、不破坏已装环境。

3. **体检**
   ```bash
   qa doctor --project <项目根>
   ```
   任一工具非 `ok` → 退出码 1，每个工具一个明确结论。

4. **用工具（只允许清单里的）**
   ```bash
   qa run bandit -- -r src/
   ```
   工具不在清单 → 拒绝执行，退出码 2。

5. **确认走的是隔离副本**
   ```bash
   qa which bandit          # 输出路径必须在 <项目根>/.tools/ 之下
   qa isolation             # 负向验证：系统侧不可见 / 未污染
   ```

## 写清单条目

```json
{
  "name": "bandit",
  "kind": "python",
  "spec": "bandit==1.7.7",
  "purpose": "Python 代码安全扫描",
  "required_by": ["REQ-002.8"],
  "install": { "uv": "pip install --no-deps {spec}" },
  "verify": { "command": "bandit --version", "match": "bandit" }
}
```

`kind` 决定安装路线：`python` → `.tools/.venv/`（uv），`node` → `.tools/node/`（bun），
`binary` → `.tools/bin/`（直链下载）。

三条硬规则：

1. **版本必须锁定** —— 形态按 `kind` 分：`python` 用 `name==version`（`bandit==1.7.7`）、
   `node` 用 `name@version`（`semver@7.7.2`）、`binary` 用**纯版本号或完整下载 URL**
   （`1.0.0` / `https://host/tool-linux-amd64`，binary 没有包名，不能写 `name@version`）。
   `>=` / `latest` 一律拒绝安装（报"版本未锁定"）。
2. **install 不得写到 `.tools/` 之外** —— `--user` / `--system` / `--prefix` /
   `.tools/` 外的绝对路径等一律拒绝安装（报"安装路径越界"）。
3. **verify 必须存在** —— 装完不验证等于没装。

## 工具装不上时怎么办（重要）

状态是 `failed` 或 `unavailable` 时：

- **必须**把对应能力标为"不可用 / 未覆盖"，在报告里写清"该工具装不上，该能力未覆盖"。
- **不得**报告为"未发现问题"或"通过"。

> 理由（与整个套件一致）：**没有证据的"通过"比失败更危险。**
> 工具没装成却报告"没发现问题"，是在制造假的安全感。

先看 `qa doctor` 给出的原因再决定：网络/镜像不可达、缺运行时（uv / bun）、
还是该 `kind` 在当前环境不可用。当前环境只有 PyPI 镜像与 npm 镜像可达，
单二进制工具（GitHub releases 分发）装不上，不要写进清单。

## 注意

- 入口 `qa` 随 npm 包分发，但清单与工具链是**每个项目各一份**，互不干扰。
- `.tools/manifest.json` 进 Git（可复现的依据），其余安装产物不进 Git。
- 隔离性要**实测**（`qa isolation`），不能靠声称。
