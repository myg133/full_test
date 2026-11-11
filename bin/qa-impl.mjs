/**
 * qa-impl —— `qa` 工具链自举机制的实现（REQ-003）
 *
 * 机制契约见 `references/tools-chain-contract.md`；需求见
 * `BA/demands/REQ-002-suite-foundation/REQ-003-tools-bootstrap/demand.md`。
 *
 * 核心约束（逐条对应需求的功能要求）：
 *   F1   `<project-root>/.tools/` 统一布局：manifest.json（进 Git）+ .venv/ node/ bin/ cache/ state.json（不进 Git）
 *   F1b 入口是包级 CLI（`bin/qa`），工具链是项目级（`.tools/`）—— 入口不放进 `.tools/`
 *   F2   声明式清单 + 三条硬规则（锁版本 / 不越界 / 必须有 verify）
 *   F3   子命令 list / doctor / install / run / which（+ init / isolation）
 *   F4   隔离性：安装目标全在 `.tools/` 内，`qa run` 的 PATH 以 `.tools/` 优先
 *   F5   失败显式：状态只有 ok / missing / failed / unavailable 四种，没有"跳过"
 *   F6   `state.json` 记录 name / version / source / installed_at / checksum
 *
 * 非功能约束：零第三方依赖（只用 `node:` 内置模块）、Linux/macOS 可移植、
 * 幂等、退出码 0 / 1 / 2。
 */

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

/** 退出码：成功。 */
const EXIT_OK = 0;
/** 退出码：校验失败或工具不可用。 */
const EXIT_FAIL = 1;
/** 退出码：调用方式错误。 */
const EXIT_USAGE = 2;

/** 工具链根目录名（项目级）。 */
const TOOLS_DIRNAME = '.tools';
/** 清单文件名（进 Git）。 */
const MANIFEST_BASENAME = 'manifest.json';
/** 安装状态文件名（不进 Git）。 */
const STATE_BASENAME = 'state.json';
/** 清单格式版本。 */
const MANIFEST_VERSION = 1;
/** 状态文件格式版本。 */
const STATE_VERSION = 1;

/** 每种工具 kind 对应的运行时与安装产物目录。 */
const KIND_RUNTIME = { python: 'uv', node: 'bun', binary: null };

/** 每种工具 kind 允许的包管理器（install 模板的第一个 token）。 */
const KIND_PACKAGE_MANAGER = { python: ['uv', 'pip'], node: ['bun', 'npm'] };

/** 项目根 `.gitignore` 必须包含的规则（顺序敏感，缺一不可）。 */
const GITIGNORE_RULES = ['.tools/*', '!.tools/manifest.json'];

/** 工具状态取值（只有这四种，不存在"跳过"）。 */
const STATUS_OK = 'ok';
const STATUS_MISSING = 'missing';
const STATUS_FAILED = 'failed';
const STATUS_UNAVAILABLE = 'unavailable';

/** 判定"网络/环境不可达"的错误特征（用于区分 failed 与 unavailable）。 */
const NETWORK_HINTS = [
  /ENOTFOUND/i,
  /ECONNREFUSED/i,
  /ETIMEDOUT/i,
  /EAI_AGAIN/i,
  /timed out/i,
  /network/i,
  /unable to connect/i,
  /could not resolve/i,
  /failed to fetch/i,
  /connection refused/i,
  /getaddrinfo/i,
  /no route to host/i,
];

/** 禁止出现在 install 命令里的越界标志。 */
const FORBIDDEN_INSTALL_FLAGS = new Set([
  '--user',
  '--system',
  '--global',
  '--prefix',
  '--root',
  '--break-system-packages',
]);

// ---------------------------------------------------------------------------
// 错误类型
// ---------------------------------------------------------------------------

/** 调用方式错误（未知子命令、缺参数等）→ 退出码 2。 */
class UsageError extends Error {}

/** 清单/配置校验失败 → 退出码 1。 */
class ValidationError extends Error {}

// ---------------------------------------------------------------------------
// 通用小工具
// ---------------------------------------------------------------------------

/**
 * 极简 shell 风格分词：支持单/双引号包裹，不做变量展开。
 * @param {string} input 待分词字符串
 * @returns {string[]} token 列表
 */
export function tokenize(input) {
  const tokens = [];
  let current = '';
  let quote = null;
  let started = false;
  for (const ch of String(input)) {
    if (quote) {
      if (ch === quote) quote = null;
      else current += ch;
      started = true;
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      started = true;
      continue;
    }
    if (/\s/.test(ch)) {
      if (started) {
        tokens.push(current);
        current = '';
        started = false;
      }
      continue;
    }
    current += ch;
    started = true;
  }
  if (started) tokens.push(current);
  return tokens;
}

/**
 * 终端显示宽度（CJK 字符按 2 列算）。
 * @param {string} text 文本
 * @returns {number} 显示宽度
 */
function displayWidth(text) {
  let width = 0;
  for (const ch of String(text)) {
    const code = ch.codePointAt(0);
    width += code > 0x2e80 ? 2 : 1;
  }
  return width;
}

/**
 * 按显示宽度右侧补空格。
 * @param {string} text 文本
 * @param {number} width 目标宽度
 * @returns {string} 补齐后的文本
 */
function padDisplay(text, width) {
  const str = String(text);
  return str + ' '.repeat(Math.max(0, width - displayWidth(str)));
}

/**
 * 当前时间的 ISO-8601 字符串。
 * @returns {string} ISO 时间
 */
function nowIso() {
  return new Date().toISOString();
}

/**
 * 计算文件 sha256。
 * @param {string} filePath 文件路径
 * @returns {string|null} sha256 十六进制；文件不存在时返回 null
 */
function sha256File(filePath) {
  try {
    const hash = crypto.createHash('sha256');
    hash.update(fs.readFileSync(filePath));
    return hash.digest('hex');
  } catch {
    return null;
  }
}

/**
 * 文件大小（字节）。
 * @param {string} filePath 文件路径
 * @returns {number} 字节数；不存在时为 0
 */
function fileSize(filePath) {
  try {
    return fs.statSync(filePath).size;
  } catch {
    return 0;
  }
}

/**
 * 人类可读的体积。
 * @param {number} bytes 字节数
 * @returns {string} 形如 "12.3 KB"
 */
function humanSize(bytes) {
  if (!bytes) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  let value = bytes;
  let index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index += 1;
  }
  return `${value.toFixed(index === 0 ? 0 : 1)} ${units[index]}`;
}

/**
 * 判断一个路径 token 是否落在 toolsRoot 之内。
 * @param {string} candidate 路径（可能含占位符）
 * @param {string} toolsRoot 工具链根绝对路径
 * @returns {boolean} 是否在工具链内
 */
function isInsideTools(candidate, toolsRoot) {
  if (!candidate) return false;
  if (candidate.includes('{tools}')) return true;
  if (!path.isAbsolute(candidate)) return false;
  const resolved = path.resolve(candidate);
  const root = path.resolve(toolsRoot);
  return resolved === root || resolved.startsWith(root + path.sep);
}

// ---------------------------------------------------------------------------
// 参数解析
// ---------------------------------------------------------------------------

/**
 * 解析命令行参数。
 *
 * 全局选项 `--project <dir>` 可出现在任意位置；`--` 之后的参数原样保留
 * （`qa run <name> -- <args>` 需要把参数透传给被调工具）。
 *
 * @param {string[]} argv 参数数组（不含 node 与脚本名）
 * @returns {{command: string, args: string[], project: string|null, passthrough: string[], help: boolean, version: boolean}} 解析结果
 */
export function parseArgv(argv) {
  const result = {
    command: '',
    args: [],
    project: null,
    passthrough: [],
    help: false,
    version: false,
    verify: false,
  };
  const positional = [];
  let afterSeparator = false;

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (afterSeparator) {
      result.passthrough.push(arg);
      continue;
    }
    if (arg === '--') {
      afterSeparator = true;
      continue;
    }
    if (arg === '--help' || arg === '-h') {
      result.help = true;
      continue;
    }
    if (arg === '--version' || arg === '-V') {
      result.version = true;
      continue;
    }
    if (arg === '--verify') {
      result.verify = true;
      continue;
    }
    if (arg === '--project') {
      const value = argv[i + 1];
      if (value === undefined) throw new UsageError('--project 需要一个目录参数');
      result.project = value;
      i += 1;
      continue;
    }
    if (arg.startsWith('--project=')) {
      result.project = arg.slice('--project='.length);
      continue;
    }
    if (arg.startsWith('-') && arg !== '-') {
      throw new UsageError(`未知选项：${arg}`);
    }
    positional.push(arg);
  }

  result.command = positional[0] ?? '';
  result.args = positional.slice(1);
  return result;
}

// ---------------------------------------------------------------------------
// 项目 / 清单 / 状态
// ---------------------------------------------------------------------------

/**
 * 工具链根目录。
 * @param {string} projectRoot 项目根
 * @returns {string} `.tools` 绝对路径
 */
function toolsRoot(projectRoot) {
  return path.join(projectRoot, TOOLS_DIRNAME);
}

/**
 * 清单文件路径。
 * @param {string} projectRoot 项目根
 * @returns {string} manifest.json 绝对路径
 */
function manifestPath(projectRoot) {
  return path.join(toolsRoot(projectRoot), MANIFEST_BASENAME);
}

/**
 * 状态文件路径。
 * @param {string} projectRoot 项目根
 * @returns {string} state.json 绝对路径
 */
function statePath(projectRoot) {
  return path.join(toolsRoot(projectRoot), STATE_BASENAME);
}

/**
 * 解析项目根目录：命令行 > 环境变量 > 当前工作目录。
 * @param {string|null} explicit 命令行传入的目录
 * @returns {string} 项目根绝对路径
 */
function resolveProjectRoot(explicit) {
  if (explicit) return path.resolve(explicit);
  const env = process.env.QA_PROJECT_ROOT;
  if (env && env.trim()) return path.resolve(env.trim());
  return process.cwd();
}

/**
 * 读取并解析清单文件。
 * @param {string} projectRoot 项目根
 * @returns {object} 清单对象
 */
function readManifest(projectRoot) {
  const file = manifestPath(projectRoot);
  if (!fs.existsSync(file)) {
    throw new ValidationError(
      `未找到工具清单：${file}\n  提示：在项目根运行 \`qa init\` 生成清单骨架，或手工创建该文件。`,
    );
  }
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (err) {
    throw new ValidationError(`工具清单不是合法 JSON：${file}（${err.message}）`);
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new ValidationError(`工具清单结构非法（应为对象）：${file}`);
  }
  return parsed;
}

/**
 * 读取安装状态文件；不存在时返回空骨架。
 * @param {string} projectRoot 项目根
 * @returns {object} 状态对象
 */
function readState(projectRoot) {
  const file = statePath(projectRoot);
  if (!fs.existsSync(file)) {
    return { version: STATE_VERSION, updated_at: null, tools: {} };
  }
  try {
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw new Error('结构非法');
    }
    if (!parsed.tools || typeof parsed.tools !== 'object') parsed.tools = {};
    return parsed;
  } catch (err) {
    throw new ValidationError(`安装状态文件不可读或已损坏：${file}（${err.message}）`);
  }
}

/**
 * 写回安装状态文件；内容无变化时不落盘（保持"幂等不改已装内容"）。
 * @param {string} projectRoot 项目根
 * @param {object} state 状态对象
 */
function writeState(projectRoot, state) {
  const file = statePath(projectRoot);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const next = { ...state, version: STATE_VERSION, updated_at: nowIso() };
  if (fs.existsSync(file)) {
    try {
      const previous = JSON.parse(fs.readFileSync(file, 'utf8'));
      const strip = (obj) => {
        const copy = { ...obj };
        delete copy.updated_at;
        return JSON.stringify(copy);
      };
      if (strip(previous) === strip(next)) return;
    } catch {
      // 旧文件损坏：直接重写
    }
  }
  fs.writeFileSync(file, `${JSON.stringify(next, null, 2)}\n`, 'utf8');
}

// ---------------------------------------------------------------------------
// 清单校验
// ---------------------------------------------------------------------------

/**
 * 解析 spec 中的版本部分。
 * @param {object} tool 清单条目
 * @returns {{version: string|null, error: string|null}} 版本与错误原因
 */
export function parseSpecVersion(tool) {
  const spec = String(tool.spec ?? '').trim();
  if (!spec) return { version: null, error: 'spec 为空' };

  if (tool.kind === 'python') {
    const match = spec.match(/^([A-Za-z0-9][A-Za-z0-9._-]*)(\[[^\]]+\])?==(.+)$/);
    if (!match) {
      return { version: null, error: `spec "${spec}" 不是精确锁定形式（应形如 name==1.2.3）` };
    }
    const version = match[3].trim();
    if (!/^\d[0-9A-Za-z.*+!-]*$/.test(version) || version.includes('*')) {
      return { version: null, error: `spec "${spec}" 的版本部分不是精确版本` };
    }
    return { version, error: null };
  }

  if (tool.kind === 'node') {
    const match = spec.match(/^(@[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+|[A-Za-z0-9][A-Za-z0-9._-]*)@(.+)$/);
    if (!match) {
      return { version: null, error: `spec "${spec}" 不是精确锁定形式（应形如 name@1.2.3）` };
    }
    const version = match[2].trim();
    if (!/^\d[0-9A-Za-z.+-]*$/.test(version)) {
      return { version: null, error: `spec "${spec}" 的版本部分不是精确版本` };
    }
    return { version, error: null };
  }

  // binary：spec 可以是精确版本号，也可以是带版本号的下载 URL
  if (/^(>=|<=|>|<|\^|~|\*)/.test(spec) || /latest/i.test(spec)) {
    return { version: null, error: `spec "${spec}" 未锁定版本` };
  }
  if (spec.startsWith('http://') || spec.startsWith('https://')) {
    return { version: spec, error: null };
  }
  if (!/^\d[0-9A-Za-z.+-]*$/.test(spec)) {
    return { version: null, error: `spec "${spec}" 不是精确版本` };
  }
  return { version: spec, error: null };
}

/**
 * 检查 install 命令模板是否越界（写出 `.tools/` 之外）。
 * @param {object} tool 清单条目
 * @param {string} root 工具链根绝对路径
 * @returns {string|null} 违规说明；未违规时返回 null
 */
export function checkInstallBoundary(tool, root) {
  const template = String(tool.install?.[KIND_RUNTIME[tool.kind]] ?? '');
  const tokens = tokenize(template);
  if (!tokens.length) return null;

  for (let i = 0; i < tokens.length; i += 1) {
    const token = tokens[i];
    if (FORBIDDEN_INSTALL_FLAGS.has(token)) {
      return `install 命令含越界标志 "${token}"`;
    }
    if (token.startsWith('--prefix=') || token.startsWith('--target=') || token.startsWith('--root=')) {
      const flag = token.slice(0, token.indexOf('='));
      const value = token.slice(token.indexOf('=') + 1);
      if (flag !== '--target' || !isInsideTools(value, root)) {
        return `install 命令的 ${flag} 指向 .tools/ 之外（"${value}"）`;
      }
      continue;
    }
    if (token === '--target') {
      const value = tokens[i + 1] ?? '';
      if (!isInsideTools(value, root)) {
        return `install 命令的 --target 指向 .tools/ 之外（"${value}"）`;
      }
      continue;
    }
    if (token === '-g') {
      return 'install 命令含全局安装标志 "-g"';
    }
    if (token === 'sudo') {
      return 'install 命令含 "sudo"';
    }
    if (token.includes('~') || token.startsWith('$HOME') || token.startsWith('${HOME}')) {
      return `install 命令引用了用户主目录（"${token}"）`;
    }
    if (token.includes('..')) {
      return `install 命令含上级目录引用（"${token}"）`;
    }
    if (path.isAbsolute(token) && !isInsideTools(token, root)) {
      return `install 命令写到 .tools/ 之外的绝对路径（"${token}"）`;
    }
  }
  return null;
}

/**
 * 校验可选字段 `entry` / `module` 的合法性。
 *
 * 这两个字段会参与**文件路径**的拼装（入口文件名 / Python 模块名），
 * 因此必须与 `name` 同级对待：不含任何路径语义（分隔符、`..`、绝对路径、`~`）。
 * 否则白名单只约束了"名字"，真正被执行的文件却可以指向 `.tools/` 之外。
 *
 * @param {object} tool 清单条目
 * @returns {string[]} 违规说明列表（空数组表示通过）
 */
export function checkEntryFields(tool) {
  const problems = [];
  const entry = tool.entry;
  if (entry !== undefined && entry !== null) {
    if (typeof entry !== 'string' || !entry.trim()) {
      problems.push(`entry 必须是非空字符串（实际 ${JSON.stringify(entry)}）`);
    } else if (/[\\/]/.test(entry)) {
      problems.push(`entry 不得包含路径分隔符（实际 "${entry}"）`);
    } else if (entry.includes('..')) {
      problems.push(`entry 不得包含 ".."（实际 "${entry}"）`);
    } else if (entry.startsWith('~')) {
      problems.push(`entry 不得引用用户主目录（实际 "${entry}"）`);
    } else if (path.isAbsolute(entry)) {
      problems.push(`entry 不得是绝对路径（实际 "${entry}"）`);
    } else if (!/^[A-Za-z0-9][A-Za-z0-9._+-]*$/.test(entry)) {
      problems.push(`entry 只允许字母数字与 . _ + -（实际 "${entry}"）`);
    }
  }
  const moduleName = tool.module;
  if (moduleName !== undefined && moduleName !== null) {
    if (typeof moduleName !== 'string' || !moduleName.trim()) {
      problems.push(`module 必须是非空字符串（实际 ${JSON.stringify(moduleName)}）`);
    } else if (/[\\/]/.test(moduleName)) {
      problems.push(`module 不得包含路径分隔符（实际 "${moduleName}"）`);
    } else if (moduleName.includes('..')) {
      problems.push(`module 不得包含 ".."（实际 "${moduleName}"）`);
    } else if (moduleName.startsWith('~')) {
      problems.push(`module 不得引用用户主目录（实际 "${moduleName}"）`);
    } else if (path.isAbsolute(moduleName)) {
      problems.push(`module 不得是绝对路径（实际 "${moduleName}"）`);
    } else if (!/^[A-Za-z0-9_][A-Za-z0-9._]*$/.test(moduleName)) {
      problems.push(`module 只允许字母数字、下划线与点（实际 "${moduleName}"）`);
    }
  }
  return problems;
}

/**
 * 校验 install 模板的**第一个 token** —— 必须是该 kind 的包管理器。
 *
 * 只约束"写到哪儿"是不够的：模板若能跑任意可执行文件（`sh -c ...`），
 * "只装包管理器"这条隐含约束就落空了。
 *
 * @param {object} tool 清单条目
 * @returns {string|null} 违规说明；未违规时返回 null
 */
export function checkInstallCommand(tool) {
  const runtimeKey = KIND_RUNTIME[tool.kind];
  if (!runtimeKey) return null; // binary 走下载 URL 路线，没有命令模板
  const template = String(tool.install?.[runtimeKey] ?? '').trim();
  if (!template) return `install.${runtimeKey} 为空`;
  const tokens = tokenize(template);
  if (!tokens.length) return `install.${runtimeKey} 为空`;
  const allowed = KIND_PACKAGE_MANAGER[tool.kind] || [];
  if (!allowed.includes(tokens[0])) {
    return `install.${runtimeKey} 的第一个 token 必须是 ${allowed.join(' / ')}（实际 "${tokens[0]}"）`;
  }
  return null;
}

/**
 * 校验整个清单。
 * @param {object} manifest 清单对象
 * @param {string} root 工具链根绝对路径
 * @returns {string[]} 错误列表（空数组表示通过）
 */
export function validateManifest(manifest, root) {
  const errors = [];
  if (manifest.version !== MANIFEST_VERSION) {
    errors.push(`清单 version 应为 ${MANIFEST_VERSION}，实际为 ${JSON.stringify(manifest.version ?? null)}`);
  }
  if (!Array.isArray(manifest.tools)) {
    errors.push('清单缺少 tools 数组');
    return errors;
  }

  const seen = new Set();
  manifest.tools.forEach((tool, index) => {
    const label = tool && typeof tool.name === 'string' ? tool.name : `#${index}`;
    if (!tool || typeof tool !== 'object' || Array.isArray(tool)) {
      errors.push(`第 ${index} 个工具条目不是对象`);
      return;
    }
    for (const field of ['name', 'kind', 'spec', 'purpose', 'required_by', 'install', 'verify']) {
      if (tool[field] === undefined || tool[field] === null) {
        errors.push(`工具 ${label} 缺少必填字段 "${field}"`);
      }
    }
    if (typeof tool.name !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._@-]*$/.test(tool.name)) {
      errors.push(`工具 ${label} 的 name 非法（只允许字母数字与 . _ @ -，且不得含路径分隔符）`);
    } else if (seen.has(tool.name)) {
      errors.push(`工具名重复：${tool.name}（name 必须全局唯一）`);
    } else {
      seen.add(tool.name);
    }
    if (!Object.prototype.hasOwnProperty.call(KIND_RUNTIME, tool.kind)) {
      errors.push(`工具 ${label} 的 kind 非法（应为 ${Object.keys(KIND_RUNTIME).join(' / ')}）`);
    }
    if (typeof tool.required_by !== 'undefined' && !Array.isArray(tool.required_by)) {
      errors.push(`工具 ${label} 的 required_by 应为数组`);
    }
    if (tool.install && typeof tool.install === 'object') {
      const runtimeKey = KIND_RUNTIME[tool.kind];
      if (runtimeKey && !tool.install[runtimeKey]) {
        errors.push(`工具 ${label} 缺少 install.${runtimeKey}`);
      }
      if (tool.kind === 'binary' && !tool.install.url) {
        errors.push(`工具 ${label} 缺少 install.url`);
      }
    }
    if (tool.verify && typeof tool.verify === 'object') {
      if (typeof tool.verify.command !== 'string' || !tool.verify.command.trim()) {
        errors.push(`工具 ${label} 缺少 verify.command`);
      }
      if (typeof tool.verify.match !== 'string') {
        errors.push(`工具 ${label} 缺少 verify.match`);
      }
    }
    if (tool.spec && typeof tool.spec === 'string') {
      const parsed = parseSpecVersion(tool);
      if (parsed.error) errors.push(`工具 ${label} 版本未锁定：${parsed.error}`);
    }
    if (tool.install && typeof tool.install === 'object' && tool.kind) {
      const violation = checkInstallBoundary(tool, root);
      if (violation) errors.push(`工具 ${label} 安装路径越界：${violation}`);
      const commandViolation = checkInstallCommand(tool);
      if (commandViolation) errors.push(`工具 ${label} install 命令非法：${commandViolation}`);
    }
    for (const problem of checkEntryFields(tool)) {
      errors.push(`工具 ${label} 入口路径越界：${problem}`);
    }
  });

  return errors;
}

// ---------------------------------------------------------------------------
// 执行环境
// ---------------------------------------------------------------------------

/**
 * 构造隔离环境的 PATH 前缀目录。
 * @param {string} root 工具链根绝对路径
 * @param {object} tool 清单条目
 * @returns {string[]} 目录列表
 */
function toolBinDirs(root, tool) {
  const dirs = [path.join(root, 'bin')];
  if (tool.kind === 'python') dirs.push(path.join(root, '.venv', 'bin'));
  if (tool.kind === 'node') dirs.push(path.join(root, 'node', 'node_modules', '.bin'));
  return dirs;
}

/**
 * 构造执行工具时的环境变量（PATH 以 `.tools/` 优先）。
 * @param {string} root 工具链根绝对路径
 * @param {object|null} tool 清单条目；null 表示通用环境
 * @returns {object} 环境变量
 */
function isolatedEnv(root, tool) {
  const dirs = tool ? toolBinDirs(root, tool) : [path.join(root, 'bin')];
  const env = { ...process.env };
  env.PATH = [...dirs, process.env.PATH || ''].filter(Boolean).join(path.delimiter);
  // 避免用户级 site-packages 混入，隔离更干净
  env.PYTHONNOUSERSITE = '1';
  env.PYTHONDONTWRITEBYTECODE = '1';
  return env;
}

/**
 * 在 PATH 中查找可执行文件（不启动子进程）。
 * @param {string} name 可执行文件名
 * @param {string} pathValue PATH 值
 * @returns {string|null} 命中路径
 */
function findOnPath(name, pathValue) {
  const dirs = (pathValue || '').split(path.delimiter).filter(Boolean);
  for (const dir of dirs) {
    const candidate = path.join(dir, name);
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      if (fs.statSync(candidate).isFile()) return candidate;
    } catch {
      // 不可访问就继续找下一个目录
    }
  }
  return null;
}

/**
 * 查找 venv 内的 Python 模块。
 * @param {string} venvDir venv 目录
 * @param {string} moduleName 模块名
 * @returns {string|null} site-packages 下的模块路径
 */
function findPythonModule(venvDir, moduleName) {
  const libDir = path.join(venvDir, 'lib');
  if (!fs.existsSync(libDir)) return null;
  for (const entry of fs.readdirSync(libDir)) {
    const sitePackages = path.join(libDir, entry, 'site-packages', moduleName);
    if (fs.existsSync(sitePackages)) return sitePackages;
  }
  return null;
}

/**
 * 解析工具的可执行入口。
 *
 * **越界即拒**：无论入口名来自 `name` 还是可选字段 `entry`，拼装出的路径
 * 必须落在 `.tools/` 之内，否则返回 null（调用方据此判 `failed` / 拒绝执行）。
 * 这一层是清单校验之外的兜底：白名单放行的是"名字"，真正被执行的文件必须再受约束。
 *
 * @param {string} root 工具链根绝对路径
 * @param {object} tool 清单条目
 * @returns {{path: string, args: string[]}|null} 入口描述；未安装或越界时为 null
 */
export function resolveExecutable(root, tool) {
  const entryName = tool.entry || tool.name;
  const inside = (candidate, args) => (isInsideTools(candidate, root) ? { path: candidate, args } : null);
  if (tool.kind === 'python') {
    const venvBin = path.join(root, '.venv', 'bin');
    const direct = path.join(venvBin, entryName);
    if (fs.existsSync(direct)) return inside(direct, []);
    const moduleName = tool.module || tool.name.replace(/-/g, '_');
    const python = path.join(venvBin, 'python');
    if (fs.existsSync(python) && findPythonModule(path.join(root, '.venv'), moduleName)) {
      return inside(python, ['-m', moduleName]);
    }
    return null;
  }
  if (tool.kind === 'node') {
    const candidate = path.join(root, 'node', 'node_modules', '.bin', entryName);
    return fs.existsSync(candidate) ? inside(candidate, []) : null;
  }
  const candidate = path.join(root, 'bin', entryName);
  return fs.existsSync(candidate) ? inside(candidate, []) : null;
}

/**
 * 判断工具的入口声明是否越界（`entry` / `module` 含路径语义）。
 *
 * @param {object} tool 清单条目
 * @returns {string|null} 违规说明；未违规时返回 null
 */
export function entryViolation(tool) {
  const problems = checkEntryFields(tool);
  return problems.length ? problems[0] : null;
}

// ---------------------------------------------------------------------------
// 子进程执行
// ---------------------------------------------------------------------------

/**
 * 执行一条命令并收集结果。
 * @param {string} command 可执行文件
 * @param {string[]} args 参数
 * @param {object} options cwd / env / timeout
 * @returns {{status: number|null, stdout: string, stderr: string, error: string|null, durationMs: number}} 执行结果
 */
function runProcess(command, args, options = {}) {
  const started = Date.now();
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    env: options.env || process.env,
    encoding: 'utf8',
    timeout: options.timeout ?? 600000,
    maxBuffer: 32 * 1024 * 1024,
    windowsHide: true,
  });
  return {
    status: result.status,
    stdout: result.stdout || '',
    stderr: result.stderr || '',
    error: result.error ? result.error.message : null,
    durationMs: Date.now() - started,
  };
}

/**
 * 判断一次安装失败是否属于"环境/网络不可达"（unavailable）而非普通失败（failed）。
 * @param {object} result 执行结果
 * @returns {boolean} 是否不可用
 */
function looksUnavailable(result) {
  const blob = `${result.error || ''}\n${result.stderr || ''}\n${result.stdout || ''}`;
  return NETWORK_HINTS.some((pattern) => pattern.test(blob));
}

/**
 * 判断一个工具状态是否属于"环境级阻塞"（索引/网络/运行时不可达）。
 *
 * 目的：让 `qa doctor` 把这类问题**汇总成环境级结论**，
 * 而不是只表现为某个工具 failed/unavailable —— 前者指向"修环境"，后者指向"改清单"。
 *
 * @param {{status: string, reason: string|null}} status 工具状态
 * @returns {boolean} 是否环境级阻塞
 */
function isEnvironmentBlocked(status) {
  if (!status) return false;
  if (status.status === STATUS_UNAVAILABLE) return true;
  const reason = status.reason || '';
  return NETWORK_HINTS.some((pattern) => pattern.test(reason));
}

/**
 * 生成"该修环境"的提示（按 kind 给出对应的镜像/运行时变量）。
 * @param {object} tool 清单条目
 * @returns {string} 提示文本
 */
function environmentHint(tool) {
  if (tool.kind === 'python') {
    return 'python 路线请设置 UV_DEFAULT_INDEX（或 UV_INDEX_URL）指向可达镜像；PIP_INDEX_URL 对 uv 不生效。缺运行时则安装 uv。';
  }
  if (tool.kind === 'node') {
    return 'node 路线请设置 npm_config_registry 指向可达镜像；缺运行时则安装 bun（或 npm）。';
  }
  return '请检查该下载源当前是否可达（地址/版本是否存在、来源服务是否在线）。';
}

// ---------------------------------------------------------------------------
// 安装
// ---------------------------------------------------------------------------

/**
 * 生成安装命令模板中的实际参数（替换占位符）。
 * @param {object} tool 清单条目
 * @param {string} root 工具链根绝对路径
 * @returns {string[]} token 列表
 */
function renderInstallTemplate(tool, root) {
  const runtimeKey = KIND_RUNTIME[tool.kind];
  const template = String(tool.install[runtimeKey] ?? '');
  const rendered = template.split('{spec}').join(tool.spec).split('{tools}').join(root);
  return tokenize(rendered);
}

/**
 * 从 uv 配置文件里解析默认索引地址。
 *
 * 只做最小解析：uv.toml 的 `default-index` / `index` / `[[index]]` 的 `url`。
 * 解析不出就返回 null（交给下一级或默认值）。
 *
 * @param {string} filePath uv.toml 路径
 * @returns {string|null} 索引地址
 */
function parseUvIndexFile(filePath) {
  let text;
  try {
    text = fs.readFileSync(filePath, 'utf8');
  } catch {
    return null;
  }
  const patterns = [/^\s*default-index\s*=\s*"([^"]+)"/m, /^\s*index\s*=\s*"([^"]+)"/m, /^\s*url\s*=\s*"([^"]+)"/m];
  for (const pattern of patterns) {
    const match = text.match(pattern);
    if (match) return match[1];
  }
  return null;
}

/**
 * 从 .npmrc 里解析 registry。
 * @param {string} filePath .npmrc 路径
 * @returns {string|null} registry 地址
 */
function parseNpmrcRegistry(filePath) {
  let text;
  try {
    text = fs.readFileSync(filePath, 'utf8');
  } catch {
    return null;
  }
  const match = text.match(/^\s*registry\s*=\s*(.+?)\s*$/m);
  return match ? match[1] : null;
}

/**
 * 解析 uv **实际会使用**的索引地址。
 *
 * 优先级与 uv 一致：环境变量 > 项目级 uv.toml > 用户级 uv.toml > 内置默认。
 * 特别注意：`PIP_INDEX_URL` 对 uv **不生效**（uv 不读 pip 的环境变量与配置），
 * 因此不能把它当作来源上报 —— 记一个没用过的地址，比不记更糟。
 *
 * @param {string} projectRoot 项目根
 * @returns {{url: string, origin: string}} 索引地址与来源说明
 */
export function resolvePythonIndex(projectRoot) {
  const env = process.env.UV_DEFAULT_INDEX || process.env.UV_INDEX_URL;
  if (env && env.trim()) {
    return { url: env.trim(), origin: process.env.UV_DEFAULT_INDEX ? 'UV_DEFAULT_INDEX' : 'UV_INDEX_URL' };
  }
  let dir = path.resolve(projectRoot);
  for (let depth = 0; depth < 20; depth += 1) {
    const candidate = path.join(dir, 'uv.toml');
    if (fs.existsSync(candidate)) {
      const url = parseUvIndexFile(candidate);
      if (url) return { url, origin: `项目 uv.toml（${candidate}）` };
    }
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  const configPath = process.env.UV_CONFIG_FILE
    || path.join(process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config'), 'uv', 'uv.toml');
  const userUrl = parseUvIndexFile(configPath);
  if (userUrl) return { url: userUrl, origin: `用户 uv.toml（${configPath}）` };
  return { url: 'https://pypi.org/simple', origin: 'uv 内置默认索引（未设置 UV_DEFAULT_INDEX / UV_INDEX_URL）' };
}

/**
 * 解析 npm/bun **实际会使用**的 registry。
 * @param {string} projectRoot 项目根
 * @returns {{url: string, origin: string}} registry 与来源说明
 */
export function resolveNodeRegistry(projectRoot) {
  const env = process.env.npm_config_registry || process.env.NPM_CONFIG_REGISTRY;
  if (env && env.trim()) {
    return { url: env.trim(), origin: process.env.npm_config_registry ? 'npm_config_registry' : 'NPM_CONFIG_REGISTRY' };
  }
  const project = parseNpmrcRegistry(path.join(projectRoot, '.npmrc'));
  if (project) return { url: project, origin: '项目 .npmrc' };
  const user = parseNpmrcRegistry(path.join(os.homedir(), '.npmrc'));
  if (user) return { url: user, origin: '用户 .npmrc' };
  return { url: 'https://registry.npmjs.org/', origin: 'npm 内置默认 registry（未设置 npm_config_registry）' };
}

/**
 * 解析工具的**实际来源**（用于 state.json 与安装日志）。
 *
 * 上报的是包管理器真正会请求的地址，不是"环境里看起来像索引"的变量。
 *
 * @param {object} tool 清单条目
 * @param {string} projectRoot 项目根
 * @returns {string} 来源描述
 */
function resolveSource(tool, projectRoot) {
  if (tool.kind === 'python') {
    const index = resolvePythonIndex(projectRoot);
    return `${index.url}（${index.origin}）`;
  }
  if (tool.kind === 'node') {
    const registry = resolveNodeRegistry(projectRoot);
    return `${registry.url}（${registry.origin}）`;
  }
  return String(tool.install?.url ?? '');
}

/**
 * 确保 Python 虚拟环境存在。
 * @param {string} root 工具链根绝对路径
 * @returns {{ok: boolean, reason: string|null, python: string|null}} 结果
 */
function ensurePythonVenv(root) {
  const venvDir = path.join(root, '.venv');
  const python = path.join(venvDir, 'bin', 'python');
  if (fs.existsSync(python)) return { ok: true, reason: null, python };

  fs.mkdirSync(root, { recursive: true });
  const env = {
    ...process.env,
    UV_PROJECT_ENVIRONMENT: venvDir,
    UV_CACHE_DIR: path.join(root, 'cache', 'uv'),
    VIRTUAL_ENV: venvDir,
  };
  if (findOnPath('uv', env.PATH)) {
    const res = runProcess('uv', ['venv', venvDir], { cwd: root, env, timeout: 180000 });
    if (res.status === 0 && fs.existsSync(python)) return { ok: true, reason: null, python };
    const detail = (res.stderr || res.error || '').trim().split('\n').slice(-3).join('; ');
    return { ok: false, reason: `uv venv 失败：${detail || `退出码 ${res.status}`}`, python: null };
  }
  const systemPython = findOnPath('python3', env.PATH) || findOnPath('python', env.PATH);
  if (systemPython) {
    const res = runProcess(systemPython, ['-m', 'venv', venvDir], { cwd: root, env, timeout: 300000 });
    if (res.status === 0 && fs.existsSync(python)) return { ok: true, reason: null, python };
    const detail = (res.stderr || res.error || '').trim().split('\n').slice(-3).join('; ');
    return { ok: false, reason: `python -m venv 失败：${detail || `退出码 ${res.status}`}`, python: null };
  }
  return { ok: false, reason: '当前环境缺少 uv 与 python3，无法创建隔离虚拟环境', python: null };
}

/**
 * 确保 Node 包目录存在。
 * @param {string} root 工具链根绝对路径
 * @returns {string} node 目录
 */
function ensureNodeDir(root) {
  const nodeDir = path.join(root, 'node');
  fs.mkdirSync(nodeDir, { recursive: true });
  const pkgPath = path.join(nodeDir, 'package.json');
  if (!fs.existsSync(pkgPath)) {
    fs.writeFileSync(
      pkgPath,
      `${JSON.stringify({ name: 'qa-tools-node', private: true, version: '0.0.0' }, null, 2)}\n`,
      'utf8',
    );
  }
  return nodeDir;
}

/**
 * 下载单二进制工具。
 * @param {object} tool 清单条目
 * @param {string} root 工具链根绝对路径
 * @returns {Promise<{ok: boolean, reason: string|null, detail: object}>} 结果
 */
async function installBinary(tool, root) {
  const url = String(tool.install?.url ?? '');
  const binDir = path.join(root, 'bin');
  fs.mkdirSync(binDir, { recursive: true });
  const target = path.join(binDir, tool.entry || tool.name);

  let response;
  try {
    response = await fetch(url, { redirect: 'follow', signal: AbortSignal.timeout(60000) });
  } catch (err) {
    return {
      ok: false,
      reason: `下载源不可达（${url}）：${err && err.message ? err.message : String(err)}`,
      detail: { kind: 'unavailable' },
    };
  }
  if (!response.ok) {
    // 404/410 = 地址或版本不存在（failed）；其余状态码 = 来源当前不可用（unavailable）
    const kind = response.status === 404 || response.status === 410 ? 'failed' : 'unavailable';
    return {
      ok: false,
      reason: `下载源返回 HTTP ${response.status}（${url}）`,
      detail: { kind, httpStatus: response.status },
    };
  }
  const buffer = Buffer.from(await response.arrayBuffer());
  const expected = tool.install?.sha256;
  if (expected) {
    const actual = crypto.createHash('sha256').update(buffer).digest('hex');
    if (actual !== expected) {
      return {
        ok: false,
        reason: `校验和不匹配：期望 ${expected}，实际 ${actual}`,
        detail: { kind: 'failed' },
      };
    }
  }
  fs.writeFileSync(target, buffer);
  fs.chmodSync(target, 0o755);
  return { ok: true, reason: null, detail: { bytes: buffer.length } };
}

/**
 * 执行一次安装。
 * @param {object} ctx 上下文
 * @param {object} tool 清单条目
 * @returns {Promise<{status: string, reason: string|null, detail: object}>} 安装结果
 */
async function performInstall(ctx, tool) {
  const root = toolsRoot(ctx.projectRoot);
  const runtimeKey = KIND_RUNTIME[tool.kind];

  if (tool.kind === 'python') {
    const venv = ensurePythonVenv(root);
    if (!venv.ok) return { status: STATUS_UNAVAILABLE, reason: venv.reason, detail: {} };

    const tokens = renderInstallTemplate(tool, root);
    if (!tokens.length) return { status: STATUS_FAILED, reason: 'install 命令为空', detail: {} };

    // 把解析出的索引显式交给 uv：state.json 上报的来源 == uv 实际请求的来源
    const index = resolvePythonIndex(ctx.projectRoot);
    const env = {
      ...process.env,
      VIRTUAL_ENV: path.join(root, '.venv'),
      UV_PROJECT_ENVIRONMENT: path.join(root, '.venv'),
      UV_CACHE_DIR: path.join(root, 'cache', 'uv'),
      UV_DEFAULT_INDEX: index.url,
      PATH: [path.join(root, '.venv', 'bin'), process.env.PATH || ''].filter(Boolean).join(path.delimiter),
    };

    let command = runtimeKey;
    let args = tokens;
    if (!findOnPath(runtimeKey, env.PATH)) {
      // 回退：uv 缺失时用 venv 自带的 pip；bun 缺失时用 npm
      if (tool.kind === 'python') {
        const pip = path.join(root, '.venv', 'bin', 'pip');
        if (!fs.existsSync(pip)) {
          return { status: STATUS_UNAVAILABLE, reason: '当前环境缺少 uv（kind: python 需要 uv 或 pip）', detail: {} };
        }
        command = pip;
        args = tokens[0] === 'pip' ? tokens.slice(1) : tokens;
      } else {
        const npm = findOnPath('npm', env.PATH);
        if (!npm) {
          return { status: STATUS_UNAVAILABLE, reason: '当前环境缺少 bun 与 npm（kind: node 需要 bun 或 npm）', detail: {} };
        }
        command = npm;
        args = tokens.map((token) => (token === 'bun' ? 'npm' : token === 'add' ? 'install' : token));
      }
    } else if (tokens[0] === runtimeKey) {
      args = tokens.slice(1);
    }

    const res = runProcess(command, args, { cwd: root, env, timeout: 600000 });
    if (res.status !== 0) {
      const detail = (res.stderr || res.stdout || res.error || '').trim().split('\n').slice(-5).join('\n');
      return {
        status: looksUnavailable(res) ? STATUS_UNAVAILABLE : STATUS_FAILED,
        reason: `安装命令失败（退出码 ${res.status}）：${detail || '无输出'}`,
        detail: { command: `${command} ${args.join(' ')}`, durationMs: res.durationMs },
      };
    }
    return {
      status: STATUS_OK,
      reason: null,
      detail: {
        command: `${command} ${args.join(' ')}`,
        durationMs: res.durationMs,
        source: resolveSource(tool, ctx.projectRoot),
      },
    };
  }

  if (tool.kind === 'node') {
    const nodeDir = ensureNodeDir(root);
    const tokens = renderInstallTemplate(tool, root);
    if (!tokens.length) return { status: STATUS_FAILED, reason: 'install 命令为空', detail: {} };

    // 同理：把解析出的 registry 显式交给 bun/npm，上报来源 == 实际请求来源
    const registry = resolveNodeRegistry(ctx.projectRoot);
    const env = {
      ...process.env,
      BUN_INSTALL_CACHE_DIR: path.join(root, 'cache', 'bun'),
      npm_config_cache: path.join(root, 'cache', 'npm'),
      npm_config_registry: registry.url,
    };

    let command = runtimeKey;
    let args = tokens;
    if (!findOnPath(runtimeKey, env.PATH)) {
      const npm = findOnPath('npm', env.PATH);
      if (!npm) {
        return { status: STATUS_UNAVAILABLE, reason: '当前环境缺少 bun 与 npm（kind: node 需要 bun 或 npm）', detail: {} };
      }
      command = npm;
      args = tokens.map((token) => (token === 'bun' ? 'npm' : token === 'add' ? 'install' : token));
    } else if (tokens[0] === runtimeKey) {
      args = tokens.slice(1);
    }

    const res = runProcess(command, args, { cwd: nodeDir, env, timeout: 600000 });
    if (res.status !== 0) {
      const detail = (res.stderr || res.stdout || res.error || '').trim().split('\n').slice(-5).join('\n');
      return {
        status: looksUnavailable(res) ? STATUS_UNAVAILABLE : STATUS_FAILED,
        reason: `安装命令失败（退出码 ${res.status}）：${detail || '无输出'}`,
        detail: { command: `${command} ${args.join(' ')}`, durationMs: res.durationMs },
      };
    }
    return {
      status: STATUS_OK,
      reason: null,
      detail: {
        command: `${command} ${args.join(' ')}`,
        durationMs: res.durationMs,
        source: resolveSource(tool, ctx.projectRoot),
      },
    };
  }

  // binary
  const res = await installBinary(tool, root);
  if (!res.ok) {
    return { status: res.detail.kind === 'unavailable' ? STATUS_UNAVAILABLE : STATUS_FAILED, reason: res.reason, detail: res.detail };
  }
  return {
    status: STATUS_OK,
    reason: null,
    detail: { command: `download ${tool.install.url}`, durationMs: 0, source: resolveSource(tool, ctx.projectRoot), bytes: res.detail.bytes },
  };
}

/**
 * 运行 verify 命令，判断工具是否真的可用。
 * @param {string} projectRoot 项目根
 * @param {object} tool 清单条目
 * @returns {{ok: boolean, output: string, reason: string|null}} 验证结果
 */
export function runVerify(projectRoot, tool) {
  const root = toolsRoot(projectRoot);
  const argv = tokenize(tool.verify.command);
  if (!argv.length) return { ok: false, output: '', reason: 'verify.command 为空' };
  const res = runProcess(argv[0], argv.slice(1), {
    cwd: projectRoot,
    env: isolatedEnv(root, tool),
    timeout: 120000,
  });
  const output = `${res.stdout || ''}${res.stderr || ''}`.trim();
  if (res.error) return { ok: false, output, reason: `verify 执行异常：${res.error}` };
  if (res.status !== 0) {
    return { ok: false, output, reason: `verify 命令退出码 ${res.status}` };
  }
  if (!output.includes(tool.verify.match)) {
    return { ok: false, output, reason: `verify 输出未包含期望串 "${tool.verify.match}"` };
  }
  return { ok: true, output, reason: null };
}

/**
 * 计算工具当前状态。
 * @param {string} projectRoot 项目根
 * @param {object} tool 清单条目
 * @param {object} state 安装状态
 * @param {boolean} verify 是否现场跑 verify
 * @returns {{status: string, reason: string|null, executable: object|null, entry: object|null}} 状态
 */
function computeStatus(projectRoot, tool, state, verify) {
  const root = toolsRoot(projectRoot);
  const entry = state.tools[tool.name] || null;

  // 入口声明越界（entry / module 含路径语义）：这是**配置错误**，不是"没装"
  const violation = entryViolation(tool);
  if (violation) {
    return {
      status: STATUS_FAILED,
      reason: `入口路径越界：${violation}`,
      executable: null,
      entry,
    };
  }

  const executable = resolveExecutable(root, tool);

  if (!entry && !executable) {
    return { status: STATUS_MISSING, reason: '未安装', executable: null, entry: null };
  }
  if (entry && (entry.status === STATUS_FAILED || entry.status === STATUS_UNAVAILABLE) && !executable) {
    return { status: entry.status, reason: entry.reason || '安装失败', executable: null, entry };
  }
  if (!executable) {
    return {
      status: STATUS_FAILED,
      reason: entry ? '状态文件显示已安装，但可执行入口已不存在' : '可执行入口不存在',
      executable: null,
      entry,
    };
  }
  if (entry && entry.status === STATUS_UNAVAILABLE) {
    return { status: STATUS_UNAVAILABLE, reason: entry.reason || '当前环境不可用', executable, entry };
  }
  if (verify) {
    const result = runVerify(projectRoot, tool);
    if (!result.ok) {
      return { status: STATUS_FAILED, reason: result.reason, executable, entry };
    }
    return { status: STATUS_OK, reason: null, executable, entry };
  }
  if (entry && entry.status === STATUS_FAILED) {
    return { status: STATUS_FAILED, reason: entry.reason || '安装失败', executable, entry };
  }
  if (!entry) {
    return { status: STATUS_MISSING, reason: '未在 state.json 中登记', executable, entry: null };
  }
  return { status: STATUS_OK, reason: null, executable, entry };
}

// ---------------------------------------------------------------------------
// 子命令实现
// ---------------------------------------------------------------------------

/**
 * `qa list`：列出清单里的工具及其状态。
 * @param {object} ctx 上下文
 * @returns {number} 退出码
 */
function cmdList(ctx) {
  const { manifest, state } = ctx;
  const tools = manifest.tools || [];
  console.log(`工具清单：${manifestPath(ctx.projectRoot)}`);
  if (!tools.length) {
    console.log('（清单为空：没有声明任何工具）');
    return EXIT_OK;
  }
  const header = ['状态', '名称', '类型', '版本锁定', '可执行入口'];
  const rows = tools.map((tool) => {
    const status = computeStatus(ctx.projectRoot, tool, state, ctx.options.verify === true);
    const executable = status.executable
      ? `${status.executable.path}${status.executable.args.length ? ` ${status.executable.args.join(' ')}` : ''}`
      : '-';
    return [status.status, tool.name, tool.kind, tool.spec, executable];
  });
  const widths = header.map((cell, index) =>
    Math.max(displayWidth(cell), ...rows.map((row) => displayWidth(row[index]))),
  );
  console.log(header.map((cell, index) => padDisplay(cell, widths[index])).join('  ').trimEnd());
  for (const row of rows) {
    console.log(row.map((cell, index) => padDisplay(cell, widths[index])).join('  ').trimEnd());
  }
  return EXIT_OK;
}

/**
 * `qa doctor`：检查各工具是否可用，四种状态逐一给出结论。
 * @param {object} ctx 上下文
 * @returns {number} 退出码
 */
function cmdDoctor(ctx) {
  const { manifest, state } = ctx;
  const tools = manifest.tools || [];
  console.log(`工具链体检：${toolsRoot(ctx.projectRoot)}`);
  if (!tools.length) {
    console.log('[warn] 清单为空：没有任何工具可检查');
    return EXIT_FAIL;
  }
  let failed = 0;
  const envBlocked = [];
  for (const tool of tools) {
    const status = computeStatus(ctx.projectRoot, tool, state, true);
    const suffix = status.reason ? `  —— ${status.reason}` : '';
    console.log(`[${status.status}] ${tool.name}（${tool.kind}, ${tool.spec}）${suffix}`);
    if (status.status !== STATUS_OK) failed += 1;
    if (isEnvironmentBlocked(status)) envBlocked.push(tool);
  }
  // 环境级结论：索引/网络/运行时不可达时，先修环境，别改清单
  if (envBlocked.length) {
    const names = envBlocked.map((tool) => tool.name).join('、');
    console.log(`[env] ${envBlocked.length} 个工具因**环境不可达**未就绪（${names}）—— 这是环境级结论，不是清单问题`);
    console.log('       先修环境再重试：python 路线 export UV_DEFAULT_INDEX=<可达镜像>；node 路线 export npm_config_registry=<可达镜像>；');
    console.log('       缺运行时则安装 uv（python）或 bun（node）。修好前，对应能力必须标为"不可用/未覆盖"。');
  }
  console.log(
    failed === 0
      ? `[ok] 全部 ${tools.length} 个工具可用`
      : `[fail] ${tools.length} 个工具中 ${failed} 个不可用（能力域必须把对应能力标为"不可用/未覆盖"，不得报告为"未发现问题"）`,
  );
  return failed === 0 ? EXIT_OK : EXIT_FAIL;
}

/**
 * `qa install`：按清单安装工具（幂等）。
 * @param {object} ctx 上下文
 * @returns {Promise<number>} 退出码
 */
async function cmdInstall(ctx) {
  const { manifest, state } = ctx;
  const tools = manifest.tools || [];
  const wanted = ctx.args;
  const selected = [];
  if (wanted.length) {
    for (const name of wanted) {
      const tool = tools.find((item) => item.name === name);
      if (!tool) {
        console.error(`[error] 清单中没有工具 "${name}"（可用：${tools.map((t) => t.name).join(', ') || '无'}）`);
        return EXIT_USAGE;
      }
      selected.push(tool);
    }
  } else {
    selected.push(...tools);
  }

  const root = toolsRoot(ctx.projectRoot);
  let problems = 0;

  for (const tool of selected) {
    // F2 硬规则 2：版本必须锁定
    const spec = parseSpecVersion(tool);
    if (spec.error) {
      console.error(`[error] 工具 ${tool.name} 版本未锁定：${spec.error}`);
      console.error(`        请改成精确版本后再安装（例如 ${tool.name}==1.2.3 / ${tool.name}@1.2.3）`);
      recordFailure(state, tool, STATUS_FAILED, `版本未锁定：${spec.error}`, ctx.projectRoot);
      problems += 1;
      continue;
    }
    // F2 硬规则 1：安装命令不得越界
    const violation = checkInstallBoundary(tool, root);
    if (violation) {
      console.error(`[error] 工具 ${tool.name} 安装路径越界：${violation}`);
      console.error('        install 命令必须只写入 .tools/ 内部，否则会污染系统环境');
      recordFailure(state, tool, STATUS_FAILED, `安装路径越界：${violation}`, ctx.projectRoot);
      problems += 1;
      continue;
    }
    // F2 硬规则 4：install 只能跑包管理器
    const commandViolation = checkInstallCommand(tool);
    if (commandViolation) {
      console.error(`[error] 工具 ${tool.name} install 命令非法：${commandViolation}`);
      console.error(`        install 的第一个 token 必须是该 kind 的包管理器（${(KIND_PACKAGE_MANAGER[tool.kind] || []).join(' / ')}）`);
      recordFailure(state, tool, STATUS_FAILED, `install 命令非法：${commandViolation}`, ctx.projectRoot);
      problems += 1;
      continue;
    }

    const existing = state.tools[tool.name];
    if (existing && existing.spec === tool.spec && existing.status === STATUS_OK) {
      const executable = resolveExecutable(root, tool);
      if (executable) {
        const verified = runVerify(ctx.projectRoot, tool);
        if (verified.ok) {
          console.log(`[skip] ${tool.name} ${tool.spec} 已安装，跳过（幂等，不重复下载）`);
          continue;
        }
        console.log(`[warn] ${tool.name} 验证未通过（${verified.reason}），重新安装`);
      } else {
        console.log(`[warn] ${tool.name} 的可执行入口已丢失，重新安装`);
      }
    }

    console.log(`[install] ${tool.name} ${tool.spec}`);
    const result = await performInstall(ctx, tool);
    if (result.status !== STATUS_OK) {
      console.error(`[error] ${tool.name} 安装失败（状态：${result.status}）：${result.reason}`);
      if (result.status === STATUS_UNAVAILABLE || isEnvironmentBlocked({ status: result.status, reason: result.reason })) {
        console.error(`[env] 这是**环境级**结论（不是清单问题）：${environmentHint(tool)}`);
      }
      recordFailure(state, tool, result.status, result.reason, ctx.projectRoot);
      problems += 1;
      continue;
    }

    const source = result.detail.source || resolveSource(tool, ctx.projectRoot);
    console.log(`[install]   来源：${source}`);
    console.log(`[install]   命令：${result.detail.command}`);
    console.log(`[install]   耗时：${(result.detail.durationMs / 1000).toFixed(1)}s`);

    const executable = resolveExecutable(root, tool);
    if (!executable) {
      const reason = '安装完成但找不到可执行入口（检查工具的 entry / module 字段）';
      console.error(`[error] ${tool.name} ${reason}`);
      recordFailure(state, tool, STATUS_FAILED, reason, ctx.projectRoot);
      problems += 1;
      continue;
    }

    const verified = runVerify(ctx.projectRoot, tool);
    if (!verified.ok) {
      console.error(`[error] ${tool.name} 验证未通过：${verified.reason}`);
      recordFailure(state, tool, STATUS_FAILED, verified.reason, ctx.projectRoot);
      problems += 1;
      continue;
    }

    const size = fileSize(executable.path);
    console.log(`[install]   产物：${executable.path}（${humanSize(size)}）`);
    console.log(`[ok] ${tool.name} ${spec.version} 已安装并通过验证`);

    state.tools[tool.name] = {
      name: tool.name,
      kind: tool.kind,
      spec: tool.spec,
      version: spec.version,
      source: tool.kind === 'binary' ? resolveSource(tool, ctx.projectRoot) : KIND_RUNTIME[tool.kind],
      source_detail: {
        runtime: KIND_RUNTIME[tool.kind],
        command: result.detail.command,
        source,
        target: root,
      },
      executable: executable.path,
      checksum: sha256File(executable.path),
      size_bytes: size,
      installed_at: nowIso(),
      status: STATUS_OK,
      reason: null,
    };
  }

  writeState(ctx.projectRoot, state);
  if (problems > 0) {
    console.error(`[fail] ${problems} 个工具未能就绪（状态已记录到 ${statePath(ctx.projectRoot)}）`);
    return EXIT_FAIL;
  }
  console.log(`[ok] 安装流程结束`);
  return EXIT_OK;
}

/**
 * 记录一次失败到 state.json（失败必须显式留痕，不得静默跳过）。
 * @param {object} state 状态对象
 * @param {object} tool 清单条目
 * @param {string} status 失败状态
 * @param {string} reason 原因
 * @param {string} projectRoot 项目根（用于解析真实来源）
 */
function recordFailure(state, tool, status, reason, projectRoot) {
  const previous = state.tools[tool.name] || {};
  const source = previous.source
    || (tool.kind === 'binary' && projectRoot ? resolveSource(tool, projectRoot) : KIND_RUNTIME[tool.kind])
    || null;
  state.tools[tool.name] = {
    ...previous,
    name: tool.name,
    kind: tool.kind,
    spec: tool.spec,
    version: previous.version || null,
    source,
    executable: previous.executable || null,
    checksum: previous.checksum || null,
    installed_at: previous.installed_at || null,
    attempted_at: nowIso(),
    status,
    reason,
  };
}

/**
 * `qa run`：白名单式执行清单里的工具。
 * @param {object} ctx 上下文
 * @returns {number} 退出码
 */
function cmdRun(ctx) {
  const { manifest, state } = ctx;
  const name = ctx.args[0];
  if (!name) {
    console.error('[error] 用法：qa run <name> [-- <args...>]');
    return EXIT_USAGE;
  }
  const tool = (manifest.tools || []).find((item) => item.name === name);
  if (!tool) {
    console.error(`[error] 工具 "${name}" 不在清单中，qa run 只执行清单里声明的工具（白名单式，不接受任意命令）`);
    console.error(`        清单工具：${(manifest.tools || []).map((t) => t.name).join(', ') || '无'}`);
    return EXIT_USAGE;
  }

  const status = computeStatus(ctx.projectRoot, tool, state, true);
  if (status.status === STATUS_UNAVAILABLE) {
    console.error(`[error] 工具 ${name} 当前环境不可用：${status.reason}`);
    console.error('        调用方必须把该能力标为"不可用/未覆盖"，不得报告为"未发现问题"');
    return EXIT_FAIL;
  }
  if (status.status === STATUS_FAILED) {
    console.error(`[error] 工具 ${name} 安装失败或验证未通过：${status.reason}`);
    return EXIT_FAIL;
  }
  if (status.status === STATUS_MISSING || !status.executable) {
    console.error(`[error] 工具 ${name} 未安装（先执行 qa install ${name}）`);
    return EXIT_FAIL;
  }

  const root = toolsRoot(ctx.projectRoot);

  // 执行前最后一道闸：真正要跑的文件必须在 .tools/ 之内
  if (!isInsideTools(status.executable.path, root)) {
    console.error(`[error] 工具 ${name} 的可执行入口路径越界，拒绝执行：${status.executable.path}`);
    console.error('        契约只允许执行 .tools/ 内的隔离副本');
    return EXIT_FAIL;
  }

  const env = isolatedEnv(root, tool);
  const argv = [...status.executable.args, ...ctx.passthrough];
  console.log(`[run] ${name} -> ${status.executable.path} ${argv.join(' ')}`.trimEnd());
  const res = spawnSync(status.executable.path, argv, {
    cwd: ctx.projectRoot,
    env,
    stdio: 'inherit',
    windowsHide: true,
  });
  if (res.error) {
    console.error(`[error] 工具 ${name} 执行失败：${res.error.message}`);
    return EXIT_FAIL;
  }
  return res.status === null ? EXIT_FAIL : res.status;
}

/**
 * `qa which`：打印工具的可执行路径（确认走的是 `.tools/` 里那份）。
 * @param {object} ctx 上下文
 * @returns {number} 退出码
 */
function cmdWhich(ctx) {
  const { manifest, state } = ctx;
  const name = ctx.args[0];
  if (!name) {
    console.error('[error] 用法：qa which <name>');
    return EXIT_USAGE;
  }
  const tool = (manifest.tools || []).find((item) => item.name === name);
  if (!tool) {
    console.error(`[error] 工具 "${name}" 不在清单中`);
    return EXIT_USAGE;
  }
  const status = computeStatus(ctx.projectRoot, tool, state, false);
  if (!status.executable) {
    console.error(`[error] 工具 ${name} 未安装（状态：${status.status}${status.reason ? ` —— ${status.reason}` : ''}）`);
    return EXIT_FAIL;
  }
  // 越界入口绝不能被当成"隔离副本里的可执行文件"报出来
  if (!isInsideTools(status.executable.path, toolsRoot(ctx.projectRoot))) {
    console.error(`[error] 工具 ${name} 的可执行入口路径越界，拒绝报出：${status.executable.path}`);
    return EXIT_FAIL;
  }
  const suffix = status.executable.args.length ? ` ${status.executable.args.join(' ')}` : '';
  console.log(`${status.executable.path}${suffix}`);
  return EXIT_OK;
}

/**
 * `qa isolation`：负向验证隔离性（装完不得污染系统环境）。
 * @param {object} ctx 上下文
 * @returns {number} 退出码
 */
function cmdIsolation(ctx) {
  const { manifest, state } = ctx;
  const root = toolsRoot(ctx.projectRoot);
  const tools = manifest.tools || [];
  console.log(`隔离性检查：${root}`);
  if (!tools.length) {
    console.log('[warn] 清单为空：没有可检查的工具');
    return EXIT_FAIL;
  }
  let problems = 0;
  for (const tool of tools) {
    const status = computeStatus(ctx.projectRoot, tool, state, false);
    if (!status.executable) {
      console.log(`[skip] ${tool.name} 未安装，无可隔离性结论（状态：${status.status}）`);
      problems += 1;
      continue;
    }
    if (!isInsideTools(status.executable.path, root)) {
      console.log(`[fail] ${tool.name} 的可执行入口在 .tools/ 之外：${status.executable.path}`);
      problems += 1;
      continue;
    }
    if (tool.kind === 'python') {
      const moduleName = tool.module || tool.name.replace(/-/g, '_');
      const systemPython = findOnPath('python3', process.env.PATH) || findOnPath('python', process.env.PATH);
      if (!systemPython) {
        console.log(`[warn] ${tool.name} 系统无 python，无法做负向验证`);
        problems += 1;
        continue;
      }
      const res = runProcess(systemPython, ['-c', `import ${moduleName}`], {
        cwd: ctx.projectRoot,
        env: { ...process.env, PYTHONNOUSERSITE: '1' },
        timeout: 60000,
      });
      if (res.status === 0) {
        console.log(`[fail] ${tool.name} 系统 Python 可导入 ${moduleName}（环境已被污染）`);
        problems += 1;
      } else {
        console.log(`[ok] ${tool.name} 系统 Python 无法导入 ${moduleName}（未污染）`);
      }
    } else if (tool.kind === 'node') {
      const found = findOnPath(tool.entry || tool.name, process.env.PATH);
      if (found) {
        console.log(`[ok] ${tool.name} 系统存在同名工具 ${found}，但 qa run 的 PATH 以 .tools/ 优先，仍走隔离副本`);
      } else {
        console.log(`[ok] ${tool.name} 系统 PATH 中不可见（未污染）`);
      }
    } else {
      console.log(`[ok] ${tool.name} 二进制位于 .tools/ 内（未污染）`);
    }
  }
  if (problems > 0) {
    console.error(`[fail] ${problems} 个工具的隔离性未通过`);
    return EXIT_FAIL;
  }
  console.log('[ok] 隔离性检查全部通过');
  return EXIT_OK;
}

/**
 * `qa init`：生成项目级 `.tools/` 骨架与 `.gitignore` 规则。
 * @param {object} ctx 上下文
 * @returns {number} 退出码
 */
function cmdInit(ctx) {
  const root = toolsRoot(ctx.projectRoot);
  fs.mkdirSync(root, { recursive: true });

  const manifestFile = manifestPath(ctx.projectRoot);
  if (!fs.existsSync(manifestFile)) {
    fs.writeFileSync(
      manifestFile,
      `${JSON.stringify({ version: MANIFEST_VERSION, tools: [] }, null, 2)}\n`,
      'utf8',
    );
    console.log(`[ok] 已生成清单骨架：${manifestFile}`);
  } else {
    console.log(`[skip] 清单已存在，未覆盖：${manifestFile}`);
  }

  const gitignoreFile = path.join(ctx.projectRoot, '.gitignore');
  const existing = fs.existsSync(gitignoreFile) ? fs.readFileSync(gitignoreFile, 'utf8') : '';
  const missing = GITIGNORE_RULES.filter((rule) => !existing.split('\n').some((line) => line.trim() === rule));
  if (missing.length) {
    const block = `\n# 工具链：除清单外都是安装产物\n${missing.join('\n')}\n`;
    const prefix = existing.length && !existing.endsWith('\n') ? '\n' : '';
    fs.appendFileSync(gitignoreFile, `${prefix}${block}`, 'utf8');
    console.log(`[ok] 已写入 .gitignore 规则：${missing.join(' / ')}`);
  } else {
    console.log(`[skip] .gitignore 已含工具链规则，未重复写入：${gitignoreFile}`);
  }

  console.log('[info] 提示：`.tools/*` + `!.tools/manifest.json` 缺一不可；写成 `.tools/` 会让清单静默不进版本库');
  return EXIT_OK;
}

// ---------------------------------------------------------------------------
// 帮助与主入口
// ---------------------------------------------------------------------------

/**
 * 输出帮助文本。
 */
function printHelp() {
  console.log(`qa —— 测试套件工具链自举入口（REQ-003）

用法：
  qa [--project <dir>] <子命令> [参数...]

子命令：
  init                     在项目根生成 .tools/ 骨架（manifest.json + .gitignore 规则）
  list [--verify]          列出清单里的工具及其状态（ok / missing / failed / unavailable）
  doctor                   逐个跑 verify 做体检，不可用项明确列出
  install [name...]        安装清单里的工具（缺省装全部）；幂等，已装且版本匹配则跳过
  run <name> [-- <args>]   在 .tools/ 隔离环境里执行清单里的工具（白名单式）
  which <name>             打印工具的可执行路径（确认走的是 .tools/ 里那份）
  isolation                负向验证隔离性（系统侧不可见 / 未污染）

全局选项：
  --project <dir>          项目根（默认当前目录；也可用环境变量 QA_PROJECT_ROOT）
  -h, --help               显示本帮助
  -V, --version            显示版本

退出码：
  0  成功
  1  校验失败或工具不可用（含安装失败、verify 未通过）
  2  调用方式错误（未知子命令、缺参数、工具不在清单中）`);
}

/**
 * 读取本包版本。
 * @returns {string} 版本号
 */
function readVersion() {
  try {
    const here = path.dirname(fileURLToPath(import.meta.url));
    const meta = JSON.parse(fs.readFileSync(path.join(here, '..', 'package.json'), 'utf8'));
    return meta.version ?? '0.0.0';
  } catch {
    return '0.0.0';
  }
}

/**
 * 主入口。
 * @param {string[]} argv 参数数组
 * @returns {Promise<number>} 退出码
 */
export async function main(argv) {
  let parsed;
  try {
    parsed = parseArgv(argv);
  } catch (err) {
    console.error(`[error] ${err.message}`);
    return EXIT_USAGE;
  }

  if (parsed.version) {
    console.log(readVersion());
    return EXIT_OK;
  }
  if (parsed.help || !parsed.command) {
    printHelp();
    return parsed.command || parsed.help ? EXIT_OK : EXIT_USAGE;
  }

  const commands = ['init', 'list', 'doctor', 'install', 'run', 'which', 'isolation', 'help'];
  if (parsed.command === 'help') {
    printHelp();
    return EXIT_OK;
  }
  if (!commands.includes(parsed.command)) {
    console.error(`[error] 未知子命令 "${parsed.command}"（可用：${commands.join(', ')}）`);
    return EXIT_USAGE;
  }

  const projectRoot = resolveProjectRoot(parsed.project);
  const ctx = { projectRoot, args: parsed.args, passthrough: parsed.passthrough, options: { verify: parsed.verify } };

  // 调用方式检查前置：参数缺失属于"调用方式错误"，不必先读清单
  const requiredArgs = { run: 1, which: 1 };
  const need = requiredArgs[parsed.command] ?? 0;
  if (parsed.args.length < need) {
    const usage = parsed.command === 'run' ? 'qa run <name> [-- <args...>]' : `qa ${parsed.command} <name>`;
    console.error(`[error] 用法：${usage}`);
    return EXIT_USAGE;
  }

  // 除 init 外的子命令都需要清单
  if (parsed.command !== 'init') {
    let manifest;
    let state;
    try {
      manifest = readManifest(projectRoot);
      state = readState(projectRoot);
    } catch (err) {
      console.error(`[error] ${err.message}`);
      return EXIT_FAIL;
    }
    const errors = validateManifest(manifest, toolsRoot(projectRoot));
    if (errors.length) {
      for (const message of errors) console.error(`[error] 清单校验失败：${message}`);
      console.error(`        清单路径：${manifestPath(projectRoot)}`);
      return EXIT_FAIL;
    }
    ctx.manifest = manifest;
    ctx.state = state;
  }

  try {
    switch (parsed.command) {
      case 'init':
        return cmdInit(ctx);
      case 'list':
        return cmdList(ctx);
      case 'doctor':
        return cmdDoctor(ctx);
      case 'install':
        return await cmdInstall(ctx);
      case 'run':
        return cmdRun(ctx);
      case 'which':
        return cmdWhich(ctx);
      case 'isolation':
        return cmdIsolation(ctx);
      default:
        console.error(`[error] 未知子命令 "${parsed.command}"`);
        return EXIT_USAGE;
    }
  } catch (err) {
    console.error(`[error] ${err && err.message ? err.message : String(err)}`);
    return EXIT_FAIL;
  }
}
