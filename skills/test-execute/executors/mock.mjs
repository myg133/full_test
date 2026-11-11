// mock.mjs — 离线 mock 驱动（node 内置 http）
//
// 硬约束：本文件是 skill 的组成部分，agent 不得修改。
//         需要新的响应场景时走"提需求"，不要改这里 —— 见 executors/index.json 的 not_supported。
//
// 本驱动只报告"观察到什么"（observed），不做任何通过/失败判定。
// 判定规则是数据（用例 steps[].expected 里的断言对象），由执行外壳统一执行。
//
// 端点集固定，定义在 executors/mock-endpoints.json（数据，不在代码里）：
//   /ok        → 正常
//   /created   → 已创建
//   /notfound  → 未找到
//   /error     → 服务端错误
//   /echo      → 回显 {method, path, query, body}（不回显敏感请求头）
//   /token     → 含敏感字段的令牌响应（专门用来测脱敏）
//   /slow?ms=N → 延迟 N 毫秒后返回（用来测 timeout）
//   其他路径    → 未找到
//
// 注意：桩服务的响应**与断言无关**。把断言从期望"未找到"改成期望"正常"，
// 桩仍然按端点表返回 —— 这样"判定随断言变化"才验得出来；
// 若桩跟着断言变，判定永远成立，机制反而验不了。
//
// 纯 Node.js，只依赖 node: 内置模块。

import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { executePlan } from './http-core.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const endpointTable = JSON.parse(readFileSync(join(here, 'mock-endpoints.json'), 'utf8'));

/** 驱动名 */
export const name = 'mock';

/** 驱动版本 */
export const version = '1.0.0';

let server = null;
let serverUrl = null;

/**
 * 读取请求体。
 * @param {object} req 请求对象
 * @returns {Promise<string>}
 */
async function readRequestBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf8');
}

/**
 * 写 JSON 响应。
 * @param {object} res 响应对象
 * @param {number} status 状态码
 * @param {any} body 响应体
 * @param {object} headers 附加响应头
 */
function writeJson(res, status, body, headers = {}) {
  const payload = JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json', ...headers });
  res.end(payload);
}

/**
 * 处理 mock 请求。
 * @param {object} req 请求对象
 * @param {object} res 响应对象
 */
async function handle(req, res) {
  const url = new URL(req.url, 'http://127.0.0.1');
  const path = url.pathname;
  const endpoint = endpointTable.endpoints[path] || endpointTable.default;

  if (endpoint.dynamic === 'echo') {
    const raw = await readRequestBody(req);
    let body = raw;
    const contentType = String(req.headers['content-type'] || '');
    if (contentType.includes('json') && raw !== '') {
      try {
        body = JSON.parse(raw);
      } catch {
        body = raw;
      }
    }
    const query = {};
    url.searchParams.forEach((value, key) => {
      query[key] = value;
    });
    // 只回显 method / path / query / body：请求头里可能有凭证，不回显
    writeJson(res, endpoint.status, { method: req.method, path, query, body });
    return;
  }

  if (endpoint.dynamic === 'delay') {
    const raw = url.searchParams.get('ms');
    const asked = Number(raw);
    const limit = Number(endpointTable.limits && endpointTable.limits.max_delay_ms) || 60000;
    const delayMs = Number.isFinite(asked) && asked > 0 ? Math.min(asked, limit) : 0;
    await new Promise((resolve) => {
      // 定时器不持有事件循环：客户端超时走了之后，剩下的延迟不该拖住进程退出
      const timer = setTimeout(resolve, delayMs);
      if (typeof timer.unref === 'function') timer.unref();
    });
    writeJson(res, endpoint.status, endpoint.body || {});
    return;
  }

  writeJson(res, endpoint.status, endpoint.body || {});
}

/**
 * 启动内置 mock 服务（执行外壳在选中本驱动时调用）。
 *
 * @returns {Promise<{base_url: string}>}
 */
export async function start() {
  if (server) return { base_url: serverUrl };
  server = createServer((req, res) => {
    handle(req, res).catch(() => {
      try {
        // 兜底响应取自端点表，不在代码里写死状态码
        writeJson(res, endpointTable.default.status, endpointTable.default.body);
      } catch {
        res.end();
      }
    });
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const address = server.address();
  const port = address && typeof address === 'object' ? address.port : 0;
  serverUrl = `http://127.0.0.1:${port}`;
  return { base_url: serverUrl };
}

/**
 * 关闭内置 mock 服务（执行结束时调用）。
 *
 * 收尾必须让进程能退出：keep-alive 的空闲连接会让 `close()` 一直等下去，
 * 所以连同残留连接一起断开（需求 D30：进程必须在有限时间内退出）。
 */
export async function stop() {
  if (!server) return;
  const current = server;
  server = null;
  serverUrl = null;
  if (typeof current.closeAllConnections === 'function') {
    try {
      current.closeAllConnections();
    } catch {
      // 关不掉连接也不能让收尾失败 —— 继续关服务
    }
  }
  await new Promise((resolve) => {
    current.close(() => resolve());
  });
}

/**
 * 执行一条用例：按执行计划逐步向内置 mock 服务发真实 HTTP 请求，如实报告每一步观察到什么。
 *
 * @param {object} caseObj 用例
 * @param {object} context 执行上下文
 * @returns {Promise<object>}
 */
export async function run(caseObj, context) {
  const plan = Array.isArray(context.steps) ? context.steps : [];
  if (plan.length === 0) {
    return {
      error: {
        type: 'request_spec_missing',
        message:
          '用例没有可执行的步骤（既没有 case.request / case.data.request，' +
          '也没有能解析成 "METHOD /path" 的 step.request 或 step.action）',
      },
    };
  }
  return executePlan(caseObj, { ...context, driver_name: name });
}
