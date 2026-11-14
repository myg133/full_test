// scan.mjs —— 依赖扫描结果的解析（契约 F7 / D113 / D114）
//
// 三种合法形态：
//   ① bandit 结果：根是对象且 results 是数组      ⇒ tool = "bandit"
//   ② npm audit 结果：根是对象且 vulnerabilities 是对象 ⇒ tool = "npm-audit"
//   ③ 扫描状态：根是对象且 status ∈ {unavailable, failed} ⇒ reason 必填非空、finding 数 0
//
// 三者都识别不出来 ⇒ **输入非法** ⇒ 退出码 1。
//
// ⚠️ 本 skill **自己一个扫描器都不跑**（零第三方依赖、不联网）：
//    扫描由 agent 用已交付的 qa-toolchain（bin/qa）跑完 bandit / npm audit 后，
//    把结果**喂进来**（--scan）。

import { InputError, isFilledString, isObject } from './io.mjs';

/** 扫描器给出的严重度 → 产物用的四级严重度。 */
const SEVERITY_MAP = Object.freeze({
  CRITICAL: 'critical',
  HIGH: 'high',
  MEDIUM: 'medium',
  MODERATE: 'medium',
  LOW: 'low',
  INFO: 'low',
  UNDEFINED: 'medium',
  critical: 'critical',
  high: 'high',
  medium: 'medium',
  moderate: 'medium',
  low: 'low',
  info: 'low',
});

/**
 * 把扫描器的严重度映射到四级枚举。
 * @param {*} value 原始严重度
 * @returns {string} critical / high / medium / low
 */
export function mapSeverity(value) {
  const key = String(value || '').trim();
  return SEVERITY_MAP[key] || 'medium';
}

/**
 * 解析 --scan 输入。
 * @param {*} doc 解析后的 JSON
 * @param {string} file 来源文件
 * @returns {{kind: string, tool: string|null, status: string, reason: string, sourceFile: string, findings: object[]}}
 */
export function parseScan(doc, file) {
  if (!isObject(doc)) {
    throw new InputError(
      `扫描结果无法识别: ${file}（根节点必须是 JSON 对象；三种合法形态分别是 bandit 结果 / npm audit 结果 / 扫描状态）`,
    );
  }

  // ① bandit
  if (Array.isArray(doc.results)) {
    const findings = doc.results.map((item, index) => {
      const at = `results[${index}]`;
      if (!isObject(item)) {
        throw new InputError(`扫描结果无法识别: ${file} 的 ${at} 必须是对象`);
      }
      const summary = isFilledString(item.issue_text)
        ? item.issue_text.trim()
        : (isFilledString(item.test_name) ? item.test_name.trim() : '');
      if (summary === '') {
        throw new InputError(`扫描结果无法识别: ${file} 的 ${at} 缺少 issue_text / test_name`);
      }
      const location = isFilledString(item.filename)
        ? `${item.filename}${item.line_number ? `:${item.line_number}` : ''}`
        : '';
      return {
        id: `SCAN-${index + 1}`,
        severity: mapSeverity(item.issue_severity),
        summary,
        detail: location,
        file: isFilledString(item.filename) ? item.filename : '',
        testId: isFilledString(item.test_id) ? item.test_id : '',
        sourceLabel: `bandit ${isFilledString(item.test_id) ? item.test_id : ''}`.trim(),
      };
    });
    return {
      kind: 'bandit',
      tool: 'bandit',
      status: 'provided',
      reason: '',
      sourceFile: file,
      findings,
    };
  }

  // ② npm audit
  if (isObject(doc.vulnerabilities)) {
    const names = Object.keys(doc.vulnerabilities);
    const findings = names.map((name, index) => {
      const at = `vulnerabilities["${name}"]`;
      const item = doc.vulnerabilities[name];
      if (!isObject(item)) {
        throw new InputError(`扫描结果无法识别: ${file} 的 ${at} 必须是对象`);
      }
      const via = Array.isArray(item.via) ? item.via.filter(isObject) : [];
      const first = via.length > 0 ? via[0] : {};
      const title = isFilledString(first.title) ? first.title.trim() : `${name} 存在已知漏洞`;
      const range = isFilledString(item.range) ? `（受影响版本 ${item.range}）` : '';
      return {
        id: `SCAN-${index + 1}`,
        severity: mapSeverity(item.severity),
        summary: `${title}${range}`,
        detail: name,
        file: name,
        testId: '',
        sourceLabel: `npm audit ${name}`,
      };
    });
    return {
      kind: 'npm-audit',
      tool: 'npm-audit',
      status: 'provided',
      reason: '',
      sourceFile: file,
      findings,
    };
  }

  // ③ 扫描状态（工具装不上 / 跑失败）
  if (doc.status === 'unavailable' || doc.status === 'failed') {
    if (!isFilledString(doc.reason)) {
      throw new InputError(
        `扫描状态缺少必填字段 reason（status=${doc.status} 时必须写清为什么没扫成）: ${file}`,
      );
    }
    return {
      kind: 'status',
      tool: isFilledString(doc.tool) ? doc.tool.trim() : null,
      status: doc.status,
      reason: doc.reason.trim(),
      sourceFile: file,
      findings: [],
    };
  }

  throw new InputError(
    `扫描结果无法识别: ${file}` +
      '（三种合法形态：根含 results 数组 = bandit 结果；根含 vulnerabilities 对象 = npm audit 结果；' +
      '根含 status ∈ {unavailable, failed} = 扫描状态）',
  );
}

/**
 * 没传 --scan 时的空扫描摘要（**显式声明**，不静默跳过）。
 * @returns {{kind: string, tool: string|null, status: string, reason: string, sourceFile: string, findings: object[]}}
 */
export function noScan() {
  return {
    kind: 'none',
    tool: null,
    status: 'not_provided',
    reason: '',
    sourceFile: '',
    findings: [],
  };
}
