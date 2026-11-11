#!/usr/bin/env node
// verify-integrity.mjs — 执行器实现完整性自检
//
// 用法: node scripts/verify-integrity.mjs [--json] [--update]
// 退出码: 0 = 执行器实现与随包清单一致, 1 = 不一致（执行器实现被改动过）, 2 = 调用方式错误
//
// 为什么需要（需求 F4）：
//   本 skill 交付的第一个"agent 会想去改"的可执行组件就是执行器。
//   agent 改了执行器源码，后续所有使用者拿到的都是被改过的工具，改动不进版本库、无法追溯。
//   本脚本对 executors/ 下的每个文件算 sha256，与随包发布的 manifest.json 比对：
//   改一个字节就能发现。
//
//   --update 是**维护者**路径（重新生成清单），不是定制路径：
//   改了执行器实现却顺手 --update，等于把污染洗成"正常"。定制需求请走配置。
//
// 纯 Node.js，只依赖 node: 内置模块。

import { existsSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

import { EXIT_FAIL, EXIT_OK, EXIT_USAGE, parseFlags, usageError, wantsJson, writeJson, writeOut } from './lib/cli.mjs';
import { fingerprintFile } from './lib/fingerprint.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const EXECUTOR_DIR = resolve(here, '..', 'executors');
const MANIFEST_FILE = join(EXECUTOR_DIR, 'manifest.json');
const MANIFEST_NAME = 'manifest.json';

const USAGE = [
  '用法: node scripts/verify-integrity.mjs [--json] [--update]',
  '',
  '选项:',
  '  --json      stdout 输出机器可读 JSON',
  '  --update    重新生成 executors/manifest.json（维护者路径，不是定制路径）',
  '',
  '退出码: 0 = 执行器实现与清单一致, 1 = 不一致, 2 = 调用方式错误',
].join('\n');

/**
 * 收集执行器目录下的文件（不含清单自身）。
 * @param {string} dir 目录
 * @returns {string[]}
 */
function listFiles(dir) {
  const out = [];
  for (const item of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, item.name);
    if (item.isDirectory()) out.push(...listFiles(full));
    else out.push(full);
  }
  return out;
}

/**
 * 计算执行器目录下的全部指纹。
 * @returns {{path: string, sha256: string, bytes: number}[]}
 */
function computeFingerprints() {
  return listFiles(EXECUTOR_DIR)
    .filter((file) => file !== MANIFEST_FILE)
    .map((file) => {
      const fingerprint = fingerprintFile(file);
      return {
        path: relative(EXECUTOR_DIR, file).split('\\').join('/'),
        sha256: fingerprint.sha256,
        bytes: fingerprint.bytes,
      };
    })
    .sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
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
  const update = argv.includes('--update');
  const rest = argv.filter((item) => item !== '--update');
  const { flags } = parseFlags(rest, { value: [] });
  const json = jsonMode || flags.get('json') === true;

  if (!existsSync(EXECUTOR_DIR)) {
    usageError(`找不到执行器目录: ${EXECUTOR_DIR}`);
  }

  const fingerprints = computeFingerprints();

  if (update) {
    const manifest = {
      schema_version: 1,
      algorithm: 'sha256',
      note: '执行器实现的完整性清单。scripts/verify-integrity.mjs 按它比对；改动执行器实现会让校验失败。',
      files: fingerprints,
    };
    writeFileSync(MANIFEST_FILE, `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
    if (json) {
      writeJson({
        ok: true,
        command: 'verify-integrity',
        updated: true,
        manifest: MANIFEST_FILE,
        files: fingerprints.length,
        exit_code: EXIT_OK,
      });
    } else {
      writeOut(`[OK] 已重新生成执行器完整性清单: ${MANIFEST_FILE}（${fingerprints.length} 个文件）\n`);
    }
    process.exitCode = EXIT_OK;
    return;
  }

  if (!existsSync(MANIFEST_FILE)) {
    usageError(`找不到执行器完整性清单: ${MANIFEST_FILE}（用 --update 生成）`);
  }
  let manifest;
  try {
    manifest = JSON.parse(readFileSync(MANIFEST_FILE, 'utf8'));
  } catch (err) {
    usageError(`执行器完整性清单无法解析: ${MANIFEST_FILE} — ${err.message}`);
  }
  if (!manifest || !Array.isArray(manifest.files)) {
    usageError(`执行器完整性清单结构非法: ${MANIFEST_FILE}`);
  }

  const recorded = new Map(manifest.files.map((item) => [item.path, item]));
  const actual = new Map(fingerprints.map((item) => [item.path, item]));
  const problems = [];

  for (const [path, item] of actual) {
    if (!recorded.has(path)) {
      problems.push(`执行器目录出现清单里没有的文件: ${path}（可能被手工添加）`);
      continue;
    }
    const expected = recorded.get(path);
    if (expected.sha256 !== item.sha256) {
      problems.push(
        `执行器实现被改动: ${path}（清单 ${String(expected.sha256).slice(0, 12)}…，实际 ${item.sha256.slice(0, 12)}…）`,
      );
    }
  }
  for (const path of recorded.keys()) {
    if (!actual.has(path)) {
      problems.push(`执行器文件缺失: ${path}（清单里有，目录里没有）`);
    }
  }

  const ok = problems.length === 0;
  if (json) {
    writeJson({
      ok,
      command: 'verify-integrity',
      executor_dir: EXECUTOR_DIR,
      manifest: MANIFEST_FILE,
      files_checked: fingerprints.length,
      problems,
      exit_code: ok ? EXIT_OK : EXIT_FAIL,
    });
  } else {
    const lines = [];
    if (ok) {
      lines.push(`[OK] 执行器实现与完整性清单一致（${fingerprints.length} 个文件）`);
    } else {
      lines.push(`✗ 执行器实现完整性校验失败: 共 ${problems.length} 个问题`);
      for (const problem of problems) lines.push(`  - ${problem}`);
      lines.push('修法: 不要改执行器实现。定制需求走配置（用例的 steps[].expected 断言 / case.request / case.auth 等）；');
      lines.push('确实需要改执行器时，走"提需求"，由维护者改实现并重新生成清单。');
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
    writeJson({ ok: false, command: 'verify-integrity', error: message, exit_code: code });
  } else {
    writeOut(`[FAIL] ${message}\n`);
  }
  process.exitCode = code;
}
