// load-exec.mjs —— 负载级**执行器 + 判定器**（零第三方依赖，只用 node: 内置模块）
//
// 契约（F1~F10 / D185~D210）：
//   - **只打本地桩**：目标地址必须是回环地址；非回环 ⇒ rc=1 + 点名（绝不打真实服务）；
//   - **两种执行模式**：`api`（默认，import `loadtest` 包拿结构化 `Result`）/ `cli`（逐字 spawn 计划里的 argv）；
//   - **argv → API 选项必须反解**（两套名字不是一套）：`maxSeconds` / `concurrency` / `requestsPerSecond` /
//!     `agentKeepAlive` / `timeout` / `method`；反解只接受 REQ-012 的规范形态，**规范外 ⇒ rc=1 + 点名**；
//   - **必须设 `statusCallback`**（不设 ⇒ HTTP 错误状态码全塌成 `-1` ⇒ 错误码分类能力丢失）；
//   - **必须防 `.loadtestrc` 渗透**：显式覆盖每个相关选项 + **显式禁 `proxy`**（⇒ 在干净的沙箱目录里跑）；
//   - **判定不得依赖进程退出码**（桩中途挂掉时压测工具仍然 rc=0）⇒ 只看观测量；
//   - **默认桩下**（未注入延迟与错误）延迟类 / 错误率类阈值**判「不可判定」**，吞吐类仍可判；
//   - **`max_concurrency` 恒判「不可判定」**（不许拿 `concurrency` / `clients` 冒充实际并发）；
//   - **只写** `<out-dir>/test-assets/load/results/`；输入只读；产物已存在 ⇒ rc=1 **不覆盖**。

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import process from 'node:process';
import { spawn } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';

import {
  InputError, StateError, UsageError, ensureDir, pathExists, readJsonFile, writeJsonFile,
} from './io.mjs';
import { Stub } from './stub.mjs';

/** 阈值键白名单（**封闭 6 个**，REQ-009 `profile-rules.md`；**不得增删**）。 */
export const THRESHOLD_KEYS = [
  'p50_latency_ms',
  'p95_latency_ms',
  'p99_latency_ms',
  'error_rate',
  'throughput_rps',
  'max_concurrency',
];

/** 判定枚举（**封闭 3 值**）。 */
export const VERDICTS = ['met', 'not_met', 'undetermined'];

/** 结果产物顶层键集（**封闭 8 个**）。 */
export const TOP_KEYS = [
  'schema_version',
  'suite',
  'environment',
  'generated_at',
  'execution',
  'scenarios',
  'verdict',
  'results_sha256',
];

/** `execution` 段的必填键（6 个）+ 条件键（`cli`，**仅** `cli_verbatim` 模式存在）。 */
export const EXECUTION_KEYS = ['mode', 'started_at', 'finished_at', 'duration_ms', 'tool', 'stub'];

/** `observed` 段的键集（**封闭 10 个**）。 */
export const OBSERVED_KEYS = [
  'total_requests',
  'total_errors',
  'error_codes',
  'error_rate',
  'mean_latency_ms',
  'effective_rps',
  'percentiles',
  'max_latency_ms',
  'min_latency_ms',
  'elapsed_seconds',
];

/** `stub_observed` 段的键集（**封闭 9 个**）。 */
export const STUB_OBSERVED_KEYS = [
  'requests',
  'errors',
  'error_rate',
  'mean_ms',
  'min_ms',
  'max_ms',
  'histogram_ms',
  'first_at_ms',
  'last_at_ms',
];

/** 阈值判定条目的键集（**封闭 5 个**）。 */
export const THRESHOLD_ENTRY_KEYS = ['key', 'threshold', 'observed', 'verdict', 'reason'];

/** `verdict` 段的键集（**封闭 6 个**）。 */
export const VERDICT_SECTION_KEYS = [
  'suite',
  'invocations_total',
  'invocations_met',
  'invocations_not_met',
  'invocations_undetermined',
  'undetermined_keys',
];

/** 场景条目的键集（8 个必填 + 2 个条件）。 */
export const SCENARIO_KEYS = [
  'scenario_id',
  'scenario_name',
  'runner',
  'target',
  'base_url',
  'thresholds_status',
  'invocations',
  'verdict',
];

/** invocation 条目的键集（10 个；`python` runner 为 8 个）。 */
export const INVOCATION_KEYS = [
  'step_index',
  'duration_s',
  'concurrency',
  'argv',
  'executed_url',
  'executed_params',
  'observed',
  'stub_observed',
  'thresholds',
  'verdict',
];

// ---------------------------------------------------------------- 通用工具

/**
 * sha256（十六进制小写）。
 * @param {string|Buffer} data 待摘要的内容
 * @returns {string} 64 位小写十六进制
 */
export function sha256(data) {
  return crypto.createHash('sha256').update(data).digest('hex');
}

/**
 * 规范化序列化（排序键 + 紧凑分隔符）—— 与 REQ-010 / 需求方复算器**同款口径**。
 * @param {*} obj 待序列化对象
 * @returns {string} 规范化 JSON 文本
 */
export function canonicalJson(obj) {
  if (obj === null || typeof obj !== 'object') return JSON.stringify(obj);
  if (Array.isArray(obj)) return `[${obj.map(canonicalJson).join(',')}]`;
  const keys = Object.keys(obj).sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${canonicalJson(obj[k])}`).join(',')}}`;
}

/**
 * 是否是回环地址（`127.0.0.0/8` 或 `::1`）。
 * @param {string} host 主机名
 * @returns {boolean}
 */
export function isLoopbackHost(host) {
  if (!host) return false;
  const h = String(host).toLowerCase().replace(/^\[/, '').replace(/\]$/, '');
  if (h === '::1' || h === '0:0:0:0:0:0:0:1') return true;
  return /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(h);
}

/**
 * 深比较（键序无关）。
 * @param {*} a 左值
 * @param {*} b 右值
 * @returns {boolean}
 */
export function deepEqual(a, b) {
  return canonicalJson(a) === canonicalJson(b);
}

// ---------------------------------------------------------------- 参数解析

const OPTIONS = ['--load-dir', '--out-dir', '--suite', '--mode', '--stub-delay-ms', '--stub-error-rate'];

/**
 * 解析命令行参数（用法错误 ⇒ 退出码 2）。
 * @param {string[]} argv 参数数组（不含 node 与脚本路径）
 * @returns {object} 解析结果
 */
export function parseArgs(argv) {
  const out = {
    loadDir: '',
    outDir: '',
    suite: '',
    mode: 'api',
    stubDelayMs: 0,
    stubErrorRate: 0,
    help: false,
  };
  const slot = {
    '--load-dir': 'loadDir',
    '--out-dir': 'outDir',
    '--suite': 'suite',
    '--mode': 'mode',
    '--stub-delay-ms': 'stubDelayMs',
    '--stub-error-rate': 'stubErrorRate',
  };

  let i = 0;
  while (i < argv.length) {
    const arg = argv[i];
    if (arg === '-h' || arg === '--help') {
      out.help = true;
      i += 1;
      continue;
    }
    const eq = arg.indexOf('=');
    const name = eq > 2 ? arg.slice(0, eq) : arg;
    if (!OPTIONS.includes(name)) {
      if (!arg.startsWith('-')) {
        throw new UsageError(`多余的位置参数: ${arg}（本工具只认 ${OPTIONS.join(' / ')}）`);
      }
      throw new UsageError(`未知参数: ${arg}`);
    }
    let value = eq > 2 ? arg.slice(eq + 1) : undefined;
    if (value === undefined) {
      value = argv[i + 1];
      if (value === undefined || value.startsWith('--')) {
        throw new UsageError(`${name} 需要一个参数`);
      }
      i += 1;
    }
    if (value === '') throw new UsageError(`${name} 需要一个非空参数`);
    out[slot[name]] = value;
    i += 1;
  }

  if (out.help) return out;
  for (const name of ['--load-dir', '--out-dir', '--suite']) {
    if (!out[slot[name]]) throw new UsageError(`缺少必填参数: ${name}`);
  }
  if (!['api', 'cli'].includes(out.mode)) {
    throw new UsageError(`--mode 的取值必须是 api 或 cli（实际 ${JSON.stringify(out.mode)}）`);
  }
  const delay = Number(out.stubDelayMs);
  if (!Number.isInteger(delay) || delay < 0) {
    throw new UsageError(`--stub-delay-ms 必须是 ≥ 0 的整数（实际 ${JSON.stringify(out.stubDelayMs)}）`);
  }
  out.stubDelayMs = delay;
  const rate = Number(out.stubErrorRate);
  if (!Number.isFinite(rate) || rate < 0 || rate > 1) {
    throw new UsageError(`--stub-error-rate 必须是 [0, 1] 之间的数值（实际 ${JSON.stringify(out.stubErrorRate)}）`);
  }
  out.stubErrorRate = rate;
  return out;
}

// ---------------------------------------------------------------- 输入（只读）

/**
 * 读压测计划（REQ-012 的产物，**只读**）。
 * @param {string} loadDir 项目根
 * @param {string} suite 套件名
 * @returns {object} 计划文档
 */
export function loadPlan(loadDir, suite) {
  const file = path.join(loadDir, 'test-assets', 'load', 'plans', `${suite}.json`);
  if (!pathExists(file)) {
    throw new InputError(`压测计划不存在: ${file}（套件 ${suite} 没有同名计划）`);
  }
  const plan = readJsonFile(file, '压测计划');
  if (!plan || typeof plan !== 'object' || Array.isArray(plan)) {
    throw new InputError(`压测计划不是合法对象: ${file}`);
  }
  return plan;
}

/**
 * 反解 REQ-012 的**规范形态** argv ⇒ API 选项 + 目标 URL。
 * ⚠️ **只接受规范形态**：规范外 ⇒ rc=1 + 点名（不许「尽力而为」地猜参数）。
 * @param {string[]} argv 计划里的 argv
 * @returns {{spec: object, url: string}} 反解结果
 */
export function reverseArgv(argv) {
  const fail = (detail) => {
    throw new InputError(`argv 不符合 REQ-012 的规范形态：${detail}`);
  };
  if (!Array.isArray(argv) || argv.length < 10) {
    fail(`至少要有 10 个元素（实际 ${Array.isArray(argv) ? argv.length : '不是数组'}）`);
  }
  if (argv[0] !== 'loadtest') fail(`第 1 个元素必须是 "loadtest"（实际 ${JSON.stringify(argv[0])}）`);
  if (argv[1] !== '-t') fail(`第 2 个元素必须是 "-t"（实际 ${JSON.stringify(argv[1])}）`);
  const maxSeconds = Number(argv[2]);
  if (!Number.isFinite(maxSeconds) || maxSeconds < 1) {
    fail(`"-t" 的取值必须是 ≥ 1 的秒数（实际 ${JSON.stringify(argv[2])}）`);
  }
  if (argv[3] !== '-c') fail(`第 4 个元素必须是 "-c"（实际 ${JSON.stringify(argv[3])}）`);
  const concurrency = Number(argv[4]);
  if (!Number.isInteger(concurrency) || concurrency < 1) {
    fail(`"-c" 的取值必须是 ≥ 1 的整数（实际 ${JSON.stringify(argv[4])}）`);
  }
  if (argv[5] !== '--cores') fail(`第 6 个元素必须是 "--cores"（实际 ${JSON.stringify(argv[5])}）`);
  if (argv[6] !== '1') fail(`"--cores" 的取值必须是 "1"（实际 ${JSON.stringify(argv[6])}）`);
  const url = String(argv[7]);
  if (argv[8] !== '-m') fail(`第 9 个元素必须是 "-m"（实际 ${JSON.stringify(argv[8])}）`);
  const method = String(argv[9]);

  const spec = {
    maxSeconds,
    concurrency,
    method,
    requestsPerSecond: null,
    agentKeepAlive: false,
    timeout: null,
  };
  let i = 10;
  let stage = 0;
  while (i < argv.length) {
    const token = argv[i];
    if (stage === 0 && token === '--rps') {
      if (argv.length - i < 2) fail('"--rps" 缺少取值');
      const rps = Number(argv[i + 1]);
      if (!Number.isFinite(rps) || rps <= 0) fail(`"--rps" 的取值必须是正数（实际 ${JSON.stringify(argv[i + 1])}）`);
      spec.requestsPerSecond = rps;
      i += 2;
      stage = 1;
      continue;
    }
    if (stage <= 1 && token === '-k') {
      spec.agentKeepAlive = true;
      i += 1;
      stage = 2;
      continue;
    }
    if (stage <= 2 && token === '-d') {
      if (argv.length - i < 2) fail('"-d" 缺少取值');
      const timeout = Number(argv[i + 1]);
      if (!Number.isFinite(timeout) || timeout <= 0) fail(`"-d" 的取值必须是正数（实际 ${JSON.stringify(argv[i + 1])}）`);
      spec.timeout = timeout;
      i += 2;
      stage = 3;
      continue;
    }
    fail(`第 ${i + 1} 个元素 ${JSON.stringify(token)} 不在规范形态里（可选参数只能是 --rps / -k / -d，且按此顺序）`);
  }
  return { spec, url };
}

/**
 * 校验目标是**回环地址**（只打本地桩 ⇒ 绝不打真实服务）。
 * @param {string} url 待校验的 URL
 * @param {string} where 位置标签（报错信息里用）
 * @returns {URL} 解析结果
 */
export function assertLoopbackUrl(url, where) {
  let parsed;
  try {
    parsed = new URL(String(url));
  } catch {
    throw new InputError(`${where} 的 URL 不可解析: ${JSON.stringify(url)}`);
  }
  if (!isLoopbackHost(parsed.hostname)) {
    throw new InputError(
      `${where} 的 URL 的 host 不是回环地址（只允许 127.0.0.0/8 或 ::1）：${url} —— 只打本地桩，绝不打真实服务`,
    );
  }
  return parsed;
}

/**
 * 校验计划（**输入非法 ⇒ rc=1 + 点名**）。
 * @param {object} plan 计划文档
 * @param {string} suite 套件名
 */
export function validatePlan(plan, suite) {
  if (plan.suite !== suite) {
    throw new InputError(`压测计划的 suite 字段与文件名不一致（计划 ${JSON.stringify(plan.suite)} vs 套件 ${suite}）`);
  }
  if (!Array.isArray(plan.scenarios) || plan.scenarios.length === 0) {
    throw new InputError('压测计划里没有场景（scenarios 必须是非空数组）');
  }
  plan.scenarios.forEach((scenario, si) => {
    const where = `场景 ${scenario && scenario.scenario_id ? scenario.scenario_id : `#${si}`}`;
    if (!scenario || typeof scenario !== 'object') {
      throw new InputError(`${where} 不是合法对象`);
    }
    if (!['loadtest', 'python'].includes(scenario.runner)) {
      throw new InputError(`${where} 的 runner 取值非法: ${JSON.stringify(scenario.runner)}（只允许 loadtest / python）`);
    }
    if (!Array.isArray(scenario.invocations) || scenario.invocations.length === 0) {
      throw new InputError(`${where} 没有 invocation（invocations 必须是非空数组）`);
    }
    const thresholds = scenario.thresholds || {};
    if (scenario.thresholds_status === 'provided') {
      if (!scenario.thresholds || typeof scenario.thresholds !== 'object') {
        throw new InputError(`${where} 的 thresholds_status 是 provided 但没有 thresholds`);
      }
      if (!scenario.thresholds_source) {
        throw new InputError(`${where} 的 thresholds_status 是 provided 但没有 thresholds_source`);
      }
    }
    for (const key of Object.keys(thresholds)) {
      if (!THRESHOLD_KEYS.includes(key)) {
        throw new InputError(
          `${where} 的阈值键 ${JSON.stringify(key)} 不在白名单内`
          + `（只允许 ${THRESHOLD_KEYS.join(' / ')}）`,
        );
      }
    }
    scenario.invocations.forEach((invocation, ii) => {
      const iwhere = `${where} 的第 ${ii} 条 invocation`;
      if (!invocation || typeof invocation !== 'object') {
        throw new InputError(`${iwhere} 不是合法对象`);
      }
      if (scenario.runner !== 'loadtest') return;
      const reversed = reverseArgv(invocation.argv);
      assertLoopbackUrl(reversed.url, `${iwhere} 的目标`);
    });
  });
}

// ---------------------------------------------------------------- 工具解析

/**
 * 解析压测工具（**不可用 ⇒ rc=1 + 明确报错**：点名缺什么、怎么装）。
 * @param {string} projectRoot 项目根（工具装在它的 `.tools/` 下）
 * @param {'api'|'cli'} mode 执行模式
 * @returns {{name: string, version: string, resolved_from: string, modulePath?: string, binPath?: string}}
 */
export function resolveTool(projectRoot, mode) {
  const tried = [];
  if (mode === 'api') {
    const candidates = [path.join(projectRoot, '.tools', 'node', 'node_modules', 'loadtest', 'index.js')];
    for (const dir of String(process.env.NODE_PATH || '').split(path.delimiter)) {
      if (!dir) continue;
      candidates.push(path.join(dir, 'loadtest', 'index.js'));
    }
    try {
      candidates.push(createRequire(import.meta.url).resolve('loadtest'));
    } catch {
      /* 解析路径上没有 loadtest：正常 */
    }
    for (const candidate of candidates) {
      if (!pathExists(candidate)) continue;
      return {
        name: 'loadtest',
        version: readToolVersion(candidate),
        resolved_from: candidate,
        modulePath: candidate,
      };
    }
    tried.push(...candidates);
    throw new InputError(
      '压测工具 loadtest 不可用：找不到 loadtest 模块'
      + `（找过: ${tried.join(' / ')}）—— 怎么装: node <交付包>/bin/qa install --project ${projectRoot}`
      + '（工具链会把 loadtest 装到 .tools/node/node_modules/）',
    );
  }

  const candidates = [path.join(projectRoot, '.tools', 'node', 'node_modules', '.bin', 'loadtest')];
  for (const dir of String(process.env.PATH || '').split(path.delimiter)) {
    if (!dir) continue;
    candidates.push(path.join(dir, 'loadtest'));
  }
  for (const candidate of candidates) {
    try {
      const st = fs.statSync(candidate);
      if (!st.isFile()) continue;
      fs.accessSync(candidate, fs.constants.X_OK);
    } catch {
      continue;
    }
    return {
      name: 'loadtest',
      version: readToolVersion(candidate),
      resolved_from: candidate,
      binPath: candidate,
    };
  }
  tried.push(...candidates);
  throw new InputError(
    '压测工具 loadtest 不可用：找不到可执行的 loadtest'
    + `（找过: ${tried.join(' / ')}）—— 怎么装: node <交付包>/bin/qa install --project ${projectRoot}`
    + '（工具链会把 loadtest 装到 .tools/node/node_modules/.bin/）',
  );
}

/**
 * 从工具的 package.json 里读版本号。
 * @param {string} toolPath 模块入口或可执行文件
 * @returns {string} 版本号（读不到时是 "unknown"）
 */
export function readToolVersion(toolPath) {
  const candidates = [];
  let dir = path.dirname(toolPath);
  candidates.push(path.join(dir, 'package.json'));
  candidates.push(path.join(dir, '..', 'package.json'));
  candidates.push(path.join(dir, '..', '..', 'package.json'));
  for (const candidate of candidates) {
    try {
      const doc = JSON.parse(fs.readFileSync(candidate, 'utf8'));
      if (doc && typeof doc.version === 'string') return doc.version;
    } catch {
      /* 继续找 */
    }
  }
  return 'unknown';
}

// ---------------------------------------------------------------- 沙箱（防 `.loadtestrc` 渗透）

/**
 * 建一个**干净**的工作目录（空的）⇒ 压测工具读不到 `.loadtestrc`
 * （`loadtest` 的 API 路径也会无条件 `loadConfig()` ⇒ 宿主的 `.loadtestrc` 会渗透进来：
 *  `concurrency` / `requestsPerSecond` / `method` / `headers` / `timeout` / `proxy` …，
 *  其中 `proxy` 会让流量**打到桩之外**）。
 * @returns {string} 沙箱目录路径
 */
export function createSandbox() {
  const bases = [];
  try {
    bases.push(os.tmpdir());
  } catch {
    /* 忽略 */
  }
  bases.push('/tmp');
  let lastError = null;
  for (const base of bases) {
    if (!base) continue;
    try {
      return fs.mkdtempSync(path.join(base, 'load-profile-sandbox-'));
    } catch (err) {
      lastError = err;
    }
  }
  throw new InputError(`建不出干净的工作目录（沙箱）: ${lastError ? lastError.message : '未知原因'}`);
}

/**
 * 删掉沙箱目录（只删**自己**建的）。
 * @param {string} dir 沙箱目录
 */
export function removeSandbox(dir) {
  if (!dir) return;
  try {
    fs.rmSync(dir, { recursive: true, force: true });
  } catch {
    /* 删不掉也不影响判定 */
  }
}

// ---------------------------------------------------------------- 执行

/**
 * 跑一个子进程并收集输出。
 * @param {string} command 可执行文件
 * @param {string[]} args 参数
 * @param {string} cwd 工作目录
 * @param {number} timeoutMs 超时
 * @returns {Promise<{stdout: string, stderr: string, code: number|null, signal: string|null, failed: boolean}>}
 */
function spawnCapture(command, args, cwd, timeoutMs) {
  return new Promise((resolve) => {
    let stdout = '';
    let stderr = '';
    let settled = false;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      resolve(value);
    };
    let child;
    try {
      child = spawn(command, args, { cwd, env: process.env });
    } catch (err) {
      finish({ stdout: '', stderr: String(err && err.message), code: null, signal: null, failed: true });
      return;
    }
    const timer = setTimeout(() => {
      try { child.kill('SIGKILL'); } catch { /* 已退出 */ }
      finish({ stdout, stderr: `${stderr}\n[执行器] 子进程超时，已强制结束`, code: null, signal: 'SIGKILL', failed: true });
    }, timeoutMs);
    if (child.stdout) child.stdout.on('data', (chunk) => { stdout += chunk.toString(); });
    if (child.stderr) child.stderr.on('data', (chunk) => { stderr += chunk.toString(); });
    child.on('error', (err) => {
      clearTimeout(timer);
      finish({ stdout, stderr: `${stderr}\n[执行器] 子进程启动失败: ${err && err.message}`, code: null, signal: null, failed: true });
    });
    child.on('close', (code, signal) => {
      clearTimeout(timer);
      finish({ stdout, stderr, code, signal, failed: false });
    });
  });
}

/**
 * API 模式：跑一次（**结构化 `Result`**，不解析 stdout）。
 * @param {object} params 参数
 * @returns {Promise<{result: object, stdout: string}>}
 */
async function runApiInvocation({ tool, url, spec }) {
  const module = await import(pathToFileURL(tool.modulePath).href);
  const loadTest = module.loadTest || (module.default && module.default.loadTest);
  if (typeof loadTest !== 'function') {
    throw new InputError('loadtest 包没有导出 loadTest(...)（API 模式不可用）');
  }
  const options = {
    url,
    maxSeconds: spec.maxSeconds,
    concurrency: spec.concurrency,
    method: spec.method,
    agentKeepAlive: spec.agentKeepAlive,
    requestsPerSecond: spec.requestsPerSecond,
    timeout: spec.timeout,
    // ⚠️ **必须设**（不设 ⇒ HTTP 错误状态码全塌成 `-1` ⇒ 错误码分类能力丢失）
    statusCallback: () => {},
  };
  const captured = [];
  const originals = { log: console.log, info: console.info };
  console.log = (...args) => { captured.push(args.map((x) => String(x)).join(' ')); };
  console.info = (...args) => { captured.push(args.map((x) => String(x)).join(' ')); };
  let result;
  try {
    result = await new Promise((resolve, reject) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        reject(new Error(`loadtest 执行超时（> ${spec.maxSeconds + 30} 秒）`));
      }, (spec.maxSeconds + 30) * 1000);
      loadTest(options, (err, value) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (err) reject(err);
        else resolve(value);
      });
    });
  } finally {
    console.log = originals.log;
    console.info = originals.info;
  }
  return { result, stdout: captured.length ? `${captured.join('\n')}\n` : '' };
}

/**
 * CLI 模式：解析 stdout（**已知文本形态**）。
 * @param {string} text stdout 原文
 * @returns {object} 解析出的观测量
 */
export function parseCliStdout(text) {
  const source = String(text || '');
  const pick = (pattern, label) => {
    const hit = pattern.exec(source);
    if (!hit) {
      throw new InputError(`CLI 模式的 stdout 解析失败：找不到「${label}」（解析不出来就不许编造数值）`);
    }
    return hit[1];
  };
  const totalRequests = Number(pick(/Completed requests:\s*(\d+)/, 'Completed requests'));
  const totalErrors = Number(pick(/Total errors:\s*(\d+)/, 'Total errors'));
  const elapsedSeconds = Number(pick(/Total time:\s*([\d.]+)\s*s/, 'Total time'));
  const meanLatencyMs = Number(pick(/Mean latency:\s*([\d.]+)\s*ms/, 'Mean latency'));
  const effectiveRps = Number(pick(/Effective rps:\s*([\d.]+)/, 'Effective rps'));
  const percentiles = {};
  const maxes = [];
  const re = /^\s*(\d+)%\s+([\d.]+)\s*ms/gm;
  let hit = re.exec(source);
  while (hit) {
    percentiles[hit[1]] = Number(hit[2]);
    if (hit[1] === '100') maxes.push(Number(hit[2]));
    hit = re.exec(source);
  }
  for (const key of ['50', '90', '95', '99']) {
    if (typeof percentiles[key] !== 'number') {
      throw new InputError(`CLI 模式的 stdout 解析失败：找不到「${key}% 分位」`);
    }
  }
  return {
    total_requests: totalRequests,
    total_errors: totalErrors,
    error_codes: { '-1': totalErrors },
    error_rate: totalRequests > 0 ? totalErrors / totalRequests : null,
    mean_latency_ms: meanLatencyMs,
    effective_rps: effectiveRps,
    percentiles: {
      '50': percentiles['50'],
      '90': percentiles['90'],
      '95': percentiles['95'],
      '99': percentiles['99'],
    },
    max_latency_ms: maxes.length ? maxes[0] : null,
    // ⚠️ CLI 的 stdout **没有最小延迟** ⇒ 记 null，**不许编造**
    min_latency_ms: null,
    elapsed_seconds: elapsedSeconds,
  };
}

/**
 * 把 API 模式的 `Result` 映射成 `observed` 段（**封闭 10 个键**）。
 * @param {object} result loadtest 的结构化结果
 * @returns {object} observed 段
 */
export function mapApiResult(result) {
  const totalRequests = Number(result.totalRequests);
  const totalErrors = Number(result.totalErrors);
  const percentiles = result.percentiles || {};
  const value = (key) => {
    const raw = percentiles[key];
    return typeof raw === 'number' ? raw : null;
  };
  return {
    total_requests: totalRequests,
    total_errors: totalErrors,
    error_codes: { ...(result.errorCodes || {}) },
    error_rate: totalRequests > 0 ? totalErrors / totalRequests : null,
    mean_latency_ms: result.meanLatencyMs,
    effective_rps: result.effectiveRps,
    percentiles: {
      '50': value('50'),
      '90': value('90'),
      '95': value('95'),
      '99': value('99'),
    },
    max_latency_ms: result.maxLatencyMs,
    min_latency_ms: result.minLatencyMs,
    elapsed_seconds: result.elapsedSeconds,
  };
}

// ---------------------------------------------------------------- 判定

/**
 * 判定一条 invocation 的阈值（**封闭枚举**：`met` / `not_met` / `undetermined`）。
 * @param {object} params 参数
 * @returns {object[]} 阈值判定条目
 */
export function judgeThresholds({ runner, thresholds, observed, stubIsDefault }) {
  const entries = [];
  let errorRateVerdict = null;
  for (const key of Object.keys(thresholds || {})) {
    const threshold = thresholds[key];
    if (runner === 'python') {
      entries.push({
        key, threshold, observed: null, verdict: 'undetermined',
        reason: 'python runner 的输出形态无契约 ⇒ 不可判定',
      });
      continue;
    }
    if (key === 'max_concurrency') {
      entries.push({
        key, threshold, observed: null, verdict: 'undetermined',
        reason: '阈值键 max_concurrency 没有对应观测量（客户端侧只有「打算并发多少」与「客户端数」，都不是实际并发）⇒ 不可判定',
      });
      continue;
    }
    if (key === 'error_rate') {
      if (stubIsDefault) {
        entries.push({
          key, threshold, observed: null, verdict: 'undetermined',
          reason: '本次桩未注入延迟与错误，错误率观测只反映桩自身行为 ⇒ 不可判定（本地桩）',
        });
        continue;
      }
      const value = observed ? observed.error_rate : null;
      if (typeof value !== 'number') {
        entries.push({
          key, threshold, observed: null, verdict: 'undetermined',
          reason: '本次没有完成的请求 ⇒ 错误率无观测量 ⇒ 不可判定',
        });
        continue;
      }
      const verdict = value <= threshold ? 'met' : 'not_met';
      errorRateVerdict = verdict;
      entries.push({
        key, threshold, observed: value, verdict,
        reason: verdict === 'met'
          ? '客户端侧错误率不超过阈值（本次在本地桩上测得）'
          : '客户端侧错误率超过阈值（本次在本地桩上测得）',
      });
      continue;
    }
    if (key === 'throughput_rps') {
      const value = observed ? observed.effective_rps : null;
      if (typeof value !== 'number') {
        entries.push({
          key, threshold, observed: null, verdict: 'undetermined',
          reason: '本次没有完成的请求 ⇒ 吞吐无观测量 ⇒ 不可判定',
        });
        continue;
      }
      const verdict = value >= threshold ? 'met' : 'not_met';
      entries.push({
        key, threshold, observed: value, verdict,
        reason: verdict === 'met'
          ? '客户端侧有效吞吐不低于阈值（本次在本地桩上测得）'
          : '客户端侧有效吞吐低于阈值（本次在本地桩上测得）',
      });
      continue;
    }
    // 延迟类（p50 / p95 / p99）
    const bucket = key.replace('_latency_ms', '').replace(/^p/, '');
    if (stubIsDefault) {
      entries.push({
        key, threshold, observed: null, verdict: 'undetermined',
        reason: '本次桩未注入延迟与错误，延迟观测只反映桩自身开销 ⇒ 不可判定（本地桩）',
      });
      continue;
    }
    const value = observed && observed.percentiles ? observed.percentiles[bucket] : null;
    if (typeof value !== 'number') {
      entries.push({
        key, threshold, observed: null, verdict: 'undetermined',
        reason: '本次没有可用的延迟分位观测 ⇒ 不可判定',
      });
      continue;
    }
    const verdict = value <= threshold ? 'met' : 'not_met';
    entries.push({
      key, threshold, observed: value, verdict,
      reason: verdict === 'met'
        ? '客户端侧延迟分位不超过阈值（本次在本地桩上测得）'
        : '客户端侧延迟分位超过阈值（本次在本地桩上测得）',
    });
  }

  // 联合口径：错误率不达标 ⇒ 同一次 invocation 的吞吐**不得**单独判「达标」
  if (errorRateVerdict === 'not_met') {
    const throughput = entries.find((entry) => entry.key === 'throughput_rps');
    if (throughput) {
      throughput.observed = null;
      throughput.verdict = 'undetermined';
      throughput.reason = '错误率不达标 ⇒ 本次吞吐观测不代表有效吞吐 ⇒ 不可判定（联合口径）';
    }
  }
  return entries;
}

/**
 * 汇总一组判定（**不得掩盖失败**）。
 * @param {string[]} verdicts 判定列表
 * @returns {string} 汇总判定
 */
export function aggregateVerdict(verdicts) {
  if (verdicts.includes('not_met')) return 'not_met';
  if (verdicts.length === 0) return 'undetermined';
  if (verdicts.includes('undetermined')) return 'undetermined';
  return 'met';
}

// ---------------------------------------------------------------- 主流程

/**
 * 执行一个套件并写出**负载级**产物与证据。
 * @param {object} options 解析后的参数
 * @returns {object} 执行摘要
 */
export async function runSuite(options) {
  const loadDir = path.resolve(options.loadDir);
  const outDir = path.resolve(options.outDir);
  const suite = options.suite;

  if (!fs.existsSync(loadDir) || !fs.statSync(loadDir).isDirectory()) {
    throw new InputError(`--load-dir 指向的不是目录: ${loadDir}`);
  }
  if (fs.existsSync(outDir) && !fs.statSync(outDir).isDirectory()) {
    throw new UsageError(`--out-dir 指向的不是目录: ${outDir}`);
  }

  // ---- 输入（只读）+ 校验：**先校验、后建目录**（非法输入 ⇒ 一个目录都不许出现） ----
  const plan = loadPlan(loadDir, suite);
  validatePlan(plan, suite);

  const resultsDir = path.join(outDir, 'test-assets', 'load', 'results');
  const artifactFile = path.join(resultsDir, `${suite}.json`);
  const evidenceDir = path.join(resultsDir, 'evidence', suite);
  if (pathExists(artifactFile)) {
    throw new StateError(`产物已存在: ${artifactFile}（本工具不覆盖既有产物 —— 请先人工处理，或换一个 --out-dir）`);
  }
  if (pathExists(evidenceDir)) {
    throw new StateError(`证据目录已存在: ${evidenceDir}（本工具不覆盖既有产物 —— 请先人工处理，或换一个 --out-dir）`);
  }

  // ---- 工具可用性前置检查（**不可用 ⇒ rc=1，不产任何产物**） ----
  const tool = resolveTool(loadDir, options.mode);

  const startedAt = new Date();
  const stub = new Stub({ delayMs: options.stubDelayMs, errorRate: options.stubErrorRate });
  const sandbox = createSandbox();
  const previousCwd = process.cwd();
  const evidence = [];
  const scenarios = [];
  let executionError = null;

  try {
    await stub.start();
    process.chdir(sandbox);
    for (const scenario of plan.scenarios) {
      const scenarioEntry = await runScenario({
        scenario, stub, tool, mode: options.mode, sandbox, stubIsDefault: options.stubDelayMs === 0 && options.stubErrorRate === 0,
      });
      scenarios.push(scenarioEntry.scenario);
      evidence.push(...scenarioEntry.evidence);
    }
  } catch (err) {
    executionError = err;
  } finally {
    process.chdir(previousCwd);
    await stub.stop();
    removeSandbox(sandbox);
  }
  if (executionError) {
    if (executionError instanceof UsageError || executionError instanceof InputError || executionError instanceof StateError) {
      throw executionError;
    }
    const detail = executionError && executionError.message ? executionError.message : String(executionError);
    throw new InputError(`执行失败: ${detail}`);
  }

  const finishedAt = new Date();
  const invocationCount = scenarios.reduce((sum, s) => sum + s.invocations.length, 0);
  const allVerdicts = scenarios.flatMap((s) => s.invocations.map((i) => i.verdict));
  const undeterminedKeys = [];
  for (const key of THRESHOLD_KEYS) {
    const hit = scenarios.some((s) => s.invocations.some((i) => i.thresholds.some((t) => t.key === key && t.verdict === 'undetermined')));
    if (hit) undeterminedKeys.push(key);
  }

  const artifact = {
    schema_version: 1,
    suite,
    environment: plan.environment,
    generated_at: startedAt.toISOString(),
    execution: {
      mode: options.mode === 'cli' ? 'cli_verbatim' : 'api_equivalent',
      started_at: startedAt.toISOString(),
      finished_at: finishedAt.toISOString(),
      duration_ms: Math.max(0, Math.round(finishedAt.getTime() - startedAt.getTime())),
      tool: { name: tool.name, version: tool.version, resolved_from: tool.resolved_from },
      stub: {
        origin: stub.origin,
        delay_ms: options.stubDelayMs,
        error_rate: options.stubErrorRate,
        status: 'stopped',
      },
      ...(options.mode === 'cli' ? { cli: { error_code_resolution: 'unavailable', percentile_source: 'stdout_text' } } : {}),
    },
    scenarios,
    verdict: {
      suite: aggregateVerdict(allVerdicts),
      invocations_total: invocationCount,
      invocations_met: allVerdicts.filter((v) => v === 'met').length,
      invocations_not_met: allVerdicts.filter((v) => v === 'not_met').length,
      invocations_undetermined: allVerdicts.filter((v) => v === 'undetermined').length,
      undetermined_keys: undeterminedKeys,
    },
  };
  artifact.results_sha256 = computeResultsSha(artifact);

  // ---- 落盘（**只写 results/**） ----
  ensureDir(resultsDir);
  for (const item of evidence) {
    const dir = path.join(evidenceDir, item.scenario_id, String(item.step_index));
    ensureDir(dir);
    writeJsonFile(path.join(dir, 'result.json'), item.result);
    fs.writeFileSync(path.join(dir, 'stdout.txt'), item.stdout, 'utf8');
    writeJsonFile(path.join(dir, 'stub-observations.json'), item.stubObserved);
  }
  const manifestFiles = {};
  for (const rel of listFilesRelative(evidenceDir)) {
    if (rel === 'manifest.json') continue;
    manifestFiles[rel] = sha256(fs.readFileSync(path.join(evidenceDir, rel)));
  }
  writeJsonFile(path.join(evidenceDir, 'manifest.json'), { suite, files: manifestFiles });
  writeJsonFile(artifactFile, artifact);

  return {
    artifact,
    artifactFile,
    evidenceDir,
    invocationCount,
  };
}

/**
 * 沉降期（毫秒）：让在途请求落到本次窗口里。
 */
const SETTLE_MS = 150;

/**
 * 等一小会儿（沉降期）。
 * @param {number} [ms=SETTLE_MS] 等待毫秒数
 * @returns {Promise<void>}
 */
function settleDelay(ms = SETTLE_MS) {
  return new Promise((resolve) => { setTimeout(resolve, ms); });
}

/**
 * 跑一个场景（**顺序执行**，场景内 invocation 按数组顺序）。
 * @param {object} params 参数
 * @returns {Promise<{scenario: object, evidence: object[]}>} 场景条目与证据
 */
async function runScenario({ scenario, stub, tool, mode, sandbox, stubIsDefault }) {
  const invocations = [];
  const evidence = [];
  for (let index = 0; index < scenario.invocations.length; index += 1) {
    const invocation = scenario.invocations[index];
    // 每条 invocation 前**重置桩侧计数** ⇒ 桩侧观测是**本次增量**
    stub.resetObservations();
    const executed = await runInvocation({
      scenario, invocation, index, stub, tool, mode, sandbox,
    });
    // ⚠️ **沉降期**：压测工具收尾时还有在途请求（客户端已被取消、桩刚收到）
    //    ⇒ 留一小段时间让它们落到**本次**窗口里（否则会被算到下一条 invocation 头上）。
    await settleDelay();
    const stubObserved = stub.snapshot();
    const thresholds = judgeThresholds({
      runner: scenario.runner,
      thresholds: scenario.thresholds || {},
      observed: executed.observed,
      stubIsDefault,
    });
    const verdict = aggregateVerdict(thresholds.map((t) => t.verdict));
    const entry = {
      step_index: invocation.step_index,
      duration_s: invocation.duration_s,
      concurrency: invocation.concurrency,
      argv: invocation.argv.slice(),
      executed_url: executed.executedUrl,
      ...(executed.executedParams ? { executed_params: executed.executedParams } : {}),
      ...(executed.observed ? { observed: executed.observed } : {}),
      stub_observed: stubObserved,
      thresholds,
      verdict,
    };
    invocations.push(entry);
    evidence.push({
      scenario_id: scenario.scenario_id,
      step_index: invocation.step_index,
      result: executed.evidenceResult,
      stdout: executed.stdout,
      stubObserved,
    });
  }
  const scenarioEntry = {
    scenario_id: scenario.scenario_id,
    scenario_name: scenario.scenario_name,
    runner: scenario.runner,
    target: scenario.target,
    base_url: scenario.base_url,
    thresholds_status: scenario.thresholds_status,
    invocations,
    verdict: aggregateVerdict(invocations.map((i) => i.verdict)),
    ...(scenario.thresholds_status === 'provided'
      ? { thresholds: { ...scenario.thresholds }, thresholds_source: scenario.thresholds_source }
      : {}),
  };
  return { scenario: scenarioEntry, evidence };
}

/**
 * 跑一条 invocation（两种模式 + `python` runner）。
 * @param {object} params 参数
 * @returns {Promise<object>} 执行结果
 */
async function runInvocation({ scenario, invocation, index, stub, tool, mode, sandbox }) {
  if (scenario.runner === 'python') {
    // 照常执行（逐字 spawn 自陈命令），但**不解析**它的输出
    const run = await spawnCapture(invocation.argv[0], invocation.argv.slice(1), sandbox, 60000);
    return {
      executedUrl: `${stub.origin}/`,
      executedParams: null,
      observed: null,
      stdout: run.stdout,
      evidenceResult: {
        mode: 'python_verbatim',
        argv: invocation.argv.slice(),
        exit_code: run.code,
        signal: run.signal,
        note: 'python runner 的输出形态无契约 ⇒ 不解析其 stdout，阈值一律判不可判定',
        ...(run.failed ? { error: run.stderr.trim() } : {}),
      },
    };
  }

  const reversed = reverseArgv(invocation.argv);
  const planUrl = new URL(reversed.url);
  // ⚠️ **只换 origin**：path 与 query 逐字保留
  const executedUrl = `${stub.origin}${planUrl.pathname}${planUrl.search}`;
  // 替换后必须仍是回环地址
  assertLoopbackUrl(executedUrl, `场景 ${scenario.scenario_id} 的第 ${index} 条 invocation 的执行 URL`);

  if (mode === 'cli') {
    const childArgs = invocation.argv.slice(1);
    childArgs[6] = executedUrl;
    const run = await spawnCapture(tool.binPath, childArgs, sandbox, (reversed.spec.maxSeconds + 30) * 1000);
    if (run.failed) {
      throw new InputError(
        `CLI 模式执行失败: ${run.stderr.trim() || '未知原因'}（场景 ${scenario.scenario_id} 的第 ${index} 条 invocation）`,
      );
    }
    const observed = parseCliStdout(run.stdout);
    return {
      executedUrl,
      executedParams: null,
      observed,
      stdout: run.stdout,
      evidenceResult: {
        mode: 'cli_verbatim',
        argv: invocation.argv.slice(),
        executed_url: executedUrl,
        exit_code: run.code,
        parsed: observed,
      },
    };
  }

  const { result, stdout } = await runApiInvocation({ tool, url: executedUrl, spec: reversed.spec });
  if (Number(result.concurrency) !== reversed.spec.concurrency) {
    throw new InputError(
      `执行参数被宿主配置渗透：并发期望 ${reversed.spec.concurrency}，实际 ${result.concurrency}`
      + '（.loadtestrc 之类 ⇒ 显式覆盖每个相关选项并显式禁 proxy）',
    );
  }
  const observed = mapApiResult(result);
  if (!(observed.total_requests > 0)) {
    throw new InputError(
      `本次执行没有产生任何完成的请求（桩侧收到 ${stub.snapshot().requests} 个）`
      + `（场景 ${scenario.scenario_id} 的第 ${index} 条 invocation）—— 判定链不能在没有观测量时编造结论`,
    );
  }
  return {
    executedUrl,
    executedParams: {
      maxSeconds: reversed.spec.maxSeconds,
      concurrency: reversed.spec.concurrency,
      requestsPerSecond: reversed.spec.requestsPerSecond,
      agentKeepAlive: reversed.spec.agentKeepAlive,
      timeout: reversed.spec.timeout,
      method: reversed.spec.method,
    },
    observed,
    stdout,
    evidenceResult: {
      mode: 'api_equivalent',
      argv: invocation.argv.slice(),
      executed_url: executedUrl,
      executed_params: {
        maxSeconds: reversed.spec.maxSeconds,
        concurrency: reversed.spec.concurrency,
        requestsPerSecond: reversed.spec.requestsPerSecond,
        agentKeepAlive: reversed.spec.agentKeepAlive,
        timeout: reversed.spec.timeout,
        method: reversed.spec.method,
      },
      result: {
        total_requests: observed.total_requests,
        total_errors: observed.total_errors,
        error_codes: observed.error_codes,
        mean_latency_ms: observed.mean_latency_ms,
        effective_rps: observed.effective_rps,
        percentiles: observed.percentiles,
        max_latency_ms: observed.max_latency_ms,
        min_latency_ms: observed.min_latency_ms,
        elapsed_seconds: observed.elapsed_seconds,
        concurrency: result.concurrency,
        clients: result.clients,
        requests_per_second: result.requestsPerSecond,
        agent: result.agent,
        max_seconds: result.maxSeconds,
      },
    },
  };
}

/**
 * 算结果产物自身的 sha256（**排除** `generated_at` 与 `results_sha256` 两个字段）。
 * @param {object} artifact 结果产物
 * @returns {string} 64 位小写十六进制
 */
export function computeResultsSha(artifact) {
  const basis = { ...artifact };
  delete basis.generated_at;
  delete basis.results_sha256;
  return sha256(canonicalJson(basis));
}

// ---------------------------------------------------------------- 产物自洽校验

/**
 * 复核一份**负载级**产物是否与计划自洽（**只读**：一个字节都不写）。
 * @param {string} projectRoot 项目根
 * @param {string} suite 套件名
 * @returns {string[]} 问题清单（空数组 = 自洽）
 */
export function verifyArtifact(projectRoot, suite) {
  const problems = [];
  const resultsDir = path.join(projectRoot, 'test-assets', 'load', 'results');
  const artifactFile = path.join(resultsDir, `${suite}.json`);
  if (!pathExists(artifactFile)) return [`结果产物不存在: ${artifactFile}`];

  let artifact;
  try {
    artifact = readJsonFile(artifactFile, '结果产物');
  } catch (err) {
    return [err && err.message ? err.message : String(err)];
  }
  if (!artifact || typeof artifact !== 'object' || Array.isArray(artifact)) {
    return ['结果产物不是合法对象'];
  }

  // ---- 顶层（封闭 8 个） ----
  const topKeys = Object.keys(artifact);
  if (!deepEqual(topKeys.slice().sort(), TOP_KEYS.slice().sort())) {
    problems.push(`顶层键集不是封闭的 8 个（实际 ${topKeys.join(',')}）`);
  }
  if (artifact.schema_version !== 1) problems.push('schema_version 不是数字 1');
  if (artifact.suite !== suite) problems.push(`suite 字段与套件名不一致（实际 ${JSON.stringify(artifact.suite)}）`);
  if (typeof artifact.generated_at !== 'string' || Number.isNaN(new Date(artifact.generated_at).getTime())) {
    problems.push('generated_at 不是合法 ISO-8601');
  }
  if (computeResultsSha(artifact) !== artifact.results_sha256) {
    problems.push('results_sha256 复算不一致（剔除 generated_at 与 results_sha256 后的内容对不上）');
  }

  // ---- execution 段 ----
  const execution = artifact.execution || {};
  const mode = execution.mode;
  const expectedExecutionKeys = mode === 'cli_verbatim'
    ? EXECUTION_KEYS.concat(['cli'])
    : EXECUTION_KEYS;
  if (!deepEqual(Object.keys(execution).slice().sort(), expectedExecutionKeys.slice().sort())) {
    problems.push(`execution 段的键集不封闭（实际 ${Object.keys(execution).join(',')}）`);
  }
  if (!['api_equivalent', 'cli_verbatim'].includes(mode)) {
    problems.push(`execution.mode 取值非法: ${JSON.stringify(mode)}`);
  }
  if (!Number.isInteger(execution.duration_ms) || execution.duration_ms < 0) {
    problems.push('execution.duration_ms 不是 ≥ 0 的整数');
  }
  const tool = execution.tool || {};
  if (!deepEqual(Object.keys(tool).slice().sort(), ['name', 'resolved_from', 'version'])) {
    problems.push(`execution.tool 的键集不是 3 个（实际 ${Object.keys(tool).join(',')}）`);
  }
  const stub = execution.stub || {};
  if (!deepEqual(Object.keys(stub).slice().sort(), ['delay_ms', 'error_rate', 'origin', 'status'])) {
    problems.push(`execution.stub 的键集不是 4 个（实际 ${Object.keys(stub).join(',')}）`);
  }
  if (stub.origin) {
    let origin = null;
    try { origin = new URL(stub.origin); } catch { origin = null; }
    if (!origin) problems.push('execution.stub.origin 不是可解析的 URL');
    else if (!isLoopbackHost(origin.hostname)) problems.push('execution.stub.origin 的 host 不是回环地址');
  }
  if (mode === 'cli_verbatim') {
    const cli = execution.cli || {};
    if (cli.error_code_resolution !== 'unavailable') {
      problems.push('execution.cli.error_code_resolution 不是 "unavailable"');
    }
    if (cli.percentile_source !== 'stdout_text') {
      problems.push('execution.cli.percentile_source 不是 "stdout_text"');
    }
  }

  // ---- 计划（只读） ----
  let plan = null;
  try {
    plan = loadPlan(projectRoot, suite);
    validatePlan(plan, suite);
  } catch (err) {
    problems.push(err && err.message ? err.message : String(err));
  }
  if (!plan) return problems;

  if (artifact.environment !== plan.environment) {
    problems.push(`environment 与计划不一致（实际 ${JSON.stringify(artifact.environment)}）`);
  }

  const scenarios = Array.isArray(artifact.scenarios) ? artifact.scenarios : [];
  if (scenarios.length !== plan.scenarios.length) {
    problems.push(`scenarios 的条数与计划不一致（实际 ${scenarios.length}，计划 ${plan.scenarios.length}）`);
  }
  const planThresholdsByScenario = [];
  plan.scenarios.forEach((p) => planThresholdsByScenario.push(p.thresholds_status === 'provided' ? (p.thresholds || {}) : {}));

  scenarios.forEach((s, si) => {
    const p = plan.scenarios[si];
    if (!p) return;
    const where = `场景 ${s && s.scenario_id ? s.scenario_id : `#${si}`}`;
    const expectedKeys = SCENARIO_KEYS.concat(p.thresholds_status === 'provided' ? ['thresholds', 'thresholds_source'] : []);
    if (!deepEqual(Object.keys(s || {}).slice().sort(), expectedKeys.slice().sort())) {
      problems.push(`${where} 的键集不封闭（实际 ${Object.keys(s || {}).join(',')}）`);
    }
    for (const key of ['scenario_id', 'scenario_name', 'runner', 'target', 'base_url', 'thresholds_status']) {
      if (!s || s[key] !== p[key]) problems.push(`${where} 的 ${key} 与计划不逐字相同`);
    }
    if (p.thresholds_status === 'provided') {
      if (!deepEqual(s.thresholds, p.thresholds)) problems.push(`${where} 的 thresholds 与计划不逐字相同`);
      if (s.thresholds_source !== p.thresholds_source) problems.push(`${where} 的 thresholds_source 与计划不逐字相同`);
    } else {
      if ('thresholds' in (s || {})) problems.push(`${where} 的 thresholds_status 是 not_provided 却出现了 thresholds 键`);
      if ('thresholds_source' in (s || {})) problems.push(`${where} 的 thresholds_status 是 not_provided 却出现了 thresholds_source 键`);
    }

    const invocations = Array.isArray(s.invocations) ? s.invocations : [];
    const planInvocations = Array.isArray(p.invocations) ? p.invocations : [];
    if (invocations.length !== planInvocations.length) {
      problems.push(`${where} 的 invocation 条数与计划不一致（实际 ${invocations.length}，计划 ${planInvocations.length}）`);
    }
    const scenarioThresholds = planThresholdsByScenario[si];
    invocations.forEach((inv, ii) => {
      const pinv = planInvocations[ii];
      const iwhere = `${where}[${inv && inv.step_index !== undefined ? inv.step_index : ii}]`;
      if (!pinv) {
        problems.push(`${iwhere} 在计划里不存在`);
        return;
      }
      const isPython = p.runner === 'python';
      let expectedInvocationKeys = INVOCATION_KEYS.slice();
      if (isPython) expectedInvocationKeys = expectedInvocationKeys.filter((k) => k !== 'observed' && k !== 'executed_params');
      if (mode === 'cli_verbatim') expectedInvocationKeys = expectedInvocationKeys.filter((k) => k !== 'executed_params');
      if (!deepEqual(Object.keys(inv || {}).slice().sort(), expectedInvocationKeys.slice().sort())) {
        problems.push(`${iwhere} 的键集不封闭（实际 ${Object.keys(inv || {}).join(',')}）`);
      }
      if (inv.step_index !== ii) problems.push(`${iwhere} 的 step_index 不是数组下标`);
      if (inv.duration_s !== pinv.duration_s) problems.push(`${iwhere} 的 duration_s 与计划不逐字相同`);
      if (inv.concurrency !== pinv.concurrency) problems.push(`${iwhere} 的 concurrency 与计划不逐字相同`);
      if (!deepEqual(inv.argv, pinv.argv)) problems.push(`${iwhere} 的 argv 与计划不逐字相同`);

      // URL：origin 必须是桩地址，path + query 逐字保留
      let executed = null;
      try { executed = new URL(String(inv.executed_url || '')); } catch { executed = null; }
      if (!executed) {
        problems.push(`${iwhere} 的 executed_url 不是可解析的 URL`);
      } else {
        if (stub.origin && `${executed.protocol}//${executed.host}` !== stub.origin) {
          problems.push(`${iwhere} 的 executed_url 的 origin 与 execution.stub.origin 不一致`);
        }
        if (!isLoopbackHost(executed.hostname)) problems.push(`${iwhere} 的 executed_url 的 host 不是回环地址`);
        if (!isPython && pinv && Array.isArray(pinv.argv)) {
          try {
            const planned = new URL(String(pinv.argv[7]));
            if (executed.pathname !== planned.pathname || executed.search !== planned.search) {
              problems.push(`${iwhere} 的 executed_url 的 path + query 与计划不逐字相同`);
            }
          } catch {
            problems.push(`${iwhere} 的计划 URL 不可解析`);
          }
        }
      }

      // observed
      if (inv.observed) {
        if (!deepEqual(Object.keys(inv.observed).slice().sort(), OBSERVED_KEYS.slice().sort())) {
          problems.push(`${iwhere} 的 observed 的键集不是封闭的 10 个（实际 ${Object.keys(inv.observed).join(',')}）`);
        }
        const percentiles = inv.observed.percentiles || {};
        if (!deepEqual(Object.keys(percentiles).slice().sort(), ['50', '90', '95', '99'])) {
          problems.push(`${iwhere} 的 observed.percentiles 的键集不是 50/90/95/99 四个`);
        }
        const totalRequests = Number(inv.observed.total_requests);
        const totalErrors = Number(inv.observed.total_errors);
        if (totalRequests === 0) {
          if (inv.observed.error_rate !== null) problems.push(`${iwhere} 的 total_requests 为 0 时 error_rate 必须是 null`);
        } else if (typeof inv.observed.error_rate !== 'number'
          || Math.abs(inv.observed.error_rate - totalErrors / totalRequests) > 1e-9) {
          problems.push(`${iwhere} 的 observed.error_rate 与 total_errors / total_requests 重算不一致`);
        }
      }

      // 阈值判定
      const entries = Array.isArray(inv.thresholds) ? inv.thresholds : [];
      const expectedKeysOfThresholds = Object.keys(scenarioThresholds);
      if (entries.length !== expectedKeysOfThresholds.length) {
        problems.push(`${iwhere} 的阈值判定条数与该场景的阈值键数不一致`);
      }
      if (!deepEqual(entries.map((e) => e.key).slice().sort(), expectedKeysOfThresholds.slice().sort())) {
        problems.push(`${iwhere} 的阈值判定键集合与计划不一致`);
      }
      for (const entry of entries) {
        if (!deepEqual(Object.keys(entry || {}).slice().sort(), THRESHOLD_ENTRY_KEYS.slice().sort())) {
          problems.push(`${iwhere}/${entry && entry.key} 的判定条目键集不是 5 个`);
        }
        if (!VERDICTS.includes(entry.verdict)) {
          problems.push(`${iwhere}/${entry.key} 的 verdict 不在封闭的 3 个枚举内`);
        }
        if (typeof entry.reason !== 'string' || entry.reason.trim() === '') {
          problems.push(`${iwhere}/${entry.key} 的 reason 不是非空字符串`);
        }
        if (!Object.prototype.hasOwnProperty.call(scenarioThresholds, entry.key)) {
          problems.push(`${iwhere}/${entry.key} 出现了计划里没有的阈值键`);
        } else if (entry.threshold !== scenarioThresholds[entry.key]) {
          problems.push(`${iwhere}/${entry.key} 的阈值值与计划不逐字相同`);
        }
        if (entry.key === 'max_concurrency' && (entry.verdict !== 'undetermined' || entry.observed !== null)) {
          problems.push(`${iwhere}/max_concurrency 必须恒判不可判定（observed 为 null）`);
        }
      }
      if (!VERDICTS.includes(inv.verdict)) {
        problems.push(`${iwhere} 的 verdict 不在封闭的 3 个枚举内`);
      }
    });
  });

  // ---- verdict 段 ----
  const verdict = artifact.verdict || {};
  if (!deepEqual(Object.keys(verdict).slice().sort(), VERDICT_SECTION_KEYS.slice().sort())) {
    problems.push(`verdict 段的键集不是封闭的 6 个（实际 ${Object.keys(verdict).join(',')}）`);
  }
  const invocations = scenarios.flatMap((s) => (Array.isArray(s.invocations) ? s.invocations : []));
  const counted = {
    met: invocations.filter((i) => i.verdict === 'met').length,
    not_met: invocations.filter((i) => i.verdict === 'not_met').length,
    undetermined: invocations.filter((i) => i.verdict === 'undetermined').length,
  };
  if (counted.met + counted.not_met + counted.undetermined !== Number(verdict.invocations_total)) {
    problems.push('verdict 的三类计数之和不等于 invocations_total');
  }
  if (Number(verdict.invocations_total) !== invocations.length) {
    problems.push('verdict.invocations_total 与产物里的 invocation 总条数不一致');
  }
  if (counted.met !== Number(verdict.invocations_met)
    || counted.not_met !== Number(verdict.invocations_not_met)
    || counted.undetermined !== Number(verdict.invocations_undetermined)) {
    problems.push('verdict 的三类计数与逐条 invocation 的判定对不上');
  }
  if (counted.not_met > 0 && verdict.suite === 'met') {
    problems.push('存在判 not_met 的 invocation，但套件汇总判成了 met（掩盖失败）');
  }
  const undeterminedKeys = new Set();
  for (const inv of invocations) {
    for (const entry of (inv.thresholds || [])) {
      if (entry.verdict === 'undetermined') undeterminedKeys.add(entry.key);
    }
  }
  const listed = new Set(Array.isArray(verdict.undetermined_keys) ? verdict.undetermined_keys : []);
  for (const key of undeterminedKeys) {
    if (!listed.has(key)) problems.push(`verdict.undetermined_keys 漏了 ${key}`);
  }

  // ---- 证据链 ----
  const evidenceDir = path.join(resultsDir, 'evidence', suite);
  if (!pathExists(evidenceDir)) {
    problems.push(`证据目录不存在: ${evidenceDir}`);
  } else {
    for (const inv of invocations) {
      const candidates = [];
      const walk = (current) => {
        let entries;
        try {
          entries = fs.readdirSync(current, { withFileTypes: true });
        } catch {
          return;
        }
        for (const entry of entries) {
          if (!entry.isDirectory()) continue;
          const full = path.join(current, entry.name);
          if (path.basename(full) === String(inv.step_index)) candidates.push(full);
          walk(full);
        }
      };
      walk(evidenceDir);
      const dir = candidates.find((c) => pathExists(path.join(c, 'result.json')));
      if (!dir) {
        problems.push(`场景 ${inv.scenario_id}[${inv.step_index}] 没有以 step_index 命名的证据子目录`);
        continue;
      }
      const files = fs.readdirSync(dir).sort();      if (!deepEqual(files, ['result.json', 'stdout.txt', 'stub-observations.json'])) {
        problems.push(`场景 ${inv.scenario_id}[${inv.step_index}] 的证据子目录里不是恰好 3 个文件（实际 ${files.join(',')}）`);
      }
    }
    const manifestFile = path.join(evidenceDir, 'manifest.json');
    if (!pathExists(manifestFile)) {
      problems.push('证据目录里没有 manifest.json');
    } else {
      let manifest = null;
      try {
        manifest = readJsonFile(manifestFile, '证据清单');
      } catch (err) {
        problems.push(err && err.message ? err.message : String(err));
      }
      const listedFiles = (manifest && typeof manifest === 'object' && manifest.files) ? manifest.files : {};
      for (const rel of listFilesRelative(evidenceDir)) {
        if (rel === 'manifest.json') continue;
        const real = sha256(fs.readFileSync(path.join(evidenceDir, rel)));
        if (listedFiles[rel] !== real) {
          problems.push(`证据清单里 ${rel} 的 sha256 与复算不一致`);
        }
      }
    }
  }

  return problems;
}

/**
 * 列出目录下的文件（相对路径，`/` 分隔）。
 * @param {string} root 目录
 * @returns {string[]} 相对路径列表（已排序）
 */
export function listFilesRelative(root) {
  const out = [];
  const walk = (dir) => {
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries.sort((a, b) => (a.name < b.name ? -1 : 1))) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.isFile()) out.push(path.relative(root, full).split(path.sep).join('/'));
    }
  };
  walk(root);
  return out.sort();
}
