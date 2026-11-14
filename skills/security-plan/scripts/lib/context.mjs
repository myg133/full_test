// context.mjs —— 安全上下文的结构层校验与归一化（契约 F1.2 / D99 / D101）
//
// 结构层约束（违反 ⇒ 报错退出 rc=1，**不留半份产物**）：
//   根        必须是对象
//   schema_version  可选；若存在必须是 1
//   service   必须是对象；service.name 必填且非空字符串
//   assets           必填非空数组；id ^AS-\d{1,3}$ 且文件内唯一；name 非空；
//                    sensitivity ∈ {critical,high,medium,low}；description 可选非空字符串
//   trust_boundaries 必填非空数组；id ^TB-\d{1,3}$ 且唯一；name 非空；
//                    controls **必填**数组（元素非空字符串，可为空数组）；from/to 可选
//   entry_points     必填非空数组；id ^EP-\d{1,3}$ 且唯一；name 非空；kind 非空字符串；
//                    asset_refs / boundary_refs **必填非空**且不悬空；description 可选
//   roles            必填非空数组；id ^ROLE-\d{1,3}$ 且唯一；name 非空
//   resources        必填非空数组；id ^RES-\d{1,3}$ 且唯一；name 非空；
//                    asset_refs **必填非空**且不悬空
//
// ⚠️ 报错信息必须**点名坏点**（字段路径 + 出错值）—— 这是判据 AC-005~AC-008 的依据。

import { InputError, isFilledString, isObject } from './io.mjs';
import { SENSITIVITIES } from './catalog.mjs';

const ID_PATTERNS = {
  assets: /^AS-\d{1,3}$/,
  trust_boundaries: /^TB-\d{1,3}$/,
  entry_points: /^EP-\d{1,3}$/,
  roles: /^ROLE-\d{1,3}$/,
  resources: /^RES-\d{1,3}$/,
};

/**
 * 校验一个 id 字段（格式 + 文件内唯一）。
 * @param {string} at 字段路径（如 assets[0].id）
 * @param {*} value 待校验值
 * @param {string} section 所属段名
 * @param {Set<string>} seen 已出现过的 id 集合
 */
function checkId(at, value, section, seen) {
  if (!isFilledString(value)) {
    throw new InputError(`${at} 缺少必填字段 id（必须是非空字符串）`);
  }
  const pattern = ID_PATTERNS[section];
  if (!pattern.test(value)) {
    throw new InputError(
      `${at} 格式非法: "${value}"（id 须匹配 ${pattern.source}）`,
    );
  }
  if (seen.has(value)) {
    throw new InputError(`${at} 重复: "${value}"（${section} 内必须唯一）`);
  }
  seen.add(value);
}

/**
 * 校验一个「非空字符串数组」字段。
 * @param {string} at 字段路径
 * @param {*} value 待校验值
 * @param {boolean} allowEmpty 是否允许空数组
 */
function checkStringArray(at, value, allowEmpty) {
  if (!Array.isArray(value)) {
    throw new InputError(`${at} 必须是数组`);
  }
  if (!allowEmpty && value.length === 0) {
    throw new InputError(`${at} 为空（该字段必须至少有一个元素）`);
  }
  value.forEach((item, index) => {
    if (!isFilledString(item)) {
      throw new InputError(`${at}[${index}] 必须是非空字符串`);
    }
  });
}

/**
 * 校验可选的说明字段（存在就必须是非空字符串）。
 * @param {string} at 字段路径
 * @param {*} value 待校验值
 */
function checkOptionalText(at, value) {
  if (value === undefined) return;
  if (!isFilledString(value)) {
    throw new InputError(`${at} 存在但不是非空字符串`);
  }
}

/**
 * 校验一个引用数组（每个元素 ∈ 允许的 id 集合）。
 * @param {string} at 字段路径
 * @param {*} value 待校验值
 * @param {Set<string>} allowed 允许的 id 集合
 * @param {string} targetName 被引用段的人读名（错误信息里用）
 */
function checkRefs(at, value, allowed, targetName) {
  checkStringArray(at, value, false);
  value.forEach((ref, index) => {
    if (!allowed.has(ref)) {
      throw new InputError(
        `${at}[${index}] 悬空引用: "${ref}"（${targetName} 里不存在这个 id）`,
      );
    }
  });
}

/**
 * 校验安全上下文并归一化。
 * @param {*} doc 解析后的 JSON
 * @param {string} file 来源文件（错误信息里用）
 * @returns {{service: object, assets: object[], trustBoundaries: object[], entryPoints: object[], roles: object[], resources: object[]}}
 */
export function validateContext(doc, file) {
  if (!isObject(doc)) {
    throw new InputError(`安全上下文的根节点必须是 JSON 对象: ${file}`);
  }

  if (doc.schema_version !== undefined && doc.schema_version !== 1) {
    throw new InputError(
      `schema_version 取值非法: ${JSON.stringify(doc.schema_version)}（必须是 1）`,
    );
  }

  // --- service ---
  if (!isObject(doc.service)) {
    throw new InputError(`service 必须是对象`);
  }
  if (!isFilledString(doc.service.name)) {
    throw new InputError(`service.name 缺少必填字段（必须是非空字符串）`);
  }

  // --- assets ---
  if (doc.assets === undefined) {
    throw new InputError(`assets 缺少必填字段（必须是非空数组）`);
  }
  if (!Array.isArray(doc.assets)) {
    throw new InputError(`assets 必须是数组`);
  }
  if (doc.assets.length === 0) {
    throw new InputError(`assets 为空（至少要有一个资产）`);
  }
  const assetIds = new Set();
  const assets = doc.assets.map((item, index) => {
    const at = `assets[${index}]`;
    if (!isObject(item)) throw new InputError(`${at} 必须是对象`);
    checkId(`${at}.id`, item.id, 'assets', assetIds);
    if (!isFilledString(item.name)) {
      throw new InputError(`${at}.name 缺少必填字段（必须是非空字符串）`);
    }
    if (!SENSITIVITIES.includes(item.sensitivity)) {
      throw new InputError(
        `${at}.sensitivity 取值非法: ${JSON.stringify(item.sensitivity)}` +
          `（允许值: ${SENSITIVITIES.join(' / ')}）`,
      );
    }
    checkOptionalText(`${at}.description`, item.description);
    return {
      id: item.id,
      name: item.name,
      sensitivity: item.sensitivity,
      description: isFilledString(item.description) ? item.description : '',
    };
  });

  // --- trust_boundaries ---
  if (doc.trust_boundaries === undefined) {
    throw new InputError(`trust_boundaries 缺少必填字段（必须是非空数组）`);
  }
  if (!Array.isArray(doc.trust_boundaries)) {
    throw new InputError(`trust_boundaries 必须是数组`);
  }
  if (doc.trust_boundaries.length === 0) {
    throw new InputError(`trust_boundaries 为空（至少要有一条信任边界）`);
  }
  const boundaryIds = new Set();
  const trustBoundaries = doc.trust_boundaries.map((item, index) => {
    const at = `trust_boundaries[${index}]`;
    if (!isObject(item)) throw new InputError(`${at} 必须是对象`);
    checkId(`${at}.id`, item.id, 'trust_boundaries', boundaryIds);
    if (!isFilledString(item.name)) {
      throw new InputError(`${at}.name 缺少必填字段（必须是非空字符串）`);
    }
    if (item.controls === undefined) {
      throw new InputError(`${at}.controls 缺少必填字段（必须是非空数组，没有控制点就写 []）`);
    }
    checkStringArray(`${at}.controls`, item.controls, true);
    checkOptionalText(`${at}.from`, item.from);
    checkOptionalText(`${at}.to`, item.to);
    return {
      id: item.id,
      name: item.name,
      controls: item.controls.slice(),
      from: isFilledString(item.from) ? item.from : '',
      to: isFilledString(item.to) ? item.to : '',
    };
  });

  // --- entry_points ---
  if (doc.entry_points === undefined) {
    throw new InputError(`entry_points 缺少必填字段（必须是非空数组）`);
  }
  if (!Array.isArray(doc.entry_points)) {
    throw new InputError(`entry_points 必须是数组`);
  }
  if (doc.entry_points.length === 0) {
    throw new InputError(`entry_points 为空（至少要有一个入口点）`);
  }
  const entryIds = new Set();
  const entryPoints = doc.entry_points.map((item, index) => {
    const at = `entry_points[${index}]`;
    if (!isObject(item)) throw new InputError(`${at} 必须是对象`);
    checkId(`${at}.id`, item.id, 'entry_points', entryIds);
    if (!isFilledString(item.name)) {
      throw new InputError(`${at}.name 缺少必填字段（必须是非空字符串）`);
    }
    if (!isFilledString(item.kind)) {
      throw new InputError(`${at}.kind 缺少必填字段（必须是非空字符串）`);
    }
    if (item.asset_refs === undefined) {
      throw new InputError(`${at}.asset_refs 缺少必填字段（必须是非空数组）`);
    }
    checkRefs(`${at}.asset_refs`, item.asset_refs, assetIds, 'assets');
    if (item.boundary_refs === undefined) {
      throw new InputError(`${at}.boundary_refs 缺少必填字段（必须是非空数组）`);
    }
    checkRefs(`${at}.boundary_refs`, item.boundary_refs, boundaryIds, 'trust_boundaries');
    checkOptionalText(`${at}.description`, item.description);
    return {
      id: item.id,
      name: item.name,
      kind: item.kind,
      asset_refs: item.asset_refs.slice(),
      boundary_refs: item.boundary_refs.slice(),
      description: isFilledString(item.description) ? item.description : '',
    };
  });

  // --- roles ---
  if (doc.roles === undefined) {
    throw new InputError(`roles 缺少必填字段（必须是非空数组）`);
  }
  if (!Array.isArray(doc.roles)) {
    throw new InputError(`roles 必须是数组`);
  }
  if (doc.roles.length === 0) {
    throw new InputError(`roles 为空（至少要有一个角色）`);
  }
  const roleIds = new Set();
  const roles = doc.roles.map((item, index) => {
    const at = `roles[${index}]`;
    if (!isObject(item)) throw new InputError(`${at} 必须是对象`);
    checkId(`${at}.id`, item.id, 'roles', roleIds);
    if (!isFilledString(item.name)) {
      throw new InputError(`${at}.name 缺少必填字段（必须是非空字符串）`);
    }
    return { id: item.id, name: item.name };
  });

  // --- resources ---
  if (doc.resources === undefined) {
    throw new InputError(`resources 缺少必填字段（必须是非空数组）`);
  }
  if (!Array.isArray(doc.resources)) {
    throw new InputError(`resources 必须是数组`);
  }
  if (doc.resources.length === 0) {
    throw new InputError(`resources 为空（至少要有一个资源）`);
  }
  const resourceIds = new Set();
  const resources = doc.resources.map((item, index) => {
    const at = `resources[${index}]`;
    if (!isObject(item)) throw new InputError(`${at} 必须是对象`);
    checkId(`${at}.id`, item.id, 'resources', resourceIds);
    if (!isFilledString(item.name)) {
      throw new InputError(`${at}.name 缺少必填字段（必须是非空字符串）`);
    }
    if (item.asset_refs === undefined) {
      throw new InputError(`${at}.asset_refs 缺少必填字段（必须是非空数组）`);
    }
    checkRefs(`${at}.asset_refs`, item.asset_refs, assetIds, 'assets');
    return {
      id: item.id,
      name: item.name,
      asset_refs: item.asset_refs.slice(),
    };
  });

  return {
    service: {
      name: doc.service.name,
      description: isFilledString(doc.service.description) ? doc.service.description : '',
    },
    assets,
    trustBoundaries,
    entryPoints,
    roles,
    resources,
  };
}

/**
 * 把功能用例集（cases.json v2）读成「只用于攻击面枚举与 id 避让」的辅助输入。
 *
 * ⚠️ 本 skill **不消费**它的用例（不复用、不改写），只用两样东西：
 *   ① 用例 id 集合 —— 产出的安全用例 id 必须避开它们；
 *   ② 步骤动作里出现的输入面 —— 作为攻击面枚举的补充线索（写进威胁的 rationale）。
 *
 * @param {*} doc 解析后的 JSON
 * @param {string} file 来源文件
 * @returns {{ids: Set<string>, actions: {id: string, action: string}[], count: number}}
 */
export function readFunctionalCases(doc, file) {
  if (!isObject(doc)) {
    throw new InputError(`功能用例集的根节点必须是 JSON 对象: ${file}`);
  }
  if (doc.cases === undefined) {
    throw new InputError(`功能用例集缺少必填字段 cases（数组）: ${file}`);
  }
  if (!Array.isArray(doc.cases)) {
    throw new InputError(`功能用例集的 cases 必须是数组: ${file}`);
  }
  const ids = new Set();
  const actions = [];
  doc.cases.forEach((item, index) => {
    const at = `cases[${index}]`;
    if (!isObject(item)) throw new InputError(`${at} 必须是对象`);
    if (!isFilledString(item.id)) {
      throw new InputError(`${at}.id 缺少必填字段（必须是非空字符串）`);
    }
    ids.add(item.id);
    const steps = Array.isArray(item.steps) ? item.steps : [];
    for (const [stepIndex, step] of steps.entries()) {
      if (isObject(step) && isFilledString(step.action)) {
        actions.push({ id: item.id, action: step.action, at: `${at}.steps[${stepIndex}]` });
      }
    }
  });
  return { ids, actions, count: doc.cases.length };
}
