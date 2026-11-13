// validate-defects.mjs —— 缺陷单与用例集的**结构层**校验（需求 F1.1 / F1.2）
//
// ⚠️ 两层划分（D72）：本模块只管**结构层**（字段缺了 / 类型错了 / 枚举越界了 /
//    id 格式错或重复）—— 违反即报错退出（退出码 1），**不得产出任何产物**。
//    「字段在但内容不足以派生」属**内容层**，不报错，由派生层判 unresolved。
//
// 纯 Node.js，只用 node: 内置模块。

import { InputError, isObject } from './io.mjs';

/** 缺陷 id 的格式（必填、文件内唯一）。 */
export const DEFECT_ID_PATTERN = /^BUG-\d{3,}$/;

/** severity 的枚举。 */
export const SEVERITIES = ['high', 'medium', 'low'];

/** status 的枚举。 */
export const STATUSES = ['open', 'fixed', 'wont_fix', 'not_reproducible'];

/** 必须是字符串的可选字段。 */
const STRING_FIELDS = ['cycle_id', 'run_id', 'evidence_path', 'description'];

/**
 * 校验缺陷单文档（结构层）。
 * @param {*} doc 缺陷单文档（JSON.parse 的结果）
 * @param {string} file 缺陷单文件路径（错误信息里用）
 * @returns {object[]} 通过校验的缺陷条目
 */
export function validateDefectsDocument(doc, file) {
  if (!isObject(doc)) {
    throw new InputError(
      `缺陷单的根节点必须是对象（不是数组或标量）: ${file}`,
    );
  }
  if (!Array.isArray(doc.defects)) {
    throw new InputError(
      `defects 必须是数组（缺陷单 ${file} 的 defects 字段类型非法）`,
    );
  }

  const seen = new Set();
  doc.defects.forEach((defect, index) => {
    const at = `defects[${index}]`;
    if (!isObject(defect)) throw new InputError(`${at} 必须是对象`);

    // --- id：必填、非空、格式合法、文件内唯一 ---
    if (!('id' in defect)) throw new InputError(`${at}.id 缺失（缺陷 id 必填）`);
    if (typeof defect.id !== 'string' || defect.id.trim() === '') {
      throw new InputError(`${at}.id 必须是非空字符串`);
    }
    if (!DEFECT_ID_PATTERN.test(defect.id)) {
      throw new InputError(
        `${at}.id 格式非法: ${defect.id}（必须匹配 ^BUG-\\d{3,}$）`,
      );
    }
    if (seen.has(defect.id)) {
      throw new InputError(
        `${at}.id 重复: ${defect.id}（缺陷 id 在同一份缺陷单里必须唯一）`,
      );
    }
    seen.add(defect.id);

    // --- title：必填、非空字符串 ---
    if (!('title' in defect)) throw new InputError(`${at}.title 缺失（缺陷标题必填）`);
    if (typeof defect.title !== 'string' || defect.title.trim() === '') {
      throw new InputError(`${at}.title 必须是非空字符串`);
    }

    // --- severity：必填、枚举 ---
    if (!('severity' in defect)) throw new InputError(`${at}.severity 缺失（必填）`);
    if (typeof defect.severity !== 'string' || !SEVERITIES.includes(defect.severity)) {
      throw new InputError(
        `${at}.severity 越界: ${JSON.stringify(defect.severity)}（允许值: ${SEVERITIES.join(' / ')}）`,
      );
    }

    // --- reproduction：若存在必须是对象（null / 字符串 / 数组都非法）---
    if ('reproduction' in defect && !isObject(defect.reproduction)) {
      throw new InputError(
        `${at}.reproduction 必须是对象（不能是 null / 字符串 / 数组）`,
      );
    }

    // --- status：若存在必须是枚举 ---
    if ('status' in defect) {
      if (typeof defect.status !== 'string' || !STATUSES.includes(defect.status)) {
        throw new InputError(
          `${at}.status 越界: ${JSON.stringify(defect.status)}（允许值: ${STATUSES.join(' / ')}）`,
        );
      }
    }

    // --- reproducible：若存在必须是布尔值 ---
    if ('reproducible' in defect && typeof defect.reproducible !== 'boolean') {
      throw new InputError(`${at}.reproducible 必须是布尔值`);
    }

    // --- case_refs：若存在必须是字符串数组（可为空数组）---
    if ('case_refs' in defect) {
      if (!Array.isArray(defect.case_refs)) {
        throw new InputError(`${at}.case_refs 必须是数组`);
      }
      defect.case_refs.forEach((ref, refIndex) => {
        if (typeof ref !== 'string') {
          throw new InputError(`${at}.case_refs[${refIndex}] 必须是字符串`);
        }
      });
    }

    // --- 其余可选字符串字段 ---
    for (const field of STRING_FIELDS) {
      if (field in defect && typeof defect[field] !== 'string') {
        throw new InputError(`${at}.${field} 必须是字符串`);
      }
    }

    // --- root_cause：若存在必须是字符串或 null ---
    if (
      'root_cause' in defect
      && defect.root_cause !== null
      && typeof defect.root_cause !== 'string'
    ) {
      throw new InputError(`${at}.root_cause 必须是字符串或 null`);
    }
  });

  return doc.defects;
}

/**
 * 校验已有用例集文档（结构层；只查本 skill 真正依赖的东西）。
 * @param {*} doc 用例集文档
 * @param {string} file 用例集文件路径
 * @returns {object[]} 用例条目
 */
export function validateCasesDocument(doc, file) {
  if (!isObject(doc)) {
    throw new InputError(`已有用例集的根节点必须是对象: ${file}`);
  }
  if (!Array.isArray(doc.cases)) {
    throw new InputError(`已有用例集缺 cases 数组: ${file}`);
  }
  const seen = new Set();
  doc.cases.forEach((caseObj, index) => {
    const at = `cases[${index}]`;
    if (!isObject(caseObj)) throw new InputError(`${at} 必须是对象`);
    if (typeof caseObj.id !== 'string' || caseObj.id.trim() === '') {
      throw new InputError(`${at}.id 必须是非空字符串`);
    }
    if (seen.has(caseObj.id)) {
      throw new InputError(`${at}.id 重复: ${caseObj.id}（用例 id 在同一份用例集里必须唯一）`);
    }
    seen.add(caseObj.id);
  });
  return doc.cases;
}

/**
 * 校验 R3 轮次契约（需求 F5 / D79 / D90）：**只读** cycle.json，不得改写。
 * @param {string} cycleDir R3 轮次目录
 * @param {object} cycle cycle.json 的内容
 * @param {string[]} defectIds 输入缺陷 id 集合
 */
export function validateCycleDocument(cycle, cycleFile, cycleDir, defectIds) {
  if (!isObject(cycle)) {
    throw new InputError(`轮次配置 cycle.json 的根节点必须是对象: ${cycleFile}`);
  }
  if (cycle.round !== 'R3') {
    throw new InputError(
      `轮次配置的 round=${JSON.stringify(cycle.round)}，R3 缺陷复现轮次必须是 "R3": ${cycleFile}`,
    );
  }
  if (cycle.round_type !== 'defect-verify') {
    throw new InputError(
      `轮次配置的 round_type=${JSON.stringify(cycle.round_type)}，必须是 "defect-verify": ${cycleFile}`,
    );
  }
  if (!isObject(cycle.trigger)) {
    throw new InputError(
      `轮次配置缺 trigger（必须是 {"type":"defect","ref":"<BUG-id>"}）: ${cycleFile}`,
    );
  }
  if (cycle.trigger.type !== 'defect') {
    throw new InputError(
      `轮次配置的 trigger.type=${JSON.stringify(cycle.trigger.type)}，必须是 "defect": ${cycleFile}`,
    );
  }
  const known = new Set(defectIds);
  if (typeof cycle.trigger.ref !== 'string' || !known.has(cycle.trigger.ref)) {
    throw new InputError(
      `轮次配置的 trigger.ref=${JSON.stringify(cycle.trigger.ref)} 不在输入缺陷 id 集合里` +
        `（轮次与缺陷单对不上）: ${cycleFile}`,
    );
  }
  const dirName = cycleDir.split('/').filter(Boolean).pop();
  if (typeof cycle.cycle_id === 'string' && cycle.cycle_id !== '' && cycle.cycle_id !== dirName) {
    throw new InputError(
      `轮次目录名 ${dirName} 与 cycle.json 的 cycle_id=${cycle.cycle_id} 不一致` +
        '（目录契约：轮次目录名 == cycle_id）: ' + cycleFile,
    );
  }
}
