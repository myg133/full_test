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
 *        （这条链路经过 test-execute → test-case-design 的**硬跨 skill 依赖**）。
 *
 * 退出码：0 = 全通过 / 1 = 有问题 / 2 = 用法错误。
 *
 * 约束：零第三方依赖、不联网；输出里**不得**出现下游业务错的特征串
 * （版本错配要报成「版本问题」，不能报成「用例字段不对」）。
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
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
  if (!fs.existsSync(suite) || !fs.existsSync(runner)) {
    return { ok: false, message: '临时根里没有 test-execute 的 offline 夹具' };
  }
  const outputDir = path.join(work, 'exec-offline');
  const run = runNode(runner, [suite, '--project-root', offlineDir, '--output-dir', outputDir, '--run-id', 'verify-offline'], work);
  if (run.code !== 0) {
    return { ok: false, message: `offline 夹具执行失败（退出码 ${run.code}）` };
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
  if (!fs.existsSync(suite) || !fs.existsSync(runner) || !fs.existsSync(stateScript)) {
    return { ok: false, message: '临时根里缺 cycle-state.mjs / run-suite.mjs / offline 夹具' };
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
  if (init.code !== 0) return { ok: false, message: `轮次初始化失败（退出码 ${init.code}）` };

  const outputDir = path.join(work, 'exec-cycle');
  const run = runNode(
    runner,
    [suite, '--project-root', offlineDir, '--output-dir', outputDir, '--run-id', 'verify-cycle', '--cycle', cycleDir],
    work,
  );
  if (run.code !== 0) return { ok: false, message: `带轮次推进的执行失败（退出码 ${run.code}）` };

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
 * 组合门主流程。
 * @param {string|undefined} rootArg 命令行给的安装根
 * @returns {number} 退出码
 */
export function runVerify(rootArg) {
  const root =
    typeof rootArg === 'string' && rootArg.trim() !== ''
      ? path.resolve(rootArg)
      : fs.mkdtempSync(path.join(os.tmpdir(), 'test-agent-skills-verify-'));
  const work = path.join(root, '.verify-work');

  console.log(`[info] 组合门临时根: ${root}`);

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
  const scenarios = [scenarioOffline(root, work), scenarioCycle(root, work)];
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
