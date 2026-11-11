// redaction.mjs — 执行产物的脱敏规则与实现
//
// 脱敏发生在**写入产物之前**：产物里存的应当已经是脱敏后的内容。
// 规则分两类：
//   1) 敏感字段名清单（对象键命中即整值替换）
//   2) 值模式正则（字符串内容命中即替换）
// 另外还有"凭证字面量"通道：执行时解析出的凭证值按字面量整体替换，
// 保证凭证值在任何产物、日志、错误信息里都不出现。
//
// 脱敏必须留痕：调用方把 rules_applied 与 redacted_fields 写进 meta.json，
// 让人知道"这里被处理过"，而不是让人以为原文如此。
//
// 纯 Node.js，只依赖 node: 内置模块。

import { readFileSync } from 'node:fs';

/** 默认敏感字段名（键名归一化后做包含匹配） */
export const DEFAULT_FIELD_NAMES = Object.freeze([
  'password',
  'passwd',
  'pwd',
  'secret',
  'token',
  'accesstoken',
  'refreshtoken',
  'apikey',
  'authorization',
  'cookie',
  'sessionid',
  'privatekey',
  'idcard',
  'creditcard',
  'bankcard',
  'credential',
  'credentials',
  'phone',
  'mobile',
  'tel',
  'ssn',
]);

/** 默认值模式（正则字符串，落地时以 g 标志编译） */
export const DEFAULT_PATTERNS = Object.freeze([
  { name: 'jwt', regex: '\\beyJ[A-Za-z0-9_-]{4,}\\.[A-Za-z0-9_-]{4,}\\.[A-Za-z0-9_-]{4,}\\b' },
  { name: 'bearer_token', regex: '\\b[Bb]earer\\s+[A-Za-z0-9._~+/=-]{8,}' },
  { name: 'connection_string', regex: '([a-zA-Z][a-zA-Z0-9+.-]*://)[^\\s:@/]+:[^\\s@/]+@' },
  { name: 'id_card', regex: '\\b\\d{17}[\\dXx]\\b' },
  { name: 'phone_number', regex: '\\b1[3-9]\\d{9}\\b' },
  { name: 'credit_card', regex: '\\b(?:\\d{4}[ -]){3}\\d{1,4}\\b|\\b\\d{13,19}\\b' },
]);

/** 不参与脱敏的键名（指纹类字段必须保持原样，否则证据链自校验必然失败） */
export const PROTECTED_KEYS = Object.freeze([
  'sha256',
  'evidence_manifest_sha256',
  'results_sha256',
  'bytes',
  'media_type',
  'run_id',
  'duration_ms',
]);

/** 凭证字面量的最小长度（过短的值会误伤普通文本） */
const MIN_SECRET_LENGTH = 4;

/**
 * 键名归一化：去掉分隔符并转小写。
 * @param {string} key 键名
 * @returns {string}
 */
export function normalizeKey(key) {
  return String(key).toLowerCase().replace(/[^a-z0-9]/g, '');
}

/**
 * 是否是敏感字段名。
 * @param {string} key 键名
 * @param {string[]} fieldNames 敏感字段名清单
 * @returns {boolean}
 */
export function isSensitiveKey(key, fieldNames) {
  const normalized = normalizeKey(key);
  if (normalized === '') return false;
  return fieldNames.some((name) => normalized.includes(normalizeKey(name)));
}

/**
 * 合并规则文件与内置规则。
 *
 * @param {object|null} fileRules 规则文件内容（{fields:[], patterns:[{name,regex}]}）
 * @returns {{fields: string[], patterns: {name: string, regex: string}[]}}
 */
export function mergeRules(fileRules) {
  const fields = [...DEFAULT_FIELD_NAMES];
  const patterns = DEFAULT_PATTERNS.map((item) => ({ ...item }));
  if (fileRules && typeof fileRules === 'object') {
    if (Array.isArray(fileRules.fields)) {
      for (const item of fileRules.fields) {
        if (typeof item === 'string' && item.trim() !== '') fields.push(item.trim());
      }
    }
    if (Array.isArray(fileRules.patterns)) {
      for (const item of fileRules.patterns) {
        if (!item || typeof item.name !== 'string' || typeof item.regex !== 'string') continue;
        patterns.push({ name: item.name, regex: item.regex });
      }
    }
  }
  return { fields, patterns };
}

/**
 * 创建脱敏器。
 *
 * @param {object} options 选项
 * @param {object|null} options.rules 规则文件内容
 * @param {string[]} options.secrets 需要整体替换的字面量（凭证值等）
 * @returns {{redactText: (text: string) => string, redactJson: (value: any) => any, stats: {redactedFields: number, rulesApplied: string[]}}}
 */
export function createRedactor(options = {}) {
  const rules = mergeRules(options.rules || null);
  const compiled = rules.patterns.map((item) => ({
    name: item.name,
    pattern: new RegExp(item.regex, 'g'),
  }));
  const secrets = (Array.isArray(options.secrets) ? options.secrets : [])
    .filter((item) => typeof item === 'string' && item.length >= MIN_SECRET_LENGTH)
    .sort((a, b) => b.length - a.length);
  const stats = { redactedFields: 0, rulesApplied: [] };
  const applied = new Set();

  /**
   * 记录一条规则被启用。
   * @param {string} name 规则名
   */
  function mark(name) {
    if (!applied.has(name)) applied.add(name);
    stats.redactedFields += 1;
  }

  /**
   * 文本脱敏。
   * @param {string} text 文本
   * @returns {string}
   */
  function redactText(text) {
    if (typeof text !== 'string' || text === '') return text;
    let out = text;
    for (const secret of secrets) {
      if (!out.includes(secret)) continue;
      out = out.split(secret).join('[REDACTED:credential]');
      mark('credential');
    }
    for (const item of compiled) {
      item.pattern.lastIndex = 0;
      if (!item.pattern.test(out)) continue;
      item.pattern.lastIndex = 0;
      out = out.replace(item.pattern, `[REDACTED:${item.name}]`);
      mark(item.name);
    }
    return out;
  }

  /**
   * 结构化脱敏（对象 / 数组 / 字符串）。
   * @param {any} value 待脱敏值
   * @returns {any}
   */
  function redactJson(value) {
    if (typeof value === 'string') return redactText(value);
    if (Array.isArray(value)) return value.map((item) => redactJson(item));
    if (value && typeof value === 'object') {
      const out = {};
      for (const [key, item] of Object.entries(value)) {
        if (PROTECTED_KEYS.includes(key)) {
          out[key] = item;
          continue;
        }
        if (isSensitiveKey(key, rules.fields)) {
          out[key] = '[REDACTED:field]';
          mark('field');
          continue;
        }
        out[key] = redactJson(item);
      }
      return out;
    }
    return value;
  }

  return {
    redactText,
    redactJson,
    stats: {
      get redactedFields() {
        return stats.redactedFields;
      },
      get rulesApplied() {
        return [...applied];
      },
    },
  };
}

/**
 * 读取规则文件。
 * @param {string} file 规则文件路径
 * @returns {object} 规则内容
 */
export function loadRulesFile(file) {
  const raw = readFileSync(file, 'utf8');
  return JSON.parse(raw);
}
