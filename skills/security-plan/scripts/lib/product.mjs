// product.mjs —— 产物装配与写盘纪律（契约 F1.5 / F2 / F4 / F6 / D98 / D115）
//
// 写盘纪律：
//   - **只写** <out-dir>/test-assets/security/；该路径之外一律只读；
//   - 产物已存在（threat-model.json / matrix.json / 任何 suites/* 目录）⇒ 报错退出 rc=1，不覆盖；
//   - 幂等：同一输入两次，除 meta.generated_at 外逐字相同（内容里没有随机量与其它时间戳）。

import path from 'node:path';

import { InputError, listDir, pathExists, writeJsonFileAtomic } from './io.mjs';

/** 产物根目录名（相对项目根）。 */
export const ASSETS_DIR = 'test-assets';
/** 安全资产目录名（相对项目根）。 */
export const SECURITY_DIR = 'security';

/**
 * 解析要写入的安全资产根目录。
 * @param {string} outDir 项目根
 * @returns {string} <out-dir>/test-assets/security 的绝对路径
 */
export function securityRootOf(outDir) {
  return path.join(path.resolve(outDir), ASSETS_DIR, SECURITY_DIR);
}

/**
 * 写入纪律检查：产物已存在即报错（**不得覆盖**）。
 * @param {string} securityRoot 安全资产根目录
 */
export function assertWritable(securityRoot) {
  const model = path.join(securityRoot, 'threat-model.json');
  if (pathExists(model)) {
    throw new InputError(
      `产物已存在，不得覆盖: ${model}（请换一个空的 --out-dir，或先自行移走已有产物）`,
    );
  }
  const matrix = path.join(securityRoot, 'matrix.json');
  if (pathExists(matrix)) {
    throw new InputError(
      `产物已存在，不得覆盖: ${matrix}（请换一个空的 --out-dir，或先自行移走已有产物）`,
    );
  }
  const suitesDir = path.join(securityRoot, 'suites');
  const existing = listDir(suitesDir);
  if (existing.length > 0) {
    throw new InputError(
      `产物已存在，不得覆盖: ${suitesDir} 下已有套件目录（${existing.join(' / ')}）`,
    );
  }
}

/**
 * 解析套件要引用的环境名。
 *
 * 缺省时取 `<out-dir>/test-assets/environments/` 下**按文件名排序的第一个**环境
 * （`_schema.json` 不是环境）；显式给了 `--environment` 就必须真实存在。
 *
 * @param {string} outDir 项目根
 * @param {string|null} requested 显式指定的环境名
 * @returns {string} 环境名
 */
export function resolveEnvironment(outDir, requested) {
  const envDir = path.join(path.resolve(outDir), ASSETS_DIR, 'environments');
  if (requested !== null && requested !== '') {
    const file = path.join(envDir, `${requested}.json`);
    if (!pathExists(file)) {
      throw new InputError(`环境定义不存在: ${file}（--environment 指定的 "${requested}" 在 ${envDir} 下没有同名文件）`);
    }
    return requested;
  }
  const files = listDir(envDir)
    .filter((name) => name.endsWith('.json') && name !== '_schema.json')
    .sort();
  if (files.length === 0) {
    throw new InputError(
      `找不到环境定义: ${envDir} 下没有任何环境文件（请提供 --environment 或先补齐环境定义）`,
    );
  }
  return files[0].replace(/\.json$/, '');
}

/**
 * 装配威胁模型文档。
 * @param {object} ctx 归一化后的上下文
 * @param {object} derived 派生结果（threats / owaspCoverage / supplements / openQuestions / scanFindings）
 * @param {object} scan 扫描摘要
 * @param {object} options 选项
 * @param {string} options.generatedAt 生成时间
 * @param {string} options.contextFileName 上下文文件名
 * @param {number} options.functionalCaseCount 功能用例条数（0 = 没传 --cases）
 * @returns {object} threat-model.json 文档
 */
export function buildThreatModel(ctx, derived, scan, options) {
  const scanSection = {
    status: scan.status,
    tool: scan.tool,
    source_file: scan.sourceFile ? path.basename(scan.sourceFile) : null,
    finding_count: scan.findings.length,
  };
  if (scan.reason) scanSection.reason = scan.reason;

  return {
    schema_version: 1,
    meta: {
      service: ctx.service.name,
      generated_at: options.generatedAt,
      threat_count: derived.threats.length,
      context_ref: options.contextFileName,
      functional_case_count: options.functionalCaseCount,
    },
    assets: ctx.assets.map((asset) => ({
      id: asset.id,
      name: asset.name,
      sensitivity: asset.sensitivity,
      description: asset.description,
    })),
    trust_boundaries: ctx.trustBoundaries.map((boundary) => ({
      id: boundary.id,
      name: boundary.name,
      controls: boundary.controls.slice(),
      from: boundary.from,
      to: boundary.to,
    })),
    entry_points: ctx.entryPoints.map((ep) => ({
      id: ep.id,
      name: ep.name,
      kind: ep.kind,
      asset_refs: ep.asset_refs.slice(),
      boundary_refs: ep.boundary_refs.slice(),
      description: ep.description,
    })),
    threats: derived.threats,
    owasp_coverage: derived.owaspCoverage,
    supplements: derived.supplements,
    scan: scanSection,
    scan_findings: derived.scanFindings,
    open_questions: derived.openQuestions,
  };
}

/**
 * 装配权限矩阵文档。
 * @param {object} matrix 矩阵内容（roles / resources / entries）
 * @param {object} options 选项
 * @param {string} options.generatedAt 生成时间
 * @param {string} options.service 服务名
 * @returns {object} matrix.json 文档
 */
export function buildMatrixDocument(matrix, options) {
  return {
    schema_version: 1,
    meta: {
      service: options.service,
      generated_at: options.generatedAt,
      entry_count: matrix.entries.length,
    },
    roles: matrix.roles,
    resources: matrix.resources,
    entries: matrix.entries,
  };
}

/**
 * 装配套件配置（suite.json）。
 *
 * ⚠️ 顶层字段集**封闭 9 个**（上游 verify-layout.mjs 对表外字段一律判 FAIL）：
 *   suite / requirement / scope / environment / cases_file / executor / base_url_from / tags / report
 *   —— **不得**出现 threat_model 之类的表外字段。
 *
 * @param {object} input 输入
 * @param {string} input.suiteName 套件目录名
 * @param {string} input.requirement 需求编号（缺省取 service.name）
 * @param {string} input.environment 环境名
 * @returns {object} suite.json 文档
 */
export function buildSuiteDocument(input) {
  return {
    suite: input.suiteName,
    requirement: input.requirement,
    scope: 'security',
    environment: input.environment,
    cases_file: 'cases.json',
    executor: 'security',
    tags: { include: ['security'], exclude: [] },
    report: {
      format: ['json', 'md'],
      output_dir: `.test-artifacts/security/${input.suiteName}`,
    },
  };
}

/**
 * 写盘：只写 <out-dir>/test-assets/security/ 下的产物。
 * @param {string} securityRoot 安全资产根目录
 * @param {object} products 待写产物
 * @param {object} products.threatModel threat-model.json 文档
 * @param {object} products.matrix matrix.json 文档
 * @param {object[]} products.suites 套件清单（每个含 name / casesDoc / suiteDoc）
 */
export function writeProducts(securityRoot, products) {
  for (const suite of products.suites) {
    const suiteDir = path.join(securityRoot, 'suites', suite.name);
    writeJsonFileAtomic(path.join(suiteDir, 'cases.json'), suite.casesDoc);
    writeJsonFileAtomic(path.join(suiteDir, 'suite.json'), suite.suiteDoc);
  }
  writeJsonFileAtomic(path.join(securityRoot, 'matrix.json'), products.matrix);
  writeJsonFileAtomic(path.join(securityRoot, 'threat-model.json'), products.threatModel);
}
