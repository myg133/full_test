# 轮次状态推进契约（state-machine）

本文件是**契约**，不是说明材料。读者是要在本项目里推进测试轮次状态的执行者：你按这里的规则提交推进意图，脚本 `scripts/cycle-state.mjs`（本 skill 目录内）负责校验、写入与留痕。

配套文件：

- `references/project-layout.md` —— 目录布局与 `cycle.json` 的字段表（字段语义以那份为准）
- `scripts/cycle-state.mjs` —— 状态推进器（唯一的状态写入入口）
- `scripts/verify-layout.mjs` —— 目录契约校验器（只读）
- `scripts/lib/state-machine.mjs` —— 状态机规则的**单一来源**（枚举 / 转移表 / 终态 / `status`↔`history` 一致性判定）

---

## 0. 硬约束：状态文件只由脚本写

**`cycle.json` 与 `cycles/index.json` 不得由 agent 直接编辑。**

agent 只能提交**推进意图**（"这一轮开始了"、"这一轮完成了"），由脚本负责：

1. 校验前置状态是否合法（转移表、终态、`status`↔`history` 自洽）
2. 原子写入（临时文件 + `rename`）
3. 留痕（`history` 追加一条记录）

> 为什么这么严：状态字段靠自觉是守不住的。REQ-001 的实测已经证明模型会**自信地绕过机器契约**——未决问题只写进人读的 `report.md`，机器可读的 JSON 里一条都没有。同样的失败模式会发生在状态字段上：模型凭印象把 `status` 改成 `completed`，却漏写 `history`。本契约把强制落在脚本上，SKILL.md 里的自然语言只是软约束。

**违规后果**：状态字段与 `history` 不自洽 → 校验器判 FAIL → 后续轮次的证据链不可信 → 整条回归线作废。

---

## 1. 状态枚举

| 枚举 | 取值 |
|---|---|
| 轮次状态 `status` | `planned` / `in_progress` / `completed` / `blocked` / `cancelled` |
| 阶段状态 `stages.<name>.status` | `pending` / `in_progress` / `done` / `blocked` / `skipped` |
| 轮次范围 `scopes[]` / `scopes_skipped[].scope` | `functional` / `security` / `load` |
| 轮次编号 `round` | `R1` / `R2` / `R3` |
| 轮次类型 `round_type` | `new-requirement` / `regression` / `defect-verify` |

---

## 2. 完整转移表

| 当前状态 | 允许转移到 | 说明 |
|---|---|---|
| `planned` | `in_progress`、`cancelled` | 已排期但尚未开工 |
| `in_progress` | `completed`、`blocked`、`cancelled` | 进行中 |
| `blocked` | `in_progress`、`cancelled` | 阻塞解除后回到进行中 |
| `completed` | ——（**终态**） | 本轮已完成，不可离开 |
| `cancelled` | ——（**终态**） | 本轮作废，不可恢复 |

```text
planned ──▶ in_progress ──▶ completed
                │
                ├──▶ blocked ──▶ in_progress   （解除阻塞后回到进行中）
                └──▶ cancelled                   （本轮作废，不再恢复）

planned ──▶ cancelled                          （开工前取消）
```

**没有自环**：`X → X` 不是合法转移。推进到当前状态属于"已在该状态"，脚本会如实报告且不做任何修改（幂等）。

---

## 3. 推进器：全部子命令与参数

```console
node scripts/cycle-state.mjs <子命令> <轮次目录> [参数...] [--json]
```

`scripts/` 相对本 skill 目录；在本仓库内等价于 `node skills/test-case-design/scripts/cycle-state.mjs ...`。

- `<轮次目录>`：轮次目录路径（相对当前工作目录）。也可直接给到 `cycle.json` 文件。
- `--json`：输出机器可读 JSON（缺省输出人读文本）。**`--json` 模式下 stdout 只有 JSON**，便于 agent 直接 `JSON.parse`。
- **退出码**：`0` = 成功；`1` = 校验失败或非法转移；`2` = 调用方式错误（未知子命令、缺参数、参数拼写错）。

### 3.1 `init` —— 创建新轮次骨架

```console
node scripts/cycle-state.mjs init test-assets/cycles/R1-REQ-001 \
  --cycle-id R1-REQ-001 --round R1 --round-type new-requirement \
  --requirement REQ-001 --scope functional --by dev-agent-1
```

| 参数 | 必填 | 说明 |
|---|---|---|
| `--cycle-id` | 是 | 轮次标识。**必须与轮次目录名完全一致**（目录契约 §1） |
| `--round` | 是 | `R1` / `R2` / `R3` |
| `--round-type` | 是 | `new-requirement` / `regression` / `defect-verify` |
| `--requirement` | 是 | 关联需求编号（如 `REQ-001`） |
| `--scope` | 否 | 本轮覆盖的范围，可重复传入（`--scope functional --scope security`） |
| `--by` | 是 | 执行者标识，写进初始 `history` 记录 |

产出：`status` = `planned`，`history` 恰一条：

```json
{ "at": "<ISO8601>", "from": "planned", "to": "planned", "by": "<agent>", "event": "created" }
```

`from` 与 `to` 都必须取自状态枚举，所以初始记录只能是 `planned → planned`；用额外的 `event: "created"` 与后续的真实转移区分开。`init` **不覆盖**已存在的 `cycle.json`（已存在 → 退出码 1，文件不动）。

### 3.2 `show` —— 读当前状态

```console
node scripts/cycle-state.mjs show test-assets/cycles/R1-REQ-001 --json
```

输出：`status`、`history`、`stages`、`scopes`、`scopes_skipped`、**`allowed_next`（允许的下一步状态）**、`problems`（状态机问题清单）。

- 状态自洽 → 退出码 0。
- 状态不自洽（如 `status` 与 `history` 最后一条的 `to` 不一致）→ **退出码 1**，并在 `problems` 里列出问题。`show` 只读，不修改任何文件。

### 3.3 `advance` —— 推进轮次状态

```console
node scripts/cycle-state.mjs advance test-assets/cycles/R1-REQ-001 --to in_progress --by dev-agent-1 [--reason "文本"]
```

| 参数 | 必填 | 说明 |
|---|---|---|
| `--to` | 是 | 目标状态，必须在状态枚举内，且必须是当前状态的合法后继 |
| `--by` | 是 | 执行者标识 |
| `--reason` | 否 | 推进理由；非空时写入本次 `history` 记录 |

成功后：`status` 与 `history` 在**同一次写入**里完成，`history` 新增且仅新增一条 `{at, from, to, by}`（`reason` 非空时附带）。

### 3.4 `skip-scope` —— 记录本轮跳过的范围

```console
node scripts/cycle-state.mjs skip-scope test-assets/cycles/R1-REQ-001 \
  --scope load --reason "需求未给性能指标，无阈值可依" --by dev-agent-1
```

| 参数 | 必填 | 说明 |
|---|---|---|
| `--scope` | 是 | 被跳过的范围，必须在 `functional` / `security` / `load` 内 |
| `--reason` | 是 | 跳过理由，**非空**。缺失或为空 → 退出码 1，文件不动 |
| `--by` | 是 | 执行者标识（**谁跳过的**）。**不允许有默认值**——缺失 → 退出码 2，取值为空 → 退出码 1，文件均不动 |

产出：`scopes_skipped` 追加一条 `{scope, reason, at, by}`：

- `reason` —— 为什么这个范围本轮不跑（可被 review 发现的理由）
- `at` —— 脚本自动生成的 ISO-8601 时间戳（什么时候跳过的）
- `by` —— 执行者标识（谁跳过的）

> 为什么 `at` / `by` 是必填：跳过记录要能被**审计**。半年后回看一条记录，只有 `{scope, reason}` 的话，不知道该找谁确认、也不知道是什么时候的决定。成本几乎为零——脚本本来就要生成时间戳。

跳过不改变轮次状态，因此不动 `history`。同一 scope 重新声明会**整条覆盖**（`reason` / `by` / `at` 一并更新）；同 scope、同 reason、同 `by` 重复执行 → 报"已记录"，不重复写入（幂等）。

### 3.5 `set-stage` —— 设置阶段状态

```console
node scripts/cycle-state.mjs set-stage test-assets/cycles/R1-REQ-001 --stage design --status done [--artifacts a,b]
```

| 参数 | 必填 | 说明 |
|---|---|---|
| `--stage` | 是 | 阶段名（`clarify` / `design` / `data` / `execute` / `triage` / `report`，允许自定义） |
| `--status` | 是 | 阶段状态，必须在阶段状态枚举内 |
| `--artifacts` | 否 | 逗号分隔的产物路径列表 |

产出：`stages.<stage>.status` 被设置（已存在则更新）。阶段状态不改变轮次状态，因此不动 `history`。

---

## 4. 原子性与副作用规则

1. **原子写**：写临时文件（`.<文件名>.tmp-<pid>-<时间戳>`）→ `fsync` → `rename` 替换。中途失败**不得**产生半写的 `cycle.json`（不会出现解析不了的中间态），也**不得**留临时文件残留。
2. **失败零副作用**：校验不通过时，目标文件**不被修改**——不追加半条 `history`，不写 `scopes_skipped`，不删临时文件。
3. **一致性由脚本保证**：`advance` 成功后 `status` 必然等于 `history` 最后一条的 `to`，因为两处在同一次写入里完成。
4. **每次推进必留痕**：`history` 新增一条 `{at, from, to, by}`，`from` = 推进前状态，`to` = 推进后状态。
5. **跳过必留痕**：`skip-scope` 的 `--reason` 为空或缺失 → 拒绝（退出码 1），文件不动；`--by` 缺失 → 拒绝（退出码 2）。写入的记录含 `scope` / `reason` / `at` / `by` 四个字段，跳过的决定可被审计。
6. **幂等**：重复执行同一命令不产生额外副作用。
   - `advance --to <当前状态>` → 报"已在该状态"，不追加 `history`，退出码 0。
   - `skip-scope` 同 scope 同 reason 同 `by` → 报"已记录"，不重复写入。
   - `set-stage` 同阶段同状态 → 报"已是该状态"，不重复写入。
7. **索引同步**：`init` 与 `advance` 成功后，脚本会同步 `test-assets/cycles/index.json` 里本轮次的 `id` / `round` / `status` 摘要（索引结构非法时先失败，不留半成品）。
8. **跨文件要么都成、要么都不变**：`cycle.json` 与 `cycles/index.json` 是同一件事的两个视图。索引写失败（如 `cycles/` 目录只读、磁盘满）时，脚本会**回滚** `cycle.json` 到写前内容（逐字节一致），退出码 1——绝不留下"轮次已推进、索引还停在旧状态"的静默脱同步。`init` 失败时回滚方式是删除刚创建的 `cycle.json`。
9. **幂等分支也同步索引**：`advance --to <当前状态>` 虽然不改 `cycle.json`，仍会按当前状态同步索引——否则"索引写失败后重试修复"这条路是断的。
10. **准入判断与校验器同一套规则**：推进器的**所有**写入路径（`init` / `advance` / `skip-scope` / `set-stage`）在动手前都会用与校验器**完全相同**的规则检查目标文件（`checkCycleConsistency`：字段类型 / 必填 / 枚举 / `status`↔`history` 一致性 / `scopes_skipped` 记录的四个必填字段）。文件本身有问题 → 拒绝并报出与校验器**同类**的问题，文件不被修改。`show` 只读，遇到同样的问题时报出同一类问题并以退出码 1 结束。

> 第 10 条是"单一来源"的完整含义：规则写在一处还不够，**用哪套规则做准入判断**也必须一致。否则会出现推进器说"没问题"、校验器判 FAIL 的分叉——推进器会把坏文件继续写下去。

---

## 5. 规则的单一来源

状态机的枚举、转移表、终态判定、`status`↔`history` 一致性判定**只有一份实现**：

```text
scripts/lib/state-machine.mjs
```

`scripts/cycle-state.mjs`（推进器）与 `scripts/verify-layout.mjs`（校验器）都 import 这个模块，**不得**各自再写一份。

> 两份实现一旦漂移，agent 就会开始"绕过脚本手改文件"，写入权的收口就白做了。校验器与推进器对同一份文件报出**同一类问题**（例如 `status` 与 `history` 不一致），这是单一来源的直接体现，也是判断实现是否漂移的探针。

---

## 6. 常见错误与修法

| 现象 / 报错关键字 | 原因 | 修法 |
|---|---|---|
| `非法转移 planned → completed` | 当前状态不允许直接跳到目标状态 | 按转移表分两步走：先 `advance --to in_progress`，再 `advance --to completed` |
| `终态不可离开` | 本轮已 `completed` / `cancelled` | 终态不可回退。确需再来一轮就 `init` 新轮次（R2 / R3） |
| `轮次已处于 "..."：未做任何修改` | 目标状态与当前状态相同 | 幂等提示，无需处理；确认状态是否真该是目标值 |
| `status "x" 与 history 最后一条的 to "y" 不一致` | 有人手改了 `status` 而没追加 `history` | 不要手改。用 `advance` 走一次合法转移（脚本会同时修好两处）；状态已经错乱到无法推进时，按 `history` 最后一条的 `to` 手工把 `status` 改回去，并补一条对应记录 |
| `history[0].by 缺少必填字段` | 留痕不完整 | 补齐 `at` / `from` / `to` / `by`；用 `advance` 生成的记录天然齐备 |
| `跳过必须写明可被 review 发现的理由` | `skip-scope` 的 `--reason` 缺失或为空 | 写清"为什么这个范围本轮不跑"（如"需求未给任何性能指标，无阈值可依"） |
| `scopes_skipped[0].reason` 缺失或为空 | 手写了跳过记录但没给理由 | 补理由；或用 `skip-scope` 重新记录 |
| `scopes_skipped[0].at` 缺少必填字段 | 手写的跳过记录没留时间戳 | 用 `skip-scope --by <agent>` 重新记录（脚本自动写 ISO-8601 时间戳） |
| `scopes_skipped[0].by` 缺少必填字段 | 手写的跳过记录没留执行者 | 同上；"谁跳过的"不允许有默认值 |
| `缺少必填参数 --by` | `skip-scope` 没给执行者 | 补 `--by <agent>`；跳过必须可被审计，脚本不会替你编一个默认值 |
| `status 取值非法` | 用了 `finished` 之类自造状态 | 只能用 `planned` / `in_progress` / `completed` / `blocked` / `cancelled` |
| `缺少必填参数 --to` / `未知参数 --xxx` | 调用方式写错 | 看 `--help`；退出码 2 表示命令本身没写对，状态文件未受影响 |
| `轮次已存在` | `init` 指向了已有 `cycle.json` 的目录 | 换目录名，或改用 `advance` / `set-stage` |
| `cycle_id "x" 与轮次目录名 "y" 不一致` | 目录名与 `cycle_id` 不符 | 目录契约要求二者一致：改目录名或改 `--cycle-id` |
| `轮次索引写入失败` | 索引写不进去（如 `cycles/` 目录只读、磁盘满） | 脚本已回滚 `cycle.json`（内容与写前一致）。修好写权限后**重试同一条命令**即可——幂等分支也会同步索引 |
| `scopes_skipped[0].at` / `.by` 缺少必填字段 | 文件里的跳过记录不合规（多半是手写的） | 推进器会拒绝继续写这个文件。先按 §3.4 用 `skip-scope --by <agent>` 重新声明该 scope，或手工补齐 `at` / `by` |
| `非法阶段状态` | `set-stage --status` 写错 | 阶段状态只能用 `pending` / `in_progress` / `done` / `blocked` / `skipped` |

---

## 7. 典型调用序列

```console
# 1) 开一轮
node scripts/cycle-state.mjs init test-assets/cycles/R1-REQ-001 \
  --cycle-id R1-REQ-001 --round R1 --round-type new-requirement \
  --requirement REQ-001 --scope functional --by dev-agent-1

# 2) 开工
node scripts/cycle-state.mjs advance test-assets/cycles/R1-REQ-001 --to in_progress --by dev-agent-1

# 3) 推进阶段
node scripts/cycle-state.mjs set-stage test-assets/cycles/R1-REQ-001 --stage design --status done

# 4) 记录不跑的范围（必须给理由与执行者）
node scripts/cycle-state.mjs skip-scope test-assets/cycles/R1-REQ-001 \
  --scope load --reason "需求未给性能指标，无阈值可依" --by dev-agent-1

# 5) 收工
node scripts/cycle-state.mjs advance test-assets/cycles/R1-REQ-001 --to completed --by dev-agent-1 --reason "R1 全部用例执行完毕"

# 6) 随时查当前状态与下一步
node scripts/cycle-state.mjs show test-assets/cycles/R1-REQ-001 --json
```
