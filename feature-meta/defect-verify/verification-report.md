# REQ-007 验证报告（交付侧）

- 需求：REQ-007「缺陷复现能力域：`defect-verify` skill（R3 缺陷复现用例生成）」
- 分支：`feature/REQ-007`
- 判据条数：**29**（AC-001~AC-029）
- 决策号范围：**D72~D97**
- 被验对象：`skills/defect-verify/` + `bin/verify-suite.mjs` 的 `scenarioDefectVerify` + `README.md` 两处 + 本目录四件套

## 1. 分层结论

| 层 | 结论 | 依据 |
|---|---|---|
| 交付物形状层 | **pass** | skill 六件套齐全、两个脚本可执行且过 `node --check`、`scripts/lib/` 六个非空模块、`skill-meta.json` 的 `requires` 含 `test-case-design` 与 `test-execute`、README 安装树与表格**两处**都有 `defect-verify` |
| 契约行为层 | **pass** | §0 夹具跑出的产物与基线真值表**逐项一致**（处置结论、用例 id、编号段、tags、`requirement_refs`、`coverage_matrix` 条数）；11 种非法输入全部 rc=1 且不留半份产物；只读与幂等成立 |
| 组合门层 | **pass** | `bin/test-agent-skills.mjs verify` 退出码 0，4 条组合场景全过，其中 `scenarioDefectVerify` **实跑** `make-defect-cases.mjs` 并从产物反推断言 |
| 诚实性层 | **pass** | 输出缺陷 id 集合 == 输入集合（5 == 5，无重复）；`unresolved` 必带非空理由；无凭空造的缺陷；复用命中的缺陷一条派生用例都没有 |
| 追溯层 | **pass** | 追溯矩阵 29 行、编号集合恰为 AC-001~AC-029；三份 md 的判据条数与决策号范围取值唯一；`manifest.json` 的 `req` 为 `REQ-007` |

> 验收脚本由**需求方**跑（并发跑会产生无因果关系的失败键），本报告只登记实现侧的自验事实。

## 2. 自验的真实输出（摘要）

### 2.1 §0 夹具主跑

```
[ok] 产物: …/run-main/test-assets/cycles/R3-DEMO/defect-cases.json
[ok] 缺陷 5 条（复用 2 / 派生 1 / 未决 2）；复现用例 3 条
  · BUG-002: unresolved —— case_refs 里的用例 TC-099 在已有用例集里找不到（不得部分复用：要么整条复用成功，要么显式说不知道）
  · BUG-004: unresolved —— 复现信息不足：reproduction.command 缺失或为空白、reproduction.steps 缺失或为空数组、reproduction.expected_failure 缺失或为空白（说不出怎么复现 ⇒ 显式说不知道，不派生也不假装复用）
```

与基线真值表逐项一致：`defects[].disposition` = `reused / unresolved / reused / unresolved / derived`；
`BUG-005.derived_case_id` = `TC-102`（输入用例集故意占用 `TC-101` ⇒ 顺延）；
`cases[]` = `TC-017 / TC-021 / TC-102`；`requirements[]` 5 条（`R-1`~`R-5`）；
`coverage_matrix[]` 3 条（`R-1` / `R-3` / `R-5`）；`meta.case_count` = 3、`meta.defect_count` = 5。

### 2.2 幂等 / 只读 / 可执行性

```
idem1 generated_at: 2026-11-13T10:12:13.860Z
idem2 generated_at: 2026-11-13T10:12:13.932Z
除 generated_at 外逐字相同: true | 字节数: 5003 5003

f6c11b624e3ef7151e4798eb21c5411a5732b5b3d7444c04ebe1928ffe0446b9  defects.json（跑前 = 跑后）
72002cf0115691a61a34d246251a4e9427fb116ead4b09ddb0b8ec7e2ba2c4a4  cases.json（跑前 = 跑后）
输入目录文件清单: cases.json / defects.json（无散落文件）

套件: REQ-DEMO-coupon（执行器 mock 1.0.0）
[dry-run] 计划执行 3 条用例，不发请求、不写产物
  - TC-017 满减券核销用例 断言 0 条（不可机械判定 → blocked）
  - TC-021 优惠券核销复现用例 断言 0 条（不可机械判定 → blocked）
  - TC-102 复现 BUG-005：导出报表偶发空文件 断言 0 条（不可机械判定 → blocked）
（按 tags.include=["BUG-005"] 再跑一次：计划执行 1 条 —— TC-102）
```

产物同时通过上游 `validate-cases.mjs`（`校验通过 … 用例总数: 3（active: 3）`、`未覆盖需求条目: R-2, R-4`），
说明它**本身就是一份合法的 v2 用例集**。

### 2.3 非法输入（11 种变体，全部 rc=1 且**无**产物）

| 变体 | rc | 产物 | stderr |
|---|---|---|---|
| 根不是对象 | 1 | 无 | `缺陷单的根节点必须是对象（不是数组或标量）: …` |
| `defects` 不是数组 | 1 | 无 | `defects 必须是数组（…）` |
| 不是合法 JSON | 1 | 无 | `缺陷单 defects.json 不是合法 JSON: …` |
| 缺 `id` | 1 | 无 | `defects[0].id 缺失（缺陷 id 必填）` |
| 缺 `title` | 1 | 无 | `defects[0].title 缺失（缺陷标题必填）` |
| 缺 `severity` | 1 | 无 | `defects[0].severity 缺失（必填）` |
| `reproduction` 是字符串 | 1 | 无 | `defects[0].reproduction 必须是对象（不能是 null / 字符串 / 数组）` |
| `id` 重复 | 1 | 无 | `defects[1].id 重复: BUG-001（…）` |
| `id` 格式错 | 1 | 无 | `defects[0].id 格式非法: BUG-XYZ（必须匹配 ^BUG-\d{3,}$）` |
| `severity` 越界 | 1 | 无 | `defects[0].severity 越界: "critical"（允许值: high / medium / low）` |
| `status` 越界 | 1 | 无 | `defects[1].status 越界: "reopened"（…）` |

### 2.4 轮次契约与写入权

```
round-not-r3   → rc=1 | 产物存在: no | 轮次配置的 round="R2"，R3 缺陷复现轮次必须是 "R3": …
trigger-unknown → rc=1 | 产物存在: no | 轮次配置的 trigger.ref="BUG-999" 不在输入缺陷 id 集合里（轮次与缺陷单对不上）: …

cycle.json 跑前跑后 sha256 一致：61a22e049f8c4c0093e7ff0b87e09dad9a6a878d3a6d073aac948494c5d47675
覆盖保护：rc=1（输出目录里已经有产物 defect-cases.json），占位文件未被改写: true
verify-layout.mjs：rc=0、0 条 FAIL；错误位置探针结论 = 位置不受约束
```

### 2.5 共享场景（**验收夹具造不出** ⇒ 以自测为证）

自造「两条缺陷引用同一条已有用例」+「`case_refs` 内含重复 id」的缺陷单，实跑一次：

```
cases[].id = ["TC-021","TC-017"] | 重复 id: []
用例 TC-021 → origin=reused | defect_refs=["BUG-010","BUG-011"] | tags=["coupon","regression","defect-verify","BUG-010","BUG-011"] | requirement_refs=["R-1","R-2"]
用例 TC-017 → origin=reused | defect_refs=["BUG-012"]    | tags=["coupon","defect-verify","BUG-012"]                  | requirement_refs=["R-3"]
共享用例 TC-021 只出现一次: true
  defect_refs 含两条缺陷: true
  tags 含 defect-verify + 两条缺陷 id: true
  requirement_refs 含两个 R-<n>: ["R-1","R-2"]（不悬空: true）
BUG-012（case_refs = ["TC-017","TC-017"]）→ reused [{"suite":"REQ-DEMO-coupon","case_id":"TC-017"}]（去重后只有一条）
```

单元自测 `scripts/selftest-defect-cases.mjs`：**17 通过 / 0 失败**（T1 去重 / T2 部分命中 / T3 共享 / T4 顺延 / T5 信息不足 / T6 幂等）。

### 2.6 组合门

```
[ok] 已装到临时根的 skill（6 个）: defect-verify, qa-toolchain, regression-plan, test-case-design, test-execute, test-report
[ok] 依赖图校验通过（6 个 skill 的版本声明与 requires 全部满足）
[ok] 组合场景: test-execute 的 offline 夹具 → 4/1/1/0
[ok] 组合场景: 轮次 execute 阶段已推进（in_progress），本次 run_id 已记入 stages.execute.runs[]
[ok] 组合场景: test-report 的报告链路 → verdict.overall=fail；cases.total=6
[ok] 组合场景: defect-verify 的复现用例链路（make-defect-cases.mjs 读缺陷单 + 已有用例集）→ 缺陷 2 条（复用 1 / 派生 1 / 未决 0）、复现用例 2 条（id 唯一：TC-001 / TC-101）
[ok] 组合门全部通过
```

版本错配探针（`requires.test-execute` 改成 `>=99.0.0`）⇒ 退出码 1，且报的是**版本问题**：

```
[version] 依赖版本不满足：skill defect-verify 要求 test-execute >=99.0.0（期望版本 99.0.0），实际版本 0.1.0
```

## 3. 与决策记录的对照

| 决策 | 实现落点 | 结论 |
|---|---|---|
| 两层合法性划分 | `lib/validate-defects.mjs`（结构层报错退出） vs `lib/derive.mjs` 的 `missingReproductionInfo()`（内容层判 `unresolved`） | 一致 |
| `case_refs` 部分命中 ⇒ 整条 `unresolved` | `lib/derive.mjs` 的 `case_refs` 分支 | 一致 |
| 归一化口径写死 | `lib/normalize.mjs`（实现侧的唯一来源，references 里原样写出） | 一致 |
| 判定顺序（`case_refs` 优先） | `lib/derive.mjs` 的 `decide()` | 一致 |
| `requirements[]` 只含缺陷条目 | `lib/product.mjs` | 一致 |
| 复现用例 `status` 一律 `active` | `lib/product.mjs` 的 `buildReusedCase()` | 一致 |
| 输出目录判定口径（按产物文件 + 目录内容） | `make-defect-cases.mjs` 的 `assertWritableOutDir()` | 一致 |
| `trigger.ref` ∈ 输入缺陷 id 集合；只读不改写 | `lib/validate-defects.mjs` 的 `validateCycleDocument()` | 一致 |
| `defects[]` 字段集封闭 | `lib/product.mjs` + `scripts/check-defect-cases.mjs` | 一致 |
| 扩展编号段与顺延 / 用尽 | `lib/product.mjs` 的 `allocateId()` + `lib/derive.mjs` 的用尽分支 | 一致 |
| 幂等口径（只允许 `meta.generated_at` 变） | `lib/product.mjs`（无随机量、无输出路径入产物） | 一致 |
| 特征匹配的用例侧 command 来源 | `lib/normalize.mjs` 的 `caseCommand()` | 一致 |
| 共享场景（去重 + 只出现一次 + 含全部缺陷） | `lib/derive.mjs` 的 `dedupeIds()` + `lib/product.mjs` 的共享合并 | 一致（并在 `references/derivation-rules.md` §5 写明裁定 + 单元自测） |

## 4. 遗留与存疑

| 项 | 说明 |
|---|---|
| 扩展编号段用尽 ⇒ `unresolved` | 造不出（需 899 条已占用用例）；规则已落地（`allocateId()` 返回 `null` 即改判），未实测 |
| 「其一为空即放行」在缺陷侧的可达性 | 缺陷侧 `command` 为空时按判定顺序先判「信息不足」⇒ `unresolved`，因此该放行规则实际只作用于**用例侧**没有 `reproduction.command` 的情形（夹具 `TC-021` 即此情形，判为命中） |
| 组合门场景的断言强度 | 场景断言的是**产物结构自洽**（处置结论、来源字段、id 唯一），不重复验收脚本的复算职责 |
