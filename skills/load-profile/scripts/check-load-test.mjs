#!/usr/bin/env node
/**
 * check-load-test.mjs —— **负载级**产物的自洽校验器（**只读**：一个字节都不写）。
 *
 * 用法:
 *   node scripts/check-load-test.mjs <项目根> --suite <套件名>
 *
 * 复核什么:
 *   - 结果产物的**顶层字段集封闭 8 个**、标量取值合法、`results_sha256` 可被独立复算；
 *   - `execution` 段（6 必填 + 1 条件）、`tool` / `stub` 子段的键集封闭；
 *   - 场景 / invocation 与**压测计划**逐字一致（顺序、字段、`argv`、阈值）；
 *   - 客户端侧观测的键集封闭、`error_rate` 可被重算、延迟分位映射正确；
 *   - 阈值判定条目的键集、枚举、阈值取值与「不可判定」口径；
 *   - 判定汇总**不掩盖失败**（任一 `not_met` ⇒ 套件汇总不得判 `met`）；
 *   - 证据目录：每个 `step_index` 一个子目录、恰好 3 个文件、`manifest.json` 的 sha256 可复算。
 *
 * 退出码: 0 = 自洽 / 1 = 不自洽（逐条点名）/ 2 = 用法错误。
 */

import path from 'node:path';
import process from 'node:process';

import { UsageError } from './lib/io.mjs';
import { verifyArtifact } from './lib/load-exec.mjs';

/** 用法说明文本。 */
const USAGE = [
  '用法: node scripts/check-load-test.mjs <项目根> --suite <套件名>',
  '',
  '复核 <项目根>/test-assets/load/results/<套件名>.json 与压测计划是否自洽（**只读**）。',
  '',
  '退出码: 0 = 自洽 / 1 = 不自洽（逐条点名）/ 2 = 用法错误。',
].join('\n');

/**
 * 解析命令行参数。
 * @param {string[]} argv 参数数组（不含 node 与脚本路径）
 * @returns {{root: string, suite: string, help: boolean}}
 */
export function parseArgs(argv) {
  const out = { root: '', suite: '', help: false };
  const slot = { '--suite': 'suite' };
  let i = 0;
  while (i < argv.length) {
    const arg = argv[i];
    if (arg === '-h' || arg === '--help') {
      out.help = true;
      i += 1;
      continue;
    }
    const eq = arg.indexOf('=');
    const name = eq > 2 ? arg.slice(0, eq) : arg;
    if (Object.prototype.hasOwnProperty.call(slot, name)) {
      let value = eq > 2 ? arg.slice(eq + 1) : undefined;
      if (value === undefined) {
        value = argv[i + 1];
        if (value === undefined || value.startsWith('--')) {
          throw new UsageError(`${name} 需要一个参数`);
        }
        i += 1;
      }
      if (value === '') throw new UsageError(`${name} 需要一个非空参数`);
      out[slot[name]] = value;
      i += 1;
      continue;
    }
    if (arg.startsWith('-')) throw new UsageError(`未知参数: ${arg}`);
    if (out.root) throw new UsageError(`多余的位置参数: ${arg}（本工具只认 <项目根> 与 --suite）`);
    out.root = arg;
    i += 1;
  }
  if (out.help) return out;
  if (!out.root) throw new UsageError('缺少必填参数: <项目根>');
  if (!out.suite) throw new UsageError('缺少必填参数: --suite');
  return out;
}

/**
 * 主流程。
 * @returns {number} 退出码
 */
function main() {
  let options;
  try {
    options = parseArgs(process.argv.slice(2));
  } catch (err) {
    if (err instanceof UsageError) {
      process.stderr.write(`${err.message}\n\n${USAGE}\n`);
      return 2;
    }
    throw err;
  }
  if (options.help) {
    process.stdout.write(`${USAGE}\n`);
    return 0;
  }

  const root = path.resolve(options.root);
  const problems = verifyArtifact(root, options.suite);
  if (problems.length > 0) {
    process.stderr.write(`产物不自洽（${problems.length} 处）:\n- ${problems.join('\n- ')}\n`);
    return 1;
  }
  process.stdout.write(`产物自洽: ${path.join(root, 'test-assets', 'load', 'results', `${options.suite}.json`)}\n`);
  return 0;
}

process.exit(main());
