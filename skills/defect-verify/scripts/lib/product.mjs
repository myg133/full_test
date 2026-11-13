// product.mjs —— 产物装配（需求 F3 / F4）
//
// 产物 `defect-cases.json` = cases.json v2 的**超集**（多一个 `defects[]` 段）：
//   顶层字段集**封闭**（7 个）：
//     schema_version / meta / requirements / open_questions / coverage_matrix / defects / cases
//   `meta` 的字段集**开放**（可另带说明字段）。
//   `defects[]` 条目的字段集**封闭**（D80）：
//     id / title / severity / status / disposition + 条件字段 reason / reused_case_refs /
//     derived_case_id / source_cycle_id。
//
// ⚠️ 共享场景（D97）：多条缺陷引用**同一条**已有用例时，产物里该用例**只出现一次**，
//    它的 defect_refs / tags / requirement_refs 含**全部**引用它的缺陷；
//    每条缺陷**各自**的 disposition 仍独立为 reused。
//
// 纯 Node.js，只用 node: 内置模块。

import { isObject } from './io.mjs';
import { decide, EXTENSION_SEGMENT_START, EXTENSION_SEGMENT_END } from './derive.mjs';

/** 顶层字段集（封闭）。 */
export const TOP_LEVEL_FIELDS = [
  'schema_version',
  'meta',
  'requirements',
  'open_questions',
  'coverage_matrix',
  'defects',
  'cases',
];

/** `defects[]` 条目的字段集（封闭，D80）。 */
export const DEFECT_ENTRY_FIELDS = [
  'id',
  'title',
  'severity',
  'status',
  'disposition',
  'reason',
  'reused_case_refs',
  'derived_case_id',
  'source_cycle_id',
];

/** 复现用例的缺省方法（D74 之外的缺省约定：不是宣称做过完整方法学）。 */
export const DEFAULT_METHOD = 'M1.1';

/**
 * 把字符串数组按首次出现去重。
 * @param {string[]} values 原始数组
 * @returns {string[]}
 */
function uniqueStrings(values) {
  const out = [];
  for (const value of values) {
    if (typeof value !== 'string') continue;
    if (!out.includes(value)) out.push(value);
  }
  return out;
}

/**
 * 装配复用用例（沿用原用例的字段，改写 requirement_refs / status / tags，并挂上来源信息）。
 * @param {object} sourceCase 原用例
 * @param {{suite: string, defectIds: string[], reqIds: string[]}} refs 引用信息
 * @returns {object} 复现用例
 */
function buildReusedCase(sourceCase, refs) {
  const originalTags = Array.isArray(sourceCase.tags) ? sourceCase.tags.map(String) : [];
  const tags = uniqueStrings(originalTags);
  if (!tags.includes('defect-verify')) tags.push('defect-verify');
  for (const defectId of refs.defectIds) {
    if (!tags.includes(defectId)) tags.push(defectId);
  }
  return {
    id: sourceCase.id,
    title: sourceCase.title,
    // D76：复现用例的 requirement_refs 一律指向「它所复现的那个缺陷」的 R-<n>
    requirement_refs: uniqueStrings(refs.reqIds),
    dimension:
      typeof sourceCase.dimension === 'string' && sourceCase.dimension !== ''
        ? sourceCase.dimension
        : 'functional',
    priority:
      typeof sourceCase.priority === 'string' && sourceCase.priority !== ''
        ? sourceCase.priority
        : 'P0',
    method:
      Array.isArray(sourceCase.method) && sourceCase.method.length > 0
        ? sourceCase.method.slice()
        : [DEFAULT_METHOD],
    // D77：复现用例的 status 一律 active
    status: 'active',
    preconditions: Array.isArray(sourceCase.preconditions) ? sourceCase.preconditions.slice() : [],
    steps: Array.isArray(sourceCase.steps) ? sourceCase.steps.map((step) => ({ ...step })) : [],
    data: isObject(sourceCase.data) ? { ...sourceCase.data } : {},
    tags,
    defect_refs: uniqueStrings(refs.defectIds),
    origin: 'reused',
    source_case_id: sourceCase.id,
    source_suite: refs.suite,
  };
}

/**
 * 装配派生用例（由缺陷单的 reproduction 派生）。
 * @param {object} defect 缺陷单条目
 * @param {{id: string, reqId: string}} info 新编号与需求条目
 * @returns {object} 复现用例
 */
function buildDerivedCase(defect, info) {
  const reproduction = defect.reproduction;
  const expected = String(reproduction.expected_failure);
  return {
    id: info.id,
    title: `复现 ${defect.id}：${defect.title}`,
    requirement_refs: [info.reqId],
    dimension: 'functional',
    priority: 'P0',
    method: [DEFAULT_METHOD],
    status: 'active',
    preconditions: [],
    // F3.3：action 逐字沿用 reproduction.steps[i]；expected 记的是**缺陷的失败现象**
    steps: reproduction.steps.map((action) => ({ action: String(action), expected })),
    data: {
      command: reproduction.command,
      expected_failure: reproduction.expected_failure,
    },
    tags: ['defect-verify', defect.id],
    // 派生只属于一条缺陷（D97）
    defect_refs: [defect.id],
    origin: 'derived',
    source_case_id: null,
    source_suite: null,
  };
}

/**
 * 装配整个产物。
 * @param {{defects: object[], cases: object[], suite: string, cycleId: string,
 *          source: string, generatedAt: string}} input 输入
 * @returns {object} 产物文档
 */
export function buildProduct(input) {
  const { defects, cases, suite, cycleId, source, generatedAt } = input;
  const casesById = new Map(cases.map((caseObj) => [caseObj.id, caseObj]));

  // 扩展编号段分配（D81 / D82）：从 TC-101 起向上扫描，取第一个空闲号位
  const used = new Set(cases.map((caseObj) => caseObj.id));
  let nextNumber = EXTENSION_SEGMENT_START;
  const allocateId = () => {
    while (nextNumber <= EXTENSION_SEGMENT_END) {
      const candidate = `TC-${String(nextNumber).padStart(3, '0')}`;
      nextNumber += 1;
      if (used.has(candidate)) continue;
      used.add(candidate);
      return candidate;
    }
    return null;
  };

  // requirements[]：每个缺陷一条（R-1…R-<n>，按缺陷在输入中的顺序）
  const requirements = defects.map((defect, index) => ({
    id: `R-${index + 1}`,
    title: `缺陷 ${defect.id} 的复现要求`,
    source_ref: `defects.json#/defects/${index}`,
    testable: true,
  }));

  const defectEntries = [];
  const productCases = [];
  const productCaseById = new Map();
  const ctx = { cases, casesById, suite, allocateId };

  defects.forEach((defect, index) => {
    const reqId = requirements[index].id;
    const decision = decide(defect, ctx);
    const entry = {
      id: defect.id,
      title: defect.title,
      severity: defect.severity,
      status: typeof defect.status === 'string' ? defect.status : 'open',
      disposition: decision.disposition,
    };

    if (decision.disposition === 'reused') {
      entry.reused_case_refs = decision.reusedCaseRefs;
      for (const ref of decision.reusedCaseRefs) {
        const existing = productCaseById.get(ref.case_id);
        if (existing) {
          // D97 共享：同一用例只出现一次，来源字段合并进全部引用它的缺陷
          existing.defect_refs = uniqueStrings([...existing.defect_refs, defect.id]);
          existing.tags = uniqueStrings([...existing.tags, defect.id]);
          existing.requirement_refs = uniqueStrings([...existing.requirement_refs, reqId]);
          continue;
        }
        const created = buildReusedCase(casesById.get(ref.case_id), {
          suite,
          defectIds: [defect.id],
          reqIds: [reqId],
        });
        productCases.push(created);
        productCaseById.set(created.id, created);
      }
    } else if (decision.disposition === 'derived') {
      entry.derived_case_id = decision.derivedCaseId;
      const created = buildDerivedCase(defect, { id: decision.derivedCaseId, reqId });
      productCases.push(created);
      productCaseById.set(created.id, created);
    } else {
      entry.reason = decision.reason;
    }

    if (typeof defect.cycle_id === 'string' && defect.cycle_id !== '') {
      entry.source_cycle_id = defect.cycle_id;
    }
    defectEntries.push(entry);
  });

  // coverage_matrix[]：只列**被覆盖**的需求条目（unresolved 的缺陷不列）
  const covered = new Set();
  for (const caseObj of productCases) {
    for (const ref of caseObj.requirement_refs) covered.add(ref);
  }
  const coverageMatrix = requirements
    .filter((requirement) => covered.has(requirement.id))
    .map((requirement) => ({
      requirement: requirement.id,
      methods_applied: [DEFAULT_METHOD],
      skipped: [],
      dimensions: ['functional'],
    }));

  return {
    schema_version: 2,
    meta: {
      source,
      generated_at: generatedAt,
      case_count: productCases.length,
      defect_count: defects.length,
      cycle_id: cycleId,
      suite,
    },
    requirements,
    open_questions: [],
    coverage_matrix: coverageMatrix,
    defects: defectEntries,
    cases: productCases,
  };
}
