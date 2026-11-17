# REQ-014 · 验收判据

> **门**：`verify-acceptance.sh`（本目录）。**主验收 = 完整模式**（含变异体套件）。
> **判据条数：20 条**（AC-001 ~ AC-020）。
> **决策号**：D211 ~ D218（见 `decisions.md`）。

---

## §0 夹具

### §0.1 形态合法的项目根 `$FX`（可反推）

```
$FX/                                  ← 项目根
└── .test-artifacts/
    └── run-demo-0001/                ← run_dir（形态合法：<root>/.test-artifacts/<id>）
        ├── meta.json
        ├── results.json
        ├── logs/runner.log
        └── evidence/
            ├── TC-001/step-1-response.json    ← passed 用例的证据
            ├── TC-002/step-1-response.json    ← failed 用例的证据（**含明文口令**）
            ├── TC-003/step-1-response.json    ← blocked 用例的证据（**含敏感字段名**）
            ├── TC-004/step-1-response.json    ← **完全无敏感内容**（验证不误伤）
            └── TC-005/step-1-response.json    ← ⚠️ **故意缺失**（results.json 声称有）
```

**`meta.json`**：

| 字段 | 值 |
|---|---|
| `run_id` | `run-demo-0001` |
| `suite` | `REQ-DEMO-demo` |
| `scope` | `functional` |
| `requirement` | `REQ-DEMO` |
| `environment` | `mock-local` |
| `started_at` / `finished_at` | ISO-8601 |
| `duration_ms` | **300** |
| `agent` | `demo-agent` |
| `executor` | `{"name":"mock","version":"0.1.0"}` |
| `tool_versions` | `{}` |
| `cases_total` / `cases_passed` / `cases_failed` / `cases_blocked` / `cases_skipped` | **4 / 1 / 1 / 1 / 1** |
| `evidence_manifest_sha256` | 按 §0.4 算出的真值 |
| `results_sha256` | 按 §0.4 算出的真值 |
| `redaction` | `{"rules_applied":[],"redacted_fields":0}` |
| `cycle` | `null` |

### §0.2 `results.json`（根节点是数组，**5 条**）

| `case_id` | `status` | `title` | `duration_ms` | `evidence[]` | `reproduction.command` | `error` |
|---|---|---|---|---|---|---|
| `TC-001` | `passed` | 正常查询 | 50 | `evidence/TC-001/step-1-response.json` | `null` | `null` |
| `TC-002` | `failed` | 登录失败 | 80 | `evidence/TC-002/step-1-response.json` | ⚠️ **`curl -X POST 'http://10.0.0.9:8080/api/v1/login' -d '{"username":"demo.user","password":"PlainTextPwd123","remember":false}'`** | `{"type":"assertion_failed","message":"status 期望 200 实得 401"}` |
| `TC-003` | `blocked` | 依赖不可用 | 60 | `evidence/TC-003/step-1-response.json` | `null` | `{"type":"dependency_unavailable","message":"上游服务不可达"}` |
| `TC-004` | `skipped` | 跳过用例 | 10 | `evidence/TC-004/step-1-response.json` | `null` | `null` |
| `TC-005` | `failed` | 证据缺失用例 | 100 | `evidence/TC-005/step-1-response.json` ⚠️ **文件故意不存在** | `null` | `{"type":"assertion_failed","message":"产物缺证据"}` |

**`evidence[]` 条目形状**（对齐 REQ-004 的 `references/evidence-chain.md` §3）：
`{path, sha256, bytes, media_type}`。

### §0.3 四份证据文件的内容（**这是本 REQ 的核心夹具**）

**TC-001（passed，无敏感内容）** —— 验证「脱敏器不误伤」+ **验证追踪标识豁免（D219）**：

```json
{
  "driver": "api",
  "request": {"method": "GET", "path": "/api/v1/items", "url": "http://10.0.0.9:8080/api/v1/items", "auth_mode": "none"},
  "response": {
    "status_code": 200,
    "headers": {"content-type": "application/json", "x-trace-id": "0123456789abcdef0123456789abcdef"},
    "body": {"code": "OK", "trace_id": "0123456789abcdef0123456789abcdef", "items": [{"id": "fedcba9876543210fedcba9876543210", "name": "样例"}]}
  }
}
```

⚠️ **这里故意放了 32 位 hex**（`x-trace-id` / `trace_id` / `items[].id` 三处）：
它们**不是**凭证（真实数据实测：业务标识全是这个形态），按 D219 **必须原样保留**。
⇒ 若实现把它们当凭证抹掉，**AC-011 判红**（`content_sha256 != sha256`）**且** AC-013 判红
（`trace_id` 没逐字保留）—— 这两条构成该豁免的**双向探针**。

**TC-002（failed，含内嵌明文口令）** —— 验证「值模式能兜住口令」：

```json
{
  "driver": "api",
  "request": {
    "method": "POST",
    "path": "/api/v1/login",
    "url": "http://10.0.0.9:8080/api/v1/login",
    "auth_mode": "basic (user:pass)"
  },
  "response": {
    "status_code": 401,
    "headers": {"content-type": "application/json"},
    "body": {
      "code": "UNAUTHENTICATED",
      "user": {"username": "demo.user", "password": "PlainTextPwd123"},
      "credential": "PlainTextPwd123",
      "note": "登录失败",
      "permissions": ["page.secrets.view", "page.secrets.manage"]
    }
  }
}
```

**TC-003（blocked，含敏感字段名 + 环境变量引用 + 非豁免键下的长 hex）** —— 验证「R1 换值但不动业务权限点 / 环境变量引用」**且**「非豁免键下的长 hex 仍被脱敏」：

```json
{
  "driver": "api",
  "request": {
    "method": "GET",
    "path": "/api/v1/deps",
    "url": "http://10.0.0.9:8080/api/v1/deps",
    "auth_mode": "bearer (env: DEMO_TEST_TOKEN)"
  },
  "response": {
    "status_code": 503,
    "headers": {"content-type": "application/json"},
    "body": {
      "code": "DEPENDENCY_UNAVAILABLE",
      "access_token": "tok_live_ABCDEF0123456789ABCDEF0123456789",
      "must_change_password": "PlainTextPwd123",
      "env_hint": "DEMO_TEST_TOKEN",
      "cache_key": "aaaabbbbccccddddaaaabbbbccccdddd"
    }
  }
}
```

⚠️ `cache_key` 是**非豁免键**下的 32 位 hex ⇒ 属「疑似凭证」⇒ **必须被脱敏**（AC-014）；
而 TC-001 豁免键下的同类 hex **必须保留**（AC-013）—— 两者形成对照，
证明「豁免是**按键名**的，不是「一律放过长 hex」。

**TC-004（skipped，完全无敏感内容）** —— 验证「`content_sha256 == sha256`」：

```json
{
  "driver": "api",
  "request": {"method": "GET", "path": "/api/v1/health", "url": "http://10.0.0.9:8080/api/v1/health", "auth_mode": "none"},
  "response": {"status_code": 200, "headers": {"content-type": "application/json"}, "body": {"status": "UP"}}
}
```

### §0.4 指纹真值口径

- `results_sha256`：对 `results.json` 文件字节算 sha256（与 REQ-010 同口径）。
- `evidence_manifest_sha256`：对**按 `path` 排序**的证据条目序列
  （每条取 `path` + `sha256` + `bytes`，以**换行**连接）算 sha256（与 REQ-010 同口径）。

### §0.5 形态不合法的 run_dir `$FX2/ART`

```
$FX2/ART/                     ← **不在** .test-artifacts/ 下 ⇒ 反推不成立
├── meta.json                 （run_id = run-demo-0002，其余同 §0.1）
├── results.json
└── evidence/TC-001/step-1-response.json
```

用于 AC-004：**不给 `--project-root` 时必须报错**，不许猜。

### §0.6 负控产物 `$FX3/.test-artifacts/run-demo-0003/`

内容与 §0.1 相同，但**所有内容均无敏感串**（无敏感字段名、无内嵌明文口令、无凭证形态）
⇒ 用于验证「脱敏器不得凭空产生替换」（`redacted_fields == 0` **且** `redacted_values == 0`）。

⚠️ **澄清（D220）**：§0.6 原文「口令改成 `not-a-secret`」**不得**实现成「保留 `password` 键、
只把值换掉」—— 那样 R1（敏感字段名）仍会命中 ⇒ 计数不为 0 ⇒ 与「`redacted_fields == 0`」
自相矛盾。**本 REQ 的实现口径**：`reproduction.command` 里的口令位置改为**无害的键 + 无害的值**
（`{"username":"demo.user","passwd_hint":"not-a-secret","remember":false}`）——
「口令改成 not-a-secret」的语义保留（仍有一个看起来像口令的值），但**键名不是敏感字段名**
⇒ R1 / R2 都不命中。
⚠️ **同时**：判定该计数为 0 的那行代码必须写成**字符串**比较
（`ctx.neg_redaction_zero === 'false'`），不是布尔比较 —— 布尔写法会让该分支永不触发。

---

## A 组 · 输出位置（AC-001 ~ AC-005）

### AC-001: 默认输出落在 `<项目根>/reports/<run_id>/`

- **前置条件**: §0.1 的 `$FX`
- **测试步骤**: 跑 `make-report.mjs --artifacts $FX/.test-artifacts/run-demo-0001`；检查
  `$FX/reports/run-demo-0001/report.json` 与 `$FX/reports/run-demo-0001/report.md` 是否存在且非空。
- **预期结果**: 两个文件**都存在且非空**；`$FX/.test-artifacts/run-demo-0001/report/` **不得**存在
  （旧默认位置不再被写）。
- **判据形式**: 查绝对事实（文件系统实况）；探针：让实现仍写 `<run_dir>/report/` ⇒ 本条判红

### AC-002: 显式 `--project-root` 时输出落在该根下

- **前置条件**: §0.1 的 `$FX`（但产物在 `$FX2/ART`）
- **测试步骤**: 跑 `make-report.mjs --artifacts $FX2/ART --project-root $FX`；检查
  `$FX/reports/run-demo-0002/report.json` 与 `report.md`。
- **预期结果**: 两个文件存在且非空；**`run_id` 取自 `meta.json`**（`run-demo-0002`），
  不是目录名 `ART`。
- **判据形式**: 查绝对事实；探针：让实现用 run_dir 的目录名当 run_id ⇒ 本条判红

### AC-003: run_dir 形态合法时能反推出项目根

- **前置条件**: §0.1 的 `$FX`
- **测试步骤**: 跑 `make-report.mjs --artifacts $FX/.test-artifacts/run-demo-0001`（**不给**
  `--project-root`）；检查输出落在 `$FX/reports/run-demo-0001/`。
- **预期结果**: 输出位置正确；**退出码 0**；stderr **不得**含「必须指定 `--project-root`」类提示。
- **判据形式**: 查绝对事实；探针：让实现拒绝反推（哪怕形态合法）⇒ 本条判红

### AC-004: 反推不成立且未给 `--project-root` ⇒ 报错退出，不产出半份报告

- **前置条件**: §0.5 的 `$FX2/ART`
- **测试步骤**: 跑 `make-report.mjs --artifacts $FX2/ART`（**不给** `--project-root`）；检查退出码、
  stderr、以及 `$FX2/ART` 与 `$FX2/reports/` 下有没有留下 `report.json` / `report.md`。
- **预期结果**: **退出码 1**；stderr 必须**点名 `--project-root`**（含该字面量）；
  **不得**留下任何 `report.json` / `report.md`（**0 字节也算存在**）；
  `$FX2/ART` 本身**逐字未变**。
- **判据形式**: 查绝对事实（退出码 + 文件系统实况）；探针：让实现默认拿 cwd 当项目根并照样出报告 ⇒ 本条判红

### AC-005: `--out-dir` 仍能完全覆盖默认输出

- **前置条件**: §0.1 的 `$FX`
- **测试步骤**: 跑 `make-report.mjs --artifacts $FX/.test-artifacts/run-demo-0001 --out-dir $WORK/elsewhere`；
  检查 `$WORK/elsewhere/report.json` 与 `report.md`；再检查 `$FX/reports/` 下**没有**被创建。
- **预期结果**: 报告落在 `$WORK/elsewhere/` 且两个文件齐备；`$FX/reports/` **不存在**（或未被本次写入）。
- **判据形式**: 查绝对事实；探针：让实现同时写两处 ⇒ 本条判红

---

## B 组 · 证据内联（AC-006 ~ AC-011）

### AC-006: `evidence.files[]` 覆盖全部实查存在的证据文件

- **前置条件**: §0.1 的 `$FX`
- **测试步骤**: 跑报告；取 `report.json` 的 `evidence.files[]`，逐条核对：
  ① 条数 == **4**（TC-001/002/003/004；TC-005 文件缺失**不进** files[]）；
  ② 每条含且仅含 `case_id` / `step` / `path` / `sha256` / `bytes` / `media_type` /
  `content` / `content_sha256` **这 8 个键**（多一个少一个都判红）；
  ③ 每条的 `path` **相对项目根**（不含 `/` 开头的绝对路径，也不含 `$FX` 的绝对前缀）；
  ④ `sha256` 与该文件**实算**的 sha256 一致（不是抄 `results.json`）。
- **预期结果**: 四项全满足；**passed 用例 TC-001 与 skipped 用例 TC-004 的证据也必须在列**
  （不许只内联失败用例的）。
- **判据形式**: 查绝对事实（逐条实算比对）；探针：让实现只内联 failed/blocked 用例的证据 ⇒ 本条判红

### AC-007: `content` 是脱敏后的原始文本，`content_sha256` 可重算

- **前置条件**: §0.1 的 `$FX`
- **测试步骤**: 对 `evidence.files[]` 的每一条，取 `content` 字符串，按 UTF-8 编码算 sha256，
  与该条的 `content_sha256` 比对；再检查 `content` 是**字符串**且**非空**。
- **预期结果**: 全部相等；`content` 均为非空字符串。
- **判据形式**: 查绝对事实（重算比对）；探针：让实现把 `content` 存成对象、或 `content_sha256`
  抄 `sha256` ⇒ 本条判红

### AC-008: 报告自包含 —— 只读 `report.json` 就能拿到全部证据内容

- **前置条件**: §0.1 的 `$FX`
- **测试步骤**: 把 `$FX/.test-artifacts/` **整个移走**（模拟产物目录不存在），只留
  `$FX/reports/run-demo-0001/report.json`；读该文件，核对 `evidence.files[]` 每条的 `content`
  非空，且能**独立解析出 TC-002 的 `body.code` == `"UNAUTHENTICATED"`**。
- **预期结果**: 内容**不依赖任何外部文件**即可读出；**不得**报「证据缺失」；
  报告中**不得**出现「请参见产物目录」之类把读者引向外部文件的说法作为唯一来源。
- **判据形式**: 查绝对事实（移走外部依赖后仍可读）；探针：让实现只写路径不写内容 ⇒ 本条判红

### AC-009: md 里内联证据内容（不只列文件名）

- **前置条件**: §0.1 的 `$FX`
- **测试步骤**: 读 `$FX/reports/run-demo-0001/report.md`；检查：① TC-002 的证据**内容**
  （如 `UNAUTHENTICATED`）在 md 正文里出现；② TC-001（passed）的证据内容也出现。
- **预期结果**: 两者都出现；md **不得**只列「证据文件：evidence/TC-002/step-1-response.json」
  而没有内容。
- **判据形式**: 查绝对事实；探针：让 md 只列路径 ⇒ 本条判红

### AC-010: 缺失的证据不进 `files[]`，且照旧点名

- **前置条件**: §0.1 的 `$FX`（TC-005 的文件故意不存在）
- **测试步骤**: 检查 `evidence.files[]` 里**没有** TC-005；再检查 `evidence.files_missing`、
  `evidence.missing_paths`、`evidence.findings[]`。
- **预期结果**: `files_missing == 1`；`missing_paths` **点名** `evidence/TC-005/step-1-response.json`；
  `findings[]` 至少一条 `kind == "missing_evidence"` 且 message 非空并点名该路径；
  `evidence_layer == "fail"`。
- **判据形式**: 查绝对事实；探针：让实现把缺失文件也塞进 `files[]`（content 为空）⇒ 本条判红

### AC-011: 无敏感内容的证据 ⇒ `content_sha256 == sha256`（脱敏器不误伤）

- **前置条件**: §0.1 的 `$FX`（TC-001 与 TC-004 无敏感内容）
- **测试步骤**: 取 `evidence.files[]` 中 `case_id` 为 `TC-001` 与 `TC-004` 的两条，
  逐条比较 `content_sha256` 与 `sha256`；再比较其 `content` 与**证据原文件的字节**
  （读原文件，UTF-8 解码后逐字比对）。
- **预期结果**: 两条的 `content_sha256 == sha256`；`content` 与原文件**逐字相同**。
- **判据形式**: 查绝对事实（逐字比对）；探针：让脱敏器把 `page.secrets.view` /
  `DEMO_TEST_TOKEN` / `http://10.0.0.9:8080` 也抹掉 ⇒ 本条判红

---

## C 组 · 脱敏（AC-012 ~ AC-016）

### AC-012: 明文口令不得出现在报告任何位置

- **前置条件**: §0.1 的 `$FX`（TC-002 的口令 `PlainTextPwd123`）
- **测试步骤**: 对 `report.json` **与** `report.md` 的**全文**（含所有字段、所有字符串、
  所有数组元素）搜索字面量 `PlainTextPwd123`。
- **预期结果**: **0 命中**；且报告里能找到替换后的占位符（`[REDACTED:` 开头）。
- **判据形式**: 查绝对事实（全文搜索）；探针：让实现只脱敏证据内容、不脱敏
  `reproduction.command` ⇒ 本条判红

### AC-013: 敏感字段名的**值**被替换

- **前置条件**: §0.1 的 `$FX`（TC-003 的 `access_token` / `must_change_password`）
- **测试步骤**: 解析 `report.json` 里 TC-003 的 `content`（JSON 文本），
  取 `body.access_token` 与 `body.must_change_password` 的值；
  并检查 `body.permissions`（TC-002）与 `body.env_hint`（TC-003）；
  **另检查 `report.md` 正文**里 `page.secrets.view` 与 `DEMO_TEST_TOKEN` 是否**逐字存在**；
  **再检查 TC-001 的 `content`**：其 `response.headers.x-trace-id`、
  `response.body.trace_id`、`response.body.items[0].id` 三个 32 位 hex 值是否**逐字保留**。
- **预期结果**: `access_token` 与 `must_change_password` 的值是占位符（**不含**原值）；
  `permissions` 的两个元素**逐字保留**（`page.secrets.view` / `page.secrets.manage`）；
  `env_hint` **逐字保留** `DEMO_TEST_TOKEN`；
  **md 里这两个值也逐字存在**（只看 json 会漏掉「md 侧过度脱敏」）；
  **TC-001 的三个 32 位 hex 逐字保留**（D219 豁免生效；它们是追踪/业务标识，不是凭证）。
- **判据形式**: 查绝对事实（逐字段取值比对）；探针：让脱敏器按「包含敏感词」替换
  （把 `page.secrets.view` 整个抹掉）⇒ 本条判红

### AC-014: 凭证字面量形态被替换

- **前置条件**: §0.1 的 `$FX`
- **测试步骤**: 在 `report.json` + `report.md` 全文搜索：
  ① `Bearer ` 后跟 ≥16 位 token 形态；② URL 里的 `user:pass@` 形态；
  ③ ≥32 位的连续十六进制串（不含 `sha256` 字段值本身）。
  **豁免**：除 `sha256` 字段值外，**豁免键**（`trace_id` / `x-trace-id` / `request_id` /
  `x-request-id` / `span_id` / `correlation_id` / `id` / `uuid`）下的值**也算合法**（D219）
  —— 判定时按**结构**收集这些键下的值（内联证据的 `content` 是 JSON 文本，须解析后收集）。
  **再豁免（D222）**：**本报告自身算出的指纹**也算合法 —— `meta.json` 的 `results_sha256` /
  `evidence_manifest_sha256`、`results.json` 里各 `evidence[].sha256`、以及**实存证据文件**的字节
  指纹（它们会出现在证据层 `findings[].message` 的**消息文本**里）。
  ⚠️ 这一组必须**从产物侧独立取**（读 `meta.json` / `results.json` / 现场算文件指纹），
  **不许抄报告里的值** ⇒ 判据的独立性不变。
- **预期结果**: 上述形态 **0 命中**（`sha256` / `content_sha256` 字段值、**豁免键下的值**与
  **本报告自身的指纹**是合法的，不得被当成凭证抹掉）；夹具里 TC-003 的 `cache_key`
  （**非豁免键**下的 32 位 hex）**必须已被脱敏**（不得出现在报告里）。
- **判据形式**: 查绝对事实（正则全文搜索）；探针：让脱敏器把 64 位 sha256 也抹掉 ⇒ 本条判红
  ⚠️ **反向探针（不许恒真）**：探针：把**非指纹**的长 hex 放行（豁免名单放太宽）⇒ 本条判红
  （夹具的 `cache_key` 就是这个探针）。

### AC-015: 报告内不含任何绝对路径

- **前置条件**: §0.1 的 `$FX`
- **测试步骤**: 在 `report.json` + `report.md` 全文搜索 `$FX` 的**绝对路径前缀**
  （以及任何以 `/` 开头、长度 ≥2 的路径形态）；逐条检查 `source.artifacts`、
  `evidence.files[].path`。
- **预期结果**: **0 命中**；`source.artifacts` 是**相对项目根**的路径
  （`.test-artifacts/run-demo-0001`）；`evidence.files[].path` 也是相对项目根的。
- **判据形式**: 查绝对事实（全文搜索）；探针：让实现保留 `source.artifacts` 的绝对路径 ⇒ 本条判红

### AC-016: `redaction` 段存在且如实计数

- **前置条件**: §0.1 的 `$FX`
- **测试步骤**: 检查 `report.json` 的 `redaction` 段：① 字段集**恰好**
  `{rules_applied, redacted_fields, redacted_values}`；② `rules_applied` 是非空 string[]、
  每项非空；③ `redacted_fields` 与 `redacted_values` 都是 number 且 **> 0**
  （本夹具确实有敏感内容）；④ 报告全文（json + md）**同时**出现
  `[REDACTED:field]`（字段规则产物，TC-003 的 `access_token`）与
  `[REDACTED:secret]`（值规则产物，TC-002 的内嵌明文口令）。
- **预期结果**: 四项全满足。
  ⚠️ ④ 是**证明「两类规则都生效」**的机械判据 —— 夹具里明文口令**只能**被值规则抓住
  （它藏在命令行字符串里，不是独立字段），敏感字段名**只能**被字段规则抓住；
  两个占位符都出现 ⇒ 两类规则都真的跑了。
- **判据形式**: 查绝对事实；探针：只跑字段规则（漏值模式）⇒ 本条判红（缺 `[REDACTED:secret]`）；
  探针：只跑值规则（漏字段规则）⇒ 本条判红（缺 `[REDACTED:field]`）

---

## D 组 · 诚实性与不变量（AC-017 ~ AC-020）

### AC-017: 报告自陈 `sha256` 与 `content_sha256` 的关系

- **前置条件**: §0.1 的 `$FX`
- **测试步骤**: 在 `report.md` 正文里查找同时出现 `sha256` 与 `content_sha256`
  （或等价中文表述「原文件指纹」/「脱敏后内容指纹」）的说明段。
- **预期结果**: 存在这样一段说明，且**点明两者不等是因为脱敏**（不是「证据被改」）。
- **判据形式**: 查绝对事实（文本存在性 + 关键片段）；探针：让报告只列字段名不解释 ⇒ 本条判红

### AC-018: 脱敏不影响证据层判定

- **前置条件**: §0.1 的 `$FX`（TC-005 证据缺失）
- **测试步骤**: 检查 `verdict.evidence_layer` 与 `verdict.overall`；并检查
  `evidence.findings[]` 里仍**点名** TC-005。
- **预期结果**: `evidence_layer == "fail"`；`overall != "pass"`；findings 仍点名缺失路径。
- **判据形式**: 查绝对事实；探针：让实现因脱敏而把证据层判 pass ⇒ 本条判红

### AC-019: 不得修改输入产物的任何既有文件

- **前置条件**: §0.1 的 `$FX`
- **测试步骤**: 跑报告**之前**对 `$FX/.test-artifacts/run-demo-0001/` 下每个文件算 sha256；
  跑完后再算一遍，逐个比对；额外检查**证据原文件**的字节级不变。
- **预期结果**: 全部逐字未变；**不得**在产物目录里新增任何文件（连 `report/` 也不许有）。
- **判据形式**: 查绝对事实（文件系统实况）；探针：让实现在产物目录里写 `report/` ⇒ 本条判红

### AC-020: 幂等 —— 同一输入两次出报告，除 `generated_at` 外逐字相同

- **前置条件**: §0.1 的 `$FX`
- **测试步骤**: 跑两次（输出到两个不同目录），取两份 `report.json`，剔除 `generated_at` 后逐字比对；
  同样比对两份 `report.md`（md 里若含生成时间，须**逐字同形**地剔除）。
- **预期结果**: 两者**逐字相同**。
- **判据形式**: 查绝对事实；探针：让实现把 `source.artifacts` 写成含时间戳的路径 ⇒ 本条判红

---

## 判定纪律（沿用本仓既有约定）

1. **判定"是否被检出"只看目标判据是否出现在新增失败键集合里**（基线失败键只取 `^FAIL` 行），
   不能只看"比基线多"。
2. **变异体套件必须自测**：先证明每个变异体**确实被目标判据检出**，再证明负控**未被检出**。
3. **判据不许恒真**：每条判据都要配**反向探针**证明它不恒真。
4. **判据不许不可满足**：判据的期望值必须由**夹具真值**推出，不得手写臆测值。
5. **门有自身 sha 前置检查**：不匹配即 0 PASS / 1 FAIL。
6. **并发跑多个门会产生无因果关系的额外 FAIL 键** ⇒ 每路独立工作根，**串行**跑。
