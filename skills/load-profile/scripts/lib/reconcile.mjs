// reconcile.mjs —— 与功能用例集的**链路存在性**对账（契约 F4.3）
//
// 规则（机械可算）：
//   1. 取输入用例集 `cases[].steps[].action`；
//   2. **归一化**：取「方法 + 空格 + 路径」，并删掉路径中所有 `{...}` 占位符段
//      （`GET /api/v1/orders/{id}` → `GET /api/v1/orders`）；
//   3. 归一化结果**等于** workload 的 `target` 的用例 id，按用例出现顺序去重 ⇒ `case_refs`；
//   4. `case_refs` 为空 ⇒ 该场景必须留一条 `topic == "coverage"` 的未决问题。
//
// ⚠️ **只回答「这条被压链路在功能用例集里有没有对应用例」**：
//    不派生用例、不写 cases.json、不改功能用例集。
//
// 纯函数模块（不碰文件系统）。

import { isObject } from './io.mjs';

/**
 * 归一化一条 action：取「方法 + 空格 + 路径」，删掉路径中所有 `{...}` 占位符段。
 * @param {*} action 原始 action
 * @returns {string|null} 归一化结果（无法解析时为 null）
 */
export function normalizeAction(action) {
  if (typeof action !== 'string') return null;
  const parts = action.trim().split(/\s+/);
  if (parts.length < 2) return null;
  const method = parts[0];
  const rawPath = parts[1];
  const segments = rawPath
    .split('/')
    .filter((segment) => !(segment.startsWith('{') && segment.endsWith('}')));
  return `${method} ${segments.join('/')}`;
}

/**
 * 算出某个被压链路在功能用例集里的对应用例 id（按用例出现顺序去重）。
 * @param {*} casesDoc 功能用例集（cases.json v2）
 * @param {string} target 被压链路（"METHOD /path"）
 * @returns {string[]} 对应用例 id
 */
export function collectCaseRefs(casesDoc, target) {
  const refs = [];
  const cases = isObject(casesDoc) && Array.isArray(casesDoc.cases) ? casesDoc.cases : [];
  for (const item of cases) {
    if (!isObject(item) || typeof item.id !== 'string') continue;
    const steps = Array.isArray(item.steps) ? item.steps : [];
    for (const step of steps) {
      const action = isObject(step) ? step.action : null;
      if (normalizeAction(action) === target) {
        if (!refs.includes(item.id)) refs.push(item.id);
        break;
      }
    }
  }
  return refs;
}
