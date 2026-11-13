// fingerprint.mjs —— 指纹算法（sha256）
//
// 口径严格照 REQ-004 的 `references/evidence-chain.md` §4：
//   证据条目行：`${path}\u0000${sha256}\n`
//   结果条目行：`${case_id}\u0000${status}\u0000${errorType}\u0000${errorMessage}\u0000${command}\u0000${steps.join(' | ')}\n`
//   results 指纹  = 各结果行（按 results.json 顺序）后再接各条结果的证据条目行
//   证据清单指纹 = 全部证据条目行按顺序连接
//
// ⚠️ 这里**自己实现**一份，不 import 其它 skill 的库：
//    报告 skill 与 test-execute 是两个独立的 skill（相对 import 只许指向本 skill 内），
//    两边的口径必须逐字一致 —— 口径漂了，报告绑定的指纹就绑错了产物。

import { createHash } from 'node:crypto';
import { readFileSync, statSync } from 'node:fs';

/**
 * 计算 sha256 十六进制摘要。
 * @param {string|Buffer} data 输入数据
 * @returns {string} 小写十六进制摘要
 */
export function sha256Hex(data) {
  return createHash('sha256').update(data).digest('hex');
}

/**
 * 计算文件的 sha256 与字节数。
 * @param {string} file 文件路径
 * @returns {{sha256: string, bytes: number}} 指纹
 */
export function fingerprintFile(file) {
  const buffer = readFileSync(file);
  return { sha256: sha256Hex(buffer), bytes: statSync(file).size };
}

/**
 * 规范化一条证据条目。
 * @param {object} entry 证据条目
 * @returns {string} 规范化行
 */
function evidenceLine(entry) {
  const path = entry && typeof entry.path === 'string' ? entry.path : '';
  const sha = entry && typeof entry.sha256 === 'string' ? entry.sha256 : '';
  return `${path}\u0000${sha}\n`;
}

/**
 * 规范化一条结果条目。
 * @param {object} entry 结果条目
 * @returns {string} 规范化行
 */
function resultLine(entry) {
  const caseId = entry && typeof entry.case_id === 'string' ? entry.case_id : '';
  const status = entry && typeof entry.status === 'string' ? entry.status : '';
  const errorType = entry && entry.error && typeof entry.error.type === 'string' ? entry.error.type : '';
  const errorMessage = entry && entry.error && typeof entry.error.message === 'string' ? entry.error.message : '';
  const command =
    entry && entry.reproduction && typeof entry.reproduction.command === 'string'
      ? entry.reproduction.command
      : '';
  const steps =
    entry && entry.reproduction && Array.isArray(entry.reproduction.steps)
      ? entry.reproduction.steps.join(' | ')
      : '';
  return `${caseId}\u0000${status}\u0000${errorType}\u0000${errorMessage}\u0000${command}\u0000${steps}\n`;
}

/**
 * 计算证据清单指纹（覆盖全部 evidence 条目的路径 + sha256）。
 * @param {object[]} results 结果数组
 * @returns {string} 指纹
 */
export function evidenceManifestFingerprint(results) {
  const list = Array.isArray(results) ? results : [];
  const parts = [];
  for (const entry of list) {
    const evidence = entry && Array.isArray(entry.evidence) ? entry.evidence : [];
    for (const item of evidence) parts.push(evidenceLine(item));
  }
  return sha256Hex(parts.join(''));
}

/**
 * 计算结果指纹（覆盖判定内容与证据条目）。
 * @param {object[]} results 结果数组
 * @returns {string} 指纹
 */
export function resultsFingerprint(results) {
  const list = Array.isArray(results) ? results : [];
  const parts = list.map((entry) => resultLine(entry));
  for (const entry of list) {
    const evidence = entry && Array.isArray(entry.evidence) ? entry.evidence : [];
    for (const item of evidence) parts.push(evidenceLine(item));
  }
  return sha256Hex(parts.join(''));
}
