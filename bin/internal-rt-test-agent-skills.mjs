#!/usr/bin/env node
/**
 * internal-rt-test-agent-skills —— 测试 Agent Skill 套件的安装器 CLI。
 *
 * 职责：把本 npm 包 `skills/` 下的各 skill 复制到用户级 skill 目录，
 * 并与该目录的 `.skill-lock.json` 协同（只增改本包自己的条目）。
 *
 * 设计约束（REQ-001 F5 / F6）：
 *  - 零第三方依赖，只使用 Node.js 内置模块；
 *  - 安装过程只做文件复制，绝不执行被安装 skill 中的任何脚本；
 *  - 不修改 shell 配置（.bashrc / .zshrc / .profile），不修改 PATH；
 *  - 不执行 git commit / git push（安装根目录本身可能是 git 仓库，提交由用户决定）；
 *  - 只触碰本包自己安装的 skill，用户已有的其他 skill 一律不动。
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));

/** 安装根目录下的 skill 子目录名。 */
const SKILLS_SUBDIR = 'skills';
/** 安装根目录下的锁文件名。 */
const LOCK_FILENAME = '.skill-lock.json';
/** 锁文件版本号（与既有 .skill-lock.json 保持一致）。 */
const LOCK_VERSION = 3;
/** 本包在 lock 文件中的 sourceType。 */
const SOURCE_TYPE = 'npm';
/** 本包名（用于在 node_modules 内反查包根目录）。 */
const PKG_NAME = 'internal-rt-test-agent-skills';

/**
 * 定位包根目录：优先取 bin/ 的上一级；若该目录不是本包（例如被软链/拷贝到别处），
 * 则向上最多 5 层查找 name 为本包的 package.json。
 * @returns {string} 包根目录绝对路径
 */
function resolvePkgRoot() {
  let dir = path.resolve(HERE, '..');
  for (let depth = 0; depth < 5; depth += 1) {
    const candidate = path.join(dir, 'package.json');
    if (fs.existsSync(candidate)) {
      try {
        const meta = JSON.parse(fs.readFileSync(candidate, 'utf8'));
        if (meta.name === PKG_NAME) return dir;
      } catch {
        // package.json 不可解析时继续向上找
      }
    }
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return path.resolve(HERE, '..');
}

const PKG_ROOT = resolvePkgRoot();
const SKILLS_SRC = path.join(PKG_ROOT, SKILLS_SUBDIR);

/**
 * 读取包自身的 package.json 元信息。
 * @returns {{name: string, version: string}} 包名与版本
 */
function readPkgMeta() {
  const metaPath = path.join(PKG_ROOT, 'package.json');
  const meta = JSON.parse(fs.readFileSync(metaPath, 'utf8'));
  return { name: meta.name ?? PKG_NAME, version: meta.version ?? '0.0.0' };
}

/**
 * 解析安装根目录。优先级：命令行 `--root` > 环境变量 `INTERNAL_RT_SKILLS_DIR` > `~/.agents`。
 *
 * 注意：`INTERNAL_RT_SKILLS_DIR` 覆盖的是**安装根目录**这一层（默认 `~/.agents`），
 * 而不是 `~/.agents/skills` 这一层。即 `INTERNAL_RT_SKILLS_DIR=/tmp/x` 时：
 *   skill 落在 `/tmp/x/skills/<name>/`，锁文件落在 `/tmp/x/.skill-lock.json`。
 *
 * @param {string|undefined} cliRoot 命令行传入的根目录
 * @returns {string} 安装根目录绝对路径
 */
function resolveRoot(cliRoot) {
  if (cliRoot) return path.resolve(cliRoot);
  const env = process.env.INTERNAL_RT_SKILLS_DIR;
  if (env && env.trim()) return path.resolve(env.trim());
  return path.join(os.homedir(), '.agents');
}

/**
 * 列出本包携带的 skill：只认含 SKILL.md 的子目录。
 * @returns {{name: string, dir: string, hasSkillMd: boolean}[]} skill 列表
 */
function discoverSkills() {
  if (!fs.existsSync(SKILLS_SRC)) return [];
  const found = [];
  for (const entry of fs.readdirSync(SKILLS_SRC, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const dir = path.join(SKILLS_SRC, entry.name);
    found.push({
      name: entry.name,
      dir,
      hasSkillMd: fs.existsSync(path.join(dir, 'SKILL.md')),
    });
  }
  return found.sort((a, b) => a.name.localeCompare(b.name));
}

/**
 * 读取锁文件；不存在时返回空骨架。
 * @param {string} lockPath 锁文件路径
 * @returns {object} 锁文件对象（保留未知的顶层字段）
 */
function readLock(lockPath) {
  if (!fs.existsSync(lockPath)) {
    return { version: LOCK_VERSION, skills: {}, dismissed: {} };
  }
  const raw = fs.readFileSync(lockPath, 'utf8');
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    throw new Error(`锁文件不是合法 JSON，已中止（未做任何修改）：${lockPath}（${err.message}）`);
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error(`锁文件结构非法，已中止（未做任何修改）：${lockPath}`);
  }
  const lock = { ...parsed };
  if (typeof lock.version !== 'number') lock.version = LOCK_VERSION;
  if (!lock.skills || typeof lock.skills !== 'object' || Array.isArray(lock.skills)) {
    lock.skills = {};
  }
  if (!lock.dismissed || typeof lock.dismissed !== 'object' || Array.isArray(lock.dismissed)) {
    lock.dismissed = {};
  }
  return lock;
}

/**
 * 写回锁文件（2 空格缩进 + 结尾换行，与既有格式一致）。
 * @param {string} lockPath 锁文件路径
 * @param {object} lock 锁文件对象
 */
function writeLock(lockPath, lock) {
  fs.mkdirSync(path.dirname(lockPath), { recursive: true });
  fs.writeFileSync(lockPath, `${JSON.stringify(lock, null, 2)}\n`, 'utf8');
}

/**
 * 列出本包**实际可安装**的 skill 名（含 SKILL.md 的子目录）。
 * 缺 SKILL.md 的目录不算数，避免把别人的同名目录误认成自己的。
 * @returns {string[]} skill 名列表
 */
function shippedSkillNames() {
  return discoverSkills()
    .filter((s) => s.hasSkillMd)
    .map((s) => s.name);
}

/**
 * 判断某个锁条目是否由本包安装。
 * @param {object|undefined} entry 锁条目
 * @param {{name: string, version: string}} meta 包元信息
 * @returns {boolean} 是否为本包安装
 */
function isOwnedEntry(entry, meta) {
  if (!entry || typeof entry !== 'object') return false;
  if (entry.sourceType !== SOURCE_TYPE) return false;
  const source = typeof entry.source === 'string' ? entry.source : '';
  return source === meta.name || source.startsWith(`${meta.name}@`);
}

/**
 * 递归同步目录：把 src 的内容镜像到 dst。
 *  - 已存在的文件就地覆盖（保留目录本身，避免在 git 仓库里产生 delete+add 噪声）；
 *  - src 中已不存在的条目从 dst 中删除，保证安装结果与包内容一致；
 *  - 不跟随 dst 中的符号链接（避免写到用户其它位置）。
 * @param {string} src 源目录
 * @param {string} dst 目标目录
 */
function syncDir(src, dst) {
  fs.mkdirSync(dst, { recursive: true });
  const srcNames = new Set(fs.readdirSync(src));
  for (const name of fs.readdirSync(dst)) {
    if (srcNames.has(name)) continue;
    fs.rmSync(path.join(dst, name), { recursive: true, force: true });
  }
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const s = path.join(src, entry.name);
    const d = path.join(dst, entry.name);
    if (entry.isDirectory()) {
      let isLink = false;
      try {
        isLink = fs.lstatSync(d).isSymbolicLink();
      } catch {
        isLink = false;
      }
      if (isLink) fs.rmSync(d, { recursive: true, force: true });
      syncDir(s, d);
    } else if (entry.isSymbolicLink()) {
      const target = fs.readlinkSync(s);
      fs.rmSync(d, { recursive: true, force: true });
      fs.symlinkSync(target, d);
    } else {
      fs.copyFileSync(s, d);
      fs.chmodSync(d, fs.statSync(s).mode & 0o777);
    }
  }
}

/**
 * 安装单个 skill：同步目录内容（不执行其中任何文件）。
 * @param {string} root 安装根目录
 * @param {string} src 源目录
 * @param {string} dest 目标目录
 */
function installSkillDir(root, src, dest) {
  fs.mkdirSync(path.join(root, SKILLS_SUBDIR), { recursive: true });
  syncDir(src, dest);
}

/**
 * 生成/更新本包的锁条目。
 * @param {object} existing 已有条目（可能是别的来源）
 * @param {{name: string, version: string}} meta 包元信息
 * @param {string} nowIso 当前时间（ISO-8601）
 * @returns {object} 新条目
 */
function buildEntry(existing, meta, nowIso) {
  const keepInstalledAt =
    existing && isOwnedEntry(existing, meta) && typeof existing.installedAt === 'string'
      ? existing.installedAt
      : nowIso;
  return {
    source: `${meta.name}@${meta.version}`,
    sourceType: SOURCE_TYPE,
    sourceUrl: `https://registry.npmjs.org/${meta.name}/-/${meta.name}-${meta.version}.tgz`,
    skillPath: 'SKILL.md',
    skillFolderHash: '',
    installedAt: keepInstalledAt,
    updatedAt: nowIso,
  };
}

/**
 * 执行 install。
 * @param {string} root 安装根目录
 */
function cmdInstall(root) {
  const meta = readPkgMeta();
  const skills = discoverSkills();
  const shippable = skills.filter((s) => s.hasSkillMd);
  for (const skipped of skills.filter((s) => !s.hasSkillMd)) {
    console.warn(`[warn] 跳过 ${skipped.name}：目录内缺少 SKILL.md`);
  }
  if (shippable.length === 0) {
    console.error(`[error] 本包未携带任何可用 skill（${SKILLS_SRC} 下没有含 SKILL.md 的目录）`);
    process.exitCode = 1;
    return;
  }

  const skillsDir = path.join(root, SKILLS_SUBDIR);
  const lockPath = path.join(root, LOCK_FILENAME);
  const lock = readLock(lockPath);
  const nowIso = new Date().toISOString();

  for (const skill of shippable) {
    const dest = path.join(skillsDir, skill.name);
    installSkillDir(root, skill.dir, dest);
    lock.skills[skill.name] = buildEntry(lock.skills[skill.name], meta, nowIso);
    console.log(`[ok] 已安装 skill: ${skill.name} -> ${dest}`);
  }

  writeLock(lockPath, lock);
  console.log(`[ok] 锁文件已更新: ${lockPath}`);
  console.log(`[info] 安装根目录: ${root}`);
}

/**
 * 执行 uninstall：只移除本包安装的 skill 目录与锁条目。
 * @param {string} root 安装根目录
 */
function cmdUninstall(root) {
  const meta = readPkgMeta();
  const skillsDir = path.join(root, SKILLS_SUBDIR);
  const lockPath = path.join(root, LOCK_FILENAME);
  const lockExisted = fs.existsSync(lockPath);
  const lock = readLock(lockPath);

  // 本包管理的 skill = 本包携带的 skill ∪ 锁文件中属于本包的条目
  const ownedNames = new Set(shippedSkillNames());
  for (const [name, entry] of Object.entries(lock.skills)) {
    if (isOwnedEntry(entry, meta)) ownedNames.add(name);
  }

  let removed = 0;
  let lockChanged = false;
  for (const name of [...ownedNames].sort()) {
    const entry = lock.skills[name];
    // 锁条目存在但不属于本包（例如用户从其它来源装的同名 skill）→ 不动它
    if (entry && !isOwnedEntry(entry, meta)) {
      console.log(`[skip] ${name}：锁条目不属于本包，保留`);
      continue;
    }
    const dir = path.join(skillsDir, name);
    if (fs.existsSync(dir)) {
      fs.rmSync(dir, { recursive: true, force: true });
      console.log(`[ok] 已移除 skill 目录: ${dir}`);
    }
    if (entry) {
      delete lock.skills[name];
      lockChanged = true;
      console.log(`[ok] 已移除锁条目: ${name}`);
    }
    removed += 1;
  }

  if (removed === 0) {
    console.log('[info] 本包没有已安装的 skill，无需卸载');
  }
  // 锁文件本来不存在且本次什么都没改动时，不凭空创建空锁文件
  if (lockExisted || lockChanged) {
    writeLock(lockPath, lock);
    console.log(`[ok] 锁文件已更新: ${lockPath}`);
  }
  console.log(`[info] 安装根目录: ${root}`);
}

/**
 * 执行 list：列出本包管理的 skill 及安装状态。
 * @param {string} root 安装根目录
 */
function cmdList(root) {
  const meta = readPkgMeta();
  const skillsDir = path.join(root, SKILLS_SUBDIR);
  const lockPath = path.join(root, LOCK_FILENAME);
  const lock = readLock(lockPath);

  const ownedNames = new Set(shippedSkillNames());
  for (const [name, entry] of Object.entries(lock.skills)) {
    if (isOwnedEntry(entry, meta)) ownedNames.add(name);
  }

  console.log(`包: ${meta.name}@${meta.version}`);
  console.log(`安装根目录: ${root}`);
  console.log(`锁文件: ${lockPath}`);
  console.log('');

  if (ownedNames.size === 0) {
    console.log('本包当前没有管理任何 skill。');
  } else {
    console.log('SKILL'.padEnd(28) + 'STATUS'.padEnd(20) + 'PATH');
    for (const name of [...ownedNames].sort()) {
      const entry = lock.skills[name];
      const dir = path.join(skillsDir, name);
      const dirExists = fs.existsSync(dir);
      let status;
      if (dirExists && isOwnedEntry(entry, meta)) status = 'installed';
      else if (dirExists) status = 'installed(no-lock)';
      else if (isOwnedEntry(entry, meta)) status = 'lock-only';
      else status = 'not-installed';
      console.log(`${name.padEnd(28)}${status.padEnd(20)}${dir}`);
    }
  }

  const others = Object.keys(lock.skills).filter((n) => !ownedNames.has(n));
  console.log('');
  console.log(`其它 skill（不在本包管理范围内，未改动）: ${others.length}`);
  for (const name of others.sort()) console.log(`  - ${name}`);
}

/**
 * 打印帮助信息。
 */
function printHelp() {
  console.log(`internal-rt-test-agent-skills —— 测试 Agent Skill 套件安装器

用法:
  internal-rt-test-agent-skills <command> [options]

命令:
  install     把本包 skills/ 下的各 skill 安装到 <安装根>/skills/<name>/（幂等）
  uninstall   移除本包安装的 skill 目录与锁条目（不碰其它 skill）
  list        列出本包管理的 skill 及其安装状态

选项:
  --root <dir>  指定安装根目录（默认 ~/.agents）；优先级高于 INTERNAL_RT_SKILLS_DIR
  -h, --help    显示本帮助
  -v, --version 显示版本号

安装根目录解析顺序:
  1. 命令行 --root
  2. 环境变量 INTERNAL_RT_SKILLS_DIR（覆盖的是 ~/.agents 这一层，不是 ~/.agents/skills）
  3. 默认 ~/.agents

示例:
  internal-rt-test-agent-skills install
  INTERNAL_RT_SKILLS_DIR=/tmp/sandbox internal-rt-test-agent-skills install
  INTERNAL_RT_SKILLS_DIR=/tmp/sandbox internal-rt-test-agent-skills list`);
}

/**
 * 解析命令行参数。
 * @param {string[]} argv 参数数组（不含 node 与脚本路径）
 * @returns {{command: string, root: string|undefined, help: boolean, version: boolean}} 解析结果
 */
function parseArgs(argv) {
  const result = { command: '', root: undefined, help: false, version: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '-h' || arg === '--help') {
      result.help = true;
    } else if (arg === '-v' || arg === '--version') {
      result.version = true;
    } else if (arg === '--root') {
      const value = argv[i + 1];
      if (!value || value.startsWith('-')) {
        throw new Error('--root 需要一个目录参数');
      }
      result.root = value;
      i += 1;
    } else if (arg.startsWith('--root=')) {
      const value = arg.slice('--root='.length);
      if (!value) throw new Error('--root 需要一个目录参数');
      result.root = value;
    } else if (!arg.startsWith('-') && !result.command) {
      result.command = arg;
    }
  }
  return result;
}

/**
 * 入口。
 */
function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (err) {
    console.error(`[error] ${err.message}`);
    process.exitCode = 1;
    return;
  }
  if (args.help) {
    printHelp();
    return;
  }
  if (args.version) {
    const meta = readPkgMeta();
    console.log(`${meta.name}@${meta.version}`);
    return;
  }
  if (!args.command) {
    printHelp();
    process.exitCode = 1;
    return;
  }
  const root = resolveRoot(args.root);
  if (args.command === 'install') {
    cmdInstall(root);
  } else if (args.command === 'uninstall') {
    cmdUninstall(root);
  } else if (args.command === 'list') {
    cmdList(root);
  } else {
    console.error(`[error] 未知命令: ${args.command}`);
    printHelp();
    process.exitCode = 1;
  }
}

try {
  main();
} catch (err) {
  console.error(`[error] ${err && err.message ? err.message : String(err)}`);
  process.exitCode = 1;
}
