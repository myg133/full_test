// suite-loader.mjs — 执行配置 / 环境配置 / 用例集的读取与解析
//
// 输入三件套（需求 F2）：
//   suite.json     → 执行配置（suite / requirement / scope / environment / cases_file / executor）
//   environments/  → 环境定义（base_url / timeout_ms / credentials / headers）
//   cases_file     → 用例集（REQ-002A 的 schema v2）
//
// 凭证边界：环境配置里只有 *_env 字段名，真实值在运行时从进程环境变量读。
// 本模块负责"读不到就报出来"，判定在 lib/verdict.mjs。
//
// 纯 Node.js，只依赖 node: 内置模块。

import { existsSync, readFileSync, statSync } from 'node:fs';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import process from 'node:process';

import { collectAssertions } from './assertion.mjs';

/** 步骤 action 里可解析出 HTTP 请求的形式（形如 "GET /ok"） */
const ACTION_REQUEST_PATTERN = /^\s*(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+(\/\S*)\s*$/i;

/** suite.json 的必填字段 */
export const SUITE_REQUIRED_FIELDS = Object.freeze([
  'suite',
  'requirement',
  'scope',
  'environment',
  'cases_file',
  'executor',
]);

/**
 * 是否是普通对象。
 * @param {any} value 待判定值
 * @returns {boolean}
 */
export function isObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * 读取并解析 JSON 文件。
 * @param {string} file 文件路径
 * @param {string} label 报错时用的标签
 * @returns {any}
 */
export function readJsonFile(file, label) {
  if (!existsSync(file)) {
    throw new Error(`${label} 不存在: ${file}`);
  }
  let raw;
  try {
    raw = readFileSync(file, 'utf8');
  } catch (err) {
    throw new Error(`${label} 无法读取: ${file} — ${err.message}`);
  }
  try {
    return JSON.parse(raw);
  } catch (err) {
    throw new Error(`${label} JSON 语法错误: ${file} — ${err.message}`);
  }
}

/**
 * 定位 suite.json：位置参数可以是文件，也可以是套件目录。
 *
 * @param {string} target 路径
 * @returns {{file: string, dir: string}}
 */
export function resolveSuiteFile(target) {
  const abs = resolve(target);
  if (existsSync(abs) && !isDirectory(abs)) return { file: abs, dir: dirname(abs) };
  const candidate = join(abs, 'suite.json');
  if (existsSync(candidate)) return { file: candidate, dir: abs };
  throw new Error(`找不到 suite.json: ${target}（既不是文件，该目录下也没有 suite.json）`);
}

/**
 * 是否是目录。
 * @param {string} path 路径
 * @returns {boolean}
 */
function isDirectory(path) {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
}

/**
 * 读取并校验执行配置。
 *
 * @param {string} suitePath suite.json 路径
 * @returns {{config: object, file: string, dir: string, casesFile: string}}
 */
export function loadSuite(suitePath) {
  const { file, dir } = resolveSuiteFile(suitePath);
  const config = readJsonFile(file, '执行配置 suite.json');
  if (!isObject(config)) throw new Error(`执行配置 suite.json 的根节点必须是对象: ${file}`);
  const missing = SUITE_REQUIRED_FIELDS.filter(
    (key) => typeof config[key] !== 'string' || config[key].trim() === '',
  );
  if (missing.length > 0) {
    throw new Error(
      `执行配置 ${file} 缺少必填字段: ${missing.join(' / ')}` +
        '（需求 F2：suite / requirement / scope / environment / cases_file / executor 均为必填）',
    );
  }
  const casesFile = isAbsolute(config.cases_file)
    ? config.cases_file
    : resolve(dir, config.cases_file);
  return { config, file, dir, casesFile };
}

/**
 * 读取环境配置。
 *
 * @param {string} projectRoot 项目根
 * @param {string} environment 环境名
 * @returns {{config: object, file: string}}
 */
export function loadEnvironment(projectRoot, environment) {
  const file = join(resolve(projectRoot), 'test-assets', 'environments', `${environment}.json`);
  const config = readJsonFile(file, `环境配置 ${environment}.json`);
  if (!isObject(config)) throw new Error(`环境配置 ${file} 的根节点必须是对象`);
  return { config, file };
}

/**
 * 读取用例集。
 *
 * @param {string} casesFile 用例集路径
 * @returns {{doc: object, file: string, cases: object[]}}
 */
export function loadCases(casesFile) {
  const doc = readJsonFile(casesFile, '用例集');
  if (!isObject(doc)) throw new Error(`用例集 ${casesFile} 的根节点必须是对象`);
  if (!Array.isArray(doc.cases)) {
    throw new Error(`用例集 ${casesFile} 缺少 cases 数组（需求 F2：用例集沿用 REQ-002A 的 v2 格式）`);
  }
  const cases = doc.cases.filter((item) => isObject(item) && typeof item.id === 'string');
  return { doc, file: casesFile, cases };
}

/**
 * 从环境配置里取出凭证引用（只取 *_env 字段名）。
 *
 * @param {object} environmentConfig 环境配置
 * @returns {string[]} 环境变量名清单
 */
export function credentialEnvNames(environmentConfig) {
  const credentials = isObject(environmentConfig) && isObject(environmentConfig.credentials)
    ? environmentConfig.credentials
    : {};
  return Object.keys(credentials)
    .filter((key) => key.endsWith('_env'))
    .map((key) => credentials[key])
    .filter((name) => typeof name === 'string' && name.trim() !== '');
}

/**
 * 取出用例的鉴权配置。
 *
 * 载体优先级：case.auth → case.data.auth。
 *
 * @param {object} caseObj 用例
 * @returns {object|null}
 */
export function caseAuth(caseObj) {
  if (!isObject(caseObj)) return null;
  if (isObject(caseObj.auth)) return caseObj.auth;
  if (isObject(caseObj.data) && isObject(caseObj.data.auth)) return caseObj.data.auth;
  return null;
}

/**
 * 取出用例鉴权配置引用的环境变量名。
 *
 * @param {object} caseObj 用例
 * @returns {string[]}
 */
export function caseAuthEnvNames(caseObj) {
  const auth = caseAuth(caseObj);
  if (!auth) return [];
  const names = [];
  if (typeof auth.env === 'string' && auth.env.trim() !== '') names.push(auth.env.trim());
  if (typeof auth.username_env === 'string' && auth.username_env.trim() !== '') {
    names.push(auth.username_env.trim());
  }
  if (typeof auth.password_env === 'string' && auth.password_env.trim() !== '') {
    names.push(auth.password_env.trim());
  }
  return names;
}

/**
 * 解析凭证：真实值只从进程环境变量读。
 *
 * @param {object} environmentConfig 环境配置
 * @param {object[]} cases 用例清单
 * @returns {{values: object, missing: string[], required: string[]}}
 */
export function resolveCredentials(environmentConfig, cases) {
  const required = new Set(credentialEnvNames(environmentConfig));
  for (const caseObj of cases || []) {
    for (const name of caseAuthEnvNames(caseObj)) required.add(name);
  }
  const values = {};
  const missing = [];
  for (const name of required) {
    const value = process.env[name];
    if (typeof value === 'string' && value !== '') values[name] = value;
    else missing.push(name);
  }
  return { values, missing, required: [...required] };
}

/**
 * 按 suite.json 的 tags 过滤用例。
 *
 * @param {object[]} cases 用例清单
 * @param {object} tags 标签过滤配置（include / exclude）
 * @returns {object[]}
 */
export function selectCases(cases, tags) {
  const include = isObject(tags) && Array.isArray(tags.include) ? tags.include : [];
  const exclude = isObject(tags) && Array.isArray(tags.exclude) ? tags.exclude : [];
  return cases.filter((item) => {
    const caseTags = Array.isArray(item.tags) ? item.tags : [];
    if (include.length > 0 && !include.some((tag) => caseTags.includes(tag))) return false;
    if (exclude.length > 0 && exclude.some((tag) => caseTags.includes(tag))) return false;
    return true;
  });
}

/**
 * 决定用哪个驱动（执行器实现）。
 *
 * 优先级：环境配置的 driver 字段 → suite.json 的 executor 字段。
 * 两者都允许写 "mock"：suite.json 的 executor 取值集合由 REQ-002B 的目录契约定义，
 * 写成 mock 之前请先确认该契约已放行（见 references/executor-spec.md）。
 *
 * @param {object} suiteConfig 执行配置
 * @param {object} environmentConfig 环境配置
 * @returns {{name: string, source: string}}
 */
export function resolveDriverName(suiteConfig, environmentConfig) {
  const fromEnv =
    isObject(environmentConfig) && typeof environmentConfig.driver === 'string'
      ? environmentConfig.driver.trim()
      : '';
  if (fromEnv !== '') return { name: fromEnv, source: 'environment.driver' };
  const fromSuite =
    isObject(suiteConfig) && typeof suiteConfig.executor === 'string'
      ? suiteConfig.executor.trim()
      : '';
  if (fromSuite !== '') return { name: fromSuite, source: 'suite.json.executor' };
  return { name: '', source: 'none' };
}

/**
 * 取出**用例级**的请求构造配置。
 *
 * 载体优先级：case.request → case.data.request。
 * step 级的请求由 stepRequest() 单独解析（逐步执行时每个 step 各有自己的请求）。
 *
 * @param {object} caseObj 用例
 * @returns {object|null}
 */
export function caseRequest(caseObj) {
  if (!isObject(caseObj)) return null;
  if (isObject(caseObj.request)) return caseObj.request;
  if (isObject(caseObj.data) && isObject(caseObj.data.request)) return caseObj.data.request;
  return null;
}

/**
 * 取出单个 step 的请求构造配置。
 *
 * 一个 step 可执行，当且仅当它有 step.request，或它的 action 能解析成 "METHOD /path"。
 *
 * @param {object} step 步骤对象
 * @returns {object|null}
 */
export function stepRequest(step) {
  if (!isObject(step)) return null;
  if (isObject(step.request)) return step.request;
  if (typeof step.action === 'string') {
    const matched = ACTION_REQUEST_PATTERN.exec(step.action);
    if (matched) return { method: matched[1].toUpperCase(), path: matched[2] };
  }
  return null;
}

/**
 * 解析一个用例的执行计划：跑哪些请求、每条断言绑到哪次响应。
 *
 * 规则（需求 F3 的多步语义）：
 *   1. 用例级载体（case.request / case.data.request）存在 → 整个用例只跑这一次请求，
 *      所有 step 上的断言都针对这同一次响应（合法的"一次响应多条断言"）。
 *   2. 否则 → 每个可执行 step 各跑一次请求，按 steps 顺序。
 *   3. 断言归属它自己所在的 step；该 step 不可执行且用例不止一次请求时，
 *      这条断言没有可判的响应 → 判 blocked（assertion_without_response），不得判 passed。
 *
 * @param {object} caseObj 用例
 * @returns {{requests: {step_index: number|null, request: object, action: string}[],
 *            assertions: {assertion: object, stepIndex: number, action: string}[],
 *            unbound: {assertion: object, stepIndex: number, action: string}[]}}
 */
export function resolveExecutionPlan(caseObj) {
  const assertions = collectAssertions(caseObj);
  const steps = isObject(caseObj) && Array.isArray(caseObj.steps) ? caseObj.steps : [];
  const caseLevel = caseRequest(caseObj);
  const requests = [];
  if (caseLevel) {
    requests.push({ step_index: null, request: caseLevel, action: '' });
  } else {
    steps.forEach((step, index) => {
      const request = stepRequest(step);
      if (!request) return;
      requests.push({
        step_index: index,
        request,
        action: isObject(step) && typeof step.action === 'string' ? step.action : '',
      });
    });
  }

  let unbound = [];
  if (requests.length === 0) {
    // 一次请求都没解析出来 → 所有断言都没有可判的响应
    unbound = assertions.slice();
  } else if (requests.length === 1) {
    // 只解析出一次请求 → 全部断言都针对这同一次响应
    unbound = [];
  } else {
    const executable = new Set(requests.map((item) => item.step_index));
    unbound = assertions.filter((item) => !executable.has(item.stepIndex));
  }
  return { requests, assertions, unbound };
}

/**
 * 从步骤描述里回退解析 HTTP 请求（形如 "GET /ok"）。
 *
 * 只在单个 step 没有显式声明请求时使用：步骤的 action 本来是给人读的一句话，
 * 但写成 "GET /ok" 这样的形式时也能直接驱动执行。
 *
 * @param {object} caseObj 用例
 * @returns {object|null}
 */
export function requestFromSteps(caseObj) {
  if (!isObject(caseObj) || !Array.isArray(caseObj.steps)) return null;
  for (const step of caseObj.steps) {
    const request = stepRequest(step);
    if (request) return request;
  }
  return null;
}
