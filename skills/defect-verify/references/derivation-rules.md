# 派生规则、编号约定与归一化口径

> 本文件是**契约**：脚本按这里的规则判，门按这里的规则判。
> 术语：**处置结论** = 每条缺陷的 `disposition`，取值 `derived` / `reused` / `unresolved`。

## 1. 判定顺序（固定）

```
① case_refs 非空？
   ├─ 是 → **先按 id 去重** → 逐个在已有用例集里找：
   │        全部找到 ⇒ reused（reused_case_refs 记 suite + case_id）
   │        任一找不到 ⇒ unresolved（reason 点名那个找不到的 id；**不得部分复用**）
   └─ 否 → ② 信息充分吗？（见 defect-input-schema.md §2.2）
            ├─ 否 ⇒ unresolved（reason 说明缺什么）
            └─ 是 → ③ 特征匹配
                     ├─ 命中 ⇒ reused（**不得再新建用例**）
                     └─ 未命中 ⇒ derived（派生 1 条新用例）
```

> ⚠️ **顺序的含义**：`reused` 不需要 `reproduction`，所以只要 `case_refs` 命中就直接复用，
> 即使缺陷单的复现信息不全；**信息充分性只是「派生分支」的前置**。

### 1.1 `case_refs` 分支

- `case_refs` **非空** ⇒ **先按 id 去重**（同一缺陷的 `case_refs` 内重复 id 先去重再判，
  去重后按「全部找到 ⇒ `reused`；任一找不到 ⇒ `unresolved`」判定）；
- **全部找到** ⇒ 处置 `reused`，`reused_case_refs` 记下每条用例的 **suite + case_id**；
- **任一找不到** ⇒ 处置 `unresolved`，`reason` **点名那个找不到的 id**；
  **不得部分复用**（一条缺陷要么复用成功，要么说不知道 —— 半条复用等于假装复用了）；
- 被复用的原用例 `status == "deprecated"` ⇒ 该缺陷**改判 `unresolved`**
  （理由：原用例已废弃，拉过来当复现用例是「名义上有覆盖、实际上跑不了」的假覆盖）。

### 1.2 特征匹配分支（`case_refs` 为空时）

- **特征（指纹）** = `归一化(command)` + `\0` + `归一化(steps 序列)`；
- **匹配规则**：某条已有用例与缺陷单的 **steps 指纹逐项相等**，**且**
  （两侧 **command 指纹相等** **或** 两侧 command **其一为空**）⇒ **命中**；
- **用例侧的 command** 取该用例的 `reproduction.command`（**若该用例带这个额外字段**），
  不带则视为**空**（上游 v2 用例集本来就没有这个字段）；
- **命中** ⇒ 处置 `reused`（记 `source_suite` / `source_case_id`），**不得再新建用例**；
- **未命中** ⇒ 处置 `derived`，**派生 1 条**复现用例；
- 命中的原用例 `status == "deprecated"` ⇒ 改判 `unresolved`（同上）。

## 2. 归一化口径（**写死**：实现与验收用同一套）

`norm(s)` 按顺序：

1. Unicode **NFKC** 规范化；
2. 去首尾空白；
3. 连续空白（`\s+`）压缩成**单个空格**；
4. 剥掉**成对包裹**的引号（`"…"` / `'…'` / `“…”` / `‘…’`）；
5. 去**末尾**标点（`。．.!！?？;；,，`）；
6. 再去首尾空白。

- **steps 指纹** = 各步 `norm(action)` 用 `\x01` 连接；
- **特征指纹** = `norm(command)` + `\0` + steps 指纹；
- 「其一为空即放行」是为了让**没有 `reproduction` 字段的 v2 用例**也能参与匹配。

> 这四步变换都是**不改变语义**的（NFKC 统一全/半角、压缩空白、剥引号、去尾标点），
> 所以「命中」确实意味着同一件事；而「只比 command」会让匹配能力归零（command 常缺失），
> 「只比 steps 的包含关系」会把不同步骤的用例误判成同一个 bug 的复现 —— 两者都不用。

## 3. 编号约定

- 复现用例的 `id` 必须匹配 `^TC-\d{3}$`（**三位**数字；`TC-1001` 不合法）。
- `reused` 的用例**沿用原 id**。
- `derived` 的新用例走**扩展编号段 `TC-101` ~ `TC-999`**（共 899 个号位；
  `TC-001`~`TC-100` 留给原套件，避免与被引用用例撞号）。
- 扩展段**已被输入用例集占用** ⇒ **顺延**到下一个空闲号
  （从 `TC-101` 起**向上扫描**，取第一个**既不在输入用例集里、也未被本轮已分配**的号位）。
- 扩展段**用尽** ⇒ 该缺陷改判 `unresolved` 并给非空理由。

## 4. 复现用例的形状

| 字段 | `derived` 取值 | `reused` 取值 |
|---|---|---|
| `id` | 扩展段新号 | **原 id**（逐字沿用） |
| `title` | `复现 <BUG-id>：<缺陷 title>` | 原用例的 `title`（沿用） |
| `requirement_refs` | 该缺陷对应的 `R-<n>` | **引用这条用例的全部缺陷**各自对应的 `R-<n>` |
| `dimension` | `functional` | 原用例的 `dimension` |
| `priority` | `P0` | 原用例的 `priority` |
| `method` | `["M1.1"]`（**缺省约定**，见下） | 原用例的 `method` |
| `status` | `active` | `active`（一律 active） |
| `preconditions` | `[]` | 原用例的 `preconditions` |
| `steps` | 由 `reproduction.steps` 派生（见 §5） | **原用例的 `steps`（逐字沿用）** |
| `data` | `{"command": …, "expected_failure": …}` | 原用例的 `data` |
| `tags` | `["defect-verify", "<BUG-id>"]` | 原用例的 `tags` ∪ `["defect-verify", <全部引用它的缺陷 id>]`（去重，原 tags 在前） |
| `defect_refs` | `["<BUG-id>"]`（派生只属于一条缺陷） | **引用它的全部缺陷 id** |
| `origin` | `"derived"` | `"reused"` |
| `source_case_id` | `null` | 原用例的 `id` |
| `source_suite` | `null` | 传入的套件标识 |

- `defect_refs` / `origin` / `source_case_id` / `source_suite` 是**额外字段** ——
  上游用例集校验器**不拦** `cases[]` 的额外字段，执行侧也**容忍**。
- ⚠️ **`method: ["M1.1"]` 是缺省约定，不是宣称做过完整方法学**：
  复现用例的目标是「把已知缺陷重跑一遍」，不是重新做一遍测试设计。
  这个约定**只是缺省值**：原用例声明了 `method` 就沿用原用例的，没声明才落回 `["M1.1"]`。

### 4.1 `steps` 的派生（`derived`）

- 每一步的 `action` = `reproduction.steps[i]` 的**原文**（逐字，不改写）；
- 每一步的 `expected` = `reproduction.expected_failure` 的**文本**（人读形态）；
- `steps` 至少 1 条。

> ⚠️ 这里的 `expected` 记的是**缺陷的失败现象**（= `expected_failure` 原文）——
> 复现用例的语义是「确认这个失败仍然发生」，不是「确认缺陷不发生」。

### 4.2 `requirement_refs` 不得悬空

- 产物文档的 `requirements[]` **只含缺陷条目**（每个缺陷一条）：
  `id` 用 `R-1`、`R-2`… **按缺陷在输入中的顺序**；`source_ref` = `defects.json#/defects/<下标>`；
- 复现用例的 `requirement_refs` **一律指向「它所复现的那个缺陷」的 `R-<n>`**（`reused` 与 `derived` 同）——
  本轮文档的主题是**缺陷**，复用的原用例自己的需求条目归属原套件，不搬进本轮；
- ⇒ `requirement_refs` **非空且不悬空**。

## 5. 共享场景的裁定（**多条缺陷引用同一条已有用例**）

这是本 REQ 最容易被实现错的一处，单独写清楚：

1. **同一缺陷的 `case_refs` 内出现重复 id** ⇒ **先去重**再判（去重后仍是「全中 ⇒ `reused`；
   任一找不到 ⇒ `unresolved`」）。
2. **多个缺陷引用同一条已有用例** ⇒ 产物里该用例**只出现一次**：
   - 该用例的 `defect_refs` 含**全部**引用它的缺陷 id；
   - 该用例的 `tags` 含 `defect-verify` 与**全部**这些缺陷 id；
   - 该用例的 `requirement_refs` 含**全部**相关缺陷的 `R-<n>`（仍**不悬空**）；
   - 每条缺陷**各自**的 `disposition` 仍独立为 `reused`，各自在 `reused_case_refs` 里记下这条用例。
3. 派生（`derived`）的用例**只属于一条缺陷**（`defect_refs` 恰好 1 个元素）。

**为什么这样裁定**：

- 若按「每条缺陷各产一条用例」处理，同一条已有用例会被复制成 N 条**同 id** 的用例 ——
  撞上游用例集校验器的「用例 ID 重复」**硬拦** ⇒ 产物**不可执行**；
- 反过来，若把后一条缺陷改判 `unresolved`（理由写「该用例已被占用」），等于宣称
  「这条缺陷没法复现」—— 而它**本来就能复现**（用的就是那条已有用例）。这是**假的「不知道」**；
- **共享**才贴近真实语义：**一条用例可以复现多个缺陷**（同一根因的多个症状）。

> ⚠️ 验收夹具（5 条缺陷互不共享用例）**造不出**这个场景 ⇒ 该分支的证据是
> `scripts/selftest-defect-cases.mjs` 的单元自测（T1 / T3），不是夹具。

## 6. 产物形状

- 顶层字段集**封闭**（7 个）：
  `schema_version` / `meta` / `requirements` / `open_questions` / `coverage_matrix` / `defects` / `cases`；
- `meta` 的字段集**开放**（可另带说明字段）：
  `source`（非空字符串）/ `generated_at`（ISO-8601）/ `case_count` / `defect_count` / `cycle_id` / `suite`；
- `requirements[]`：每个缺陷一条；
- `open_questions[]`：数组（可为空）；
- `coverage_matrix[]`：**每个被覆盖的需求条目一条**
  （`requirement` / `methods_applied` 含 `M1.1` / `dimensions` 含 `functional` / `skipped`）；
  **未被覆盖的（`unresolved` 缺陷）不列** —— 让它出现在「未覆盖需求条目」清单里，那才是诚实的；
- `defects[]`：**字段集封闭**，每条 `id` / `title` / `severity` / `status` / `disposition`，
  外加**条件字段** `reason`（`unresolved` 必填且非空）/ `reused_case_refs`（`reused` 必填）/
  `derived_case_id`（`derived` 必填）/ `source_cycle_id`（输入带 `cycle_id` 时搬运）；
  `disposition == "derived"` ⇒ **有** `derived_case_id`、**无** `reused_case_refs`、**无** `reason`，其余同理；
- `cases[]`：复现用例（见 §4）。

## 7. 诚实性红线

1. 输出里缺陷 id 的**集合必须等于**输入的缺陷 id 集合（不多、不少、不重、不漏）；
2. 每条缺陷**必须有且只有一个**处置结论；
3. `unresolved` **必须**给非空 `reason`；**不得**把「信息不足」悄悄变成「复用」或「派生」；
4. **不得凭空造缺陷**（输出的缺陷条目里不得出现输入没有的 id；用例的 `defect_refs` 同理）；
5. **不得重复派生**：已有对应用例的缺陷**不得**再产一条新用例；一个缺陷**最多**一条 `derived` 用例；
6. **不得修改输入**：缺陷单、已有用例集、`cycle.json` 逐字节未变；
7. **幂等**：同一输入两次运行，产物除 `meta.generated_at` 外**逐字相同**
   （**唯一**允许变动的字段是 `meta.generated_at`）。

## 8. 写入权

- **只写自己的输出目录**（`--out-dir` 指定，默认为 `--cycle-dir`）；**不得**写进输入所在目录；
- 产物 `<out-dir>/defect-cases.json` **已存在** ⇒ **报错退出**（不得覆盖别人的东西）；
- `<out-dir>` 不存在 ⇒ **创建**；
- `<out-dir>` 存在且含**除 `cycle.json` 之外**的任何文件 ⇒ **报错退出**；
- `<out-dir>` 存在且只含 `cycle.json`（默认 = `--cycle-dir` 时）⇒ **允许**。
