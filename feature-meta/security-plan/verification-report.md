# REQ-008 验证报告（`security-plan` skill）

- 需求：REQ-008「安全能力域：`security-plan` skill（OWASP 全套 + 依赖扫描）」
- 分支：`feature/REQ-008`
- 判据条数：**29**（AC-001~AC-029）
- 决策号范围：**D98~D126**
- 需求文档（只读）：`BA/demands/REQ-002-suite-foundation/REQ-008-security-plan/`
- 自验环境：Node v26.13.1 / Linux；夹具落在临时目录（不写进被验包）

> 本报告里的**每一段输出都是真实跑出来的**（未跑验收门，理由见 §9）。

---

## 1. 夹具主跑（逐条核对）

夹具 = 需求 `acceptance.md` §0 的公共夹具（订单服务形态：3 资产 / 2 信任边界 / 3 入口点 / 3 角色 / 2 资源），
主跑命令：

```console
node skills/security-plan/scripts/make-security-plan.mjs \
  --context <FX>/inputs/context.json \
  --cases   <FX>/inputs/cases.json \
  --scan    <FX>/inputs/bandit.json \
  --out-dir <项目根副本>
```

真实输出：

```
[ok] 产物根: <FX>/run/proj-1/test-assets/security
[ok] 威胁 11 条（OWASP 覆盖 7 类 / 不适用 3 类；补充类 covered 1 类 / 不适用 3 类）
[ok] 权限矩阵: 角色 3 × 资源 2，条目 12 条（允许缺口 1 条）
[ok] 安全用例 18 条，套件 7 个（SEC-001-access-control / SEC-002-injection / SEC-003-insecure-design / SEC-004-misconfiguration / SEC-005-authentication / SEC-006-integrity / SEC-007-logging）
[ok] 扫描: status=provided，finding 2 条
主跑 rc=0
```

### 1.1 威胁清单（11 条，逐条字段）

```
TH-1  | A03 | tampering             | high   | model | asset=AS-1     | tb=TB-1     | ep=EP-1         | scan=-      | sup=-
TH-2  | A03 | tampering             | high   | model | asset=AS-2     | tb=TB-1     | ep=EP-2         | scan=-      | sup=-
TH-3  | A08 | tampering             | high   | model | asset=AS-3     | tb=TB-2     | ep=EP-3         | scan=-      | sup=-
TH-4  | A07 | spoofing              | high   | model | asset=AS-1     | tb=TB-1     | ep=EP-1         | scan=-      | sup=-
TH-5  | A05 | information_disclosure| medium | model | asset=AS-1     | tb=TB-1     | ep=EP-1         | scan=-      | sup=-
TH-6  | A05 | information_disclosure| medium | model | asset=AS-2     | tb=TB-1     | ep=EP-2         | scan=-      | sup=-
TH-7  | A04 | tampering             | medium | model | asset=AS-1+AS-2+AS-3 | tb=TB-1+TB-2 | ep=EP-1+EP-2+EP-3 | scan=- | sup=-
TH-8  | A09 | repudiation           | medium | model | asset=AS-3     | tb=TB-2     | ep=EP-3         | scan=-      | sup=-
TH-9  | A01 | elevation_of_privilege| high   | model | asset=AS-1     | tb=TB-1     | ep=EP-1         | scan=-      | sup=-
TH-10 | A07 | spoofing              | high   | scan  | asset=AS-1+AS-2+AS-3 | tb=TB-1+TB-2 | ep=EP-1+EP-2+EP-3 | scan=SCAN-1 | sup=-
TH-11 | A05 | information_disclosure| medium | scan  | asset=AS-1+AS-2+AS-3 | tb=TB-1+TB-2 | ep=EP-1+EP-2+EP-3 | scan=SCAN-2 | sup=xxe
```

逐条核对：字段集**恰好 12 个**；`id` 合 `^TH-\d+$` 且唯一；`category` ∈ STRIDE 六类；
`owasp` ∈ A01~A10；`source` 三态合法且「含 `scan` ⇔ `scan_refs` 非空」；三个引用数组非空且不悬空。

### 1.2 OWASP 十类交代（逐类）

```
A01 covered [TH-9]
A02 not_applicable reason=已检查 assets / entry_points / resources 的名称与说明，未… open_question=Q-1
A03 covered [TH-1,TH-2]
A04 covered [TH-7]
A05 covered [TH-5,TH-6,TH-11]
A06 not_applicable reason=本次只提供了代码级扫描（bandit），没有提供依赖清单扫描（npm audit），第三方组… open_question=Q-2
A07 covered [TH-4,TH-10]
A08 covered [TH-3]
A09 covered [TH-8]
A10 not_applicable reason=上下文里没有命中 URL / 回调 / webhook 等出站请求入口，本服务不由外部输入触… open_question=Q-3
```

键集**恰为** A01~A10；每个 `covered` 的 `threat_refs` **恰为**该类全部威胁；
每个 `not_applicable` 带**非空理由** + 指向 `category` 等于该类的未决问题（Q-1/A02、Q-2/A06、Q-3/A10）。

### 1.3 四类实战补充（逐类）

```
file_upload    not_applicable reason=已检查 entry_points 的名称与说明，未命中上传 / multipart / 附件…
ssrf           not_applicable reason=已检查 entry_points 的名称与说明，未命中 URL / 回调 / webhook…
xxe            covered [TH-11]
deserialization not_applicable reason=已检查 entry_points 的名称与说明，未命中反序列化类输入面，本服务不对外部数据做…
```

`xxe` 的被引用威胁 `TH-11` 的 `supplement_refs` **含** `xxe`（反向对应成立）。

### 1.4 扫描接入

```
scan: {"status":"provided","tool":"bandit","source_file":"bandit.json","finding_count":2}
scan_findings: [{"id":"SCAN-1","severity":"high","summary":"Possible hardcoded password: 'secret123'","threat_refs":["TH-10"]},
                {"id":"SCAN-2","severity":"medium","summary":"Consider possible security implications of xml parsing","threat_refs":["TH-11"]}]
```

两种扫描形态 + 不传 `--scan` 的实跑：

```
不传 --scan:      rc=0 scan.status=not_provided tool=null     finding=0 含 scan 的威胁=0
npm-audit:        rc=0 scan.status=provided    tool=npm-audit finding=1 含 scan 的威胁=1
scan-unavailable: rc=0 scan.status=unavailable tool=bandit    finding=0 含 scan 的威胁=0
```

### 1.5 权限矩阵（12 条，逐条）

```
ROLE-1 RES-1 read  deny  expected threat=-
ROLE-1 RES-1 write deny  expected threat=-
ROLE-1 RES-2 read  deny  expected threat=-
ROLE-1 RES-2 write deny  expected threat=-
ROLE-2 RES-1 read  allow expected threat=-
ROLE-2 RES-1 write allow expected threat=-
ROLE-2 RES-2 read  allow gap     threat=TH-9
ROLE-2 RES-2 write deny  expected threat=-
ROLE-3 RES-1 read  allow expected threat=-
ROLE-3 RES-1 write allow expected threat=-
ROLE-3 RES-2 read  allow expected threat=-
ROLE-3 RES-2 write allow expected threat=-
```

`roles` / `resources` 的 id 集合与上下文**完全相等**（ROLE-1..3 / RES-1..2）；
每个 `(role, resource)` 组合至少一条；唯一 `gap` 条目 `decision == "allow"` 且指向
`TH-9`（`category == "elevation_of_privilege"`）；**每条**越权类威胁都被至少一条 gap 引用（双向）。

### 1.6 套件与用例（逐个套件）

```
SEC-001-access-control    : 顶层字段 7 个 | cases=1 | R-1→threat-model.json#/threats/TH-9 | suite=SEC-001-access-control scope=security executor=security env=local
SEC-002-injection         : 顶层字段 7 个 | cases=4 | R-1→…/TH-1 R-2→…/TH-2 | suite=SEC-002-injection scope=security executor=security env=local
SEC-003-insecure-design   : 顶层字段 7 个 | cases=2 | R-1→…/TH-7 | scope=security executor=security env=local
SEC-004-misconfiguration   : 顶层字段 7 个 | cases=6 | R-1→…/TH-5 R-2→…/TH-6 R-3→…/TH-11 | scope=security executor=security env=local
SEC-005-authentication    : 顶层字段 7 个 | cases=2 | R-1→…/TH-4 R-2→…/TH-10 | scope=security executor=security env=local
SEC-006-integrity         : 顶层字段 7 个 | cases=2 | R-1→…/TH-3 | scope=security executor=security env=local
SEC-007-logging           : 顶层字段 7 个 | cases=1 | R-1→…/TH-8 | scope=security executor=security env=local

用例总数=18；id=TC-004,…,TC-021
id 唯一=true；与输入集冲突=无
tags 缺 security / 威胁 id 的用例数=0
```

顶层 7 个字段 = `schema_version,meta,requirements,open_questions,coverage_matrix,defects,cases`；
`requirements[].source_ref` 恰为 `threat-model.json#/threats/<TH-id>`；
`cases[].id` 合 `^TC-\d{3}$`、跨套件唯一、不与输入集 `TC-001`/`TC-002`/`TC-003` 冲突；
`dimension == "security"`、`status == "active"`、`method` ⊆ 方法库、`tags` 含 `security` 与威胁 id。

---

## 2. 幂等

同一输入跑两次（两个不同 out-dir），把 `meta.generated_at` 换成占位后逐字比对：

```
第二次 rc=0
  threat-model.json: 逐字相同=true（14277 vs 14277 字节）
  matrix.json: 逐字相同=true（3394 vs 3394 字节）
  suites/SEC-001-access-control/cases.json: 逐字相同=true
  suites/SEC-002-injection/cases.json: 逐字相同=true
  suites/SEC-003-insecure-design/cases.json: 逐字相同=true
  suites/SEC-004-misconfiguration/cases.json: 逐字相同=true
  suites/SEC-005-authentication/cases.json: 逐字相同=true
  suites/SEC-006-integrity/cases.json: 逐字相同=true
  suites/SEC-007-logging/cases.json: 逐字相同=true
  suites/SEC-001-access-control/suite.json: 逐字相同=true
```

---

## 3. 只读（输入不改、out-dir 之外不写）

```
跑前: context.json=018c5eddd159d16f…  cases.json=41e79610a9f64c64…  bandit.json=3e5c80d143bf6c8e…
跑后: context.json=018c5eddd159d16f…  cases.json=41e79610a9f64c64…  bandit.json=3e5c80d143bf6c8e…
输入 sha256 一致=true
输入目录条目跑前=bandit.json,cases.json,context.json,npm-audit.json,scan-unavailable.json
输入目录条目跑后=bandit.json,cases.json,context.json,npm-audit.json,scan-unavailable.json
out-dir 顶层条目跑前=.gitignore,test-assets
out-dir 顶层条目跑后=.gitignore,test-assets
out-dir 之外的输入目录无新增文件=true
```

「产物已存在即报错」：单元自测里预置占位 `threat-model.json` 再跑 ⇒ 退出码 1、占位内容逐字未变。

---

## 4. 加载层可消费（**只证到加载层**，不要求 dry-run）

上游 `skills/test-execute/scripts/lib/suite-loader.mjs` 的 `loadSuite` + `loadCases` + `selectCases`：

```
loadcheck rc=0
SEC-001-access-control   total=1 selected=1  scope=security executor=security environment=local
SEC-002-injection        total=4 selected=4  scope=security executor=security environment=local
SEC-003-insecure-design  total=2 selected=2  scope=security executor=security environment=local
SEC-004-misconfiguration  total=6 selected=6  scope=security executor=security environment=local
SEC-005-authentication   total=2 selected=2  scope=security executor=security environment=local
SEC-006-integrity        total=2 selected=2  scope=security executor=security environment=local
SEC-007-logging          total=1 selected=1  scope=security executor=security environment=local
```

上游用例集校验器的**真实退出码**：

```
validate-cases SEC-001-access-control: 退出码=0
validate-cases SEC-002-injection: 退出码=0
validate-cases SEC-003-insecure-design: 退出码=0
validate-cases SEC-004-misconfiguration: 退出码=0
validate-cases SEC-005-authentication: 退出码=0
validate-cases SEC-006-integrity: 退出码=0
validate-cases SEC-007-logging: 退出码=0
check-security-plan rc=0: [ok] 产物自洽: <FX>/run/proj-1/test-assets/security
[ok] 威胁 11 条、套件 7 个、用例 18 条（id 跨套件唯一）
```

上游目录契约校验器（把产物放进满足上游契约的最小项目根）：

```
[OK]   test-assets/security/suites/SEC-001-access-control/suite.json 字段完整、枚举合法、引用有效
…（7 个套件全 OK）
[OK]   test-assets/cycles/R1-REQ-001/cycle.json 枚举合法、跳过理由与状态历史一致
[OK]   .gitignore 已忽略 .test-artifacts/
结论: 0 FAIL / 14 OK        （退出码 0）
```

⚠️ **没有**跑 `run-suite.mjs --dry-run`：`security` 执行器在 `test-execute/executors/index.json`
的 `not_implemented` 里，且执行器查找在 dry-run 分支**之前** ⇒ dry-run 会先抛错。
「能跑通」若来自环境的 `driver` 覆盖，那是**误配对**（用功能执行器跑安全用例），不作数。

---

## 5. 非法输入（rc=1 / rc=2，且不留半份产物）

13 种非法上下文/扫描变体（真实输出，逐条）：

```
OK   no-assets:          rc=1 leftover=[] [error] assets 缺少必填字段（必须是非空数组）
OK   tb-string:          rc=1 leftover=[] [error] trust_boundaries 必须是数组
OK   ep-no-name:         rc=1 leftover=[] [error] entry_points[0].name 缺少必填字段（必须是非空字符串）
OK   no-roles:           rc=1 leftover=[] [error] roles 缺少必填字段（必须是非空数组）
OK   res-object:         rc=1 leftover=[] [error] resources 必须是数组
OK   dangling-asset:     rc=1 leftover=[] [error] entry_points[0].asset_refs[0] 悬空引用: "AS-999"（assets 里不存在这个 id）
OK   dangling-boundary:  rc=1 leftover=[] [error] entry_points[1].boundary_refs[0] 悬空引用: "TB-999"（trust_boundaries 里不存在这个 id）
OK   empty-asset-refs:   rc=1 leftover=[] [error] resources[0].asset_refs 为空（该字段必须至少有一个元素）
OK   dup-asset-id:       rc=1 leftover=[] [error] assets[1].id 重复: "AS-1"（assets 内必须唯一）
OK   bad-ep-id:          rc=1 leftover=[] [error] entry_points[0].id 格式非法: "EP-XYZ"（id 须匹配 ^EP-\d{1,3}$）
OK   bad-sensitivity:    rc=1 leftover=[] [error] assets[0].sensitivity 取值非法: "secret"（允许值: critical / high / medium / low）
OK   empty-ep-kind:      rc=1 leftover=[] [error] entry_points[0].kind 缺少必填字段（必须是非空字符串）
OK   scan-unrecognizable:rc=1 leftover=[] [error] 扫描结果无法识别: …（三种合法形态：根含 results 数组 = bandit 结果；根含 vulnerabilities 对象 = npm audit 结果；根含 status ∈ {unavailable, failed} = 扫描状态）
ALL NEG CASES OK
```

用法错（rc=2）：

```
OK   no-args:        rc=2 [usage] 缺少必填参数: --context
OK   only-context:   rc=2 [usage] 缺少必填参数: --out-dir
OK   unknown-switch: rc=2 [usage] 未知参数: --bogus
```

`leftover=[]` = 输出目录里**没有** `threat-model.json` / `matrix.json` / `suites/`（按存在性判定）。

---

## 6. 覆盖诚实性

- 十类 / 四类**逐类有交代**（§1.2 / §1.3），不存在「既无 covered 也无 not_applicable」的类；
- 覆盖状态**从威胁集合反推** ⇒ 「判 not_applicable 却有该类威胁」在结构上不可能出现
  （单元自测 T6 逐类核过：covered 的 `threat_refs` 与该类威胁集合**完全相等**）；
- 每个资产 / 边界 / 入口都至少被一条威胁引用（`usedAssets` / `usedBoundaries` / `usedEntries` 全覆盖）。

单元自测（`scripts/selftest-security-plan.mjs`）：

```
[ok] 自测全部通过：95 条断言
```

（覆盖：上下文 9 种非法变体点名坏点、「用户口令哈希」不算密码学环节、
角色级别映射、扫描发现分类、扫描三形态解析、覆盖声明双向一致、矩阵缺口双向对应、
用例 id 避让与全局唯一、幂等、非法输入不留产物、产物已存在即报错。）

---

## 7. 组合门（真跑）

```console
node bin/test-agent-skills.mjs verify
```

真实输出（节选，5 条场景全过）：

```
[info] 组合门临时根: <临时根>
[ok] 已装到临时根的 skill（7 个）: defect-verify, qa-toolchain, regression-plan, security-plan, test-case-design, test-execute, test-report
[ok] 依赖图校验通过（7 个 skill 的版本声明与 requires 全部满足）
[ok] 组合场景: test-execute 的 offline 夹具 → 4/1/1/0（与该夹具 README 的预期一致）
[ok] 组合场景: 轮次 execute 阶段已推进（in_progress），本次 run_id 已记入 stages.execute.runs[]
[ok] 组合场景: test-report 的报告链路（make-report.mjs 读 test-execute 的执行产物）→ verdict.case_layer=fail、verdict.evidence_layer=pass、verdict.regression_layer=not_applicable、verdict.overall=fail；cases.total=6、cases.passed=4、cases.failed=1、cases.blocked=1、cases.skipped=0（与执行产物逐字一致）
[ok] 组合场景: defect-verify 的复现用例链路（make-defect-cases.mjs 读缺陷单 + 已有用例集）→ 缺陷 2 条（复用 1 / 派生 1 / 未决 0）、复现用例 2 条（id 唯一：TC-001 / TC-101）
[ok] 组合场景: security-plan 的规划链路（make-security-plan.mjs 读安全上下文 + 功能用例集 + 依赖扫描结果）→ 威胁 11 条（OWASP 十类：已覆盖 7 类 / 不适用 3 类）、扫描发现 2 条全部映射到威胁、权限矩阵 12 条（允许缺口 1 条）、套件 7 个 / 安全用例 18 条（id 跨套件唯一且不与输入集冲突）；产物可被上游加载层消费且过上游用例集校验器
[ok] 组合门全部通过
[info] 默认临时根已清理: <临时根>
（退出码 0）
```

新增场景 `scenarioSecurityPlan` **真的跑**主入口并**从产物反推**断言（十类交代 / 四类补充 /
不悬空不漏 / 矩阵双向 / 套件字段集封闭 / 用例 id 与方法库 / 加载层消费 / 上游校验器退出码），
**没有**断言 `run-suite.mjs --dry-run` 能跑通。

---

## 8. 上游连带约束（实查，未跑任何验收门脚本）

```
[ok] README 漏写的 skill: 无
[ok] README 多写的 skill: 无
[ok] README 的 skill 表格里有 security-plan
[ok] README 的安装树里有 security-plan/
[ok] skills/<每个>/skill-meta.json 形状合法（name == 目录名；version 合 <数字>.<数字>.<数字>；requires 的值合 >=<x.y.z> 或 <x.y.z>）
[ok] skills/<每个>/SKILL.md frontmatter name 与 skill-meta.json 一致
[ok] skills/<每个>/SKILL.md 的 description 非空
[ok] security-plan.requires 含 test-case-design
[ok] security-plan.requires 含 qa-toolchain
[ok] security-plan.requires 不含 test-execute
[ok] 包内根 feature-meta/manifest.json 的 req 仍是 REQ-006
[ok] package.json 的 version 仍是 0.1.0
[ok] package.json 的 files 未变（["skills/","bin/","README.md","LICENSE"]）
[ok] npm pack 里有 7 个 skill 目录（defect-verify, qa-toolchain, regression-plan, security-plan, test-case-design, test-execute, test-report）
[ok] npm pack 里 feature-meta 条目数 = 0
[ok] 特定字样命中: 0 处
[ok] 既有 skill 被改动的文件: 无
[ok] 改动面越界文件: 无
UPSTREAM CHECKS ALL OK
```

---

## 9. 没做的事（明确说明）

- **没有跑本 REQ 的验收门**：需求侧在维护门（门有 sha256 前置钉版），并发跑会产生
  无因果关系的 FAIL 键。门钉版后由需求方跑。
- **没有跑上游五条门的验收脚本**：用 §8 的**逐条实查**代替（上游门扫的正是这些点），
  避免与需求侧并发跑门。
- **没有执行任何安全用例**：`security` 执行器未实现（属后续 REQ），本 REQ 只做规划。
- **没有跑任何扫描器**：扫描由 agent 用 `qa-toolchain` 跑完后把结果喂进 `--scan`。
- **没有改** `test-execute`（含 `executors/`）、既有 6 个 skill、包内根 `feature-meta/manifest.json`、`package.json`。
