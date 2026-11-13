#!/usr/bin/env node
/**
 * make-report.mjs —— 执行报告的主入口。
 *
 * 用法：
 *   node scripts/make-report.mjs --artifacts <run_dir> [--regression-plan <file>] [--out-dir <dir>]
 *
 *   --artifacts       执行产物目录（必填）：含 meta.json / results.json / evidence/
 *   --regression-plan 回归计划文件（可选）：给出后做回归对账
 *   --out-dir         报告输出目录（默认 `<run_dir>/report/`）
 *
 * 退出码：
 *   0 = 报告已产出
 *   1 = 输入缺失或非法（**不产出半份报告**）
 *   2 = 用法错误
 *
 * 硬约束：
 *   - **只读**消费输入产物，绝不写输入产物目录里的任何既有文件；
 *   - 只写自己的输出目录（默认 `<run_dir>/report/`）；
 *   - 零第三方依赖、不联网（只用 node: 内置模块）；
 *   - 幂等：同一输入两次出报告，除 `generated_at` 外逐字相同。
 */

import fs from 'node:fs';
import path from 'node:path';
import { parseArgs, UsageError } from './lib/cli.mjs';
import { loadArtifacts, loadPlan, InputError } from './lib/artifacts.mjs';
import { buildReport } from './lib/analyze.mjs';
import { renderMarkdown } from './lib/render.mjs';

/**
 * 打印用法。
 * @returns {string} 用法文本
 */
function usage() {
  return [
    '用法: node scripts/make-report.mjs --artifacts <run_dir> [--regression-plan <file>] [--out-dir <dir>]',
    '',
    '  --artifacts <run_dir>        执行产物目录（必填）',
    '  --regression-plan <file>     回归计划文件（可选；不给则不做回归对账）',
    '  --out-dir <dir>              报告输出目录（默认 <run_dir>/report/）',
  ].join('\n');
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
    console.error(`[usage] ${err && err.message ? err.message : String(err)}`);
    console.error(usage());
    return 2;
  }
  if (options.help) {
    console.log(usage());
    return 0;
  }

  let artifacts;
  let plan;
  try {
    artifacts = loadArtifacts(path.resolve(options.artifacts));
    plan = loadPlan(options.regressionPlan === null ? null : path.resolve(options.regressionPlan));
  } catch (err) {
    if (err instanceof InputError) {
      console.error(`[error] ${err.message}`);
      return 1;
    }
    console.error(`[error] ${err && err.message ? err.message : String(err)}`);
    return 1;
  }

  let report;
  let markdown;
  try {
    report = buildReport({
      dir: artifacts.dir,
      meta: artifacts.meta,
      results: artifacts.results,
      plan,
      planPath: options.regressionPlan === null ? null : path.resolve(options.regressionPlan),
      generatedAt: new Date().toISOString(),
    });
    markdown = renderMarkdown(report);
  } catch (err) {
    console.error(`[error] 生成报告失败：${err && err.message ? err.message : String(err)}`);
    return 1;
  }

  // ⚠️ 全部校验与计算都过了才落盘 —— 输入非法时**不留半份报告**。
  const outDir = options.outDir ? path.resolve(options.outDir) : path.join(artifacts.dir, 'report');
  try {
    fs.mkdirSync(outDir, { recursive: true });
    fs.writeFileSync(path.join(outDir, 'report.json'), `${JSON.stringify(report, null, 2)}\n`, 'utf8');
    fs.writeFileSync(path.join(outDir, 'report.md'), markdown, 'utf8');
  } catch (err) {
    console.error(`[error] 写报告失败：${err && err.message ? err.message : String(err)}`);
    return 1;
  }

  console.log(`[ok] 报告已产出：${path.join(outDir, 'report.json')}`);
  console.log(`[ok] 报告已产出：${path.join(outDir, 'report.md')}`);
  console.log(
    `[ok] 三层结论：case_layer=${report.verdict.case_layer} evidence_layer=${report.verdict.evidence_layer} ` +
      `regression_layer=${report.verdict.regression_layer} overall=${report.verdict.overall}`,
  );
  return 0;
}

try {
  process.exitCode = main();
} catch (err) {
  if (err instanceof UsageError) {
    console.error(`[usage] ${err.message}`);
    process.exitCode = 2;
  } else {
    console.error(`[error] ${err && err.message ? err.message : String(err)}`);
    process.exitCode = 1;
  }
}
