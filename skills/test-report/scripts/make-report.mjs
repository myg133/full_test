#!/usr/bin/env node
/**
 * make-report.mjs —— 执行报告的主入口。
 *
 * 用法：
 *   node scripts/make-report.mjs --artifacts <run_dir> [--project-root <dir>]
 *                                [--regression-plan <file>] [--out-dir <dir>]
 *
 *   --artifacts       执行产物目录（必填）：含 meta.json / results.json / evidence/
 *   --project-root    项目根（可选但**总是需要**）：显式指定；不给则从
 *                     `<root>/.test-artifacts/<id>` 形态反推；两条都不成立 ⇒ 报错退出
 *   --regression-plan 回归计划文件（可选）：给出后做回归对账
 *   --out-dir         报告输出目录（默认 `<项目根>/reports/<run_id>/`）
 *
 * 退出码：
 *   0 = 报告已产出
 *   1 = 输入缺失或非法 / 项目根定位失败（**不产出半份报告**）
 *   2 = 用法错误
 *
 * 硬约束：
 *   - **只读**消费输入产物，绝不写输入产物目录里的任何既有文件；
 *   - 只写自己的输出目录（默认 `<项目根>/reports/<run_id>/`）；
 *   - 零第三方依赖、不联网（只用 node: 内置模块）；
 *   - 幂等：同一输入两次出报告，除 `generated_at` 外逐字相同。
 */

import fs from 'node:fs';
import path from 'node:path';
import { parseArgs, UsageError } from './lib/cli.mjs';
import { loadArtifacts, loadPlan, InputError } from './lib/artifacts.mjs';
import { buildReport, needsReviewCaseIds } from './lib/analyze.mjs';
import { renderMarkdown } from './lib/render.mjs';
import { resolveProjectRoot, ProjectRootError } from './lib/project-root.mjs';
import { createRedactor } from './lib/redaction.mjs';

/**
 * 打印用法。
 * @returns {string} 用法文本
 */
function usage() {
  return [
    '用法: node scripts/make-report.mjs --artifacts <run_dir> [--project-root <dir>]',
    '                            [--regression-plan <file>] [--out-dir <dir>]',
    '',
    '  --artifacts <run_dir>        执行产物目录（必填）',
    '  --project-root <dir>         项目根；不给则要求产物目录呈 <root>/.test-artifacts/<id> 形态',
    '  --regression-plan <file>     回归计划文件（可选；不给则不做回归对账）',
    '  --out-dir <dir>              报告输出目录（默认 <项目根>/reports/<run_id>/）',
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

  // ① 先校验输入（F1.2.2：输入合法性**先于**项目根定位 —— 否则报错会误导调用方）。
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

  // ② 再定位项目根（D212 三段式；两条路都不成立 ⇒ 报错，不猜）。
  let projectRoot;
  try {
    projectRoot = resolveProjectRoot(
      artifacts.dir,
      options.projectRoot === null ? null : path.resolve(options.projectRoot),
    ).root;
  } catch (err) {
    if (err instanceof ProjectRootError) {
      console.error(`[error] ${err.message}`);
      return 1;
    }
    console.error(`[error] ${err && err.message ? err.message : String(err)}`);
    return 1;
  }

  let report;
  let markdown;
  try {
    const redactor = createRedactor({ projectRoot });
    report = buildReport({
      dir: artifacts.dir,
      meta: artifacts.meta,
      results: artifacts.results,
      plan,
      planPath: options.regressionPlan === null ? null : path.resolve(options.regressionPlan),
      generatedAt: new Date().toISOString(),
      projectRoot,
      redactor,
    });
    markdown = renderMarkdown(report, { needsReviewCaseIds: needsReviewCaseIds(plan) });
  } catch (err) {
    console.error(`[error] 生成报告失败：${err && err.message ? err.message : String(err)}`);
    return 1;
  }

  // ③ 输出目录：`--out-dir` 完全覆盖；否则 `<项目根>/reports/<run_id>/`（run_id 取自 meta.json）。
  const outDir = options.outDir
    ? path.resolve(options.outDir)
    : path.join(projectRoot, 'reports', report.source.run_id);

  // ⚠️ 全部校验与计算都过了才落盘 —— 输入非法时**不留半份报告**。
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
