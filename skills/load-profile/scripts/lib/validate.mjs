// validate.mjs —— **产物侧**自检（契约 F2 / F3 / F4 / F5）
//
// 为什么要有产物侧这一层：上游对 `cases_file` 指向的文件**只校验存在、不校验内容**
// ⇒ 负载模型本体的字段集、枚举取值、引用是否漂移，全靠本层兜住。
//
// 同一份实现服务两个用途：
//   - `make-load-profile.mjs`：**落盘前**对内存里的产物跑一遍（不合法 ⇒ 不落盘）；
//   - `check-load-profile.mjs`：**落盘后**对磁盘上的产物再跑一遍（拿已产出的产物复核）。
//
// ⚠️ 这里只判**产物自身**的自洽性（字段集 / 枚举 / 引用 / 覆盖 / 诚实性）；
//    「与输入逐字相等」由入口脚本在构造期保证。

import fs from 'node:fs';
import path from 'node:path';

import {
  FORBIDDEN_RESULT_KEYS,
  LOAD_SCOPE,
  OPEN_QUESTION_FIELDS,
  OPEN_QUESTION_ID_PATTERN,
  OPEN_QUESTION_TOPICS,
  PRODUCT_SCHEMA_VERSION,
  PROFILE_FIELDS,
  PROFILE_STEP_FIELDS,
  PROFILE_TYPES,
  REFERENCE_ENTRY_FIELDS,
  REFERENCE_FIELDS,
  REPORT_FIELDS,
  RUNNERS,
  RUNTIMES,
  SCENARIO_FIELDS,
  SCENARIO_REQUIRED_FIELDS,
  SUITE_ALLOWED_FIELDS,
  SUITE_DIR_PATTERN,
  SUITE_REQUIRED_FIELDS,
  THRESHOLD_KEYS,
  TOOL_FIELDS,
  TRACEABILITY_FIELDS,
} from './catalog.mjs';
import { isFilledString, isObject } from './io.mjs';

/**
 * 比较两个对象的键集（键序无关）。
 * @param {object} value 待判定对象
 * @param {string[]} expected 期望的键集
 * @returns {string|null} 差异说明（一致时为 null）
 */
function keySetProblem(value, expected) {
  const actual = Object.keys(value).sort();
  const want = [...expected].sort();
  if (actual.length === want.length && actual.every((key, index) => key === want[index])) return null;
  return `实际 {${actual.join(', ')}}，期望 {${want.join(', ')}}`;
}

/**
 * 递归扫「压测结论键」与 `method` 键。
 * @param {*} node 待扫描节点
 * @param {string} where 位置标签
 * @param {string[]} problems 问题清单
 */
function scanForbiddenKeys(node, where, problems) {
  if (Array.isArray(node)) {
    node.forEach((item, index) => scanForbiddenKeys(item, `${where}[${index}]`, problems));
    return;
  }
  if (!isObject(node)) return;
  for (const [key, value] of Object.entries(node)) {
    if (FORBIDDEN_RESULT_KEYS.includes(key)) {
      problems.push(`${where}.${key} 是压测结论键（本 REQ 不发压，产物里不许出现）`);
    }
    if (key === 'method') {
      problems.push(`${where}.method 方法字段不允许出现在负载产物里`);
    }
    scanForbiddenKeys(value, `${where}.${key}`, problems);
  }
}

/**
 * 校验一条未决问题条目。
 * @param {*} question 待校验条目
 * @param {string} where 位置标签
 * @param {Set<string>} seenIds 文件内已用过的 id
 * @param {string[]} problems 问题清单
 */
function checkQuestion(question, where, seenIds, problems) {
  if (!isObject(question)) {
    problems.push(`${where} 必须是对象`);
    return;
  }
  const keyProblem = keySetProblem(question, OPEN_QUESTION_FIELDS);
  if (keyProblem) problems.push(`${where} 的字段集不对：${keyProblem}`);
  if (!isFilledString(question.id) || !OPEN_QUESTION_ID_PATTERN.test(question.id)) {
    problems.push(`${where}.id 不合规（须合 ^OQ-\\d{3}$）`);
  } else if (seenIds.has(question.id)) {
    problems.push(`${where}.id "${question.id}" 在同一个文件里重复`);
  } else {
    seenIds.add(question.id);
  }
  if (!OPEN_QUESTION_TOPICS.includes(question.topic)) {
    problems.push(`${where}.topic "${question.topic}" 不在允许值内（${OPEN_QUESTION_TOPICS.join(' / ')}）`);
  }
  if (!isFilledString(question.question)) {
    problems.push(`${where}.question 必须是非空字符串`);
  }
}

/**
 * 校验一个场景模型本体。
 * @param {string} name 场景短名（= 文件名去扩展名）
 * @param {*} doc 场景文档
 * @param {string[]} problems 问题清单
 */
function checkScenarioDoc(name, doc, problems) {
  const where = `scenarios/${name}.json`;
  if (!isObject(doc)) {
    problems.push(`${where} 不是合法的 JSON 对象`);
    return;
  }
  for (const key of Object.keys(doc)) {
    if (!SCENARIO_FIELDS.includes(key)) problems.push(`${where} 出现表外顶层字段 "${key}"`);
  }
  for (const key of SCENARIO_REQUIRED_FIELDS) {
    if (!(key in doc)) problems.push(`${where} 缺必填字段 "${key}"`);
  }
  if (doc.schema_version !== PRODUCT_SCHEMA_VERSION) {
    problems.push(`${where}.schema_version 必须是 ${PRODUCT_SCHEMA_VERSION}`);
  }
  if (doc.name !== name) {
    problems.push(`${where} 的 name("${doc.name}") 必须等于文件名去扩展名("${name}")`);
  }
  if (!isObject(doc.profile)) {
    problems.push(`${where}.profile 不是对象`);
  } else {
    const keyProblem = keySetProblem(doc.profile, PROFILE_FIELDS);
    if (keyProblem) problems.push(`${where}.profile 的字段集不对：${keyProblem}`);
    if (!PROFILE_TYPES.includes(doc.profile.type)) {
      problems.push(`${where}.profile.type "${doc.profile.type}" 不在允许值内`);
    }
    if (!Array.isArray(doc.profile.steps) || doc.profile.steps.length < 1) {
      problems.push(`${where}.profile.steps 必须是至少 1 项的数组`);
    } else {
      doc.profile.steps.forEach((step, index) => {
        if (!isObject(step)) {
          problems.push(`${where}.profile.steps[${index}] 不是对象`);
          return;
        }
        const stepProblem = keySetProblem(step, PROFILE_STEP_FIELDS);
        if (stepProblem) problems.push(`${where}.profile.steps[${index}] 的字段集不对：${stepProblem}`);
      });
    }
  }
  if (!isObject(doc.tool)) {
    problems.push(`${where}.tool 不是对象`);
  } else {
    const keyProblem = keySetProblem(doc.tool, TOOL_FIELDS);
    if (keyProblem) problems.push(`${where}.tool 的字段集不对：${keyProblem}`);
    if (!RUNNERS.includes(doc.tool.runner)) {
      problems.push(`${where}.tool.runner "${doc.tool.runner}" 不在允许值内`);
    }
    if (!RUNTIMES.includes(doc.tool.runtime)) {
      problems.push(`${where}.tool.runtime "${doc.tool.runtime}" 不在允许值内`);
    }
  }
  if (doc.thresholds_status !== 'provided' && doc.thresholds_status !== 'not_provided') {
    problems.push(`${where}.thresholds_status 取值非法（只能是 provided / not_provided）`);
  } else if (doc.thresholds_status === 'provided') {
    if (!('thresholds' in doc)) problems.push(`${where} 声称有指标来源却没有 thresholds 键`);
    if (!('thresholds_source' in doc)) problems.push(`${where} 声称有指标来源却没有 thresholds_source 键`);
    if (isObject(doc.thresholds)) {
      for (const key of Object.keys(doc.thresholds)) {
        if (!THRESHOLD_KEYS.includes(key)) problems.push(`${where}.thresholds 出现表外键 "${key}"`);
      }
    }
  } else {
    if ('thresholds' in doc) problems.push(`${where} 没有指标来源却写了 thresholds 键`);
    if ('thresholds_source' in doc) problems.push(`${where} 没有指标来源却写了 thresholds_source 键`);
  }
  if (!isObject(doc.traceability)) {
    problems.push(`${where}.traceability 不是对象`);
  } else {
    const keyProblem = keySetProblem(doc.traceability, TRACEABILITY_FIELDS);
    if (keyProblem) problems.push(`${where}.traceability 的字段集不对：${keyProblem}`);
    if (!Array.isArray(doc.traceability.requirement_refs)) {
      problems.push(`${where}.traceability.requirement_refs 必须是数组`);
    }
    if (!Array.isArray(doc.traceability.case_refs)) {
      problems.push(`${where}.traceability.case_refs 必须是数组`);
    }
  }
  const questions = doc.open_questions;
  if (!Array.isArray(questions)) {
    problems.push(`${where}.open_questions 必须是数组`);
  } else {
    const seenIds = new Set();
    questions.forEach((question, index) => {
      checkQuestion(question, `${where}.open_questions[${index}]`, seenIds, problems);
    });
    const thresholdQuestions = questions.filter(
      (question) => isObject(question) && question.topic === 'thresholds',
    );
    if (doc.thresholds_status === 'not_provided' && thresholdQuestions.length < 1) {
      problems.push(`${where} 没有指标来源却没有 topic=thresholds 的未决问题`);
    }
    if (doc.thresholds_status === 'provided' && thresholdQuestions.length > 0) {
      problems.push(`${where} 有指标来源却留了 topic=thresholds 的未决问题`);
    }
    const caseRefs = isObject(doc.traceability) && Array.isArray(doc.traceability.case_refs)
      ? doc.traceability.case_refs
      : [];
    if (caseRefs.length === 0) {
      const coverageQuestions = questions.filter(
        (question) => isObject(question) && question.topic === 'coverage',
      );
      if (coverageQuestions.length < 1) {
        problems.push(`${where} 没有对应用例却没有 topic=coverage 的未决问题`);
      }
    }
  }
  scanForbiddenKeys(doc, where, problems);
}

/**
 * 校验一整套产物（场景本体 + 套件 + 计划清单）。
 * @param {{scenarios: {name: string, doc: any}[], suites: {dirName: string, suiteDoc: any, refDoc: any}[], report: any}} products 产物集合
 * @returns {string[]} 问题清单（空数组 = 自洽）
 */
export function inspectProducts(products) {
  const problems = [];
  const bodies = new Map();
  for (const scenario of products.scenarios) {
    bodies.set(scenario.name, scenario.doc);
  }

  // --- 场景本体 ---
  for (const scenario of products.scenarios) {
    if (!/^[a-z0-9][a-z0-9-]*$/.test(scenario.name)) {
      problems.push(`scenarios/${scenario.name}.json 的文件名不合命名约定 ^[a-z0-9][a-z0-9-]*$`);
    }
    checkScenarioDoc(scenario.name, scenario.doc, problems);
  }

  // --- 套件 ---
  const referenced = new Map();
  for (const suite of products.suites) {
    const where = `suites/${suite.dirName}`;
    if (!SUITE_DIR_PATTERN.test(suite.dirName)) {
      problems.push(`${where} 的目录名不合 ^LOAD-\\d{3}-<短名>$`);
    }
    if (!isObject(suite.suiteDoc)) {
      problems.push(`${where}/suite.json 不是合法的 JSON 对象`);
    } else {
      for (const key of Object.keys(suite.suiteDoc)) {
        if (!SUITE_ALLOWED_FIELDS.includes(key)) {
          problems.push(`${where}/suite.json 出现表外字段 "${key}"（顶层字段集封闭）`);
        }
      }
      for (const key of SUITE_REQUIRED_FIELDS) {
        if (!isFilledString(suite.suiteDoc[key])) {
          problems.push(`${where}/suite.json 缺必填字段 "${key}"（须为非空字符串）`);
        }
      }
      if (suite.suiteDoc.scope !== LOAD_SCOPE) problems.push(`${where}/suite.json 的 scope 必须是 "${LOAD_SCOPE}"`);
      if (suite.suiteDoc.executor !== LOAD_SCOPE) problems.push(`${where}/suite.json 的 executor 必须是 "${LOAD_SCOPE}"`);
      if (suite.suiteDoc.cases_file !== 'scenario.json') {
        problems.push(`${where}/suite.json 的 cases_file 必须是 "scenario.json"`);
      }
      if (suite.suiteDoc.suite !== suite.dirName) {
        problems.push(`${where}/suite.json 的 suite("${suite.suiteDoc.suite}") 必须等于所在目录名`);
      }
      scanForbiddenKeys(suite.suiteDoc, `${where}/suite.json`, problems);
    }
    if (!isObject(suite.refDoc)) {
      problems.push(`${where}/scenario.json 不是合法的 JSON 对象`);
      continue;
    }
    const keyProblem = keySetProblem(suite.refDoc, REFERENCE_FIELDS);
    if (keyProblem) problems.push(`${where}/scenario.json 的字段集不对：${keyProblem}`);
    if (suite.refDoc.schema_version !== PRODUCT_SCHEMA_VERSION) {
      problems.push(`${where}/scenario.json 的 schema_version 必须是 ${PRODUCT_SCHEMA_VERSION}`);
    }
    if (suite.refDoc.suite !== suite.dirName) {
      problems.push(`${where}/scenario.json 的 suite("${suite.refDoc.suite}") 必须等于所在目录名`);
    }
    if (!Array.isArray(suite.refDoc.scenarios) || suite.refDoc.scenarios.length < 1) {
      problems.push(`${where}/scenario.json 的 scenarios 必须是至少 1 项的数组`);
      continue;
    }
    for (const entry of suite.refDoc.scenarios) {
      if (!isObject(entry)) {
        problems.push(`${where}/scenario.json 的 scenarios 元素不是对象`);
        continue;
      }
      const entryProblem = keySetProblem(entry, REFERENCE_ENTRY_FIELDS);
      if (entryProblem) problems.push(`${where}/scenario.json 的引用元素字段集不对：${entryProblem}`);
      if (!isFilledString(entry.path)) {
        problems.push(`${where}/scenario.json 的引用缺 path`);
        continue;
      }
      const targetName = path.basename(entry.path);
      if (targetName !== `${entry.name}.json`) {
        problems.push(`${where}/scenario.json 的引用 path 指向 "${targetName}"，与 name("${entry.name}") 不一致`);
      }
      const body = bodies.get(entry.name);
      if (!body) {
        problems.push(`${where}/scenario.json 的引用指向不存在的场景模型 "${entry.path}"`);
        continue;
      }
      if (body.id !== entry.id) {
        problems.push(`${where}/scenario.json 的引用 id "${entry.id}" 与本体 "${body.id}" 漂移`);
      }
      if (body.name !== entry.name) {
        problems.push(`${where}/scenario.json 的引用 name "${entry.name}" 与本体 "${body.name}" 漂移`);
      }
      const count = referenced.get(entry.id) || 0;
      referenced.set(entry.id, count + 1);
    }
  }

  // --- 双向覆盖完整性 ---
  for (const scenario of products.scenarios) {
    const id = isObject(scenario.doc) ? scenario.doc.id : null;
    const count = referenced.get(id) || 0;
    if (count !== 1) {
      problems.push(`容量目标 ${id} 被 ${count} 个套件引用（应当恰好 1 个）`);
    }
  }

  // --- 压测计划清单 ---
  if (!isObject(products.report)) {
    problems.push('report.json 不是合法的 JSON 对象');
  } else {
    const keyProblem = keySetProblem(products.report, REPORT_FIELDS);
    if (keyProblem) problems.push(`report.json 的顶层字段集不对：${keyProblem}`);
    if (!Array.isArray(products.report.open_questions)) {
      problems.push('report.json 的 open_questions 必须是数组');
    } else {
      const seenIds = new Set();
      products.report.open_questions.forEach((question, index) => {
        checkQuestion(question, `report.json 的 open_questions[${index}]`, seenIds, problems);
      });
    }
    scanForbiddenKeys(products.report, 'report.json', problems);
  }

  return problems;
}

/**
 * 落盘前自检：产物不合法 ⇒ 抛错（调用方据此**不落盘**）。
 * @param {object} products 产物集合
 */
export function assertProductInvariants(products) {
  const problems = inspectProducts(products);
  if (problems.length > 0) {
    throw new Error(`产物自检不通过：\n${problems.map((item) => `- ${item}`).join('\n')}`);
  }
}

/**
 * 读磁盘上的产物并自检（给 check-load-profile.mjs 用）。
 * @param {string} loadDir test-assets/load 的绝对路径
 * @returns {string[]} 问题清单（空数组 = 自洽）
 */
export function inspectProductsOnDisk(loadDir) {
  const problems = [];
  const scenarios = [];
  const scenarioDir = path.join(loadDir, 'scenarios');
  let scenarioFiles = [];
  try {
    scenarioFiles = fs
      .readdirSync(scenarioDir, { withFileTypes: true })
      .filter((entry) => entry.isFile() && entry.name.endsWith('.json'))
      .map((entry) => entry.name)
      .sort();
  } catch {
    problems.push(`找不到场景目录: ${scenarioDir}`);
  }
  for (const file of scenarioFiles) {
    const name = file.replace(/\.json$/, '');
    let doc = null;
    try {
      doc = JSON.parse(fs.readFileSync(path.join(scenarioDir, file), 'utf8'));
    } catch (err) {
      problems.push(`scenarios/${file} 不是合法 JSON（${err.message}）`);
      continue;
    }
    scenarios.push({ name, doc });
  }

  const suites = [];
  const suitesDir = path.join(loadDir, 'suites');
  let suiteDirs = [];
  try {
    suiteDirs = fs
      .readdirSync(suitesDir, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .sort();
  } catch {
    problems.push(`找不到套件目录: ${suitesDir}`);
  }
  for (const dirName of suiteDirs) {
    const dir = path.join(suitesDir, dirName);
    const readOne = (file) => {
      try {
        return JSON.parse(fs.readFileSync(path.join(dir, file), 'utf8'));
      } catch (err) {
        problems.push(`suites/${dirName}/${file} 不是合法 JSON（${err.message}）`);
        return null;
      }
    };
    suites.push({ dirName, suiteDoc: readOne('suite.json'), refDoc: readOne('scenario.json') });
  }

  let report = null;
  try {
    report = JSON.parse(fs.readFileSync(path.join(loadDir, 'report.json'), 'utf8'));
  } catch (err) {
    problems.push(`report.json 不是合法 JSON（${err.message}）`);
  }

  problems.push(...inspectProducts({ scenarios, suites, report }));
  return problems;
}
