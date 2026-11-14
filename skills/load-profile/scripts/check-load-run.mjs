#!/usr/bin/env node
/**
 * check-load-run.mjs —— 压测计划的**产物自洽校验器**（拿已产出的计划复核一份）。
 *
 * 用法:
 *   node scripts/check-load-run.mjs <项目根>
 *   node scripts/check-load-run.mjs --out-dir <项目根>
 *
 * 查什么:
 *   - `plans/` 下的计划文件集合与 `suites/` 下的套件**一一对应**（不多不少、不许叫 suite.json）；
 *   - 计划与负载模型**逐字对得上**：场景顺序、`step_index` / `duration_s` / `concurrency`、
 *     `argv` 的每一个元素、阈值的有无与取值、未决问题的条目数与 id / topic；
 *   - 三层字段集**封闭**（4 / 12 / 4）、枚举取值合法、整数合法；
 *   - 没有压测结论键、没有执行痕迹键、没有「已压测 / 已达标」这类表述；
 *   - 计划里的 `base_url` 与环境文件里的值**逐字相等**，URL 是 `base_url` 去尾斜杠 + 目标路径。
 *
 * 退出码: 0 = 自洽 / 1 = 查出问题 / 2 = 用法错误。
 *
 * ⚠️ 本校验器**必须有行为护栏**：篡改过的计划（哪怕只改一个 `-t` 的值）必须被判红（rc=1）。
 *    零第三方依赖、不联网、不写任何文件。
 */

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

import { InputError, UsageError } from './lib/io.mjs';
import { buildPlans, diffDocs, inspectPlanDocs, loadSide } from './lib/plan.mjs';

/** 用法说明文本。 */
const USAGE = [
  '用法: node scripts/check-load-run.mjs <项目根>',
  '      node scripts/check-load-run.mjs --out-dir <项目根>',
  '',
  '校验 <项目根>/test-assets/load/plans/ 下已产出的压测计划是否与负载模型自洽。',
  '退出码: 0 = 自洽 / 1 = 查出问题 / 2 = 用法错误。',
].join('\n');

/**
 * 解析命令行参数。
 * @param {string[]} argv 参数数组
 * @returns {{root: string}}
 */
function parseArgs(argv) {
  let root = '';
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '-h' || arg === '--help') {
      process.stdout.write(`${USAGE}\n`);
      process.exit(0);
    }
    if (arg === '--out-dir') {
      root = argv[i + 1] || '';
      i += 1;
    } else if (arg.startsWith('--out-dir=')) {
      root = arg.slice('--out-dir='.length);
    } else if (!arg.startsWith('-') && root === '') {
      root = arg;
    } else {
      process.stderr.write(`未知参数: ${arg}\n\n${USAGE}\n`);
      process.exit(2);
    }
  }
  if (root === '') {
    process.stderr.write(`缺少项目根参数\n\n${USAGE}\n`);
    process.exit(2);
  }
  return { root };
}

/**
 * 列出目录下的 .json 文件名（不存在 ⇒ 空数组）。
 * @param {string} dir 目录
 * @returns {string[]}
 */
function listJsonFiles(dir) {
  try {
    return fs
      .readdirSync(dir, { withFileTypes: true })
      .filter((entry) => entry.isFile() && entry.name.endsWith('.json'))
      .map((entry) => entry.name)
      .sort();
  } catch {
    return [];
  }
}

/**
 * 主流程。
 * @returns {number} 退出码
 */
function main() {
  const { root } = parseArgs(process.argv.slice(2));
  const rootDir = path.resolve(root);
  if (!fs.existsSync(rootDir) || !fs.statSync(rootDir).isDirectory()) {
    process.stderr.write(`项目根不存在或不是目录: ${rootDir}\n`);
    return 2;
  }
  const plansDir = path.join(rootDir, 'test-assets', 'load', 'plans');
  if (!fs.existsSync(plansDir) || !fs.statSync(plansDir).isDirectory()) {
    process.stderr.write(`找不到压测计划目录: ${plansDir}\n`);
    return 1;
  }

  const problems = [];
  let expected;
  try {
    // --- 从负载模型重新算一遍「应该长什么样」 ---
    expected = buildPlans(loadSide(rootDir));
  } catch (err) {
    if (err instanceof InputError) {
      process.stderr.write(`输入非法，没法核对计划: ${err.message}\n`);
      return 1;
    }
    throw err;
  }

  // --- 文件集合：与套件一一对应 ---
  const files = listJsonFiles(plansDir);
  const expectedNames = expected.map((plan) => `${plan.name}.json`);
  for (const name of expectedNames) {
    if (!files.includes(name)) problems.push(`缺少计划文件 ${name}`);
  }
  for (const file of files) {
    if (!expectedNames.includes(file)) problems.push(`多出没有对应套件的计划文件 ${file}`);
  }
  if (files.includes('suite.json')) {
    problems.push('plans/ 下出现了 suite.json（会被上游当成套件）');
  }

  // --- 逐个计划核对 ---
  for (const plan of expected) {
    const file = path.join(plansDir, `${plan.name}.json`);
    if (!fs.existsSync(file)) continue;
    let actual;
    try {
      actual = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch (err) {
      problems.push(`${plan.name}.json: 不是合法 JSON（${err && err.message ? err.message : String(err)}）`);
      continue;
    }
    // 结构自检（字段集封闭 / 枚举 / 结论键 / 执行痕迹）
    problems.push(...inspectPlanDocs([{ name: plan.name, doc: actual }]));
    // 与模型逐字比对（键序无关）
    diffDocs(plan.doc, actual, plan.name, problems);
  }

  if (problems.length > 0) {
    process.stderr.write(`压测计划不自洽（${problems.length} 处）:\n`);
    for (const problem of problems) {
      process.stderr.write(`- ${problem}\n`);
    }
    return 1;
  }
  process.stdout.write(`压测计划自洽: ${plansDir}\n`);
  return 0;
}

process.exit(main());
