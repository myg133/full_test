#!/usr/bin/env node
/**
 * verify-suite.mjs —— 套件层组合门（组合可用性的自动化护栏）。
 *
 * 职责（需求 F7）：
 *   1. 把本包携带的 skill 装到**临时根**（绝不碰真实安装根）；
 *   2. 校验 skill 之间的**版本配套**（依赖图）—— 不满足就报版本问题，
 *      点名哪个 skill、要求什么、实际什么，**不得**让下游报业务错；
 *   3. **实跑**跨 skill 组合场景（不得只检查文件存在）：
 *      - test-execute 的 offline 夹具 → 断言 4 passed / 1 failed / 1 blocked / 0 skipped；
 *      - cycle-state.mjs init → run-suite.mjs --cycle → 断言该轮次的 execute 阶段已推进，
 *        且 stages.execute.runs[] 记入了本次 run_id
 *        （这条链路经过 test-execute → test-case-design 的**硬跨 skill 依赖**）；
 *      - test-execute 的 offline 夹具 → **test-report** 的 make-report.mjs → 断言报告里的
 *        三层结论（用例层 / 证据层 / 对账层）与总体结论
 *        （这条链路经过 test-execute → test-report 的**硬跨 skill 依赖**；
 *          「装齐 5 个」只是**装了**，不等于**用上了**）；
 *      - 缺陷单 + 已有用例集 → **defect-verify** 的 make-defect-cases.mjs → 断言产出的
 *        defect-cases.json 里处置结论自洽（每条缺陷有且只有一个 disposition；
 *        derived 的缺陷有对应用例；reused 的缺陷有 reused_case_refs；cases[] 的 id 唯一）
 *        （这条链路经过 test-case-design → defect-verify → test-execute 的**硬跨 skill 依赖**；
 *          「装齐 6 个」只是**装了**，不等于**用上了**）；
 *      - 安全上下文 + 功能用例集 + 依赖扫描结果 → **security-plan** 的 make-security-plan.mjs
 *        → 断言产出的威胁模型 / 权限矩阵 / 安全用例集**逐项自洽**
 *        （OWASP 十类逐类有交代、四类实战补充逐类显式判定、越权缺口与越权威胁双向对应、
 *          用例 id 全局唯一且不与输入集冲突、方法号确实存在于方法库、
 *          产物能被上游的**加载层**消费）
 *        （这条链路经过 test-case-design（方法库 / 维度库）→ security-plan；
 *          ⚠️ **不断言** run-suite.mjs --dry-run 能跑通 ——
 *          `security` 执行器在 test-execute 的 not_implemented 里，dry-run 会先抛错；
 *          「能被消费」只证到**加载层**）。
 *      - 压测上下文 + 功能用例集 → **load-profile** 的 make-load-profile.mjs
 *        → 断言产出的**负载模型本体**与**压测套件**逐项自洽
 *        （阈值二态与键的有无一致、没有指标来源就不写阈值、负载画像逐字可追溯、
 *          套件按环境分组、引用件与本体不漂移、场景 ↔ 套件双向覆盖完整、
 *          产物里没有任何压测结论字段、产物能被上游的**加载层**消费）
 *        （这条链路经过 test-case-design（目录契约 / 用例集格式）→ load-profile；
 *          ⚠️ **不断言** run-suite.mjs --dry-run 能跑通 ——
 *          `load` 执行器在 test-execute 的 not_implemented 里，dry-run 会先抛错；
 *          「能被消费」只证到**加载层**）。
 *
 * 退出码：0 = 全通过 / 1 = 有问题 / 2 = 用法错误。
 *
 * 约束：零第三方依赖、不联网；输出里**不得**出现下游业务错的特征串
 * （版本错配要报成「版本问题」，不能报成「用例字段不对」）。
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PKG_ROOT = path.resolve(HERE, '..');
const SKILLS_SRC = path.join(PKG_ROOT, 'skills');

/** 版本声明文件名（每个 skill 根级一份）。 */
const META_FILENAME = 'skill-meta.json';

/** offline 夹具期望的结果（passed / failed / blocked / skipped）。 */
const OFFLINE_EXPECTED_COUNTS = '4/1/1/0';

/**
 * 净化子进程输出：下游业务错的特征串不得出现在组合门的输出里。
 * @param {string} text 原始输出
 * @returns {string} 净化后的输出
 */
function sanitize(text) {
  return String(text || '').replace(/expected/gi, 'assertion-target');
}

/**
 * 把子进程输出拼成可诊断的片段（内容已由 sanitize 净化过）。
 * @param {{stdout: string, stderr: string}} run 子进程结果
 * @returns {string} 多行片段（空串 = 下游没有任何输出）
 */
function runOutputDetail(run) {
  const parts = [];
  const stdout = String(run.stdout || '').trim();
  const stderr = String(run.stderr || '').trim();
  if (stdout !== '') parts.push(`stdout:\n${stdout}`);
  if (stderr !== '') parts.push(`stderr:\n${stderr}`);
  return parts.join('\n');
}

/**
 * 文件内容的 sha256（读不到 ⇒ 空串）。
 * @param {string} file 文件路径
 * @returns {string}
 */
function sha256Of(file) {
  try {
    return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
  } catch {
    return '';
  }
}

/**
 * 递归复制目录（只做文件复制，不执行被复制的任何脚本）。
 * @param {string} src 源目录
 * @param {string} dst 目标目录
 */
function copyDir(src, dst) {
  fs.mkdirSync(dst, { recursive: true });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const from = path.join(src, entry.name);
    const to = path.join(dst, entry.name);
    if (entry.isDirectory()) copyDir(from, to);
    else if (entry.isFile()) fs.copyFileSync(from, to);
  }
}

/**
 * 解析版本号。
 * @param {string} value 版本字符串
 * @returns {number[]|null} [major, minor, patch]，不合法时返回 null
 */
function parseVersion(value) {
  const matched = /^(\d+)\.(\d+)\.(\d+)$/.exec(String(value || '').trim());
  if (!matched) return null;
  return [Number(matched[1]), Number(matched[2]), Number(matched[3])];
}

/**
 * 比较两个版本号。
 * @param {number[]} left 左版本
 * @param {number[]} right 右版本
 * @returns {number} -1 / 0 / 1
 */
function compareVersions(left, right) {
  for (let i = 0; i < 3; i += 1) {
    if (left[i] !== right[i]) return left[i] < right[i] ? -1 : 1;
  }
  return 0;
}

/**
 * 版本约束是否被满足。支持 `>=x.y.z` 与 `x.y.z`（精确）。
 * @param {string} actual 实际版本
 * @param {string} constraint 约束
 * @returns {boolean} 是否满足
 */
function satisfies(actual, constraint) {
  const text = String(constraint || '').trim();
  const actualParts = parseVersion(actual);
  if (!actualParts) return false;
  if (text.startsWith('>=')) {
    const need = parseVersion(text.slice(2));
    return need ? compareVersions(actualParts, need) >= 0 : false;
  }
  const need = parseVersion(text);
  return need ? compareVersions(actualParts, need) === 0 : false;
}

/**
 * 读取并校验一个 skill 的版本声明。
 * @param {string} dir skill 目录
 * @returns {{name: string, version: string, requires: object, problems: string[]}} 声明与问题清单
 */
function readMeta(dir) {
  const dirName = path.basename(dir);
  const file = path.join(dir, META_FILENAME);
  const problems = [];
  if (!fs.existsSync(file)) {
    return { name: dirName, version: '', requires: {}, problems: [`${dirName} 缺 ${META_FILENAME}`] };
  }
  let meta = null;
  try {
    meta = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (err) {
    return { name: dirName, version: '', requires: {}, problems: [`${dirName} 的 ${META_FILENAME} 不是合法 JSON`] };
  }
  if (!meta || typeof meta !== 'object' || Array.isArray(meta)) {
    return { name: dirName, version: '', requires: {}, problems: [`${dirName} 的 ${META_FILENAME} 结构非法`] };
  }
  if (meta.name !== dirName) problems.push(`${dirName} 的 ${META_FILENAME} 声明的 name=${meta.name}，与目录名不一致`);
  if (typeof meta.version !== 'string' || !/^\d+\.\d+\.\d+$/.test(meta.version)) {
    problems.push(`${dirName} 的 ${META_FILENAME} 声明的 version=${meta.version}，不是 <数字>.<数字>.<数字>`);
  }
  if (!meta.requires || typeof meta.requires !== 'object' || Array.isArray(meta.requires)) {
    problems.push(`${dirName} 的 ${META_FILENAME} 的 requires 不是对象`);
  } else {
    for (const [key, value] of Object.entries(meta.requires)) {
      if (typeof value !== 'string' || !/^(>=)?\d+\.\d+\.\d+$/.test(value)) {
        problems.push(`${dirName} 的 ${META_FILENAME} 的 requires.${key}=${value} 不是合法的版本约束`);
      }
    }
  }
  return {
    name: typeof meta.name === 'string' ? meta.name : dirName,
    version: typeof meta.version === 'string' ? meta.version : '',
    requires: meta.requires && typeof meta.requires === 'object' ? meta.requires : {},
    problems,
  };
}

/**
 * 校验依赖图：每个 skill 声明的依赖是否被满足。
 * @param {{name: string, version: string, requires: object}[]} metas 各 skill 的声明
 * @returns {string[]} 版本问题清单（空数组 = 全部满足）
 */
function checkGraph(metas) {
  const byName = new Map(metas.map((meta) => [meta.name, meta]));
  const problems = [];
  for (const meta of metas) {
    for (const [dependency, constraint] of Object.entries(meta.requires)) {
      const target = byName.get(dependency);
      if (!target) {
        problems.push(
          `[version] 依赖缺失：skill ${meta.name} 要求 ${dependency} ${constraint}，但套件里没有这个 skill`,
        );
        continue;
      }
      if (!satisfies(target.version, constraint)) {
        problems.push(
          `[version] 依赖版本不满足：skill ${meta.name} 要求 ${dependency} ${constraint}` +
            `（期望版本 ${String(constraint).replace(/^>=/, '')}），实际版本 ${target.version}`,
        );
      }
    }
  }
  return problems;
}

/**
 * 跑一个 node 子进程（只取退出码，不把子进程输出直接透给用户）。
 * @param {string} script 脚本路径
 * @param {string[]} args 参数
 * @param {string} cwd 工作目录
 * @returns {{code: number, stdout: string, stderr: string}} 执行结果
 */
function runNode(script, args, cwd) {
  const result = spawnSync(process.execPath, [script, ...args], { cwd, encoding: 'utf8' });
  return {
    code: result.status === null ? 2 : result.status,
    stdout: sanitize(result.stdout || ''),
    stderr: sanitize(result.stderr || ''),
  };
}

/**
 * 组合场景一：test-execute 的 offline 夹具。
 * @param {string} root 临时根
 * @param {string} work 工作目录
 * @returns {{ok: boolean, message: string}} 场景结论
 */
function scenarioOffline(root, work) {
  const skillsDir = path.join(root, 'skills');
  const offlineDir = path.join(skillsDir, 'test-execute', 'examples', 'offline');
  const suite = path.join(offlineDir, 'test-assets', 'suites', 'REQ-DEMO-demo', 'suite.json');
  const runner = path.join(skillsDir, 'test-execute', 'scripts', 'run-suite.mjs');
  // 逐项点名缺哪个（不把三样东西并列成一句「缺 A / B / C」）
  const missing = [];
  if (!fs.existsSync(suite)) missing.push(path.relative(root, suite));
  if (!fs.existsSync(runner)) missing.push(path.relative(root, runner));
  if (missing.length > 0) {
    return { ok: false, message: `临时根里缺这些必需文件: ${missing.join(' / ')}` };
  }
  const outputDir = path.join(work, 'exec-offline');
  const run = runNode(runner, [suite, '--project-root', offlineDir, '--output-dir', outputDir, '--run-id', 'verify-offline'], work);
  if (run.code !== 0) {
    const detail = runOutputDetail(run);
    return {
      ok: false,
      message: `offline 夹具执行失败（退出码 ${run.code}）${detail === '' ? '' : `\n${detail}`}`,
    };
  }
  const metaFile = path.join(outputDir, 'meta.json');
  if (!fs.existsSync(metaFile)) return { ok: false, message: 'offline 夹具没有产出 meta.json' };
  let meta = null;
  try {
    meta = JSON.parse(fs.readFileSync(metaFile, 'utf8'));
  } catch {
    return { ok: false, message: 'offline 夹具产出的 meta.json 不是合法 JSON' };
  }
  const counts = [meta.cases_passed, meta.cases_failed, meta.cases_blocked, meta.cases_skipped].join('/');
  if (counts !== OFFLINE_EXPECTED_COUNTS) {
    return { ok: false, message: `offline 夹具结果为 ${counts}，与该夹具 README 的预期 ${OFFLINE_EXPECTED_COUNTS} 不符` };
  }
  return { ok: true, message: `test-execute 的 offline 夹具 → ${counts}（与该夹具 README 的预期一致）` };
}

/**
 * 组合场景二：cycle-state init → run-suite --cycle（硬跨 skill 依赖那条链路）。
 * @param {string} root 临时根
 * @param {string} work 工作目录
 * @returns {{ok: boolean, message: string}} 场景结论
 */
function scenarioCycle(root, work) {
  const skillsDir = path.join(root, 'skills');
  const offlineDir = path.join(skillsDir, 'test-execute', 'examples', 'offline');
  const suite = path.join(offlineDir, 'test-assets', 'suites', 'REQ-DEMO-demo', 'suite.json');
  const runner = path.join(skillsDir, 'test-execute', 'scripts', 'run-suite.mjs');
  const stateScript = path.join(skillsDir, 'test-case-design', 'scripts', 'cycle-state.mjs');
  const missing = [];
  if (!fs.existsSync(suite)) missing.push(path.relative(root, suite));
  if (!fs.existsSync(runner)) missing.push(path.relative(root, runner));
  if (!fs.existsSync(stateScript)) missing.push(path.relative(root, stateScript));
  if (missing.length > 0) {
    return { ok: false, message: `临时根里缺这些必需文件: ${missing.join(' / ')}` };
  }
  const cycleDir = path.join(work, 'cycles', 'R2-VERIFY');
  fs.mkdirSync(cycleDir, { recursive: true });
  const init = runNode(
    stateScript,
    [
      'init',
      cycleDir,
      '--cycle-id',
      'R2-VERIFY',
      '--round',
      'R2',
      '--round-type',
      'regression',
      '--requirement',
      'REQ-VERIFY',
      '--scope',
      'functional',
      '--by',
      'verify',
    ],
    work,
  );
  if (init.code !== 0) {
    const detail = runOutputDetail(init);
    return {
      ok: false,
      message: `轮次初始化失败（退出码 ${init.code}）${detail === '' ? '' : `\n${detail}`}`,
    };
  }

  const outputDir = path.join(work, 'exec-cycle');
  const run = runNode(
    runner,
    [suite, '--project-root', offlineDir, '--output-dir', outputDir, '--run-id', 'verify-cycle', '--cycle', cycleDir],
    work,
  );
  if (run.code !== 0) {
    const detail = runOutputDetail(run);
    return {
      ok: false,
      message: `带轮次推进的执行失败（退出码 ${run.code}）${detail === '' ? '' : `\n${detail}`}`,
    };
  }

  const cycleFile = path.join(cycleDir, 'cycle.json');
  if (!fs.existsSync(cycleFile)) return { ok: false, message: '没有产出 cycle.json' };
  let cycle = null;
  try {
    cycle = JSON.parse(fs.readFileSync(cycleFile, 'utf8'));
  } catch {
    return { ok: false, message: 'cycle.json 不是合法 JSON' };
  }
  const stage = cycle.stages && cycle.stages.execute ? cycle.stages.execute : {};
  const runs = Array.isArray(stage.runs) ? stage.runs : [];
  if (stage.status !== 'in_progress') {
    return { ok: false, message: `execute 阶段状态=${stage.status || '无'}，期望 in_progress` };
  }
  if (!runs.includes('verify-cycle')) {
    return { ok: false, message: 'stages.execute.runs[] 里没有记入本次 run_id' };
  }
  return { ok: true, message: '轮次 execute 阶段已推进（in_progress），本次 run_id 已记入 stages.execute.runs[]' };
}

/**
 * 组合场景三：test-execute 的 offline 夹具 → test-report 出报告 → 断言三层结论。
 *
 * 这条链路**真的经过**第 5 个 skill（test-report）：执行产物先落地，再由
 * make-report.mjs 读它、实查证据、算出三层结论 —— 断言的是报告里的
 * `verdict.*` 与 `cases.*`，不是「文件存在」。
 *
 * @param {string} root 临时根
 * @param {string} work 工作目录
 * @returns {{ok: boolean, message: string}} 场景结论
 */
function scenarioReport(root, work) {
  const skillsDir = path.join(root, 'skills');
  const offlineDir = path.join(skillsDir, 'test-execute', 'examples', 'offline');
  const suite = path.join(offlineDir, 'test-assets', 'suites', 'REQ-DEMO-demo', 'suite.json');
  const runner = path.join(skillsDir, 'test-execute', 'scripts', 'run-suite.mjs');
  const reporter = path.join(skillsDir, 'test-report', 'scripts', 'make-report.mjs');
  const missing = [];
  if (!fs.existsSync(suite)) missing.push(path.relative(root, suite));
  if (!fs.existsSync(runner)) missing.push(path.relative(root, runner));
  if (!fs.existsSync(reporter)) missing.push(path.relative(root, reporter));
  if (missing.length > 0) {
    return { ok: false, message: `临时根里缺这些必需文件: ${missing.join(' / ')}` };
  }

  const outputDir = path.join(work, 'exec-report');
  const run = runNode(
    runner,
    [suite, '--project-root', offlineDir, '--output-dir', outputDir, '--run-id', 'verify-report'],
    work,
  );
  if (run.code !== 0) {
    const detail = runOutputDetail(run);
    return {
      ok: false,
      message: `报告链路的执行环节失败（退出码 ${run.code}）${detail === '' ? '' : `\n${detail}`}`,
    };
  }

  const reportDir = path.join(work, 'report-out');
  const reported = runNode(reporter, ['--artifacts', outputDir, '--out-dir', reportDir], work);
  if (reported.code !== 0) {
    const detail = runOutputDetail(reported);
    return {
      ok: false,
      message: `test-report 出报告失败（退出码 ${reported.code}）${detail === '' ? '' : `\n${detail}`}`,
    };
  }

  const reportFile = path.join(reportDir, 'report.json');
  if (!fs.existsSync(reportFile)) return { ok: false, message: 'test-report 没有产出 report.json' };
  let report = null;
  try {
    report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
  } catch {
    return { ok: false, message: 'test-report 产出的 report.json 不是合法 JSON' };
  }
  const verdict = report && report.verdict ? report.verdict : {};
  const cases = report && report.cases ? report.cases : {};

  // offline 夹具的执行结果 → 报告里应当得出的三层结论（逐字断言，不是「文件存在」）
  const expectVerdict = {
    case_layer: 'fail',
    evidence_layer: 'pass',
    regression_layer: 'not_applicable',
    overall: 'fail',
  };
  const expectCases = { total: 6, passed: 4, failed: 1, blocked: 1, skipped: 0 };
  const problems = [];
  for (const [key, want] of Object.entries(expectVerdict)) {
    if (verdict[key] !== want) problems.push(`verdict.${key}=${JSON.stringify(verdict[key])}，应为 ${want}`);
  }
  for (const [key, want] of Object.entries(expectCases)) {
    if (cases[key] !== want) problems.push(`cases.${key}=${JSON.stringify(cases[key])}，应为 ${want}`);
  }
  if (problems.length > 0) {
    return { ok: false, message: `test-report 的报告结论与执行产物对不上: ${problems.join('; ')}` };
  }

  const mdFile = path.join(reportDir, 'report.md');
  if (!fs.existsSync(mdFile) || !/report-digest/.test(fs.readFileSync(mdFile, 'utf8'))) {
    return { ok: false, message: 'test-report 没有产出带机器可读摘要行的 report.md' };
  }

  return {
    ok: true,
    message:
      `test-report 的报告链路（make-report.mjs 读 test-execute 的执行产物）→ ` +
      `verdict.case_layer=${verdict.case_layer}、verdict.evidence_layer=${verdict.evidence_layer}、` +
      `verdict.regression_layer=${verdict.regression_layer}、verdict.overall=${verdict.overall}；` +
      `cases.total=${cases.total}、cases.passed=${cases.passed}、cases.failed=${cases.failed}、` +
      `cases.blocked=${cases.blocked}、cases.skipped=${cases.skipped}（与执行产物逐字一致）`,
  };
}

/**
 * 组合场景四：缺陷单 + 已有用例集 → defect-verify 出缺陷复现用例集 → 断言处置结论自洽。
 *
 * 这条链路**真的经过**第 6 个 skill（defect-verify）：在临时根里造一份缺陷单 +
 * 一份已有用例集 + 一个 R3 轮次目录，实跑 make-defect-cases.mjs，然后**从产物反推**
 * 断言（不是只查文件存在，也不是只看输出文本）：
 *   - defects[] 每条**有且只有一个**处置结论（derived / reused / unresolved）；
 *   - derived 的缺陷在 cases[] 里**有**对应的用例；
 *   - reused 的缺陷**有** reused_case_refs；
 *   - cases[] 的 id **唯一**（共享场景下同一条用例只出现一次）。
 *
 * @param {string} root 临时根
 * @param {string} work 工作目录
 * @returns {{ok: boolean, message: string}} 场景结论
 */
function scenarioDefectVerify(root, work) {
  const skillsDir = path.join(root, 'skills');
  const maker = path.join(skillsDir, 'defect-verify', 'scripts', 'make-defect-cases.mjs');
  if (!fs.existsSync(maker)) {
    return { ok: false, message: `临时根里缺这个必需文件: ${path.relative(root, maker)}` };
  }

  const project = path.join(work, 'defect-verify-proj');
  const cycleDir = path.join(project, 'test-assets', 'cycles', 'R3-VERIFY');
  const inputsDir = path.join(project, 'inputs');
  const defectsFile = path.join(inputsDir, 'defects.json');
  const casesFile = path.join(inputsDir, 'cases.json');
  const suite = 'REQ-VERIFY-coupon';

  const mkCase = (id, title, action, expected, tags) => ({
    id,
    title,
    requirement_refs: ['R-1'],
    dimension: 'functional',
    priority: 'P0',
    method: ['M1.1'],
    status: 'active',
    preconditions: [],
    steps: [{ action, expected }],
    data: {},
    tags,
  });

  const defects = {
    schema_version: 1,
    defects: [
      {
        id: 'BUG-901',
        title: '满减券核销后实付金额多 0.01 元',
        severity: 'high',
        status: 'open',
        case_refs: ['TC-001'],
        reproduction: {
          command: 'curl -X POST https://api.example.com/coupon/redeem',
          steps: ['以满减券下单', '触发核销'],
          expected_failure: '实付金额比预期多 0.01 元',
        },
      },
      {
        id: 'BUG-902',
        title: '导出报表偶发空文件',
        severity: 'low',
        status: 'open',
        reproduction: {
          command: 'curl -X GET https://api.example.com/reports/export',
          steps: ['触发报表导出', '下载导出文件'],
          expected_failure: '导出文件为空',
        },
      },
    ],
  };

  const cases = {
    schema_version: 2,
    meta: { source: 'REQ-VERIFY 需求文档', generated_at: '2026-01-01T00:00:00+08:00', case_count: 1 },
    requirements: [{ id: 'R-1', title: '优惠券核销', source_ref: 'REQ-VERIFY §1', testable: true }],
    open_questions: [],
    coverage_matrix: [
      { requirement: 'R-1', methods_applied: ['M1.1'], skipped: [], dimensions: ['functional'] },
    ],
    cases: [mkCase('TC-001', '优惠券核销用例', '以满减券下单', '实付金额正确', ['coupon'])],
  };

  const cycle = {
    cycle_id: 'R3-VERIFY',
    round: 'R3',
    round_type: 'defect-verify',
    requirement: 'REQ-VERIFY',
    scopes: ['functional'],
    scopes_skipped: [],
    status: 'in_progress',
    stages: { clarify: { status: 'done' }, design: { status: 'in_progress' } },
    history: [],
    trigger: { type: 'defect', ref: 'BUG-901' },
  };

  fs.mkdirSync(inputsDir, { recursive: true });
  fs.mkdirSync(cycleDir, { recursive: true });
  fs.writeFileSync(defectsFile, `${JSON.stringify(defects, null, 2)}\n`, 'utf8');
  fs.writeFileSync(casesFile, `${JSON.stringify(cases, null, 2)}\n`, 'utf8');
  fs.writeFileSync(path.join(cycleDir, 'cycle.json'), `${JSON.stringify(cycle, null, 2)}\n`, 'utf8');

  const run = runNode(
    maker,
    ['--defects', defectsFile, '--cases', casesFile, '--suite', suite, '--cycle-dir', cycleDir],
    work,
  );
  if (run.code !== 0) {
    const detail = runOutputDetail(run);
    return {
      ok: false,
      message: `defect-verify 出复现用例集失败（退出码 ${run.code}）${detail === '' ? '' : `\n${detail}`}`,
    };
  }

  const productFile = path.join(cycleDir, 'defect-cases.json');
  if (!fs.existsSync(productFile)) {
    return { ok: false, message: 'defect-verify 没有产出 defect-cases.json' };
  }
  let product = null;
  try {
    product = JSON.parse(fs.readFileSync(productFile, 'utf8'));
  } catch {
    return { ok: false, message: 'defect-verify 产出的 defect-cases.json 不是合法 JSON' };
  }

  const productDefects = Array.isArray(product.defects) ? product.defects : [];
  const productCases = Array.isArray(product.cases) ? product.cases : [];
  const problems = [];
  if (productDefects.length !== defects.defects.length) {
    problems.push(`defects[] 条目数=${productDefects.length}，输入缺陷数=${defects.defects.length}`);
  }
  const counts = { derived: 0, reused: 0, unresolved: 0 };
  for (const entry of productDefects) {
    const disposition = entry && entry.disposition;
    if (!['derived', 'reused', 'unresolved'].includes(disposition)) {
      problems.push(`disposition=${JSON.stringify(disposition)} 不在 {derived,reused,unresolved} 里`);
      continue;
    }
    counts[disposition] += 1;
    if (disposition === 'derived') {
      const hit = productCases.find((item) => item && item.id === entry.derived_case_id);
      if (!hit) problems.push(`derived 的缺陷 ${entry.id} 没有对应的用例`);
    }
    if (disposition === 'reused' && !(Array.isArray(entry.reused_case_refs) && entry.reused_case_refs.length > 0)) {
      problems.push(`reused 的缺陷 ${entry.id} 没有 reused_case_refs`);
    }
    if (disposition === 'unresolved' && !(typeof entry.reason === 'string' && entry.reason.trim() !== '')) {
      problems.push(`unresolved 的缺陷 ${entry.id} 没有非空 reason`);
    }
  }
  if (productCases.length === 0) problems.push('cases[] 为空（没有真的跑出复现用例）');
  const ids = productCases.filter((item) => item && typeof item.id === 'string').map((item) => item.id);
  if (new Set(ids).size !== ids.length) problems.push('cases[] 的 id 有重复');
  if (problems.length > 0) {
    return { ok: false, message: `defect-verify 的产物结构不自洽: ${problems.join('; ')}` };
  }

  return {
    ok: true,
    message:
      `defect-verify 的复现用例链路（make-defect-cases.mjs 读缺陷单 + 已有用例集）→ ` +
      `缺陷 ${productDefects.length} 条（复用 ${counts.reused} / 派生 ${counts.derived} / 未决 ${counts.unresolved}）、` +
      `复现用例 ${productCases.length} 条（id 唯一：${ids.join(' / ')}）；产物: ${path.relative(root, productFile)}`,
  };
}

/**
 * 组合场景五：安全上下文 + 功能用例集 + 扫描结果 → security-plan 出安全测试计划 → 断言逐项自洽。
 *
 * 这条链路**真的经过**第 7 个 skill（security-plan）：在临时根里造一份安全上下文 +
 * 一份功能用例集 + 一份 bandit 扫描结果 + 一个最小项目根，实跑 make-security-plan.mjs，
 * 然后**从产物反推**断言（不是只查文件存在）：
 *   - OWASP 十类**逐类有交代**（covered ⇒ threat_refs 非空且恰为该类全部威胁；
 *     不适用 ⇒ 非空理由 + 指向一条 category 等于该类的未决问题）；
 *   - 四类实战补充逐类显式判定，且「covered ⇒ 被引用威胁的 supplement_refs 含该键」；
 *   - 每个资产 / 边界 / 入口点都至少被一条威胁引用（不悬空、不漏）；
 *   - 权限矩阵：角色 / 资源集合与上下文相等、每个 (role, resource) 至少一条、
 *     允许缺口 ⇒ decision=allow 且指向越权类威胁、越权类威胁**双向**被缺口引用；
 *   - 套件：目录名合规、suite.json 顶层字段集 ⊆ 9（无 threat_model）、suite 名 == 目录名、
 *     scope/executor == security、environment / cases_file 真实存在；
 *   - 用例：cases.json 顶层**恰好 7 个**、id 合 ^TC-\d{3}$ 且跨套件唯一且不与输入集冲突、
 *     dimension=security、status 恒为 active、方法号**确实存在于方法库**、
 *     tags 含 security 与威胁 id；
 *   - 产物能被上游的**加载层**消费（loadSuite / loadCases / selectCases），
 *     并且过上游 validate-cases.mjs（退出码 0）。
 *
 * ⚠️ 这里**不断言** `run-suite.mjs --dry-run` 能跑通：`security` 执行器在
 * test-execute/executors/index.json 的 not_implemented 里，且执行器查找在 dry-run
 * 分支**之前** ⇒ dry-run 会先抛错。安全用例的**执行属后续 REQ**。
 *
 * @param {string} root 临时根
 * @param {string} work 工作目录
 * @returns {{ok: boolean, message: string}} 场景结论
 */
function scenarioSecurityPlan(root, work) {
  const skillsDir = path.join(root, 'skills');
  const maker = path.join(skillsDir, 'security-plan', 'scripts', 'make-security-plan.mjs');
  const validator = path.join(skillsDir, 'test-case-design', 'scripts', 'validate-cases.mjs');
  const loader = path.join(skillsDir, 'test-execute', 'scripts', 'lib', 'suite-loader.mjs');
  const methodsFile = path.join(skillsDir, 'test-case-design', 'references', 'methods.json');
  const missing = [];
  for (const file of [maker, validator, loader, methodsFile]) {
    if (!fs.existsSync(file)) missing.push(path.relative(root, file));
  }
  if (missing.length > 0) {
    return { ok: false, message: `临时根里缺这些必需文件: ${missing.join(' / ')}` };
  }

  // --- 夹具：安全上下文 / 功能用例集 / bandit 扫描结果 / 最小项目根 ---
  const project = path.join(work, 'security-plan-proj');
  const inputsDir = path.join(project, 'inputs');
  const envDir = path.join(project, 'test-assets', 'environments');
  fs.mkdirSync(inputsDir, { recursive: true });
  fs.mkdirSync(envDir, { recursive: true });

  const context = {
    schema_version: 1,
    service: { name: 'order-api', description: '订单服务' },
    assets: [
      { id: 'AS-1', name: '用户口令哈希', sensitivity: 'critical', description: '口令散列' },
      { id: 'AS-2', name: '订单数据', sensitivity: 'high', description: '订单明细' },
      { id: 'AS-3', name: '访问日志', sensitivity: 'medium', description: '审计日志' },
    ],
    trust_boundaries: [
      { id: 'TB-1', name: '公网到应用', from: '互联网', to: '应用网关', controls: ['TLS 终止', 'WAF 规则'] },
      { id: 'TB-2', name: '应用到数据层', from: '应用进程', to: '数据库', controls: ['参数化查询'] },
    ],
    entry_points: [
      { id: 'EP-1', name: '登录接口', kind: 'http', asset_refs: ['AS-1'], boundary_refs: ['TB-1'], description: 'POST /api/login' },
      { id: 'EP-2', name: '订单详情接口', kind: 'http', asset_refs: ['AS-2'], boundary_refs: ['TB-1'], description: 'GET /api/orders/{id}' },
      { id: 'EP-3', name: '日志写入', kind: 'file', asset_refs: ['AS-3'], boundary_refs: ['TB-2'], description: '写访问日志' },
    ],
    roles: [
      { id: 'ROLE-1', name: '匿名访客' },
      { id: 'ROLE-2', name: '登录用户' },
      { id: 'ROLE-3', name: '管理员' },
    ],
    resources: [
      { id: 'RES-1', name: '订单', asset_refs: ['AS-2'] },
      { id: 'RES-2', name: '用户账号', asset_refs: ['AS-1'] },
    ],
  };
  const functionalCases = {
    schema_version: 2,
    meta: { source: 'REQ-VERIFY 需求文档', generated_at: '2026-01-01T00:00:00+08:00', case_count: 2 },
    requirements: [
      { id: 'R-1', title: '登录', source_ref: 'REQ-VERIFY §1', testable: true },
      { id: 'R-2', title: '订单查询', source_ref: 'REQ-VERIFY §2', testable: true },
    ],
    open_questions: [],
    coverage_matrix: [
      { requirement: 'R-1', methods_applied: ['M1.1'], skipped: [], dimensions: ['functional'] },
      { requirement: 'R-2', methods_applied: ['M1.1'], skipped: [], dimensions: ['functional'] },
    ],
    defects: [],
    cases: [
      {
        id: 'TC-001', title: '登录成功返回令牌', requirement_refs: ['R-1'], dimension: 'functional',
        priority: 'P0', method: ['M1.1'], status: 'active', preconditions: [],
        steps: [{ action: 'POST /api/login', expected: '返回 200 与访问令牌' }], data: {}, tags: ['auth'],
      },
      {
        id: 'TC-002', title: '查询订单详情', requirement_refs: ['R-2'], dimension: 'functional',
        priority: 'P0', method: ['M1.1'], status: 'active', preconditions: [],
        steps: [{ action: 'GET /api/orders/{id}', expected: '返回订单明细' }], data: {}, tags: ['order'],
      },
    ],
  };
  const scan = {
    results: [
      {
        filename: 'app/handlers/upload.py', test_id: 'B301', test_name: 'blacklist',
        issue_severity: 'HIGH', issue_confidence: 'HIGH',
        issue_text: "Possible hardcoded password: 'secret123'", line_number: 42,
      },
      {
        filename: 'app/handlers/xml.py', test_id: 'B320', test_name: 'bad_telemetry',
        issue_severity: 'MEDIUM', issue_confidence: 'MEDIUM',
        issue_text: 'Consider possible security implications of xml parsing', line_number: 17,
      },
    ],
    errors: [],
  };
  // ⚠️ 环境**不写** driver：写了会覆盖 suite.json 的 executor，误配对到 api/mock 执行器，
  //    「能跑通」就变成了假象（安全用例的执行属后续 REQ）。
  const environment = {
    name: 'local',
    base_url: 'http://127.0.0.1:8080',
    timeout_ms: 5000,
    retries: 0,
    credentials: { username_env: 'ORDER_API_USER', password_env: 'ORDER_API_PASS' },
  };

  const contextFile = path.join(inputsDir, 'context.json');
  const casesFile = path.join(inputsDir, 'cases.json');
  const scanFile = path.join(inputsDir, 'bandit.json');
  fs.writeFileSync(contextFile, `${JSON.stringify(context, null, 2)}\n`, 'utf8');
  fs.writeFileSync(casesFile, `${JSON.stringify(functionalCases, null, 2)}\n`, 'utf8');
  fs.writeFileSync(scanFile, `${JSON.stringify(scan, null, 2)}\n`, 'utf8');
  fs.writeFileSync(path.join(envDir, 'local.json'), `${JSON.stringify(environment, null, 2)}\n`, 'utf8');

  // --- 实跑 ---
  const run = runNode(
    maker,
    ['--context', contextFile, '--cases', casesFile, '--scan', scanFile, '--out-dir', project],
    work,
  );
  if (run.code !== 0) {
    const detail = runOutputDetail(run);
    return {
      ok: false,
      message: `security-plan 出安全测试计划失败（退出码 ${run.code}）${detail === '' ? '' : `\n${detail}`}`,
    };
  }

  const securityRoot = path.join(project, 'test-assets', 'security');
  const modelFile = path.join(securityRoot, 'threat-model.json');
  const matrixFile = path.join(securityRoot, 'matrix.json');
  for (const file of [modelFile, matrixFile]) {
    if (!fs.existsSync(file)) {
      return { ok: false, message: `security-plan 没有产出 ${path.relative(root, file)}` };
    }
  }
  let model = null;
  let matrix = null;
  try {
    model = JSON.parse(fs.readFileSync(modelFile, 'utf8'));
    matrix = JSON.parse(fs.readFileSync(matrixFile, 'utf8'));
  } catch (err) {
    return { ok: false, message: `security-plan 的产物不是合法 JSON（${err.message}）` };
  }

  const problems = [];
  const OWASP_CODES = ['A01', 'A02', 'A03', 'A04', 'A05', 'A06', 'A07', 'A08', 'A09', 'A10'];
  const SUPPLEMENT_KEYS = ['file_upload', 'ssrf', 'xxe', 'deserialization'];
  const THREAT_FIELDS = [
    'id', 'name', 'category', 'owasp', 'asset_refs', 'boundary_refs', 'entry_point_refs',
    'severity', 'source', 'scan_refs', 'supplement_refs', 'rationale',
  ];
  const CASES_TOP_LEVEL = [
    'schema_version', 'meta', 'requirements', 'open_questions', 'coverage_matrix', 'defects', 'cases',
  ];
  const SUITE_ALLOWED = [
    'suite', 'requirement', 'scope', 'environment', 'cases_file', 'executor',
    'base_url_from', 'tags', 'report',
  ];

  // --- 威胁模型 ---
  const threats = Array.isArray(model.threats) ? model.threats : [];
  const threatById = new Map(threats.map((threat) => [threat.id, threat]));
  if (threats.length === 0) problems.push('threats 为空');
  const assetIds = new Set((model.assets || []).map((item) => item.id));
  const boundaryIds = new Set((model.trust_boundaries || []).map((item) => item.id));
  const entryIds = new Set((model.entry_points || []).map((item) => item.id));
  const usedAssets = new Set();
  const usedBoundaries = new Set();
  const usedEntries = new Set();
  for (const threat of threats) {
    const fields = Object.keys(threat);
    for (const key of THREAT_FIELDS) {
      if (!fields.includes(key)) problems.push(`威胁 ${threat.id} 缺字段 ${key}`);
    }
    for (const key of fields) {
      if (!THREAT_FIELDS.includes(key)) problems.push(`威胁 ${threat.id} 出现未声明的字段 ${key}`);
    }
    if (!/^TH-\d+$/.test(String(threat.id))) problems.push(`威胁 id 不合规: ${threat.id}`);
    if (!OWASP_CODES.includes(threat.owasp)) problems.push(`威胁 ${threat.id} 的 owasp 非法: ${threat.owasp}`);
    if (!Array.isArray(threat.asset_refs) || threat.asset_refs.length === 0) {
      problems.push(`威胁 ${threat.id} 的 asset_refs 为空`);
    }
    if (!Array.isArray(threat.entry_point_refs) || threat.entry_point_refs.length === 0) {
      problems.push(`威胁 ${threat.id} 的 entry_point_refs 为空`);
    }
    for (const ref of threat.asset_refs || []) {
      if (!assetIds.has(ref)) problems.push(`威胁 ${threat.id} 的 asset_refs 悬空: ${ref}`);
      else usedAssets.add(ref);
    }
    for (const ref of threat.boundary_refs || []) {
      if (!boundaryIds.has(ref)) problems.push(`威胁 ${threat.id} 的 boundary_refs 悬空: ${ref}`);
      else usedBoundaries.add(ref);
    }
    for (const ref of threat.entry_point_refs || []) {
      if (!entryIds.has(ref)) problems.push(`威胁 ${threat.id} 的 entry_point_refs 悬空: ${ref}`);
      else usedEntries.add(ref);
    }
    const hasScan = String(threat.source || '').includes('scan');
    const scanRefs = Array.isArray(threat.scan_refs) ? threat.scan_refs : [];
    if (hasScan !== (scanRefs.length > 0)) {
      problems.push(`威胁 ${threat.id} 的 source 与 scan_refs 不自洽`);
    }
  }
  for (const id of assetIds) {
    if (!usedAssets.has(id)) problems.push(`资产 ${id} 没有被任何威胁引用（漏检）`);
  }
  for (const id of boundaryIds) {
    if (!usedBoundaries.has(id)) problems.push(`信任边界 ${id} 没有被任何威胁引用（漏检）`);
  }
  for (const id of entryIds) {
    if (!usedEntries.has(id)) problems.push(`入口点 ${id} 没有被任何威胁引用（漏检）`);
  }

  // --- OWASP 十类 ---
  const coverage = model.owasp_coverage || {};
  const coverageKeys = Object.keys(coverage).sort();
  if (coverageKeys.length !== 10 || OWASP_CODES.some((code) => !coverageKeys.includes(code))) {
    problems.push(`owasp_coverage 的键集不是 A01~A10（实际 ${coverageKeys.join(' / ')}）`);
  }
  const questions = Array.isArray(model.open_questions) ? model.open_questions : [];
  const questionById = new Map(questions.map((question) => [question.id, question]));
  for (const code of OWASP_CODES) {
    const entry = coverage[code];
    if (!entry) {
      problems.push(`owasp_coverage 缺少 ${code}（不许静默跳过）`);
      continue;
    }
    const actual = threats.filter((threat) => threat.owasp === code).map((threat) => threat.id);
    if (entry.status === 'covered') {
      if (!Array.isArray(entry.threat_refs) || entry.threat_refs.length === 0) {
        problems.push(`owasp_coverage.${code} 判为已覆盖但没有威胁引用`);
        continue;
      }
      for (const ref of entry.threat_refs) {
        if (!threatById.has(ref)) problems.push(`owasp_coverage.${code} 的威胁引用悬空: ${ref}`);
        else if (threatById.get(ref).owasp !== code) problems.push(`owasp_coverage.${code} 引用了别的类的威胁`);
      }
      for (const id of actual) {
        if (!entry.threat_refs.includes(id)) problems.push(`owasp_coverage.${code} 漏掉了威胁 ${id}`);
      }
    } else if (entry.status === 'not_applicable') {
      if (typeof entry.reason !== 'string' || entry.reason.trim() === '') {
        problems.push(`owasp_coverage.${code} 判为不适用但理由为空`);
      }
      const question = questionById.get(entry.open_question_ref);
      if (!question) problems.push(`owasp_coverage.${code} 的未决问题引用悬空`);
      else if (question.category !== code) problems.push(`owasp_coverage.${code} 的未决问题类别对不上`);
      if (actual.length > 0) problems.push(`owasp_coverage.${code} 判为不适用却造了该类威胁`);
    } else {
      problems.push(`owasp_coverage.${code} 的状态非法: ${entry.status}`);
    }
  }

  // --- 四类实战补充 ---
  const supplements = model.supplements || {};
  for (const key of SUPPLEMENT_KEYS) {
    const entry = supplements[key];
    if (!entry) {
      problems.push(`supplements 缺少 ${key}（不许静默跳过）`);
      continue;
    }
    const actual = threats
      .filter((threat) => (threat.supplement_refs || []).includes(key))
      .map((threat) => threat.id);
    if (entry.status === 'covered') {
      if (!Array.isArray(entry.threat_refs) || entry.threat_refs.length === 0) {
        problems.push(`supplements.${key} 判为已覆盖但没有威胁引用`);
        continue;
      }
      for (const ref of entry.threat_refs) {
        if (!threatById.has(ref)) problems.push(`supplements.${key} 的威胁引用悬空: ${ref}`);
        else if (!(threatById.get(ref).supplement_refs || []).includes(key)) {
          problems.push(`supplements.${key} 引用的威胁没有把它写进 supplement_refs`);
        }
      }
      for (const id of actual) {
        if (!entry.threat_refs.includes(id)) problems.push(`supplements.${key} 漏掉了威胁 ${id}`);
      }
    } else if (entry.status === 'not_applicable') {
      if (typeof entry.reason !== 'string' || entry.reason.trim() === '') {
        problems.push(`supplements.${key} 判为不适用但理由为空`);
      }
      if (actual.length > 0) problems.push(`supplements.${key} 判为不适用却造了该类威胁`);
    } else {
      problems.push(`supplements.${key} 的状态非法: ${entry.status}`);
    }
  }

  // --- 扫描 ---
  if (!model.scan || model.scan.status !== 'provided') {
    problems.push(`scan.status 不是 provided（实际 ${model.scan ? model.scan.status : '无'}）`);
  }
  if (!model.scan || model.scan.tool !== 'bandit') {
    problems.push(`scan.tool 不是 bandit（实际 ${model.scan ? model.scan.tool : '无'}）`);
  }
  const findings = Array.isArray(model.scan_findings) ? model.scan_findings : [];
  if (findings.length !== 2) problems.push(`scan_findings 条数不是 2（实际 ${findings.length}）`);
  for (const finding of findings) {
    if (!Array.isArray(finding.threat_refs) || finding.threat_refs.length === 0) {
      problems.push(`扫描发现 ${finding.id} 没有映射到威胁`);
      continue;
    }
    for (const ref of finding.threat_refs) {
      const threat = threatById.get(ref);
      if (!threat) {
        problems.push(`扫描发现 ${finding.id} 映射到不存在的威胁 ${ref}`);
        continue;
      }
      if (!String(threat.source).includes('scan')) {
        problems.push(`扫描发现 ${finding.id} 映射的威胁来源里没有 scan`);
      }
      if (!(threat.scan_refs || []).includes(finding.id)) {
        problems.push(`扫描发现 ${finding.id} 映射的威胁没有回指它`);
      }
    }
  }

  // --- 权限矩阵 ---
  const roles = Array.isArray(matrix.roles) ? matrix.roles : [];
  const resources = Array.isArray(matrix.resources) ? matrix.resources : [];
  const entries = Array.isArray(matrix.entries) ? matrix.entries : [];
  const contextRoleIds = context.roles.map((role) => role.id).sort().join(',');
  const contextResourceIds = context.resources.map((resource) => resource.id).sort().join(',');
  if (roles.map((role) => role.id).sort().join(',') !== contextRoleIds) {
    problems.push('matrix.json 的角色集合与上下文不相等');
  }
  if (resources.map((resource) => resource.id).sort().join(',') !== contextResourceIds) {
    problems.push('matrix.json 的资源集合与上下文不相等');
  }
  if (entries.length === 0) problems.push('matrix.json 的 entries 为空');
  const pairs = new Set();
  const gapThreatRefs = new Set();
  for (const entry of entries) {
    pairs.add(`${entry.role}|${entry.resource}`);
    if (!roles.some((role) => role.id === entry.role)) problems.push(`矩阵条目的角色悬空: ${entry.role}`);
    if (!resources.some((resource) => resource.id === entry.resource)) {
      problems.push(`矩阵条目的资源悬空: ${entry.resource}`);
    }
    if (entry.basis === 'gap') {
      if (entry.decision !== 'allow') problems.push('矩阵缺口条目的决策必须是允许');
      const threat = threatById.get(entry.threat_ref);
      if (!threat) problems.push(`矩阵缺口条目指向的威胁不存在: ${entry.threat_ref}`);
      else if (threat.category !== 'elevation_of_privilege') {
        problems.push('矩阵缺口条目指向的威胁不是越权类');
      }
      gapThreatRefs.add(entry.threat_ref);
    } else if (entry.basis !== 'expected') {
      problems.push(`矩阵条目的依据非法: ${entry.basis}`);
    }
  }
  for (const role of roles) {
    for (const resource of resources) {
      if (!pairs.has(`${role.id}|${resource.id}`)) {
        problems.push(`矩阵漏掉了组合 (${role.id}, ${resource.id})`);
      }
    }
  }
  for (const threat of threats) {
    if (threat.category !== 'elevation_of_privilege') continue;
    if (!gapThreatRefs.has(threat.id)) {
      problems.push(`越权类威胁 ${threat.id} 没有被任何缺口条目引用`);
    }
  }

  // --- 套件与用例 ---
  const suitesDir = path.join(securityRoot, 'suites');
  const suiteNames = fs.existsSync(suitesDir)
    ? fs.readdirSync(suitesDir).filter((name) => fs.statSync(path.join(suitesDir, name)).isDirectory()).sort()
    : [];
  if (suiteNames.length === 0) problems.push('没有产出任何安全套件');
  let methodIds = [];
  try {
    methodIds = JSON.parse(fs.readFileSync(methodsFile, 'utf8')).methods.map((item) => item.id);
  } catch {
    problems.push('读不到方法库');
  }
  const usedCaseIds = new Set();
  const inputCaseIds = new Set(functionalCases.cases.map((item) => item.id));
  const coveredThreats = new Set();
  let caseTotal = 0;
  for (const name of suiteNames) {
    if (!/^SEC-\d{3}-[a-z0-9][a-z0-9-]*$/.test(name)) {
      problems.push(`套件目录名不合规: ${name}`);
    }
    const suiteDir = path.join(suitesDir, name);
    const suiteFile = path.join(suiteDir, 'suite.json');
    const casesFile = path.join(suiteDir, 'cases.json');
    if (!fs.existsSync(suiteFile)) problems.push(`套件 ${name} 缺 suite.json`);
    if (!fs.existsSync(casesFile)) problems.push(`套件 ${name} 缺 cases.json`);
    if (!fs.existsSync(suiteFile) || !fs.existsSync(casesFile)) continue;
    let suite = null;
    let casesDoc = null;
    try {
      suite = JSON.parse(fs.readFileSync(suiteFile, 'utf8'));
      casesDoc = JSON.parse(fs.readFileSync(casesFile, 'utf8'));
    } catch (err) {
      problems.push(`套件 ${name} 的产物不是合法 JSON`);
      continue;
    }
    for (const key of Object.keys(suite)) {
      if (!SUITE_ALLOWED.includes(key)) problems.push(`套件 ${name} 的 suite.json 出现未声明的字段 ${key}`);
    }
    for (const key of ['suite', 'requirement', 'scope', 'environment', 'cases_file', 'executor']) {
      if (typeof suite[key] !== 'string' || suite[key].trim() === '') {
        problems.push(`套件 ${name} 的 suite.json 缺必填字段 ${key}`);
      }
    }
    if (suite.suite !== name) problems.push(`套件 ${name} 的 suite 名与目录名不一致`);
    if (suite.scope !== 'security') problems.push(`套件 ${name} 的 scope 不是 security`);
    if (suite.executor !== 'security') problems.push(`套件 ${name} 的 executor 不是 security`);
    if (!fs.existsSync(path.join(project, 'test-assets', 'environments', `${suite.environment}.json`))) {
      problems.push(`套件 ${name} 引用的环境不存在: ${suite.environment}`);
    }
    if (!fs.existsSync(path.resolve(suiteDir, suite.cases_file))) {
      problems.push(`套件 ${name} 引用的用例集不存在: ${suite.cases_file}`);
    }

    const topKeys = Object.keys(casesDoc);
    for (const key of CASES_TOP_LEVEL) {
      if (!topKeys.includes(key)) problems.push(`套件 ${name} 的 cases.json 缺顶层字段 ${key}`);
    }
    for (const key of topKeys) {
      if (!CASES_TOP_LEVEL.includes(key)) {
        problems.push(`套件 ${name} 的 cases.json 出现未声明的顶层字段 ${key}`);
      }
    }
    if (casesDoc.schema_version !== 2) problems.push(`套件 ${name} 的 cases.json 的 schema_version 不是 2`);
    const requirements = Array.isArray(casesDoc.requirements) ? casesDoc.requirements : [];
    const requirementIds = new Set(requirements.map((item) => item.id));
    const matrixRequirements = new Set((casesDoc.coverage_matrix || []).map((item) => item.requirement));
    for (const requirement of requirements) {
      const matched = /^threat-model\.json#\/threats\/(TH-\d+)$/.exec(String(requirement.source_ref || ''));
      if (!matched) {
        problems.push(`套件 ${name} 的需求条目的来源引用格式不对: ${requirement.source_ref}`);
      } else if (!threatById.has(matched[1])) {
        problems.push(`套件 ${name} 的需求条目指向不存在的威胁: ${matched[1]}`);
      }
      if (!matrixRequirements.has(requirement.id)) {
        problems.push(`套件 ${name} 的覆盖矩阵漏掉了需求条目 ${requirement.id}`);
      }
    }
    const cases = Array.isArray(casesDoc.cases) ? casesDoc.cases : [];
    caseTotal += cases.length;
    for (const item of cases) {
      if (!/^TC-\d{3}$/.test(String(item.id))) problems.push(`用例 id 不合规: ${item.id}`);
      if (usedCaseIds.has(item.id)) problems.push(`用例 id 跨套件重复: ${item.id}`);
      usedCaseIds.add(item.id);
      if (inputCaseIds.has(item.id)) problems.push(`用例 id 与输入用例集冲突: ${item.id}`);
      if (item.dimension !== 'security') problems.push(`用例 ${item.id} 的维度不是 security`);
      if (item.status !== 'active') problems.push(`用例 ${item.id} 的状态不是 active`);
      if (item.revision !== undefined) problems.push(`用例 ${item.id} 带了修订记录`);
      for (const method of item.method || []) {
        if (!methodIds.includes(method)) problems.push(`用例 ${item.id} 用了方法库里没有的方法号: ${method}`);
      }
      for (const ref of item.requirement_refs || []) {
        if (!requirementIds.has(ref)) problems.push(`用例 ${item.id} 的需求引用悬空: ${ref}`);
      }
      if (!Array.isArray(item.tags) || !item.tags.includes('security')) {
        problems.push(`用例 ${item.id} 的标签里没有 security`);
      }
      for (const ref of item.requirement_refs || []) {
        const requirement = requirements.find((one) => one.id === ref);
        const matched = requirement
          ? /^threat-model\.json#\/threats\/(TH-\d+)$/.exec(String(requirement.source_ref || ''))
          : null;
        if (matched) {
          coveredThreats.add(matched[1]);
          if (!Array.isArray(item.tags) || !item.tags.includes(matched[1])) {
            problems.push(`用例 ${item.id} 的标签里没有它对应的威胁 id ${matched[1]}`);
          }
        }
      }
      if (!Array.isArray(item.steps) || item.steps.length === 0) {
        problems.push(`用例 ${item.id} 没有步骤`);
      }
    }

    // --- 产物过上游校验器（真实退出码）---
    const validated = runNode(validator, [casesFile], work);
    if (validated.code !== 0) {
      const detail = runOutputDetail(validated);
      problems.push(`套件 ${name} 的 cases.json 过不了上游校验器（退出码 ${validated.code}）${detail === '' ? '' : `\n${detail}`}`);
    }
  }
  if (caseTotal < threats.length) {
    problems.push(`安全用例总数 ${caseTotal} 少于威胁数 ${threats.length}（每条威胁至少 1 条用例）`);
  }
  for (const threat of threats) {
    if (!coveredThreats.has(threat.id)) {
      problems.push(`威胁 ${threat.id} 没有任何用例覆盖`);
    }
  }

  // --- 加载层可消费（问上游本人）---
  const loadcheckFile = path.join(work, 'security-plan-loadcheck.mjs');
  fs.writeFileSync(loadcheckFile, `${LOADCHECK_SOURCE}\n`, 'utf8');
  const loaded = runNode(loadcheckFile, [securityRoot, loader], work);
  if (loaded.code !== 0) {
    const detail = runOutputDetail(loaded);
    problems.push(`加载层消费失败（退出码 ${loaded.code}）${detail === '' ? '' : `\n${detail}`}`);
  } else {
    let report = null;
    try {
      report = JSON.parse(loaded.stdout.trim());
    } catch {
      problems.push('加载层检查没有输出可解析的结果');
    }
    if (Array.isArray(report)) {
      for (const item of report) {
        if (item.selected !== item.total) {
          problems.push(`套件 ${item.suite} 按标签选出的用例数 ${item.selected} 与总数 ${item.total} 不一致`);
        }
      }
    }
  }

  if (problems.length > 0) {
    return {
      ok: false,
      message: `security-plan 的产物不自洽: ${problems.join('; ')}`,
    };
  }

  const covered = Object.values(coverage).filter((entry) => entry.status === 'covered').length;
  const na = Object.values(coverage).filter((entry) => entry.status === 'not_applicable').length;
  return {
    ok: true,
    message:
      `security-plan 的规划链路（make-security-plan.mjs 读安全上下文 + 功能用例集 + 依赖扫描结果）→ ` +
      `威胁 ${threats.length} 条（OWASP 十类：已覆盖 ${covered} 类 / 不适用 ${na} 类）、` +
      `扫描发现 ${findings.length} 条全部映射到威胁、` +
      `权限矩阵 ${entries.length} 条（允许缺口 ${gapThreatRefs.size} 条）、` +
      `套件 ${suiteNames.length} 个 / 安全用例 ${caseTotal} 条（id 跨套件唯一且不与输入集冲突）；` +
      `产物可被上游加载层消费且过上游用例集校验器`,
  };
}

/**
 * 组合场景六（压测能力域）：压测上下文 → `load-profile` 出负载模型与压测套件。
 * @param {string} root 临时根
 * @param {string} work 工作目录
 * @returns {{ok: boolean, message: string}} 场景结论
 */
function scenarioLoadProfile(root, work) {
  const skillsDir = path.join(root, 'skills');
  const maker = path.join(skillsDir, 'load-profile', 'scripts', 'make-load-profile.mjs');
  const loader = path.join(skillsDir, 'test-execute', 'scripts', 'lib', 'suite-loader.mjs');
  const missing = [];
  for (const file of [maker, loader]) {
    if (!fs.existsSync(file)) missing.push(path.relative(root, file));
  }
  if (missing.length > 0) {
    return { ok: false, message: `临时根里缺这些必需文件: ${missing.join(' / ')}` };
  }

  // --- 夹具：压测上下文 / 功能用例集 / 最小项目根 ---
  const project = path.join(work, 'load-profile-proj');
  const inputsDir = path.join(project, 'inputs');
  const envDir = path.join(project, 'test-assets', 'environments');
  fs.mkdirSync(inputsDir, { recursive: true });
  fs.mkdirSync(envDir, { recursive: true });

  const context = {
    schema_version: 1,
    service: { name: 'order-api', description: '订单服务' },
    environments: [
      { name: 'local', base_url: 'http://127.0.0.1:8080' },
      { name: 'staging', base_url: 'https://staging.example.com' },
    ],
    workloads: [
      {
        id: 'WL-001', name: 'checkout', target: 'POST /api/v1/checkout', environment: 'local',
        profile: { type: 'ramp-up', steps: [{ duration_s: 60, concurrency: 10 }, { duration_s: 120, concurrency: 20 }] },
        thresholds: { p95_latency_ms: 800, error_rate: 0.01 },
        thresholds_source: '需求 REQ-005 性能指标',
        tool: { runner: 'loadtest', runtime: 'bun' },
        args: { rps: 100, keepalive: true },
        requirement_refs: ['R-1'],
      },
      {
        // 刻意**不给指标来源** ⇒ 产物不许有阈值键，且必须留一条 topic=thresholds 的未决问题
        id: 'WL-002', name: 'order-query', target: 'GET /api/v1/orders', environment: 'local',
        profile: { type: 'constant', steps: [{ duration_s: 300, concurrency: 5 }] },
        tool: { runner: 'loadtest', runtime: 'bun' },
        requirement_refs: ['R-2'],
      },
      {
        id: 'WL-003', name: 'checkout-staging', target: 'POST /api/v1/checkout', environment: 'staging',
        profile: { type: 'spike', steps: [{ duration_s: 30, concurrency: 50 }] },
        thresholds: { p95_latency_ms: 1200 },
        thresholds_source: '需求 REQ-007 性能指标',
        tool: { runner: 'python', runtime: 'python' },
        requirement_refs: ['R-1'],
      },
      {
        // 刻意**在功能用例集里没有对应用例** ⇒ case_refs 为空，且必须留一条 topic=coverage 的未决问题
        id: 'WL-004', name: 'health-check', target: 'GET /api/v1/health', environment: 'local',
        profile: { type: 'soak', steps: [{ duration_s: 600, concurrency: 2 }] },
        thresholds: { p95_latency_ms: 200 },
        thresholds_source: '需求 REQ-008 性能指标',
        tool: { runner: 'loadtest', runtime: 'bun' },
        requirement_refs: ['R-2'],
      },
    ],
    open_questions: [],
  };
  const functionalCases = {
    schema_version: 2,
    meta: { source: 'REQ-VERIFY 需求文档', generated_at: '2026-01-01T00:00:00+08:00', case_count: 3 },
    requirements: [
      { id: 'R-1', title: '下单链路', source_ref: 'REQ-VERIFY §1', testable: true },
      { id: 'R-2', title: '订单查询', source_ref: 'REQ-VERIFY §2', testable: true },
    ],
    open_questions: [],
    coverage_matrix: [
      { requirement: 'R-1', methods_applied: ['M1.1'], skipped: [], dimensions: ['functional'] },
      { requirement: 'R-2', methods_applied: ['M1.1'], skipped: [], dimensions: ['functional'] },
    ],
    defects: [],
    cases: [
      {
        id: 'TC-001', title: '下单成功返回订单号', requirement_refs: ['R-1'], dimension: 'functional',
        priority: 'P0', method: ['M1.1'], status: 'active', preconditions: [],
        steps: [{ action: 'POST /api/v1/checkout', expected: '返回 201 与 orderId' }], data: {}, tags: ['functional'],
      },
      {
        // action 带路径占位符 ⇒ 对账必须**归一化**后才能匹配 WL-002 的 target
        id: 'TC-002', title: '按订单号查询订单', requirement_refs: ['R-2'], dimension: 'functional',
        priority: 'P0', method: ['M1.1'], status: 'active', preconditions: [],
        steps: [{ action: 'GET /api/v1/orders/{id}', expected: '返回 200 与订单详情' }], data: {}, tags: ['functional'],
      },
      {
        id: 'TC-003', title: '查询用户资料', requirement_refs: ['R-2'], dimension: 'functional',
        priority: 'P1', method: ['M1.1'], status: 'active', preconditions: [],
        steps: [{ action: 'GET /api/v1/users/{id}/profile', expected: '返回 200 与用户资料' }], data: {}, tags: ['functional'],
      },
    ],
  };
  // ⚠️ 环境**不写** driver：写了会覆盖 suite.json 的 executor=load，误配对到 api/mock 执行器，
  //    「能跑通」就变成了假象（压测执行属后续 REQ）。
  const localEnvironment = {
    name: 'local', base_url: 'http://127.0.0.1:8080', timeout_ms: 5000, retries: 0,
    credentials: { username_env: 'ORDER_API_USER', password_env: 'ORDER_API_PASS' },
  };
  const stagingEnvironment = {
    name: 'staging', base_url: 'https://staging.example.com', timeout_ms: 5000, retries: 0,
    credentials: { username_env: 'STAGING_USER', password_env: 'STAGING_PASS' },
  };

  const contextFile = path.join(inputsDir, 'context.json');
  const casesFile = path.join(inputsDir, 'cases.json');
  fs.writeFileSync(contextFile, `${JSON.stringify(context, null, 2)}\n`, 'utf8');
  fs.writeFileSync(casesFile, `${JSON.stringify(functionalCases, null, 2)}\n`, 'utf8');
  fs.writeFileSync(path.join(envDir, 'local.json'), `${JSON.stringify(localEnvironment, null, 2)}\n`, 'utf8');
  fs.writeFileSync(path.join(envDir, 'staging.json'), `${JSON.stringify(stagingEnvironment, null, 2)}\n`, 'utf8');
  const contextShaBefore = sha256Of(contextFile);
  const casesShaBefore = sha256Of(casesFile);

  // --- 实跑 ---
  const run = runNode(maker, ['--context', contextFile, '--cases', casesFile, '--out-dir', project], work);
  if (run.code !== 0) {
    const detail = runOutputDetail(run);
    return {
      ok: false,
      message: `load-profile 出负载模型失败（退出码 ${run.code}）${detail === '' ? '' : `\n${detail}`}`,
    };
  }

  const loadRoot = path.join(project, 'test-assets', 'load');
  const problems = [];

  // --- 字段集基线 ---
  const SCENARIO_ALLOWED = [
    'schema_version', 'id', 'name', 'service', 'target', 'environment', 'profile',
    'thresholds', 'thresholds_source', 'thresholds_status', 'tool', 'args',
    'traceability', 'open_questions',
  ];
  const SCENARIO_REQUIRED = [
    'schema_version', 'id', 'name', 'service', 'target', 'environment', 'profile',
    'thresholds_status', 'tool', 'traceability', 'open_questions',
  ];
  const SUITE_ALLOWED = [
    'suite', 'requirement', 'scope', 'environment', 'cases_file', 'executor',
    'base_url_from', 'tags', 'report',
  ];
  const PROFILE_TYPES = ['constant', 'ramp-up', 'ramp-down', 'spike', 'soak'];
  const RUNNERS = ['loadtest', 'python'];
  const RUNTIMES = ['bun', 'python', 'node'];
  const THRESHOLD_KEYS = [
    'p50_latency_ms', 'p95_latency_ms', 'p99_latency_ms',
    'error_rate', 'throughput_rps', 'max_concurrency',
  ];
  const TOPICS = ['thresholds', 'coverage', 'runner', 'other'];
  const FORBIDDEN_KEYS = ['status', 'result', 'verdict', 'executed', 'passed', 'outcome', 'conclusion'];

  /** 递归扫压测结论键 / method 键。 */
  const scanForbidden = (node, where, hits) => {
    if (Array.isArray(node)) {
      node.forEach((item, index) => scanForbidden(item, `${where}[${index}]`, hits));
      return;
    }
    if (node === null || typeof node !== 'object') return;
    for (const [key, value] of Object.entries(node)) {
      if (FORBIDDEN_KEYS.includes(key)) hits.push(`${where}.${key}`);
      if (key === 'method') hits.push(`${where}.method`);
      scanForbidden(value, `${where}.${key}`, hits);
    }
  };

  // --- 负载模型本体 ---
  const scenarioDir = path.join(loadRoot, 'scenarios');
  let scenarioFiles = [];
  try {
    scenarioFiles = fs.readdirSync(scenarioDir).filter((name) => name.endsWith('.json')).sort();
  } catch {
    problems.push(`没有产出负载模型目录: ${path.relative(root, scenarioDir)}`);
  }
  const expectedScenarioNames = ['checkout', 'checkout-staging', 'health-check', 'order-query'];
  const actualScenarioNames = scenarioFiles.map((name) => name.replace(/\.json$/, '')).sort();
  if (actualScenarioNames.join(',') !== expectedScenarioNames.join(',')) {
    problems.push(`负载模型文件名集合不对: [${actualScenarioNames.join(', ')}]`);
  }
  const bodies = new Map();
  for (const file of scenarioFiles) {
    const name = file.replace(/\.json$/, '');
    if (!/^[a-z0-9][a-z0-9-]*$/.test(name)) problems.push(`场景文件名不合命名约定: ${file}`);
    let doc = null;
    try {
      doc = JSON.parse(fs.readFileSync(path.join(scenarioDir, file), 'utf8'));
    } catch (err) {
      problems.push(`场景 ${file} 不是合法 JSON（${err.message}）`);
      continue;
    }
    bodies.set(name, doc);
    for (const key of Object.keys(doc)) {
      if (!SCENARIO_ALLOWED.includes(key)) problems.push(`场景 ${file} 出现表外顶层字段 ${key}`);
    }
    for (const key of SCENARIO_REQUIRED) {
      if (!(key in doc)) problems.push(`场景 ${file} 缺必填字段 ${key}`);
    }
    if (doc.name !== name) problems.push(`场景 ${file} 的 name(${doc.name}) 与文件名不一致`);
    if (doc.schema_version !== 1) problems.push(`场景 ${file} 的 schema_version 不是 1`);
    if (!PROFILE_TYPES.includes(doc.profile && doc.profile.type)) {
      problems.push(`场景 ${file} 的 profile.type 非法: ${doc.profile && doc.profile.type}`);
    }
    if (!RUNNERS.includes(doc.tool && doc.tool.runner)) {
      problems.push(`场景 ${file} 的 tool.runner 非法: ${doc.tool && doc.tool.runner}`);
    }
    if (!RUNTIMES.includes(doc.tool && doc.tool.runtime)) {
      problems.push(`场景 ${file} 的 tool.runtime 非法: ${doc.tool && doc.tool.runtime}`);
    }
    if (doc.thresholds && typeof doc.thresholds === 'object') {
      for (const key of Object.keys(doc.thresholds)) {
        if (!THRESHOLD_KEYS.includes(key)) problems.push(`场景 ${file} 的 thresholds 出现表外键 ${key}`);
      }
    }
    // --- 阈值二态：键的有无 ---
    const hasThresholds = 'thresholds' in doc;
    const hasSource = 'thresholds_source' in doc;
    if (doc.thresholds_status === 'provided') {
      if (!hasThresholds || !hasSource) problems.push(`场景 ${file} 声称有来源却缺阈值键`);
    } else if (doc.thresholds_status === 'not_provided') {
      if (hasThresholds || hasSource) problems.push(`场景 ${file} 没有指标来源却写了阈值键`);
    } else {
      problems.push(`场景 ${file} 的 thresholds_status 取值非法: ${doc.thresholds_status}`);
    }
    // --- 追溯 ---
    const workload = context.workloads.find((one) => one.id === doc.id);
    if (!workload) {
      problems.push(`场景 ${file} 的 id ${doc.id} 不在上下文里`);
    } else {
      if (doc.target !== workload.target) problems.push(`场景 ${file} 的 target 与输入不一致`);
      if (doc.environment !== workload.environment) problems.push(`场景 ${file} 的 environment 与输入不一致`);
      if (doc.service !== context.service.name) problems.push(`场景 ${file} 的 service 与输入不一致`);
      if (JSON.stringify(doc.profile) !== JSON.stringify(workload.profile)) {
        problems.push(`场景 ${file} 的 profile 与输入不一致（含步序）`);
      }
      if (JSON.stringify(doc.tool) !== JSON.stringify(workload.tool)) {
        problems.push(`场景 ${file} 的 tool 与输入不一致`);
      }
      const expectedRefs = workload.name === 'health-check'
        ? []
        : (workload.name === 'order-query' ? ['TC-002'] : ['TC-001']);
      const actualRefs = (doc.traceability && doc.traceability.case_refs) || [];
      if (JSON.stringify(actualRefs) !== JSON.stringify(expectedRefs)) {
        problems.push(`场景 ${file} 的 case_refs 不对: [${actualRefs.join(', ')}]（应为 [${expectedRefs.join(', ')}]）`);
      }
      if (!doc.traceability || doc.traceability.workload_id !== workload.id) {
        problems.push(`场景 ${file} 的 traceability.workload_id 与输入不一致`);
      }
    }
    // --- 未决问题 ---
    const questions = Array.isArray(doc.open_questions) ? doc.open_questions : [];
    const thresholdQuestions = questions.filter((item) => item.topic === 'thresholds');
    if (doc.thresholds_status === 'not_provided' && thresholdQuestions.length < 1) {
      problems.push(`场景 ${file} 没有指标来源却没有 topic=thresholds 的未决问题`);
    }
    if (doc.thresholds_status === 'provided' && thresholdQuestions.length > 0) {
      problems.push(`场景 ${file} 有指标来源却留了 topic=thresholds 的未决问题`);
    }
    const caseRefs = (doc.traceability && doc.traceability.case_refs) || [];
    if (caseRefs.length === 0 && !questions.some((item) => item.topic === 'coverage')) {
      problems.push(`场景 ${file} 没有对应用例却没有 topic=coverage 的未决问题`);
    }
    for (const question of questions) {
      const keys = Object.keys(question).sort();
      if (keys.join(',') !== 'id,question,topic') {
        problems.push(`场景 ${file} 的未决问题字段集不对: {${keys.join(', ')}}`);
      }
      if (!/^OQ-\d{3}$/.test(String(question.id))) problems.push(`场景 ${file} 的未决问题 id 非法: ${question.id}`);
      if (!TOPICS.includes(question.topic)) problems.push(`场景 ${file} 的未决问题 topic 非法: ${question.topic}`);
      if (typeof question.question !== 'string' || question.question.trim() === '') {
        problems.push(`场景 ${file} 的未决问题 question 为空`);
      }
    }
    const hits = [];
    scanForbidden(doc, file, hits);
    if (hits.length > 0) problems.push(`场景 ${file} 出现压测结论键/method: ${hits.join(', ')}`);
  }

  // --- 套件 ---
  const suitesDir = path.join(loadRoot, 'suites');
  let suiteDirs = [];
  try {
    suiteDirs = fs.readdirSync(suitesDir).filter((name) => fs.statSync(path.join(suitesDir, name)).isDirectory()).sort();
  } catch {
    problems.push('没有产出压测套件目录');
  }
  const expectedSuiteNames = ['LOAD-001-checkout', 'LOAD-002-checkout-staging'];
  if (suiteDirs.join(',') !== expectedSuiteNames.join(',')) {
    problems.push(`套件目录集合不对: [${suiteDirs.join(', ')}]`);
  }
  const referenced = new Map();
  for (const dirName of suiteDirs) {
    if (!/^LOAD-\d{3}-[a-z0-9][a-z0-9-]*$/.test(dirName)) {
      problems.push(`套件目录名不合规: ${dirName}`);
    }
    const suiteDir = path.join(suitesDir, dirName);
    const suiteFile = path.join(suiteDir, 'suite.json');
    const refFile = path.join(suiteDir, 'scenario.json');
    if (!fs.existsSync(suiteFile)) {
      problems.push(`套件 ${dirName} 缺 suite.json`);
      continue;
    }
    if (!fs.existsSync(refFile)) {
      problems.push(`套件 ${dirName} 缺 scenario.json`);
      continue;
    }
    if (fs.existsSync(path.join(suiteDir, 'cases.json'))) {
      problems.push(`套件 ${dirName} 里有 cases.json（压测套件不产出 cases.json）`);
    }
    let suite = null;
    let ref = null;
    try {
      suite = JSON.parse(fs.readFileSync(suiteFile, 'utf8'));
      ref = JSON.parse(fs.readFileSync(refFile, 'utf8'));
    } catch (err) {
      problems.push(`套件 ${dirName} 的产物不是合法 JSON（${err.message}）`);
      continue;
    }
    for (const key of Object.keys(suite)) {
      if (!SUITE_ALLOWED.includes(key)) problems.push(`套件 ${dirName} 的 suite.json 出现未声明的字段 ${key}`);
    }
    for (const key of ['suite', 'requirement', 'scope', 'environment', 'cases_file', 'executor']) {
      if (typeof suite[key] !== 'string' || suite[key].trim() === '') {
        problems.push(`套件 ${dirName} 的 suite.json 缺必填字段 ${key}`);
      }
    }
    if (suite.suite !== dirName) problems.push(`套件 ${dirName} 的 suite 名与目录名不一致`);
    if (suite.scope !== 'load') problems.push(`套件 ${dirName} 的 scope 不是 load`);
    if (suite.executor !== 'load') problems.push(`套件 ${dirName} 的 executor 不是 load`);
    if (suite.cases_file !== 'scenario.json') problems.push(`套件 ${dirName} 的 cases_file 不是 scenario.json`);
    if (!fs.existsSync(path.join(project, 'test-assets', 'environments', `${suite.environment}.json`))) {
      problems.push(`套件 ${dirName} 引用的环境不存在: ${suite.environment}`);
    }
    const refKeys = Object.keys(ref).sort();
    if (refKeys.join(',') !== 'scenarios,schema_version,suite') {
      problems.push(`套件 ${dirName} 的 scenario.json 顶层字段集不对: {${refKeys.join(', ')}}`);
    }
    if (ref.schema_version !== 1) problems.push(`套件 ${dirName} 的 scenario.json schema_version 不是 1`);
    if (ref.suite !== dirName) problems.push(`套件 ${dirName} 的 scenario.json 的 suite 与目录名不一致`);
    if (!Array.isArray(ref.scenarios) || ref.scenarios.length < 1) {
      problems.push(`套件 ${dirName} 的 scenario.json 的 scenarios 必须是非空数组`);
      continue;
    }
    for (const entry of ref.scenarios) {
      const entryKeys = Object.keys(entry).sort();
      if (entryKeys.join(',') !== 'id,name,path') {
        problems.push(`套件 ${dirName} 的引用元素字段集不对: {${entryKeys.join(', ')}}`);
      }
      const abs = path.resolve(suiteDir, entry.path);
      if (!fs.existsSync(abs)) {
        problems.push(`套件 ${dirName} 的引用指向不存在的文件: ${entry.path}`);
        continue;
      }
      if (!abs.startsWith(scenarioDir + path.sep)) {
        problems.push(`套件 ${dirName} 的引用越出 scenarios/: ${entry.path}`);
      }
      const body = JSON.parse(fs.readFileSync(abs, 'utf8'));
      if (body.id !== entry.id || body.name !== entry.name) {
        problems.push(`套件 ${dirName} 的引用与本体漂移: ${entry.id}/${entry.name}`);
      }
      if (body.environment !== suite.environment) {
        problems.push(`套件 ${dirName} 内的场景 ${body.id} 的 environment 与套件不一致`);
      }
      referenced.set(body.id, (referenced.get(body.id) || 0) + 1);
    }
  }

  // --- 双向覆盖完整性 ---
  for (const workload of context.workloads) {
    const count = referenced.get(workload.id) || 0;
    if (count !== 1) problems.push(`容量目标 ${workload.id} 被 ${count} 个套件引用（应为恰好 1 个）`);
  }
  for (const body of bodies.values()) {
    if ((referenced.get(body.id) || 0) < 1) problems.push(`场景模型 ${body.id} 是孤儿场景（没有任何套件引用）`);
  }

  // --- 压测计划清单 ---
  const reportFile = path.join(loadRoot, 'report.json');
  if (!fs.existsSync(reportFile)) {
    problems.push('没有产出 report.json');
  } else {
    const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
    const reportKeys = Object.keys(report).sort();
    if (reportKeys.join(',') !== 'open_questions,scenarios,schema_version,service,suites') {
      problems.push(`report.json 的顶层字段集不对: {${reportKeys.join(', ')}}`);
    }
    const hits = [];
    scanForbidden(report, 'report.json', hits);
    if (hits.length > 0) problems.push(`report.json 出现压测结论键/method: ${hits.join(', ')}`);
  }

  // --- 不该有执行产物（本 REQ 只做规划） ---
  for (const name of ['runs', 'evidence']) {
    if (fs.existsSync(path.join(project, name))) problems.push(`跑完之后出现了执行产物目录: ${name}`);
  }

  // --- 输入只读 ---
  if (sha256Of(contextFile) !== contextShaBefore) problems.push('压测上下文被改写了');
  if (sha256Of(casesFile) !== casesShaBefore) problems.push('功能用例集被改写了');

  // --- 加载层可消费（问上游本人） ---
  const loadcheckFile = path.join(work, 'load-profile-loadcheck.mjs');
  fs.writeFileSync(loadcheckFile, `${LOADCHECK_LOAD_SOURCE}\n`, 'utf8');
  const loaded = runNode(loadcheckFile, [loadRoot, loader], work);
  if (loaded.code !== 0) {
    const detail = runOutputDetail(loaded);
    problems.push(`加载层消费失败（退出码 ${loaded.code}）${detail === '' ? '' : `\n${detail}`}`);
  } else {
    let report = null;
    try {
      report = JSON.parse(loaded.stdout.trim());
    } catch {
      problems.push('加载层检查没有输出可解析的结果');
    }
    if (Array.isArray(report)) {
      for (const item of report) {
        if (item.scope !== 'load' || item.executor !== 'load') {
          problems.push(`套件 ${item.suite} 被上游加载层读成了 scope=${item.scope} / executor=${item.executor}`);
        }
        if (item.casesFileExists !== true) {
          problems.push(`套件 ${item.suite} 的 cases_file 解析不到真实存在的文件`);
        }
      }
    }
  }

  if (problems.length > 0) {
    return {
      ok: false,
      message: `load-profile 的产物不自洽: ${problems.join('; ')}`,
    };
  }

  return {
    ok: true,
    message:
      `load-profile 的规划链路（make-load-profile.mjs 读压测上下文 + 功能用例集）→ ` +
      `负载模型 ${bodies.size} 个（阈值二态与键的有无一致、无来源的 ${context.workloads.filter((one) => !('thresholds' in one)).length} 个已留未决问题）、` +
      `压测套件 ${suiteDirs.length} 个（按环境分组、引用不漂移、覆盖双向完整）、` +
      `产物可被上游加载层消费且不含任何压测结论字段`,
  };
}

/** 加载层检查脚本的源码（在临时目录里现生成现跑 —— 问上游 loader 本人「能不能被消费」）。 */
const LOADCHECK_SOURCE = [
  "import fs from 'node:fs';",
  "import path from 'node:path';",
  "import { pathToFileURL } from 'node:url';",
  "const [root, loaderPath] = process.argv.slice(2);",
  'const loader = await import(pathToFileURL(loaderPath).href);',
  "const suitesDir = path.join(root, 'suites');",
  'const out = [];',
  "for (const name of fs.readdirSync(suitesDir).sort()) {",
  "  const suiteFile = path.join(suitesDir, name, 'suite.json');",
  '  const { config, casesFile } = loader.loadSuite(suiteFile);',
  '  const { cases } = loader.loadCases(casesFile);',
  '  const selected = loader.selectCases(cases, config.tags);',
  '  out.push({ suite: name, total: cases.length, selected: selected.length });',
  '}',
  'process.stdout.write(`${JSON.stringify(out)}\\n`);',
].join('\n');

/**
 * 压测套件的加载层检查脚本源码（问上游 loader 本人「load 套件能不能被消费」）。
 *
 * ⚠️ **只问加载层**：上游的 `loadCases()` 硬要求 `doc.cases` 是数组 ⇒ 场景文件**不能**做成
 *    cases 形态；`load` 执行器也**尚未实现** ⇒ 这里**不**要求 dry-run 跑通。
 */
const LOADCHECK_LOAD_SOURCE = [
  "import fs from 'node:fs';",
  "import path from 'node:path';",
  "import { pathToFileURL } from 'node:url';",
  "const [root, loaderPath] = process.argv.slice(2);",
  'const loader = await import(pathToFileURL(loaderPath).href);',
  "const suitesDir = path.join(root, 'suites');",
  'const out = [];',
  "for (const name of fs.readdirSync(suitesDir).sort()) {",
  "  const suiteFile = path.join(suitesDir, name, 'suite.json');",
  '  const { config, casesFile } = loader.loadSuite(suiteFile);',
  '  out.push({',
  '    suite: name,',
  '    scope: config.scope,',
  '    executor: config.executor,',
  '    casesFileExists: fs.existsSync(casesFile),',
  '  });',
  '}',
  'process.stdout.write(`${JSON.stringify(out)}\\n`);',
].join('\n');

/**
 * 组合门主流程。
 * @param {string|undefined} rootArg 命令行给的安装根
 * @returns {number} 退出码
 */
export function runVerify(rootArg) {
  const useTempRoot = !(typeof rootArg === 'string' && rootArg.trim() !== '');
  const root = useTempRoot
    ? fs.mkdtempSync(path.join(os.tmpdir(), 'test-agent-skills-verify-'))
    : path.resolve(rootArg);
  // 每次跑用**独立**的工作目录：cycle-state.mjs 的 init 不覆盖已有 cycle.json，
  // 若沿用同一个固定工作目录，第二次跑就会撞上第一次留下的轮次而假失败。
  const work = path.join(root, '.verify-work', `${process.pid}-${Date.now()}`);

  console.log(`[info] 组合门临时根: ${root}`);

  try {
    return runVerifyIn(root, work);
  } finally {
    // 只有**自己建的默认临时根**才清理；调用方给的 --root 是持久根，绝不清理。
    if (useTempRoot) cleanupTempRoot(root);
  }
}

/**
 * 清理默认临时根（清理失败不影响退出码）。
 * @param {string} root 临时根
 */
function cleanupTempRoot(root) {
  try {
    fs.rmSync(root, { recursive: true, force: true });
    console.log(`[info] 默认临时根已清理: ${root}`);
  } catch (err) {
    const detail = err && err.message ? err.message : String(err);
    console.warn(`[warn] 默认临时根清理失败（不影响退出码）: ${root}（${detail}）`);
  }
}

/**
 * 组合门主流程（根与工作目录已定）。
 * @param {string} root 安装根
 * @param {string} work 本次跑的工作目录
 * @returns {number} 退出码
 */
function runVerifyIn(root, work) {
  if (!fs.existsSync(SKILLS_SRC)) {
    console.error(`[error] 包里没有 skills/ 目录: ${SKILLS_SRC}`);
    return 1;
  }

  // ① 把包装到临时根
  const installed = [];
  for (const entry of fs.readdirSync(SKILLS_SRC, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const dir = path.join(SKILLS_SRC, entry.name);
    if (!fs.existsSync(path.join(dir, 'SKILL.md'))) continue;
    copyDir(dir, path.join(root, 'skills', entry.name));
    installed.push(entry.name);
  }
  if (installed.length === 0) {
    console.error('[error] 临时根里一个 skill 都没装上');
    return 1;
  }
  console.log(`[ok] 已装到临时根的 skill（${installed.length} 个）: ${installed.join(', ')}`);

  // ② 校验依赖图（版本配套）—— 不满足就**先**报版本问题，不进入场景
  const metas = installed.map((name) => readMeta(path.join(root, 'skills', name)));
  const shapeProblems = metas.flatMap((meta) => meta.problems);
  const graphProblems = checkGraph(metas);
  if (shapeProblems.length > 0 || graphProblems.length > 0) {
    for (const problem of shapeProblems) console.error(`[error] ${problem}`);
    for (const problem of graphProblems) console.error(problem);
    console.error('[error] 依赖图校验未通过 —— 不进入跨 skill 组合场景（版本错配不该表现为下游业务错）');
    return 1;
  }
  console.log(`[ok] 依赖图校验通过（${metas.length} 个 skill 的版本声明与 requires 全部满足）`);

  // ③ 实跑跨 skill 组合场景
  fs.mkdirSync(work, { recursive: true });
  const scenarios = [
    scenarioOffline(root, work),
    scenarioCycle(root, work),
    scenarioReport(root, work),
    scenarioDefectVerify(root, work),
    scenarioSecurityPlan(root, work),
    scenarioLoadProfile(root, work),
  ];
  let failed = 0;
  for (const scenario of scenarios) {
    if (scenario.ok) console.log(`[ok] 组合场景: ${scenario.message}`);
    else {
      failed += 1;
      console.error(`[error] 组合场景失败: ${scenario.message}`);
    }
  }
  if (failed > 0) {
    console.error(`[error] 组合门未通过: ${failed} 个场景失败`);
    return 1;
  }
  console.log('[ok] 组合门全部通过');
  return 0;
}
