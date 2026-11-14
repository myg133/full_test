#!/usr/bin/env node
/**
 * plan-load-run.mjs —— 压测能力域的 **runner 适配**（主入口）。
 *
 * 用法:
 *   node scripts/plan-load-run.mjs \
 *     --load-dir <含 test-assets/load/ 的项目根> \
 *     --out-dir  <写出侧项目根>
 *
 * 做什么:
 *   读 REQ-009 产出的**负载模型** + **压测套件** + **环境**，产出**压测计划**（命令清单）：
 *
 *   <out-dir>/test-assets/load/plans/
 *   └── <套件名>.json                     每个套件一个；每个 profile 段一条完整可跑的 argv
 *
 * 退出码: 0 = 成功 / 1 = 输入非法或违反写入纪律 / 2 = 用法错误。
 *
 * 硬约束（契约 F1 / F4 / F5 / F6 / F7）:
 *   - **只读**输入：负载模型 / 套件 / 环境一律不改写；
 *   - **只写** <out-dir>/test-assets/load/plans/；产物已存在 ⇒ 报错退出（**不覆盖**）；
 *   - **先校验、后建目录**：输入非法时 `plans/` **一个都不许出现**（0 字节的空目录也不行）；
 *   - **多段不合并**：`profile.steps[]` 每段一条 invocation（合并 = 丢梯度 = 失真）；
 *   - **`args` 未知键一律拒绝**（静默忽略 = 悄悄丢参数 = 压出来的不是你想压的）；
 *   - **`python` runner 必须自陈完整命令**（不许编造默认命令）；
 *   - **诚实**：阈值可携带（逐字来自模型），但**绝不**产出任何「已达标/未达标」的结论；
 *   - **不发压**：不 spawn 压测工具、不联网、不打桩、不判阈值（`load` 执行器尚未实现）。
 */

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

import { InputError, StateError, UsageError, ensureDir, pathExists, writeJsonFile } from './lib/io.mjs';
import { buildPlans, inspectPlanDocs, loadSide } from './lib/plan.mjs';

/** 用法说明文本。 */
const USAGE = [
  '用法: node scripts/plan-load-run.mjs \\',
  '         --load-dir <含 test-assets/load/ 的项目根> \\',
  '         --out-dir  <写出侧项目根>',
  '',
  '产出（只写 <out-dir>/test-assets/load/plans/）:',
  '  <套件名>.json                            压测计划（每个 profile 段一条完整可跑的 argv）',
  '',
  '退出码: 0 = 成功 / 1 = 输入非法或违反写入纪律 / 2 = 用法错误。',
].join('\n');

/**
 * 解析命令行参数。
 * @param {string[]} argv 参数数组（不含 node 与脚本路径）
 * @returns {{loadDir: string, outDir: string, help: boolean}}
 */
export function parseArgs(argv) {
  const out = { loadDir: '', outDir: '', help: false };
  const slot = { '--load-dir': 'loadDir', '--out-dir': 'outDir' };

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
    if (!Object.prototype.hasOwnProperty.call(slot, name)) {
      if (!arg.startsWith('-')) {
        throw new UsageError(`多余的位置参数: ${arg}（本工具只认 --load-dir 与 --out-dir）`);
      }
      throw new UsageError(`未知参数: ${arg}`);
    }
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
  for (const name of ['--load-dir', '--out-dir']) {
    if (!out[slot[name]]) throw new UsageError(`缺少必填参数: ${name}`);
  }
  return out;
}

/**
 * 写出侧的计划目录。
 * @param {string} outDir 写出侧项目根
 * @returns {string}
 */
function plansDirOf(outDir) {
  return path.join(outDir, 'test-assets', 'load', 'plans');
}

/**
 * 写入纪律：产物已存在 ⇒ 报错（**不覆盖**既有产物）。
 * @param {string} plansDir 计划目录
 */
function assertWritable(plansDir) {
  if (!pathExists(plansDir)) return;
  throw new StateError(
    `产物已存在: ${plansDir}（本工具不覆盖既有产物 —— 请先人工处理，或换一个 --out-dir）`,
  );
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
    const loadDir = path.resolve(options.loadDir);
    const outDir = path.resolve(options.outDir);
    if (!fs.existsSync(loadDir) || !fs.statSync(loadDir).isDirectory()) {
      throw new InputError(`--load-dir 指向的不是目录: ${loadDir}`);
    }
    if (fs.existsSync(outDir) && !fs.statSync(outDir).isDirectory()) {
      throw new UsageError(`--out-dir 指向的不是目录: ${outDir}`);
    }

    // --- 输入（只读）+ 校验 + 构造计划：全程不写任何文件 ---
    const side = loadSide(loadDir);
    const plans = buildPlans(side);

    // --- 产物侧自检：不通过 ⇒ 一律不落盘（不产生半份产物） ---
    const problems = inspectPlanDocs(plans);
    if (problems.length > 0) {
      throw new InputError(`压测计划不自洽（${problems.length} 处）:\n- ${problems.join('\n- ')}`);
    }

    // --- 写入纪律（落盘前先核） ---
    const plansDir = plansDirOf(outDir);
    assertWritable(plansDir);

    // --- 落盘（只写 plans/） ---
    ensureDir(plansDir);
    for (const plan of plans) {
      writeJsonFile(path.join(plansDir, `${plan.name}.json`), plan.doc);
    }

    const invocations = plans.reduce(
      (sum, plan) => sum + plan.doc.scenarios.reduce((n, s) => n + s.invocations.length, 0),
      0,
    );
    process.stdout.write(
      [
        `产物已生成: ${plansDir}`,
        `  压测计划 ${plans.length} 个: ${plans.map((p) => p.name).join(', ')}`,
        `  invocation 合计 ${invocations} 条（每个 profile 段一条，不合并）`,
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
