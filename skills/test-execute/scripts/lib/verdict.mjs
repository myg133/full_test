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
  CONFLICTING_REQUEST_CARRIER: 'conflicting_request_carrier',
  INCOMPLETE_REQUEST_CARRIER: 'incomplete_request_carrier',
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
 * 把"没写全 path 的载体"列成一句话。
 *
 * 需求 D25：这条规则对用例级载体与 step 级载体**一视同仁** ——
 * 缺 path 是「补齐」，与"载体冲突"的「二选一」是两种不同的修法。
 *
 * @param {object} incomplete 计划层的 incomplete 结构（{carriers: [...]}）
 * @returns {string} 空串表示没有缺 path 的载体
 */
export function incompleteCarriersText(incomplete) {
  const items = isObject(incomplete) && Array.isArray(incomplete.carriers) ? incomplete.carriers : [];
  if (items.length === 0) return '';
  return items
    .map((item) => {
      const isCase = isObject(item) && item.carrier === 'case';
      const where = isCase
        ? '用例级请求载体'
        : `steps[${isObject(item) ? item.step_index : '?'}] 的请求载体`;
      const method =
        isObject(item) && typeof item.method === 'string' && item.method.trim() !== ''
          ? item.method.trim()
          : 'GET';
      return `${where}没有写明 path（method 可省略，默认 GET；当前读到 method=${method}）`;
    })
    .join('；');
}

/**
 * 把"载体冲突"列成一句话。
 *
 * @param {object} conflict 计划层的 conflict 结构
 * @returns {string} 空串表示没有冲突
 */
export function conflictText(conflict) {
  if (!isObject(conflict)) return '';
  const caseLabel =
    isObject(conflict.case_request) && typeof conflict.case_request.label === 'string'
      ? conflict.case_request.label
      : '（未知）';
  const where = (Array.isArray(conflict.steps) ? conflict.steps : [])
    .map((item) => {
      const label =
        isObject(item) && typeof item.label === 'string' && item.label !== '' ? item.label : '（未知）';
      return `steps[${isObject(item) ? item.step_index : '?'}]（${label}）`;
    })
    .join('、');
  return `用例级请求载体指向 ${caseLabel}，${where} 指向不同的端点`;
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
    // 需求 D26：判定类型取更根本的那个（没有断言 → 补上 path 也不会变得可判定），
    // 但**信息不能丢**：载体问题一并点出，免得调用方改完再撞第二个，白白多一轮返工。
    const carriers = incompleteCarriersText(plan.incomplete);
    const extra = carriers !== '' ? `。另外：${carriers}，也需要一并补上` : '';
    return {
      ...empty,
      status: STATUS.BLOCKED,
      error: {
        type: BLOCK_TYPES.NO_ASSERTION,
        message:
          '缺少可机械判定的断言：该用例所有 steps[].expected 都是普通字符串，' +
          `无法机械判定，因此判 blocked（不得判 passed）${extra}`,
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

  // 载体不完整（需求 D23/D25）：**任何一类载体**（用例级 / step 级）没写明 path。
  // 缺 path 是「补齐」，冲突是「二选一」—— 两种修法不同，错误类型必须分开，
  // 否则调用方会照着"冲突"去改（去掉载体 / 去掉 step），而真正要补的是 path。
  const incomplete = isObject(plan.incomplete) ? plan.incomplete : null;
  if (incomplete) {
    const carriers = incompleteCarriersText(incomplete);
    const carriersText = carriers !== '' ? carriers : '请求载体没有写明 path';
    // 多问题并存时（需求 D26）：类型取更根本的这个，但其它问题一并点出。
    const conflictNote = conflictText(plan.conflict);
    const extra =
      conflictNote !== '' ? `。另外：${conflictNote}，也需要一并处理（去掉其中一边）` : '';
    return {
      ...empty,
      status: STATUS.BLOCKED,
      error: {
        type: BLOCK_TYPES.INCOMPLETE_REQUEST_CARRIER,
        message:
          `${carriersText} —— 请补上 path；若本意是由 step 提供路径，请去掉该载体。` +
          `判 blocked（不得判 passed）${extra}`,
      },
      reason: '请求载体不完整（缺 path）',
    };
  }

  // 载体冲突（计划层就发现的歧义）：用例级载体与 step 级请求指向不同的端点。
  // 是"一次调用"还是"多次调用"是需求方的意图 —— 实现不替需求方裁定，
  // 所以既不静默丢掉哪一边，也不判 passed，直接判 blocked。
  const conflict = isObject(plan.conflict) ? plan.conflict : null;
  if (conflict) {
    return {
      ...empty,
      status: STATUS.BLOCKED,
      error: {
        type: BLOCK_TYPES.CONFLICTING_REQUEST_CARRIER,
        message:
          `载体冲突：${conflictText(conflict)}。` +
          '是同一次调用还是多次调用，需要需求方裁定 —— ' +
          '实现不替需求方猜，所以该用例判 blocked（不得判 passed），' +
          '也不会静默丢掉其中一边的请求',
      },
      reason: '用例级载体与 step 级请求冲突',
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
        item.bound_to_step === null
          ? '（该用例只解析出一次请求，本次断言针对的是这同一次响应）'
          : item.bound_to_step !== undefined && item.bound_to_step !== item.step_index
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
