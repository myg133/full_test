---
name: security-plan
description: |
  Turn a security context into a security test plan: read the service's assets, trust boundaries, entry points, roles and resources, derive a STRIDE/OWASP threat model (all ten OWASP classes accounted for, four practical supplements judged explicitly), build the role × resource × action permission matrix, and derive security cases into consumable suites — threat-model.json, matrix.json and suites/SEC-<编号>-<短名>/{cases.json,suite.json} under test-assets/security/.
  Use this skill when the user asks to "安全测试规划"、"威胁建模"、"OWASP 覆盖"、"权限矩阵"、"越权分析"、"security plan"、"threat model"、"security test cases", or when a service needs a security test plan before anyone writes or runs security cases.
  It answers "哪些威胁成立、覆盖到什么程度、越权缺口在哪" — it does NOT execute the cases (the security executor is not implemented yet; that is a later REQ), it does NOT run scanners (scan results are fed in via --scan), and it never invents threats that are not anchored in the security context.
---

# 安全测试规划（威胁模型 → 权限矩阵 → 安全用例）

把一份**安全上下文**变成一份**可消费的安全测试计划**：

```
安全上下文 ──► 威胁模型 ──► 权限矩阵 ──► 安全用例集 + 套件配置
```

**判定一律走脚本。** 三条硬约束：

| 约束 | 为什么 |
|---|---|
| **十类 OWASP 逐类有交代** | 静默跳过 = 假的「已经覆盖了」。不适用 ⇒ `not_applicable` + **非空理由** + 一条**未决问题** |
| **威胁必须锚定真实资产 / 边界 / 入口** | 凭空造的威胁 = 自说自话；上下文里的每个资产、每条边界、每个入口**都不得漏** |
| **「未做」必须说出来** | 没喂扫描结果 ⇒ `scan.status = "not_provided"`，不许假装扫过 |

## 怎么用

```console
# 1) 产安全测试计划（产物落在 <out-dir>/test-assets/security/）
node scripts/make-security-plan.mjs \
  --context test-assets/inputs/security-context.json \
  --cases   test-assets/suites/REQ-001-order/cases.json \
  --scan    test-assets/inputs/bandit.json \
  --out-dir .

# 2) 复核产物是否自洽（字段集封闭、引用不悬空、覆盖声明与事实一致）
node scripts/check-security-plan.mjs .

# 3) 派生规则的单元自测（含验收夹具造不出来的分支）
node scripts/selftest-security-plan.mjs
```

`--context` 与 `--out-dir` 必需；`--cases` / `--scan` / `--environment` / `--requirement` 可选。
退出码：`0` 成功 / `1` 输入非法或违反写入纪律 / `2` 用法错误。

## 产物长什么样

```
<out-dir>/test-assets/security/
├── threat-model.json          # 威胁模型 + OWASP 十类覆盖 + 四类补充 + 扫描声明 + 未决问题
├── matrix.json                # 角色 × 资源 × 动作的权限矩阵（含「允许缺口」）
└── suites/SEC-001-access-control/
    ├── cases.json             # cases.json v2（顶层封闭 7 个，dimension=security，status=active）
    └── suite.json             # scope=security / executor=security（顶层封闭 9 个，无 threat_model）
```

- 威胁 ↔ 用例的关联靠 `requirements[].source_ref = "threat-model.json#/threats/<TH-id>"`，
  **不靠 id 后缀**（上游 `validate-cases.mjs` 硬拦 `^TC-\d{3}$`，`TC-SEC-001` 不合法）。
- 用例 `tags` 含 `security` 与威胁 id ⇒ 执行侧可以按威胁分批跑。
- `matrix.json` 里 `basis == "gap"` 的条目 = **本应拒绝却允许**的越权缺口，
  每条都指向一条越权类（`elevation_of_privilege`）威胁；反过来每条越权类威胁都被至少一条 gap 引用。

## 边界

- **只读输入**：安全上下文 / 功能用例集 / 扫描结果一律不改写。
- **只写自己的目录**：只写 `<out-dir>/test-assets/security/`；产物已存在 ⇒ 报错退出（不覆盖）。
- **幂等**：同一输入两次，除 `meta.generated_at` 外逐字相同。
- **不执行**安全用例：`security` 执行器**未实现**（属后续 REQ）；本 skill 只负责**规划**。
- **不跑扫描器**：扫描由 agent 用已交付的 `qa-toolchain`（`bin/qa`）跑 bandit / npm audit 后
  把结果**喂进来**（`--scan`）；工具装不上 ⇒ 显式传「扫描状态」JSON，**不得**静默跳过。
- **零第三方依赖、不联网**：只用 Node.js 内置模块。

## 判定规则在哪

- `references/security-context-schema.md` —— 安全上下文格式（字段、必填、枚举、两层合法性划分）。
- `references/threat-model-format.md` —— 威胁模型产物契约（威胁 12 字段、OWASP 十类、四类补充、扫描三形态）。
- `references/threat-derivation.md` —— 威胁派生规则（规则表、关键词表、扫描发现分类、矩阵判定口径）。
- `references/matrix-format.md` —— 权限矩阵产物契约与决策表。
- `references/derivation-rules.md` —— 用例派生与落位规则（封闭 7 个、方法库、id 分配、套件落位、加载层口径）。
- `scripts/check-security-plan.mjs` —— 产物自洽校验器（拿已产出的产物复核一份）。
