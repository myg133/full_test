// io.mjs —— 输入读取、产物写入与错误类型（零第三方依赖，只用 node: 内置模块）
//
// 退出码语义（契约 F1.1）：
//   0 = 成功
//   1 = 输入非法 / 违反写入纪律（InputError）
//   2 = 用法错误（参数缺失、参数不认、--out-dir 指向文件）（UsageError）
//
// ⚠️ 写入纪律：产物**只写** <out-dir>/test-assets/load/；
//    输入（压测上下文 / 功能用例集）一律**只读**。
// ⚠️ 「先校验、后建目录」：非法输入时**不得**留下半份产物
//    （test-assets/load/ 一个都不许出现，0 字节的空目录也不行）。

import fs from 'node:fs';
import path from 'node:path';

/** 用法错误：退出码 2。 */
export class UsageError extends Error {
  constructor(message) {
    super(message);
    this.name = 'UsageError';
  }
}

/** 输入非法 / 违反写入纪律：退出码 1。 */
export class InputError extends Error {
  constructor(message) {
    super(message);
    this.name = 'InputError';
  }
}

/** 状态非法（例如产物已存在）：退出码 1（与输入非法同一档，但原因不同）。 */
export class StateError extends Error {
  constructor(message) {
    super(message);
    this.name = 'StateError';
  }
}

/**
 * 是否是普通对象（不是数组，也不是 null）。
 * @param {*} value 待判定值
 * @returns {boolean}
 */
export function isObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * 是否是非空字符串（去掉首尾空白后仍非空）。
 * @param {*} value 待判定值
 * @returns {boolean}
 */
export function isFilledString(value) {
  return typeof value === 'string' && value.trim() !== '';
}

/**
 * 深拷贝（JSON 语义）。产物里的值一律来自 JSON 输入 ⇒ JSON 拷贝即可，
 * 且天然去掉 undefined / 函数等 JSON 表达不了的东西。
 * @param {*} value 待拷贝值
 * @returns {*} 拷贝结果
 */
export function clone(value) {
  return value === undefined ? undefined : JSON.parse(JSON.stringify(value));
}

/**
 * 读 JSON 文件（读不到 / 语法错 ⇒ InputError）。
 * @param {string} file 文件路径
 * @param {string} label 人读标签（错误信息里用）
 * @returns {any} 解析结果
 */
export function readJsonFile(file, label) {
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch (err) {
    const detail = err && err.message ? err.message : String(err);
    throw new InputError(`${label} 读不到: ${file}（${detail}）`);
  }
  try {
    return JSON.parse(raw);
  } catch (err) {
    const detail = err && err.message ? err.message : String(err);
    throw new InputError(`${label} 不是合法 JSON: ${file}（${detail}）`);
  }
}

/**
 * 写 JSON 文件（**确定性**：2 空格缩进 + 末尾换行；键序由构造顺序决定）。
 * ⚠️ 产物里**不写**生成时间戳 ⇒ 同一输入两次跑出来的文件逐字相同。
 * @param {string} file 文件路径
 * @param {*} doc 待写入的文档
 */
export function writeJsonFile(file, doc) {
  fs.writeFileSync(file, `${JSON.stringify(doc, null, 2)}\n`, 'utf8');
}

/**
 * 建目录（已存在则不动）。
 * @param {string} dir 目录路径
 */
export function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

/**
 * 路径是否存在（文件或目录都算）。
 * @param {string} target 路径
 * @returns {boolean}
 */
export function pathExists(target) {
  try {
    fs.lstatSync(target);
    return true;
  } catch {
    return false;
  }
}

/**
 * 目录是否为空（不存在也当空）。
 * @param {string} dir 目录路径
 * @returns {boolean}
 */
export function isEmptyDir(dir) {
  try {
    return fs.readdirSync(dir).length === 0;
  } catch {
    return true;
  }
}

/**
 * 列出目录下的子目录名（不存在 ⇒ 空数组）。
 * @param {string} dir 目录路径
 * @returns {string[]}
 */
export function listDirs(dir) {
  try {
    return fs
      .readdirSync(dir, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .sort();
  } catch {
    return [];
  }
}

/**
 * 列出目录下的 .json 文件名（不存在 ⇒ 空数组）。
 * @param {string} dir 目录路径
 * @returns {string[]}
 */
export function listJsonFiles(dir) {
  try {
    return fs
      .readdirSync(dir, { withFileTypes: true })
      .filter((entry) => entry.isFile() && entry.name.endsWith('.json'))
      .map((entry) => entry.name)
      .sort();
  } catch {
    return [];
  }
}

/**
 * 相对项目根的展示路径（用于报错信息）。
 * @param {string} root 项目根
 * @param {string} target 目标路径
 * @returns {string}
 */
export function relativeTo(root, target) {
  const rel = path.relative(root, target);
  return rel === '' ? '.' : rel;
}
