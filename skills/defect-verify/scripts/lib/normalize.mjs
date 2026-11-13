// normalize.mjs —— 归一化口径与特征匹配（需求 D74 / D96）
//
// ⚠️ 这里的口径是**写死**的：实现与验收必须用同一套，否则「命中」这件事不可核。
//    归一化 norm(s)（按顺序）：
//      1. Unicode NFKC 规范化；
//      2. 去首尾空白；
//      3. 连续空白（\s+）压缩成单个空格；
//      4. 剥掉成对包裹的引号（"…" / '…' / “…” / ‘…’）；
//      5. 去**末尾**标点（。．.!！?？;；,，）；
//      6. 再去首尾空白。
//
//    steps 指纹 = 各步 norm(action) 用 \x01 连接；
//    匹配规则：某条已有用例与缺陷单的 steps 指纹逐项相等，**且**
//      （两侧 command 指纹相等 **或** 两侧 command 其一为空）⇒ 命中。
//
//    用例侧的 command 取该用例的 reproduction.command（若带这个额外字段，D96），
//    不带则视为空 —— 上游 v2 用例集本来就没有这个字段。
//
// 纯 Node.js，不联网。

import { isObject } from './io.mjs';

/** 步骤之间的连接符（指纹里用，避免与文本里的其它字符撞车）。 */
export const STEP_SEPARATOR = '\x01';

/** 末尾标点集合（去末尾标点用）。 */
const TRAILING_PUNCTUATION = /[。．.!！?？;；,，]+$/u;

/** 成对包裹的引号（剥一层）。 */
const PAIRED_QUOTES = /^(["'“”‘’])([\s\S]*)\1$/;

/**
 * 归一化一段文本（口径见文件头）。
 * @param {*} value 待归一化的值（null / undefined 视作空串）
 * @returns {string} 归一化结果
 */
export function normalizeText(value) {
  let text = value === undefined || value === null ? '' : String(value);
  text = text.normalize('NFKC');
  text = text.trim();
  text = text.replace(/\s+/g, ' ');
  const quoted = PAIRED_QUOTES.exec(text);
  if (quoted) text = quoted[2];
  text = text.trim();
  text = text.replace(TRAILING_PUNCTUATION, '');
  return text.trim();
}

/**
 * 取步骤数组里每一步的 action 文本（元素是字符串时按字符串取）。
 * @param {*} steps 步骤数组
 * @returns {string[]}
 */
function stepActions(steps) {
  if (!Array.isArray(steps)) return [];
  return steps.map((step) => (isObject(step) ? step.action : step));
}

/**
 * steps 指纹：各步归一化后用 \x01 连接。
 * @param {*} steps 步骤数组
 * @returns {string}
 */
export function stepsFingerprint(steps) {
  return stepActions(steps).map((action) => normalizeText(action)).join(STEP_SEPARATOR);
}

/**
 * 取用例侧的 command（该用例的 reproduction.command；不带则为空）。
 * @param {object} caseObj 已有用例
 * @returns {string}
 */
export function caseCommand(caseObj) {
  if (!isObject(caseObj)) return '';
  if (!isObject(caseObj.reproduction)) return '';
  return typeof caseObj.reproduction.command === 'string' ? caseObj.reproduction.command : '';
}

/**
 * 取缺陷侧的 command（该缺陷的 reproduction.command）。
 * @param {object} defectObj 缺陷单条目
 * @returns {string}
 */
export function defectCommand(defectObj) {
  if (!isObject(defectObj)) return '';
  if (!isObject(defectObj.reproduction)) return '';
  return typeof defectObj.reproduction.command === 'string' ? defectObj.reproduction.command : '';
}

/**
 * 特征匹配：已有用例与缺陷单是否说的是同一件事。
 * @param {object} caseObj 已有用例
 * @param {object} defectObj 缺陷单条目
 * @returns {boolean} 命中即 true
 */
export function featureMatches(caseObj, defectObj) {
  const caseSteps = stepsFingerprint(isObject(caseObj) ? caseObj.steps : []);
  const defectSteps = stepsFingerprint(
    isObject(defectObj) && isObject(defectObj.reproduction) ? defectObj.reproduction.steps : [],
  );
  if (caseSteps !== defectSteps) return false;
  const caseFp = normalizeText(caseCommand(caseObj));
  const defectFp = normalizeText(defectCommand(defectObj));
  return caseFp === defectFp || caseFp === '' || defectFp === '';
}
