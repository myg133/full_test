# REQ-001 决策记录

> BA 自己拍板的细节写这里；Planner 周检，不逐条审批。

| # | 日期 | 决策 | 理由 | 可逆 | 复核 |
|---|------|------|------|------|------|
| D1 | 2026-11-09 | 首期只做「需求 → 测试用例设计」一个能力域 | 它是整条测试链路上游，用例质量决定后续执行类测试的覆盖率上限；且纯文档工作、对运行环境零依赖，能最快跑通 Agent 替代人工的闭环 | 是 | Planner 周检 |
| D2 | 2026-11-09 | 被测对象类型不限定，做通用框架 | 用户明确选择"暂不限定"；导致 skill 不得假设被测系统是 REST API / Web UI / CLI，输出 schema 必须与被测类型解耦 | 否 | Planner 周检 |
| D3 | 2026-11-09 | 交付形态为 npm 包，安装到 `~/.agents/skills/` | 用户指定。npm 携带版本与更新通道；用户级安装使 skill 对所有项目生效，契合通用框架定位 | 是 | Planner 周检 |
| D4 | 2026-11-09 | 用例输出用 JSON 而非 YAML | Node.js 无内置 YAML 解析器；skill 脚本要求零第三方依赖才能在任意环境独立运行，故选 Node 内置 `JSON.parse` 原生支持的格式 | 是 | Planner 周检 |
| D5 | 2026-11-09 | 校验与渲染逻辑下沉为脚本，不写进 SKILL.md | 二者是确定性计算（同输入必同输出），且需要被 eval 独立调用；属 skill-creator 规范中"该 bundle 成脚本"的判定 | 是 | Planner 周检 |
| D6 | 2026-11-09 | npm 包名 `test-agent-skills` | 已核查 `registry.npmmirror.com` 与 `registry.npmjs.org` 均未被占用；命名直接对应"测试 Agent Skill 套件"的定位，不含厂商/产品标识，便于跨环境复用与公开发布 | 是 | Planner 周检 |
| D7 | 2026-11-09 | 安装器提供 `TEST_AGENT_SKILLS_DIR` 环境变量覆盖安装根 | 隔离测试目录，避免验收过程污染用户真实的 `~/.agents/skills`（后者是 git 仓库，改动会进版本管理） | 是 | Planner 周检 |
| D8 | 2026-11-09 | `.skill-lock.json` 协作策略：新增 `sourceType: "npm"` 条目，不动其他条目 | 现有 lock 格式已支持 `sourceType` 枚举（github / well-known），新增 npm 类型是自然扩展；安装器必须只增自己的条目，避免误伤用户其他 skill | 是 | Planner 周检 |
| D9 | 2026-11-09 | 需求歧义必须显式暴露为"未决问题"，不靠猜 | 替代独立测试人员的核心价值之一就是发现需求本身的缺陷；静默假设会让遗漏的需求缺陷永久消失 | 否 | Planner 周检 |
| D10 | 2026-11-09 | 本 REQ 不执行 `npm publish` | 用户尚未 `npm login`，发布是外部可见动作；只交付可 `npm install` 的 tarball，发布由用户决定 | 是 | Planner 周检 |
| D11 | 2026-11-09 | 移除交付物中的厂商/产品标识：npm 包名定为 `test-agent-skills`，CLI 名 `test-agent-skills`，环境变量 `TEST_AGENT_SKILLS_DIR` | 用户要求交付文件中不出现特定厂商字样。套件定位是"通用测试能力"，命名不应绑定任一运行时生态，否则跨环境复用与对外分发都受限。已核查新名在 `registry.npmmirror.com` 与 `registry.npmjs.org` 均未被占用 | 是 | Planner 周检 |
