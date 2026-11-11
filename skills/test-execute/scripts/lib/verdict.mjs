// verdict.mjs — status 判定的**唯一模块**
//
// 硬约束（对应需求 F3 / AC-005）：
//   1. `status` 的取值与判定逻辑只允许出现在本文件。
//   2. 执行器（executors/*.mjs）只报告"观察到什么"（observed），
//      不得出现通过/失败判定分支，也不得返回 status。
//   3. 判定规则是**数据**（用例 steps[].expected 里的断言对象），不是代码。
//
// 判定口径：
//   passed  = 全部断言成立
//   failed  = 有断言不成立 / 执行报错 / 超时
//   blocked = 无法判定（缺少可机械判定的断言、凭证或环境缺失、执行器无法启动）
//   skipped = 不执行（用例已废弃 / 用例自身被标记为 blocked）
//
// 为什么"不可判定"必须判 blocked 而不是 passed：执行器"跑完了没报错"不等于"通过"。
// 把不可判定的用例算作通过，等于把"没测"记成"测过且通过"。宁可漏报通过，不可虚报通过。
//
// 纯 Node.js，只依赖 node: 内置模块。

import { compareAssertion, isAssertionObject, isObject } from './assertion.mjs';

/** status 枚举（唯一来源） */
export const STATUS = Object.freeze({
  PASSED: 'passed',
  FAILED: 'failed',
  BLOCKED: 'blocked',
  SKIPPED: 'skipped',
});

/** status 取值清单 */
export const STATUS_VALUES = Object.freeze([
  STATUS.PASSED,
  STATUS.FAILED,
  STATUS.BLOCKED,
  STATUS.SKIPPED,
]);

/** 阻塞原因类型 */
export const BLOCK_TYPES = Object.freeze({
  NO_ASSERTION: 'no_mechanical_assertion',
  CREDENTIAL_MISSING: 'credential_missing',
  ENVIRONMENT_MISSING: 'environment_missing',
  REQUEST_SPEC_MISSING: 'request_spec_missing',
  EXECUTOR_ERROR: 'executor_error',
});

/** 会被判为 blocked 的执行器错误类型（其余错误类型判 failed） */
const BLOCKING_ERROR_TYPES = Object.freeze([
  BLOCK_TYPES.CREDENTIAL_MISSING,
  BLOCK_TYPES.ENVIRONMENT_MISSING,
  BLOCK_TYPES.REQUEST_SPEC_MISSING,
]);

/**
 * 从用例里收集结构化断言。
 *
 * 载体：steps[].expected 为断言对象时算一条断言；为普通字符串时不算。
 *
 * @param {object} caseObj 用例对象
 * @returns {{assertion: object, stepIndex: number, action: string}[]}
 */
export function collectAssertions(caseObj) {
  const found = [];
  if (!isObject(caseObj)) return found;
  const steps = Array.isArray(caseObj.steps) ? caseObj.steps : [];
  steps.forEach((step, stepIndex) => {
    if (!isObject(step)) return;
    if (!isAssertionObject(step.expected)) return;
    found.push({
      assertion: step.expected,
      stepIndex,
      action: typeof step.action === 'string' ? step.action : '',
    });
  });
  return found;
}

/**
 * 执行断言集合。
 *
 * @param {{assertion: object}[]} assertions 断言集合
 * @param {object} observed 观察结果
 * @returns {{ok: boolean, failures: {path: string, op: string, expected: any, actual: any, message: string}[]}}
 */
export function evaluateAssertions(assertions, observed) {
  const failures = [];
  for (const item of assertions) {
    const outcome = compareAssertion(item.assertion, observed || {});
    if (!outcome.ok) {
      failures.push({
        path: item.assertion.path,
        op: item.assertion.op,
        expected: item.assertion.expected,
        actual: outcome.found ? outcome.actual : null,
        message: outcome.message,
      });
    }
  }
  return { ok: failures.length === 0, failures };
}

/**
 * 统一判定入口：给定用例与执行结果，得出 status。
 *
 * @param {object} spec 判定输入
 * @param {string} spec.lifecycle 用例生命周期状态（active / modified / deprecated / blocked）
 * @param {{assertion: object}[]} spec.assertions 结构化断言集合
 * @param {object} spec.execution 执行器返回（{observed, error, reproduction}）
 * @returns {{status: string, error: object|null, failures: object[], reason: string|null}}
 */
export function decide(spec) {
  const lifecycle = spec.lifecycle || 'active';
  const assertions = Array.isArray(spec.assertions) ? spec.assertions : [];
  const execution = isObject(spec.execution) ? spec.execution : {};
  const empty = { status: STATUS.BLOCKED, error: null, failures: [], reason: null };

  if (lifecycle === 'deprecated') {
    return { ...empty, status: STATUS.SKIPPED, reason: '用例已废弃（status: deprecated），不执行' };
  }
  if (lifecycle === 'blocked') {
    return { ...empty, status: STATUS.SKIPPED, reason: '用例自身被标记为 blocked（status: blocked），不执行' };
  }
  if (assertions.length === 0) {
    return {
      ...empty,
      status: STATUS.BLOCKED,
      error: {
        type: BLOCK_TYPES.NO_ASSERTION,
        message:
          '缺少可机械判定的断言：该用例所有 steps[].expected 都是普通字符串，' +
          '无法机械判定，因此判 blocked（不得判 passed）',
      },
      reason: '缺少可机械判定的断言',
    };
  }
  if (execution.error) {
    const error = isObject(execution.error) ? execution.error : { type: 'executor_error', message: String(execution.error) };
    const blocking = BLOCKING_ERROR_TYPES.includes(error.type);
    return {
      status: blocking ? STATUS.BLOCKED : STATUS.FAILED,
      error: {
        type: typeof error.type === 'string' && error.type !== '' ? error.type : 'executor_error',
        message: typeof error.message === 'string' ? error.message : String(error),
      },
      failures: [],
      reason: blocking ? '环境/凭证缺失，无法执行' : '执行报错',
    };
  }
  if (!isObject(execution.observed)) {
    return {
      status: STATUS.FAILED,
      error: { type: 'executor_error', message: '执行器没有返回 observed：无法判定结果' },
      failures: [],
      reason: '执行器未返回观察结果',
    };
  }
  const evaluated = evaluateAssertions(assertions, execution.observed);
  if (evaluated.ok) {
    return { status: STATUS.PASSED, error: null, failures: [], reason: null };
  }
  const summary = evaluated.failures
    .map((item) => `${item.path} ${item.op} ${JSON.stringify(item.expected)} 不成立`)
    .join('; ');
  return {
    status: STATUS.FAILED,
    error: {
      type: 'assertion_failed',
      message: `${evaluated.failures.length} 条断言不成立: ${summary}`,
    },
    failures: evaluated.failures,
    reason: '断言不成立',
  };
}
