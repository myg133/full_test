// api.mjs — 真实 HTTP 驱动（node 内置 fetch）
//
// 硬约束：本文件是 skill 的组成部分，agent 不得修改。
//         换请求方式、加断言、改字段名 —— 全部由配置表达（见 executors/index.json）。
//
// 本驱动只报告"观察到了什么"（observed），不做任何通过/失败判定。
// 判定规则是数据（用例 steps[].expected 里的断言对象），由执行外壳统一执行。
//
// 逐步执行：一个用例的每个可执行 step 各发一次请求（计划由执行外壳给出），
// 每一步的 observed 单独回报，断言再由外壳绑定到各自所在 step 的响应。
//
// 纯 Node.js，只依赖 node: 内置模块。

import { executePlan } from './http-core.mjs';

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
 * 执行一条用例：按执行计划逐步打真实 HTTP，如实报告每一步观察到什么。
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
          '也没有能解析成 "METHOD /path" 的 step.request 或 step.action）：' +
          '真实 HTTP 驱动不知道该打哪个地址',
      },
    };
  }
  return executePlan(caseObj, { ...context, driver_name: name });
}
