#!/usr/bin/env node
/**
 * make-defect-cases.mjs —— R3 缺陷复现用例生成（主入口）。
 *
 * 用法:
 *   node scripts/make-defect-cases.mjs \
 *     --defects <defects.json> --cases <cases.json> --suite <suite-id> \
 *     --cycle-dir <R3 轮次目录> [--out-dir <目录>]
 *
 * 做什么:
 *   读缺陷单（defects.json）+ 已有用例集（cases.json）+ R3 轮次目录（cycle.json），
 *   对**每条**缺陷给出**有且只有一个**处置结论（reused / derived / unresolved），
 *   产出缺陷复现用例集 `defect-cases.json`（cases.json v2 的超集，多一个 defects[] 段）。
 *
 * 退出码: 0 = 成功 / 1 = 输入非法或违反写入纪律 / 2 = 用法错误。
 *
 * 硬约束（需求 F6 / F7）:
 *   - **只读**输入：缺陷单、已有用例集、cycle.json 一律不改写（逐字节未变）；
 *   - **只写** <out-dir>/defect-cases.json 一个文件（默认 out-dir = --cycle-dir）；
 *   - **幂等**：同一输入两次运行，除 meta.generated_at 外逐字相同；
 *   - 不推进轮次状态机、不改 cycle.json、不产 R3 的 suite.json、不产缺陷验证报告、
 *     不改缺陷状态。
 *
 * 纯 Node.js：只用 node: 内置模块，零第三方依赖，不联网。
 */

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

import { parseArgs, USAGE, UsageError } from './lib/cli.mjs';
import { InputError, readJsonFile, writeJsonFileAtomic } from './lib/io.mjs';
import {
  validateCasesDocument,
  validateCycleDocument,
  validateDefectsDocument,
} from './lib/validate-defects.mjs';
import { buildProduct } from './lib/product.mjs';

/**
 * 输出目录的写入纪律（需求 F7 / D78）：
 *   - <out-dir>/defect-cases.json 已存在 ⇒ 报错退出（不得覆盖别人的东西）；
 *   - <out-dir> 不存在 ⇒ 创建；
 *   - <out-dir> 存在且含**除 cycle.json 之外**的任何文件 ⇒ 报错退出。
 * @param {string} outDir 输出目录
 */
function assertWritableOutDir(outDir) {
  const product = path.join(outDir, 'defect-cases.json');
  if (fs.existsSync(product)) {
    throw new InputError(
      `输出目录里已经有产物 defect-cases.json（不得覆盖别人的东西）: ${product}`,
    );
  }
  if (fs.existsSync(outDir)) {
    const others = fs.readdirSync(outDir).filter((name) => name !== 'cycle.json');
    if (others.length > 0) {
      throw new InputError(
        `输出目录里已有其它文件（${others.join(' / ')}）—— 只允许 cycle.json: ${outDir}`,
      );
    }
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
    console.error(`[usage] ${err.message}`);
    console.error(USAGE);
    return 2;
  }
  if (options.help) {
    console.log(USAGE);
    return 0;
  }

  try {
    const defectsFile = path.resolve(options.defects);
    const casesFile = path.resolve(options.cases);
    const cycleDir = path.resolve(options.cycleDir);
    const outDir = options.outDir ? path.resolve(options.outDir) : cycleDir;

    // ① 读 + 校验缺陷单（结构层非法 ⇒ 报错退出，不留半份产物）
    const defectsDoc = readJsonFile(defectsFile, '缺陷单 defects.json');
    const defects = validateDefectsDocument(defectsDoc, defectsFile);

    // ② 读 + 校验已有用例集
    const casesDoc = readJsonFile(casesFile, '已有用例集 cases.json');
    const cases = validateCasesDocument(casesDoc, casesFile);

    // ③ 读 + 校验 R3 轮次契约（只读 cycle.json）
    const cycleFile = path.join(cycleDir, 'cycle.json');
    if (!fs.existsSync(cycleFile)) {
      throw new InputError(`轮次目录里没有 cycle.json: ${cycleFile}`);
    }
    const cycle = readJsonFile(cycleFile, '轮次配置 cycle.json');
    validateCycleDocument(cycle, cycleFile, cycleDir, defects.map((item) => item.id));

    // ④ 写入纪律（产物已存在 / 目录里有别人的东西 ⇒ 报错退出）
    assertWritableOutDir(outDir);

    // ⑤ 装配产物
    const product = buildProduct({
      defects,
      cases,
      suite: options.suite,
      cycleId: typeof cycle.cycle_id === 'string' && cycle.cycle_id !== ''
        ? cycle.cycle_id
        : path.basename(cycleDir),
      source: defectsFile,
      generatedAt: new Date().toISOString(),
    });

    // ⑥ 只写这一个文件
    const productFile = path.join(outDir, 'defect-cases.json');
    writeJsonFileAtomic(productFile, product);

    const counts = { reused: 0, derived: 0, unresolved: 0 };
    for (const entry of product.defects) counts[entry.disposition] += 1;
    console.log(`[ok] 产物: ${productFile}`);
    console.log(
      `[ok] 缺陷 ${product.defects.length} 条（复用 ${counts.reused} / 派生 ${counts.derived} / 未决 ${counts.unresolved}）；` +
        `复现用例 ${product.cases.length} 条`,
    );
    for (const entry of product.defects) {
      if (entry.disposition === 'unresolved') {
        console.log(`  · ${entry.id}: unresolved —— ${entry.reason}`);
      }
    }
    return 0;
  } catch (err) {
    if (err instanceof UsageError) {
      console.error(`[usage] ${err.message}`);
      console.error(USAGE);
      return 2;
    }
    if (err instanceof InputError) {
      console.error(`[error] ${err.message}`);
      return 1;
    }
    console.error(`[error] unexpected: ${err && err.message ? err.message : String(err)}`);
    return 1;
  }
}

process.exitCode = main();
