// io.mjs —— 输入读取、输出写入与错误类型（零第三方依赖，只用 node: 内置模块）
//
// 退出码语义（需求 F1.4 / F4.4）：
//   0 = 成功
//   1 = 输入非法 / 引用非法 / 违反写入纪律（InputError）
//   2 = 用法错误（缺参数、参数不认）（UsageError）
//
// ⚠️ 写入纪律：产物**只写** <out-dir>/defect-cases.json 一个文件；
//    输入（缺陷单 / 已有用例集 / cycle.json）一律**只读**。

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
 * 读文本文件（读不到即 InputError）。
 * @param {string} file 文件路径
 * @param {string} label 人读标签（错误信息里用）
 * @returns {string} 文件内容
 */
export function readTextFile(file, label) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (err) {
    const detail = err && err.message ? err.message : String(err);
    throw new InputError(`${label} 读不到: ${file}（${detail}）`);
  }
}

/**
 * 读 JSON 文件（不是合法 JSON 即 InputError，错误信息点名文件与「JSON」）。
 * @param {string} file 文件路径
 * @param {string} label 人读标签
 * @returns {*} 解析结果
 */
export function readJsonFile(file, label) {
  const text = readTextFile(file, label);
  try {
    return JSON.parse(text);
  } catch (err) {
    const detail = err && err.message ? err.message : String(err);
    throw new InputError(`${label} 不是合法 JSON: ${file}（${detail}）`);
  }
}

/**
 * 写 JSON 文件（2 空格缩进 + 结尾换行；先写临时文件再 rename ⇒ 不会留下半份产物）。
 * @param {string} file 目标文件
 * @param {object} value 待写对象
 */
export function writeJsonFileAtomic(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = path.join(
    path.dirname(file),
    `.${path.basename(file)}.tmp-${process.pid}`,
  );
  fs.writeFileSync(tmp, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
  fs.renameSync(tmp, file);
}
