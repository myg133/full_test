#!/usr/bin/env node
/**
 * plan-regression.mjs —— R2 回归轮：产出一份回归选样计划。
 *
 * 用法：
 *   node scripts/plan-regression.mjs --changelog <file> --cases <file> --cycle-dir <dir> \
 *        [--dimensions <file>] [--methods <file>] [--json]
 *
 * 行为：
 *   - 在 <dir> 内写 regression-plan.json（轮次目录内，与 cycle.json 同级）；
 *   - 只读输入：用例集（cases.json）与变更日志一律**不写**；
 *   - 维度库 / 方法库未显式传时，回落到同包内 test-case-design 的那两份（唯一来源）。
 *
 * 退出码：0 = 成功 / 1 = 输入或引用非法 / 2 = 用法错误。
 *
 * 纯 Node.js，零第三方依赖，不联网。
 */

import fs from 'node:fs';
import path from 'node:path';

import { parseArgs } from './lib/cli.mjs';
import { parseChangelog } from './lib/changelog.mjs';
import { InputError, UsageError, readJsonFile, readTextFile, resolveLibraryFile, writeJsonFile } from './lib/io.mjs';
import { buildPlan } from './lib/plan.mjs';

const SPEC = {
  options: ['--changelog', '--cases', '--cycle-dir', '--dimensions', '--methods'],
  flags: ['--json'],
  required: ['--changelog', '--cases', '--cycle-dir'],
};

/** 计划文件名（固定）。 */
const PLAN_FILENAME = 'regression-plan.json';

/**
 * 校验 changelog 里的引用是否真实存在。
 *
 * 静默忽略坏引用 = 悄悄漏测（不可容忍），所以这里一律报错退出。
 *
 * @param {object[]} entries 变更条目
 * @param {Set<string>} knownRequirements 输入用例集里的需求条目 id
 * @param {Set<string>} knownCases 输入用例集里的用例 id
 * @param {Set<string>} knownDimensions 维度库里的维度 id
 */
function verifyReferences(entries, knownRequirements, knownCases, knownDimensions) {
  for (const entry of entries) {
    for (const ref of entry.requirement_refs) {
      if (!knownRequirements.has(ref)) {
        throw new InputError(
          `变更条目 ${entry.id} 引用了不存在的需求条目: ${ref}（输入用例集的 requirements[] 里没有这个 id）`,
        );
      }
    }
    for (const ref of entry.case_refs) {
      if (!knownCases.has(ref)) {
        throw new InputError(
          `变更条目 ${entry.id} 引用了不存在的用例: ${ref}（输入用例集的 cases[] 里没有这个 id）`,
        );
      }
    }
    for (const ref of entry.dim_refs) {
      if (!knownDimensions.has(ref)) {
        throw new InputError(
          `变更条目 ${entry.id} 引用了不存在的维度: ${ref}（维度库里没有这个 id）`,
        );
      }
    }
  }
}

/**
 * 主流程。
 */
function main() {
  const args = parseArgs(process.argv.slice(2), SPEC);

  const changelogPath = path.resolve(args['--changelog']);
  const casesPath = path.resolve(args['--cases']);
  const cycleDir = path.resolve(args['--cycle-dir']);
  const dimensionsPath = resolveLibraryFile(args['--dimensions'], 'dimensions');
  const methodsPath = resolveLibraryFile(args['--methods'], 'methods');

  const changelogText = readTextFile(changelogPath, '变更日志');
  const casesDoc = readJsonFile(casesPath, '用例集');
  const dimensionsDoc = readJsonFile(dimensionsPath, '维度库');
  const methodsDoc = readJsonFile(methodsPath, '方法库');

  const cases = Array.isArray(casesDoc.cases) ? casesDoc.cases : [];
  const requirements = Array.isArray(casesDoc.requirements) ? casesDoc.requirements : [];
  const dimensions = Array.isArray(dimensionsDoc.dimensions) ? dimensionsDoc.dimensions : [];
  const methods = Array.isArray(methodsDoc.methods) ? methodsDoc.methods : [];

  const entries = parseChangelog(changelogText);
  verifyReferences(
    entries,
    new Set(requirements.map((item) => item.id)),
    new Set(cases.map((item) => item.id)),
    new Set(dimensions.map((item) => item.id)),
  );

  const plan = buildPlan({
    entries,
    cases,
    dimensions,
    methods,
    cycleId: path.basename(cycleDir),
    source: { changelog: args['--changelog'], cases: args['--cases'] },
  });

  const outPath = path.join(cycleDir, PLAN_FILENAME);
  writeJsonFile(outPath, plan);

  if (args['--json']) {
    process.stdout.write(`${JSON.stringify(plan, null, 2)}\n`);
  } else {
    const s = plan.summary;
    process.stdout.write(
      `[ok] 回归计划已写出: ${outPath}\n` +
        `[info] selected=${s.selected} needs_review=${s.needs_review} ` +
        `undecidable_changes=${s.undecidable_changes} impact_complete=${s.impact_complete}\n`,
    );
  }
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
