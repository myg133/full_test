// runner.mjs —— runner 适配契约（参数映射 / runner 形态 / 边界）
//
// 事实依据（`loadtest@8.2.1` 的真实 CLI 参数表）：
//   `-t` = maxSeconds（秒）/ `-c` = concurrency / `-d` = timeout（**单请求**、毫秒）/
//   `-m` = method / `--rps` = requestsPerSecond（**每客户端**）/ `-k` = keepalive /
//   `--cores` = 核数（默认半核）；**URL 是唯一的位置参数**（多于一个 ⇒ `Too many arguments`）。
//
// ⚠️ 本模块**只做映射**：不 spawn 压测工具、不联网、不打桩、不判阈值达标。
//    产物里只允许出现「该敲什么命令」，**绝不出现**「压出来是什么」。
//
// 三条硬纪律（契约 F4 / F5 / F7）：
//   1. **多段不合并**：`profile.steps[]` 每段一条 invocation（合并 = 丢梯度 = 失真）；
//   2. **`args` 未知键一律拒绝**（静默忽略 = 悄悄丢参数 = 压出来的不是你想压的）；
//   3. **`python` runner 必须自陈完整命令**（不许编造默认命令 —— 没有事实支撑的命令 = 凭空造）。

import { InputError } from './io.mjs';

/** runner 枚举（逐字取自负载模型的 `tool.runner`）。 */
export const RUNNERS = ['loadtest', 'python'];

/** runtime 枚举（逐字取自负载模型的 `tool.runtime`）。 */
export const RUNTIMES = ['bun', 'python', 'node'];

/** 负载画像类型枚举（逐字取自负载模型的 `profile.type`）。 */
export const PROFILE_TYPES = ['constant', 'ramp-up', 'ramp-down', 'spike', 'soak'];

/** `args` 的**已知键白名单**（按 runner 分；跨 runner 的键同样拒绝）。 */
export const ARGS_WHITELIST = {
  loadtest: ['rps', 'keepalive', 'timeout_s', 'method'],
  python: ['command'],
};

/** `python` runner 允许出现的占位符。 */
export const ALLOWED_PLACEHOLDERS = ['duration_s', 'concurrency'];

/** 压测结论键（**任意层级**都不许出现；`thresholds_status` **不算** `status`）。 */
export const FORBIDDEN_CONCLUSION_KEYS = [
  'status',
  'result',
  'verdict',
  'executed',
  'passed',
  'outcome',
  'conclusion',
];

/** 执行痕迹键（本 REQ **一个请求都不发** ⇒ 产物里不许有「跑过」的痕迹）。 */
export const EXECUTION_TRACE_KEYS = [
  'executed',
  'started_at',
  'finished_at',
  'timestamp',
  'duration_ms',
  'elapsed',
  'latency',
  'bytes',
  'status_code',
  'response',
  'responses',
  'samples',
  'metrics',
  'result_rows',
];

/** 禁表述（字符串值里出现即判红 —— 堵「用中文写一句『已压测通过』」的绕法）。 */
export const FORBIDDEN_PHRASES = ['已压测', '已达标', '已通过', '压测完成', '压测结果'];

/** 未决问题的主题枚举。 */
export const OQ_TOPICS = ['thresholds', 'coverage', 'runner', 'other'];

/** 未决问题 id 的形态。 */
export const OQ_ID_PATTERN = /^OQ-\d{3}$/;

/**
 * 拆 `target`（形态 `METHOD /path`）。
 * @param {*} target 负载模型里的 target
 * @returns {{method: string, path: string}}
 */
export function parseTarget(target) {
  if (typeof target !== 'string' || target.trim() === '') {
    throw new InputError(`target 必须是非空字符串（形态 "METHOD /path"），实际是 ${JSON.stringify(target)}`);
  }
  const cut = target.indexOf(' ');
  if (cut <= 0) {
    throw new InputError(`target 必须是 "METHOD /path" 形态（方法 + 空格 + 以 / 开头的路径），实际是 ${JSON.stringify(target)}`);
  }
  const method = target.slice(0, cut);
  const path = target.slice(cut + 1);
  if (!/^[A-Z][A-Z0-9_-]*$/.test(method)) {
    throw new InputError(`target 的方法部分必须是大写方法名，实际是 ${JSON.stringify(method)}（target=${JSON.stringify(target)}）`);
  }
  if (!path.startsWith('/')) {
    throw new InputError(`target 的路径部分必须以 / 开头，实际是 ${JSON.stringify(path)}（target=${JSON.stringify(target)}）`);
  }
  if (/\s/.test(path)) {
    throw new InputError(`target 的路径部分不能含空白，实际是 ${JSON.stringify(path)}（target=${JSON.stringify(target)}）`);
  }
  return { method, path };
}

/**
 * 拼完整绝对 URL（`base_url` 去尾部 `/` + 目标路径）。
 * ⚠️ 场景条目里的 `base_url` **字段**仍逐字等于环境文件里的值（**含**尾斜杠）；
 *    只有拼出来的 **URL** 不带尾斜杠（URL 里不得出现 `//`）。
 * @param {string} baseUrl 环境文件里的 base_url（逐字）
 * @param {string} path 目标路径（以 / 开头）
 * @returns {string} 完整绝对 URL
 */
export function buildUrl(baseUrl, path) {
  return `${String(baseUrl).replace(/\/+$/, '')}${path}`;
}

/**
 * 核 `args` 的键是否都在该 runner 的白名单里。
 * @param {string} runner runner 名
 * @param {*} args 负载模型里的 args
 */
export function assertArgsKeys(runner, args) {
  const allowed = ARGS_WHITELIST[runner] || [];
  for (const key of Object.keys(args)) {
    if (!allowed.includes(key)) {
      throw new InputError(
        `args 里有未知的键 "${key}"（runner=${runner} 只认 ${allowed.join(' / ')}）—— `
        + '未知键一律拒绝，不静默忽略也不透传',
      );
    }
  }
}

/**
 * 构造 `loadtest` runner 的一条 argv（规范形态见契约 F4.1）。
 * @param {object} model 负载模型本体
 * @param {object} step 该段的 `{duration_s, concurrency}`
 * @param {string} baseUrl 环境文件里的 base_url（逐字）
 * @returns {string[]} 完整可跑的 argv
 */
export function buildLoadtestArgv(model, step, baseUrl) {
  const { method, path } = parseTarget(model.target);
  const args = model.args && typeof model.args === 'object' ? model.args : {};
  const verb = args.method ? String(args.method).toUpperCase() : method.toUpperCase();
  const argv = [
    'loadtest',
    '-t',
    String(step.duration_s),
    '-c',
    String(step.concurrency),
    // ⚠️ 恒定钉死：默认是半核，且 rps / maxRequests 都按核分摊 ⇒ 不钉则语义随机器变
    '--cores',
    '1',
    buildUrl(baseUrl, path),
    '-m',
    verb,
  ];
  if (args.rps !== undefined) argv.push('--rps', String(args.rps));
  if (args.keepalive === true) argv.push('-k');
  // ⚠️ `timeout_s` 是**秒**，`-d` 是**毫秒**且是**单请求**超时（不是压测总时长）
  if (args.timeout_s !== undefined) argv.push('-d', String(Math.round(Number(args.timeout_s) * 1000)));
  return argv;
}

/**
 * 构造 `python` runner 的一条 argv（自陈命令 + 占位符替换）。
 * ⚠️ **不许**为 `python` runner 编造默认命令 —— 没有事实支撑的命令 = 凭空造。
 * @param {object} model 负载模型本体
 * @param {object} step 该段的 `{duration_s, concurrency}`
 * @returns {string[]} 完整 argv
 */
export function buildPythonArgv(model, step) {
  const args = model.args && typeof model.args === 'object' ? model.args : {};
  const command = args.command;
  if (!Array.isArray(command) || command.length === 0) {
    throw new InputError(
      'python runner 必须由 args.command 自陈完整命令（完整 argv 数组）—— 缺 command；'
      + '本工具不许为 python runner 编造默认命令',
    );
  }
  const substituted = command.map((item) => String(item)
    .replace(/\{duration_s\}/g, String(step.duration_s))
    .replace(/\{concurrency\}/g, String(step.concurrency)));
  for (const item of substituted) {
    const hit = /\{([^}]*)\}/.exec(item);
    if (hit) {
      throw new InputError(
        `args.command 里有未知的占位符 "${hit[0]}" —— 只允许 {duration_s} 与 {concurrency}`,
      );
    }
  }
  const argv = substituted.slice();
  // 契约要求 argv 里含有该段的时长与并发取值；自陈命令没带占位符时补上（值来自模型，不是编造）
  if (!argv.includes(String(step.duration_s))) argv.push(String(step.duration_s));
  if (!argv.includes(String(step.concurrency))) argv.push(String(step.concurrency));
  return argv;
}

/**
 * 按 runner 构造一条 argv。
 * @param {object} model 负载模型本体
 * @param {object} step 该段的 `{duration_s, concurrency}`
 * @param {string} baseUrl 环境文件里的 base_url（逐字）
 * @returns {string[]} 完整可跑的 argv
 */
export function buildArgv(model, step, baseUrl) {
  const runner = model.tool && model.tool.runner;
  if (runner === 'loadtest') return buildLoadtestArgv(model, step, baseUrl);
  if (runner === 'python') return buildPythonArgv(model, step);
  throw new InputError(`runner 取值非法: ${JSON.stringify(runner)}（只允许 ${RUNNERS.join(' / ')}）`);
}
