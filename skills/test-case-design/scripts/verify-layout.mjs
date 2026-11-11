#!/usr/bin/env node
// verify-layout.mjs — 项目级测试资产目录契约校验器
//
// 用法: node scripts/verify-layout.mjs [project-root]
//   上面这个路径相对本 skill 目录（skills/test-case-design/scripts/verify-layout.mjs）。
//   在本仓库内等价于: node skills/test-case-design/scripts/verify-layout.mjs [project-root]
// 退出码: 0 = 契约通过, 1 = 存在违规, 2 = 调用方式错误
//
// 纯 Node.js 实现，只依赖 node: 内置模块。
// 只读取文件：不写入、不修改、不删除任何内容，因此可重复执行（幂等）。
// 报错信息面向"要自我修复的执行者"：每条都带文件路径 + 字段路径 + 可操作的说明。

import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { basename, dirname, join, relative, resolve, sep } from 'node:path';
import process from 'node:process';

// 状态机规则的**单一来源**：本文件不得自带第二份转移表 / 终态判定 /
// status↔history 一致性判定，一律 import 复用（见 scripts/lib/state-machine.mjs）。
import {
  CYCLE_STATUSES,
  ROUNDS,
  checkCycleConsistency,
  indexEntryMismatches,
} from './lib/state-machine.mjs';

// ---------------------------------------------------------------- 常量

const ASSETS_DIR = 'test-assets';
const ENV_DIR_REL = 'test-assets/environments';
const CYCLES_DIR_REL = 'test-assets/cycles';
const ARTIFACTS_DIR = '.test-artifacts';

const ENV_SCHEMA_REL = `${ENV_DIR_REL}/_schema.json`;
const ENV_INDEX_REL = `${CYCLES_DIR_REL}/index.json`;

// 环境配置的契约基线：必填字段、字段类型、允许的顶层字段
const ENV_REQUIRED = ['name', 'base_url', 'timeout_ms', 'credentials'];
const ENV_FIELD_TYPES = {
  name: 'string',
  base_url: 'string',
  timeout_ms: 'integer',
  retries: 'integer',
  credentials: 'object',
  headers: 'object',
  verify_tls: 'boolean',
  data_fixtures: 'array',
  driver: 'string',
};
const ENV_ALLOWED_FIELDS = Object.keys(ENV_FIELD_TYPES);
// 允许在环境配置里声明"用哪个驱动"（执行器实现由 test-execute skill 提供）
const ENV_DRIVER_VALUES = ['api', 'mock'];
// 项目自带的 _schema.json 可能还没写 driver（契约刚放开），
// 这些字段对项目 schema 而言算"契约已认可"，不按多余字段拦下
const ENV_TOLERATED_SCHEMA_KEYS = ['driver'];

// suite.json 的契约基线
const SUITE_REQUIRED = ['suite', 'requirement', 'scope', 'environment', 'cases_file', 'executor'];
const SUITE_SCOPES = ['functional', 'security', 'load'];
const SUITE_EXECUTORS = ['api', 'ui', 'load', 'security', 'mock'];
// suite.json 的顶层字段集是封闭的：出现表外字段（含 load_scenario / threat_model
// 这类 scope 专属字段）一律判 FAIL。语义与 environments 的顶层封闭集合一致。
const SUITE_ALLOWED_FIELDS = [
  'suite',
  'requirement',
  'scope',
  'environment',
  'cases_file',
  'executor',
  'base_url_from',
  'tags',
  'report',
];

// cycle.json 的契约基线
// 注意：轮次状态枚举、阶段状态枚举、scope 枚举、轮次编号/类型枚举与状态机规则
// 统一来自 scripts/lib/state-machine.mjs（单一来源），此处不再另立一份。

// 环境变量名形态：大写字母 / 下划线开头
const ENV_VAR_NAME_PATTERN = /^[A-Z_][A-Z0-9_]*$/;

// ---------------------------------------------------------------- 结果收集

const report = [];
const seenIssue = new Set();

function pass(text) {
  report.push({ ok: true, text });
}

function problem(text) {
  report.push({ ok: false, text });
}

/**
 * 登记一条"结构性问题"（同一文件内 kind+path 相同的只报一次）。
 * @param {string} rel 相对项目根的文件路径
 * @param {string} kind 问题类别：missing / type / extra / enum
 * @param {string} path 文件内的字段路径
 * @param {string} text 问题说明
 */
function addIssue(rel, kind, path, text) {
  const key = `${rel}|${kind}|${path}`;
  if (seenIssue.has(key)) return;
  seenIssue.add(key);
  problem(`${rel}: ${text}`);
}

// ---------------------------------------------------------------- 通用工具

function isObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isFilledString(value) {
  return typeof value === 'string' && value.trim() !== '';
}

function typeMatches(value, type) {
  switch (type) {
    case 'object':
      return isObject(value);
    case 'array':
      return Array.isArray(value);
    case 'string':
      return typeof value === 'string';
    case 'integer':
      return typeof value === 'number' && Number.isInteger(value);
    case 'number':
      return typeof value === 'number' && Number.isFinite(value);
    case 'boolean':
      return typeof value === 'boolean';
    case 'null':
      return value === null;
    default:
      return true;
  }
}

function describeType(value) {
  if (value === null) return 'null';
  if (Array.isArray(value)) return 'array';
  if (typeof value === 'number') return Number.isInteger(value) ? 'integer' : 'number';
  if (typeof value === 'undefined') return 'undefined';
  return typeof value;
}

function joinPath(base, key) {
  return base ? `${base}.${key}` : key;
}

function toSlash(path) {
  return path.split(sep).join('/');
}

function isDir(path) {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
}

function isFile(path) {
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
}

/**
 * 递归列出目录下的所有文件。
 * @param {string} dir 目录绝对路径
 * @param {string[]} out 收集结果
 * @returns {string[]} 文件绝对路径列表
 */
function listFiles(dir, out = []) {
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const entry of entries) {
    if (entry.name === '.git' || entry.name === 'node_modules') continue;
    const full = join(dir, entry.name);
    if (entry.isDirectory()) listFiles(full, out);
    else if (entry.isFile()) out.push(full);
  }
  return out;
}

/**
 * 读取并解析 JSON 文件；失败时直接登记问题并返回 null。
 * @param {string} file 文件绝对路径
 * @param {string} rel 相对项目根的文件路径（用于报错）
 * @returns {any|null} 解析结果
 */
function readJson(file, rel) {
  let raw;
  try {
    raw = readFileSync(file, 'utf8');
  } catch (err) {
    problem(`${rel}: 无法读取文件 — ${err.message}`);
    return null;
  }
  try {
    return JSON.parse(raw);
  } catch (err) {
    problem(`${rel}: JSON 语法错误，解析失败 — ${err.message}`);
    return null;
  }
}

// ---------------------------------------------------------------- JSON Schema 子集校验器

/**
 * 按 JSON Schema 的一个子集校验数据。
 *
 * 支持的关键字：type / required / properties / additionalProperties / items / enum。
 * 不支持 $ref / allOf / oneOf / anyOf / 条件分支等——本契约的 schema 只用到上面的子集。
 * 新增关键字时只需扩展这一个函数。
 *
 * @param {any} data 待校验数据
 * @param {object} schema schema 片段
 * @param {string} path 当前字段路径（根为 ''）
 * @returns {{kind: string, path: string, text: string}[]} 问题列表
 */
function validateAgainstSchema(data, schema, path = '', toleratedKeys = []) {
  const issues = [];
  if (!isObject(schema)) return issues;

  if (schema.type !== undefined) {
    const types = Array.isArray(schema.type) ? schema.type : [schema.type];
    if (!types.some((t) => typeMatches(data, t))) {
      issues.push({
        kind: 'type',
        path,
        text: `${path ? `${path} ` : ''}类型错误：期望 ${types.join(' / ')}，实际 ${describeType(data)}`,
      });
      return issues;
    }
  }

  if (Array.isArray(schema.enum) && !schema.enum.some((v) => v === data)) {
    const allowed = schema.enum.map((v) => JSON.stringify(v)).join(' / ');
    issues.push({
      kind: 'enum',
      path,
      text: `${path ? `${path} ` : ''}取值非法：${JSON.stringify(data)}（允许值: ${allowed}）`,
    });
  }

  if (isObject(data)) {
    const props = isObject(schema.properties) ? schema.properties : {};

    if (Array.isArray(schema.required)) {
      for (const key of schema.required) {
        if (data[key] === undefined) {
          const at = joinPath(path, key);
          issues.push({ kind: 'missing', path: at, text: `${at} 缺少必填字段` });
        }
      }
    }

    for (const [key, sub] of Object.entries(props)) {
      if (data[key] !== undefined) {
        issues.push(...validateAgainstSchema(data[key], sub, joinPath(path, key)));
      }
    }

    if (schema.additionalProperties === false) {
      for (const key of Object.keys(data)) {
        if (toleratedKeys.includes(key)) continue;
        if (!Object.prototype.hasOwnProperty.call(props, key)) {
          const at = joinPath(path, key);
          issues.push({
            kind: 'extra',
            path: at,
            text: `${at} 是多余的字段（未在 schema 中定义）`,
          });
        }
      }
    }
  }

  if (Array.isArray(data) && isObject(schema.items)) {
    data.forEach((item, index) => {
      issues.push(...validateAgainstSchema(item, schema.items, `${path}[${index}]`));
    });
  }

  return issues;
}

// ---------------------------------------------------------------- 检查 3 / 4：环境配置

/**
 * 环境配置的契约基线校验（不依赖项目自带的 schema）。
 * @param {object} data 环境配置对象
 * @param {string} rel 文件相对路径
 */
function validateEnvBaseline(data, rel) {
  for (const key of ENV_REQUIRED) {
    if (data[key] === undefined) {
      addIssue(rel, 'missing', key, `${key} 缺少必填字段`);
    }
  }
  for (const [key, type] of Object.entries(ENV_FIELD_TYPES)) {
    if (data[key] !== undefined && !typeMatches(data[key], type)) {
      addIssue(
        rel,
        'type',
        key,
        `${key} 类型错误：期望 ${type}，实际 ${describeType(data[key])}`,
      );
    }
  }
  for (const key of Object.keys(data)) {
    if (!ENV_ALLOWED_FIELDS.includes(key)) {
      addIssue(rel, 'extra', key, `${key} 是多余的字段（未在 schema 中定义）`);
    }
  }
  if (typeof data.driver === 'string' && !ENV_DRIVER_VALUES.includes(data.driver)) {
    addIssue(
      rel,
      'enum',
      'driver',
      `driver 取值非法："${data.driver}"（允许值: ${ENV_DRIVER_VALUES.join(' / ')}）`,
    );
  }
}

/**
 * 检查 4：credentials 下不得出现明文凭证，且 *_env 的值必须是合法环境变量名。
 * @param {object} data 环境配置对象
 * @param {string} rel 文件相对路径
 */
function checkCredentials(data, rel) {
  if (!isObject(data.credentials)) return;
  for (const [key, value] of Object.entries(data.credentials)) {
    const at = `credentials.${key}`;
    if (!key.endsWith('_env')) {
      problem(
        `${rel}: ${at} 是明文凭证：只允许 *_env 形式的环境变量引用（值为环境变量名），禁止写入凭证本身`,
      );
      continue;
    }
    if (typeof value !== 'string') continue; // 类型错误由类型检查报告
    if (!ENV_VAR_NAME_PATTERN.test(value)) {
      problem(
        `${rel}: ${at} 的值是非法环境变量名："${value}"（须匹配 ^[A-Z_][A-Z0-9_]*$，即大写字母/下划线开头）`,
      );
    }
  }
}

/**
 * 检查 2 / 3 / 4：环境目录、环境配置 schema、各环境文件。
 * @param {string} root 项目根目录
 * @param {string} envDir 环境目录绝对路径
 * @param {object|null} schema 已解析的 schema（不可用时为 null）
 * @returns {Set<string>} 可用环境名集合
 */
function checkEnvironments(root, envDir, schema) {
  const envNames = new Set();
  const files = listFiles(envDir).filter(
    (f) => f.endsWith('.json') && basename(f) !== '_schema.json',
  );
  for (const file of files) {
    envNames.add(basename(file, '.json'));
  }

  for (const file of files) {
    const rel = toSlash(relative(root, file));
    const data = readJson(file, rel);
    if (data === null) continue;
    if (!isObject(data)) {
      problem(`${rel}: 根节点必须是 JSON 对象`);
      continue;
    }

    validateEnvBaseline(data, rel);

    // --- 检查 3：环境标识必须与文件名一致（契约 §3.2） ---
    const expectedName = basename(file, '.json');
    if (isFilledString(data.name) && data.name !== expectedName) {
      problem(
        `${rel}: name "${data.name}" 与环境文件名 "${expectedName}" 不一致：` +
          '环境标识必须与文件名（不含 .json）完全一致',
      );
    }

    if (schema) {
      for (const issue of validateAgainstSchema(data, schema, '', ENV_TOLERATED_SCHEMA_KEYS)) {
        addIssue(rel, issue.kind, issue.path, issue.text);
      }
    }
    checkCredentials(data, rel);
  }

  return envNames;
}

// ---------------------------------------------------------------- 检查 5 / 6 / 7 / 8 / 14：执行配置

/**
 * 校验一个 suite.json。
 * @param {string} file 文件绝对路径
 * @param {string} root 项目根目录
 * @param {Set<string>} envNames 已定义的环境名集合
 */
function checkSuite(file, root, envNames) {
  const rel = toSlash(relative(root, file));
  const data = readJson(file, rel);
  if (data === null) return;
  if (!isObject(data)) {
    problem(`${rel}: 根节点必须是 JSON 对象`);
    return;
  }

  const dir = dirname(file);
  const dirName = basename(dir);

  // --- 检查 5：必填字段与枚举 ---
  for (const key of SUITE_REQUIRED) {
    if (data[key] === undefined) {
      addIssue(rel, 'missing', key, `${key} 缺少必填字段`);
    } else if (!isFilledString(data[key])) {
      addIssue(rel, 'type', key, `${key} 必须是非空字符串`);
    }
  }
  if (typeof data.scope === 'string' && !SUITE_SCOPES.includes(data.scope)) {
    addIssue(
      rel,
      'enum',
      'scope',
      `scope 取值非法："${data.scope}"（允许值: ${SUITE_SCOPES.join(' / ')}）`,
    );
  }
  if (typeof data.executor === 'string' && !SUITE_EXECUTORS.includes(data.executor)) {
    addIssue(
      rel,
      'enum',
      'executor',
      `executor 取值非法："${data.executor}"（允许值: ${SUITE_EXECUTORS.join(' / ')}）`,
    );
  }

  // --- 检查 8：suite 与目录名一致 ---
  if (isFilledString(data.suite) && data.suite !== dirName) {
    problem(`${rel}: suite "${data.suite}" 与所在目录名 "${dirName}" 不一致`);
  }

  // --- 检查 6：environment 必须存在 ---
  if (isFilledString(data.environment) && !envNames.has(data.environment)) {
    problem(
      `${rel}: environment "${data.environment}" 在 ${ENV_DIR_REL}/ 中不存在（可用: ${[...envNames].join(' / ') || '无'}）`,
    );
  }

  // --- 检查 7：cases_file 指向的文件必须存在 ---
  if (isFilledString(data.cases_file)) {
    const target = resolve(dir, data.cases_file);
    if (!target.startsWith(root + sep) && target !== root) {
      problem(`${rel}: cases_file "${data.cases_file}" 必须指向项目内的相对路径，不能越出项目根目录`);
    } else if (!existsSync(target)) {
      problem(
        `${rel}: cases_file 指向的文件不存在："${data.cases_file}"（相对所在目录 "${dirName}/" 解析）`,
      );
    }
  }

  // --- 顶层字段集是封闭的：scope 专属字段也不允许出现在 suite.json 里 ---
  for (const key of Object.keys(data)) {
    if (!SUITE_ALLOWED_FIELDS.includes(key)) {
      addIssue(
        rel,
        'extra',
        key,
        `${key} 是多余的字段（suite.json 的顶层字段集是封闭的：${SUITE_ALLOWED_FIELDS.join(' / ')}）`,
      );
    }
  }

  // --- tags ---
  if (data.tags !== undefined) {
    if (!isObject(data.tags)) {
      addIssue(rel, 'type', 'tags', 'tags 类型错误：期望 object，实际 ' + describeType(data.tags));
    } else {
      for (const key of ['include', 'exclude']) {
        const value = data.tags[key];
        if (value === undefined) continue;
        const ok = Array.isArray(value) && value.every((v) => typeof v === 'string');
        if (!ok) {
          addIssue(rel, 'type', `tags.${key}`, `tags.${key} 类型错误：期望 字符串数组，实际 ${describeType(value)}`);
        }
      }
    }
  }

  // --- report 与检查 14 ---
  if (data.report !== undefined) {
    if (!isObject(data.report)) {
      addIssue(
        rel,
        'type',
        'report',
        `report 类型错误：期望 object，实际 ${describeType(data.report)}`,
      );
    } else {
      const format = data.report.format;
      if (format !== undefined) {
        const ok = Array.isArray(format) && format.every((v) => typeof v === 'string');
        if (!ok) {
          addIssue(rel, 'type', 'report.format', `report.format 类型错误：期望 字符串数组，实际 ${describeType(format)}`);
        }
      }
      const outputDir = data.report.output_dir;
      if (outputDir !== undefined) {
        if (!isFilledString(outputDir)) {
          addIssue(rel, 'type', 'report.output_dir', 'report.output_dir 必须是非空字符串');
        } else if (!outputDir.startsWith(`${ARTIFACTS_DIR}/`)) {
          problem(
            `${rel}: report.output_dir "${outputDir}" 不在 ${ARTIFACTS_DIR}/ 下（执行产物必须落在不进 Git 的目录）`,
          );
        }
      }
    }
  }
}

// ---------------------------------------------------------------- 检查 9 / 10 / 11：轮次状态

/**
 * 校验一个 cycle.json。
 * @param {string} file 文件绝对路径
 * @param {string} root 项目根目录
 */
function checkCycle(file, root) {
  const rel = toSlash(relative(root, file));
  const data = readJson(file, rel);
  if (data === null) return;
  if (!isObject(data)) {
    problem(`${rel}: 根节点必须是 JSON 对象`);
    return;
  }

  if (!isFilledString(data.cycle_id)) {
    addIssue(rel, 'missing', 'cycle_id', 'cycle_id 缺少必填字段（或不是非空字符串）');
  } else {
    // §1 命名规则：轮次目录名 = 该目录 cycle.json 的 cycle_id 字段值
    const expectedId = basename(dirname(file));
    if (data.cycle_id !== expectedId) {
      problem(
        `${rel}: cycle_id "${data.cycle_id}" 与轮次目录名 "${expectedId}" 不一致：` +
          '轮次目录名必须与 cycle_id 一致',
      );
    }
  }
  if (!isFilledString(data.requirement)) {
    addIssue(rel, 'missing', 'requirement', 'requirement 缺少必填字段（或不是非空字符串）');
  }

  // --- 检查 9 / 10 / 11：轮次字段的类型、必填、枚举与一致性 ---
  // 判定规则只有一份实现（scripts/lib/state-machine.mjs）：
  // 转移表、终态、status↔history 一致性、scopes_skipped 记录的必填字段。
  // 推进器 scripts/cycle-state.mjs 做准入判断时调用的是同一个入口
  // （checkCycleConsistency），两边报出的是同一类问题。
  for (const issue of checkCycleConsistency(data)) {
    addIssue(rel, issue.kind, issue.path, issue.text);
  }
}

// ---------------------------------------------------------------- 检查 12：轮次索引

/**
 * 检查 12：cycles/index.json 中每个 id 在 cycles/ 下都有对应目录。
 * @param {string} file index.json 绝对路径
 * @param {string} root 项目根目录
 * @param {string} cyclesDir cycles 目录绝对路径
 */
function checkCycleIndex(file, root, cyclesDir) {
  const rel = toSlash(relative(root, file));
  const data = readJson(file, rel);
  if (data === null) return;
  if (!isObject(data)) {
    problem(`${rel}: 根节点必须是 JSON 对象`);
    return;
  }
  if (!Array.isArray(data.cycles)) {
    addIssue(rel, 'type', 'cycles', `cycles 类型错误：期望 array，实际 ${describeType(data.cycles)}`);
    return;
  }

  data.cycles.forEach((entry, index) => {
    const at = `cycles[${index}]`;
    if (!isObject(entry)) {
      addIssue(rel, 'type', at, `${at} 类型错误：期望 object，实际 ${describeType(entry)}`);
      return;
    }
    if (!isFilledString(entry.id)) {
      addIssue(rel, 'missing', `${at}.id`, `${at}.id 缺少必填字段（或不是非空字符串）`);
      return;
    }
    if (!isDir(join(cyclesDir, entry.id))) {
      problem(`${rel}: 悬空的 cycle id "${entry.id}"（${CYCLES_DIR_REL}/ 下无对应目录）`);
    }
    if (typeof entry.round === 'string' && !ROUNDS.includes(entry.round)) {
      addIssue(rel, 'enum', `${at}.round`, `${at}.round 取值非法："${entry.round}"（允许值: ${ROUNDS.join(' / ')}）`);
    }
    if (typeof entry.status === 'string' && !CYCLE_STATUSES.includes(entry.status)) {
      addIssue(
        rel,
        'enum',
        `${at}.status`,
        `${at}.status 取值非法："${entry.status}"（允许值: ${CYCLE_STATUSES.join(' / ')}）`,
      );
    }

    // --- index 是 cycle 的派生视图：条目与 cycle.json 的 status / round 必须一致 ---
    const cycleFile = join(cyclesDir, entry.id, 'cycle.json');
    if (isFile(cycleFile)) {
      const cycleRel = toSlash(relative(root, cycleFile));
      const cycle = readJson(cycleFile, cycleRel);
      if (cycle !== null && isObject(cycle)) {
        const mismatches = indexEntryMismatches(entry, cycle);
        for (const mismatch of mismatches) {
          problem(
            `${rel}: ${at} 与 ${cycleRel} 不一致（${mismatch}）：` +
              'index 是 cycle 的派生视图，必须与轮次状态保持一致',
          );
        }
      }
    }
  });
}

// ---------------------------------------------------------------- 检查 13：gitignore

/**
 * 检查 13：.test-artifacts/ 必须在项目 .gitignore 中。
 * @param {string} root 项目根目录
 */
function checkGitignore(root) {
  const file = join(root, '.gitignore');
  if (!isFile(file)) {
    problem(`.gitignore 缺失：${ARTIFACTS_DIR}/ 必须被忽略（执行产物不得进 Git）`);
    return;
  }
  let content;
  try {
    content = readFileSync(file, 'utf8');
  } catch (err) {
    problem(`.gitignore: 无法读取文件 — ${err.message}`);
    return;
  }
  let ignored = false;
  for (const raw of content.split(/\r?\n/)) {
    const line = raw.trim();
    if (line === '' || line.startsWith('#') || line.startsWith('!')) continue;
    const normalized = line.replace(/^\/+/, '').replace(/\/+$/, '');
    if (normalized === ARTIFACTS_DIR || normalized.startsWith(`${ARTIFACTS_DIR}/`)) {
      ignored = true;
      break;
    }
  }
  if (!ignored) {
    problem(`.gitignore 未忽略 ${ARTIFACTS_DIR}/：执行产物必须留在 Git 之外（加上 "${ARTIFACTS_DIR}/" 一行）`);
  }
}

// ---------------------------------------------------------------- 主流程

/**
 * 执行全部检查。
 * @param {string} root 项目根目录绝对路径
 */
function runChecks(root) {
  const assetsDir = join(root, ASSETS_DIR);
  const envDir = join(assetsDir, 'environments');
  const cyclesDir = join(assetsDir, 'cycles');

  // 检查 1
  if (!isDir(assetsDir)) {
    problem(`${ASSETS_DIR}/ 缺失：测试资产根目录必须存在于项目根下`);
    return;
  }
  pass(`${ASSETS_DIR}/ 存在`);

  // 检查 2：环境目录与 schema
  let schema = null;
  if (!isDir(envDir)) {
    problem(`${ENV_DIR_REL}/ 缺失：环境定义目录必须存在`);
  } else {
    pass(`${ENV_DIR_REL}/ 存在`);
    const schemaFile = join(envDir, '_schema.json');
    if (!isFile(schemaFile)) {
      problem(`${ENV_SCHEMA_REL} 缺失：环境配置 schema 必须存在`);
    } else {
      const schemaDoc = readJson(schemaFile, ENV_SCHEMA_REL);
      if (schemaDoc !== null) {
        if (!isObject(schemaDoc)) {
          problem(`${ENV_SCHEMA_REL}: 根节点必须是 JSON 对象`);
        } else {
          schema = schemaDoc;
          pass(`${ENV_SCHEMA_REL} 存在且可解析`);
        }
      }
    }
  }

  // 检查 3 / 4：环境配置
  let envNames = new Set();
  if (isDir(envDir)) {
    const before = report.length;
    envNames = checkEnvironments(root, envDir, schema);
    const envFiles = listFiles(envDir).filter(
      (f) => f.endsWith('.json') && basename(f) !== '_schema.json',
    );
    for (const file of envFiles) {
      const rel = toSlash(relative(root, file));
      const hasProblem = report.slice(before).some((line) => !line.ok && line.text.startsWith(`${rel}: `));
      if (!hasProblem) pass(`${rel} 符合契约与 schema`);
    }
  }

  // 检查 5 / 6 / 7 / 8 / 14：执行配置
  const suiteFiles = listFiles(assetsDir).filter((f) => basename(f) === 'suite.json');
  for (const file of suiteFiles) {
    const before = report.length;
    const rel = toSlash(relative(root, file));
    checkSuite(file, root, envNames);
    const hasProblem = report.slice(before).some((line) => !line.ok);
    if (!hasProblem) pass(`${rel} 字段完整、枚举合法、引用有效`);
  }

  // 检查 9 / 10 / 11：轮次状态
  const cycleFiles = listFiles(cyclesDir).filter((f) => basename(f) === 'cycle.json');
  for (const file of cycleFiles) {
    const before = report.length;
    checkCycle(file, root);
    const hasProblem = report.slice(before).some((line) => !line.ok);
    if (!hasProblem) pass(`${toSlash(relative(root, file))} 枚举合法、跳过理由与状态历史一致`);
  }

  // 检查 12：轮次索引
  if (!isDir(cyclesDir)) {
    problem(`${CYCLES_DIR_REL}/ 缺失：轮次状态目录必须存在`);
  } else {
    const indexFile = join(cyclesDir, 'index.json');
    if (!isFile(indexFile)) {
      problem(`${ENV_INDEX_REL} 缺失：轮次索引必须存在`);
    } else {
      const before = report.length;
      checkCycleIndex(indexFile, root, cyclesDir);
      const hasProblem = report.slice(before).some((line) => !line.ok);
      if (!hasProblem) pass(`${ENV_INDEX_REL} 中每个 cycle id 都有对应目录`);
    }
  }

  // 检查 13
  const before = report.length;
  checkGitignore(root);
  if (report.length === before) pass(`.gitignore 已忽略 ${ARTIFACTS_DIR}/`);
}

function main() {
  const args = process.argv.slice(2);
  if (args.length > 1) {
    process.stdout.write(
      '用法: node scripts/verify-layout.mjs [project-root]\n' +
        '      （路径相对 skill 目录；仓库内为 skills/test-case-design/scripts/verify-layout.mjs）\n',
    );
    process.exit(2);
  }

  const root = resolve(args[0] ?? process.cwd());
  if (!isDir(root)) {
    process.stdout.write(`[FAIL] 项目根目录不存在或不是目录: ${root}\n`);
    process.stderr.write(`[FAIL] 项目根目录不存在或不是目录: ${root}\n`);
    process.stdout.write('结论: 1 FAIL / 0 OK\n');
    process.exit(1);
  }

  runChecks(root);

  let okCount = 0;
  let failCount = 0;
  for (const line of report) {
    const tag = (line.ok ? '[OK]' : '[FAIL]').padEnd(7);
    process.stdout.write(`${tag}${line.text}\n`);
    if (line.ok) okCount += 1;
    else {
      failCount += 1;
      // stderr 只带问题行：只看 stderr 的调用方也能定位到全部违规
      process.stderr.write(`${tag}${line.text}\n`);
    }
  }

  process.stdout.write(`结论: ${failCount} FAIL / ${okCount} OK\n`);
  process.exit(failCount > 0 ? 1 : 0);
}

main();
