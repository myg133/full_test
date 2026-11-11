#!/usr/bin/env node
// cycle-state.mjs — 轮次状态推进器（状态写入权的收口点）
//
// 用法: node scripts/cycle-state.mjs <子命令> <轮次目录> [参数...]
//   路径相对当前工作目录；也可直接给到 cycle.json 文件。
//   在本仓库内等价于: node skills/test-case-design/scripts/cycle-state.mjs ...
//
// 退出码: 0 = 成功, 1 = 校验失败或非法转移, 2 = 调用方式错误
//
// 硬约束: cycle.json / cycles/index.json 的状态写入只允许经由本脚本。
//         agent 不得直接编辑这两个文件。
//
// 纯 Node.js，只依赖 node: 内置模块，无第三方依赖。
// 状态机规则（枚举 / 转移表 / 终态 / status↔history 一致性）来自
// scripts/lib/state-machine.mjs，本文件不另立一份。

import {
  closeSync,
  existsSync,
  fsyncSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import process from 'node:process';

import {
  CYCLE_SCOPES,
  CYCLE_STATUSES,
  ROUND_TYPES,
  ROUNDS,
  STAGE_STATUSES,
  allowedNext,
  canTransition,
  checkCycleState,
  isCycleStatus,
  isObject,
  isStageStatus,
  isTerminalStatus,
  transitionError,
} from './lib/state-machine.mjs';

// ---------------------------------------------------------------- CLI 骨架

/** 子命令的参数表：value = 需要取值的参数（可重复的标在 repeat 里） */
const COMMAND_SPECS = {
  init: { value: ['cycle-id', 'round', 'round-type', 'requirement', 'scope', 'by'], repeat: ['scope'] },
  show: { value: [] },
  advance: { value: ['to', 'by', 'reason'] },
  'skip-scope': { value: ['scope', 'reason'] },
  'set-stage': { value: ['stage', 'status', 'artifacts'] },
};

const USAGE = [
  '用法: node scripts/cycle-state.mjs <子命令> <轮次目录> [参数...] [--json]',
  '',
  '子命令:',
  '  init       创建新轮次骨架',
  '             --cycle-id <id> --round <R1|R2|R3> --round-type <类型> --requirement <需求编号>',
  '             --scope <scope>（可重复） --by <agent>',
  '  show       读当前状态：status / history / stages / 允许的下一步',
  '  advance    推进轮次状态  --to <状态> --by <agent> [--reason <文本>]',
  '  skip-scope 记录本轮跳过的 scope  --scope <scope> --reason <文本>',
  '  set-stage  设置阶段状态  --stage <名称> --status <状态> [--artifacts a,b]',
  '',
  '通用参数: --json 输出机器可读 JSON（缺省输出人读文本）',
].join('\n');

/** 命令执行期间的上下文（用于报错与输出） */
let context = { command: null, json: false };

/** 带退出码的 CLI 错误 */
class CliError extends Error {
  /**
   * @param {string} message 完整诊断信息（含文件路径 / 字段路径 / 问题 / 修法）
   * @param {number} code 退出码：1 = 校验失败，2 = 调用方式错误
   * @param {string|null} field 字段路径
   * @param {object[]} problems 结构化问题列表
   */
  constructor(message, code, field = null, problems = []) {
    super(message);
    this.code = code;
    this.field = field;
    this.problems = problems;
  }
}

/**
 * 校验失败：目标文件不得被修改，退出码 1。
 * @param {string} message 诊断信息
 * @param {string|null} field 字段路径
 * @param {object[]} problems 结构化问题列表
 */
function failValidation(message, field = null, problems = []) {
  throw new CliError(message, 1, field, problems);
}

/**
 * 调用方式错误：退出码 2。
 * @param {string} message 诊断信息
 */
function failUsage(message) {
  throw new CliError(message, 2);
}

/**
 * 写人读输出。
 * @param {string} text 文本
 */
function writeOut(text) {
  process.stdout.write(text);
}

/**
 * 写机器可读输出（合法 JSON）。
 * @param {object} payload 数据
 */
function writeJson(payload) {
  writeOut(`${JSON.stringify(payload, null, 2)}\n`);
}

// ---------------------------------------------------------------- 参数解析

/**
 * 解析命令行参数。
 * @param {string[]} args 参数数组
 * @param {{value: string[], repeat: string[]}} spec 参数表
 * @returns {{flags: Map<string, any>, positionals: string[]}}
 */
function parseArgs(args, spec) {
  const flags = new Map();
  const positionals = [];
  const repeatable = spec.repeat || [];
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === '--') {
      positionals.push(...args.slice(i + 1));
      break;
    }
    if (!arg.startsWith('--')) {
      positionals.push(arg);
      continue;
    }
    const eq = arg.indexOf('=');
    const name = eq === -1 ? arg.slice(2) : arg.slice(2, eq);
    if (name === 'json') {
      if (eq !== -1) failUsage('--json 不接受取值');
      flags.set('json', true);
      continue;
    }
    if (!spec.value.includes(name)) {
      failUsage(`未知参数 --${name}（${context.command} 支持的参数: ${spec.value.join(' / ')}）`);
    }
    let value;
    if (eq !== -1) {
      value = arg.slice(eq + 1);
    } else {
      if (i + 1 >= args.length) failUsage(`参数 --${name} 缺少取值`);
      value = args[i + 1];
      i += 1;
    }
    if (repeatable.includes(name)) {
      const list = flags.get(name) || [];
      list.push(value);
      flags.set(name, list);
    } else {
      flags.set(name, value);
    }
  }
  return { flags, positionals };
}

/**
 * 取必填参数：缺失 → 调用方式错误（退出码 2）；取值为空 → 校验失败（退出码 1）。
 * @param {Map<string, any>} flags 参数表
 * @param {string} name 参数名
 * @returns {string} 去空白后的取值
 */
function requireFlag(flags, name) {
  const raw = flags.get(name);
  if (raw === undefined) failUsage(`缺少必填参数 --${name}`);
  const value = String(raw).trim();
  if (value === '') failValidation(`参数 --${name} 的取值不能为空`, name);
  return value;
}

// ---------------------------------------------------------------- 文件读写

/**
 * 原子写：先写临时文件，再 rename 替换。
 * 中途失败不留半写文件，也不留临时文件残留。
 * @param {string} file 目标文件绝对路径
 * @param {any} data 要写入的数据
 */
function writeJsonAtomic(file, data) {
  const text = `${JSON.stringify(data, null, 2)}\n`;
  const dir = dirname(file);
  const tmp = join(dir, `.${basename(file)}.tmp-${process.pid}-${Date.now()}`);
  let fd = null;
  try {
    fd = openSync(tmp, 'wx', 0o644);
    writeFileSync(fd, text, 'utf8');
    fsyncSync(fd);
    closeSync(fd);
    fd = null;
    renameSync(tmp, file);
  } catch (err) {
    if (fd !== null) {
      try {
        closeSync(fd);
      } catch {
        // 关闭失败不影响后续清理
      }
    }
    try {
      unlinkSync(tmp);
    } catch {
      // 临时文件可能尚未创建
    }
    throw err;
  }
}

/**
 * 解析轮次目标路径。
 * @param {string} pathArg 命令行给出的路径
 * @returns {{dir: string, file: string}}
 */
function resolveTarget(pathArg) {
  const abs = resolve(pathArg);
  const dir = basename(abs) === 'cycle.json' ? dirname(abs) : abs;
  return { dir, file: join(dir, 'cycle.json') };
}

/**
 * 读取并解析 cycle.json。文件缺失或不可解析 → 校验失败（不修改任何内容）。
 * @param {string} file cycle.json 绝对路径
 * @returns {object} 解析结果
 */
function loadCycle(file) {
  if (!existsSync(file)) {
    failValidation(`${file}: 轮次文件不存在：先用 init 创建轮次，或检查路径是否正确`);
  }
  let raw;
  try {
    raw = readFileSync(file, 'utf8');
  } catch (err) {
    failValidation(`${file}: 无法读取文件 — ${err.message}`);
  }
  let data;
  try {
    data = JSON.parse(raw);
  } catch (err) {
    failValidation(`${file}: JSON 语法错误，解析失败 — ${err.message}`);
  }
  if (!isObject(data)) failValidation(`${file}: 根节点必须是 JSON 对象`);
  return data;
}

/**
 * 定位轮次索引目录：轮次目录的父目录名为 cycles 时才维护 index.json。
 * @param {string} cycleDir 轮次目录绝对路径
 * @returns {string|null} 索引目录
 */
function cyclesDirFor(cycleDir) {
  const parent = dirname(cycleDir);
  return basename(parent) === 'cycles' ? parent : null;
}

/**
 * 预检 index.json：结构非法时提前失败，避免动过 cycle.json 才发现索引写不了。
 * @param {string} cyclesDir 索引目录
 * @returns {object|null} 解析结果（不存在时为 null）
 */
function readIndex(cyclesDir) {
  const file = join(cyclesDir, 'index.json');
  if (!existsSync(file)) return null;
  let raw;
  try {
    raw = readFileSync(file, 'utf8');
  } catch (err) {
    failValidation(`${file}: 无法读取文件 — ${err.message}`);
  }
  let data;
  try {
    data = JSON.parse(raw);
  } catch (err) {
    failValidation(`${file}: JSON 语法错误，解析失败 — ${err.message}`);
  }
  if (!isObject(data) || !Array.isArray(data.cycles)) {
    failValidation(`${file}: 结构非法：根节点必须是对象且含 cycles 数组`);
  }
  return data;
}

/**
 * 同步轮次索引：index.json 是全局视图，状态字段与 cycle.json 保持一致。
 * @param {string} cyclesDir 索引目录
 * @param {{id: string, round: any, status: string}} entry 本轮次摘要
 */
function syncIndex(cyclesDir, entry) {
  const file = join(cyclesDir, 'index.json');
  const data = readIndex(cyclesDir) || { cycles: [] };
  const existing = data.cycles.find((item) => isObject(item) && item.id === entry.id);
  if (existing) {
    existing.round = entry.round;
    existing.status = entry.status;
  } else {
    data.cycles.push({ id: entry.id, round: entry.round, status: entry.status });
  }
  writeJsonAtomic(file, data);
}

// ---------------------------------------------------------------- 公共检查

/**
 * 轮次文件的状态机问题清单（与校验器共用同一套判定）。
 * @param {object} data cycle.json 解析结果
 * @param {string} file cycle.json 绝对路径
 * @returns {{kind: string, path: string, text: string}[]}
 */
function stateIssues(data, file) {
  return checkCycleState(data).map((issue) => ({
    ...issue,
    text: `${file}: ${issue.path}: ${issue.text}`,
  }));
}

/**
 * 状态机问题非空时拒绝继续（失败零副作用）。
 * @param {object} data cycle.json 解析结果
 * @param {string} file cycle.json 绝对路径
 */
function refuseOnStateIssues(data, file) {
  const issues = stateIssues(data, file);
  if (issues.length === 0) return;
  const message = issues.map((issue) => issue.text).join('\n');
  failValidation(
    `${message}\n修法: 先修好上面列出的状态问题（status 与 history 必须自洽），再执行本命令`,
    'status',
    issues.map((issue) => ({ field: issue.path, message: issue.text })),
  );
}

// ---------------------------------------------------------------- 子命令

/**
 * init：创建新轮次骨架。
 * @param {{dir: string, file: string}} target 轮次目标
 * @param {Map<string, any>} flags 参数表
 */
function cmdInit(target, flags) {
  const cycleId = requireFlag(flags, 'cycle-id');
  const round = requireFlag(flags, 'round');
  const roundType = requireFlag(flags, 'round-type');
  const requirement = requireFlag(flags, 'requirement');
  const by = requireFlag(flags, 'by');
  const rawScopes = flags.get('scope') || [];
  if (!Array.isArray(rawScopes)) failUsage('--scope 可重复传入，但取值必须逐个给出');
  const scopes = rawScopes.map((item) => String(item).trim()).filter((item) => item !== '');

  if (existsSync(target.file)) {
    failValidation(
      `${target.file}: 轮次已存在：init 不覆盖已有 cycle.json（改状态请用 advance / set-stage）`,
    );
  }
  const dirName = basename(target.dir);
  if (cycleId !== dirName) {
    failValidation(
      `${target.file}: cycle_id "${cycleId}" 与轮次目录名 "${dirName}" 不一致：` +
        '目录契约要求轮次目录名 = cycle_id（要么改目录名，要么改 --cycle-id）',
      'cycle_id',
    );
  }
  if (!ROUNDS.includes(round)) {
    failValidation(
      `${target.file}: round 取值非法："${round}"（允许值: ${ROUNDS.join(' / ')}）`,
      'round',
    );
  }
  if (!ROUND_TYPES.includes(roundType)) {
    failValidation(
      `${target.file}: round_type 取值非法："${roundType}"（允许值: ${ROUND_TYPES.join(' / ')}）`,
      'round_type',
    );
  }
  for (const scope of scopes) {
    if (!CYCLE_SCOPES.includes(scope)) {
      failValidation(
        `${target.file}: scopes 取值非法："${scope}"（允许值: ${CYCLE_SCOPES.join(' / ')}）`,
        'scopes',
      );
    }
  }

  const cyclesDir = cyclesDirFor(target.dir);
  if (cyclesDir) readIndex(cyclesDir); // 预检：索引结构非法时先失败，不留半成品

  mkdirSync(target.dir, { recursive: true });
  const data = {
    cycle_id: cycleId,
    requirement,
    round,
    round_type: roundType,
    status: 'planned',
    scopes,
    scopes_skipped: [],
    stages: {
      clarify: { status: 'pending' },
      design: { status: 'pending' },
      data: { status: 'pending' },
      execute: { status: 'pending' },
      triage: { status: 'pending' },
      report: { status: 'pending' },
    },
    trigger: { type: 'requirement', ref: requirement },
    history: [
      {
        at: new Date().toISOString(),
        from: 'planned',
        to: 'planned',
        by,
        event: 'created',
      },
    ],
  };
  writeJsonAtomic(target.file, data);
  if (cyclesDir) syncIndex(cyclesDir, { id: cycleId, round, status: 'planned' });

  writeResult({
    command: 'init',
    target,
    status: 'planned',
    changed: true,
    extra: { cycle_id: cycleId, requirement, history: data.history },
  });
}

/**
 * show：读当前状态与允许的下一步。
 * @param {{dir: string, file: string}} target 轮次目标
 */
function cmdShow(target) {
  const data = loadCycle(target.file);
  const issues = checkCycleState(data);
  const payload = {
    ok: issues.length === 0,
    command: 'show',
    cycle_dir: target.dir,
    cycle_file: target.file,
    cycle_id: typeof data.cycle_id === 'string' ? data.cycle_id : null,
    requirement: typeof data.requirement === 'string' ? data.requirement : null,
    status: typeof data.status === 'string' ? data.status : null,
    allowed_next: allowedNext(data.status),
    terminal: isTerminalStatus(data.status),
    history: Array.isArray(data.history) ? data.history : [],
    stages: isObject(data.stages) ? data.stages : {},
    scopes: Array.isArray(data.scopes) ? data.scopes : [],
    scopes_skipped: Array.isArray(data.scopes_skipped) ? data.scopes_skipped : [],
    problems: issues.map((issue) => ({ field: issue.path, message: issue.text })),
  };

  if (context.json) {
    writeJson(payload);
  } else {
    writeOut(renderShowText(payload, target));
  }
  if (issues.length > 0) process.exitCode = 1;
}

/**
 * advance：推进轮次状态。status 与 history 在同一次写入里完成。
 * @param {{dir: string, file: string}} target 轮次目标
 * @param {Map<string, any>} flags 参数表
 */
function cmdAdvance(target, flags) {
  const to = requireFlag(flags, 'to');
  const by = requireFlag(flags, 'by');
  const rawReason = flags.get('reason');

  const data = loadCycle(target.file);
  refuseOnStateIssues(data, target.file);

  const from = data.status;
  if (!isCycleStatus(to)) {
    failValidation(
      `${target.file}: status 取值非法："${to}"（允许值: ${CYCLE_STATUSES.join(' / ')}）`,
      'status',
    );
  }
  if (to === from) {
    writeResult({
      command: 'advance',
      target,
      status: from,
      changed: false,
      message: `轮次已处于 "${from}"：未做任何修改（幂等，不追加 history）`,
      extra: { history: data.history },
    });
    return;
  }
  if (!canTransition(from, to)) {
    failValidation(`${target.file}: status: ${transitionError(from, to)}`, 'status');
  }

  const cyclesDir = cyclesDirFor(target.dir);
  if (cyclesDir) readIndex(cyclesDir); // 预检索引，避免动过 cycle.json 才发现索引写不了

  data.status = to;
  const entry = { at: new Date().toISOString(), from, to, by };
  const reason = typeof rawReason === 'string' ? rawReason.trim() : '';
  if (reason !== '') entry.reason = reason;
  data.history.push(entry);
  writeJsonAtomic(target.file, data);
  if (cyclesDir && typeof data.cycle_id === 'string' && data.cycle_id !== '') {
    syncIndex(cyclesDir, { id: data.cycle_id, round: data.round, status: to });
  }

  writeResult({
    command: 'advance',
    target,
    status: to,
    changed: true,
    extra: { history: data.history, entry },
  });
}

/**
 * skip-scope：记录本轮跳过的 scope。理由必须非空。
 * @param {{dir: string, file: string}} target 轮次目标
 * @param {Map<string, any>} flags 参数表
 */
function cmdSkipScope(target, flags) {
  const scope = requireFlag(flags, 'scope');
  const rawReason = flags.get('reason');
  if (typeof rawReason !== 'string' || rawReason.trim() === '') {
    failValidation(
      `${target.file}: scopes_skipped[].reason: 跳过必须写明可被 review 发现的理由：` +
        '--reason 缺失或为空均拒绝，文件未被修改',
      'scopes_skipped[].reason',
    );
  }
  const reason = rawReason.trim();
  if (!CYCLE_SCOPES.includes(scope)) {
    failValidation(
      `${target.file}: scopes_skipped[].scope: scope 取值非法："${scope}"` +
        `（允许值: ${CYCLE_SCOPES.join(' / ')}）`,
      'scopes_skipped[].scope',
    );
  }

  const data = loadCycle(target.file);
  if (!Array.isArray(data.scopes_skipped)) data.scopes_skipped = [];
  const existing = data.scopes_skipped.find((item) => isObject(item) && item.scope === scope);

  if (existing && existing.reason === reason) {
    writeResult({
      command: 'skip-scope',
      target,
      status: typeof data.status === 'string' ? data.status : null,
      changed: false,
      message: `scope "${scope}" 已记录且理由未变：未做任何修改（幂等）`,
      extra: { scopes_skipped: data.scopes_skipped },
    });
    return;
  }

  if (existing) existing.reason = reason;
  else data.scopes_skipped.push({ scope, reason });
  writeJsonAtomic(target.file, data);

  writeResult({
    command: 'skip-scope',
    target,
    status: typeof data.status === 'string' ? data.status : null,
    changed: true,
    extra: { scopes_skipped: data.scopes_skipped },
  });
}

/**
 * set-stage：设置阶段状态。
 * @param {{dir: string, file: string}} target 轮次目标
 * @param {Map<string, any>} flags 参数表
 */
function cmdSetStage(target, flags) {
  const stage = requireFlag(flags, 'stage');
  const status = requireFlag(flags, 'status');
  const rawArtifacts = flags.get('artifacts');
  let artifacts;
  if (typeof rawArtifacts === 'string') {
    artifacts = rawArtifacts
      .split(',')
      .map((item) => item.trim())
      .filter((item) => item !== '');
  }
  if (!isStageStatus(status)) {
    failValidation(
      `${target.file}: stages.${stage}.status: status 取值非法："${status}"` +
        `（允许值: ${STAGE_STATUSES.join(' / ')}）`,
      `stages.${stage}.status`,
    );
  }

  const data = loadCycle(target.file);
  if (!isObject(data.stages)) data.stages = {};
  const current = data.stages[stage];
  const currentStatus = isObject(current) ? current.status : undefined;
  const artifactsSame =
    artifacts === undefined ||
    (isObject(current) &&
      Array.isArray(current.artifacts) &&
      current.artifacts.length === artifacts.length &&
      current.artifacts.every((item, index) => item === artifacts[index]));

  if (currentStatus === status && artifactsSame) {
    writeResult({
      command: 'set-stage',
      target,
      status: typeof data.status === 'string' ? data.status : null,
      changed: false,
      message: `阶段 "${stage}" 已是 "${status}"：未做任何修改（幂等）`,
      extra: { stages: data.stages },
    });
    return;
  }

  const next = isObject(current) ? { ...current } : {};
  next.status = status;
  if (artifacts !== undefined) next.artifacts = artifacts;
  data.stages[stage] = next;
  writeJsonAtomic(target.file, data);

  writeResult({
    command: 'set-stage',
    target,
    status: typeof data.status === 'string' ? data.status : null,
    changed: true,
    extra: { stages: data.stages },
  });
}

// ---------------------------------------------------------------- 输出渲染

/**
 * 渲染 show 的人读输出。
 * @param {object} payload show 的数据
 * @param {{dir: string, file: string}} target 轮次目标
 * @returns {string} 文本
 */
function renderShowText(payload, target) {
  const lines = [];
  lines.push(`轮次: ${payload.cycle_file}`);
  lines.push(`状态: ${payload.status === null ? '（缺失）' : payload.status}`);
  lines.push(
    `允许的下一步: ${payload.allowed_next.length > 0 ? payload.allowed_next.join(' / ') : '（无：终态不可离开）'}`,
  );
  lines.push(`history 条数: ${payload.history.length}`);
  for (const [index, item] of payload.history.entries()) {
    const parts = [`${index + 1}. ${item.from} → ${item.to}`];
    if (item.by) parts.push(`by ${item.by}`);
    if (item.at) parts.push(`at ${item.at}`);
    if (item.reason) parts.push(`reason ${item.reason}`);
    lines.push(parts.join('  '));
  }
  const stageNames = Object.keys(payload.stages);
  lines.push(`stages: ${stageNames.length > 0 ? stageNames.join(' / ') : '（无）'}`);
  for (const name of stageNames) {
    const body = payload.stages[name];
    lines.push(`  - ${name}: ${isObject(body) ? body.status : '（非法）'}`);
  }
  for (const issue of payload.problems) {
    lines.push(`[FAIL] ${target.file}: ${issue.field}: ${issue.message}`);
  }
  return `${lines.join('\n')}\n`;
}

/**
 * 渲染写操作的结果。
 * @param {object} spec 结果描述
 */
function writeResult(spec) {
  const payload = {
    ok: true,
    command: spec.command,
    cycle_dir: spec.target.dir,
    cycle_file: spec.target.file,
    status: spec.status,
    allowed_next: allowedNext(spec.status),
    changed: spec.changed,
    ...(spec.message ? { message: spec.message } : {}),
    ...(spec.extra || {}),
  };
  if (context.json) {
    writeJson(payload);
    return;
  }
  const lines = [];
  lines.push(`[OK] ${spec.command}: ${spec.target.file}`);
  if (spec.status) lines.push(`状态: ${spec.status}`);
  if (spec.message) lines.push(spec.message);
  else if (spec.changed) lines.push('已写入（原子写：临时文件 + rename）');
  else lines.push('未做任何修改');
  writeOut(`${lines.join('\n')}\n`);
}

// ---------------------------------------------------------------- 主流程

/**
 * 执行子命令。
 * @param {string[]} argv 命令行参数
 */
function dispatch(argv) {
  const command = argv[0];
  context.command = command;
  const spec = COMMAND_SPECS[command];
  const { flags, positionals } = parseArgs(argv.slice(1), spec);
  context.json = flags.get('json') === true;

  if (positionals.length === 0) {
    failUsage(`子命令 ${command} 缺少轮次目录参数\n${USAGE}`);
  }
  if (positionals.length > 1) {
    failUsage(`子命令 ${command} 只接受一个轮次目录参数，多余参数: ${positionals.slice(1).join(' / ')}`);
  }
  const target = resolveTarget(positionals[0]);

  if (command === 'init') cmdInit(target, flags);
  else if (command === 'show') cmdShow(target);
  else if (command === 'advance') cmdAdvance(target, flags);
  else if (command === 'skip-scope') cmdSkipScope(target, flags);
  else if (command === 'set-stage') cmdSetStage(target, flags);
}

function main() {
  const argv = process.argv.slice(2);
  if (argv.length === 0) {
    process.stderr.write(`${USAGE}\n`);
    process.exitCode = 2;
    return;
  }
  if (argv[0] === '--help' || argv[0] === '-h' || argv[0] === 'help') {
    writeOut(`${USAGE}\n`);
    return;
  }
  const command = argv[0];
  if (!Object.prototype.hasOwnProperty.call(COMMAND_SPECS, command)) {
    process.stderr.write(`未知子命令 "${command}"\n${USAGE}\n`);
    process.exitCode = 2;
    return;
  }

  try {
    dispatch(argv);
  } catch (err) {
    if (err instanceof CliError) {
      if (context.json) {
        writeJson({
          ok: false,
          command: context.command,
          error: err.message,
          field: err.field,
          problems: err.problems,
          exit_code: err.code,
        });
      } else {
        const lines = err.message.split('\n').map((line) => `[FAIL] ${line}`);
        writeOut(`${lines.join('\n')}\n`);
        process.stderr.write(`${lines.join('\n')}\n`);
      }
      process.exitCode = err.code;
      return;
    }
    const message = err && err.message ? err.message : String(err);
    if (context.json) {
      writeJson({
        ok: false,
        command: context.command,
        error: `未预期的错误: ${message}`,
        exit_code: 1,
      });
    } else {
      const line = `[FAIL] 未预期的错误: ${message}`;
      writeOut(`${line}\n`);
      process.stderr.write(`${line}\n`);
    }
    process.exitCode = 1;
  }
}

main();
