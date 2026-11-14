// catalog.mjs —— 枚举常量与「唯一来源」的外部库装载（方法库 / 维度库）
//
// ⚠️ 方法号的**唯一来源**是 skills/test-case-design/references/methods.json
//    （M1.1~M1.6 + M2.1 威胁建模(STRIDE) / M2.2 攻击面枚举 / M2.3 模糊测试）。
//    架构稿里写的「M4.2（安全）」**不存在**（陈旧）—— 不在这里另立一份副本。
// ⚠️ 维度的**唯一来源**是 skills/test-case-design/references/dimensions.json（其中已含 security）。
//    副本 = 又一份真相 = 枚举分叉的病根；读不到就**明确报错**，绝不静默降级到内置列表。

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { InputError } from './io.mjs';

const LIB_DIR = path.dirname(fileURLToPath(import.meta.url));

/** 本 skill 的根目录（skills/security-plan）。 */
export const SKILL_ROOT = path.resolve(LIB_DIR, '..', '..');

/** 同级 skill：test-case-design（方法库 / 维度库的所在处）。 */
export const TCD_ROOT = path.resolve(SKILL_ROOT, '..', 'test-case-design');

/** OWASP 十类（A01~A10）。 */
export const OWASP_CODES = Object.freeze([
  'A01',
  'A02',
  'A03',
  'A04',
  'A05',
  'A06',
  'A07',
  'A08',
  'A09',
  'A10',
]);

/** OWASP 十类的中文名（产物里的理由文本用）。 */
export const OWASP_NAMES = Object.freeze({
  A01: '访问控制失效',
  A02: '密码学失效',
  A03: '注入',
  A04: '不安全设计',
  A05: '安全配置错误',
  A06: '易受攻击和过时的组件',
  A07: '身份识别与认证失效',
  A08: '软件与数据完整性失效',
  A09: '安全日志与监控失效',
  A10: '服务端请求伪造',
});

/** 四类实战补充（键集固定四个）。 */
export const SUPPLEMENT_KEYS = Object.freeze(['file_upload', 'ssrf', 'xxe', 'deserialization']);

/** 四类实战补充的中文名。 */
export const SUPPLEMENT_NAMES = Object.freeze({
  file_upload: '文件上传',
  ssrf: '服务端请求伪造（SSRF）',
  xxe: 'XML 外部实体注入（XXE）',
  deserialization: '反序列化',
});

/** STRIDE 六类（威胁的 category 枚举）。 */
export const STRIDE_CATEGORIES = Object.freeze([
  'spoofing',
  'tampering',
  'repudiation',
  'information_disclosure',
  'denial_of_service',
  'elevation_of_privilege',
]);

/** 严重度枚举。 */
export const SEVERITIES = Object.freeze(['critical', 'high', 'medium', 'low']);

/** 敏感度枚举（资产的 sensitivity）。 */
export const SENSITIVITIES = Object.freeze(['critical', 'high', 'medium', 'low']);

/** 敏感度排序（取资源下最敏感的资产）。 */
export const SENSITIVITY_ORDER = Object.freeze({ critical: 4, high: 3, medium: 2, low: 1 });

/**
 * 读一个 JSON 文件并取其中的 id 数组。
 * @param {string} file 文件路径
 * @param {string} label 人读标签
 * @param {string} key 顶层数组字段名
 * @returns {string[]} id 数组
 */
function readIdList(file, label, key) {
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch (err) {
    const detail = err && err.message ? err.message : String(err);
    throw new InputError(`${label} 不可用: ${file}（${detail}）`);
  }
  let doc;
  try {
    doc = JSON.parse(raw);
  } catch (err) {
    const detail = err && err.message ? err.message : String(err);
    throw new InputError(`${label} 不可用（不是合法 JSON）: ${file}（${detail}）`);
  }
  const list = doc && Array.isArray(doc[key]) ? doc[key] : null;
  if (!list || list.length === 0) {
    throw new InputError(`${label} 不可用: ${file} 缺少非空的 ${key} 数组`);
  }
  const ids = [];
  for (const [index, item] of list.entries()) {
    const id = item && typeof item.id === 'string' ? item.id.trim() : '';
    if (id === '') {
      throw new InputError(`${label} 不可用: ${file} 的 ${key}[${index}].id 必须是非空字符串`);
    }
    ids.push(id);
  }
  return ids;
}

/**
 * 装载方法库的方法号（唯一来源：test-case-design/references/methods.json）。
 * @returns {string[]} 方法号清单
 */
export function loadMethodIds() {
  return readIdList(
    path.join(TCD_ROOT, 'references', 'methods.json'),
    '方法库',
    'methods',
  );
}

/**
 * 装载覆盖维度 id（唯一来源：test-case-design/references/dimensions.json）。
 * @returns {string[]} 维度 id 清单
 */
export function loadDimensionIds() {
  return readIdList(
    path.join(TCD_ROOT, 'references', 'dimensions.json'),
    '覆盖维度库',
    'dimensions',
  );
}
