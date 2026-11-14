# 威胁派生规则（威胁模型怎么来的）

> 契约来源：需求 F2 / F3 / F4 / F7、决策 D102 / D103 / D104 / D113 / D114 / D126。
> 判定口径属于**实现方的判断**（契约不写死），但「交代完整 + 理由非空 + 声明与事实一致」
> 是硬要求。

## 1. 派生流水线

```
安全上下文 ──► 规则集 ──► 威胁清单 ──► 覆盖声明（OWASP 十类 + 四类补充）
                    │                      │
                    └──► 扫描发现映射 ─────┘
                                  │
                     权限矩阵 ◄───┘（越权类威胁 ⇒ 允许缺口）
```

## 2. 规则表

每条规则产出的威胁都锚定**真实的**资产 + 信任边界 + 入口点，并写明 `rationale`。

| # | 规则 | 触发条件 | OWASP | STRIDE | 补充类 |
|---|---|---|---|---|---|
| 1 | 入口输入面兜底 | **每个**入口点都跑 | 文件类入口 ⇒ `A08`，其余 ⇒ `A03` | `tampering` | — |
| 2 | 认证入口 | 入口名 / 说明命中登录·认证·令牌等 | `A07` | `spoofing` | — |
| 3 | 接口错误响应 | 入口 `kind` 是 http/api 或名里带「接口」 | `A05` | `information_disclosure` | — |
| 4 | 跨入口业务流程 | 入口点 ≥ 2 **且**存在普通业务角色 | `A04` | `tampering` | — |
| 5 | 密码学环节 | 资产命中密钥·明文凭据·证书·加解密 | `A02` | `information_disclosure` | — |
| 6 | 出站请求 | 入口命中 URL·回调·webhook | `A10` | `information_disclosure` | `ssrf` |
| 7 | 文件上传 | 入口命中 上传·multipart·附件 | `A04` | `tampering` | `file_upload` |
| 8 | XML 解析 | 入口命中 xml | `A05` | `information_disclosure` | `xxe` |
| 9 | 反序列化 | 入口命中 反序列化·pickle·unserialize | `A08` | `tampering` | `deserialization` |
| 10 | 审计留痕 | 资产命中 日志·审计·监控 | `A09` | `repudiation` | — |
| 11 | 越权缺口 | 存在普通业务角色 **且**存在凭据类资源 | `A01` | `elevation_of_privilege` | — |
| 12 | 扫描发现 | 每条扫描发现 | 按发现分类（见下） | 按发现分类 | 按发现分类 |

### 关键词表

| 用途 | 关键词 |
|---|---|
| 认证 | 登录 登陆 认证 鉴权 授权 口令 凭据 令牌 会话 login signin auth token session credential |
| 密码学 | 密钥 私钥 明文口令 明文密码 明文凭据 加解密 加密 解密 证书 secret cipher encrypt decrypt certificate |
| 出站（SSRF） | url 回调 webhook 外链 图片地址 远程拉取 proxy fetch callback image redirect |
| 上传 | 上传 upload multipart 附件 文件上传 |
| XML | xml |
| 反序列化 | 反序列化 deserialize pickle unserialize marshal |
| 审计 | 日志 审计 监控 audit trail |
| 凭据类资产 | 口令 凭据 账号 账户 密钥 密码 credential password account identity |

⚠️ **「用户口令哈希」不算密码学环节**（哈希不是加解密）⇒ `A02` 在这类服务上自然不适用。
⚠️ 关键词命中的是**名称与说明**，不是运行时事实 —— 命中即**记一条威胁**，不命中即**显式记不适用 + 理由**，
两种情况都不假装「已经覆盖」。

## 3. 扫描发现 → 威胁

| 发现类型 | OWASP | STRIDE | 补充类 |
|---|---|---|---|
| 硬编码口令 / 密钥（bandit） | `A07` | `spoofing` | — |
| XML 解析（bandit） | `A05` | `information_disclosure` | `xxe` |
| 不安全反序列化（bandit） | `A08` | `tampering` | `deserialization` |
| 注入类（bandit） | `A03` | `tampering` | — |
| 依赖漏洞（npm audit） | `A06` | `tampering` | — |
| 其它 | `A05` | `tampering` | — |

**锚定方式**：先按扫描结果里的文件名 / 摘要与入口点的辨识度词匹配；匹配不到就
**保守锚定全部入口点** —— 宁可多标，也不把发现挂空（挂空 = 假的「已经覆盖」）。

**合并规则**：若模型侧已有一条威胁的 OWASP 类、STRIDE 类、入口点集合都与该发现完全一致，
则合并进那条威胁（`source` 变成 `model+scan`，`scan_refs` 加上该 finding id）；
否则单列一条 `source = "scan"` 的威胁。

## 4. 覆盖声明的口径

- **覆盖状态从威胁集合反推**：有该类威胁 ⇒ `covered`（`threat_refs` 恰为该类全部威胁）；
  没有 ⇒ `not_applicable` + 非空理由 + 一条 `open_questions[]`（`category` 等于该类）。
- ⇒ 「判不适用却造了该类威胁」这种自相矛盾**结构上不可能出现**。
- 四类实战补充同理：`covered` 的 `threat_refs` 恰为 `supplement_refs` 含该键的全部威胁 id。
- **不许静默跳过**：十类与四类**每类都有交代**。

## 5. 矩阵规则

见 `matrix-format.md` §3。要点：

- 越权类威胁只在「有普通业务角色 **且** 有凭据类资源」时产生；
- 这两个条件成立时，必然产出至少一条指向该威胁的 `gap` 条目 ⇒ **双向对应由构造保证**；
- 缺口只标在**凭据类资源的读操作**上 —— 其余组合是正常业务，标成缺口是噪声。

## 6. 诚实性红线

1. **威胁集合必须与输入可对账** —— 每条威胁锚定真实的资产 + 边界 + 入口点，`rationale` 非空；
   上下文的每个资产 / 边界 / 入口点都**至少**被一条威胁引用。
2. **`unresolved` / `not_applicable` 一律必须带非空理由**。
3. **不得凭空造「已覆盖」** —— 声明 `covered` 就必须有真实威胁支撑。
4. **不许静默跳过** —— OWASP 十类、四类实战补充，都必须有交代。
5. **只写 `--out-dir`**；**幂等**；**产物已存在即报错**。
