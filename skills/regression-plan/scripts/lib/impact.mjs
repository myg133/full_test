// impact.mjs —— 影响面判定（需求 F3 的核心公式）
//
//   affected(case)   = 需求命中 ∨ 用例命中 ∨ 维度命中（显式 @dim: 或 applies_when 信号词）
//   method_blocked   = 变更条目正文命中该用例所用方法的 not_applies_when
//   selected         = affected ∧ ¬method_blocked ∧ status == active
//   needs_review     = affected ∧  method_blocked
//
// 三条口径说明（与判据一致）：
//  - 维度命中走**两条路径**：显式 `@dim:<维度名>`，与条目正文命中该维度的 `applies_when` 信号词。
//    信号词路径的偏差方向是「多选」（多跑），属可容忍方向。
//  - 方法不适用走**隐式命中**：正文逐字包含某方法 `not_applies_when` 的某一条短语即算命中。
//    命中意味着「该方法在本次变更场景下不适用」→ 影响面判不了 → 交人工复核，
//    不得静默当成「不受影响」。
//  - 生命周期的判定只作用于 `selected`：`needs_review` 是「方法适用性判不了」，
//    与生命周期状态无关（判不了就得说出来，不能因为用例已废弃就悄悄丢掉）。
//
// 纯 Node.js，只依赖 node: 内置模块。

/**
 * 取出维度库的信号词集合（缺字段时按空处理，不得因库结构缺项而崩）。
 * @param {object} dim 维度条目
 * @returns {string[]} 信号词列表
 */
function signalsOf(dim) {
  const words = Array.isArray(dim.applies_when) ? dim.applies_when : [];
  return words.filter((word) => typeof word === 'string' && word !== '');
}

/**
 * 取出方法库的不适用短语集合（缺字段时按空处理）。
 * @param {object} method 方法条目
 * @returns {string[]} 短语列表
 */
function notAppliesOf(method) {
  const phrases = Array.isArray(method.not_applies_when) ? method.not_applies_when : [];
  return phrases.filter((phrase) => typeof phrase === 'string' && phrase !== '');
}

/**
 * 逐条变更条目判定它的影响面来源。
 * @param {object[]} entries 变更条目（changelog.mjs 的切分结果）
 * @param {object[]} dimensions 维度库条目
 * @param {object[]} methods 方法库条目
 * @returns {object[]} 变更条目的影响面（每条含 dimensions / explicit_dimensions / signal_dimensions / method_hits）
 */
export function analyzeChanges(entries, dimensions, methods) {
  const changes = [];
  for (const entry of entries) {
    const explicitDimensions = [];
    for (const id of entry.dim_refs) {
      if (!explicitDimensions.includes(id)) explicitDimensions.push(id);
    }

    const signalDimensions = [];
    for (const dim of dimensions) {
      for (const word of signalsOf(dim)) {
        if (!entry.text.includes(word)) continue;
        signalDimensions.push({ dimension: dim.id, signal: word });
        break;
      }
    }

    const methodHits = [];
    for (const method of methods) {
      for (const phrase of notAppliesOf(method)) {
        if (!entry.text.includes(phrase)) continue;
        methodHits.push(method.id);
        break;
      }
    }

    const hitDimensionIds = [];
    for (const dim of dimensions) {
      const hit = explicitDimensions.includes(dim.id) || signalDimensions.some((s) => s.dimension === dim.id);
      if (hit) hitDimensionIds.push(dim.id);
    }

    changes.push({
      id: entry.id,
      title: entry.title,
      requirement_refs: Array.isArray(entry.requirement_refs) ? entry.requirement_refs : [],
      case_refs: Array.isArray(entry.case_refs) ? entry.case_refs : [],
      dimensions: hitDimensionIds,
      explicit_dimensions: explicitDimensions,
      signal_dimensions: signalDimensions,
      method_hits: methodHits,
    });
  }
  return changes;
}

/**
 * 判定一条用例落在哪些变更条目的影响面内。
 * @param {object} caseObj 用例
 * @param {object[]} changes 变更条目影响面
 * @returns {object[]} 命中该用例的变更条目（按变更顺序）
 */
function affectedChanges(caseObj, changes) {
  const refs = Array.isArray(caseObj.requirement_refs) ? caseObj.requirement_refs : [];
  const dim = typeof caseObj.dimension === 'string' ? caseObj.dimension : '';
  const id = typeof caseObj.id === 'string' ? caseObj.id : '';
  const hit = [];
  for (const change of changes) {
    const hitRequirement = (Array.isArray(change.requirement_refs) ? change.requirement_refs : []).some(
      (ref) => refs.includes(ref),
    );
    const hitCase = (Array.isArray(change.case_refs) ? change.case_refs : []).includes(id);
    const hitDimension = (Array.isArray(change.dimensions) ? change.dimensions : []).includes(dim);
    if (hitRequirement || hitCase || hitDimension) hit.push(change);
  }
  return hit;
}

/**
 * 判定哪些变更条目把这条用例「方法挡住」了。
 *
 * 注意：被挡住这件事**来自任意变更条目**，不只是命中该用例影响面的那几条 ——
 * 「方法在本次变更场景下不适用」是场景级事实。
 *
 * @param {object} caseObj 用例
 * @param {object[]} changes 变更条目影响面
 * @returns {{change: object, method: string}[]} 挡住该用例的（变更条目，方法）对
 */
function blockedBy(caseObj, changes) {
  const methods = Array.isArray(caseObj.method) ? caseObj.method : [];
  const blocked = [];
  for (const change of changes) {
    for (const method of Array.isArray(change.method_hits) ? change.method_hits : []) {
      if (methods.includes(method)) blocked.push({ change, method });
    }
  }
  return blocked;
}

/**
 * 取该用例**自己**的命中路径标记（可解释的 reason）。
 *
 * 口径：标记必须指向**本用例自己**的实际命中路径 ——
 *   - `requirement_ref:<r>` ：该用例自己引用了需求条目 r，且变更条目也引用了它；
 *   - `case_ref:<id>`        ：变更条目显式引用了**本用例**；
 *   - `dim_ref:<dim>` / `dim_signal:<dim>(<词>)`：变更条目命中了**本用例所用的**维度。
 * 不得拿「变更条目里恰好有的第一个引用」冒充命中路径（那会把一条用例的 reason
 * 指向另一条用例或另一条需求）。
 *
 * @param {object} caseObj 用例
 * @param {object[]} hit 命中该用例的变更条目
 * @returns {string} 来源标记
 */
function firstMarker(caseObj, hit) {
  const caseId = typeof caseObj.id === 'string' ? caseObj.id : '';
  const caseRequirements = Array.isArray(caseObj.requirement_refs) ? caseObj.requirement_refs : [];
  const caseDimension = typeof caseObj.dimension === 'string' ? caseObj.dimension : '';
  for (const change of hit) {
    for (const ref of Array.isArray(change.requirement_refs) ? change.requirement_refs : []) {
      if (caseRequirements.includes(ref)) return `requirement_ref:${ref}`;
    }
    for (const ref of Array.isArray(change.case_refs) ? change.case_refs : []) {
      if (ref === caseId) return `case_ref:${ref}`;
    }
    for (const dim of Array.isArray(change.explicit_dimensions) ? change.explicit_dimensions : []) {
      if (dim === caseDimension) return `dim_ref:${dim}`;
    }
    for (const signal of Array.isArray(change.signal_dimensions) ? change.signal_dimensions : []) {
      if (signal.dimension === caseDimension) return `dim_signal:${signal.dimension}(${signal.signal})`;
    }
  }
  return 'affected';
}

/**
 * 逐条用例判定归属。
 * @param {object[]} cases 用例集
 * @param {object[]} changes 变更条目影响面
 * @returns {{selected: object[], needsReview: object[]}} 两个互斥集合
 */
export function selectCases(cases, changes) {
  const selected = [];
  const needsReview = [];
  for (const caseObj of cases) {
    const hit = affectedChanges(caseObj, changes);
    if (hit.length === 0) continue;
    const blocked = blockedBy(caseObj, changes);

    const changeRefs = [];
    for (const change of hit) if (!changeRefs.includes(change.id)) changeRefs.push(change.id);
    for (const item of blocked) if (!changeRefs.includes(item.change.id)) changeRefs.push(item.change.id);

    if (blocked.length > 0) {
      needsReview.push({
        case_id: caseObj.id,
        reason: `method_not_applies:${blocked[0].method}`,
        change_refs: changeRefs,
      });
      continue;
    }
    if (caseObj.status === 'active') {
      selected.push({
        case_id: caseObj.id,
        reason: firstMarker(caseObj, hit),
        change_refs: changeRefs,
      });
    }
  }
  return { selected, needsReview };
}

/**
 * 取一条变更条目「影响到的用例 id」集合（D45 / F5.1 的「影响用例(C)」）。
 *
 * 三条命中路径（与 F3 公式一致）：需求路径 / 用例路径 / 维度路径
 * （维度 = 显式 `@dim:` ∪ 正文命中的 `applies_when` 信号词，即 change.dimensions）。
 *
 * @param {object} change 变更条目影响面
 * @param {object[]} cases 用例集
 * @returns {string[]} 受该条目影响的用例 id
 */
function affectedCaseIds(change, cases) {
  const ids = [];
  const requirementRefs = Array.isArray(change.requirement_refs) ? change.requirement_refs : [];
  const caseRefs = Array.isArray(change.case_refs) ? change.case_refs : [];
  const dimensions = Array.isArray(change.dimensions) ? change.dimensions : [];
  for (const caseObj of cases) {
    const id = typeof caseObj.id === 'string' ? caseObj.id : '';
    const refs = Array.isArray(caseObj.requirement_refs) ? caseObj.requirement_refs : [];
    const dim = typeof caseObj.dimension === 'string' ? caseObj.dimension : '';
    const hitRequirement = requirementRefs.some((ref) => refs.includes(ref));
    const hitCase = caseRefs.includes(id);
    const hitDimension = dimensions.includes(dim);
    if (hitRequirement || hitCase || hitDimension) ids.push(id);
  }
  return ids;
}

/**
 * 给「判不了」的变更条目写一条可核对的理由。
 *
 * 理由必须说清「为什么推不出用例级影响面」，且不得点名不存在的实体。
 *
 * @param {object} change 变更条目影响面
 * @returns {string} 判不了的理由
 */
function undecidableReason(change) {
  const hasRequirement = (Array.isArray(change.requirement_refs) ? change.requirement_refs : []).length > 0;
  const hasCase = (Array.isArray(change.case_refs) ? change.case_refs : []).length > 0;
  const hasExplicit = (Array.isArray(change.explicit_dimensions) ? change.explicit_dimensions : []).length > 0;
  const hasSignal = (Array.isArray(change.signal_dimensions) ? change.signal_dimensions : []).length > 0;
  const hasMethod = (Array.isArray(change.method_hits) ? change.method_hits : []).length > 0;
  const hasExplicitRef = hasRequirement || hasCase || hasExplicit;
  if (!hasExplicitRef && !hasSignal && !hasMethod) {
    return '无显式引用，且正文未命中任何维度/方法信号，推不出用例级影响面';
  }
  if (!hasExplicitRef && !hasSignal) {
    return '只命中方法短语（无显式引用、无维度命中），推不出用例级影响面';
  }
  return '推不出用例级影响面：显式引用与维度信号都落不到具体用例，也没有被方法短语挡住的用例';
}

/**
 * 判定哪些变更条目「判不了」（D45 / F5.1 的可操作定义）。
 *
 *   影响用例(C)   = 需求路径 ∨ 用例路径 ∨ 维度路径 能落到**具体用例**的集合
 *   全影响面       = 所有变更条目的 影响用例(C) 之并
 *   挡住的用例(C)  = 全影响面里、用了被 C 的正文命中的 not_applies_when 短语所属方法的用例
 *   C 判不了 ⟺ 影响用例(C) 为空 且 挡住的用例(C) 为空
 *
 * 推论（也是必须落地的那两种情形）：
 *   - 只命中方法短语、且对应不到任何用例 → 判不了；
 *   - 合法引用、但无任何用例覆盖 → 判不了。
 * 这类条目**不得**让任何用例进 selected / needs_review，但必须显式列进 undecidable_changes，
 * 且 `summary.impact_complete` 必须因此为 false。
 *
 * @param {object[]} changes 变更条目影响面
 * @param {object[]} cases 用例集
 * @returns {{change_id: string, reason: string}[]} 判不了的变更条目
 */
export function findUndecidable(changes, cases) {
  const list = Array.isArray(cases) ? cases : [];
  const affectedByChange = new Map();
  const universe = new Set();
  for (const change of changes) {
    const ids = affectedCaseIds(change, list);
    affectedByChange.set(change.id, ids);
    for (const id of ids) universe.add(id);
  }

  const undecidable = [];
  for (const change of changes) {
    const affected = affectedByChange.get(change.id) || [];
    if (affected.length > 0) continue;
    // 挡住的用例(C)：全影响面里、用了被 C 命中的方法的用例
    const methodHits = Array.isArray(change.method_hits) ? change.method_hits : [];
    let blocked = 0;
    for (const caseObj of list) {
      const id = typeof caseObj.id === 'string' ? caseObj.id : '';
      if (!universe.has(id)) continue;
      const methods = Array.isArray(caseObj.method) ? caseObj.method : [];
      if (methods.some((method) => methodHits.includes(method))) blocked += 1;
    }
    if (blocked > 0) continue;
    undecidable.push({
      change_id: change.id,
      reason: undecidableReason(change),
    });
  }
  return undecidable;
}
