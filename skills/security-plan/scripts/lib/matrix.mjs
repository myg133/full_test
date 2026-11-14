// matrix.mjs —— 权限矩阵派生（角色 × 资源 × 动作）
//
// 契约（F4 / D105 / D106）：
//   - roles / resources 与上下文对应段**集合相等**；
//   - entries 非空；每个 (role, resource) 组合**至少**一条记录；
//   - entries[].role / resource 不悬空；action 非空；decision ∈ {allow, deny}；
//     basis ∈ {expected, gap}；
//   - basis == 'expected' ⇒ threat_ref 必须为 null；
//     basis == 'gap' ⇒ decision 必须为 'allow' 且 threat_ref 指向一条
//     category == 'elevation_of_privilege' 的威胁；
//   - **双向**：每条越权类威胁都必须被至少一条 gap 条目引用。
//
// 矩阵只登记「**由上下文可推导**」的现状；上下文没给的（例如写操作）一律按
// **更安全的一侧**记录，并在 note 里写明这是待人工确认的假设（不臆造事实）。

import { isCredentialAsset, roleLevel } from './threats.mjs';

/** 矩阵动作集。 */
export const MATRIX_ACTIONS = Object.freeze(['read', 'write']);

/**
 * 派生权限矩阵。
 * @param {object} ctx 归一化后的安全上下文
 * @param {object[]} threats 威胁清单
 * @returns {{roles: object[], resources: object[], entries: object[]}}
 */
export function deriveMatrix(ctx, threats) {
  const credentialAssetIds = new Set(
    ctx.assets.filter((asset) => isCredentialAsset(asset)).map((asset) => asset.id),
  );
  const credentialResourceIds = new Set(
    ctx.resources
      .filter((resource) => resource.asset_refs.some((id) => credentialAssetIds.has(id)))
      .map((resource) => resource.id),
  );
  const authzThreats = threats.filter((threat) => threat.category === 'elevation_of_privilege');
  const authzThreat = authzThreats.length > 0 ? authzThreats[0] : null;

  const entries = [];
  for (const role of ctx.roles) {
    const level = roleLevel(role);
    for (const resource of ctx.resources) {
      const isCredential = credentialResourceIds.has(resource.id);
      for (const action of MATRIX_ACTIONS) {
        entries.push(buildEntry({
          role,
          resource,
          action,
          level,
          isCredential,
          authzThreat,
          ctx,
        }));
      }
    }
  }

  return {
    roles: ctx.roles.map((role) => ({ id: role.id, name: role.name })),
    resources: ctx.resources.map((resource) => ({ id: resource.id, name: resource.name })),
    entries,
  };
}

/**
 * 构造一条矩阵记录。
 * @param {object} input 输入参数
 * @returns {object} 矩阵条目
 */
function buildEntry({ role, resource, action, level, isCredential, authzThreat, ctx }) {
  const base = {
    role: role.id,
    resource: resource.id,
    action,
    decision: 'deny',
    basis: 'expected',
    threat_ref: null,
    note: '',
  };

  if (level === 'anonymous') {
    base.decision = 'deny';
    base.basis = 'expected';
    base.note = '未认证身份不应访问该资源';
    return base;
  }

  if (level === 'admin') {
    base.decision = 'allow';
    base.basis = 'expected';
    base.note = '管理员按职责可访问该资源';
    return base;
  }

  // 普通业务角色
  if (isCredential && action === 'read') {
    base.decision = 'allow';
    base.basis = 'gap';
    base.threat_ref = authzThreat ? authzThreat.id : null;
    base.note = authzThreat
      ? `只校验登录态、未校验归属 ⇒ 本应拒绝（越权读取他人「${resource.name}」）`
      : '只校验登录态、未校验归属 ⇒ 本应拒绝（越权读取他人资源）';
    return base;
  }

  if (isCredential && action === 'write') {
    base.decision = 'deny';
    base.basis = 'expected';
    base.note = `凭据类资源不应由普通角色写入（按更安全的一侧记录；若实际可写，需要补一条缺口）`;
    return base;
  }

  base.decision = 'allow';
  base.basis = 'expected';
  base.note = `普通角色按业务归属可访问「${resource.name}」（归属校验是否落地需人工确认）`;
  return base;
}

/**
 * 矩阵的自洽自检（供 check-security-plan.mjs 复用）。
 * @param {object} matrix 矩阵文档
 * @param {object[]} threats 威胁清单
 * @returns {string[]} 问题清单（空数组 = 自洽）
 */
export function checkMatrix(matrix, threats) {
  const problems = [];
  const roleIds = new Set((matrix.roles || []).map((role) => role.id));
  const resourceIds = new Set((matrix.resources || []).map((resource) => resource.id));
  const threatIds = new Set(threats.map((threat) => threat.id));
  const threatById = new Map(threats.map((threat) => [threat.id, threat]));
  const entries = Array.isArray(matrix.entries) ? matrix.entries : [];

  if (entries.length === 0) problems.push('entries 为空');

  const pairs = new Set();
  for (const [index, entry] of entries.entries()) {
    const at = `entries[${index}]`;
    if (!roleIds.has(entry.role)) problems.push(`${at}.role 悬空引用: "${entry.role}"`);
    if (!resourceIds.has(entry.resource)) problems.push(`${at}.resource 悬空引用: "${entry.resource}"`);
    if (typeof entry.action !== 'string' || entry.action.trim() === '') {
      problems.push(`${at}.action 必须是非空字符串`);
    }
    if (entry.decision !== 'allow' && entry.decision !== 'deny') {
      problems.push(`${at}.decision 取值非法: ${JSON.stringify(entry.decision)}`);
    }
    if (entry.basis !== 'expected' && entry.basis !== 'gap') {
      problems.push(`${at}.basis 取值非法: ${JSON.stringify(entry.basis)}`);
    }
    if (entry.basis === 'expected') {
      if (entry.threat_ref !== null) {
        problems.push(`${at} 的 basis 是 expected，threat_ref 必须为 null`);
      }
    } else if (entry.basis === 'gap') {
      if (entry.decision !== 'allow') {
        problems.push(`${at} 的 basis 是 gap，decision 必须是 allow`);
      }
      if (typeof entry.threat_ref !== 'string' || entry.threat_ref.trim() === '') {
        problems.push(`${at} 的 basis 是 gap，threat_ref 必须非空`);
      } else if (!threatIds.has(entry.threat_ref)) {
        problems.push(`${at}.threat_ref 悬空引用: "${entry.threat_ref}"`);
      } else if (threatById.get(entry.threat_ref).category !== 'elevation_of_privilege') {
        problems.push(`${at}.threat_ref 指向的威胁不是越权类（category != elevation_of_privilege）`);
      }
    }
    pairs.add(`${entry.role}|${entry.resource}`);
  }

  for (const role of matrix.roles || []) {
    for (const resource of matrix.resources || []) {
      if (!pairs.has(`${role.id}|${resource.id}`)) {
        problems.push(`(role, resource) 组合 (${role.id}, ${resource.id}) 没有任何 entries 记录`);
      }
    }
  }

  const referenced = new Set(
    entries.filter((entry) => entry.basis === 'gap').map((entry) => entry.threat_ref),
  );
  for (const threat of threats) {
    if (threat.category !== 'elevation_of_privilege') continue;
    if (!referenced.has(threat.id)) {
      problems.push(`越权类威胁 ${threat.id} 没有被任何 basis == "gap" 的条目引用`);
    }
  }

  return problems;
}
