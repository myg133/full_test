#!/usr/bin/env node
// run-suite.mjs — 执行外壳：调度执行器、统一判定、产出证据链
//
// 用法: node scripts/run-suite.mjs <suite.json> [--cycle <轮次目录>] [--json] [--dry-run]
//       可选补充: [--project-root <目录>] [--run-id <标识>] [--output-dir <目录>]
//                 [--agent <标识>] [--strict]
//
// 退出码: 0 = 执行与证据链自校验通过
//         1 = 校验失败或执行失败（配置非法、驱动起不来、证据链自校验不通过、执行器异常）
//         2 = 调用方式错误
//
// 退出码说的是**执行流程本身**成不成功，不等于"用例有没有通过"：
// 用例的通过/失败/阻塞看 results.json 的 status 与 meta.json 的计数。
// 需要"有失败用例就让流水线红"的场景，加 --strict。
//
// 分层（需求 F3 / D2）：
//   执行器 → 报告"观察到了什么"（observed）
//   本脚本 → 读断言 → 比对 observed → 得出 status（判定集中在 lib/verdict.mjs）
//
// 硬约束：本脚本**不直接写 cycle.json**。轮次状态只经 REQ-002.5a 的 cycle-state.mjs 写。
//
// 纯 Node.js，只依赖 node: 内置模块。

import { randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import process from 'node:process';
import { fileURLToPath, pathToFileURL } from 'node:url';

import {
  EXIT_FAIL,
  EXIT_OK,
  EXIT_USAGE,
  parseFlags,
  stringFlag,
  usageError,
  wantsJson,
  writeJson,
  writeOut,
} from './lib/cli.mjs';
import { resolvePath } from './lib/assertion.mjs';
import { collectAssertions, decide, STATUS } from './lib/verdict.mjs';
import { createRedactor } from './lib/redaction.mjs';
import {
  evidenceManifestFingerprint,
  fingerprintFile,
  resultsFingerprint,
} from './lib/fingerprint.mjs';
import {
  caseAuth,
  caseRequest,
  loadCases,
  loadEnvironment,
  loadSuite,
  requestFromSteps,
  resolveCredentials,
  resolveDriverName,
  selectCases,
} from './lib/suite-loader.mjs';
import { advanceExecuteStage } from './lib/cycle.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const SKILL_DIR = resolve(here, '..');
const EXECUTOR_DIR = join(SKILL_DIR, 'executors');

const USAGE = [
  '用法: node scripts/run-suite.mjs <suite.json> [--cycle <轮次目录>] [--json] [--dry-run]',
  '',
  '选项:',
  '  --cycle <轮次目录>    把本次执行批次记进该轮次（经 cycle-state.mjs 推进 execute 阶段）',
  '  --json               stdout 输出机器可读 JSON',
  '  --dry-run            只解析配置与用例集并列出将要执行什么，不发请求、不写产物',
  '  --project-root <目录>  项目根（默认当前工作目录）',
  '  --run-id <标识>       本次执行标识（默认 <套件名>-<时间戳>-<随机串>）',
  '  --output-dir <目录>   产物目录（默认 <项目根>/.test-artifacts/<run_id>）',
  '  --agent <标识>        执行者标识，写进 meta.json 的 agent',
  '  --strict             有失败或阻塞的用例时退出码取 1（默认只由执行流程成败决定退出码）',
  '',
  '退出码: 0 = 成功, 1 = 校验失败或执行失败, 2 = 调用方式错误',
].join('\n');

/**
 * 取第一个有定义的数值。
 * @param {...any} values 候选值
 * @returns {number|null}
 */
function firstNumber(...values) {
  for (const value of values) {
    if (typeof value === 'number' && Number.isFinite(value)) return value;
  }
  return null;
}

/**
 * 生成执行标识。
 * @param {string} suite 套件名
 * @returns {string}
 */
function makeRunId(suite) {
  const now = new Date();
  const pad = (value) => String(value).padStart(2, '0');
  const stamp =
    `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}` +
    `-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;
  const suffix = randomBytes(3).toString('hex');
  const safeSuite = String(suite || 'suite').replace(/[^\w.-]+/g, '-');
  return `${safeSuite}-${stamp}-${suffix}`;
}

/**
 * 原子写文件（临时文件 + rename）。
 * @param {string} file 目标路径
 * @param {string} text 内容
 */
function writeTextAtomic(file, text) {
  mkdirSync(dirname(file), { recursive: true });
  const tmp = join(dirname(file), `.${file.split(/[\\/]/).pop()}.tmp-${process.pid}`);
  writeFileSync(tmp, text, 'utf8');
  renameSync(tmp, file);
}

/**
 * 脱敏一段证据内容：JSON 按结构脱敏（能命中敏感字段名），其余按文本脱敏。
 * @param {any} content 原始内容
 * @param {object} redactor 脱敏器
 * @returns {string}
 */
function redactContent(content, redactor) {
  if (content && typeof content === 'object') {
    return `${JSON.stringify(redactor.redactJson(content), null, 2)}\n`;
  }
  const text = String(content === undefined || content === null ? '' : content);
  const trimmed = text.trim();
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    try {
      return `${JSON.stringify(redactor.redactJson(JSON.parse(trimmed)), null, 2)}\n`;
    } catch {
      // 不是合法 JSON：落回文本脱敏
    }
  }
  return redactor.redactText(text);
}

/**
 * 相对路径是否安全（不能越出产物目录）。
 * @param {string} relPath 相对路径
 * @returns {boolean}
 */
function isSafeRelativePath(relPath) {
  if (typeof relPath !== 'string' || relPath === '') return false;
  if (relPath.startsWith('/') || relPath.includes('\\')) return false;
  return !relPath.split('/').includes('..');
}

/**
 * 读取执行器注册表。
 * @returns {{file: string, registry: object}}
 */
function loadRegistry() {
  const file = join(EXECUTOR_DIR, 'index.json');
  if (!existsSync(file)) {
    throw new Error(`找不到执行器注册表: ${file}`);
  }
  const registry = JSON.parse(readFileSync(file, 'utf8'));
  if (!registry || !Array.isArray(registry.executors)) {
    throw new Error(`执行器注册表结构非法: ${file}`);
  }
  return { file, registry };
}

/**
 * 执行一个套件。
 *
 * @param {object} options 选项
 * @returns {Promise<{payload: object, exitCode: number}>}
 */
async function executeSuite(options) {
  const projectRoot = resolve(options.projectRoot);
  const suite = loadSuite(options.suitePath);
  const environment = loadEnvironment(projectRoot, suite.config.environment);
  const casesDoc = loadCases(suite.casesFile);
  const selected = selectCases(casesDoc.cases, suite.config.tags);

  const { registry, file: registryFile } = loadRegistry();
  const driverChoice = resolveDriverName(suite.config, environment.config);
  const entry = registry.executors.find((item) => item.name === driverChoice.name);
  if (!entry) {
    const known = registry.executors.map((item) => item.name).join(' / ');
    const pending = Array.isArray(registry.not_implemented) ? registry.not_implemented : [];
    if (pending.includes(driverChoice.name)) {
      throw new Error(
        `执行器 "${driverChoice.name}" 尚未实现（本 REQ 只交付 ${known}）：` +
          `来源 ${driverChoice.source}。需要它时走"提需求"，不要改执行器源码。`,
      );
    }
    throw new Error(
      `执行器 "${driverChoice.name}" 未在执行器注册表中注册（来源 ${driverChoice.source}）。` +
        `已注册: ${known}。注册表: ${registryFile}`,
    );
  }

  const credentials = resolveCredentials(environment.config, selected);

  if (options.dryRun) {
    const plan = selected.map((item) => {
      const assertions = collectAssertions(item);
      const request = caseRequest(item) || requestFromSteps(item);
      return {
        case_id: item.id,
        title: item.title || '',
        status_in_case_set: typeof item.status === 'string' ? item.status : 'active',
        request: request || null,
        assertions: assertions.map((entryItem) => entryItem.assertion),
        mechanical: assertions.length > 0,
      };
    });
    return {
      payload: {
        ok: true,
        command: 'run-suite',
        dry_run: true,
        suite: suite.config.suite,
        requirement: suite.config.requirement,
        scope: suite.config.scope,
        environment: suite.config.environment,
        executor: { name: entry.name, version: entry.version },
        executor_source: driverChoice.source,
        cases_total: selected.length,
        cases_skipped_by_case_set: casesDoc.cases.length - selected.length,
        missing_credentials: credentials.missing,
        plan,
      },
      exitCode: EXIT_OK,
    };
  }

  const runId = options.runId || makeRunId(suite.config.suite);
  const runDir = options.outputDir
    ? resolve(options.outputDir)
    : join(projectRoot, '.test-artifacts', runId);
  const evidenceRoot = join(runDir, 'evidence');
  const logsDir = join(runDir, 'logs');
  // 同一 run_id 重复执行：不留下上一次运行的残留（幂等，不相互污染）
  rmSync(evidenceRoot, { recursive: true, force: true });
  rmSync(logsDir, { recursive: true, force: true });
  mkdirSync(evidenceRoot, { recursive: true });
  mkdirSync(logsDir, { recursive: true });

  const logLines = [];
  /**
   * 记一行运行日志。
   * @param {string} text 内容
   */
  const log = (text) => {
    logLines.push(`[${new Date().toISOString()}] ${text}`);
  };

  const redactor = createRedactor({
    rules: null,
    secrets: Object.values(credentials.values),
  });

  const driverModule = await import(pathToFileURL(join(EXECUTOR_DIR, entry.module)).href);
  const driver = {
    name: driverModule.name || entry.name,
    version: driverModule.version || entry.version,
    start: driverModule.start,
    stop: driverModule.stop,
    run: driverModule.run,
  };

  const startedAt = new Date();
  const startedAtMs = Date.now();
  let effectiveBaseUrl =
    typeof environment.config.base_url === 'string' ? environment.config.base_url : '';
  let builtInService = false;

  log(`开始执行套件 ${suite.config.suite}（执行器 ${driver.name} ${driver.version}）`);
  log(`产物目录: ${runDir}`);

  try {
    if (typeof driver.start === 'function') {
      const started = await driver.start({});
      if (started && typeof started.base_url === 'string' && started.base_url !== '') {
        effectiveBaseUrl = started.base_url;
        builtInService = true;
        log(`内置服务已启动: ${effectiveBaseUrl}`);
      }
    }
  } catch (err) {
    throw new Error(`执行器启动失败: ${err && err.message ? err.message : String(err)}`);
  }

  const variables = {};
  const results = [];

  for (const caseObj of selected) {
    const caseId = caseObj.id;
    const caseStartedAt = new Date();
    const caseStartedMs = Date.now();
    const assertions = collectAssertions(caseObj);
    const lifecycle = typeof caseObj.status === 'string' ? caseObj.status : 'active';
    const request = caseRequest(caseObj) || requestFromSteps(caseObj);
    const auth = caseAuth(caseObj);
    const timeoutMs =
      firstNumber(caseObj.timeout_ms, caseObj.data && caseObj.data.timeout_ms, environment.config.timeout_ms) || 30000;
    const retries =
      firstNumber(caseObj.retries, caseObj.data && caseObj.data.retries, environment.config.retries) || 0;

    let execution = { observed: null, evidence: [], reproduction: null, error: null };

    if (credentials.missing.length > 0) {
      execution = {
        error: {
          type: 'credential_missing',
          message:
            `环境变量未设置: ${credentials.missing.join(' / ')}` +
            '（读不到凭证 → 该用例判 blocked，不是 failed；环境缺失与用例失败是两回事）',
        },
      };
    } else if (assertions.length === 0) {
      execution = {
        error: {
          type: 'no_mechanical_assertion',
          message:
            '缺少可机械判定的断言：该用例所有 steps[].expected 都是普通字符串，' +
            '无法机械判定，因此判 blocked（不得判 passed）',
        },
      };
    } else {
      const context = {
        run_id: runId,
        base_url: effectiveBaseUrl,
        timeout_ms: timeoutMs,
        retries,
        headers: environment.config.headers || {},
        resolved_credentials: credentials.values,
        variables,
        evidence_dir: join(evidenceRoot, caseId),
        case: caseObj,
        request,
        auth,
      };
      try {
        execution = (await driver.run(caseObj, context)) || { error: { type: 'executor_error', message: '执行器没有返回结果' } };
      } catch (err) {
        execution = {
          error: {
            type: 'executor_error',
            message: `执行器抛出异常: ${err && err.message ? err.message : String(err)}`,
          },
        };
      }
    }

    const verdict = decide({ lifecycle, assertions, execution });

    // 证据写入：先脱敏，再落盘，再算指纹
    const evidenceEntries = [];
    const evidenceItems = Array.isArray(execution.evidence) ? execution.evidence : [];
    for (const evidenceItem of evidenceItems) {
      const relPath = `evidence/${caseId}/${evidenceItem.path}`;
      if (!isSafeRelativePath(relPath)) {
        log(`跳过不安全的证据路径: ${evidenceItem.path}`);
        continue;
      }
      const absPath = join(runDir, relPath);
      mkdirSync(dirname(absPath), { recursive: true });
      writeFileSync(absPath, redactContent(evidenceItem.content, redactor), 'utf8');
      const fingerprint = fingerprintFile(absPath);
      evidenceEntries.push({
        path: relPath,
        sha256: fingerprint.sha256,
        bytes: fingerprint.bytes,
        media_type: typeof evidenceItem.media_type === 'string' ? evidenceItem.media_type : 'application/octet-stream',
      });
    }

    // 提取值：供后续用例用 ${name} 引用
    const extractSpec = Array.isArray(caseObj.extract)
      ? caseObj.extract
      : Array.isArray(caseObj.data && caseObj.data.extract)
        ? caseObj.data.extract
        : [];
    if (verdict.status === STATUS.PASSED && execution.observed) {
      for (const item of extractSpec) {
        if (!item || typeof item.name !== 'string' || typeof item.path !== 'string') continue;
        const found = resolvePath(item.path, execution.observed);
        if (found.found) variables[item.name] = found.value;
      }
    }

    const steps = (Array.isArray(caseObj.steps) ? caseObj.steps : [])
      .map((step) => (step && typeof step.action === 'string' ? step.action : ''))
      .filter((item) => item !== '');
    const reproduction = execution.reproduction && typeof execution.reproduction === 'object'
      ? {
          steps: Array.isArray(execution.reproduction.steps) && execution.reproduction.steps.length > 0
            ? execution.reproduction.steps
            : steps,
          command: typeof execution.reproduction.command === 'string' ? execution.reproduction.command : null,
          expected:
            typeof execution.reproduction.expected === 'string' && execution.reproduction.expected !== ''
              ? execution.reproduction.expected
              : null,
        }
      : { steps, command: null, expected: null };

    const finishedMs = Date.now();
    results.push({
      case_id: caseId,
      title: typeof caseObj.title === 'string' ? caseObj.title : '',
      requirement_refs: Array.isArray(caseObj.requirement_refs) ? caseObj.requirement_refs : [],
      status: verdict.status,
      started_at: caseStartedAt.toISOString(),
      finished_at: new Date(finishedMs).toISOString(),
      duration_ms: finishedMs - caseStartedMs,
      evidence: evidenceEntries,
      reproduction,
      error: verdict.error,
    });
    log(`用例 ${caseId}: ${verdict.status}${verdict.reason ? `（${verdict.reason}）` : ''}`);
  }

  if (typeof driver.stop === 'function') {
    try {
      await driver.stop({});
    } catch {
      log('执行器结束钩子报错（忽略）');
    }
  }

  const finishedAtMs = Date.now();
  const counts = {
    passed: results.filter((item) => item.status === STATUS.PASSED).length,
    failed: results.filter((item) => item.status === STATUS.FAILED).length,
    blocked: results.filter((item) => item.status === STATUS.BLOCKED).length,
    skipped: results.filter((item) => item.status === STATUS.SKIPPED).length,
  };

  const redactedResults = redactor.redactJson(results);
  const resultsText = `${JSON.stringify(redactedResults, null, 2)}\n`;
  writeTextAtomic(join(runDir, 'results.json'), resultsText);

  const manifestFingerprint = evidenceManifestFingerprint(redactedResults);
  const resultsHash = resultsFingerprint(redactedResults);

  // 轮次状态：只经 cycle-state.mjs 写
  let cycleInfo = null;
  if (options.cycle) {
    const artifactPath = relative(projectRoot, runDir) || runDir;
    const advanced = await advanceExecuteStage(options.cycle, artifactPath, options.agent);
    cycleInfo = {
      cycle_dir: resolve(options.cycle),
      ok: advanced.ok,
      exit_code: advanced.code,
      message: advanced.message,
      stage: 'execute',
      stage_status: 'in_progress',
      artifact_path: artifactPath,
      run_id: runId,
    };
    log(advanced.message);
  }

  const meta = {
    run_id: runId,
    suite: suite.config.suite,
    scope: suite.config.scope,
    requirement: suite.config.requirement,
    environment: suite.config.environment,
    started_at: startedAt.toISOString(),
    finished_at: new Date(finishedAtMs).toISOString(),
    duration_ms: finishedAtMs - startedAtMs,
    agent: options.agent,
    executor: { name: driver.name, version: driver.version },
    executor_source: driverChoice.source,
    target: builtInService
      ? { driver: driver.name, base_url: effectiveBaseUrl, source: 'built_in_service' }
      : { driver: driver.name, source: 'environment' },
    tool_versions: {},
    cases_total: results.length,
    cases_passed: counts.passed,
    cases_failed: counts.failed,
    cases_blocked: counts.blocked,
    cases_skipped: counts.skipped,
    evidence_manifest_sha256: manifestFingerprint,
    results_sha256: resultsHash,
    cases_file: relative(projectRoot, suite.casesFile) || suite.casesFile,
    cycle: cycleInfo,
  };
  // 脱敏留痕：先脱敏 meta 本身，再记统计（统计字段自身不参与脱敏）
  const redactedMeta = redactor.redactJson(meta);
  redactedMeta.redaction = {
    rules_applied: redactor.stats.rulesApplied,
    redacted_fields: redactor.stats.redactedFields,
  };
  writeTextAtomic(join(runDir, 'meta.json'), `${JSON.stringify(redactedMeta, null, 2)}\n`);
  writeTextAtomic(join(runDir, 'logs', 'runner.log'), `${redactor.redactText(logLines.join('\n'))}\n`);

  // 自校验：落盘之后重算指纹，确认证据链自洽
  const selfProblems = [];
  const writtenResults = JSON.parse(readFileSync(join(runDir, 'results.json'), 'utf8'));
  if (evidenceManifestFingerprint(writtenResults) !== manifestFingerprint) {
    selfProblems.push('results.json 的证据清单指纹与 meta.json 记录不一致');
  }
  if (resultsFingerprint(writtenResults) !== resultsHash) {
    selfProblems.push('results.json 的结果指纹与 meta.json 记录不一致');
  }
  for (const item of writtenResults) {
    for (const evidenceItem of item.evidence || []) {
      const absPath = join(runDir, evidenceItem.path);
      if (!existsSync(absPath)) {
        selfProblems.push(`证据文件缺失: ${evidenceItem.path}`);
        continue;
      }
      const fingerprint = fingerprintFile(absPath);
      if (fingerprint.sha256 !== evidenceItem.sha256) {
        selfProblems.push(`证据文件指纹不匹配: ${evidenceItem.path}`);
      }
    }
  }

  const payload = {
    ok: selfProblems.length === 0,
    command: 'run-suite',
    run_id: runId,
    run_dir: runDir,
    suite: suite.config.suite,
    requirement: suite.config.requirement,
    scope: suite.config.scope,
    environment: suite.config.environment,
    executor: { name: driver.name, version: driver.version },
    cases_total: results.length,
    cases_passed: counts.passed,
    cases_failed: counts.failed,
    cases_blocked: counts.blocked,
    cases_skipped: counts.skipped,
    results: results.map((item) => ({
      case_id: item.case_id,
      status: item.status,
      evidence: item.evidence.length,
      error: item.error ? item.error.type : null,
    })),
    evidence_manifest_sha256: manifestFingerprint,
    results_sha256: resultsHash,
    redaction: redactedMeta.redaction,
    cycle: cycleInfo,
    problems: selfProblems,
  };

  let exitCode = EXIT_OK;
  if (selfProblems.length > 0) exitCode = EXIT_FAIL;
  if (options.strict && (counts.failed > 0 || counts.blocked > 0)) exitCode = EXIT_FAIL;
  return { payload, exitCode };
}

/**
 * 主流程。
 */
async function main() {
  const argv = process.argv.slice(2);
  // --json 必须先于参数解析识别：否则用法错误会在 json 标志置位之前抛出，
  // stdout 会变成人读文本而不是合法 JSON。
  const jsonMode = wantsJson(argv);

  if (argv.includes('--help') || argv.includes('-h')) {
    writeOut(`${USAGE}\n`);
    process.exitCode = EXIT_OK;
    return;
  }

  const strict = argv.includes('--strict');
  const dryRun = argv.includes('--dry-run');
  const rest = argv.filter((item) => item !== '--strict' && item !== '--dry-run');
  const { flags, positionals } = parseFlags(rest, {
    value: ['cycle', 'project-root', 'run-id', 'output-dir', 'agent'],
  });
  const json = jsonMode || flags.get('json') === true;

  if (positionals.length === 0) {
    usageError(`缺少必填参数 <suite.json>\n${USAGE}`);
  }
  if (positionals.length > 1) {
    usageError(`只接受一个 suite.json 路径，多余参数: ${positionals.slice(1).join(' / ')}\n${USAGE}`);
  }

  const options = {
    suitePath: positionals[0],
    projectRoot: stringFlag(flags, 'project-root', process.cwd()),
    runId: stringFlag(flags, 'run-id', null),
    outputDir: stringFlag(flags, 'output-dir', null),
    cycle: stringFlag(flags, 'cycle', null),
    agent: stringFlag(flags, 'agent', process.env.TEST_EXEC_AGENT || 'unspecified'),
    dryRun,
    strict,
  };

  const result = await executeSuite(options);
  if (json) {
    writeJson({ ...result.payload, exit_code: result.exitCode });
  } else {
    const lines = [];
    lines.push(`套件: ${result.payload.suite}（执行器 ${result.payload.executor.name} ${result.payload.executor.version}）`);
    if (result.payload.dry_run) {
      lines.push(`[dry-run] 计划执行 ${result.payload.cases_total} 条用例，不发请求、不写产物`);
      for (const item of result.payload.plan) {
        lines.push(
          `  - ${item.case_id} ${item.title} 断言 ${item.assertions.length} 条${item.mechanical ? '' : '（不可机械判定 → blocked）'}`,
        );
      }
    } else {
      lines.push(`产物: ${result.payload.run_dir}`);
      lines.push(
        `用例: 共 ${result.payload.cases_total} 条 → 通过 ${result.payload.cases_passed} / 失败 ${result.payload.cases_failed}` +
          ` / 阻塞 ${result.payload.cases_blocked} / 跳过 ${result.payload.cases_skipped}`,
      );
      for (const item of result.payload.results) {
        lines.push(`  - ${item.case_id}: ${item.status}${item.error ? `（${item.error}）` : ''}`);
      }
      if (result.payload.cycle) lines.push(`轮次: ${result.payload.cycle.message}`);
    }
    for (const problem of result.payload.problems || []) lines.push(`[FAIL] ${problem}`);
    writeOut(`${lines.join('\n')}\n`);
  }
  process.exitCode = result.exitCode;
}

main().catch((err) => {
  const jsonMode = wantsJson(process.argv.slice(2));
  const message = err && err.message ? err.message : String(err);
  const code = err && err.code === EXIT_USAGE ? EXIT_USAGE : EXIT_FAIL;
  if (jsonMode) {
    writeJson({ ok: false, command: 'run-suite', error: message, exit_code: code });
  } else {
    writeOut(`[FAIL] ${message}\n`);
  }
  process.exitCode = code;
});
