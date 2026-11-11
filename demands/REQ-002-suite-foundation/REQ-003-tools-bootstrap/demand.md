# 需求：测试套件基座 — `.tools` 工具链自举机制

- **需求编号**: REQ-003
- **所属 Epic**: REQ-002 suite-foundation
- **优先级**: P1
- **状态**: 已就绪
- **前置**: REQ-002.3（目录契约 —— 已完成，`test-assets/` 与 `.tools/` 的位置已定）

## 需求描述

### 背景

后续能力域要用的工具都不是 Node 内置能覆盖的：

| 能力域 | 需要的工具 | 语言 |
|---|---|---|
| 安全（REQ-002.8） | `bandit`（Python 代码安全）、`pip-audit`（Python 依赖漏洞） | Python |
| 压测（REQ-002.9） | `loadtest`（压测 runner） | Node |
| 通用 | `uv`（Python 包管理）、`bun`（Node 包管理） | 二进制 |

**用户决策（早前）**：测试过程中用到的依赖程序，**如果环境中不存在，则安装到 `.tools/` 里，不污染系统环境**。

**为什么这条必须做成机制，而不是每个 skill 各写一份安装命令**：

1. **不污染系统**是硬要求。系统 Python 环境被 `pip install` 弄脏后，排查"这个包到底装没装"会变成噩梦；CI 镜像与本地环境的行为也会分叉。
2. **工具链要可复现**。工具的版本、来源、校验和必须声明出来，不能是某次 `pip install` 的偶然结果。
3. **工具缺失必须显式**。如果某个工具装不上（网络受限、镜像 404），skill 必须明确报告"该能力不可用"，**绝不能静默跳过并宣称"没发现问题"**。这与 REQ-002.5b 的"不可机械判定的用例判 blocked 而非 passed"是同一条原则：**没有证据的"通过"比失败更危险。**

### 目标

交付一个**声明式、可复现、不污染系统、失败显式**的工具链自举机制：统一的 `.tools/` 布局 + 统一的 `qa` 入口 + 声明式清单 + 失败降级报告。

**这不是做测试，是做"测试要用的工具从哪来、怎么装、装不上怎么办"的规约。**

### 范围边界

**在范围内**：

- `.tools/` 目录布局与 `.tools/manifest.json` 清单格式
- 自举脚本 `scripts/qa`（统一入口）
- 工具安装策略：优先本地缓存 → 镜像源 → 官方源；失败显式降级
- 隔离性验证（装完不得污染系统环境）
- 工具可用性检查与"能力不可用"的报告格式

**不在范围内**：

- 具体的工具清单内容（哪些工具进 `.tools/manifest.json` 由各能力域的 REQ 决定 —— REQ-002.8 加安全工具，REQ-002.9 加压测工具）
- 各工具自身的使用封装（属对应能力域 REQ）
- 容器化方案（当前环境 Docker daemon 未运行）
- 二进制工具的下载分发（当前环境 GitHub releases 不可达，见下）

## 环境实测结论（设计前提，已在本机验证）

| 事实 | 影响 |
|---|---|
| **仅 PyPI 镜像与 npmmirror 可达**，GitHub releases 不可达 | 单二进制工具（`nuclei` / `trivy` / `osv-scanner`）**装不上** → 这些工具不纳入清单 |
| **npmmirror 的二进制镜像 404** | 不能靠 npm 镜像拿预编译二进制 → 纯 JS 工具（`loadtest`）可装，编译型不行 |
| **Docker daemon 未运行** | 容器化隔离方案不可用 → 必须靠目录级隔离 |
| `uv sync` 装到 `.tools/.venv` 后，系统 `import httpx` 仍 `ModuleNotFoundError` | Python 隔离路线**可行** |
| `bun install` 装到 `.tools/node/` 后，系统 `command -v loadtest` 无输出 | Node 隔离路线**可行** |
| `loadtest` 在 bun 下 TCP 模式 42,255 rps，node HTTP 模式 2,907 rps（14.5×） | 压测工具优先 bun 运行时（属 REQ-002.9，本 REQ 只负责装） |

**设计推论**：工具链以**解释型/纯 JS 工具**为主（Python 包 + Node 包），**不依赖预编译二进制分发**。这是当前网络约束下的必然选择 —— 但清单格式不应把这一点写死，将来网络条件变化时应能直接加二进制工具条目。

## 功能要求

### F1 `.tools/` 目录布局

```
<project-root>/                       # 被测项目根（不是 npm 包根）
└── .tools/                       # 工具链根
    ├── manifest.json             # 工具清单（进 Git —— 声明要装什么）
    ├── .venv/                    # Python 虚拟环境（uv 管理，不进 Git）
    ├── node/                     # Node 包（bun 管理，不进 Git）
    ├── cache/                    # 下载缓存（不进 Git）
    └── state.json                # 已安装状态（不进 Git）
```

**关键点**：

- `.tools/manifest.json` **进 Git**（声明要装什么，是可复现的依据）
- `.venv/` / `node/` / `cache/` / `state.json` **不进 Git**（是安装产物）

**`.gitignore` 的精确写法**（`.tools/` 整目录忽略会导致 `manifest.json` 的例外规则失效 —— git 不会进入已忽略的目录）：

```gitignore
# 工具链：除清单外都是安装产物
.tools/*
!.tools/manifest.json
```

> 注意用 `.tools/*` 而不是 `.tools/`。写成 `.tools/` 时 git 直接跳过整个目录，后面的 `!.tools/manifest.json` 永远不生效 —— 清单就静默地不进版本库了。

### F1b 统一入口的归属：`bin/qa`（包级 CLI）

统一入口 `qa` **不能**放在 `.tools/` 下 —— 那里除清单外都不进 Git，入口脚本会跟着安装产物一起丢失。

正确归属：

| 层 | 位置 | 进 Git | 进 npm 包 | 说明 |
|---|---|---|---|---|
| **入口实现** | npm 包根 `bin/qa` | ✓ | ✓（`package.json` 的 `files` 已含 `bin/`） | 包级 CLI，注册为 npm bin `qa` |
| **清单** | 项目 `<project-root>/.tools/manifest.json` | ✓ | — | 项目自己声明要装什么 |
| **安装产物** | 项目 `<project-root>/.tools/` 其余部分 | ✗ | — | 每个项目各自一份，互不干扰 |

`qa` 跑在被测项目里，管理**当前项目**的 `.tools/`。这样「工具链是项目级的、入口是套件级的」两件事都成立。

### F2 工具清单 `manifest.json`

```json
{
  "version": 1,
  "tools": [
    {
      "name": "bandit",
      "kind": "python",
      "spec": "bandit==1.7.7",
      "purpose": "Python 代码安全扫描",
      "required_by": ["REQ-002.8"],
      "install": { "uv": "pip install --no-deps {spec}" },
      "verify": { "command": "bandit --version", "match": "bandit" }
    },
    {
      "name": "loadtest",
      "kind": "node",
      "spec": "loadtest@8.2.1",
      "purpose": "压测 runner",
      "required_by": ["REQ-002.9"],
      "install": { "bun": "bun add {spec}" },
      "verify": { "command": "loadtest --version", "match": "loadtest" }
    }
  ]
}
```

**字段语义**：

| 字段 | 必填 | 说明 |
|---|---|---|
| `name` | 是 | 工具名。**全局唯一**，是 `qa <name>` 的调用键 |
| `kind` | 是 | `python` / `node` / `binary`。决定用哪条安装路线 |
| `spec` | 是 | 版本锁定串。**必须锁版本** —— 工具行为会变，工具版本是证据链的一部分 |
| `purpose` | 是 | 这个工具干什么。人可读 |
| `required_by` | 是 | 哪些能力域需要它。用于"这个能力依赖的工具装不上"时定位影响面 |
| `install` | 是 | 安装命令模板。`{spec}` 是版本占位符。**必须只写到 `.tools/` 内部** |
| `verify` | 是 | 安装后如何确认可用：`command` + `match`（输出里应包含的串） |

**硬规则**：

1. `install` 里的命令**不得**写到 `.tools/` 之外（`uv pip install --target` / `uv venv` / `bun install --cwd` 之类），否则就是污染系统。
2. `spec` **必须锁版本**，不允许 `>=` / `latest`。
3. `verify` 必须存在 —— 装完不验证等于没装。

### F3 统一入口 `qa`

```bash
qa <子命令> [参数...]
```

| 子命令 | 作用 |
|---|---|
| `qa list` | 列出清单里的工具及其安装状态 |
| `qa doctor` | 检查各工具是否可用（跑 `verify`），不可用的明确列出 |
| `qa install [name...]` | 安装（缺省装全部）。幂等：已装且版本匹配则跳过 |
| `qa run <name> -- <args>` | 在 `.tools/` 隔离环境里执行工具。工具不在清单 → 拒绝 |
| `qa which <name>` | 打印工具的可执行路径（用于确认走的是 `.tools/` 里的那份，不是系统的） |

**`qa run` 的三条约束**：

1. **只允许执行清单里的工具** —— `qa run` 是白名单式的，不接受任意命令。这条防止它退化成"随便跑命令"的万能入口。
2. **执行环境的 PATH 必须以 `.tools/` 优先** —— 系统里恰好也有同名工具时，必须跑 `.tools/` 里那份。
3. **工具不可用时明确报错** —— 退出码非 0，且错误信息要说清"工具 X 未安装 / 安装失败（原因）"，**不能静默跳过**。

### F4 隔离性

| 要求 | 验证方式 |
|---|---|
| Python 工具装进 `.tools/.venv/`，系统 `python3 -c "import X"` 仍失败 | 安装后跑一次负向验证 |
| Node 工具装进 `.tools/node/`，系统 `command -v <tool>` 无输出 | 同上 |
| `qa run` 实际执行的是 `.tools/` 里的那份 | `qa which <name>` 输出路径必须在 `.tools/` 下 |

**隔离性的负向验证是必须的** —— "装完不污染"不能靠声称，要靠实测。

### F5 失败显式降级

工具装不上时，**不得静默跳过**。`qa doctor` 的输出必须明确区分：

| 状态 | 含义 |
|---|---|
| `ok` | 已安装且 `verify` 通过 |
| `missing` | 清单里有，未安装 |
| `failed` | 安装尝试过但失败（附原因） |
| `unavailable` | 当前环境装不了（如网络受限、该 `kind` 在本环境不可用） |

**并且**：调用方（各能力域 skill）拿到 `unavailable` 时，**必须**把对应能力标为"不可用/未覆盖"，**不得**报告为"未发现问题"。理由同前：没有证据的"通过"比失败更危险。

### F6 `state.json`

记录每个工具的已安装状态：版本、来源、安装时间、校验和。用途：

- 幂等：版本匹配则跳过安装
- 可追溯：报告里能说清"用的是哪个版本的工具"
- 与证据链呼应（REQ-002.5b 的 `meta.json` 里要记 `tool_versions`）

## 非功能要求

- **零依赖**：自举脚本用 `node:` 内置模块或 POSIX shell（`sh`），不引入第三方包
- **可移植**：Linux / macOS；Windows 尽力而为并明确标注不支持的路径
- **幂等**：重复 `qa install` 不重复下载、不破坏已装环境
- **不污染系统**：任何安装路径都不得写到 `.tools/` 之外
- **退出码语义**：`0` 成功 / `1` 校验失败或工具不可用 / `2` 调用方式错误
- **可观测**：每次安装输出可读日志（装了什么、从哪来、多大、耗时）

## 验收要点

见 `acceptance.md`（待写）。

## 依赖说明

- **前置**：REQ-002.3（目录契约）—— 已完成
- **后续**：REQ-002.8（安全工具）、REQ-002.9（压测工具）—— 二者的工具清单由本 REQ 的机制承载
- **并行**：可与 REQ-002.5b 并行 —— 本 REQ 只碰 `.tools/` 相关路径与统一入口，不碰 `skills/test-case-design/` 与 `skills/test-execute/`
