// io.mjs —— 输入读取与库文件定位
//
// 两条硬约束（需求 F2 / AC-027）：
//  1. 只用 node: 内置模块，零第三方依赖；
//  2. 维度库 / 方法库的**唯一来源**是同包内 test-case-design 的那两份 JSON ——
//     本 skill 不另存副本；未显式传 --dimensions / --methods 时回落到那两份。
//
// 纯 Node.js，不联网。

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));

/** 同包内库文件的目录：skills/test-case-design/references/（相对本文件三级） */
export const LIB_DIR = path.resolve(HERE, '..', '..', '..', 'test-case-design', 'references');

/** 用法错误：退出码 2。 */
export class UsageError extends Error {}

/** 输入 / 引用非法：退出码 1。 */
export class InputError extends Error {}

/**
 * 读文本文件。
 * @param {string} file 文件路径
 * @param {string} label 人读标签（错误信息里用）
 * @returns {string} 文件内容
 */
export function readTextFile(file, label) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (err) {
    throw new InputError(`${label} 读不到: ${file}（${err && err.message ? err.message : String(err)}）`);
  }
}

/**
 * 读 JSON 文件。
 * @param {string} file 文件路径
 * @param {string} label 人读标签
 * @returns {object} 解析结果
 */
export function readJsonFile(file, label) {
  const text = readTextFile(file, label);
  try {
    return JSON.parse(text);
  } catch (err) {
    throw new InputError(`${label} 不是合法 JSON: ${file}（${err && err.message ? err.message : String(err)}）`);
  }
}

/**
 * 定位库文件：显式路径优先；缺省回落到同包内 test-case-design 的那一份。
 * @param {string|undefined} explicit 显式传入的路径
 * @param {string} libName 库名（dimensions / methods）
 * @returns {string} 绝对路径
 */
export function resolveLibraryFile(explicit, libName) {
  if (typeof explicit === 'string' && explicit.trim() !== '') return path.resolve(explicit);
  return path.join(LIB_DIR, `${libName}.json`);
}

/**
 * 写 JSON 文件（2 空格缩进 + 结尾换行）。
 * @param {string} file 目标文件
 * @param {object} value 待写对象
 */
export function writeJsonFile(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}
