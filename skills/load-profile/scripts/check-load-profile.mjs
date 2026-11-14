#!/usr/bin/env node
/**
 * check-load-profile.mjs —— 压测产物的**自洽性校验器**（拿已产出的产物复核一份）。
 *
 * 用法:
 *   node scripts/check-load-profile.mjs <项目根>
 *   node scripts/check-load-profile.mjs --out-dir <项目根>
 *
 * 查什么:
 *   - 负载模型本体的顶层字段集封闭 14 个、profile / tool / traceability 各封闭；
 *   - 枚举取值合法（profile.type 5 值 / tool.runner 2 值 / tool.runtime 3 值 / 阈值键 6 值）；
 *   - 「没有指标来源 ⇒ 不写阈值」用**键的有无**表达，且必留 topic=thresholds 的未决问题；
 *   - 套件目录名 `LOAD-<三位编号>-<短名>`、suite.json 顶层 ⊆ 上游 9 个允许字段、
 *     scope/executor 必须是 load、cases_file 必须是 scenario.json；
 *   - 套件级引用件是**引用**（不是模型副本）：字段集封闭、引用可解析、与本体不漂移；
 *   - 场景 ↔ 套件的**双向覆盖完整性**（无孤儿场景 / 无孤儿套件 / 每个容量目标恰好一个套件）；
 *   - 产物里没有压测结论字段（status / result / verdict / executed / passed / outcome / conclusion），
 *     也没有 method 字段。
 *
 * 退出码: 0 = 自洽 / 1 = 查出问题 / 2 = 用法错误。
 *
 * 零第三方依赖、不联网、不写任何文件。
 */

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

import { inspectProductsOnDisk } from './lib/validate.mjs';

/** 用法说明文本。 */
const USAGE = [
  '用法: node scripts/check-load-profile.mjs <项目根>',
  '      node scripts/check-load-profile.mjs --out-dir <项目根>',
  '',
  '校验 <项目根>/test-assets/load/ 下已产出的压测产物是否自洽。',
  '退出码: 0 = 自洽 / 1 = 查出问题 / 2 = 用法错误。',
].join('\n');

/**
 * 解析命令行参数。
 * @param {string[]} argv 参数数组
 * @returns {{outDir: string}}
 */
function parseArgs(argv) {
  let outDir = '';
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '-h' || arg === '--help') {
      process.stdout.write(`${USAGE}\n`);
      process.exit(0);
    }
    if (arg === '--out-dir') {
      outDir = argv[i + 1] || '';
      i += 1;
    } else if (arg.startsWith('--out-dir=')) {
      outDir = arg.slice('--out-dir='.length);
    } else if (outDir === '' && !arg.startsWith('-')) {
      outDir = arg;
    } else {
      process.stderr.write(`未知参数: ${arg}\n\n${USAGE}\n`);
      process.exit(2);
    }
  }
  if (outDir === '') {
    process.stderr.write(`缺少项目根参数\n\n${USAGE}\n`);
    process.exit(2);
  }
  return { outDir };
}

/**
 * 主流程。
 * @returns {number} 退出码
 */
function main() {
  const { outDir } = parseArgs(process.argv.slice(2));
  const root = path.resolve(outDir);
  if (!fs.existsSync(root) || !fs.statSync(root).isDirectory()) {
    process.stderr.write(`项目根不存在或不是目录: ${root}\n`);
    return 2;
  }
  const loadDir = path.join(root, 'test-assets', 'load');
  if (!fs.existsSync(loadDir)) {
    process.stderr.write(`找不到压测产物目录: ${loadDir}\n`);
    return 1;
  }
  const problems = inspectProductsOnDisk(loadDir);
  if (problems.length > 0) {
    process.stderr.write(`压测产物不自洽（${problems.length} 处）:\n`);
    for (const problem of problems) {
      process.stderr.write(`- ${problem}\n`);
    }
    return 1;
  }
  process.stdout.write(`压测产物自洽: ${loadDir}\n`);
  return 0;
}

process.exit(main());
