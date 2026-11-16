# REQ-013 Dev 派工单（`DEV-BRIEF.md`）

> **收件人**：Dev（实现方）· **发件人**：需求方（BA）
> **契约是唯一依据**：本工单**不重复**契约内容，只说「做什么 / 在哪做 / 怎么验 / 不许做什么」。
> ⚠️ **发现契约有问题 ⇒ 上报需求方，不许自改契约**（角色分离）。

---

## 1. 做什么

实现 REQ-013 = `load-profile` skill 的 **B 阶段「负载级执行与判定链」**：
消费 REQ-012 产出的压测计划，**真的跑起来**（打**本地桩**），并按 REQ-009 的阈值给出**判定结论**。

**一句话**：A 阶段交的是「命令清单」，你交的是「**执行器 + 判定器 + 桩服务**」。

---

## 2. 在哪做

| 项 | 值 |
|---|---|
| 工作目录 | `<REPO_ROOT>/feature-REQ-013`（**已存在**，分支 `feature/REQ-013`，基于 develop） |
| 你的改动范围 | `skills/load-profile/`（**只在这里**）+ `feature-meta/load-runner/`（追溯件） |
| ⛔ 不许碰 | `skills/` 下的**其它 7 个 skill** · `bin/` · `package.json` · `README.md` · `LICENSE` · `BA/` |

---

## 3. 必读（**按顺序读，不要跳**）

| # | 文件 | 为什么 |
|---|---|---|
| 1 | `BA/demands/REQ-002-suite-foundation/REQ-013-load-exec/demand.md` | **功能契约 F1~F10** + 产物形状 + 夹具规格 ⇒ 你的实现依据 |
| 2 | `BA/demands/REQ-002-suite-foundation/REQ-013-load-exec/acceptance.md` | **41 条判据 AC-001~AC-041** ⇒ 验收标准 |
| 3 | `BA/demands/REQ-002-suite-foundation/REQ-013-load-exec/decisions.md` | **26 条决策 D185~D210** ⇒ 歧义时的裁定依据 |
| 4 | `BA/demands/REQ-002-suite-foundation/REQ-013-load-exec/PROBE-FACTS.md` | 勘察事实（**loadtest 的执行面 API、实测数据、已知陷阱**） |
| 5 | `skills/load-profile/references/runner-adapters.md` | REQ-012 的 runner 契约（你要消费它的 `argv`） |
| 6 | `skills/load-profile/references/profile-rules.md` | 阈值键白名单 6 个 |

⚠️ **判据条数守恒 41、决策号守恒 26** —— 你**不得**改契约，也不得在实现里引用不存在的决策号。

---

## 4. 交付物（**7 项**）

| # | 交付物 | 位置（相对你的 worktree 根） |
|---|---|---|
| 1 | 执行入口 | `skills/load-profile/scripts/run-load-test.mjs` |
| 2 | 产物自洽校验器 | `skills/load-profile/scripts/check-load-test.mjs` |
| 3 | 桩服务 | `skills/load-profile/scripts/lib/stub.mjs` |
| 4 | 执行器 / 判定器 | `skills/load-profile/scripts/lib/load-exec.mjs` |
| 5 | 契约文档 | `skills/load-profile/references/load-exec-contract.md`（**新文件**） |
| 6 | SKILL.md | **只追加**一节（B 阶段入口与「只打本地桩」边界）；**既有内容逐字不改** |
| 7 | 追溯件 | `feature-meta/load-runner/` 四件套**追加** REQ-013 的条目（**不覆盖** REQ-012 的内容） |

---

## 5. 已勘察的事实（**别重查，直接用**）

- `loadtest@8.2.1`：**CLI 无 JSON 输出**，但**包提供 API** ——
  `import { loadTest } from '<loadtest>/index.js'`，回调直接给结构化 `Result`。
  ⚠️ **不要解析 stdout**（api 模式）。
- ⚠️ **不设 `statusCallback` ⇒ 所有 HTTP 错误码塌成 `-1`** ⇒ api 模式**必须**设它（AC-039 会判）。
- API 选项名：`maxSeconds` / `concurrency` / `requestsPerSecond` / `agentKeepAlive` / `timeout`(毫秒) / `url` / `method`
  ⇒ 与 REQ-012 的 CLI 形态 argv **不是一套名字** ⇒ 需要**反解层**（AC-026 会判反解一致性）。
- `Result` 字段：`totalRequests` / `totalErrors` / **`errorCodes`**（**不是** `errors`）/ `meanLatencyMs` /
  `effectiveRps` / `percentiles{50,90,95,99}` / `maxLatencyMs` / `minLatencyMs` / `elapsedSeconds` / `clients` / `concurrency`。
- ⚠️ **客户端侧请求数比桩侧少约等于并发数**（在途请求）⇒ 判据只判**上界**，别写等式。
- ⚠️ **桩中途挂掉时 loadtest 仍返回 rc=0** ⇒ 判定**不得依赖退出码**。
- ⚠️ **全部失败时 `effectiveRps` 依然很高** ⇒ 吞吐必须与错误率**联合判**。
- ⚠️ **API 也会读 `.loadtestrc`** ⇒ 必须**显式覆盖**每个相关选项并**显式禁 `proxy`**。
- **桩会残留** ⇒ 生命周期必须由执行器托管（起 / 等就绪 / 停 / 异常路径也停）；
  停桩时**连同残留连接一起断开**（keep-alive 空闲连接会拖住 `close()`）。
- **桩侧延迟必须聚合**（按 ms 桶的直方图），**不存全量样本**（1.4 万次请求存全量 ⇒ 产物爆炸）。

---

## 6. 工具前置（**验收前置，不是你的活**）

`loadtest@8.2.1` 必须装到**夹具项目根**的 `.tools/node/node_modules/loadtest/`。
验收门**不装工具**（契约 §0.1）⇒ 工具缺失时门会明确报错（AC-033）。
安装方式（需求方已在验收环境备好）：`node <REPO_ROOT>/code/bin/qa install --project <项目根>`。

⚠️ `.tools/manifest.json` 的 `verify.match` 必须是 **`"Loadtest"`（大写 L）** ——
`loadtest --version` 的真实输出是 `Loadtest version: 8.2.1`；写小写会让 `qa doctor` 判 failed。

---

## 7. 怎么验（**验收门**）

门：`BA/demands/REQ-002-suite-foundation/REQ-013-load-exec/verify-acceptance.sh`
**定稿 sha256**：`e4743970c04defb76aeb8b060d27ecff0078e78e0ee92f5a07e574af00eb6f0f`

```bash
G=<REPO_ROOT>/BA/demands/REQ-002-suite-foundation/REQ-013-load-exec/verify-acceptance.sh
SHA=e4743970c04defb76aeb8b060d27ecff0078e78e0ee92f5a07e574af00eb6f0f
P=<REPO_ROOT>/feature-REQ-013          # 你的 worktree 根 = 被验包根
export QA013_SCRIPT_SHA=$SHA QA013_LOADTEST_SRC=$HOME/.local/share/agent-runtime-data/tmp/req013/lt

QA013_NO_MUT=1 QA013_WORK_ROOT=/tmp-ia-qa013 bash $G $P      # 快跑：期望 41 PASS / 0 FAIL，rc=0
QA013_WORK_ROOT=/tmp-ia-qa013 bash $G $P                     # 完整模式：期望 41/41 变异体全检出 + 负控未检出，rc=0（≈42 分钟）
```

⚠️ **工作根目录要每个命令不同**（并发跑会产生无因果关系的额外失败键）。
⚠️ `/tmp` 在本机**不可写** ⇒ 用 `~/.local/share/agent-runtime-data/tmp/qa013-*/`。

---

## 8. 硬约束（**违反即返工**）

1. **只打本地桩**：目标地址**必须**是回环地址；非回环 ⇒ **rc=1 + 点名**（AC-032）。**绝不**打任何真实服务。
2. **不改契约**（三件套一个字都不许改）；发现问题**上报**。
3. **不改上游**：`skills/` 下其它 7 个 skill · `bin/` · `package.json` · `README.md` · `LICENSE` · `BA/`。
4. **不装工具**（工具链是 REQ-003 的事）。
5. **不改 `test-execute` / `test-report`**（负载级产物**不塞进** `report.json`）。
6. **诚实性**：产物里**不得**出现「生产环境容量达标」这类表述；**必须**出现「本地桩」限定；
   `undetermined` **不得**写成 `passed`；**不得**编造观测量（CLI 模式拿不到最小延迟 ⇒ 记 `null`）。
7. **默认桩下**：延迟类 / 错误率类阈值**必须**判 `undetermined`（**不是** `met`）——
   这是本 REQ 最核心的红线，AC-019 会判。
8. **写入纪律**：只写 `test-assets/load/results/`；**输入只读**；产物已存在 ⇒ **rc=1 不覆盖**。
9. **退出码**：跑完（哪怕不达标）⇒ `0`；输入非法 / 工具不可用 / 非回环 ⇒ `1`；用法错误 ⇒ `2`。
10. **不留残留**：执行结束（含异常与中断）后**桩必须已停**（AC-035 会探端口）。
11. **幂等（结构级）**：同一输入两次跑 ⇒ **结构**逐字相同（数值允许抖动）⇒ AC-030 的归一化清单共 **6 类**（契约里列了）。
12. **交付包不含 「内部运行时字样」 字样**（AC-036）。
13. **追溯件**：`feature-meta/load-runner/` 下 `verification-report.md` / `traceability.md` / `feature.json` /
    `feature-meta.json` **四个文件都要有**，且含 REQ-013 条目；
    `traceability.md` 里 REQ-013 的**决策号并集 == D185~D210 全集**（归属按行内最后一个 `REQ-\d+` 判定）。
14. **不许 `npm publish`**。

---

## 9. 提交规范

- 分支：`feature/REQ-013`（**不要**合并到 develop，不要改别的分支）。
- 提交信息格式：`[{区域}] {描述} (关联: REQ-013) [session: mvs_744b60ef3d984cffbcd54448ac77bd8c]`
- **自己先跑通门**（快跑 41/0 + 完整模式 41/41 检出）**再**交付。
- 交付报告里写：改了哪些文件 · 门的两组数字与 rc · **契约缺陷上报**（如有）· **未验证项**（如有）。

---

## 10. ⛔ 独立性要求（**重要**）

需求方侧**有一份参考实现**（过程件，在临时目录里），它**不会**给你 —— **你不要去找它、不要抄它**。
你的实现要**独立**按契约做出来 —— 否则验收就失去意义（验收门验的是「**你**的交付物」，
不是「那份参考实现」）。

⚠️ 若你**偶然**看到了它，**照抄即视为未交付**，需求方会要求重做。
