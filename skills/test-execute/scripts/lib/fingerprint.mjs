// fingerprint.mjs — 证据指纹计算（sha256）
//
// 三种指纹：
//   1) 单文件指纹：证据文件的 sha256 与字节数，写进 results.json 的 evidence[]
//   2) 证据清单指纹：对 results.json 全部 evidence 条目（路径 + sha256）再算一次的总指纹
//      —— 写进 meta.json 的 evidence_manifest_sha256
//   3) 结果指纹：对 results.json 的判定内容（用例 ID / status / 错误 / 复现信息 / 证据条目）
//      算一次的总指纹 —— 写进 meta.json 的 results_sha256
//
// 为什么要有第 3 种：第 2 种只覆盖证据条目，改一条用例的 status 是改不动的。
// 第 3 种覆盖 results.json 的全部判定内容，才能发现"把 failed 改成 passed"这类改写。
//
// 规范化序列化（两端必须完全一致，verify-evidence.mjs 依赖它复算）：
//   证据条目行：${path}\u0000${sha256}\n
//   结果条目行：${case_id}\u0000${status}\u0000${errorType}\u0000${errorMessage}\u0000${command}\u0000${steps}\n
//
// 纯 Node.js，只依赖 node: 内置模块。

import { createHash } from 'node:crypto';
import { readFileSync, statSync } from 'node:fs';

/**
 * 计算 sha256 十六进制摘要。
 * @param {string|Buffer} data 输入数据
 * @returns {string}
 */
export function sha256Hex(data) {
  return createHash('sha256').update(data).digest('hex');
}

/**
 * 计算文件的 sha256 与字节数。
 * @param {string} file 文件路径
 * @returns {{sha256: string, bytes: number}}
 */
export function fingerprintFile(file) {
  const buffer = readFileSync(file);
  return { sha256: sha256Hex(buffer), bytes: statSync(file).size };
}

/**
 * 规范化一条证据条目。
 * @param {object} entry 证据条目
 * @returns {string}
 */
function evidenceLine(entry) {
  const path = entry && typeof entry.path === 'string' ? entry.path : '';
  const sha = entry && typeof entry.sha256 === 'string' ? entry.sha256 : '';
  return `${path}\u0000${sha}\n`;
}

/**
 * 规范化一条结果条目。
 * @param {object} entry 结果条目
 * @returns {string}
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
 * @returns {string}
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
 * @returns {string}
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
