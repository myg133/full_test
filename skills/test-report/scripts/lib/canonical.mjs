// canonical.mjs —— 规范化序列化与报告自身指纹
//
// 口径见 demand.md F3.2：
//   1. 对象：键名按**码位升序**排序后拼接（无空白）；
//   2. 数组：**保持原顺序**；
//   3. 字符串用 JSON 转义形式；数字 / 布尔 / null 用 JSON 字面量形式；
//   4. 结果按 UTF-8 取 sha256 十六进制。
//
// 指纹的**自指问题**：`report_sha256` 不能把自己算进去 —— 计算前先剔除
// `generated_at` 与 `report_sha256` 两个字段。

import { sha256Hex } from './fingerprint.mjs';

/** 计算报告指纹时必须剔除的字段（`generated_at` 是幂等自验唯一允许变动的字段）。 */
export const EXCLUDED_FROM_DIGEST = ['generated_at', 'report_sha256'];

/**
 * 规范化序列化（对象键按码位升序，数组保序，无空白）。
 * @param {*} value 待序列化的值
 * @returns {string} 规范化字符串
 */
export function stableStringify(value) {
  if (value === null) return 'null';
  if (Array.isArray(value)) return `[${value.map((item) => stableStringify(item)).join(',')}]`;
  if (typeof value === 'object') {
    const keys = Object.keys(value).sort();
    const parts = keys.map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`);
    return `{${parts.join(',')}}`;
  }
  return JSON.stringify(value);
}

/**
 * 取报告参与指纹计算的载荷（剔除 `generated_at` 与 `report_sha256`）。
 * @param {object} report 报告对象
 * @returns {object} 载荷副本
 */
export function digestPayload(report) {
  const clone = { ...report };
  for (const key of EXCLUDED_FROM_DIGEST) delete clone[key];
  return clone;
}

/**
 * 按 F3.2 口径计算报告自身指纹。
 * @param {object} report 报告对象
 * @returns {string} 64 位十六进制指纹
 */
export function computeReportSha256(report) {
  return sha256Hex(stableStringify(digestPayload(report)));
}

/**
 * 按摘要行的书写口径把一个值转成字符串（数组用逗号连接，顺序敏感）。
 * @param {*} value 报告里的值
 * @returns {string} 摘要行里的字面值
 */
export function digestValue(value) {
  if (Array.isArray(value)) return value.map((item) => (typeof item === 'string' ? item : JSON.stringify(item))).join(',');
  if (value === null) return 'null';
  if (typeof value === 'object') return JSON.stringify(value);
  return String(value);
}

/**
 * 按点号路径从报告里取值。
 * @param {object} root 报告对象
 * @param {string} dotted 点号路径（如 `cases.total`）
 * @returns {*} 取到的值（找不到返回 undefined）
 */
export function getByPath(root, dotted) {
  let current = root;
  for (const part of String(dotted).split('.')) {
    if (current === null || typeof current !== 'object') return undefined;
    current = current[part];
  }
  return current;
}
