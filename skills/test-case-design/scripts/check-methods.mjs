#!/usr/bin/env node
// check-methods.mjs — 测试方法使用与覆盖维度核验器（REQ-005）
//
// 用法:
//   node scripts/check-methods.mjs <cases.json> [--json]
//   node scripts/check-methods.mjs --methods <路径> --dimensions <路径>
//   node scripts/check-methods.mjs --methods <路径> --selftest
//   node scripts/check-methods.mjs --methods <路径> --doc <路径> --check-doc
//
// 退出码: 0 = 无 ERROR（可能有 WARN / 无法判定）; 1 = 有 ERROR; 2 = 用法错误
//
// 三类结论（互斥，同一条 (需求条目, 方法) 只落一类）:
//   ERROR      —— 产出确实缺失，是可机械判定的事实 → 退出码 1
//   WARN       —— 适用性存疑，是主观判断           → 退出码 0，但必须列出
//   无法判定   —— 证据不足（如 expected 是人读字符串）→ 单独一类，既不算通过也不算失败
//
// 零依赖: 只用 node: 内置模块，不发起网络请求，不执行用例文本中的任何内容。

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';
import process from 'node:process';

// 严重级别常量 —— 报告与退出码都从这里取，改一处即可
const SEVERITY_ERROR = 'ERROR';
const SEVERITY_WARNING = 'WARN';

// 方法/维度库与说明文档的默认位置（相对脚本自身，保证与调用目录无关）
const SKILL_ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const DEFAULT_METHODS_PATH = join(SKILL_ROOT, 'references', 'methods.json');
const DEFAULT_DIMENSIONS_PATH = join(SKILL_ROOT, 'references', 'dimensions.json');

// 谓词种类（D3：只支持有限几种，不做通用表达式）
const PREDICATE_KINDS = [
  'min_cases_by_dimension',
  'distinct_expected',
  'has_dimension',
  'min_assertions_per_case',
  'min_cases_total',
  'dimension_pair_present',
];

// ------------------------------------------------------------------------ 基础工具

function isObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isFilledString(value) {
  return typeof value === 'string' && value.trim() !== '';
}

/**
 * 稳定的字符串化：用于比较“期望取值”是否相同。
 * 对象按键排序后再序列化，避免键序不同被当成不同取值。
 */
function stableStringify(value) {
  if (Array.isArray(value)) {
    return `[${value.map(stableStringify).join(',')}]`;
  }
  if (isObject(value)) {
    const keys = Object.keys(value).sort();
    return `{${keys.map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value === undefined ? null : value);
}

/** 信号命中：需求文本里是否出现某个适用信号（字面子串匹配，大小写不敏感）。 */
function matchSignals(signals, text) {
  const matched = [];
  if (!Array.isArray(signals)) return matched;
  const haystack = text.toLowerCase();
  for (const signal of signals) {
    if (!isFilledString(signal)) continue;
    if (haystack.includes(signal.toLowerCase())) matched.push(signal);
  }
  return matched;
}

// ------------------------------------------------------------------------ 结论收集

const findings = {
  errors: [],
  warnings: [],
  undecidable: [],
  verdicts: [],
};

function addError(type, requirement, method, message) {
  findings.errors.push({
    type,
    requirement: requirement === undefined ? null : requirement,
    method: method === undefined ? null : method,
    message,
    severity: SEVERITY_ERROR,
  });
}

function addWarning(type, requirement, method, message) {
  findings.warnings.push({
    type,
    requirement: requirement === undefined ? null : requirement,
    method: method === undefined ? null : method,
    message,
    severity: SEVERITY_WARNING,
  });
}

function addUndecidable(requirement, method, reason) {
  findings.undecidable.push({ requirement, method, reason });
}

function addVerdict(requirement, method, status, message) {
  findings.verdicts.push({ requirement, method, status, message });
}

// ------------------------------------------------------------------------ 参数解析

function parseArgs(argv) {
  const opts = {
    file: null,
    json: false,
    methods: null,
    dimensions: null,
    doc: null,
    selftest: false,
    checkDoc: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--json') {
      opts.json = true;
    } else if (arg === '--selftest') {
      opts.selftest = true;
    } else if (arg === '--check-doc') {
      opts.checkDoc = true;
    } else if (arg === '--methods' || arg === '--dimensions' || arg === '--doc') {
      const value = argv[i + 1];
      if (value === undefined || value.startsWith('--')) {
        return { error: `参数 ${arg} 缺少取值` };
      }
      i += 1;
      if (arg === '--methods') opts.methods = value;
      else if (arg === '--dimensions') opts.dimensions = value;
      else opts.doc = value;
    } else if (arg.startsWith('--')) {
      return { error: `未知参数: ${arg}` };
    } else if (opts.file === null) {
      opts.file = arg;
    } else {
      return { error: `多余的位置参数: ${arg}` };
    }
  }

  if (opts.checkDoc && !opts.doc) {
    return { error: '--check-doc 需要配合 --doc <说明文档路径>' };
  }

  return { opts };
}

// ------------------------------------------------------------------------ 库加载与自检

function readJsonFile(file, label) {
  let raw;
  try {
    raw = readFileSync(file, 'utf8');
  } catch (err) {
    return { error: `无法读取${label}: ${file}（${err.message}）` };
  }
  try {
    return { value: JSON.parse(raw) };
  } catch (err) {
    return { error: `${label} JSON 语法错误: ${file} 解析失败 — ${err.message}` };
  }
}

/** 读取一个纯文本文件（说明文档不是 JSON）。 */
function readTextFile(file, label) {
  try {
    return { value: readFileSync(file, 'utf8') };
  } catch (err) {
    return { error: `无法读取${label}: ${file}（${err.message}）` };
  }
}

/**
 * 校验一个谓词定义是否合法。
 * 谓词是数据，合法性也必须能被机械校验 —— 否则“判定依据”本身不可信。
 */
function validatePredicate(predicate, at) {
  const issues = [];
  if (!isObject(predicate)) {
    issues.push(`${at} 必须是对象`);
    return issues;
  }
  if (!PREDICATE_KINDS.includes(predicate.kind)) {
    issues.push(`${at}.kind 取值非法: "${predicate.kind}"，允许值: ${PREDICATE_KINDS.join(' / ')}`);
    return issues;
  }
  const kind = predicate.kind;
  const needsDimension = ['min_cases_by_dimension', 'distinct_expected', 'has_dimension'];
  if (needsDimension.includes(kind) && !isFilledString(predicate.dimension)) {
    issues.push(`${at}.dimension 必须是非空字符串`);
  }
  if (kind === 'dimension_pair_present') {
    if (!Array.isArray(predicate.dimensions) || predicate.dimensions.length < 2) {
      issues.push(`${at}.dimensions 必须是至少含 2 个维度 id 的数组`);
    } else if (!predicate.dimensions.every((id) => isFilledString(id))) {
      issues.push(`${at}.dimensions 的元素必须是非空字符串`);
    }
  }
  const needsMin = ['min_cases_by_dimension', 'distinct_expected', 'min_assertions_per_case', 'min_cases_total'];
  if (needsMin.includes(kind)) {
    if (typeof predicate.min !== 'number' || !Number.isInteger(predicate.min) || predicate.min < 0) {
      issues.push(`${at}.min 必须是非负整数`);
    }
  }
  if (predicate.distinct_expected !== undefined && typeof predicate.distinct_expected !== 'boolean') {
    issues.push(`${at}.distinct_expected 必须是布尔值`);
  }
  if (predicate.distinct_min !== undefined) {
    if (typeof predicate.distinct_min !== 'number' || !Number.isInteger(predicate.distinct_min) || predicate.distinct_min < 1) {
      issues.push(`${at}.distinct_min 必须是 ≥ 1 的整数`);
    }
  }
  return issues;
}

/** 校验方法库结构。返回问题清单（空 = 合法）。 */
function validateMethodsLibrary(library) {
  const issues = [];
  if (!isObject(library)) {
    issues.push('方法库根节点必须是对象');
    return issues;
  }
  if (!Array.isArray(library.methods) || library.methods.length === 0) {
    issues.push('方法库缺少非空的 methods 数组');
    return issues;
  }
  const seen = new Set();
  library.methods.forEach((method, index) => {
    const at = `methods[${index}]`;
    if (!isObject(method)) {
      issues.push(`${at} 必须是对象`);
      return;
    }
    if (!isFilledString(method.id)) {
      issues.push(`${at}.id 必须是非空字符串`);
    } else if (seen.has(method.id)) {
      issues.push(`${at}.id 重复的方法编号: "${method.id}"`);
    } else {
      seen.add(method.id);
    }
    if (!isFilledString(method.name)) {
      issues.push(`${at}.name 必须是非空字符串`);
    }
    if (!Array.isArray(method.applies_when) || method.applies_when.length === 0) {
      issues.push(`${at}.applies_when 必须是非空数组`);
    } else if (!method.applies_when.every(isFilledString)) {
      issues.push(`${at}.applies_when 的元素必须是非空字符串`);
    }
    if (!Array.isArray(method.not_applies_when)) {
      issues.push(`${at}.not_applies_when 必须是数组`);
    }
    if (!Array.isArray(method.required_outputs) || method.required_outputs.length === 0) {
      issues.push(`${at}.required_outputs 必须是非空数组（方法必须有可机械核验的产出）`);
    } else {
      method.required_outputs.forEach((predicate, pIndex) => {
        for (const issue of validatePredicate(predicate, `${at}.required_outputs[${pIndex}]`)) {
          issues.push(issue);
        }
      });
    }
    if (!Array.isArray(method.typical_dimensions)) {
      issues.push(`${at}.typical_dimensions 必须是数组`);
    }
    if (!Array.isArray(method.anti_patterns)) {
      issues.push(`${at}.anti_patterns 必须是数组`);
    }
  });
  return issues;
}

/** 校验维度库结构。返回问题清单（空 = 合法）。 */
function validateDimensionsLibrary(library) {
  const issues = [];
  if (!isObject(library)) {
    issues.push('维度库根节点必须是对象');
    return issues;
  }
  if (!Array.isArray(library.dimensions) || library.dimensions.length === 0) {
    issues.push('维度库缺少非空的 dimensions 数组');
    return issues;
  }
  const seen = new Set();
  library.dimensions.forEach((dimension, index) => {
    const at = `dimensions[${index}]`;
    if (!isObject(dimension)) {
      issues.push(`${at} 必须是对象`);
      return;
    }
    if (!isFilledString(dimension.id)) {
      issues.push(`${at}.id 必须是非空字符串`);
    } else if (seen.has(dimension.id)) {
      issues.push(`${at}.id 重复的维度 id: "${dimension.id}"`);
    } else {
      seen.add(dimension.id);
    }
    if (!isFilledString(dimension.name)) {
      issues.push(`${at}.name 必须是非空字符串`);
    }
    if (!Array.isArray(dimension.applies_when)) {
      issues.push(`${at}.applies_when 必须是数组`);
    }
    if (dimension.always_applies !== undefined && typeof dimension.always_applies !== 'boolean') {
      issues.push(`${at}.always_applies 必须是布尔值`);
    }
    if (dimension.skip_reason_required !== true) {
      issues.push(`${at}.skip_reason_required 必须是 true（跳过该维度必须写 reason）`);
    }
  });
  return issues;
}

// ------------------------------------------------------------------------ 说明文档一致性

/**
 * 把说明文档切成以 “### ” 开头的小节，用于逐方法比对。
 */
function splitDocSections(doc) {
  const sections = [];
  const lines = doc.split(/\r?\n/);
  let current = { heading: '', lines: [] };
  for (const line of lines) {
    if (/^#{2,4}\s/.test(line)) {
      sections.push(current);
      current = { heading: line, lines: [] };
    } else {
      current.lines.push(line);
    }
  }
  sections.push(current);
  return sections.map((section) => ({ heading: section.heading, text: `${section.heading}\n${section.lines.join('\n')}` }));
}

/**
 * 比对方法库与说明文档：方法 id / 名称 / 适用信号必须一致。
 * 方法库为准（需求 D4）；不一致时点名不一致的方法与字段。
 */
function compareDocWithLibrary(library, doc) {
  const issues = [];
  const sections = splitDocSections(doc);

  for (const method of library.methods) {
    const section = sections.find((item) => item.heading.includes(method.id));
    if (!section) {
      issues.push(`说明文档缺少方法 ${method.id}（${method.name}）的条目`);
      continue;
    }
    if (!section.text.includes(method.name)) {
      issues.push(`说明文档中方法 ${method.id} 的名称与方法库不一致：方法库为 "${method.name}"`);
    }
    for (const signal of method.applies_when) {
      if (!section.text.includes(signal)) {
        issues.push(`说明文档中方法 ${method.id} 缺少适用信号 "${signal}"（与 references/methods.json 不一致）`);
      }
    }
    for (const signal of method.not_applies_when || []) {
      if (!section.text.includes(signal)) {
        issues.push(`说明文档中方法 ${method.id} 缺少不适用信号 "${signal}"（与 references/methods.json 不一致）`);
      }
    }
  }

  const knownIds = new Set(library.methods.map((method) => method.id));
  for (const section of sections) {
    const found = section.heading.match(/M\d+\.\d+/g) || [];
    for (const id of found) {
      if (!knownIds.has(id)) {
        issues.push(`说明文档提到方法库中不存在的方法编号 "${id}"（以 references/methods.json 为准）`);
      }
    }
  }

  return issues;
}

// ------------------------------------------------------------------------ 谓词求值

/**
 * 取出一条用例的断言情况。
 *
 * comparable=false 表示证据不足（steps[].expected 是人读字符串），
 * 此时任何基于断言的判定都必须报“无法判定”，不得当成通过，也不得当成失败。
 */
function inspectCase(testCase) {
  const result = { assertions: 0, values: [], humanReadable: false, hasValueless: false };
  const steps = Array.isArray(testCase.steps) ? testCase.steps : [];
  for (const step of steps) {
    if (!isObject(step)) {
      result.humanReadable = true;
      continue;
    }
    const expected = step.expected;
    if (isObject(expected)) {
      result.assertions += 1;
      if (expected.expected === undefined) {
        result.hasValueless = true;
      } else {
        result.values.push(expected.expected);
      }
    } else {
      result.humanReadable = true;
    }
  }
  return result;
}

/** 统计一组用例的期望取值区分度。 */
function checkDistinctExpected(group, min) {
  const values = [];
  for (const testCase of group) {
    const info = inspectCase(testCase);
    if (info.humanReadable) {
      return {
        state: 'undecidable',
        reason: `${testCase.id || '用例'} 的 steps[].expected 是人读字符串，无法机械比较期望取值的区分度`,
      };
    }
    values.push(...info.values);
  }
  const distinct = new Set(values.map(stableStringify)).size;
  if (distinct < min) {
    return {
      state: 'missing',
      message: `期望取值只有 ${distinct} 种（要求 ≥ ${min}），不具区分度`,
    };
  }
  return { state: 'ok' };
}

/**
 * 对一个需求条目核验某个方法的全部 required_outputs。
 * 返回 { state: 'ok' | 'missing' | 'undecidable', ... }。
 *
 * 判定必须保守：证据不足时只报 undecidable，绝不悄悄当通过。
 */
function evaluateRequiredOutputs(method, cases) {
  const missing = [];
  let undecidableReason = null;

  for (const predicate of method.required_outputs) {
    const kind = predicate.kind;

    if (kind === 'min_cases_by_dimension') {
      const group = cases.filter((item) => item.dimension === predicate.dimension);
      if (group.length < predicate.min) {
        missing.push(`${predicate.dimension} 维度用例数 ${group.length} < ${predicate.min}`);
        continue;
      }
      if (predicate.distinct_expected) {
        const distinct = checkDistinctExpected(group, predicate.distinct_min || 2);
        if (distinct.state === 'undecidable') {
          undecidableReason = undecidableReason || distinct.reason;
        } else if (distinct.state === 'missing') {
          missing.push(`${predicate.dimension} 维度下 ${distinct.message}`);
        }
      }
    } else if (kind === 'distinct_expected') {
      const group = cases.filter((item) => item.dimension === predicate.dimension);
      if (group.length === 0) {
        missing.push(`${predicate.dimension} 维度没有任何用例，无法比较期望取值的区分度`);
        continue;
      }
      const distinct = checkDistinctExpected(group, predicate.min);
      if (distinct.state === 'undecidable') {
        undecidableReason = undecidableReason || distinct.reason;
      } else if (distinct.state === 'missing') {
        missing.push(`${predicate.dimension} 维度下 ${distinct.message}`);
      }
    } else if (kind === 'has_dimension') {
      const group = cases.filter((item) => item.dimension === predicate.dimension);
      if (group.length === 0) {
        missing.push(`没有 ${predicate.dimension} 维度的用例`);
      }
    } else if (kind === 'min_assertions_per_case') {
      for (const testCase of cases) {
        const info = inspectCase(testCase);
        if (info.humanReadable) {
          undecidableReason =
            undecidableReason ||
            `${testCase.id || '用例'} 的 steps[].expected 是人读字符串，无法机械统计断言数`;
          continue;
        }
        if (info.assertions < predicate.min) {
          missing.push(`${testCase.id || '用例'} 只有 ${info.assertions} 条断言（要求 ≥ ${predicate.min}）`);
        }
      }
    } else if (kind === 'min_cases_total') {
      if (cases.length < predicate.min) {
        missing.push(`该需求条目下用例数 ${cases.length} < ${predicate.min}`);
      }
    } else if (kind === 'dimension_pair_present') {
      const [first, second] = predicate.dimensions;
      const hasFirst = cases.some((item) => item.dimension === first);
      const hasSecond = cases.some((item) => item.dimension === second);
      if (!hasFirst || !hasSecond) {
        missing.push(`没有同时覆盖 ${first} 与 ${second} 两个维度的用例`);
      }
    }
  }

  if (missing.length > 0) {
    return { state: 'missing', detail: missing };
  }
  if (undecidableReason) {
    return { state: 'undecidable', reason: undecidableReason };
  }
  return { state: 'ok' };
}

// ------------------------------------------------------------------------ 用例集核验

function requirementText(requirement) {
  const parts = [];
  if (isFilledString(requirement.title)) parts.push(requirement.title);
  if (isFilledString(requirement.source_ref)) parts.push(requirement.source_ref);
  return parts.join('\n');
}

function casesOfRequirement(cases, requirementId) {
  return cases.filter(
    (item) =>
      isObject(item) &&
      Array.isArray(item.requirement_refs) &&
      item.requirement_refs.includes(requirementId) &&
      item.status !== 'deprecated',
  );
}

/**
 * 核验一份用例集。
 * 只读 cases.json 现有字段，不引入任何新字段。
 */
function checkCases(doc, methodsLibrary, dimensionsLibrary) {
  const requirements = Array.isArray(doc.requirements) ? doc.requirements : [];
  const cases = Array.isArray(doc.cases) ? doc.cases : [];
  const matrix = Array.isArray(doc.coverage_matrix) ? doc.coverage_matrix : [];

  const matrixByRequirement = new Map();
  for (const entry of matrix) {
    if (isObject(entry) && isFilledString(entry.requirement)) {
      matrixByRequirement.set(entry.requirement, entry);
    }
  }

  const methodById = new Map();
  for (const method of methodsLibrary.methods) {
    methodById.set(method.id, method);
  }
  const dimensionById = new Map();
  for (const dimension of dimensionsLibrary.dimensions) {
    dimensionById.set(dimension.id, dimension);
  }

  for (const requirement of requirements) {
    if (!isObject(requirement) || !isFilledString(requirement.id)) continue;
    if (requirement.testable === false) continue;

    const requirementId = requirement.id;
    const text = requirementText(requirement);
    const entry = matrixByRequirement.get(requirementId);
    const applied = entry && Array.isArray(entry.methods_applied) ? entry.methods_applied : [];
    const skipped = entry && Array.isArray(entry.skipped) ? entry.skipped : [];
    const relatedCases = casesOfRequirement(cases, requirementId);

    if (!entry) {
      addWarning(
        'COVERAGE_MATRIX_MISSING',
        requirementId,
        null,
        `需求条目 ${requirementId} 没有出现在 coverage_matrix 中，无法核验其方法使用`,
      );
    }

    // --- 跳过声明：方法跳过与维度跳过都必须写 reason ---
    const skippedMethods = new Set();
    const skippedDimensions = new Set();
    for (const skip of skipped) {
      if (!isObject(skip)) {
        addError('SKIP_REASON_MISSING', requirementId, null, `需求条目 ${requirementId} 的 skipped 项不是对象`);
        continue;
      }
      const target = isFilledString(skip.method)
        ? skip.method
        : isFilledString(skip.dimension)
          ? skip.dimension
          : null;
      if (target === null) {
        addError(
          'SKIP_REASON_MISSING',
          requirementId,
          null,
          `需求条目 ${requirementId} 的 skipped 项既没有 method 也没有 dimension，无法判断跳过了什么`,
        );
        continue;
      }
      if (isFilledString(skip.method)) skippedMethods.add(skip.method);
      if (isFilledString(skip.dimension)) skippedDimensions.add(skip.dimension);
      if (!isFilledString(skip.reason)) {
        addError(
          'SKIP_REASON_MISSING',
          requirementId,
          target,
          `需求条目 ${requirementId} 跳过了 ${target}，但没有写明 reason（跳过必须留痕，不能空跳过）`,
        );
      }
    }

    // --- 方法使用核验 ---
    for (const method of methodsLibrary.methods) {
      const declared = applied.includes(method.id);
      const isSkipped = skippedMethods.has(method.id);
      const applyHits = matchSignals(method.applies_when, text);
      const notApplyHits = matchSignals(method.not_applies_when, text);
      const applicable = applyHits.length > 0 && notApplyHits.length === 0;

      if (declared) {
        const evaluation = evaluateRequiredOutputs(method, relatedCases);
        if (evaluation.state === 'missing') {
          const detail = evaluation.detail.join('；');
          addError(
            'METHOD_OUTPUT_MISSING',
            requirementId,
            method.id,
            `需求条目 ${requirementId} 声明使用 ${method.id}（${method.name}），但缺少必需产出：${detail}`,
          );
          addVerdict(
            requirementId,
            method.id,
            'missing_output',
            `声明使用 ${method.id}（${method.name}）但缺少必需产出：${detail}`,
          );
        } else if (evaluation.state === 'undecidable') {
          addUndecidable(
            requirementId,
            method.id,
            `需求条目 ${requirementId} 的 ${method.id}（${method.name}）：${evaluation.reason}`,
          );
          addVerdict(
            requirementId,
            method.id,
            'undecidable',
            `证据不足，无法判定 ${method.id}（${method.name}）的必需产出是否齐备`,
          );
        } else if (!applicable) {
          const reason = notApplyHits.length > 0 ? `命中不适用信号（${notApplyHits.join('、')}）` : '没有命中任何适用信号';
          addWarning(
            'METHOD_SUSPECT',
            requirementId,
            method.id,
            `需求条目 ${requirementId} 声明使用 ${method.id}（${method.name}），但该条目${reason}，方法适用性存疑`,
          );
          addVerdict(requirementId, method.id, 'suspect', `该需求条目${reason}，方法适用性存疑`);
        } else {
          addVerdict(requirementId, method.id, 'satisfied', `必需产出齐备（${method.id} ${method.name}）`);
        }
        continue;
      }

      if (isSkipped) {
        addVerdict(requirementId, method.id, 'not_applicable', `已显式跳过 ${method.id}（${method.name}）`);
        continue;
      }

      if (applicable) {
        addWarning(
          'METHOD_MISSING',
          requirementId,
          method.id,
          `需求条目 ${requirementId} 命中 ${method.id}（${method.name}）的适用信号（${applyHits.join('、')}），但 methods_applied 里没有声明该方法`,
        );
        addVerdict(requirementId, method.id, 'missing_output', `命中适用信号但未声明 ${method.id}（${method.name}）`);
        continue;
      }

      addVerdict(requirementId, method.id, 'not_applicable', `该需求条目未命中 ${method.id}（${method.name}）的适用信号`);
    }

    // --- 声明了但方法库里没有登记的编号：判不了 ---
    for (const methodId of applied) {
      if (methodById.has(methodId)) continue;
      if (skippedMethods.has(methodId)) continue;
      addUndecidable(
        requirementId,
        methodId,
        `需求条目 ${requirementId} 声明使用 ${methodId}，但该编号未在方法库中登记，无法核验其必需产出`,
      );
      addVerdict(requirementId, methodId, 'undecidable', `方法编号 ${methodId} 未在方法库中登记，无法核验`);
    }

    // --- 覆盖维度适用性 ---
    for (const dimension of dimensionsLibrary.dimensions) {
      const alwaysApplies = dimension.always_applies === true;
      const hits = matchSignals(dimension.applies_when, text);
      const applicable = alwaysApplies || hits.length > 0;
      if (!applicable) continue;
      if (skippedDimensions.has(dimension.id)) continue;
      const covered = relatedCases.some((item) => item.dimension === dimension.id);
      if (covered) continue;
      const signalText = alwaysApplies ? '基础维度（始终适用）' : `适用信号（${hits.join('、')}）`;
      addWarning(
        'DIMENSION_MISSING',
        requirementId,
        dimension.id,
        `需求条目 ${requirementId} 命中维度 ${dimension.id}（${dimension.name}）的${signalText}，但该条目下没有一条 ${dimension.id} 维度的用例`,
      );
    }
  }

  // --- 用例级方法编号未在方法库登记 ---
  // 这里刻意不带 requirement：结论落在“方法编号”上，不落在某条需求条目上，
  // 避免与 (需求条目, 方法) 组合的其它结论混在一起。
  for (const testCase of cases) {
    if (!isObject(testCase) || !Array.isArray(testCase.method)) continue;
    for (const methodId of testCase.method) {
      if (!isFilledString(methodId) || methodById.has(methodId)) continue;
      const refs = Array.isArray(testCase.requirement_refs) ? testCase.requirement_refs.join('、') : '未标注';
      addWarning(
        'UNKNOWN_CASE_METHOD',
        null,
        methodId,
        `用例 ${testCase.id || '未标注'} 声明了方法 ${methodId}，但该编号未在方法库中登记（关联需求条目: ${refs}）`,
      );
    }
  }
}

// ------------------------------------------------------------------------ 输出

function publicFinding(finding) {
  return {
    type: finding.type,
    requirement: finding.requirement,
    method: finding.method,
    message: finding.message,
  };
}

function buildJsonOutput(exitCode) {
  return {
    ok: findings.errors.length === 0,
    command: 'check-methods',
    exit_code: exitCode,
    summary: {
      errors: findings.errors.length,
      warnings: findings.warnings.length,
      undecidable: findings.undecidable.length,
    },
    errors: findings.errors.map(publicFinding),
    warnings: findings.warnings.map(publicFinding),
    undecidable: findings.undecidable.map((item) => ({
      requirement: item.requirement,
      method: item.method,
      reason: item.reason,
    })),
    verdicts: findings.verdicts.map((verdict) => ({
      requirement: verdict.requirement,
      method: verdict.method,
      status: verdict.status,
      message: verdict.message,
    })),
  };
}

function writeLine(text, options) {
  // --json 模式下 stdout 只能有 JSON：人读内容一律走 stderr
  const stream = options && options.json ? process.stderr : process.stdout;
  stream.write(`${text}\n`);
}

function printHumanReport(context) {
  writeLine(`测试方法核验 —— ${context.title}`, { json: context.json });
  if (context.subtitle) writeLine(context.subtitle, { json: context.json });
  writeLine('', { json: context.json });
  writeLine(
    `结论: ${findings.errors.length} 个 ${SEVERITY_ERROR} / ${findings.warnings.length} 个 ${SEVERITY_WARNING} / ${findings.undecidable.length} 个无法判定`,
    { json: context.json },
  );

  if (findings.errors.length > 0) {
    writeLine('', { json: context.json });
    writeLine(`${SEVERITY_ERROR} 明细（产出确实缺失，必须修）:`, { json: context.json });
    for (const finding of findings.errors) {
      writeLine(`  [${finding.severity}] ${finding.type}: ${finding.message}`, { json: context.json });
    }
  }

  if (findings.warnings.length > 0) {
    writeLine('', { json: context.json });
    writeLine(`${SEVERITY_WARNING} 明细（适用性存疑，必须在报告里说明，不得静默忽略）:`, { json: context.json });
    for (const finding of findings.warnings) {
      writeLine(`  [${finding.severity}] ${finding.type}: ${finding.message}`, { json: context.json });
    }
  }

  if (findings.undecidable.length > 0) {
    writeLine('', { json: context.json });
    writeLine('无法判定明细（证据不足，既不算通过也不算失败）:', { json: context.json });
    for (const item of findings.undecidable) {
      writeLine(`  ${item.requirement} / ${item.method}: ${item.reason}`, { json: context.json });
    }
  }

  if (findings.verdicts.length > 0) {
    writeLine('', { json: context.json });
    writeLine('判定明细（需求条目 × 方法）:', { json: context.json });
    for (const verdict of findings.verdicts) {
      writeLine(`  ${verdict.requirement} / ${verdict.method}  ${verdict.status}  ${verdict.message}`, {
        json: context.json,
      });
    }
  }
}

// ------------------------------------------------------------------------ 主流程

function main() {
  const argv = process.argv.slice(2);
  const parsed = parseArgs(argv);
  const jsonMode = argv.includes('--json');

  if (parsed.error) {
    const exitCode = 2;
    if (jsonMode) {
      addError('USAGE', null, null, `用法错误: ${parsed.error}`);
      process.stdout.write(`${JSON.stringify(buildJsonOutput(exitCode), null, 2)}\n`);
    } else {
      process.stderr.write(`用法错误: ${parsed.error}\n`);
      process.stderr.write(
        '用法: node scripts/check-methods.mjs <cases.json> [--json]\n' +
          '      node scripts/check-methods.mjs --methods <路径> --dimensions <路径>\n' +
          '      node scripts/check-methods.mjs --methods <路径> --selftest\n' +
          '      node scripts/check-methods.mjs --methods <路径> --doc <路径> --check-doc\n',
      );
    }
    process.exit(exitCode);
  }

  const opts = parsed.opts;
  const methodsPath = resolve(opts.methods || DEFAULT_METHODS_PATH);
  const dimensionsPath = resolve(opts.dimensions || DEFAULT_DIMENSIONS_PATH);

  const methodsRead = readJsonFile(methodsPath, '方法库');
  if (methodsRead.error) {
    addError('METHOD_LIBRARY_INVALID', null, null, methodsRead.error);
    return finish(jsonMode, { title: '方法库读取失败' });
  }
  const dimensionsRead = readJsonFile(dimensionsPath, '维度库');
  if (dimensionsRead.error) {
    addError('DIMENSION_LIBRARY_INVALID', null, null, dimensionsRead.error);
    return finish(jsonMode, { title: '维度库读取失败' });
  }

  const methodsLibrary = methodsRead.value;
  const dimensionsLibrary = dimensionsRead.value;

  const libraryIssues = [
    ...validateMethodsLibrary(methodsLibrary).map((issue) => ({ kind: '方法库', issue })),
    ...validateDimensionsLibrary(dimensionsLibrary).map((issue) => ({ kind: '维度库', issue })),
  ];
  if (libraryIssues.length > 0) {
    for (const item of libraryIssues) {
      addError('LIBRARY_INVALID', null, null, `${item.kind}结构非法: ${item.issue}`);
    }
    return finish(jsonMode, { title: '方法库/维度库自检失败' });
  }

  // --- 自检模式：只校验两个库本身 ---
  if (opts.selftest) {
    return finish(jsonMode, {
      title: '方法库/维度库自检',
      subtitle: `方法库: ${methodsPath}\n维度库: ${dimensionsPath}`,
    });
  }

  // --- 说明文档一致性模式 ---
  if (opts.checkDoc) {
    const docRead = readTextFile(resolve(opts.doc), '说明文档');
    if (docRead.error) {
      addError('DOC_INVALID', null, null, docRead.error);
      return finish(jsonMode, { title: '说明文档读取失败' });
    }
    const issues = compareDocWithLibrary(methodsLibrary, docRead.value);
    for (const issue of issues) {
      addError('DOC_MISMATCH', null, null, issue);
    }
    return finish(jsonMode, { title: '方法库与说明文档一致性检查' });
  }

  // --- 没有给用例集：只做库自检（换库用的快速入口） ---
  if (!opts.file) {
    return finish(jsonMode, {
      title: '方法库/维度库自检',
      subtitle: `方法库: ${methodsPath}\n维度库: ${dimensionsPath}`,
    });
  }

  const casesRead = readJsonFile(resolve(opts.file), '用例集');
  if (casesRead.error) {
    addError('CASES_INVALID', null, null, casesRead.error);
    return finish(jsonMode, { title: '用例集读取失败' });
  }

  checkCases(casesRead.value, methodsLibrary, dimensionsLibrary);

  return finish(jsonMode, {
    title: `用例集 ${opts.file}`,
    subtitle: `方法库: ${methodsPath}\n维度库: ${dimensionsPath}`,
  });
}

function finish(jsonMode, context) {
  const exitCode = findings.errors.length > 0 ? 1 : 0;
  if (jsonMode) {
    process.stdout.write(`${JSON.stringify(buildJsonOutput(exitCode), null, 2)}\n`);
  } else {
    printHumanReport({ ...context, json: jsonMode });
  }
  process.exit(exitCode);
}

main();
