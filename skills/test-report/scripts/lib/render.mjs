// render.mjs —— `report.md` 的渲染（**md 是 json 的渲染**，不是独立内容）
//
// 契约（F4 / F4.1 / F4.2）：
//   1. md 里的每个数字必须与 report.json 的同名路径**逐字相等**；
//   2. md 含**一行**机器可读摘要 `<!-- report-digest: key=value; ... -->`，
//      每个键是 report.json 的点号路径，值逐字相等（数组用逗号连接、顺序敏感）；
//   3. 正文的关键数字按「标签 + 数字」呈现，标签取自 F4.2 的固定词汇表；
//   4. md 必须**点名**：漏跑的用例 id、失败的用例 id 与错误摘要、判不了的变更 id 与原因、
//      待人工复核的用例 id（AC-016：待复核不能只有条数，必须在待复核语境里点到 id）。
//
// ⚠️ 措辞纪律：正文里**不写**「回归」二字 —— 回归层是可选层，
//    不给计划时报告不得出现任何断言回归状态的措辞（AC-018）。

import { digestValue, getByPath } from './canonical.mjs';

/** 摘要行必须覆盖的键（AC-011 要求的 12 个必需键 + 若干可核键）。 */
const DIGEST_KEYS = [
  'cases.total',
  'cases.passed',
  'cases.failed',
  'cases.blocked',
  'cases.skipped',
  'cases.duration_ms_total',
  'verdict.case_layer',
  'verdict.evidence_layer',
  'verdict.regression_layer',
  'verdict.overall',
  'source.run_id',
  'source.suite',
  'source.requirement',
  'source.environment',
  'source.results_sha256',
  'source.evidence_manifest_sha256',
  'evidence.files_present',
  'evidence.files_missing',
  'regression.selected_planned',
  'regression.selected_executed',
  'regression.selected_missing',
  'regression.needs_review_planned',
  'regression.needs_review_executed',
  'regression.impact_complete',
  'report_sha256',
];

/**
 * 生成机器可读摘要行。
 * @param {object} report 报告对象
 * @returns {string} 摘要行
 */
export function renderDigest(report) {
  const pairs = [];
  for (const key of DIGEST_KEYS) {
    const value = getByPath(report, key);
    if (value === undefined) continue;
    pairs.push(`${key}=${digestValue(value)}`);
  }
  return `<!-- report-digest: ${pairs.join('; ')} -->`;
}

/**
 * 判定「用例层」的说明。
 * @param {object} cases 计数段
 * @returns {string} 说明
 */
function caseLayerNote(cases) {
  if (cases.failed > 0) return `有 ${cases.failed} 条用例判定为 failed`;
  if (cases.blocked > 0) return `有 ${cases.blocked} 条用例不可判定（blocked）`;
  return '跑过的用例全部判定为 passed';
}

/**
 * 判定「流程层」的说明。
 * @param {object} evidence 证据段
 * @returns {string} 说明
 */
function evidenceLayerNote(evidence) {
  if (evidence.findings.length > 0) return `证据链核查发现 ${evidence.findings.length} 项问题`;
  return '证据链自洽：文件实查、计数重算、指纹重算全部一致';
}

/**
 * 判定「对账层」的说明。
 * @param {object|null} regression 回归段
 * @returns {string} 说明
 */
function regressionLayerNote(regression) {
  if (regression === null) return '未提供计划，本层不适用';
  if (regression.selected_missing.length > 0) {
    return `计划选样有 ${regression.selected_missing.length} 条未执行`;
  }
  if (regression.needs_review_planned > 0) {
    return `有 ${regression.needs_review_planned} 条待人工复核，不等于对账通过`;
  }
  if (regression.impact_complete !== true) return '有变更判不了，影响面不完整';
  return '计划选样全部执行完毕，且没有待复核或判不了的条目';
}

/**
 * 渲染失败与阻塞用例的明细。
 * @param {object[]} failures 失败与阻塞用例
 * @returns {string[]} 文本行
 */
function renderFailures(failures) {
  const lines = [];
  if (failures.length === 0) {
    lines.push('本次执行没有失败或阻塞的用例。', '');
    return lines;
  }
  for (const failure of failures) {
    lines.push(`### ${failure.case_id} · ${failure.title}`, '');
    lines.push(`- 状态：${failure.status}`);
    const error = failure.error && typeof failure.error === 'object' ? failure.error : null;
    lines.push(`- 错误类型：${error && error.type ? error.type : '无'}`);
    lines.push(`- 错误信息：${error && error.message ? error.message : '无'}`);
    const reproduction = failure.reproduction && typeof failure.reproduction === 'object' ? failure.reproduction : null;
    const command = reproduction && typeof reproduction.command === 'string' ? reproduction.command : '';
    lines.push(`- 复现命令：${command === '' ? '（无）' : `\`${command}\``}`);
    const steps = reproduction && Array.isArray(reproduction.steps) ? reproduction.steps : [];
    if (steps.length === 0) {
      lines.push('- 复现步骤：（无）');
    } else {
      lines.push('- 复现步骤：');
      steps.forEach((step, index) => lines.push(`  ${index + 1}. ${step}`));
    }
    const evidence = Array.isArray(failure.evidence) ? failure.evidence : [];
    if (evidence.length === 0) {
      lines.push('- 证据文件：（无）');
    } else {
      lines.push('- 证据文件：');
      for (const item of evidence) {
        const rel = item && typeof item.path === 'string' ? item.path : '（未命名）';
        lines.push(`  - ${rel}`);
      }
    }
    lines.push('');
  }
  return lines;
}

/**
 * 渲染计划对账段。
 * @param {object} regression 回归段
 * @param {string[]} needsReviewCaseIds 待人工复核的用例 id（逐条点名）
 * @returns {string[]} 文本行
 */
function renderRegression(regression, needsReviewCaseIds) {
  const lines = [];
  lines.push(`- 计划选样：${regression.selected_planned} 条`);
  lines.push(`- 已执行选样：${regression.selected_executed} 条`);
  lines.push(`- 漏跑：${regression.selected_missing.length} 条（${regression.selected_missing.join('、')}）`);
  lines.push(`- 待复核：${regression.needs_review_planned} 条`);
  lines.push(`- 已执行的待复核：${regression.needs_review_executed} 条`);
  lines.push(`- 判不了：${regression.undecidable_changes.length} 条（${regression.undecidable_changes.map((item) => item.change_id).join('、')}）`);
  lines.push(`- 影响面完整：${regression.impact_complete ? '是' : '否'}`);
  lines.push('');
  if (regression.selected_missing.length > 0) {
    lines.push('漏跑明细：', '');
    for (const caseId of regression.selected_missing) lines.push(`- ${caseId}`);
    lines.push('');
  }
  // 待复核用例必须**逐条点名**（AC-016）——只有条数的话，读者看不出是哪几条要人工复核。
  // 名单行只写 id 与「待复核」语境，**不写数字**（避免数字被当成别的指标的条数）。
  if (needsReviewCaseIds.length > 0) {
    lines.push('待复核明细：', '');
    for (const caseId of needsReviewCaseIds) lines.push(`- ${caseId}：待复核用例`);
    lines.push('');
  }
  if (regression.undecidable_changes.length > 0) {
    lines.push('判不了的变更明细：', '');
    for (const item of regression.undecidable_changes) {
      lines.push(`- ${item.change_id}：${item.reason}`);
    }
    lines.push('');
  }
  return lines;
}

/**
 * 渲染完整的 markdown 报告。
 * @param {object} report 报告对象
 * @param {{needsReviewCaseIds?: string[]}} [options] 附加渲染输入（待复核用例 id —— 供 md 点名用）
 * @returns {string} markdown 文本
 */
export function renderMarkdown(report, options = {}) {
  const { source, cases, verdict, failures, evidence, regression } = report;
  const needsReviewCaseIds = Array.isArray(options.needsReviewCaseIds) ? options.needsReviewCaseIds : [];
  const lines = [];
  lines.push('# 执行报告', '');
  lines.push(`- 运行标识：${source.run_id}`);
  lines.push(`- 套件标识：${source.suite}`);
  lines.push(`- 关联需求：${source.requirement}`);
  lines.push(`- 执行环境：${source.environment}`);
  lines.push(`- 开始时间：${source.started_at}`);
  lines.push(`- 结束时间：${source.finished_at}`);
  lines.push(`- 报告生成时间：${report.generated_at}`);
  lines.push(`- 产物目录：${source.artifacts}`);
  lines.push('');
  lines.push(renderDigest(report));
  lines.push('');

  lines.push('## 一、三层结论', '');
  lines.push('| 层 | 结论 | 说明 |');
  lines.push('|---|---|---|');
  lines.push(`| 用例层 | ${verdict.case_layer} | ${caseLayerNote(cases)} |`);
  lines.push(`| 证据层 | ${verdict.evidence_layer} | ${evidenceLayerNote(evidence)} |`);
  lines.push(`| 对账层（计划） | ${verdict.regression_layer} | ${regressionLayerNote(regression)} |`);
  lines.push(`| 总体结论 | ${verdict.overall} | 任一层不过，总体结论就不为通过 |`);
  lines.push('');

  lines.push('## 二、用例计数', '');
  lines.push('| 指标 | 数值 |');
  lines.push('|---|---|');
  lines.push(`| 用例总数 | ${cases.total} |`);
  lines.push(`| 通过 | ${cases.passed} |`);
  lines.push(`| 失败 | ${cases.failed} |`);
  lines.push(`| 阻塞 | ${cases.blocked} |`);
  lines.push(`| 跳过 | ${cases.skipped} |`);
  lines.push(`| 用例总耗时 | ${cases.duration_ms_total} 毫秒 |`);
  lines.push('');

  lines.push('## 三、失败与阻塞用例', '');
  for (const line of renderFailures(failures)) lines.push(line);

  lines.push('## 四、证据链核查', '');
  lines.push(`- 实查证据条目：${countClaimedEvidence(report)} 份`);
  lines.push(`- 实存证据文件：${evidence.files_present} 份`);
  lines.push(`- 缺失证据文件：${evidence.files_missing} 份`);
  if (evidence.missing_paths.length === 0) {
    lines.push('- 缺失路径：（无）');
  } else {
    lines.push('- 缺失路径：');
    for (const rel of evidence.missing_paths) lines.push(`  - ${rel}`);
  }
  lines.push('');
  if (evidence.findings.length === 0) {
    lines.push('证据层发现（evidence.findings）：（无）', '');
  } else {
    lines.push('证据层发现（evidence.findings）：', '');
    lines.push('| 类型 | 说明 |');
    lines.push('|---|---|');
    for (const finding of evidence.findings) {
      lines.push(`| ${finding.kind} | ${finding.message} |`);
    }
    lines.push('');
  }

  if (regression !== null) {
    lines.push('## 五、计划对账', '');
    for (const line of renderRegression(regression, needsReviewCaseIds)) lines.push(line);
  }

  lines.push(`## ${regression !== null ? '六' : '五'}、指纹`, '');
  lines.push(`- 输入 results_sha256：${source.results_sha256}`);
  lines.push(`- 输入 evidence_manifest_sha256：${source.evidence_manifest_sha256}`);
  lines.push(`- 报告 report_sha256：${report.report_sha256}`);
  lines.push('');
  return `${lines.join('\n')}`;
}

/**
 * 统计 results.json 里声称的证据条目总数（用于 md 的展示）。
 * @param {object} report 报告对象
 * @returns {number} 条目数
 */
function countClaimedEvidence(report) {
  const files = report.evidence ? report.evidence.files_present : 0;
  const missing = report.evidence ? report.evidence.files_missing : 0;
  return files + missing;
}
