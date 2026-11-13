// analyze.mjs —— 报告的分析核心（**每个数字都从输入重算**）
//
// 三层结论（demand.md §1.1 / D48）：
//   用例层 —— 跑的那些用例判定如何（results.json 的 status 分布）
//   流程层 —— 这份产物本身可信吗（证据实查 + 计数核对 + 指纹重算）
//   回归层 —— 该跑的有没有都跑（regression-plan.json ∩ results.json，可选层）
//
// 诚实性红线（F6）：
//   - blocked 计入 blocked，**绝不**计入 passed；
//   - 证据不自洽 → 流程层 fail；
//   - 计数以 results.json 重算为准，meta.json 的自述只用来**对账**；
//   - 报告里的每个数字都能从输入重算，reproduction 逐字搬运。

import fs from 'node:fs';
import path from 'node:path';
import { fingerprintFile, resultsFingerprint, evidenceManifestFingerprint } from './fingerprint.mjs';
import { computeReportSha256 } from './canonical.mjs';
import { isPlainObject } from './artifacts.mjs';

/** meta.json 的五个计数字段 → 报告 cases 段的对应键。 */
const COUNT_FIELDS = [
  ['cases_total', 'total'],
  ['cases_passed', 'passed'],
  ['cases_failed', 'failed'],
  ['cases_blocked', 'blocked'],
  ['cases_skipped', 'skipped'],
];

/** `source` 段必须来自 meta.json 的字段。 */
const SOURCE_FIELDS = ['run_id', 'suite', 'requirement', 'environment', 'started_at', 'finished_at'];

/**
 * 取 meta.json 里的一个必填字符串字段。
 * @param {object} meta meta.json
 * @param {string} key 字段名
 * @returns {string} 字段值
 */
function sourceString(meta, key) {
  const value = meta[key];
  if (typeof value !== 'string' || value === '') {
    throw new Error(`meta.json 缺字段 ${key}（或不是非空字符串）—— 报告无法绑定这次执行`);
  }
  return value;
}

/**
 * 从 results.json 逐条重算用例计数。
 * @param {object[]} results 结果数组
 * @returns {{total: number, passed: number, failed: number, blocked: number, skipped: number}} 计数
 */
export function recountCases(results) {
  const counts = { total: results.length, passed: 0, failed: 0, blocked: 0, skipped: 0 };
  for (const entry of results) {
    const status = isPlainObject(entry) ? entry.status : '';
    if (status === 'passed') counts.passed += 1;
    else if (status === 'failed') counts.failed += 1;
    else if (status === 'blocked') counts.blocked += 1;
    else if (status === 'skipped') counts.skipped += 1;
  }
  return counts;
}

/**
 * 逐条实查证据文件（不信 results.json 的自述）。
 * @param {object[]} results 结果数组
 * @param {string} dir 产物目录
 * @returns {{files_present: number, files_missing: number, missing_paths: string[], findings: object[]}} 实查结果
 */
export function inspectEvidence(results, dir) {
  const findings = [];
  const missingPaths = [];
  let present = 0;
  let missing = 0;
  for (const entry of results) {
    const list = isPlainObject(entry) && Array.isArray(entry.evidence) ? entry.evidence : [];
    for (const item of list) {
      if (!isPlainObject(item) || typeof item.path !== 'string' || item.path === '') continue;
      const rel = item.path;
      const full = path.join(dir, rel);
      let exists = false;
      try {
        exists = fs.existsSync(full) && fs.statSync(full).isFile();
      } catch {
        exists = false;
      }
      if (!exists) {
        missing += 1;
        missingPaths.push(rel);
        findings.push({
          kind: 'missing_evidence',
          message: `证据文件缺失：${rel}（results.json 声称存在，实查不存在）`,
        });
        continue;
      }
      present += 1;
      const actual = fingerprintFile(full);
      if (typeof item.sha256 === 'string' && item.sha256 !== '' && actual.sha256 !== item.sha256) {
        findings.push({
          kind: 'evidence_mismatch',
          message: `证据文件内容与记录不符：${rel}（记录 sha256=${item.sha256}，实算 sha256=${actual.sha256}）`,
        });
      } else if (Number.isFinite(item.bytes) && item.bytes !== actual.bytes) {
        findings.push({
          kind: 'evidence_mismatch',
          message: `证据文件字节数与记录不符：${rel}（记录 ${item.bytes} 字节，实算 ${actual.bytes} 字节）`,
        });
      }
    }
  }
  return { files_present: present, files_missing: missing, missing_paths: missingPaths, findings };
}

/**
 * 核对 meta.json 的计数与重算值。
 * @param {object} meta meta.json
 * @param {object} counts 重算出来的计数
 * @returns {object[]} count_mismatch 类发现
 */
export function checkCounts(meta, counts) {
  const findings = [];
  for (const [metaKey, countKey] of COUNT_FIELDS) {
    const declared = meta[metaKey];
    if (typeof declared === 'number' && declared !== counts[countKey]) {
      findings.push({
        kind: 'count_mismatch',
        message: `计数不符：${metaKey}（meta.json 记 ${declared}，从 results.json 重算为 ${counts[countKey]}）`,
      });
    }
  }
  return findings;
}

/**
 * 核对 meta.json 记录的两个指纹与重算值。
 * @param {object} meta meta.json
 * @param {string} recomputedResults 重算的结果指纹
 * @param {string} recomputedManifest 重算的证据清单指纹
 * @returns {object[]} fingerprint_mismatch 类发现
 */
export function checkFingerprints(meta, recomputedResults, recomputedManifest) {
  const findings = [];
  if (typeof meta.results_sha256 === 'string' && meta.results_sha256 !== recomputedResults) {
    findings.push({
      kind: 'fingerprint_mismatch',
      message: `结果指纹不符：meta.json 记 ${meta.results_sha256}，从 results.json 重算为 ${recomputedResults}`,
    });
  }
  if (
    typeof meta.evidence_manifest_sha256 === 'string'
    && meta.evidence_manifest_sha256 !== recomputedManifest
  ) {
    findings.push({
      kind: 'fingerprint_mismatch',
      message: `证据清单指纹不符：meta.json 记 ${meta.evidence_manifest_sha256}，重算为 ${recomputedManifest}`,
    });
  }
  return findings;
}

/**
 * 回归对账（可选层）。
 * @param {object|null} plan 回归计划（null = 不给计划）
 * @param {object[]} results 结果数组
 * @returns {object|null} 回归段
 */
export function reconcile(plan, results) {
  if (plan === null) return null;
  const executed = new Set(results.filter(isPlainObject).map((entry) => String(entry.case_id)));
  const selected = Array.isArray(plan.selected) ? plan.selected.filter(isPlainObject) : [];
  const needsReview = Array.isArray(plan.needs_review) ? plan.needs_review.filter(isPlainObject) : [];
  const undecidable = Array.isArray(plan.undecidable_changes) ? plan.undecidable_changes.filter(isPlainObject) : [];
  const selectedMissing = selected
    .map((entry) => String(entry.case_id))
    .filter((caseId) => !executed.has(caseId));
  const summary = isPlainObject(plan.summary) ? plan.summary : {};
  const impactComplete =
    typeof summary.impact_complete === 'boolean' ? summary.impact_complete : undecidable.length === 0;
  return {
    selected_planned: selected.length,
    selected_executed: selected.filter((entry) => executed.has(String(entry.case_id))).length,
    selected_missing: selectedMissing,
    needs_review_planned: needsReview.length,
    needs_review_executed: needsReview.filter((entry) => executed.has(String(entry.case_id))).length,
    undecidable_changes: undecidable.map((entry) => ({
      change_id: String(entry.change_id),
      reason: String(entry.reason),
    })),
    impact_complete: impactComplete,
  };
}

/**
 * 推导三层结论与总体结论。
 * @param {object} counts 重算的计数
 * @param {object} evidence 实查结果
 * @param {object|null} regression 回归段（null = 不给计划）
 * @returns {{case_layer: string, evidence_layer: string, regression_layer: string, overall: string}} 三层结论
 */
export function deriveVerdict(counts, evidence, regression) {
  let caseLayer = 'pass';
  if (counts.failed > 0) caseLayer = 'fail';
  else if (counts.blocked > 0) caseLayer = 'incomplete';

  const evidenceLayer = evidence.findings.length > 0 ? 'fail' : 'pass';

  let regressionLayer = 'not_applicable';
  if (regression !== null) {
    if (regression.selected_missing.length > 0) regressionLayer = 'fail';
    else if (regression.needs_review_planned > 0) regressionLayer = 'incomplete';
    else if (regression.impact_complete !== true) regressionLayer = 'incomplete';
    else regressionLayer = 'pass';
  }

  let overall = 'pass';
  if (caseLayer === 'fail' || evidenceLayer === 'fail' || regressionLayer === 'fail') overall = 'fail';
  else if (caseLayer === 'incomplete' || evidenceLayer === 'unknown' || regressionLayer === 'unknown') {
    overall = 'incomplete';
  } else if (regressionLayer === 'incomplete') overall = 'incomplete';

  return {
    case_layer: caseLayer,
    evidence_layer: evidenceLayer,
    regression_layer: regressionLayer,
    overall,
  };
}

/**
 * 组装报告对象。
 * @param {{dir: string, meta: object, results: object[], plan: object|null, planPath: string|null, generatedAt: string}} input 输入
 * @returns {object} 报告对象
 */
export function buildReport(input) {
  const { dir, meta, results, plan, planPath, generatedAt } = input;
  const counts = recountCases(results);
  const durationTotal = results.reduce((sum, entry) => {
    const value = isPlainObject(entry) ? Number(entry.duration_ms) : NaN;
    return sum + (Number.isFinite(value) ? value : 0);
  }, 0);

  const recomputedResults = resultsFingerprint(results);
  const recomputedManifest = evidenceManifestFingerprint(results);
  const inspected = inspectEvidence(results, dir);
  const findings = [
    ...inspected.findings,
    ...checkCounts(meta, counts),
    ...checkFingerprints(meta, recomputedResults, recomputedManifest),
  ];
  const evidence = {
    files_present: inspected.files_present,
    files_missing: inspected.files_missing,
    missing_paths: inspected.missing_paths,
    findings,
  };

  const failures = results
    .filter((entry) => isPlainObject(entry) && (entry.status === 'failed' || entry.status === 'blocked'))
    .map((entry) => ({
      case_id: String(entry.case_id),
      title: typeof entry.title === 'string' ? entry.title : String(entry.case_id),
      status: String(entry.status),
      error: entry.error === undefined ? null : entry.error,
      reproduction: entry.reproduction === undefined ? null : entry.reproduction,
      evidence: Array.isArray(entry.evidence) ? entry.evidence : [],
    }));

  const regression = reconcile(plan, results);
  const verdict = deriveVerdict(counts, evidence, regression);

  const report = {
    schema_version: 1,
    generated_at: generatedAt,
    source: {
      artifacts: dir,
      run_id: sourceString(meta, 'run_id'),
      suite: sourceString(meta, 'suite'),
      requirement: sourceString(meta, 'requirement'),
      environment: sourceString(meta, 'environment'),
      started_at: sourceString(meta, 'started_at'),
      finished_at: sourceString(meta, 'finished_at'),
      results_sha256: recomputedResults,
      evidence_manifest_sha256: recomputedManifest,
      regression_plan: planPath,
    },
    cases: {
      total: counts.total,
      passed: counts.passed,
      failed: counts.failed,
      blocked: counts.blocked,
      skipped: counts.skipped,
      duration_ms_total: durationTotal,
    },
    verdict,
    failures,
    evidence,
    regression,
    report_sha256: '',
  };
  report.report_sha256 = computeReportSha256(report);
  return report;
}
