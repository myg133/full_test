// cli.mjs —— 命令行参数解析（零依赖）
//
// 契约（F1.1 / D100）：
//   node scripts/make-security-plan.mjs \
//     --context <安全上下文.json> [--cases <功能用例集.json>] [--scan <扫描结果.json>] \
//     [--environment <环境名>] [--requirement <需求编号>] --out-dir <项目根>
//
// 退出码：0 成功 / 1 输入非法或违反写入纪律 / 2 用法错误。
//
// 纯 Node.js。

/** 用法错误：退出码 2。 */
export class UsageError extends Error {
  constructor(message) {
    super(message);
    this.name = 'UsageError';
  }
}

const OPTIONS = ['--context', '--cases', '--scan', '--environment', '--requirement', '--out-dir'];
const REQUIRED = ['--context', '--out-dir'];

/**
 * 解析命令行参数。
 * @param {string[]} argv 参数数组（不含 node 与脚本路径）
 * @returns {{context: string, cases: string|null, scan: string|null, environment: string|null, requirement: string|null, outDir: string, help: boolean}}
 */
export function parseArgs(argv) {
  const out = {
    context: '',
    cases: null,
    scan: null,
    environment: null,
    requirement: null,
    outDir: '',
    help: false,
  };
  const slot = {
    '--context': 'context',
    '--cases': 'cases',
    '--scan': 'scan',
    '--environment': 'environment',
    '--requirement': 'requirement',
    '--out-dir': 'outDir',
  };

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
    if (!OPTIONS.includes(name)) throw new UsageError(`未知参数: ${arg}`);
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
  }

  if (out.help) return out;
  for (const name of REQUIRED) {
    if (!out[slot[name]]) throw new UsageError(`缺少必填参数: ${name}`);
  }
  return out;
}

/** 用法说明文本。 */
export const USAGE = [
  '用法: node scripts/make-security-plan.mjs \\',
  '  --context <安全上下文.json> [--cases <功能用例集.json>] [--scan <扫描结果.json>] \\',
  '  [--environment <环境名>] [--requirement <需求编号>] --out-dir <项目根>',
  '',
  '产物落位: <out-dir>/test-assets/security/',
  '  threat-model.json / matrix.json / suites/SEC-<编号>-<短名>/{cases.json,suite.json}',
  '',
  '退出码: 0 = 成功 / 1 = 输入非法或违反写入纪律 / 2 = 用法错误',
].join('\n');
