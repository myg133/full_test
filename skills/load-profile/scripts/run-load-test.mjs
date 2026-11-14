#!/usr/bin/env node
/**
 * run-load-test.mjs —— 压测能力域的 **负载级执行与判定链**（主入口）。
 *
 * 用法:
 *   node scripts/run-load-test.mjs \
 *     --load-dir <含 test-assets/load/ 的项目根> \
 *     --out-dir  <写出侧项目根> \
 *     --suite    <套件名> \
 *     [--mode api|cli] [--stub-delay-ms <N>] [--stub-error-rate <R>]
 *
 * 做什么:
 *   读 REQ-012 产出的**压测计划**（命令清单），**真的跑起来**（只打**本地桩**），
 *   并按计划里逐字携带的**阈值**给出判定结论，产出**负载级**产物与证据：
 *
 *   <out-dir>/test-assets/load/results/
 *   ├── <套件名>.json                      判定产物（顶层封闭 8 个键）
 *   └── evidence/<套件名>/
 *       ├── manifest.json                  逐个证据文件的 sha256
 *       └── <场景标识>/<step_index>/       每条 invocation 一个证据目录
 *           ├── result.json                该次执行的原始结果
 *           ├── stdout.txt                 该次执行的 stdout 原文
 *           └── stub-observations.json     桩侧观测快照
 *
 * 退出码: 0 = 跑完（**哪怕不达标也是 0**） / 1 = 输入非法 / 工具不可用 / 非回环 /
 *         产物已存在 / 判定链自身出错 / 2 = 用法错误。
 *
 * 硬约束:
 *   - **只打本地桩**：目标地址必须是回环地址；非回环 ⇒ rc=1 + 点名（**绝不**打真实服务）；
 *   - **只写** <out-dir>/test-assets/load/results/；输入（计划 / 模型 / 环境）一律**只读**；
 *   - **先校验、后建目录**：输入非法时 `results/` **一个都不许出现**；
 *   - **产物已存在 ⇒ rc=1 不覆盖**；
 *   - **判定不依赖进程退出码**（桩中途挂掉时压测工具仍然 rc=0 ⇒ 只看观测量）；
 *   - **诚实**：默认桩下延迟类 / 错误率类阈值判**不可判定**（不判达标）；判定枚举只有
 *     `met` / `not_met` / `undetermined`；结论只限定在「本次、本地桩、该负载模型」范围内。
 */

import process from 'node:process';

import { InputError, StateError, UsageError } from './lib/io.mjs';
import { parseArgs, runSuite } from './lib/load-exec.mjs';

/** 用法说明文本。 */
const USAGE = [
  '用法: node scripts/run-load-test.mjs \\',
  '         --load-dir <含 test-assets/load/ 的项目根> \\',
  '         --out-dir  <写出侧项目根> \\',
  '         --suite    <套件名> \\',
  '         [--mode api|cli] [--stub-delay-ms <N>] [--stub-error-rate <R>]',
  '',
  '产出（只写 <out-dir>/test-assets/load/results/）:',
  '  <套件名>.json                          负载级判定产物（顶层封闭 8 个键）',
  '  evidence/<套件名>/manifest.json        逐个证据文件的 sha256',
  '  evidence/<套件名>/<场景>/<step>/…      每条 invocation 的原始结果 / stdout / 桩侧观测',
  '',
  '⚠️ **只打本地桩**：目标地址必须是回环地址；结论只限定在「本次、本地桩」范围内。',
  '',
  '退出码: 0 = 跑完（哪怕不达标也是 0） / 1 = 输入非法或工具不可用或非回环 / 2 = 用法错误。',
].join('\n');

/**
 * 主流程。
 * @returns {Promise<number>} 退出码
 */
async function main() {
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
    const result = await runSuite(options);
    const artifact = result.artifact;
    process.stdout.write(
      [
        `产物已生成: ${result.artifactFile}`,
        `  证据目录: ${result.evidenceDir}`,
        `  执行模式: ${artifact.execution.mode}（桩: ${artifact.execution.stub.origin}）`,
        `  invocation 合计 ${result.invocationCount} 条；套件判定: ${artifact.verdict.suite}`,
        `  不可判定阈值键: ${artifact.verdict.undetermined_keys.join(', ') || '（无）'}`,
        '  ⚠️ 以上结论**只在本地桩上**成立，不代表任何真实服务的容量。',
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
    process.stderr.write(`执行失败: ${detail}\n`);
    return 1;
  }
}

process.exit(await main());
