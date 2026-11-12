// cli.mjs —— 命令行参数解析（零依赖）
//
// 契约（判据 §0）：
//   --changelog <file> --cases <file> --cycle-dir <dir> [--dimensions <file>] [--methods <file>] [--json]
// 退出码：0 成功 / 1 输入或引用非法 / 2 用法错误。
//
// 纯 Node.js。

import { UsageError } from './io.mjs';

/**
 * 解析命令行参数。
 * @param {string[]} argv 参数数组（不含 node 与脚本路径）
 * @param {{options: string[], flags: string[], required: string[]}} spec 参数规格
 * @returns {object} 解析结果（键名带 `--` 前缀）
 */
export function parseArgs(argv, spec) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith('--')) throw new UsageError(`未知参数: ${arg}`);
    const eq = arg.indexOf('=');
    let key = arg;
    let inlineValue = null;
    if (eq > 2) {
      key = arg.slice(0, eq);
      inlineValue = arg.slice(eq + 1);
    }
    if (spec.flags.includes(key)) {
      if (inlineValue !== null && inlineValue !== 'true' && inlineValue !== 'false') {
        throw new UsageError(`${key} 不接受取值`);
      }
      out[key] = inlineValue !== 'false';
      continue;
    }
    if (!spec.options.includes(key)) throw new UsageError(`未知参数: ${arg}`);
    let value = inlineValue;
    if (value === null) {
      value = argv[i + 1];
      if (value === undefined || value.startsWith('--')) throw new UsageError(`${key} 需要一个参数`);
      i += 1;
    }
    out[key] = value;
  }
  for (const key of spec.required) {
    if (out[key] === undefined || out[key] === '') throw new UsageError(`缺少必填参数: ${key}`);
  }
  return out;
}
