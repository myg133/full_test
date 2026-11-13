// artifacts.mjs —— 输入读取与校验（**只读**消费）
//
// 硬约束（F2）：
//   1. 只读 —— 绝不写输入产物目录里的任何既有文件；
//   2. 输入缺失或非法 → 报错退出（退出码 1），**不得**产出半份报告；
//   3. 错误信息必须点名「是什么坏了」。

import fs from 'node:fs';
import path from 'node:path';

/** 输入非法（退出码 1）。 */
export class InputError extends Error {
  constructor(message) {
    super(message);
    this.name = 'InputError';
  }
}

/**
 * 判断是不是普通对象（不是数组、不是 null）。
 * @param {*} value 待判定值
 * @returns {boolean} 是否是普通对象
 */
export function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

/**
 * 读取并解析一个 JSON 文件。
 * @param {string} file 文件路径
 * @param {string} label 文件在报错里的名字
 * @returns {*} 解析后的值
 */
function readJsonFile(file, label) {
  if (!fs.existsSync(file)) {
    throw new InputError(`缺少 ${label}：${file}`);
  }
  let text = '';
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (err) {
    throw new InputError(`${label} 不可读：${file}（${err && err.message ? err.message : String(err)}）`);
  }
  try {
    return JSON.parse(text);
  } catch (err) {
    throw new InputError(`${label} 不是合法 JSON：${file}（${err && err.message ? err.message : String(err)}）`);
  }
}

/**
 * 读取一次执行的全部产物（meta.json / results.json）。
 * @param {string} dir 执行产物目录
 * @returns {{dir: string, meta: object, results: object[]}} 产物
 */
export function loadArtifacts(dir) {
  if (!fs.existsSync(dir)) {
    throw new InputError(`执行产物目录不存在：${dir}`);
  }
  if (!fs.statSync(dir).isDirectory()) {
    throw new InputError(`执行产物路径不是目录：${dir}`);
  }
  const meta = readJsonFile(path.join(dir, 'meta.json'), 'meta.json');
  if (!isPlainObject(meta)) {
    throw new InputError(`meta.json 的根节点必须是对象：${path.join(dir, 'meta.json')}`);
  }
  const results = readJsonFile(path.join(dir, 'results.json'), 'results.json');
  if (!Array.isArray(results)) {
    throw new InputError(`results.json 的根节点必须是数组：${path.join(dir, 'results.json')}`);
  }
  return { dir, meta, results };
}

/**
 * 读取回归计划（可选层）。
 * @param {string|null} file 计划文件路径（null = 不给计划）
 * @returns {object|null} 计划对象
 */
export function loadPlan(file) {
  if (file === null || file === undefined || file === '') return null;
  if (!fs.existsSync(file)) {
    throw new InputError(`回归计划文件不存在：${file}`);
  }
  const plan = readJsonFile(file, 'regression-plan.json');
  if (!isPlainObject(plan)) {
    throw new InputError(`回归计划的根节点必须是对象：${file}`);
  }
  return plan;
}
