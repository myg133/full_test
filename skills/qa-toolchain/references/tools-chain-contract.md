# 工具链契约（`.tools/` 自举机制）

> 归属：REQ-002.4「测试套件基座 — `.tools` 工具链自举机制」。
> 需求文档：`BA/demands/REQ-002-suite-foundation/REQ-002.4-tools-bootstrap/demand.md`
> 验收标准：`BA/demands/REQ-002-suite-foundation/REQ-002.4-tools-bootstrap/acceptance.md`
>
> **这份文档描述的是机制，不是测试用例。** 清单里具体装哪些工具由各能力域的 REQ 决定
> （REQ-002.8 加安全工具，REQ-002.9 加压测工具）。
>
> **分发位置**：本文件是 `qa-toolchain` skill 的一部分，随 npm 包分发
> （`skills/` 在 `package.json` 的 `files` 白名单里），装包的用户可通过 skill 机制发现。

---

## 1. 定位：入口是包级的，工具链是项目级的

| 层 | 位置 | 进 Git | 进 npm 包 |
|---|---|---|---|
| **入口实现** | npm 包根 `bin/qa`（实现见 `bin/qa-impl.mjs`） | ✅ | ✅（`package.json` 的 `files` 含 `bin/`） |
| **清单** | 项目 `<project-root>/.tools/manifest.json` | ✅ | — |
| **安装产物** | 项目 `<project-root>/.tools/` 其余部分 | ❌ | — |

**为什么入口不能放在 `.tools/` 下**：`.tools/` 里除清单外都不进 Git，入口脚本会跟着
安装产物一起丢失。入口属于套件（npm 包），工具链属于项目。

`qa` 在被测项目里运行，管理**当前项目**的 `.tools/`。每个项目一份工具链，互不干扰。

---

## 2. 目录布局

```text
<project-root>/                       # 被测项目根（不是 npm 包根）
└── .tools/
    ├── manifest.json                 # 工具清单（进 Git —— 声明要装什么）
    ├── .venv/                        # Python 虚拟环境（uv 管理，不进 Git）
    ├── node/                         # Node 包（bun 管理，不进 Git）
    │   └── node_modules/.bin/        #   可执行入口
    ├── bin/                          # 单二进制工具（不进 Git）
    ├── cache/                        # 下载缓存（uv / bun / npm，不进 Git）
    └── state.json                    # 已安装状态（不进 Git）
```

### `.gitignore` 的精确写法

```gitignore
# 工具链：除清单外都是安装产物
.tools/*
!.tools/manifest.json
```

> ⚠️ **必须用 `.tools/*`，不能用 `.tools/`。**
> 写成 `.tools/` 时 git 直接跳过整个目录，后面的 `!.tools/manifest.json` 永远不生效 ——
> 清单就**静默地不进版本库**了（`git status` 里看不到，也没有任何报错）。
> `qa init` 会把这两行写进项目根 `.gitignore`；也可以手工照抄。

---

## 3. 清单格式 `.tools/manifest.json`

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

| 字段 | 必填 | 说明 |
|---|---|---|
| `name` | ✅ | 工具名，**全局唯一**，是 `qa <name>` 的调用键。不得含路径分隔符 |
| `kind` | ✅ | `python` / `node` / `binary`，决定走哪条安装路线 |
| `spec` | ✅ | 版本锁定串（见下方硬规则 2） |
| `purpose` | ✅ | 这个工具干什么，人可读 |
| `required_by` | ✅ | 哪些能力域需要它（用于"这个能力依赖的工具装不上"时定位影响面） |
| `install` | ✅ | 安装命令模板，按 kind 取键：`uv` / `bun` / `url` |
| `verify` | ✅ | 安装后如何确认可用：`command` + `match`（输出里应包含的串） |

### 可选字段

| 字段 | 适用 kind | 说明 |
|---|---|---|
| `entry` | 全部 | 可执行文件名与 `name` 不同时指定（如包 `build` 的入口是 `pyproject-build`）。**只能是文件名**：不得含路径分隔符 / `..` / 绝对路径 / `~` |
| `module` | `python` | Python 模块名（默认取 `name`，连字符转下划线）。工具只提供模块入口时用它。**只能是模块名**：同样不得含路径分隔符 / `..` / 绝对路径 / `~` |
| `install.sha256` | `binary` | 下载产物的期望 sha256，不匹配则安装判为 `failed` |

> `entry` / `module` 会参与**文件路径**的拼装，所以必须与 `name` 同级对待。
> 白名单放行的是"名字"，但真正被执行的文件必须再受一层约束 ——
> 否则 `entry: "../../evil.sh"` 就能让 `qa run` 执行 `.tools/` 之外的任意文件。
> 越界的 `entry` / `module` 在**清单校验阶段**就被拒（退出码 1，报「入口路径越界」），
> `resolveExecutable()` / `qa run` / `qa which` 三处另有兜底断言。

### 四条硬规则

1. **版本必须锁定** —— `spec` 必须是精确版本，形态按 `kind` 分列：

   | kind | `spec` 形态 | 示例 |
   |---|---|---|
   | `python` | `name==version` | `bandit==1.7.7` |
   | `node` | `name@version` | `semver@7.7.2` |
   | `binary` | 纯版本号，或完整下载 URL | `1.0.0` / `https://host/tool-linux-amd64` |

   `>=` / `>` / `<=` / `<` / `~` / `^` / `*` / `latest` 一律**拒绝安装**，报「版本未锁定」。
   *理由：工具行为会变，工具版本是证据链的一部分。*
   *binary 之所以只有这两种形态：binary 路线没有包管理器，不存在「包名@版本」这个概念可写，
   要么只说「装哪个版本」，要么说「从哪拿」。*
2. **`install` 不得写到 `.tools/` 之外** —— 出现 `--user` / `--system` / `--global` /
   `--prefix` / `--root` / `-g` / `sudo` / `~` / `$HOME` / `..` / 指向 `.tools/` 之外的
   绝对路径，一律**拒绝安装**，报「安装路径越界」。
   *理由：污染系统后，"这个包到底装没装"会变成噩梦，CI 与本机行为也会分叉。*
3. **`verify` 必须存在** —— 装完不验证等于没装。`verify.command` 必须**退出码 0** 且
   输出包含 `verify.match`。
4. **`install` 只能跑包管理器** —— 模板的**第一个 token** 必须是该 kind 的包管理器：

   | kind | 允许的第一个 token | 说明 |
   |---|---|---|
   | `python` | `uv` / `pip` | `pip` 是 `uv` 缺失时的合法回退（venv 自带 pip） |
   | `node` | `bun` / `npm` | `npm` 是 `bun` 缺失时的合法回退 |
   | `binary` | — | 走下载 URL 路线，没有命令模板 |

   写成 `sh -c ...`、`curl ... | sh` 之类一律**拒绝安装**。
   *理由：只约束"写到哪儿"是不够的 —— 命令本身不受限，"只装包管理器"这条隐含约束就落空了。*

### `install` 模板的两种写法

`install` 的值按 kind 取键，键名后面是**运行时参数**：

- `{"uv": "pip install --no-deps {spec}"}` → 实际执行 `uv pip install --no-deps bandit==1.7.7`
- `{"bun": "bun add {spec}"}` → 实际执行 `bun add loadtest@8.2.1`

**运行时名写不写都行**：`{"bun": "bun add {spec}"}` 与 `{"bun": "add {spec}"}` 等价
（前导的 `bun` 不会被重复拼接）。`{spec}` 会被替换成工具的 `spec`，
`{tools}` 会被替换成 `<project-root>/.tools/` 的绝对路径。

运行时缺失时的回退：`uv` 缺失 → 用 venv 自带的 `pip`；`bun` 缺失 → 用 `npm`
（`add` 自动改写为 `install`）。

> ⚠️ **「两者都没有」指的是运行时与其回退都不可用**（无 `uv` 且无 `pip` / 无 `bun` 且无 `npm`），
> 这才判 `unavailable`。与之相对，清单里 `install` 块**取不到对应键**
> （缺 `install.uv` / `install.bun` / `install.url`）是**清单校验错误**：
> `qa install` 整体退出码 1 并报「工具 X 缺少 install.uv」，该工具**根本不会进入安装流程**，
> 既不是 `unavailable` 也不是 `failed`。模板存在但渲染后为空是防御分支，判 `failed`。

---

## 4. 统一入口 `qa`

```bash
qa [--project <dir>] <子命令> [参数...]
```

| 子命令 | 作用 |
|---|---|
| `qa init` | 在项目根生成 `.tools/manifest.json` 骨架与 `.gitignore` 规则（幂等） |
| `qa list [--verify]` | 列出清单里的工具及其状态 |
| `qa doctor` | 逐个跑 `verify` 做体检，不可用项明确列出 |
| `qa install [name...]` | 安装（缺省装全部）。幂等：已装且版本匹配则跳过 |
| `qa run <name> -- <args>` | 在 `.tools/` 隔离环境里执行工具。工具不在清单 → 拒绝 |
| `qa which <name>` | 打印工具的可执行路径（确认走的是 `.tools/` 里那份） |
| `qa isolation` | 负向验证隔离性（系统侧不可见 / 未污染） |

`--project <dir>` 可出现在任意位置；缺省用当前目录，也可用环境变量 `QA_PROJECT_ROOT`。

### `qa run` 的三条约束

1. **白名单式** —— 只执行清单里声明的工具。工具不在清单 → 退出码 2，**不执行任何命令**。
2. **PATH 以 `.tools/` 优先** —— 执行时 PATH 前缀是 `.tools/bin`、
   `.tools/.venv/bin`、`.tools/node/node_modules/.bin`。系统里恰好有同名工具时，
   跑的一定是 `.tools/` 里那份。
3. **不可用时明确报错** —— 退出码非 0，错误信息说清「工具 X 未安装 / 安装失败（原因）」，
   **不静默跳过**。

### 退出码

| 码 | 含义 |
|---|---|
| `0` | 成功 |
| `1` | 校验失败或工具不可用（清单非法、锁版本失败、越界安装、安装失败、verify 未通过、doctor 有不可用项） |
| `2` | 调用方式错误（未知子命令、缺参数、工具不在清单中） |

`qa run` 成功启动工具后，**透传被调工具自己的退出码**。

---

## 5. 状态语义（失败显式降级）

工具状态只有四种，**没有「跳过」**：

| 状态 | 含义 |
|---|---|
| `ok` | 已安装且 `verify` 通过 |
| `missing` | 清单里有，未安装 |
| `failed` | 安装尝试过但失败，或 `verify` 未通过（附原因） |
| `unavailable` | 当前环境装不了（网络受限、来源不可达、缺运行时、该 kind 在本环境不可用） |

### `failed` 与 `unavailable` 的分界（根因 → 状态）

| 根因 | 状态 |
|---|---|
| 下载源不可达（连接被拒 / DNS 失败 / 网络受限 / 超时） | `unavailable` |
| 下载源可达但返回非 404/410 的错误码（5xx 等） | `unavailable` |
| 下载源可达但返回 404 / 410（地址或版本不存在） | `failed` |
| `install.sha256` 不匹配 | `failed` |
| 安装命令执行报错（包不存在、编译失败等） | `failed` |
| 运行时缺失且回退也不可用（无 uv+pip / 无 bun+npm） | `unavailable` |
| 声明了但未安装 | `missing` |
| 已安装但 `verify` 未通过 | `failed` |

> **分界的唯一目的**：让人知道**该改环境还是该改清单**。
> 404 说明地址不对（或版本不存在），是**可修的配置问题**；判成 `unavailable`
> 会把一个改一行清单就能修好的错误，升级成"这个环境装不了"的错误结论 ——
> 那是把可修错误降级成不可修结论，比误报成功更糟。
>
> 一条例外：安装命令自身失败时，若其输出命中网络类特征
> （`ENOTFOUND` / `ECONNREFUSED` / `ETIMEDOUT` / `EAI_AGAIN` / `timed out` / `network` 等），
> 判 `unavailable`（环境问题），否则判 `failed`（清单或包的问题）。

**调用方（各能力域 skill）的义务**：拿到 `failed` / `unavailable` 时，
必须把对应能力标为「**不可用 / 未覆盖**」，**不得**报告为「未发现问题」。

> 理由（与整个套件一致）：**没有证据的「通过」比失败更危险。**
> 工具没装成却报告「没发现问题」，是在制造假的安全感。

`qa doctor` 在有任一工具非 `ok` 时退出码为 1；`qa install` 在有任一工具未就绪时退出码为 1。

> **清单校验错误是另一类**：清单本身不合法（缺必填字段、`install` 块缺对应键、
> 版本未锁定、安装路径越界、`entry` / `module` 越界、`install` 第一个 token 不是包管理器）时，
> `qa install` **在安装前**就整体退出码 1 并报「清单校验失败：…」，
> 此时工具不会进入安装流程，状态表不适用。

### 环境级结论

`qa doctor` 除了逐个工具给状态，还会把「索引/网络/运行时不可达」这类问题
**汇总成环境级结论**单独报出来（`[env] …` 行）。理由：这类失败修的是**环境**，
不是清单 —— 只看到"某个工具 failed"会让人去改清单，改完还是失败。

`qa install` 遇到同类失败时也会给一行 `[env]` 提示。两者都**不写任何文件**
（`qa doctor` 是只读体检：跑完 `.tools/` 目录树逐项不变）。

---

## 6. `state.json`

```json
{
  "version": 1,
  "updated_at": "2026-11-11T18:00:00.000Z",
  "tools": {
    "pyflakes": {
      "name": "pyflakes",
      "kind": "python",
      "spec": "pyflakes==3.2.0",
      "version": "3.2.0",
      "source": "uv",
      "source_detail": {
        "runtime": "uv",
        "command": "uv pip install --no-deps pyflakes==3.2.0",
        "source": "https://pypi.tuna.tsinghua.edu.cn/simple",
        "target": "/abs/path/.tools"
      },
      "executable": "/abs/path/.tools/.venv/bin/pyflakes",
      "checksum": "…sha256…",
      "size_bytes": 12345,
      "installed_at": "2026-11-11T18:00:00.000Z",
      "status": "ok",
      "reason": null
    }
  }
}
```

用途：幂等（版本匹配则跳过安装）、可追溯（报告里能说清用的是哪个版本）、
失败留痕（`failed` / `unavailable` 也会写进来，不会「装不上就当没事」）。

> `checksum` 是**已安装可执行文件**的 sha256，不是上游发布包的哈希
> （解释型工具的产物由包管理器生成，上游哈希无从获取）。需要上游哈希时用
> `install.sha256` 在 binary 路线上做校验。

---

## 7. 隔离性

| 要求 | 验证方式 |
|---|---|
| Python 工具装进 `.tools/.venv/`，系统 `python3 -c "import X"` 仍失败 | `qa isolation` + 系统侧负向验证 |
| Node 工具装进 `.tools/node/`，系统 `command -v <tool>` 无输出 | 同上 |
| `qa run` 实际执行的是 `.tools/` 里那份 | `qa which <name>` 的输出必须在 `.tools/` 下 |

**隔离性的负向验证是必须的** —— 「装完不污染」不能靠声称，要靠实测。

`qa isolation` 会跑负向检查：系统 Python 能否 import 该模块、系统 PATH 里能否找到同名
工具、已装入口是否落在 `.tools/` 内。系统存在同名工具时不算隔离失败
（`qa run` 的 PATH 以 `.tools/` 优先，仍走隔离副本）。

---

## 8. 环境约束与已知限制

| 事实 | 影响 |
|---|---|
| 仅 PyPI 镜像与 npmmirror 可达，GitHub releases 不可达 | 单二进制工具（`nuclei` / `trivy` / `osv-scanner`）装不上 → 不要写进清单 |
| npmmirror 的二进制镜像 404 | 纯 JS 工具可装；预编译二进制不可得 |
| Docker daemon 未运行 | 容器化隔离不可用 → 只能靠目录级隔离 |
| 索引源来自环境变量 | Python 路线：`UV_DEFAULT_INDEX` / `UV_INDEX_URL`；Node 路线：`npm_config_registry` / `NPM_CONFIG_REGISTRY`。`qa` 不写死镜像地址 |

### 索引源：uv 认哪些变量（**别被 `PIP_INDEX_URL` 骗了**）

| 路线 | 生效的环境变量 | 备注 |
|---|---|---|
| Python（uv） | `UV_DEFAULT_INDEX`、`UV_INDEX_URL` | **优先级高于** `uv.toml` 里的 `default-index` |
| Python（pip 回退） | `PIP_INDEX_URL`、`PIP_EXTRA_INDEX_URL` | 仅当 `uv` 缺失、改用 venv 自带 `pip` 时才生效 |
| Node（bun / npm） | `npm_config_registry`、`NPM_CONFIG_REGISTRY` | 其次是项目 `.npmrc`、用户 `~/.npmrc` 的 `registry=` |

> ⚠️ **`PIP_INDEX_URL` 对 uv 路线不生效** —— uv 不读 pip 的环境变量，也不读
> `/etc/pip.conf`。`qa` 上报的来源只采信包管理器**真正会用的**地址：
> 解析顺序为 `环境变量 > 项目 uv.toml > 用户 uv.toml > 内置默认`，
> 并把解析结果显式交给子进程（uv 路线设 `UV_DEFAULT_INDEX`，node 路线设
> `npm_config_registry`），**保证 `state.json` 上报的来源 == 实际请求的来源**。
>
> 记一个没用过的地址，比不记更糟 —— 那会让证据链说谎。

### python 路线需要可达镜像

uv 默认走 `https://pypi.org/simple`，本机时通时不通。**装 python 工具前先设索引源**：

```bash
export UV_DEFAULT_INDEX=https://mirrors.aliyun.com/pypi/simple   # 或任何可达镜像
export UV_INDEX_URL="$UV_DEFAULT_INDEX"                            # 兼容老版本 uv
```

索引不可达时，`qa install` 会报 `unavailable`，`qa doctor` 会把它**汇总成环境级结论**：

```
[env] 1 个工具因**环境不可达**未就绪（bandit）—— 这是环境级结论，不是清单问题
       先修环境再重试：python 路线 export UV_DEFAULT_INDEX=<可达镜像>；…
```

**分界**：索引/网络/运行时不可达 → 修**环境**；404/410、版本未锁定、清单字段非法 →
修**清单**。搞错方向会白折腾（见 §5 的分界表）。

**已知限制**：

- **binary 路线只支持直链下载的单个可执行文件**（`install.url` + 可选 `install.sha256`），
  **不支持压缩包解压**（zip / tar.gz）。需要时在清单外自行解压。
- **Windows 未支持**：路径分隔符、`bin/` 可执行入口、`.venv/bin` 布局都是 POSIX 假设。
  在 Windows 上会明确报错，不会假装支持。
- `qa run` 的工作目录是项目根，不是 `.tools/`。

---

## 9. 与其他 REQ 的关系

- **前置**：REQ-002.3（目录契约）—— `.tools/` 的位置已定。
- **后续**：REQ-002.8（安全工具）、REQ-002.9（压测工具）—— 二者的工具清单由本机制承载。
- **并行**：可与 REQ-002.5b 并行 —— 本机制只碰 `.tools/` 路径与 `bin/qa`，
  不碰 `skills/test-case-design/` 与 `skills/test-execute/`。
