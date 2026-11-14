#!/usr/bin/env node
/**
 * selftest-security-plan.mjs —— 派生规则的单元自测。
 *
 * 覆盖那些**验收夹具造不出来**的分支（口令哈希 vs 明文口令、角色级别、扫描分类、
 * 矩阵缺口的双向对应、用例 id 避让、幂等、非法输入不留产物、产物已存在即报错）。
 *
 * 用法: node scripts/selftest-security-plan.mjs
 * 退出码: 0 = 全部通过 / 1 = 有断言失败
 *
 * 纯 Node.js：只用 node: 内置模块，零第三方依赖，不联网。
 * 临时产物落在系统临时目录（每次跑用独立目录，跑完自行清理）。
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { InputError } from './lib/io.mjs';
import { validateContext } from './lib/context.mjs';
import { classifyFinding, isCredentialAsset, roleLevel } from './lib/threats.mjs';
import { deriveThreats } from './lib/threats.mjs';
import { deriveMatrix } from './lib/matrix.mjs';
import { allocateCaseId, deriveSuites } from './lib/cases.mjs';
import { parseScan } from './lib/scan.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));

let passed = 0;
const failures = [];

/**
 * 断言。
 * @param {string} name 用例名
 * @param {boolean} condition 条件
 * @param {string} detail 失败时的说明
 */
function check(name, condition, detail) {
  if (condition) {
    passed += 1;
    return;
  }
  failures.push(`${name}${detail ? ` —— ${detail}` : ''}`);
}

/**
 * 最小上下文（与验收夹具同形，但更小）。
 * @returns {object} 上下文文档
 */
function baseContext() {
  return {
    schema_version: 1,
    service: { name: 'order-api' },
    assets: [
      { id: 'AS-1', name: '用户口令哈希', sensitivity: 'critical' },
      { id: 'AS-2', name: '订单数据', sensitivity: 'high' },
      { id: 'AS-3', name: '访问日志', sensitivity: 'medium' },
    ],
    trust_boundaries: [
      { id: 'TB-1', name: '公网到应用', controls: ['TLS 终止'] },
      { id: 'TB-2', name: '应用到数据层', controls: ['参数化查询'] },
    ],
    entry_points: [
      { id: 'EP-1', name: '登录接口', kind: 'http', asset_refs: ['AS-1'], boundary_refs: ['TB-1'], description: 'POST /api/login' },
      { id: 'EP-2', name: '订单详情接口', kind: 'http', asset_refs: ['AS-2'], boundary_refs: ['TB-1'], description: 'GET /api/orders/{id}' },
      { id: 'EP-3', name: '日志写入', kind: 'file', asset_refs: ['AS-3'], boundary_refs: ['TB-2'], description: '写访问日志' },
    ],
    roles: [
      { id: 'ROLE-1', name: '匿名访客' },
      { id: 'ROLE-2', name: '登录用户' },
      { id: 'ROLE-3', name: '管理员' },
    ],
    resources: [
      { id: 'RES-1', name: '订单', asset_refs: ['AS-2'] },
      { id: 'RES-2', name: '用户账号', asset_refs: ['AS-1'] },
    ],
  };
}

/**
 * 归一化一份上下文（结构非法即抛）。
 * @param {object} doc 上下文文档
 * @returns {object} 归一化结果
 */
function normalize(doc) {
  return validateContext(doc, 'selftest');
}

// --- T1：上下文结构层校验：五种非法变体都要抛 InputError 且点名坏点 ---
const illegal = [
  ['缺 assets', (doc) => { delete doc.assets; }, 'assets'],
  ['trust_boundaries 是字符串', (doc) => { doc.trust_boundaries = 'x'; }, 'trust_boundaries'],
  ['缺 entry_points[0].name', (doc) => { delete doc.entry_points[0].name; }, 'entry_points[0].name'],
  ['缺 roles', (doc) => { delete doc.roles; }, 'roles'],
  ['resources 是对象', (doc) => { doc.resources = {}; }, 'resources'],
  ['引用悬空', (doc) => { doc.entry_points[0].asset_refs = ['AS-999']; }, 'AS-999'],
  ['id 重复', (doc) => { doc.assets[1].id = 'AS-1'; }, 'AS-1'],
  ['id 格式错', (doc) => { doc.entry_points[0].id = 'EP-XYZ'; }, 'EP-XYZ'],
  ['枚举越界', (doc) => { doc.assets[0].sensitivity = 'secret'; }, 'secret'],
];
for (const [name, mutate, keyword] of illegal) {
  const doc = baseContext();
  mutate(doc);
  let message = null;
  try {
    normalize(doc);
  } catch (err) {
    message = err instanceof InputError ? err.message : `不是 InputError: ${err.message}`;
  }
  check(`T1 ${name} 抛 InputError`, message !== null, '没有抛错');
  check(`T1 ${name} 点名坏点`, message !== null && message.includes(keyword), `消息: ${message}`);
}

// --- T2：关键词判定（口令哈希 ≠ 密码学环节）---
{
  const ctx = normalize(baseContext());
  const hash = ctx.assets.find((asset) => asset.id === 'AS-1');
  const order = ctx.assets.find((asset) => asset.id === 'AS-2');
  check('T2 「用户口令哈希」不是密码学资产', !/密钥|明文口令|加密|证书/.test(hash.name));
  check('T2 「用户口令哈希」是凭据资产', isCredentialAsset(hash));
  check('T2 「订单数据」不是凭据资产', !isCredentialAsset(order));
  const cryptoDoc = baseContext();
  cryptoDoc.assets[0].name = '支付密钥';
  const cryptoCtx = normalize(cryptoDoc);
  const derived = deriveThreats(cryptoCtx, { status: 'not_provided', tool: null, findings: [], kind: 'none', reason: '', sourceFile: '' }, { actions: [], ids: new Set(), count: 0 });
  check('T2 出现「支付密钥」时 A02 被覆盖', derived.owaspCoverage.A02.status === 'covered',
    `实际 ${derived.owaspCoverage.A02.status}`);
}

// --- T3：角色级别 ---
{
  const ctx = normalize(baseContext());
  check('T3 匿名访客 → anonymous', roleLevel(ctx.roles[0]) === 'anonymous');
  check('T3 登录用户 → user', roleLevel(ctx.roles[1]) === 'user');
  check('T3 管理员 → admin', roleLevel(ctx.roles[2]) === 'admin');
}

// --- T4：扫描分类 ---
{
  const hardcoded = classifyFinding({ summary: "Possible hardcoded password: 'secret123'" }, 'bandit');
  check('T4 硬编码口令 → A07', hardcoded.owasp === 'A07', `实际 ${hardcoded.owasp}`);
  const xml = classifyFinding({ summary: 'Consider possible security implications of xml parsing' }, 'bandit');
  check('T4 xml → A05', xml.owasp === 'A05', `实际 ${xml.owasp}`);
  check('T4 xml → 补充类 xxe', xml.supplement === 'xxe', `实际 ${xml.supplement}`);
  const dep = classifyFinding({ summary: 'Prototype Pollution' }, 'npm-audit');
  check('T4 npm audit → A06', dep.owasp === 'A06', `实际 ${dep.owasp}`);
}

// --- T5：扫描三形态 ---
{
  const bandit = parseScan({ results: [{ issue_text: 'x', issue_severity: 'HIGH' }] }, 'bandit.json');
  check('T5 bandit 形态 tool=bandit', bandit.tool === 'bandit');
  check('T5 bandit 形态 finding 数=1', bandit.findings.length === 1);
  const npmAudit = parseScan({ vulnerabilities: { lodash: { severity: 'high' } } }, 'npm.json');
  check('T5 npm audit 形态 tool=npm-audit', npmAudit.tool === 'npm-audit');
  const status = parseScan({ tool: 'bandit', status: 'unavailable', reason: '装不上' }, 'st.json');
  check('T5 扫描状态形态 status=unavailable', status.status === 'unavailable');
  check('T5 扫描状态形态 finding 数=0', status.findings.length === 0);
  let threw = false;
  try {
    parseScan({ foo: 1 }, 'x.json');
  } catch (err) {
    threw = err instanceof InputError;
  }
  check('T5 无法识别的扫描结果报错', threw);
}

// --- T6：覆盖诚实性（十类 / 四类逐类有交代；不出现自相矛盾）---
{
  const ctx = normalize(baseContext());
  const derived = deriveThreats(ctx, { status: 'not_provided', tool: null, findings: [], kind: 'none', reason: '', sourceFile: '' }, { actions: [], ids: new Set(), count: 0 });
  const keys = Object.keys(derived.owaspCoverage);
  check('T6 OWASP 键集恰为 A01~A10', keys.length === 10 && keys.every((key, index) => key === `A0${index + 1}` || key === 'A10'), keys.join(','));
  check('T6 四类补充键集齐', Object.keys(derived.supplements).length === 4);
  for (const [code, entry] of Object.entries(derived.owaspCoverage)) {
    check(`T6 ${code} 有交代`, entry.status === 'covered' || entry.status === 'not_applicable');
    if (entry.status === 'not_applicable') {
      check(`T6 ${code} 不适用带理由`, typeof entry.reason === 'string' && entry.reason.trim() !== '');
      check(`T6 ${code} 不适用带未决问题`, Boolean(entry.open_question_ref));
      const actual = derived.threats.filter((threat) => threat.owasp === code);
      check(`T6 ${code} 不适用却没有该类威胁`, actual.length === 0, `实际 ${actual.length} 条`);
    } else {
      const actual = derived.threats.filter((threat) => threat.owasp === code).map((threat) => threat.id);
      check(`T6 ${code} covered 的 threat_refs 恰为该类全部威胁`,
        JSON.stringify([...entry.threat_refs].sort()) === JSON.stringify([...actual].sort()));
    }
  }
  for (const [key, entry] of Object.entries(derived.supplements)) {
    check(`T6 补充类 ${key} 有交代`, entry.status === 'covered' || entry.status === 'not_applicable');
    if (entry.status === 'not_applicable') {
      check(`T6 补充类 ${key} 不适用带理由`, typeof entry.reason === 'string' && entry.reason.trim() !== '');
    }
  }
}

// --- T7：矩阵缺口的双向对应 ---
{
  const ctx = normalize(baseContext());
  const derived = deriveThreats(ctx, { status: 'not_provided', tool: null, findings: [], kind: 'none', reason: '', sourceFile: '' }, { actions: [], ids: new Set(), count: 0 });
  const matrix = deriveMatrix(ctx, derived.threats);
  const gaps = matrix.entries.filter((entry) => entry.basis === 'gap');
  const eop = derived.threats.filter((threat) => threat.category === 'elevation_of_privilege');
  check('T7 存在越权类威胁', eop.length >= 1);
  check('T7 越权类威胁都被 gap 引用', eop.every((threat) => gaps.some((entry) => entry.threat_ref === threat.id)));
  check('T7 gap 条目 decision=allow', gaps.every((entry) => entry.decision === 'allow'));
  check('T7 gap 条目都指向越权类威胁', gaps.every((entry) => {
    const threat = derived.threats.find((one) => one.id === entry.threat_ref);
    return threat && threat.category === 'elevation_of_privilege';
  }));
  const pairs = new Set(matrix.entries.map((entry) => `${entry.role}|${entry.resource}`));
  const covered = matrix.roles.every((role) => matrix.resources.every((resource) => pairs.has(`${role.id}|${resource.id}`)));
  check('T7 每个 (role, resource) 组合至少一条', covered);
  check('T7 expected 条目不带 threat_ref', matrix.entries.filter((entry) => entry.basis === 'expected').every((entry) => entry.threat_ref === null));
}

// --- T8：用例 id 分配避开输入集占用号 + 全局唯一 ---
{
  const used = new Set(['TC-001', 'TC-002', 'TC-003']);
  const ids = [allocateCaseId(used), allocateCaseId(used), allocateCaseId(used)];
  check('T8 避开输入集占用号', ids.every((id) => !['TC-001', 'TC-002', 'TC-003'].includes(id)), ids.join(','));
  check('T8 分配的号唯一', new Set(ids).size === ids.length);
  check('T8 分配的号合 ^TC-\\d{3}$', ids.every((id) => /^TC-\d{3}$/.test(id)));
}

// --- T9：派生出的用例覆盖每条威胁，且 tag 含 security 与威胁 id ---
{
  const ctx = normalize(baseContext());
  const derived = deriveThreats(ctx, { status: 'not_provided', tool: null, findings: [], kind: 'none', reason: '', sourceFile: '' }, { actions: [], ids: new Set(), count: 0 });
  const suites = deriveSuites(ctx, derived.threats, { generatedAt: '2026-01-01T00:00:00.000Z', usedIds: new Set() });
  const allCases = suites.flatMap((suite) => suite.casesDoc.cases);
  check('T9 每条威胁至少一条用例', derived.threats.every((threat) => allCases.some((item) => item.tags.includes(threat.id))));
  check('T9 用例 tag 含 security', allCases.every((item) => item.tags.includes('security')));
  check('T9 用例 dimension 恒为 security', allCases.every((item) => item.dimension === 'security'));
  check('T9 用例 status 恒为 active', allCases.every((item) => item.status === 'active' && item.revision === undefined));
  check('T9 顶层字段集恰好 7 个', suites.every((suite) => Object.keys(suite.casesDoc).length === 7));
  check('T9 套件目录名合规', suites.every((suite) => /^SEC-\d{3}-[a-z0-9][a-z0-9-]*$/.test(suite.name)));
}

// --- T10 / T11 / T12：端到端（幂等 / 非法输入不留产物 / 产物已存在即报错）---
{
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'security-plan-selftest-'));
  const maker = path.join(HERE, 'make-security-plan.mjs');
  const contextFile = path.join(work, 'context.json');
  fs.writeFileSync(contextFile, `${JSON.stringify(baseContext(), null, 2)}\n`, 'utf8');
  const makeProject = (name) => {
    const dir = path.join(work, name);
    fs.mkdirSync(path.join(dir, 'test-assets', 'environments'), { recursive: true });
    fs.writeFileSync(
      path.join(dir, 'test-assets', 'environments', 'local.json'),
      `${JSON.stringify({ name: 'local', base_url: 'http://127.0.0.1:8080', timeout_ms: 5000, retries: 0, credentials: {} }, null, 2)}\n`,
      'utf8',
    );
    return dir;
  };
  const runMaker = (args) => spawnSync(process.execPath, [maker, ...args], { encoding: 'utf8' });

  const projA = makeProject('proj-a');
  const projB = makeProject('proj-b');
  const first = runMaker(['--context', contextFile, '--out-dir', projA]);
  const second = runMaker(['--context', contextFile, '--out-dir', projB]);
  check('T10 第一次跑成功', first.status === 0, first.stderr);
  check('T10 第二次跑成功', second.status === 0, second.stderr);

  const strip = (text) => text.replace(/"generated_at": "[^"]*"/g, '"generated_at": "<STAMP>"');
  const modelA = strip(fs.readFileSync(path.join(projA, 'test-assets', 'security', 'threat-model.json'), 'utf8'));
  const modelB = strip(fs.readFileSync(path.join(projB, 'test-assets', 'security', 'threat-model.json'), 'utf8'));
  check('T10 两次产物除 generated_at 外逐字相同', modelA === modelB);
  const matrixA = strip(fs.readFileSync(path.join(projA, 'test-assets', 'security', 'matrix.json'), 'utf8'));
  const matrixB = strip(fs.readFileSync(path.join(projB, 'test-assets', 'security', 'matrix.json'), 'utf8'));
  check('T10 两次矩阵除 generated_at 外逐字相同', matrixA === matrixB);

  // 非法输入 ⇒ rc=1 且不留半份产物
  const badFile = path.join(work, 'bad-context.json');
  const bad = baseContext();
  delete bad.assets;
  fs.writeFileSync(badFile, `${JSON.stringify(bad, null, 2)}\n`, 'utf8');
  const projBad = makeProject('proj-bad');
  const badRun = runMaker(['--context', badFile, '--out-dir', projBad]);
  check('T11 非法输入 rc=1', badRun.status === 1, `实际 ${badRun.status}`);
  check('T11 非法输入点名字段', (badRun.stderr || '').includes('assets'), badRun.stderr);
  const secBad = path.join(projBad, 'test-assets', 'security');
  check('T11 非法输入不留半份产物',
    !fs.existsSync(path.join(secBad, 'threat-model.json')) &&
    !fs.existsSync(path.join(secBad, 'matrix.json')) &&
    !fs.existsSync(path.join(secBad, 'suites')));

  // 产物已存在 ⇒ rc=1 且不覆盖
  const placeholder = path.join(secBad, 'threat-model.json');
  fs.mkdirSync(secBad, { recursive: true });
  fs.writeFileSync(placeholder, 'PLACEHOLDER\n', 'utf8');
  const again = runMaker(['--context', contextFile, '--out-dir', projBad]);
  check('T12 产物已存在 rc=1', again.status === 1, `实际 ${again.status}`);
  check('T12 产物已存在不覆盖', fs.readFileSync(placeholder, 'utf8') === 'PLACEHOLDER\n');

  fs.rmSync(work, { recursive: true, force: true });
}

if (failures.length > 0) {
  console.error(`[fail] 自测未通过：${failures.length} 条断言失败（共 ${passed + failures.length} 条）`);
  for (const failure of failures) console.error(`  · ${failure}`);
  process.exitCode = 1;
} else {
  console.log(`[ok] 自测全部通过：${passed} 条断言`);
}
