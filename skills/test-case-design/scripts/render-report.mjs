#!/usr/bin/env node
// render-report.mjs — 用例集 Markdown 报告渲染器（schema v2）
//
// 用法: node scripts/render-report.mjs <cases.json>
// 输出: stdout，五部分 —— 用例总览表 / 追溯矩阵 / 未覆盖需求条目清单 / 未决问题 / 覆盖矩阵
// 退出码: 0 = 渲染完成, 1 = 读取或解析失败
//
// 纯 Node.js 实现，只依赖 node: 内置模块；只读文件，不发起网络请求。
//
// v2 说明：deprecated 状态的用例在总览表中标注，但不计入“已覆盖”；
// 未决问题与覆盖矩阵来自 open_questions[] / coverage_matrix[]，缺失时章节保留并标注未声明。

import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import process from 'node:process';

const CASE_STATUSES = ['active', 'deprecated', 'modified', 'blocked'];

function isObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isFilledString(value) {
  return typeof value === 'string' && value.trim() !== '';
}

// 表格单元格转义：竖线会截断 Markdown 表格，换行会破坏单行结构
function escapeCell(value) {
  if (!isFilledString(value)) return '';
  return value.replace(/\|/g, '\\|').replace(/\r?\n/g, ' ').trim();
}

// 状态归一化：缺失按 active 处理（v1 用例集没有状态字段）
function caseStatus(item) {
  if (!isObject(item)) return 'active';
  return typeof item.status === 'string' && CASE_STATUSES.includes(item.status) ? item.status : 'active';
}

// 覆盖统计：deprecated 的用例不参与覆盖
function buildCoverage(requirements, cases) {
  const covered = new Map();

  cases.forEach((item) => {
    if (!isObject(item) || !Array.isArray(item.requirement_refs)) return;
    if (caseStatus(item) === 'deprecated') return;
    item.requirement_refs.forEach((ref) => {
      if (!isFilledString(ref)) return;
      if (!covered.has(ref)) covered.set(ref, []);
      if (isFilledString(item.id) && !covered.get(ref).includes(item.id)) {
        covered.get(ref).push(item.id);
      }
    });
  });

  const rows = requirements
    .filter((item) => isObject(item) && isFilledString(item.id))
    .map((item) => {
      const caseIds = covered.get(item.id) || [];
      return {
        id: item.id,
        title: isFilledString(item.title) ? item.title : '',
        testable: item.testable !== false,
        caseIds,
        status: caseIds.length > 0 ? '已覆盖' : '未覆盖',
      };
    });

  return rows;
}

// 未决问题章节（v2）
function renderOpenQuestions(lines, questions) {
  lines.push('## 未决问题');
  lines.push('');

  if (!Array.isArray(questions) || questions.length === 0) {
    lines.push('（未声明未决问题：要么需求无歧义，要么尚未识别歧义）');
    lines.push('');
    return;
  }

  questions.forEach((item, index) => {
    const at = isObject(item) ? item : {};
    const id = isFilledString(at.id) ? at.id : `open_questions[${index}]`;
    const refs = Array.isArray(at.requirement_refs)
      ? at.requirement_refs.filter(isFilledString).join(', ')
      : '';
    const affected = Array.isArray(at.affected_cases)
      ? at.affected_cases.filter(isFilledString).join(', ')
      : '';

    lines.push(`### ${id}`);
    lines.push('');
    lines.push(`- 问题: ${escapeCell(at.question)}`);
    lines.push(`- 严重级别: ${escapeCell(at.severity) || '未标注'}`);
    lines.push(`- 覆盖方式: ${escapeCell(at.coverage) || '未标注'}`);
    if (isFilledString(at.defer_reason)) {
      lines.push(`- 延后理由: ${escapeCell(at.defer_reason)}`);
    }
    lines.push(`- 关联需求条目: ${refs || '—'}`);
    lines.push(`- 受影响用例: ${affected || '—'}`);
    lines.push('');

    const interpretations = Array.isArray(at.interpretations) ? at.interpretations : [];
    if (interpretations.length === 0) {
      lines.push('（未给出解读）');
      lines.push('');
      return;
    }
    lines.push('| 解读 | 影响 |');
    lines.push('| --- | --- |');
    interpretations.forEach((interpretation) => {
      const reading = isObject(interpretation) ? interpretation.reading : '';
      const impact = isObject(interpretation) ? interpretation.impact : '';
      lines.push(`| ${escapeCell(reading)} | ${escapeCell(impact)} |`);
    });
    lines.push('');
  });
}

// 覆盖矩阵章节（v2）
function renderCoverageMatrix(lines, matrix) {
  lines.push('## 覆盖矩阵');
  lines.push('');

  if (!Array.isArray(matrix) || matrix.length === 0) {
    lines.push('（未声明覆盖矩阵：无法审计“跳过了哪些方法、为什么跳过”）');
    lines.push('');
    return;
  }

  lines.push('| 需求条目 | 已应用方法 | 跳过方法及原因 | 覆盖维度 |');
  lines.push('| --- | --- | --- | --- |');
  matrix.forEach((item, index) => {
    const at = isObject(item) ? item : {};
    const requirement = isFilledString(at.requirement) ? at.requirement : `coverage_matrix[${index}]`;

    const applied = Array.isArray(at.methods_applied)
      ? at.methods_applied.filter(isFilledString).join(', ')
      : '';

    const skipped = Array.isArray(at.skipped)
      ? at.skipped
          .filter(isObject)
          .map((skip) => {
            const method = isFilledString(skip.method) ? skip.method : '(未命名方法)';
            const reason = isFilledString(skip.reason) ? skip.reason : '(未说明原因)';
            return `${method}：${reason}`;
          })
          .join('；')
      : '';

    const dimensions = Array.isArray(at.dimensions)
      ? at.dimensions.filter(isFilledString).join(', ')
      : '';

    lines.push(
      `| ${escapeCell(requirement)} | ${escapeCell(applied) || '—'} | ${escapeCell(skipped) || '—'} | ${escapeCell(dimensions) || '—'} |`,
    );
  });
  lines.push('');
}

function render(doc, file) {
  const requirements = Array.isArray(doc.requirements) ? doc.requirements : [];
  const cases = Array.isArray(doc.cases) ? doc.cases : [];
  const rows = buildCoverage(requirements, cases);
  const uncovered = rows.filter((row) => row.status === '未覆盖');
  const questions = Array.isArray(doc.open_questions) ? doc.open_questions : [];
  const matrix = Array.isArray(doc.coverage_matrix) ? doc.coverage_matrix : [];

  const meta = isObject(doc.meta) ? doc.meta : {};
  const source = isFilledString(meta.source) ? meta.source : '未标注';
  const generatedAt = isFilledString(meta.generated_at) ? meta.generated_at : '未标注';
  const testableCount = rows.filter((row) => row.testable).length;
  const deprecatedCount = cases.filter((item) => caseStatus(item) === 'deprecated').length;

  const lines = [];

  lines.push('# 测试用例报告');
  lines.push('');
  lines.push(`- 用例集文件: \`${file}\``);
  lines.push(`- 需求来源: ${escapeCell(source)}`);
  lines.push(`- 生成时间: ${escapeCell(generatedAt)}`);
  lines.push(`- 需求条目总数: ${rows.length}（可测试 ${testableCount}）`);
  lines.push(`- 用例总数: ${cases.length}（其中 deprecated ${deprecatedCount} 条，不计入覆盖）`);
  lines.push(`- 未决问题数: ${questions.length}`);
  lines.push('');

  lines.push('## 用例总览');
  lines.push('');
  if (cases.length === 0) {
    lines.push('（用例集为空）');
  } else {
    lines.push('| 用例 ID | 标题 | 关联需求 | 维度 | 优先级 | 状态 |');
    lines.push('| --- | --- | --- | --- | --- | --- |');
    cases.forEach((item, index) => {
      const at = isObject(item) ? item : {};
      const refs = Array.isArray(at.requirement_refs)
        ? at.requirement_refs.filter(isFilledString).join(', ')
        : '';
      const status = caseStatus(at);
      const statusCell = status === 'deprecated' ? 'deprecated（不计入覆盖）' : status;
      lines.push(
        `| ${escapeCell(at.id) || `cases[${index}]`} | ${escapeCell(at.title)} | ${escapeCell(refs)} | ${escapeCell(at.dimension)} | ${escapeCell(at.priority)} | ${statusCell} |`,
      );
    });
  }
  lines.push('');

  lines.push('## 追溯矩阵');
  lines.push('');
  if (rows.length === 0) {
    lines.push('（没有需求条目）');
  } else {
    lines.push('| 需求条目 | 标题 | 可测试 | 覆盖用例 | 覆盖状态 |');
    lines.push('| --- | --- | --- | --- | --- |');
    rows.forEach((row) => {
      const caseIds = row.caseIds.length > 0 ? row.caseIds.join(', ') : '—';
      lines.push(
        `| ${escapeCell(row.id)} | ${escapeCell(row.title)} | ${row.testable ? '是' : '否'} | ${escapeCell(caseIds)} | ${row.status} |`,
      );
    });
  }
  lines.push('');

  lines.push('## 未覆盖需求条目');
  lines.push('');
  if (uncovered.length === 0) {
    lines.push('无（全部需求条目均已被用例覆盖）');
  } else {
    uncovered.forEach((row) => {
      const note = row.testable ? '可测试但无用例覆盖' : '标记为不可测试';
      const title = row.title ? ` — ${escapeCell(row.title)}` : '';
      lines.push(`- ${escapeCell(row.id)}${title}（${note}）`);
    });
  }
  lines.push('');

  renderOpenQuestions(lines, questions);
  renderCoverageMatrix(lines, matrix);

  return lines.join('\n');
}

function main() {
  const file = process.argv[2];

  if (!file) {
    process.stderr.write('用法: node scripts/render-report.mjs <cases.json>\n');
    process.exit(2);
  }

  const target = resolve(file);

  let raw;
  try {
    raw = readFileSync(target, 'utf8');
  } catch (err) {
    process.stderr.write(`无法读取用例集文件: ${file}（${err.message}）\n`);
    process.exit(1);
  }

  let doc;
  try {
    doc = JSON.parse(raw);
  } catch (err) {
    process.stderr.write(`JSON 语法错误: ${file} 解析失败 — ${err.message}\n`);
    process.exit(1);
  }

  if (!isObject(doc)) {
    process.stderr.write('结构错误: 用例集根节点必须是 JSON 对象\n');
    process.exit(1);
  }

  process.stdout.write(`${render(doc, file)}\n`);
  process.exit(0);
}

main();
