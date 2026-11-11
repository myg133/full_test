// http-core.mjs — 两个 HTTP 驱动共用的请求构造与发送逻辑
//
// 硬约束：本目录（executors/）下的文件是 skill 的组成部分，agent 不得修改。
// 定制需求必须由配置表达（见 executors/index.json 与 references/executor-spec.md）。
//
// 本模块只做"发请求、如实报告看到了什么"，不做任何通过/失败判定。
//
// 纯 Node.js，只依赖 node: 内置模块。

import { setTimeout as wait } from 'node:timers/promises';

/** 默认超时（毫秒） */
export const DEFAULT_TIMEOUT_MS = 30000;

/** 默认重试次数 */
export const DEFAULT_RETRIES = 0;

/**
 * 是否是普通对象。
 * @param {any} value 待判定值
 * @returns {boolean}
 */
export function isObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * 替换字符串里的 ${变量} 占位符。
 *
 * @param {string} text 原文
 * @param {object} variables 变量表
 * @returns {string}
 */
export function interpolate(text, variables) {
  if (typeof text !== 'string') return text;
  return text.replace(/\$\{([^}]+)\}/g, (whole, name) => {
    const key = String(name).trim();
    if (Object.prototype.hasOwnProperty.call(variables, key)) return String(variables[key]);
    return whole;
  });
}

/**
 * 递归替换对象里的占位符。
 *
 * @param {any} value 原值
 * @param {object} variables 变量表
 * @returns {any}
 */
export function interpolateDeep(value, variables) {
  if (typeof value === 'string') return interpolate(value, variables);
  if (Array.isArray(value)) return value.map((item) => interpolateDeep(item, variables));
  if (isObject(value)) {
    const out = {};
    for (const [key, item] of Object.entries(value)) out[key] = interpolateDeep(item, variables);
    return out;
  }
  return value;
}

/**
 * 拼接完整 URL。
 *
 * @param {string} baseUrl 根地址
 * @param {string} path 路径（可自带 ?query）
 * @param {object} query 查询参数
 * @returns {string}
 */
export function buildUrl(baseUrl, path, query) {
  const root = String(baseUrl || '').replace(/\/+$/, '');
  const rawPath = String(path || '/');
  const [pathPart, inlineQuery] = rawPath.split('?');
  const params = new URLSearchParams();
  if (inlineQuery) {
    for (const [key, value] of new URLSearchParams(inlineQuery)) params.append(key, value);
  }
  if (isObject(query)) {
    for (const [key, value] of Object.entries(query)) {
      if (value === undefined || value === null) continue;
      params.append(key, String(value));
    }
  }
  const queryPart = params.toString();
  return `${root}${pathPart.startsWith('/') ? pathPart : `/${pathPart}`}${queryPart ? `?${queryPart}` : ''}`;
}

/**
 * 由鉴权配置构造请求头。
 *
 * 鉴权配置只引用环境变量名；真实值从 context.resolved_credentials 取，
 * 且**不会**被写进证据与复现命令（复现命令里写的是环境变量名本身）。
 *
 * @param {object} auth 鉴权配置
 * @param {object} credentials 已解析的凭证值表
 * @returns {{headers: object, missing: string[], description: string}}
 */
export function buildAuthHeaders(auth, credentials) {
  const headers = {};
  const missing = [];
  if (!isObject(auth)) return { headers, missing, description: 'none' };
  const type = typeof auth.type === 'string' ? auth.type.trim().toLowerCase() : 'none';
  if (type === 'none' || type === '') return { headers, missing, description: 'none' };
  const values = isObject(credentials) ? credentials : {};
  if (type === 'bearer') {
    const name = typeof auth.env === 'string' ? auth.env.trim() : '';
    const value = name ? values[name] : undefined;
    if (!value) {
      if (name) missing.push(name);
      return { headers, missing, description: 'bearer' };
    }
    headers.authorization = `Bearer ${value}`;
    return { headers, missing, description: `bearer (env: ${name})` };
  }
  if (type === 'basic') {
    const userName = typeof auth.username_env === 'string' ? auth.username_env.trim() : '';
    const passName = typeof auth.password_env === 'string' ? auth.password_env.trim() : '';
    const user = userName ? values[userName] : undefined;
    const pass = passName ? values[passName] : undefined;
    if (!user) {
      if (userName) missing.push(userName);
      return { headers, missing, description: 'basic' };
    }
    if (passName && !pass) {
      missing.push(passName);
      return { headers, missing, description: 'basic' };
    }
    const raw = passName ? `${user}:${pass}` : `${user}`;
    headers.authorization = `Basic ${Buffer.from(raw, 'utf8').toString('base64')}`;
    return { headers, missing, description: `basic (env: ${[userName, passName].filter(Boolean).join(', ')})` };
  }
  if (type === 'header') {
    const headerName = typeof auth.header === 'string' ? auth.header.trim() : '';
    const envName = typeof auth.env === 'string' ? auth.env.trim() : '';
    const value = envName ? values[envName] : undefined;
    if (!headerName || !value) {
      if (envName) missing.push(envName);
      return { headers, missing, description: 'header' };
    }
    headers[headerName.toLowerCase()] = value;
    return { headers, missing, description: `header ${headerName} (env: ${envName})` };
  }
  return { headers, missing, description: type };
}

/**
 * 发送一次 HTTP 请求。
 *
 * @param {object} spec 请求描述
 * @param {string} spec.url 完整 URL
 * @param {string} spec.method 方法
 * @param {object} spec.headers 请求头
 * @param {any} spec.body 请求体
 * @param {number} spec.timeoutMs 超时
 * @param {number} spec.retries 重试次数（只对网络错误与超时重试）
 * @returns {Promise<{ok: boolean, observed?: object, error?: object}>}
 */
export async function performRequest(spec) {
  const timeoutMs = Number.isFinite(spec.timeoutMs) && spec.timeoutMs > 0 ? spec.timeoutMs : DEFAULT_TIMEOUT_MS;
  const retries = Number.isFinite(spec.retries) && spec.retries > 0 ? Math.floor(spec.retries) : DEFAULT_RETRIES;
  const method = String(spec.method || 'GET').toUpperCase();
  const headers = { ...(spec.headers || {}) };
  let body;
  if (spec.body !== undefined && spec.body !== null && method !== 'GET' && method !== 'HEAD') {
    if (typeof spec.body === 'string') {
      body = spec.body;
      if (!Object.keys(headers).some((key) => key.toLowerCase() === 'content-type')) {
        headers['content-type'] = 'application/json';
      }
    } else {
      body = JSON.stringify(spec.body);
      if (!Object.keys(headers).some((key) => key.toLowerCase() === 'content-type')) {
        headers['content-type'] = 'application/json';
      }
    }
  }
  let lastError = null;
  for (let attempt = 0; attempt <= retries; attempt += 1) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    const startedAt = Date.now();
    try {
      const response = await fetch(spec.url, {
        method,
        headers,
        body,
        signal: controller.signal,
      });
      const text = await response.text();
      clearTimeout(timer);
      const durationMs = Date.now() - startedAt;
      const headerMap = {};
      response.headers.forEach((value, key) => {
        headerMap[String(key).toLowerCase()] = value;
      });
      let parsed = text;
      const contentType = String(headerMap['content-type'] || '');
      if (contentType.includes('json')) {
        try {
          parsed = JSON.parse(text);
        } catch {
          parsed = text;
        }
      }
      return {
        ok: true,
        observed: {
          status_code: response.status,
          headers: headerMap,
          body: parsed,
          duration_ms: durationMs,
          url: spec.url,
          method,
        },
      };
    } catch (err) {
      clearTimeout(timer);
      const aborted = err && (err.name === 'AbortError' || err.name === 'TimeoutError');
      lastError = aborted
        ? { type: 'timeout', message: `请求超时（超过 ${timeoutMs} 毫秒）` }
        : { type: 'network_error', message: `请求失败: ${err && err.message ? err.message : String(err)}` };
      if (attempt < retries) await wait(50);
    }
  }
  return { ok: false, error: lastError };
}

/**
 * 生成复现命令里的鉴权片段。
 *
 * **只含环境变量名，不含凭证值**（需求 D19）：复现命令里写明文凭证 = 把凭证写进证据链，
 * 与"产物零凭证"直接冲突。代价是"带鉴权的用例不能照抄命令就跑通"，
 * 需要按环境变量名补上 —— 这是已知且被接受的限制。
 *
 * @param {object} auth 鉴权配置
 * @returns {string[]} curl 参数片段
 */
export function buildAuthCommand(auth) {
  if (!isObject(auth)) return [];
  const type = typeof auth.type === 'string' ? auth.type.trim().toLowerCase() : 'none';
  if (type === 'bearer') {
    const env = typeof auth.env === 'string' ? auth.env.trim() : '';
    if (!env) return [];
    return [`-H 'Authorization: Bearer \${${env}}'`];
  }
  if (type === 'basic') {
    const user = typeof auth.username_env === 'string' ? auth.username_env.trim() : '';
    const pass = typeof auth.password_env === 'string' ? auth.password_env.trim() : '';
    if (!user) return [];
    return [`-u '\${${user}}:\${${pass}}'`];
  }
  if (type === 'header') {
    const header = typeof auth.header === 'string' ? auth.header.trim() : '';
    const env = typeof auth.env === 'string' ? auth.env.trim() : '';
    if (!header || !env) return [];
    return [`-H '${header}: \${${env}}'`];
  }
  return [];
}

/**
 * 把一个请求描述成 "METHOD /path"。
 *
 * 执行计划里大多数 step 自带动作描述，但用例级载体那条路径下没有 ——
 * 那里这次请求就是"整个用例的那一次调用"。用请求本身描述它，
 * 保证"发出去的请求"不会因为没有描述而在复现信息里消失（需求 D21）。
 *
 * @param {object} request 请求配置
 * @returns {string}
 */
export function describeRequest(request) {
  const method = String((request && request.method) || 'GET')
    .trim()
    .toUpperCase() || 'GET';
  const rawPath = request && typeof request.path === 'string' ? request.path.trim() : '';
  return `${method} ${rawPath !== '' ? rawPath : '/'}`;
}

/**
 * 生成 curl 形式的复现命令。
 *
 * 凭证以环境变量名出现（`${TOKEN_ENV}`），**不写真实值**。
 *
 * @param {object} spec 请求描述
 * @returns {string}
 */
export function buildCurlCommand(spec) {
  const parts = [`curl -X ${String(spec.method || 'GET').toUpperCase()} '${spec.url}'`];
  for (const [key, value] of Object.entries(spec.headers || {})) {
    parts.push(`-H '${key}: ${value}'`);
  }
  for (const fragment of buildAuthCommand(spec.auth)) {
    parts.push(fragment);
  }
  if (spec.body !== undefined && spec.body !== null) {
    const body = typeof spec.body === 'string' ? spec.body : JSON.stringify(spec.body);
    parts.push(`-d '${body}'`);
  }
  return parts.join(' ');
}

/**
 * 按执行计划逐步发请求，如实报告每一步观察到什么。
 *
 * 计划由执行外壳给出（`context.steps`）：`[{step_index, request, action}]`，按顺序执行。
 * 本函数**不做任何判定**，只负责"跑"与"报告"（需求 F3 的分层）。
 *
 * @param {object} caseObj 用例
 * @param {object} context 执行上下文
 * @returns {Promise<object>}
 */
export async function executePlan(caseObj, context) {
  const plan = Array.isArray(context.steps) ? context.steps : [];
  const variables = context.variables || {};
  const steps = [];
  const commands = [];
  const executedActions = [];

  for (const item of plan) {
    const request = item.request || {};
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
    const content = `${JSON.stringify(
      {
        driver: context.driver_name,
        request: { method, path, url, auth_mode: auth.description },
        response: { status_code: observed.status_code, headers: observed.headers, body: observed.body },
      },
      null,
      2,
    )}\n`;
    steps.push({
      step_index: item.step_index,
      observed,
      evidence: [{ path: 'response.json', media_type: 'application/json', content }],
    });
    commands.push(
      buildCurlCommand({
        method,
        url,
        headers: request.headers || {},
        body,
        auth: context.auth,
      }),
    );
    if (typeof item.action === 'string' && item.action !== '') executedActions.push(item.action);
    else executedActions.push(describeRequest(request));
  }

  const last = steps.length > 0 ? steps[steps.length - 1] : null;
  const flatEvidence = [];
  for (const item of steps) {
    for (const evidence of item.evidence) flatEvidence.push(evidence);
  }
  return {
    steps,
    observed: last ? last.observed : null,
    evidence: flatEvidence,
    reproduction: {
      steps: executedActions,
      command: commands.length > 0 ? commands.join('\n') : null,
      expected: (Array.isArray(caseObj.steps) ? caseObj.steps : [])
        .map((step) => (step && typeof step.expected === 'string' ? step.expected : ''))
        .filter((item) => item !== '')
        .join('; '),
    },
  };
}
