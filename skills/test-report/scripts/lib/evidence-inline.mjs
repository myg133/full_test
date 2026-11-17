// evidence-inline.mjs —— 证据内容内联（REQ-014 demand.md §F2）
//
// 目标：`report.json` **自包含** —— 只读它就能拿到全部证据内容，
// 不再只是「指向被 .gitignore 忽略的产物目录」的路径引用。
//
// 每个条目的字段集**恰好** 8 个（F2.2）：
//   case_id / step / path / sha256 / bytes / media_type / content / content_sha256
//
//   - `path`      相对**项目根**（不是相对产物目录）；
//   - `sha256`    **实算**的文件字节指纹（不是抄 `results.json`）；
//   - `bytes`     文件字节数；
//   - `content`   **脱敏后的原始文本**（D213：没被动过就逐字保留原文件）；
//   - `content_sha256` 对 `content`（UTF-8 字节）算的 sha256。
//
// ⚠️ 缺失的证据文件**不内联**（没有内容可内联）—— 仍由
//    `evidence.files_missing` / `missing_paths` / `findings` 照旧点名（F2.5）。

import fs from 'node:fs';
import path from 'node:path';
import { sha256Hex } from './fingerprint.mjs';
import { relativeToRoot } from './project-root.mjs';
import { isPlainObject } from './artifacts.mjs';

/** 扩展名 → media_type 的兜底推断表。 */
const MEDIA_TYPES = {
  '.json': 'application/json',
  '.har': 'application/json',
  '.txt': 'text/plain',
  '.log': 'text/plain',
  '.md': 'text/markdown',
  '.csv': 'text/csv',
  '.html': 'text/html',
  '.xml': 'application/xml',
  '.yaml': 'application/yaml',
  '.yml': 'application/yaml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.pdf': 'application/pdf',
};

/**
 * 推断 media_type。
 * @param {string} file 文件路径
 * @returns {string} media_type
 */
function inferMediaType(file) {
  const ext = path.extname(file).toLowerCase();
  return MEDIA_TYPES[ext] || 'application/octet-stream';
}

/**
 * 从证据文件名里解析步序号（`step-1-response.json` → `1`；解析不出为 `""`）。
 * @param {string} fileName 文件名
 * @returns {string} 步序号
 */
function parseStep(fileName) {
  const matched = /step-(\d+)/.exec(fileName);
  return matched ? matched[1] : '';
}

/**
 * 扫描全部证据文件，内联**实查存在**的那些。
 * @param {{results: object[], runDir: string, projectRoot: string, redactor: object}} input 输入
 * @returns {object[]} `evidence.files[]` 的条目（按 path 排序）
 */
export function buildEvidenceFiles(input) {
  const { results, runDir, projectRoot, redactor } = input;
  const files = [];
  const seen = new Set();
  for (const entry of results) {
    const caseId = isPlainObject(entry) && typeof entry.case_id === 'string' ? entry.case_id : '';
    const list = isPlainObject(entry) && Array.isArray(entry.evidence) ? entry.evidence : [];
    for (const item of list) {
      if (!isPlainObject(item) || typeof item.path !== 'string' || item.path === '') continue;
      const rel = item.path;
      const abs = path.join(runDir, rel);
      let exists = false;
      try {
        exists = fs.existsSync(abs) && fs.statSync(abs).isFile();
      } catch {
        exists = false;
      }
      // ⚠️ 缺失的文件**不内联**（F2.5）—— 照旧由 files_missing / missing_paths / findings 点名。
      if (!exists) continue;
      const key = `${caseId} ${rel}`;
      if (seen.has(key)) continue;
      seen.add(key);
      const buffer = fs.readFileSync(abs);
      const rawText = buffer.toString('utf8');
      const sha256 = sha256Hex(buffer);
      // ⚠️ D221：本文件**实算**出来的指纹也是「本报告涉及的指纹」——
      //    findings 消息里会引用它（「记录 sha256=X，实算 sha256=Y」）⇒ 必须**早于**内容脱敏登记，
      //    否则它会被长 hex 规则当凭证抹掉。
      redactor.addFingerprints([sha256]);
      const content = redactor.redactEvidenceText(rawText);
      files.push({
        case_id: caseId,
        step: parseStep(path.basename(rel)),
        path: relativeToRoot(projectRoot, abs),
        sha256,
        bytes: buffer.length,
        media_type: typeof item.media_type === 'string' && item.media_type !== ''
          ? item.media_type
          : inferMediaType(abs),
        content,
        content_sha256: sha256Hex(Buffer.from(content, 'utf8')),
      });
    }
  }
  files.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  return files;
}
