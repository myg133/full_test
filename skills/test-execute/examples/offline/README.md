# 离线示例：一个不依赖任何外部服务的完整执行链路

这个目录是一个**自包含的最小项目**，用来演示 `test-execute` skill 的完整链路：
执行 → 证据链 → 校验。它不连任何真实系统，也不需要装任何依赖。

## 跑起来

```console
# 1) 先看要跑什么（不发请求、不写产物）
node ../../scripts/run-suite.mjs test-assets/suites/REQ-DEMO-demo/suite.json \
  --project-root . --dry-run

# 2) 执行（mock 驱动自动起一个本地桩服务，用完即关）
node ../../scripts/run-suite.mjs test-assets/suites/REQ-DEMO-demo/suite.json \
  --project-root .

# 3) 校验证据链
node ../../scripts/verify-evidence.mjs .test-artifacts/<run_id>
```

命令里的路径相对本目录。也可以从仓库根跑：

```console
node skills/test-execute/scripts/run-suite.mjs \
  skills/test-execute/examples/offline/test-assets/suites/REQ-DEMO-demo/suite.json \
  --project-root skills/test-execute/examples/offline
```

## 这个示例在演示什么

| 用例 | 演示 | 期望结果 |
|---|---|---|
| TC-001 | 结构化断言成立 | `passed` |
| TC-002 | 状态码断言（`$status`） | `passed` |
| TC-003 | **故意失败**：断言写成期望 200，实际 404 | `failed` |
| TC-004 | **故意不可判定**：`expected` 是普通字符串 | `blocked`（不是 `passed`） |
| TC-005 | 脱敏：`/token` 的 `token` 字段在产物里不可见明文 | `passed`，产物里搜不到 `secret-value` |
| TC-006 | 多步用例：两步都成立 | `passed`，证据两份（`step-1-response.json` / `step-2-response.json`） |

TC-003 与 TC-004 是**故意**失败的示例：它们演示"判定随断言变化"与"不可判定不许算通过"。
删掉它们就得到一个全绿的示例套件。

## 目录里有什么

```text
offline/
├── .gitignore                                  # 忽略 .test-artifacts/
├── README.md
└── test-assets/
    ├── environments/mock.json                  # 环境定义：driver 声明用 mock 驱动
    └── suites/REQ-DEMO-demo/
        ├── suite.json                           # 执行配置
        └── cases.json                           # 用例集（REQ-002A 的 schema v2）
```

## mock 驱动怎么启用

本示例用的是**环境配置的 `driver` 字段**（`environments/mock.json` 里的 `"driver": "mock"`）——
"用哪个驱动"是环境属性，同一环境可以换驱动跑。
`suite.json` 的 `"executor": "api"` 保持目录契约的合法取值。

另一种写法是 `suite.json` 的 `"executor": "mock"`，目录契约也已放行（两种都接受）。
优先级：**环境配置的 `driver` > `suite.json` 的 `executor`**。

## 关于凭证

本示例的境配置**刻意不声明** `credentials`，因此不设任何环境变量就能跑通。
真实环境配置按 REQ-002B 声明 `credentials`（只放 `*_env` 变量名）；
声明了而对应环境变量没设时，该用例判 `blocked`（`error.type = credential_missing`），
**不是 `failed`** —— 环境缺失和用例失败是两回事。
