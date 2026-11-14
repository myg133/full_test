# 安全上下文格式（`--context`）

> 契约来源：需求 F1.2 / 决策 D99 / D101。**实现必须逐条满足**。
> 本文件是「安全上下文」这个输入的**唯一**格式说明。

## 1. 它是什么

安全上下文把一个服务的**资产 / 信任边界 / 入口点 / 角色 / 资源**写清楚。
威胁模型、权限矩阵、安全用例这三样产物**全部**从它派生 —— 上下文里没有的东西，
产物里不许凭空出现（诚实性红线 F8.1）。

## 2. `--out-dir` 的语义

`--out-dir` 是**目标项目根**（不是「产物目录」）。产物固定落在：

```
<out-dir>/test-assets/security/
├── threat-model.json
├── matrix.json
└── suites/SEC-<编号>-<短名>/{cases.json,suite.json}
```

工具**只写**这个目录，该路径之外一律**只读**（D98）。

## 3. 字段集

```json
{
  "schema_version": 1,
  "service": { "name": "order-api", "description": "订单服务" },
  "assets": [
    { "id": "AS-1", "name": "用户口令哈希", "sensitivity": "critical", "description": "口令散列" }
  ],
  "trust_boundaries": [
    { "id": "TB-1", "name": "公网到应用", "from": "互联网", "to": "应用网关",
      "controls": ["TLS 终止", "WAF 规则"] }
  ],
  "entry_points": [
    { "id": "EP-1", "name": "登录接口", "kind": "http",
      "asset_refs": ["AS-1"], "boundary_refs": ["TB-1"], "description": "POST /api/login" }
  ],
  "roles": [
    { "id": "ROLE-1", "name": "匿名访客" }
  ],
  "resources": [
    { "id": "RES-1", "name": "订单", "asset_refs": ["AS-2"] }
  ]
}
```

### 结构层约束（违反 ⇒ 退出码 1，**不留半份产物**）

| 位置 | 约束 |
|---|---|
| 根 | 必须是对象 |
| `schema_version` | 可选；若存在必须是 `1` |
| `service` | 必须是对象；`service.name` **必填**且非空字符串 |
| `assets` | **必填**，非空数组；每项 `id`（合 `^AS-\d{1,3}$`、文件内唯一）、`name`（非空）、`sensitivity`（枚举 `critical` / `high` / `medium` / `low`）、`description`（可选非空字符串） |
| `trust_boundaries` | **必填**，非空数组；每项 `id`（合 `^TB-\d{1,3}$`、唯一）、`name`（非空）、`controls`（**必填**数组，元素为非空字符串，**可为空数组**）、`from` / `to`（可选非空字符串） |
| `entry_points` | **必填**，非空数组；每项 `id`（合 `^EP-\d{1,3}$`、唯一）、`name`（非空）、`kind`（非空字符串，自由取值）、`asset_refs`（**必填非空**，每项 ∈ `assets[].id`）、`boundary_refs`（**必填非空**，每项 ∈ `trust_boundaries[].id`）、`description`（可选） |
| `roles` | **必填**，非空数组；每项 `id`（合 `^ROLE-\d{1,3}$`、唯一）、`name`（非空） |
| `resources` | **必填**，非空数组；每项 `id`（合 `^RES-\d{1,3}$`、唯一）、`name`（非空）、`asset_refs`（**必填非空**，每项 ∈ `assets[].id`） |

⚠️ **`roles` / `resources` 为什么也是必填**：权限矩阵是「角色 × 资源 × 动作」，
角色与资源必须**有出处**（来自上下文），不能由实现凭空捏造 —— 否则矩阵就是自说自话。

⚠️ **`controls` 允许是空数组**（= 这条边界上没有控制点 —— 这本身就是要写进威胁模型的事实），
但**不允许缺字段**（缺字段与「没有控制点」是两回事）。

## 4. 两层退出码

| 情形 | 退出码 |
|---|---|
| 缺 `--context` / 缺 `--out-dir` / 出现不认识的开关 | **2**（调用方式错误） |
| 参数给了但**内容非法**（缺字段 / 类型错 / 枚举越界 / id 重复 / id 格式错 / 引用悬空） | **1**（stderr 点名是什么坏了，**不得产出任何产物**） |

## 5. 可选输入

| 参数 | 语义 |
|---|---|
| `--cases <cases.json>` | 功能用例集（cases.json v2）。**用途仅限攻击面枚举的补充输入** + 产出用例 id 避让。本 skill **不消费**它的用例 id（不复用、不改写）。 |
| `--scan <扫描结果.json>` | 依赖扫描结果，三种合法形态见 `threat-model-format.md`。 |
| `--environment <环境名>` | 套件 `environment` 字段取值；缺省时取 `<out-dir>/test-assets/environments/` 下**按文件名排序的第一个**环境。 |
| `--requirement <需求编号>` | 套件 `requirement` 字段取值；缺省时取上下文的 `service.name`。 |

## 6. 怎么写一份好上下文

- 每个入口点都要写清它**碰哪些资产**、**跨哪条边界** —— 威胁与矩阵都靠这两条引用落地；
- `description` 写具体的接口 / 路径（本实现用它做攻击面枚举的输入面提示）；
- 资产名写**业务语义**（「用户口令哈希」而不是「表 t_user」）—— 威胁派生靠关键词命中；
- 角色名写**权限语义**（匿名访客 / 登录用户 / 管理员）—— 权限矩阵靠它定决策方向。
