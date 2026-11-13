// cli.mjs —— 命令行参数解析（零依赖）
//
// 契约（需求 F4.4）：
//   node scripts/make-defect-cases.mjs \
//     --defects <defects.json> --cases <cases.json> --suite <suite-id> \
//     --cycle-dir <R3 轮次目录> [--out-dir <目录>]
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

const OPTIONS = ['--defects', '--cases', '--suite', '--cycle-dir', '--out-dir'];
const REQUIRED = ['--defects', '--cases', '--suite', '--cycle-dir'];

/**
 * 解析命令行参数。
 * @param {string[]} argv 参数数组（不含 node 与脚本路径）
 * @returns {{defects: string, cases: string, suite: string, cycleDir: string, outDir: string|null, help: boolean}}
 */
export function parseArgs(argv) {
  const out = {
    defects: '',
    cases: '',
    suite: '',
    cycleDir: '',
    outDir: null,
    help: false,
  };
  const slot = {
    '--defects': 'defects',
    '--cases': 'cases',
    '--suite': 'suite',
    '--cycle-dir': 'cycleDir',
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
  '用法: node scripts/make-defect-cases.mjs \\',
  '  --defects <defects.json> --cases <cases.json> --suite <suite-id> \\',
  '  --cycle-dir <R3 轮次目录> [--out-dir <目录>]',
  '',
  '退出码: 0 = 成功 / 1 = 输入非法或违反写入纪律 / 2 = 用法错误',
].join('\n');
