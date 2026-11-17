// redaction.mjs —— 报告内一律脱敏（REQ-014 demand.md §F3）
//
// ⚠️ D218：本模块**自包含**实现，**不** import 其它 skill 的代码
//    （本仓没有跨 skill import 的先例；相对 import 只许指向本 skill 内 —— REQ-010 AC-026）。
//
// 三类规则（与 demand.md F3 的 R1 / R2 / R3 一一对应）：
//   R1 敏感**字段名**  ⇒ 整值替换为 `[REDACTED:field]`
//   R2 敏感**值模式**  ⇒ 替换为 `[REDACTED:secret]`
//   R3 **绝对路径**    ⇒ 换成相对项目根的路径
//
// 另有**豁免名单**（D219）：追踪 / 业务标识键（`trace_id` / `x-trace-id` / `request_id` /
// `x-request-id` / `span_id` / `correlation_id` / `id` / `uuid`）下的值**原样保留**，
// 不参与任何脱敏规则 —— 「长得像 hash」不是可靠的凭证信号，业务标识与 token 同形。
//
// 还有**已知指纹豁免**（D221）：本报告涉及的指纹值（产物里**声明**的 + 报告**重算**的）
// 即便命中长 hex 形态也**原样保留、不计数** —— 它们确定不是凭证，
// 却会以「值」的形态嵌在 findings 的**自由文本**里（键级豁免对自由文本无效）。
// ⚠️ 只对「长 hex」这一条规则开口子：内嵌 JSON 口令 / Bearer / URL userinfo 仍按真凭证处理。
//
// R1 / R2 的分工（F3.1 / AC-016）：
//   - 敏感字段名**只在对象键上**判 ⇒ `must_change_password` 的值被换掉；
//   - 裸词**不认** ⇒ `page.secrets.view`（业务权限点）、`DEMO_TEST_TOKEN`（环境变量引用）逐字保留；
//   - 值模式只认「凭证形态」⇒ 内嵌 JSON 口令 / `Bearer <token>` / `user:pass@host` / 长十六进制串。
//   ⇒ 内嵌 JSON 里的口令（藏在命令行字符串中，不是独立字段）**只能**被 R2 抓住。
//
// 计数（D216 / F3.3）：
//   redacted_fields = R1 命中的替换次数
//   redacted_values = R2 + R3 命中的替换次数
//   **如实**计数：产物里没有敏感内容时就是 0（不虚报），有就如实报；
//   ⚠️ **只在值真的变了时才计数** —— 把「已经是占位符的值」再替换成同样的占位符不算一次替换。

/** 敏感字段名的「完整键名」匹配（大小写与分隔符不敏感；前缀必须以分隔符收尾）。 */
const SENSITIVE_KEY = new RegExp(
  '^(?:.*[-_.])?(?:'
  + [
    'password',
    'passwd',
    'pwd',
    'token',
    'secret',
    'api[_-]?key',
    'apikey',
    'access[_-]?key',
    'secret[_-]?key',
    'private[_-]?key',
    'authorization',
    'cookie',
    'credential',
    'credentials',
    'session(?:[_-]?id)?',
  ].join('|')
  + ')$',
  'i',
);

/** 敏感字段名的「归一化全等」名单（补齐 camelCase 形态，如 `accessToken`）。 */
const SENSITIVE_NORMALIZED = new Set([
  'password', 'passwd', 'pwd', 'token', 'secret', 'apikey', 'accesskey',
  'secretkey', 'privatekey', 'authorization', 'cookie', 'credential',
  'credentials', 'session', 'sessionid', 'accesstoken', 'refreshtoken',
  'clientsecret',
]);

/** R2① 内嵌 JSON 形态的敏感键值（`"password":"xxx"`）—— `reproduction.command` 的真漏洞。 */
const INLINE_JSON = new RegExp(
  '("(?:'
  + [
    'password',
    'passwd',
    'pwd',
    'token',
    'secret',
    'api[_-]?key',
    'apikey',
    'access[_-]?key',
    'secret[_-]?key',
    'private[_-]?key',
    'authorization',
    'cookie',
    'credential',
    'credentials',
    'session(?:[_-]?id)?',
  ].join('|')
  + ')"\\s*:\\s*")((?:[^"\\\\]|\\\\.)*)(")',
  'gi',
);

/** R2② `Bearer <token>`。 */
const BEARER = /\bBearer\s+[A-Za-z0-9._~+/=-]{16,}/g;

/** R2③ URL 里的 `user:pass@host`。 */
const URL_USERINFO = /([a-zA-Z0-9._%+-]+):([^@\s/"']+)@/g;

/** R2④ 独立的长十六进制串（≥32 位，疑似凭证）。 */
const LONG_HEX = /(?<![0-9a-fA-F])[0-9a-fA-F]{32,}(?![0-9a-fA-F])/g;

/** 字段名里含 `sha256` 的键：值是**指纹**，按 demand.md §0.4 的口径豁免，不得当成凭证抹掉。 */
const FINGERPRINT_KEY = /sha256/i;

/**
 * 追踪 / 业务标识**豁免名单**（D219）：这些键下的值**原样保留**，不参与任何脱敏规则。
 *
 * ⚠️ 理由（真实数据实测，用户 YF-test 的 58 份证据）：32 位 hex 出现的键**全部**是业务标识
 *    （`x-trace-id` 58 / `trace_id` 27 / `items[].id` 16 / `id` 4），**没有一条是真凭证**；
 *    抹掉 `trace_id` 会让报告失去查后端日志的能力。
 * ⚠️ 豁免**按键名**判定 ⇒ 证据内容必须**结构化**遍历（解析 JSON 后按键判断），
 *    不是纯文本正则 —— 否则就会变成「一律放过长 hex」。
 */
const EXEMPT_KEY = /^(?:trace[_-]?id|x-trace-id|request[_-]?id|x-request-id|span[_-]?id|correlation[_-]?id|id|uuid)$/i;

/** 实际启用的规则名（`redaction.rules_applied` 逐条点名 —— D216：规则是装着的，不是本次命中的）。 */
export const RULES_APPLIED = [
  'field-name:sensitive-key',
  'secret-pattern:inline-json',
  'secret-pattern:bearer',
  'secret-pattern:url-userinfo',
  'secret-pattern:long-hex',
  'path:absolute-to-project-relative',
  'exempt-key:trace-and-business-id',
  'exempt-value:known-fingerprint',
];

/** 敏感字段名的整值替换占位符。 */
export const REDACTED_FIELD = '[REDACTED:field]';

/** 敏感值模式的替换占位符。 */
export const REDACTED_SECRET = '[REDACTED:secret]';

/**
 * 判定一个键名是否命中敏感字段名名单。
 * @param {string} key 键名
 * @returns {boolean} 是否敏感
 */
export function isSensitiveKey(key) {
  if (typeof key !== 'string' || key === '') return false;
  if (SENSITIVE_KEY.test(key)) return true;
  const normalized = key.toLowerCase().replace(/[-_.\s]/g, '');
  return SENSITIVE_NORMALIZED.has(normalized);
}

/**
 * 判定一个键名是否命中追踪 / 业务标识**豁免名单**（D219）。
 * @param {string} key 键名
 * @returns {boolean} 是否豁免
 */
export function isExemptKey(key) {
  if (typeof key !== 'string' || key === '') return false;
  return EXEMPT_KEY.test(key);
}

/**
 * 建一个脱敏器（计数是**全局**的：证据内容与报告正文共用同一份计数）。
 *
 * @param {{projectRoot?: string|null, fingerprints?: string[]|Set<string>}} [options] 选项
 *   - `projectRoot`：R3 用（绝对路径 → 相对项目根）；
 *   - `fingerprints`：**已知指纹**（D221）—— 本报告涉及的全部指纹值，
 *     它们即便命中长 hex 形态也**原样保留、不计数**（它们确定不是凭证）。
 * @returns {object} 脱敏器
 */
export function createRedactor(options = {}) {
  const projectRoot = typeof options.projectRoot === 'string' && options.projectRoot !== ''
    ? options.projectRoot
    : null;
  const stats = { fields: 0, values: 0 };
  /** 已知指纹集合（D221）：值层面的豁免 —— 只对「长 hex」这一条规则开口子。 */
  const knownFingerprints = new Set();

  /**
   * 追加已知指纹（D221）。
   * @param {string[]|Set<string>|string} values 指纹值（可批量追加）
   * @returns {number} 追加后的指纹条数
   */
  function addFingerprints(values) {
    const list = values instanceof Set
      ? Array.from(values)
      : Array.isArray(values) ? values : [values];
    for (const value of list) {
      if (typeof value === 'string' && value !== '') knownFingerprints.add(value);
    }
    return knownFingerprints.size;
  }

  addFingerprints(options.fingerprints);

  /**
   * R3：把落在项目根下的绝对路径换成相对项目根的路径。
   * @param {string} text 文本
   * @returns {string} 处理后的文本
   */
  function redactProjectPaths(text) {
    if (!projectRoot || projectRoot === '/') return text;
    const prefix = projectRoot.endsWith('/') ? projectRoot : `${projectRoot}/`;
    if (!text.includes(prefix)) return text;
    let out = text;
    let index = out.indexOf(prefix);
    while (index >= 0) {
      out = `${out.slice(0, index)}${out.slice(index + prefix.length)}`;
      stats.values += 1;
      index = out.indexOf(prefix, index);
    }
    return out;
  }

  /**
   * R2：对一段自由文本做值模式脱敏。
   *
   * ⚠️ **只在值真的变了时才计数**（D219 补充要求）：把「已经是占位符的值」再替换成同样的
   *    占位符**不算**一次替换（否则产物侧已脱敏过的内容会被虚报成「这里脱敏过」）。
   * @param {string} text 文本
   * @returns {string} 脱敏后的文本
   */
  function redactText(text) {
    if (typeof text !== 'string' || text === '') return text;
    let out = text;
    out = out.replace(INLINE_JSON, (_match, head, value, tail) => {
      if (value === REDACTED_SECRET) return _match;
      stats.values += 1;
      return `${head}${REDACTED_SECRET}${tail}`;
    });
    out = out.replace(BEARER, () => {
      stats.values += 1;
      return `Bearer ${REDACTED_SECRET}`;
    });
    // ⚠️ userinfo 整体替换（**含 '@'**）：留着 '@' 会留下「user:xxx@host」这种凭证形态的残渣
    //    （验收判据 AC-014 全文扫 `user:pass@` 形态）。
    out = out.replace(URL_USERINFO, () => {
      stats.values += 1;
      return REDACTED_SECRET;
    });
    out = out.replace(LONG_HEX, (matched) => {
      // ⚠️ D221：**已知指纹**（本报告自己算出来的、或产物里声明的指纹）确定不是凭证
      //    ⇒ 原样保留、**不计数**（没替换过就不能算一次替换）。
      //    ⚠️ 只对「长 hex」这一条规则开口子 —— 内嵌 JSON 口令 / Bearer / URL userinfo
      //    仍按真凭证处理（真凭证优先）。
      if (knownFingerprints.has(matched)) return matched;
      stats.values += 1;
      return REDACTED_SECRET;
    });
    return redactProjectPaths(out);
  }

  /**
   * R1 + R2：递归脱敏一个节点（对象 / 数组 / 字符串）。
   *
   * ⚠️ 豁免（D219）：**豁免键**下的值原样保留 —— 既不参与字段名规则，也不参与值模式规则。
   * @param {*} node 待处理节点
   * @param {{skipKeys?: Set<string>}} [opts] 选项（要**原样保留**的键名集合）
   * @returns {*} 脱敏后的节点
   */
  function redactNode(node, opts = {}) {
    const skipKeys = opts.skipKeys instanceof Set ? opts.skipKeys : new Set();
    if (Array.isArray(node)) return node.map((item) => redactNode(item, opts));
    if (node !== null && typeof node === 'object') {
      const out = {};
      for (const [key, value] of Object.entries(node)) {
        // 指纹字段豁免：sha256 / content_sha256 的值**不是**凭证。
        if (FINGERPRINT_KEY.test(key) || skipKeys.has(key)) {
          out[key] = value;
          continue;
        }
        // 追踪 / 业务标识豁免（D219）：值原样保留，不参与任何脱敏规则。
        if (isExemptKey(key)) {
          out[key] = value;
          continue;
        }
        if (isSensitiveKey(key)) {
          // ⚠️ 只有值**真的变了**才计数（产物侧已脱敏过的值不再算一次）。
          if (value !== REDACTED_FIELD) stats.fields += 1;
          out[key] = REDACTED_FIELD;
          continue;
        }
        out[key] = redactNode(value, opts);
      }
      return out;
    }
    if (typeof node === 'string') return redactText(node);
    return node;
  }

  /**
   * 脱敏一份证据文件的**原始文本**。
   *
   * ⚠️ D213：能解析成 JSON 就按「对象」脱敏；**若脱敏后与脱敏前等价，就保留原始文本逐字不动**
   *    （⇒ 无敏感内容的文件满足 `content_sha256 == sha256` 严格相等 —— AC-011）；
   *    只有真被替换了才重新序列化。
   * @param {string} rawText 原文件文本
   * @returns {string} 脱敏后的文本
   */
  function redactEvidenceText(rawText) {
    if (typeof rawText !== 'string' || rawText === '') return rawText;
    let parsed = null;
    try {
      parsed = JSON.parse(rawText);
    } catch {
      // 不是 JSON：按自由文本脱敏（没命中就逐字保留）。
      return redactText(rawText);
    }
    const before = JSON.stringify(parsed);
    const redacted = redactNode(parsed);
    if (JSON.stringify(redacted) === before) return rawText;
    return `${JSON.stringify(redacted, null, 2)}\n`;
  }

  return {
    redactText,
    redactNode,
    redactEvidenceText,
    addFingerprints,
    stats,
    rulesApplied: () => RULES_APPLIED.slice(),
  };
}

/**
 * 收集**产物里声明的指纹**（D221）。
 *
 * 来源：`meta.json` 的 `results_sha256` / `evidence_manifest_sha256`，
 * 以及 `results[]` 里各 `evidence[].sha256`。
 * ⚠️ 这些值会被报告的 findings 消息**逐字引用**（「meta.json 记 X，重算为 Y」）
 *    ⇒ 必须**早于任何一次脱敏**登记进已知指纹集合，否则会被长 hex 规则当凭证抹掉。
 * @param {object} meta meta.json
 * @param {object[]} results 结果数组
 * @returns {string[]} 声明的指纹值
 */
export function collectDeclaredFingerprints(meta, results) {
  const values = [];
  const add = (value) => {
    if (typeof value === 'string' && value !== '') values.push(value);
  };
  if (meta && typeof meta === 'object') {
    add(meta.results_sha256);
    add(meta.evidence_manifest_sha256);
  }
  const list = Array.isArray(results) ? results : [];
  for (const entry of list) {
    const evidence = entry && Array.isArray(entry.evidence) ? entry.evidence : [];
    for (const item of evidence) {
      if (item && typeof item === 'object') add(item.sha256);
    }
  }
  return values;
}
