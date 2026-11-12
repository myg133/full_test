#!/usr/bin/env node
/**
 * check-plan.mjs —— 校验一份回归计划是否与输入自洽。
 *
 * 用法：
 *   node scripts/check-plan.mjs --plan <file> --cases <file> --changelog <file> \
 *        [--dimensions <file>] [--methods <file>] [--json]
 *
 * 校验内容（全部查绝对事实）：
 *   1. 计划里出现的用例 id 必须真实存在于输入用例集（不得凭空造用例）；
 *   2. 按输入与库**重新算一遍**影响面，比对 selected / needs_review 两个集合（须逐项相等）；
 *   3. 判不了的变更条目集合与重新算出的结果一致；
 *   4. summary 的每个数字与对应集合的长度逐字相等，impact_complete 与判不了条数不矛盾；
 *   5. selected 与 needs_review 互斥。
 *
 * 退出码：0 = 计划自洽 / 1 = 查出问题 / 2 = 用法错误。
 *
 * 纯 Node.js，零第三方依赖，不联网。
 */

import path from 'node:path';

import { parseArgs } from './lib/cli.mjs';
import { parseChangelog } from './lib/changelog.mjs';
import { InputError, UsageError, readJsonFile, readTextFile, resolveLibraryFile } from './lib/io.mjs';
import { buildPlan } from './lib/plan.mjs';

const SPEC = {
  options: ['--plan', '--cases', '--changelog', '--dimensions', '--methods'],
  flags: ['--json'],
  required: ['--plan', '--cases', '--changelog'],
};

/**
 * 比较两个 id 集合（顺序无关）。
 * @param {string[]} left 左集合
 * @param {string[]} right 右集合
 * @returns {string[]} 差集说明（空数组表示相等）
 */
function diffSets(left, right) {
  const a = [...left].sort();
  const b = [...right].sort();
  const extra = a.filter((item) => !b.includes(item));
  const missing = b.filter((item) => !a.includes(item));
  const problems = [];
  if (extra.length > 0) problems.push(`多出 [${extra.join(',')}]`);
  if (missing.length > 0) problems.push(`缺少 [${missing.join(',')}]`);
  return problems;
}

/**
 * 主流程。
 */
function main() {
  const args = parseArgs(process.argv.slice(2), SPEC);

  const planPath = path.resolve(args['--plan']);
  const casesPath = path.resolve(args['--cases']);
  const changelogPath = path.resolve(args['--changelog']);
  const dimensionsPath = resolveLibraryFile(args['--dimensions'], 'dimensions');
  const methodsPath = resolveLibraryFile(args['--methods'], 'methods');

  const plan = readJsonFile(planPath, '回归计划');
  const casesDoc = readJsonFile(casesPath, '用例集');
  const dimensionsDoc = readJsonFile(dimensionsPath, '维度库');
  const methodsDoc = readJsonFile(methodsPath, '方法库');
  const changelogText = readTextFile(changelogPath, '变更日志');

  const cases = Array.isArray(casesDoc.cases) ? casesDoc.cases : [];
  const dimensions = Array.isArray(dimensionsDoc.dimensions) ? dimensionsDoc.dimensions : [];
  const methods = Array.isArray(methodsDoc.methods) ? methodsDoc.methods : [];
  const knownCaseIds = new Set(cases.map((item) => item.id));

  const expected = buildPlan({
    entries: parseChangelog(changelogText),
    cases,
    dimensions,
    methods,
    cycleId: typeof plan.cycle_id === 'string' ? plan.cycle_id : '',
    source: { changelog: args['--changelog'], cases: args['--cases'] },
  });

  const problems = [];
  const selected = Array.isArray(plan.selected) ? plan.selected : [];
  const needsReview = Array.isArray(plan.needs_review) ? plan.needs_review : [];
  const undecidable = Array.isArray(plan.undecidable_changes) ? plan.undecidable_changes : [];

  // ① 不得凭空造用例
  for (const item of [...selected, ...needsReview]) {
    const caseId = String(item.case_id);
    if (!knownCaseIds.has(caseId)) problems.push(`计划里出现输入中不存在的用例 id: ${caseId}`);
    if (typeof item.reason !== 'string' || item.reason.trim() === '') {
      problems.push(`${caseId} 的 reason 为空 —— 每条选样都必须有可解释的来源`);
    }
    const refs = Array.isArray(item.change_refs) ? item.change_refs : [];
    if (refs.length === 0) problems.push(`${caseId} 的 change_refs 为空`);
  }

  // ② 与重算结果逐项比对
  problems.push(...diffSets(selected.map((item) => String(item.case_id)), expected.selected.map((item) => item.case_id)).map(
    (text) => `selected 不一致: ${text}`,
  ));
  problems.push(...diffSets(needsReview.map((item) => String(item.case_id)), expected.needs_review.map((item) => item.case_id)).map(
    (text) => `needs_review 不一致: ${text}`,
  ));

  // ③ 判不了的变更条目
  problems.push(
    ...diffSets(undecidable.map((item) => String(item.change_id)), expected.undecidable_changes.map((item) => item.change_id)).map(
      (text) => `undecidable_changes 不一致: ${text}`,
    ),
  );

  // ④ 摘要数字
  const summary = plan.summary && typeof plan.summary === 'object' ? plan.summary : {};
  if (Number(summary.total_cases) !== cases.length) {
    problems.push(`summary.total_cases=${summary.total_cases}，实际用例数=${cases.length}`);
  }
  if (Number(summary.selected) !== selected.length) {
    problems.push(`summary.selected=${summary.selected}，实际=${selected.length}`);
  }
  if (Number(summary.needs_review) !== needsReview.length) {
    problems.push(`summary.needs_review=${summary.needs_review}，实际=${needsReview.length}`);
  }
  if (Number(summary.undecidable_changes) !== undecidable.length) {
    problems.push(`summary.undecidable_changes=${summary.undecidable_changes}，实际=${undecidable.length}`);
  }
  if (summary.impact_complete !== (undecidable.length === 0)) {
    problems.push(`summary.impact_complete=${summary.impact_complete}，与判不了条数矛盾`);
  }

  // ⑤ 两个集合互斥
  const selectedIds = new Set(selected.map((item) => String(item.case_id)));
  const overlap = needsReview.map((item) => String(item.case_id)).filter((id) => selectedIds.has(id));
  if (overlap.length > 0) problems.push(`同时出现在 selected 与 needs_review 的用例: ${overlap.join(',')}`);

  if (args['--json']) {
    process.stdout.write(`${JSON.stringify({ ok: problems.length === 0, problems }, null, 2)}\n`);
  } else if (problems.length === 0) {
    process.stdout.write(`[ok] 计划自洽: ${planPath}\n`);
  } else {
    for (const problem of problems) process.stderr.write(`[error] ${problem}\n`);
    process.stderr.write(`[error] 计划不自洽: 共 ${problems.length} 处问题\n`);
  }

  if (problems.length > 0) process.exitCode = 1;
}

try {
  main();
} catch (err) {
  if (err instanceof UsageError) {
    process.stderr.write(`[usage] ${err.message}\n`);
    process.exitCode = 2;
  } else if (err instanceof InputError) {
    process.stderr.write(`[error] ${err.message}\n`);
    process.exitCode = 1;
  } else {
    process.stderr.write(`[error] ${err && err.message ? err.message : String(err)}\n`);
    process.exitCode = 1;
  }
}
