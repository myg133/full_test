// threats.mjs —— 威胁派生（OWASP 十类 + STRIDE 六类 + 四类实战补充 + 扫描接入）
//
// 契约要点：
//   - 威胁条目字段集**封闭 12 个**（D102）；`category` 用 STRIDE 六类，`owasp` 用 A01~A10；
//   - 每条威胁锚定**真实的**资产 + 信任边界 + 入口点（不得凭空造，F8.1）；
//   - 上下文的每个资产 / 边界 / 入口点都**至少**被一条威胁引用（AC-025：不漏）；
//   - OWASP 十类**逐类显式判定**（covered + threat_refs / not_applicable + 非空理由 +
//     一条 open_question）；四类实战补充逐类显式判定（D103 / D104）；
//   - 扫描发现必须映射成威胁；未提供扫描时不得出现 `source` 含 `scan` 的威胁（D113 / D114）。
//
// 判定口径（哪一类适用 / 不适用）属于**实现方的判断**（契约不写死），
// 但「交代完整 + 理由非空 + 声明与事实一致」是硬要求 —— 覆盖状态一律**从威胁集合反推**，
// 因此不会出现「说 not_applicable 却有该类威胁」的自相矛盾（AC-027）。

import { OWASP_CODES, OWASP_NAMES, SUPPLEMENT_KEYS } from './catalog.mjs';

/** 威胁条目的封闭字段集（12 个，顺序即写盘顺序）。 */
export const THREAT_FIELDS = Object.freeze([
  'id',
  'name',
  'category',
  'owasp',
  'asset_refs',
  'boundary_refs',
  'entry_point_refs',
  'severity',
  'source',
  'scan_refs',
  'supplement_refs',
  'rationale',
]);

// --- 关键词表（判定「这条威胁成不成立」的信号；写在 references/threat-derivation.md 里）---

/** 认证 / 身份类信号。 */
const AUTH_KW = ['登录', '登陆', '认证', '鉴权', '授权', '口令', '凭据', '令牌', '会话',
  'login', 'signin', 'sign-in', 'auth', 'token', 'session', 'credential'];
/** 密码学类信号（「口令哈希」**不算**命中：哈希不是密码学环节）。 */
const CRYPTO_KW = ['密钥', '私钥', '明文口令', '明文密码', '明文凭据', '加解密', '加密', '解密',
  '证书', 'secret', 'cipher', 'encrypt', 'decrypt', 'certificate'];
/** 出站请求（SSRF）类信号。 */
const SSRF_KW = ['url', '回调', 'webhook', '外链', '图片地址', '远程拉取', 'proxy', 'fetch',
  'callback', 'webhook', 'image', 'redirect'];
/** 文件上传类信号。 */
const UPLOAD_KW = ['上传', 'upload', 'multipart', '附件', '文件上传'];
/** XML 解析类信号。 */
const XML_KW = ['xml'];
/** 反序列化类信号。 */
const DESER_KW = ['反序列化', 'deserialize', 'pickle', 'unserialize', 'marshal'];
/** 审计留痕类信号（资产侧）。 */
const AUDIT_KW = ['日志', '审计', '监控', 'audit', 'trail'];
/** 凭据 / 身份类资产信号（用于判定「凭据类资源 ⇒ 越权缺口」）。 */
const CRED_KW = ['口令', '凭据', '账号', '账户', '密钥', '密码', 'credential', 'password',
  'account', 'identity'];

/** 命中不了太多噪声的通用词（做输入面提示时排除）。 */
const TOKEN_STOP = new Set(['http', 'https', 'json', 'data', 'none', 'post', 'get', 'put',
  'del', 'api', 'the', 'and', 'for', 'with', 'file']);

/**
 * 文本里是否命中任一关键词。
 * @param {string} text 待检文本（会被转小写）
 * @param {string[]} keywords 关键词表
 * @returns {boolean}
 */
export function hasAny(text, keywords) {
  const lowered = String(text || '').toLowerCase();
  return keywords.some((keyword) => lowered.includes(keyword.toLowerCase()));
}

/**
 * 角色权限级别（由角色名推出）。
 * 匿名 → anonymous / 管理员 → admin / 其它一律按**最小权限**当 user 处理。
 * @param {object} role 角色
 * @returns {'anonymous'|'admin'|'user'}
 */
export function roleLevel(role) {
  const name = String(role.name || '').toLowerCase();
  if (hasAny(name, ['匿名', 'anonymous', 'guest', '访客', '未登录', '公共'])) return 'anonymous';
  if (hasAny(name, ['管理员', 'admin', '运维', '超级'])) return 'admin';
  return 'user';
}

/**
 * 这个资产是不是「凭据 / 身份类资产」。
 * @param {object} asset 资产
 * @returns {boolean}
 */
export function isCredentialAsset(asset) {
  return hasAny(`${asset.name} ${asset.description || ''}`, CRED_KW);
}

/**
 * 入口点是不是「接口类」（有 HTTP 语义）。
 * @param {object} ep 入口点
 * @returns {boolean}
 */
export function isApiEntry(ep) {
  if (/http|api|rest|grpc|webhook/i.test(ep.kind)) return true;
  return hasAny(`${ep.name} ${ep.description || ''}`, ['接口', 'api', 'http', 'endpoint']);
}

/**
 * 提取入口点的「有辨识度的词」（用于把功能用例里的输入面对回入口点）。
 * @param {object} ep 入口点
 * @returns {string[]} 词表
 */
export function entryTokens(ep) {
  const text = `${ep.name} ${ep.description || ''}`;
  const raw = text.match(/[A-Za-z0-9_\-{}/]{4,}/g) || [];
  const tokens = new Set();
  for (const chunk of raw) {
    for (const part of chunk.split(/[^A-Za-z0-9_\-{}+]/)) {
      const lowered = part.toLowerCase();
      if (lowered.length >= 4 && !TOKEN_STOP.has(lowered)) tokens.add(lowered);
    }
  }
  return [...tokens];
}

/**
 * 把功能用例的动作线索挂到入口点上（攻击面枚举的**补充**输入）。
 * @param {object} ctx 归一化后的上下文
 * @param {{actions: {id: string, action: string}[]}} functional 功能用例集摘要
 * @returns {Map<string, string[]>} 入口点 id → 线索数组
 */
function buildHints(ctx, functional) {
  const hints = new Map();
  const actions = functional && Array.isArray(functional.actions) ? functional.actions : [];
  if (actions.length === 0) return hints;
  for (const ep of ctx.entryPoints) {
    const tokens = entryTokens(ep);
    if (tokens.length === 0) continue;
    const hits = [];
    for (const item of actions) {
      const lowered = String(item.action || '').toLowerCase();
      if (tokens.some((token) => lowered.includes(token))) {
        hits.push(`${item.id}: ${item.action}`);
      }
    }
    if (hits.length > 0) hints.set(ep.id, hits);
  }
  return hints;
}

/**
 * 把扫描发现分类到 OWASP 类 / STRIDE 类 / 补充类。
 * @param {object} finding 扫描发现
 * @param {string} kind 扫描器种类（bandit / npm-audit）
 * @returns {{owasp: string, category: string, supplement: string|null, title: string}}
 */
export function classifyFinding(finding, kind) {
  const text = `${finding.summary || ''} ${finding.detail || ''} ${finding.testId || ''}`.toLowerCase();
  if (kind === 'npm-audit') {
    return {
      owasp: 'A06',
      category: 'tampering',
      supplement: null,
      title: `第三方依赖存在已知漏洞（${finding.summary}）`,
    };
  }
  if (hasAny(text, ['hardcoded', 'password', 'secret', 'credential', '密码', '口令'])) {
    return {
      owasp: 'A07',
      category: 'spoofing',
      supplement: null,
      title: '代码中存在硬编码凭据',
    };
  }
  if (hasAny(text, ['xml'])) {
    return {
      owasp: 'A05',
      category: 'information_disclosure',
      supplement: 'xxe',
      title: 'XML 解析配置不安全（可能存在 XXE）',
    };
  }
  if (hasAny(text, ['pickle', 'deserial', '反序列化', 'marshal', 'yaml.load'])) {
    return {
      owasp: 'A08',
      category: 'tampering',
      supplement: 'deserialization',
      title: '存在不安全的反序列化处理',
    };
  }
  if (hasAny(text, ['injection', 'sql', 'command', 'shell'])) {
    return {
      owasp: 'A03',
      category: 'tampering',
      supplement: null,
      title: '扫描器报告了注入风险',
    };
  }
  return {
    owasp: 'A05',
    category: 'tampering',
    supplement: null,
    title: '扫描器报告了安全问题',
  };
}

/**
 * 派生威胁模型。
 *
 * @param {object} ctx 归一化后的安全上下文
 * @param {object} scan 扫描结果摘要（parseScan 的产物）
 * @param {object} functional 功能用例集摘要（readFunctionalCases 的产物）
 * @returns {{threats: object[], owaspCoverage: object, supplements: object, openQuestions: object[], scanFindings: object[]}}
 */
export function deriveThreats(ctx, scan, functional) {
  const assetById = new Map(ctx.assets.map((item) => [item.id, item]));
  const boundaryById = new Map(ctx.trustBoundaries.map((item) => [item.id, item]));
  const hints = buildHints(ctx, functional);

  const threats = [];
  const push = (draft) => {
    const threat = {
      id: `TH-${threats.length + 1}`,
      name: draft.name,
      category: draft.category,
      owasp: draft.owasp,
      asset_refs: draft.asset_refs.slice(),
      boundary_refs: draft.boundary_refs.slice(),
      entry_point_refs: draft.entry_point_refs.slice(),
      severity: draft.severity,
      source: draft.source || 'model',
      scan_refs: (draft.scan_refs || []).slice(),
      supplement_refs: (draft.supplement_refs || []).slice(),
      rationale: draft.rationale,
    };
    threats.push(threat);
    return threat;
  };

  const assetNames = (ids) => ids.map((id) => {
    const asset = assetById.get(id);
    return asset ? `${asset.name}（${id}）` : id;
  }).join('、');
  const boundaryNames = (ids) => ids.map((id) => {
    const boundary = boundaryById.get(id);
    return boundary ? `${boundary.name}（${id}）` : id;
  }).join('、');
  const epLabel = (ep) => (ep.description ? `${ep.name}（${ep.description}）` : ep.name);
  const hintText = (epId) => {
    const list = hints.get(epId);
    if (!list || list.length === 0) return '';
    return `；功能用例里已出现该输入面（${list.join('；')}）`;
  };

  const allAssetIds = ctx.assets.map((item) => item.id);
  const allBoundaryIds = ctx.trustBoundaries.map((item) => item.id);
  const allEntryIds = ctx.entryPoints.map((item) => item.id);
  const userRoles = ctx.roles.filter((role) => roleLevel(role) === 'user');
  const credentialAssets = ctx.assets.filter((asset) => isCredentialAsset(asset));
  const credentialResourceIds = ctx.resources
    .filter((resource) => resource.asset_refs.some((id) => credentialAssets.some((a) => a.id === id)))
    .map((resource) => resource.id);

  // --- 规则 1（兜底，覆盖面）：每个入口点至少一条威胁，锚定它自己的资产与边界 ---
  for (const ep of ctx.entryPoints) {
    const fileLike = /file/i.test(ep.kind);
    push({
      name: fileLike
        ? `入口「${ep.name}」的文件写入缺少类型与路径校验`
        : `入口「${ep.name}」存在注入风险（外部输入缺少服务端校验）`,
      category: 'tampering',
      owasp: fileLike ? 'A08' : 'A03',
      asset_refs: ep.asset_refs.slice(),
      boundary_refs: ep.boundary_refs.slice(),
      entry_point_refs: [ep.id],
      severity: 'high',
      rationale: fileLike
        ? `入口「${epLabel(ep)}」在信任边界「${boundaryNames(ep.boundary_refs)}」上接收外部内容并影响资产「${assetNames(ep.asset_refs)}」，` +
          '未见内容类型、路径与大小的校验，存在日志注入、任意文件写入或恶意内容植入的风险' +
          hintText(ep.id)
        : `入口「${epLabel(ep)}」在信任边界「${boundaryNames(ep.boundary_refs)}」上接收外部输入并影响资产「${assetNames(ep.asset_refs)}」，` +
          '边界上未见针对该入口的输入类型 / 长度 / 取值白名单校验，存在参数注入与类型混淆风险' +
          hintText(ep.id),
    });
  }

  // --- 规则 2：认证入口（A07 / spoofing） ---
  for (const ep of ctx.entryPoints) {
    if (!hasAny(`${ep.name} ${ep.description || ''}`, AUTH_KW)) continue;
    push({
      name: `入口「${ep.name}」的认证机制可被暴力猜解或会话劫持`,
      category: 'spoofing',
      owasp: 'A07',
      asset_refs: ep.asset_refs.slice(),
      boundary_refs: ep.boundary_refs.slice(),
      entry_point_refs: [ep.id],
      severity: 'high',
      rationale: `入口「${epLabel(ep)}」直接处理凭据 / 会话，信任边界「${boundaryNames(ep.boundary_refs)}」上只登记了 ` +
        `${boundaryById.get(ep.boundary_refs[0]) ? boundaryById.get(ep.boundary_refs[0]).controls.join('、') || '未登记任何控制点' : '未登记任何控制点'}，` +
        '未见失败锁定、速率限制与会话绑定，存在暴力猜解与令牌劫持的风险',
    });
  }

  // --- 规则 3：接口错误响应（A05 / information_disclosure） ---
  for (const ep of ctx.entryPoints) {
    if (!isApiEntry(ep)) continue;
    push({
      name: `入口「${ep.name}」的错误响应可能泄露内部实现信息`,
      category: 'information_disclosure',
      owasp: 'A05',
      asset_refs: ep.asset_refs.slice(),
      boundary_refs: ep.boundary_refs.slice(),
      entry_point_refs: [ep.id],
      severity: 'medium',
      rationale: `入口「${epLabel(ep)}」在异常路径上直接返回错误，若沿用默认框架的错误页会把堆栈、SQL 片段、内部路径或` +
        `服务端可达地址回显给调用方，泄露资产「${assetNames(ep.asset_refs)}」的实现细节`,
    });
  }

  // --- 规则 4：跨入口业务流程（A04 / tampering） ---
  if (ctx.entryPoints.length >= 2 && userRoles.length > 0) {
    const eps = ctx.entryPoints;
    const epsAssets = [...new Set(eps.flatMap((ep) => ep.asset_refs))];
    const epsBoundaries = [...new Set(eps.flatMap((ep) => ep.boundary_refs))];
    push({
      name: '业务流程缺少服务端强制校验（可跳过前置步骤直接调用后置接口）',
      category: 'tampering',
      owasp: 'A04',
      asset_refs: epsAssets.length > 0 ? epsAssets : allAssetIds,
      boundary_refs: epsBoundaries.length > 0 ? epsBoundaries : allBoundaryIds,
      entry_point_refs: eps.map((ep) => ep.id),
      severity: 'medium',
      rationale: `角色「${userRoles.map((role) => role.name).join('、')}」可以依次调用 ${eps.length} 个入口点（` +
        `${eps.map((ep) => ep.name).join('、')}），但上下文里没有登记任何跨步骤的状态 / 顺序 / 次数校验，` +
        '攻击者可能跳过前置步骤直接调用后置入口，破坏资产「' + assetNames(epsAssets) + '」的业务约束',
    });
  }

  // --- 规则 5：密码学环节（A02 / information_disclosure） ---
  for (const asset of ctx.assets) {
    if (!hasAny(`${asset.name} ${asset.description || ''}`, CRYPTO_KW)) continue;
    const eps = ctx.entryPoints.filter((ep) => ep.asset_refs.includes(asset.id));
    const epsAssets = [...new Set(eps.flatMap((ep) => ep.asset_refs))];
    const epsBoundaries = [...new Set(eps.flatMap((ep) => ep.boundary_refs))];
    push({
      name: `资产「${asset.name}」涉及的密码学环节缺少统一实现`,
      category: 'information_disclosure',
      owasp: 'A02',
      asset_refs: [asset.id],
      boundary_refs: epsBoundaries.length > 0 ? epsBoundaries : allBoundaryIds,
      entry_point_refs: eps.length > 0 ? eps.map((ep) => ep.id) : allEntryIds,
      severity: 'critical',
      rationale: `资产「${asset.name}（${asset.id}）」的名称 / 说明命中了密码学关键词，说明本服务存在加解密或密钥处理环节；` +
        '但上下文里没有登记对应的算法、密钥来源与轮换策略，存在弱算法、明文密钥或密钥硬编码的风险',
    });
  }

  // --- 规则 6：出站请求（A10 + ssrf 补充 / information_disclosure） ---
  for (const ep of ctx.entryPoints) {
    if (!hasAny(`${ep.name} ${ep.description || ''}`, SSRF_KW)) continue;
    push({
      name: `入口「${ep.name}」可能触发服务端请求伪造`,
      category: 'information_disclosure',
      owasp: 'A10',
      asset_refs: ep.asset_refs.slice(),
      boundary_refs: ep.boundary_refs.slice(),
      entry_point_refs: [ep.id],
      severity: 'high',
      supplement_refs: ['ssrf'],
      rationale: `入口「${epLabel(ep)}」的名称 / 说明里出现了可由外部指定的地址（URL / 回调 / webhook），` +
        '若服务端直接按该地址发起请求且没有目标网段白名单，攻击者可借它访问内网服务或元数据接口',
    });
  }

  // --- 规则 7：文件上传（file_upload 补充 / A04 / tampering） ---
  for (const ep of ctx.entryPoints) {
    if (!hasAny(`${ep.name} ${ep.description || ''}`, UPLOAD_KW)) continue;
    push({
      name: `入口「${ep.name}」的文件上传缺少类型、大小与存储路径校验`,
      category: 'tampering',
      owasp: 'A04',
      asset_refs: ep.asset_refs.slice(),
      boundary_refs: ep.boundary_refs.slice(),
      entry_point_refs: [ep.id],
      severity: 'high',
      supplement_refs: ['file_upload'],
      rationale: `入口「${epLabel(ep)}」接收用户上传的文件，上下文里没有登记允许的类型 / 扩展名 / 大小上限与落盘路径约束，` +
        '存在上传可执行文件、覆盖既有文件或借上传落地持久化后门的风险',
    });
  }

  // --- 规则 8：XML 解析（xxe 补充 / A05 / information_disclosure） ---
  for (const ep of ctx.entryPoints) {
    if (!hasAny(`${ep.name} ${ep.description || ''}`, XML_KW)) continue;
    push({
      name: `入口「${ep.name}」的 XML 解析可能允许外部实体`,
      category: 'information_disclosure',
      owasp: 'A05',
      asset_refs: ep.asset_refs.slice(),
      boundary_refs: ep.boundary_refs.slice(),
      entry_point_refs: [ep.id],
      severity: 'high',
      supplement_refs: ['xxe'],
      rationale: `入口「${epLabel(ep)}」处理 XML 报文，上下文里没有登记是否禁用外部实体与 DTD，` +
        '若解析器放开外部实体，可被用来读取服务端文件或发起内网请求',
    });
  }

  // --- 规则 9：反序列化（deserialization 补充 / A08 / tampering） ---
  for (const ep of ctx.entryPoints) {
    if (!hasAny(`${ep.name} ${ep.description || ''}`, DESER_KW)) continue;
    push({
      name: `入口「${ep.name}」对外部数据做反序列化`,
      category: 'tampering',
      owasp: 'A08',
      asset_refs: ep.asset_refs.slice(),
      boundary_refs: ep.boundary_refs.slice(),
      entry_point_refs: [ep.id],
      severity: 'high',
      supplement_refs: ['deserialization'],
      rationale: `入口「${epLabel(ep)}」对外部输入做反序列化，上下文里没有登记反序列化白名单或类型校验，` +
        '存在被构造载荷篡改内存状态或触发副作用的风险',
    });
  }

  // --- 规则 10：审计留痕（A09 / repudiation） ---
  for (const asset of ctx.assets) {
    if (!hasAny(`${asset.name} ${asset.description || ''}`, AUDIT_KW)) continue;
    const eps = ctx.entryPoints.filter((ep) => ep.asset_refs.includes(asset.id));
    const epsAssets = [...new Set(eps.flatMap((ep) => ep.asset_refs))];
    const epsBoundaries = [...new Set(eps.flatMap((ep) => ep.boundary_refs))];
    push({
      name: `资产「${asset.name}」的审计留痕可能不完整`,
      category: 'repudiation',
      owasp: 'A09',
      asset_refs: [asset.id],
      boundary_refs: epsBoundaries.length > 0 ? epsBoundaries : allBoundaryIds,
      entry_point_refs: eps.length > 0 ? eps.map((ep) => ep.id) : allEntryIds,
      severity: 'medium',
      rationale: `资产「${asset.name}（${asset.id}）」是审计留痕的载体，但上下文里没有登记哪些关键操作必须落日志、谁可以读日志，` +
        '一旦关键操作不落痕，事后无法对操作人取证（抵赖风险）',
    });
  }

  // --- 规则 11：越权缺口（A01 / elevation_of_privilege）---
  //   普通角色 + 凭据类资源 ⇒ 只校验登录态、未校验归属 ⇒ 越权。
  //   这条威胁是权限矩阵「允许缺口」的**唯一**依据（F4 的双向对应）。
  if (userRoles.length > 0 && credentialResourceIds.length > 0) {
    const resources = ctx.resources.filter((resource) => credentialResourceIds.includes(resource.id));
    const resourceAssets = [...new Set(resources.flatMap((resource) => resource.asset_refs))];
    const eps = ctx.entryPoints.filter((ep) =>
      ep.asset_refs.some((id) => resourceAssets.includes(id)));
    const epsAssets = [...new Set(eps.flatMap((ep) => ep.asset_refs))];
    const epsBoundaries = [...new Set(eps.flatMap((ep) => ep.boundary_refs))];
    push({
      name: `普通角色对凭据类资源缺少归属校验（可越权访问他人${resources.map((r) => r.name).join('、')}）`,
      category: 'elevation_of_privilege',
      owasp: 'A01',
      asset_refs: resourceAssets,
      boundary_refs: epsBoundaries.length > 0 ? epsBoundaries : allBoundaryIds,
      entry_point_refs: eps.length > 0 ? eps.map((ep) => ep.id) : allEntryIds,
      severity: 'high',
      rationale: `角色「${userRoles.map((role) => role.name).join('、')}」对资源「${resources.map((r) => r.name).join('、')}」` +
        `（关联资产「${assetNames(resourceAssets)}」，敏感度 ${ctx.assets.filter((a) => resourceAssets.includes(a.id)).map((a) => a.sensitivity).join('/')}）` +
        '只登记了登录态校验、没有归属（属主 / 租户）校验 ⇒ 登录用户可读写他人数据',
    });
  }

  // --- 扫描接入：每条扫描发现都必须映射到一条威胁（D114）---
  const scanFindings = [];
  for (const finding of scan.findings) {
    const cls = classifyFinding(finding, scan.kind);
    const eps = anchorEntryPoints(finding, ctx);
    const epsAssets = [...new Set(eps.flatMap((ep) => ep.asset_refs))];
    const epsBoundaries = [...new Set(eps.flatMap((ep) => ep.boundary_refs))];
    const same = threats.find(
      (threat) => threat.owasp === cls.owasp && threat.category === cls.category &&
        threat.entry_point_refs.length === eps.length &&
        eps.every((ep) => threat.entry_point_refs.includes(ep.id)),
    );
    let target;
    if (same) {
      same.source = 'model+scan';
      if (!same.scan_refs.includes(finding.id)) same.scan_refs.push(finding.id);
      if (cls.supplement && !same.supplement_refs.includes(cls.supplement)) {
        same.supplement_refs.push(cls.supplement);
      }
      target = same;
    } else {
      target = push({
        name: cls.title,
        category: cls.category,
        owasp: cls.owasp,
        asset_refs: epsAssets.length > 0 ? epsAssets : allAssetIds,
        boundary_refs: epsBoundaries.length > 0 ? epsBoundaries : allBoundaryIds,
        entry_point_refs: eps.map((ep) => ep.id),
        severity: finding.severity,
        source: 'scan',
        scan_refs: [finding.id],
        supplement_refs: cls.supplement ? [cls.supplement] : [],
        rationale: `依赖扫描结果「${finding.sourceLabel}」报告：${finding.summary}。` +
          `该发现落在资产「${assetNames(epsAssets.length > 0 ? epsAssets : allAssetIds)}」上，` +
          '影响经由入口点 ' + eps.map((ep) => ep.name).join('、') + ' 可达 ⇒ 登记为一条扫描来源的威胁',
      });
    }
    scanFindings.push({
      id: finding.id,
      severity: finding.severity,
      summary: finding.summary,
      threat_refs: [target.id],
    });
  }

  // --- 覆盖兜底：上下文的每个资产 / 边界 / 入口点都至少被一条威胁引用（AC-025）---
  const usedAssets = new Set(threats.flatMap((threat) => threat.asset_refs));
  const usedBoundaries = new Set(threats.flatMap((threat) => threat.boundary_refs));
  const usedEntries = new Set(threats.flatMap((threat) => threat.entry_point_refs));

  for (const asset of ctx.assets) {
    if (usedAssets.has(asset.id)) continue;
    const eps = ctx.entryPoints.filter((ep) => ep.asset_refs.includes(asset.id));
    const anchors = eps.length > 0 ? eps : ctx.entryPoints;
    push({
      name: `资产「${asset.name}」没有被任何入口点直接引用，仍可能被越权路径间接暴露`,
      category: 'information_disclosure',
      owasp: 'A05',
      asset_refs: [asset.id],
      boundary_refs: [...new Set(anchors.flatMap((ep) => ep.boundary_refs))],
      entry_point_refs: anchors.map((ep) => ep.id),
      severity: asset.sensitivity === 'critical' ? 'high' : 'medium',
      rationale: `资产「${asset.name}（${asset.id}，敏感度 ${asset.sensitivity}）」没有出现在任何入口点的 asset_refs 里，` +
        '但它仍是需要保护的数据；若只按入口点做威胁推导，它会被整条漏掉 ⇒ 这里显式补一条威胁兜底，避免遗漏',
    });
  }

  for (const boundary of ctx.trustBoundaries) {
    if (usedBoundaries.has(boundary.id)) continue;
    const eps = ctx.entryPoints.filter((ep) => ep.boundary_refs.includes(boundary.id));
    const anchors = eps.length > 0 ? eps : ctx.entryPoints;
    const epsAssets = [...new Set(anchors.flatMap((ep) => ep.asset_refs))];
    push({
      name: `信任边界「${boundary.name}」上没有登记任何控制点`,
      category: 'tampering',
      owasp: 'A05',
      asset_refs: epsAssets.length > 0 ? epsAssets : allAssetIds,
      boundary_refs: [boundary.id],
      entry_point_refs: anchors.map((ep) => ep.id),
      severity: 'medium',
      rationale: `信任边界「${boundary.name}（${boundary.id}）」的 controls 为空数组（= 没有控制点），` +
        '跨越这条边界的流量没有任何登记在案的防护，是典型的默认配置风险',
    });
  }

  for (const ep of ctx.entryPoints) {
    if (usedEntries.has(ep.id)) continue;
    push({
      name: `入口「${ep.name}」的威胁面尚未被梳理`,
      category: 'tampering',
      owasp: 'A05',
      asset_refs: ep.asset_refs.slice(),
      boundary_refs: ep.boundary_refs.slice(),
      entry_point_refs: [ep.id],
      severity: 'medium',
      rationale: `入口「${epLabel(ep)}」在上下文里登记了，但没有匹配到任何已知的威胁规则；` +
        '这里显式登记一条待人工确认的威胁，避免它在清单里消失',
    });
  }

  // --- OWASP 十类：逐类显式判定（覆盖状态**从威胁集合反推**）---
  const classReasons = buildClassReasons(ctx, scan, {
    userRoles,
    credentialResourceIds,
  });
  const owaspCoverage = {};
  const openQuestions = [];
  let questionIndex = 0;
  for (const code of OWASP_CODES) {
    const refs = threats.filter((threat) => threat.owasp === code).map((threat) => threat.id);
    if (refs.length > 0) {
      owaspCoverage[code] = { status: 'covered', threat_refs: refs };
      continue;
    }
    const reason = classReasons[code];
    questionIndex += 1;
    const questionId = `Q-${questionIndex}`;
    openQuestions.push({
      id: questionId,
      category: code,
      question: `本服务是否真的不涉及「${OWASP_NAMES[code]}」相关环节？请确认上下文里没有漏登记的${OWASP_NAMES[code]}相关资产 / 入口。`,
      reason,
    });
    owaspCoverage[code] = {
      status: 'not_applicable',
      reason,
      open_question_ref: questionId,
    };
  }

  // --- 四类实战补充：逐类显式判定 ---
  const supplements = {};
  for (const key of SUPPLEMENT_KEYS) {
    const refs = threats
      .filter((threat) => threat.supplement_refs.includes(key))
      .map((threat) => threat.id);
    if (refs.length > 0) {
      supplements[key] = { status: 'covered', threat_refs: refs };
    } else {
      supplements[key] = {
        status: 'not_applicable',
        reason: supplementReason(key, ctx),
      };
    }
  }

  return { threats, owaspCoverage, supplements, openQuestions, scanFindings };
}

/**
 * 把扫描发现锚定到入口点。
 * 优先按文件名 / 描述里的辨识度词匹配；匹配不到就**保守锚定全部入口点**
 * （宁可多标，也不把发现挂空 —— 挂空 = 假的「已经覆盖」）。
 * @param {object} finding 扫描发现
 * @param {object} ctx 归一化后的上下文
 * @returns {object[]} 锚定的入口点
 */
export function anchorEntryPoints(finding, ctx) {
  const haystack = `${finding.file || ''} ${finding.summary || ''} ${finding.detail || ''}`.toLowerCase();
  const matched = ctx.entryPoints.filter((ep) => {
    const tokens = entryTokens(ep);
    return tokens.length > 0 && tokens.some((token) => haystack.includes(token));
  });
  return matched.length > 0 ? matched : ctx.entryPoints;
}

/**
 * 各 OWASP 类的「不适用」理由（每条都必须非空，且说清**检查了什么**）。
 * @param {object} ctx 归一化后的上下文
 * @param {object} scan 扫描摘要
 * @param {object} facts 判定用的事实
 * @returns {object} code → 理由
 */
function buildClassReasons(ctx, scan, facts) {
  const reasons = {
    A01: facts.credentialResourceIds.length > 0
      ? '（本类不适用）'
      : '上下文里的资源没有关联到任何凭据 / 身份类资产（未命中口令 / 账号 / 密钥等关键词），未发现可被越权访问的身份数据',
    A02: '已检查 assets / entry_points / resources 的名称与说明，未命中任何密码学关键词（密钥、明文凭据、证书、加解密），本服务不涉及密码学环节',
    A03: '（本类不适用）',
    A04: facts.userRoles.length === 0
      ? '上下文里没有普通业务角色，不存在跨角色的流程编排，不安全设计类风险不成立'
      : `上下文里只有 ${ctx.entryPoints.length} 个入口点，不构成跨入口的业务流程编排，不安全设计类风险不成立`,
    A05: ctx.entryPoints.every((ep) => !isApiEntry(ep))
      ? '上下文里没有接口类入口点，错误响应与默认配置类风险不在本服务的攻击面内'
      : '（本类不适用）',
    A06: scan.status === 'not_provided'
      ? '本次没有提供依赖扫描结果（scan.status=not_provided），第三方组件的已知漏洞未评估，不能声称已覆盖'
      : `本次只提供了代码级扫描（${scan.tool || '未知工具'}），没有提供依赖清单扫描（npm audit），第三方组件的已知漏洞未评估，不能声称已覆盖`,
    A07: '上下文里没有命中登录 / 认证 / 令牌等关键词的入口点，本服务不承担身份识别与认证职责',
    A08: '上下文里没有文件类入口点，也没有登记数据落库 / 完整性校验环节，软件与数据完整性风险不成立',
    A09: '上下文里没有登记日志 / 审计类资产，本服务不承担安全日志与监控职责',
    A10: '上下文里没有命中 URL / 回调 / webhook 等出站请求入口，本服务不由外部输入触发服务端出站请求',
  };
  // A01 / A03 / A04 / A05 在**有**对应事实时不会走到 not_applicable 分支；
  // 这里兜底成非空理由，避免出现空字符串。
  if (reasons.A01.startsWith('（本类')) {
    reasons.A01 = '上下文的资源没有关联到任何凭据 / 身份类资产，未发现可被越权访问的身份数据';
  }
  if (reasons.A03.startsWith('（本类')) {
    reasons.A03 = '上下文里没有可接收外部输入的入口点，注入类风险不成立';
  }
  if (reasons.A04.startsWith('（本类')) {
    reasons.A04 = '上下文里没有普通业务角色，不存在跨角色的流程编排，不安全设计类风险不成立';
  }
  if (reasons.A05.startsWith('（本类')) {
    reasons.A05 = '上下文里没有接口类入口点，错误响应与默认配置类风险不在本服务的攻击面内';
  }
  return reasons;
}

/**
 * 四类实战补充的「不适用」理由。
 * @param {string} key 补充类键
 * @param {object} ctx 归一化后的上下文
 * @returns {string} 理由（非空）
 */
function supplementReason(key, ctx) {
  switch (key) {
    case 'file_upload':
      return '已检查 entry_points 的名称与说明，未命中上传 / multipart / 附件类输入面，本服务不接收用户上传的文件';
    case 'ssrf':
      return '已检查 entry_points 的名称与说明，未命中 URL / 回调 / webhook 类输入面，本服务不由外部输入触发服务端出站请求';
    case 'xxe':
      return '已检查 entry_points 的名称与说明，未命中 XML 解析类输入面，扫描结果里也没有 XML 相关发现，本服务不处理外部 XML';
    case 'deserialization':
      return '已检查 entry_points 的名称与说明，未命中反序列化类输入面，本服务不对外部数据做反序列化处理';
    default:
      return `未识别补充类「${key}」，按不适用处理`;
  }
}
