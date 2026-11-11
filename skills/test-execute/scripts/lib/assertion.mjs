// assertion.mjs — 断言对象（steps[].expected 的结构化形态）的解析与求值
//
// 断言对象结构（REQ-002.5b 决定）：
//   { "path": "$.data.orderId", "op": "equals", "expected": "A-1" }
//
// 路径语义：
//   $status          → HTTP 状态码
//   $header.X-Trace-Id → 响应头
//   $.a.b[0].c       → 响应体（JSONPath 风格）
//   $                → 整个响应体
//
// 本模块只做"取值与比较"。**不产出 status** —— status 的判定集中在 lib/verdict.mjs，
// 执行器（executors/*.mjs）也不得出现通过/失败判定分支。
//
// 纯 Node.js，只依赖 node: 内置模块。

/** 判定操作枚举 */
export const ASSERT_OPS = Object.freeze([
  'equals',
  'not_equals',
  'contains',
  'not_contains',
  'matches',
  'exists',
  'not_exists',
  'type',
  'gt',
  'gte',
  'lt',
  'lte',
]);

/** type 操作可用的类型名 */
export const ASSERT_TYPES = Object.freeze([
  'string',
  'number',
  'boolean',
  'object',
  'array',
  'null',
]);

/** 断言对象允许出现的字段（封闭集合） */
export const ASSERT_FIELDS = Object.freeze(['path', 'op', 'expected']);

/** 不需要 expected 的操作 */
const OPS_WITHOUT_EXPECTED = Object.freeze(['exists', 'not_exists']);

/**
 * 是否是普通对象。
 * @param {any} value 待判定值
 * @returns {boolean}
 */
export function isObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * 是否是非空字符串。
 * @param {any} value 待判定值
 * @returns {boolean}
 */
export function isFilledString(value) {
  return typeof value === 'string' && value.trim() !== '';
}

/**
 * 是否是断言对象形态（非空对象）。
 * @param {any} value 待判定值
 * @returns {boolean}
 */
export function isAssertionObject(value) {
  return isObject(value) && Object.keys(value).length > 0;
}

/**
 * 校验断言对象的合法性。
 *
 * @param {any} value 待校验值
 * @returns {string[]} 问题清单；空数组表示合法
 */
export function validateAssertionObject(value) {
  const problems = [];
  if (!isObject(value)) {
    problems.push('断言对象必须是 JSON 对象');
    return problems;
  }
  for (const key of Object.keys(value)) {
    if (!ASSERT_FIELDS.includes(key)) {
      problems.push(
        `断言对象出现未知字段 "${key}"（允许字段: ${ASSERT_FIELDS.join(' / ')}）`,
      );
    }
  }
  if (!isFilledString(value.path)) {
    problems.push('断言对象缺少必填字段 path（被检路径，如 "$.data.orderId" / "$status"）');
  } else if (!value.path.startsWith('$')) {
    problems.push(
      `断言对象的 path "${value.path}" 非法：必须以 "$" 开头` +
        '（"$.a.b" 取响应体字段，"$status" 取 HTTP 状态码，"$header.X-Key" 取响应头）',
    );
  }
  if (!isFilledString(value.op)) {
    problems.push(`断言对象缺少必填字段 op（允许值: ${ASSERT_OPS.join(' / ')}）`);
  } else if (!ASSERT_OPS.includes(value.op)) {
    problems.push(`断言对象的 op 取值非法: "${value.op}"，允许值: ${ASSERT_OPS.join(' / ')}`);
  }
  const op = value.op;
  if (isFilledString(op) && ASSERT_OPS.includes(op)) {
    if (OPS_WITHOUT_EXPECTED.includes(op)) {
      if (value.expected !== undefined) {
        problems.push(`断言对象的 op "${op}" 不接受 expected 字段（该操作只判断存在性）`);
      }
    } else if (value.expected === undefined) {
      problems.push(`断言对象的 op "${op}" 缺少必填字段 expected（比较值）`);
    } else if (op === 'type') {
      if (!ASSERT_TYPES.includes(value.expected)) {
        problems.push(
          `断言对象的 expected 取值非法: "${value.expected}"` +
            `（op 为 type 时只接受类型名: ${ASSERT_TYPES.join(' / ')}）`,
        );
      }
    } else if (op === 'matches') {
      if (!isFilledString(value.expected)) {
        problems.push('断言对象的 expected 必须是非空字符串（op 为 matches 时是正则）');
      } else {
        try {
          new RegExp(value.expected);
        } catch (err) {
          problems.push(`断言对象的 expected 不是合法正则: ${err.message}`);
        }
      }
    }
  }
  return problems;
}

/**
 * 解析路径。
 *
 * @param {string} path 路径串
 * @returns {{kind: string, segments: any[], name: string|null}}
 */
export function parsePath(path) {
  if (typeof path !== 'string' || path === '') {
    return { kind: 'body', segments: [], name: null };
  }
  if (path === '$status') return { kind: 'status', segments: [], name: null };
  if (path.startsWith('$header.')) {
    return { kind: 'header', segments: [], name: path.slice('$header.'.length) };
  }
  const rest = path.startsWith('$.') ? path.slice(2) : path.startsWith('$') ? path.slice(1) : path;
  if (rest === '') return { kind: 'body', segments: [], name: null };
  const segments = [];
  for (const rawSegment of rest.split('.')) {
    const match = /^([^[\]]*)((?:\[\d+\])*)$/.exec(rawSegment);
    if (!match) return { kind: 'body', segments: [rawSegment], name: null };
    const name = match[1];
    if (name !== '') segments.push(name);
    const indexes = match[2] || '';
    const indexPattern = /\[(\d+)\]/g;
    let found = indexPattern.exec(indexes);
    while (found !== null) {
      segments.push(Number(found[1]));
      found = indexPattern.exec(indexes);
    }
  }
  return { kind: 'body', segments, name: null };
}

/**
 * 按路径从 observed 取值。
 *
 * @param {string} path 路径串
 * @param {object} observed 执行器报告的观察结果
 * @returns {{found: boolean, value: any}}
 */
export function resolvePath(path, observed) {
  const parsed = parsePath(path);
  if (parsed.kind === 'status') {
    return { found: observed && observed.status_code !== undefined, value: observed ? observed.status_code : undefined };
  }
  if (parsed.kind === 'header') {
    const headers = observed && isObject(observed.headers) ? observed.headers : {};
    const key = String(parsed.name || '').toLowerCase();
    const hit = Object.keys(headers).find((item) => item.toLowerCase() === key);
    return { found: hit !== undefined, value: hit === undefined ? undefined : headers[hit] };
  }
  let current = observed ? observed.body : undefined;
  for (const segment of parsed.segments) {
    if (current === null || current === undefined) return { found: false, value: undefined };
    if (typeof segment === 'number') {
      if (!Array.isArray(current)) return { found: false, value: undefined };
      current = current[segment];
    } else {
      if (typeof current !== 'object' || Array.isArray(current)) return { found: false, value: undefined };
      if (!Object.prototype.hasOwnProperty.call(current, segment)) {
        return { found: false, value: undefined };
      }
      current = current[segment];
    }
  }
  return { found: current !== undefined, value: current };
}

/**
 * 深比较（数值按数值比，字符串按字符串比，数组与对象逐层比）。
 * @param {any} left 左值
 * @param {any} right 右值
 * @returns {boolean}
 */
export function deepEqual(left, right) {
  if (left === right) return true;
  if (typeof left === 'number' && typeof right === 'number') return left === right;
  if (typeof left !== typeof right) return false;
  if (Array.isArray(left) && Array.isArray(right)) {
    if (left.length !== right.length) return false;
    return left.every((item, index) => deepEqual(item, right[index]));
  }
  if (isObject(left) && isObject(right)) {
    const leftKeys = Object.keys(left);
    const rightKeys = Object.keys(right);
    if (leftKeys.length !== rightKeys.length) return false;
    return leftKeys.every(
      (key) => Object.prototype.hasOwnProperty.call(right, key) && deepEqual(left[key], right[key]),
    );
  }
  return false;
}

/**
 * 值的类型名（与 ASSERT_TYPES 对齐）。
 * @param {any} value 待判定值
 * @returns {string}
 */
export function typeName(value) {
  if (value === null) return 'null';
  if (Array.isArray(value)) return 'array';
  return typeof value;
}

/**
 * contains 语义：字符串 → 子串；数组 → 元素命中；对象 → 键命中或序列化后包含。
 * @param {any} actual 实际值
 * @param {any} expected 期望值
 * @returns {boolean}
 */
function containsValue(actual, expected) {
  if (typeof actual === 'string') return actual.includes(String(expected));
  if (Array.isArray(actual)) return actual.some((item) => deepEqual(item, expected));
  if (isObject(actual)) {
    if (typeof expected === 'string' && Object.prototype.hasOwnProperty.call(actual, expected)) {
      return true;
    }
    return JSON.stringify(actual).includes(String(expected));
  }
  return String(actual) === String(expected);
}

/**
 * 数值比较辅助：非数值返回 null。
 * @param {any} value 待判定值
 * @returns {number|null}
 */
function numeric(value) {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string' && value.trim() !== '' && Number.isFinite(Number(value))) {
    return Number(value);
  }
  return null;
}

/**
 * 从用例里收集结构化断言。
 *
 * 载体：steps[].expected 为断言对象时算一条断言；为普通字符串时不算。
 *
 * @param {object} caseObj 用例对象
 * @returns {{assertion: object, stepIndex: number, action: string}[]}
 */
export function collectAssertions(caseObj) {
  const found = [];
  if (!isObject(caseObj)) return found;
  const steps = Array.isArray(caseObj.steps) ? caseObj.steps : [];
  steps.forEach((step, stepIndex) => {
    if (!isObject(step)) return;
    if (!isAssertionObject(step.expected)) return;
    found.push({
      assertion: step.expected,
      stepIndex,
      action: typeof step.action === 'string' ? step.action : '',
    });
  });
  return found;
}

/**
 * 执行单条断言。
 *
 * @param {object} assertion 断言对象
 * @param {object} observed 观察结果
 * @returns {{ok: boolean, actual: any, found: boolean, message: string}}
 */
export function compareAssertion(assertion, observed) {
  const { found, value } = resolvePath(assertion.path, observed);
  const expected = assertion.expected;
  const actualText = found ? JSON.stringify(value) : '（路径不存在）';
  const expectText = expected === undefined ? '（无）' : JSON.stringify(expected);
  const fail = (reason) => ({
    ok: false,
    actual: value,
    found,
    message: `${assertion.path} ${assertion.op} ${expectText} 不成立（实际 ${actualText}）：${reason}`,
  });
  const pass = () => ({ ok: true, actual: value, found, message: `${assertion.path} ${assertion.op} ${expectText} 成立` });

  switch (assertion.op) {
    case 'equals':
      return found && deepEqual(value, expected) ? pass() : fail('值不相等');
    case 'not_equals':
      return !found || !deepEqual(value, expected) ? pass() : fail('值相等');
    case 'contains':
      return found && containsValue(value, expected) ? pass() : fail('不包含期望内容');
    case 'not_contains':
      return !found || !containsValue(value, expected) ? pass() : fail('包含期望内容');
    case 'matches':
      if (!found) return fail('路径不存在');
      return new RegExp(String(expected)).test(String(value)) ? pass() : fail('不匹配正则');
    case 'exists':
      return found ? pass() : fail('路径不存在');
    case 'not_exists':
      return !found ? pass() : fail('路径存在');
    case 'type':
      if (!found) return fail('路径不存在');
      return typeName(value) === expected ? pass() : fail(`类型不是 ${expected}`);
    case 'gt':
    case 'gte':
    case 'lt':
    case 'lte': {
      if (!found) return fail('路径不存在');
      const left = numeric(value);
      const right = numeric(expected);
      if (left === null || right === null) return fail('比较的两侧不是数值');
      const ok =
        assertion.op === 'gt'
          ? left > right
          : assertion.op === 'gte'
            ? left >= right
            : assertion.op === 'lt'
              ? left < right
              : left <= right;
      return ok ? pass() : fail('数值关系不成立');
    }
    default:
      return fail(`未知 op "${assertion.op}"`);
  }
}
