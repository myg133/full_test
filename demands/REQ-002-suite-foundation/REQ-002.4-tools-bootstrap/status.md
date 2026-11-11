# 状态：REQ-002.4 `.tools` 工具链自举机制

- **状态**: 已就绪
- **更新者**: ba-local-ba-20261109161500
- **更新时间**: 2026-11-11 18:50

## 状态历史

| 时间 | 从 | 到 | 操作者 | 备注 |
|------|----|----|--------|------|
| 2026-11-11 18:50 | 草稿 | 已就绪 | ba-local-ba-20261109161500 | 创建需求文档（15 条 AC），含环境实测约束与失败显式降级原则 |

## 阻塞项

（无）

## 依赖说明

- **前置**：REQ-002.3（目录契约）—— 已完成
- **后续**：REQ-002.8（安全工具清单）、REQ-002.9（压测工具清单）
- **并行**：可与 REQ-002.5b 并行 —— 本 REQ 只碰 `bin/qa` 与项目级 `.tools/`，不碰 `skills/test-case-design/` 与 `skills/test-execute/`

## 环境实测约束（设计前提）

- 仅 PyPI 镜像与 npmmirror 可达；GitHub releases 不可达 → `nuclei` / `trivy` / `osv-scanner` 装不上，**不纳入清单**
- npmmirror 二进制镜像 404 → 纯 JS 工具可装，编译型不行
- Docker daemon 未运行 → 容器化隔离不可用 → 必须靠目录级隔离
- 已实测：`uv sync` 到 `.tools/.venv` 后系统 `import httpx` 仍失败；`bun install` 到 `.tools/node/` 后系统 `command -v loadtest` 无输出 → 两条隔离路线可行

## 设计要点备忘

- **入口在包级 `bin/qa`，工具链在项目级 `.tools/`** —— 入口不能放 `.tools/`（那里除清单外都不进 Git，会跟着安装产物丢失）
- **`.gitignore` 用 `.tools/*` 而非 `.tools/`** —— 后者会让 `!.tools/manifest.json` 的例外规则失效，清单就静默不进版本库
- **失败必须显式**：`failed` / `unavailable` 不得被当成"通过"或"跳过"
- **隔离靠实测**：装完必须做负向验证（系统侧 import 失败 / `command -v` 无输出），不能靠声称
