#!/usr/bin/env bash
# REQ-010 验收脚本 —— `test-report` skill（执行报告 + 回归对账）
#
# 判据集：AC-001~AC-029（条数从 acceptance.md 的 `### AC-` 实际条数动态取，不写死）
#
# 用法: verify-acceptance.sh <package-dir>
#   <package-dir> 指向**被验包根目录**（含 skills/ 与 bin/，以及 feature-meta/、README.md）
#
# 退出码: 0 = 全部通过; 1 = 有 AC 未通过 / 不可判定 / 变异体有逃逸; 2 = 用法错误
#
# 环境变量:
#   REQ010_NO_MUT=1   跳过变异体套件（快跑 / 嵌套运行用）
#   QA010_SCRIPT_SHA  期望的**本脚本自身** sha256；不匹配即判红并中止
#
# 设计要点（门是被验对象，不是脚手架 —— D65）:
#   - 只读被验包；一切变异都在**副本**上做，绝不在原地改被验对象。
#   - 夹具（执行产物 / 回归计划）一律造在临时目录里；**两个指纹由本脚本自己算**，
#     内嵌一份**独立**的指纹算法实现（照 REQ-004 的 evidence-chain.md §4），
#     **绝不 import 被验包里的 fingerprint.mjs**（被验实现坏了会把门一起带偏）。
#   - 判据正文与本脚本的理解有出入时，以 acceptance.md 的判据正文为准；
#     分歧写进本脚本注释，并在 /tmp/req010-verify/OPEN-ISSUES.md 留档待裁定。
#   - 变异体套件的注入方式：**入口脚本包装（shim）** —— 把副本里的
#     `skills/test-report/scripts/make-report.mjs` 换成一层包装，包装调用原实现
#     （原文件 move 到 make-report.real.mjs）后再对**产物**做一处语义篡改。
#     为什么不用「源码字面量锚点」：本门在 Dev 实现之前就写好（先自测门、再派 Dev），
#     实现源码的字面量此刻不存在，无法预置锚点；包装式注入对任意实现都成立。
#     「锚点逐字唯一命中 1 次」的机械等价物 = **产物里的锚点路径恰好出现 1 次**
#     （如 cases.blocked），命中 0 次或 >1 次即判「无效变异」。
#   - 变异检出走**新增失败键**（变异运行的失败键 减去 基线失败键，整行精确排除）；
#     **不用**对称差：对称差把「基线红、变异后绿」也算成变化，那是噪声不是检出。
#     崩溃造成的判红是假检出，不计入检出率（结构合法性单独自证：node --check 通过 + 脚本能正常跑完）。
#   - 变异体套件里有一个**负控 M0**（打不到任何判据的无害篡改）：它必须**未检出**。
#     若 M0 也被报成「已检出」⇒ 探测器恒真 ⇒ 本门失效（门侧缺陷，判红）。
#   - 有效变异体不足 4 个 ⇒ **不可判定**（门侧注入问题），退出码非 0，但不算被验实现的失败。

set -uo pipefail

# ---------------------------------------------------------------- 用法

if [ $# -lt 1 ]; then
  echo "用法: verify-acceptance.sh <package-dir>" >&2
  exit 2
fi
PKG_RAW="$1"
if [ ! -d "$PKG_RAW" ]; then
  echo "被验包目录不存在: $PKG_RAW" >&2
  exit 2
fi
PKG="$(cd "$PKG_RAW" 2>/dev/null && pwd)" || { echo "被验包目录不可读: $PKG_RAW" >&2; exit 2; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/$(basename "${BASH_SOURCE[0]}")"
DEMAND_ROOT="$(cd "$SELF_DIR/../../../.." 2>/dev/null && pwd || echo "$SELF_DIR")"
DEMAND_DIR="$SELF_DIR"
ACCEPTANCE="$DEMAND_DIR/acceptance.md"
DECISIONS="$DEMAND_DIR/decisions.md"

# ---------------------------------------------------------------- 判据条数（动态取）

AC_COUNT=0
if [ -f "$ACCEPTANCE" ]; then
  AC_COUNT="$(grep -cE '^### AC-' "$ACCEPTANCE" 2>/dev/null || true)"
  case "$AC_COUNT" in ''|*[!0-9]*) AC_COUNT=0 ;; esac
fi
if [ "$AC_COUNT" -eq 0 ]; then
  echo "无法从 $ACCEPTANCE 读到判据条数（`### AC-` 实际条数）—— 不可判定，不判通过" >&2
  exit 1
fi

# ---------------------------------------------------------------- 门禁前置：脚本自身指纹

if [ -n "${QA010_SCRIPT_SHA:-}" ]; then
  SELF_SHA="$(sha256sum "$SELF" 2>/dev/null | cut -d' ' -f1)"
  if [ "$SELF_SHA" != "$QA010_SCRIPT_SHA" ]; then
    echo "FAIL  门禁前置：验收脚本自身 sha256 不符（实际 $SELF_SHA，期望 $QA010_SCRIPT_SHA）" >&2
    echo "结论: 0 PASS / 1 FAIL" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------- 工作目录

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qa-010-XXXXXX")"
cleanup() {
  # ⚠️ 本机 rm 是 shim（可恢复删除）：清理失败**不得**改变判定，也不断言回收站为空。
  if [ "${QA010_KEEP_WORK:-0}" = "1" ]; then
    printf '[debug] 工作目录已保留: %s\n' "$WORK"
    return 0
  fi
  rm -rf "$WORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT

RES_DIR="$WORK/res"
mkdir -p "$RES_DIR"

TR="$PKG/skills/test-report"
BINDIR="$PKG/bin"
TCD="$PKG/skills/test-case-design"
FEATURE_META="$PKG/feature-meta"
README="$PKG/README.md"
INSTALLER="$BINDIR/test-agent-skills.mjs"

PASS=0
FAIL=0
UNDEC=0
MUT_TOTAL=0
MUT_DETECTED=0
MUT_ESCAPED=""
MUT_INVALID=""
MUT_NOTE=""
MUT_UNDEC=0
MUT_CONTROL_OK=0
MUT_MISSING_IMPL=0
MUT_CONTROL_FAILED=""

ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1" > "$RES_DIR/$2.res"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1" > "$RES_DIR/$2.res"; }
# 不可判定 —— 既不判红也不判绿（不可判定 ≠ 通过）
undec(){ UNDEC=$((UNDEC+1)); printf 'UNDEC %s\n' "$1" > "$RES_DIR/$2.res"; }
step(){ printf '\n— %s\n' "$1"; }

# 抽出「失败的 AC 键集合」—— 变异体判定完全建立在它上面
failkeys() {
  printf '%s\n' "$1" | sed 's/\x1b\[[0-9;]*m//g' | grep -E '^[[:space:]]*FAIL' | grep -oE 'AC-[0-9]+' | sort -u
}
# ⚠️ 不用「对称差」判定检出：对称差把「基线红、变异后绿」也算成变化（噪声）。
#    检出的唯一口径是「新增失败键」= 变异运行的失败键 减去 基线失败键（见变异体套件段）。

# ---------------------------------------------------------------- 判据自带的独立工具（不 import 被验包）

cat > "$WORK/fingerprint.mjs" <<'FIXFP'
// fingerprint.mjs —— 判据自带的**独立**指纹实现
// 照 REQ-004 的 references/evidence-chain.md §4 重写；**不** import 被验包里的实现。
// 规范化序列化：证据行 `${path}\0${sha256}\n`；结果行
//   `${case_id}\0${status}\0${errorType}\0${errorMessage}\0${command}\0${steps.join(" | ")}\n`
// results 指纹 = 各结果行（按顺序）后再接各条结果的证据条目行；
// 证据清单指纹 = 全部证据条目行连接。
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

export const sha256Hex = (data) => createHash('sha256').update(data).digest('hex');

function evidenceLine(entry) {
  const path = entry && typeof entry.path === 'string' ? entry.path : '';
  const sha = entry && typeof entry.sha256 === 'string' ? entry.sha256 : '';
  return `${path}\u0000${sha}\n`;
}

function resultLine(entry) {
  const caseId = entry && typeof entry.case_id === 'string' ? entry.case_id : '';
  const status = entry && typeof entry.status === 'string' ? entry.status : '';
  const errorType = entry && entry.error && typeof entry.error.type === 'string' ? entry.error.type : '';
  const errorMessage = entry && entry.error && typeof entry.error.message === 'string' ? entry.error.message : '';
  const command = entry && entry.reproduction && typeof entry.reproduction.command === 'string'
    ? entry.reproduction.command : '';
  const steps = entry && entry.reproduction && Array.isArray(entry.reproduction.steps)
    ? entry.reproduction.steps.join(' | ') : '';
  return `${caseId}\u0000${status}\u0000${errorType}\u0000${errorMessage}\u0000${command}\u0000${steps}\n`;
}

export function evidenceManifestFingerprint(results) {
  const list = Array.isArray(results) ? results : [];
  const parts = [];
  for (const entry of list) {
    const evidence = entry && Array.isArray(entry.evidence) ? entry.evidence : [];
    for (const item of evidence) parts.push(evidenceLine(item));
  }
  return sha256Hex(parts.join(''));
}

export function resultsFingerprint(results) {
  const list = Array.isArray(results) ? results : [];
  const parts = list.map((entry) => resultLine(entry));
  for (const entry of list) {
    const evidence = entry && Array.isArray(entry.evidence) ? entry.evidence : [];
    for (const item of evidence) parts.push(evidenceLine(item));
  }
  return sha256Hex(parts.join(''));
}

// 目录内容的 sha256 清单（用于被验实现指纹与副本前后比对）
export function dirFingerprint(root) {
  const lines = [];
  const walk = (dir) => {
    let entries = [];
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const entry of entries) {
      if (entry.name === '.git' || entry.name === 'node_modules') continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.isFile()) {
        const hash = createHash('sha256').update(fs.readFileSync(full)).digest('hex');
        lines.push(`${path.relative(root, full)} ${hash}`);
      }
    }
  };
  walk(root);
  lines.sort();
  return lines.join('\n');
}

// 命令行用法: node fingerprint.mjs <dir> —— 打印该目录内容的 sha256 清单
if (process.argv[1] && /fingerprint\.mjs$/.test(process.argv[1]) && process.argv[2]) {
  process.stdout.write(`${dirFingerprint(process.argv[2])}\n`);
}
FIXFP

cat > "$WORK/frontmatter.mjs" <<'FIXFM'
// frontmatter.mjs —— 取 YAML frontmatter 里某个 key 的**值**（判空必须判到值上）
// 用法: node frontmatter.mjs <file> <key>
// 输出: JSON { found, raw, value, empty }
import fs from 'node:fs';

const [file, key] = process.argv.slice(2);
const out = { found: false, raw: '', value: '', empty: true };
const emit = () => { process.stdout.write(`${JSON.stringify(out)}\n`); };

let text = '';
try { text = fs.readFileSync(file, 'utf8'); } catch { emit(); process.exit(0); }

const lines = text.split(/\r?\n/);
let start = -1;
for (let i = 0; i < lines.length; i += 1) {
  if (/^---\s*$/.test(lines[i])) { start = i; break; }
}
if (start < 0) { emit(); process.exit(0); }
let end = -1;
for (let i = start + 1; i < lines.length; i += 1) {
  if (/^---\s*$/.test(lines[i])) { end = i; break; }
}
if (end < 0) { emit(); process.exit(0); }
const fm = lines.slice(start + 1, end);

const escaped = String(key || '').replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const keyRe = new RegExp(`^${escaped}\\s*:\\s*(.*)$`);
let idx = -1;
for (let i = 0; i < fm.length; i += 1) {
  const m = keyRe.exec(fm[i]);
  if (m) { idx = i; out.found = true; out.raw = m[1].trim(); break; }
}
if (idx < 0) { emit(); process.exit(0); }

if (/^[|>][+-]?\d*$/.test(out.raw)) {
  const parts = [];
  for (let i = idx + 1; i < fm.length; i += 1) {
    const line = fm[i];
    if (line.trim() === '') { parts.push(''); continue; }
    if (!/^[ \t]/.test(line)) break;
    parts.push(line.trim());
  }
  out.value = parts.join('\n').trim();
} else {
  let value = out.raw;
  if (/^".*"$/s.test(value) || /^'.*'$/s.test(value)) value = value.slice(1, -1);
  out.value = value.trim();
}
out.empty = out.value === '';
emit();
FIXFM

cat > "$WORK/readme-skills.mjs" <<'FIXREADME'
// readme-skills.mjs —— 从 README 里抽「skill 清单」集合（AC-003）
// 口径：① 表头首格是 Skill 的表格 → 取其每一行的首格；② 正文里的 skills/<name> 路径；
//       ③ 安装树代码块里 skills/ 根之后的条目。三者取**并集**。
import fs from 'node:fs';

const text = fs.readFileSync(process.argv[2], 'utf8');
const names = new Set();
const lines = text.split(/\r?\n/);

let inSkillTable = false;
for (const line of lines) {
  if (!line.trim().startsWith('|')) { inSkillTable = false; continue; }
  const cells = line.split('|').slice(1, -1).map((cell) => cell.trim().replace(/`/g, ''));
  if (cells.length === 0) continue;
  if (!inSkillTable) {
    if (cells[0].toLowerCase() === 'skill') inSkillTable = true;
    continue;
  }
  if (cells[0] && /^[a-z][a-z0-9-]*$/.test(cells[0])) names.add(cells[0]);
}

for (const match of text.matchAll(/skills\/([A-Za-z0-9][A-Za-z0-9._-]*)/g)) names.add(match[1]);

let inFence = false;
let treeRootSeen = false;
for (const line of lines) {
  if (line.trim().startsWith('```')) {
    inFence = !inFence;
    treeRootSeen = false;
    continue;
  }
  if (!inFence) continue;
  if (/skills\/?$/.test(line.trim())) { treeRootSeen = true; continue; }
  if (!treeRootSeen) continue;
  const match = line.match(/^[│├└─\s]*`?([a-z][a-z0-9-]*)`?\/\s*(#.*)?$/);
  if (match) names.add(match[1]);
}
process.stdout.write(`${JSON.stringify([...names].sort())}\n`);
FIXREADME

cat > "$WORK/scan-deps.mjs" <<'FIXSCAN'
// scan-deps.mjs —— AC-026：零第三方依赖 + 不联网 + 相对 import 只许指向本 skill 内
// 用法: node scan-deps.mjs <skill-dir>
import fs from 'node:fs';
import path from 'node:path';

const skillDir = path.resolve(process.argv[2]);
const files = [];
const walk = (dir) => {
  let entries = [];
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full);
    else if (/\.mjs$/.test(entry.name)) files.push(full);
  }
};
walk(skillDir);

const thirdParty = [];
const network = [];
const outside = [];

for (const file of files) {
  const raw = fs.readFileSync(file, 'utf8');
  const src = raw.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
  const dir = path.dirname(file);
  src.split(/\r?\n/).forEach((line, index) => {
    const specs = [];
    const staticImport = line.match(/\bfrom\s+['"]([^'"]+)['"]/);
    if (staticImport) specs.push(staticImport[1]);
    const bareImport = line.match(/^\s*import\s+['"]([^'"]+)['"]/);
    if (bareImport) specs.push(bareImport[1]);
    const requireCall = line.match(/\brequire\s*\(\s*['"]([^'"]+)['"]\s*\)/);
    if (requireCall) specs.push(requireCall[1]);
    const dynamicImport = line.match(/\bimport\s*\(\s*['"]([^'"]+)['"]\s*\)/);
    if (dynamicImport) specs.push(dynamicImport[1]);
    const dynamicTemplate = line.match(/\bimport\s*\(\s*`([^`]*)`\s*\)/);
    if (dynamicTemplate) specs.push(dynamicTemplate[1]);
    for (const spec of specs) {
      if (spec.startsWith('node:')) continue;
      if (spec.startsWith('./') || spec.startsWith('../')) {
        const resolved = path.resolve(dir, spec);
        const rel = path.relative(skillDir, resolved);
        if (rel.startsWith('..')) outside.push(`${file}:${index + 1}: ${spec}`);
        continue;
      }
      thirdParty.push(`${file}:${index + 1}: ${spec}`);
    }
    if (/\bfetch\s*\(/.test(line)) network.push(`${file}:${index + 1}: ${line.trim()}`);
    else if (/\bXMLHttpRequest\b/.test(line)) network.push(`${file}:${index + 1}: ${line.trim()}`);
    else if (/node:https?['"]/.test(line)) network.push(`${file}:${index + 1}: ${line.trim()}`);
  });
}
process.stdout.write(`${JSON.stringify({ files: files.length, thirdParty, network, outside })}\n`);
FIXSCAN

cat > "$WORK/pathcount.mjs" <<'FIXPATH'
// pathcount.mjs —— 数一个点号路径在 JSON 树里出现几次（变异体「锚点唯一命中」用）
// 用法: node pathcount.mjs <file.json> <a.b.c>
import fs from 'node:fs';

const [file, dotted] = process.argv.slice(2);
let root = null;
try { root = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { root = null; }
let count = 0;
const walk = (node, parts) => {
  if (!node || typeof node !== 'object') return;
  for (const key of Object.keys(node)) {
    const next = [...parts, key];
    if (next.join('.') === dotted) count += 1;
    walk(node[key], next);
  }
};
walk(root, []);
process.stdout.write(`${count}\n`);
FIXPATH

cat > "$WORK/pkgfiles.mjs" <<'FIXFILES'
// pkgfiles.mjs —— 列出被验包里匹配某个相对路径的文件（变异体入口锚点唯一性用）
// 用法: node pkgfiles.mjs <pkg-dir> <relative-path>
import fs from 'node:fs';
import path from 'node:path';

const [root, rel] = process.argv.slice(2);
const hits = [];
const walk = (dir) => {
  let entries = [];
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full);
    else if (entry.isFile() && path.relative(root, full) === rel) hits.push(full);
  }
};
walk(path.resolve(root));
process.stdout.write(`${JSON.stringify(hits)}\n`);
FIXFILES

cat > "$WORK/mkfixture.mjs" <<'FIXMK'
// mkfixture.mjs —— 按 acceptance.md §0 自造夹具（执行产物 + 回归计划）
// 用法: node mkfixture.mjs <art-dir> <plan-file>
// ⚠️ 两个指纹由**本脚本自己算**（内嵌的独立算法），不得写死字面量。
// ⚠️ TC-005 的证据文件**故意不存在**，但它的 sha256/bytes 算得出：
//    先在临时目录造出那个文件、算完指纹，再**移走**（move，不是 remove）。
import fs from 'node:fs';
import path from 'node:path';
import { resultsFingerprint, evidenceManifestFingerprint, sha256Hex } from './fingerprint.mjs';

const [artDir, planFile] = process.argv.slice(2);
const ISO = '2026-11-13T00:00:00Z';
const sha256 = sha256Hex;

const BODIES = {
  'evidence/TC-001/step-1-response.json': '{\n  "status": 200,\n  "case": "TC-001"\n}\n',
  'evidence/TC-002/step-1-response.json': '{\n  "status": 500,\n  "case": "TC-002"\n}\n',
  'evidence/TC-003/step-1-response.json': '{\n  "status": 200,\n  "case": "TC-003"\n}\n',
  'evidence/TC-005/step-1-response.json': '{\n  "status": 200,\n  "case": "TC-005"\n}\n',
};

const ev = (p) => {
  const body = BODIES[p];
  return { path: p, sha256: sha256(body), bytes: Buffer.byteLength(body), media_type: 'application/json' };
};

const results = [
  {
    case_id: 'TC-001', title: '健康检查通过', requirement_refs: ['R-1'], status: 'passed',
    started_at: ISO, finished_at: ISO, duration_ms: 120,
    evidence: [ev('evidence/TC-001/step-1-response.json')],
    reproduction: { steps: ['GET /api/health'], command: 'curl -X GET /api/health', expected: '' },
    error: null,
  },
  {
    case_id: 'TC-002', title: '订单查询返回 500', requirement_refs: ['R-1'], status: 'failed',
    started_at: ISO, finished_at: ISO, duration_ms: 340,
    evidence: [ev('evidence/TC-002/step-1-response.json')],
    reproduction: { steps: ['GET /api/orders'], command: 'curl -X GET /api/orders', expected: 'status=200' },
    error: { type: 'assertion', message: '期望 200，实际 500' },
  },
  {
    case_id: 'TC-003', title: '列表用例缺少断言', requirement_refs: ['R-2'], status: 'blocked',
    started_at: ISO, finished_at: ISO, duration_ms: 55,
    evidence: [ev('evidence/TC-003/step-1-response.json')],
    reproduction: { steps: ['GET /api/items'], command: 'curl -X GET /api/items', expected: '' },
    error: { type: 'missing_assertion', message: '用例缺少可机械判定的断言' },
  },
  {
    case_id: 'TC-004', title: '已废弃用例', requirement_refs: ['R-2'], status: 'skipped',
    started_at: ISO, finished_at: ISO, duration_ms: 0,
    evidence: [],
    reproduction: { steps: [], command: '', expected: '' },
    error: null,
  },
  {
    case_id: 'TC-005', title: '报表导出通过', requirement_refs: ['R-3'], status: 'passed',
    started_at: ISO, finished_at: ISO, duration_ms: 210,
    evidence: [ev('evidence/TC-005/step-1-response.json')],
    reproduction: { steps: ['GET /api/reports'], command: 'curl -X GET /api/reports', expected: '' },
    error: null,
  },
];

// meta.json：计数**故意**与实际不符（真值 5/2/1/1/1，meta 写 6/2/1/1/2）—— AC-021 的源。
// duration_ms = 725 = 各条用例 duration_ms 之和（两种口径同值，实现方不可能踩坑）。
const meta = {
  run_id: 'run-demo-0001',
  suite: 'REQ-DEMO-demo',
  scope: 'functional',
  requirement: 'REQ-DEMO',
  environment: 'mock-local',
  started_at: ISO,
  finished_at: ISO,
  duration_ms: 725,
  agent: 'demo-agent',
  executor: { name: 'mock', version: '0.1.0' },
  tool_versions: {},
  cases_total: 6,
  cases_passed: 2,
  cases_failed: 1,
  cases_blocked: 1,
  cases_skipped: 2,
  evidence_manifest_sha256: evidenceManifestFingerprint(results),
  results_sha256: resultsFingerprint(results),
  redaction: { rules_applied: [], redacted_fields: 0 },
  cycle: null,
};

const PLAN = {
  schema_version: 1,
  cycle_id: 'R2-DEMO',
  generated_at: ISO,
  source: { changelog: 'CHANGELOG.md', cases: 'cases.json' },
  changes: [
    { id: 'C-1', title: '健康检查接口调整', requirement_refs: [], case_refs: ['TC-001'], dimensions: [], explicit_dimensions: [], signal_dimensions: [], method_hits: [] },
    { id: 'C-2', title: '订单列表断言调整', requirement_refs: ['R-1'], case_refs: [], dimensions: [], explicit_dimensions: [], signal_dimensions: [], method_hits: [] },
    { id: 'C-3', title: '文档措辞调整', requirement_refs: [], case_refs: [], dimensions: [], explicit_dimensions: [], signal_dimensions: [], method_hits: [] },
  ],
  selected: [
    { case_id: 'TC-001', reason: 'case_ref:TC-001', change_refs: ['C-1'] },
    { case_id: 'TC-002', reason: 'case_ref:TC-002', change_refs: ['C-1'] },
    { case_id: 'TC-006', reason: 'case_ref:TC-006', change_refs: ['C-1'] },
  ],
  needs_review: [
    { case_id: 'TC-003', reason: 'method_not_applies:M1.2', change_refs: ['C-2'] },
  ],
  undecidable_changes: [
    { change_id: 'C-3', reason: '无显式引用，且正文未命中任何维度/方法信号' },
  ],
  summary: { total_cases: 6, selected: 3, needs_review: 1, undecidable_changes: 1, impact_complete: false },
};

fs.mkdirSync(path.join(artDir, 'evidence'), { recursive: true });
fs.mkdirSync(path.join(artDir, 'logs'), { recursive: true });
for (const p of Object.keys(BODIES)) {
  if (p === 'evidence/TC-005/step-1-response.json') continue;
  fs.mkdirSync(path.join(artDir, path.dirname(p)), { recursive: true });
  fs.writeFileSync(path.join(artDir, p), BODIES[p]);
}
// TC-005：先在**证据路径上**真的造出那个文件（内容已定，指纹算得出），
//          再用 **move（rename，不是 remove）** 把它移出产物目录 —— 文件实况必须不存在。
const stash = path.join(artDir, '..', 'stash-TC-005');
fs.mkdirSync(stash, { recursive: true });
const tc005 = path.join(artDir, 'evidence', 'TC-005', 'step-1-response.json');
fs.mkdirSync(path.dirname(tc005), { recursive: true });
fs.writeFileSync(tc005, BODIES['evidence/TC-005/step-1-response.json']);
fs.renameSync(tc005, path.join(stash, 'step-1-response.json'));

fs.writeFileSync(path.join(artDir, 'logs', 'runner.log'), 'mock runner log\n');
fs.writeFileSync(path.join(artDir, 'meta.json'), `${JSON.stringify(meta, null, 2)}\n`);
fs.writeFileSync(path.join(artDir, 'results.json'), `${JSON.stringify(results, null, 2)}\n`);
fs.mkdirSync(path.dirname(planFile), { recursive: true });
fs.writeFileSync(path.join(planFile), `${JSON.stringify(PLAN, null, 2)}\n`);

process.stdout.write(`${JSON.stringify({
  results_sha256: meta.results_sha256,
  evidence_manifest_sha256: meta.evidence_manifest_sha256,
})}\n`);
FIXMK

cat > "$WORK/judge.mjs" <<'FIXJUDGE'
#!/usr/bin/env node
// judge.mjs —— 报告侧判据的**独立复算器**（AC-005 ~ AC-023）
//
// 原则（对标 D65「门是被验对象，不是脚手架」）：
//   ① 一切数字都从**输入**（results.json / regression-plan.json）重算，不信报告里的自述；
//   ② 指纹用本脚本自带的独立实现（./fingerprint.mjs），**不** import 被验包里的实现；
//   ③ 只读被验包与夹具，绝不写回。
//
// 用法: node judge.mjs <art-dir> <plan-file> <out-plan> <out-noplan> <out-tamper> <pkg-root>
// 输出: 每行 "AC-xxx\tPASS|FAIL\t说明"
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { resultsFingerprint, evidenceManifestFingerprint } from './fingerprint.mjs';

const [artDir, planFile, outPlan, outNoPlan, outTamper, pkgRoot] = process.argv.slice(2);

const out = [];
const emit = (id, ok, msg) => {
  out.push(`${id}\t${ok ? 'PASS' : 'FAIL'}\t${String(msg).replace(/[\t\r\n]+/g, ' ').trim()}`);
};
const readJson = (p) => { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; } };
const readText = (p) => { try { return fs.readFileSync(p, 'utf8'); } catch { return ''; } };
const sha256Hex = (s) => crypto.createHash('sha256').update(s, 'utf8').digest('hex');
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const getPath = (root, dotted) => {
  let cur = root;
  for (const part of String(dotted).split('.')) {
    if (!isObj(cur) && !Array.isArray(cur)) return undefined;
    cur = cur[part];
  }
  return cur;
};
const fmt = (v) => {
  if (Array.isArray(v)) return v.map((x) => (typeof x === 'string' ? x : JSON.stringify(x))).join(',');
  if (v === null) return 'null';
  if (typeof v === 'object') return JSON.stringify(v);
  return String(v);
};
const stableStringify = (value, sortKeys) => {
  if (value === null) return 'null';
  if (Array.isArray(value)) return `[${value.map((v) => stableStringify(v, sortKeys)).join(',')}]`;
  if (typeof value === 'object') {
    const keys = Object.keys(value);
    const ordered = sortKeys ? keys.slice().sort() : keys;
    return `{${ordered.map((k) => `${JSON.stringify(k)}:${stableStringify(value[k], sortKeys)}`).join(',')}}`;
  }
  return JSON.stringify(value);
};

// ---------------------------------------------------------------- 输入
const results = readJson(path.join(artDir, 'results.json'));
const meta = readJson(path.join(artDir, 'meta.json'));
const plan = readJson(planFile);
const rp = readJson(path.join(outPlan, 'report.json'));
const md = readText(path.join(outPlan, 'report.md'));
const rnp = readJson(path.join(outNoPlan, 'report.json'));
const mdn = readText(path.join(outNoPlan, 'report.md'));
const rt = readJson(path.join(outTamper, 'report.json'));
const mdt = readText(path.join(outTamper, 'report.md'));
const schemaDoc = readText(path.join(pkgRoot, 'skills', 'test-report', 'references', 'report-schema.md'));

const resultsArr = Array.isArray(results) ? results : [];
const counts = { total: resultsArr.length, passed: 0, failed: 0, blocked: 0, skipped: 0 };
for (const r of resultsArr) {
  const s = isObj(r) ? r.status : '';
  if (s === 'passed') counts.passed += 1;
  else if (s === 'failed') counts.failed += 1;
  else if (s === 'blocked') counts.blocked += 1;
  else if (s === 'skipped') counts.skipped += 1;
}
const durTotal = resultsArr.reduce(
  (a, r) => a + (isObj(r) && Number.isFinite(Number(r.duration_ms)) ? Number(r.duration_ms) : 0),
  0,
);
const caseIds = new Set(resultsArr.filter(isObj).map((r) => String(r.case_id)));
const failIds = resultsArr
  .filter((r) => isObj(r) && (r.status === 'failed' || r.status === 'blocked'))
  .map((r) => String(r.case_id))
  .sort();
const planSelected = isObj(plan) && Array.isArray(plan.selected) ? plan.selected.map((s) => String(s.case_id)) : [];
const planReview = isObj(plan) && Array.isArray(plan.needs_review) ? plan.needs_review.map((s) => String(s.case_id)) : [];
const planUndec = isObj(plan) && Array.isArray(plan.undecidable_changes) ? plan.undecidable_changes : [];
const cs = isObj(rp) && isObj(rp.cases) ? rp.cases : {};
const vd = isObj(rp) && isObj(rp.verdict) ? rp.verdict : {};
const ev = isObj(rp) && isObj(rp.evidence) ? rp.evidence : {};
const reg = isObj(rp) && isObj(rp.regression) ? rp.regression : {};
const findings = Array.isArray(ev.findings) ? ev.findings : [];
const missingPaths = Array.isArray(ev.missing_paths) ? ev.missing_paths.map(String) : [];
const selectedMissing = Array.isArray(reg.selected_missing) ? reg.selected_missing.map(String) : [];

// ---------------------------------------------------------------- AC-005 计数重算
{
  const problems = [];
  if (!isObj(rp)) problems.push('report.json 不可读');
  else if (!isObj(rp.cases)) problems.push('report.json 的 cases 段缺失');
  else {
    for (const k of ['total', 'passed', 'failed', 'blocked', 'skipped']) {
      if (cs[k] !== counts[k]) problems.push(`cases.${k}=${JSON.stringify(cs[k])}，从 results.json 重算应为 ${counts[k]}`);
    }
    if (isObj(meta) && cs.total === meta.cases_total) {
      problems.push(`cases.total 与 meta.json 的自述（${meta.cases_total}）相同 —— 说明抄了 meta 而不是重算`);
    }
  }
  emit('AC-005', problems.length === 0, problems.join('; ') || `重算真值 total=${counts.total} passed=${counts.passed} failed=${counts.failed} blocked=${counts.blocked} skipped=${counts.skipped}`);
}

// ---------------------------------------------------------------- AC-006 状态分布逐条一致
{
  const problems = [];
  if (!isObj(rp)) problems.push('report.json 不可读');
  else {
    for (const k of ['passed', 'failed', 'blocked', 'skipped']) {
      if (cs[k] !== counts[k]) problems.push(`cases.${k}=${JSON.stringify(cs[k])}，逐条累加应为 ${counts[k]}`);
    }
    if (!Array.isArray(rp.failures)) problems.push('failures 段缺失或不是数组');
    else {
      const rep = rp.failures.map((f) => String(isObj(f) ? f.case_id : '')).sort();
      if (rep.join('|') !== failIds.join('|')) {
        problems.push(`failures 的 case_id 集合=[${rep.join(',')}]，与 results.json 里 failed+blocked 的集合=[${failIds.join(',')}] 不相等`);
      }
    }
  }
  emit('AC-006', problems.length === 0, problems.join('; ') || `逐条累加与 failures 集合均一致（${failIds.join(',')}）`);
}

// ---------------------------------------------------------------- AC-007 证据实查
{
  const problems = [];
  const EXPECT = 'evidence/TC-005/step-1-response.json';
  if (!isObj(rp)) problems.push('report.json 不可读');
  else if (!isObj(rp.evidence)) problems.push('evidence 段缺失');
  else {
    if (!missingPaths.includes(EXPECT)) problems.push(`evidence.missing_paths 没有点名 ${EXPECT}（实际=[${missingPaths.join(',')}]）`);
    if (ev.files_missing !== 1) problems.push(`evidence.files_missing=${JSON.stringify(ev.files_missing)}，应为 1`);
    if (ev.files_present !== 3) problems.push(`evidence.files_present=${JSON.stringify(ev.files_present)}，应为 3`);
    const hit = findings.find((f) => isObj(f) && f.kind === 'missing_evidence'
      && typeof f.message === 'string' && f.message.trim() !== '' && f.message.includes(EXPECT));
    if (!hit) problems.push(`evidence.findings 里没有一条 kind=missing_evidence、message 非空且点名 ${EXPECT} 的条目`);
    if (vd.evidence_layer !== 'fail') problems.push(`verdict.evidence_layer=${JSON.stringify(vd.evidence_layer)}，应为 fail`);
  }
  emit('AC-007', problems.length === 0, problems.join('; ') || 'missing_paths/files_present/files_missing/findings/evidence_layer 均符合');
}

// ---------------------------------------------------------------- AC-008 指纹绑定
{
  const problems = [];
  const recR = resultsFingerprint(resultsArr);
  const recE = evidenceManifestFingerprint(resultsArr);
  const mR = isObj(meta) ? meta.results_sha256 : undefined;
  const mE = isObj(meta) ? meta.evidence_manifest_sha256 : undefined;
  const src = isObj(rp) && isObj(rp.source) ? rp.source : {};
  if (mR !== recR) problems.push('meta.results_sha256 与重算值不符');
  if (mE !== recE) problems.push('meta.evidence_manifest_sha256 与重算值不符');
  if (src.results_sha256 !== recR) problems.push(`report.source.results_sha256=${JSON.stringify(src.results_sha256)}，重算值=${recR}`);
  if (src.evidence_manifest_sha256 !== recE) problems.push(`report.source.evidence_manifest_sha256=${JSON.stringify(src.evidence_manifest_sha256)}，重算值=${recE}`);
  emit('AC-008', problems.length === 0, problems.join('; ') || `四个值全部相等（results=${recR.slice(0, 12)}…）`);
}

// ---------------------------------------------------------------- AC-010 report_sha256 可重算
{
  const problems = [];
  if (!isObj(rp)) problems.push('report.json 不可读');
  else {
    const clone = JSON.parse(JSON.stringify(rp));
    delete clone.generated_at;
    delete clone.report_sha256;
    const cands = new Set([
      stableStringify(clone, true),
      stableStringify(clone, false),
      JSON.stringify(clone, null, 2),
      `${JSON.stringify(clone, null, 2)}\n`,
      `${stableStringify(clone, true)}\n`,
    ]);
    const hashes = new Set([...cands].map((c) => sha256Hex(c)));
    const claimed = rp.report_sha256;
    if (typeof claimed !== 'string' || !/^[0-9a-f]{64}$/i.test(claimed)) {
      problems.push(`report_sha256=${JSON.stringify(claimed)} 不是 64 位 hex`);
    } else if (!hashes.has(claimed)) {
      problems.push(`report_sha256=${claimed} 与「剔除 generated_at 与 report_sha256 后稳定序列化」重算出的值不符`);
    }
    const docOk = /report_sha256/.test(schemaDoc)
      && /generated_at/.test(schemaDoc)
      && /(排除|剔除|去掉|去除|不含)/.test(schemaDoc)
      && /(sha256|SHA-256|sha-256)/i.test(schemaDoc)
      && /(序列化|规范化|canonical|stable)/i.test(schemaDoc);
    if (!docOk) problems.push('references/report-schema.md 里没有写明 report_sha256 的规范化口径（剔除 generated_at 与本字段后的稳定序列化）');
  }
  emit('AC-010', problems.length === 0, problems.join('; ') || '可重算且口径已写进 schema');
}

// ---------------------------------------------------------------- AC-011 md 摘要与正文
{
  const problems = [];
  if (!isObj(rp)) problems.push('report.json 不可读');
  else {
    const digestLines = md.match(/<!--\s*report-digest:[^\n]*?-->/g) || [];
    if (digestLines.length !== 1) {
      problems.push(`report.md 里的 report-digest 摘要行出现 ${digestLines.length} 次，要求恰好 1 行`);
    }
    const pairs = [];
    if (digestLines.length >= 1) {
      const inner = digestLines[0].replace(/^<!--\s*report-digest:/, '').replace(/-->\s*$/, '').trim();
      for (const piece of inner.split(';')) {
        const p = piece.trim();
        if (!p) continue;
        const eq = p.indexOf('=');
        if (eq < 0) { problems.push(`摘要里的片段「${p}」不是 key=value 形式`); continue; }
        pairs.push([p.slice(0, eq).trim(), p.slice(eq + 1).trim()]);
      }
    }
    const seen = new Set();
    for (const [k, v] of pairs) {
      seen.add(k);
      const val = getPath(rp, k);
      if (val === undefined) { problems.push(`摘要里的键 ${k} 在 report.json 里没有同名路径`); continue; }
      const expect = fmt(val);
      if (v !== expect) problems.push(`摘要里的 ${k}=${v}，report.json 的同名路径是 ${expect}（逐字不等）`);
    }
    const REQUIRED = ['cases.total', 'cases.passed', 'cases.failed', 'cases.blocked', 'cases.skipped',
      'verdict.case_layer', 'verdict.evidence_layer', 'verdict.regression_layer', 'verdict.overall',
      'source.results_sha256', 'source.evidence_manifest_sha256', 'report_sha256'];
    for (const k of REQUIRED) if (!seen.has(k)) problems.push(`摘要缺必需键 ${k}`);
    // ④ 正文关键数字（对齐 demand.md F4.2 的标签词汇表）：
    //    标签 + 数字（标签与数字之间**不得出现字母或数字** —— 拦的是 id 自带的数字；
    //    单位 条/个/项 **可省略**）。
    //    ⚠️ 标签与数字之间的「间隔」里**不允许**出现字母/数字（否则「漏跑：TC-006（1 条）」里的
    //    「006」会被当成漏跑条数 —— 那是误判）。这种写法按「未呈现」处理（不判红，只是不计入呈现数）。
    const BODY = md.replace(/<!--\s*report-digest:[^\n]*?-->/g, '');
    const METRICS = [
      { key: 'cases.total', expect: counts.total, label: '(?:用例总数|共计|总计|合计)' },
      { key: 'cases.passed', expect: counts.passed, label: '(?:通过)' },
      { key: 'cases.failed', expect: counts.failed, label: '(?:失败)' },
      { key: 'cases.blocked', expect: counts.blocked, label: '(?:阻塞|阻断)' },
      { key: 'cases.skipped', expect: counts.skipped, label: '(?:跳过)' },
      { key: 'regression.selected_missing', expect: selectedMissing.length, label: '(?:漏跑|未执行|未跑)' },
      { key: 'regression.needs_review_planned', expect: Number(reg.needs_review_planned || 0), label: '(?:待复核|需复核|人工复核)' },
      { key: 'regression.undecidable_changes', expect: Array.isArray(reg.undecidable_changes) ? reg.undecidable_changes.length : 0, label: '(?:判不了|无法判定|不可判定)' },
    ];
    let presented = 0;
    for (const m of METRICS) {
      const re = new RegExp(`${m.label}[^0-9A-Za-z\\u4e00-\\u9fa5]{0,10}?(\\d+)\\s*[条个项]?`, 'g');
      const hits = [...BODY.matchAll(re)].map((x) => Number(x[1]));
      if (hits.length === 0) continue;
      presented += 1;
      for (const h of hits) {
        if (h !== m.expect) problems.push(`正文里「${m.key}」标签后的数字是 ${h}，与摘要的 ${m.expect} 不一致`);
      }
    }
    if (presented < 4) problems.push(`正文只呈现了 ${presented}/8 个关键数字（F4.2 标签词汇表口径），要求至少 4 个`);
  }
  emit('AC-011', problems.length === 0, problems.join('; ') || '摘要键齐全、逐字相等，正文关键数字与摘要一致');
}

// ---------------------------------------------------------------- AC-012 overall=pass 的自洽不变式
{
  const problems = [];
  if (isObj(rp) && vd.overall === 'pass') {
    if (cs.failed !== 0) problems.push(`overall=pass 但 cases.failed=${JSON.stringify(cs.failed)}`);
    if (cs.blocked !== 0) problems.push(`overall=pass 但 cases.blocked=${JSON.stringify(cs.blocked)}`);
    if (vd.evidence_layer !== 'pass') problems.push(`overall=pass 但 verdict.evidence_layer=${JSON.stringify(vd.evidence_layer)}`);
    if (!(vd.regression_layer === 'pass' || vd.regression_layer === 'not_applicable')) {
      problems.push(`overall=pass 但 verdict.regression_layer=${JSON.stringify(vd.regression_layer)}`);
    }
    if (!isObj(reg) || reg.impact_complete !== true) {
      problems.push(`overall=pass 但 regression.impact_complete=${isObj(reg) ? JSON.stringify(reg.impact_complete) : 'null'}`);
    }
  }
  emit('AC-012', problems.length === 0, problems.join('; ') || `overall=${JSON.stringify(vd.overall)}（自洽条件未被触发）`);
}

// ---------------------------------------------------------------- AC-013 必填字段集
{
  const problems = [];
  if (!isObj(rp)) {
    problems.push('report.json 不可读');
  } else {
    if (typeof rp.schema_version !== 'number') problems.push('schema_version 缺失或不是 number');
    if (typeof rp.generated_at !== 'string' || rp.generated_at === '') problems.push('generated_at 缺失或不是非空 string');
    const src = isObj(rp.source) ? rp.source : null;
    if (!src) problems.push('source 段缺失');
    else {
      for (const k of ['artifacts', 'run_id', 'suite', 'requirement', 'environment', 'started_at', 'finished_at', 'results_sha256', 'evidence_manifest_sha256']) {
        if (typeof src[k] !== 'string' || src[k] === '') problems.push(`source.${k} 缺失或不是非空 string`);
      }
      if (!(src.regression_plan === null || (typeof src.regression_plan === 'string' && src.regression_plan !== ''))) {
        problems.push('source.regression_plan 必须是 string 或 null');
      }
    }
    if (!isObj(rp.cases)) problems.push('cases 段缺失');
    else for (const k of ['total', 'passed', 'failed', 'blocked', 'skipped', 'duration_ms_total']) {
      if (typeof rp.cases[k] !== 'number') problems.push(`cases.${k} 缺失或不是 number`);
    }
    if (!isObj(rp.verdict)) problems.push('verdict 段缺失');
    else {
      const enums = {
        case_layer: ['pass', 'fail', 'incomplete'],
        evidence_layer: ['pass', 'fail', 'unknown'],
        regression_layer: ['pass', 'fail', 'incomplete', 'not_applicable', 'unknown'],
        overall: ['pass', 'fail', 'incomplete'],
      };
      for (const [k, allowed] of Object.entries(enums)) {
        if (typeof rp.verdict[k] !== 'string' || !allowed.includes(rp.verdict[k])) {
          problems.push(`verdict.${k}=${JSON.stringify(rp.verdict[k])}，不在枚举 [${allowed.join(',')}] 里`);
        }
      }
    }
    if (!Array.isArray(rp.failures)) problems.push('failures 缺失或不是数组');
    else rp.failures.forEach((f, i) => {
      if (!isObj(f)) { problems.push(`failures[${i}] 不是对象`); return; }
      for (const k of ['case_id', 'title', 'status']) {
        if (typeof f[k] !== 'string' || f[k] === '') problems.push(`failures[${i}].${k} 缺失或不是非空 string`);
      }
      for (const k of ['error', 'reproduction', 'evidence']) {
        if (!(k in f)) problems.push(`failures[${i}] 缺 ${k} 字段`);
      }
    });
    if (!isObj(rp.evidence)) problems.push('evidence 段缺失');
    else {
      if (typeof rp.evidence.files_present !== 'number') problems.push('evidence.files_present 缺失或不是 number');
      if (typeof rp.evidence.files_missing !== 'number') problems.push('evidence.files_missing 缺失或不是 number');
      if (!Array.isArray(rp.evidence.missing_paths) || rp.evidence.missing_paths.some((x) => typeof x !== 'string')) {
        problems.push('evidence.missing_paths 缺失或不是 string[]');
      }
      if (!Array.isArray(rp.evidence.findings)) problems.push('evidence.findings 缺失或不是数组');
      else rp.evidence.findings.forEach((f, i) => {
        if (!isObj(f)) { problems.push(`evidence.findings[${i}] 不是对象`); return; }
        const kinds = ['missing_evidence', 'evidence_mismatch', 'count_mismatch', 'fingerprint_mismatch'];
        if (!kinds.includes(f.kind)) problems.push(`evidence.findings[${i}].kind=${JSON.stringify(f.kind)}，不在枚举 [${kinds.join(',')}] 里`);
        if (typeof f.message !== 'string' || f.message.trim() === '') problems.push(`evidence.findings[${i}].message 缺失或为空`);
      });
    }
    if (rp.regression !== null) {
      if (!isObj(rp.regression)) problems.push('regression 既不是 null 也不是对象');
      else {
        for (const k of ['selected_planned', 'selected_executed', 'needs_review_planned', 'needs_review_executed']) {
          if (typeof rp.regression[k] !== 'number') problems.push(`regression.${k} 缺失或不是 number`);
        }
        if (!Array.isArray(rp.regression.selected_missing) || rp.regression.selected_missing.some((x) => typeof x !== 'string')) {
          problems.push('regression.selected_missing 缺失或不是 string[]');
        }
        if (!Array.isArray(rp.regression.undecidable_changes)) problems.push('regression.undecidable_changes 缺失或不是数组');
        else rp.regression.undecidable_changes.forEach((u, i) => {
          if (!isObj(u)) { problems.push(`regression.undecidable_changes[${i}] 不是对象`); return; }
          if (typeof u.change_id !== 'string' || u.change_id === '') problems.push(`regression.undecidable_changes[${i}].change_id 缺失`);
          if (typeof u.reason !== 'string' || u.reason === '') problems.push(`regression.undecidable_changes[${i}].reason 缺失或为空`);
        });
        if (typeof rp.regression.impact_complete !== 'boolean') problems.push('regression.impact_complete 缺失或不是 boolean');
      }
    }
    if (typeof rp.report_sha256 !== 'string' || !/^[0-9a-f]{64}$/i.test(rp.report_sha256)) {
      problems.push('report_sha256 缺失或不是 64 位 hex');
    }
  }
  const F3_TOKENS = ['schema_version', 'generated_at', 'artifacts', 'run_id', 'suite', 'requirement', 'environment',
    'started_at', 'finished_at', 'results_sha256', 'evidence_manifest_sha256', 'regression_plan',
    'total', 'passed', 'failed', 'blocked', 'skipped', 'duration_ms_total',
    'case_layer', 'evidence_layer', 'regression_layer', 'overall',
    'case_id', 'title', 'status', 'error', 'reproduction', 'evidence',
    'files_present', 'files_missing', 'missing_paths', 'findings', 'kind', 'message',
    'selected_planned', 'selected_executed', 'needs_review_planned', 'needs_review_executed', 'selected_missing',
    'undecidable_changes', 'change_id', 'reason', 'impact_complete', 'report_sha256',
    'missing_evidence', 'evidence_mismatch', 'count_mismatch', 'fingerprint_mismatch'];
  if (schemaDoc.trim() === '') problems.push('references/report-schema.md 缺失或为空');
  else for (const t of F3_TOKENS) {
    if (!schemaDoc.includes(t)) problems.push(`references/report-schema.md 里没有列出 F3 必填字段 ${t}`);
  }
  emit('AC-013', problems.length === 0, problems.join('; ') || `必填字段与枚举全部符合；schema 列出 ${F3_TOKENS.length} 个字段名`);
}

// ---------------------------------------------------------------- AC-014 漏跑点名
{
  const problems = [];
  const expectedMissing = planSelected.filter((id) => !caseIds.has(id));
  if (!isObj(rp)) problems.push('report.json 不可读');
  else {
    if (!Array.isArray(reg.selected_missing)) problems.push('regression.selected_missing 缺失');
    else if (selectedMissing.join('|') !== expectedMissing.join('|')) {
      problems.push(`regression.selected_missing=[${selectedMissing.join(',')}]，计划减执行应为 [${expectedMissing.join(',')}]`);
    }
    if (!md.includes('TC-006')) problems.push('report.md 里没有逐字点名 TC-006');
  }
  emit('AC-014', problems.length === 0, problems.join('; ') || `漏跑点名一致（${expectedMissing.join(',')}）`);
}

// ---------------------------------------------------------------- AC-015 漏跑导向失败
{
  const problems = [];
  if (isObj(rp) && selectedMissing.length > 0) {
    if (vd.regression_layer !== 'fail') problems.push(`selected_missing 非空但 verdict.regression_layer=${JSON.stringify(vd.regression_layer)}，应为 fail`);
    if (vd.overall === 'pass') problems.push('selected_missing 非空但 verdict.overall=pass');
  }
  emit('AC-015', problems.length === 0, problems.join('; ') || `selected_missing 非空 ⇒ regression_layer=${JSON.stringify(vd.regression_layer)}、overall=${JSON.stringify(vd.overall)}`);
}

// ---------------------------------------------------------------- AC-016 needs_review
{
  const problems = [];
  if (!isObj(rp)) problems.push('report.json 不可读');
  else {
    if (reg.needs_review_planned !== 1) problems.push(`regression.needs_review_planned=${JSON.stringify(reg.needs_review_planned)}，应为 1`);
    if (reg.needs_review_executed !== 1) problems.push(`regression.needs_review_executed=${JSON.stringify(reg.needs_review_executed)}，应为 1`);
    if (vd.regression_layer === 'pass') problems.push('needs_review 非空但 verdict.regression_layer=pass');
    if (!md.includes('TC-003')) problems.push('report.md 里没有点名待复核用例 TC-003');
  }
  emit('AC-016', problems.length === 0, problems.join('; ') || '待复核计数与点名均正确');
}

// ---------------------------------------------------------------- AC-017 判不了的变更
{
  const problems = [];
  if (!isObj(rp)) problems.push('report.json 不可读');
  else {
    const ud = Array.isArray(reg.undecidable_changes) ? reg.undecidable_changes : [];
    if (ud.length !== 1) problems.push(`regression.undecidable_changes 条数=${ud.length}，应为 1`);
    else {
      if (String(ud[0].change_id) !== 'C-3') problems.push(`undecidable_changes[0].change_id=${JSON.stringify(ud[0].change_id)}，应为 C-3`);
      const planReason = planUndec.length > 0 ? String(planUndec[0].reason) : '';
      if (!planReason) problems.push('计划里的 undecidable_changes[0].reason 不可读');
      else if (String(ud[0].reason) !== planReason) problems.push(`undecidable_changes[0].reason 与计划不一致`);
    }
    if (reg.impact_complete !== false) problems.push(`regression.impact_complete=${JSON.stringify(reg.impact_complete)}，应为 false`);
    if (vd.overall === 'pass') problems.push('影响面不完整但 verdict.overall=pass');
    if (!md.includes('C-3')) problems.push('report.md 里没有点名变更 C-3');
  }
  emit('AC-017', problems.length === 0, problems.join('; ') || '判不了的变更已呈现且不判通过');
}

// ---------------------------------------------------------------- AC-018 无计划不得编造回归层
{
  const problems = [];
  if (!isObj(rnp)) problems.push('不给计划时的 report.json 不可读');
  else {
    if (rnp.regression !== null) problems.push(`regression=${JSON.stringify(rnp.regression)}，应为 null`);
    const v = isObj(rnp.verdict) ? rnp.verdict : {};
    if (v.regression_layer !== 'not_applicable') problems.push(`verdict.regression_layer=${JSON.stringify(v.regression_layer)}，应为 not_applicable`);
  }
  const BODY = mdn.replace(/<!--\s*report-digest:[^\n]*?-->/g, '');
  for (const line of BODY.split(/\r?\n/)) {
    let idx = line.indexOf('回归');
    while (idx >= 0) {
      const window = line.slice(idx, idx + 14);
      if (/\b(pass|fail|incomplete|unknown)\b/.test(window)) {
        problems.push(`report.md 正文出现 regression_layer 的其它取值：「${window.trim()}」`);
      } else if (/(通过|完整|覆盖)/.test(window)) {
        problems.push(`report.md 正文出现断言回归状态的措辞：「${window.trim()}」`);
      }
      idx = line.indexOf('回归', idx + 2);
    }
  }
  emit('AC-018', problems.length === 0, problems.join('; ') || 'regression=null、regression_layer=not_applicable、正文无回归状态断言');
}

// ---------------------------------------------------------------- AC-019 blocked 不计入 passed
{
  const problems = [];
  if (!isObj(rp)) problems.push('report.json 不可读');
  else {
    if (cs.blocked !== counts.blocked) problems.push(`cases.blocked=${JSON.stringify(cs.blocked)}，应为 ${counts.blocked}`);
    if (cs.passed !== counts.passed) problems.push(`cases.passed=${JSON.stringify(cs.passed)}，应为 ${counts.passed}（不含 blocked 用例）`);
    if (vd.overall === 'pass') problems.push('存在 blocked 用例但 verdict.overall=pass');
  }
  emit('AC-019', problems.length === 0, problems.join('; ') || `blocked=${cs.blocked}、passed=${cs.passed}、overall=${JSON.stringify(vd.overall)}`);
}

// ---------------------------------------------------------------- AC-020 证据链不自洽
{
  const problems = [];
  const tev = isObj(rt) && isObj(rt.evidence) ? rt.evidence : {};
  const tv = isObj(rt) && isObj(rt.verdict) ? rt.verdict : {};
  const tf = Array.isArray(tev.findings) ? tev.findings : [];
  if (!isObj(rt)) problems.push('被篡改副本的 report.json 不可读');
  else {
    if (tv.evidence_layer !== 'fail') problems.push(`verdict.evidence_layer=${JSON.stringify(tv.evidence_layer)}，应为 fail`);
    if (tv.overall === 'pass') problems.push('verdict.overall=pass');
    const hit = tf.find((f) => isObj(f) && (f.kind === 'evidence_mismatch' || f.kind === 'fingerprint_mismatch')
      && typeof f.message === 'string' && f.message.trim() !== ''
      && (f.message.includes('TC-002') || f.message.includes('step-1-response.json') || /指纹/.test(f.message)));
    if (!hit) problems.push('evidence.findings 里没有 kind ∈ {evidence_mismatch, fingerprint_mismatch} 且 message 点名被篡改证据路径（或点名「指纹不符」）的条目');
    else {
      const frag = hit.message.includes('step-1-response.json') ? 'step-1-response.json'
        : (hit.message.includes('TC-002') ? 'TC-002' : String(hit.kind));
      if (!mdt.includes(frag)) problems.push(`report.md 里没有出现该条 message 的关键片段「${frag}」`);
    }
  }
  emit('AC-020', problems.length === 0, problems.join('; ') || '篡改副本被证据层抓住');
}

// ---------------------------------------------------------------- AC-021 meta 计数不符
{
  const problems = [];
  if (!isObj(rp)) problems.push('report.json 不可读');
  else {
    const hit = findings.find((f) => isObj(f) && f.kind === 'count_mismatch'
      && typeof f.message === 'string' && f.message.trim() !== ''
      && /6/.test(f.message) && /5/.test(f.message)
      && (f.message.includes('cases_total') || f.message.includes('总数')));
    if (!hit) problems.push('evidence.findings 里没有一条 kind=count_mismatch、message 同时含 6 与 5 且点名 cases_total（或「总数」）的条目');
    else {
      const frag = hit.message.includes('cases_total') ? 'cases_total' : '总数';
      if (!md.includes(frag)) problems.push(`report.md 里没有出现该条 message 的关键片段「${frag}」`);
    }
    if (!(vd.evidence_layer === 'fail' || vd.overall !== 'pass')) {
      problems.push('计数不符既没让 evidence_layer=fail，也没让 overall != pass');
    }
    for (const k of ['total', 'passed', 'failed', 'blocked', 'skipped']) {
      if (cs[k] !== counts[k]) problems.push(`cases.${k}=${JSON.stringify(cs[k])}，重算应为 ${counts[k]}（计数不符时 cases 仍必须按 results.json 重算）`);
    }
  }
  emit('AC-021', problems.length === 0, problems.join('; ') || '计数不符被点名，且 cases 仍按 results.json 重算');
}

// ---------------------------------------------------------------- AC-022 复现信息逐字搬运
{
  const problems = [];
  const src002 = resultsArr.find((r) => isObj(r) && r.case_id === 'TC-002');
  const rep002 = isObj(rp) && Array.isArray(rp.failures)
    ? rp.failures.find((f) => isObj(f) && f.case_id === 'TC-002') : null;
  if (!rep002) problems.push('failures 里没有 TC-002');
  else {
    const a = isObj(rep002.reproduction) ? rep002.reproduction : null;
    const b = isObj(src002) && isObj(src002.reproduction) ? src002.reproduction : null;
    if (!a || !b) problems.push('reproduction 段缺失（报告侧或产物侧）');
    else {
      if (a.command !== b.command) problems.push(`reproduction.command=${JSON.stringify(a.command)}，产物里是 ${JSON.stringify(b.command)}（必须逐字搬运）`);
      if (JSON.stringify(a.steps) !== JSON.stringify(b.steps)) problems.push(`reproduction.steps=${JSON.stringify(a.steps)}，产物里是 ${JSON.stringify(b.steps)}（不得摘要或省略）`);
    }
  }
  if (isObj(src002) && isObj(src002.reproduction) && typeof src002.reproduction.command === 'string'
      && src002.reproduction.command !== '' && !md.includes(src002.reproduction.command)) {
    problems.push('report.md 里没有出现 reproduction.command 的原文');
  }
  emit('AC-022', problems.length === 0, problems.join('; ') || '复现信息逐字搬运且 md 出现 command 原文');
}

// ---------------------------------------------------------------- AC-023 数字与 id 溯源
{
  const problems = [];
  if (!isObj(rp)) problems.push('report.json 不可读');
  else {
    const IDS = new Set(caseIds);
    for (const id of planSelected) IDS.add(id);
    for (const id of planReview) IDS.add(id);
    for (const c of (isObj(plan) && Array.isArray(plan.changes) ? plan.changes : [])) {
      for (const ref of (Array.isArray(c.case_refs) ? c.case_refs : [])) IDS.add(String(ref));
    }
    const CHANGE_IDS = new Set();
    for (const c of (isObj(plan) && Array.isArray(plan.changes) ? plan.changes : [])) {
      if (c.id !== undefined) CHANGE_IDS.add(String(c.id));
      if (c.change_id !== undefined) CHANGE_IDS.add(String(c.change_id));
    }
    for (const u of planUndec) if (u.change_id !== undefined) CHANGE_IDS.add(String(u.change_id));

    // ① json 侧
    for (const f of (Array.isArray(rp.failures) ? rp.failures : [])) {
      const id = String(isObj(f) ? f.case_id : '');
      if (!IDS.has(id)) problems.push(`failures 里出现输入中没有的用例 id ${id}`);
    }
    for (const id of selectedMissing) {
      if (!planSelected.includes(id)) problems.push(`selected_missing 里的 ${id} 不在计划的 selected 里`);
    }
    for (const u of (Array.isArray(reg.undecidable_changes) ? reg.undecidable_changes : [])) {
      const cid = String(isObj(u) ? u.change_id : '');
      if (!CHANGE_IDS.has(cid)) problems.push(`undecidable_changes 里出现输入中没有的变更 id ${cid}`);
    }
    // ② md 侧
    const prefixOf = (id) => { const m = String(id).match(/^[A-Za-z][A-Za-z0-9]*-/); return m ? m[0] : ''; };
    const casePrefixes = new Set([...IDS].map(prefixOf).filter(Boolean));
    const changePrefixes = new Set([...CHANGE_IDS].map(prefixOf).filter(Boolean));
    for (const tok of new Set(md.match(/[A-Za-z][A-Za-z0-9]*-\d+/g) || [])) {
      const prefix = prefixOf(tok);
      if (casePrefixes.has(prefix) && !IDS.has(tok)) problems.push(`report.md 里出现输入中没有的用例 id ${tok}`);
      else if (changePrefixes.has(prefix) && !CHANGE_IDS.has(tok)) problems.push(`report.md 里出现输入中没有的变更 id ${tok}`);
    }
    // ③ 用例层数字
    const ALLOWED = ['total', 'passed', 'failed', 'blocked', 'skipped', 'duration_ms_total'];
    for (const k of Object.keys(cs)) if (!ALLOWED.includes(k)) problems.push(`cases 段出现未声明的键 ${k}`);
    for (const k of ['total', 'passed', 'failed', 'blocked', 'skipped']) {
      if (cs[k] !== counts[k]) problems.push(`cases.${k}=${JSON.stringify(cs[k])}，重算应为 ${counts[k]}`);
    }
    if (cs.duration_ms_total !== durTotal) problems.push(`cases.duration_ms_total=${JSON.stringify(cs.duration_ms_total)}，各条 duration_ms 之和为 ${durTotal}`);
    // ④ 回归层数字逐字段重算
    const executed = new Set(caseIds);
    const expectReg = {
      selected_planned: planSelected.length,
      selected_executed: planSelected.filter((id) => executed.has(id)).length,
      needs_review_planned: planReview.length,
      needs_review_executed: planReview.filter((id) => executed.has(id)).length,
    };
    for (const [k, v] of Object.entries(expectReg)) {
      if (reg[k] !== v) problems.push(`regression.${k}=${JSON.stringify(reg[k])}，按 plan 与 results.json 重算应为 ${v}`);
    }
    for (const [k, v] of Object.entries(reg)) {
      if (typeof v === 'number' && !Object.prototype.hasOwnProperty.call(expectReg, k)) {
        problems.push(`regression 段出现无法逐字段重算的数字字段 ${k}=${v}`);
      }
    }
    const udLen = Array.isArray(reg.undecidable_changes) ? reg.undecidable_changes.length : 0;
    if (udLen !== planUndec.length) problems.push(`regression.undecidable_changes.length=${udLen}，计划里是 ${planUndec.length}`);
    const planImpact = isObj(plan) && isObj(plan.summary) ? plan.summary.impact_complete : undefined;
    if (reg.impact_complete !== planImpact) problems.push(`regression.impact_complete=${JSON.stringify(reg.impact_complete)}，计划里是 ${JSON.stringify(planImpact)}`);
    if (reg.selected_planned !== reg.selected_executed + selectedMissing.length) {
      problems.push(`selected_planned=${JSON.stringify(reg.selected_planned)} ≠ selected_executed=${JSON.stringify(reg.selected_executed)} + selected_missing.length=${selectedMissing.length}`);
    }
    // ⑤ 顶层野生数字
    for (const [k, v] of Object.entries(rp)) {
      if (typeof v === 'number' && k !== 'schema_version') problems.push(`report.json 顶层出现野生数字字段 ${k}=${v}`);
    }
  }
  emit('AC-023', problems.length === 0, problems.join('; ') || 'id 溯源、逐字段重算、顶层枚举全部通过');
}

process.stdout.write(`${out.join('\n')}\n`);
FIXJUDGE

# ---------------------------------------------------------------- 夹具

step "准备夹具（§0：执行产物 + 回归计划；指纹由本脚本自算）"
FX="$WORK/fx"
ART="$FX/ART"
PLAN="$FX/PLAN/regression-plan.json"
mkdir -p "$FX"
FIXINFO="$(node "$WORK/mkfixture.mjs" "$ART" "$PLAN" 2>&1)"
FIX_OK="$(printf '%s' "$FIXINFO" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const o=JSON.parse(s);console.log((o&&typeof o.results_sha256==="string"&&o.results_sha256.length===64)?"1":"0")}catch(e){console.log("0")}})')"
if [ "${FIX_OK:-0}" != "1" ]; then
  echo "夹具生成失败 —— 不可判定，不判通过" >&2
  printf '%s\n' "$FIXINFO" | head -5 >&2
  exit 1
fi
printf '夹具指纹（独立实现自算）: %s\n' "$FIXINFO"

# 被验实现入口
MAKE="$TR/scripts/make-report.mjs"
CHECK="$TR/scripts/check-report.mjs"

# ---------------------------------------------------------------- 跑被验实现（多种前置）

step "跑被验实现（带计划 / 不带计划 / 证据被篡改）"

run_make() { # $1 = artifacts dir, $2 = out dir, $3 = plan file（空 = 不给计划）
  if [ -n "$3" ]; then
    node "$MAKE" --artifacts "$1" --regression-plan "$3" --out-dir "$2" >"$WORK/make.log" 2>&1
  else
    node "$MAKE" --artifacts "$1" --out-dir "$2" >"$WORK/make.log" 2>&1
  fi
  return $?
}

OUT_PLAN="$WORK/out-plan"
OUT_NOPLAN="$WORK/out-noplan"
OUT_TAMPER="$WORK/out-tamper"
mkdir -p "$OUT_PLAN" "$OUT_NOPLAN" "$OUT_TAMPER"

ART_TAMPER="$WORK/art-tamper"
cp -r "$ART" "$ART_TAMPER"
# 篡改 TC-002 的证据文件内容（**不改** results.json 里的 sha256）⇒ 实算 sha 与记录值不符
printf '{\n  "status": 500,\n  "case": "TC-002",\n  "tampered": true\n}\n' \
  > "$ART_TAMPER/evidence/TC-002/step-1-response.json"

RC_PLAN=0;   run_make "$ART"       "$OUT_PLAN"   "$PLAN" || RC_PLAN=$?
RC_NOPLAN=0; run_make "$ART"       "$OUT_NOPLAN" ""      || RC_NOPLAN=$?
RC_TAMPER=0; run_make "$ART_TAMPER" "$OUT_TAMPER" "$PLAN" || RC_TAMPER=$?
printf 'make-report 退出码: 带计划=%s 不带计划=%s 被篡改=%s\n' "$RC_PLAN" "$RC_NOPLAN" "$RC_TAMPER"

# ---------------------------------------------------------------- 报告侧判据（B/C/D/E 组，交给独立复算器）

step "报告侧判据（AC-005 ~ AC-023）"
JUDGE_OUT="$WORK/judge.out"
if [ "$RC_PLAN" -ne 0 ] || [ "$RC_NOPLAN" -ne 0 ] || [ "$RC_TAMPER" -ne 0 ]; then
  printf '被验实现跑报告失败（rc=%s/%s/%s）—— 报告侧判据不可判定\n' "$RC_PLAN" "$RC_NOPLAN" "$RC_TAMPER"
  for id in AC-005 AC-006 AC-007 AC-008 AC-010 AC-011 AC-012 AC-013 AC-014 AC-015 \
            AC-016 AC-017 AC-018 AC-019 AC-020 AC-021 AC-022 AC-023; do
    undec "$id 报告未产出（make-report 退出码非 0）" "$id"
  done
else
  node "$WORK/judge.mjs" "$ART" "$PLAN" "$OUT_PLAN" "$OUT_NOPLAN" "$OUT_TAMPER" "$PKG" \
    > "$JUDGE_OUT" 2>"$WORK/judge.err"
  while IFS=$'\t' read -r jid jres jmsg; do
    [ -n "$jid" ] || continue
    if [ "$jres" = "PASS" ]; then
      ok "$jid 报告侧判据" "$jid"
    else
      bad "$jid 报告侧判据" "$jid"
      printf '  · %s\n' "$jmsg" >> "$RES_DIR/$jid.res"
    fi
  done < "$JUDGE_OUT"
  if [ -s "$WORK/judge.err" ]; then
    printf '  · judge stderr: %s\n' "$(head -3 "$WORK/judge.err" | tr '\n' ' ')"
  fi
fi

# ---------------------------------------------------------------- A 组（交付物形状）

step "AC-001 test-report skill 存在且结构合法"
A1="AC-001"
A1_PROBLEMS=""
if [ ! -d "$TR" ]; then
  A1_PROBLEMS="缺目录 skills/test-report/"
else
  for f in "SKILL.md" "skill-meta.json" "references/report-schema.md" "references/report-rules.md" \
           "scripts/make-report.mjs" "scripts/check-report.mjs"; do
    [ -s "$TR/$f" ] || A1_PROBLEMS="$A1_PROBLEMS [缺或空: $f]"
  done
  NAME_OK=0; DESC_OK=0
  if [ -s "$TR/SKILL.md" ]; then
    FM_NAME="$(node "$WORK/frontmatter.mjs" "$TR/SKILL.md" name 2>/dev/null)"
    FM_DESC="$(node "$WORK/frontmatter.mjs" "$TR/SKILL.md" description 2>/dev/null)"
    FM_NAME_VAL="$(node -e 'try{const o=JSON.parse(process.argv[1]);console.log(String(o.value||""))}catch(e){console.log("")}' "$FM_NAME")"
    [ "$FM_NAME_VAL" = "test-report" ] && NAME_OK=1
    DESC_EMPTY="$(node -e 'try{const o=JSON.parse(process.argv[1]);console.log(o.found&&!o.empty?"0":"1")}catch(e){console.log("1")}' "$FM_DESC")"
    [ "$DESC_EMPTY" = "0" ] && DESC_OK=1
  fi
  CHK_OK=0
  for f in "scripts/make-report.mjs" "scripts/check-report.mjs"; do
    if [ -s "$TR/$f" ] && node --check "$TR/$f" >/dev/null 2>&1; then
      head -1 "$TR/$f" 2>/dev/null | grep -q '^#!.*node' && CHK_OK=$((CHK_OK+1))
      [ -x "$TR/$f" ] && CHK_OK=$((CHK_OK+1))
    fi
  done
  if [ -n "$A1_PROBLEMS" ]; then
    :
  elif [ "$NAME_OK" -ne 1 ]; then
    A1_PROBLEMS="SKILL.md frontmatter 的 name 不是 test-report"
  elif [ "$DESC_OK" -ne 1 ]; then
    A1_PROBLEMS="SKILL.md frontmatter 的 description 为空值"
  elif [ "$CHK_OK" -lt 2 ]; then
    A1_PROBLEMS="两个脚本的首行不是 '#!' 且不可执行，或 node --check 不通过"
  fi
fi
if [ -z "$A1_PROBLEMS" ]; then ok "$A1" "$A1"; else bad "$A1" "$A1"; printf '  · %s\n' "$A1_PROBLEMS" >> "$RES_DIR/$A1.res"; fi

step "AC-002 每个 skill 都声明版本与依赖（skill-meta.json）"
A2="AC-002"
A2_PROBLEMS=""
SKILL_DIRS=""
for d in "$PKG"/skills/*/; do
  [ -d "$d" ] || continue
  [ -f "$d/SKILL.md" ] || continue
  SKILL_DIRS="$SKILL_DIRS $d"
done
TR_REQUIRES_OK=0
for d in $SKILL_DIRS; do
  NAME="$(basename "$d")"
  META="$d/skill-meta.json"
  if [ ! -s "$META" ]; then A2_PROBLEMS="$A2_PROBLEMS [$NAME 缺 skill-meta.json]"; continue; fi
  RES="$(node -e '
const fs=require("fs");
let o=null; try{o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));}catch(e){console.log("PARSE_ERR");process.exit(0);}
if(!o||typeof o!=="object"||Array.isArray(o)){console.log("BAD_SHAPE");process.exit(0);}
const dir=process.argv[2];
const problems=[];
if(o.name!==dir)problems.push("name="+o.name);
if(typeof o.version!=="string"||!/^[0-9]+\.[0-9]+\.[0-9]+$/.test(o.version))problems.push("version="+o.version);
if(!o.requires||typeof o.requires!=="object"||Array.isArray(o.requires))problems.push("requires 非法");
else for(const [k,v] of Object.entries(o.requires)) if(typeof v!=="string"||!/^(>=)?[0-9]+\.[0-9]+\.[0-9]+$/.test(v)) problems.push("requires."+k+"="+v);
let fm=""; try{fm=fs.readFileSync(process.argv[3]+"/SKILL.md","utf8").slice(0,2000);}catch(e){}
const m=fm.match(/^---\s*$[\s\S]*?^name:\s*(\S+)\s*$/m);
const skillName=m?m[1]:null;
if(skillName!==o.name)problems.push("SKILL.md name="+skillName+" vs meta.name="+o.name);
console.log(JSON.stringify({problems,requires:o.requires||{}}));
' "$META" "$NAME" "$d" 2>/dev/null)"
  P="$(node -e 'try{const o=JSON.parse(process.argv[1]);console.log((o.problems||[]).join(";"))}catch(e){console.log("PARSE_ERR")}' "$RES" 2>/dev/null)"
  REQ="$(node -e 'try{const o=JSON.parse(process.argv[1]);console.log(Object.keys(o.requires||{}).join(","))}catch(e){console.log("")}' "$RES" 2>/dev/null)"
  [ -n "$P" ] && A2_PROBLEMS="$A2_PROBLEMS [$NAME $P]"
  if [ "$NAME" = "test-report" ]; then
    case ",$REQ," in *,test-execute,*) TR_REQUIRES_OK=1 ;; esac
  fi
done
if [ -z "$SKILL_DIRS" ]; then
  A2_PROBLEMS="被验包里没有任何含 SKILL.md 的 skill 目录"
elif [ "$TR_REQUIRES_OK" -ne 1 ]; then
  A2_PROBLEMS="$A2_PROBLEMS [test-report 的 requires 里没有 test-execute（它消费执行产物的格式，是硬依赖）]"
fi
if [ -z "$A2_PROBLEMS" ]; then ok "$A2" "$A2"; else bad "$A2" "$A2"; printf '  · %s\n' "$A2_PROBLEMS" >> "$RES_DIR/$A2.res"; fi

step "AC-003 README 的 skill 清单与实际目录一致"
A3="AC-003"
A3_PROBLEMS=""
if [ ! -s "$README" ]; then
  A3_PROBLEMS="缺 README.md 或为空"
else
  README_NAMES="$(node "$WORK/readme-skills.mjs" "$README" 2>/dev/null)"
  DIR_NAMES="$(for d in $SKILL_DIRS; do basename "$d"; done | sort | tr '\n' ' ' | sed 's/ $//')"
  R_SET="$(printf '%s' "$README_NAMES" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).sort().join(" "))}catch(e){console.log("__PARSE_ERR__")}})')"
  if [ "$R_SET" = "__PARSE_ERR__" ]; then
    A3_PROBLEMS="README 抽取失败"
  elif [ "$R_SET" != "$DIR_NAMES" ]; then
    A3_PROBLEMS="README 的 skill 清单集合=[$R_SET] 与实际目录集合=[$DIR_NAMES] 不相等"
  else
    case " $R_SET " in *" test-report "*) ;; *) A3_PROBLEMS="README 的清单里没有 test-report" ;; esac
  fi
fi
if [ -z "$A3_PROBLEMS" ]; then ok "$A3" "$A3"; else bad "$A3" "$A3"; printf '  · %s\n' "$A3_PROBLEMS" >> "$RES_DIR/$A3.res"; fi

step "AC-004 新产物不得打破既有目录契约"
A4="AC-004"
VL="$TCD/scripts/verify-layout.mjs"
A4_PROBLEMS=""
if [ ! -f "$VL" ]; then
  A4_PROBLEMS="缺 $VL（前置条件不满足）"
else
  PROJ="$WORK/proj"
  mkdir -p "$PROJ/test-assets/environments" "$PROJ/test-assets/suites/REQ-001-coupon" \
           "$PROJ/test-assets/cycles/R1-REQ-001" "$PROJ/test-assets/cycles/R2-DEMO"
  printf '# 测试资产\n' > "$PROJ/test-assets/README.md"
  cat > "$PROJ/test-assets/environments/_schema.json" <<'EOF'
{ "$schema":"https://json-schema.org/draft/2020-12/schema","title":"测试环境配置","type":"object",
  "required":["name","base_url","timeout_ms","credentials"],"additionalProperties":false,
  "properties":{
    "name":{"type":"string"},"base_url":{"type":"string"},"timeout_ms":{"type":"integer"},
    "retries":{"type":"integer"},
    "credentials":{"type":"object","required":["username_env"],"additionalProperties":false,
      "properties":{"username_env":{"type":"string"},"password_env":{"type":"string"}}},
    "headers":{"type":"object"},"verify_tls":{"type":"boolean"},
    "data_fixtures":{"type":"array","items":{"type":"object","required":["path"],
      "properties":{"path":{"type":"string"},"cleanup":{"type":"boolean"}}}}}}
EOF
  cat > "$PROJ/test-assets/environments/local.json" <<'EOF'
{ "name":"local","base_url":"http://127.0.0.1:8080","timeout_ms":5000,"retries":0,
  "credentials":{"username_env":"LOCAL_USER","password_env":"LOCAL_PASS"},"verify_tls":false }
EOF
  cat > "$PROJ/test-assets/suites/REQ-001-coupon/cases.json" <<'EOF'
{ "requirements":[], "cases":[] }
EOF
  cat > "$PROJ/test-assets/suites/REQ-001-coupon/suite.json" <<'EOF'
{ "suite":"REQ-001-coupon","requirement":"REQ-001","scope":"functional","environment":"local",
  "cases_file":"cases.json","executor":"api",
  "report":{"format":["html"],"output_dir":".test-artifacts/REQ-001"} }
EOF
  cat > "$PROJ/test-assets/cycles/R1-REQ-001/cycle.json" <<'EOF'
{ "cycle_id":"R1-REQ-001","round":"R1","round_type":"new-requirement","requirement":"REQ-001",
  "scopes":["functional"],"scopes_skipped":[],"status":"in_progress",
  "stages":{"clarify":{"status":"done"},"design":{"status":"in_progress"}},
  "history":[{"at":"2026-11-11T18:00:00+08:00","from":"planned","to":"in_progress","by":"seed"}] }
EOF
  cat > "$PROJ/test-assets/cycles/R2-DEMO/cycle.json" <<'EOF'
{ "cycle_id":"R2-DEMO","round":"R2","round_type":"regression","requirement":"REQ-001",
  "scopes":["functional"],"scopes_skipped":[],"status":"in_progress",
  "stages":{"clarify":{"status":"done"},"design":{"status":"in_progress"}},
  "history":[{"at":"2026-11-11T18:00:00+08:00","from":"planned","to":"in_progress","by":"seed"}] }
EOF
  cat > "$PROJ/test-assets/cycles/index.json" <<'EOF'
{ "cycles":[{"id":"R1-REQ-001","round":"R1","status":"in_progress","cases_total":0,"cases_passed":0,"bugs_found":0},
            {"id":"R2-DEMO","round":"R2","status":"in_progress","cases_total":0,"cases_passed":0,"bugs_found":0}] }
EOF
  printf '.test-artifacts/\n' > "$PROJ/.gitignore"
  # 新产物放在**轮次目录内**（与 cycle.json 同级）
  mkdir -p "$PROJ/test-assets/cycles/R2-DEMO/report"
  printf '{"schema_version":1,"cycle_id":"R2-DEMO"}\n' > "$PROJ/test-assets/cycles/R2-DEMO/report/report.json"
  printf '# 报告\n' > "$PROJ/test-assets/cycles/R2-DEMO/report/report.md"
  VL_OUT="$(node "$VL" "$PROJ" 2>&1)"; VL_RC=$?
  VL_FAILS="$(printf '%s\n' "$VL_OUT" | grep -c '^\[FAIL\]' || true)"
  case "$VL_FAILS" in ''|*[!0-9]*) VL_FAILS=99 ;; esac
  # 错误位置探针：必须给出明确结论（二选一），不得两种结论都不给
  A4_CONC="不可判定：错误位置探针没布置成功"
  PROJ2="$WORK/proj-wrongpos"
  cp -r "$PROJ" "$PROJ2" 2>/dev/null
  mkdir -p "$PROJ2/test-assets/report"
  mv "$PROJ2/test-assets/cycles/R2-DEMO/report/report.json" "$PROJ2/test-assets/report/report.json" 2>/dev/null
  mv "$PROJ2/test-assets/cycles/R2-DEMO/report/report.md" "$PROJ2/test-assets/report/report.md" 2>/dev/null
  if [ -f "$PROJ2/test-assets/report/report.json" ]; then
    VL2_OUT="$(node "$VL" "$PROJ2" 2>&1)"; VL2_RC=$?
    VL2_FAILS="$(printf '%s\n' "$VL2_OUT" | grep -c '^\[FAIL\]' || true)"
    case "$VL2_FAILS" in ''|*[!0-9]*) VL2_FAILS=99 ;; esac
    if [ "$VL2_RC" -eq 0 ] && [ "$VL2_FAILS" -eq 0 ]; then
      A4_CONC="位置不受约束（校验器不查该位置 → 本条判绿，不得要求实现去管它）"
    else
      A4_CONC="位置受约束（校验器判红：rc=$VL2_RC FAIL=$VL2_FAILS → 本条判红）"
    fi
  fi
  printf '  · AC-004 错误位置探针结论: %s\n' "$A4_CONC"
  if [ "$VL_RC" -eq 0 ] && [ "$VL_FAILS" -eq 0 ]; then
    case "$A4_CONC" in
      位置不受约束*) ;;
      *) A4_PROBLEMS="$A4_PROBLEMS [$A4_CONC]" ;;
    esac
  else
    A4_PROBLEMS="$A4_PROBLEMS [verify-layout 退出码=$VL_RC FAIL 级问题数=$VL_FAILS 输出=$(printf '%s' "$VL_OUT" | grep '^\[FAIL\]' | head -3 | tr '\n' ' ')]"
  fi
fi
if [ -z "$A4_PROBLEMS" ]; then ok "$A4" "$A4"; else bad "$A4" "$A4"; printf '  · %s\n' "$A4_PROBLEMS" >> "$RES_DIR/$A4.res"; fi

# ---------------------------------------------------------------- AC-009（非法输入）

step "AC-009 输入缺失或非法时必须报错退出，不得产出半份报告"
A9="AC-009"
A9_PROBLEMS=""
BAD_ART="$WORK/art-bad"
cp -r "$ART" "$BAD_ART"
printf '{ not json' > "$BAD_ART/meta.json"
BAD_ART2="$WORK/art-bad2"
cp -r "$ART" "$BAD_ART2"
printf '{"not":"an array"}\n' > "$BAD_ART2/results.json"

check_bad_input() { # $1 = 描述, $2 = artifacts, $3 = out dir
  local desc="$1" art="$2" out="$3"
  mkdir -p "$out"
  node "$MAKE" --artifacts "$art" --out-dir "$out" >"$WORK/bad.log" 2>&1
  local rc=$?
  local msg; msg="$(head -3 "$WORK/bad.log" | tr '\n' ' ')"
  [ "$rc" -ne 0 ] || A9_PROBLEMS="$A9_PROBLEMS [$desc: 退出码=0，期望非 0]"
  if [ -s "$out/report.json" ] || [ -s "$out/report.md" ]; then
    A9_PROBLEMS="$A9_PROBLEMS [$desc: 留下了半份报告]"
  fi
  printf '  · %s → rc=%s %s\n' "$desc" "$rc" "$msg"
}
if [ ! -f "$MAKE" ]; then
  A9_PROBLEMS="缺 scripts/make-report.mjs"
else
  check_bad_input "产物目录不存在" "$WORK/no-such-dir" "$WORK/out-bad1"
  check_bad_input "meta.json 非法 JSON" "$BAD_ART" "$WORK/out-bad2"
  check_bad_input "results.json 根节点非数组" "$BAD_ART2" "$WORK/out-bad3"
fi
if [ -z "$A9_PROBLEMS" ]; then ok "$A9" "$A9"; else bad "$A9" "$A9"; printf '  · %s\n' "$A9_PROBLEMS" >> "$RES_DIR/$A9.res"; fi

# ---------------------------------------------------------------- F 组（幂等 / 写入权）

step "AC-024 同一输入两次出报告必须逐字相同"
A24="AC-024"
A24_PROBLEMS=""
if [ ! -s "$OUT_PLAN/report.json" ] || [ ! -s "$OUT_PLAN/report.md" ]; then
  A24_PROBLEMS="带计划的报告没产出"
else
  ID1="$WORK/out-idem1"; ID2="$WORK/out-idem2"
  rm -rf "$ID1" "$ID2" 2>/dev/null || true
  mkdir -p "$ID1" "$ID2"
  run_make "$ART" "$ID1" "$PLAN"
  run_make "$ART" "$ID2" "$PLAN"
  if [ ! -s "$ID1/report.json" ] || [ ! -s "$ID2/report.json" ]; then
    A24_PROBLEMS="两次跑没有都产出报告"
  else
    TS1="$(node -e 'try{console.log(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).generated_at||""))}catch(e){console.log("")}' "$ID1/report.json")"
    TS2="$(node -e 'try{console.log(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).generated_at||""))}catch(e){console.log("")}' "$ID2/report.json")"
    J1="$(node -e '
const fs=require("fs");
const o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
delete o.generated_at;
process.stdout.write(JSON.stringify(o));
' "$ID1/report.json")"
    J2="$(node -e '
const fs=require("fs");
const o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
delete o.generated_at;
process.stdout.write(JSON.stringify(o));
' "$ID2/report.json")"
    if [ "$J1" != "$J2" ]; then
      A24_PROBLEMS="两份 report.json 除 generated_at 外不相同"
    fi
    M1="$(node -e '
const fs=require("fs");
let t=fs.readFileSync(process.argv[1],"utf8");
if(process.argv[2]) t=t.split(process.argv[2]).join("<TS>");
process.stdout.write(t);
' "$ID1/report.md" "$TS1")"
    M2="$(node -e '
const fs=require("fs");
let t=fs.readFileSync(process.argv[1],"utf8");
if(process.argv[2]) t=t.split(process.argv[2]).join("<TS>");
process.stdout.write(t);
' "$ID2/report.md" "$TS2")"
    if [ "$M1" != "$M2" ]; then
      A24_PROBLEMS="两份 report.md 除 generated_at 外不相同"
    fi
  fi
fi
if [ -z "$A24_PROBLEMS" ]; then ok "$A24" "$A24"; else bad "$A24" "$A24"; printf '  · %s\n' "$A24_PROBLEMS" >> "$RES_DIR/$A24.res"; fi

step "AC-025 输出路径约定 + 只写自己的目录"
A25="AC-025"
A25_PROBLEMS=""
ART_DEF="$WORK/art-default"
cp -r "$ART" "$ART_DEF"
BEFORE_DEF="$(node "$WORK/fingerprint.mjs" 2>/dev/null; node -e '
const fs=require("fs");const path=require("path");const crypto=require("crypto");
const root=process.argv[1];const out=[];
const walk=(d)=>{for(const e of fs.readdirSync(d,{withFileTypes:true})){const f=path.join(d,e.name);
 if(e.isDirectory()){ if(e.name==="report") continue; walk(f);} else out.push(path.relative(root,f)+" "+crypto.createHash("sha256").update(fs.readFileSync(f)).digest("hex"));}};
walk(root);out.sort();process.stdout.write(out.join("\n"));
' "$ART_DEF")"
run_make "$ART_DEF" "" "$PLAN" 2>/dev/null
node "$MAKE" --artifacts "$ART_DEF" --regression-plan "$PLAN" >"$WORK/def.log" 2>&1
DEF_RC=$?
if [ ! -s "$ART_DEF/report/report.json" ] || [ ! -s "$ART_DEF/report/report.md" ]; then
  A25_PROBLEMS="$A25_PROBLEMS [默认输出目录下没有 report/report.json 与 report/report.md（rc=$DEF_RC）]"
fi
AFTER_DEF="$(node -e '
const fs=require("fs");const path=require("path");const crypto=require("crypto");
const root=process.argv[1];const out=[];
const walk=(d)=>{for(const e of fs.readdirSync(d,{withFileTypes:true})){const f=path.join(d,e.name);
 if(e.isDirectory()){ if(e.name==="report") continue; walk(f);} else out.push(path.relative(root,f)+" "+crypto.createHash("sha256").update(fs.readFileSync(f)).digest("hex"));}};
walk(root);out.sort();process.stdout.write(out.join("\n"));
' "$ART_DEF")"
[ "$BEFORE_DEF" = "$AFTER_DEF" ] || A25_PROBLEMS="$A25_PROBLEMS [输入产物目录里除 report/ 外有文件被改动]"

ART_OUT="$WORK/art-outside"
cp -r "$ART" "$ART_OUT"
BEFORE_OUT="$(node -e '
const fs=require("fs");const path=require("path");const crypto=require("crypto");
const root=process.argv[1];const out=[];
const walk=(d)=>{for(const e of fs.readdirSync(d,{withFileTypes:true})){const f=path.join(d,e.name);
 if(e.isDirectory()){ if(e.name==="report") continue; walk(f);} else out.push(path.relative(root,f)+" "+crypto.createHash("sha256").update(fs.readFileSync(f)).digest("hex"));}};
walk(root);out.sort();process.stdout.write(out.join("\n"));
' "$ART_OUT")"
OUT_EXTRA="$WORK/out-extra"
mkdir -p "$OUT_EXTRA"
run_make "$ART_OUT" "$OUT_EXTRA" "$PLAN"
if [ ! -s "$OUT_EXTRA/report.json" ] || [ ! -s "$OUT_EXTRA/report.md" ]; then
  A25_PROBLEMS="$A25_PROBLEMS [--out-dir 指定的目录里没有报告]"
fi
AFTER_OUT="$(node -e '
const fs=require("fs");const path=require("path");const crypto=require("crypto");
const root=process.argv[1];const out=[];
const walk=(d)=>{for(const e of fs.readdirSync(d,{withFileTypes:true})){const f=path.join(d,e.name);
 if(e.isDirectory()){ if(e.name==="report") continue; walk(f);} else out.push(path.relative(root,f)+" "+crypto.createHash("sha256").update(fs.readFileSync(f)).digest("hex"));}};
walk(root);out.sort();process.stdout.write(out.join("\n"));
' "$ART_OUT")"
[ "$BEFORE_OUT" = "$AFTER_OUT" ] || A25_PROBLEMS="$A25_PROBLEMS [输出目录在产物目录之外时，输入产物目录没有逐字未变]"
if [ -z "$A25_PROBLEMS" ]; then ok "$A25" "$A25"; else bad "$A25" "$A25"; printf '  · %s\n' "$A25_PROBLEMS" >> "$RES_DIR/$A25.res"; fi

step "AC-026 零第三方依赖 + 可移植（不联网）"
A26="AC-026"
A26_PROBLEMS=""
if [ ! -d "$TR" ]; then
  A26_PROBLEMS="缺 skills/test-report/（前置条件不满足）"
else
  SCAN="$(node "$WORK/scan-deps.mjs" "$TR" 2>/dev/null)"
  TP="$(node -e 'try{console.log(JSON.parse(process.argv[1]).thirdParty.length)}catch(e){console.log(-1)}' "$SCAN" 2>/dev/null)"
  NET="$(node -e 'try{console.log(JSON.parse(process.argv[1]).network.length)}catch(e){console.log(-1)}' "$SCAN" 2>/dev/null)"
  OUTS="$(node -e 'try{console.log(JSON.parse(process.argv[1]).outside.length)}catch(e){console.log(-1)}' "$SCAN" 2>/dev/null)"
  TPD="$(node -e 'try{console.log(JSON.parse(process.argv[1]).thirdParty.slice(0,3).join(" ; "))}catch(e){console.log("解析失败")}' "$SCAN" 2>/dev/null)"
  NETD="$(node -e 'try{console.log(JSON.parse(process.argv[1]).network.slice(0,3).join(" ; "))}catch(e){console.log("解析失败")}' "$SCAN" 2>/dev/null)"
  OUTD="$(node -e 'try{console.log(JSON.parse(process.argv[1]).outside.slice(0,3).join(" ; "))}catch(e){console.log("解析失败")}' "$SCAN" 2>/dev/null)"
  [ "${TP:-1}" -eq 0 ] || A26_PROBLEMS="$A26_PROBLEMS [非 node: 内置的 import/require: $TPD]"
  [ "${NET:-1}" -eq 0 ] || A26_PROBLEMS="$A26_PROBLEMS [网络调用: $NETD]"
  [ "${OUTS:-1}" -eq 0 ] || A26_PROBLEMS="$A26_PROBLEMS [相对 import 指向了本 skill 之外: $OUTD]"
fi
if [ -z "$A26_PROBLEMS" ]; then ok "$A26" "$A26"; else bad "$A26" "$A26"; printf '  · %s\n' "$A26_PROBLEMS" >> "$RES_DIR/$A26.res"; fi

step "AC-027 不得修改输入产物的任何既有文件"
A27="AC-027"
A27_PROBLEMS=""
ART_WRITE="$WORK/art-write"
cp -r "$ART" "$ART_WRITE"
FP_BEFORE="$(node "$WORK/fingerprint.mjs" "$ART_WRITE" 2>/dev/null)"
run_make "$ART_WRITE" "$WORK/out-write" "$PLAN"
FP_AFTER="$(node "$WORK/fingerprint.mjs" "$ART_WRITE" 2>/dev/null)"
if [ -z "$FP_BEFORE" ] || [ "$FP_BEFORE" != "$FP_AFTER" ]; then
  CH="$(diff <(printf '%s\n' "$FP_BEFORE") <(printf '%s\n' "$FP_AFTER") 2>/dev/null | head -6 | tr '\n' ' ')"
  A27_PROBLEMS="输入产物目录下的文件被改动: $CH"
fi
if [ -z "$A27_PROBLEMS" ]; then ok "$A27" "$A27"; else bad "$A27" "$A27"; printf '  · %s\n' "$A27_PROBLEMS" >> "$RES_DIR/$A27.res"; fi

# ---------------------------------------------------------------- H 组（追溯 / 组合门）

step "AC-028 交付侧记账必须与实际一致"
A28="AC-028"
A28_PROBLEMS=""
TR_META="$FEATURE_META/test-report"
for f in status.md traceability.md verification-report.md manifest.json; do
  [ -s "$TR_META/$f" ] || A28_PROBLEMS="$A28_PROBLEMS [缺 feature-meta/test-report/$f 或为空]"
done
# ⑤ feature-meta/test-report/manifest.json 的 req 必须是 REQ-010
if [ -s "$TR_META/manifest.json" ]; then
  MY_REQ="$(node -e 'try{console.log(String(require(process.argv[1]).req||""))}catch(e){console.log("__ERR__")}' "$TR_META/manifest.json" 2>/dev/null)"
  [ "$MY_REQ" = "REQ-010" ] || A28_PROBLEMS="$A28_PROBLEMS [feature-meta/test-report/manifest.json 的 req=$MY_REQ，要求 REQ-010]"
fi
# 根目录四件套与 feature-meta/regression-plan/ 子目录必须**未被改写**
#   （判据写的是「逐字未变」；本门按**内容标识**核验：req 编号 / 判据条数 / 追溯矩阵编号集合）
ROOT_MANIFEST="$FEATURE_META/manifest.json"
if [ ! -s "$ROOT_MANIFEST" ]; then
  A28_PROBLEMS="$A28_PROBLEMS [缺 feature-meta/manifest.json]"
else
  ROOT_REQ="$(node -e 'try{console.log(String(require(process.argv[1]).req||""))}catch(e){console.log("__ERR__")}' "$ROOT_MANIFEST" 2>/dev/null)"
  [ "$ROOT_REQ" = "REQ-006" ] || A28_PROBLEMS="$A28_PROBLEMS [feature-meta/manifest.json 的 req=$ROOT_REQ（REQ-006 的既有追溯件不得被改写）]"
fi
RP_META="$FEATURE_META/regression-plan"
for f in status.md traceability.md verification-report.md manifest.json; do
  [ -s "$RP_META/$f" ] || A28_PROBLEMS="$A28_PROBLEMS [缺 feature-meta/regression-plan/$f —— REQ-011 的既有追溯件不得被改写]"
done
if [ -s "$RP_META/manifest.json" ]; then
  RP_REQ="$(node -e 'try{console.log(String(require(process.argv[1]).req||""))}catch(e){console.log("__ERR__")}' "$RP_META/manifest.json" 2>/dev/null)"
  [ "$RP_REQ" = "REQ-011" ] || A28_PROBLEMS="$A28_PROBLEMS [feature-meta/regression-plan/manifest.json 的 req=$RP_REQ（REQ-011 的既有追溯件不得被改写）]"
fi
# 判据条数（动态）与决策号集合（动态）
DEC_SET="$(grep -oE '^\| D[0-9]+' "$DECISIONS" 2>/dev/null | grep -oE 'D[0-9]+' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
DEC_MIN="$(printf '%s' "$DEC_SET" | tr ' ' '\n' | grep -E '^D[0-9]+$' | sed 's/D//' | sort -n | head -1)"
DEC_MAX="$(printf '%s' "$DEC_SET" | tr ' ' '\n' | grep -E '^D[0-9]+$' | sed 's/D//' | sort -n | tail -1)"
EXPECT_IDS="$(grep -oE '^### (AC-[0-9]+)' "$ACCEPTANCE" 2>/dev/null | grep -oE 'AC-[0-9]+' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
EXPECT_ROWS="$(printf '%s' "$EXPECT_IDS" | tr ' ' '\n' | grep -cE '^AC-[0-9]+$')"
if [ -s "$TR_META/traceability.md" ]; then
  MATRIX_IDS="$(grep -E '^\|[[:space:]]*AC-[0-9]+' "$TR_META/traceability.md" 2>/dev/null | grep -oE 'AC-[0-9]+' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  MATRIX_ROWS="$(grep -cE '^\|[[:space:]]*AC-[0-9]+' "$TR_META/traceability.md" 2>/dev/null || true)"
  case "$MATRIX_ROWS" in ''|*[!0-9]*) MATRIX_ROWS=0 ;; esac
  [ "$MATRIX_ROWS" -eq "$EXPECT_ROWS" ] || A28_PROBLEMS="$A28_PROBLEMS [追溯矩阵行数=$MATRIX_ROWS，要求 $EXPECT_ROWS 行（== acceptance.md 的实际判据条数）]"
  [ "$MATRIX_IDS" = "$EXPECT_IDS" ] || A28_PROBLEMS="$A28_PROBLEMS [追溯矩阵的 AC 编号集合=[$MATRIX_IDS]，要求恰好 [$EXPECT_IDS]]"
fi
# 三份 md 各恰一处「N 条判据」，且 N == 实际条数
for f in status.md traceability.md verification-report.md; do
  if [ ! -s "$TR_META/$f" ]; then continue; fi
  OCC="$(grep -oE '[0-9]+[[:space:]]*条判据' "$TR_META/$f" 2>/dev/null | wc -l | tr -d ' ')"
  NUM="$(grep -oE '[0-9]+[[:space:]]*条判据' "$TR_META/$f" 2>/dev/null | head -1 | grep -oE '[0-9]+' | head -1)"
  [ "$OCC" = "1" ] || A28_PROBLEMS="$A28_PROBLEMS [$f 里「N 条判据」出现 $OCC 次，要求恰好 1 次]"
  [ "$NUM" = "$AC_COUNT" ] || A28_PROBLEMS="$A28_PROBLEMS [$f 的条数声明=$NUM，与 acceptance.md 的实际条数 $AC_COUNT 不符]"
  MDS="$(node -e '
const fs=require("fs");
const text=fs.readFileSync(process.argv[1],"utf8");
const set=new Set();
for(const m of text.matchAll(/D(\d+)\s*[~～\-–]\s*D?(\d+)/g)){
  const a=Number(m[1]),b=Number(m[2]);
  for(let i=Math.min(a,b);i<=Math.max(a,b);i++) set.add("D"+i);
}
for(const m of text.matchAll(/\bD(\d+)\b/g)) set.add("D"+m[1]);
console.log([...set].sort((x,y)=>Number(x.slice(1))-Number(y.slice(1))).join(" "));
' "$TR_META/$f" 2>/dev/null)"
  [ "$MDS" = "$DEC_SET" ] || A28_PROBLEMS="$A28_PROBLEMS [$f 的决策号集合=[$MDS]，与 decisions.md 的实际集合=[$DEC_SET] 不符]"
done
if [ -z "$A28_PROBLEMS" ]; then ok "$A28" "$A28"; else bad "$A28" "$A28"; printf '  · %s\n' "$A28_PROBLEMS" >> "$RES_DIR/$A28.res"; fi

step "AC-029 组合门必须覆盖第 5 个 skill"
A29="AC-029"
A29_PROBLEMS=""
VERIFY_ROOT="$WORK/verifyroot"
mkdir -p "$VERIFY_ROOT"
if [ ! -f "$INSTALLER" ]; then
  A29_PROBLEMS="缺 bin/test-agent-skills.mjs"
else
  VERIFY_OUT="$(node "$INSTALLER" verify --root "$VERIFY_ROOT" 2>&1)"; VERIFY_RC=$?
  [ "$VERIFY_RC" -ne 0 ] && A29_PROBLEMS="$A29_PROBLEMS [verify 退出码=$VERIFY_RC out=$(printf '%s' "$VERIFY_OUT" | head -3 | tr '\n' ' ')]"
  # ① 临时根装齐全部 skill（含 test-report）
  INSTALLED="$(ls -1 "$VERIFY_ROOT/skills" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
  EXPECT_SKILLS="$(for d in $SKILL_DIRS; do basename "$d"; done | sort | tr '\n' ' ' | sed 's/ $//')"
  [ "$INSTALLED" = "$EXPECT_SKILLS" ] || A29_PROBLEMS="$A29_PROBLEMS [临时根装的是 [$INSTALLED]，被验包的 skill 是 [$EXPECT_SKILLS]]"
  case " $INSTALLED " in *" test-report "*) ;; *) A29_PROBLEMS="$A29_PROBLEMS [临时根没有装 test-report]" ;; esac
  INST_COUNT="$(printf '%s' "$INSTALLED" | tr ' ' '\n' | grep -cE '^[a-z]' || true)"
  [ "${INST_COUNT:-0}" -ge 5 ] || A29_PROBLEMS="$A29_PROBLEMS [临时根只装了 ${INST_COUNT:-0} 个 skill，要求至少 5 个（第 5 个 skill 必须是 test-report）]"
  # ② 依赖图校验通过
  printf '%s' "$VERIFY_OUT" | grep -q '依赖图校验通过' || A29_PROBLEMS="$A29_PROBLEMS [输出里没有「依赖图校验通过」]"
  printf '%s' "$VERIFY_OUT" | grep -q '\[version\]' && A29_PROBLEMS="$A29_PROBLEMS [依赖图报了版本问题]"
  # ③ 跨 skill 组合场景实跑（输出里有成功场景，且临时根里真的跑出了产物）
  SCEN="$(printf '%s' "$VERIFY_OUT" | grep -c '组合场景' || true)"
  [ "${SCEN:-0}" -ge 1 ] || A29_PROBLEMS="$A29_PROBLEMS [输出里没有组合场景的实跑记录]"
  printf '%s' "$VERIFY_OUT" | grep -q '组合场景失败' && A29_PROBLEMS="$A29_PROBLEMS [组合场景失败]"
  # ③ 之补（OI-7 裁定）：至少有一条组合场景**真的经过 test-report** ——「装了」不等于「用上了」。
  #   机械口径（三条同时成立才算数）：
  #     ① 组合场景的输出行里点名 test-report / make-report；
  #     ② 该场景**真的产出了报告产物**（临时根里出现非空的 report.json），或直接断言了报告里的结论；
  #     ③ 组合门对它的断言是**实跑的**（断言了 verdict/overall 的值），而不是只查文件存在。
  SCEN_TR="$(printf '%s' "$VERIFY_OUT" | grep -E '组合场景' | grep -E 'test-report|make-report' | head -1)"
  if [ -z "$SCEN_TR" ]; then
    A29_PROBLEMS="$A29_PROBLEMS [没有一条组合场景真的经过 test-report（只装不跑 ⇒ 判红）]"
  else
    REPORT_ART="$(find "$VERIFY_ROOT" -path "$VERIFY_ROOT/skills" -prune -o -type f -name report.json -size +0c -print 2>/dev/null | head -1)"
    VERDICT_ASSERT="$(printf '%s' "$SCEN_TR" | grep -cE 'verdict\.overall|verdict\.' || true)"
    if [ "${VERDICT_ASSERT:-0}" -eq 0 ]; then
      A29_PROBLEMS="$A29_PROBLEMS [经过 test-report 的组合场景没有断言报告里的结论（verdict/overall），只是查了文件存在]"
    fi
    if [ -z "$REPORT_ART" ] && [ "${VERDICT_ASSERT:-0}" -eq 0 ]; then
      A29_PROBLEMS="$A29_PROBLEMS [组合场景声称经过 test-report，但临时根里没有真的产出 report.json]"
    fi
  fi
  TR_INSTALL="$VERIFY_ROOT/skills/test-execute"
  OFFLINE="$TR_INSTALL/examples/offline"
  SUITE="$OFFLINE/test-assets/suites/REQ-DEMO-demo/suite.json"
  if [ -f "$SUITE" ] && [ -f "$TR_INSTALL/scripts/run-suite.mjs" ]; then
    node "$TR_INSTALL/scripts/run-suite.mjs" "$SUITE" --project-root "$OFFLINE" \
      --output-dir "$WORK/gate-exec-offline" --run-id gate-offline >/dev/null 2>&1
    if [ -s "$WORK/gate-exec-offline/meta.json" ]; then
      COUNTS="$(node -e 'const o=require(process.argv[1]);console.log([o.cases_passed,o.cases_failed,o.cases_blocked,o.cases_skipped].join("/"));' "$WORK/gate-exec-offline/meta.json" 2>/dev/null)"
      [ "$COUNTS" = "4/1/1/0" ] || A29_PROBLEMS="$A29_PROBLEMS [offline 夹具结果=$COUNTS，期望 4/1/1/0]"
    else
      A29_PROBLEMS="$A29_PROBLEMS [offline 夹具没有产出 meta.json —— 组合场景没真跑]"
    fi
  else
    A29_PROBLEMS="$A29_PROBLEMS [临时根里没有 test-execute 的 offline 夹具]"
  fi
  # ④ 版本错配时报**版本问题**（不是下游业务错）
  BADPKG="$WORK/badpkg"
  mkdir -p "$BADPKG"
  cp -r "$PKG"/. "$BADPKG"/ 2>/dev/null
  if [ -s "$BADPKG/skills/test-report/skill-meta.json" ]; then
    node -e '
const fs=require("fs");const f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));
o.requires=o.requires||{};o.requires["test-execute"]=">=99.0.0";fs.writeFileSync(f,JSON.stringify(o,null,2));
' "$BADPKG/skills/test-report/skill-meta.json" 2>/dev/null
    mkdir -p "$WORK/badroot"
    BADV_OUT="$(node "$BADPKG/bin/test-agent-skills.mjs" verify --root "$WORK/badroot" 2>&1)"; BADV_RC=$?
    [ "$BADV_RC" -ne 0 ] || A29_PROBLEMS="$A29_PROBLEMS [把 test-report 的 requires 改成 >=99.0.0 后 verify 仍然退出码 0 —— 依赖图没校验]"
    printf '%s' "$BADV_OUT" | grep -q 'test-report' || A29_PROBLEMS="$A29_PROBLEMS [版本错配的输出没有点名 test-report]"
    printf '%s' "$BADV_OUT" | grep -q '99.0.0' || A29_PROBLEMS="$A29_PROBLEMS [版本错配的输出没有给出要求的版本值]"
    printf '%s' "$BADV_OUT" | grep -q '0.1.0' || A29_PROBLEMS="$A29_PROBLEMS [版本错配的输出没有给出实际版本值]"
    if printf '%s' "$BADV_OUT" | grep -qiE '缺少必填字段|expected'; then
      A29_PROBLEMS="$A29_PROBLEMS [版本错配的输出里出现了下游业务错的特征串]"
    fi
  else
    A29_PROBLEMS="$A29_PROBLEMS [副本里没有 test-report/skill-meta.json，无法做版本错配探针]"
  fi
fi
if [ -z "$A29_PROBLEMS" ]; then ok "$A29" "$A29"; else bad "$A29" "$A29"; printf '  · %s\n' "$A29_PROBLEMS" >> "$RES_DIR/$A29.res"; fi

# ---------------------------------------------------------------- 输出（按判据编号排序）

step "结论"
AC_IDS="$(grep -oE '^### (AC-[0-9]+)' "$ACCEPTANCE" 2>/dev/null | grep -oE 'AC-[0-9]+' | sort -u)"
for id in $AC_IDS; do
  if [ -f "$RES_DIR/$id.res" ]; then
    cat "$RES_DIR/$id.res"
  else
    printf 'UNDEC %s  本门未覆盖这条判据 —— 不可判定，不判通过\n' "$id"
  fi
done

# ---------------------------------------------------------------- 变异体套件
#
# 口径（**只**认「新增失败键」）：
#   基线失败键 = 基线运行里**失败**的判据编号（只取 FAIL 行 —— PASS/UNDEC 的 .res 里也有 AC 编号，不能混进来）。
#   新增失败键 = 变异运行的失败键 减去 基线失败键（整行精确排除）。
#   检出 = 目标判据出现在**新增**失败键里。
#   ⚠️ 不用「对称差」：对称差把「基线红、变异后绿」也算成变化，那是噪声不是检出。
#   ⚠️ 负控（M0）必须**未检出**：它证明探测器不是恒真 —— 若 M0 也被报成「已检出」，本门失效。

if [ "${REQ010_NO_MUT:-0}" = "1" ]; then
  printf '\n变异体套件: 已跳过（REQ010_NO_MUT=1）—— 不可判定，不计入通过；检出率结论以完整模式为准\n'
  MUT_NOTE="跳过"
else
  step "变异体套件（4 个正控 + 1 个负控；检测口径 = 新增失败键）"

  # ① 基线失败键（只取 FAIL 行）
  BASE_FAILS="$(cat "$RES_DIR"/*.res 2>/dev/null | grep -hE '^FAIL' | grep -oE 'AC-[0-9]+' | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//')"
  printf '%s\n' $BASE_FAILS | grep -v '^$' | LC_ALL=C sort -u > "$WORK/base_fails.txt"
  if [ -n "$BASE_FAILS" ]; then
    printf '基线本身不绿（失败键: [%s]）—— 变异检测以**新增失败键**为准\n' "$BASE_FAILS"
  else
    printf '基线失败键: []（基线全绿）\n'
  fi
  printf '检测口径: 新增失败键 = 变异运行的失败键 减去 基线失败键（整行精确排除；「消失的失败键」不算检出）\n'

  # ② 跑一次变异包，返回「新增失败键」（空格分隔）
  run_mutant_gate() { # $1 = 变异体包目录
    local mpkg="$1" mout mf
    mout="$(REQ010_NO_MUT=1 QA010_SCRIPT_SHA= bash "$SELF" "$mpkg" 2>&1)"
    mf="$(printf '%s\n' "$mout" | sed 's/\x1b\[[0-9;]*m//g' | grep -E '^[[:space:]]*FAIL' | grep -oE 'AC-[0-9]+' | LC_ALL=C sort -u | grep -v '^$' || true)"
    comm -13 "$WORK/base_fails.txt" <(printf '%s\n' "$mf") | tr '\n' ' ' | sed 's/ $//'
  }

  # ③ 注入包装层（shim）：原实现 move 到 make-report.real.mjs，包装层跑完原实现后篡改产物
  #    $1 = 变异体包目录, $2 = 篡改代码
  #    ⚠️ 包装层**不**重算 report_sha256：报告内容一变，sha 的重算值就变 ⇒ AC-010 必然变红。
  #    正控本来就要变红，多红一条不影响检出；负控则按约定把 AC-010 从「新增失败键」里排除。
  inject_shim() {
    local mpkg="$1" code="$2"
    local entry="$mpkg/skills/test-report/scripts/make-report.mjs"
    mv "$entry" "$mpkg/skills/test-report/scripts/make-report.real.mjs" 2>/dev/null || return 1
    cat > "$entry" <<SHIMEOF
#!/usr/bin/env node
// 变异体包装层（仅存在于变异副本里）：先跑原实现，再对产物做一处语义篡改。
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const real = path.join(here, 'make-report.real.mjs');
const args = process.argv.slice(2);
const run = spawnSync(process.execPath, [real, ...args], { stdio: 'inherit' });
const code = run.status === null ? 1 : run.status;
if (code === 0) {
  const argOf = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : null; };
  const outDir = argOf('--out-dir') || path.join(argOf('--artifacts') || '', 'report');
  const file = path.join(outDir, 'report.json');
  if (fs.existsSync(file)) {
    const report = JSON.parse(fs.readFileSync(file, 'utf8'));
    ${code}
    fs.writeFileSync(file, JSON.stringify(report, null, 2) + '\n');
  }
}
process.exit(code);
SHIMEOF
    return 0
  }

  MUT_NAMES=(
    "blocked 计入 passed"
    "selected_missing 恒空数组"
    "有 failed 仍给 overall=pass"
    "报告数字与产物不符（cases.total 写死 42）"
  )
  MUT_ANCHORS=(
    "cases.blocked"
    "regression.selected_missing"
    "verdict.overall"
    "cases.total"
  )
  MUT_TARGETS=(
    "AC-019"
    "AC-014"
    "AC-012"
    "AC-005"
  )
  MUT_CODE=(
    "if (report.cases) { const b = report.cases.blocked; report.cases.passed = report.cases.passed + b; report.cases.blocked = 0; }"
    "if (report.regression) report.regression.selected_missing = [];"
    "if (report.verdict) report.verdict.overall = 'pass';"
    "if (report.cases) report.cases.total = 42;"
  )
  MUT_REQUIRED=4

  for i in "${!MUT_NAMES[@]}"; do
    NAME="${MUT_NAMES[$i]}"
    ANCHOR="${MUT_ANCHORS[$i]}"
    TARGET="${MUT_TARGETS[$i]}"
    CODE="${MUT_CODE[$i]}"
    MUTPKG="$WORK/mut-$i"
    mkdir -p "$MUTPKG"
    cp -r "$PKG"/. "$MUTPKG"/ 2>/dev/null
    ENTRY_REL="skills/test-report/scripts/make-report.mjs"
    ENTRY="$MUTPKG/$ENTRY_REL"
    STATUS="有效"
    # 自证 ①：入口锚点在副本里**逐字唯一命中 1 次**
    #   ⚠️ 两种「无效」要分开说：入口脚本**不存在** = **实现未交付**（不是门侧问题）；
    #      入口存在但命中数 ≠ 1 = **门侧锚点不可达**（不唯一）。
    if [ ! -f "$ENTRY" ]; then
      STATUS="无效变异（**实现缺失**：$ENTRY_REL 不存在 —— 变异体无法注入；这是实现未交付，不是门侧问题）"
      MUT_MISSING_IMPL=1
    else
      HITS="$(node "$WORK/pkgfiles.mjs" "$MUTPKG" "$ENTRY_REL" 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).length)}catch(e){console.log(0)}})')"
      if [ "${HITS:-0}" -ne 1 ]; then
        STATUS="无效变异（门侧锚点不可达：入口锚点命中 $HITS 次，要求恰好 1 次）"
      fi
    fi
    # 自证 ②：产物里的锚点路径恰好出现 1 次（锚点 0 次或 >1 次即无效变异）
    if [ "$STATUS" = "有效" ]; then
      ACNT="$(node "$WORK/pathcount.mjs" "$OUT_PLAN/report.json" "$ANCHOR" 2>/dev/null)"
      case "$ACNT" in ''|*[!0-9]*) ACNT=0 ;; esac
      if [ "$ACNT" -ne 1 ]; then
        STATUS="无效变异（产物里的锚点路径 $ANCHOR 命中 $ACNT 次，要求恰好 1 次）"
      fi
    fi
    # 注入：把入口脚本换成包装层（原实现 move 到 make-report.real.mjs）
    if [ "$STATUS" = "有效" ]; then
      BEFORE_SHA="$(sha256sum "$ENTRY" 2>/dev/null | cut -d' ' -f1)"
      inject_shim "$MUTPKG" "$CODE" || STATUS="无效变异（包装层注入失败）"
      AFTER_SHA="$(sha256sum "$ENTRY" 2>/dev/null | cut -d' ' -f1)"
      if [ "$STATUS" = "有效" ]; then
        if [ -z "$BEFORE_SHA" ] || [ "$BEFORE_SHA" = "$AFTER_SHA" ]; then
          STATUS="无效变异（注入前后 sha256 没变）"
        fi
      fi
      # 自证 ③：结构合法（node --check 通过 + 脚本能正常跑完）
      if [ "$STATUS" = "有效" ]; then
        node --check "$ENTRY" >/dev/null 2>&1 || STATUS="无效变异（变异后 node --check 不通过）"
      fi
      if [ "$STATUS" = "有效" ]; then
        MUTART="$WORK/mutart-$i"
        cp -r "$ART" "$MUTART"
        MUTOUT="$WORK/mutout-$i"
        mkdir -p "$MUTOUT"
        node "$ENTRY" --artifacts "$MUTART" --regression-plan "$PLAN" --out-dir "$MUTOUT" >/dev/null 2>&1
        MRC=$?
        if [ "$MRC" -ne 0 ] || [ ! -s "$MUTOUT/report.json" ]; then
          STATUS="无效变异（变异后脚本没正常跑完：rc=$MRC）—— 崩溃造成的判红是假检出"
        fi
      fi
    fi
    if [ "$STATUS" != "有效" ]; then
      MUT_INVALID="$MUT_INVALID [$NAME: $STATUS]"
      printf '变异体 %s: 无效变异（%s）—— 不计入分母\n' "$NAME" "$STATUS"
      continue
    fi
    MUT_TOTAL=$((MUT_TOTAL+1))
    NEW_FAILS="$(run_mutant_gate "$MUTPKG")"
    if printf '%s' " $NEW_FAILS " | grep -q " $TARGET "; then
      MUT_DETECTED=$((MUT_DETECTED+1))
      printf '变异体 %s: 已检出（目标 %s 出现在新增失败键集合里；新增=[%s]）\n' "$NAME" "$TARGET" "$NEW_FAILS"
    else
      MUT_ESCAPED="$MUT_ESCAPED [$NAME → 目标 $TARGET 未出现在新增失败键集合（新增=[$NEW_FAILS]）]"
      printf '变异体 %s: 逃逸（目标 %s 未出现在新增失败键集合里；新增=[%s]）\n' "$NAME" "$TARGET" "$NEW_FAILS"
    fi
  done

  # ④ 负控 M0：打不到任何判据的**无害**篡改 —— 期望「未检出」。
  #    它检验的是探测器本身：若 M0 也被报成「已检出」，说明探测器恒真 ⇒ 本门失效（门侧缺陷，判红）。
  #    ⚠️ 无害字段会改变 report.json 的内容 ⇒ report_sha256 的重算值随之改变 ⇒ AC-010 必然变红。
  #       这是包装层「不重算 sha」的必然结果，与被验实现的 sha 口径无关；
  #       按约定把 AC-010 从负控的「新增失败键」里**排除**（负控只看除 AC-010 外有没有新增失败键）。
  CTRL_NAME="负控 M0：新增无害字段（meta_note）"
  CTRLPKG="$WORK/mut-control"
  mkdir -p "$CTRLPKG"
  cp -r "$PKG"/. "$CTRLPKG"/ 2>/dev/null
  CTRL_STATUS="有效"
  if [ ! -f "$CTRLPKG/skills/test-report/scripts/make-report.mjs" ]; then
    CTRL_STATUS="无效变异（**实现缺失**：skills/test-report/scripts/make-report.mjs 不存在 —— 变异体无法注入；这是实现未交付，不是门侧问题）"
    MUT_MISSING_IMPL=1
  elif ! inject_shim "$CTRLPKG" "report.meta_note = 'mutant-control';"; then
    CTRL_STATUS="无效变异（包装层注入失败）"
  fi
  if [ "$CTRL_STATUS" = "有效" ]; then
    node --check "$CTRLPKG/skills/test-report/scripts/make-report.mjs" >/dev/null 2>&1 \
      || CTRL_STATUS="无效变异（变异后 node --check 不通过）"
  fi
  if [ "$CTRL_STATUS" = "有效" ]; then
    CTRLOUT="$WORK/ctrlout"
    mkdir -p "$CTRLOUT"
    node "$CTRLPKG/skills/test-report/scripts/make-report.mjs" --artifacts "$ART" --regression-plan "$PLAN" \
      --out-dir "$CTRLOUT" >/dev/null 2>&1
    CRC=$?
    if [ "$CRC" -ne 0 ] || [ ! -s "$CTRLOUT/report.json" ]; then
      CTRL_STATUS="无效变异（变异后脚本没正常跑完：rc=$CRC）"
    fi
  fi
  if [ "$CTRL_STATUS" != "有效" ]; then
    MUT_INVALID="$MUT_INVALID [$CTRL_NAME: $CTRL_STATUS]"
    printf '负控 %s: 无效变异（%s）—— 探测器的灵敏度不可判定\n' "$CTRL_NAME" "$CTRL_STATUS"
  else
    CTRL_NEW="$(run_mutant_gate "$CTRLPKG")"
    CTRL_NEW_EFF="$(printf '%s\n' $CTRL_NEW | grep -v '^AC-010$' | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')"
    if [ -z "$CTRL_NEW_EFF" ]; then
      MUT_CONTROL_OK=1
      printf '负控 %s: 未检出（除 AC-010 外的新增失败键为空；AC-010 因无害字段改变 report_sha256 的重算值而红，按约定排除）—— 符合预期，探测器不是恒真\n' "$CTRL_NAME"
    else
      MUT_CONTROL_FAILED="[$CTRL_NAME → 本不该让任何判据变红，却出现新增失败键 [$CTRL_NEW_EFF] —— 探测器疑似恒真]"
      printf '负控 %s: 被报成「已检出」（新增失败键=[%s]）—— 门侧缺陷：探测器恒真\n' "$CTRL_NAME" "$CTRL_NEW_EFF"
    fi
  fi

  # ⑤ 结论（责任方要指对：「实现缺失」是实现方的问题，「锚点不可达」才是门侧的问题）
  MUT_WHY="门侧注入问题：锚点不可达或注入不生效"
  if [ "$MUT_MISSING_IMPL" -eq 1 ]; then
    MUT_WHY="**实现缺失**：skills/test-report/scripts/make-report.mjs 不存在 —— 变异体无法注入；这是实现未交付，不是门侧问题"
  fi
  if [ -n "$MUT_ESCAPED" ]; then
    MUT_NOTE="检出 $MUT_DETECTED/$MUT_TOTAL（有效变异体）；逃逸:$MUT_ESCAPED"
  elif [ "$MUT_TOTAL" -lt "$MUT_REQUIRED" ]; then
    MUT_UNDEC=1
    MUT_NOTE="不可判定：有效变异体只有 $MUT_TOTAL/$MUT_REQUIRED（$MUT_WHY）；无效变异:$MUT_INVALID"
  elif [ -n "$MUT_INVALID" ]; then
    MUT_UNDEC=1
    MUT_NOTE="不可判定：$MUT_INVALID（$MUT_WHY）"
  else
    MUT_NOTE="检出 $MUT_DETECTED/$MUT_TOTAL（有效变异体）"
  fi
  printf '变异体套件: %s\n' "$MUT_NOTE"
fi

# ---------------------------------------------------------------- 结论

EVAL_COUNT=$((PASS + FAIL + UNDEC))
if [ "$EVAL_COUNT" -ne "$AC_COUNT" ]; then
  printf '\n⚠️ 判据条数不符：本门评了 %s 条，acceptance.md 的 `### AC-` 实际条数是 %s 条\n' "$EVAL_COUNT" "$AC_COUNT"
  FAIL=$((FAIL+1))
fi
printf '\n结论: %s PASS / %s FAIL\n' "$PASS" "$FAIL"
if [ "$UNDEC" -gt 0 ]; then
  printf '不可判定: %s 条\n' "$UNDEC"
fi
printf '验收脚本 sha256: %s\n' "$(sha256sum "$SELF" 2>/dev/null | cut -d' ' -f1)"
printf '被验实现指纹（skills/test-report/）: %s\n' "$(node "$WORK/fingerprint.mjs" "$TR" 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1)"
if [ "$MUT_NOTE" = "跳过" ]; then
  printf '变异体套件: 已跳过（REQ010_NO_MUT=1）—— 不可判定，检出率结论以完整模式为准\n'
elif [ -n "$MUT_ESCAPED" ]; then
  printf '变异体套件: %s —— 有变异体逃逸（真缺陷），整体判红\n' "$MUT_NOTE"
elif [ -n "$MUT_CONTROL_FAILED" ]; then
  printf '变异体套件: %s\n' "$MUT_NOTE"
  printf '负控失败：探测器疑似恒真 ⇒ 本门失效（门侧缺陷）—— %s\n' "$MUT_CONTROL_FAILED"
  printf '  （负控本该「未检出」；它被报成「已检出」说明检出判定恒真，本门结论不可采信）\n'
elif [ "$MUT_UNDEC" -eq 1 ]; then
  printf '不可判定: 1 项（变异体套件）—— %s\n' "$MUT_NOTE"
  if [ "$MUT_MISSING_IMPL" -eq 1 ]; then
    printf '  （这是**实现未交付**，不是门侧问题：变异体需要 `skills/test-report/scripts/make-report.mjs` 才能注入。退出码为 1，判据结论仍以上面的 PASS/FAIL 为准）\n'
  else
    printf '  （这是**门侧注入问题**，不是被验实现的缺陷；退出码为 1，判据结论仍以上面的 PASS/FAIL 为准）\n'
  fi
fi

# 退出条件：
#   - 逃逸（MUT_ESCAPED）      ⇒ 判红（真缺陷）
#   - 负控失败（MUT_CONTROL_FAILED） ⇒ 判红（门侧缺陷：探测器恒真）
#   - 不可判定（MUT_UNDEC）     ⇒ 退出码非 0，但不判红也不判绿（门侧注入问题）
#   - 有效变异体必须全部检出（MUT_DETECTED == MUT_TOTAL）且数量达标（MUT_TOTAL >= MUT_REQUIRED）
if [ "$FAIL" -eq 0 ] && [ "$UNDEC" -eq 0 ] && [ -z "$MUT_ESCAPED" ] && [ -z "$MUT_CONTROL_FAILED" ] \
   && { [ "${REQ010_NO_MUT:-0}" = "1" ] || { [ "$MUT_UNDEC" -eq 0 ] \
        && [ "$MUT_TOTAL" -ge "$MUT_REQUIRED" ] && [ "$MUT_DETECTED" -eq "$MUT_TOTAL" ] \
        && [ "$MUT_CONTROL_OK" -eq 1 ]; }; }; then
  exit 0
fi
exit 1
