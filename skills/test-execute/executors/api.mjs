// api.mjs — 真实 HTTP 驱动（node 内置 fetch）
//
// 硬约束：本文件是 skill 的组成部分，agent 不得修改。
//         换请求方式、加断言、改字段名 —— 全部由配置表达（见 executors/index.json）。
//
// 本驱动只报告"观察到什么"（observed），不做任何通过/失败判定。
// 判定规则是数据（用例 steps[].expected 里的断言对象），由执行外壳统一执行。
//
// 纯 Node.js，只依赖 node: 内置模块。

import {
  buildAuthHeaders,
  buildCurlCommand,
  buildUrl,
  interpolateDeep,
  performRequest,
} from './http-core.mjs';

/** 驱动名 */
export const name = 'api';

/** 驱动版本 */
export const version = '1.0.0';

/**
 * 启动钩子：真实 HTTP 驱动不需要额外资源。
 *
 * @returns {Promise<object>}
 */
export async function start() {
  return {};
}

/**
 * 结束钩子。
 */
export async function stop() {
  // 无需清理
}

/**
 * 执行一条用例：按用例声明的请求打一次真实 HTTP，如实报告观察结果。
 *
 * @param {object} caseObj 用例
 * @param {object} context 执行上下文
 * @returns {Promise<object>}
 */
export async function run(caseObj, context) {
  const request = context.request || null;
  if (!request) {
    return {
      error: {
        type: 'request_spec_missing',
        message:
          '用例没有声明请求（case.request / case.data.request / case.steps[].request），' +
          '真实 HTTP 驱动不知道该打哪个地址',
      },
    };
  }
  const variables = context.variables || {};
  const method = String(request.method || 'GET').toUpperCase();
  const path = interpolateDeep(request.path === undefined ? '/' : request.path, variables);
  const headers = interpolateDeep(request.headers || {}, variables);
  const body = request.body === undefined ? undefined : interpolateDeep(request.body, variables);

  const auth = buildAuthHeaders(context.auth, context.resolved_credentials);
  if (auth.missing.length > 0) {
    return {
      error: {
        type: 'credential_missing',
        message: `环境变量未设置: ${auth.missing.join(' / ')}（读不到凭证 → 该用例算阻塞，不是失败）`,
      },
    };
  }
  const allHeaders = { ...headers, ...auth.headers };

  const url = buildUrl(context.base_url, path, interpolateDeep(request.query || {}, variables));
  const outcome = await performRequest({
    url,
    method,
    headers: allHeaders,
    body,
    timeoutMs: context.timeout_ms,
    retries: context.retries,
  });
  if (!outcome.ok) return { error: outcome.error };

  const observed = outcome.observed;
  const evidenceContent = `${JSON.stringify(
    {
      driver: name,
      request: { method, path, url, auth_mode: auth.description },
      response: { status_code: observed.status_code, headers: observed.headers, body: observed.body },
    },
    null,
    2,
  )}\n`;

  return {
    observed,
    evidence: [{ path: 'response.json', media_type: 'application/json', content: evidenceContent }],
    reproduction: {
      steps: (Array.isArray(caseObj.steps) ? caseObj.steps : [])
        .map((step) => (step && typeof step.action === 'string' ? step.action : ''))
        .filter((item) => item !== ''),
      command: buildCurlCommand({
        method,
        url,
        headers: request.headers || {},
        body,
      }),
      expected: (Array.isArray(caseObj.steps) ? caseObj.steps : [])
        .map((step) => (step && typeof step.expected === 'string' ? step.expected : ''))
        .filter((item) => item !== '')
        .join('; '),
    },
  };
}
