#!/usr/bin/env node
/**
 * check-security-plan.mjs —— 安全规划产物的自洽校验器。
 *
 * 用法:
 *   node scripts/check-security-plan.mjs <项目根>
 *
 * 查什么（对照 references/ 的产物契约）:
 *   1. threat-model.json：威胁条目字段集**封闭 12 个**、id 唯一且合 `^TH-\d+$`、
 *      枚举合法、三个引用数组不悬空、`source` 含 `scan` ⇔ `scan_refs` 非空；
 *   2. owasp_coverage：键集**恰为** A01~A10，每类都有交代；
 *      `covered` ⇒ threat_refs 非空且**恰为**该类全部威胁；`not_applicable` ⇒ 理由非空
 *      + 指向一条 category 等于该类的未决问题 + 该类**没有任何**威胁；
 *   3. supplements：键集**恰为**四类实战补充，逐类显式判定，双向对应；
 *   4. scan / scan_findings：状态四态合法；finding 数与声明一致；每条 finding 映射到
 *      真实威胁，且被引用威胁的 `source` 含 `scan`、`scan_refs` 含该 finding；
 *   5. matrix.json：角色 / 资源集合非空、条目不悬空、每个 (role, resource) 至少一条、
 *      `gap` ⇔ allow + 越权类威胁、越权类威胁**双向**被 gap 引用；
 *   6. 套件：目录名合规、`suite.json` 顶层字段集 ⊆ 9 个允许字段、`suite` == 目录名、
 *      `scope`/`executor` == security、`environment`/`cases_file` 真实存在；
 *   7. cases.json：顶层字段集**恰好 7 个**、`schema_version == 2`、需求条目与威胁双向覆盖、
 *      覆盖矩阵与需求条目一一对应、方法号**确实存在于方法库**、`status` 恒为 `active`、
 *      `dimension` 恒为 `security`、用例 id 合 `^TC-\d{3}$` 且跨套件唯一、tags 含
 *      `security` 与威胁 id。
 *
 * 退出码: 0 = 自洽 / 1 = 不自洽 / 2 = 用法错误。
 *
 * 纯 Node.js：只用 node: 内置模块，零第三方依赖，不联网；**只读**产物，不改任何东西。
 */

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

import { isFilledString, isObject } from './lib/io.mjs';
import { loadMethodIds } from './lib/catalog.mjs';
import { OWASP_CODES, SEVERITIES, STRIDE_CATEGORIES, SUPPLEMENT_KEYS } from './lib/catalog.mjs';
import { THREAT_FIELDS } from './lib/threats.mjs';
import { CASES_TOP_LEVEL_FIELDS } from './lib/cases.mjs';
import { checkMatrix } from './lib/matrix.mjs';

/** suite.json 允许的顶层字段（封闭 9 个）。 */
const SUITE_ALLOWED_FIELDS = [
  'suite', 'requirement', 'scope', 'environment', 'cases_file', 'executor',
  'base_url_from', 'tags', 'report',
];
/** suite.json 的必填字段。 */
const SUITE_REQUIRED_FIELDS = ['suite', 'requirement', 'scope', 'environment', 'cases_file', 'executor'];
/** 用例优先级枚举。 */
const PRIORITIES = ['P0', 'P1', 'P2', 'P3'];
/** 用例 id 形态。 */
const CASE_ID_PATTERN = /^TC-\d{3}$/;
/** 威胁 id 形态。 */
const THREAT_ID_PATTERN = /^TH-\d+$/;
/** 扫描发现 id 形态。 */
const SCAN_ID_PATTERN = /^SCAN-\d+$/;
/** 套件目录名形态。 */
const SUITE_DIR_PATTERN = /^SEC-\d{3}-[a-z0-9][a-z0-9-]*$/;
/** 扫描状态枚举。 */
const SCAN_STATUSES = ['provided', 'not_provided', 'unavailable', 'failed'];

/**
 * 读一个 JSON 文件；读不到或解析失败即记问题并返回 null。
 * @param {string} file 文件路径
 * @param {string} label 人读标签
 * @param {string[]} problems 问题清单
 * @returns {object|null}
 */
function readJson(file, label, problems) {
  if (!fs.existsSync(file)) {
    problems.push(`${label} 不存在: ${file}`);
    return null;
  }
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (err) {
    problems.push(`${label} 不是合法 JSON: ${file}（${err && err.message ? err.message : String(err)}）`);
    return null;
  }
}

/**
 * 校验威胁模型文档。
 * @param {object} doc threat-model.json
 * @param {string[]} problems 问题清单
 * @returns {{threats: object[], byId: Map<string, object>}}
 */
export function checkThreatModel(doc, problems) {
  const push = (message) => problems.push(message);
  if (!isObject(doc)) {
    push('threat-model.json 的根节点必须是对象');
    return { threats: [], byId: new Map() };
  }
  for (const field of ['schema_version', 'meta', 'assets', 'trust_boundaries', 'entry_points',
    'threats', 'owasp_coverage', 'supplements', 'scan', 'scan_findings', 'open_questions']) {
    if (doc[field] === undefined) push(`threat-model.json 缺少顶层字段 ${field}`);
  }

  const assetIds = new Set((doc.assets || []).map((item) => item.id));
  const boundaryIds = new Set((doc.trust_boundaries || []).map((item) => item.id));
  const entryIds = new Set((doc.entry_points || []).map((item) => item.id));

  const threats = Array.isArray(doc.threats) ? doc.threats : [];
  if (threats.length === 0) push('threats 为空（至少要有一条威胁）');
  const byId = new Map();
  threats.forEach((threat, index) => {
    const at = `threats[${index}]`;
    if (!isObject(threat)) {
      push(`${at} 必须是对象`);
      return;
    }
    for (const key of Object.keys(threat)) {
      if (!THREAT_FIELDS.includes(key)) push(`${at} 出现未声明的字段 ${key}（字段集封闭 12 个）`);
    }
    for (const key of THREAT_FIELDS) {
      if (threat[key] === undefined) push(`${at} 缺少字段 ${key}`);
    }
    if (!THREAT_ID_PATTERN.test(String(threat.id))) push(`${at}.id 非法: ${JSON.stringify(threat.id)}`);
    if (byId.has(threat.id)) push(`${at}.id 重复: ${threat.id}`);
    byId.set(threat.id, threat);
    if (!isFilledString(threat.name)) push(`${at}.name 必须是非空字符串`);
    if (!STRIDE_CATEGORIES.includes(threat.category)) push(`${at}.category 取值非法: ${threat.category}`);
    if (!OWASP_CODES.includes(threat.owasp)) push(`${at}.owasp 取值非法: ${threat.owasp}`);
    if (!SEVERITIES.includes(threat.severity)) push(`${at}.severity 取值非法: ${threat.severity}`);
    if (!['model', 'scan', 'model+scan'].includes(threat.source)) push(`${at}.source 取值非法: ${threat.source}`);
    if (!isFilledString(threat.rationale)) push(`${at}.rationale 必须是非空字符串`);
    for (const key of ['asset_refs', 'boundary_refs', 'entry_point_refs', 'scan_refs', 'supplement_refs']) {
      if (!Array.isArray(threat[key])) push(`${at}.${key} 必须是数组`);
    }
    for (const key of ['asset_refs', 'boundary_refs', 'entry_point_refs']) {
      if (Array.isArray(threat[key]) && threat[key].length === 0) push(`${at}.${key} 为空`);
    }
    for (const ref of threat.asset_refs || []) {
      if (!assetIds.has(ref)) push(`${at}.asset_refs 悬空引用: ${ref}`);
    }
    for (const ref of threat.boundary_refs || []) {
      if (!boundaryIds.has(ref)) push(`${at}.boundary_refs 悬空引用: ${ref}`);
    }
    for (const ref of threat.entry_point_refs || []) {
      if (!entryIds.has(ref)) push(`${at}.entry_point_refs 悬空引用: ${ref}`);
    }
    const sourceHasScan = String(threat.source || '').includes('scan');
    const scanRefs = Array.isArray(threat.scan_refs) ? threat.scan_refs : [];
    if (sourceHasScan && scanRefs.length === 0) {
      push(`${at}.source 含 scan，但 scan_refs 为空`);
    }
    if (!sourceHasScan && scanRefs.length > 0) {
      push(`${at}.scan_refs 非空，但 source 不含 scan`);
    }
    for (const ref of threat.supplement_refs || []) {
      if (!SUPPLEMENT_KEYS.includes(ref)) push(`${at}.supplement_refs 取值非法: ${ref}`);
    }
  });

  // --- OWASP 十类 ---
  const coverage = isObject(doc.owasp_coverage) ? doc.owasp_coverage : {};
  for (const key of Object.keys(coverage)) {
    if (!OWASP_CODES.includes(key)) push(`owasp_coverage 出现未声明的键 ${key}`);
  }
  const questions = Array.isArray(doc.open_questions) ? doc.open_questions : [];
  const questionById = new Map();
  questions.forEach((question, index) => {
    const at = `open_questions[${index}]`;
    if (!isObject(question)) {
      push(`${at} 必须是对象`);
      return;
    }
    if (!isFilledString(question.id)) push(`${at}.id 必须是非空字符串`);
    if (questionById.has(question.id)) push(`${at}.id 重复: ${question.id}`);
    questionById.set(question.id, question);
    if (!isFilledString(question.question)) push(`${at}.question 必须是非空字符串`);
    if (!isFilledString(question.reason)) push(`${at}.reason 必须是非空字符串`);
    if (!OWASP_CODES.includes(question.category) && !SUPPLEMENT_KEYS.includes(question.category)) {
      push(`${at}.category 取值非法: ${question.category}`);
    }
  });

  for (const code of OWASP_CODES) {
    const entry = coverage[code];
    if (entry === undefined) {
      push(`owasp_coverage 缺少 ${code}（十类每类都必须有交代，不许静默跳过）`);
      continue;
    }
    const actual = threats.filter((threat) => threat.owasp === code).map((threat) => threat.id);
    if (entry.status === 'covered') {
      if (!Array.isArray(entry.threat_refs) || entry.threat_refs.length === 0) {
        push(`owasp_coverage.${code} 判为 covered，但 threat_refs 为空`);
        continue;
      }
      for (const ref of entry.threat_refs) {
        if (!byId.has(ref)) push(`owasp_coverage.${code}.threat_refs 悬空引用: ${ref}`);
        else if (byId.get(ref).owasp !== code) push(`owasp_coverage.${code}.threat_refs 指向了 owasp=${byId.get(ref).owasp} 的威胁`);
      }
      for (const id of actual) {
        if (!entry.threat_refs.includes(id)) push(`owasp_coverage.${code} 漏掉了该类的威胁 ${id}`);
      }
    } else if (entry.status === 'not_applicable') {
      if (!isFilledString(entry.reason)) push(`owasp_coverage.${code} 判为 not_applicable，但 reason 为空`);
      if (!isFilledString(entry.open_question_ref)) {
        push(`owasp_coverage.${code} 判为 not_applicable，但没有 open_question_ref`);
      } else {
        const question = questionById.get(entry.open_question_ref);
        if (!question) push(`owasp_coverage.${code}.open_question_ref 悬空引用: ${entry.open_question_ref}`);
        else if (question.category !== code) {
          push(`owasp_coverage.${code}.open_question_ref 指向的未决问题 category=${question.category}`);
        }
      }
      if (actual.length > 0) {
        push(`owasp_coverage.${code} 判为 not_applicable，却有该类威胁（${actual.join(' / ')}）`);
      }
    } else {
      push(`owasp_coverage.${code}.status 取值非法: ${JSON.stringify(entry.status)}`);
    }
  }

  // --- 四类实战补充 ---
  const supplements = isObject(doc.supplements) ? doc.supplements : {};
  for (const key of Object.keys(supplements)) {
    if (!SUPPLEMENT_KEYS.includes(key)) push(`supplements 出现未声明的键 ${key}`);
  }
  for (const key of SUPPLEMENT_KEYS) {
    const entry = supplements[key];
    if (entry === undefined) {
      push(`supplements 缺少 ${key}（四类必须逐类显式判定，不许静默跳过）`);
      continue;
    }
    const actual = threats
      .filter((threat) => (threat.supplement_refs || []).includes(key))
      .map((threat) => threat.id);
    if (entry.status === 'covered') {
      if (!Array.isArray(entry.threat_refs) || entry.threat_refs.length === 0) {
        push(`supplements.${key} 判为 covered，但 threat_refs 为空`);
        continue;
      }
      for (const ref of entry.threat_refs) {
        if (!byId.has(ref)) push(`supplements.${key}.threat_refs 悬空引用: ${ref}`);
        else if (!(byId.get(ref).supplement_refs || []).includes(key)) {
          push(`supplements.${key}.threat_refs 指向的威胁没有把 ${key} 写进 supplement_refs`);
        }
      }
      for (const id of actual) {
        if (!entry.threat_refs.includes(id)) push(`supplements.${key} 漏掉了该类的威胁 ${id}`);
      }
    } else if (entry.status === 'not_applicable') {
      if (!isFilledString(entry.reason)) push(`supplements.${key} 判为 not_applicable，但 reason 为空`);
      if (actual.length > 0) {
        push(`supplements.${key} 判为 not_applicable，却有该类威胁（${actual.join(' / ')}）`);
      }
    } else {
      push(`supplements.${key}.status 取值非法: ${JSON.stringify(entry.status)}`);
    }
  }

  // --- 扫描 ---
  const scan = isObject(doc.scan) ? doc.scan : null;
  if (scan === null) {
    push('scan 必须是对象');
  } else {
    if (!SCAN_STATUSES.includes(scan.status)) push(`scan.status 取值非法: ${scan.status}`);
    const findings = Array.isArray(doc.scan_findings) ? doc.scan_findings : [];
    if (typeof scan.finding_count === 'number' && scan.finding_count !== findings.length) {
      push(`scan.finding_count=${scan.finding_count} 与 scan_findings 条数 ${findings.length} 不一致`);
    }
    if (scan.status !== 'provided' && findings.length > 0) {
      push(`scan.status=${scan.status} 时 scan_findings 必须为空数组`);
    }
    if (scan.status === 'not_provided') {
      for (const threat of threats) {
        if (String(threat.source || '').includes('scan')) {
          push(`未提供扫描，却出现了 source 含 scan 的威胁 ${threat.id}`);
        }
      }
    }
    findings.forEach((finding, index) => {
      const at = `scan_findings[${index}]`;
      if (!isObject(finding)) {
        push(`${at} 必须是对象`);
        return;
      }
      if (!SCAN_ID_PATTERN.test(String(finding.id))) push(`${at}.id 非法: ${JSON.stringify(finding.id)}`);
      if (!isFilledString(finding.summary)) push(`${at}.summary 必须是非空字符串`);
      if (!Array.isArray(finding.threat_refs) || finding.threat_refs.length === 0) {
        push(`${at}.threat_refs 必须非空`);
        return;
      }
      for (const ref of finding.threat_refs) {
        const threat = byId.get(ref);
        if (!threat) {
          push(`${at}.threat_refs 悬空引用: ${ref}`);
          continue;
        }
        if (!String(threat.source || '').includes('scan')) {
          push(`${at} 引用的威胁 ${ref} 的 source 不含 scan`);
        }
        if (!(threat.scan_refs || []).includes(finding.id)) {
          push(`${at} 引用的威胁 ${ref} 的 scan_refs 里没有 ${finding.id}`);
        }
      }
    });
  }

  return { threats, byId };
}

/**
 * 校验一个套件的 cases.json。
 * @param {object} doc cases.json
 * @param {Map<string, object>} threatById 威胁 id → 威胁
 * @param {Set<string>} usedCaseIds 已用过的用例 id（跨套件唯一）
 * @param {string[]} methodIds 方法库里的方法号
 * @param {string} label 人读标签
 * @param {string[]} problems 问题清单
 */
export function checkCasesDocument(doc, threatById, usedCaseIds, methodIds, label, problems) {
  const push = (message) => problems.push(message);
  if (!isObject(doc)) {
    push(`${label} 的根节点必须是对象`);
    return;
  }
  for (const key of Object.keys(doc)) {
    if (!CASES_TOP_LEVEL_FIELDS.includes(key)) push(`${label} 出现未声明的顶层字段 ${key}（字段集封闭 7 个）`);
  }
  for (const key of CASES_TOP_LEVEL_FIELDS) {
    if (doc[key] === undefined) push(`${label} 缺少顶层字段 ${key}`);
  }
  if (doc.schema_version !== 2) push(`${label}.schema_version=${JSON.stringify(doc.schema_version)}，应为 2`);
  if (!Array.isArray(doc.open_questions)) push(`${label}.open_questions 必须是数组`);
  if (!Array.isArray(doc.defects)) push(`${label}.defects 必须是数组`);

  const requirements = Array.isArray(doc.requirements) ? doc.requirements : [];
  const requirementIds = new Set();
  requirements.forEach((requirement, index) => {
    const at = `${label}.requirements[${index}]`;
    if (!isObject(requirement)) {
      push(`${at} 必须是对象`);
      return;
    }
    if (!isFilledString(requirement.id)) push(`${at}.id 必须是非空字符串`);
    if (requirementIds.has(requirement.id)) push(`${at}.id 重复: ${requirement.id}`);
    requirementIds.add(requirement.id);
    if (!isFilledString(requirement.title)) push(`${at}.title 必须是非空字符串`);
    if (typeof requirement.testable !== 'boolean') push(`${at}.testable 必须是布尔值`);
    const matched = /^threat-model\.json#\/threats\/(TH-\d+)$/.exec(String(requirement.source_ref || ''));
    if (!matched) {
      push(`${at}.source_ref 必须是 threat-model.json#/threats/<TH-id> 形式（实际: ${JSON.stringify(requirement.source_ref)}）`);
    } else if (!threatById.has(matched[1])) {
      push(`${at}.source_ref 指向的威胁不存在: ${matched[1]}`);
    }
  });

  const matrix = Array.isArray(doc.coverage_matrix) ? doc.coverage_matrix : [];
  const matrixRequirements = new Set();
  matrix.forEach((entry, index) => {
    const at = `${label}.coverage_matrix[${index}]`;
    if (!isObject(entry)) {
      push(`${at} 必须是对象`);
      return;
    }
    if (!requirementIds.has(entry.requirement)) {
      push(`${at}.requirement 悬空引用: ${JSON.stringify(entry.requirement)}`);
    }
    if (matrixRequirements.has(entry.requirement)) {
      push(`${at}.requirement 重复: ${entry.requirement}`);
    }
    matrixRequirements.add(entry.requirement);
    if (!Array.isArray(entry.methods_applied) || entry.methods_applied.length === 0) {
      push(`${at}.methods_applied 必须是非空数组`);
    } else {
      for (const method of entry.methods_applied) {
        if (!methodIds.includes(method)) push(`${at}.methods_applied 里的方法号 "${method}" 不在方法库里`);
      }
    }
    if (!Array.isArray(entry.dimensions) || entry.dimensions.length === 0) {
      push(`${at}.dimensions 必须是非空数组`);
    } else if (!entry.dimensions.includes('security')) {
      push(`${at}.dimensions 必须含 "security"`);
    }
  });
  for (const id of requirementIds) {
    if (!matrixRequirements.has(id)) push(`${label}.coverage_matrix 漏掉了需求条目 ${id}`);
  }

  const cases = Array.isArray(doc.cases) ? doc.cases : [];
  cases.forEach((item, index) => {
    const at = `${label}.cases[${index}]`;
    if (!isObject(item)) {
      push(`${at} 必须是对象`);
      return;
    }
    if (!CASE_ID_PATTERN.test(String(item.id))) push(`${at}.id 非法: ${JSON.stringify(item.id)}（须匹配 ^TC-\\d{3}$）`);
    if (usedCaseIds.has(item.id)) push(`${at}.id 跨套件重复: ${item.id}`);
    usedCaseIds.add(item.id);
    if (!isFilledString(item.title)) push(`${at}.title 必须是非空字符串`);
    if (item.dimension !== 'security') push(`${at}.dimension=${JSON.stringify(item.dimension)}，应为 "security"`);
    if (!PRIORITIES.includes(item.priority)) push(`${at}.priority 取值非法: ${item.priority}`);
    if (item.status !== 'active') push(`${at}.status=${JSON.stringify(item.status)}，必须恒为 "active"`);
    if (item.revision !== undefined) push(`${at} 带了 revision（刚派生的用例没有前序版本，不得声称被改过）`);
    if (!Array.isArray(item.method) || item.method.length === 0) {
      push(`${at}.method 必须是非空数组`);
    } else {
      for (const method of item.method) {
        if (!methodIds.includes(method)) push(`${at}.method 里的方法号 "${method}" 不在方法库里`);
      }
    }
    if (!Array.isArray(item.requirement_refs) || item.requirement_refs.length === 0) {
      push(`${at}.requirement_refs 必须是非空数组`);
    } else {
      for (const ref of item.requirement_refs) {
        if (!requirementIds.has(ref)) push(`${at}.requirement_refs 悬空引用: ${ref}`);
      }
    }
    if (!Array.isArray(item.steps) || item.steps.length === 0) {
      push(`${at}.steps 必须是非空数组`);
    } else {
      item.steps.forEach((step, stepIndex) => {
        const stepAt = `${at}.steps[${stepIndex}]`;
        if (!isObject(step)) {
          push(`${stepAt} 必须是对象`);
          return;
        }
        if (!isFilledString(step.action)) push(`${stepAt}.action 必须是非空字符串`);
        if (!isFilledString(step.expected)) push(`${stepAt}.expected 必须是非空字符串`);
      });
    }
    if (!Array.isArray(item.tags)) {
      push(`${at}.tags 必须是数组`);
    } else {
      if (!item.tags.includes('security')) push(`${at}.tags 缺 "security"`);
      for (const ref of item.requirement_refs || []) {
        const requirement = requirements.find((one) => one.id === ref);
        const matched = requirement ? /^threat-model\.json#\/threats\/(TH-\d+)$/.exec(String(requirement.source_ref || '')) : null;
        if (matched && !item.tags.includes(matched[1])) {
          push(`${at}.tags 缺该需求条目对应的威胁 id ${matched[1]}`);
        }
      }
    }
  });
}

/**
 * 主流程。
 * @returns {number} 退出码
 */
function main() {
  const args = process.argv.slice(2).filter((arg) => arg !== '-h' && arg !== '--help');
  if (args.length !== 1) {
    console.error('[usage] 用法: node scripts/check-security-plan.mjs <项目根>');
    return 2;
  }
  const root = path.resolve(args[0]);
  const securityRoot = path.join(root, 'test-assets', 'security');
  const problems = [];

  if (!fs.existsSync(securityRoot)) {
    console.error(`[error] 安全资产目录不存在: ${securityRoot}`);
    return 1;
  }

  const methodIds = loadMethodIds();

  const modelDoc = readJson(path.join(securityRoot, 'threat-model.json'), 'threat-model.json', problems);
  let threatById = new Map();
  if (modelDoc !== null) {
    const result = checkThreatModel(modelDoc, problems);
    threatById = result.byId;
  }

  const matrixDoc = readJson(path.join(securityRoot, 'matrix.json'), 'matrix.json', problems);
  if (matrixDoc !== null) {
    const threats = modelDoc && Array.isArray(modelDoc.threats) ? modelDoc.threats : [];
    for (const message of checkMatrix(matrixDoc, threats)) {
      problems.push(`matrix.json: ${message}`);
    }
  }

  const suitesDir = path.join(securityRoot, 'suites');
  const suiteNames = fs.existsSync(suitesDir)
    ? fs.readdirSync(suitesDir).filter((name) => fs.statSync(path.join(suitesDir, name)).isDirectory()).sort()
    : [];
  if (suiteNames.length === 0) problems.push('suites/ 下没有任何套件目录');

  const usedCaseIds = new Set();
  const coveredThreats = new Set();
  for (const name of suiteNames) {
    const suiteDir = path.join(suitesDir, name);
    if (!SUITE_DIR_PATTERN.test(name)) {
      problems.push(`套件目录名不合规: ${name}（须匹配 ${SUITE_DIR_PATTERN.source}）`);
    }
    const suiteDoc = readJson(path.join(suiteDir, 'suite.json'), `${name}/suite.json`, problems);
    if (suiteDoc !== null) {
      for (const key of Object.keys(suiteDoc)) {
        if (!SUITE_ALLOWED_FIELDS.includes(key)) {
          problems.push(`${name}/suite.json 出现未声明的字段 ${key}（顶层字段集封闭 9 个）`);
        }
      }
      for (const key of SUITE_REQUIRED_FIELDS) {
        if (!isFilledString(suiteDoc[key])) {
          problems.push(`${name}/suite.json.${key} 必须存在且是非空字符串`);
        }
      }
      if (suiteDoc.suite !== name) {
        problems.push(`${name}/suite.json 的 suite="${suiteDoc.suite}" 与目录名不一致`);
      }
      if (suiteDoc.scope !== 'security') problems.push(`${name}/suite.json.scope=${suiteDoc.scope}，应为 "security"`);
      if (suiteDoc.executor !== 'security') problems.push(`${name}/suite.json.executor=${suiteDoc.executor}，应为 "security"`);
      const envFile = path.join(root, 'test-assets', 'environments', `${suiteDoc.environment}.json`);
      if (!fs.existsSync(envFile)) {
        problems.push(`${name}/suite.json 的 environment="${suiteDoc.environment}" 在 environments/ 下不存在`);
      }
      const casesFile = path.resolve(suiteDir, String(suiteDoc.cases_file || ''));
      if (!fs.existsSync(casesFile)) {
        problems.push(`${name}/suite.json 的 cases_file 不存在: ${suiteDoc.cases_file}`);
      }
    }
    const casesDoc = readJson(path.join(suiteDir, 'cases.json'), `${name}/cases.json`, problems);
    if (casesDoc !== null) {
      checkCasesDocument(casesDoc, threatById, usedCaseIds, methodIds, `${name}/cases.json`, problems);
      const requirements = Array.isArray(casesDoc.requirements) ? casesDoc.requirements : [];
      const cases = Array.isArray(casesDoc.cases) ? casesDoc.cases : [];
      for (const item of cases) {
        for (const ref of item.requirement_refs || []) {
          const requirement = requirements.find((one) => one.id === ref);
          const matched = requirement
            ? /^threat-model\.json#\/threats\/(TH-\d+)$/.exec(String(requirement.source_ref || ''))
            : null;
          if (matched) coveredThreats.add(matched[1]);
        }
      }
    }
  }

  for (const id of threatById.keys()) {
    if (!coveredThreats.has(id)) {
      problems.push(`威胁 ${id} 没有任何用例覆盖（每条威胁至少派生 1 条用例）`);
    }
  }

  if (problems.length > 0) {
    console.error(`[error] 产物不自洽，共 ${problems.length} 处问题: ${securityRoot}`);
    for (const message of problems) console.error(`  · ${message}`);
    return 1;
  }
  console.log(`[ok] 产物自洽: ${securityRoot}`);
  console.log(
    `[ok] 威胁 ${threatById.size} 条、套件 ${suiteNames.length} 个、用例 ${usedCaseIds.size} 条（id 跨套件唯一）`,
  );
  return 0;
}

process.exitCode = main();
