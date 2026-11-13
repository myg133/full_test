#!/usr/bin/env node
/**
 * check-defect-cases.mjs —— 缺陷复现用例集的自洽校验器。
 *
 * 用法:
 *   node scripts/check-defect-cases.mjs <defect-cases.json>
 *
 * 查什么（对照 references/derivation-rules.md 的产物契约）:
 *   1. 顶层字段集**封闭**（7 个）与 `meta` 的必填字段；
 *   2. `requirements[]` 的编号连续、唯一，`source_ref` 形如 `defects.json#/defects/<i>`；
 *   3. `defects[]` 的字段集**封闭**、处置结论互斥且完备（`unresolved` 必带非空理由）；
 *   4. `cases[]` 的 id 合 `^TC-\d{3}$` 且唯一，必填字段齐全，`requirement_refs` 不悬空，
 *      `tags` 含 `defect-verify` 与全部缺陷 id，四个来源字段齐全；
 *   5. `coverage_matrix[]` 只列被覆盖的需求条目，且覆盖到每一个有对应用例的需求条目。
 *
 * 退出码: 0 = 自洽 / 1 = 不自洽 / 2 = 用法错误。
 *
 * 纯 Node.js：只用 node: 内置模块，零第三方依赖，不联网。
 */

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

import { isObject, isFilledString } from './lib/io.mjs';
import { TOP_LEVEL_FIELDS, DEFECT_ENTRY_FIELDS } from './lib/product.mjs';

const CASE_ID_PATTERN = /^TC-\d{3}$/;
const DISPOSITIONS = ['derived', 'reused', 'unresolved'];

/**
 * 校验产物文档。
 * @param {object} doc 产物文档
 * @returns {string[]} 问题清单（空数组 = 自洽）
 */
export function checkProduct(doc) {
  const problems = [];
  const push = (message) => problems.push(message);

  // --- 顶层字段集（封闭） ---
  const actualTop = Object.keys(doc);
  for (const field of TOP_LEVEL_FIELDS) {
    if (!actualTop.includes(field)) push(`顶层缺字段 ${field}`);
  }
  for (const field of actualTop) {
    if (!TOP_LEVEL_FIELDS.includes(field)) push(`顶层出现未声明的字段 ${field}`);
  }
  if (doc.schema_version !== 2) push(`schema_version=${JSON.stringify(doc.schema_version)}，应为 2`);

  const meta = isObject(doc.meta) ? doc.meta : {};
  if (!isFilledString(meta.source)) push('meta.source 缺失或为空');
  if (!isFilledString(meta.generated_at)) push('meta.generated_at 缺失或为空');
  if (!isFilledString(meta.cycle_id)) push('meta.cycle_id 缺失或为空');
  if (!isFilledString(meta.suite)) push('meta.suite 缺失或为空');

  const defects = Array.isArray(doc.defects) ? doc.defects : [];
  const cases = Array.isArray(doc.cases) ? doc.cases : [];
  const requirements = Array.isArray(doc.requirements) ? doc.requirements : [];
  const matrix = Array.isArray(doc.coverage_matrix) ? doc.coverage_matrix : [];
  if (!Array.isArray(doc.open_questions)) push('open_questions 不是数组');

  if (meta.case_count !== cases.length) {
    push(`meta.case_count=${JSON.stringify(meta.case_count)}，与 cases.length=${cases.length} 不符`);
  }
  if (meta.defect_count !== defects.length) {
    push(`meta.defect_count=${JSON.stringify(meta.defect_count)}，与 defects.length=${defects.length} 不符`);
  }

  // --- requirements[] ---
  const requirementIds = new Set();
  requirements.forEach((requirement, index) => {
    const at = `requirements[${index}]`;
    if (!isObject(requirement)) {
      push(`${at} 不是对象`);
      return;
    }
    if (!isFilledString(requirement.id)) {
      push(`${at}.id 缺失或为空`);
      return;
    }
    if (requirementIds.has(requirement.id)) push(`${at}.id 重复: ${requirement.id}`);
    requirementIds.add(requirement.id);
    if (requirement.id !== `R-${index + 1}`) {
      push(`${at}.id=${JSON.stringify(requirement.id)}，应为 R-${index + 1}`);
    }
    if (!/^defects\.json#\/defects\/\d+$/.test(String(requirement.source_ref))) {
      push(`${at}.source_ref=${JSON.stringify(requirement.source_ref)} 不形如 defects.json#/defects/<i>`);
    }
  });
  if (requirements.length !== defects.length) {
    push(`requirements[] 条目数=${requirements.length}，与 defects[] 条目数=${defects.length} 不符`);
  }

  // --- defects[] ---
  const defectIds = new Set();
  defects.forEach((entry, index) => {
    const at = `defects[${index}]`;
    if (!isObject(entry)) {
      push(`${at} 不是对象`);
      return;
    }
    const id = String(entry.id);
    for (const field of Object.keys(entry)) {
      if (!DEFECT_ENTRY_FIELDS.includes(field)) {
        push(`${at}（${id}）出现未声明的字段 ${field}`);
      }
    }
    if (!isFilledString(entry.id)) push(`${at}.id 缺失或为空`);
    if (defectIds.has(id)) push(`${at}.id 重复: ${id}`);
    defectIds.add(id);
    if (!isFilledString(entry.title)) push(`${at}.title 缺失或为空`);
    if (!isFilledString(entry.severity)) push(`${at}.severity 缺失或为空`);
    if (!isFilledString(entry.status)) push(`${at}.status 缺失或为空`);

    const disposition = entry.disposition;
    if (!DISPOSITIONS.includes(disposition)) {
      push(`${at}.disposition=${JSON.stringify(disposition)}，不在 {derived, reused, unresolved} 里`);
      return;
    }
    const hasReason = Object.prototype.hasOwnProperty.call(entry, 'reason');
    const hasRefs = Object.prototype.hasOwnProperty.call(entry, 'reused_case_refs');
    const hasDerived = Object.prototype.hasOwnProperty.call(entry, 'derived_case_id');
    if (disposition === 'derived') {
      if (!isFilledString(entry.derived_case_id)) push(`${at}.derived_case_id 缺失或为空`);
      if (hasRefs) push(`${at}（${id}）disposition=derived 却带 reused_case_refs`);
      if (hasReason) push(`${at}（${id}）disposition=derived 却带 reason`);
    } else if (disposition === 'reused') {
      if (!Array.isArray(entry.reused_case_refs) || entry.reused_case_refs.length === 0) {
        push(`${at}.reused_case_refs 缺失或为空数组`);
      } else {
        entry.reused_case_refs.forEach((ref, refIndex) => {
          if (!isObject(ref)) {
            push(`${at}.reused_case_refs[${refIndex}] 不是对象`);
            return;
          }
          if (!isFilledString(ref.suite)) push(`${at}.reused_case_refs[${refIndex}].suite 缺失或为空`);
          if (!isFilledString(ref.case_id)) push(`${at}.reused_case_refs[${refIndex}].case_id 缺失或为空`);
        });
      }
      if (hasDerived) push(`${at}（${id}）disposition=reused 却带 derived_case_id`);
      if (hasReason) push(`${at}（${id}）disposition=reused 却带 reason`);
    } else {
      if (!isFilledString(entry.reason)) push(`${at}.reason 缺失或为空`);
      if (hasRefs) push(`${at}（${id}）disposition=unresolved 却带 reused_case_refs`);
      if (hasDerived) push(`${at}（${id}）disposition=unresolved 却带 derived_case_id`);
    }
  });

  // --- cases[] ---
  const caseIds = new Set();
  cases.forEach((caseObj, index) => {
    const at = `cases[${index}]`;
    if (!isObject(caseObj)) {
      push(`${at} 不是对象`);
      return;
    }
    const id = String(caseObj.id);
    if (!CASE_ID_PATTERN.test(id)) push(`${at}.id=${JSON.stringify(caseObj.id)} 不合 ^TC-\\d{3}$`);
    if (caseIds.has(id)) push(`${at}.id 重复: ${id}`);
    caseIds.add(id);
    if (!isFilledString(caseObj.title)) push(`${at}.title 缺失或为空`);
    if (!isFilledString(caseObj.dimension)) push(`${at}.dimension 缺失或为空`);
    if (!isFilledString(caseObj.priority)) push(`${at}.priority 缺失或为空`);
    if (!isFilledString(caseObj.status)) push(`${at}.status 缺失或为空`);
    if (!Array.isArray(caseObj.method) || caseObj.method.length === 0) {
      push(`${at}.method 缺失或为空数组`);
    }
    if (!Array.isArray(caseObj.requirement_refs) || caseObj.requirement_refs.length === 0) {
      push(`${at}.requirement_refs 缺失或为空数组`);
    } else {
      caseObj.requirement_refs.forEach((ref, refIndex) => {
        if (!requirementIds.has(String(ref))) {
          push(`${at}.requirement_refs[${refIndex}]=${JSON.stringify(ref)} 悬空（requirements[] 里没有）`);
        }
      });
    }
    if (!Array.isArray(caseObj.steps) || caseObj.steps.length === 0) {
      push(`${at}.steps 缺失或为空数组`);
    } else {
      caseObj.steps.forEach((step, stepIndex) => {
        if (!isObject(step)) {
          push(`${at}.steps[${stepIndex}] 不是对象`);
          return;
        }
        if (!isFilledString(step.action)) push(`${at}.steps[${stepIndex}].action 缺失或为空`);
        if (!isFilledString(step.expected)) push(`${at}.steps[${stepIndex}].expected 缺失或为空`);
      });
    }
    if (!Array.isArray(caseObj.tags)) {
      push(`${at}.tags 不是数组`);
    } else if (!caseObj.tags.map(String).includes('defect-verify')) {
      push(`${at}.tags 里没有 "defect-verify"`);
    }
    if (!Array.isArray(caseObj.defect_refs) || caseObj.defect_refs.length === 0) {
      push(`${at}.defect_refs 缺失或为空数组`);
    } else {
      for (const ref of caseObj.defect_refs) {
        if (!defectIds.has(String(ref))) {
          push(`${at}.defect_refs 里的 ${JSON.stringify(ref)} 不在 defects[] 的 id 集合里`);
        }
        if (Array.isArray(caseObj.tags) && !caseObj.tags.map(String).includes(String(ref))) {
          push(`${at}.tags 里没有缺陷 id ${JSON.stringify(String(ref))}`);
        }
      }
    }
    if (!['derived', 'reused'].includes(caseObj.origin)) {
      push(`${at}.origin=${JSON.stringify(caseObj.origin)}，不在 {derived, reused} 里`);
    } else if (caseObj.origin === 'reused') {
      if (!isFilledString(caseObj.source_case_id)) push(`${at}.source_case_id 缺失或为空（origin=reused）`);
      if (!isFilledString(caseObj.source_suite)) push(`${at}.source_suite 缺失或为空（origin=reused）`);
    } else {
      if (caseObj.source_case_id !== null && caseObj.source_case_id !== undefined) {
        push(`${at}.source_case_id=${JSON.stringify(caseObj.source_case_id)}，origin=derived 时应为 null 或不存在`);
      }
      if (caseObj.source_suite !== null && caseObj.source_suite !== undefined) {
        push(`${at}.source_suite=${JSON.stringify(caseObj.source_suite)}，origin=derived 时应为 null 或不存在`);
      }
      if (Array.isArray(caseObj.defect_refs) && caseObj.defect_refs.length !== 1) {
        push(`${at}.defect_refs 长度为 ${caseObj.defect_refs.length}，派生用例只属于一条缺陷`);
      }
    }
  });

  // --- 处置结论与用例互相对得上 ---
  for (const entry of defects) {
    if (!isObject(entry)) continue;
    if (entry.disposition === 'derived') {
      const target = cases.find((caseObj) => isObject(caseObj) && caseObj.id === entry.derived_case_id);
      if (!target) push(`defects 里的 ${entry.id} 声明的 derived_case_id=${entry.derived_case_id} 在 cases[] 里找不到`);
      else if (target.origin !== 'derived') push(`defects 里的 ${entry.id} 的 derived_case_id 指向的用例 origin 不是 derived`);
    }
    if (entry.disposition === 'reused' && Array.isArray(entry.reused_case_refs)) {
      for (const ref of entry.reused_case_refs) {
        if (!isObject(ref)) continue;
        const target = cases.find((caseObj) => isObject(caseObj) && caseObj.id === ref.case_id);
        if (!target) push(`defects 里的 ${entry.id} 复用的用例 ${ref.case_id} 在 cases[] 里找不到`);
        else if (!Array.isArray(target.defect_refs) || !target.defect_refs.map(String).includes(String(entry.id))) {
          push(`defects 里的 ${entry.id} 复用的用例 ${ref.case_id} 的 defect_refs 里没有 ${entry.id}`);
        }
      }
    }
  }

  // --- coverage_matrix[] ---
  const covered = new Set();
  for (const caseObj of cases) {
    if (!isObject(caseObj)) continue;
    for (const ref of Array.isArray(caseObj.requirement_refs) ? caseObj.requirement_refs : []) {
      covered.add(String(ref));
    }
  }
  const matrixReqs = new Set();
  matrix.forEach((item, index) => {
    const at = `coverage_matrix[${index}]`;
    if (!isObject(item)) {
      push(`${at} 不是对象`);
      return;
    }
    if (!requirementIds.has(String(item.requirement))) {
      push(`${at}.requirement=${JSON.stringify(item.requirement)} 不在 requirements[] 里`);
    }
    if (matrixReqs.has(String(item.requirement))) push(`${at}.requirement 重复: ${item.requirement}`);
    matrixReqs.add(String(item.requirement));
    if (!Array.isArray(item.methods_applied) || item.methods_applied.length === 0) {
      push(`${at}.methods_applied 缺失或为空数组`);
    }
    if (!Array.isArray(item.dimensions) || item.dimensions.length === 0) {
      push(`${at}.dimensions 缺失或为空数组`);
    }
    if (item.skipped !== undefined && !Array.isArray(item.skipped)) push(`${at}.skipped 不是数组`);
  });
  for (const ref of covered) {
    if (!matrixReqs.has(ref)) push(`需求条目 ${ref} 有对应用例，但不在 coverage_matrix 里`);
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
    console.error('[usage] 用法: node scripts/check-defect-cases.mjs <defect-cases.json>');
    return 2;
  }
  const file = path.resolve(args[0]);
  if (!fs.existsSync(file)) {
    console.error(`[error] 产物文件不存在: ${file}`);
    return 1;
  }
  let doc = null;
  try {
    doc = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (err) {
    console.error(`[error] 产物不是合法 JSON: ${file}（${err && err.message ? err.message : String(err)}）`);
    return 1;
  }
  if (!isObject(doc)) {
    console.error(`[error] 产物的根节点必须是对象: ${file}`);
    return 1;
  }

  const problems = checkProduct(doc);
  if (problems.length > 0) {
    console.error(`[error] 产物不自洽，共 ${problems.length} 处问题: ${file}`);
    for (const problem of problems) console.error(`  · ${problem}`);
    return 1;
  }
  console.log(`[ok] 产物自洽: ${file}`);
  console.log(
    `[ok] 缺陷 ${Array.isArray(doc.defects) ? doc.defects.length : 0} 条、` +
      `复现用例 ${Array.isArray(doc.cases) ? doc.cases.length : 0} 条、` +
      `需求条目 ${Array.isArray(doc.requirements) ? doc.requirements.length : 0} 条`,
  );
  return 0;
}

process.exitCode = main();
