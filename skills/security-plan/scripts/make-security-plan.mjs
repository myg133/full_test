#!/usr/bin/env node
/**
 * make-security-plan.mjs —— 安全测试规划（主入口）。
 *
 * 用法:
 *   node scripts/make-security-plan.mjs \
 *     --context <安全上下文.json> \
 *     [--cases <功能用例集 cases.json>] \
 *     [--scan <扫描结果.json>] \
 *     [--environment <环境名>] \
 *     [--requirement <需求编号>] \
 *     --out-dir <目标项目根>
 *
 * 做什么:
 *   读安全上下文（+ 可选的功能用例集 / 依赖扫描结果），产出
 *   **威胁模型** + **权限矩阵** + **安全用例集** + **安全套件配置**：
 *
 *   <out-dir>/test-assets/security/
 *   ├── threat-model.json
 *   ├── matrix.json
 *   └── suites/SEC-<编号>-<短名>/{cases.json,suite.json}
 *
 * 退出码: 0 = 成功 / 1 = 输入非法或违反写入纪律 / 2 = 用法错误。
 *
 * 硬约束（契约 F1 / F7 / F8）:
 *   - **只读**输入：安全上下文 / 功能用例集 / 扫描结果一律不改写；
 *   - **只写** <out-dir>/test-assets/security/；产物已存在 ⇒ 报错退出（不覆盖）；
 *   - **幂等**：同一输入两次，除 meta.generated_at 外逐字相同；
 *   - **不执行**任何用例（安全用例的执行属后续 REQ；`security` 执行器尚未实现）；
 *   - **不跑**任何扫描器（扫描由 agent 用 qa-toolchain 跑完再喂进来）；
 *   - 零第三方依赖、不联网：只用 Node.js 内置模块。
 */

import path from 'node:path';
import process from 'node:process';

import { parseArgs, USAGE, UsageError } from './lib/cli.mjs';
import { InputError, readJsonFile } from './lib/io.mjs';
import { loadDimensionIds, loadMethodIds } from './lib/catalog.mjs';
import { readFunctionalCases, validateContext } from './lib/context.mjs';
import { noScan, parseScan } from './lib/scan.mjs';
import { deriveThreats } from './lib/threats.mjs';
import { deriveMatrix } from './lib/matrix.mjs';
import { deriveSuites, methodsForThreat } from './lib/cases.mjs';
import {
  assertWritable,
  buildMatrixDocument,
  buildSuiteDocument,
  buildThreatModel,
  resolveEnvironment,
  securityRootOf,
  writeProducts,
} from './lib/product.mjs';

/**
 * 主流程。
 * @returns {number} 退出码
 */
function main() {
  let options;
  try {
    options = parseArgs(process.argv.slice(2));
  } catch (err) {
    console.error(`[usage] ${err.message}`);
    console.error(USAGE);
    return 2;
  }
  if (options.help) {
    console.log(USAGE);
    return 0;
  }

  try {
    const contextFile = path.resolve(options.context);
    const outDir = path.resolve(options.outDir);
    const securityRoot = securityRootOf(outDir);

    // ① 读 + 校验安全上下文（结构层非法 ⇒ 报错退出，不留半份产物）
    const contextDoc = readJsonFile(contextFile, '安全上下文');
    const ctx = validateContext(contextDoc, contextFile);

    // ② 读功能用例集（可选）：只用于攻击面枚举的补充线索 + 用例 id 避让
    let functional = { ids: new Set(), actions: [], count: 0 };
    if (options.cases) {
      const casesFile = path.resolve(options.cases);
      const casesDoc = readJsonFile(casesFile, '功能用例集');
      functional = readFunctionalCases(casesDoc, casesFile);
    }

    // ③ 读扫描结果（可选）：三种合法形态；都识别不出来 ⇒ 输入非法
    const scan = options.scan
      ? parseScan(readJsonFile(path.resolve(options.scan), '扫描结果'), path.resolve(options.scan))
      : noScan();

    // ④ 方法库 / 维度库（唯一来源：test-case-design）—— 读不到就明确报错，不降级
    const methodIds = loadMethodIds();
    const dimensionIds = loadDimensionIds();
    if (!dimensionIds.includes('security')) {
      throw new InputError('覆盖维度库里没有 "security" 维度（唯一来源：test-case-design/references/dimensions.json）');
    }

    // ⑤ 派生：威胁 → 权限矩阵 → 安全用例
    const derived = deriveThreats(ctx, scan, functional);
    for (const threat of derived.threats) {
      for (const method of methodsForThreat(threat)) {
        if (!methodIds.includes(method)) {
          throw new InputError(`方法号 "${method}" 不在方法库里（唯一来源：test-case-design/references/methods.json）`);
        }
      }
    }
    const matrix = deriveMatrix(ctx, derived.threats);
    const usedIds = new Set(functional.ids);
    const generatedAt = new Date().toISOString();
    const suites = deriveSuites(ctx, derived.threats, { generatedAt, usedIds });

    // ⑥ 环境解析 + 写入纪律检查（**都在写盘之前** ⇒ 失败不留半份产物）
    const environment = resolveEnvironment(outDir, options.environment);
    assertWritable(securityRoot);

    // ⑦ 装配 + 写盘
    const requirement = options.requirement ? options.requirement : ctx.service.name;
    const threatModel = buildThreatModel(ctx, derived, scan, {
      generatedAt,
      contextFileName: path.basename(contextFile),
      functionalCaseCount: functional.count,
    });
    const matrixDoc = buildMatrixDocument(matrix, { generatedAt, service: ctx.service.name });
    writeProducts(securityRoot, {
      threatModel,
      matrix: matrixDoc,
      suites: suites.map((suite) => ({
        name: suite.name,
        casesDoc: suite.casesDoc,
        suiteDoc: buildSuiteDocument({ suiteName: suite.name, requirement, environment }),
      })),
    });

    // ⑧ 汇报
    const caseTotal = suites.reduce((sum, suite) => sum + suite.casesDoc.cases.length, 0);
    console.log(`[ok] 产物根: ${securityRoot}`);
    console.log(
      `[ok] 威胁 ${derived.threats.length} 条（OWASP 覆盖 ${Object.values(derived.owaspCoverage).filter((item) => item.status === 'covered').length} 类 / ` +
      `不适用 ${Object.values(derived.owaspCoverage).filter((item) => item.status === 'not_applicable').length} 类；` +
      `补充类 covered ${Object.values(derived.supplements).filter((item) => item.status === 'covered').length} 类 / ` +
      `不适用 ${Object.values(derived.supplements).filter((item) => item.status === 'not_applicable').length} 类）`,
    );
    console.log(
      `[ok] 权限矩阵: 角色 ${matrix.roles.length} × 资源 ${matrix.resources.length}，条目 ${matrix.entries.length} 条` +
      `（允许缺口 ${matrix.entries.filter((entry) => entry.basis === 'gap').length} 条）`,
    );
    console.log(
      `[ok] 安全用例 ${caseTotal} 条，套件 ${suites.length} 个（${suites.map((suite) => suite.name).join(' / ')}）`,
    );
    console.log(`[ok] 扫描: status=${scan.status}，finding ${scan.findings.length} 条`);
    return 0;
  } catch (err) {
    if (err instanceof UsageError) {
      console.error(`[usage] ${err.message}`);
      console.error(USAGE);
      return 2;
    }
    if (err instanceof InputError) {
      console.error(`[error] ${err.message}`);
      return 1;
    }
    console.error(`[error] unexpected: ${err && err.message ? err.message : String(err)}`);
    return 1;
  }
}

process.exitCode = main();
