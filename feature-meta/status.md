# REQ-005 开发状态

- 需求：REQ-005「测试方法库（数据化）+ test-case-design SKILL.md 重写」
- 分支：`feature/REQ-005`
- 状态：**开发完成（待 QA 交叉验证）**
- 实现：`skills/test-case-design/`（skill：test-case-design）
  - `references/methods.json` —— 测试设计方法库（唯一来源，M1.1~M1.6）
  - `references/dimensions.json` —— 覆盖维度枚举（唯一来源，8 个维度）
  - `references/design-methods.md` —— 方法说明文档（人读；校验依据只有 JSON）
  - `references/coverage-dimensions.md` —— 维度清单文档（由脚本对照保证与 JSON 一致）
  - `references/case-schema.md` —— 用例集结构契约（schema v2）
  - `scripts/check-methods.mjs` —— 方法使用与维度适用性核验器
  - `scripts/validate-cases.mjs` —— 用例集结构校验器
  - `SKILL.md` —— skill 入口（方法选择与维度适用性一律走脚本）
- 核心变更：`methods_applied[]` 从「字符串声明」变成「可核验事实」——
  声称用了某方法，必须能在用例集里找到该方法的必需产出，否则报 ERROR。
- 自验：
  - 主验收 `BA/demands/REQ-002-suite-foundation/REQ-005-method-library/verify-acceptance.sh` → **35 PASS / 0 FAIL**
  - REQ-002A 回归 → **19 PASS / 0 FAIL**
  - REQ-002B 回归 → **41 PASS / 0 FAIL**
- 需求文档（只读）：`BA/demands/REQ-002-suite-foundation/REQ-005-method-library/`
  （`acceptance.md` 35 条判据 / `decisions.md` D1~D25 / `verify-acceptance.sh`）
- 上游基线：REQ-001（skill 化实证）、REQ-002A（schema v2 校验器）、
  REQ-002B（项目布局），本 REQ 不改其语义，只在 `skipped[].method` 留一处向后兼容放宽（D11）。
