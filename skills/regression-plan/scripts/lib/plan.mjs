// plan.mjs —— 产出 regression-plan.json 的计划体
//
// 输出契约见 references/regression-plan-schema.md。
// 三个集合（selected / needs_review / undecidable_changes）两两互斥：
//  - selected 与 needs_review 按用例 id 互斥（一条用例要么「确定重跑」，要么「存疑待复核」）；
//  - undecidable_changes 装的是**变更条目**（不是用例），与前两者天然不同域，
//    且判不了的条目不得让任何用例进 selected。
//
// 纯 Node.js。

import { analyzeChanges, findUndecidable, selectCases } from './impact.mjs';

/**
 * 组装计划。
 *
 * @param {object} input 输入
 * @param {object[]} input.entries 变更条目
 * @param {object[]} input.cases 用例集
 * @param {object[]} input.dimensions 维度库条目
 * @param {object[]} input.methods 方法库条目
 * @param {string} input.cycleId 轮次号
 * @param {{changelog: string, cases: string}} input.source 输入来源
 * @returns {object} 计划对象
 */
export function buildPlan({ entries, cases, dimensions, methods, cycleId, source }) {
  const changes = analyzeChanges(entries, dimensions, methods);
  const { selected, needsReview } = selectCases(cases, changes);
  const undecidable = findUndecidable(changes, cases);

  return {
    schema_version: 1,
    cycle_id: cycleId,
    generated_at: new Date().toISOString(),
    source,
    changes,
    selected,
    needs_review: needsReview,
    undecidable_changes: undecidable,
    summary: {
      total_cases: cases.length,
      selected: selected.length,
      needs_review: needsReview.length,
      undecidable_changes: undecidable.length,
      impact_complete: undecidable.length === 0,
    },
  };
}

/**
 * 去掉时间戳字段后的可比对副本（幂等自验用）。
 * @param {object} plan 计划对象
 * @returns {object} 可比对副本
 */
export function withoutTimestamp(plan) {
  const copy = { ...plan };
  delete copy.generated_at;
  return copy;
}
