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

import { compareAssertion, isObject } from './assertion.mjs';

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
  ASSERTION_WITHOUT_RESPONSE: 'assertion_without_response',
  EXECUTOR_ERROR: 'executor_error',
});

/** 会被判为 blocked 的执行器错误类型（其余错误类型判 failed） */
const BLOCKING_ERROR_TYPES = Object.freeze([
  BLOCK_TYPES.CREDENTIAL_MISSING,
  BLOCK_TYPES.ENVIRONMENT_MISSING,
  BLOCK_TYPES.REQUEST_SPEC_MISSING,
]);

/**
 * 把断言绑定到可判的响应上。
 *
 * 规则（需求 F3 的多步语义）：
 *   - 用例只解析出**一次**请求时，所有断言都针对这同一次响应（一次响应多条断言）。
 *   - 用例解析出**多次**请求时，每条断言绑定到它自己所在 step 的响应。
 *   - 绑定不到响应的断言 → 没有可判的响应 → 该用例判 blocked（不得判 passed）。
 *
 * @param {{requests: object[], assertions: object[]}} plan 执行计划
 * @param {object} execution 执行器返回
 * @returns {{bindings: object[], missing: object[]}}
 */
export function bindAssertions(plan, execution) {
  const requests = Array.isArray(plan && plan.requests) ? plan.requests : [];
  const assertions = Array.isArray(plan && plan.assertions) ? plan.assertions : [];
  const stepResults = Array.isArray(execution && execution.steps) ? execution.steps : [];
  const responses = new Map();
  for (const item of stepResults) {
    if (!item || item.step_index === undefined) continue;
    responses.set(item.step_index, item.observed);
  }
  const legacy = execution && execution.observed ? execution.observed : undefined;

  if (requests.length === 1) {
    const only = responses.has(requests[0].step_index)
      ? responses.get(requests[0].step_index)
      : legacy;
    const bindings = assertions.map((item) => ({
      ...item,
      observed: only,
      // 该用例只解析出一次请求：所有断言都针对这同一次响应（记下它属于哪一步，便于追溯）
      bound_to_step: requests[0].step_index,
    }));
    return {
      bindings,
      missing: only === undefined ? assertions.slice() : [],
    };
  }
  const bindings = assertions.map((item) => ({
    ...item,
    observed: responses.has(item.stepIndex) ? responses.get(item.stepIndex) : undefined,
  }));
  // 运行时没拿到响应（执行器没跑或没回报这一步）—— 与"计划层就不可绑定"是两回事
  return { bindings, missing: bindings.filter((item) => item.observed === undefined) };
}

/**
 * 统一判定入口：给定用例与执行结果，得出 status。
 *
 * @param {object} spec 判定输入
 * @param {string} spec.lifecycle 用例生命周期状态（active / modified / deprecated / blocked）
 * @param {{requests: object[], assertions: object[]}} spec.plan 执行计划（请求 + 断言 + 归属）
 * @param {object} spec.execution 执行器返回（{observed, steps, error, reproduction}）
 * @returns {{status: string, error: object|null, failures: object[], reason: string|null}}
 */
export function decide(spec) {
  const lifecycle = spec.lifecycle || 'active';
  const plan = spec.plan || { requests: [], assertions: [] };
  const assertions = Array.isArray(plan.assertions) ? plan.assertions : [];
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

  const bound = bindAssertions(plan, execution);

  if (execution.error) {
    const error = isObject(execution.error)
      ? execution.error
      : { type: 'executor_error', message: String(execution.error) };
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

  // 计划层就不可绑定的断言（所在 step 不可执行）→ 没有响应就判不了，判不了就 blocked。
  // 放在执行错误之后：环境/凭证问题要先报出来，它比用例写法问题更根本。
  const planUnbound = Array.isArray(plan.unbound) ? plan.unbound : [];
  const missing = planUnbound.length > 0 ? planUnbound : bound.missing;
  if (missing.length > 0) {
    const where = missing
      .map((item) => `steps[${item.stepIndex}]${item.action ? `（${item.action}）` : ''}`)
      .join('、');
    return {
      ...empty,
      status: STATUS.BLOCKED,
      error: {
        type: BLOCK_TYPES.ASSERTION_WITHOUT_RESPONSE,
        message:
          `有 ${missing.length} 条断言没有可判的响应（所在 step 不可执行）：${where}。` +
          '没有响应就判不了，判不了就 blocked（不得判 passed）',
      },
      reason: '断言所在 step 不可执行',
    };
  }

  const failures = [];
  for (const item of bound.bindings) {
    const outcome = compareAssertion(item.assertion, item.observed || {});
    if (!outcome.ok) {
      failures.push({
        path: item.assertion.path,
        op: item.assertion.op,
        expected: item.assertion.expected,
        actual: outcome.found ? outcome.actual : null,
        step_index: item.stepIndex,
        message: outcome.message,
      });
    }
  }
  if (failures.length === 0) {
    return { status: STATUS.PASSED, error: null, failures: [], reason: null };
  }
  const summary = failures
    .map((item) => {
      const where = `steps[${item.step_index}]`;
      const note =
        item.bound_to_step !== undefined && item.bound_to_step !== item.step_index
          ? `（该用例只解析出一次请求，本次断言针对的是 steps[${item.bound_to_step}] 的响应）`
          : '';
      return `${where} ${item.path} ${item.op} ${JSON.stringify(item.expected)} 不成立${note}`;
    })
    .join('; ');
  return {
    status: STATUS.FAILED,
    error: {
      type: 'assertion_failed',
      message: `${failures.length} 条断言不成立: ${summary}`,
    },
    failures,
    reason: '断言不成立',
  };
}
