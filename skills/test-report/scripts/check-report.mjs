#!/usr/bin/env node
/**
 * check-report.mjs —— 报告的自洽校验器。
 *
 * 用法：
 *   node scripts/check-report.mjs <report.json>
 *
 * 查什么：
 *   1. `report.json` 的必填字段集、类型与枚举（对照 `references/report-schema.md` 的固定清单）；
 *   2. `report_sha256` 能否按 F3.2 的规范化口径**从报告自身重算**出来；
 *   3. `overall == "pass"` 时的自洽不变式（failed / blocked 必为 0，证据层必为 pass，
 *      给计划时对账层与影响面完整性也得满足）；
 *   4. 若同目录下有 `report.md`：摘要行**恰好一行**、每个键值与 json 逐字相等，
 *      且正文里按 F4.2 词表呈现的关键数字与摘要一致。
 *
 * 退出码：0 = 自洽 / 1 = 不自洽 / 2 = 用法错误。
 */

import fs from 'node:fs';
import path from 'node:path';
import { computeReportSha256, digestValue, getByPath } from './lib/canonical.mjs';

/** 必填字段的类型约束。 */
const REQUIRED = {
  'schema_version': 'number',
  'generated_at': 'string',
  'source': 'object',
  'cases': 'object',
  'verdict': 'object',
  'failures': 'array',
  'evidence': 'object',
  'regression': 'object|null',
  'report_sha256': 'string',
};

/** 结论字段的取值枚举。 */
const ENUMS = {
  'verdict.case_layer': ['pass', 'fail', 'incomplete'],
  'verdict.evidence_layer': ['pass', 'fail', 'unknown'],
  'verdict.regression_layer': ['pass', 'fail', 'incomplete', 'not_applicable', 'unknown'],
  'verdict.overall': ['pass', 'fail', 'incomplete'],
};

/** `cases` 段的固定键集（不多不少）。 */
const CASE_KEYS = ['total', 'passed', 'failed', 'blocked', 'skipped', 'duration_ms_total'];

/** `source` 段的固定键集。 */
const SOURCE_KEYS = [
  'artifacts', 'run_id', 'suite', 'requirement', 'environment',
  'started_at', 'finished_at', 'results_sha256', 'evidence_manifest_sha256', 'regression_plan',
];

/** 摘要行必须覆盖的键。 */
const DIGEST_REQUIRED = [
  'cases.total', 'cases.passed', 'cases.failed', 'cases.blocked', 'cases.skipped',
  'verdict.case_layer', 'verdict.evidence_layer', 'verdict.regression_layer', 'verdict.overall',
  'source.results_sha256', 'source.evidence_manifest_sha256', 'report_sha256',
];

/** 证据层发现的 kind 枚举。 */
const FINDING_KINDS = ['missing_evidence', 'evidence_mismatch', 'count_mismatch', 'fingerprint_mismatch'];

/** 正文关键数字的标签词表（F4.2）。 */
const BODY_METRICS = [
  { key: 'cases.total', label: '(?:用例总数|共计|总计|合计)' },
  { key: 'cases.passed', label: '(?:通过)' },
  { key: 'cases.failed', label: '(?:失败)' },
  { key: 'cases.blocked', label: '(?:阻塞|阻断)' },
  { key: 'cases.skipped', label: '(?:跳过)' },
  { key: 'regression.selected_missing', label: '(?:漏跑|未执行|未跑)', whenPlan: true },
  { key: 'regression.needs_review_planned', label: '(?:待复核|需复核|人工复核)', whenPlan: true },
  { key: 'regression.undecidable_changes', label: '(?:判不了|无法判定|不可判定)', whenPlan: true },
];

/**
 * 判断值的类型名。
 * @param {*} value 待判定值
 * @returns {string} 类型名
 */
function typeName(value) {
  if (value === null) return 'null';
  if (Array.isArray(value)) return 'array';
  return typeof value;
}

/**
 * 校验 report.json。
 * @param {object} report 报告对象
 * @returns {string[]} 问题清单（空 = 自洽）
 */
function checkReport(report) {
  const problems = [];
  for (const [key, expected] of Object.entries(REQUIRED)) {
    if (!(key in report)) {
      problems.push(`缺字段 ${key}`);
      continue;
    }
    const actual = typeName(report[key]);
    if (expected === 'object|null') {
      if (actual !== 'object' && actual !== 'null') problems.push(`${key} 的类型是 ${actual}，应为 object 或 null`);
    } else if (actual !== expected) {
      problems.push(`${key} 的类型是 ${actual}，应为 ${expected}`);
    }
  }
  for (const [path, allowed] of Object.entries(ENUMS)) {
    const value = getByPath(report, path);
    if (typeof value !== 'string' || !allowed.includes(value)) {
      problems.push(`${path}=${JSON.stringify(value)}，不在枚举 [${allowed.join(',')}] 里`);
    }
  }
  if (typeof report.cases === 'object' && report.cases !== null) {
    for (const key of CASE_KEYS) {
      if (typeof report.cases[key] !== 'number') problems.push(`cases.${key} 缺失或不是 number`);
    }
    for (const key of Object.keys(report.cases)) {
      if (!CASE_KEYS.includes(key)) problems.push(`cases 段出现未声明的键 ${key}`);
    }
  }
  if (typeof report.source === 'object' && report.source !== null) {
    for (const key of SOURCE_KEYS) {
      if (!(key in report.source)) problems.push(`source 段缺字段 ${key}`);
    }
  }
  if (Array.isArray(report.failures)) {
    report.failures.forEach((item, index) => {
      if (item === null || typeof item !== 'object') {
        problems.push(`failures[${index}] 不是对象`);
        return;
      }
      for (const key of ['case_id', 'title', 'status', 'error', 'reproduction', 'evidence']) {
        if (!(key in item)) problems.push(`failures[${index}] 缺字段 ${key}`);
      }
    });
  }
  if (typeof report.evidence === 'object' && report.evidence !== null) {
    const evidence = report.evidence;
    if (typeof evidence.files_present !== 'number') problems.push('evidence.files_present 不是 number');
    if (typeof evidence.files_missing !== 'number') problems.push('evidence.files_missing 不是 number');
    if (!Array.isArray(evidence.missing_paths)) problems.push('evidence.missing_paths 不是数组');
    if (!Array.isArray(evidence.findings)) problems.push('evidence.findings 不是数组');
    else {
      evidence.findings.forEach((finding, index) => {
        if (finding === null || typeof finding !== 'object') {
          problems.push(`evidence.findings[${index}] 不是对象`);
          return;
        }
        if (!FINDING_KINDS.includes(finding.kind)) {
          problems.push(`evidence.findings[${index}].kind=${JSON.stringify(finding.kind)} 不在枚举里`);
        }
        if (typeof finding.message !== 'string' || finding.message.trim() === '') {
          problems.push(`evidence.findings[${index}].message 缺失或为空`);
        }
      });
    }
  }
  if (report.regression !== null && typeof report.regression === 'object') {
    const regression = report.regression;
    for (const key of ['selected_planned', 'selected_executed', 'needs_review_planned', 'needs_review_executed']) {
      if (typeof regression[key] !== 'number') problems.push(`regression.${key} 不是 number`);
    }
    if (!Array.isArray(regression.selected_missing)) problems.push('regression.selected_missing 不是数组');
    if (!Array.isArray(regression.undecidable_changes)) problems.push('regression.undecidable_changes 不是数组');
    else {
      regression.undecidable_changes.forEach((item, index) => {
        if (item === null || typeof item !== 'object') {
          problems.push(`regression.undecidable_changes[${index}] 不是对象`);
          return;
        }
        if (typeof item.change_id !== 'string' || item.change_id === '') {
          problems.push(`regression.undecidable_changes[${index}].change_id 缺失`);
        }
        if (typeof item.reason !== 'string' || item.reason === '') {
          problems.push(`regression.undecidable_changes[${index}].reason 缺失或为空`);
        }
      });
    }
    if (typeof regression.impact_complete !== 'boolean') problems.push('regression.impact_complete 不是 boolean');
  }
  if (typeof report.report_sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(report.report_sha256)) {
    problems.push(`report_sha256=${JSON.stringify(report.report_sha256)} 不是 64 位十六进制`);
  } else {
    const recomputed = computeReportSha256(report);
    if (recomputed !== report.report_sha256) {
      problems.push(`report_sha256 与按 F3.2 口径重算的值不符（重算 ${recomputed}）`);
    }
  }
  const verdict = typeof report.verdict === 'object' && report.verdict !== null ? report.verdict : {};
  const cases = typeof report.cases === 'object' && report.cases !== null ? report.cases : {};
  if (verdict.overall === 'pass') {
    if (cases.failed !== 0) problems.push(`overall=pass 但 cases.failed=${JSON.stringify(cases.failed)}`);
    if (cases.blocked !== 0) problems.push(`overall=pass 但 cases.blocked=${JSON.stringify(cases.blocked)}`);
    if (verdict.evidence_layer !== 'pass') problems.push(`overall=pass 但 verdict.evidence_layer=${JSON.stringify(verdict.evidence_layer)}`);
    if (verdict.regression_layer !== 'pass' && verdict.regression_layer !== 'not_applicable') {
      problems.push(`overall=pass 但 verdict.regression_layer=${JSON.stringify(verdict.regression_layer)}`);
    }
    if (report.regression !== null && report.regression.impact_complete !== true) {
      problems.push('overall=pass 但 regression.impact_complete 不是 true');
    }
  }
  return problems;
}

/**
 * 校验 report.md 与 report.json 的一致性。
 * @param {object} report 报告对象
 * @param {string} markdown markdown 文本
 * @returns {string[]} 问题清单（空 = 一致）
 */
function checkMarkdown(report, markdown) {
  const problems = [];
  const digestLines = markdown.match(/<!--\s*report-digest:[^\n]*?-->/g) || [];
  if (digestLines.length !== 1) {
    problems.push(`report.md 里的 report-digest 摘要行出现 ${digestLines.length} 次，要求恰好 1 行`);
    return problems;
  }
  const inner = digestLines[0].replace(/^<!--\s*report-digest:/, '').replace(/-->\s*$/, '').trim();
  const seen = new Set();
  for (const piece of inner.split(';')) {
    const item = piece.trim();
    if (!item) continue;
    const eq = item.indexOf('=');
    if (eq < 0) {
      problems.push(`摘要里的片段「${item}」不是 key=value 形式`);
      continue;
    }
    const key = item.slice(0, eq).trim();
    const value = item.slice(eq + 1).trim();
    seen.add(key);
    const actual = getByPath(report, key);
    if (actual === undefined) {
      problems.push(`摘要里的键 ${key} 在 report.json 里没有同名路径`);
      continue;
    }
    const expected = digestValue(actual);
    if (value !== expected) {
      problems.push(`摘要里的 ${key}=${value}，report.json 的同名路径是 ${expected}（逐字不等）`);
    }
  }
  for (const key of DIGEST_REQUIRED) {
    if (!seen.has(key)) problems.push(`摘要缺必需键 ${key}`);
  }
  const body = markdown.replace(/<!--\s*report-digest:[^\n]*?-->/g, '');
  for (const metric of BODY_METRICS) {
    if (metric.whenPlan && report.regression === null) continue;
    const value = getByPath(report, metric.key);
    const expect = Array.isArray(value) ? value.length : Number(value || 0);
    const re = new RegExp(`${metric.label}[^0-9A-Za-z\\u4e00-\\u9fa5]{0,10}?(\\d+)\\s*[条个项]?`, 'g');
    const hits = [...body.matchAll(re)].map((item) => Number(item[1]));
    if (hits.length === 0) continue;
    for (const hit of hits) {
      if (hit !== expect) {
        problems.push(`正文里「${metric.key}」标签后的数字是 ${hit}，与报告里的 ${expect} 不一致`);
      }
    }
  }
  return problems;
}

/**
 * 主流程。
 * @returns {number} 退出码
 */
function main() {
  const args = process.argv.slice(2).filter((arg) => arg !== '-h' && arg !== '--help');
  if (args.length === 0 || args.length > 1) {
    console.error('[usage] 用法: node scripts/check-report.mjs <report.json>');
    return 2;
  }
  const file = path.resolve(args[0]);
  if (!fs.existsSync(file)) {
    console.error(`[error] 报告文件不存在：${file}`);
    return 1;
  }
  let report = null;
  try {
    report = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (err) {
    console.error(`[error] 报告不是合法 JSON：${file}（${err && err.message ? err.message : String(err)}）`);
    return 1;
  }
  if (report === null || typeof report !== 'object' || Array.isArray(report)) {
    console.error(`[error] 报告的根节点必须是对象：${file}`);
    return 1;
  }

  const problems = checkReport(report);
  const mdFile = path.join(path.dirname(file), 'report.md');
  if (fs.existsSync(mdFile)) {
    const markdown = fs.readFileSync(mdFile, 'utf8');
    for (const problem of checkMarkdown(report, markdown)) problems.push(problem);
  }

  if (problems.length > 0) {
    console.error(`[error] 报告不自洽，共 ${problems.length} 处问题：`);
    for (const problem of problems) console.error(`  · ${problem}`);
    return 1;
  }
  console.log(`[ok] 报告自洽：${file}`);
  console.log(`[ok] overall=${report.verdict.overall} report_sha256=${report.report_sha256}`);
  return 0;
}

process.exitCode = main();
