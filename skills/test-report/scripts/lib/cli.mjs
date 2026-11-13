// cli.mjs —— 命令行参数解析
//
// 用法：
//   node scripts/make-report.mjs --artifacts <run_dir> [--regression-plan <file>] [--out-dir <dir>]
//
// 退出码语义：用法错 = 2，输入非法 = 1（与 F7 的调用方契约一致）。

/** 用法错误（退出码 2）。 */
export class UsageError extends Error {
  constructor(message) {
    super(message);
    this.name = 'UsageError';
  }
}

/**
 * 解析命令行参数。
 * @param {string[]} argv 参数数组（不含 node 与脚本路径）
 * @returns {{artifacts: string, regressionPlan: string|null, outDir: string|null, help: boolean}} 解析结果
 */
export function parseArgs(argv) {
  const options = { artifacts: '', regressionPlan: null, outDir: null, help: false };
  let i = 0;
  while (i < argv.length) {
    const arg = argv[i];
    if (arg === '-h' || arg === '--help') {
      options.help = true;
      i += 1;
      continue;
    }
    const isInline = (name) => arg.startsWith(`${name}=`);
    const isFlag = (name) => arg === name || isInline(name);
    if (isFlag('--artifacts')) {
      if (isInline('--artifacts')) {
        options.artifacts = arg.slice('--artifacts='.length);
      } else {
        const value = argv[i + 1];
        if (value === undefined || String(value).startsWith('--')) {
          throw new UsageError('--artifacts 需要一个目录参数');
        }
        options.artifacts = String(value);
        i += 1;
      }
      if (!options.artifacts) throw new UsageError('--artifacts 需要一个目录参数');
    } else if (isFlag('--regression-plan')) {
      if (isInline('--regression-plan')) {
        options.regressionPlan = arg.slice('--regression-plan='.length);
      } else {
        const value = argv[i + 1];
        if (value === undefined || String(value).startsWith('--')) {
          throw new UsageError('--regression-plan 需要一个文件参数');
        }
        options.regressionPlan = String(value);
        i += 1;
      }
      if (!options.regressionPlan) throw new UsageError('--regression-plan 需要一个文件参数');
    } else if (isFlag('--out-dir')) {
      if (isInline('--out-dir')) {
        options.outDir = arg.slice('--out-dir='.length);
      } else {
        const value = argv[i + 1];
        if (value === undefined || String(value).startsWith('--')) {
          throw new UsageError('--out-dir 需要一个目录参数');
        }
        options.outDir = String(value);
        i += 1;
      }
      // 空串视作「没给」→ 走默认输出目录
      if (options.outDir === '') options.outDir = null;
    } else {
      throw new UsageError(`未知参数: ${arg}`);
    }
    i += 1;
  }
  if (options.help) return options;
  if (!options.artifacts) {
    throw new UsageError('缺少必填参数 --artifacts <run_dir>（执行产物目录）');
  }
  return options;
}
