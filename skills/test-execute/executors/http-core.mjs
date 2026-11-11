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
  if (spec.body !== undefined && spec.body !== null) {
    const body = typeof spec.body === 'string' ? spec.body : JSON.stringify(spec.body);
    parts.push(`-d '${body}'`);
  }
  return parts.join(' ');
}
