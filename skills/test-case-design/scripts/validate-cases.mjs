#!/usr/bin/env node
// validate-cases.mjs — 测试用例集结构校验器（schema v2）
//
// 用法: node scripts/validate-cases.mjs <cases.json>
//       node scripts/validate-cases.mjs --init     （输出字段齐备的 v2 骨架到 stdout）
// 退出码: 0 = 校验通过, 1 = 校验失败, 2 = 调用方式错误
//
// 纯 Node.js 实现，只依赖 node: 内置模块。
// 只读取并解析 JSON 文件：不发起任何网络请求，也不执行需求文本或用例文本中的任何内容。
//
// 向后兼容规则：顶层未声明 "schema_version": 2 时按 v1 宽松规则处理——
//   open_questions / coverage_matrix / cases[].method / cases[].status 缺失只报 WARN；
//   显式声明 "schema_version": 2 时同样情形一律升级为 ERROR（声明了 v2 就要守 v2 的规矩）。
//   注意：字段“存在但内容非法”在两种模式下都是 ERROR，宽松的只是“缺字段”这一件事。

import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import process from 'node:process';

// 覆盖维度枚举，与 references/coverage-dimensions.md 的清单保持一致
const DIMENSIONS = [
  'functional',
  'boundary',
  'exception',
  'permission',
  'data',
  'concurrency',
  'performance',
  'compatibility',
];

const PRIORITIES = ['P0', 'P1', 'P2', 'P3'];

const CASE_ID_PATTERN = /^TC-\d{3}$/;
const QUESTION_ID_PATTERN = /^Q\d+$/;
// 方法编号格式，如 M1.1 / M1.2。本阶段只校验格式，不校验方法库中是否真的存在该编号
const METHOD_PATTERN = /^M\d+\.\d+$/;
// 维度跳过前缀（D11）：coverage_matrix[].skipped[].method 允许写成 "dimension:<维度名>"。
// 向后兼容：写成方法编号的旧写法行为完全不变（方法编号格式检查的结果一字不改）。
// 注意：这只放宽 skipped[] 这一处 —— cases[].method[] 与 coverage_matrix[].methods_applied[]
// 仍然只接受方法编号（它们记的是"用了哪些方法"，不是"跳过了什么"）。
const DIMENSION_SKIP_PREFIX = 'dimension:';

// 用例生命周期状态枚举
const CASE_STATUSES = ['active', 'deprecated', 'modified', 'blocked'];
// 未决问题严重级别
const QUESTION_SEVERITIES = ['blocking', 'non-blocking'];
// 未决问题的覆盖方式
const QUESTION_COVERAGES = ['cases', 'deferred'];

// --- 结构化断言对象（REQ-002.5b 的断言载体）---
//
// steps[].expected 有两种形态：
//   1) 普通字符串（人读的预期结果）—— REQ-002A 原有形态，行为完全不变
//   2) 断言对象（机械可判定的规则）—— { path, op, expected }
//
// 断言对象里的 path / op / expected 必须合法；不合法即 ERROR。
const ASSERT_OPS = [
  'equals',
  'not_equals',
  'contains',
  'not_contains',
  'matches',
  'exists',
  'not_exists',
  'type',
  'gt',
  'gte',
  'lt',
  'lte',
];
const ASSERT_TYPES = ['string', 'number', 'boolean', 'object', 'array', 'null'];
const ASSERT_FIELDS = ['path', 'op', 'expected'];
// 不需要 expected 的操作
const ASSERT_OPS_WITHOUT_EXPECTED = ['exists', 'not_exists'];

/**
 * 校验一个断言对象。
 *
 * @param {object} value 待校验的断言对象
 * @returns {string[]} 问题清单；空数组表示合法
 */
function validateAssertionObject(value) {
  const issues = [];

  for (const key of Object.keys(value)) {
    if (!ASSERT_FIELDS.includes(key)) {
      issues.push(`出现未知字段 "${key}"（允许字段: ${ASSERT_FIELDS.join(' / ')}）`);
    }
  }

  if (!isFilledString(value.path)) {
    issues.push('缺少必填字段 path（被检路径，如 "$.data.orderId" / "$status" / "$header.X-Trace-Id"）');
  } else if (!value.path.startsWith('$')) {
    issues.push(
      `path 取值非法: "${value.path}"，必须以 "$" 开头` +
        '（"$.a.b" 取响应体字段，"$status" 取 HTTP 状态码，"$header.X-Key" 取响应头）',
    );
  }

  if (!isFilledString(value.op)) {
    issues.push(`缺少必填字段 op（允许值: ${ASSERT_OPS.join(' / ')}）`);
  } else if (!ASSERT_OPS.includes(value.op)) {
    issues.push(`op 取值非法: "${value.op}"，允许值: ${ASSERT_OPS.join(' / ')}`);
  } else if (ASSERT_OPS_WITHOUT_EXPECTED.includes(value.op)) {
    if (value.expected !== undefined) {
      issues.push(`op "${value.op}" 不接受 expected 字段（该操作只判断存在性）`);
    }
  } else if (value.expected === undefined) {
    issues.push(`op "${value.op}" 缺少必填字段 expected（比较值）`);
  } else if (value.op === 'type') {
    if (!ASSERT_TYPES.includes(value.expected)) {
      issues.push(
        `expected 取值非法: "${value.expected}"（op 为 type 时只接受类型名: ${ASSERT_TYPES.join(' / ')}）`,
      );
    }
  } else if (value.op === 'matches') {
    if (!isFilledString(value.expected)) {
      issues.push('expected 必须是非空字符串（op 为 matches 时是正则）');
    } else {
      try {
        new RegExp(value.expected);
      } catch (err) {
        issues.push(`expected 不是合法正则: ${err.message}`);
      }
    }
  }

  return issues;
}

const problems = [];
const warnings = [];

// 严格模式（schema v2）：由顶层 "schema_version": 2 开启
let strict = false;

function fail(message) {
  problems.push(message);
}

function warn(message) {
  warnings.push(message);
}

// 缺失类问题：严格模式升级为 ERROR，宽松模式（v1 兼容）只报 WARN
function failOrWarn(message) {
  if (strict) {
    problems.push(message);
  } else {
    warnings.push(message);
  }
}

function isObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isFilledString(value) {
  return typeof value === 'string' && value.trim() !== '';
}

// skipped[].method 的合法取值有两种形态（D11）：
//   1) 方法编号（如 "M1.4"）—— 旧写法，行为完全不变
//   2) 维度跳过标识（如 "dimension:concurrency"）—— 新增，见 references/case-schema.md
// 维度名不在 8 个覆盖维度枚举内时只报 WARN：写法合法但很可能拼错了，
// 报 ERROR 会把"名字不认识"和"格式非法"混为一谈，也会误伤合法的新维度扩展。
function skipTargetKind(value) {
  if (!isFilledString(value)) return 'empty';
  const trimmed = value.trim();
  if (METHOD_PATTERN.test(trimmed)) return 'method';
  if (trimmed.startsWith(DIMENSION_SKIP_PREFIX)) return 'dimension';
  return 'invalid';
}

// 问题清单同时写入 stdout 与 stderr：调用方无论捕获哪个流都能定位到缺陷类型
function emit(line) {
  process.stdout.write(`${line}\n`);
  process.stderr.write(`${line}\n`);
}

// 用例状态归一化：缺 status 视为 active（v1 用例集没有状态字段）
function caseStatus(item) {
  if (!isObject(item)) return 'active';
  return typeof item.status === 'string' && CASE_STATUSES.includes(item.status) ? item.status : 'active';
}

function validateRequirements(requirements) {
  const ids = new Set();

  requirements.forEach((item, index) => {
    const at = `requirements[${index}]`;

    if (!isObject(item)) {
      fail(`${at} 必须是对象`);
      return;
    }

    if (!isFilledString(item.id)) {
      fail(`${at} 缺少必填字段 id（需求条目 ID 必须是非空字符串）`);
      return;
    }

    if (ids.has(item.id)) {
      fail(`${at}.id 重复的需求条目 ID: "${item.id}"`);
    }
    ids.add(item.id);

    if (item.title === undefined) {
      warn(`${at}.title 缺失，建议补上需求条目标题以便追溯矩阵可读`);
    } else if (!isFilledString(item.title)) {
      fail(`${at}.title 必须是非空字符串`);
    }

    if (item.testable !== undefined && typeof item.testable !== 'boolean') {
      fail(`${at}.testable 必须是布尔值（true/false）`);
    }

    if (item.source_ref !== undefined && typeof item.source_ref !== 'string') {
      fail(`${at}.source_ref 必须是字符串`);
    }
  });

  return ids;
}

function validateCases(cases, requirementIds) {
  const seenIds = new Map();
  const caseIds = new Set();

  cases.forEach((item, index) => {
    const at = `cases[${index}]`;

    if (!isObject(item)) {
      fail(`${at} 必须是对象`);
      return;
    }

    // --- id: 必填 + 全局唯一 + 格式 ---
    if (!isFilledString(item.id)) {
      fail(`${at} 缺少必填字段 id（用例 ID 必须是非空字符串）`);
    } else {
      if (!CASE_ID_PATTERN.test(item.id)) {
        fail(`${at}.id 非法: "${item.id}"，用例 ID 必须匹配 ^TC-\\d{3}$`);
      }
      if (seenIds.has(item.id)) {
        fail(`${at}.id 重复的用例 ID: "${item.id}"（与 cases[${seenIds.get(item.id)}] 冲突）`);
      } else {
        seenIds.set(item.id, index);
      }
      caseIds.add(item.id);
    }

    // --- title: 必填非空 ---
    if (item.title === undefined) {
      fail(`${at} 缺少必填字段 title`);
    } else if (!isFilledString(item.title)) {
      fail(`${at}.title 必须是非空字符串`);
    }

    // --- requirement_refs: 必填非空数组，且不能悬空 ---
    if (item.requirement_refs === undefined) {
      fail(`${at} 缺少必填字段 requirement_refs`);
    } else if (!Array.isArray(item.requirement_refs)) {
      fail(`${at}.requirement_refs 必须是数组`);
    } else if (item.requirement_refs.length === 0) {
      fail(`${at}.requirement_refs 为空，每个用例至少关联 1 个需求条目`);
    } else {
      item.requirement_refs.forEach((ref, refIndex) => {
        const refAt = `${at}.requirement_refs[${refIndex}]`;
        if (!isFilledString(ref)) {
          fail(`${refAt} 必须是非空字符串`);
          return;
        }
        if (!requirementIds.has(ref)) {
          fail(`${refAt} 悬空引用: "${ref}" 在 requirements 中不存在对应的需求条目`);
        }
      });
    }

    // --- dimension: 必填 + 枚举 ---
    if (item.dimension === undefined) {
      fail(`${at} 缺少必填字段 dimension`);
    } else if (!DIMENSIONS.includes(item.dimension)) {
      fail(`${at}.dimension 取值非法: "${item.dimension}"，允许值: ${DIMENSIONS.join(' / ')}`);
    }

    // --- priority: 必填 + 枚举 ---
    if (item.priority === undefined) {
      fail(`${at} 缺少必填字段 priority`);
    } else if (!PRIORITIES.includes(item.priority)) {
      fail(`${at}.priority 取值非法: "${item.priority}"，允许值: ${PRIORITIES.join(' / ')}`);
    }

    // --- steps: 必填，至少 1 条，每条含非空 action 与 expected ---
    if (item.steps === undefined) {
      fail(`${at} 缺少必填字段 steps`);
    } else if (!Array.isArray(item.steps)) {
      fail(`${at}.steps 必须是数组`);
    } else if (item.steps.length === 0) {
      fail(`${at}.steps 为空，至少需要 1 个步骤`);
    } else {
      item.steps.forEach((step, stepIndex) => {
        const stepAt = `${at}.steps[${stepIndex}]`;
        if (!isObject(step)) {
          fail(`${stepAt} 必须是对象（含 action 与 expected）`);
          return;
        }
        if (!isFilledString(step.action)) {
          fail(`${stepAt} 缺少必填字段 action（操作不能为空）`);
        }
        if (isObject(step.expected)) {
          // 结构化断言对象（REQ-002.5b）：字段缺失或 op 非法都要点名报错
          for (const issue of validateAssertionObject(step.expected)) {
            fail(`${stepAt}.expected: ${issue}`);
          }
        } else if (!isFilledString(step.expected)) {
          // 与放宽前完全一致的报错（纯字符串 expected 的旧用例集行为不变）
          fail(`${stepAt} 缺少必填字段 expected（预期结果不能为空）`);
        }
      });
    }

    // --- method（v2）: 可选字符串数组，元素须匹配方法编号格式 ---
    if (item.method === undefined) {
      failOrWarn(`${at} 缺少字段 method（未声明该用例应用了哪些测试方法）`);
    } else if (!Array.isArray(item.method)) {
      fail(`${at}.method 必须是数组`);
    } else if (item.method.length === 0) {
      warn(`${at}.method 为空数组，该用例未关联任何测试方法`);
    } else {
      item.method.forEach((method, methodIndex) => {
        const methodAt = `${at}.method[${methodIndex}]`;
        if (!isFilledString(method)) {
          fail(`${methodAt} 必须是非空字符串`);
          return;
        }
        if (!METHOD_PATTERN.test(method)) {
          fail(`${methodAt} 方法编号格式非法: "${method}"，必须匹配 ^M\\d+\\.\\d+$`);
        }
      });
    }

    // --- status（v2）: 可选枚举，缺失按 active 处理 ---
    const statusValid = CASE_STATUSES.includes(item.status);
    if (item.status === undefined) {
      failOrWarn(`${at} 缺少字段 status（生命周期状态，缺失按 active 处理）`);
    } else if (!statusValid) {
      fail(`${at}.status 取值非法: "${item.status}"，允许值: ${CASE_STATUSES.join(' / ')}`);
    }

    // --- revision（v2）: 非 active 状态必须给出修订记录 ---
    if (item.revision === undefined) {
      if (statusValid && item.status !== 'active') {
        fail(`${at} 缺少必填字段 revision：status 为 "${item.status}" 时必须给出修订记录`);
      }
    } else if (!isObject(item.revision)) {
      fail(`${at}.revision 必须是对象`);
    } else {
      if (!isFilledString(item.revision.change)) {
        fail(`${at}.revision.change 不能为空：修订记录必须写清改了什么`);
      }
      if (
        item.revision.previous_status !== undefined &&
        !CASE_STATUSES.includes(item.revision.previous_status)
      ) {
        fail(
          `${at}.revision.previous_status 取值非法: "${item.revision.previous_status}"，允许值: ${CASE_STATUSES.join(' / ')}`,
        );
      }
      if (item.revision.changed_at !== undefined && !isFilledString(item.revision.changed_at)) {
        fail(`${at}.revision.changed_at 必须是非空字符串`);
      }
      if (item.revision.triggered_by !== undefined && !isFilledString(item.revision.triggered_by)) {
        fail(`${at}.revision.triggered_by 必须是非空字符串`);
      }
    }

    // --- 可选字段的类型约束 ---
    if (item.preconditions !== undefined && !Array.isArray(item.preconditions)) {
      fail(`${at}.preconditions 必须是数组`);
    }
    if (item.data !== undefined && !isObject(item.data)) {
      fail(`${at}.data 必须是对象`);
    }
    if (item.tags !== undefined && !Array.isArray(item.tags)) {
      fail(`${at}.tags 必须是数组`);
    }
  });

  return caseIds;
}

// open_questions[]（v2）: 未决问题清单
function validateOpenQuestions(questions, requirementIds, caseIds) {
  if (questions === undefined) {
    failOrWarn('缺少顶层字段 open_questions（未决问题清单：暴露需求歧义的地方）');
    return { total: 0, blocking: 0 };
  }
  if (!Array.isArray(questions)) {
    fail('open_questions 必须是数组');
    return { total: 0, blocking: 0 };
  }
  if (questions.length === 0) {
    warn('open_questions 为空：未声明任何未决问题');
    return { total: 0, blocking: 0 };
  }

  const seenIds = new Set();
  let blocking = 0;

  questions.forEach((item, index) => {
    const at = `open_questions[${index}]`;

    if (!isObject(item)) {
      fail(`${at} 必须是对象`);
      return;
    }

    // --- id: 必填 + 唯一 + 格式 ---
    if (!isFilledString(item.id)) {
      fail(`${at} 缺少必填字段 id（未决问题 ID 必须是非空字符串）`);
    } else {
      if (!QUESTION_ID_PATTERN.test(item.id)) {
        fail(`${at}.id 非法: "${item.id}"，未决问题 ID 必须匹配 ^Q\\d+$`);
      }
      if (seenIds.has(item.id)) {
        fail(`${at}.id 重复的未决问题 ID: "${item.id}"`);
      }
      seenIds.add(item.id);
    }

    // --- question: 必填非空 ---
    if (item.question === undefined) {
      fail(`${at} 缺少必填字段 question（未决问题描述不能为空）`);
    } else if (!isFilledString(item.question)) {
      fail(`${at}.question 不能为空`);
    }

    // --- requirement_refs: 必填非空数组，且不能悬空 ---
    if (item.requirement_refs === undefined) {
      fail(`${at} 缺少必填字段 requirement_refs`);
    } else if (!Array.isArray(item.requirement_refs)) {
      fail(`${at}.requirement_refs 必须是数组`);
    } else if (item.requirement_refs.length === 0) {
      fail(`${at}.requirement_refs 为空，至少关联 1 个需求条目`);
    } else {
      item.requirement_refs.forEach((ref, refIndex) => {
        const refAt = `${at}.requirement_refs[${refIndex}]`;
        if (!isFilledString(ref)) {
          fail(`${refAt} 必须是非空字符串`);
          return;
        }
        if (!requirementIds.has(ref)) {
          fail(`${refAt} 悬空引用: "${ref}" 在 requirements 中不存在对应的需求条目`);
        }
      });
    }

    // --- interpretations: 必填，至少 2 条，每条含非空 reading 与 impact ---
    if (item.interpretations === undefined) {
      fail(`${at} 缺少必填字段 interpretations`);
    } else if (!Array.isArray(item.interpretations)) {
      fail(`${at}.interpretations 必须是数组`);
    } else if (item.interpretations.length < 2) {
      fail(
        `${at}.interpretations 至少 2 条：只列一种解读等于替需求方做了裁定（当前 ${item.interpretations.length} 条）`,
      );
    } else {
      item.interpretations.forEach((interpretation, interpretationIndex) => {
        const iAt = `${at}.interpretations[${interpretationIndex}]`;
        if (!isObject(interpretation)) {
          fail(`${iAt} 必须是对象（含 reading 与 impact）`);
          return;
        }
        if (!isFilledString(interpretation.reading)) {
          fail(`${iAt}.reading 不能为空`);
        }
        if (!isFilledString(interpretation.impact)) {
          fail(`${iAt}.impact 不能为空`);
        }
      });
    }

    // --- affected_cases: 可选数组，每项须存在于 cases[].id ---
    if (item.affected_cases !== undefined) {
      if (!Array.isArray(item.affected_cases)) {
        fail(`${at}.affected_cases 必须是数组`);
      } else {
        item.affected_cases.forEach((ref, refIndex) => {
          const refAt = `${at}.affected_cases[${refIndex}]`;
          if (!isFilledString(ref)) {
            fail(`${refAt} 必须是非空字符串`);
            return;
          }
          if (!caseIds.has(ref)) {
            fail(`${refAt} 悬空引用: "${ref}" 在 cases 中不存在对应的用例`);
          }
        });
      }
    }

    // --- severity: 必填枚举 ---
    if (item.severity === undefined) {
      fail(`${at} 缺少必填字段 severity`);
    } else if (!QUESTION_SEVERITIES.includes(item.severity)) {
      fail(`${at}.severity 取值非法: "${item.severity}"，允许值: ${QUESTION_SEVERITIES.join(' / ')}`);
    } else if (item.severity === 'blocking') {
      blocking += 1;
    }

    // --- coverage: 必填枚举；deferred 时必须给出 defer_reason ---
    if (item.coverage === undefined) {
      fail(`${at} 缺少必填字段 coverage`);
    } else if (!QUESTION_COVERAGES.includes(item.coverage)) {
      fail(`${at}.coverage 取值非法: "${item.coverage}"，允许值: ${QUESTION_COVERAGES.join(' / ')}`);
    } else if (item.coverage === 'deferred') {
      if (item.defer_reason === undefined) {
        fail(`${at} 缺少必填字段 defer_reason：coverage 为 "deferred" 时必须写明延后理由`);
      } else if (!isFilledString(item.defer_reason)) {
        fail(`${at}.defer_reason 不能为空：coverage 为 "deferred" 时必须写明延后理由`);
      }
    }
  });

  return { total: questions.length, blocking };
}

// coverage_matrix[]（v2）: 需求条目 → 已应用方法 / 跳过方法及原因
function validateCoverageMatrix(matrix, requirementIds) {
  if (matrix === undefined) {
    failOrWarn('缺少顶层字段 coverage_matrix（需求条目 → 方法覆盖矩阵：跳过也要留痕）');
    return { total: 0, withSkipped: 0 };
  }
  if (!Array.isArray(matrix)) {
    fail('coverage_matrix 必须是数组');
    return { total: 0, withSkipped: 0 };
  }

  const seen = new Map();
  let withSkipped = 0;

  matrix.forEach((item, index) => {
    const at = `coverage_matrix[${index}]`;

    if (!isObject(item)) {
      fail(`${at} 必须是对象`);
      return;
    }

    // --- requirement: 必填，须存在于 requirements[].id，且全局唯一 ---
    if (!isFilledString(item.requirement)) {
      fail(`${at} 缺少必填字段 requirement（需求条目 ID）`);
    } else {
      if (!requirementIds.has(item.requirement)) {
        fail(
          `${at}.requirement 悬空引用: "${item.requirement}" 在 requirements 中不存在对应的需求条目`,
        );
      }
      if (seen.has(item.requirement)) {
        fail(
          `${at}.requirement 重复的需求条目 ID: "${item.requirement}"（与 coverage_matrix[${seen.get(item.requirement)}] 冲突）`,
        );
      } else {
        seen.set(item.requirement, index);
      }
    }

    // --- methods_applied: 必填非空数组，元素须匹配方法编号格式 ---
    if (item.methods_applied === undefined) {
      fail(`${at} 缺少必填字段 methods_applied`);
    } else if (!Array.isArray(item.methods_applied)) {
      fail(`${at}.methods_applied 必须是数组`);
    } else if (item.methods_applied.length === 0) {
      fail(`${at}.methods_applied 为空，至少要声明 1 个已应用方法`);
    } else {
      item.methods_applied.forEach((method, methodIndex) => {
        const methodAt = `${at}.methods_applied[${methodIndex}]`;
        if (!isFilledString(method)) {
          fail(`${methodAt} 必须是非空字符串`);
          return;
        }
        if (!METHOD_PATTERN.test(method)) {
          fail(`${methodAt} 方法编号格式非法: "${method}"，必须匹配 ^M\\d+\\.\\d+$`);
        }
      });
    }

    // --- skipped: 可选数组，每项含合法 method 与非空 reason ---
    if (item.skipped !== undefined) {
      if (!Array.isArray(item.skipped)) {
        fail(`${at}.skipped 必须是数组`);
      } else {
        if (item.skipped.length > 0) withSkipped += 1;
        item.skipped.forEach((skip, skipIndex) => {
          const sAt = `${at}.skipped[${skipIndex}]`;
          if (!isObject(skip)) {
            fail(`${sAt} 必须是对象（含 method 与 reason）`);
            return;
          }
          if (!isFilledString(skip.method)) {
            fail(`${sAt}.method 必须是非空字符串`);
          } else {
            const kind = skipTargetKind(skip.method);
            if (kind === 'invalid') {
              fail(
                `${sAt}.method 方法编号格式非法: "${skip.method}"，必须匹配 ^M\\d+\\.\\d+$` +
                  `（如 "M1.4"），或写成维度跳过 "dimension:<维度名>"（如 "dimension:concurrency"）`,
              );
            } else if (kind === 'dimension') {
              const dimName = skip.method.trim().slice(DIMENSION_SKIP_PREFIX.length).trim();
              if (dimName === '') {
                fail(
                  `${sAt}.method 维度跳过写法不完整: "${skip.method}"，` +
                    '必须写成 "dimension:<维度名>"，<维度名> 不能为空',
                );
              } else if (!DIMENSIONS.includes(dimName)) {
                warn(
                  `${sAt}.method 维度名 "${dimName}" 不在覆盖维度枚举内（${DIMENSIONS.join(' / ')}），` +
                    '该跳过声明不会生效，请检查是否拼错',
                );
              }
            }
          }
          if (skip.reason === undefined) {
            fail(`${sAt} 缺少必填字段 reason（跳过方法必须留痕，不能空跳过）`);
          } else if (!isFilledString(skip.reason)) {
            fail(`${sAt}.reason 不能为空：跳过方法必须写明原因`);
          }
        });
      }
    }

    // --- dimensions: 可选数组 ---
    if (item.dimensions !== undefined && !Array.isArray(item.dimensions)) {
      fail(`${at}.dimensions 必须是数组`);
    }
  });

  return { total: matrix.length, withSkipped };
}

// 覆盖统计：deprecated 的用例不参与覆盖（不算作“已覆盖”）
function collectCoverage(requirements, cases) {
  const covered = new Set();

  cases.forEach((item) => {
    if (!isObject(item) || !Array.isArray(item.requirement_refs)) return;
    if (caseStatus(item) === 'deprecated') return;
    item.requirement_refs.forEach((ref) => {
      if (isFilledString(ref)) covered.add(ref);
    });
  });

  const uncovered = requirements
    .filter((item) => isObject(item) && isFilledString(item.id) && !covered.has(item.id))
    .map((item) => item.id);

  return { covered, uncovered };
}

function countStatuses(cases) {
  const counts = new Map(CASE_STATUSES.map((name) => [name, 0]));
  cases.forEach((item) => {
    if (!isObject(item)) return;
    const status = caseStatus(item);
    if (counts.has(status)) counts.set(status, counts.get(status) + 1);
  });
  return counts;
}

function printStats(doc, file, requirements, cases, uncovered, questionStats, matrixStats) {
  const testableCount = requirements.filter(
    (item) => isObject(item) && item.testable !== false,
  ).length;

  const distribution = new Map(DIMENSIONS.map((name) => [name, 0]));
  let unknownDimension = 0;

  cases.forEach((item) => {
    if (!isObject(item)) return;
    if (typeof item.dimension === 'string' && distribution.has(item.dimension)) {
      distribution.set(item.dimension, distribution.get(item.dimension) + 1);
    } else {
      unknownDimension += 1;
    }
  });

  const statuses = countStatuses(cases);
  const statusText = (name) => `${name}: ${statuses.get(name)}`;

  const source = isObject(doc.meta) && isFilledString(doc.meta.source) ? doc.meta.source : '未标注';
  const generatedAt =
    isObject(doc.meta) && isFilledString(doc.meta.generated_at) ? doc.meta.generated_at : '未标注';

  process.stdout.write(`校验通过: ${file}\n`);
  process.stdout.write(`需求来源: ${source}\n`);
  process.stdout.write(`生成时间: ${generatedAt}\n`);
  process.stdout.write(`需求条目总数: ${requirements.length}\n`);
  process.stdout.write(`可测试条目数: ${testableCount}\n`);
  process.stdout.write(
    `用例总数: ${cases.length}（active: ${statuses.get('active')} / deprecated: ${statuses.get('deprecated')} / blocked: ${statuses.get('blocked')}）\n`,
  );
  process.stdout.write(
    `用例状态分布: ${CASE_STATUSES.map(statusText).join(' / ')}\n`,
  );
  process.stdout.write('按维度分布:\n');
  for (const [name, count] of distribution) {
    process.stdout.write(`  ${name}: ${count}\n`);
  }
  if (unknownDimension > 0) {
    process.stdout.write(`  (非法维度): ${unknownDimension}\n`);
  }
  process.stdout.write(
    uncovered.length > 0
      ? `未覆盖需求条目: ${uncovered.join(', ')}\n`
      : '未覆盖需求条目: 无（全部需求条目均已被用例覆盖）\n',
  );
  process.stdout.write(
    `未决问题数: ${questionStats.total}（blocking: ${questionStats.blocking}）\n`,
  );
  process.stdout.write(
    `覆盖矩阵条目数: ${matrixStats.total}（其中带跳过声明: ${matrixStats.withSkipped}）\n`,
  );
}

function printWarnings() {
  for (const warning of warnings) {
    process.stdout.write(`[WARN] ${warning}\n`);
  }
}

// ---------------------------------------------------------------- v2 骨架生成

/**
 * 生成字段齐备的 schema v2 骨架。
 *
 * 为什么要骨架：只把字段清单写进文档，仍然是在靠模型的自觉填全字段——
 * 而这正是 REQ-001 eval 已经证死的失败模式（模型会自信地少写一半，然后宣称覆盖完整）。
 * 让 agent 从骨架往里填，"字段齐备"才从叮嘱变成结构保证。
 *
 * 骨架里的 `<...>` 是**占位符**，必须替换成真实内容。
 *
 * @returns {object} v2 骨架对象
 */
function buildSkeleton() {
  return {
    schema_version: 2,
    meta: {
      source: '<需求来源标识：文档名 / 链接 / 需求单号>',
      generated_at: '<ISO-8601 生成时间，如 2026-11-11T18:00:00+08:00>',
      case_count: 1,
    },
    requirements: [
      {
        id: 'R-1',
        title: '<需求条目标题>',
        source_ref: '<原文摘录或位置：章节号 / 页码 / 引用句>',
        testable: true,
      },
    ],
    open_questions: [
      {
        id: 'Q1',
        question: '<把需求本身的歧义说清楚：哪种理解会改变行为>',
        requirement_refs: ['R-1'],
        interpretations: [
          { reading: '<第一种合理解读>', impact: '<按这种解读，行为或期望结果会有什么不同>' },
          { reading: '<第二种合理解读>', impact: '<按这种解读，行为或期望结果会有什么不同>' },
        ],
        affected_cases: ['TC-001'],
        severity: 'non-blocking',
        coverage: 'cases',
      },
    ],
    coverage_matrix: [
      {
        requirement: 'R-1',
        // 方法编号取 M1.x 段（测试设计方法，见 references/methods.json）——
        // 骨架给出的是**能直接用**的编号：照抄 M0.x 会被 check-methods.mjs 判"无法判定"。
        methods_applied: ['M1.1'],
        skipped: [],
        dimensions: ['functional'],
      },
    ],
    cases: [
      {
        id: 'TC-001',
        title: '<一句话说清这条用例验证什么>',
        requirement_refs: ['R-1'],
        dimension: 'functional',
        priority: 'P0',
        method: ['M1.1'],
        status: 'active',
        preconditions: [],
        steps: [{ action: '<可执行的动作>', expected: '<可判定的预期结果>' }],
        data: {},
        tags: [],
      },
    ],
  };
}

/**
 * 骨架自检：用**同一套**校验规则检查刚生成的骨架。
 * 骨架若自检不通过，说明校验器与骨架不同步——这是脚本自己的 bug，必须当场暴露。
 *
 * @param {object} doc 骨架对象
 * @returns {string[]} 问题列表（空 = 自检通过）
 */
function selfCheckSkeleton(doc) {
  const savedProblems = problems.splice(0, problems.length);
  const savedWarnings = warnings.splice(0, warnings.length);
  const savedStrict = strict;
  strict = true;
  const requirementIds = validateRequirements(doc.requirements);
  const caseIds = validateCases(doc.cases, requirementIds);
  validateOpenQuestions(doc.open_questions, requirementIds, caseIds);
  validateCoverageMatrix(doc.coverage_matrix, requirementIds);
  const issues = problems.slice();
  problems.splice(0, problems.length, ...savedProblems);
  warnings.splice(0, warnings.length, ...savedWarnings);
  strict = savedStrict;
  return issues;
}

function main() {
  const argv = process.argv.slice(2);

  // --- --init：输出字段齐备的 v2 骨架（纯增量，不影响原有校验路径） ---
  if (argv.includes('--init')) {
    const files = argv.filter((item) => item !== '--init');
    if (files.length > 0) {
      emit('用法: node scripts/validate-cases.mjs --init（--init 不接受文件参数）');
      process.exit(2);
    }
    const skeleton = buildSkeleton();
    const issues = selfCheckSkeleton(skeleton);
    if (issues.length > 0) {
      emit(`骨架自检失败（校验器与骨架不同步，属脚本缺陷）: 共 ${issues.length} 个问题`);
      for (const issue of issues) {
        emit(`  - ${issue}`);
      }
      process.exit(1);
    }
    process.stdout.write(`${JSON.stringify(skeleton, null, 2)}\n`);
    process.exit(0);
  }

  const file = argv[0];

  if (!file) {
    emit('用法: node scripts/validate-cases.mjs <cases.json>');
    process.exit(2);
  }

  const target = resolve(file);

  let raw;
  try {
    raw = readFileSync(target, 'utf8');
  } catch (err) {
    emit(`无法读取用例集文件: ${file}（${err.message}）`);
    process.exit(1);
  }

  let doc;
  try {
    doc = JSON.parse(raw);
  } catch (err) {
    emit(`JSON 语法错误: ${file} 解析失败 — ${err.message}`);
    process.exit(1);
  }

  if (!isObject(doc)) {
    emit('结构错误: 用例集根节点必须是 JSON 对象');
    process.exit(1);
  }

  // schema_version 决定严格程度：显式声明 2 → 严格模式；缺省或显式 1 → v1 宽松模式
  if (doc.schema_version === undefined || doc.schema_version === 1) {
    strict = false;
  } else if (doc.schema_version === 2) {
    strict = true;
  } else {
    strict = false;
    warn(
      `未知的 schema_version: "${doc.schema_version}"（当前只识别 1 / 2），按 v1 宽松规则校验`,
    );
  }

  const requirements = doc.requirements;
  const cases = doc.cases;

  if (requirements === undefined) {
    fail('缺少必填字段 requirements（需求条目数组）');
  } else if (!Array.isArray(requirements)) {
    fail('requirements 必须是数组');
  }

  if (cases === undefined) {
    fail('缺少必填字段 cases（用例数组）');
  } else if (!Array.isArray(cases)) {
    fail('cases 必须是数组');
  }

  const requirementList = Array.isArray(requirements) ? requirements : [];
  const caseList = Array.isArray(cases) ? cases : [];

  const requirementIds = validateRequirements(requirementList);
  const caseIds = validateCases(caseList, requirementIds);
  const questionStats = validateOpenQuestions(doc.open_questions, requirementIds, caseIds);
  const matrixStats = validateCoverageMatrix(doc.coverage_matrix, requirementIds);

  if (problems.length > 0) {
    emit(`✗ 校验失败: 共 ${problems.length} 个问题（文件: ${file}）`);
    for (const problem of problems) {
      emit(`  - ${problem}`);
    }
    printWarnings();
    process.exit(1);
  }

  // meta.case_count 与实际用例数不一致只提示不报错：它是抬头元信息，不是结构约束
  if (
    isObject(doc.meta) &&
    typeof doc.meta.case_count === 'number' &&
    doc.meta.case_count !== caseList.length
  ) {
    warn(`meta.case_count (${doc.meta.case_count}) 与实际用例数 (${caseList.length}) 不一致`);
  }

  printWarnings();

  const { uncovered } = collectCoverage(requirementList, caseList);
  printStats(doc, file, requirementList, caseList, uncovered, questionStats, matrixStats);
  process.exit(0);
}

main();
