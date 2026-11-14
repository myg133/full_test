#!/usr/bin/env node
/**
 * make-load-profile.mjs —— 压测能力域的**负载模型规划**（主入口）。
 *
 * 用法:
 *   node scripts/make-load-profile.mjs \
 *     --context <压测上下文.json> \
 *     [--cases <功能用例集 cases.json>] \
 *     --out-dir <目标项目根>
 *
 * 做什么:
 *   读一份**压测上下文**（容量目标 + 负载画像 + 阈值及其来源）与一份**可选**的功能用例集，
 *   产出**负载模型本体** + **压测套件** + **压测计划清单**：
 *
 *   <out-dir>/test-assets/load/
 *   ├── report.json                              压测计划清单（套件 ↔ 场景映射 + 未决问题）
 *   ├── scenarios/<场景>.json                    负载模型本体（每个容量目标一个）
 *   └── suites/LOAD-<编号>-<短名>/
 *       ├── scenario.json                         套件级**引用件**（指向 scenarios/）
 *       └── suite.json                            执行配置（scope=load / executor=load）
 *
 * 退出码: 0 = 成功 / 1 = 输入非法或违反写入纪律 / 2 = 用法错误。
 *
 * 硬约束（契约 F1 / F5 / F7 / F8）:
 *   - **只读**输入：压测上下文 / 功能用例集一律不改写；
 *   - **只写** <out-dir>/test-assets/load/；产物已存在 ⇒ 报错退出（**不覆盖**）；
 *   - **先校验、后建目录**：输入非法时**不留半份产物**（test-assets/load/ 一个都不许出现）；
 *   - **幂等**：产物**不含**生成时间戳 ⇒ 同一输入两次跑出来的文件逐字相同；
 *   - **诚实**：没有指标来源就**不写阈值**（用阈值键的有无表达），并留未决问题；
 *   - **不发压**：`load` 执行器尚未实现 ⇒ 本工具只做规划，不跑 runner、不装工具、不联网。
 */

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

import { parseArgs, USAGE, UsageError } from './lib/cli.mjs';
import { validateContext } from './lib/context.mjs';
import { InputError, StateError, isEmptyDir, pathExists, readJsonFile } from './lib/io.mjs';
import { buildProducts, writeProducts } from './lib/product.mjs';
import { assertProductInvariants } from './lib/validate.mjs';

/**
 * 产物根（<out-dir>/test-assets/load）。
 * @param {string} outDir 项目根
 * @returns {string}
 */
function loadRootOf(outDir) {
  return path.join(outDir, 'test-assets', 'load');
}

/**
 * 写入纪律：产物已存在 ⇒ 报错（**不覆盖**既有产物）。
 * @param {string} loadDir 产物根
 */
function assertWritable(loadDir) {
  if (!pathExists(loadDir)) return;
  let stat = null;
  try {
    stat = fs.lstatSync(loadDir);
  } catch {
    return;
  }
  if (!stat.isDirectory() || !isEmptyDir(loadDir)) {
    throw new StateError(
      `产物已存在: ${loadDir}（本工具不覆盖既有产物 —— 请先人工处理，或换一个 --out-dir）`,
    );
  }
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

  try {
    const outDir = path.resolve(options.outDir);
    if (pathExists(outDir) && !fs.statSync(outDir).isDirectory()) {
      throw new UsageError(`--out-dir 指向的不是目录: ${outDir}`);
    }

    // --- 输入（只读） ---
    const contextDoc = readJsonFile(path.resolve(options.context), '压测上下文');
    const context = validateContext(contextDoc);
    const casesDoc = options.cases
      ? readJsonFile(path.resolve(options.cases), '功能用例集')
      : null;

    // --- 写入纪律（落盘前先核） ---
    const loadDir = loadRootOf(outDir);
    assertWritable(loadDir);

    // --- 构造 + 产物侧自检（不通过 ⇒ 一律不落盘） ---
    const products = buildProducts({ context, casesDoc });
    assertProductInvariants(products);

    // --- 落盘 ---
    writeProducts(loadDir, products);

    const suiteNames = products.suites.map((suite) => suite.dirName);
    const scenarioNames = products.scenarios.map((scenario) => scenario.name);
    const questionCount = products.report.open_questions.length;
    process.stdout.write(
      [
        `产物已生成: ${loadDir}`,
        `  负载模型本体 ${scenarioNames.length} 个: ${scenarioNames.join(', ')}`,
        `  压测套件 ${suiteNames.length} 个: ${suiteNames.join(', ')}`,
        `  未决问题 ${questionCount} 条`,
        '',
      ].join('\n'),
    );
    return 0;
  } catch (err) {
    if (err instanceof UsageError) {
      process.stderr.write(`${err.message}\n\n${USAGE}\n`);
      return 2;
    }
    if (err instanceof InputError) {
      process.stderr.write(`输入非法: ${err.message}\n`);
      return 1;
    }
    if (err instanceof StateError) {
      process.stderr.write(`状态非法: ${err.message}\n`);
      return 1;
    }
    const detail = err && err.message ? err.message : String(err);
    process.stderr.write(`生成失败: ${detail}\n`);
    return 1;
  }
}

process.exit(main());
