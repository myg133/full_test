#!/usr/bin/env node
// redact.mjs — 产物脱敏
//
// 用法: node scripts/redact.mjs <file-or-dir> [--config <规则文件>] [--json]
// 退出码: 0 = 脱敏完成（且没有需要脱敏的内容）, 1 = 校验失败或仍有敏感内容, 2 = 调用方式错误
//
// 说明：
//   执行外壳在**写入产物之前**就已经完成脱敏（走 lib/redaction.mjs），
//   所以正常情况下这里跑一遍应该是"没有可脱敏的内容"。
//   本脚本用于：临时检查某个目录/文件里还有没有敏感内容；按自定义规则补一次脱敏。
//
//   注意：直接改已生成的产物会让证据链的 sha256 失配 —— 改完请重跑 verify-evidence.mjs 确认。
//
// 纯 Node.js，只依赖 node: 内置模块。

import { existsSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';
import process from 'node:process';

import { EXIT_FAIL, EXIT_OK, EXIT_USAGE, parseFlags, usageError, wantsJson, writeJson, writeOut } from './lib/cli.mjs';
import { createRedactor, loadRulesFile } from './lib/redaction.mjs';

const USAGE = [
  '用法: node scripts/redact.mjs <file-or-dir> [--config <规则文件>] [--json]',
  '',
  '选项:',
  '  --config <规则文件>   规则文件（{fields: [], patterns: [{name, regex}]}），与内置规则合并',
  '  --json               stdout 输出机器可读 JSON',
  '  --dry-run            只报告不改动',
  '',
  '退出码: 0 = 没有可脱敏的内容, 1 = 仍有敏感内容或处理失败, 2 = 调用方式错误',
].join('\n');

/**
 * 收集目录下的文件清单。
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
 * 判断文本是不是 JSON 文档。
 * @param {string} text 文本
 * @returns {boolean}
 */
function looksLikeJson(text) {
  const trimmed = text.trim();
  return trimmed.startsWith('{') || trimmed.startsWith('[');
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
  const dryRun = argv.includes('--dry-run');
  const rest = argv.filter((item) => item !== '--dry-run');
  const { flags, positionals } = parseFlags(rest, { value: ['config'] });
  const json = jsonMode || flags.get('json') === true;

  if (positionals.length === 0) usageError(`缺少必填参数 <file-or-dir>\n${USAGE}`);
  if (positionals.length > 1) {
    usageError(`只接受一个 file-or-dir 参数，多余参数: ${positionals.slice(1).join(' / ')}\n${USAGE}`);
  }
  const target = resolve(positionals[0]);
  if (!existsSync(target)) usageError(`路径不存在: ${target}`);

  let rules = null;
  const configFile = flags.get('config');
  if (typeof configFile === 'string' && configFile !== '') {
    const configPath = resolve(configFile);
    if (!existsSync(configPath)) usageError(`规则文件不存在: ${configPath}`);
    try {
      rules = loadRulesFile(configPath);
    } catch (err) {
      usageError(`规则文件无法解析: ${configPath} — ${err.message}`);
    }
  }

  const files = statSync(target).isDirectory() ? listFiles(target) : [target];
  const redactor = createRedactor({ rules, secrets: [] });
  const changed = [];
  for (const file of files) {
    let raw;
    try {
      raw = readFileSync(file, 'utf8');
    } catch {
      continue;
    }
    const before = redactor.stats.redactedFields;
    let output;
    if (looksLikeJson(raw)) {
      try {
        output = `${JSON.stringify(redactor.redactJson(JSON.parse(raw)), null, 2)}\n`;
      } catch {
        output = redactor.redactText(raw);
      }
    } else {
      output = redactor.redactText(raw);
    }
    const touched = redactor.stats.redactedFields > before;
    if (touched && !dryRun) writeFileSync(file, output, 'utf8');
    if (touched) {
      const rel = relative(process.cwd(), file);
      changed.push(rel && !rel.startsWith('..') ? rel : file);
    }
  }

  const redactedFields = redactor.stats.redactedFields;
  const ok = redactedFields === 0;
  if (json) {
    writeJson({
      ok,
      command: 'redact',
      target,
      files_scanned: files.length,
      files_changed: changed,
      redacted_fields: redactedFields,
      rules_applied: redactor.stats.rulesApplied,
      dry_run: dryRun,
      exit_code: ok ? EXIT_OK : EXIT_FAIL,
    });
  } else {
    const lines = [];
    if (ok) {
      lines.push(`[OK] 没有可脱敏的内容（扫描 ${files.length} 个文件）`);
    } else {
      lines.push(`发现敏感内容: 脱敏 ${redactedFields} 处，涉及 ${changed.length} 个文件${dryRun ? '（dry-run，未改动）' : ''}`);
      for (const item of changed) lines.push(`  - ${item}`);
      lines.push(`启用的规则: ${redactor.stats.rulesApplied.join(' / ') || '（无）'}`);
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
    writeJson({ ok: false, command: 'redact', error: message, exit_code: code });
  } else {
    writeOut(`[FAIL] ${message}\n`);
  }
  process.exitCode = code;
}
