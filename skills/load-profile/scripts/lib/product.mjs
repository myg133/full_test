// product.mjs —— 负载模型的**产物构造与落盘**（契约 F2 / F3 / F8）
//
// 产物形状：
//   <out-dir>/test-assets/load/
//   ├── report.json                                 压测计划清单（套件 ↔ 场景映射 + 未决问题）
//   ├── scenarios/<场景>.json                       负载模型本体（每个容量目标一个）
//   └── suites/LOAD-<编号>-<短名>/
//       ├── scenario.json                           套件级**引用件**（指向 scenarios/）
//       └── suite.json                              执行配置（scope=load / executor=load）
//
// 三条硬约束：
//   1. **字段集封闭**：场景本体顶层封闭 14 个；引用件顶层封闭 3 个；
//      `suite.json` 顶层 ⊆ 上游 9 个允许字段（**不许**出现 scope 专属字段）。
//   2. **逐字可追溯**：profile / tool / args / thresholds / thresholds_source /
//      target / environment / service 全部**逐字等于**输入（键序无关，值逐字）。
//   3. **诚实**：`thresholds_status` 二态 + 阈值键的**有无**表达「有没有指标来源」；
//      没有来源就**不写阈值**，并留一条 `topic = "thresholds"` 的未决问题；
//      没有对应用例就留一条 `topic = "coverage"` 的未决问题。
//
// ⚠️ 产物里**不含**生成时间戳 ⇒ 同一输入两次跑出来的文件逐字相同。

import path from 'node:path';

import {
  LOAD_SCOPE,
  OPEN_QUESTION_ID_PATTERN,
  PRODUCT_SCHEMA_VERSION,
  REQUIREMENT_ID,
  REPORT_SCHEMA_VERSION,
  SCENARIO_RELATIVE_PREFIX,
} from './catalog.mjs';
import { clone, ensureDir, isObject, writeJsonFile } from './io.mjs';
import { collectCaseRefs } from './reconcile.mjs';

/**
 * 造一条未决问题（封闭 3 个字段）。
 * @param {number} seq 序号（1 起）
 * @param {string} topic 主题
 * @param {string} question 问题正文（非空）
 * @returns {{id: string, topic: string, question: string}}
 */
function makeQuestion(seq, topic, question) {
  const id = `OQ-${String(seq).padStart(3, '0')}`;
  if (!OPEN_QUESTION_ID_PATTERN.test(id)) {
    throw new Error(`未决问题 id 不合规: ${id}`);
  }
  return { id, topic, question };
}

/**
 * 构造全部产物（不落盘 —— 落盘前先过一遍产物侧自检）。
 * @param {{context: object, casesDoc: *}} input 归一化后的上下文 + 可选的功能用例集
 * @returns {{scenarios: object[], suites: object[], report: object, openQuestions: object[]}}
 */
export function buildProducts({ context, casesDoc }) {
  const serviceName = context.service.name;
  const scenarios = [];
  const suiteMembers = new Map();
  const derivedQuestions = [];
  let questionSeq = 0;

  for (const workload of context.workloads) {
    const hasThresholds = 'thresholds' in workload;
    const caseRefs = collectCaseRefs(casesDoc, workload.target);

    // --- 该场景自己的未决问题（缺口必须显式） ---
    const questions = [];
    if (!hasThresholds) {
      questionSeq += 1;
      const question = makeQuestion(
        questionSeq,
        'thresholds',
        `容量目标 ${workload.id}（${workload.name}）没有给出指标来源：需求侧尚未提供该链路的性能指标口径，` +
          '阈值无从谈起；请需求方补充指标来源与阈值口径，在此之前本场景不写任何阈值。',
      );
      questions.push(question);
      derivedQuestions.push({ ...question, workload_id: workload.id });
    }
    if (caseRefs.length === 0) {
      questionSeq += 1;
      const question = makeQuestion(
        questionSeq,
        'coverage',
        `容量目标 ${workload.id}（${workload.name}）在被压链路 "${workload.target}" 上没有对应用例：` +
          '功能用例集里找不到这条链路 ⇒ 该负载目标没有回归护栏，压测结论没有对照基准；' +
          '请补一条功能用例，或确认该链路不需要功能对照。',
      );
      questions.push(question);
      derivedQuestions.push({ ...question, workload_id: workload.id });
    }

    // --- 场景本体（顶层封闭 14 个；thresholds / thresholds_source / args 是条件字段） ---
    const scenarioDoc = {
      schema_version: PRODUCT_SCHEMA_VERSION,
      id: workload.id,
      name: workload.name,
      service: serviceName,
      target: workload.target,
      environment: workload.environment,
      profile: clone(workload.profile),
      ...(hasThresholds
        ? { thresholds: clone(workload.thresholds), thresholds_source: workload.thresholds_source }
        : {}),
      thresholds_status: hasThresholds ? 'provided' : 'not_provided',
      tool: clone(workload.tool),
      ...(isObject(workload.args) ? { args: clone(workload.args) } : {}),
      traceability: {
        workload_id: workload.id,
        requirement_refs: Array.isArray(workload.requirement_refs) ? [...workload.requirement_refs] : [],
        case_refs: [...caseRefs],
      },
      open_questions: questions,
    };

    scenarios.push({ name: workload.name, doc: scenarioDoc });

    if (!suiteMembers.has(workload.environment)) suiteMembers.set(workload.environment, []);
    suiteMembers.get(workload.environment).push({ workload, scenarioDoc });
  }

  // --- 套件：按 environments[] 的出现顺序编号，同环境的容量目标归入同一个套件 ---
  const suites = [];
  const envOrder = [];
  for (const environment of context.environments) {
    if (!envOrder.includes(environment.name)) envOrder.push(environment.name);
  }
  let suiteNumber = 0;
  for (const environmentName of envOrder) {
    const members = suiteMembers.get(environmentName);
    if (!members || members.length === 0) continue;
    suiteNumber += 1;
    const dirName = `LOAD-${String(suiteNumber).padStart(3, '0')}-${members[0].workload.name}`;
    suites.push({
      dirName,
      environment: environmentName,
      suiteDoc: {
        suite: dirName,
        requirement: REQUIREMENT_ID,
        scope: LOAD_SCOPE,
        environment: environmentName,
        cases_file: 'scenario.json',
        executor: LOAD_SCOPE,
      },
      refDoc: {
        schema_version: PRODUCT_SCHEMA_VERSION,
        suite: dirName,
        scenarios: members.map((member) => ({
          path: `${SCENARIO_RELATIVE_PREFIX}${member.workload.name}.json`,
          id: member.workload.id,
          name: member.workload.name,
        })),
      },
    });
  }

  // --- 压测计划清单 ---
  const reportQuestions = [];
  let reportSeq = 0;
  for (const question of derivedQuestions) {
    reportSeq += 1;
    reportQuestions.push({
      id: `OQ-${String(reportSeq).padStart(3, '0')}`,
      topic: question.topic,
      question: question.question,
    });
  }
  for (const question of context.openQuestions) {
    reportSeq += 1;
    reportQuestions.push({
      id: `OQ-${String(reportSeq).padStart(3, '0')}`,
      topic: question.topic,
      question: question.question,
    });
  }

  const report = {
    schema_version: REPORT_SCHEMA_VERSION,
    service: clone(context.service),
    suites: suites.map((suite) => ({
      suite: suite.dirName,
      requirement: REQUIREMENT_ID,
      environment: suite.environment,
      scenarios: suite.refDoc.scenarios.map((entry) => ({
        id: entry.id,
        name: entry.name,
        path: `scenarios/${entry.name}.json`,
      })),
    })),
    scenarios: scenarios.map((scenario) => ({
      id: scenario.doc.id,
      name: scenario.doc.name,
      path: `scenarios/${scenario.name}.json`,
      environment: scenario.doc.environment,
      suite: (suites.find((suite) =>
        suite.refDoc.scenarios.some((entry) => entry.id === scenario.doc.id),
      ) || { dirName: '' }).dirName,
      thresholds_status: scenario.doc.thresholds_status,
    })),
    open_questions: reportQuestions,
  };

  return { scenarios, suites, report, openQuestions: reportQuestions };
}

/**
 * 落盘（**只写** <load-dir>/ 下面；调用方保证该目录此前不存在或为空）。
 * @param {string} loadDir test-assets/load 的绝对路径
 * @param {{scenarios: object[], suites: object[], report: object}} products 构造好的产物
 * @returns {string[]} 写出的文件相对路径（相对 loadDir）
 */
export function writeProducts(loadDir, products) {
  const written = [];
  const scenarioDir = path.join(loadDir, 'scenarios');
  ensureDir(scenarioDir);
  for (const scenario of products.scenarios) {
    const file = path.join(scenarioDir, `${scenario.name}.json`);
    writeJsonFile(file, scenario.doc);
    written.push(path.join('scenarios', `${scenario.name}.json`));
  }
  for (const suite of products.suites) {
    const dir = path.join(loadDir, 'suites', suite.dirName);
    ensureDir(dir);
    writeJsonFile(path.join(dir, 'scenario.json'), suite.refDoc);
    writeJsonFile(path.join(dir, 'suite.json'), suite.suiteDoc);
    written.push(path.join('suites', suite.dirName, 'scenario.json'));
    written.push(path.join('suites', suite.dirName, 'suite.json'));
  }
  writeJsonFile(path.join(loadDir, 'report.json'), products.report);
  written.push('report.json');
  return written;
}
