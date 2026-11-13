// derive.mjs —— 派生规则的核心判定（需求 F2 / D72~D97）
//
// 判定顺序（D75，**固定**）：
//
//   ① case_refs 非空？
//      ├─ 是 → **先按 id 去重**（D97）→ 逐个在已有用例集里找：
//      │        全部找到 ⇒ reused（reused_case_refs 记 suite + case_id）
//      │        任一找不到 ⇒ unresolved（reason 点名那个找不到的 id；不得部分复用，D73）
//      └─ 否 → ② 信息充分吗？（F1.3）
//               ├─ 否 ⇒ unresolved（reason 说明缺什么）
//               └─ 是 → ③ 特征匹配（D74 / D96）
//                        ├─ 命中 ⇒ reused（不得再新建用例）
//                        └─ 未命中 ⇒ derived（派生 1 条新用例；扩展段用尽 ⇒ unresolved，D81）
//
// 纯 Node.js，只用 node: 内置模块。

import { isObject } from './io.mjs';
import { featureMatches } from './normalize.mjs';

/** 扩展编号段（D81）：TC-101 ~ TC-999（三位数字封顶，TC-1001 不合法）。 */
export const EXTENSION_SEGMENT_START = 101;
export const EXTENSION_SEGMENT_END = 999;

/**
 * 按 id 去重（保留首次出现的顺序）—— D97：同一缺陷的 case_refs 内重复 id 先去重再判。
 * @param {string[]} ids 原始 id 列表
 * @returns {string[]}
 */
export function dedupeIds(ids) {
  const out = [];
  for (const id of ids) {
    if (typeof id !== 'string') continue;
    if (!out.includes(id)) out.push(id);
  }
  return out;
}

/**
 * 复现信息是否充分（F1.3 —— **内容层**，不报错，由这里判 unresolved）。
 * @param {object} defect 缺陷单条目
 * @returns {string[]} 缺什么（空数组 = 充分）
 */
export function missingReproductionInfo(defect) {
  const missing = [];
  const reproduction = isObject(defect) && isObject(defect.reproduction) ? defect.reproduction : null;
  if (!reproduction) {
    missing.push('reproduction 缺失');
    return missing;
  }
  if (typeof reproduction.command !== 'string' || reproduction.command.trim() === '') {
    missing.push('reproduction.command 缺失或为空白');
  }
  if (!Array.isArray(reproduction.steps) || reproduction.steps.length === 0) {
    missing.push('reproduction.steps 缺失或为空数组');
  }
  if (typeof reproduction.expected_failure !== 'string' || reproduction.expected_failure.trim() === '') {
    missing.push('reproduction.expected_failure 缺失或为空白');
  }
  return missing;
}

/**
 * 判定一条缺陷的处置结论（**有且只有一个**）。
 * @param {object} defect 缺陷单条目
 * @param {{cases: object[], casesById: Map<string, object>, suite: string, allocateId: () => (string|null)}} ctx 上下文
 * @returns {{disposition: 'derived'|'reused'|'unresolved', reason?: string,
 *            reusedCaseRefs?: {suite: string, case_id: string}[], derivedCaseId?: string}}
 */
export function decide(defect, ctx) {
  const refs = dedupeIds(Array.isArray(defect.case_refs) ? defect.case_refs : []);

  // ① case_refs 分支
  if (refs.length > 0) {
    const missing = refs.filter((ref) => !ctx.casesById.has(ref));
    if (missing.length > 0) {
      return {
        disposition: 'unresolved',
        reason:
          `case_refs 里的用例 ${missing.join(' / ')} 在已有用例集里找不到` +
          '（不得部分复用：要么整条复用成功，要么显式说不知道）',
      };
    }
    const deprecated = refs.find((ref) => ctx.casesById.get(ref).status === 'deprecated');
    if (deprecated) {
      return {
        disposition: 'unresolved',
        reason: `复用的原用例 ${deprecated} 已废弃（status=deprecated），无法作为复现用例复用`,
      };
    }
    return {
      disposition: 'reused',
      reusedCaseRefs: refs.map((ref) => ({ suite: ctx.suite, case_id: ref })),
    };
  }

  // ② 信息充分性（只是「派生分支」的前置 —— reused 不需要 reproduction）
  const missingInfo = missingReproductionInfo(defect);
  if (missingInfo.length > 0) {
    return {
      disposition: 'unresolved',
      reason:
        `复现信息不足：${missingInfo.join('、')}` +
        '（说不出怎么复现 ⇒ 显式说不知道，不派生也不假装复用）',
    };
  }

  // ③ 特征匹配
  const hit = ctx.cases.find((caseObj) => featureMatches(caseObj, defect));
  if (hit) {
    if (hit.status === 'deprecated') {
      return {
        disposition: 'unresolved',
        reason: `特征匹配到的原用例 ${hit.id} 已废弃（status=deprecated），无法作为复现用例复用`,
      };
    }
    return {
      disposition: 'reused',
      reusedCaseRefs: [{ suite: ctx.suite, case_id: hit.id }],
    };
  }

  // ④ 未命中 ⇒ 派生 1 条新用例
  const newId = ctx.allocateId();
  if (!newId) {
    return {
      disposition: 'unresolved',
      reason:
        `扩展编号段 TC-${EXTENSION_SEGMENT_START}~TC-${EXTENSION_SEGMENT_END} 已用尽，` +
        '无法为该缺陷分配新的复现用例编号',
    };
  }
  return { disposition: 'derived', derivedCaseId: newId };
}
