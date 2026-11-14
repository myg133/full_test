# REQ-012 施工单（需求方 → 实现方）

> **标题**：压测能力域 A 阶段 —— `load-profile` skill 的 **runner 适配**（负载模型 → 工具可消费的压测计划）
> **编号**：REQ-012（承 REQ-009；架构 §8 的 `REQ-002.9` = `load-profile` skill（负载模型 + **runner 适配**））
> **勘察依据**：`$HOME/.local/share/agent-runtime-data/tmp/req012/PROBE-FACTS.md`（**第一手实测/读源码**，别重复调研）
> **决策**：需求方 2026-11-14 已拍板 —— **A 阶段先做**「规划产物可被真实压测工具消费」；B 阶段（负载级执行与判定链）**单独立项**（REQ-013），且 **B 阶段只打本地桩服务，绝不打真实服务**。

---

## 0. 本 REQ 的一句话定位

**REQ-009 产出了「负载模型」；REQ-012 补上「怎么用真实压测工具把它压出去」——但一个请求都不发。**

产出的是**计划**（该敲什么命令），不是**结果**（压出来什么样）。

---

## 1. 交付边界（做什么 / 不做什么）

### 1.1 做

1. **在 `skills/load-profile/` 内新增 runner 适配器**：读 REQ-009 的负载模型 + 套件，产出**工具可执行的压测计划**（命令清单形态）。
2. **参数映射**：`profile.steps[]` → 工具的并发/时长参数；`args` → 工具的其余参数；`target`（`METHOD /path`）+ 环境的 `base_url` → 完整 URL。
3. **多段保真**：`steps[]` 是多段（ramp-up 两段），工具 CLI 是单段 ⇒ **每段一条 invocation**，**不许合并成一条**（合并 = 丢梯度信息 = 失真）。
4. **可执行的产物**：计划里的每条 invocation 是一条**完整可跑的 argv**（含工具名与 URL），任何人复制就能跑。
5. **校验器**：复核计划与模型一致（不改模型、不改计划）。

### 1.2 不做（**越界即红**）

| # | 不做 | 为什么 |
|---|---|---|
| 1 | **不发任何请求**（不 spawn 压测工具、不联网、不打桩） | 本 REQ 只产出**计划**。执行属 B 阶段（REQ-013） |
| 2 | **不装工具** | `loadtest` 由 `qa-toolchain` 管（`.tools/manifest.json`）；本 REQ 只**声明**依赖，不装 |
| 3 | **不改 REQ-009 的产物** | `scenarios/` / `suites/` / `report.json` **逐字不动**（`skills/load-profile/` 的既有 14 文件一个都不许改，除非本单明确点名） |
| 4 | **不改 `test-execute`** | 执行器、证据链、`not_implemented` 全不动。`load` 仍是 `not_implemented` |
| 5 | **不做阈值判定** | 阈值是**判定**用的，属 B 阶段。计划**可以携带**阈值（供人看），但**绝不产出任何「已达标/未达标」的结论** |
| 6 | **不写 `cases.json`**、不派生用例 | 沿用 REQ-009 |
| 7 | **不新增 skill 目录** | 这是 `load-profile` skill 的延续（PROBE-FACTS B4） |

---

## 2. 设计岔路的**需求方裁定**（已拍板，实现方照做，不要自己改）

| # | 岔路 | **裁定** | 理由 |
|---|---|---|---|
| G1 | **产物形态** | **(a) 每套件一个命令清单 JSON** | 结构化 ⇒ 后续 B 阶段能直接消费；shell 脚本不可被机器读 |
| G2 | **落点** | **(a) `test-assets/load/plans/`** | 仍在 load 能力域内（REQ-009 AC-026 只允许写 `test-assets/load/`） |
| G3 | **多段怎么落** | **(a) 每 step 一条 invocation** | 合并 = 有损 = 失真。`ramp-up` 的两段必须都在 |
| G4 | **`args` 未知键** | **(a) 拒绝**（rc=1，点名未知键） | 「静默忽略」= 悄悄丢参数 = 压出来的不是你想压的；**诚实优先于宽容**（沿用 REQ-009 的纪律） |
| G5 | **多核** | **(a) 显式钉 `--cores 1`** | 默认是半核且会把 `-n`/`--rps` 按核分摊（PROBE-FACTS C14/D8）⇒ 不钉则语义随机器变 |
| G6 | **`python` runner** | **(b) 由 `args` 显式声明完整命令** | 契约里钉死一种形态是凭空规定；`args` 开放 ⇒ 让实现自陈，但**必须自陈完整**，不许含糊 |
| G7 | **要不要门** | **(a) 要**，沿用 REQ-009 模式 | 门是交付物，必须被当作被验对象（D65） |

---

## 3. 功能契约 F1~F8（实现方按此交付）

### F1 入口与用法

```
node skills/load-profile/scripts/plan-load-run.mjs \
  --load-dir <含 test-assets/load/ 的项目根> \
  --out-dir  <项目根>
```

- `--load-dir` 与 `--out-dir` **必需**；指向同一项目根时最自然。
- 退出码：`0` 成功 / `1` 输入非法或违反写入纪律 / `2` 用法错误。
- 零第三方依赖，只用 Node 内置模块。

### F2 输入

- **负载模型**：`<load-dir>/test-assets/load/scenarios/*.json`（REQ-009 产物，字段集封闭 14）。
- **套件**：`<load-dir>/test-assets/load/suites/*/scenario.json`（引用件）+ `suite.json`。
- **环境**：`<load-dir>/test-assets/environments/<环境名>.json` 的 `base_url`（**只读**，不改不建）。

### F3 输出（**这是本 REQ 的核心交付形态**）

`<out-dir>/test-assets/load/plans/<套件名>.json`，每个套件一个：

```json
{
  "schema_version": 1,
  "suite": "LOAD-001-checkout",
  "environment": "local",
  "runner": "loadtest",
  "runtime": "bun",
  "target": "POST /api/v1/checkout",
  "base_url": "http://127.0.0.1:8080",
  "profile_type": "ramp-up",
  "invocations": [
    { "step_index": 0, "duration_s": 60, "concurrency": 10,
      "argv": ["loadtest", "-t", "60", "-c", "10", "--cores", "1", "http://127.0.0.1:8080/api/v1/checkout", "-m", "POST"] },
    { "step_index": 1, "duration_s": 120, "concurrency": 20,
      "argv": ["loadtest", "-t", "120", "-c", "20", "--cores", "1", "http://127.0.0.1:8080/api/v1/checkout", "-m", "POST"] }
  ],
  "thresholds_status": "provided",
  "thresholds": { "p95_latency_ms": 800, "error_rate": 0.01 },
  "thresholds_source": "需求 REQ-005 性能指标",
  "open_questions": []
}
```

**字段规则**：
- 顶层字段集**封闭**（具体几个由契约钉死，实现方不得增删）。
- `invocations[]` 的元素字段集封闭，**每元素必须含 `argv`（完整可跑的 argv 数组）**。
- `argv` 里**必须**含工具名与完整 URL ⇒ 复制即可跑。
- **不得**出现任何压测结论键（`status`/`result`/`verdict`/`executed`/`passed`/`outcome`/`conclusion`）—— **注意 `thresholds_status` 不算 `status`**（沿用 REQ-009 的口径）。
- 阈值**可以携带**（`thresholds` / `thresholds_source` / `thresholds_status` 逐字来自模型），但**不带任何判定结论**。

### F4 参数映射（`loadtest` runner）

| 模型字段 | → argv | 备注 |
|---|---|---|
| `profile.steps[i].duration_s` | `-t <秒>` | 整数秒 |
| `profile.steps[i].concurrency` | `-c <并发>` | 整数 |
| —— | `--cores 1` | **恒定钉死**（G5） |
| `target` 的方法 | `-m <METHOD>` | 大写 |
| `base_url` + `target` 的路径 | 位置参数（完整 URL） | **URL 必须是完整绝对 URL** |
| `args.rps` | `--rps <值>` | |
| `args.keepalive`（true） | `-k` | false ⇒ 不给 |
| `args.timeout_s` | `-d <毫秒>` | **秒 → 毫秒 ×1000**（易错点，契约要钉死） |
| `args.<其它已知键>` | 见 F4.1 | |
| `args.<未知键>` | **拒绝**，rc=1，点名该键 | G4 |

**F4.1 `args` 的已知键白名单**（实现方按此；白名单之外的键 ⇒ 拒绝）：

| `args` 键 | 类型 | → argv | 说明 |
|---|---|---|---|
| `rps` | number > 0 | `--rps <值>` | 每客户端 rps（PROBE-FACTS C6） |
| `keepalive` | boolean | `-k` | true 时给 |
| `timeout_s` | number > 0 | `-d <值×1000>` | **单请求**超时（毫秒） |
| `method` | string | `-m <值>` | 覆盖 `target` 的方法（可选） |

### F5 `python` runner（G6）

`tool.runner == "python"` ⇒ **必须**由 `args` 显式声明完整命令，否则 **rc=1** 并点名缺哪个键。

建议形态（实现方自定键名，但契约只钉「必须自陈完整」这一条）：
- `args.command`：**完整命令的 argv 数组**（如 `["python", "-m", "mylab", "--concurrency", "10"]`）。
- 计划里该套件的 `invocations[].argv` = **声明的命令 + 映射进来的参数**（时长/并发等），**不得**执行。

⚠️ **不许**为 `python` runner 编造一条默认命令 —— 没有事实支撑的命令 = 凭空造。

### F6 写入纪律（沿用 REQ-009 的硬约束）

- **只写** `<out-dir>/test-assets/load/plans/`。
- **先校验、后建目录**：输入非法 ⇒ **不留半份产物**（`plans/` 一个都不许出现）。
- **产物已存在 ⇒ 报错退出，不覆盖**。
- **幂等**：同一输入两次跑 ⇒ 两份计划**逐字相同**（**不含**生成时间戳 / 随机 id / 宿主路径）。
- **输入只读**：模型、套件、环境文件一律不改写。

### F7 诚实性

- 计划里**不得**出现任何压测结论键。
- **不得**出现「已压测」「已达标」之类的表述。
- `thresholds_status == "not_provided"` 的场景 ⇒ 计划里**也不得**有阈值键（沿用 REQ-009 的「键的有无」口径），并**必须**携带该场景的 `topic=thresholds` 未决问题。

### F8 校验器

`node skills/load-profile/scripts/check-load-run.mjs <项目根>`：
- 复核 `plans/*.json` 与 `scenarios/` / `suites/` **一致**（条数、顺序、`argv` 参数与模型逐字对得上）。
- 复核无结论键、无半份产物、字段集封闭。
- 退出码同 F1。

---

## 4. 实现方必须自测的项（**不写进交付物也没关系，但要在报告里给出真实输出**）

| # | 自测 |
|---|---|
| 1 | 夹具跑一遍 ⇒ 计划形态与 F3 的示例**逐字对得上** |
| 2 | **多段保真**：ramp-up 的两条 invocation **都在**，`duration_s`/`concurrency` 逐字对应 |
| 3 | **URL 拼接**：完整 URL、无尾斜杠错乱、方法与路径分离正确 |
| 4 | **`timeout_s` → `-d` 的毫秒换算**（`10` ⇒ `-d 10000`） |
| 5 | **未知 `args` 键** ⇒ rc=1 + 点名 + **不留 `plans/`** |
| 6 | **`python` runner 缺命令** ⇒ rc=1 + 点名 |
| 7 | **幂等**：两次跑逐字相同 |
| 8 | **产物已存在** ⇒ rc=1 + 既有产物未变 |
| 9 | **只写 plans/**：`scenarios/`、`suites/`、`environments/` 跑前跑后逐字未变 |
| 10 | **零请求**：自测期间**没有**任何 HTTP 请求发出（可用桩服务计数器或直接断言无网络调用） |

---

## 5. 需求方会做的独立验收（**你必须能过**）

1. **独立验收门**（需求方写，含变异体套件）⇒ 判据逐条判红/判绿。
2. **外部探针套件**（需求方自建，先自测工装再用）⇒ 探针必须被检出。
3. **T1 语义复算**（独立 verifier，**零 import** 被验包）⇒ 逐字段复算。
4. **上游门回归**（REQ-009/010/011/007/008/006 + 002A/002B + 组合门）⇒ **既有契约一个都不许被打破**。
5. **交付红线**：交付物不得含内部运行时字样；`npm pack` 里 `feature-meta` **0 条**。

⚠️ **重点**：REQ-009 的门会检查 `skills/load-profile/` 的**结构与指纹** —— 你**新增**文件是可以的（AC-001 只要求那些文件存在非空），但**不许改** REQ-009 既有 14 个文件的内容。改了就可能被 REQ-009 的门判红。

---

## 6. 提交格式

```
[实现] REQ-012 load-profile runner 适配：<简述> (关联: REQ-012) [session: mvs_744b60ef3d984cffbcd54448ac77bd8c]
```

---

## 7. 需求方**没有**验到、你也**不必**做的

- 真实压测工具**是否真的能跑**（本 REQ 不执行 ⇒ 只保证 argv 形态正确、参数名真实存在）。
- B 阶段的负载级判定与证据链。
- 任何真实服务的容量表现。

**不许**在交付物里声称「已验证压测可跑」—— 那是不存在的事实。
