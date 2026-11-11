// cycle.mjs — 调用 REQ-002.5a 的状态推进器（cycle-state.mjs）
//
// 硬约束：轮次状态只能由 cycle-state.mjs 写（需求 F1 / F7）。
//         本模块**不直接写 cycle.json**，只提交推进意图给推进器。
//
// 为什么用 node:worker_threads 而不是起子进程：
//   需求 AC-015 要求脚本不依赖外部进程工具。本模块在同进程的独立线程里运行
//   推进器脚本，拿到它自己的退出码与输出，既不引入外部依赖，也不污染本脚本的 stdout。
//
// 纯 Node.js，只依赖 node: 内置模块。

import { dirname, resolve } from 'node:path';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { Worker } from 'node:worker_threads';

const here = dirname(fileURLToPath(import.meta.url));

/** REQ-002.5a 的状态推进器（相对本 skill 的路径） */
export const CYCLE_STATE_SCRIPT = resolve(here, '..', '..', '..', 'test-case-design', 'scripts', 'cycle-state.mjs');

/**
 * 调用状态推进器。
 *
 * @param {string[]} args 推进器参数（不含子命令）
 * @param {number} timeoutMs 超时（毫秒）
 * @returns {Promise<{code: number, stdout: string, stderr: string}>}
 */
export async function callCycleState(args, timeoutMs = 30000) {
  if (!existsSync(CYCLE_STATE_SCRIPT)) {
    return {
      code: 2,
      stdout: '',
      stderr: `找不到状态推进器: ${CYCLE_STATE_SCRIPT}（test-case-design skill 未随包安装？）`,
    };
  }
  return new Promise((resolvePromise) => {
    let stdout = '';
    let stderr = '';
    let settled = false;
    const worker = new Worker(CYCLE_STATE_SCRIPT, {
      argv: [...args, '--json'],
      stdout: true,
      stderr: true,
    });
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      worker.terminate();
      resolvePromise({ code: 2, stdout, stderr: `${stderr}\n状态推进器调用超时` });
    }, timeoutMs);
    worker.stdout.on('data', (chunk) => {
      stdout += chunk.toString();
    });
    worker.stderr.on('data', (chunk) => {
      stderr += chunk.toString();
    });
    worker.on('error', (err) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolvePromise({ code: 2, stdout, stderr: `${stderr}\n状态推进器运行失败: ${err.message}` });
    });
    worker.on('exit', (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolvePromise({ code: code === null ? 2 : code, stdout, stderr });
    });
  });
}

/**
 * 推进执行阶段：把本次执行批次记进轮次状态。
 *
 * 只用推进器的能力：
 *   - `--status in_progress` 设置阶段状态
 *   - `--artifacts` 记产物路径
 *   - `--run <run_id>` 把本次执行追加进 `stages.execute.runs[]`（REQ-002.5a 的推进器已支持）
 *
 * @param {string} cycleDir 轮次目录
 * @param {string} artifactPath 本次产物目录（相对项目根）
 * @param {string} runId 本次执行标识
 * @returns {Promise<{ok: boolean, code: number, payload: object|null, message: string}>}
 */
export async function advanceExecuteStage(cycleDir, artifactPath, runId) {
  const args = [
    'set-stage',
    cycleDir,
    '--stage',
    'execute',
    '--status',
    'in_progress',
    '--artifacts',
    artifactPath,
  ];
  if (typeof runId === 'string' && runId !== '') args.push('--run', runId);
  const result = await callCycleState(args);
  let payload = null;
  try {
    payload = JSON.parse(result.stdout);
  } catch {
    payload = null;
  }
  const ok = result.code === 0;
  const message = ok
    ? `轮次 ${cycleDir} 的 execute 阶段已推进（状态 in_progress），产物路径已记入 stages.execute.artifacts，` +
      `本次执行标识已记入 stages.execute.runs[]`
    : `轮次状态推进失败（退出码 ${result.code}）: ${result.stderr || result.stdout}`;
  return { ok, code: result.code, payload, message };
}
