#!/usr/bin/env bash
# REQ-007 验收脚本 —— `defect-verify` skill（R3 缺陷复现用例生成）
#
# 判据集：AC-001~AC-029（条数从 acceptance.md 的 `### AC-` 实际条数动态取，不写死）
#
# 用法: verify-acceptance.sh <package-dir>
#   <package-dir> 指向**被验包根目录**（含 skills/ 与 bin/，以及 feature-meta/、README.md）
#
# 退出码: 0 = 全部通过; 1 = 有 AC 未通过 / 不可判定 / 变异体有逃逸 / 负控失败; 2 = 用法错误
#
# 环境变量:
#   REQ007_NO_MUT=1   跳过变异体套件（快跑 / 嵌套运行用）
#   QA007_SCRIPT_SHA  期望的**本脚本自身** sha256；不匹配即判红并中止
#   QA007_KEEP_WORK=1 保留工作目录（调试）
#   QA007_WORK_ROOT   工作目录的父目录（默认 ${TMPDIR:-/tmp}）
#
# 设计要点（门是被验对象，不是脚手架 —— D65）:
#   - 只读被验包；一切变异都在**副本**上做，绝不在原地改被验对象。
#   - 夹具（缺陷单 / 用例集 / R3 轮次目录）一律造在临时目录里。
#   - 产物侧判据用**独立复算器**（内嵌 judge.mjs）：自己重算派生规则与归一化口径，
#     **绝不 import 被验包**；自带独立的归一化/特征匹配实现。
#   - 判据正文与本脚本的理解有出入时，以 acceptance.md 的判据正文为准；
#     分歧写进本脚本注释。
#   - 变异体套件的注入方式：**入口脚本包装（shim）** —— 把副本里的
#     `skills/defect-verify/scripts/make-defect-cases.mjs` 换成一层包装，包装调用原实现
#     （原文件 move 到 make-defect-cases.real.mjs）后再对**产物**做一处语义篡改。
#     「锚点逐字唯一命中 1 次」的机械等价物 = **入口脚本在副本里恰好存在 1 份**。
#   - 变异检出走**新增失败键**（变异运行的失败键 减去 基线失败键，整行精确排除）；
#     **不用**对称差：对称差把「基线红、变异后绿」也算成变化，那是噪声不是检出。
#     ⚠️ **基线失败键只取 `^FAIL` 行** —— PASS / UNDEC 行里也有 AC 编号，混进来会让基线键
#     集合变成**全集**，此后任何变异的「新增失败键」都恒等于全集 ⇒ 整套检测沦为橡皮章，
#     而门仍然 exit 0（REQ-010 的最致命一处缺陷，本门不得重蹈）。
#   - 崩溃造成的判红是假检出，不计入检出率（结构合法性单独自证）。
#   - 变异体套件里有一个**负控 M0**（打不到任何判据的无害篡改）：它必须**未检出**。
#     若 M0 也被报成「已检出」⇒ 探测器恒真 ⇒ 本门失效（门侧缺陷，判红，退出码非 0）。
#   - 有效变异体不足 4 个 ⇒ **不可判定**（门侧注入问题），退出码非 0，但不算被验实现的失败。
#   - **门跑在「没有实现」的真包上必须优雅降级**（D86）：不崩溃，如实报 FAIL / 不可判定。

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
  echo "无法从 $ACCEPTANCE 读到判据条数（\`### AC-\` 实际条数）—— 不可判定，不判通过" >&2
  exit 1
fi

# ---------------------------------------------------------------- 门禁前置：脚本自身指纹

if [ -n "${QA007_SCRIPT_SHA:-}" ]; then
  SELF_SHA="$(sha256sum "$SELF" 2>/dev/null | cut -d' ' -f1)"
  if [ "$SELF_SHA" != "$QA007_SCRIPT_SHA" ]; then
    echo "FAIL  门禁前置：验收脚本自身 sha256 不符（实际 $SELF_SHA，期望 $QA007_SCRIPT_SHA）" >&2
    echo "结论: 0 PASS / 1 FAIL" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------- 工作目录

WORK_PARENT="${QA007_WORK_ROOT:-${TMPDIR:-/tmp}}"
mkdir -p "$WORK_PARENT" 2>/dev/null || true
WORK="$(mktemp -d "$WORK_PARENT/qa-007-XXXXXX")"
cleanup() {
  # ⚠️ 本机 rm 是 shim（可恢复删除）：清理失败**不得**改变判定。
  if [ "${QA007_KEEP_WORK:-0}" = "1" ]; then
    printf '[debug] 工作目录已保留: %s\n' "$WORK"
    return 0
  fi
  rm -rf "$WORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT

RES_DIR="$WORK/res"
mkdir -p "$RES_DIR"

TR="$PKG/skills/defect-verify"
TCD="$PKG/skills/test-case-design"
TEX="$PKG/skills/test-execute"
FEATURE_META="$PKG/feature-meta"
README="$PKG/README.md"
INSTALLER="$PKG/bin/test-agent-skills.mjs"

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

# ---------------------------------------------------------------- 判据自带的独立工具（不 import 被验包）

cat > "$WORK/fingerprint.mjs" <<'FIXFP'
// fingerprint.mjs —— 判据自带的**独立**指纹实现（不 import 被验包里的实现）
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

export const sha256Hex = (data) => createHash('sha256').update(data).digest('hex');

export function sha256File(file) {
  try { return createHash('sha256').update(fs.readFileSync(file)).digest('hex'); }
  catch { return ''; }
}

// 目录内容的 sha256 清单（每行 "相对路径 sha256"，按路径排序）
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
        lines.push(`${path.relative(root, full).split(path.sep).join('/')} ${hash}`);
      }
    }
  };
  walk(root);
  lines.sort();
  return lines.join('\n');
}

// 命令行用法: node fingerprint.mjs <dir>
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
// 输出: { names, table, tree } —— table / tree 分别用于「两处都要有」的判定。
import fs from 'node:fs';

const text = fs.readFileSync(process.argv[2], 'utf8');
const names = new Set();
const table = new Set();
const tree = new Set();
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
  if (cells[0] && /^[a-z][a-z0-9-]*$/.test(cells[0])) { names.add(cells[0]); table.add(cells[0]); }
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
  if (match) { names.add(match[1]); tree.add(match[1]); }
}
process.stdout.write(`${JSON.stringify({
  names: [...names].sort(), table: [...table].sort(), tree: [...tree].sort(),
})}\n`);
FIXREADME

cat > "$WORK/scan-deps.mjs" <<'FIXSCAN'
// scan-deps.mjs —— 零第三方依赖 + 不联网 + 相对 import 只许指向本 skill 内
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

cat > "$WORK/snapdir.mjs" <<'FIXSNAP'
// snapdir.mjs —— 目录的**完整**快照（每行 "相对路径 sha256"，按路径排序）
// 用法: node snapdir.mjs <dir>
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const root = path.resolve(process.argv[2]);
const lines = [];
const walk = (dir) => {
  let entries = [];
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) { walk(full); continue; }
    if (!entry.isFile()) continue;
    const rel = path.relative(root, full).split(path.sep).join('/');
    const hash = crypto.createHash('sha256').update(fs.readFileSync(full)).digest('hex');
    lines.push(`${rel} ${hash}`);
  }
};
walk(root);
lines.sort();
process.stdout.write(`${lines.join('\n')}\n`);
FIXSNAP

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
// mkfixture.mjs —— 按 acceptance.md §0 自造夹具
//   用法: node mkfixture.mjs <fx-dir>
// 产出:
//   <fx>/inputs/defects.json        缺陷单夹具（5 条缺陷，覆盖 5 条分支）
//   <fx>/inputs/cases.json          已有用例集夹具（7 条用例，含已占用的 TC-101）
//   <fx>/proj/                      项目根
//     test-assets/cycles/R3-DEMO/cycle.json
//     test-assets/environments/mock.json
//     suites/REQ-DEMO-coupon/suite.json   （cases_file 相对解析到 defect-cases.json）
import fs from 'node:fs';
import path from 'node:path';

const fx = process.argv[2];
const ISO = '2026-11-13T00:00:00Z';
const SUITE = 'REQ-DEMO-coupon';

const defects = {
  schema_version: 1,
  defects: [
    {
      id: 'BUG-001',
      title: '满减券核销后实付金额多 0.01 元',
      severity: 'high',
      cycle_id: 'R1-REQ-001',
      run_id: 'run-001',
      case_refs: ['TC-017'],
      evidence_path: '.test-artifacts/R1-REQ-001/evidence/TC-017',
      status: 'open',
      reproducible: true,
      root_cause: null,
      reproduction: {
        command: 'curl -X POST https://api.example.com/coupon/redeem',
        steps: ['以满减券下单', '触发核销'],
        expected_failure: '实付金额比预期多 0.01 元',
      },
    },
    {
      id: 'BUG-002',
      title: '订单列表接口偶发超时',
      severity: 'medium',
      case_refs: ['TC-099'],
      status: 'open',
      reproduction: {
        command: 'curl -X GET https://api.example.com/orders',
        steps: ['查询订单列表'],
        expected_failure: '请求超时',
      },
    },
    {
      id: 'BUG-003',
      title: '优惠券核销后金额校验缺失',
      severity: 'medium',
      status: 'open',
      reproduction: {
        command: 'curl -X POST https://api.example.com/coupon/redeem',
        steps: ['以满减券下单', '触发核销'],
        expected_failure: '实付金额与预期不一致',
      },
    },
    {
      id: 'BUG-004',
      title: '支付回调缺陷（复现信息不足）',
      severity: 'low',
      status: 'open',
      reproduction: { command: '', steps: [], expected_failure: '' },
    },
    {
      id: 'BUG-005',
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

const mkCase = (id, title, req, action, expected, tags, extra = {}) => ({
  id,
  title,
  requirement_refs: [req],
  dimension: 'functional',
  priority: 'P0',
  method: ['M1.1'],
  status: 'active',
  preconditions: [],
  steps: [{ action, expected }],
  data: {},
  tags,
  ...extra,
});

const cases = {
  schema_version: 2,
  meta: { source: 'REQ-DEMO 需求文档', generated_at: ISO, case_count: 7 },
  requirements: [
    { id: 'R-1', title: '健康检查接口可用', source_ref: 'REQ-DEMO §1', testable: true },
    { id: 'R-2', title: '订单查询返回正确', source_ref: 'REQ-DEMO §2', testable: true },
    { id: 'R-3', title: '报表导出可用', source_ref: 'REQ-DEMO §3', testable: true },
    { id: 'R-4', title: '优惠券核销金额正确', source_ref: 'REQ-DEMO §4', testable: true },
  ],
  open_questions: [],
  coverage_matrix: [
    { requirement: 'R-1', methods_applied: ['M1.1'], skipped: [], dimensions: ['functional'] },
    { requirement: 'R-2', methods_applied: ['M1.1'], skipped: [], dimensions: ['functional'] },
    { requirement: 'R-3', methods_applied: ['M1.1'], skipped: [], dimensions: ['functional'] },
    { requirement: 'R-4', methods_applied: ['M1.1'], skipped: [], dimensions: ['functional'] },
  ],
  cases: [
    mkCase('TC-001', '健康检查通过', 'R-1', 'GET /api/health', '状态码 200', ['smoke']),
    mkCase('TC-002', '订单查询返回 500', 'R-2', 'GET /api/orders', '状态码 200', ['order']),
    mkCase('TC-003', '列表用例缺少断言', 'R-2', 'GET /api/items', '返回非空列表', ['order']),
    mkCase('TC-005', '报表导出通过', 'R-3', 'GET /api/reports', '状态码 200', ['report']),
    mkCase('TC-017', '满减券核销用例', 'R-4', '以满减券下单', '实付金额正确', ['coupon']),
    {
      id: 'TC-021',
      title: '优惠券核销复现用例',
      requirement_refs: ['R-4'],
      dimension: 'functional',
      priority: 'P0',
      method: ['M1.1'],
      status: 'active',
      preconditions: [],
      steps: [
        { action: '以满减券下单', expected: '实付金额正确' },
        { action: '触发核销', expected: '实付金额正确' },
      ],
      data: {},
      tags: ['coupon', 'regression'],
    },
    mkCase('TC-101', '已占用扩展段编号的用例', 'R-3', '占位导出', '导出成功', ['report']),
  ],
};

const cycle = {
  cycle_id: 'R3-DEMO',
  round: 'R3',
  round_type: 'defect-verify',
  requirement: 'REQ-DEMO',
  scopes: ['functional'],
  scopes_skipped: [],
  status: 'in_progress',
  stages: { clarify: { status: 'done' }, design: { status: 'in_progress' } },
  history: [{ at: '2026-11-13T00:00:00+08:00', from: 'planned', to: 'in_progress', by: 'seed' }],
  trigger: { type: 'defect', ref: 'BUG-001' },
};

const environment = {
  name: 'mock',
  base_url: 'http://127.0.0.1:0',
  timeout_ms: 5000,
  retries: 0,
  driver: 'mock',
};

// 顶层字段集**封闭**（9 个：上表字段 + base_url_from）；cases_file 相对套件目录解析
const suiteJson = {
  suite: SUITE,
  requirement: 'REQ-DEMO',
  scope: 'functional',
  environment: 'mock',
  cases_file: '../../test-assets/cycles/R3-DEMO/defect-cases.json',
  executor: 'api',
  base_url_from: 'mock',
  tags: { include: ['defect-verify'] },
  report: { format: ['json'], output_dir: `.test-artifacts/${SUITE}` },
};

const writeJson = (file, value) => {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
};

writeJson(path.join(fx, 'inputs', 'defects.json'), defects);
writeJson(path.join(fx, 'inputs', 'cases.json'), cases);
writeJson(path.join(fx, 'proj', 'test-assets', 'cycles', 'R3-DEMO', 'cycle.json'), cycle);
writeJson(path.join(fx, 'proj', 'test-assets', 'environments', 'mock.json'), environment);
writeJson(path.join(fx, 'proj', 'suites', SUITE, 'suite.json'), suiteJson);

process.stdout.write(`${JSON.stringify({ suite: SUITE, defects: defects.defects.length, cases: cases.cases.length })}\n`);
FIXMK

cat > "$WORK/judge.mjs" <<'FIXJUDGE'
#!/usr/bin/env node
// judge.mjs —— REQ-007 **产物侧**判据的独立复算器（AC-009 ~ AC-024）
//
// 原则（对标 D65「门是被验对象，不是脚手架」）：
//   ① 处置结论、复现用例的形状**全部从输入（defects.json / cases.json）重算**，
//      不信产物里的自述；
//   ② 归一化口径与特征匹配用**本脚本自带的独立实现**（照 demand.md D74 的口径），
//      **不** import 被验包里的实现；
//   ③ 只读被验包与夹具，绝不写回。
//
// 用法: node judge.mjs <cfg.json>
// 输出: 每行 "AC-xxx\tPASS|FAIL|UNDEC\t说明"
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const cfg = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));

const out = [];
const emit = (id, ok, msg) => {
  out.push(`${id}\t${ok}\t${String(msg).replace(/[\t\r\n]+/g, ' ').trim()}`);
};
const readJson = (p) => { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; } };
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const sarr = (v) => (Array.isArray(v) ? v : []);
const nonEmpty = (v) => typeof v === 'string' && v.trim() !== '';

// ---------------------------------------------------------------- 输入

const defectsDoc = readJson(cfg.defects);
const casesDoc = readJson(cfg.cases);
const defects = isObj(defectsDoc) && Array.isArray(defectsDoc.defects) ? defectsDoc.defects : [];
const inputCases = isObj(casesDoc) && Array.isArray(casesDoc.cases) ? casesDoc.cases : [];
const inputCaseIds = new Set(inputCases.filter(isObj).map((c) => String(c.id)));
const inputDefectIds = new Set(defects.filter(isObj).map((d) => String(d.id)));

const productPath = path.join(cfg.outMain, 'defect-cases.json');
const product = readJson(productPath);
const PRODUCT_MISSING = !fs.existsSync(productPath);
const PRODUCT_BAD = !PRODUCT_MISSING && !isObj(product);

const JUDGE_IDS = [
  'AC-009', 'AC-010', 'AC-011', 'AC-012', 'AC-013', 'AC-014',
  'AC-015', 'AC-016', 'AC-017', 'AC-018', 'AC-019',
  'AC-020', 'AC-021', 'AC-022', 'AC-023', 'AC-024',
];

if (PRODUCT_MISSING) {
  for (const id of JUDGE_IDS) emit(id, 'UNDEC', `产物未产出（${productPath} 不存在）—— 不可判定，不判通过`);
  process.stdout.write(`${out.join('\n')}\n`);
  process.exit(0);
}
if (PRODUCT_BAD) {
  for (const id of JUDGE_IDS) emit(id, 'FAIL', '产物不是合法 JSON（根节点不是对象）');
  process.stdout.write(`${out.join('\n')}\n`);
  process.exit(0);
}

// ---------------------------------------------------------------- 独立复算：归一化与特征匹配（D74）

const norm = (value) => {
  let s = String(value === undefined || value === null ? '' : value);
  s = s.normalize('NFKC');
  s = s.trim();
  s = s.replace(/\s+/g, ' ');
  const quoted = /^(["'“”‘’])([\s\S]*)\1$/.exec(s);
  if (quoted) s = quoted[2];
  s = s.trim();
  s = s.replace(/[。．.!！?？;；,，]+$/u, '');
  return s.trim();
};
const stepsFp = (steps) => sarr(steps).map((s) => norm(isObj(s) ? s.action : s)).join('\u0001');
const caseFp = (c) => {
  const cmd = isObj(c.reproduction) ? c.reproduction.command : '';
  return { cmd: norm(cmd), steps: stepsFp(c.steps) };
};
const defectFp = (d) => {
  const rep = isObj(d.reproduction) ? d.reproduction : {};
  return { cmd: norm(rep.command), steps: stepsFp(rep.steps) };
};
const featureHit = (c, d) => {
  const cf = caseFp(c);
  const df = defectFp(d);
  if (cf.steps !== df.steps) return false;
  return cf.cmd === df.cmd || cf.cmd === '' || df.cmd === '';
};
const sufficient = (d) => {
  const rep = isObj(d.reproduction) ? d.reproduction : null;
  if (!rep) return false;
  if (!nonEmpty(rep.command)) return false;
  if (!Array.isArray(rep.steps) || rep.steps.length === 0) return false;
  if (!nonEmpty(rep.expected_failure)) return false;
  return true;
};

// ---------------------------------------------------------------- 独立复算：期望的处置（D72/D73/D75/D81/D82）

const expected = [];
{
  const allocated = new Set(inputCaseIds);
  let next = 101;
  for (const d of defects) {
    const rec = { id: String(d.id) };
    const refs = Array.isArray(d.case_refs) ? d.case_refs.map(String) : [];
    if (refs.length > 0) {
      const missing = refs.filter((r) => !inputCaseIds.has(r));
      if (missing.length === 0) {
        rec.disposition = 'reused';
        rec.reused_case_refs = refs.map((r) => ({ suite: cfg.suite, case_id: r }));
        rec.source_case_id = refs[0];
      } else {
        rec.disposition = 'unresolved';
        rec.missing = missing;
      }
    } else if (!sufficient(d)) {
      rec.disposition = 'unresolved';
      rec.insufficient = true;
    } else {
      const hit = inputCases.find((c) => isObj(c) && featureHit(c, d));
      if (hit) {
        rec.disposition = 'reused';
        rec.reused_case_refs = [{ suite: cfg.suite, case_id: String(hit.id) }];
        rec.source_case_id = String(hit.id);
      } else {
        while (allocated.has(`TC-${String(next).padStart(3, '0')}`)) next += 1;
        const id = `TC-${String(next).padStart(3, '0')}`;
        allocated.add(id);
        next += 1;
        rec.disposition = 'derived';
        rec.derived_case_id = id;
      }
    }
    expected.push(rec);
  }
}
const expOf = (id) => expected.find((r) => r.id === id) || null;

// ---------------------------------------------------------------- 产物的取值

const pDefects = sarr(product.defects);
const pCases = sarr(product.cases);
const pReqs = sarr(product.requirements);
const pMatrix = sarr(product.coverage_matrix);
const pMeta = isObj(product.meta) ? product.meta : {};
const dOf = (id) => pDefects.find((d) => isObj(d) && String(d.id) === id) || null;
const casesFor = (id) => pCases.filter((c) => isObj(c) && sarr(c.defect_refs).map(String).includes(id));
const derivedFor = (id) => casesFor(id).filter((c) => c.origin === 'derived');
const deepEqual = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const has = (obj, key) => isObj(obj) && Object.prototype.hasOwnProperty.call(obj, key);

// ---------------------------------------------------------------- AC-009 case_refs 命中即复用；找不到即 unresolved

{
  const problems = [];
  const d1 = dOf('BUG-001');
  if (!d1) problems.push('产物里没有 BUG-001 的条目');
  else {
    if (d1.disposition !== 'reused') problems.push(`BUG-001.disposition=${JSON.stringify(d1.disposition)}，应为 "reused"`);
    const want = [{ suite: cfg.suite, case_id: 'TC-017' }];
    if (!deepEqual(d1.reused_case_refs, want)) problems.push(`BUG-001.reused_case_refs=${JSON.stringify(d1.reused_case_refs)}，应为 ${JSON.stringify(want)}`);
    if (has(d1, 'derived_case_id')) problems.push('BUG-001 带 derived_case_id（命中即复用，不得新建）');
    if (has(d1, 'reason')) problems.push('BUG-001 带 reason（它不是 unresolved）');
  }
  const d2 = dOf('BUG-002');
  if (!d2) problems.push('产物里没有 BUG-002 的条目');
  else {
    if (d2.disposition !== 'unresolved') problems.push(`BUG-002.disposition=${JSON.stringify(d2.disposition)}，应为 "unresolved"`);
    if (!nonEmpty(d2.reason)) problems.push('BUG-002.reason 缺失或为空');
    else if (!String(d2.reason).includes('TC-099')) problems.push(`BUG-002.reason=${JSON.stringify(d2.reason)}，未点名找不到的用例 id TC-099`);
    if (has(d2, 'reused_case_refs')) problems.push('BUG-002 带 reused_case_refs（不得假装复用）');
    if (has(d2, 'derived_case_id')) problems.push('BUG-002 带 derived_case_id（它不是派生）');
  }
  if (derivedFor('BUG-001').length > 0) problems.push('产物里有以 BUG-001 为 defect_refs 的 derived 用例（命中即复用，不得新建）');
  emit('AC-009', problems.length === 0 ? 'PASS' : 'FAIL', problems.join('; ') || 'case_refs 命中即复用、找不到即 unresolved');
}

// ---------------------------------------------------------------- AC-010 特征匹配命中即复用

{
  const problems = [];
  const d3 = dOf('BUG-003');
  if (!d3) problems.push('产物里没有 BUG-003 的条目');
  else {
    if (d3.disposition !== 'reused') problems.push(`BUG-003.disposition=${JSON.stringify(d3.disposition)}，应为 "reused"（特征匹配命中）`);
    const want = [{ suite: cfg.suite, case_id: 'TC-021' }];
    if (!deepEqual(d3.reused_case_refs, want)) problems.push(`BUG-003.reused_case_refs=${JSON.stringify(d3.reused_case_refs)}，应为 ${JSON.stringify(want)}`);
    if (has(d3, 'derived_case_id')) problems.push('BUG-003 带 derived_case_id（特征命中，不得新建）');
  }
  if (derivedFor('BUG-003').length > 0) problems.push('产物里有以 BUG-003 为 defect_refs 的 derived 用例（特征命中，不得新建）');
  emit('AC-010', problems.length === 0 ? 'PASS' : 'FAIL', problems.join('; ') || '特征匹配命中即复用');
}

// ---------------------------------------------------------------- AC-011 未命中才派生

{
  const problems = [];
  const d5 = dOf('BUG-005');
  if (!d5) problems.push('产物里没有 BUG-005 的条目');
  else {
    if (d5.disposition !== 'derived') problems.push(`BUG-005.disposition=${JSON.stringify(d5.disposition)}，应为 "derived"`);
    if (!nonEmpty(d5.derived_case_id)) problems.push('BUG-005.derived_case_id 缺失或为空');
    else {
      const c = pCases.find((x) => isObj(x) && String(x.id) === String(d5.derived_case_id));
      if (!c) problems.push(`产物里找不到 id=${d5.derived_case_id} 的派生用例`);
      else {
        if (c.origin !== 'derived') problems.push(`派生用例 ${c.id}.origin=${JSON.stringify(c.origin)}，应为 "derived"`);
        if (!sarr(c.defect_refs).map(String).includes('BUG-005')) problems.push(`派生用例 ${c.id}.defect_refs=${JSON.stringify(c.defect_refs)}，未含 BUG-005`);
      }
    }
    if (has(d5, 'reused_case_refs')) problems.push('BUG-005 带 reused_case_refs（它不是复用）');
    if (has(d5, 'reason')) problems.push('BUG-005 带 reason（它不是 unresolved）');
  }
  emit('AC-011', problems.length === 0 ? 'PASS' : 'FAIL', problems.join('; ') || '未命中才派生');
}

// ---------------------------------------------------------------- AC-012 信息不足判 unresolved

{
  const problems = [];
  const d4 = dOf('BUG-004');
  if (!d4) problems.push('产物里没有 BUG-004 的条目');
  else {
    if (d4.disposition !== 'unresolved') problems.push(`BUG-004.disposition=${JSON.stringify(d4.disposition)}，应为 "unresolved"`);
    if (!nonEmpty(d4.reason)) problems.push('BUG-004.reason 缺失或为空');
    if (has(d4, 'reused_case_refs')) problems.push('BUG-004 带 reused_case_refs');
    if (has(d4, 'derived_case_id')) problems.push('BUG-004 带 derived_case_id（信息不足不得派生）');
  }
  if (casesFor('BUG-004').length > 0) problems.push('产物里有引用 BUG-004 的用例（信息不足不得产出用例）');
  emit('AC-012', problems.length === 0 ? 'PASS' : 'FAIL', problems.join('; ') || '信息不足判 unresolved');
}

// ---------------------------------------------------------------- AC-013 扩展编号段不撞号

{
  const problems = [];
  const derived = pCases.filter((c) => isObj(c) && c.origin === 'derived');
  if (derived.length === 0) problems.push('产物里没有 origin=derived 的用例（无法判本条）');
  for (const c of derived) {
    const id = String(c.id);
    if (!/^TC-1[0-9][0-9]$/.test(id)) problems.push(`派生用例 ${id} 不在扩展编号段 TC-101~TC-999`);
    if (inputCaseIds.has(id)) problems.push(`派生用例 ${id} 与输入用例集的 id 撞号`);
  }
  const ids = pCases.map((c) => String(c.id));
  const dup = ids.filter((x, i) => ids.indexOf(x) !== i);
  if (dup.length > 0) problems.push(`产物内用例 id 重复: ${[...new Set(dup)].join(',')}`);
  emit('AC-013', problems.length === 0 ? 'PASS' : 'FAIL', problems.join('; ') || '扩展编号段不撞号');
}

// ---------------------------------------------------------------- AC-014 处置结论互斥且完备 + 产物形状封闭

{
  const problems = [];
  const TOP_LEVEL = ['schema_version', 'meta', 'requirements', 'open_questions', 'coverage_matrix', 'defects', 'cases'];
  const actualTop = Object.keys(product).sort();
  const extraTop = actualTop.filter((k) => !TOP_LEVEL.includes(k));
  if (extraTop.length > 0) problems.push(`顶层字段集不是封闭的（多出: ${extraTop.join(',')}）`);
  const missingTop = TOP_LEVEL.filter((k) => !actualTop.includes(k));
  if (missingTop.length > 0) problems.push(`顶层缺字段: ${missingTop.join(',')}`);
  if (pDefects.length !== defects.length) problems.push(`defects[] 条目数=${pDefects.length}，输入缺陷数=${defects.length}`);
  const ENTRY_ALLOWED = ['id', 'title', 'severity', 'status', 'disposition', 'reason', 'reused_case_refs', 'derived_case_id', 'source_cycle_id'];
  const seen = new Set();
  for (const d of pDefects) {
    if (!isObj(d)) { problems.push('defects[] 里有非对象条目'); continue; }
    const id = String(d.id);
    if (seen.has(id)) problems.push(`defects[] 里 ${id} 重复出现`);
    seen.add(id);
    const extra = Object.keys(d).filter((k) => !ENTRY_ALLOWED.includes(k));
    if (extra.length > 0) problems.push(`defects[] 条目 ${id} 的字段集不是封闭的（多出: ${extra.join(',')}）`);
    const disp = d.disposition;
    if (!['derived', 'reused', 'unresolved'].includes(disp)) { problems.push(`${id}.disposition=${JSON.stringify(disp)}，不在 {derived,reused,unresolved} 内`); continue; }
    const hasReason = has(d, 'reason');
    const hasRefs = has(d, 'reused_case_refs');
    const hasDerived = has(d, 'derived_case_id');
    if (disp === 'derived') {
      if (!nonEmpty(d.derived_case_id)) problems.push(`${id}: disposition=derived 但 derived_case_id 缺失或为空`);
      if (hasRefs) problems.push(`${id}: disposition=derived 但带 reused_case_refs（结论不互斥）`);
      if (hasReason) problems.push(`${id}: disposition=derived 但带 reason（结论不互斥）`);
    } else if (disp === 'reused') {
      if (!Array.isArray(d.reused_case_refs) || d.reused_case_refs.length === 0) problems.push(`${id}: disposition=reused 但 reused_case_refs 缺失或为空`);
      if (hasDerived) problems.push(`${id}: disposition=reused 但带 derived_case_id（结论不互斥）`);
      if (hasReason) problems.push(`${id}: disposition=reused 但带 reason（结论不互斥）`);
    } else {
      if (!nonEmpty(d.reason)) problems.push(`${id}: disposition=unresolved 但 reason 缺失或为空`);
      if (hasRefs) problems.push(`${id}: disposition=unresolved 但带 reused_case_refs（结论不互斥）`);
      if (hasDerived) problems.push(`${id}: disposition=unresolved 但带 derived_case_id（结论不互斥）`);
    }
  }
  emit('AC-014', problems.length === 0 ? 'PASS' : 'FAIL', problems.join('; ') || '处置结论互斥且完备，产物形状封闭');
}

// ---------------------------------------------------------------- AC-015 id 合 ^TC-\d{3}$

{
  const problems = [];
  for (const c of pCases) {
    if (!isObj(c)) { problems.push('cases[] 里有非对象条目'); continue; }
    if (!/^TC-\d{3}$/.test(String(c.id))) problems.push(`用例 id=${JSON.stringify(c.id)} 不合 ^TC-\\d{3}$`);
  }
  const ids = pCases.filter(isObj).map((c) => String(c.id));
  const dup = ids.filter((x, i) => ids.indexOf(x) !== i);
  if (dup.length > 0) problems.push(`用例 id 重复: ${[...new Set(dup)].join(',')}`);
  emit('AC-015', problems.length === 0 ? 'PASS' : 'FAIL', problems.join('; ') || 'id 合 ^TC-\\d{3}$ 且唯一');
}

// ---------------------------------------------------------------- AC-016 必填字段齐全且不悬空

{
  const problems = [];
  const reqIds = new Set(pReqs.filter(isObj).map((r) => String(r.id)));
  for (const c of pCases) {
    if (!isObj(c)) continue;
    const id = String(c.id);
    if (!nonEmpty(c.title)) problems.push(`${id}.title 缺失或为空`);
    if (!Array.isArray(c.requirement_refs) || c.requirement_refs.length === 0) problems.push(`${id}.requirement_refs 缺失或为空`);
    else {
      for (const r of c.requirement_refs) {
        if (!reqIds.has(String(r))) problems.push(`${id}.requirement_refs 里的 ${JSON.stringify(r)} 悬空（requirements[] 里没有）`);
      }
    }
    if (!nonEmpty(c.dimension)) problems.push(`${id}.dimension 缺失或为空`);
    if (!nonEmpty(c.priority)) problems.push(`${id}.priority 缺失或为空`);
    if (!Array.isArray(c.method) || c.method.length === 0) problems.push(`${id}.method 缺失或为空数组`);
    if (!nonEmpty(c.status)) problems.push(`${id}.status 缺失或为空`);
    if (!Array.isArray(c.steps) || c.steps.length === 0) problems.push(`${id}.steps 缺失或为空数组`);
    else {
      c.steps.forEach((s, i) => {
        if (!isObj(s) || !nonEmpty(s.action)) problems.push(`${id}.steps[${i}].action 缺失或为空`);
        if (!isObj(s) || !nonEmpty(s.expected)) problems.push(`${id}.steps[${i}].expected 缺失或为空`);
      });
    }
    if (!Array.isArray(c.tags)) problems.push(`${id}.tags 不是数组`);
  }
  for (const m of pMatrix) {
    if (!isObj(m) || !reqIds.has(String(m.requirement))) problems.push(`coverage_matrix 里的 requirement=${JSON.stringify(isObj(m) ? m.requirement : m)} 不在 requirements[] 里`);
  }
  // 每个「有对应用例的需求条目」都必须在 coverage_matrix 里
  const covered = new Set();
  for (const c of pCases) if (isObj(c)) for (const r of sarr(c.requirement_refs)) covered.add(String(r));
  const matrixReqs = new Set(pMatrix.filter(isObj).map((m) => String(m.requirement)));
  for (const r of covered) {
    if (!matrixReqs.has(r)) problems.push(`需求条目 ${r} 有对应用例，但不在 coverage_matrix 里`);
  }
  emit('AC-016', problems.length === 0 ? 'PASS' : 'FAIL', problems.join('; ') || '必填字段齐全且 requirement_refs 不悬空');
}

// ---------------------------------------------------------------- AC-017 defect_refs / origin / source_case_id / source_suite

{
  const problems = [];
  for (const c of pCases) {
    if (!isObj(c)) continue;
    const id = String(c.id);
    if (!Array.isArray(c.defect_refs) || c.defect_refs.length === 0) problems.push(`${id}.defect_refs 缺失或为空数组`);
    else {
      for (const r of c.defect_refs) {
        if (!inputDefectIds.has(String(r))) problems.push(`${id}.defect_refs 里的 ${JSON.stringify(r)} 不在输入缺陷 id 集合里`);
      }
    }
    if (!['derived', 'reused'].includes(c.origin)) problems.push(`${id}.origin=${JSON.stringify(c.origin)}，不在 {derived,reused} 内`);
    else if (c.origin === 'reused') {
      if (!nonEmpty(c.source_case_id)) problems.push(`${id}.source_case_id 缺失或为空（origin=reused）`);
      else if (!inputCaseIds.has(String(c.source_case_id))) problems.push(`${id}.source_case_id=${JSON.stringify(c.source_case_id)} 不在输入用例集里`);
      if (!nonEmpty(c.source_suite)) problems.push(`${id}.source_suite 缺失或为空（origin=reused）`);
    } else {
      if (c.source_case_id !== null && c.source_case_id !== undefined) problems.push(`${id}.source_case_id=${JSON.stringify(c.source_case_id)}，origin=derived 时应为 null 或不存在`);
      if (c.source_suite !== null && c.source_suite !== undefined) problems.push(`${id}.source_suite=${JSON.stringify(c.source_suite)}，origin=derived 时应为 null 或不存在`);
    }
  }
  emit('AC-017', problems.length === 0 ? 'PASS' : 'FAIL', problems.join('; ') || 'defect_refs/origin/source_case_id/source_suite 齐全');
}

// ---------------------------------------------------------------- AC-018 tags 含 defect-verify 与缺陷 id

{
  const problems = [];
  for (const c of pCases) {
    if (!isObj(c)) continue;
    const id = String(c.id);
    const tags = sarr(c.tags).map(String);
    if (!tags.includes('defect-verify')) problems.push(`${id}.tags 里没有 "defect-verify"`);
    for (const r of sarr(c.defect_refs)) {
      if (!tags.includes(String(r))) problems.push(`${id}.tags 里没有缺陷 id ${JSON.stringify(String(r))}`);
    }
  }
  emit('AC-018', problems.length === 0 ? 'PASS' : 'FAIL', problems.join('; ') || 'tags 含 defect-verify 与缺陷 id');
}

// ---------------------------------------------------------------- AC-019 产物能被 test-execute 直接消费

{
  const problems = [];
  const TOP9 = ['suite', 'requirement', 'scope', 'environment', 'cases_file', 'executor', 'base_url_from', 'tags', 'report'];
  const suiteFile = path.join(cfg.projectRoot, 'suites', cfg.suite, 'suite.json');
  const suiteDoc = readJson(suiteFile);
  if (!isObj(suiteDoc)) problems.push(`套件配置 ${suiteFile} 不可读`);
  else {
    const extra = Object.keys(suiteDoc).filter((k) => !TOP9.includes(k));
    if (extra.length > 0) problems.push(`suite.json 顶层字段集不是封闭的（多出: ${extra.join(',')}）`);
    if (!nonEmpty(suiteDoc.cases_file)) problems.push('suite.json 没有 cases_file');
  }
  const runSuite = cfg.runSuite;
  if (!fs.existsSync(runSuite)) problems.push(`缺 ${runSuite}（前置条件不满足）`);
  else {
    const runDry = (suitePath) => {
      const res = spawnSync(process.execPath, [runSuite, suitePath, '--project-root', cfg.projectRoot, '--dry-run', '--json'],
        { encoding: 'utf8' });
      let count = null;
      try { count = JSON.parse(res.stdout).cases_total; } catch { count = null; }
      if (count === null) {
        // 兜底：stdout 里可能混了别的输出 → 取第一个 '{' 到最后一个 '}' 之间的 JSON
        const a = res.stdout.indexOf('{');
        const b = res.stdout.lastIndexOf('}');
        if (a >= 0 && b > a) {
          try { count = JSON.parse(res.stdout.slice(a, b + 1)).cases_total; } catch { count = null; }
        }
      }
      return { code: res.status, count, stdout: res.stdout || '', stderr: res.stderr || '' };
    };
    const all = runDry(suiteFile);
    if (all.code !== 0) problems.push(`run-suite.mjs --dry-run 退出码=${all.code}（stderr: ${all.stderr.slice(0, 200)}）`);
    else if (all.count !== pCases.length) problems.push(`--dry-run 计划执行 ${all.count} 条，与产物 cases.length=${pCases.length} 不符`);

    // 按缺陷分批跑：tags.include = ["BUG-005"]
    const variant = path.join(cfg.projectRoot, 'suites', cfg.suite, 'suite.bug005.json');
    const vdoc = isObj(suiteDoc) ? { ...suiteDoc, tags: { include: ['BUG-005'] } } : { tags: { include: ['BUG-005'] } };
    fs.writeFileSync(variant, `${JSON.stringify(vdoc, null, 2)}\n`);
    const one = runDry(variant);
    const wantOne = casesFor('BUG-005').length;
    if (one.code !== 0) problems.push(`按缺陷分批的 --dry-run 退出码=${one.code}`);
    else if (one.count !== wantOne) problems.push(`tags.include=["BUG-005"] 选中 ${one.count} 条，期望 ${wantOne} 条`);
  }
  emit('AC-019', problems.length === 0 ? 'PASS' : 'FAIL', problems.join('; ') || '产物能被 test-execute 直接消费');
}

// ---------------------------------------------------------------- AC-020 缺陷 id 集合 == 输入

{
  const problems = [];
  const outIds = pDefects.filter(isObj).map((d) => String(d.id));
  const outSet = new Set(outIds);
  const inSet = new Set(inputDefectIds);
  const missing = [...inSet].filter((x) => !outSet.has(x));
  const extra = [...outSet].filter((x) => !inSet.has(x));
  if (missing.length > 0) problems.push(`产物少了缺陷: ${missing.join(',')}`);
  if (extra.length > 0) problems.push(`产物多了缺陷: ${extra.join(',')}`);
  if (outIds.length !== outSet.size) problems.push('产物里有重复的缺陷 id');
  if (pReqs.length !== defects.length) problems.push(`requirements[] 条目数=${pReqs.length}，输入缺陷数=${defects.length}`);
  defects.forEach((d, i) => {
    const r = pReqs[i];
    if (!isObj(r)) { problems.push(`requirements[${i}] 缺失`); return; }
    if (String(r.id) !== `R-${i + 1}`) problems.push(`requirements[${i}].id=${JSON.stringify(r.id)}，应为 R-${i + 1}`);
    if (String(r.source_ref) !== `defects.json#/defects/${i}`) problems.push(`requirements[${i}].source_ref=${JSON.stringify(r.source_ref)}，应为 defects.json#/defects/${i}`);
  });
  emit('AC-020', problems.length === 0 ? 'PASS' : 'FAIL', problems.join('; ') || '缺陷 id 集合 == 输入');
}

// ---------------------------------------------------------------- AC-021 unresolved 必带非空理由

{
  const problems = [];
  for (const d of pDefects) {
    if (!isObj(d)) continue;
    if (d.disposition !== 'unresolved') continue;
    const id = String(d.id);
    if (!nonEmpty(d.reason)) problems.push(`${id}.reason 缺失或为空`);
    if (has(d, 'derived_case_id')) problems.push(`${id} 是 unresolved 却带 derived_case_id`);
    if (has(d, 'reused_case_refs')) problems.push(`${id} 是 unresolved 却带 reused_case_refs`);
  }
  const unres = pDefects.filter((d) => isObj(d) && d.disposition === 'unresolved');
  if (unres.length === 0) problems.push('产物里一条 unresolved 都没有 —— 本条无法判读（实现可能把信息不足悄悄变成了复用/派生）');
  emit('AC-021', problems.length === 0 ? 'PASS' : 'FAIL', problems.join('; ') || 'unresolved 必带非空理由');
}

// ---------------------------------------------------------------- AC-022 不得凭空造缺陷

{
  const problems = [];
  for (const d of pDefects) {
    if (!isObj(d)) continue;
    if (!inputDefectIds.has(String(d.id))) problems.push(`defects[] 里出现了输入没有的 id: ${JSON.stringify(d.id)}`);
  }
  for (const c of pCases) {
    if (!isObj(c)) continue;
    for (const r of sarr(c.defect_refs)) {
      if (!inputDefectIds.has(String(r))) problems.push(`cases[] 里的 ${String(c.id)} 引用了输入没有的缺陷 id: ${JSON.stringify(String(r))}`);
    }
  }
  pReqs.forEach((r, i) => {
    if (!isObj(r)) { problems.push(`requirements[${i}] 不是对象`); return; }
    const m = /^defects\.json#\/defects\/(\d+)$/.exec(String(r.source_ref));
    if (!m) problems.push(`requirements[${i}].source_ref=${JSON.stringify(r.source_ref)} 不形如 defects.json#/defects/<i>`);
    else if (Number(m[1]) >= defects.length) problems.push(`requirements[${i}].source_ref 指向了不存在的缺陷下标 ${m[1]}`);
  });
  emit('AC-022', problems.length === 0 ? 'PASS' : 'FAIL', problems.join('; ') || '不得凭空造缺陷');
}

// ---------------------------------------------------------------- AC-023 不得重复派生

{
  const problems = [];
  for (const id of inputDefectIds) {
    const n = derivedFor(id).length;
    if (n > 1) problems.push(`缺陷 ${id} 有 ${n} 条派生用例（最多 1 条）`);
  }
  for (const id of ['BUG-001', 'BUG-003']) {
    if (derivedFor(id).length > 0) problems.push(`缺陷 ${id} 已有对应用例（复用），却又有派生用例`);
  }
  const ids = pCases.filter(isObj).map((c) => String(c.id));
  const dup = ids.filter((x, i) => ids.indexOf(x) !== i);
  if (dup.length > 0) problems.push(`产物内用例 id 重复: ${[...new Set(dup)].join(',')}`);
  emit('AC-023', problems.length === 0 ? 'PASS' : 'FAIL', problems.join('; ') || '不得重复派生');
}

// ---------------------------------------------------------------- AC-024 幂等

{
  const problems = [];
  const p1 = path.join(cfg.outIdem1, 'defect-cases.json');
  const p2 = path.join(cfg.outIdem2, 'defect-cases.json');
  if (!fs.existsSync(p1) || !fs.existsSync(p2)) problems.push('两次运行没有都产出 defect-cases.json');
  else {
    const readText = (p) => fs.readFileSync(p, 'utf8');
    const ts = (p) => {
      const o = readJson(p);
      return isObj(o) && isObj(o.meta) && typeof o.meta.generated_at === 'string' ? o.meta.generated_at : null;
    };
    let t1 = readText(p1);
    let t2 = readText(p2);
    const s1 = ts(p1);
    const s2 = ts(p2);
    if (s1) t1 = t1.split(s1).join('<TS>');
    if (s2) t2 = t2.split(s2).join('<TS>');
    if (t1 !== t2) problems.push('两次运行的产物除 generated_at 外不相同');
  }
  emit('AC-024', problems.length === 0 ? 'PASS' : 'FAIL', problems.join('; ') || '同一输入两次逐字相同（除 generated_at）');
}

// ---------------------------------------------------------------- 输出

process.stdout.write(`${out.join('\n')}\n`);
FIXJUDGE

# ---------------------------------------------------------------- 夹具

step "准备夹具（§0：缺陷单 + 已有用例集 + R3 轮次目录）"
FX="$WORK/fx"
FIXINFO="$(node "$WORK/mkfixture.mjs" "$FX" 2>&1)"
if [ $? -ne 0 ] || [ ! -s "$FX/inputs/defects.json" ] || [ ! -s "$FX/inputs/cases.json" ]; then
  echo "夹具生成失败 —— 不可判定，不判通过" >&2
  printf '%s\n' "$FIXINFO" | head -5 >&2
  exit 1
fi
printf '夹具: %s\n' "$FIXINFO"

SUITE_ID="REQ-DEMO-coupon"
DEFECTS_FX="$FX/inputs/defects.json"
CASES_FX="$FX/inputs/cases.json"
CYCLE_REL="test-assets/cycles/R3-DEMO"
# 输入目录的**跑前**快照（AC-025 用）—— 必须在任何一次跑被验实现之前取
INPUTS_BEFORE="$(node "$WORK/snapdir.mjs" "$FX/inputs" 2>/dev/null)"

# ---------------------------------------------------------------- 跑被验实现

MAKE="$TR/scripts/make-defect-cases.mjs"
CHECK="$TR/scripts/check-defect-cases.mjs"

step "跑被验实现（主跑 / 幂等两次）"

run_make() { # $1 = 项目根（轮次目录在其 test-assets/cycles/R3-DEMO 下）, $2 = 额外参数（可空）
  local proj="$1"; shift
  local cycle_dir="$proj/$CYCLE_REL"
  node "$MAKE" --defects "$DEFECTS_FX" --cases "$CASES_FX" --suite "$SUITE_ID" \
    --cycle-dir "$cycle_dir" "$@" >"$WORK/make.log" 2>"$WORK/make.err"
  return $?
}

PROJ_MAIN="$WORK/run-main"
PROJ_IDEM1="$WORK/run-idem1"
PROJ_IDEM2="$WORK/run-idem2"
for d in "$PROJ_MAIN" "$PROJ_IDEM1" "$PROJ_IDEM2"; do
  mkdir -p "$d"
  cp -r "$FX/proj"/. "$d"/ 2>/dev/null
done

RC_MAIN=0; run_make "$PROJ_MAIN" || RC_MAIN=$?
RC_IDEM1=0; run_make "$PROJ_IDEM1" || RC_IDEM1=$?
RC_IDEM2=0; run_make "$PROJ_IDEM2" || RC_IDEM2=$?
OUT_MAIN="$PROJ_MAIN/$CYCLE_REL"
printf 'make-defect-cases 退出码: 主跑=%s 幂等1=%s 幂等2=%s\n' "$RC_MAIN" "$RC_IDEM1" "$RC_IDEM2"
if [ "$RC_MAIN" -ne 0 ]; then
  printf '  · stderr: %s\n' "$(head -3 "$WORK/make.err" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------- 产物侧判据（C/D/E/F 组，交给独立复算器）

step "产物侧判据（AC-009 ~ AC-024，独立复算器）"
cat > "$WORK/judge-cfg.json" <<CFGCFG
{
  "defects": "$DEFECTS_FX",
  "cases": "$CASES_FX",
  "suite": "$SUITE_ID",
  "outMain": "$OUT_MAIN",
  "outIdem1": "$PROJ_IDEM1/$CYCLE_REL",
  "outIdem2": "$PROJ_IDEM2/$CYCLE_REL",
  "projectRoot": "$PROJ_MAIN",
  "runSuite": "$TEX/scripts/run-suite.mjs",
  "pkgRoot": "$PKG"
}
CFGCFG
JUDGE_OUT="$WORK/judge.out"
node "$WORK/judge.mjs" "$WORK/judge-cfg.json" > "$JUDGE_OUT" 2>"$WORK/judge.err"
JUDGE_RC=$?
if [ "$JUDGE_RC" -ne 0 ]; then
  printf '复算器异常退出（rc=%s）—— 产物侧判据不可判定\n' "$JUDGE_RC"
  head -5 "$WORK/judge.err"
  for id in AC-009 AC-010 AC-011 AC-012 AC-013 AC-014 AC-015 AC-016 AC-017 AC-018 AC-019 \
            AC-020 AC-021 AC-022 AC-023 AC-024; do
    undec "$id 复算器异常（rc=$JUDGE_RC）" "$id"
  done
else
  while IFS=$'\t' read -r jid jres jmsg; do
    [ -n "$jid" ] || continue
    case "$jres" in
      PASS) ok "$jid 产物侧判据" "$jid" ;;
      UNDEC) undec "$jid $jmsg" "$jid" ;;
      *) bad "$jid 产物侧判据" "$jid"; printf '  · %s\n' "$jmsg" >> "$RES_DIR/$jid.res" ;;
    esac
  done < "$JUDGE_OUT"
  if [ -s "$WORK/judge.err" ]; then
    printf '  · judge stderr: %s\n' "$(head -3 "$WORK/judge.err" | tr '\n' ' ')"
  fi
fi

# ---------------------------------------------------------------- A 组（交付物形状）

step "AC-001 defect-verify skill 存在且结构合法"
A1="AC-001"
A1_PROBLEMS=""
if [ ! -d "$TR" ]; then
  A1_PROBLEMS="缺目录 skills/defect-verify/"
else
  for f in "SKILL.md" "skill-meta.json" "references/defect-input-schema.md" "references/derivation-rules.md" \
           "scripts/make-defect-cases.mjs" "scripts/check-defect-cases.mjs"; do
    [ -s "$TR/$f" ] || A1_PROBLEMS="$A1_PROBLEMS [缺或空: $f]"
  done
  LIB_N="$(find "$TR/scripts/lib" -maxdepth 1 -type f -name '*.mjs' -size +0c 2>/dev/null | wc -l | tr -d ' ')"
  case "$LIB_N" in ''|*[!0-9]*) LIB_N=0 ;; esac
  [ "${LIB_N:-0}" -ge 3 ] || A1_PROBLEMS="$A1_PROBLEMS [scripts/lib/ 下非空的 .mjs 模块只有 ${LIB_N:-0} 个，要求 ≥ 3]"
  NAME_OK=0; DESC_OK=0
  if [ -s "$TR/SKILL.md" ]; then
    FM_NAME="$(node "$WORK/frontmatter.mjs" "$TR/SKILL.md" name 2>/dev/null)"
    FM_DESC="$(node "$WORK/frontmatter.mjs" "$TR/SKILL.md" description 2>/dev/null)"
    FM_NAME_VAL="$(node -e 'try{const o=JSON.parse(process.argv[1]);console.log(String(o.value||""))}catch(e){console.log("")}' "$FM_NAME")"
    [ "$FM_NAME_VAL" = "defect-verify" ] && NAME_OK=1
    DESC_EMPTY="$(node -e 'try{const o=JSON.parse(process.argv[1]);console.log(o.found&&!o.empty?"0":"1")}catch(e){console.log("1")}' "$FM_DESC")"
    [ "$DESC_EMPTY" = "0" ] && DESC_OK=1
  fi
  # 逐脚本判定（各自满足，不是两个合起来满足其一）
  A1_SCRIPT_PROBLEMS=""
  for f in "scripts/make-defect-cases.mjs" "scripts/check-defect-cases.mjs"; do
    p="$TR/$f"
    if [ ! -s "$p" ]; then
      A1_SCRIPT_PROBLEMS="$A1_SCRIPT_PROBLEMS [$f 缺失或为空]"
      continue
    fi
    head -1 "$p" 2>/dev/null | grep -q '^#!.*node' || A1_SCRIPT_PROBLEMS="$A1_SCRIPT_PROBLEMS [$f 首行不是 '#!…node' 的 shebang]"
    [ -x "$p" ] || A1_SCRIPT_PROBLEMS="$A1_SCRIPT_PROBLEMS [$f 不可执行]"
    node --check "$p" >/dev/null 2>&1 || A1_SCRIPT_PROBLEMS="$A1_SCRIPT_PROBLEMS [$f 的 node --check 不通过]"
  done
  if [ -n "$A1_PROBLEMS" ]; then
    :
  elif [ "$NAME_OK" -ne 1 ]; then
    A1_PROBLEMS="SKILL.md frontmatter 的 name 不是 defect-verify"
  elif [ "$DESC_OK" -ne 1 ]; then
    A1_PROBLEMS="SKILL.md frontmatter 的 description 为空值"
  elif [ -n "$A1_SCRIPT_PROBLEMS" ]; then
    A1_PROBLEMS="两个脚本未逐个满足（首行 shebang / 可执行 / node --check）: $A1_SCRIPT_PROBLEMS"
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
DV_REQUIRES_OK=0
for d in $SKILL_DIRS; do
  NAME="$(basename "$d")"
  META="$d/skill-meta.json"
  if [ ! -s "$META" ]; then A2_PROBLEMS="$A2_PROBLEMS [$NAME 缺 skill-meta.json]"; continue; fi
  FM_SKILL_JSON="$(node "$WORK/frontmatter.mjs" "$d/SKILL.md" name 2>/dev/null)"
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
let fmObj={found:false,value:""};
try{fmObj=JSON.parse(process.argv[4]||"{}");}catch(e){}
let skillName=(fmObj&&fmObj.found)?String(fmObj.value||""):null;
if(skillName===null){
  let fm=""; try{fm=fs.readFileSync(process.argv[3]+"/SKILL.md","utf8").slice(0,2000);}catch(e){}
  const m=fm.match(/^---\s*$[\s\S]*?^name:\s*(\S+)\s*$/m);
  skillName=m?m[1]:null;
}
if(skillName!==o.name)problems.push("SKILL.md name="+skillName+" vs meta.name="+o.name);
console.log(JSON.stringify({problems,requires:o.requires||{}}));
' "$META" "$NAME" "$d" "$FM_SKILL_JSON" 2>/dev/null)"
  P="$(node -e 'try{const o=JSON.parse(process.argv[1]);console.log((o.problems||[]).join(";"))}catch(e){console.log("PARSE_ERR")}' "$RES" 2>/dev/null)"
  REQ="$(node -e 'try{const o=JSON.parse(process.argv[1]);console.log(Object.keys(o.requires||{}).join(","))}catch(e){console.log("")}' "$RES" 2>/dev/null)"
  [ -n "$P" ] && A2_PROBLEMS="$A2_PROBLEMS [$NAME $P]"
  if [ "$NAME" = "defect-verify" ]; then
    case ",$REQ," in *,test-case-design,*) DV_TCD=1 ;; esac
    case ",$REQ," in *,test-execute,*) DV_TEX=1 ;; esac
  fi
done
if [ -z "$SKILL_DIRS" ]; then
  A2_PROBLEMS="被验包里没有任何含 SKILL.md 的 skill 目录"
elif [ "${DV_TCD:-0}" != "1" ]; then
  A2_PROBLEMS="$A2_PROBLEMS [defect-verify 的 requires 里没有 test-case-design（它消费用例集，是硬依赖）]"
elif [ "${DV_TEX:-0}" != "1" ]; then
  A2_PROBLEMS="$A2_PROBLEMS [defect-verify 的 requires 里没有 test-execute（复现用例由它执行，是硬依赖）]"
fi
if [ -z "$A2_PROBLEMS" ]; then ok "$A2" "$A2"; else bad "$A2" "$A2"; printf '  · %s\n' "$A2_PROBLEMS" >> "$RES_DIR/$A2.res"; fi

step "AC-003 README 的 skill 清单与实际目录一致（两处都要有 defect-verify）"
A3="AC-003"
A3_PROBLEMS=""
if [ ! -s "$README" ]; then
  A3_PROBLEMS="缺 README.md 或为空"
else
  README_NAMES="$(node "$WORK/readme-skills.mjs" "$README" 2>/dev/null)"
  DIR_NAMES="$(for d in $SKILL_DIRS; do basename "$d"; done | sort | tr '\n' ' ' | sed 's/ $//')"
  R_SET="$(printf '%s' "$README_NAMES" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const o=JSON.parse(s);console.log(o.names.join(" "))}catch(e){console.log("__PARSE_ERR__")}})')"
  R_TABLE="$(printf '%s' "$README_NAMES" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const o=JSON.parse(s);console.log(o.table.join(" "))}catch(e){console.log("")}})')"
  R_TREE="$(printf '%s' "$README_NAMES" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const o=JSON.parse(s);console.log(o.tree.join(" "))}catch(e){console.log("")}})')"
  if [ "$R_SET" = "__PARSE_ERR__" ]; then
    A3_PROBLEMS="README 抽取失败"
  elif [ "$R_SET" != "$DIR_NAMES" ]; then
    A3_PROBLEMS="README 的 skill 清单集合=[$R_SET] 与实际目录集合=[$DIR_NAMES] 不相等"
  else
    case " $R_SET " in *" defect-verify "*) ;; *) A3_PROBLEMS="README 的清单里没有 defect-verify" ;; esac
  fi
  case " $R_TABLE " in *" defect-verify "*) ;; *) A3_PROBLEMS="$A3_PROBLEMS [defect-verify 没出现在 skill 表格里]" ;; esac
  case " $R_TREE " in *" defect-verify "*) ;; *) A3_PROBLEMS="$A3_PROBLEMS [defect-verify 没出现在安装树代码块里]" ;; esac
fi
if [ -z "$A3_PROBLEMS" ]; then ok "$A3" "$A3"; else bad "$A3" "$A3"; printf '  · %s\n' "$A3_PROBLEMS" >> "$RES_DIR/$A3.res"; fi

step "AC-004 新产物不得打破既有目录契约"
A4="AC-004"
A4_PROBLEMS=""
VL="$TCD/scripts/verify-layout.mjs"
if [ ! -f "$VL" ]; then
  A4_PROBLEMS="缺 $VL（前置条件不满足）"
else
  PROJ="$WORK/proj-layout"
  mkdir -p "$PROJ/test-assets/environments" "$PROJ/test-assets/suites/REQ-001-coupon" \
           "$PROJ/test-assets/cycles/R1-REQ-001" "$PROJ/test-assets/cycles/R3-DEMO"
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
  cat > "$PROJ/test-assets/cycles/R3-DEMO/cycle.json" <<'EOF'
{ "cycle_id":"R3-DEMO","round":"R3","round_type":"defect-verify","requirement":"REQ-001",
  "scopes":["functional"],"scopes_skipped":[],"status":"in_progress",
  "stages":{"clarify":{"status":"done"},"design":{"status":"in_progress"}},
  "history":[{"at":"2026-11-11T18:00:00+08:00","from":"planned","to":"in_progress","by":"seed"}],
  "trigger":{"type":"defect","ref":"BUG-001"} }
EOF
  cat > "$PROJ/test-assets/cycles/index.json" <<'EOF'
{ "cycles":[{"id":"R1-REQ-001","round":"R1","status":"in_progress","cases_total":0,"cases_passed":0,"bugs_found":0},
            {"id":"R3-DEMO","round":"R3","status":"in_progress","cases_total":0,"cases_passed":0,"bugs_found":0}] }
EOF
  printf '.test-artifacts/\n' > "$PROJ/.gitignore"
  # 本 REQ 的产物落轮次目录（与 cycle.json 同级）
  printf '{"schema_version":2,"defects":[],"cases":[]}\n' > "$PROJ/test-assets/cycles/R3-DEMO/defect-cases.json"
  VL_OUT="$(node "$VL" "$PROJ" 2>&1)"; VL_RC=$?
  VL_FAILS="$(printf '%s\n' "$VL_OUT" | grep -c '^\[FAIL\]' || true)"
  case "$VL_FAILS" in ''|*[!0-9]*) VL_FAILS=99 ;; esac
  # 错误位置探针：必须给出明确结论（二选一），不得两种结论都不给
  A4_CONC="不可判定：错误位置探针没布置成功"
  PROJ2="$WORK/proj-layout-wrongpos"
  cp -r "$PROJ" "$PROJ2" 2>/dev/null
  mkdir -p "$PROJ2/test-assets/cycles"
  mv "$PROJ2/test-assets/cycles/R3-DEMO/defect-cases.json" "$PROJ2/test-assets/defect-cases.json" 2>/dev/null
  if [ -f "$PROJ2/test-assets/defect-cases.json" ]; then
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

# ---------------------------------------------------------------- B 组（缺陷单校验）

step "B 组：缺陷单校验（AC-005 ~ AC-008）"

run_bad_defects() { # $1 = 描述, $2 = 缺陷单文件, $3 = 必须点名的关键词（空格分隔，任一命中即可）
  local desc="$1" file="$2"; shift 2
  local proj="$WORK/bad-$(echo "$desc" | tr -c 'a-zA-Z0-9' '_')"
  mkdir -p "$proj"
  cp -r "$FX/proj"/. "$proj"/ 2>/dev/null
  node "$MAKE" --defects "$file" --cases "$CASES_FX" --suite "$SUITE_ID" \
    --cycle-dir "$proj/$CYCLE_REL" >"$WORK/bad.out" 2>"$WORK/bad.err"
  local rc=$?
  local problems=""
  [ "$rc" -eq 1 ] || problems="$problems [$desc: 退出码=$rc，要求 1（输入非法）]"
  local hit=0
  for kw in "$@"; do grep -q -- "$kw" "$WORK/bad.err" && hit=1; done
  [ "$hit" -eq 1 ] || problems="$problems [$desc: stderr 里没有点名坏点（期望含: $*）]"
  if [ -e "$proj/$CYCLE_REL/defect-cases.json" ]; then
    problems="$problems [$desc: 留下了 defect-cases.json（半份产物，$(wc -c <"$proj/$CYCLE_REL/defect-cases.json" 2>/dev/null | tr -d ' ') 字节）]"
  fi
  printf '  · %s → rc=%s stderr=%s\n' "$desc" "$rc" "$(head -2 "$WORK/bad.err" | tr '\n' ' ')" >&2
  printf '%s' "$problems"
}

if [ ! -f "$MAKE" ]; then
  bad "AC-005 缺 scripts/make-defect-cases.mjs —— 无法执行本条（实现未交付）" "AC-005"
  bad "AC-006 缺 scripts/make-defect-cases.mjs —— 无法执行本条（实现未交付）" "AC-006"
  bad "AC-007 缺 scripts/make-defect-cases.mjs —— 无法执行本条（实现未交付）" "AC-007"
  bad "AC-008 缺 scripts/make-defect-cases.mjs —— 无法执行本条（实现未交付）" "AC-008"
else
  BAD_DIR="$WORK/bad-defects"
  mkdir -p "$BAD_DIR"

  # AC-005：必填字段缺失 / 类型错
  A5_PROBLEMS=""
  for variant in no-id no-title no-severity repro-string; do
    f="$BAD_DIR/$variant.json"
    node -e '
const fs=require("fs");
const src=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
const v=process.argv[2];
if(v==="no-id") delete src.defects[0].id;
else if(v==="no-title") delete src.defects[0].title;
else if(v==="no-severity") delete src.defects[0].severity;
else if(v==="repro-string") src.defects[0].reproduction="not-an-object";
fs.writeFileSync(process.argv[3],JSON.stringify(src,null,2)+"\n");
' "$DEFECTS_FX" "$variant" "$f"
    case "$variant" in
      no-id) P5="$(run_bad_defects "缺陷单缺 id" "$f" "id")" ;;
      no-title) P5="$(run_bad_defects "缺陷单缺 title" "$f" "title")" ;;
      no-severity) P5="$(run_bad_defects "缺陷单缺 severity" "$f" "severity")" ;;
      repro-string) P5="$(run_bad_defects "reproduction 不是对象" "$f" "reproduction")" ;;
    esac
    [ -n "$P5" ] && A5_PROBLEMS="$A5_PROBLEMS $P5"
  done
  if [ -z "$A5_PROBLEMS" ]; then ok "AC-005" "AC-005"; else bad "AC-005" "AC-005"; printf '  ·%s\n' "$A5_PROBLEMS" >> "$RES_DIR/AC-005.res"; fi

  # AC-006：非法输入（根不是对象 / defects 不是数组 / 非法 JSON）
  A6_PROBLEMS=""
  printf '[]\n' > "$BAD_DIR/root-array.json"
  printf '{"defects":{}}\n' > "$BAD_DIR/defects-not-array.json"
  printf '{ not json\n' > "$BAD_DIR/not-json.json"
  P6="$(run_bad_defects "根不是对象" "$BAD_DIR/root-array.json" "defects" "defects.json" "根")"
  [ -n "$P6" ] && A6_PROBLEMS="$A6_PROBLEMS $P6"
  P6="$(run_bad_defects "defects 不是数组" "$BAD_DIR/defects-not-array.json" "defects")"
  [ -n "$P6" ] && A6_PROBLEMS="$A6_PROBLEMS $P6"
  P6="$(run_bad_defects "缺陷单不是合法 JSON" "$BAD_DIR/not-json.json" "defects.json" "JSON" "JSON")"
  [ -n "$P6" ] && A6_PROBLEMS="$A6_PROBLEMS $P6"
  if [ -z "$A6_PROBLEMS" ]; then ok "AC-006" "AC-006"; else bad "AC-006" "AC-006"; printf '  ·%s\n' "$A6_PROBLEMS" >> "$RES_DIR/AC-006.res"; fi

  # AC-007：id 唯一 + 格式
  A7_PROBLEMS=""
  node -e '
const fs=require("fs");const src=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
src.defects[1].id="BUG-001";fs.writeFileSync(process.argv[2],JSON.stringify(src,null,2)+"\n");
' "$DEFECTS_FX" "$BAD_DIR/dup-id.json"
  node -e '
const fs=require("fs");const src=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
src.defects[0].id="BUG-XYZ";fs.writeFileSync(process.argv[2],JSON.stringify(src,null,2)+"\n");
' "$DEFECTS_FX" "$BAD_DIR/bad-id.json"
  P7="$(run_bad_defects "缺陷 id 重复" "$BAD_DIR/dup-id.json" "BUG-001" "重复" "unique")"
  [ -n "$P7" ] && A7_PROBLEMS="$A7_PROBLEMS $P7"
  P7="$(run_bad_defects "缺陷 id 格式错" "$BAD_DIR/bad-id.json" "BUG-XYZ" "id")"
  [ -n "$P7" ] && A7_PROBLEMS="$A7_PROBLEMS $P7"
  if [ -z "$A7_PROBLEMS" ]; then ok "AC-007" "AC-007"; else bad "AC-007" "AC-007"; printf '  ·%s\n' "$A7_PROBLEMS" >> "$RES_DIR/AC-007.res"; fi

  # AC-008：severity / status 枚举
  A8_PROBLEMS=""
  node -e '
const fs=require("fs");const src=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
src.defects[0].severity="critical";fs.writeFileSync(process.argv[2],JSON.stringify(src,null,2)+"\n");
' "$DEFECTS_FX" "$BAD_DIR/bad-severity.json"
  node -e '
const fs=require("fs");const src=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
src.defects[1].status="reopened";fs.writeFileSync(process.argv[2],JSON.stringify(src,null,2)+"\n");
' "$DEFECTS_FX" "$BAD_DIR/bad-status.json"
  P8="$(run_bad_defects "severity 越界" "$BAD_DIR/bad-severity.json" "severity" "critical")"
  [ -n "$P8" ] && A8_PROBLEMS="$A8_PROBLEMS $P8"
  P8="$(run_bad_defects "status 越界" "$BAD_DIR/bad-status.json" "status" "reopened")"
  [ -n "$P8" ] && A8_PROBLEMS="$A8_PROBLEMS $P8"
  if [ -z "$A8_PROBLEMS" ]; then ok "AC-008" "AC-008"; else bad "AC-008" "AC-008"; printf '  ·%s\n' "$A8_PROBLEMS" >> "$RES_DIR/AC-008.res"; fi
fi

# ---------------------------------------------------------------- F 组（写入权）

step "AC-025 不得修改输入（缺陷单 + 已有用例集）"
A25="AC-025"
A25_PROBLEMS=""
if [ "$RC_MAIN" -ne 0 ] || [ ! -s "$OUT_MAIN/defect-cases.json" ]; then
  A25_PROBLEMS="实现没跑通或没产出产物，无法验证输入是否被改写"
else
  INPUTS_AFTER="$(node "$WORK/snapdir.mjs" "$FX/inputs" 2>/dev/null)"
  if [ -z "$INPUTS_BEFORE" ] || [ "$INPUTS_BEFORE" != "$INPUTS_AFTER" ]; then
    A25_PROBLEMS="输入目录（缺陷单 + 用例集）被改动: $(diff <(printf '%s\n' "$INPUTS_BEFORE") <(printf '%s\n' "$INPUTS_AFTER") 2>/dev/null | head -6 | tr '\n' ' ')"
  fi
fi
if [ -z "$A25_PROBLEMS" ]; then ok "$A25" "$A25"; else bad "$A25" "$A25"; printf '  · %s\n' "$A25_PROBLEMS" >> "$RES_DIR/$A25.res"; fi

step "AC-026 只写自己的目录"
A26="AC-026"
A26_PROBLEMS=""
if [ "$RC_MAIN" -ne 0 ] || [ ! -s "$OUT_MAIN/defect-cases.json" ]; then
  A26_PROBLEMS="实现没跑通或没产出产物，无法验证落位与覆盖保护"
else
  # ② cycle.json 逐字节未变
  CYC_NOW="$(sha256sum "$OUT_MAIN/cycle.json" 2>/dev/null | cut -d' ' -f1)"
  CYC_WANT="$(sha256sum "$FX/proj/$CYCLE_REL/cycle.json" 2>/dev/null | cut -d' ' -f1)"
  [ -n "$CYC_NOW" ] && [ "$CYC_NOW" = "$CYC_WANT" ] || A26_PROBLEMS="$A26_PROBLEMS [cycle.json 被改写]"
  # ③ 输入所在目录无散落文件（AC-025 已比过内容，这里再比目录清单）
  STRAY="$(find "$FX/inputs" -type f 2>/dev/null | wc -l | tr -d ' ')"
  [ "${STRAY:-0}" -eq 2 ] || A26_PROBLEMS="$A26_PROBLEMS [输入目录里有散落文件（现在 ${STRAY:-0} 个文件，要求 2 个）]"
  # ④ 覆盖保护：预先放一个占位产物，再跑一次 → 必须报错退出且占位内容未被改写
  PROJ_OVR="$WORK/run-overwrite"
  mkdir -p "$PROJ_OVR"
  cp -r "$FX/proj"/. "$PROJ_OVR"/ 2>/dev/null
  printf '{"placeholder":true}\n' > "$PROJ_OVR/$CYCLE_REL/defect-cases.json"
  OVR_BEFORE="$(sha256sum "$PROJ_OVR/$CYCLE_REL/defect-cases.json" 2>/dev/null | cut -d' ' -f1)"
  run_make "$PROJ_OVR" >/dev/null 2>&1
  OVR_RC=$?
  OVR_AFTER="$(sha256sum "$PROJ_OVR/$CYCLE_REL/defect-cases.json" 2>/dev/null | cut -d' ' -f1)"
  [ "$OVR_RC" -ne 0 ] || A26_PROBLEMS="$A26_PROBLEMS [产物已存在时仍然退出码 0（必须报错退出，不得覆盖）]"
  [ "$OVR_BEFORE" = "$OVR_AFTER" ] || A26_PROBLEMS="$A26_PROBLEMS [产物已存在时被覆盖了]"
  # ⑤ 项目里除允许位置外没有别的 defect-cases.json
  STRAY2="$(find "$PROJ_MAIN" -name 'defect-cases.json' -type f 2>/dev/null | grep -v "^$OUT_MAIN/defect-cases.json$" | tr '\n' ' ')"
  [ -z "$STRAY2" ] || A26_PROBLEMS="$A26_PROBLEMS [项目里出现了别处的 defect-cases.json: $STRAY2]"
fi
if [ -z "$A26_PROBLEMS" ]; then ok "$A26" "$A26"; else bad "$A26" "$A26"; printf '  · %s\n' "$A26_PROBLEMS" >> "$RES_DIR/$A26.res"; fi

# ---------------------------------------------------------------- G 组（轮次 / 组合门 / 追溯）

step "AC-027 R3 轮次契约（且不得改写 cycle.json）"
A27="AC-027"
A27_PROBLEMS=""
if [ ! -f "$MAKE" ]; then
  A27_PROBLEMS="缺 scripts/make-defect-cases.mjs —— 无法执行本条（实现未交付）"
else
  CYC_MAIN_SHA="$(sha256sum "$OUT_MAIN/cycle.json" 2>/dev/null | cut -d' ' -f1)"
  CYC_FIX_SHA="$(sha256sum "$FX/proj/$CYCLE_REL/cycle.json" 2>/dev/null | cut -d' ' -f1)"
  [ -n "$CYC_MAIN_SHA" ] && [ "$CYC_MAIN_SHA" = "$CYC_FIX_SHA" ] || A27_PROBLEMS="$A27_PROBLEMS [cycle.json 被改写（工具只读不改写）]"
  for variant in round-not-r3 trigger-unknown; do
    PROJ_C="$WORK/cycle-$variant"
    mkdir -p "$PROJ_C"
    cp -r "$FX/proj"/. "$PROJ_C"/ 2>/dev/null
    if [ "$variant" = "round-not-r3" ]; then
      node -e '
const fs=require("fs");const f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));
o.round="R2";fs.writeFileSync(f,JSON.stringify(o,null,2)+"\n");' "$PROJ_C/$CYCLE_REL/cycle.json"
      KWS="round R3 R2"
    else
      node -e '
const fs=require("fs");const f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));
o.trigger={type:"defect",ref:"BUG-999"};fs.writeFileSync(f,JSON.stringify(o,null,2)+"\n");' "$PROJ_C/$CYCLE_REL/cycle.json"
      KWS="BUG-999 trigger"
    fi
    node "$MAKE" --defects "$DEFECTS_FX" --cases "$CASES_FX" --suite "$SUITE_ID" \
      --cycle-dir "$PROJ_C/$CYCLE_REL" >"$WORK/cyc.out" 2>"$WORK/cyc.err"
    rc=$?
    [ "$rc" -eq 1 ] || A27_PROBLEMS="$A27_PROBLEMS [$variant: 退出码=$rc，要求 1]"
    hit=0; for kw in $KWS; do grep -q -- "$kw" "$WORK/cyc.err" && hit=1; done
    [ "$hit" -eq 1 ] || A27_PROBLEMS="$A27_PROBLEMS [$variant: stderr 没点名坏点]"
    [ ! -e "$PROJ_C/$CYCLE_REL/defect-cases.json" ] || A27_PROBLEMS="$A27_PROBLEMS [$variant: 留下了 defect-cases.json]"
    printf '  · %s → rc=%s stderr=%s\n' "$variant" "$rc" "$(head -2 "$WORK/cyc.err" | tr '\n' ' ')"
  done
fi
if [ -z "$A27_PROBLEMS" ]; then ok "$A27" "$A27"; else bad "$A27" "$A27"; printf '  · %s\n' "$A27_PROBLEMS" >> "$RES_DIR/$A27.res"; fi

step "AC-028 组合门必须真的跑过 defect-verify"
A28="AC-028"
A28_PROBLEMS=""
VERIFY_ROOT="$WORK/verifyroot"
mkdir -p "$VERIFY_ROOT"
if [ ! -f "$INSTALLER" ]; then
  A28_PROBLEMS="缺 bin/test-agent-skills.mjs"
else
  VERIFY_OUT="$(node "$INSTALLER" verify --root "$VERIFY_ROOT" 2>&1)"; VERIFY_RC=$?
  [ "$VERIFY_RC" -ne 0 ] && A28_PROBLEMS="$A28_PROBLEMS [verify 退出码=$VERIFY_RC out=$(printf '%s' "$VERIFY_OUT" | head -3 | tr '\n' ' ')]"
  INSTALLED="$(ls -1 "$VERIFY_ROOT/skills" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
  EXPECT_SKILLS="$(for d in $SKILL_DIRS; do basename "$d"; done | sort | tr '\n' ' ' | sed 's/ $//')"
  [ "$INSTALLED" = "$EXPECT_SKILLS" ] || A28_PROBLEMS="$A28_PROBLEMS [临时根装的是 [$INSTALLED]，被验包的 skill 是 [$EXPECT_SKILLS]]"
  case " $INSTALLED " in *" defect-verify "*) ;; *) A28_PROBLEMS="$A28_PROBLEMS [临时根没有装 defect-verify]" ;; esac
  printf '%s' "$VERIFY_OUT" | grep -q '依赖图校验通过' || A28_PROBLEMS="$A28_PROBLEMS [输出里没有「依赖图校验通过」]"
  printf '%s' "$VERIFY_OUT" | grep -q '\[version\]' && A28_PROBLEMS="$A28_PROBLEMS [依赖图报了版本问题]"
  SCEN="$(printf '%s' "$VERIFY_OUT" | grep -c '组合场景' || true)"
  [ "${SCEN:-0}" -ge 1 ] || A28_PROBLEMS="$A28_PROBLEMS [输出里没有组合场景的实跑记录]"
  printf '%s' "$VERIFY_OUT" | grep -q '组合场景失败' && A28_PROBLEMS="$A28_PROBLEMS [组合场景失败]"
  # ③ 至少有一条组合场景**真的经过 defect-verify**（产物反推；文本只作辅助证据）
  SCEN_DV="$(printf '%s' "$VERIFY_OUT" | grep -E '组合场景' | grep -E 'defect-verify|make-defect-cases' | head -1)"
  if [ -z "$SCEN_DV" ]; then
    A28_PROBLEMS="$A28_PROBLEMS [没有一条组合场景真的经过 defect-verify（只装不跑 ⇒ 判红）]"
  else
    DV_ARTS="$(find "$VERIFY_ROOT" -path "$VERIFY_ROOT/skills" -prune -o -type f -name 'defect-cases.json' -size +0c -print 2>/dev/null)"
    DV_ART=""
    ART_PROB=""
    while IFS= read -r cand; do
      [ -n "$cand" ] || continue
      probe="$(node -e '
const fs=require("fs");
let o=null;
try{o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));}catch(e){console.log("defect-cases.json 不是合法 JSON");process.exit(0);}
if(!o||typeof o!=="object"){console.log("defect-cases.json 根节点不是对象");process.exit(0);}
const defects=Array.isArray(o.defects)?o.defects:[];
const cases=Array.isArray(o.cases)?o.cases:[];
const problems=[];
if(defects.length===0)problems.push("defects[] 为空 —— 组合场景没有真的跑出缺陷处置");
if(cases.length===0)problems.push("cases[] 为空 —— 组合场景没有真的跑出复现用例");
for(const d of defects){
  if(!d||typeof d!=="object"){problems.push("defects[] 里有非对象条目");continue;}
  const disp=d.disposition;
  if(!["derived","reused","unresolved"].includes(disp)){problems.push("disposition="+JSON.stringify(disp)+" 不在枚举内");continue;}
  if(disp==="derived"){
    const hit=cases.some(c=>c&&c.id===d.derived_case_id);
    if(!hit)problems.push("derived 的缺陷 "+d.id+" 没有对应的用例");
  }
  if(disp==="reused"&&!(Array.isArray(d.reused_case_refs)&&d.reused_case_refs.length>0))problems.push("reused 的缺陷 "+d.id+" 没有 reused_case_refs");
}
const ids=cases.filter(c=>c&&typeof c.id==="string").map(c=>c.id);
if(new Set(ids).size!==ids.length)problems.push("cases[] 的 id 有重复");
console.log(problems.length===0?"OK":problems.join("; "));
' "$cand" 2>/dev/null)"
      if [ "$probe" = "OK" ]; then DV_ART="$cand"; ART_PROB="OK"; break; fi
      if [ -z "$ART_PROB" ]; then ART_PROB="$probe"; DV_ART="$cand"; fi
    done <<QA007_ARTS
$DV_ARTS
QA007_ARTS
    if [ -z "$DV_ART" ]; then
      A28_PROBLEMS="$A28_PROBLEMS [组合场景声称经过 defect-verify，但临时根里没有真的产出**非空** defect-cases.json —— 只装不跑 ⇒ 判红]"
    elif [ "$ART_PROB" != "OK" ]; then
      A28_PROBLEMS="$A28_PROBLEMS [临时根产出的 defect-cases.json 不合格: $ART_PROB]"
    fi
  fi
  # ④ 版本错配时报**版本问题**（不是下游业务错）
  BADPKG="$WORK/badpkg"
  mkdir -p "$BADPKG"
  cp -r "$PKG"/. "$BADPKG"/ 2>/dev/null
  if [ -s "$BADPKG/skills/defect-verify/skill-meta.json" ]; then
    node -e '
const fs=require("fs");const f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));
o.requires=o.requires||{};o.requires["test-execute"]=">=99.0.0";fs.writeFileSync(f,JSON.stringify(o,null,2));
' "$BADPKG/skills/defect-verify/skill-meta.json" 2>/dev/null
    mkdir -p "$WORK/badroot"
    BADV_OUT="$(node "$BADPKG/bin/test-agent-skills.mjs" verify --root "$WORK/badroot" 2>&1)"; BADV_RC=$?
    [ "$BADV_RC" -ne 0 ] || A28_PROBLEMS="$A28_PROBLEMS [把 defect-verify 的 requires 改成 >=99.0.0 后 verify 仍然退出码 0 —— 依赖图没校验]"
    printf '%s' "$BADV_OUT" | grep -q 'defect-verify' || A28_PROBLEMS="$A28_PROBLEMS [版本错配的输出没有点名 defect-verify]"
    printf '%s' "$BADV_OUT" | grep -q '99.0.0' || A28_PROBLEMS="$A28_PROBLEMS [版本错配的输出没有给出要求的版本值]"
    if printf '%s' "$BADV_OUT" | grep -qiE '缺少必填字段|expected'; then
      A28_PROBLEMS="$A28_PROBLEMS [版本错配的输出里出现了下游业务错的特征串]"
    fi
  else
    A28_PROBLEMS="$A28_PROBLEMS [副本里没有 defect-verify/skill-meta.json，无法做版本错配探针]"
  fi
fi
if [ -z "$A28_PROBLEMS" ]; then ok "$A28" "$A28"; else bad "$A28" "$A28"; printf '  · %s\n' "$A28_PROBLEMS" >> "$RES_DIR/$A28.res"; fi

step "AC-029 交付侧记账必须与实际一致"
A29="AC-029"
A29_PROBLEMS=""
DV_META="$FEATURE_META/defect-verify"
for f in status.md traceability.md verification-report.md manifest.json; do
  [ -s "$DV_META/$f" ] || A29_PROBLEMS="$A29_PROBLEMS [缺 feature-meta/defect-verify/$f 或为空]"
done
if [ -s "$DV_META/manifest.json" ]; then
  MY_REQ="$(node -e 'try{console.log(String(require(process.argv[1]).req||""))}catch(e){console.log("__ERR__")}' "$DV_META/manifest.json" 2>/dev/null)"
  [ "$MY_REQ" = "REQ-007" ] || A29_PROBLEMS="$A29_PROBLEMS [feature-meta/defect-verify/manifest.json 的 req=$MY_REQ，要求 REQ-007]"
fi
# 既有追溯件不得被改写（根四件套 + test-report / regression-plan 子目录）
ROOT_MANIFEST="$FEATURE_META/manifest.json"
if [ -s "$ROOT_MANIFEST" ]; then
  ROOT_REQ="$(node -e 'try{console.log(String(require(process.argv[1]).req||""))}catch(e){console.log("__ERR__")}' "$ROOT_MANIFEST" 2>/dev/null)"
  [ "$ROOT_REQ" = "REQ-006" ] || A29_PROBLEMS="$A29_PROBLEMS [feature-meta/manifest.json 的 req=$ROOT_REQ（REQ-006 的既有追溯件不得被改写）]"
fi
for sub in test-report regression-plan; do
  for f in status.md traceability.md verification-report.md manifest.json; do
    [ -s "$FEATURE_META/$sub/$f" ] || A29_PROBLEMS="$A29_PROBLEMS [缺 feature-meta/$sub/$f —— 既有追溯件不得被改写或删除]"
  done
done
# 判据条数（动态）与决策号集合（动态）
DEC_SET="$(grep -oE '^\| D[0-9]+' "$DECISIONS" 2>/dev/null | grep -oE 'D[0-9]+' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
EXPECT_IDS="$(grep -oE '^### (AC-[0-9]+)' "$ACCEPTANCE" 2>/dev/null | grep -oE 'AC-[0-9]+' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
EXPECT_ROWS="$(printf '%s' "$EXPECT_IDS" | tr ' ' '\n' | grep -cE '^AC-[0-9]+$')"
if [ -s "$DV_META/traceability.md" ]; then
  MATRIX_IDS="$(grep -E '^\|[[:space:]]*AC-[0-9]+' "$DV_META/traceability.md" 2>/dev/null | grep -oE 'AC-[0-9]+' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  MATRIX_ROWS="$(grep -cE '^\|[[:space:]]*AC-[0-9]+' "$DV_META/traceability.md" 2>/dev/null || true)"
  case "$MATRIX_ROWS" in ''|*[!0-9]*) MATRIX_ROWS=0 ;; esac
  [ "$MATRIX_ROWS" -eq "$EXPECT_ROWS" ] || A29_PROBLEMS="$A29_PROBLEMS [追溯矩阵行数=$MATRIX_ROWS，要求 $EXPECT_ROWS 行（== acceptance.md 的实际判据条数）]"
  [ "$MATRIX_IDS" = "$EXPECT_IDS" ] || A29_PROBLEMS="$A29_PROBLEMS [追溯矩阵的 AC 编号集合=[$MATRIX_IDS]，要求恰好 [$EXPECT_IDS]]"
fi
# 三份 md 的判据条数与决策号范围必须**取值唯一**
EXPECT_DEC_SET="$DEC_SET"
for f in status.md traceability.md verification-report.md; do
  if [ ! -s "$DV_META/$f" ]; then continue; fi
  # 接受两种写法：「29 条判据」与「判据条数：**29**」——
  #   两种写法抽出来的数字集合都必须 == {实际条数}（出现第二个不同取值即判红）。
  NUMSET="$(grep -oE '[0-9]+[[:space:]]*条判据|判据条数[^0-9]{0,8}[0-9]+' "$DV_META/$f" 2>/dev/null \
    | grep -oE '[0-9]+' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  if [ -z "$NUMSET" ]; then
    A29_PROBLEMS="$A29_PROBLEMS [$f 里没有记载判据条数]"
  elif [ "$NUMSET" != "$AC_COUNT" ]; then
    A29_PROBLEMS="$A29_PROBLEMS [$f 的判据条数取值集合=[$NUMSET]，要求恰好 {${AC_COUNT}}（出现第二个不同取值即判红）]"
  fi
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
' "$DV_META/$f" 2>/dev/null)"
  [ "$MDS" = "$EXPECT_DEC_SET" ] || A29_PROBLEMS="$A29_PROBLEMS [$f 的决策号取值集合=[$MDS]，要求恰好 {${EXPECT_DEC_SET}}（出现第二个不同取值即判红）]"
done
printf '  · 实现侧追溯范围: 取 decisions.md 的实际决策号集合=[%s]（取值唯一；重复引用同一取值不算多处记载）\n' "$EXPECT_DEC_SET"
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
#   基线失败键 = 基线运行里**失败**的判据编号（**只取 FAIL 行** —— PASS/UNDEC 的 .res 里也有
#   AC 编号，混进来会让基线键集合变成全集，此后任何变异的「新增失败键」都恒等于全集 ⇒
#   整套检测沦为橡皮章而门仍然 exit 0。REQ-010 的最致命一处缺陷，本门不得重蹈）。
#   新增失败键 = 变异运行的失败键 减去 基线失败键（整行精确排除）。
#   检出 = 目标判据出现在**新增**失败键里。
#   ⚠️ 不用「对称差」：对称差把「基线红、变异后绿」也算成变化，那是噪声不是检出。

if [ "${REQ007_NO_MUT:-0}" = "1" ]; then
  printf '\n变异体套件: 已跳过（REQ007_NO_MUT=1）—— 不可判定，不计入通过；检出率结论以完整模式为准\n'
  MUT_NOTE="跳过"
else
  step "变异体套件（5 个正控 + 1 个负控；检测口径 = 新增失败键）"

  # ① 基线失败键（**只取 FAIL 行**）
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
    mout="$(REQ007_NO_MUT=1 QA007_SCRIPT_SHA= bash "$SELF" "$mpkg" 2>&1)"
    mf="$(printf '%s\n' "$mout" | sed 's/\x1b\[[0-9;]*m//g' | grep -E '^[[:space:]]*FAIL' | grep -oE 'AC-[0-9]+' | LC_ALL=C sort -u | grep -v '^$' || true)"
    comm -13 "$WORK/base_fails.txt" <(printf '%s\n' "$mf") | tr '\n' ' ' | sed 's/ $//'
  }

  # ③ 注入包装层（shim）：原实现 move 到 make-defect-cases.real.mjs，包装层跑完原实现后篡改产物
  #    $1 = 变异体包目录, $2 = 篡改代码
  #    ⚠️ 包装层必须**保留原文件的权限位**（`cat >` 新建的文件会拿到 umask 默认值 644）——
  #    否则包装层自身「不可执行」，AC-001 的逐脚本判定会把每个变异体都判红，
  #    负控 M0 也会被误报成「已检出」⇒ 门自己把自己的工装当成了变异缺陷。
  inject_shim() {
    local mpkg="$1" code="$2"
    local entry="$mpkg/skills/defect-verify/scripts/make-defect-cases.mjs"
    local mode; mode="$(stat -c '%a' "$entry" 2>/dev/null || echo 755)"
    mv "$entry" "$mpkg/skills/defect-verify/scripts/make-defect-cases.real.mjs" 2>/dev/null || return 1
    cat > "$entry" <<SHIMEOF
#!/usr/bin/env node
// 变异体包装层（仅存在于变异副本里）：先跑原实现，再对产物做一处语义篡改。
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const real = path.join(here, 'make-defect-cases.real.mjs');
const args = process.argv.slice(2);
const run = spawnSync(process.execPath, [real, ...args], { stdio: 'inherit' });
const code = run.status === null ? 1 : run.status;
if (code === 0) {
  const argOf = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : null; };
  const outDir = argOf('--out-dir') || argOf('--cycle-dir') || '';
  const file = path.join(outDir, 'defect-cases.json');
  if (fs.existsSync(file)) {
    const report = JSON.parse(fs.readFileSync(file, 'utf8'));
    ${code}
    fs.writeFileSync(file, JSON.stringify(report, null, 2) + '\n');
  }
}
process.exit(code);
SHIMEOF
    chmod "$mode" "$entry" 2>/dev/null || true
    return 0
  }

  MUT_NAMES=(
    "case_refs 命中的缺陷被改判成 derived"
    "产物里少了一条缺陷条目"
    "unresolved 的理由被清空"
    "派生用例的 id 撞上输入用例集的号"
    "派生用例的 tags 漏了缺陷 id"
  )
  MUT_CODE=(
    "if (report.defects && report.defects[0]) { report.defects[0].disposition = 'derived'; delete report.defects[0].reused_case_refs; }"
    "if (Array.isArray(report.defects)) { report.defects = report.defects.filter((d) => d && d.id !== 'BUG-005'); }"
    "if (report.defects && report.defects[3]) { report.defects[3].reason = ''; }"
    "if (Array.isArray(report.cases)) { for (const c of report.cases) { if (c && c.origin === 'derived') { c.id = 'TC-005'; } } } if (report.defects && report.defects[4]) { report.defects[4].derived_case_id = 'TC-005'; }"
    "if (Array.isArray(report.cases)) { for (const c of report.cases) { if (c && c.origin === 'derived') { c.tags = (c.tags || []).filter((t) => t !== 'BUG-005'); } } }"
  )
  MUT_TARGETS=(
    "AC-009"
    "AC-020"
    "AC-021"
    "AC-013"
    "AC-018"
  )
  MUT_REQUIRED=4

  for i in "${!MUT_NAMES[@]}"; do
    NAME="${MUT_NAMES[$i]}"
    TARGET="${MUT_TARGETS[$i]}"
    CODE="${MUT_CODE[$i]}"
    MUTPKG="$WORK/mut-$i"
    mkdir -p "$MUTPKG"
    cp -r "$PKG"/. "$MUTPKG"/ 2>/dev/null
    ENTRY_REL="skills/defect-verify/scripts/make-defect-cases.mjs"
    ENTRY="$MUTPKG/$ENTRY_REL"
    STATUS="有效"
    # 自证 ①：入口脚本在副本里**逐字唯一命中 1 次**
    #   ⚠️ 两种「无效」要分开说：入口脚本**不存在** = **实现未交付**（不是门侧问题）；
    #      入口存在但命中数 ≠ 1 = **门侧锚点不可达**（不唯一）。
    if [ ! -f "$ENTRY" ]; then
      STATUS="**实现缺失**：$ENTRY_REL 不存在 —— 变异体无法注入；这是实现未交付，不是门侧问题"
      MUT_MISSING_IMPL=1
    else
      HITS="$(node "$WORK/pkgfiles.mjs" "$MUTPKG" "$ENTRY_REL" 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).length)}catch(e){console.log(0)}})')"
      if [ "${HITS:-0}" -ne 1 ]; then
        STATUS="门侧锚点不可达：入口锚点命中 $HITS 次，要求恰好 1 次"
      fi
    fi
    # 注入：把入口脚本换成包装层（原实现 move 到 make-defect-cases.real.mjs）
    if [ "$STATUS" = "有效" ]; then
      BEFORE_SHA="$(sha256sum "$ENTRY" 2>/dev/null | cut -d' ' -f1)"
      inject_shim "$MUTPKG" "$CODE" || STATUS="包装层注入失败"
      AFTER_SHA="$(sha256sum "$ENTRY" 2>/dev/null | cut -d' ' -f1)"
      if [ "$STATUS" = "有效" ]; then
        if [ -z "$BEFORE_SHA" ] || [ "$BEFORE_SHA" = "$AFTER_SHA" ]; then
          STATUS="注入前后 sha256 没变（注入未生效）"
        fi
      fi
      # 自证 ②：结构合法（node --check 通过 + 脚本能正常跑完）
      if [ "$STATUS" = "有效" ]; then
        node --check "$ENTRY" >/dev/null 2>&1 || STATUS="变异后 node --check 不通过"
      fi
      if [ "$STATUS" = "有效" ]; then
        # ⚠️ 变异体的轮次目录必须带 cycle.json（实现要读它做轮次契约校验）
        MUTPROJ="$WORK/mutproj-$i"
        mkdir -p "$MUTPROJ"
        cp -r "$FX/proj"/. "$MUTPROJ"/ 2>/dev/null
        MUTOUT="$MUTPROJ/$CYCLE_REL"
        node "$ENTRY" --defects "$DEFECTS_FX" --cases "$CASES_FX" --suite "$SUITE_ID" \
          --cycle-dir "$MUTOUT" >/dev/null 2>&1
        MRC=$?
        if [ "$MRC" -ne 0 ] || [ ! -s "$MUTOUT/defect-cases.json" ]; then
          STATUS="变异后脚本没正常跑完：rc=$MRC —— 崩溃造成的判红是假检出"
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
  #    它检验的是探测器本身：若 M0 也被报成「已检出」，说明探测器恒真 ⇒ 本门失效。
  #    ⚠️ 无害字段放在 `meta` 里（F4.1：meta 的字段集开放）⇒ 不触发任何判据。
  CTRL_NAME="负控 M0：往 meta 里加一个无害字段（gate_note）"
  CTRLPKG="$WORK/mut-control"
  mkdir -p "$CTRLPKG"
  cp -r "$PKG"/. "$CTRLPKG"/ 2>/dev/null
  CTRL_STATUS="有效"
  if [ ! -f "$CTRLPKG/skills/defect-verify/scripts/make-defect-cases.mjs" ]; then
    CTRL_STATUS="**实现缺失**：skills/defect-verify/scripts/make-defect-cases.mjs 不存在 —— 变异体无法注入；这是实现未交付，不是门侧问题"
    MUT_MISSING_IMPL=1
  elif ! inject_shim "$CTRLPKG" "if (report.meta) { report.meta.gate_note = 'mutant-control'; }"; then
    CTRL_STATUS="包装层注入失败"
  fi
  if [ "$CTRL_STATUS" = "有效" ]; then
    node --check "$CTRLPKG/skills/defect-verify/scripts/make-defect-cases.mjs" >/dev/null 2>&1 \
      || CTRL_STATUS="变异后 node --check 不通过"
  fi
  if [ "$CTRL_STATUS" = "有效" ]; then
    CTRLPROJ="$WORK/ctrlproj"
    mkdir -p "$CTRLPROJ"
    cp -r "$FX/proj"/. "$CTRLPROJ"/ 2>/dev/null
    CTRLOUT="$CTRLPROJ/$CYCLE_REL"
    node "$CTRLPKG/skills/defect-verify/scripts/make-defect-cases.mjs" --defects "$DEFECTS_FX" \
      --cases "$CASES_FX" --suite "$SUITE_ID" --cycle-dir "$CTRLOUT" >/dev/null 2>&1
    CRC=$?
    if [ "$CRC" -ne 0 ] || [ ! -s "$CTRLOUT/defect-cases.json" ]; then
      CTRL_STATUS="变异后脚本没正常跑完：rc=$CRC"
    fi
  fi
  if [ "$CTRL_STATUS" != "有效" ]; then
    MUT_INVALID="$MUT_INVALID [$CTRL_NAME: $CTRL_STATUS]"
    printf '负控 %s: 无效变异（%s）—— 探测器的灵敏度不可判定\n' "$CTRL_NAME" "$CTRL_STATUS"
  else
    CTRL_NEW="$(run_mutant_gate "$CTRLPKG")"
    if [ -z "$CTRL_NEW" ]; then
      MUT_CONTROL_OK=1
      printf '负控 %s: 未检出（新增失败键为空）—— 符合预期，探测器不是恒真\n' "$CTRL_NAME"
    else
      MUT_CONTROL_FAILED="[$CTRL_NAME → 本不该让任何判据变红，却出现新增失败键 [$CTRL_NEW] —— 探测器疑似恒真]"
      printf '负控 %s: 被报成「已检出」（新增失败键=[%s]）—— 门侧缺陷：探测器恒真\n' "$CTRL_NAME" "$CTRL_NEW"
    fi
  fi

  # ⑤ 结论（责任方要指对：「实现缺失」是实现方的问题，「锚点不可达」才是门侧的问题）
  MUT_WHY="门侧注入问题：锚点不可达或注入不生效"
  if [ "$MUT_MISSING_IMPL" -eq 1 ]; then
    MUT_WHY="**实现缺失**：skills/defect-verify/scripts/make-defect-cases.mjs 不存在 —— 变异体无法注入；这是实现未交付，不是门侧问题"
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
printf '被验实现指纹（skills/defect-verify/）: %s\n' "$(node "$WORK/fingerprint.mjs" "$TR" 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1)"
if [ "$MUT_NOTE" = "跳过" ]; then
  printf '变异体套件: 已跳过（REQ007_NO_MUT=1）—— 不可判定，检出率结论以完整模式为准\n'
elif [ -n "$MUT_ESCAPED" ]; then
  printf '变异体套件: %s —— 有变异体逃逸（真缺陷），整体判红\n' "$MUT_NOTE"
elif [ -n "$MUT_CONTROL_FAILED" ]; then
  printf '变异体套件: %s\n' "$MUT_NOTE"
  printf '负控失败：探测器疑似恒真 ⇒ 本门失效（门侧缺陷）—— %s\n' "$MUT_CONTROL_FAILED"
  printf '  （负控本该「未检出」；它被报成「已检出」说明检出判定恒真，本门结论不可采信）\n'
elif [ "$MUT_UNDEC" -eq 1 ]; then
  printf '不可判定: 1 项（变异体套件）—— %s\n' "$MUT_NOTE"
  if [ "$MUT_MISSING_IMPL" -eq 1 ]; then
    printf '  （这是**实现未交付**，不是门侧问题：变异体需要 `skills/defect-verify/scripts/make-defect-cases.mjs` 才能注入。退出码为 1，判据结论仍以上面的 PASS/FAIL 为准）\n'
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
   && { [ "${REQ007_NO_MUT:-0}" = "1" ] || { [ "$MUT_UNDEC" -eq 0 ] \
        && [ "$MUT_TOTAL" -ge "$MUT_REQUIRED" ] && [ "$MUT_DETECTED" -eq "$MUT_TOTAL" ] \
        && [ "$MUT_CONTROL_OK" -eq 1 ]; }; }; then
  exit 0
fi
exit 1
