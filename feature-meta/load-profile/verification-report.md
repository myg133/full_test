# REQ-009 交付验证报告 —— `load-profile`

> 需求编号：**REQ-009** · 决策号 **D127~D155** · 判据条数：29（AC-001 ~ AC-029）
> 验收门：`BA/demands/REQ-002-suite-foundation/REQ-009-load-profile/verify-acceptance.sh`
> （sha256 `e573d1793c9b523ca479adc0daa5fad901cfc15aa4f741cbdaa22c091b5b9f21`，**未改动**）
> 被验包：`<REPO_ROOT>/feature-REQ-009`

---

## 1. 验收门 —— 快跑（`REQ009_NO_MUT=1`）

命令：

```console
R=<REPO_ROOT>/BA/demands/REQ-002-suite-foundation/REQ-009-load-profile
P=<REPO_ROOT>/feature-REQ-009
SHA=e573d1793c9b523ca479adc0daa5fad901cfc15aa4f741cbdaa22c091b5b9f21
mkdir -p /tmp/req009-w1/gate1
REQ009_NO_MUT=1 QA009_WORK_ROOT=/tmp/req009-w1/gate1 \
  QA009_SCRIPT_SHA=$SHA bash $R/verify-acceptance.sh $P
```

真实输出摘要：

```
PASS AC-001 load-profile skill 存在且结构合法
PASS AC-002 每个 skill 都声明版本与依赖；load-profile.requires 恰为 test-case-design + qa-toolchain
PASS AC-003 README 的 skill 清单与实际目录一致，load-profile 两处都在
PASS AC-004 上游校验器对该 load 套件的判定行全 [OK]（2 个套件）
PASS AC-005 上下文的必填字段与顶层封闭集被校验（V1/V1b/V2）
PASS AC-006 workload 的引用完整、target 格式合法（V3/V7）
PASS AC-007 workload 的 id 唯一且格式合法（V4/V8）
PASS AC-008 枚举合法且 thresholds/thresholds_source 成对（V5/V6/V8b）
PASS AC-009 场景字段集封闭（4 个场景，14 个顶层字段）+ report.json 字段集封闭
PASS AC-010 梯度 / 阈值 / tool / target 逐字等于输入
PASS AC-011 thresholds_status 二态与键的有无一致
PASS AC-012 场景文件名合约定且与体内 name 一致
PASS AC-013 场景与容量目标一一对应（4 个）
PASS AC-014 阈值键集与值逐字等于输入，无凭空阈值
PASS AC-015 套件目录名合规且按环境分组（2 个套件）
PASS AC-016 suite.json 字段集封闭 + scope/executor=load + cases_file=scenario.json
PASS AC-017 引用件字段集封闭 + 引用可解析 +与本体不漂移
PASS AC-018 上游 loadSuite() 真实调用解析 load 套件不抛错
PASS AC-019 场景 ↔ 套件双向覆盖完整（无孤儿场景 / 无孤儿套件）
PASS AC-020 环境无 driver + executor=load + 无 cases.json + 跑完无执行产物
PASS AC-021 无来源必留痕 / 有来源不乱留
PASS AC-022 全部产物无压测结论字段
PASS AC-023 未决问题字段齐全 / id 唯一 / coverage 留痕
PASS AC-024 case_refs 与复算一致 + traceability 逐字相等 + 无 method 字段
PASS AC-025 两次跑（不同 out-dir）的产物逐字相同
PASS AC-026 只写 test-assets/load/，环境与轮次文件逐字未变
PASS AC-027 输入文件跑前跑后 sha256 一致
PASS AC-028 产物已存在即报错（rc=1）且既有产物未被覆盖
PASS AC-029 交付侧记账与实际一致（追溯件四件套 / req / 矩阵 / 条数与决策号取值唯一）

结论: 29 PASS / 0 FAIL
验收脚本 sha256: e573d1793c9b523ca479adc0daa5fad901cfc15aa4f741cbdaa22c091b5b9f21
判据条数（动态取 acceptance.md）: 29
变异体套件: 已跳过（REQ009_NO_MUT=1）—— 不可判定，不计入通过；检出率结论以完整模式为准
门自身 stderr 的 bash 错误行: 0
```

退出码：`0`。

## 2. 验收门 —— 完整模式（变异体套件）

命令（**不设** `REQ009_NO_MUT`，每次跑门给**独立**的 `QA009_WORK_ROOT`）：

```console
mkdir -p /tmp/req009-w1/gatefull
QA009_WORK_ROOT=/tmp/req009-w1/gatefull \
  QA009_SCRIPT_SHA=$SHA bash $R/verify-acceptance.sh $P
```

真实输出摘要（变异体套件部分）：

```
变异体 场景模型顶层多一个字段: 已检出（目标 AC-009 出现在新增失败键集合里；新增=[AC-009]）
变异体 枚举越界：tool.runner 改成非法值: 已检出（目标 AC-008 出现在新增失败键集合里；新增=[AC-008 AC-010]）
变异体 无来源却声称有来源并拍出阈值: 已检出（目标 AC-011 出现在新增失败键集合里；新增=[AC-010 AC-011 AC-014 AC-021]）
变异体 阈值数值被改（凭空改阈值）: 已检出（目标 AC-010 出现在新增失败键集合里；新增=[AC-010 AC-014]）
变异体 场景文件名不合命名约定: 已检出（目标 AC-012 出现在新增失败键集合里；新增=[AC-012]）
变异体 多出一个场景模型: 已检出（目标 AC-013 出现在新增失败键集合里；新增=[AC-012 AC-013]）
变异体 套件目录名编号不是三位: 已检出（目标 AC-015 出现在新增失败键集合里；新增=[AC-015 AC-017]）
变异体 executor 被改成 api（误配对）: 已检出（目标 AC-016 出现在新增失败键集合里；新增=[AC-016 AC-018 AC-020]）
变异体 suite.json 多出 load_scenario 字段: 已检出（目标 AC-016 出现在新增失败键集合里；新增=[AC-004 AC-016]）
变异体 case_refs 里塞不存在的用例 id: 已检出（目标 AC-024 出现在新增失败键集合里；新增=[AC-024]）
变异体 引用件漏掉一个场景引用: 已检出（目标 AC-017 出现在新增失败键集合里；新增=[AC-015 AC-017 AC-019]）
变异体 环境文件里出现 driver 字段: 已检出（目标 AC-020 出现在新增失败键集合里；新增=[AC-020 AC-026]）
变异体 场景里出现 status: passed: 已检出（目标 AC-022 出现在新增失败键集合里；新增=[AC-009 AC-022]）
变异体 无来源场景的未决问题被清空: 已检出（目标 AC-021 出现在新增失败键集合里；新增=[AC-021]）
变异体 无对应用例场景的未决问题被清空: 已检出（目标 AC-023 出现在新增失败键集合里；新增=[AC-023]）
变异体 输入文件被改写: 已检出（目标 AC-027 出现在新增失败键集合里；新增=[AC-027]）
变异体 每次跑给未决问题追加序号（破坏幂等）: 已检出（目标 AC-025 出现在新增失败键集合里；新增=[AC-025]）
变异体 跑前把已有产物移走（模拟漏检「已存在」）: 已检出（目标 AC-028 出现在新增失败键集合里；新增=[AC-028]）
变异体 环境文件被改写（写了不该写的目录）: 已检出（目标 AC-026 出现在新增失败键集合里；新增=[AC-026]）
变异体 skill-meta.json 被删掉: 已检出（目标 AC-001 出现在新增失败键集合里；新增=[AC-001 AC-002]）
变异体 skill-meta.json 的 requires 多出 test-execute: 已检出（目标 AC-002 出现在新增失败键集合里；新增=[AC-002]）
变异体 README 里的 load-profile 被删掉: 已检出（目标 AC-003 出现在新增失败键集合里；新增=[AC-003]）
变异体 cases_file 指向不存在的文件: 已检出（目标 AC-004 出现在新增失败键集合里；新增=[AC-004 AC-016]）
变异体 suite 字段与目录名不一致: 已检出（目标 AC-004 出现在新增失败键集合里；新增=[AC-004 AC-015]）
变异体 suite.json 缺必填字段（让上游加载层抛错）: 已检出（目标 AC-018 出现在新增失败键集合里；新增=[AC-004 AC-016 AC-018]）
变异体 feature-meta/load-profile/traceability.md 被删掉: 已检出（目标 AC-029 出现在新增失败键集合里；新增=[AC-029]）
变异体 删掉一个套件目录（留下孤儿场景）: 已检出（目标 AC-019 出现在新增失败键集合里；新增=[AC-015 AC-019]）
负控 负控 M0：给未决问题的文字追加一段固定无害说明: 未检出（新增失败键为空）—— 符合预期，探测器不是恒真
变异体套件: 检出 27/27（有效变异体）

结论: 29 PASS / 0 FAIL
变异体套件: 检出 27/27（有效变异体）
门自身 stderr 的 bash 错误行: 0
```

- 退出码：`0`；门自身 stderr：**0 字节**（门干净）。
- **正控 27/27 全部检出**；**负控 M0 未检出**（探测器不是恒真）。
- 变异体覆盖到的判据：AC-001 / AC-002 / AC-003 / AC-004 / AC-008 / AC-009 / AC-010 / AC-011 /
  AC-012 / AC-013 / AC-015 / AC-016 / AC-017 / AC-018 / AC-019 / AC-020 / AC-021 / AC-022 /
  AC-023 / AC-024 / AC-025 / AC-026 / AC-027 / AC-028 / AC-029（**25 个**判据有**专属**正控）。
  - AC-014 无专属正控，但被「阈值数值被改」「无来源却声称有来源」两个变异体**连带**检出；
  - AC-005 / AC-006 / AC-007 属**输入侧**判据（违规发生在产物生成之前，产物里没有痕迹可篡改）
    ⇒ 由 §4 的**非法输入实跑**保证。

## 3. 组合门 —— `node bin/test-agent-skills.mjs verify`

真实输出（全文）：

```
[info] 组合门临时根: /tmp/test-agent-skills-verify-a8ptEN
[ok] 已装到临时根的 skill（8 个）: defect-verify, load-profile, qa-toolchain, regression-plan, security-plan, test-case-design, test-execute, test-report
[ok] 依赖图校验通过（8 个 skill 的版本声明与 requires 全部满足）
[ok] 组合场景: test-execute 的 offline 夹具 → 4/1/1/0（与该夹具 README 的预期一致）
[ok] 组合场景: 轮次 execute 阶段已推进（in_progress），本次 run_id 已记入 stages.execute.runs[]
[ok] 组合场景: test-report 的报告链路（make-report.mjs 读 test-execute 的执行产物）→ verdict.case_layer=fail、verdict.evidence_layer=pass、verdict.regression_layer=not_applicable、verdict.overall=fail；cases.total=6、cases.passed=4、cases.failed=1、cases.blocked=1、cases.skipped=0（与执行产物逐字一致）
[ok] 组合场景: defect-verify 的复现用例链路（make-defect-cases.mjs 读缺陷单 + 已有用例集）→ 缺陷 2 条（复用 1 / 派生 1 / 未决 0）、复现用例 2 条（id 唯一：TC-001 / TC-101）
[ok] 组合场景: security-plan 的规划链路（make-security-plan.mjs 读安全上下文 + 功能用例集 + 依赖扫描结果）→ 威胁 11 条（OWASP 十类：已覆盖 7 类 / 不适用 3 类）、扫描发现 2 条全部映射到威胁、权限矩阵 12 条（允许缺口 1 条）、套件 7 个 / 安全用例 18 条（id 跨套件唯一且不与输入集冲突）；产物可被上游加载层消费且过上游用例集校验器
[ok] 组合场景: load-profile 的规划链路（make-load-profile.mjs 读压测上下文 + 功能用例集）→ 负载模型 4 个（阈值二态与键的有无一致、无来源的 1 个已留未决问题）、压测套件 2 个（按环境分组、引用不漂移、覆盖双向完整）、产物可被上游加载层消费且不含任何压测结论字段
[ok] 组合门全部通过
```

退出码：`0`。**既有 4 个场景的结论逐字未变**（离线夹具 / 轮次推进 / 报告链路 / 缺陷复现 / 安全规划
共 5 条既有场景行），新增的第 8 个 skill 的场景（`load-profile`）通过。

⚠️ 组合门场景**不断言** `run-suite.mjs --dry-run` 跑通（`load` 执行器未实现 ⇒ 必然抛错）：
「能被消费」只证到**加载层**（上游 `loadSuite()` 真实调用不抛错）。

## 4. 交付前的自查

| 项 | 命令 | 结果 |
|---|---|---|
| 全部脚本语法 | `node --check skills/load-profile/scripts/*.mjs skills/load-profile/scripts/lib/*.mjs bin/verify-suite.mjs` | 全部通过（无输出） |
| 脚本可执行位 | `ls -l skills/load-profile/scripts/*.mjs` | 两个入口脚本均为 `-rwxr-xr-x` |
| 夹具主跑 | `make-load-profile.mjs --context … --cases … --out-dir …` | rc=0，产物落在 `test-assets/load/`（`report.json` + `scenarios/`×4 + `suites/`×2） |
| 非法输入实跑 | 10 个变体（V1 / V1b / V2 / V3 / V4 / V5 / V6 / V7 / V8 / V8b） | 全部 rc=1、stderr 点名坏点、**无** `test-assets/load/` |
| 用法错 | 缺 `--out-dir` / `--out-dir` 指向文件 / 未知参数 | 全部 rc=2 |
| 幂等 | 同一输入跑两个 out-dir | 两份产物 `diff -r` **无差异** |
| 产物已存在 | 同一 out-dir 再跑一次 | rc=1、stderr 点名「产物已存在」、既有产物逐字未变 |
| 输入只读 | 跑前跑后 sha256 | `context.json` / `cases.json` 均未变 |
| 产物自检 | `check-load-profile.mjs <项目根>` | rc=0（「压测产物自洽」） |

## 5. 我**没有验到**的部分

- 见 `status.md` §5（跨平台、压测执行器、环境文件缺失分支、工具链安装、并发跑门、组合门夹具独立性）。
- **未跑**验收方的外部探针（如 F-01 逃逸形态 A / B、删上游模块的三探针）—— 那些探针验的是**门**，
  不是本实现；门本身未改动（sha256 与需求方给的钉版一致）。
