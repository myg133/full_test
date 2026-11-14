// cases.mjs —— 从威胁派生安全用例（cases.json v2，**顶层封闭 7 个**）
//
// 契约（F5 / D107~D109 / D124 / D125）：
//   - 每条威胁**至少**派生 1 条用例；同一威胁下的用例 title 互不相同、steps 不完全相同；
//   - requirements[].source_ref **恰为** "threat-model.json#/threats/<TH-id>"；
//   - coverage_matrix[] 每个 requirement 出现且只出现一次；
//   - cases[].id 合 ^TC-\d{3}$、跨全部套件**全局唯一**、不与输入用例集冲突；
//   - cases[].dimension 恒为 "security"；cases[].status 恒为 "active"（且不带 revision）；
//   - cases[].method[] 每个方法号必须**真的存在于**方法库（上游只查格式，不查存在性）；
//   - cases[].tags 含 "security" 与该威胁的 id。
//
// 套件怎么分组由实现决定（D110）：本实现按 **OWASP 类**分组 —— 一个类一个套件，
// 目录名 SEC-<编号>-<短名>。

import { OWASP_NAMES } from './catalog.mjs';

/** 产物 cases.json 的顶层字段集（封闭 7 个，顺序即写盘顺序）。 */
export const CASES_TOP_LEVEL_FIELDS = Object.freeze([
  'schema_version',
  'meta',
  'requirements',
  'open_questions',
  'coverage_matrix',
  'defects',
  'cases',
]);

/** 套件短名（OWASP 类 → 目录名后缀）。 */
export const SUITE_SLUGS = Object.freeze({
  A01: 'access-control',
  A02: 'cryptography',
  A03: 'injection',
  A04: 'insecure-design',
  A05: 'misconfiguration',
  A06: 'vulnerable-components',
  A07: 'authentication',
  A08: 'integrity',
  A09: 'logging',
  A10: 'ssrf',
});

/**
 * 分配一个用例 id（形如 TC-001；跳过输入用例集已占用的号与已分配的号）。
 * @param {Set<string>} used 已占用 / 已禁用的 id 集合（会被就地更新）
 * @returns {string} 新的用例 id
 */
export function allocateCaseId(used) {
  for (let number = 1; number <= 999; number += 1) {
    const candidate = `TC-${String(number).padStart(3, '0')}`;
    if (!used.has(candidate)) {
      used.add(candidate);
      return candidate;
    }
  }
  throw new Error('用例编号已用尽（^TC-\\d{3}$ 最多 999 个）');
}

/**
 * 这条威胁该用哪些方法（方法号必须存在于方法库）。
 * @param {object} threat 威胁
 * @returns {string[]} 方法号
 */
export function methodsForThreat(threat) {
  const methods = ['M2.1'];
  if (['tampering', 'information_disclosure', 'spoofing'].includes(threat.category)) {
    methods.push('M2.2');
  }
  if (
    threat.supplement_refs.includes('xxe') ||
    threat.supplement_refs.includes('deserialization') ||
    threat.category === 'denial_of_service'
  ) {
    methods.push('M2.3');
  }
  return methods;
}

/**
 * 威胁 → 用例步骤。
 *
 * ⚠️ `expected` 写的是**安全期望**（被拒绝 / 被限流 / 不泄漏）：执行时观察到相反
 * 行为即判 failed。规划阶段不臆断「当前一定是坏的」。
 *
 * @param {object} threat 威胁
 * @param {object} ctx 归一化后的上下文
 * @param {'attack'|'fuzz'} variant 变体
 * @returns {object[]} steps
 */
export function stepsForThreat(threat, ctx, variant) {
  const epIds = threat.entry_point_refs;
  const eps = epIds.map((id) => ctx.entryPoints.find((ep) => ep.id === id)).filter(Boolean);
  const epLabel = eps.length > 0
    ? eps.map((ep) => (ep.description ? `${ep.name}（${ep.description}）` : ep.name)).join(' / ')
    : '相关入口点';
  const assetIds = threat.asset_refs;
  const assets = assetIds.map((id) => ctx.assets.find((asset) => asset.id === id)).filter(Boolean);
  const assetLabel = assets.length > 0
    ? assets.map((asset) => `${asset.name}（${asset.id}）`).join('、')
    : '相关资产';

  if (variant === 'fuzz') {
    return [
      {
        action: `对 ${epLabel} 持续投递结构畸形的输入（缺字段、类型错乱、超长嵌套、重复键、非法字符）`,
        expected: '服务保持可用并返回统一错误响应；不出现 5xx 堆栈、内部路径泄露、进程崩溃或数据被写坏',
      },
    ];
  }

  switch (threat.category) {
    case 'spoofing':
      return [
        {
          action: `用错误口令对 ${epLabel} 连续发起 10 次登录请求`,
          expected: '第 10 次起请求被拒绝或触发账号锁定与速率限制；响应不泄露账户是否存在',
        },
        {
          action: `用他人签发或已过期的令牌访问 ${epLabel}`,
          expected: '请求被拒绝（401/403），且响应不泄露令牌校验细节与签发逻辑',
        },
      ];
    case 'tampering':
      return [
        {
          action: `向 ${epLabel} 提交注入 / 篡改载荷（' OR 1=1 --、../../etc/passwd、超长字符串、重复参数）`,
          expected: '载荷被拒绝或按白名单规范化；服务不执行注入载荷，不出现 5xx 与内部堆栈',
        },
      ];
    case 'repudiation':
      return [
        {
          action: `以不同角色各执行一次关键操作，随后查询 ${assetLabel} 对应的审计留痕`,
          expected: '每次关键操作在审计留痕中都有对应记录（角色、时间、对象、结果）；普通角色无法修改或删除该记录',
        },
      ];
    case 'information_disclosure':
      return [
        {
          action: `向 ${epLabel} 提交异常参数并观察响应体、响应头与错误页`,
          expected: '响应体只返回统一错误信息，不含堆栈、SQL、内部路径、密钥或服务端可达地址',
        },
      ];
    case 'denial_of_service':
      return [
        {
          action: `向 ${epLabel} 连续发起高并发与超大请求体`,
          expected: '服务按限流策略拒绝或降级，不出现资源耗尽、进程崩溃与数据不一致',
        },
      ];
    case 'elevation_of_privilege':
      return [
        {
          action: `以普通业务角色访问 / 写入他人的 ${assetLabel}`,
          expected: '越权访问被拒绝（403），响应不含他人数据；同一口径下角色本人访问自己数据仍然成功',
        },
      ];
    default:
      return [
        {
          action: `对 ${epLabel} 发起一次未授权的访问尝试，观察服务对 ${assetLabel} 的处理`,
          expected: '请求被拒绝且不泄露内部信息；服务状态与数据保持一致',
        },
      ];
  }
}

/**
 * 从威胁派生套件（每个 OWASP 类一个套件）。
 *
 * @param {object} ctx 归一化后的安全上下文
 * @param {object[]} threats 威胁清单
 * @param {object} options 选项
 * @param {string} options.generatedAt 生成时间
 * @param {Set<string>} options.usedIds 用例 id 占用集合（会被更新）
 * @returns {object[]} 套件清单
 */
export function deriveSuites(ctx, threats, options) {
  const { generatedAt, usedIds } = options;
  const groups = new Map();
  for (const threat of threats) {
    if (!groups.has(threat.owasp)) groups.set(threat.owasp, []);
    groups.get(threat.owasp).push(threat);
  }
  const codes = [...groups.keys()].sort();
  const suites = [];

  codes.forEach((code, groupIndex) => {
    const group = groups.get(code);
    const slug = SUITE_SLUGS[code] || code.toLowerCase();
    const suiteName = `SEC-${String(groupIndex + 1).padStart(3, '0')}-${slug}`;

    const requirements = [];
    const coverageMatrix = [];
    const cases = [];
    const usedTitles = new Set();

    group.forEach((threat, threatIndex) => {
      const requirementId = `R-${threatIndex + 1}`;
      requirements.push({
        id: requirementId,
        title: `${threat.id} ${threat.name}`,
        source_ref: `threat-model.json#/threats/${threat.id}`,
        testable: true,
      });

      const methods = methodsForThreat(threat);
      coverageMatrix.push({
        requirement: requirementId,
        methods_applied: methods.slice(),
        skipped: [],
        dimensions: ['security'],
      });

      const variants = ['attack'];
      if (['tampering', 'information_disclosure', 'denial_of_service'].includes(threat.category)) {
        variants.push('fuzz');
      }
      variants.forEach((variant, variantIndex) => {
        const baseTitle = variantIndex === 0
          ? threat.name
          : `${threat.name}（畸形输入与边界值）`;
        let title = baseTitle;
        if (usedTitles.has(title)) title = `${baseTitle}（${threat.id}）`;
        usedTitles.add(title);

        const tags = ['security', threat.id, `owasp-${threat.owasp.toLowerCase()}`];
        for (const supplement of threat.supplement_refs) tags.push(`supplement-${supplement}`);

        cases.push({
          id: allocateCaseId(usedIds),
          title,
          requirement_refs: [requirementId],
          dimension: 'security',
          priority: priorityFor(threat.severity),
          method: methods.slice(),
          status: 'active',
          preconditions: [],
          steps: stepsForThreat(threat, ctx, variant),
          data: {},
          tags,
        });
      });
    });

    suites.push({
      name: suiteName,
      owasp: code,
      owaspName: OWASP_NAMES[code] || code,
      casesDoc: {
        schema_version: 2,
        meta: {
          source: 'security-plan',
          generated_at: generatedAt,
          case_count: cases.length,
          suite: suiteName,
          threat_count: group.length,
        },
        requirements,
        open_questions: [],
        coverage_matrix: coverageMatrix,
        defects: [],
        cases,
      },
    });
  });

  return suites;
}

/**
 * 严重度 → 优先级。
 * @param {string} severity 严重度
 * @returns {string} P0~P3
 */
export function priorityFor(severity) {
  if (severity === 'critical' || severity === 'high') return 'P0';
  if (severity === 'medium') return 'P1';
  return 'P2';
}
