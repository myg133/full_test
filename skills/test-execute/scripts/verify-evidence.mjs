#!/usr/bin/env node
// verify-evidence.mjs — 证据链完整性校验
//
// 用法: node scripts/verify-evidence.mjs <run_dir> [--json]
// 退出码: 0 = 证据链自洽, 1 = 校验失败（证据被改动/丢失/结果被改写/计数造假）, 2 = 调用方式错误
//
// 校验项：
//   1) 证据文件存在        —— 丢失即报
//   2) 证据文件 sha256 一致 —— 被改动即报
//   3) 证据清单指纹一致    —— results.json 的 evidence 条目被改即报
//   4) 结果指纹一致        —— results.json 的判定内容被改即报（含 status 被改写）
//   5) 计数一致            —— meta.json 的 cases_total 等与 results.json 实际条数/分布相符
//
// 纯 Node.js，只依赖 node: 内置模块。

import { existsSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import process from 'node:process';

import { EXIT_FAIL, EXIT_OK, EXIT_USAGE, parseFlags, usageError, wantsJson, writeJson, writeOut } from './lib/cli.mjs';
import { evidenceManifestFingerprint, fingerprintFile, resultsFingerprint } from './lib/fingerprint.mjs';
import { STATUS } from './lib/verdict.mjs';

const USAGE = [
  '用法: node scripts/verify-evidence.mjs <run_dir> [--json]',
  '',
  '选项:',
  '  --json   stdout 输出机器可读 JSON',
  '',
  '退出码: 0 = 证据链自洽, 1 = 校验失败, 2 = 调用方式错误',
].join('\n');

/**
 * 读取并解析 JSON 文件。
 * @param {string} file 文件路径
 * @param {string} label 标签
 * @returns {{ok: boolean, data: any, message: string|null}}
 */
function readJson(file, label) {
  if (!existsSync(file)) {
    return { ok: false, data: null, message: `${label} 不存在: ${file}` };
  }
  let raw;
  try {
    raw = readFileSync(file, 'utf8');
  } catch (err) {
    return { ok: false, data: null, message: `${label} 无法读取: ${file} — ${err.message}` };
  }
  try {
    return { ok: true, data: JSON.parse(raw), message: null };
  } catch (err) {
    return { ok: false, data: null, message: `${label} JSON 语法错误: ${file} — ${err.message}` };
  }
}

/**
 * 校验一份执行产物的证据链。
 *
 * @param {string} runDir 产物目录
 * @returns {{problems: string[], counts: object}}
 */
function verify(runDir) {
  const problems = [];
  const metaFile = join(runDir, 'meta.json');
  const resultsFile = join(runDir, 'results.json');

  const meta = readJson(metaFile, 'meta.json');
  if (!meta.ok) {
    problems.push(meta.message);
    return { problems, counts: {} };
  }
  const results = readJson(resultsFile, 'results.json');
  if (!results.ok) {
    problems.push(results.message);
    return { problems, counts: {} };
  }
  if (!Array.isArray(results.data)) {
    problems.push(`results.json 的根节点必须是数组: ${resultsFile}`);
    return { problems, counts: {} };
  }
  const metaData = meta.data;
  const list = results.data;

  // --- 1/2: 证据文件存在与指纹一致 ---
  for (const entry of list) {
    if (!entry || typeof entry !== 'object') {
      problems.push('results.json 里有非对象的条目');
      continue;
    }
    const caseId = typeof entry.case_id === 'string' ? entry.case_id : '(未知用例)';
    const evidence = Array.isArray(entry.evidence) ? entry.evidence : [];
    for (const item of evidence) {
      if (!item || typeof item.path !== 'string') {
        problems.push(`${caseId}: evidence 条目缺少 path`);
        continue;
      }
      const absPath = join(runDir, item.path);
      if (!existsSync(absPath)) {
        problems.push(`${caseId}: 证据文件丢失: ${item.path}`);
        continue;
      }
      const fingerprint = fingerprintFile(absPath);
      if (typeof item.sha256 === 'string' && fingerprint.sha256 !== item.sha256) {
        problems.push(
          `${caseId}: 证据文件被改动: ${item.path}（记录 ${item.sha256.slice(0, 12)}…，实际 ${fingerprint.sha256.slice(0, 12)}…）`,
        );
      }
      if (typeof item.bytes === 'number' && fingerprint.bytes !== item.bytes) {
        problems.push(
          `${caseId}: 证据文件字节数不符: ${item.path}（记录 ${item.bytes}，实际 ${fingerprint.bytes}）`,
        );
      }
    }
  }

  // --- 3: 证据清单指纹 ---
  const manifestFingerprint = evidenceManifestFingerprint(list);
  if (typeof metaData.evidence_manifest_sha256 === 'string') {
    if (metaData.evidence_manifest_sha256 !== manifestFingerprint) {
      problems.push(
        'results.json 与 meta.json 记录的证据清单指纹不符（evidence_manifest_sha256）：' +
          'results.json 的证据条目被改动过',
      );
    }
  } else {
    problems.push('meta.json 缺少 evidence_manifest_sha256');
  }

  // --- 4: 结果指纹 ---
  const resultsHash = resultsFingerprint(list);
  if (typeof metaData.results_sha256 === 'string') {
    if (metaData.results_sha256 !== resultsHash) {
      problems.push(
        'results.json 与 meta.json 记录的清单指纹不符（results_sha256）：' +
          'results.json 的判定内容（用例状态/错误/复现信息）被改动过',
      );
    }
  } else {
    problems.push('meta.json 缺少 results_sha256');
  }

  // --- 5: 计数一致 ---
  const actual = {
    cases_total: list.length,
    cases_passed: list.filter((item) => item && item.status === STATUS.PASSED).length,
    cases_failed: list.filter((item) => item && item.status === STATUS.FAILED).length,
    cases_blocked: list.filter((item) => item && item.status === STATUS.BLOCKED).length,
    cases_skipped: list.filter((item) => item && item.status === STATUS.SKIPPED).length,
  };
  for (const key of Object.keys(actual)) {
    const recorded = metaData[key];
    if (typeof recorded !== 'number') {
      problems.push(`meta.json 缺少计数字段 ${key}`);
      continue;
    }
    if (recorded !== actual[key]) {
      problems.push(
        `meta.json 的 ${key} 与 results.json 的实际条数不符（记录 ${recorded}，实际 ${actual[key]}）：计数造假`,
      );
    }
  }

  return { problems, counts: actual };
}

/**
 * 主流程。
 */
function main() {
  const argv = process.argv.slice(2);
  const jsonMode = wantsJson(argv);

  if (argv.includes('--help') || argv.includes('-h')) {
    writeOut(`${USAGE}\n`);
    process.exitCode = EXIT_OK;
    return;
  }
  const { flags, positionals } = parseFlags(argv, { value: [] });
  const json = jsonMode || flags.get('json') === true;

  if (positionals.length === 0) usageError(`缺少必填参数 <run_dir>\n${USAGE}`);
  if (positionals.length > 1) {
    usageError(`只接受一个 run_dir 参数，多余参数: ${positionals.slice(1).join(' / ')}\n${USAGE}`);
  }
  const runDir = resolve(positionals[0]);
  if (!existsSync(runDir)) {
    usageError(`产物目录不存在: ${runDir}`);
  }

  const outcome = verify(runDir);
  const ok = outcome.problems.length === 0;
  if (json) {
    writeJson({
      ok,
      command: 'verify-evidence',
      run_dir: runDir,
      counts: outcome.counts,
      problems: outcome.problems,
      exit_code: ok ? EXIT_OK : EXIT_FAIL,
    });
  } else {
    const lines = [];
    if (ok) {
      lines.push(`[OK] 证据链自洽: ${runDir}`);
      lines.push(
        `  用例 ${outcome.counts.cases_total} 条 → 通过 ${outcome.counts.cases_passed} / 失败 ${outcome.counts.cases_failed}` +
          ` / 阻塞 ${outcome.counts.cases_blocked} / 跳过 ${outcome.counts.cases_skipped}`,
      );
    } else {
      lines.push(`✗ 证据链校验失败: 共 ${outcome.problems.length} 个问题（目录: ${runDir}）`);
      for (const problem of outcome.problems) lines.push(`  - ${problem}`);
    }
    writeOut(`${lines.join('\n')}\n`);
  }
  process.exitCode = ok ? EXIT_OK : EXIT_FAIL;
}

try {
  main();
} catch (err) {
  const jsonMode = wantsJson(process.argv.slice(2));
  const message = err && err.message ? err.message : String(err);
  const code = err && err.code === EXIT_USAGE ? EXIT_USAGE : EXIT_FAIL;
  if (jsonMode) {
    writeJson({ ok: false, command: 'verify-evidence', error: message, exit_code: code });
  } else {
    writeOut(`[FAIL] ${message}\n`);
  }
  process.exitCode = code;
}
