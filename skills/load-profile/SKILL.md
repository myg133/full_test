---
name: load-profile
description: |
  Turn a load-testing context into a load model: read the capacity targets, load profiles and metric thresholds (with their sources) plus an optional functional case set, and emit one load-model body per capacity target, one load suite per target environment, and a load plan listing — scenarios/<场景>.json, suites/LOAD-<编号>-<短名>/{scenario.json,suite.json} and report.json under test-assets/load/.
  Use this skill when the user asks to "压测规划"、"负载模型"、"压测画像"、"容量目标"、"load profile"、"load scenario"、"压测套件", or when a service needs a load model before anyone sends pressure.
  It answers "每条容量目标要压成什么样、阈值有没有依据、这条被压链路有没有回归护栏" — it does NOT send pressure (the load executor is not implemented yet; that is a later REQ), it does NOT write cases.json, it never invents thresholds without a source, and it never writes a "passed" verdict for something that was never run.
---

# 压测规划（容量目标 → 负载模型 → 压测套件）

把一份**压测上下文**变成一份**可消费的压测计划**：

```
压测上下文 ──► 负载模型本体 ──► 压测套件（按环境分组）──► 压测计划清单
```

**判定一律走脚本。** 三条硬约束：

| 约束 | 为什么 |
|---|---|
| **没有指标来源就不写阈值** | 凭空拍的阈值让压测结论毫无意义 ⇒ 用**阈值键的有无**表达（`thresholds_status` 二态），并留一条 `topic=thresholds` 的未决问题 |
| **阈值与来源必须成对** | 「有阈值没来源」= 凭空拍；「有来源没阈值」= 自相矛盾 ⇒ 两种都在**输入层**就拒（rc=1） |
| **未压测 ≠ 已通过** | 本 skill 只做规划、不发压 ⇒ 产物里**一个**压测结论字段都不许出现（`status` / `result` / `verdict` / `executed` / `passed` / `outcome` / `conclusion`） |

## 怎么用

```console
# 1) 产负载模型与压测套件（产物落在 <out-dir>/test-assets/load/）
node scripts/make-load-profile.mjs \
  --context test-assets/inputs/load-context.json \
  --cases   test-assets/suites/REQ-004-order/cases.json \
  --out-dir .

# 2) 复核产物是否自洽（字段集封闭、引用不漂移、覆盖完整、无结论字段）
node scripts/check-load-profile.mjs .
```

`--context` 与 `--out-dir` 必需；`--cases` 可选（用于**链路存在性**对账）。
退出码：`0` 成功 / `1` 输入非法或违反写入纪律 / `2` 用法错误。

## 产物长什么样

```
<out-dir>/test-assets/load/
├── report.json                                  # 压测计划清单（套件 ↔ 场景映射 + 未决问题）
├── scenarios/<场景>.json                        # 负载模型本体（每个容量目标一个，字段集封闭 14 个）
└── suites/LOAD-<编号>-<短名>/
    ├── scenario.json                            # 套件级**引用件**（封闭 3 个，指向 scenarios/）
    └── suite.json                               # scope=load / executor=load / cases_file=scenario.json
```

- **套件按环境分组**（多对一）：同一 `environment` 的容量目标进同一个套件；编号按 `environments[]` 的出现顺序分配；短名取该套件**第一个**场景的 `name`。
- **套件级 `scenario.json` 是引用，不是模型副本**：每个引用带 `id` / `name` 两个**防漂移锚点**，本体改了身份而引用没改 ⇒ 漂移判红。
- `suite.json` 的顶层字段集 ⊆ 上游 **9 个**允许字段（**不许**出现 `load_scenario` 这类 scope 专属字段）。

## 边界

- **只读输入**：压测上下文 / 功能用例集一律不改写。
- **只写自己的目录**：只写 `<out-dir>/test-assets/load/`；产物已存在 ⇒ 报错退出（**不覆盖**）。
- **先校验、后建目录**：输入非法时**不留半份产物**（`test-assets/load/` 一个都不许出现）。
- **幂等**：产物**不含**生成时间戳 ⇒ 同一输入两次跑出来的文件**逐字相同**。
- **不发压**：不跑 runner、不统计 TTFT/TPS/吞吐、不判容量拐点（`load` 执行器尚未实现，属后续 REQ）。
- **不写 `cases.json`**、不派生用例（用例设计归 REQ-006）；压测用例不是「步骤 → 预期」形态。
- **不扩方法库**：产物里**不写** `method` 字段（方法库里没有压测方法）。
- **不创建/修改环境配置**、不改轮次状态：上下文里的 `environments[]` 是「**目标环境清单**」，环境文件由项目提供。
- **不装工具**、**不联网**：`tool.runner` / `tool.runtime` 只是**声明**（工具由 `qa-toolchain` 管）。
- 零第三方依赖：只用 Node.js 内置模块。

## 判定规则在哪

- `references/load-context-schema.md` —— 压测上下文格式（顶层封闭 5 个、workload 封闭 10 个、阈值成对规则、两层退出码）。
- `references/load-scenario-format.md` —— 负载模型本体与套件级引用件的产物契约（字段集封闭 14 / 3）。
- `references/profile-rules.md` —— 负载画像、阈值与**链路存在性**对账规则（归一化与未决问题口径）。
- `scripts/check-load-profile.mjs` —— 产物自洽校验器（拿已产出的产物复核一份）。

## B 阶段：负载级执行与判定链（**只打本地桩**）

> 上文「`load-profile` 的描述」里那句「load 执行器尚未实现」指的是 **A 阶段**（REQ-012 的规划入口：
> 负载模型 → 压测计划，**零请求**）。**B 阶段**（本节）把计划**真的跑起来**并给出**阈值判定**。

A 阶段交的是「命令清单」，B 阶段交的是「**执行器 + 判定器 + 桩服务**」：

```console
# 1) 消费 REQ-012 的压测计划 ⇒ 真的跑起来（只打本地桩）⇒ 判定产物 + 负载级证据
node scripts/run-load-test.mjs \
  --load-dir <项目根> \
  --out-dir  <项目根> \
  --suite    <套件名> \
  [--mode api|cli] [--stub-delay-ms <N>] [--stub-error-rate <R>]

# 2) 复核产物是否自洽（字段集封闭、判定口径、证据清单 sha256 可复算）
node scripts/check-load-test.mjs <项目根> --suite <套件名>
```

退出码：`0` 跑完（**哪怕不达标也是 0**） / `1` 输入非法、工具不可用、目标非回环、产物已存在 /
`2` 用法错误。

### ⛔ 边界：**只打本地桩，绝不打真实服务**

| 边界 | 口径 |
|---|---|
| **目标必须是回环地址** | 计划里的 URL 与替换后的执行 URL **都**必须是 `127.0.0.0/8` 或 `::1`；非回环 ⇒ **rc=1 + 点名** |
| **origin 只换 origin** | 协议 + 主机 + 端口换成桩地址；**path 与 query 逐字保留** |
| **桩只监听回环** | 桩自带计数 / 延迟直方图 / 延迟与错误注入，**不含任何真实业务逻辑**；**生命周期由执行器托管**（异常与中断路径也必停） |
| **结论只在本地桩上成立** | 产物里**不得**出现「生产环境容量达标」这类表述；**必须**带「本地桩 / `127.0.0.1`」的限定 |

### 判定口径（**封闭 3 值**：`met` / `not_met` / `undetermined`）

- 阈值**只**吃计划里逐字携带的 `thresholds`（键集封闭 6 个）；
- **默认桩**（未注入延迟与错误）下，延迟类 / 错误率类阈值判 **`undetermined`**（**不是**「达标」）；`throughput_rps` 仍可判；
- **`max_concurrency` 恒判 `undetermined`**（没有对应观测量 ⇒ 不许拿 `concurrency` / `clients` 冒充实际并发）；
- **`python` runner 一律 `undetermined`**（输出形态无契约），但**照常执行**并**留下证据**；
- 判定**不依赖进程退出码**（桩中途挂掉时压测工具仍然 rc=0 ⇒ 只看退出码 = 假绿）。

### 产物（**只写** `<out-dir>/test-assets/load/results/`）

```
<out-dir>/test-assets/load/results/
├── <套件名>.json                    # 负载级判定产物（顶层封闭 8 个键）
└── evidence/<套件名>/
    ├── manifest.json                # 逐个证据文件的 sha256
    └── <场景标识>/<step_index>/     # 每条 invocation 一个证据目录
        ├── result.json  ├── stdout.txt  └── stub-observations.json
```

- **只读**输入（计划 / 模型 / 环境一律不改写）；**先校验、后建目录**（输入非法 ⇒ `results/` 一个都不许出现）；
- **产物已存在 ⇒ rc=1 不覆盖**；
- **幂等只承诺结构级**（键集、键序、判定口径一致；数值允许抖动 —— 压测是随机过程）。

判定规则在哪：`references/load-exec-contract.md`（B 阶段契约：两个入口 / 桩 / 反解层 / 判定映射 / 产物形状 / 已知限制）。
