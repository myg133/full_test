#!/usr/bin/env node
/**
 * selftest-report-submittable.mjs —— REQ-014 的单元自测。
 *
 * 覆盖 REQ-014 的三件事 + D219 豁免名单：
 *   1. 项目根三段式定位（显式 / 反推 / 失败报错）；
 *   2. 证据内容内联（8 个键、相对项目根的 path、实算指纹、缺失文件不进、content_sha256 可重算）；
 *   3. 报告内脱敏（字段名 / 值模式 / 绝对路径 / **追踪标识豁免**）；
 *   4. 不变量：无敏感内容 ⇒ `content_sha256 == sha256`；脱敏计数如实；幂等。
 *
 * 用法: node scripts/selftest-report-submittable.mjs
 * 退出码: 0 = 全部通过 / 1 = 有用例失败
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createRedactor } from './lib/redaction.mjs';
import { resolveProjectRoot, deriveProjectRoot, ProjectRootError } from './lib/project-root.mjs';
import { buildEvidenceFiles } from './lib/evidence-inline.mjs';
import { sha256Hex } from './lib/fingerprint.mjs';

let passed = 0;
let failed = 0;

/**
 * 记一条断言。
 * @param {boolean} ok 是否通过
 * @param {string} label 用例名
 * @param {string} [detail] 失败详情
 */
function check(ok, label, detail = '') {
  if (ok) {
    passed += 1;
    console.log(`PASS ${label}`);
    return;
  }
  failed += 1;
  console.log(`FAIL ${label}`);
  if (detail !== '') console.log(`  · ${detail}`);
}

/**
 * 造一个临时目录。
 * @returns {string} 目录绝对路径
 */
function mkTmp() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'test-report-selftest-'));
}

// ---------------------------------------------------------------- 1. 项目根定位

{
  const tmp = mkTmp();
  const projectRoot = path.join(tmp, 'proj');
  const runDir = path.join(projectRoot, '.test-artifacts', 'run-0001');
  fs.mkdirSync(runDir, { recursive: true });

  const derived = resolveProjectRoot(runDir, null);
  check(derived.root === projectRoot && derived.source === 'derived', '项目根 · 从 <root>/.test-artifacts/<id> 形态反推');

  const explicitDir = path.join(tmp, 'other');
  fs.mkdirSync(explicitDir, { recursive: true });
  const explicit = resolveProjectRoot(path.join(tmp, 'ART'), explicitDir);
  check(explicit.root === explicitDir && explicit.source === 'explicit', '项目根 · 显式指定优先');

  let missingRootMessage = '';
  try {
    resolveProjectRoot(path.join(tmp, 'ART'), path.join(tmp, 'no-such-root'));
  } catch (err) {
    missingRootMessage = err instanceof ProjectRootError ? err.message : `不是 ProjectRootError: ${err.message}`;
  }
  check(
    missingRootMessage.includes('项目根不存在'),
    '项目根 · 显式指定的位置不存在时报错',
    `错误信息=${missingRootMessage}`,
  );

  let failedWithMessage = '';
  try {
    resolveProjectRoot(path.join(tmp, 'ART'), null);
  } catch (err) {
    failedWithMessage = err instanceof ProjectRootError ? err.message : `不是 ProjectRootError: ${err.message}`;
  }
  check(
    failedWithMessage.includes('--project-root'),
    '项目根 · 不可反推时报错并点名 --project-root',
    `错误信息=${failedWithMessage}`,
  );
  check(deriveProjectRoot(path.join(tmp, 'ART')) === null, '项目根 · 形态不合法时反推返回 null');

  fs.rmSync(tmp, { recursive: true, force: true });
}

// ---------------------------------------------------------------- 2. 脱敏规则

{
  const redactor = createRedactor({ projectRoot: '/work/proj' });

  // R1 敏感字段名
  const r1 = redactor.redactNode({
    must_change_password: 'PlainTextPwd123',
    access_token: 'tok_live_ABCDEF',
    password: 'x',
    username: 'demo.user',
    page: 'page.secrets.view',
  });
  check(r1.must_change_password === '[REDACTED:field]', 'R1 · must_change_password 命中敏感字段名');
  check(r1.access_token === '[REDACTED:field]', 'R1 · access_token 命中敏感字段名');
  check(r1.password === '[REDACTED:field]', 'R1 · password 命中敏感字段名');
  check(r1.username === 'demo.user', 'R1 · username 不命中（业务账号保留 —— D214）');
  check(r1.page === 'page.secrets.view', 'R1 · 业务权限点不被误伤（F3.1）');

  // R2 值模式
  const r2 = redactor.redactNode({
    command: 'curl -d \'{"username":"demo.user","password":"PlainTextPwd123"}\'',
    auth: 'Bearer ABCDEFGHIJKLMNOPQRSTUVWXYZ012345',
    url: 'http://admin:s3cr3t@example.com/api',
    hex: 'aaaabbbbccccddddaaaabbbbccccdddd',
  });
  check(!r2.command.includes('PlainTextPwd123') && r2.command.includes('[REDACTED:secret]'), 'R2 · 内嵌 JSON 口令被替换');
  check(r2.auth === 'Bearer [REDACTED:secret]', 'R2 · Bearer <token> 被替换');
  check(!r2.url.includes('s3cr3t') && !r2.url.includes(':s3cr3t@'), 'R2 · URL userinfo 被替换');
  check(r2.hex === '[REDACTED:secret]', 'R2 · 长 hex 被替换');

  // D219 豁免名单
  const r3 = redactor.redactNode({
    trace_id: '0123456789abcdef0123456789abcdef',
    'x-trace-id': '0123456789abcdef0123456789abcdef',
    request_id: '0123456789abcdef0123456789abcdef',
    'x-request-id': '0123456789abcdef0123456789abcdef',
    span_id: '0123456789abcdef0123456789abcdef',
    correlation_id: '0123456789abcdef0123456789abcdef',
    id: 'fedcba9876543210fedcba9876543210',
    uuid: '0123456789abcdef0123456789abcdef',
    cache_key: 'aaaabbbbccccddddaaaabbbbccccdddd',
  });
  const hex = '0123456789abcdef0123456789abcdef';
  check(
    r3.trace_id === hex && r3['x-trace-id'] === hex && r3.request_id === hex && r3['x-request-id'] === hex,
    'D219 · 追踪标识键下的值原样保留',
  );
  check(
    r3.span_id === hex && r3.correlation_id === hex && r3.id === 'fedcba9876543210fedcba9876543210' && r3.uuid === hex,
    'D219 · span_id / correlation_id / id / uuid 下的值原样保留',
  );
  check(r3.cache_key === '[REDACTED:secret]', 'D219 · 非豁免键下的长 hex 仍被脱敏（豁免是按键名的）');

  // R3 绝对路径
  const r4 = redactor.redactNode({
    text: '产物在 /work/proj/.test-artifacts/run-0001/logs/runner.log 里，被测目标 http://10.0.0.9:8080/api',
  });
  check(
    r4.text.includes('.test-artifacts/run-0001/logs/runner.log') && !r4.text.includes('/work/proj/'),
    'R3 · 落在项目根下的绝对路径换成相对路径',
  );
  check(r4.text.includes('http://10.0.0.9:8080/api'), 'R3 · 被测目标的 IP/端口逐字保留（D214）');
}

// ---------------------------------------------------------------- 3. 证据内联

{
  const tmp = mkTmp();
  const projectRoot = path.join(tmp, 'proj');
  const runDir = path.join(projectRoot, '.test-artifacts', 'run-0001');
  const evidenceDir = path.join(runDir, 'evidence', 'TC-001');
  fs.mkdirSync(evidenceDir, { recursive: true });
  const raw = `${JSON.stringify({
    driver: 'api',
    response: {
      headers: { 'x-trace-id': '0123456789abcdef0123456789abcdef' },
      body: { trace_id: '0123456789abcdef0123456789abcdef', code: 'OK' },
    },
  }, null, 2)}\n`;
  fs.writeFileSync(path.join(evidenceDir, 'step-1-response.json'), raw, 'utf8');

  const results = [
    {
      case_id: 'TC-001',
      status: 'passed',
      evidence: [
        { path: 'evidence/TC-001/step-1-response.json', sha256: 'x', bytes: 0, media_type: 'application/json' },
        { path: 'evidence/TC-002/step-1-response.json', sha256: 'y', bytes: 0, media_type: 'application/json' },
      ],
    },
  ];
  const redactor = createRedactor({ projectRoot });
  const files = buildEvidenceFiles({ results, runDir, projectRoot, redactor });

  check(files.length === 1, '内联 · 缺失的证据文件不进 files[]', `实得 ${files.length} 条`);
  const file = files[0] || {};
  const wantKeys = ['case_id', 'content', 'content_sha256', 'media_type', 'path', 'sha256', 'step', 'bytes'];
  check(
    Object.keys(file).sort().join(',') === wantKeys.slice().sort().join(','),
    '内联 · 每条恰好 8 个键',
    `实得 [${Object.keys(file).sort().join(',')}]`,
  );
  check(file.path === '.test-artifacts/run-0001/evidence/TC-001/step-1-response.json', '内联 · path 相对项目根', file.path);
  check(file.sha256 === sha256Hex(Buffer.from(raw, 'utf8')), '内联 · sha256 是实算的原文件指纹');
  check(file.bytes === Buffer.byteLength(raw, 'utf8'), '内联 · bytes 是原文件字节数');
  check(file.content === raw, '内联 · 无敏感内容时 content 与原文件逐字相同（D213）');
  check(file.content_sha256 === file.sha256, '内联 · 无敏感内容时 content_sha256 == sha256（AC-011 不变量）');
  check(file.step === '1', '内联 · step 从文件名解析', file.step);

  fs.rmSync(tmp, { recursive: true, force: true });
}

// ---------------------------------------------------------------- 4. 端到端（入口）

{
  const tmp = mkTmp();
  const projectRoot = path.join(tmp, 'proj');
  const runId = 'run-selftest';
  const runDir = path.join(projectRoot, '.test-artifacts', runId);
  fs.mkdirSync(path.join(runDir, 'evidence', 'TC-001'), { recursive: true });
  fs.mkdirSync(path.join(runDir, 'evidence', 'TC-002'), { recursive: true });

  const rawClean = `${JSON.stringify({ driver: 'api', body: { code: 'OK', id: 'fedcba9876543210fedcba9876543210' } }, null, 2)}\n`;
  const rawDirty = `${JSON.stringify({ driver: 'api', body: { password: 'PlainTextPwd123', note: '登录失败' } }, null, 2)}\n`;
  fs.writeFileSync(path.join(runDir, 'evidence', 'TC-001', 'step-1-response.json'), rawClean, 'utf8');
  fs.writeFileSync(path.join(runDir, 'evidence', 'TC-002', 'step-1-response.json'), rawDirty, 'utf8');

  const meta = {
    run_id: runId,
    suite: 'REQ-SELFTEST',
    requirement: 'REQ-SELFTEST',
    environment: 'mock-local',
    started_at: '2026-01-01T00:00:00.000Z',
    finished_at: '2026-01-01T00:00:01.000Z',
  };
  const results = [
    {
      case_id: 'TC-001',
      title: '正常用例',
      status: 'passed',
      duration_ms: 10,
      evidence: [{ path: 'evidence/TC-001/step-1-response.json', sha256: 'x', bytes: 1, media_type: 'application/json' }],
      reproduction: null,
      error: null,
    },
    {
      case_id: 'TC-002',
      title: '失败用例',
      status: 'failed',
      duration_ms: 20,
      evidence: [{ path: 'evidence/TC-002/step-1-response.json', sha256: 'y', bytes: 1, media_type: 'application/json' }],
      reproduction: { steps: [], command: 'curl -d \'{"password":"PlainTextPwd123"}\'', expected: null },
      error: { type: 'assertion_failed', message: '实得 401' },
    },
  ];
  fs.writeFileSync(path.join(runDir, 'meta.json'), `${JSON.stringify(meta, null, 2)}\n`, 'utf8');
  fs.writeFileSync(path.join(runDir, 'results.json'), `${JSON.stringify(results, null, 2)}\n`, 'utf8');

  const script = path.join(path.dirname(new URL(import.meta.url).pathname), 'make-report.mjs');
  const run = (args) => spawnSync(process.execPath, [script, ...args], { encoding: 'utf8' });

  // ① 默认输出位置
  const first = run(['--artifacts', runDir]);
  const outDir = path.join(projectRoot, 'reports', runId);
  check(first.status === 0, '端到端 · 默认输出退出码 0', `stderr=${first.stderr}`);
  check(
    fs.existsSync(path.join(outDir, 'report.json')) && fs.existsSync(path.join(outDir, 'report.md')),
    '端到端 · 报告落在 <项目根>/reports/<run_id>/',
  );
  check(!fs.existsSync(path.join(runDir, 'report')), '端到端 · 旧默认位置 <run_dir>/report/ 不再被写');

  const report = JSON.parse(fs.readFileSync(path.join(outDir, 'report.json'), 'utf8'));
  check(report.source.artifacts === `.test-artifacts/${runId}`, '端到端 · source.artifacts 相对项目根', report.source.artifacts);
  check(
    !JSON.stringify(report).includes('PlainTextPwd123'),
    '端到端 · 明文口令不出现在报告任何位置',
  );
  check(
    Object.keys(report.redaction).sort().join(',') === 'redacted_fields,redacted_values,rules_applied',
    '端到端 · redaction 段字段集恰好 3 个键',
    JSON.stringify(Object.keys(report.redaction)),
  );
  check(
    report.redaction.redacted_fields > 0 && report.redaction.redacted_values > 0,
    '端到端 · 脱敏计数如实（产物里有敏感内容 ⇒ 计数 > 0）',
    JSON.stringify(report.redaction),
  );
  check(report.evidence.files.length === 2, '端到端 · 证据内容全部内联（含 passed 用例的）');
  const tc001 = report.evidence.files.find((f) => f.case_id === 'TC-001');
  check(tc001 && tc001.content_sha256 === tc001.sha256, '端到端 · 无敏感内容 ⇒ content_sha256 == sha256');

  // ② 幂等（除 generated_at 外逐字相同）
  const out2 = path.join(tmp, 'out2');
  const second = run(['--artifacts', runDir, '--out-dir', out2]);
  const strip = (text) => text.replace(/"generated_at": "[^"]+"/, '"generated_at": "<TS>"');
  check(
    second.status === 0 && strip(fs.readFileSync(path.join(outDir, 'report.json'), 'utf8'))
      === strip(fs.readFileSync(path.join(out2, 'report.json'), 'utf8')),
    '端到端 · 幂等：两次报告除 generated_at 外逐字相同',
  );
  check(
    fs.readFileSync(path.join(outDir, 'report.md'), 'utf8').replace(/\d{4}-\d{2}-\d{2}T[\d:.]+Z/g, '<TS>')
      === fs.readFileSync(path.join(out2, 'report.md'), 'utf8').replace(/\d{4}-\d{2}-\d{2}T[\d:.]+Z/g, '<TS>'),
    '端到端 · 幂等：两份 report.md 除时间戳外逐字相同',
  );

  // ③ 不可反推且没给 --project-root ⇒ rc=1 且点名 --project-root、不留半份报告
  const artDir = path.join(tmp, 'ART');
  fs.mkdirSync(artDir, { recursive: true });
  fs.writeFileSync(path.join(artDir, 'meta.json'), `${JSON.stringify(meta, null, 2)}\n`, 'utf8');
  fs.writeFileSync(path.join(artDir, 'results.json'), `${JSON.stringify(results, null, 2)}\n`, 'utf8');
  const bad = run(['--artifacts', artDir]);
  check(bad.status === 1, '端到端 · 不可反推且未给 --project-root ⇒ 退出码 1', `实得 ${bad.status}`);
  check(bad.stderr.includes('--project-root'), '端到端 · 报错点名 --project-root', bad.stderr.trim());
  check(
    !fs.existsSync(path.join(artDir, 'report.json')) && !fs.existsSync(path.join(artDir, 'report.md'))
      && !fs.existsSync(path.join(tmp, 'reports')),
    '端到端 · 失败时不留下半份报告',
  );

  fs.rmSync(tmp, { recursive: true, force: true });
}

console.log('');
console.log(`自测结果：${passed} PASS / ${failed} FAIL`);
process.exitCode = failed === 0 ? 0 : 1;
