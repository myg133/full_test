// cli.mjs — 本 skill 各脚本共用的 CLI 骨架
//
// 退出码语义（全套脚本统一）：
//   0 = 成功
//   1 = 校验失败或执行失败
//   2 = 调用方式错误
//
// `--json` 模式 stdout 只有 JSON（成功 / 校验失败 / 用法错误三种情形都是），
// 便于调用方直接 JSON.parse。
//
// 纯 Node.js，只依赖 node: 内置模块。

import process from 'node:process';

export const EXIT_OK = 0;
export const EXIT_FAIL = 1;
export const EXIT_USAGE = 2;

/** 带退出码的 CLI 错误 */
export class CliError extends Error {
  /**
   * @param {string} message 完整诊断信息
   * @param {number} code 退出码：1 = 校验失败，2 = 调用方式错误
   * @param {object} details 结构化补充信息（问题清单等）
   */
  constructor(message, code = EXIT_FAIL, details = {}) {
    super(message);
    this.code = code;
    this.details = details;
  }
}

/**
 * 调用方式错误 → 退出码 2。
 * @param {string} message 诊断信息
 * @param {object} details 结构化补充信息
 */
export function usageError(message, details = {}) {
  throw new CliError(message, EXIT_USAGE, details);
}

/**
 * 校验失败 / 执行失败 → 退出码 1。
 * @param {string} message 诊断信息
 * @param {object} details 结构化补充信息
 */
export function failure(message, details = {}) {
  throw new CliError(message, EXIT_FAIL, details);
}

/**
 * 是否请求了机器可读输出。
 *
 * 必须在参数解析**之前**判断：否则用法错误会在 json 标志置位之前抛出，
 * stdout 会变成人读文本而不是合法 JSON。
 *
 * @param {string[]} argv 完整参数数组
 * @returns {boolean}
 */
export function wantsJson(argv) {
  return argv.some((item) => item === '--json' || item.startsWith('--json='));
}

/**
 * 写人读输出。
 * @param {string} text 文本
 */
export function writeOut(text) {
  process.stdout.write(text);
}

/**
 * 写机器可读输出（合法 JSON）。
 * @param {object} payload 数据
 */
export function writeJson(payload) {
  writeOut(`${JSON.stringify(payload, null, 2)}\n`);
}

/**
 * 写日志行到 stderr（stdout 在 --json 模式下只留 JSON）。
 * @param {string} text 文本
 */
export function writeLog(text) {
  process.stderr.write(`${text}\n`);
}

/**
 * 解析命令行参数。
 *
 * @param {string[]} argv 参数数组（不含 node 与脚本路径）
 * @param {{value?: string[], repeatable?: string[]}} spec 参数表
 * @returns {{flags: Map<string, any>, positionals: string[]}}
 */
export function parseFlags(argv, spec = {}) {
  const valueKeys = spec.value || [];
  const repeatable = spec.repeatable || [];
  const flags = new Map();
  const positionals = [];
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--') {
      positionals.push(...argv.slice(i + 1));
      break;
    }
    if (!arg.startsWith('--')) {
      positionals.push(arg);
      continue;
    }
    const eq = arg.indexOf('=');
    const name = eq === -1 ? arg.slice(2) : arg.slice(2, eq);
    if (name === 'json') {
      if (eq !== -1) usageError('--json 不接受取值');
      flags.set('json', true);
      continue;
    }
    if (!valueKeys.includes(name)) {
      usageError(`未知参数 --${name}（支持的参数: ${valueKeys.join(' / ')}）`);
    }
    let value;
    if (eq !== -1) {
      value = arg.slice(eq + 1);
    } else {
      if (i + 1 >= argv.length) usageError(`参数 --${name} 缺少取值`);
      value = argv[i + 1];
      i += 1;
    }
    if (repeatable.includes(name)) {
      const list = flags.get(name) || [];
      list.push(value);
      flags.set(name, list);
    } else {
      flags.set(name, value);
    }
  }
  return { flags, positionals };
}

/**
 * 取字符串型参数（缺省值由调用方给出）。
 * @param {Map<string, any>} flags 参数表
 * @param {string} name 参数名
 * @param {string|null} fallback 缺省值
 * @returns {string|null}
 */
export function stringFlag(flags, name, fallback = null) {
  const raw = flags.get(name);
  if (raw === undefined) return fallback;
  const value = String(raw).trim();
  return value === '' ? fallback : value;
}
