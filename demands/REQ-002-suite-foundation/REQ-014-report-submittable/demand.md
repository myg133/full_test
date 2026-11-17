# REQ-014 · 测试报告可提交化

> **一句话**：让 `test-report` 产出的报告**能直接提交进仓库** —— 报告落在项目根的
> `reports/<run_id>/`（不是被 `.gitignore` 忽略的产物目录里），**证据内容内联进
> `report.json`**（不再只是路径引用），且报告内**一律脱敏**。

---

## 1. 背景（用户实机反馈 · 2026-11-17）

用户在 `/home/myg133/Projects/Anchnet/YF-test/` 做功能测试（后端 `192.168.104.218:5173`，
环境标识 `cd-218`，套件 `REQ-P0-api-contract-218`，31 条用例），跑完后发现三件事：

| # | 现象 | 根因 |
|---|---|---|
| ① | **报告落在一个提交不了的地方** | 工具默认输出到 `<run_dir>/report/`，而 `run_dir` = `<项目根>/.test-artifacts/<run_id>/`，**该目录被项目 `.gitignore` 忽略** ⇒ 报告本身也不可提交 |
| ② | **报告提交后证据全丢** | `report.json` 里证据是**路径引用**（`"path": "evidence/TC-001/step-1-response.json"`，相对 run_dir），而 run_dir 在被忽略的目录里 ⇒ 报告单独提交出去只剩一堆失效路径 |
| ③ | **报告里有明文口令与本机绝对路径** | `reproduction.command` 逐字搬运自用例集，内嵌 JSON 里的 `"password":"password123"` **没被脱敏**；`source.artifacts` 是**绝对路径** `/home/myg133/...`；md 里的「产物目录」同 |

用户原话（截取）：

> 「测试报告需要指明输出在项目根目录。对映证据需要是可提交的。引用文件的方式，会导致内容丢失。」

### 1.1 已实测的事实（勘察，不重查）

- **证据文件本身已被 `test-execute` 脱敏过**：`must_change_password` 的值已是 `"[REDACTED:field]"`；
  `auth_mode` 的值是 `"bearer (env: CD_TEST_TOKEN)"`（**环境变量引用，不是真 token**）；
  `page.secrets.manage` 是**业务权限点名，不是 secret 值**。
  ⇒ **真凭证不在证据文件里**；真漏洞在 `reproduction.command` 的**内嵌 JSON 字符串**。
- **证据量**：58 份文件 / 合计 360 KB / 单份最大 2695 B ⇒ 内联后 `report.json` 约 450 KB（可接受）。
- **证据文件里没有绝对路径**（0 份命中）—— 绝对路径只出现在 `source.artifacts` 与 md 的「产物目录」。
- **REQ-010 的 AC-025 钉死了「默认输出在 `<run_dir>/report/`」** ⇒ 新默认必须**显式取代**它
  （这是同一 skill 的行为演进，不是跨 skill 冲突；处置见 §4）。

---

## 2. 功能项

### F1 报告输出落在项目根的可提交位置

- **F1.1** 报告输出目录 = `<项目根>/reports/<run_id>/`，产出 `report.json` + `report.md` 两个文件。
- **F1.2** 项目根定位有两条路，**优先级如下**：
  1. **显式** `--project-root <dir>`；
  2. **反推**：仅当 run_dir 的形态是 `<root>/.test-artifacts/<id>` 时，`root` = run_dir 的上两级；
  3. **两条都不成立 ⇒ 报错退出（rc=1）**，stderr 必须点名 `--project-root`。
     **不许猜**（不许默认拿 cwd 当项目根，也不许默认拿 run_dir 当项目根）。
- **F1.2.1** **项目根「总是」需要**，不因 `--out-dir` 而豁免 —— 报告里的 `source.artifacts`
  必须**相对项目根**（F3.2），没有项目根就产不出合规报告。
  ⇒ `--out-dir` **只覆盖输出目录**，不豁免项目根定位。
- **F1.2.2** **输入合法性先于项目根定位**：先校验 `meta.json` / `results.json`，
  再定位项目根。⇒ 输入非法时报错必须点名**是什么坏了**（`产物目录` / `meta.json` /
  `results.json`），**不许**被「无法推断项目根」抢先（否则调用方拿到的是误导性的错误）。
- **F1.3** `--out-dir <dir>` 仍可用，**完全覆盖**默认输出目录（向后兼容，不废弃）。
- **F1.4** `<run_id>` 取自 `meta.json` 的 `run_id` 字段（**不自己编**）。

### F2 证据内容内联进报告（报告自包含）

- **F2.1** `report.json` 新增 `evidence.files[]`：**每一份实查存在的证据文件一条**，包括
  **passed 用例的证据**（不只失败用例的）。
- **F2.2** 每个条目的字段集**恰好**这 8 个：
  | 字段 | 类型 | 说明 |
  |---|---|---|
  | `case_id` | string | 该证据所属用例 id |
  | `step` | string | 步序号（从 `evidence/<case_id>/step-N-*.json` 的文件名解析；解析不出则为 `""`） |
  | `path` | string | **相对项目根**的路径（如 `.test-artifacts/<run_id>/evidence/TC-001/step-1-response.json`） |
  | `sha256` | string | **实算**的文件字节指纹（64 位 hex），不是抄 `results.json` |
  | `bytes` | number | 文件字节数 |
  | `media_type` | string | 从证据条目抄（`results.json` 里的 `media_type`）；缺失则按扩展名推断 |
  | `content` | string | **脱敏后的原始文本**（不是解析后再序列化 ⇒ 字节级保真） |
  | `content_sha256` | string | 对 `content`（UTF-8 字节）算的 sha256（64 位 hex） |
- **F2.3** **`content_sha256` 与 `sha256` 的关系是本 REQ 的核心不变量**：
  - 证据文件**不含任何敏感内容** ⇒ 脱敏器不动它 ⇒ **`content_sha256 == sha256`**（严格相等）；
  - 证据文件**含敏感内容** ⇒ 被替换 ⇒ `content_sha256 != sha256`，
    且报告必须**明确说明两者为何不等**（不是「证据被改」，是「展示层脱敏」）。
- **F2.4** `failures[].evidence[]` **保持既有语义不变**（逐字取自产物，含相对 run_dir 的
  `path`）—— 本 REQ **只做增量**，不改既有字段的含义。新增的 `evidence.files[]` 才是
  「实查 + 内联」的权威视图。
- **F2.5** **缺失的证据文件不内联**（没有内容可内联），且 `evidence.files_missing` /
  `evidence.missing_paths` / `evidence.findings[]` **照旧点名**。

### F3 报告内一律脱敏

脱敏器作用在**报告里所有来自产物的文本**上（证据内容、复现命令、错误消息、标题）。

| 类别 | 规则 | 占位符 |
|---|---|---|
| R1 敏感**字段名** | 对象的键命中敏感名单（`password` / `passwd` / `pwd` / `token` / `secret` / `api_key` / `apikey` / `access_key` / `private_key` / `authorization` / `cookie` / `credential` / `session` 等，大小写与分隔符不敏感）⇒ **整值替换** | `[REDACTED:field]` |
| R2 敏感**值模式** | ① 内嵌 JSON 形态：`"password":"xxx"`、`"token":"xxx"` 等（**这是 `reproduction.command` 的真漏洞**）；② `Bearer <token>`；③ URL 里的 `user:pass@host`；④ 独立的长十六进制/Base64 串（≥32 位） | `[REDACTED:secret]` |
| R3 **绝对路径** | 任何以 `/` 开头且落在项目根下的路径 ⇒ 换成**相对项目根**的路径 | 相对路径本身 |

- **F3.1** R1 的匹配**必须按完整键名**，不得误伤业务字段：
  - `must_change_password` 命中名单 ⇒ **值**替换（对）；
  - `page.secrets.manage` 是**字符串值**里的业务权限点 ⇒ **不得**替换（值模式 R2 只认
    `Bearer` / 内嵌 JSON / 长凭证形态，不认裸词）。
  - `bearer (env: CD_TEST_TOKEN)` 是**环境变量引用** ⇒ **不得**替换成 `[REDACTED:secret]`
    （否则读者不知道该配哪个环境变量）—— 但其中若夹带真 token 形态则仍须替换。
- **F3.2** R3 作用于**报告内所有字段**，包括 `source.artifacts`（绝对 ⇒ 相对项目根）、
  `evidence.files[].path`、md 正文。
- **F3.3** 报告新增 `redaction` 段，字段集恰好：
  `{rules_applied: string[], redacted_fields: number, redacted_values: number}`
  —— `rules_applied` 点名**实际启用**的规则（R1/R2/R3 的具体规则名），
  `redacted_fields` / `redacted_values` 是**替换计数**（不是 0 也不许瞎编）。
  **产物里没有敏感内容时**，该段必须如实写 `redacted_fields: 0` / `redacted_values: 0`
  —— 不得为了让报告「看起来在脱敏」而虚报计数。
- **F3.4** **被测目标的 IP 与端口保留**（如 `192.168.104.218:5173`）——
  它是**被测对象标识**，不是凭证；抹掉报告就失去意义。**用户名亦保留**
  （`chen.qiming` 是业务账号，不是密钥）。⚠️ 本条是**有意取舍**，已登记为决策 D214。
- **F3.5** **追踪 / 业务标识豁免名单**（D219）：下列**键名**下的值**原样保留**，不参与任何脱敏规则 ——
  `trace_id` / `x-trace-id` / `request_id` / `x-request-id` / `span_id` / `correlation_id` / `id` / `uuid`。
  **理由（真实数据实测）**：用户 YF-test 的 58 份证据里，32 位 hex 出现的键**全部**是业务标识
  （`x-trace-id` 58 / `trace_id` 27 / `items[].id` 16 / `id` 4），**没有一条是真凭证**；
  抹掉 `trace_id` 会让报告失去查后端日志的能力。
  ⇒ 判据 AC-011（`content_sha256 == sha256`）在**夹具里带一个 32 位 hex** ⇒ 豁免不生效就判红
  （这同时是 AC-011 的**反向探针**，不再是恒真）。

### F4 诚实性红线

- **F4.1** 报告必须**自陈脱敏**：md 正文里有一段说明「内联内容是脱敏后的；`sha256` 是原文件
  指纹，`content_sha256` 是脱敏后内容指纹；两者不等是因为脱敏，不是因为证据被改」。
- **F4.2** 脱敏**不得**影响证据层判定：证据缺失 / 指纹不符 / 计数不符 ⇒ 证据层仍判 `fail`。
- **F4.3** 不得因脱敏而**丢失证据内容**：`content` 必须是脱敏后的**完整原始文本**，
  不得截断、不得摘要、不得只留前 N 字节。
- **F4.4** 幂等：同一输入两次出报告，除 `generated_at` 外**逐字相同**。

### F5 组合门（`bin/verify-suite.mjs`）必须同步

组合门的 `scenarioReport` 场景（test-execute 的 offline 夹具 → test-report 出报告 →
断言三层结论）**硬编码了旧的调用形态**，本 REQ 改了默认输出位置与项目根要求 ⇒ 它必须同步：

- **F5.1** 调 `make-report.mjs` 时**必须给 `--project-root`**（offline 夹具的执行产物落在
  `<work>/exec-report`，**不是** `<root>/.test-artifacts/<id>` 形态 ⇒ 不可反推）。
- **F5.2** 该场景**改为走新的默认输出位置**（不给 `--out-dir`），并断言报告落在
  `<项目根>/reports/<run_id>/`（`<run_id>` = `verify-report`）——
  这样组合门就**实跑**验证了本次的核心行为，而不是只验证「显式指定了输出目录时能用」。
- **F5.3** 三层结论的断言（`verdict.*` / `cases.*`）**逐字不变**。

> ⚠️ 本条**不在** REQ-014 的验收门覆盖范围内（组合门有自己的门：REQ-011）；
> 由 REQ-011 的门 + 需求方复跑组合门验证。登记于此是为了**不漏**。

---

## 3. 非目标

- ❌ **不改 `test-execute` 侧**：`reproduction.command` 的明文口令在**产物生成侧**才是根因，
  但修它属 `test-execute` 的契约变更（REQ-010 同族），**不在本 REQ 范围**。
  本 REQ 在**报告侧**兜底（纵深防御），并把根因登记为遗留项（见 §5）。
- ❌ 不改 `test-execute` 的产物目录约定（`.test-artifacts/` 仍是不进 Git 的产物区）。
- ❌ 不引入第三方依赖、不联网（沿用 REQ-010 AC-026 的硬约束）。
- ❌ 不做报告的历史版本管理、不做多报告合并。
- ❌ 不改 `regression-plan` / `test-case-design` / `defect-verify` 等其他 skill。

---

## 4. 与 REQ-010 的关系（**显式取代**）

| 项 | REQ-010（收口时） | REQ-014（本次） |
|---|---|---|
| 默认输出位置 | `<run_dir>/report/`（AC-025 ①） | **`<项目根>/reports/<run_id>/`** |
| `--out-dir` | 覆盖默认 | **不变**（仍覆盖） |
| 项目根定位 | 无此概念 | `--project-root` 显式 / 从 run_dir 形态反推 / 否则报错 |
| 证据 | 路径引用 + 实查判定 | **保留路径引用 + 新增 `evidence.files[]` 内联** |
| 脱敏 | 无（逐字搬运） | **报告内一律脱敏** |

⇒ **REQ-010 的 AC-025 ①「默认输出在 `<run_dir>/report/`」被本 REQ 明确取代。**
处置：REQ-010 的契约与验收门**同步改**该分支（其余四项不动），门 sha 变化**如实登记**
（原 sha 保留 + 新 sha + 原因），并**重跑 REQ-010 完整门**确认其余判据仍绿。

---

## 5. 遗留项（登记不修，本 REQ 只兜底）

| 项 | 内容 | 归属 |
|---|---|---|
| L-01 | **`reproduction.command` 的明文口令在产物生成侧（`test-execute`）未脱敏**：命令是内嵌 JSON 字符串，字段名规则（R1）匹配不到，只有值模式（R2）能兜住。根因在 `test-execute` 产出 `results.json` 时就该脱敏 | 后续 REQ（改 `test-execute` 的契约与门；本 REQ 只在报告侧兜底） |
| L-02 | **报告里的被测 IP / 用户名保留**（有意取舍，见 F3.4）—— 若将来报告要进**公开**仓库，需另开脱敏维度 | 后续 REQ（按仓库可见性分级脱敏） |

---

## 6. 产物形状

`report.json` 顶层（**在 REQ-010 的 8 个键基础上新增 2 个**）：

```
schema_version / generated_at / source / cases / verdict / failures /
evidence / regression / report_sha256
                    ↑ 新增：evidence.files[]（内联视图）
                    ↑ 新增：redaction（脱敏自陈）
```

> ⚠️ REQ-010 AC-013 ⑤「顶层只允许**一个**数字型叶子字段（`schema_version`）」**仍然成立** ——
> 新增的两个段里**不得**出现顶层数字型叶子字段（`redaction.redacted_fields` 是**嵌套**的，不是顶层）。

---

## 7. 用户拍板（2026-11-17）

| 决策点 | 选定 | 说明 |
|---|---|---|
| 报告输出目录 | **`<项目根>/reports/<run_id>/`** | 沿用用户现有的 `reports/REQ-P0-api-contract-218-.../` 结构 |
| 证据形态 | **内容内联进 `report.json`** | 报告单文件自包含，单独提交也不丢 |
| 敏感内容 | **报告内一律脱敏** | 口令/凭证 → 占位符；绝对路径 → 相对路径 |
