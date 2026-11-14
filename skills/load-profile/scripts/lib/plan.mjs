// plan.mjs —— 压测计划的**读入、校验、构造与自检**（零第三方依赖，只用 node: 内置模块）
//
// 做四件事：
//   1. **读入**（只读）：负载模型本体 + 套件引用件 + 套件执行配置 + 环境文件；
//   2. **校验输入**：引用不得悬空/漂移、环境必须有 `base_url`、模型内容必须合法、
//      `args` 的未知键必须拒绝、`python` runner 必须自陈完整命令；
//   3. **构造计划**：一个套件一个计划文件，每个 profile 段一条 invocation（**不许合并**）；
//   4. **产物侧自检**：三层字段集封闭、枚举合法、无压测结论、无执行痕迹。
//
// ⚠️ **写入纪律**：本模块**不写任何文件**（写盘在入口脚本里，且严格「先校验、后建目录」）。
// ⚠️ **诚实性**：计划里可以携带阈值（供人看），但**绝不**产出任何「已达标/未达标」的结论。

import fs from 'node:fs';
import path from 'node:path';

import { InputError, clone, isObject, isFilledString, readJsonFile } from './io.mjs';
import {
  ARGS_WHITELIST,
  EXECUTION_TRACE_KEYS,
  FORBIDDEN_CONCLUSION_KEYS,
  FORBIDDEN_PHRASES,
  OQ_ID_PATTERN,
  OQ_TOPICS,
  PROFILE_TYPES,
  RUNNERS,
  RUNTIMES,
  assertArgsKeys,
  buildArgv,
  parseTarget,
} from './runner.mjs';

/** 计划顶层字段集（封闭 4 个）。 */
export const PLAN_TOP_FIELDS = ['schema_version', 'suite', 'environment', 'scenarios'];

/** 场景条目必填字段集（10 个）。 */
export const PLAN_SCENARIO_FIELDS = [
  'scenario_id',
  'scenario_name',
  'runner',
  'runtime',
  'target',
  'base_url',
  'profile_type',
  'invocations',
  'thresholds_status',
  'open_questions',
];

/** 场景条目的条件字段（模型 `provided` 时才有）。 */
export const PLAN_SCENARIO_COND_FIELDS = ['thresholds', 'thresholds_source'];

/** invocation 元素字段集（封闭 4 个）。 */
export const PLAN_INVOCATION_FIELDS = ['step_index', 'duration_s', 'concurrency', 'argv'];

/** 阈值状态二态。 */
export const THRESHOLD_STATUSES = ['provided', 'not_provided'];

/**
 * 负载模型所在目录。
 * @param {string} loadDir 读入侧项目根
 * @returns {string}
 */
export function loadRootOf(loadDir) {
  return path.join(loadDir, 'test-assets', 'load');
}

/**
 * 列出目录下的子目录名（不存在 ⇒ 空数组）。
 * @param {string} dir 目录
 * @returns {string[]}
 */
function listDirs(dir) {
  try {
    return fs
      .readdirSync(dir, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .sort();
  } catch {
    return [];
  }
}

/**
 * 是不是「含空白之外都正常」的整数（≥ min）。
 * @param {*} value 待判定值
 * @param {number} min 下界
 * @returns {boolean}
 */
function isIntAtLeast(value, min) {
  return Number.isInteger(value) && value >= min;
}

/**
 * 校验负载模型本体并返回它。
 * @param {string} file 模型文件路径
 * @param {string} label 报错用的标签
 * @returns {object} 模型本体
 */
export function validateModel(file, label) {
  const model = readJsonFile(file, label);
  if (!isObject(model)) throw new InputError(`${label} 必须是一个 JSON 对象: ${file}`);

  for (const key of ['id', 'name', 'environment']) {
    if (!isFilledString(model[key])) {
      throw new InputError(`${label} 的 ${key} 必须是非空字符串（实际 ${JSON.stringify(model[key])}）`);
    }
  }

  // --- target：形态 "METHOD /path" ---
  parseTarget(model.target);

  // --- profile：类型枚举 + 段列表 ---
  if (!isObject(model.profile)) throw new InputError(`${label} 的 profile 必须是对象`);
  if (!PROFILE_TYPES.includes(model.profile.type)) {
    throw new InputError(
      `${label} 的 profile.type 取值非法: ${JSON.stringify(model.profile.type)}`
      + `（只允许 ${PROFILE_TYPES.join(' / ')}）`,
    );
  }
  if (!Array.isArray(model.profile.steps) || model.profile.steps.length === 0) {
    throw new InputError(`${label} 的 profile.steps 必须是非空数组`);
  }
  for (let i = 0; i < model.profile.steps.length; i += 1) {
    const step = model.profile.steps[i];
    const where = `${label} 的 profile.steps[${i}]`;
    if (!isObject(step)) throw new InputError(`${where} 必须是对象`);
    const keys = Object.keys(step).sort();
    if (keys.join(',') !== 'concurrency,duration_s') {
      throw new InputError(`${where} 的字段集必须恰为 duration_s / concurrency（实际 ${keys.join(',')}）`);
    }
    if (!isIntAtLeast(step.duration_s, 1)) {
      throw new InputError(`${where} 的 duration_s 必须是 ≥1 的整数（实际 ${JSON.stringify(step.duration_s)}）`);
    }
    if (!isIntAtLeast(step.concurrency, 1)) {
      throw new InputError(`${where} 的 concurrency 必须是 ≥1 的整数（实际 ${JSON.stringify(step.concurrency)}）`);
    }
  }

  // --- tool：runner / runtime 枚举 ---
  if (!isObject(model.tool)) throw new InputError(`${label} 的 tool 必须是对象`);
  if (!RUNNERS.includes(model.tool.runner)) {
    throw new InputError(
      `${label} 的 tool.runner 取值非法: ${JSON.stringify(model.tool.runner)}`
      + `（只允许 ${RUNNERS.join(' / ')}）`,
    );
  }
  if (!RUNTIMES.includes(model.tool.runtime)) {
    throw new InputError(
      `${label} 的 tool.runtime 取值非法: ${JSON.stringify(model.tool.runtime)}`
      + `（只允许 ${RUNTIMES.join(' / ')}）`,
    );
  }

  // --- 阈值的二态与键的有无必须自洽 ---
  if (!THRESHOLD_STATUSES.includes(model.thresholds_status)) {
    throw new InputError(
      `${label} 的 thresholds_status 取值非法: ${JSON.stringify(model.thresholds_status)}`
      + '（只允许 provided / not_provided）',
    );
  }
  const hasThresholds = Object.prototype.hasOwnProperty.call(model, 'thresholds');
  const hasSource = Object.prototype.hasOwnProperty.call(model, 'thresholds_source');
  if (model.thresholds_status === 'provided') {
    if (!hasThresholds || !hasSource) {
      throw new InputError(`${label} 的 thresholds_status 是 provided，但 thresholds / thresholds_source 缺一个`);
    }
    if (!isObject(model.thresholds)) throw new InputError(`${label} 的 thresholds 必须是对象`);
    if (!isFilledString(model.thresholds_source)) {
      throw new InputError(`${label} 的 thresholds_source 必须是非空字符串`);
    }
  } else if (hasThresholds || hasSource) {
    throw new InputError(`${label} 的 thresholds_status 是 not_provided，但出现了 thresholds / thresholds_source 键`);
  }

  // --- args：未知键一律拒绝；python runner 必须自陈完整命令 ---
  if (model.args !== undefined) {
    if (!isObject(model.args)) throw new InputError(`${label} 的 args 必须是对象`);
    assertArgsKeys(model.tool.runner, model.args);
    const args = model.args;
    if (model.tool.runner === 'loadtest') {
      if (args.rps !== undefined && !(typeof args.rps === 'number' && args.rps > 0)) {
        throw new InputError(`${label} 的 args.rps 必须是 >0 的数字（实际 ${JSON.stringify(args.rps)}）`);
      }
      if (args.keepalive !== undefined && typeof args.keepalive !== 'boolean') {
        throw new InputError(`${label} 的 args.keepalive 必须是布尔值（实际 ${JSON.stringify(args.keepalive)}）`);
      }
      if (args.timeout_s !== undefined && !(typeof args.timeout_s === 'number' && args.timeout_s > 0)) {
        throw new InputError(`${label} 的 args.timeout_s 必须是 >0 的数字（实际 ${JSON.stringify(args.timeout_s)}）`);
      }
      if (args.method !== undefined && !isFilledString(args.method)) {
        throw new InputError(`${label} 的 args.method 必须是非空字符串（实际 ${JSON.stringify(args.method)}）`);
      }
    }
    if (model.tool.runner === 'python') {
      if (!Object.prototype.hasOwnProperty.call(args, 'command')) {
        throw new InputError(
          `${label} 是 python runner，但 args 里没有 command —— 必须自陈完整命令（完整 argv 数组）；`
          + '本工具不许为 python runner 编造默认命令',
        );
      }
      if (!Array.isArray(args.command) || args.command.length === 0) {
        throw new InputError(
          `${label} 的 args.command 必须是**非空 argv 数组**（字符串命令要分词 ⇒ 分词歧义 ⇒ 不接受）`,
        );
      }
      for (const item of args.command) {
        if (typeof item !== 'string' || item === '') {
          throw new InputError(`${label} 的 args.command 只能含非空字符串元素（实际 ${JSON.stringify(args.command)}）`);
        }
      }
    }
  } else if (model.tool.runner === 'python') {
    throw new InputError(
      `${label} 是 python runner，但 args 里没有 command —— 必须自陈完整命令（完整 argv 数组）；`
      + '本工具不许为 python runner 编造默认命令',
    );
  }

  // --- traceability ---
  if (!isObject(model.traceability)) throw new InputError(`${label} 的 traceability 必须是对象`);
  if (!Array.isArray(model.traceability.case_refs)) {
    throw new InputError(`${label} 的 traceability.case_refs 必须是数组`);
  }

  // --- open_questions（结构封闭 3） ---
  if (!Array.isArray(model.open_questions)) {
    throw new InputError(`${label} 的 open_questions 必须是数组`);
  }
  for (const q of model.open_questions) {
    if (!isObject(q)) throw new InputError(`${label} 的 open_questions 元素必须是对象`);
    const keys = Object.keys(q).sort();
    if (keys.join(',') !== 'id,question,topic') {
      throw new InputError(`${label} 的 open_questions 元素字段集必须恰为 id / topic / question（实际 ${keys.join(',')}）`);
    }
    if (!OQ_ID_PATTERN.test(String(q.id))) {
      throw new InputError(`${label} 的 open_questions id 不合 ^OQ-\\d{3}$（实际 ${JSON.stringify(q.id)}）`);
    }
    if (!OQ_TOPICS.includes(q.topic)) {
      throw new InputError(
        `${label} 的 open_questions topic 取值非法: ${JSON.stringify(q.topic)}（只允许 ${OQ_TOPICS.join(' / ')}）`,
      );
    }
    if (!isFilledString(q.question)) {
      throw new InputError(`${label} 的 open_questions question 必须是非空字符串`);
    }
  }

  // --- 缺口必须显式：没有指标来源 ⇒ 必有 thresholds 主题；有来源 ⇒ 必无 ---
  const topics = model.open_questions.map((q) => q.topic);
  if (model.thresholds_status === 'not_provided' && !topics.includes('thresholds')) {
    throw new InputError(
      `${label} 没有指标来源（thresholds_status=not_provided），但 open_questions 里没有 topic=thresholds 的未决问题`,
    );
  }
  if (model.thresholds_status === 'provided' && topics.includes('thresholds')) {
    throw new InputError(
      `${label} 有指标来源（thresholds_status=provided），但 open_questions 里出现了 topic=thresholds 的未决问题`,
    );
  }
  if (model.traceability.case_refs.length === 0 && !topics.includes('coverage')) {
    throw new InputError(
      `${label} 没有对应用例（traceability.case_refs 为空），但 open_questions 里没有 topic=coverage 的未决问题`,
    );
  }

  return model;
}

/**
 * 读入侧：负载模型 + 套件 + 环境（**只读**，不改不建）。
 * @param {string} loadDir 读入侧项目根
 * @returns {{suites: object[], envs: Map<string, object>}}
 */
export function loadSide(loadDir) {
  const root = loadRootOf(loadDir);
  const suitesDir = path.join(root, 'suites');
  const envDir = path.join(loadDir, 'test-assets', 'environments');
  if (!fs.existsSync(suitesDir) || !fs.statSync(suitesDir).isDirectory()) {
    throw new InputError(`找不到压测套件目录: ${suitesDir}`);
  }

  const envs = new Map();
  const suiteNames = listDirs(suitesDir);
  if (suiteNames.length === 0) {
    throw new InputError(`压测套件目录里一个套件都没有: ${suitesDir}`);
  }

  const suites = [];
  for (const name of suiteNames) {
    const suiteDir = path.join(suitesDir, name);
    const cfgFile = path.join(suiteDir, 'suite.json');
    const refFile = path.join(suiteDir, 'scenario.json');
    if (!fs.existsSync(cfgFile)) {
      throw new InputError(`套件 ${name} 缺少执行配置 suite.json: ${cfgFile}`);
    }
    if (!fs.existsSync(refFile)) {
      throw new InputError(`套件 ${name} 缺少引用件 scenario.json: ${refFile}`);
    }
    const cfg = readJsonFile(cfgFile, `套件 ${name} 的 suite.json`);
    if (!isObject(cfg)) throw new InputError(`套件 ${name} 的 suite.json 必须是对象`);
    if (cfg.suite !== name) {
      throw new InputError(`套件 ${name} 的 suite.json 的 suite 字段与目录名不一致（实际 ${JSON.stringify(cfg.suite)}）`);
    }
    if (!isFilledString(cfg.environment)) {
      throw new InputError(`套件 ${name} 的 suite.json 缺少 environment 字段`);
    }
    const refDoc = readJsonFile(refFile, `套件 ${name} 的 scenario.json`);
    if (!isObject(refDoc)) throw new InputError(`套件 ${name} 的 scenario.json 必须是对象`);
    if (!Array.isArray(refDoc.scenarios) || refDoc.scenarios.length === 0) {
      throw new InputError(`套件 ${name} 的 scenario.json 的 scenarios 必须是非空数组`);
    }

    const entries = [];
    for (let i = 0; i < refDoc.scenarios.length; i += 1) {
      const ref = refDoc.scenarios[i];
      const where = `套件 ${name} 的 scenario.json 的 scenarios[${i}]`;
      if (!isObject(ref)) throw new InputError(`${where} 必须是对象`);
      if (!isFilledString(ref.path)) throw new InputError(`${where} 缺 path`);
      const abs = path.resolve(suiteDir, ref.path);
      const scenariosDir = path.resolve(path.join(root, 'scenarios'));
      if (!abs.startsWith(`${scenariosDir}${path.sep}`)) {
        throw new InputError(`${where} 的 path 必须指向 scenarios/ 下（实际解析到 ${abs}）`);
      }
      if (!fs.existsSync(abs)) {
        throw new InputError(`${where} 的 path 解析不到文件: ${abs}（引用不得悬空）`);
      }
      const model = validateModel(abs, `负载模型 ${path.basename(abs)}`);
      if (model.id !== ref.id) {
        throw new InputError(
          `${where} 的 id 与模型漂移（引用 ${JSON.stringify(ref.id)}，模型 ${JSON.stringify(model.id)}）`,
        );
      }
      if (model.name !== ref.name) {
        throw new InputError(
          `${where} 的 name 与模型漂移（引用 ${JSON.stringify(ref.name)}，模型 ${JSON.stringify(model.name)}）`,
        );
      }
      if (model.environment !== cfg.environment) {
        throw new InputError(
          `套件 ${name} 的环境是 ${JSON.stringify(cfg.environment)}，但场景 ${model.id} 的环境是 `
          + `${JSON.stringify(model.environment)}（套件按环境分组 ⇒ 两者必须一致）`,
        );
      }
      entries.push({ ref, model, file: abs });
    }

    suites.push({ name, dir: suiteDir, cfg, entries });
  }

  for (const suite of suites) {
    const envName = suite.cfg.environment;
    if (!envs.has(envName)) {
      const envFile = path.join(envDir, `${envName}.json`);
      if (!fs.existsSync(envFile)) {
        throw new InputError(
          `环境 ${JSON.stringify(envName)} 的环境文件不存在: ${envFile}（base_url 取不到 ⇒ 不能拼 URL）`,
        );
      }
      const env = readJsonFile(envFile, `环境 ${envName}`);
      if (!isObject(env)) throw new InputError(`环境 ${envName} 的文件必须是对象`);
      if (!isFilledString(env.base_url)) {
        throw new InputError(`环境 ${envName} 的文件里没有非空的 base_url（base_url 是 URL 的唯一来源）`);
      }
      envs.set(envName, env);
    }
  }

  return { suites, envs };
}

/**
 * 构造计划：一个套件一个计划文档。
 * @param {{suites: object[], envs: Map<string, object>}} side 读入侧
 * @returns {{name: string, doc: object}[]}
 */
export function buildPlans(side) {
  const plans = [];
  for (const suite of side.suites) {
    const env = side.envs.get(suite.cfg.environment);
    const scenarios = [];
    for (const entry of suite.entries) {
      const model = entry.model;
      const invocations = model.profile.steps.map((step, index) => ({
        step_index: index,
        duration_s: step.duration_s,
        concurrency: step.concurrency,
        argv: buildArgv(model, step, env.base_url),
      }));
      const scenario = {
        scenario_id: model.id,
        scenario_name: model.name,
        runner: model.tool.runner,
        runtime: model.tool.runtime,
        target: model.target,
        base_url: env.base_url,
        profile_type: model.profile.type,
        invocations,
        thresholds_status: model.thresholds_status,
      };
      if (model.thresholds_status === 'provided') {
        scenario.thresholds = clone(model.thresholds);
        scenario.thresholds_source = model.thresholds_source;
      }
      scenario.open_questions = model.open_questions.map((q) => ({
        id: q.id,
        topic: q.topic,
        question: q.question,
      }));
      scenarios.push(scenario);
    }
    plans.push({
      name: suite.name,
      doc: {
        schema_version: 1,
        suite: suite.name,
        environment: suite.cfg.environment,
        scenarios,
      },
    });
  }
  return plans;
}

/**
 * 深比较（**键序无关** —— 键序打乱不算内容变了）。
 * @param {*} a 左值
 * @param {*} b 右值
 * @returns {boolean}
 */
export function deepEqual(a, b) {
  if (a === b) return true;
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false;
    return a.every((item, i) => deepEqual(item, b[i]));
  }
  if (isObject(a) && isObject(b)) {
    const ka = Object.keys(a).sort();
    const kb = Object.keys(b).sort();
    if (ka.length !== kb.length) return false;
    if (!ka.every((k, i) => k === kb[i])) return false;
    return ka.every((k) => deepEqual(a[k], b[k]));
  }
  return false;
}

/**
 * 未决问题（`open_questions`）的**专项比对**。
 *
 * ⚠️ 口径依据（契约 AC-021 ⑧ + 需求方 Q5 裁定：未决问题的具体文字属实现方的判断）：
 *   - `id` 与 `topic` **逐字等于**模型同一条目；
 *   - **条目数相等**、元素**字段集封闭 3**（`id` / `topic` / `question`）；
 *   - `question` **只查「是字符串且去首尾空白后非空」** —— 它的**文字不要求逐字相等**
 *     （REQ-012 不得比契约更严，否则会把合法的自定措辞判成不自洽）。
 *
 * @param {*} expected 期望值（模型侧）
 * @param {*} actual 实际值（产物侧）
 * @param {string} at 路径前缀
 * @param {string[]} out 差异收集器
 */
export function diffOpenQuestions(expected, actual, at, out) {
  if (!Array.isArray(expected) || !Array.isArray(actual)) {
    out.push(`${at}: 类型不同（期望 ${Array.isArray(expected) ? '数组' : '对象'}，实际 ${Array.isArray(actual) ? '数组' : '对象'}）`);
    return;
  }
  if (expected.length !== actual.length) {
    out.push(`${at}: 数组长度不同（期望 ${expected.length}，实际 ${actual.length}）`);
    return;
  }
  for (let i = 0; i < expected.length; i += 1) {
    const itemAt = `${at}[${i}]`;
    const e = isObject(expected[i]) ? expected[i] : {};
    const a = isObject(actual[i]) ? actual[i] : {};
    const eKeys = Object.keys(e).sort();
    const aKeys = Object.keys(a).sort();
    if (eKeys.join(',') !== aKeys.join(',')) {
      out.push(`${itemAt}: 字段集与模型侧不一致（模型 ${eKeys.join(',')}，实际 ${aKeys.join(',')}）`);
    }
    if (!deepEqual(e.id, a.id)) {
      out.push(`${itemAt}.id: 取值不同（期望 ${JSON.stringify(e.id)}，实际 ${JSON.stringify(a.id)}）`);
    }
    if (!deepEqual(e.topic, a.topic)) {
      out.push(`${itemAt}.topic: 取值不同（期望 ${JSON.stringify(e.topic)}，实际 ${JSON.stringify(a.topic)}）`);
    }
    // `question` 只查非空字符串，**不逐字比文字**。
    if (!isFilledString(a.question)) {
      out.push(`${itemAt}.question: 为空或不是字符串（实际 ${JSON.stringify(a.question)}）`);
    }
  }
}

/**
 * 列出两处文档的差异（用于报错信息）。
 * @param {*} expected 期望值
 * @param {*} actual 实际值
 * @param {string} at 路径前缀
 * @param {string[]} out 差异收集器
 */
export function diffDocs(expected, actual, at, out) {
  if (Array.isArray(expected) || Array.isArray(actual)) {
    if (!Array.isArray(expected) || !Array.isArray(actual)) {
      out.push(`${at}: 类型不同（期望 ${Array.isArray(expected) ? '数组' : '对象'}，实际 ${Array.isArray(actual) ? '数组' : '对象'}）`);
      return;
    }
    if (expected.length !== actual.length) {
      out.push(`${at}: 数组长度不同（期望 ${expected.length}，实际 ${actual.length}）`);
      return;
    }
    for (let i = 0; i < expected.length; i += 1) diffDocs(expected[i], actual[i], `${at}[${i}]`, out);
    return;
  }
  if (isObject(expected) && isObject(actual)) {
    const ke = Object.keys(expected).sort();
    const ka = Object.keys(actual).sort();
    for (const key of ke) {
      if (!Object.prototype.hasOwnProperty.call(actual, key)) {
        out.push(`${at}.${key}: 缺少这个键（期望 ${JSON.stringify(expected[key])}）`);
        continue;
      }
      // ⚠️ `open_questions` 走**专项口径**（契约 AC-021 ⑧）：`question` 的文字不要求逐字相等，
      //    只比 `id` / `topic` 逐字 + 条目数 + 字段集封闭 3 + `question` 非空字符串。
      if (key === 'open_questions') {
        diffOpenQuestions(expected[key], actual[key], `${at}.${key}`, out);
        continue;
      }
      diffDocs(expected[key], actual[key], `${at}.${key}`, out);
    }
    for (const key of ka) {
      if (!Object.prototype.hasOwnProperty.call(expected, key)) {
        out.push(`${at}.${key}: 多了这个键（实际 ${JSON.stringify(actual[key])}）`);
      }
    }
    return;
  }
  if (!deepEqual(expected, actual)) {
    out.push(`${at}: 取值不同（期望 ${JSON.stringify(expected)}，实际 ${JSON.stringify(actual)}）`);
  }
}

/**
 * 递归扫「压测结论键 / 执行痕迹键 / 禁表述」。
 * @param {*} node 待扫节点
 * @param {string} at 路径前缀
 * @param {string[]} problems 问题收集器
 */
export function scanForbidden(node, at, problems) {
  if (node === null || typeof node !== 'object') {
    if (typeof node === 'string') {
      for (const phrase of FORBIDDEN_PHRASES) {
        if (node.includes(phrase)) problems.push(`${at}: 出现了禁表述「${phrase}」`);
      }
    }
    return;
  }
  if (Array.isArray(node)) {
    node.forEach((item, i) => scanForbidden(item, `${at}[${i}]`, problems));
    return;
  }
  for (const [key, value] of Object.entries(node)) {
    if (FORBIDDEN_CONCLUSION_KEYS.includes(key)) problems.push(`${at}.${key}: 出现了压测结论键`);
    if (key === 'ok' && value === true) problems.push(`${at}.${key}: 出现了值为 true 的结论键`);
    if (EXECUTION_TRACE_KEYS.includes(key)) problems.push(`${at}.${key}: 出现了执行痕迹键`);
    if (key === 'cases_file') problems.push(`${at}.${key}: 出现了会被上游 suite.json 语义混淆的字段`);
    scanForbidden(value, `${at}.${key}`, problems);
  }
}

/**
 * 计划产物的**自检**（落盘前跑一遍；字段集封闭 / 枚举合法 / 整数合法 / 无结论）。
 * @param {{name: string, doc: object}[]} plans 计划列表
 * @returns {string[]} 问题列表（空数组 = 自洽）
 */
export function inspectPlanDocs(plans) {
  const problems = [];
  for (const plan of plans) {
    const doc = plan.doc;
    const where = plan.name;
    if (!isObject(doc)) {
      problems.push(`${where}: 不是合法 JSON 对象`);
      continue;
    }
    const topKeys = Object.keys(doc).sort();
    if (topKeys.join(',') !== [...PLAN_TOP_FIELDS].sort().join(',')) {
      problems.push(`${where}: 顶层字段集不封闭（实际 ${topKeys.join(',')}）`);
    }
    if (doc.schema_version !== 1) problems.push(`${where}: schema_version 不是 1`);
    if (doc.suite !== plan.name) problems.push(`${where}: suite 字段与文件名不一致`);
    if (!Array.isArray(doc.scenarios) || doc.scenarios.length === 0) {
      problems.push(`${where}: scenarios 必须是非空数组`);
      continue;
    }
    const seenOq = new Set();
    for (const scenario of doc.scenarios) {
      const at = `${where}/${scenario.scenario_id || '?'}`;
      if (!isObject(scenario)) {
        problems.push(`${at}: 不是合法 JSON 对象`);
        continue;
      }
      const cond = scenario.thresholds_status === 'provided' ? PLAN_SCENARIO_COND_FIELDS : [];
      const expect = [...PLAN_SCENARIO_FIELDS, ...cond].sort().join(',');
      const actual = Object.keys(scenario).sort().join(',');
      if (actual !== expect) problems.push(`${at}: 场景条目字段集不封闭（实际 ${actual}）`);
      if (!RUNNERS.includes(scenario.runner)) problems.push(`${at}: runner 取值非法`);
      if (!RUNTIMES.includes(scenario.runtime)) problems.push(`${at}: runtime 取值非法`);
      if (!PROFILE_TYPES.includes(scenario.profile_type)) problems.push(`${at}: profile_type 取值非法`);
      if (!THRESHOLD_STATUSES.includes(scenario.thresholds_status)) {
        problems.push(`${at}: thresholds_status 取值非法`);
      }
      if (scenario.thresholds_status === 'not_provided'
        && (Object.prototype.hasOwnProperty.call(scenario, 'thresholds')
          || Object.prototype.hasOwnProperty.call(scenario, 'thresholds_source'))) {
        problems.push(`${at}: thresholds_status=not_provided 却出现了阈值键`);
      }
      if (!Array.isArray(scenario.open_questions)) {
        problems.push(`${at}: open_questions 必须是数组`);
      } else {
        for (const q of scenario.open_questions) {
          const qKeys = Object.keys(q || {}).sort().join(',');
          if (qKeys !== 'id,question,topic') problems.push(`${at}: 未决问题字段集不封闭（实际 ${qKeys}）`);
          if (!OQ_ID_PATTERN.test(String(q.id))) problems.push(`${at}: 未决问题 id 不合 ^OQ-\\d{3}$`);
          if (seenOq.has(q.id)) problems.push(`${at}: 未决问题 id 在同一计划文件内不唯一（${q.id}）`);
          seenOq.add(q.id);
          if (!OQ_TOPICS.includes(q.topic)) problems.push(`${at}: 未决问题 topic 取值非法`);
          if (!isFilledString(q.question)) problems.push(`${at}: 未决问题 question 为空`);
        }
      }
      if (!Array.isArray(scenario.invocations) || scenario.invocations.length === 0) {
        problems.push(`${at}: invocations 必须是非空数组`);
        continue;
      }
      for (let i = 0; i < scenario.invocations.length; i += 1) {
        const inv = scenario.invocations[i];
        const invAt = `${at}[${i}]`;
        const invKeys = Object.keys(inv || {}).sort().join(',');
        if (invKeys !== [...PLAN_INVOCATION_FIELDS].sort().join(',')) {
          problems.push(`${invAt}: invocation 字段集不封闭（实际 ${invKeys}）`);
        }
        if (inv.step_index !== i) problems.push(`${invAt}: step_index 不等于下标 ${i}`);
        if (!isIntAtLeast(inv.duration_s, 1)) problems.push(`${invAt}: duration_s 不是 ≥1 的整数`);
        if (!isIntAtLeast(inv.concurrency, 1)) problems.push(`${invAt}: concurrency 不是 ≥1 的整数`);
        if (!Array.isArray(inv.argv) || inv.argv.length === 0) {
          problems.push(`${invAt}: argv 必须是非空字符串数组`);
        } else if (!inv.argv.every((x) => typeof x === 'string' && x !== '')) {
          problems.push(`${invAt}: argv 含空元素或非字符串元素`);
        }
      }
    }
    scanForbidden(doc, where, problems);
  }
  return problems;
}
