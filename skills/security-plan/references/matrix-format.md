# 权限矩阵产物格式（`matrix.json`）

> 契约来源：需求 F4、决策 D105 / D106。

## 1. 形状

```json
{
  "schema_version": 1,
  "meta": { "service": "order-api", "generated_at": "…", "entry_count": 12 },
  "roles": [ { "id": "ROLE-1", "name": "匿名访客" } ],
  "resources": [ { "id": "RES-1", "name": "订单" } ],
  "entries": [
    { "role": "ROLE-1", "resource": "RES-1", "action": "read", "decision": "deny",
      "basis": "expected", "threat_ref": null, "note": "未登录不可读" },
    { "role": "ROLE-2", "resource": "RES-2", "action": "read", "decision": "allow",
      "basis": "gap", "threat_ref": "TH-9", "note": "只校验登录未校验归属，可越权读他人账号" }
  ]
}
```

| 字段 | 约束 |
|---|---|
| `roles` / `resources` | 与上下文对应段**集合相等**（id 集合相同、条数相同） |
| `entries` | **非空**数组 |
| `entries[].role` / `entries[].resource` | 必须 ∈ `roles[].id` / `resources[].id`（**不悬空**） |
| `entries[].action` | 非空字符串 |
| `entries[].decision` | 枚举 `allow` / `deny` |
| `entries[].basis` | 枚举 `expected` / `gap` |
| `entries[].threat_ref` | `null` 或 ∈ `threats[].id` |
| `entries[].note` | 可选字符串 |

**覆盖要求**：`(role, resource)` 的**每个组合**至少有一条 `entries` 记录。

## 2. 允许缺口口径（`basis`）

| `basis` | 含义 | 约束 |
|---|---|---|
| `expected` | 该决策是**预期行为** | `threat_ref` 必须为 `null` |
| `gap` | **本应拒绝却允许**的缺口 | `decision` 必须为 `allow`；`threat_ref` 必须**非空**且指向一条 `category == "elevation_of_privilege"`（越权类）的威胁 |

**双向对应**：每条 `category == "elevation_of_privilege"` 的威胁，**必须**被至少一条
`basis == "gap"` 的条目引用。（越权类威胁必须有对应的矩阵缺口，否则「威胁」落不到矩阵上。）

## 3. 本实现的判定口径

矩阵只登记「**由上下文可推导**」的现状；上下文没给的（例如写操作）一律按
**更安全的一侧**记录，并在 `note` 里写明这是待人工确认的假设 —— **不臆造事实**。

### 角色级别（由角色名推出）

| 级别 | 关键词 | 决策方向 |
|---|---|---|
| `anonymous` | 匿名 / anonymous / guest / 访客 / 未登录 / 公共 | 所有资源、所有动作 ⇒ `deny` + `expected` |
| `admin` | 管理员 / admin / 运维 / 超级 | 所有资源、所有动作 ⇒ `allow` + `expected` |
| `user` | **其它一律按最小权限当普通业务角色** | 见下 |

### 资源敏感度

资源敏感度取它 `asset_refs` 所关联资产的**最高**敏感度（critical > high > medium > low）。

### 凭据类资源

资源所关联的资产若命中「凭据 / 身份」关键词（口令 / 凭据 / 账号 / 账户 / 密钥 / 密码 /
credential / password / account / identity），该资源即「**凭据类资源**」。

### 决策表

| 角色级别 | 资源 | 动作 | `decision` | `basis` | `threat_ref` |
|---|---|---|---|---|---|
| `anonymous` | 任意 | 任意 | `deny` | `expected` | `null` |
| `admin` | 任意 | 任意 | `allow` | `expected` | `null` |
| `user` | 凭据类资源 | `read` | `allow` | **`gap`** | 越权类威胁（必须有） |
| `user` | 凭据类资源 | `write` | `deny` | `expected` | `null` |
| `user` | 其它资源 | 任意 | `allow` | `expected` | `null` |

⚠️ **只有凭据类资源的读操作判 `gap`** —— 「登录用户能看订单」是正常业务，
把它标成缺口是噪声；「登录用户能看**别人的账号**」才是越权。

⚠️ **双向对应怎么保证**：越权类威胁（`category == "elevation_of_privilege"`）只在
「存在普通业务角色 **且** 存在凭据类资源」时才产生 —— 这两个条件同时成立时，
上面决策表必然产出至少一条指向它的 `gap` 条目 ⇒ 双向对应**由构造保证**，不靠事后补。

## 4. 诚实性边界

- `decision` 记的是**现状**，`basis` 记的是「这条现状**是否符合**预期」。
- 上下文里没写清楚的东西（写操作、归属校验是否落地）⇒ 在 `note` 里**明说**是假设，
  交给人工确认，而不是替上下文编一个结论。
