# 缺陷单格式（`defects.json`）

> 本文件是**契约**：脚本按这里的规则判，门按这里的规则判。
> 上游只给了**单条**缺陷记录的形状，**文件级契约由 REQ-007 定义**。

## 1. 文件形状

```json
{
  "schema_version": 1,
  "defects": [
    {
      "id": "BUG-001",
      "title": "满减券核销后实付金额多 0.01 元",
      "severity": "high",
      "description": "（可选）现象描述",
      "cycle_id": "R1-REQ-001",
      "run_id": "run-001",
      "case_refs": ["TC-017"],
      "evidence_path": ".test-artifacts/R1-REQ-001/evidence/TC-017",
      "status": "open",
      "reproducible": true,
      "root_cause": null,
      "reproduction": {
        "command": "curl -X POST https://api.example.com/coupon/redeem",
        "steps": ["以满减券下单", "触发核销"],
        "expected_failure": "实付金额比预期多 0.01 元"
      }
    }
  ]
}
```

## 2. 两层合法性划分（**最重要的一处**）

「报错退出」与「判 `unresolved`」是两件不同的事，必须分层，否则契约自相矛盾。

| 层 | 含义 | 判定 | 违反的后果 |
|---|---|---|---|
| **结构层** | 字段**缺了 / 类型错了 / 枚举越界了 / id 格式错或重复** —— 这份输入根本**不是**一份合法的缺陷单 | **报错退出**（退出码 1），stderr **点名坏点**，**不得产出任何产物** | 判红 |
| **内容层** | 字段**在**，但**内容不足以派生**（说不出怎么复现） | **不报错**，走处置判定 → `unresolved` + 非空 `reason` | 判 `unresolved`（不是失败） |

> ⚠️ **为什么不把内容层也做成报错**：`unresolved` 的存在意义就是「显式说不知道」。
> 一份缺了复现步骤的缺陷单是**真实存在的业务输入**（需求方还没查清），
> 把它当「非法文件」拒收，等于让工具对真实输入闭口不谈。

### 2.1 结构层：必填与类型约束（违反 → 报错退出，退出码 1）

| 位置 | 约束 | 报错示例 |
|---|---|---|
| 根 | 必须是对象（不是数组 / 不是标量） | `缺陷单的根节点必须是对象（不是数组或标量）: <file>` |
| `defects` | 必须是数组 | `defects 必须是数组（缺陷单 <file> 的 defects 字段类型非法）` |
| `defects[i]` | 必须是对象 | `defects[0] 必须是对象` |
| `defects[i].id` | **必填**，非空字符串，匹配 `^BUG-\d{3,}$`，**文件内唯一** | `defects[0].id 格式非法: BUG-XYZ（必须匹配 ^BUG-\d{3,}$）` / `defects[1].id 重复: BUG-001（…）` |
| `defects[i].title` | **必填**，非空字符串 | `defects[0].title 必须是非空字符串` |
| `defects[i].severity` | **必填**，枚举 `high` / `medium` / `low` | `defects[0].severity 越界: "critical"（允许值: high / medium / low）` |
| `defects[i].reproduction` | **若存在**必须是对象（`null` / 字符串 / 数组都非法） | `defects[0].reproduction 必须是对象（不能是 null / 字符串 / 数组）` |
| `defects[i].status` | **若存在**必须是枚举 `open` / `fixed` / `wont_fix` / `not_reproducible` | `defects[1].status 越界: "reopened"（…）` |
| `defects[i].reproducible` | **若存在**必须是 boolean | `defects[0].reproducible 必须是布尔值` |
| `defects[i].case_refs` | **若存在**必须是字符串数组（可为空数组） | `defects[0].case_refs 必须是数组` |
| `defects[i].cycle_id` / `run_id` / `evidence_path` / `description` | **若存在**必须是字符串 | `defects[0].cycle_id 必须是字符串` |
| `defects[i].root_cause` | **若存在**必须是字符串或 `null` | `defects[0].root_cause 必须是字符串或 null` |

### 2.2 内容层（不报错；由处置判定处理）

以下任一成立 ⇒ 该缺陷**信息不足以派生** ⇒ 处置 `unresolved` + 非空 `reason`：

- `reproduction` **缺失**；
- `reproduction.command` 缺失或为空白串；
- `reproduction.steps` 缺失、不是数组、或为空数组；
- `reproduction.expected_failure` 缺失或为空白串。

> ⚠️ `reproduction` **整体缺失**属于内容层（不是结构层）：一份还没填复现步骤的缺陷单是真实输入。

## 3. 错误退出的纪律

- 退出码：**1**（输入非法）/ **2**（用法错误：缺参数、参数不认）。
- stderr **必须点名是什么坏了**（含字段名与坏值）。
- **不得产出半份产物**：`defect-cases.json` **只要存在**就算留下了半份产物
  （**0 字节也算**，按**存在性**判定，不按「非空」判定）⇒ 实现必须**先校验、后写盘**。

## 4. 已有用例集（`cases.json`，schema v2）

- 根必须是对象且有 `cases` 数组；每条用例有非空字符串 `id`，且 `id` 在文件内唯一。
- 复用的用例沿用它的 `title` / `dimension` / `priority` / `method` / `preconditions` / `steps` / `data`。
- 用例侧参与特征匹配的 `command` 取该用例的 `reproduction.command`
  （**若该用例带这个额外字段**）；不带则视为**空**。
- 用例集**只读**：本 skill 绝不改写它。

## 5. R3 轮次目录（`cycle.json`）

- `round == "R3"`、`round_type == "defect-verify"`；
- `trigger == {"type": "defect", "ref": "<BUG-id>"}`，且 `trigger.ref` **必须 ∈ 输入缺陷 id 集合**
  （否则轮次与缺陷单对不上 ⇒ 输入非法 ⇒ 报错退出）；
- 轮次目录名 **== `cycle_id`**；
- `cycle.json` **只读不改写**（逐字节未变）。
