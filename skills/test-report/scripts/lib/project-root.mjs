// project-root.mjs —— 项目根定位（REQ-014 demand.md §F1.2，D212）
//
// 三段式，**不猜**：
//   ① `--project-root <dir>` 显式指定；
//   ② 从 run_dir 形态 `<root>/.test-artifacts/<id>` 反推（root = run_dir 的上两级）；
//   ③ 两条都不成立 ⇒ 报错退出（rc=1），stderr 点名 `--project-root`。
//
// ⚠️ 不许默认拿 cwd 当项目根，也不许默认拿 run_dir 当项目根 ——
//    猜错的后果是「报告落在一个用户没预期的目录」：静默的错比报错更坏。

import fs from 'node:fs';
import path from 'node:path';

/** 产物区的目录名（形态 `<root>/.test-artifacts/<id>`）。 */
const ARTIFACTS_DIR = '.test-artifacts';

/**
 * 项目根定位失败（退出码 1）。
 */
export class ProjectRootError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ProjectRootError';
  }
}

/**
 * 判定一个目录是不是一个存在的目录。
 * @param {string} dir 目录
 * @returns {boolean} 是不是存在的目录
 */
function isDirectory(dir) {
  try {
    return fs.existsSync(dir) && fs.statSync(dir).isDirectory();
  } catch {
    return false;
  }
}

/**
 * 从 run_dir 的形态反推项目根。
 * @param {string} runDir 产物目录（绝对路径）
 * @returns {string|null} 项目根（形态不合法时返回 null）
 */
export function deriveProjectRoot(runDir) {
  const parent = path.dirname(runDir);
  if (path.basename(parent) !== ARTIFACTS_DIR) return null;
  return path.dirname(parent);
}

/**
 * 定位项目根。
 * @param {string} runDir 产物目录（绝对路径）
 * @param {string|null} explicit 显式指定的项目根（null = 没给）
 * @returns {{root: string, source: 'explicit'|'derived'}} 项目根与其来源
 * @throws {ProjectRootError} 显式指定的位置不存在、或两条路都不成立
 */
export function resolveProjectRoot(runDir, explicit) {
  if (typeof explicit === 'string' && explicit !== '') {
    const root = path.resolve(explicit);
    if (!isDirectory(root)) {
      throw new ProjectRootError(`项目根不存在或不是目录：${root}`);
    }
    return { root, source: 'explicit' };
  }
  const derived = deriveProjectRoot(runDir);
  if (derived === null || !isDirectory(derived)) {
    throw new ProjectRootError(
      `无法从产物目录推断项目根：${runDir} 不在 <项目根>/${ARTIFACTS_DIR}/<run_id> 形态下`
      + ' —— 请用 --project-root <项目根> 指定项目根',
    );
  }
  return { root: derived, source: 'derived' };
}

/**
 * 把一个绝对路径换成相对项目根的路径（分隔符统一成 `/`）。
 * @param {string} root 项目根
 * @param {string} target 目标绝对路径
 * @returns {string} 相对路径（相同则返回 `.`）
 */
export function relativeToRoot(root, target) {
  const rel = path.relative(root, target);
  if (rel === '') return '.';
  return rel.split(path.sep).join('/');
}
