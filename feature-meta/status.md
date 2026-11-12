# REQ-006 开发状态

- 需求：REQ-006「安全 / 压力 / 可观测性覆盖维度 + M2.x 安全测试方法段」
- 分支：`feature/REQ-006`
- 状态：**开发完成（待 QA 交叉验证）**
- 实现：`skills/test-case-design/`（skill：test-case-design）
- 规模：覆盖维度枚举从 8 项扩到 **11 个维度**（新增 `security` / `stress` / `observability`）；
  方法库收录 M1.x / M2.x 两段，方法区间 **M1.1~M2.3**（通用方法 6 种 + 安全方法 3 种，共 **9 种方法**）。
- 实现清单（被验目录下的每一个交付文件）：
  - `references/dimensions.json` —— 覆盖维度枚举（唯一来源，11 个维度）
  - `references/methods.json` —— 测试方法库（唯一来源，M1.1~M2.3，共 9 种方法）
  - `references/design-methods.md` —— 方法说明文档（人读；校验依据只有 JSON）
  - `references/coverage-dimensions.md` —— 维度清单文档（由脚本对照保证与 JSON 一致）
  - `references/case-schema.md` —— 用例集结构契约（schema v2）
  - `references/project-layout.md` —— 项目布局契约（REQ-002B）
  - `references/state-machine.md` —— 轮次状态机说明（REQ-002.5a）
  - `scripts/check-methods.mjs` —— 方法使用与维度适用性核验器
  - `scripts/validate-cases.mjs` —— 用例集结构校验器
  - `scripts/cycle-state.mjs` —— 轮次状态推进脚本
  - `scripts/render-report.mjs` —— 报告渲染脚本
  - `scripts/verify-layout.mjs` —— 目录契约校验脚本
  - `scripts/lib/state-machine.mjs` —— 状态机公共库
  - `SKILL.md` —— skill 入口（方法选择与维度适用性一律走脚本）
- 核心变更：
  - **维度侧** —— 枚举新增 `security`（认证会话/注入/凭据密钥/脱敏加密/审计）、
    `stress`（限流/降级/背压/超时不丢数据）、`observability`（日志/指标/告警/追踪），
    三者的 `applies_when` 信号集合两两不同；清单文档同步补 3 行表格 + 3 节逐维度检查清单。
  - **方法侧** —— 方法库新增 M2.x 段：M2.1 威胁建模（STRIDE）、M2.2 攻击面枚举、M2.3 模糊测试，
    每种方法都带可机械核验的必需产出（谓词引用的维度 id 必须真实存在于枚举里）。
  - **编号侧** —— `DESIGN_METHOD_SEGMENT` 覆盖 M1 / M2 两段；`M0.x` / `M4.x`（Layer 0 必选测试点段）
    仍不在库内、仍判"无法判定"，未登记提示里的分类提示原样保留。
- 自验：
  - 主验收 `BA/demands/REQ-002-suite-foundation/REQ-006-security-stress-observability/verify-acceptance.sh` → **42 PASS / 0 FAIL**
  - REQ-002A 回归 → **19 PASS / 0 FAIL**
  - REQ-002B 回归 → **41 PASS / 0 FAIL**
- 需求文档（只读）：`BA/demands/REQ-002-suite-foundation/REQ-006-security-stress-observability/`
  （`acceptance.md` 42 条判据 / `decisions.md` D1~D31 / `verify-acceptance.sh`）
- 上游基线：REQ-001（skill 化实证）、REQ-002A（schema v2 校验器）、
  REQ-002B（项目布局）；本 REQ 不改它们的语义。
