// state-machine.mjs — 轮次状态机规则的**单一来源**
//
// 本文件是轮次状态相关规则的唯一定义处：
//   - 轮次状态枚举 / 阶段状态枚举 / 轮次范围枚举 / 轮次编号与类型枚举
//   - 状态转移表
//   - 终态判定
//   - `status` ↔ `history` 一致性判定
//   - 轮次状态相关的字段检查（供校验器与推进器共用）
//
// `scripts/cycle-state.mjs`（推进器）与 `scripts/verify-layout.mjs`（校验器）
// 都必须 import 本文件，不得各自再写一份转移表或终态判定。
// 两份实现一旦漂移，agent 就会开始"绕过脚本手改文件"，状态写入权的收口就白做了。
//
// 纯 Node.js，只依赖 node: 内置模块。只导出规则，不做任何 I/O。

// ---------------------------------------------------------------- 枚举

/** 轮次状态枚举（沿用 REQ-002B 契约） */
export const CYCLE_STATUSES = Object.freeze([
  'planned',
  'in_progress',
  'completed',
  'blocked',
  'cancelled',
]);

/** 阶段状态枚举（沿用 REQ-002B 契约） */
export const STAGE_STATUSES = Object.freeze([
  'pending',
  'in_progress',
  'done',
  'blocked',
  'skipped',
]);

/** 轮次覆盖的 scope 枚举 */
export const CYCLE_SCOPES = Object.freeze(['functional', 'security', 'load']);

/** 轮次编号枚举 */
export const ROUNDS = Object.freeze(['R1', 'R2', 'R3']);

/** 轮次类型枚举 */
export const ROUND_TYPES = Object.freeze(['new-requirement', 'regression', 'defect-verify']);

/** 终态：不可再离开 */
export const TERMINAL_STATUSES = Object.freeze(['completed', 'cancelled']);

/** history 每条记录必填的字段 */
export const HISTORY_REQUIRED_FIELDS = Object.freeze(['at', 'from', 'to', 'by']);

/** scopes_skipped 每条记录必填的字段 */
export const SKIP_RECORD_REQUIRED_FIELDS = Object.freeze(['scope', 'reason', 'at', 'by']);

// ---------------------------------------------------------------- 转移表

/**
 * 状态转移表：当前状态 → 允许到达的状态。
 * 终态对应空数组，表示不可离开。
 */
export const TRANSITIONS = Object.freeze({
  planned: Object.freeze(['in_progress', 'cancelled']),
  in_progress: Object.freeze(['completed', 'blocked', 'cancelled']),
  blocked: Object.freeze(['in_progress', 'cancelled']),
  completed: Object.freeze([]),
  cancelled: Object.freeze([]),
});

// ---------------------------------------------------------------- 判定

/**
 * 是否为合法的轮次状态取值。
 * @param {any} value 待判定值
 * @returns {boolean}
 */
export function isCycleStatus(value) {
  return typeof value === 'string' && CYCLE_STATUSES.includes(value);
}

/**
 * 是否为合法的阶段状态取值。
 * @param {any} value 待判定值
 * @returns {boolean}
 */
export function isStageStatus(value) {
  return typeof value === 'string' && STAGE_STATUSES.includes(value);
}

/**
 * 是否为终态（completed / cancelled）。
 * @param {any} status 轮次状态
 * @returns {boolean}
 */
export function isTerminalStatus(status) {
  return typeof status === 'string' && TERMINAL_STATUSES.includes(status);
}

/**
 * 当前状态允许的下一步状态。
 * @param {any} from 当前状态
 * @returns {string[]} 允许的下一步；当前状态非法或为终态时返回空数组
 */
export function allowedNext(from) {
  if (!isCycleStatus(from)) return [];
  return [...TRANSITIONS[from]];
}

/**
 * 是否允许这次转移。
 * @param {any} from 当前状态
 * @param {any} to 目标状态
 * @returns {boolean}
 */
export function canTransition(from, to) {
  if (!isCycleStatus(from) || !isCycleStatus(to)) return false;
  return TRANSITIONS[from].includes(to);
}

/**
 * 生成非法转移的诊断文案：问题说明 + 合法的下一步动作。
 * 校验器与推进器共用同一份文案，避免两边说法不一致。
 * @param {any} from 当前状态
 * @param {any} to 目标状态
 * @returns {string}
 */
export function transitionError(from, to) {
  if (isTerminalStatus(from)) {
    return (
      `非法转移 ${from} → ${to}：${from} 是终态，终态不可离开` +
      `（终态: ${TERMINAL_STATUSES.join(' / ')}）`
    );
  }
  const next = allowedNext(from);
  if (next.length === 0) {
    return (
      `非法转移 ${from} → ${to}：当前状态 "${from}" 不是合法的轮次状态` +
      `（允许值: ${CYCLE_STATUSES.join(' / ')}）`
    );
  }
  return (
    `非法转移 ${from} → ${to}：当前状态 ${from} 允许的下一步是 ${next.join(' / ')}` +
    `（终态 ${TERMINAL_STATUSES.join(' / ')} 不可离开）`
  );
}

/**
 * 判定 `status` 与 `history` 最后一条的 `to` 是否一致。
 * 判定规则只存在这一份：校验器与推进器都调用它。
 * @param {any} data cycle.json 解析结果
 * @returns {{status: string, lastTo: string, message: string}|null} 不一致时返回问题描述
 */
export function statusHistoryMismatch(data) {
  if (!isObject(data)) return null;
  const history = data.history;
  if (!Array.isArray(history) || history.length === 0) return null;
  const last = history[history.length - 1];
  if (!isObject(last)) return null;
  if (typeof data.status !== 'string' || typeof last.to !== 'string') return null;
  if (data.status === last.to) return null;
  return {
    status: data.status,
    lastTo: last.to,
    message:
      `status "${data.status}" 与 history 最后一条的 to "${last.to}" 不一致：` +
      '改状态时必须同时追加 history 记录',
  };
}

// ---------------------------------------------------------------- 轮次状态字段检查

/**
 * 检查 cycle.json 中与"状态机"相关的字段。
 * 校验器（verify-layout.mjs）与推进器（cycle-state.mjs）共用本函数，
 * 保证两边对同一份文件报出同一类问题。
 *
 * @param {any} data cycle.json 解析结果
 * @returns {{kind: string, path: string, text: string}[]} 问题列表
 */
export function checkCycleState(data) {
  const issues = [];
  if (!isObject(data)) return issues;

  // --- status ---
  if (data.status === undefined) {
    issues.push({
      kind: 'missing',
      path: 'status',
      text: 'status 缺少必填字段（轮次必须有当前状态）',
    });
  } else if (typeof data.status !== 'string') {
    issues.push({
      kind: 'type',
      path: 'status',
      text: `status 类型错误：期望 string，实际 ${describeType(data.status)}`,
    });
  } else if (!isCycleStatus(data.status)) {
    issues.push({
      kind: 'enum',
      path: 'status',
      text: `status 取值非法："${data.status}"（允许值: ${CYCLE_STATUSES.join(' / ')}）`,
    });
  }

  // --- history ---
  if (!Array.isArray(data.history)) {
    issues.push({
      kind: 'missing',
      path: 'history',
      text: 'history 缺少必填字段（或不是数组）：状态变更必须留痕',
    });
  } else if (data.history.length === 0) {
    issues.push({
      kind: 'missing',
      path: 'history',
      text: 'history 为空：至少需要一条状态变更记录，才能校验 status 与 history 的一致性',
    });
  } else {
    data.history.forEach((entry, index) => {
      const at = `history[${index}]`;
      if (!isObject(entry)) {
        issues.push({
          kind: 'type',
          path: at,
          text: `${at} 类型错误：期望 object，实际 ${describeType(entry)}`,
        });
        return;
      }
      for (const key of HISTORY_REQUIRED_FIELDS) {
        if (!isFilledString(entry[key])) {
          issues.push({
            kind: 'missing',
            path: `${at}.${key}`,
            text: `${at}.${key} 缺少必填字段（或不是非空字符串）：每次状态变更都要留痕`,
          });
        }
      }
      for (const key of ['from', 'to']) {
        if (isFilledString(entry[key]) && !isCycleStatus(entry[key])) {
          issues.push({
            kind: 'enum',
            path: `${at}.${key}`,
            text:
              `${at}.${key} 取值非法："${entry[key]}"` +
              `（允许值: ${CYCLE_STATUSES.join(' / ')}）`,
          });
        }
      }
    });
    const mismatch = statusHistoryMismatch(data);
    if (mismatch) {
      issues.push({ kind: 'consistency', path: 'status', text: mismatch.message });
    }
  }

  // --- stages ---
  if (data.stages !== undefined) {
    if (!isObject(data.stages)) {
      issues.push({
        kind: 'type',
        path: 'stages',
        text: `stages 类型错误：期望 object，实际 ${describeType(data.stages)}`,
      });
    } else {
      for (const [stage, body] of Object.entries(data.stages)) {
        const at = `stages.${stage}`;
        if (!isObject(body)) {
          issues.push({
            kind: 'type',
            path: at,
            text: `${at} 类型错误：期望 object，实际 ${describeType(body)}`,
          });
          continue;
        }
        if (typeof body.status === 'string' && !isStageStatus(body.status)) {
          issues.push({
            kind: 'enum',
            path: `${at}.status`,
            text:
              `${at}.status 取值非法："${body.status}"` +
              `（允许值: ${STAGE_STATUSES.join(' / ')}）`,
          });
        }
      }
    }
  }

  return issues;
}

// ---------------------------------------------------------------- 跳过记录检查

/**
 * 检查一条跳过记录（`scopes_skipped[]` 的元素）。
 * 校验器与推进器共用本函数，保证两边对同一条记录报出同一类问题。
 *
 * @param {any} entry 跳过记录
 * @param {string} at 字段路径前缀（如 `scopes_skipped[0]`）
 * @returns {{kind: string, path: string, text: string}[]} 问题列表
 */
export function checkSkipRecord(entry, at) {
  const issues = [];
  if (!isObject(entry)) {
    issues.push({
      kind: 'type',
      path: at,
      text: `${at} 类型错误：期望 object，实际 ${describeType(entry)}`,
    });
    return issues;
  }
  if (!isFilledString(entry.scope)) {
    issues.push({
      kind: 'missing',
      path: `${at}.scope`,
      text: `${at}.scope 缺少必填字段（或不是非空字符串）`,
    });
  } else if (!CYCLE_SCOPES.includes(entry.scope)) {
    issues.push({
      kind: 'enum',
      path: `${at}.scope`,
      text: `${at}.scope 取值非法："${entry.scope}"（允许值: ${CYCLE_SCOPES.join(' / ')}）`,
    });
  }
  if (!isFilledString(entry.reason)) {
    issues.push({
      kind: 'missing',
      path: `${at}.reason`,
      text: `${at}.reason 为空：跳过必须写明可被 review 发现的理由`,
    });
  }
  if (!isFilledString(entry.at)) {
    issues.push({
      kind: 'missing',
      path: `${at}.at`,
      text: `${at}.at 缺少必填字段（或不是非空字符串）：跳过记录必须可被审计（什么时候跳过的）`,
    });
  }
  if (!isFilledString(entry.by)) {
    issues.push({
      kind: 'missing',
      path: `${at}.by`,
      text: `${at}.by 缺少必填字段（或不是非空字符串）：跳过记录必须可被审计（谁跳过的）`,
    });
  }
  return issues;
}

/**
 * 检查 cycle.json 的 `scopes_skipped` 数组。
 * @param {any} data cycle.json 解析结果
 * @returns {{kind: string, path: string, text: string}[]} 问题列表
 */
export function checkScopesSkipped(data) {
  const issues = [];
  if (!isObject(data) || !Array.isArray(data.scopes_skipped)) return issues;
  data.scopes_skipped.forEach((entry, index) => {
    issues.push(...checkSkipRecord(entry, `scopes_skipped[${index}]`));
  });
  return issues;
}

// ---------------------------------------------------------------- 小工具

/**
 * 是否为非空字符串。
 * @param {any} value 待判定值
 * @returns {boolean}
 */
export function isFilledString(value) {
  return typeof value === 'string' && value.trim() !== '';
}

/**
 * 是否为普通对象（非 null、非数组）。
 * @param {any} value 待判定值
 * @returns {boolean}
 */
export function isObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * 描述值的类型，供诊断文案使用。
 * @param {any} value 待描述值
 * @returns {string}
 */
export function describeType(value) {
  if (value === null) return 'null';
  if (Array.isArray(value)) return 'array';
  if (typeof value === 'number') return Number.isInteger(value) ? 'integer' : 'number';
  if (typeof value === 'undefined') return 'undefined';
  return typeof value;
}
