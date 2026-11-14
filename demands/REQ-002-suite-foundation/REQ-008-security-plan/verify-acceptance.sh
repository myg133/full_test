#!/usr/bin/env bash
# REQ-008 验收脚本 —— `security-plan` skill（安全能力域：OWASP 全套 + 依赖扫描）
#
# 判据集：AC-001~AC-029（条数从 acceptance.md 的 `### AC-` 实际条数动态取，不写死）
#
# 用法: verify-acceptance.sh <package-dir>
#   <package-dir> 指向**被验包根目录**（含 skills/ 与 bin/，以及 feature-meta/、README.md）
#
# 退出码: 0 = 全部通过; 1 = 有 AC 未通过 / 不可判定 / 变异体有逃逸 / 负控失败; 2 = 用法错误
#
# 环境变量:
#   REQ008_NO_MUT=1   跳过变异体套件（快跑 / 嵌套运行用）
#   QA008_SCRIPT_SHA  期望的**本脚本自身** sha256；不匹配即判红并中止
#   QA008_KEEP_WORK=1 保留工作目录（调试）
#   QA008_WORK_ROOT   工作目录的父目录（默认 ${TMPDIR:-/tmp}）
#
# 设计要点（门是被验对象，不是脚手架 —— D65）:
#   - 只读被验包；一切变异都在**副本**上做，绝不在原地改被验对象。
#   - 夹具（安全上下文 / 功能用例集 / 扫描结果 / 最小项目根）一律造在临时目录里。
#   - 产物侧判据用**独立复算器**（内嵌 judge.mjs）：自己重算威胁/矩阵/用例的判定口径，
#     **绝不 import 被验包**；自带独立的解析 / 集合运算 / 枚举实现。
#   - ⚠️ **上游加载层检查单独一个进程**（内嵌 loadcheck.mjs）：它 import 被验包的
#     suite-loader.mjs 调 loadSuite / loadCases / selectCases —— 因为
#     「产品能不能被上游消费」的**唯一**真实答案只能问上游本人（D122）。
#     这与「复算器不 import 被验包」不冲突：复算保持纯净，兼容性问上游。
#   - 判据正文与本脚本的理解有出入时，以 acceptance.md 的判据正文为准；分歧写进本脚本注释。
#   - 变异体套件的注入方式：**入口脚本包装（shim）** —— 把副本里的
#     `skills/security-plan/scripts/make-security-plan.mjs` 换成一层包装，包装调用原实现
#     （原文件 move 到 make-security-plan.real.mjs）后再对**产物**做一处语义篡改。
#   - 变异检出走**新增失败键**（变异运行的失败键 减去 基线失败键，整行精确排除）；
#     **不用**对称差：对称差把「基线红、变异后绿」也算成变化，那是噪声不是检出。
#     ⚠️ **基线失败键只取 `^FAIL` 行** —— PASS / UNDEC 行里也有 AC 编号，混进来会让基线键
#     集合变成**全集**，此后任何变异的「新增失败键」都恒等于全集 ⇒ 整套检测沦为橡皮章，
#     而门仍然 exit 0（REQ-010 的最致命一处缺陷，本门不得重蹈）。
#   - 崩溃造成的判红是假检出，不计入检出率（结构合法性单独自证）。
#   - 变异体套件里有一个**负控 M0**（打不到任何判据的无害篡改）：它必须**未检出**。
#     若 M0 也被报成「已检出」⇒ 探测器恒真 ⇒ 本门失效（门侧缺陷，判红，退出码非 0）。
#   - 有效变异体不足 6 个 ⇒ **不可判定**（门侧注入问题），退出码非 0，但不算被验实现的失败。
#   - **门跑在「没有实现」的真包上必须优雅降级**（D118）：不崩溃，如实报 FAIL / 不可判定。

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

# ---------------------------------------------------------------- 决策号集合（动态取 —— D120）

# 实现侧追溯范围 = decisions.md 的**实际** D 集合（不写死）。
DECISION_IDS=""
DECISION_MIN=""
DECISION_MAX=""
if [ -f "$DECISIONS" ]; then
  DECISION_IDS="$(grep -oE '^## D[0-9]+' "$DECISIONS" 2>/dev/null | grep -oE 'D[0-9]+' | sort -u | tr '\n' ' ')"
fi
# ⚠️ 必须按**数值**排序（`sort -u` 是字典序，会把 D100 排在 D98 前面 ⇒ 与门里的
#    数值序期望集合对不上，AC-029 会假红）。
DECISION_IDS="$(printf '%s\n' $DECISION_IDS | sort -t'D' -k2,2n | tr '\n' ' ' | sed 's/ $//')"
if [ -z "$DECISION_IDS" ]; then
  echo "无法从 $DECISIONS 读到决策号集合 —— 不可判定，不判通过" >&2
  exit 1
fi
DECISION_COUNT="$(printf '%s\n' $DECISION_IDS | wc -l | tr -d ' ')"
DECISION_MIN="$(printf '%s\n' $DECISION_IDS | head -1)"
DECISION_MAX="$(printf '%s\n' $DECISION_IDS | tail -1)"

# ---------------------------------------------------------------- 门禁前置：脚本自身指纹

if [ -n "${QA008_SCRIPT_SHA:-}" ]; then
  SELF_SHA="$(sha256sum "$SELF" 2>/dev/null | cut -d' ' -f1)"
  if [ "$SELF_SHA" != "$QA008_SCRIPT_SHA" ]; then
    echo "FAIL  门禁前置：验收脚本自身 sha256 不符（实际 $SELF_SHA，期望 $QA008_SCRIPT_SHA）" >&2
    echo "结论: 0 PASS / 1 FAIL" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------- 工作目录

WORK_PARENT="${QA008_WORK_ROOT:-${TMPDIR:-/tmp}}"
mkdir -p "$WORK_PARENT" 2>/dev/null || true
WORK="$(mktemp -d "$WORK_PARENT/qa-008-XXXXXX")"
cleanup() {
  # ⚠️ 本机 rm 是 shim（可恢复删除）：清理失败**不得**改变判定。
  if [ "${QA008_KEEP_WORK:-0}" = "1" ]; then
    printf '[debug] 工作目录已保留: %s\n' "$WORK"
    return 0
  fi
  rm -rf "$WORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT

RES_DIR="$WORK/res"
mkdir -p "$RES_DIR"

TR="$PKG/skills/security-plan"
TCD="$PKG/skills/test-case-design"
TEX="$PKG/skills/test-execute"
FEATURE_META="$PKG/feature-meta"
README="$PKG/README.md"

ENTRY_REL="skills/security-plan/scripts/make-security-plan.mjs"
ENTRY="$PKG/$ENTRY_REL"

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

process.stdout.write(`${JSON.stringify({ names: [...names].sort(), table: [...table].sort(), tree: [...tree].sort() })}\n`);
FIXREADME

cat > "$WORK/pkgfiles.mjs" <<'FIXPF'
// pkgfiles.mjs —— 在被验包里找相对路径**逐字**等于给定路径的文件（变异锚点自证）
// 用法: node pkgfiles.mjs <pkg-dir> <relative-path>
// 输出: JSON 数组（命中文件的相对路径）
import fs from 'node:fs';
import path from 'node:path';

const [root, rel] = process.argv.slice(2);
const hits = [];
const walk = (dir) => {
  let entries = [];
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const entry of entries) {
    if (entry.name === '.git' || entry.name === 'node_modules') continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full);
    else if (entry.isFile()) {
      const r = path.relative(root, full).split(path.sep).join('/');
      if (r === rel) hits.push(r);
    }
  }
};
walk(root);
process.stdout.write(`${JSON.stringify(hits)}\n`);
FIXPF

cat > "$WORK/snapdir.mjs" <<'FIXSD'
// snapdir.mjs —— 目录内容的逐字快照（文件列表 + 每个文件的内容 sha256），用于「只读输入」核
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';

const root = process.argv[2];
const lines = [];
const walk = (dir) => {
  let entries = [];
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const entry of entries) {
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
process.stdout.write(`${lines.join('\n')}\n`);
FIXSD

# ---------------------------------------------------------------- 夹具

step "准备夹具（§0：安全上下文 + 功能用例集 + 扫描结果 + 最小项目根）"

cat > "$WORK/mkfixture.mjs" <<'FIXMK'
// mkfixture.mjs —— 按 acceptance.md §0 自造夹具
//   用法: node mkfixture.mjs <fx-dir>
// 产出:
//   <fx>/inputs/context.json            安全上下文夹具（3 资产 / 2 边界 / 3 入口点 / 3 角色 / 2 资源）
//   <fx>/inputs/cases.json              功能用例集夹具（3 条用例，占用 TC-001~TC-003）
//   <fx>/inputs/bandit.json             扫描结果形态①（bandit，2 条 finding）
//   <fx>/inputs/npm-audit.json          扫描结果形态②（npm audit，1 条 finding）
//   <fx>/inputs/scan-unavailable.json   扫描结果形态③（工具不可达）
//   <fx>/inputs/unknown-scan.json       非法扫描文件（三种形态都识别不出来）
//   <fx>/bad/*.json                     B 组的非法输入变体
//   <fx>/proj/                          最小项目根（.gitignore + environments + cycles）
import fs from 'node:fs';
import path from 'node:path';

const fx = process.argv[2];
const ISO = '2026-11-14T00:00:00+08:00';

const writeJson = (file, value) => {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
};

// ---------------------------------------------------------------- 安全上下文

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

const clone = (value) => JSON.parse(JSON.stringify(value));

// ---------------------------------------------------------------- 功能用例集（--cases 输入）

const mkCase = (id, title, req, action, expected, tags) => ({
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
});

const cases = {
  schema_version: 2,
  meta: { source: 'REQ-DEMO 需求文档', generated_at: ISO, case_count: 3 },
  requirements: [
    { id: 'R-1', title: '登录成功返回令牌', source_ref: 'REQ-DEMO §1', testable: true },
    { id: 'R-2', title: '查询订单详情', source_ref: 'REQ-DEMO §2', testable: true },
    { id: 'R-3', title: '导出访问日志', source_ref: 'REQ-DEMO §3', testable: true },
  ],
  open_questions: [],
  coverage_matrix: [
    { requirement: 'R-1', methods_applied: ['M1.1'], skipped: [], dimensions: ['functional'] },
    { requirement: 'R-2', methods_applied: ['M1.1'], skipped: [], dimensions: ['functional'] },
    { requirement: 'R-3', methods_applied: ['M1.1'], skipped: [], dimensions: ['functional'] },
  ],
  defects: [],
  cases: [
    mkCase('TC-001', '登录成功返回令牌', 'R-1', 'POST /api/login', '状态码 200', ['auth']),
    mkCase('TC-002', '查询订单详情', 'R-2', 'GET /api/orders/{id}', '状态码 200', ['order']),
    mkCase('TC-003', '导出访问日志', 'R-3', 'GET /api/audit/logs', '状态码 200', ['audit']),
  ],
};

// ---------------------------------------------------------------- 扫描结果（三种合法形态 + 一种非法）

const bandit = {
  results: [
    {
      filename: 'app/handlers/upload.py',
      test_id: 'B301',
      test_name: 'blacklist',
      issue_severity: 'HIGH',
      issue_confidence: 'HIGH',
      issue_text: "Possible hardcoded password: 'secret123'",
      line_number: 42,
    },
    {
      filename: 'app/handlers/xml.py',
      test_id: 'B320',
      test_name: 'bad_telemetry',
      issue_severity: 'MEDIUM',
      issue_confidence: 'MEDIUM',
      issue_text: 'Consider possible security implications of xml parsing',
      line_number: 17,
    },
  ],
  errors: [],
};

const npmAudit = {
  auditReportVersion: 2,
  vulnerabilities: {
    lodash: {
      name: 'lodash',
      severity: 'high',
      range: '<4.17.21',
      via: [{ title: 'Prototype Pollution', url: 'https://github.com/advisories/GHSA-x5cx-7h7x-2h4r' }],
    },
  },
  metadata: { vulnerabilities: { info: 0, low: 0, moderate: 0, high: 1, critical: 0 } },
};

const scanUnavailable = {
  tool: 'bandit',
  status: 'unavailable',
  reason: 'bandit 未就绪：PyPI 镜像不可达，uv/pip 均安装失败（见 qa doctor 结论）',
};

const unknownScan = { foo: 1 };

// ---------------------------------------------------------------- B 组的非法输入变体

const bad = {};

// AC-005：必填字段与类型
{
  const c = clone(context); delete c.assets; bad['c-no-assets'] = c;
}
{
  const c = clone(context); c.trust_boundaries = 'TB-1,TB-2'; bad['c-boundaries-string'] = c;
}
{
  const c = clone(context); delete c.entry_points[0].name; bad['c-no-ep-name'] = c;
}
{
  const c = clone(context); delete c.roles; bad['c-no-roles'] = c;
}
{
  const c = clone(context); c.resources = { 'RES-1': '订单' }; bad['c-resources-object'] = c;
}
// AC-006：引用完整性
{
  const c = clone(context); c.entry_points[0].asset_refs = ['AS-999']; bad['c-dangling-asset'] = c;
}
{
  const c = clone(context); c.entry_points[1].boundary_refs = ['TB-999']; bad['c-dangling-boundary'] = c;
}
{
  const c = clone(context); c.resources[0].asset_refs = []; bad['c-empty-res-assets'] = c;
}
// AC-007：id 唯一性与格式
{
  const c = clone(context); c.assets[1].id = 'AS-1'; bad['c-dup-asset'] = c;
}
{
  const c = clone(context); c.entry_points[0].id = 'EP-XYZ'; bad['c-bad-ep-id'] = c;
}
// AC-008：枚举
{
  const c = clone(context); c.assets[0].sensitivity = 'secret'; bad['c-bad-sensitivity'] = c;
}
{
  const c = clone(context); c.entry_points[0].kind = ''; bad['c-empty-kind'] = c;
}

// ---------------------------------------------------------------- 最小项目根

const envSchema = {
  $schema: 'https://json-schema.org/draft/2020-12/schema',
  title: '测试环境配置',
  type: 'object',
  required: ['name', 'base_url', 'timeout_ms', 'credentials'],
  additionalProperties: false,
  properties: {
    name: { type: 'string', description: '环境标识，与文件名一致' },
    base_url: { type: 'string', description: '被测服务根地址' },
    timeout_ms: { type: 'integer', description: '单请求超时毫秒' },
    retries: { type: 'integer', description: '失败重试次数' },
    credentials: {
      type: 'object',
      description: '凭证引用，只允许环境变量名，禁止明文',
      required: ['username_env'],
      properties: {
        username_env: { type: 'string', description: '存放用户名的环境变量名' },
        password_env: { type: 'string', description: '存放密码的环境变量名' },
      },
      additionalProperties: false,
    },
    headers: { type: 'object', description: '附加请求头' },
    verify_tls: { type: 'boolean', description: '是否校验 TLS 证书' },
    driver: { type: 'string', enum: ['api', 'mock'], description: '用哪个执行器驱动跑这个环境' },
    data_fixtures: {
      type: 'array',
      description: '执行前准备的数据集',
      items: {
        type: 'object',
        required: ['path'],
        properties: {
          path: { type: 'string', description: 'fixture 文件路径（相对项目根）' },
          cleanup: { type: 'boolean', description: '执行后清理' },
        },
      },
    },
  },
};

// ⚠️ **不得写 `driver` 字段**（D126）：环境的 driver 会覆盖 suite.json 的 executor；
// 写了就会误配对到 api/mock 执行器 ⇒ 「能跑通」是假象。详见 acceptance.md §0.4。
const environment = {
  name: 'local',
  base_url: 'http://127.0.0.1:8080',
  timeout_ms: 5000,
  retries: 0,
  credentials: { username_env: 'ORDER_API_USER', password_env: 'ORDER_API_PASS' },
};

const cycle = {
  cycle_id: 'R1-REQ-001',
  round: 'R1',
  round_type: 'new-requirement',
  requirement: 'REQ-DEMO',
  scopes: ['functional', 'security'],
  scopes_skipped: [],
  status: 'in_progress',
  stages: { clarify: { status: 'done' }, design: { status: 'in_progress' } },
  history: [{ at: ISO, from: 'planned', to: 'in_progress', by: 'seed' }],
};

const cycleIndex = {
  cycles: [{ id: 'R1-REQ-001', round: 'R1', status: 'in_progress' }],
};

writeJson(path.join(fx, 'inputs', 'context.json'), context);
writeJson(path.join(fx, 'inputs', 'cases.json'), cases);
writeJson(path.join(fx, 'inputs', 'bandit.json'), bandit);
writeJson(path.join(fx, 'inputs', 'npm-audit.json'), npmAudit);
writeJson(path.join(fx, 'inputs', 'scan-unavailable.json'), scanUnavailable);
writeJson(path.join(fx, 'inputs', 'unknown-scan.json'), unknownScan);
for (const [name, value] of Object.entries(bad)) {
  writeJson(path.join(fx, 'bad', `${name}.json`), value);
}

fs.mkdirSync(path.join(fx, 'proj'), { recursive: true });
fs.writeFileSync(path.join(fx, 'proj', '.gitignore'), '.test-artifacts/\n');
writeJson(path.join(fx, 'proj', 'test-assets', 'environments', '_schema.json'), envSchema);
writeJson(path.join(fx, 'proj', 'test-assets', 'environments', 'local.json'), environment);
writeJson(path.join(fx, 'proj', 'test-assets', 'cycles', 'index.json'), cycleIndex);
writeJson(path.join(fx, 'proj', 'test-assets', 'cycles', 'R1-REQ-001', 'cycle.json'), cycle);

process.stdout.write(`${JSON.stringify({
  assets: context.assets.length,
  boundaries: context.trust_boundaries.length,
  entryPoints: context.entry_points.length,
  roles: context.roles.length,
  resources: context.resources.length,
  functionalCases: cases.cases.length,
  banditFindings: bandit.results.length,
  npmAuditFindings: Object.keys(npmAudit.vulnerabilities).length,
  badVariants: Object.keys(bad).length,
})}\n`);
FIXMK

FX="$WORK/fx"
FIXINFO="$(node "$WORK/mkfixture.mjs" "$FX" 2>&1)"
FIX_RC=$?
if [ "$FIX_RC" -ne 0 ] || [ ! -s "$FX/inputs/context.json" ] || [ ! -s "$FX/inputs/bandit.json" ] || [ ! -s "$FX/proj/test-assets/environments/local.json" ]; then
  echo "夹具生成失败 —— 不可判定，不判通过" >&2
  printf '%s\n' "$FIXINFO" | head -5 >&2
  exit 1
fi
printf '夹具: %s\n' "$FIXINFO"

CTX="$FX/inputs/context.json"
FCASES="$FX/inputs/cases.json"
BANDIT="$FX/inputs/bandit.json"
NPMAUDIT="$FX/inputs/npm-audit.json"
SCANUNAVAIL="$FX/inputs/scan-unavailable.json"
UNKNOWNSCAN="$FX/inputs/unknown-scan.json"

# 输入目录的**跑前**快照（AC-028 ② 用）—— 必须在任何一次跑被验实现之前取
INPUTS_BEFORE="$(node "$WORK/snapdir.mjs" "$FX/inputs" 2>/dev/null)"

# ---------------------------------------------------------------- 跑被验实现

step "跑被验实现（主跑 / 幂等两次 / 无扫描 / 工具不可达 / 非法输入变体）"

IMPL_MISSING=0
if [ ! -f "$ENTRY" ]; then
  IMPL_MISSING=1
  printf '⚠️ 实现缺失: %s 不存在 —— 产品侧判据将判红（实现未交付，不是门侧问题）\n' "$ENTRY_REL"
fi

run_impl() { # $1 = 运行 id, $2 = out-dir, 其余 = 额外参数
  local id="$1"; shift
  local out="$1"; shift
  if [ "$IMPL_MISSING" -eq 1 ]; then
    printf '实现缺失，跳过运行 %s\n' "$id" >&2
    return 127
  fi
  node "$ENTRY" "$@" --out-dir "$out" >"$WORK/impl-$id.log" 2>"$WORK/impl-$id.err"
  return $?
}

new_proj() { # $1 = 目标目录名
  local d="$WORK/$1"
  mkdir -p "$d"
  cp -r "$FX/proj"/. "$d"/ 2>/dev/null
  printf '%s' "$d"
}

PROJ_MAIN="$(new_proj run-main)"
PROJ_IDEM1="$(new_proj run-idem1)"
PROJ_IDEM2="$(new_proj run-idem2)"
PROJ_NOSCAN="$(new_proj run-noscan)"
PROJ_UNAVAIL="$(new_proj run-unavail)"
PROJ_NPMAUDIT="$(new_proj run-npmaudit)"

RC_MAIN=0; run_impl main "$PROJ_MAIN" --context "$CTX" --cases "$FCASES" --scan "$BANDIT" || RC_MAIN=$?
RC_IDEM1=0; run_impl idem1 "$PROJ_IDEM1" --context "$CTX" --cases "$FCASES" --scan "$BANDIT" || RC_IDEM1=$?
RC_IDEM2=0; run_impl idem2 "$PROJ_IDEM2" --context "$CTX" --cases "$FCASES" --scan "$BANDIT" || RC_IDEM2=$?
RC_NOSCAN=0; run_impl noscan "$PROJ_NOSCAN" --context "$CTX" --cases "$FCASES" || RC_NOSCAN=$?
RC_UNAVAIL=0; run_impl unavail "$PROJ_UNAVAIL" --context "$CTX" --scan "$SCANUNAVAIL" || RC_UNAVAIL=$?
RC_NPMAUDIT=0; run_impl npmaudit "$PROJ_NPMAUDIT" --context "$CTX" --scan "$NPMAUDIT" || RC_NPMAUDIT=$?
printf '主跑 rc=%s 幂等1 rc=%s 幂等2 rc=%s 无扫描 rc=%s 工具不可达 rc=%s npm-audit rc=%s\n' \
  "$RC_MAIN" "$RC_IDEM1" "$RC_IDEM2" "$RC_NOSCAN" "$RC_UNAVAIL" "$RC_NPMAUDIT"
if [ "$RC_MAIN" -ne 0 ] && [ "$IMPL_MISSING" -eq 0 ]; then
  printf '  · stderr: %s\n' "$(head -3 "$WORK/impl-main.err" 2>/dev/null | tr '\n' ' ')"
fi

# 非法输入变体（每个变体跑一次；期望 rc=1 且不留半份产物）
run_bad() { # $1 = 变体名, $2 = 上下文文件, $3 = 扫描文件（可空）
  local name="$1" ctxf="$2" scanf="$3"
  local d; d="$(new_proj "bad-$name")"
  local rc=0
  if [ -n "$scanf" ]; then
    run_impl "bad-$name" "$d" --context "$ctxf" --scan "$scanf" || rc=$?
  else
    run_impl "bad-$name" "$d" --context "$ctxf" || rc=$?
  fi
  local leftover="no"
  if [ -e "$d/test-assets/security/threat-model.json" ] || [ -e "$d/test-assets/security/matrix.json" ] || [ -d "$d/test-assets/security/suites" ]; then
    leftover="yes"
  fi
  local safe="${name//-/_}"
  # bash 不允许在变量名位置展开（`BAD_RC_$safe=...` 会被当命令执行）⇒ 用 printf -v 拼字面量名。
  printf -v "BAD_RC_${safe}" '%s' "$rc"
  printf -v "BAD_LEFTOVER_${safe}" '%s' "$leftover"
  printf -v "BAD_ERR_${safe}" '%s' "$WORK/impl-bad-${name}.err"
  printf '  变体 %-22s rc=%s 留半份产物=%s\n' "$name" "$rc" "$leftover"
}

# ---------------------------------------------------------------- 独立复算器（judge.mjs）

step "产物侧判据（AC-009 ~ AC-027，独立复算器）"

cat > "$WORK/judge.mjs" <<'FIXJUDGE'
// judge.mjs —— 判据自带的**独立复算器**
// ⚠️ **绝不 import 被验包任何模块**（D122）：自带独立的解析 / 集合运算 / 枚举实现。
//    方法库与维度库只作为**数据文件**读取（JSON），不是 import 被验包的实现。
// 用法: node judge.mjs <config.json>
// 输出: 每行 `AC-xxx\tPASS|FAIL|UNDEC\t说明`
import fs from 'node:fs';
import path from 'node:path';

const cfg = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const out = [];
const emit = (id, res, msg) => { out.push(`${id}\t${res}\t${msg}`); };

// ---------------------------------------------------------------- 小工具（独立实现）

const isObj = (v) => typeof v === 'object' && v !== null && !Array.isArray(v);
const filled = (v) => typeof v === 'string' && v.trim() !== '';
const readJson = (f) => { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch { return null; } };
const setOf = (arr) => new Set(Array.isArray(arr) ? arr : []);
const sameSet = (a, b) => a.size === b.size && [...a].every((x) => b.has(x));
const uniq = (arr) => new Set(arr);

const OWASP_CLASSES = ['A01', 'A02', 'A03', 'A04', 'A05', 'A06', 'A07', 'A08', 'A09', 'A10'];
const SUPPLEMENTS = ['file_upload', 'ssrf', 'xxe', 'deserialization'];
const STRIDE = ['spoofing', 'tampering', 'repudiation', 'information_disclosure', 'denial_of_service', 'elevation_of_privilege'];
const SEVERITIES = ['critical', 'high', 'medium', 'low'];
const SOURCES = ['model', 'scan', 'model+scan'];
const PRIORITIES = ['P0', 'P1', 'P2', 'P3'];
const CASE_STATUSES = ['active'];
const CASE_TOP = ['schema_version', 'meta', 'requirements', 'open_questions', 'coverage_matrix', 'defects', 'cases'];
const SUITE_ALLOWED = ['suite', 'requirement', 'scope', 'environment', 'cases_file', 'executor', 'base_url_from', 'tags', 'report'];
const SUITE_REQUIRED = ['suite', 'requirement', 'scope', 'environment', 'cases_file', 'executor'];
const THREAT_FIELDS = [
  'id', 'name', 'category', 'owasp', 'asset_refs', 'boundary_refs', 'entry_point_refs',
  'severity', 'source', 'scan_refs', 'supplement_refs', 'rationale',
];

// ---------------------------------------------------------------- 输入

const ctx = readJson(cfg.context);
const inputCases = readJson(cfg.cases);
const methodsDoc = readJson(cfg.methodsFile);
const dimsDoc = readJson(cfg.dimensionsFile);
const METHOD_IDS = new Set((methodsDoc && Array.isArray(methodsDoc.methods) ? methodsDoc.methods : []).map((m) => m.id));
const DIM_IDS = new Set((dimsDoc && Array.isArray(dimsDoc.dimensions) ? dimsDoc.dimensions : []).map((d) => d.id));

const secRoot = (p) => path.join(p, 'test-assets', 'security');

function loadProducts(outDir) {
  const tm = readJson(path.join(secRoot(outDir), 'threat-model.json'));
  const mx = readJson(path.join(secRoot(outDir), 'matrix.json'));
  const suitesDir = path.join(secRoot(outDir), 'suites');
  const suites = [];
  let names = [];
  try {
    names = fs.readdirSync(suitesDir).filter((n) => {
      try { return fs.statSync(path.join(suitesDir, n)).isDirectory(); } catch { return false; }
    }).sort();
  } catch { names = []; }
  for (const n of names) {
    const dir = path.join(suitesDir, n);
    suites.push({
      dirName: n,
      dir,
      cases: readJson(path.join(dir, 'cases.json')),
      suite: readJson(path.join(dir, 'suite.json')),
    });
  }
  return { tm, mx, suites };
}

const main = loadProducts(cfg.main);
const noScan = loadProducts(cfg.noScan);
const unavail = loadProducts(cfg.unavail);

// ---------------------------------------------------------------- 通用缺产物判定

const MISSING_TM = '产物缺失：<out-dir>/test-assets/security/threat-model.json 不存在或不是合法 JSON';
const MISSING_MX = '产物缺失：<out-dir>/test-assets/security/matrix.json 不存在或不是合法 JSON';
const MISSING_SUITES = '产物缺失：<out-dir>/test-assets/security/suites/ 下没有套件目录（或 cases.json 不可解析）';

const tm = main.tm;
const mx = main.mx;
const threats = tm && Array.isArray(tm.threats) ? tm.threats : [];
const threatById = new Map(threats.map((t) => [t && t.id, t]));
const threatIds = new Set(threats.map((t) => t && t.id));

const ctxAssets = ctx && Array.isArray(ctx.assets) ? ctx.assets : [];
const ctxBoundaries = ctx && Array.isArray(ctx.trust_boundaries) ? ctx.trust_boundaries : [];
const ctxEntryPoints = ctx && Array.isArray(ctx.entry_points) ? ctx.entry_points : [];
const ctxRoles = ctx && Array.isArray(ctx.roles) ? ctx.roles : [];
const ctxResources = ctx && Array.isArray(ctx.resources) ? ctx.resources : [];
const ctxAssetIds = new Set(ctxAssets.map((a) => a && a.id));
const ctxBoundaryIds = new Set(ctxBoundaries.map((b) => b && b.id));
const ctxEntryIds = new Set(ctxEntryPoints.map((e) => e && e.id));
const ctxRoleIds = new Set(ctxRoles.map((r) => r && r.id));
const ctxResourceIds = new Set(ctxResources.map((r) => r && r.id));

// ---------------------------------------------------------------- AC-009 资产/边界/入口点三段逐条对应

{
  const problems = [];
  if (!tm) {
    problems.push(MISSING_TM);
  } else {
    const segs = [
      ['assets', ctxAssets, 'AS-'],
      ['trust_boundaries', ctxBoundaries, 'TB-'],
      ['entry_points', ctxEntryPoints, 'EP-'],
    ];
    for (const [seg, ctxSeg] of segs) {
      const got = Array.isArray(tm[seg]) ? tm[seg] : null;
      if (got === null) { problems.push(`threat-model.json 缺 ${seg} 段`); continue; }
      const ctxIds = ctxSeg.map((x) => x && x.id);
      const gotIds = got.map((x) => x && x.id);
      if (!sameSet(uniq(gotIds), uniq(ctxIds))) {
        problems.push(`${seg} 的 id 集合与上下文不一致（产物: [${gotIds.join(', ')}] vs 上下文: [${ctxIds.join(', ')}]）`);
      }
      if (got.length !== ctxSeg.length) {
        problems.push(`${seg} 条数不一致（产物 ${got.length} vs 上下文 ${ctxSeg.length}）`);
      }
      // 逐条核对关键字段
      const ctxById = new Map(ctxSeg.map((x) => [x && x.id, x]));
      for (const item of got) {
        const src = ctxById.get(item && item.id);
        if (!src) continue;
        if (seg === 'assets' && item.sensitivity !== src.sensitivity) {
          problems.push(`${seg}/${item.id} 的 sensitivity 与上下文不一致（${item.sensitivity} vs ${src.sensitivity}）`);
        }
        if (seg === 'trust_boundaries') {
          const a = JSON.stringify(Array.isArray(item.controls) ? item.controls : null);
          const b = JSON.stringify(Array.isArray(src.controls) ? src.controls : null);
          if (a !== b) problems.push(`${seg}/${item.id} 的 controls 与上下文不一致`);
        }
        if (seg === 'entry_points' && item.kind !== src.kind) {
          problems.push(`${seg}/${item.id} 的 kind 与上下文不一致（${item.kind} vs ${src.kind}）`);
        }
      }
    }
  }
  emit('AC-009', problems.length ? 'FAIL' : 'PASS', problems.join('; ') || '三段与上下文逐条对应');
}

// ---------------------------------------------------------------- AC-010 威胁字段齐全 / 唯一 / 枚举合法

{
  const problems = [];
  if (!tm) {
    problems.push(MISSING_TM);
  } else if (!Array.isArray(tm.threats) || tm.threats.length === 0) {
    problems.push('threats[] 缺失或为空');
  } else {
    const seen = new Set();
    for (const t of tm.threats) {
      const at = `threats[${(tm.threats || []).indexOf(t)}]`;
      if (!isObj(t)) { problems.push(`${at} 不是对象`); continue; }
      const keys = Object.keys(t).sort();
      const expect = [...THREAT_FIELDS].sort();
      if (keys.length !== expect.length || keys.some((k, i) => k !== expect[i])) {
        problems.push(`${at} 的字段集不是约定的 12 个（多: [${keys.filter((k) => !expect.includes(k)).join(',')}] 少: [${expect.filter((k) => !keys.includes(k)).join(',')}])`);
      }
      if (!filled(t.id) || !/^TH-\d+$/.test(t.id)) problems.push(`${at}.id 非法: ${JSON.stringify(t.id)}（须合 ^TH-\\d+$）`);
      else if (seen.has(t.id)) problems.push(`${at}.id 重复: ${t.id}`);
      else seen.add(t.id);
      if (!filled(t.name)) problems.push(`${at}.name 为空`);
      if (!STRIDE.includes(t.category)) problems.push(`${at}.category 取值非法: ${JSON.stringify(t.category)}`);
      if (!OWASP_CLASSES.includes(t.owasp)) problems.push(`${at}.owasp 取值非法: ${JSON.stringify(t.owasp)}`);
      if (!SEVERITIES.includes(t.severity)) problems.push(`${at}.severity 取值非法: ${JSON.stringify(t.severity)}`);
      if (!SOURCES.includes(t.source)) problems.push(`${at}.source 取值非法: ${JSON.stringify(t.source)}`);
      for (const f of ['asset_refs', 'boundary_refs', 'entry_point_refs', 'scan_refs', 'supplement_refs']) {
        if (!Array.isArray(t[f])) problems.push(`${at}.${f} 不是数组`);
      }
      const srcHasScan = typeof t.source === 'string' && t.source.includes('scan');
      const refsNonEmpty = Array.isArray(t.scan_refs) && t.scan_refs.length > 0;
      if (srcHasScan !== refsNonEmpty) {
        problems.push(`${at} 的 source(${t.source}) 与 scan_refs 是否非空(${refsNonEmpty}) 不自洽`);
      }
    }
  }
  emit('AC-010', problems.length ? 'FAIL' : 'PASS', problems.join('; ') || '威胁字段齐全、id 唯一、枚举合法');
}

// ---------------------------------------------------------------- AC-011 OWASP 十类每类都有交代

{
  const problems = [];
  const cov = tm && isObj(tm.owasp_coverage) ? tm.owasp_coverage : null;
  if (!tm) problems.push(MISSING_TM);
  else if (!cov) problems.push('threat-model.json 缺 owasp_coverage 段');
  else {
    const keys = Object.keys(cov).sort();
    const expect = [...OWASP_CLASSES].sort();
    if (!sameSet(uniq(keys), uniq(expect))) {
      problems.push(`owasp_coverage 的键集不是恰 A01~A10（实际: [${keys.join(', ')}]）`);
    }
    for (const cls of OWASP_CLASSES) {
      const item = cov[cls];
      if (item === undefined) { problems.push(`OWASP ${cls} 既没有 covered 声明、也没有 not_applicable 声明`); continue; }
      if (!isObj(item)) { problems.push(`OWASP ${cls} 的取值不是对象`); continue; }
      if (item.status !== 'covered' && item.status !== 'not_applicable') {
        problems.push(`OWASP ${cls} 的 status 取值非法: ${JSON.stringify(item.status)}`);
        continue;
      }
      if (item.status === 'covered') {
        const refs = Array.isArray(item.threat_refs) ? item.threat_refs : [];
        if (refs.length === 0) { problems.push(`OWASP ${cls} 声明 covered 但 threat_refs 为空`); continue; }
        for (const r of refs) {
          if (!threatIds.has(r)) { problems.push(`OWASP ${cls} 的 threat_refs 指向不存在的威胁 ${r}`); continue; }
          if (threatById.get(r).owasp !== cls) problems.push(`OWASP ${cls} 的 threat_refs 里的 ${r} 的 owasp 是 ${threatById.get(r).owasp}`);
        }
        const classThreats = threats.filter((t) => isObj(t) && t.owasp === cls).map((t) => t.id);
        if (!sameSet(uniq(refs), uniq(classThreats))) {
          problems.push(`OWASP ${cls} 的 threat_refs 与该类威胁集合不一致（声明: [${refs.join(',')}] 实际: [${classThreats.join(',')}]）`);
        }
      }
    }
  }
  emit('AC-011', problems.length ? 'FAIL' : 'PASS', problems.join('; ') || 'A01~A10 十类每类都有交代');
}

// ---------------------------------------------------------------- AC-012 不适用必须带非空理由 + 一条未决问题

{
  const problems = [];
  const cov = tm && isObj(tm.owasp_coverage) ? tm.owasp_coverage : null;
  const oq = tm && Array.isArray(tm.open_questions) ? tm.open_questions : null;
  if (!tm) problems.push(MISSING_TM);
  else {
    if (!oq) problems.push('threat-model.json 缺 open_questions 段');
    if (cov) {
      const seenQ = new Set();
      for (const q of (oq || [])) {
        if (!isObj(q)) { problems.push('open_questions[] 里有非对象条目'); continue; }
        if (!filled(q.id)) problems.push('open_questions[] 有条目 id 为空');
        else if (seenQ.has(q.id)) problems.push(`open_questions[] 的 id 重复: ${q.id}`);
        else seenQ.add(q.id);
        if (!filled(q.question)) problems.push(`open_questions/${q.id} 的 question 为空`);
        if (!filled(q.reason)) problems.push(`open_questions/${q.id} 的 reason 为空`);
      }
      for (const cls of OWASP_CLASSES) {
        const item = cov[cls];
        if (!isObj(item) || item.status !== 'not_applicable') continue;
        if (!filled(item.reason)) problems.push(`OWASP ${cls} 判 not_applicable 但 reason 为空`);
        if (!filled(item.open_question_ref)) {
          problems.push(`OWASP ${cls} 判 not_applicable 但没有 open_question_ref`);
          continue;
        }
        const q = (oq || []).find((x) => isObj(x) && x.id === item.open_question_ref);
        if (!q) problems.push(`OWASP ${cls} 的 open_question_ref "${item.open_question_ref}" 在 open_questions[] 里不存在`);
        else if (q.category !== cls) problems.push(`OWASP ${cls} 的未决问题 ${q.id} 的 category 是 ${JSON.stringify(q.category)}，与该类不符`);
      }
    }
  }
  emit('AC-012', problems.length ? 'FAIL' : 'PASS', problems.join('; ') || 'not_applicable 均带非空理由并留了未决问题');
}

// ---------------------------------------------------------------- AC-013 四类实战补充逐类显式判定

{
  const problems = [];
  const sup = tm && isObj(tm.supplements) ? tm.supplements : null;
  if (!tm) problems.push(MISSING_TM);
  else if (!sup) problems.push('threat-model.json 缺 supplements 段');
  else {
    const keys = Object.keys(sup).sort();
    const expect = [...SUPPLEMENTS].sort();
    if (!sameSet(uniq(keys), uniq(expect))) {
      problems.push(`supplements 的键集不是恰四个实战补充类（实际: [${keys.join(', ')}]）`);
    }
    for (const key of SUPPLEMENTS) {
      const item = sup[key];
      if (item === undefined) { problems.push(`实战补充 ${key} 没有显式判定`); continue; }
      if (!isObj(item)) { problems.push(`实战补充 ${key} 的取值不是对象`); continue; }
      if (item.status !== 'covered' && item.status !== 'not_applicable') {
        problems.push(`实战补充 ${key} 的 status 取值非法: ${JSON.stringify(item.status)}`);
        continue;
      }
      if (item.status === 'covered') {
        const refs = Array.isArray(item.threat_refs) ? item.threat_refs : [];
        if (refs.length === 0) { problems.push(`实战补充 ${key} 声明 covered 但 threat_refs 为空`); continue; }
        for (const r of refs) {
          if (!threatIds.has(r)) { problems.push(`实战补充 ${key} 的 threat_refs 指向不存在的威胁 ${r}`); continue; }
          const srefs = threatById.get(r).supplement_refs;
          if (!Array.isArray(srefs) || !srefs.includes(key)) {
            problems.push(`实战补充 ${key} 引用的威胁 ${r} 的 supplement_refs 里没有 ${key}`);
          }
        }
        const classThreats = threats
          .filter((t) => isObj(t) && Array.isArray(t.supplement_refs) && t.supplement_refs.includes(key))
          .map((t) => t.id);
        if (!sameSet(uniq(refs), uniq(classThreats))) {
          problems.push(`实战补充 ${key} 的 threat_refs 与 supplement_refs 含该键的威胁集合不一致（声明: [${refs.join(',')}] 实际: [${classThreats.join(',')}]）`);
        }
      } else if (!filled(item.reason)) {
        problems.push(`实战补充 ${key} 判 not_applicable 但 reason 为空`);
      }
    }
  }
  emit('AC-013', problems.length ? 'FAIL' : 'PASS', problems.join('; ') || '四类实战补充逐类显式判定');
}

// ---------------------------------------------------------------- AC-014 扫描接入

{
  const problems = [];
  const checkOne = (label, prod, expectStatus, expectTool, expectFindings) => {
    const t = prod.tm;
    if (!t) { problems.push(`${label}: ${MISSING_TM}`); return; }
    // ⚠️ 必须用**本产品自己的**威胁集合（不能用主跑那份 —— 否则三个跑的结论会被混成一份）
    const ownThreats = Array.isArray(t.threats) ? t.threats : [];
    const ownThreatIds = new Set(ownThreats.map((x) => x && x.id));
    const scan = isObj(t.scan) ? t.scan : null;
    if (!scan) { problems.push(`${label}: threat-model.json 缺 scan 段`); return; }
    if (scan.status !== expectStatus) problems.push(`${label}: scan.status 是 ${JSON.stringify(scan.status)}，期望 ${expectStatus}`);
    if (expectTool !== null && scan.tool !== expectTool) problems.push(`${label}: scan.tool 是 ${JSON.stringify(scan.tool)}，期望 ${expectTool}`);
    const findings = Array.isArray(t.scan_findings) ? t.scan_findings : null;
    if (!findings) { problems.push(`${label}: threat-model.json 缺 scan_findings 段`); return; }
    if (findings.length !== expectFindings) problems.push(`${label}: scan_findings 条数 ${findings.length}，期望 ${expectFindings}`);
    const seenF = new Set();
    for (const f of findings) {
      if (!isObj(f)) { problems.push(`${label}: scan_findings 里有非对象条目`); continue; }
      if (!filled(f.id) || !/^SCAN-\d+$/.test(f.id)) problems.push(`${label}: scan_finding id 非法: ${JSON.stringify(f.id)}`);
      else if (seenF.has(f.id)) problems.push(`${label}: scan_finding id 重复: ${f.id}`);
      else seenF.add(f.id);
      const refs = Array.isArray(f.threat_refs) ? f.threat_refs : [];
      if (refs.length === 0) { problems.push(`${label}: scan_finding ${f.id} 的 threat_refs 为空`); continue; }
      for (const r of refs) {
        if (!ownThreatIds.has(r)) { problems.push(`${label}: scan_finding ${f.id} 指向不存在的威胁 ${r}`); continue; }
        const th = ownThreats.find((x) => x && x.id === r);
        if (!filled(th.source) || !th.source.includes('scan')) problems.push(`${label}: scan_finding ${f.id} 引用的威胁 ${r} 的 source 不含 scan`);
        const srefs = Array.isArray(th.scan_refs) ? th.scan_refs : [];
        if (!srefs.includes(f.id)) problems.push(`${label}: 威胁 ${r} 的 scan_refs 里没有 ${f.id}`);
      }
    }
    if (expectStatus !== 'provided') {
      const scanSourced = ownThreats.filter((x) => isObj(x) && filled(x.source) && x.source.includes('scan'));
      if (scanSourced.length > 0) {
        problems.push(`${label}: 未提供扫描却出现 ${scanSourced.length} 条 source 含 scan 的威胁`);
      }
    }
  };
  checkOne('主跑(喂了 bandit)', main, 'provided', 'bandit', 2);
  checkOne('不传 --scan', noScan, 'not_provided', null, 0);
  checkOne('传了 unavailable 状态', unavail, 'unavailable', null, 0);
  emit('AC-014', problems.length ? 'FAIL' : 'PASS', problems.join('; ') || '扫描发现已映射成威胁，未扫描时显式声明');
}

// ---------------------------------------------------------------- AC-015 矩阵形状与引用

{
  const problems = [];
  if (!mx) problems.push(MISSING_MX);
  else {
    const roles = Array.isArray(mx.roles) ? mx.roles : null;
    const resources = Array.isArray(mx.resources) ? mx.resources : null;
    const entries = Array.isArray(mx.entries) ? mx.entries : null;
    if (!roles) problems.push('matrix.json 缺 roles 段');
    if (!resources) problems.push('matrix.json 缺 resources 段');
    if (!entries) problems.push('matrix.json 缺 entries 段');
    if (roles && !sameSet(uniq(roles.map((r) => r && r.id)), uniq(ctxRoles.map((r) => r && r.id)))) {
      problems.push(`matrix.roles 的 id 集合与上下文不一致（产物: [${roles.map((r) => r && r.id).join(',')}]）`);
    }
    if (resources && !sameSet(uniq(resources.map((r) => r && r.id)), uniq(ctxResources.map((r) => r && r.id)))) {
      problems.push(`matrix.resources 的 id 集合与上下文不一致（产物: [${resources.map((r) => r && r.id).join(',')}]）`);
    }
    if (entries) {
      if (entries.length === 0) problems.push('matrix.entries 为空');
      const pairs = new Set();
      for (const e of entries) {
        if (!isObj(e)) { problems.push('matrix.entries 里有非对象条目'); continue; }
        if (!ctxRoleIds.has(e.role)) problems.push(`matrix.entries 里的 role "${e.role}" 不在矩阵角色集合中（悬空）`);
        if (!ctxResourceIds.has(e.resource)) problems.push(`matrix.entries 里的 resource "${e.resource}" 不在矩阵资源集合中（悬空）`);
        if (!filled(e.action)) problems.push(`matrix.entries 里的 action 为空（role=${e.role} resource=${e.resource}）`);
        if (e.decision !== 'allow' && e.decision !== 'deny') problems.push(`matrix.entries 的 decision 取值非法: ${JSON.stringify(e.decision)}`);
        if (e.basis !== 'expected' && e.basis !== 'gap') problems.push(`matrix.entries 的 basis 取值非法: ${JSON.stringify(e.basis)}`);
        pairs.add(`${e.role}||${e.resource}`);
      }
      for (const r of ctxRoles) {
        for (const res of ctxResources) {
          if (!pairs.has(`${r && r.id}||${res && res.id}`)) {
            problems.push(`矩阵缺少 (role=${r && r.id}, resource=${res && res.id}) 这一格的条目`);
          }
        }
      }
    }
  }
  emit('AC-015', problems.length ? 'FAIL' : 'PASS', problems.join('; ') || '矩阵形状与引用成立');
}

// ---------------------------------------------------------------- AC-016 允许缺口 ↔ 越权类威胁（双向）

{
  const problems = [];
  const elev = threats.filter((t) => isObj(t) && t.category === 'elevation_of_privilege').map((t) => t.id);
  if (!mx) problems.push(MISSING_MX);
  else {
    const entries = Array.isArray(mx.entries) ? mx.entries : [];
    const referenced = new Set();
    for (const e of entries) {
      if (!isObj(e)) continue;
      if (e.basis === 'gap') {
        if (e.decision !== 'allow') problems.push(`basis=gap 的条目（${e.role}/${e.resource}/${e.action}）decision 不是 allow`);
        if (!filled(e.threat_ref)) { problems.push(`basis=gap 的条目（${e.role}/${e.resource}/${e.action}）没有 threat_ref`); continue; }
        if (!threatIds.has(e.threat_ref)) { problems.push(`basis=gap 的条目引用了不存在的威胁 ${e.threat_ref}`); continue; }
        const th = threatById.get(e.threat_ref);
        if (th.category !== 'elevation_of_privilege') {
          problems.push(`basis=gap 的条目引用的威胁 ${e.threat_ref} 的 category 是 ${th.category}，不是越权类`);
          continue;
        }
        referenced.add(e.threat_ref);
      } else if (e.basis === 'expected') {
        if (e.threat_ref !== null && e.threat_ref !== undefined) {
          problems.push(`basis=expected 的条目（${e.role}/${e.resource}/${e.action}）不应带 threat_ref（实际 ${e.threat_ref}）`);
        }
      }
    }
    for (const id of elev) {
      if (!referenced.has(id)) problems.push(`越权类威胁 ${id} 没有被任何 basis=gap 的矩阵条目引用`);
    }
  }
  emit('AC-016', problems.length ? 'FAIL' : 'PASS', problems.join('; ') || '允许缺口与越权类威胁双向对应');
}

// ---------------------------------------------------------------- 跨套件聚合

const agg = { cases: [], reqs: [], files: [] };
for (const s of main.suites) {
  agg.files.push(s);
  const doc = s.cases;
  if (!isObj(doc)) continue;
  const reqs = Array.isArray(doc.requirements) ? doc.requirements : [];
  const reqById = new Map(reqs.map((r) => [r && r.id, r]));
  for (const r of reqs) agg.reqs.push({ file: s.dirName, req: r });
  for (const c of (Array.isArray(doc.cases) ? doc.cases : [])) {
    agg.cases.push({ file: s.dirName, doc, reqById, case: c });
  }
}

const threatOfReq = (req) => {
  if (!isObj(req) || !filled(req.source_ref)) return null;
  const m = /^threat-model\.json#\/threats\/(TH-\d+)$/.exec(req.source_ref);
  return m ? m[1] : null;
};
const threatIdsOfCase = (item) => {
  const ids = [];
  const refs = Array.isArray(item.case.requirement_refs) ? item.case.requirement_refs : [];
  for (const r of refs) {
    const req = item.reqById.get(r);
    const th = threatOfReq(req);
    if (th) ids.push(th);
  }
  return ids;
};

// ---------------------------------------------------------------- AC-017 每条威胁至少派生 1 条用例 + 不得重复派生

{
  const problems = [];
  if (main.suites.length === 0) problems.push(MISSING_SUITES);
  else {
    const perThreat = new Map();
    for (const item of agg.cases) {
      const ids = threatIdsOfCase(item);
      for (const id of ids) {
        if (!perThreat.has(id)) perThreat.set(id, []);
        perThreat.get(id).push(item);
      }
    }
    for (const t of threats) {
      const list = perThreat.get(t.id) || [];
      if (list.length === 0) problems.push(`威胁 ${t.id} 没有派生出任何安全用例`);
    }
    for (const [id, list] of perThreat.entries()) {
      const titles = list.map((i) => (isObj(i.case) ? i.case.title : undefined));
      if (new Set(titles).size !== titles.length) {
        problems.push(`威胁 ${id} 派生的用例 title 有重复（重复派生）`);
      }
      const steps = list.map((i) => JSON.stringify(isObj(i.case) ? i.case.steps : null));
      if (new Set(steps).size !== steps.length) {
        problems.push(`威胁 ${id} 派生的用例 steps 有完全相同的（重复派生）`);
      }
    }
    for (const item of agg.cases) {
      const refs = isObj(item.case) ? item.case.requirement_refs : null;
      if (!Array.isArray(refs) || refs.length === 0) problems.push(`${item.file} 里有用例的 requirement_refs 为空`);
    }
  }
  emit('AC-017', problems.length ? 'FAIL' : 'PASS', problems.join('; ') || '每条威胁至少派生 1 条用例且不重复派生');
}

// ---------------------------------------------------------------- AC-018 用例 id 形态 / 全局唯一 / 不与输入集冲突

{
  const problems = [];
  if (main.suites.length === 0) problems.push(MISSING_SUITES);
  else {
    const seen = new Map();
    for (const item of agg.cases) {
      const id = isObj(item.case) ? item.case.id : undefined;
      if (!filled(id) || !/^TC-\d{3}$/.test(id)) {
        problems.push(`${item.file} 里有用例 id 非法: ${JSON.stringify(id)}（须合 ^TC-\\d{3}$）`);
        continue;
      }
      if (seen.has(id)) problems.push(`用例 id ${id} 在多个套件里重复（${seen.get(id)} 与 ${item.file}）`);
      else seen.set(id, item.file);
    }
    const inputIds = new Set(((inputCases && Array.isArray(inputCases.cases) ? inputCases.cases : [])).map((c) => c && c.id));
    for (const id of seen.keys()) {
      if (inputIds.has(id)) problems.push(`用例 id ${id} 与 --cases 输入集的 id 冲突`);
    }
  }
  emit('AC-018', problems.length ? 'FAIL' : 'PASS', problems.join('; ') || '用例 id 合 ^TC-\\d{3}$、全局唯一、不与输入集冲突');
}

// ---------------------------------------------------------------- AC-019 source_ref 指向真实威胁 + requirement_refs 不悬空

{
  const problems = [];
  if (main.suites.length === 0) problems.push(MISSING_SUITES);
  else {
    const covered = new Set();
    for (const s of main.suites) {
      const doc = s.cases;
      if (!isObj(doc)) { problems.push(`${s.dirName}/cases.json 不是合法 JSON 对象`); continue; }
      const reqs = Array.isArray(doc.requirements) ? doc.requirements : [];
      const reqIds = new Set();
      for (const r of reqs) {
        if (!isObj(r)) { problems.push(`${s.dirName} 的 requirements[] 里有非对象条目`); continue; }
        if (!filled(r.id)) { problems.push(`${s.dirName} 的 requirements[] 有条目 id 为空`); continue; }
        if (reqIds.has(r.id)) problems.push(`${s.dirName} 的 requirements[].id 重复: ${r.id}`);
        reqIds.add(r.id);
        const th = threatOfReq(r);
        if (!th) {
          problems.push(`${s.dirName} 的 requirement ${r.id} 的 source_ref 不是 "threat-model.json#/threats/<TH-id>" 形式: ${JSON.stringify(r.source_ref)}`);
          continue;
        }
        if (!threatIds.has(th)) {
          problems.push(`${s.dirName} 的 requirement ${r.id} 指向不存在的威胁 ${th}`);
          continue;
        }
        covered.add(th);
      }
      for (const item of agg.cases.filter((x) => x.file === s.dirName)) {
        const refs = isObj(item.case) ? item.case.requirement_refs : null;
        if (!Array.isArray(refs) || refs.length === 0) { problems.push(`${s.dirName} 的用例 ${item.case && item.case.id} 的 requirement_refs 为空`); continue; }
        for (const r of refs) {
          if (!reqIds.has(r)) problems.push(`${s.dirName} 的用例 ${item.case && item.case.id} 的 requirement_refs 指向不存在的 ${r}（悬空）`);
        }
      }
    }
    for (const t of threats) {
      if (!covered.has(t.id)) problems.push(`威胁 ${t.id} 没有对应的 requirements[] 条目`);
    }
  }
  emit('AC-019', problems.length ? 'FAIL' : 'PASS', problems.join('; ') || 'source_ref 指向真实威胁、requirement_refs 不悬空');
}

// ---------------------------------------------------------------- AC-020 顶层封闭 7 个 + 用例字段齐全

{
  const problems = [];
  let undecMsg = null;
  if (main.suites.length === 0) problems.push(MISSING_SUITES);
  else if (METHOD_IDS.size === 0 || DIM_IDS.size === 0) {
    undecMsg = '读不到方法库/维度库（methods.json 或 dimensions.json 缺失）—— 不可判定';
  } else {
    for (const s of main.suites) {
      const doc = s.cases;
      if (!isObj(doc)) { problems.push(`${s.dirName}/cases.json 不是合法 JSON 对象`); continue; }
      const keys = Object.keys(doc).sort();
      const expect = [...CASE_TOP].sort();
      const extra = keys.filter((k) => !expect.includes(k));
      const missing = expect.filter((k) => !keys.includes(k));
      if (extra.length) problems.push(`${s.dirName}/cases.json 的顶层字段集多了 [${extra.join(', ')}]（封闭 7 个）`);
      if (missing.length) problems.push(`${s.dirName}/cases.json 的顶层字段集少了 [${missing.join(', ')}]（封闭 7 个）`);
      if (doc.schema_version !== 2) problems.push(`${s.dirName}/cases.json 的 schema_version 是 ${JSON.stringify(doc.schema_version)}，期望 2`);
      for (const f of ['open_questions', 'defects', 'coverage_matrix']) {
        if (!Array.isArray(doc[f])) problems.push(`${s.dirName}/cases.json 的 ${f} 不是数组`);
      }
      const reqs = Array.isArray(doc.requirements) ? doc.requirements : [];
      const reqIds = new Set(reqs.filter((r) => isObj(r)).map((r) => r.id));
      const cm = Array.isArray(doc.coverage_matrix) ? doc.coverage_matrix : [];
      const cmSeen = new Set();
      for (const m of cm) {
        if (!isObj(m)) { problems.push(`${s.dirName} 的 coverage_matrix[] 里有非对象条目`); continue; }
        if (!reqIds.has(m.requirement)) { problems.push(`${s.dirName} 的 coverage_matrix 的 requirement "${m.requirement}" 不在 requirements[] 里（悬空）`); continue; }
        if (cmSeen.has(m.requirement)) problems.push(`${s.dirName} 的 coverage_matrix 的 requirement 重复: ${m.requirement}`);
        cmSeen.add(m.requirement);
        const ma = Array.isArray(m.methods_applied) ? m.methods_applied : [];
        if (ma.length === 0) problems.push(`${s.dirName} 的 coverage_matrix/${m.requirement} 的 methods_applied 为空`);
        for (const x of ma) if (!METHOD_IDS.has(x)) problems.push(`${s.dirName} 的 coverage_matrix/${m.requirement} 的方法号 "${x}" 不在方法库里`);
        const dims = Array.isArray(m.dimensions) ? m.dimensions : [];
        if (dims.length === 0) problems.push(`${s.dirName} 的 coverage_matrix/${m.requirement} 的 dimensions 为空`);
        for (const d of dims) if (!DIM_IDS.has(d)) problems.push(`${s.dirName} 的 coverage_matrix/${m.requirement} 的维度 "${d}" 不在维度库里`);
        if (!dims.includes('security')) problems.push(`${s.dirName} 的 coverage_matrix/${m.requirement} 的 dimensions 里没有 security`);
      }
      for (const r of reqIds) {
        if (!cmSeen.has(r)) problems.push(`${s.dirName} 的 requirement ${r} 没有出现在 coverage_matrix 里`);
      }
      for (const c of (Array.isArray(doc.cases) ? doc.cases : [])) {
        if (!isObj(c)) { problems.push(`${s.dirName} 的 cases[] 里有非对象条目`); continue; }
        const at = `${s.dirName}/cases.json#${c.id}`;
        if (!filled(c.id)) problems.push(`${at} 的 id 为空`);
        if (!filled(c.title)) problems.push(`${at} 的 title 为空`);
        if (c.dimension !== 'security') problems.push(`${at} 的 dimension 是 ${JSON.stringify(c.dimension)}，期望 security`);
        if (!PRIORITIES.includes(c.priority)) problems.push(`${at} 的 priority 取值非法: ${JSON.stringify(c.priority)}`);
        const method = Array.isArray(c.method) ? c.method : null;
        if (!method || method.length === 0) problems.push(`${at} 的 method 为空`);
        else for (const x of method) if (!METHOD_IDS.has(x)) problems.push(`${at} 的方法号 "${x}" 不在方法库里`);
        if (!CASE_STATUSES.includes(c.status)) problems.push(`${at} 的 status 是 ${JSON.stringify(c.status)}，必须恒为 active`);
        if (c.revision !== undefined) problems.push(`${at} 带了 revision（安全用例刚派生，不得声明修订）`);
        const steps = Array.isArray(c.steps) ? c.steps : null;
        if (!steps || steps.length === 0) problems.push(`${at} 的 steps 为空`);
        else {
          steps.forEach((st, i) => {
            if (!isObj(st)) { problems.push(`${at} 的 steps[${i}] 不是对象`); return; }
            if (!filled(st.action)) problems.push(`${at} 的 steps[${i}].action 为空`);
            if (!filled(st.expected)) problems.push(`${at} 的 steps[${i}].expected 为空`);
          });
        }
        if (!Array.isArray(c.tags)) problems.push(`${at} 的 tags 不是数组`);
      }
    }
  }
  if (undecMsg) emit('AC-020', 'UNDEC', undecMsg);
  else emit('AC-020', problems.length ? 'FAIL' : 'PASS', problems.join('; ') || '顶层封闭 7 个且用例字段齐全');
}

// ---------------------------------------------------------------- AC-021 tags 含 security 与威胁 id

{
  const problems = [];
  if (main.suites.length === 0) problems.push(MISSING_SUITES);
  else {
    for (const item of agg.cases) {
      const c = item.case;
      if (!isObj(c)) continue;
      const tags = Array.isArray(c.tags) ? c.tags : [];
      if (!tags.includes('security')) problems.push(`${item.file} 的用例 ${c.id} 的 tags 里没有 security`);
      for (const th of threatIdsOfCase(item)) {
        if (!tags.includes(th)) problems.push(`${item.file} 的用例 ${c.id} 的 tags 里没有威胁 id ${th}`);
      }
    }
  }
  emit('AC-021', problems.length ? 'FAIL' : 'PASS', problems.join('; ') || 'tags 含 security 与威胁 id');
}

// ---------------------------------------------------------------- AC-025 威胁集合与输入可对账

{
  const problems = [];
  if (!tm) problems.push(MISSING_TM);
  else {
    const usedAssets = new Set();
    const usedBoundaries = new Set();
    const usedEntries = new Set();
    for (const t of threats) {
      if (!isObj(t)) continue;
      const a = Array.isArray(t.asset_refs) ? t.asset_refs : [];
      const b = Array.isArray(t.boundary_refs) ? t.boundary_refs : [];
      const e = Array.isArray(t.entry_point_refs) ? t.entry_point_refs : [];
      if (a.length === 0) problems.push(`威胁 ${t.id} 的 asset_refs 为空`);
      if (b.length === 0) problems.push(`威胁 ${t.id} 的 boundary_refs 为空`);
      if (e.length === 0) problems.push(`威胁 ${t.id} 的 entry_point_refs 为空`);
      for (const x of a) { if (!ctxAssetIds.has(x)) problems.push(`威胁 ${t.id} 的 asset_refs 指向不存在的资产 ${x}`); else usedAssets.add(x); }
      for (const x of b) { if (!ctxBoundaryIds.has(x)) problems.push(`威胁 ${t.id} 的 boundary_refs 指向不存在的信任边界 ${x}`); else usedBoundaries.add(x); }
      for (const x of e) { if (!ctxEntryIds.has(x)) problems.push(`威胁 ${t.id} 的 entry_point_refs 指向不存在的入口点 ${x}`); else usedEntries.add(x); }
    }
    for (const id of ctxAssetIds) if (!usedAssets.has(id)) problems.push(`上下文的资产 ${id} 没有被任何威胁引用（漏了）`);
    for (const id of ctxBoundaryIds) if (!usedBoundaries.has(id)) problems.push(`上下文的信任边界 ${id} 没有被任何威胁引用（漏了）`);
    for (const id of ctxEntryIds) if (!usedEntries.has(id)) problems.push(`上下文的入口点 ${id} 没有被任何威胁引用（漏了）`);
  }
  emit('AC-025', problems.length ? 'FAIL' : 'PASS', problems.join('; ') || '威胁集合与输入可对账');
}

// ---------------------------------------------------------------- AC-026 不得凭空造威胁 / 不得凭空声称已覆盖

{
  const problems = [];
  if (!tm) problems.push(MISSING_TM);
  else {
    for (const t of threats) {
      if (!isObj(t)) continue;
      if (!filled(t.rationale)) problems.push(`威胁 ${t && t.id} 的 rationale 为空`);
    }
    const cov = isObj(tm.owasp_coverage) ? tm.owasp_coverage : {};
    for (const cls of OWASP_CLASSES) {
      const item = cov[cls];
      if (!isObj(item) || item.status !== 'covered') continue;
      const refs = Array.isArray(item.threat_refs) ? item.threat_refs : [];
      if (refs.length === 0) problems.push(`OWASP ${cls} 声明 covered 但 threat_refs 为空（凭空声称已覆盖）`);
      for (const r of refs) if (!threatIds.has(r)) problems.push(`OWASP ${cls} 声明 covered 但引用了不存在的威胁 ${r}`);
    }
    const sup = isObj(tm.supplements) ? tm.supplements : {};
    for (const key of SUPPLEMENTS) {
      const item = sup[key];
      if (!isObj(item) || item.status !== 'covered') continue;
      const refs = Array.isArray(item.threat_refs) ? item.threat_refs : [];
      if (refs.length === 0) problems.push(`实战补充 ${key} 声明 covered 但 threat_refs 为空（凭空声称已覆盖）`);
      for (const r of refs) if (!threatIds.has(r)) problems.push(`实战补充 ${key} 声明 covered 但引用了不存在的威胁 ${r}`);
    }
  }
  emit('AC-026', problems.length ? 'FAIL' : 'PASS', problems.join('; ') || '没有凭空造威胁，也没有凭空声称已覆盖');
}

// ---------------------------------------------------------------- AC-027 覆盖声明与事实一致

{
  const problems = [];
  if (!tm) problems.push(MISSING_TM);
  else {
    const cov = isObj(tm.owasp_coverage) ? tm.owasp_coverage : {};
    for (const cls of OWASP_CLASSES) {
      const item = cov[cls];
      if (!isObj(item)) continue;
      const classThreats = threats.filter((t) => isObj(t) && t.owasp === cls).map((t) => t.id);
      if (item.status === 'covered') {
        const refs = Array.isArray(item.threat_refs) ? item.threat_refs : [];
        if (!sameSet(uniq(refs), uniq(classThreats))) {
          problems.push(`OWASP ${cls} 声明 covered，但该类威胁集合与声明不一致（声明: [${refs.join(',')}] 实际: [${classThreats.join(',')}]）`);
        }
      } else if (item.status === 'not_applicable') {
        if (classThreats.length > 0) {
          problems.push(`OWASP ${cls} 声明 not_applicable，却仍有该类威胁 [${classThreats.join(',')}]（自相矛盾）`);
        }
      }
    }
    const sup = isObj(tm.supplements) ? tm.supplements : {};
    for (const key of SUPPLEMENTS) {
      const item = sup[key];
      if (!isObj(item)) continue;
      const classThreats = threats
        .filter((t) => isObj(t) && Array.isArray(t.supplement_refs) && t.supplement_refs.includes(key))
        .map((t) => t.id);
      if (item.status === 'covered') {
        const refs = Array.isArray(item.threat_refs) ? item.threat_refs : [];
        if (!sameSet(uniq(refs), uniq(classThreats))) {
          problems.push(`实战补充 ${key} 声明 covered，但相关威胁集合与声明不一致（声明: [${refs.join(',')}] 实际: [${classThreats.join(',')}]）`);
        }
      } else if (item.status === 'not_applicable') {
        if (classThreats.length > 0) {
          problems.push(`实战补充 ${key} 声明 not_applicable，却仍有相关威胁 [${classThreats.join(',')}]（自相矛盾）`);
        }
      }
    }
  }
  emit('AC-027', problems.length ? 'FAIL' : 'PASS', problems.join('; ') || '覆盖声明与威胁事实一致');
}

process.stdout.write(`${out.join('\n')}\n`);
FIXJUDGE

cat > "$WORK/judge-cfg.json" <<CFGCFG
{
  "context": "$CTX",
  "cases": "$FCASES",
  "main": "$PROJ_MAIN",
  "noScan": "$PROJ_NOSCAN",
  "unavail": "$PROJ_UNAVAIL",
  "methodsFile": "$TCD/references/methods.json",
  "dimensionsFile": "$TCD/references/dimensions.json"
}
CFGCFG

JUDGE_OUT="$WORK/judge.out"
node "$WORK/judge.mjs" "$WORK/judge-cfg.json" > "$JUDGE_OUT" 2>"$WORK/judge.err"
JUDGE_RC=$?
if [ "$JUDGE_RC" -ne 0 ]; then
  printf '复算器异常退出（rc=%s）—— 产物侧判据不可判定\n' "$JUDGE_RC"
  head -5 "$WORK/judge.err"
  for id in AC-009 AC-010 AC-011 AC-012 AC-013 AC-014 AC-015 AC-016 AC-017 AC-018 AC-019 \
            AC-020 AC-021 AC-025 AC-026 AC-027; do
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

# ---------------------------------------------------------------- 上游加载层检查（loadcheck.mjs，**另一个进程**）

step "AC-024 上游加载层检查（loadSuite / loadCases / selectCases + validate-cases.mjs）"

cat > "$WORK/loadcheck.mjs" <<'FIXLC'
// loadcheck.mjs —— **另一个进程**：调用**被验包**的上游加载层
// ⚠️ 与 judge.mjs 的分工（D122）：
//    judge.mjs 是**独立复算器**，绝不 import 被验包；
//    本脚本**故意** import 被验包的 suite-loader.mjs —— 因为「产品能不能被上游消费」
//    的**唯一**真实答案只能问上游本人。
// 用法: node loadcheck.mjs <cfg.json>
// 输出: JSON { ok, perSuite: [ { suite, loadSuite, loadCases, selected, total, problems: [] } ] }
import fs from 'node:fs';
import path from 'node:path';

const cfg = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const { loadSuite, loadCases, selectCases } = await import(cfg.suiteLoaderUrl);

const secRoot = path.join(cfg.outDir, 'test-assets', 'security');
const suitesDir = path.join(secRoot, 'suites');
let names = [];
try {
  names = fs.readdirSync(suitesDir).filter((n) => {
    try { return fs.statSync(path.join(suitesDir, n)).isDirectory(); } catch { return false; }
  }).sort();
} catch { names = []; }

const perSuite = [];
for (const name of names) {
  const suiteFile = path.join(suitesDir, name, 'suite.json');
  const entry = { suite: name, loadSuite: false, loadCases: false, selected: 0, total: 0, problems: [] };
  let config = null;
  try {
    const loaded = loadSuite(suiteFile);
    config = loaded.config;
    entry.loadSuite = true;
  } catch (err) {
    entry.problems.push(`loadSuite 抛错: ${err.message}`);
  }
  if (config) {
    try {
      const casesFile = path.isAbsolute(config.cases_file)
        ? config.cases_file
        : path.resolve(path.dirname(suiteFile), config.cases_file);
      const doc = loadCases(casesFile);
      entry.loadCases = true;
      entry.total = Array.isArray(doc.cases) ? doc.cases.length : 0;
      const selected = selectCases(doc.cases, config.tags);
      entry.selected = selected.length;
      const include = config.tags && Array.isArray(config.tags.include) ? config.tags.include : [];
      if (include.length === 0) {
        if (selected.length !== entry.total) {
          entry.problems.push(`tags.include 为空时 selectCases 应选出全部用例（${selected.length}/${entry.total}）`);
        }
      } else {
        const tagged = doc.cases.filter((c) => include.some((t) => Array.isArray(c.tags) && c.tags.includes(t)));
        if (selected.length !== tagged.length) {
          entry.problems.push(`selectCases 选出的条数（${selected.length}）与按 tags.include 手算的条数（${tagged.length}）不一致`);
        }
      }
    } catch (err) {
      entry.problems.push(`loadCases/selectCases 抛错: ${err.message}`);
    }
  }
  perSuite.push(entry);
}

process.stdout.write(`${JSON.stringify({ ok: perSuite.length > 0, perSuite })}\n`);
FIXLC

AC24_PROBLEMS=""
AC24_STATUS="PASS"
if [ "$IMPL_MISSING" -eq 1 ]; then
  AC24_STATUS="FAIL"; AC24_PROBLEMS="实现缺失：$ENTRY_REL 不存在"
elif [ ! -f "$TEX/scripts/lib/suite-loader.mjs" ]; then
  AC24_STATUS="UNDEC"; AC24_PROBLEMS="被验包里没有 test-execute 的 suite-loader.mjs —— 加载层检查不可判定"
elif [ ! -f "$TCD/scripts/validate-cases.mjs" ]; then
  AC24_STATUS="UNDEC"; AC24_PROBLEMS="被验包里没有 test-case-design 的 validate-cases.mjs —— 用例集校验不可判定"
else
  cat > "$WORK/loadcheck-cfg.json" <<LCCFG
{
  "outDir": "$PROJ_MAIN",
  "suiteLoaderUrl": "file://$TEX/scripts/lib/suite-loader.mjs"
}
LCCFG
  LC_OUT="$(node "$WORK/loadcheck.mjs" "$WORK/loadcheck-cfg.json" 2>"$WORK/loadcheck.err")"
  LC_RC=$?
  if [ "$LC_RC" -ne 0 ]; then
    AC24_STATUS="UNDEC"; AC24_PROBLEMS="加载层检查进程异常退出（rc=$LC_RC）：$(head -2 "$WORK/loadcheck.err" | tr '\n' ' ')"
  else
    LC_PROBLEMS="$(node -e '
const s=process.argv[1]||"";
try{const o=JSON.parse(s);const p=[];for(const x of (o.perSuite||[])){for(const m of (x.problems||[]))p.push(x.suite+": "+m);}
  if((o.perSuite||[]).length===0)p.push("没有套件目录");
  process.stdout.write(p.join("; "));}catch(e){process.stdout.write("PARSE_ERR: "+e.message);}' "$LC_OUT" 2>/dev/null)"
    if [ -n "$LC_PROBLEMS" ]; then AC24_STATUS="FAIL"; AC24_PROBLEMS="$LC_PROBLEMS"; fi
  fi
  # 产物 cases.json 过 validate-cases.mjs（退出码 0；上游对 open_questions 为空只记 WARN）
  VC_PROBLEMS=""
  VC_FOUND=0
  for cases_file in "$PROJ_MAIN"/test-assets/security/suites/*/cases.json; do
    [ -f "$cases_file" ] || continue
    VC_FOUND=$((VC_FOUND+1))
    node "$TCD/scripts/validate-cases.mjs" "$cases_file" >"$WORK/validate-cases.log" 2>&1
    VC_RC=$?
    if [ "$VC_RC" -ne 0 ]; then
      VC_PROBLEMS="$VC_PROBLEMS [$(basename "$(dirname "$cases_file")"): validate-cases 退出码 $VC_RC: $(head -2 "$WORK/validate-cases.log" | tr '\n' ' ')]"
    fi
  done
  if [ "$VC_FOUND" -eq 0 ]; then
    AC24_STATUS="FAIL"; AC24_PROBLEMS="$AC24_PROBLEMS [没有可校验的 cases.json]"
  elif [ -n "$VC_PROBLEMS" ]; then
    AC24_STATUS="FAIL"; AC24_PROBLEMS="$AC24_PROBLEMS$VC_PROBLEMS"
  fi
fi
case "$AC24_STATUS" in
  PASS) ok "AC-024 上游加载层可解析（loadSuite/loadCases/selectCases + validate-cases 通过；不要求执行器可跑）" "AC-024" ;;
  UNDEC) undec "AC-024 $AC24_PROBLEMS" "AC-024" ;;
  *) bad "AC-024 上游加载层不可解析" "AC-024"; printf '  · %s\n' "$AC24_PROBLEMS" >> "$RES_DIR/AC-024.res" ;;
esac

# ---------------------------------------------------------------- A 组（交付物形状）

step "AC-001 security-plan skill 存在且结构合法"
A1="AC-001"
A1_PROBLEMS=""
if [ ! -d "$TR" ]; then
  A1_PROBLEMS="缺目录 skills/security-plan/"
else
  for f in "SKILL.md" "skill-meta.json" \
           "references/security-context-schema.md" "references/threat-model-format.md" \
           "references/matrix-format.md" "references/derivation-rules.md" \
           "scripts/make-security-plan.mjs" "scripts/check-security-plan.mjs"; do
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
    [ "$FM_NAME_VAL" = "security-plan" ] && NAME_OK=1
    DESC_EMPTY="$(node -e 'try{const o=JSON.parse(process.argv[1]);console.log(o.found&&!o.empty?"0":"1")}catch(e){console.log("1")}' "$FM_DESC")"
    [ "$DESC_EMPTY" = "0" ] && DESC_OK=1
  fi
  # 逐脚本判定（各自满足，不是两个合起来满足其一）
  A1_SCRIPT_PROBLEMS=""
  for f in "scripts/make-security-plan.mjs" "scripts/check-security-plan.mjs"; do
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
    A1_PROBLEMS="SKILL.md frontmatter 的 name 不是 security-plan"
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
SP_TCD=0; SP_QTC=0; SP_TEX=0
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
  if [ "$NAME" = "security-plan" ]; then
    case ",$REQ," in *,test-case-design,*) SP_TCD=1 ;; esac
    case ",$REQ," in *,qa-toolchain,*) SP_QTC=1 ;; esac
    case ",$REQ," in *,test-execute,*) SP_TEX=1 ;; esac
  fi
done
if [ -z "$SKILL_DIRS" ]; then
  A2_PROBLEMS="被验包里没有任何含 SKILL.md 的 skill 目录"
elif [ "${SP_TCD:-0}" != "1" ]; then
  A2_PROBLEMS="$A2_PROBLEMS [security-plan 的 requires 里没有 test-case-design（它消费方法库/维度库/目录契约，是硬依赖）]"
elif [ "${SP_QTC:-0}" != "1" ]; then
  A2_PROBLEMS="$A2_PROBLEMS [security-plan 的 requires 里没有 qa-toolchain（扫描器由 bin/qa 跑、结果喂进 --scan，是硬依赖）]"
elif [ "${SP_TEX:-0}" = "1" ]; then
  A2_PROBLEMS="$A2_PROBLEMS [security-plan 的 requires 里含 test-execute —— REQ-002.8 依赖 002.2+002.4 不含 002.5b，且 security 执行器未实现，这是假依赖（D121）]"
fi
if [ -z "$A2_PROBLEMS" ]; then ok "$A2" "$A2"; else bad "$A2" "$A2"; printf '  · %s\n' "$A2_PROBLEMS" >> "$RES_DIR/$A2.res"; fi

step "AC-003 README 的 skill 清单与实际目录一致（两处都要有 security-plan）"
A3="AC-003"
A3_PROBLEMS=""
if [ ! -s "$README" ]; then
  A3_PROBLEMS="缺 README.md 或为空"
else
  README_NAMES="$(node "$WORK/readme-skills.mjs" "$README" 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log((JSON.parse(s).names||[]).join(" "))}catch(e){console.log("")}})')"
  README_TABLE="$(node "$WORK/readme-skills.mjs" "$README" 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log((JSON.parse(s).table||[]).join(" "))}catch(e){console.log("")}})')"
  README_TREE="$(node "$WORK/readme-skills.mjs" "$README" 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log((JSON.parse(s).tree||[]).join(" "))}catch(e){console.log("")}})')"
  ACTUAL_NAMES=""
  for d in $SKILL_DIRS; do ACTUAL_NAMES="$ACTUAL_NAMES $(basename "$d")"; done
  R_SORT="$(printf '%s\n' $README_NAMES | sort -u | tr '\n' ' ' | sed 's/ $//')"
  A_SORT="$(printf '%s\n' $ACTUAL_NAMES | sort -u | tr '\n' ' ' | sed 's/ $//')"
  [ -n "$A_SORT" ] || A3_PROBLEMS="$A3_PROBLEMS [被验包里没有任何含 SKILL.md 的 skill 目录]"
  [ "$R_SORT" = "$A_SORT" ] || A3_PROBLEMS="$A3_PROBLEMS [README 的 skill 清单=[$R_SORT] 与实际目录=[$A_SORT] 不一致]"
  case " $README_TABLE " in *" security-plan "*) ;; *) A3_PROBLEMS="$A3_PROBLEMS [security-plan 没出现在 README 的 skill 表格里]" ;; esac
  case " $README_TREE " in *" security-plan "*) ;; *) A3_PROBLEMS="$A3_PROBLEMS [security-plan 没出现在 README 的安装树代码块里]" ;; esac
fi
if [ -z "$A3_PROBLEMS" ]; then ok "$A3" "$A3"; else bad "$A3" "$A3"; printf '  · %s\n' "$A3_PROBLEMS" >> "$RES_DIR/$A3.res"; fi

step "AC-004 新产物不得打破既有目录契约（实跑 verify-layout.mjs）"
A4="AC-004"
A4_PROBLEMS=""
A4_NOTE=""
LAYOUT="$TCD/scripts/verify-layout.mjs"
if [ ! -f "$LAYOUT" ]; then
  A4_PROBLEMS="被验包里没有 test-case-design 的 verify-layout.mjs —— 兼容性不可判定"
else
  # ① 把安全产物放进契约规定的项目根
  LAY_PROJ="$WORK/layout-proj"
  mkdir -p "$LAY_PROJ"
  cp -r "$FX/proj"/. "$LAY_PROJ"/ 2>/dev/null
  mkdir -p "$LAY_PROJ/test-assets/security"
  cp -r "$PROJ_MAIN/test-assets/security/." "$LAY_PROJ/test-assets/security/" 2>/dev/null
  # ② 跑校验器
  LAY_OUT="$(node "$LAYOUT" "$LAY_PROJ" 2>&1)"; LAY_RC=$?
  if [ "$LAY_RC" -ne 0 ]; then
    A4_PROBLEMS="$A4_PROBLEMS [verify-layout.mjs 退出码 $LAY_RC（期望 0）: $(printf '%s' "$LAY_OUT" | grep -iE 'fail|问题|违规' | head -3 | tr '\n' ' ')]"
  fi
  if printf '%s' "$LAY_OUT" | grep -qE '^\[FAIL\]|^FAIL|✗'; then
    A4_PROBLEMS="$A4_PROBLEMS [verify-layout.mjs 输出里出现 FAIL 级问题: $(printf '%s' "$LAY_OUT" | grep -E '^\[FAIL\]|^FAIL|✗' | head -3 | tr '\n' ' ')]"
  fi
  # ④ 错误位置探针：把 threat-model.json 放到契约外，记录校验器的结论
  LAY_PROBE="$WORK/layout-probe"
  mkdir -p "$LAY_PROBE"
  cp -r "$FX/proj"/. "$LAY_PROBE"/ 2>/dev/null
  mkdir -p "$LAY_PROBE/test-assets/security"
  cp -r "$PROJ_MAIN/test-assets/security/." "$LAY_PROBE/test-assets/security/" 2>/dev/null
  cp "$LAY_PROBE/test-assets/security/threat-model.json" "$LAY_PROBE/test-assets/threat-model.json" 2>/dev/null
  PROBE_OUT="$(node "$LAYOUT" "$LAY_PROBE" 2>&1)"; PROBE_RC=$?
  if [ "$PROBE_RC" -eq 0 ]; then
    A4_NOTE="错误位置探针：校验器**不查** threat-model.json 的位置（退出码 0）⇒ 位置不受约束（不得要求实现去管它）"
  else
    A4_NOTE="错误位置探针：校验器对 threat-model.json 的错误位置**判红**（退出码 $PROBE_RC）⇒ 位置受约束"
  fi
  printf '  · %s\n' "$A4_NOTE"
fi
if [ -z "$A4_PROBLEMS" ]; then ok "$A4" "$A4"; else bad "$A4" "$A4"; printf '  · %s\n' "$A4_PROBLEMS" >> "$RES_DIR/$A4.res"; fi

# ---------------------------------------------------------------- B 组（输入解析与校验）

step "AC-005 ~ AC-008 输入解析与校验"

# 判一个变体：$1 = 变体名, $2 = 期望 stderr 里必须出现的词（| 分隔，任一命中即可）
check_bad_variant() {
  local name="$1" tokens="$2"
  local safe="${name//-/_}"
  local rcvar="BAD_RC_$safe" leftover="BAD_LEFTOVER_$safe" errvar="BAD_ERR_$safe"
  local rc="${!rcvar:-127}" leftover_flag="${!leftover:-yes}" errf="${!errvar:-/nonexistent}"
  local problems=""
  if [ "$rc" = "127" ]; then
    problems="实现缺失，本变体未跑"
  else
    [ "$rc" = "1" ] || problems="退出码是 $rc，要求 1（输入非法）"
    if [ "$leftover_flag" = "yes" ]; then
      problems="$problems 留下了半份产物（threat-model.json / matrix.json / suites/ 之一出现了）"
    fi
    local errtext=""
    [ -f "$errf" ] && errtext="$(cat "$errf" 2>/dev/null)"
    if ! printf '%s' "$errtext" | grep -qE "($tokens)"; then
      problems="$problems stderr 里没有点名坏点（期望出现其中之一: $tokens）；实际 stderr: $(printf '%s' "$errtext" | head -2 | tr '\n' ' ')"
    fi
  fi
  if [ -n "$problems" ]; then
    B_PROBLEMS="$B_PROBLEMS [$name: $problems]"
  fi
}

b_begin() { B_CUR="$1"; B_PROBLEMS=""; }
b_end() {
  if [ -z "$B_PROBLEMS" ]; then ok "$B_CUR" "$B_CUR"; else bad "$B_CUR" "$B_CUR"; printf '  · %s\n' "$B_PROBLEMS" >> "$RES_DIR/$B_CUR.res"; fi
}

b_begin "AC-005"
run_bad "c-no-assets" "$FX/bad/c-no-assets.json" ""
run_bad "c-boundaries-string" "$FX/bad/c-boundaries-string.json" ""
run_bad "c-no-ep-name" "$FX/bad/c-no-ep-name.json" ""
run_bad "c-no-roles" "$FX/bad/c-no-roles.json" ""
run_bad "c-resources-object" "$FX/bad/c-resources-object.json" ""
check_bad_variant "c-no-assets" "assets"
check_bad_variant "c-boundaries-string" "trust_boundaries"
check_bad_variant "c-no-ep-name" "entry_points|name"
check_bad_variant "c-no-roles" "roles"
check_bad_variant "c-resources-object" "resources"
b_end

b_begin "AC-006"
run_bad "c-dangling-asset" "$FX/bad/c-dangling-asset.json" ""
run_bad "c-dangling-boundary" "$FX/bad/c-dangling-boundary.json" ""
run_bad "c-empty-res-assets" "$FX/bad/c-empty-res-assets.json" ""
check_bad_variant "c-dangling-asset" "AS-999"
check_bad_variant "c-dangling-boundary" "TB-999"
check_bad_variant "c-empty-res-assets" "assets|RES-1|为空"
b_end

b_begin "AC-007"
run_bad "c-dup-asset" "$FX/bad/c-dup-asset.json" ""
run_bad "c-bad-ep-id" "$FX/bad/c-bad-ep-id.json" ""
check_bad_variant "c-dup-asset" "AS-1"
check_bad_variant "c-bad-ep-id" "EP-XYZ"
b_end

b_begin "AC-008"
run_bad "c-bad-sensitivity" "$FX/bad/c-bad-sensitivity.json" ""
run_bad "c-empty-kind" "$FX/bad/c-empty-kind.json" ""
run_bad "unknown-scan" "$CTX" "$UNKNOWNSCAN"
check_bad_variant "c-bad-sensitivity" "sensitivity|secret"
check_bad_variant "c-empty-kind" "kind"
check_bad_variant "unknown-scan" "scan|扫描|无法识别|形态"
# 三种合法扫描形态都要被接受（退出码 0）
if [ "$RC_NPMAUDIT" != "0" ]; then
  B_PROBLEMS="$B_PROBLEMS [合法扫描形态 npm-audit 未被接受：退出码 $RC_NPMAUDIT：$(head -2 "$WORK/impl-npmaudit.err" 2>/dev/null | tr '\n' ' ')]"
fi
if [ "$RC_UNAVAIL" != "0" ]; then
  B_PROBLEMS="$B_PROBLEMS [合法扫描形态 unavailable 未被接受：退出码 $RC_UNAVAIL：$(head -2 "$WORK/impl-unavail.err" 2>/dev/null | tr '\n' ' ')]"
fi
if [ "$RC_MAIN" != "0" ]; then
  B_PROBLEMS="$B_PROBLEMS [合法扫描形态 bandit 未被接受：退出码 $RC_MAIN：$(head -2 "$WORK/impl-main.err" 2>/dev/null | tr '\n' ' ')]"
fi
b_end

# ---------------------------------------------------------------- F 组：套件落位（AC-022 / AC-023）

step "AC-022 / AC-023 套件目录名与 suite.json 字段集"

cat > "$WORK/suite-check.mjs" <<'FIXSC'
// suite-check.mjs —— 套件落位检查（AC-022 / AC-023）
// 用法: node suite-check.mjs <项目根>
// 输出: JSON { ac022: [问题...], ac023: [问题...] }
import fs from 'node:fs';
import path from 'node:path';

const root = process.argv[2];
const sec = path.join(root, 'test-assets', 'security');
const suitesDir = path.join(sec, 'suites');
const ALLOWED = ['suite', 'requirement', 'scope', 'environment', 'cases_file', 'executor', 'base_url_from', 'tags', 'report'];
const REQUIRED = ['suite', 'requirement', 'scope', 'environment', 'cases_file', 'executor'];
const ac022 = [];
const ac023 = [];

let names = [];
try {
  names = fs.readdirSync(suitesDir).filter((n) => fs.statSync(path.join(suitesDir, n)).isDirectory()).sort();
} catch { names = []; }

if (names.length === 0) {
  ac022.push('test-assets/security/suites/ 下没有套件目录');
}

for (const name of names) {
  const dir = path.join(suitesDir, name);
  if (!/^SEC-\d{3}-[a-z0-9][a-z0-9-]*$/.test(name)) {
    ac022.push(`套件目录名 "${name}" 不合规（须合 ^SEC-\\d{3}-[a-z0-9][a-z0-9-]*$）`);
  }
  const casesFile = path.join(dir, 'cases.json');
  const suiteFile = path.join(dir, 'suite.json');
  for (const [label, file] of [['cases.json', casesFile], ['suite.json', suiteFile]]) {
    let ok = false;
    try { ok = fs.statSync(file).isFile() && fs.statSync(file).size > 0; } catch { ok = false; }
    if (!ok) ac022.push(`套件目录 ${name} 缺 ${label} 或为空`);
  }
  let suite = null;
  try { suite = JSON.parse(fs.readFileSync(suiteFile, 'utf8')); } catch { suite = null; }
  if (!suite || typeof suite !== 'object' || Array.isArray(suite)) {
    ac023.push(`套件 ${name} 的 suite.json 不是合法 JSON 对象`);
    continue;
  }
  if (suite.suite !== name) {
    ac022.push(`套件 ${name} 的 suite.json 的 suite 字段是 ${JSON.stringify(suite.suite)}，与目录名不一致`);
  }
  for (const key of Object.keys(suite)) {
    if (!ALLOWED.includes(key)) ac023.push(`套件 ${name} 的 suite.json 出现表外字段 "${key}"（顶层字段集封闭 9 个）`);
  }
  for (const key of REQUIRED) {
    if (typeof suite[key] !== 'string' || suite[key].trim() === '') {
      ac023.push(`套件 ${name} 的 suite.json 缺必填字段 ${key}`);
    }
  }
  if (suite.scope !== 'security') ac023.push(`套件 ${name} 的 scope 是 ${JSON.stringify(suite.scope)}，要求 security`);
  if (suite.executor !== 'security') ac023.push(`套件 ${name} 的 executor 是 ${JSON.stringify(suite.executor)}，要求 security`);
  if (typeof suite.environment === 'string' && suite.environment.trim() !== '') {
    const envFile = path.join(root, 'test-assets', 'environments', `${suite.environment}.json`);
    if (!fs.existsSync(envFile)) ac023.push(`套件 ${name} 的 environment "${suite.environment}" 在 test-assets/environments/ 下没有同名 .json`);
  }
  if (typeof suite.cases_file === 'string' && suite.cases_file.trim() !== '') {
    const target = path.resolve(dir, suite.cases_file);
    if (!fs.existsSync(target)) ac023.push(`套件 ${name} 的 cases_file "${suite.cases_file}" 指向的文件不存在`);
  }
}

process.stdout.write(`${JSON.stringify({ ac022, ac023 })}\n`);
FIXSC

A22_PROBLEMS=""
A23_PROBLEMS=""
if [ ! -d "$PROJ_MAIN/test-assets/security" ]; then
  A22_PROBLEMS="产物缺失：<out-dir>/test-assets/security/ 不存在"
  A23_PROBLEMS="产物缺失：<out-dir>/test-assets/security/ 不存在"
else
  SC_OUT="$(node "$WORK/suite-check.mjs" "$PROJ_MAIN" 2>"$WORK/suite-check.err")"
  SC_RC=$?
  if [ "$SC_RC" -ne 0 ]; then
    A22_PROBLEMS="套件落位检查进程异常退出（rc=$SC_RC）"
    A23_PROBLEMS="套件落位检查进程异常退出（rc=$SC_RC）"
  else
    A22_PROBLEMS="$(node -e 'const s=process.argv[1]||"";try{const o=JSON.parse(s);process.stdout.write((o.ac022||[]).join("; "))}catch(e){process.stdout.write("PARSE_ERR")}' "$SC_OUT" 2>/dev/null)"
    A23_PROBLEMS="$(node -e 'const s=process.argv[1]||"";try{const o=JSON.parse(s);process.stdout.write((o.ac023||[]).join("; "))}catch(e){process.stdout.write("PARSE_ERR")}' "$SC_OUT" 2>/dev/null)"
  fi
fi
if [ -z "$A22_PROBLEMS" ]; then ok "AC-022" "AC-022"; else bad "AC-022" "AC-022"; printf '  · %s\n' "$A22_PROBLEMS" >> "$RES_DIR/AC-022.res"; fi
if [ -z "$A23_PROBLEMS" ]; then ok "AC-023" "AC-023"; else bad "AC-023" "AC-023"; printf '  · %s\n' "$A23_PROBLEMS" >> "$RES_DIR/AC-023.res"; fi

# ---------------------------------------------------------------- AC-028 幂等 / 只写 / 不覆盖

step "AC-028 幂等、只写自己的目录、不得改输入"
A28="AC-028"
A28_PROBLEMS=""
if [ "$IMPL_MISSING" -eq 1 ]; then
  A28_PROBLEMS="实现缺失，无法核幂等与只读"
else
  # ① 幂等：两次运行（不同 out-dir）逐字比较（排除 meta.generated_at）
  IDEM_CMP="$(node -e '
const fs=require("fs"),path=require("path");
const a=process.argv[1],b=process.argv[2];
const strip=(d)=>{if(d&&typeof d==="object"){if(Array.isArray(d))return d.map(strip);
  const o={};for(const k of Object.keys(d).sort()){if(k==="generated_at")continue;o[k]=strip(d[k]);}return o;}return d;};
const list=(root)=>{const r=[];const walk=(d)=>{let es=[];try{es=fs.readdirSync(d,{withFileTypes:true});}catch{return;}
for(const e of es){const f=path.join(d,e.name);if(e.isDirectory())walk(f);else if(e.isFile())r.push(path.relative(root,f).split(path.sep).join("/"));}};
walk(root);r.sort();return r;};
const ra=list(a),rb=list(b);
const problems=[];
if(JSON.stringify(ra)!==JSON.stringify(rb))problems.push("两次运行产出的文件清单不同："+JSON.stringify(ra)+" vs "+JSON.stringify(rb));
else for(const rel of ra){let x,y;
 try{x=JSON.parse(fs.readFileSync(path.join(a,rel),"utf8"));}catch(e){problems.push(rel+" 不是合法 JSON");continue;}
 try{y=JSON.parse(fs.readFileSync(path.join(b,rel),"utf8"));}catch(e){problems.push(rel+" 不是合法 JSON");continue;}
 if(JSON.stringify(strip(x))!==JSON.stringify(strip(y)))problems.push(rel+" 两次运行不相同（除 generated_at 外）");}
console.log(problems.join("; "));
' "$PROJ_IDEM1/test-assets/security" "$PROJ_IDEM2/test-assets/security" 2>/dev/null)"
  [ -z "$IDEM_CMP" ] || A28_PROBLEMS="$A28_PROBLEMS [$IDEM_CMP]"
  # ② 输入只读：sha256 前后一致
  INPUTS_AFTER="$(node "$WORK/snapdir.mjs" "$FX/inputs" 2>/dev/null)"
  [ "$INPUTS_BEFORE" = "$INPUTS_AFTER" ] || A28_PROBLEMS="$A28_PROBLEMS [输入文件在跑完后变了（sha256 前后不一致）]"
  # ③ 只写 out-dir：夹具目录里不得出现产物
  STRAY="$(find "$FX" -path "$FX/proj" -prune -o -name 'threat-model.json' -print -o -name 'matrix.json' -print 2>/dev/null | head -3)"
  [ -z "$STRAY" ] || A28_PROBLEMS="$A28_PROBLEMS [out-dir 之外出现了产物: $STRAY]"
  PROJ_AFTER="$(node "$WORK/snapdir.mjs" "$FX/proj" 2>/dev/null)"
  # ④ 产物已存在即报错：预置占位文件，再跑一次
  DUP_PROJ="$(new_proj run-dup)"
  mkdir -p "$DUP_PROJ/test-assets/security"
  printf 'PLACEHOLDER\n' > "$DUP_PROJ/test-assets/security/threat-model.json"
  DUP_SHA_BEFORE="$(sha256sum "$DUP_PROJ/test-assets/security/threat-model.json" | cut -d' ' -f1)"
  DUP_RC=0; run_impl dup "$DUP_PROJ" --context "$CTX" --cases "$FCASES" --scan "$BANDIT" || DUP_RC=$?
  DUP_SHA_AFTER="$(sha256sum "$DUP_PROJ/test-assets/security/threat-model.json" 2>/dev/null | cut -d' ' -f1)"
  [ "$DUP_RC" = "1" ] || A28_PROBLEMS="$A28_PROBLEMS [产物已存在时退出码是 $DUP_RC，要求 1（必须报错退出，不得覆盖）]"
  [ "$DUP_SHA_BEFORE" = "$DUP_SHA_AFTER" ] || A28_PROBLEMS="$A28_PROBLEMS [产物已存在时被覆盖了（占位文件内容被改写）]"
fi
if [ -z "$A28_PROBLEMS" ]; then ok "$A28" "$A28"; else bad "$A28" "$A28"; printf '  · %s\n' "$A28_PROBLEMS" >> "$RES_DIR/$A28.res"; fi

# ---------------------------------------------------------------- AC-029 交付侧记账

step "AC-029 交付侧记账必须与实际一致"
A29="AC-029"
A29_PROBLEMS=""
SP_META="$FEATURE_META/security-plan"
for f in status.md traceability.md verification-report.md manifest.json; do
  [ -s "$SP_META/$f" ] || A29_PROBLEMS="$A29_PROBLEMS [缺 feature-meta/security-plan/$f 或为空]"
done
if [ -s "$SP_META/manifest.json" ]; then
  MY_REQ="$(node -e 'try{console.log(String(require(process.argv[1]).req||""))}catch(e){console.log("__ERR__")}' "$SP_META/manifest.json" 2>/dev/null)"
  [ "$MY_REQ" = "REQ-008" ] || A29_PROBLEMS="$A29_PROBLEMS [feature-meta/security-plan/manifest.json 的 req=$MY_REQ，要求 REQ-008]"
fi
# 既有追溯件必须齐全且未被改写（根四件套 + test-report / regression-plan / defect-verify 子目录）
ROOT_MANIFEST="$FEATURE_META/manifest.json"
if [ -s "$ROOT_MANIFEST" ]; then
  ROOT_REQ="$(node -e 'try{console.log(String(require(process.argv[1]).req||""))}catch(e){console.log("__ERR__")}' "$ROOT_MANIFEST" 2>/dev/null)"
  [ "$ROOT_REQ" = "REQ-006" ] || A29_PROBLEMS="$A29_PROBLEMS [feature-meta/manifest.json 的 req=$ROOT_REQ（既有追溯件不得被改写；REQ-008 的追溯件在 feature-meta/security-plan/）]"
else
  A29_PROBLEMS="$A29_PROBLEMS [缺 feature-meta/manifest.json —— 既有追溯件不得被删除]"
fi
for sub in test-report regression-plan defect-verify; do
  for f in status.md traceability.md verification-report.md manifest.json; do
    [ -s "$FEATURE_META/$sub/$f" ] || A29_PROBLEMS="$A29_PROBLEMS [缺 feature-meta/$sub/$f —— 既有追溯件不得被改写或删除]"
  done
done
# 追溯矩阵行数与编号集合（动态取判据条数）
EXPECT_IDS="$(grep -oE '^### (AC-[0-9]+)' "$ACCEPTANCE" 2>/dev/null | grep -oE 'AC-[0-9]+' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
EXPECT_ROWS="$(printf '%s' "$EXPECT_IDS" | tr ' ' '\n' | grep -cE '^AC-[0-9]+$')"
if [ -s "$SP_META/traceability.md" ]; then
  MATRIX_IDS="$(grep -E '^\|[[:space:]]*AC-[0-9]+' "$SP_META/traceability.md" 2>/dev/null | grep -oE 'AC-[0-9]+' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  MATRIX_ROWS="$(grep -cE '^\|[[:space:]]*AC-[0-9]+' "$SP_META/traceability.md" 2>/dev/null || true)"
  case "$MATRIX_ROWS" in ''|*[!0-9]*) MATRIX_ROWS=0 ;; esac
  if [ "$MATRIX_ROWS" -eq 0 ]; then
    MATRIX_IDS="$(grep -oE 'AC-[0-9]+' "$SP_META/traceability.md" 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    MATRIX_ROWS="$(grep -cE 'AC-[0-9]+' "$SP_META/traceability.md" 2>/dev/null || true)"
    case "$MATRIX_ROWS" in ''|*[!0-9]*) MATRIX_ROWS=0 ;; esac
  fi
  [ "$MATRIX_ROWS" -eq "$EXPECT_ROWS" ] || A29_PROBLEMS="$A29_PROBLEMS [追溯矩阵行数=$MATRIX_ROWS，要求 $EXPECT_ROWS 行（== acceptance.md 的实际判据条数）]"
  [ "$MATRIX_IDS" = "$EXPECT_IDS" ] || A29_PROBLEMS="$A29_PROBLEMS [追溯矩阵的 AC 编号集合=[$MATRIX_IDS]，要求恰好 [$EXPECT_IDS]]"
fi
# 三份 md 的判据条数与决策号范围必须**取值唯一**
EXPECT_DEC_SET="$DECISION_IDS"
for f in status.md traceability.md verification-report.md; do
  [ -s "$SP_META/$f" ] || continue
  NUMSET="$(grep -oE '[0-9]+[[:space:]]*条判据|判据条数[^0-9]{0,8}[0-9]+' "$SP_META/$f" 2>/dev/null \
    | grep -oE '[0-9]+' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  if [ -z "$NUMSET" ]; then
    A29_PROBLEMS="$A29_PROBLEMS [$f 里没有记载判据条数]"
  elif [ "$NUMSET" != "$AC_COUNT" ]; then
    A29_PROBLEMS="$A29_PROBLEMS [$f 的判据条数取值集合=[$NUMSET]，要求恰好 {${AC_COUNT}}（出现第二个不同取值即判红）]"
  fi
  MP="$(node -e '
const fs=require("fs");
const text=fs.readFileSync(process.argv[1],"utf8");
const expKey=(process.argv[2]||"").split(" ").filter(Boolean).join(" ");
const all=new Set();
const rangeSets=[];
for(const m of text.matchAll(/D(\d+)\s*[~～\-–]\s*D?(\d+)/g)){
  const a=Number(m[1]),b=Number(m[2]);
  const s=[];
  for(let i=Math.min(a,b);i<=Math.max(a,b);i++){ s.push("D"+i); all.add("D"+i); }
  rangeSets.push(s.join(" "));
}
for(const m of text.matchAll(/\bD(\d+)\b/g)) all.add("D"+m[1]);
const allKey=[...all].sort((x,y)=>Number(x.slice(1))-Number(y.slice(1))).join(" ");
const problems=[];
if(allKey!==expKey) problems.push("决策号取值集合=["+allKey+"]，要求恰好 {"+expKey+"}");
for(const r of [...new Set(rangeSets)]){
  if(r!==expKey) problems.push("出现了不等于实际集合的决策号范围 ["+r+"]，要求恰好 {"+expKey+"}（范围字面量自身必须等于 decisions.md 的实际集合，不能靠文件别处提到的 D 编号掩盖）");
}
console.log(problems.join(" ;; "));
' "$SP_META/$f" "$EXPECT_DEC_SET" 2>/dev/null)"
  [ -z "$MP" ] || A29_PROBLEMS="$A29_PROBLEMS [$f: $MP]"
done
printf '  · 实现侧追溯范围: 取 decisions.md 的实际决策号集合=[%s]（%s 条；取值唯一；重复引用同一取值不算多处记载）\n' "$EXPECT_DEC_SET" "$DECISION_COUNT"
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

# ---------------------------------------------------------------- 归一化比较器（变异自证用）

cat > "$WORK/normcmp.mjs" <<'FIXNC'
// normcmp.mjs —— 比较两个产物目录（忽略 meta.generated_at）
// 用法: node normcmp.mjs <dirA> <dirB>  → 输出 SAME / DIFF
import fs from 'node:fs';
import path from 'node:path';

const strip = (d) => {
  if (d && typeof d === 'object') {
    if (Array.isArray(d)) return d.map(strip);
    const o = {};
    for (const k of Object.keys(d).sort()) {
      if (k === 'generated_at') continue;
      o[k] = strip(d[k]);
    }
    return o;
  }
  return d;
};
const list = (root) => {
  const r = [];
  const walk = (d) => {
    let es = [];
    try { es = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of es) {
      const f = path.join(d, e.name);
      if (e.isDirectory()) walk(f);
      else if (e.isFile()) r.push(path.relative(root, f).split(path.sep).join('/'));
    }
  };
  walk(root);
  r.sort();
  return r;
};
const [a, b] = process.argv.slice(2);
const la = list(a);
const lb = list(b);
if (JSON.stringify(la) !== JSON.stringify(lb)) { process.stdout.write('DIFF\n'); process.exit(0); }
for (const rel of la) {
  let x; let y;
  try { x = JSON.parse(fs.readFileSync(path.join(a, rel), 'utf8')); } catch { process.stdout.write('DIFF\n'); process.exit(0); }
  try { y = JSON.parse(fs.readFileSync(path.join(b, rel), 'utf8')); } catch { process.stdout.write('DIFF\n'); process.exit(0); }
  if (JSON.stringify(strip(x)) !== JSON.stringify(strip(y))) { process.stdout.write('DIFF\n'); process.exit(0); }
}
process.stdout.write('SAME\n');
FIXNC

# ---------------------------------------------------------------- 变异体套件
#
# 口径（**只**认「新增失败键」）：
#   基线失败键 = 基线运行里**失败**的判据编号（**只取 FAIL 行** —— PASS/UNDEC 的 .res 里也有
#   AC 编号，混进来会让基线键集合变成全集，此后任何变异的「新增失败键」都恒等于全集 ⇒
#   整套检测沦为橡皮章而门仍然 exit 0。REQ-010 的最致命一处缺陷，本门不得重蹈）。
#   新增失败键 = 变异运行的失败键 减去 基线失败键（整行精确排除）。
#   检出 = 目标判据出现在**新增**失败键里。
#   ⚠️ 不用「对称差」：对称差把「基线红、变异后绿」也算成变化，那是噪声不是检出。

if [ "${REQ008_NO_MUT:-0}" = "1" ]; then
  printf '\n变异体套件: 已跳过（REQ008_NO_MUT=1）—— 不可判定，不计入通过；检出率结论以完整模式为准\n'
  MUT_NOTE="跳过"
else
  step "变异体套件（13 个正控 + 1 个负控 M0；检测口径 = 新增失败键）"

  # ① 基线失败键（**只取 FAIL 行**）
  BASE_FAILS="$(cat "$RES_DIR"/*.res 2>/dev/null | grep -E '^FAIL[[:space:]]' | grep -oE 'AC-[0-9]+' | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//')"
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
    mout="$(REQ008_NO_MUT=1 QA008_SCRIPT_SHA= bash "$SELF" "$mpkg" 2>&1)"
    mf="$(printf '%s\n' "$mout" | sed 's/\x1b\[[0-9;]*m//g' | grep -E '^FAIL[[:space:]]' | grep -oE 'AC-[0-9]+' | LC_ALL=C sort -u | grep -v '^$' || true)"
    comm -13 "$WORK/base_fails.txt" <(printf '%s\n' "$mf") | tr '\n' ' ' | sed 's/ $//'
  }

  # ③ 注入包装层（shim）：原实现 move 到 make-security-plan.real.mjs，包装层跑完原实现后篡改产物
  #    $1 = 变异体包目录, $2 = 篡改代码
  #    ⚠️ 包装层必须**保留原文件的权限位**（`cat >` 新建的文件会拿到 umask 默认值 644）——
  #    否则包装层自身「不可执行」，AC-001 的逐脚本判定会把每个变异体都判红，
  #    负控 M0 也会被误报成「已检出」⇒ 门自己把自己的工装当成了变异缺陷。
  inject_shim() {
    local mpkg="$1" code="$2"
    local entry="$mpkg/skills/security-plan/scripts/make-security-plan.mjs"
    local mode; mode="$(stat -c '%a' "$entry" 2>/dev/null || echo 755)"
    mv "$entry" "$mpkg/skills/security-plan/scripts/make-security-plan.real.mjs" 2>/dev/null || return 1
    cat > "$entry" <<SHIMEOF
#!/usr/bin/env node
// 变异体包装层（仅存在于变异副本里）：先跑原实现，再对产物做一处语义篡改。
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const real = path.join(here, 'make-security-plan.real.mjs');
const args = process.argv.slice(2);
const run = spawnSync(process.execPath, [real, ...args], { stdio: 'inherit' });
const code = run.status === null ? 1 : run.status;
if (code === 0) {
  const argOf = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : null; };
  const outDir = argOf('--out-dir') || '';
  const sec = path.join(outDir, 'test-assets', 'security');
  const readJson = (f) => JSON.parse(fs.readFileSync(f, 'utf8'));
  const writeJson = (f, v) => fs.writeFileSync(f, JSON.stringify(v, null, 2) + '\n');
  const suiteDirs = () => {
    const d = path.join(sec, 'suites');
    try { return fs.readdirSync(d).filter((n) => fs.statSync(path.join(d, n)).isDirectory()).sort(); }
    catch { return []; }
  };
  ${code}
}
process.exit(code);
SHIMEOF
    chmod "$mode" "$entry" 2>/dev/null || true
    return 0
  }

  MUT_NAMES=(
    "OWASP 少交代一类（删掉 A07）"
    "not_applicable 的理由被清空"
    "四类实战补充里 not_applicable 的理由被清空"
    "扫描发现的 threat_refs 被清空"
    "矩阵里某个 expected 条目的 decision 被改成非法值"
    "某条威胁的 rationale 被清空"
    "某条威胁的 asset_refs 被清空"
    "某个套件的 suite.json 被加了 threat_model 字段"
    "某个套件的 suite.json 的 suite 字段被改错"
    "某个套件的 cases.json 被删掉 defects 顶层字段"
    "某条用例的 dimension 被改成 functional"
    "某条用例的 status 被改成 modified"
    "某条用例的 tags 被去掉威胁 id"
  )
  MUT_CODE=(
    "{ const f = path.join(sec, 'threat-model.json'); if (fs.existsSync(f)) { const t = readJson(f); if (t.owasp_coverage) delete t.owasp_coverage['A07']; writeJson(f, t); } }"
    "{ const f = path.join(sec, 'threat-model.json'); if (fs.existsSync(f)) { const t = readJson(f); const c = t.owasp_coverage || {}; const k = Object.keys(c).find((x) => c[x] && c[x].status === 'not_applicable'); if (k) c[k].reason = ''; writeJson(f, t); } }"
    "{ const f = path.join(sec, 'threat-model.json'); if (fs.existsSync(f)) { const t = readJson(f); const s = t.supplements || {}; const k = Object.keys(s).find((x) => s[x] && s[x].status === 'not_applicable'); if (k) s[k].reason = ''; writeJson(f, t); } }"
    "{ const f = path.join(sec, 'threat-model.json'); if (fs.existsSync(f)) { const t = readJson(f); if (t.scan_findings && t.scan_findings[0]) t.scan_findings[0].threat_refs = []; writeJson(f, t); } }"
    "{ const f = path.join(sec, 'matrix.json'); if (fs.existsSync(f)) { const m = readJson(f); const e = (m.entries || []).find((x) => x.basis === 'expected'); if (e) e.decision = 'blocked'; writeJson(f, m); } }"
    "{ const f = path.join(sec, 'threat-model.json'); if (fs.existsSync(f)) { const t = readJson(f); if (t.threats && t.threats[0]) t.threats[0].rationale = ''; writeJson(f, t); } }"
    "{ const f = path.join(sec, 'threat-model.json'); if (fs.existsSync(f)) { const t = readJson(f); if (t.threats && t.threats[0]) t.threats[0].asset_refs = []; writeJson(f, t); } }"
    "{ const dirs = suiteDirs(); if (dirs[0]) { const f = path.join(sec, 'suites', dirs[0], 'suite.json'); if (fs.existsSync(f)) { const s = readJson(f); s.threat_model = 'threat-model.json'; writeJson(f, s); } } }"
    "{ const dirs = suiteDirs(); if (dirs[0]) { const f = path.join(sec, 'suites', dirs[0], 'suite.json'); if (fs.existsSync(f)) { const s = readJson(f); s.suite = 'SEC-999-wrong'; writeJson(f, s); } } }"
    "{ const dirs = suiteDirs(); if (dirs[0]) { const f = path.join(sec, 'suites', dirs[0], 'cases.json'); if (fs.existsSync(f)) { const d = readJson(f); delete d.defects; writeJson(f, d); } } }"
    "{ const dirs = suiteDirs(); if (dirs[0]) { const f = path.join(sec, 'suites', dirs[0], 'cases.json'); if (fs.existsSync(f)) { const d = readJson(f); if (d.cases && d.cases[0]) d.cases[0].dimension = 'functional'; writeJson(f, d); } } }"
    "{ const dirs = suiteDirs(); if (dirs[0]) { const f = path.join(sec, 'suites', dirs[0], 'cases.json'); if (fs.existsSync(f)) { const d = readJson(f); if (d.cases && d.cases[0]) { d.cases[0].status = 'modified'; d.cases[0].revision = { previous_status: 'active', change: 'mutant', changed_at: '2026-11-14' }; } writeJson(f, d); } } }"
    "{ const dirs = suiteDirs(); if (dirs[0]) { const f = path.join(sec, 'suites', dirs[0], 'cases.json'); if (fs.existsSync(f)) { const d = readJson(f); if (d.cases && d.cases[0]) d.cases[0].tags = (d.cases[0].tags || []).filter((x) => !/^TH-\\d+\$/.test(x)); writeJson(f, d); } } }"
  )
  MUT_TARGETS=(
    "AC-011"
    "AC-012"
    "AC-013"
    "AC-014"
    "AC-015"
    "AC-026"
    "AC-025"
    "AC-023"
    "AC-022"
    "AC-020"
    "AC-020"
    "AC-020"
    "AC-021"
  )
  MUT_REQUIRED=6

  for i in "${!MUT_NAMES[@]}"; do
    NAME="${MUT_NAMES[$i]}"
    TARGET="${MUT_TARGETS[$i]}"
    CODE="${MUT_CODE[$i]}"
    MUTPKG="$WORK/mut-$i"
    mkdir -p "$MUTPKG"
    cp -r "$PKG"/. "$MUTPKG"/ 2>/dev/null
    STATUS="有效"
    # 自证 ①：入口脚本在副本里**逐字唯一命中 1 次**
    #   ⚠️ 两种「无效」要分开说：入口脚本**不存在** = **实现未交付**（不是门侧问题）；
    #      入口存在但命中数 ≠ 1 = **门侧锚点不可达**（不唯一）。
    if [ ! -f "$MUTPKG/$ENTRY_REL" ]; then
      STATUS="**实现缺失**：$ENTRY_REL 不存在 —— 变异体无法注入；这是实现未交付，不是门侧问题"
      MUT_MISSING_IMPL=1
    else
      HITS="$(node "$WORK/pkgfiles.mjs" "$MUTPKG" "$ENTRY_REL" 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).length)}catch(e){console.log(0)}})')"
      if [ "${HITS:-0}" -ne 1 ]; then
        STATUS="门侧锚点不可达：入口锚点命中 $HITS 次，要求恰好 1 次"
      fi
    fi
    # 注入：把入口脚本换成包装层（原实现 move 到 make-security-plan.real.mjs）
    if [ "$STATUS" = "有效" ]; then
      BEFORE_SHA="$(sha256sum "$MUTPKG/$ENTRY_REL" 2>/dev/null | cut -d' ' -f1)"
      inject_shim "$MUTPKG" "$CODE" || STATUS="包装层注入失败"
      AFTER_SHA="$(sha256sum "$MUTPKG/$ENTRY_REL" 2>/dev/null | cut -d' ' -f1)"
      if [ "$STATUS" = "有效" ]; then
        if [ -z "$BEFORE_SHA" ] || [ "$BEFORE_SHA" = "$AFTER_SHA" ]; then
          STATUS="注入前后 sha256 没变（注入未生效）"
        fi
      fi
      # 自证 ②：结构合法（node --check 通过 + 脚本能正常跑完）
      if [ "$STATUS" = "有效" ]; then
        node --check "$MUTPKG/$ENTRY_REL" >/dev/null 2>&1 || STATUS="变异后 node --check 不通过"
      fi
      if [ "$STATUS" = "有效" ]; then
        MUTPROJ="$WORK/mutproj-$i"
        mkdir -p "$MUTPROJ"
        cp -r "$FX/proj"/. "$MUTPROJ"/ 2>/dev/null
        MUTOUT="$MUTPROJ"
        node "$MUTPKG/$ENTRY_REL" --context "$CTX" --cases "$FCASES" --scan "$BANDIT" --out-dir "$MUTOUT" >/dev/null 2>&1
        MRC=$?
        if [ "$MRC" -ne 0 ] || [ ! -s "$MUTOUT/test-assets/security/threat-model.json" ]; then
          STATUS="变异后脚本没正常跑完：rc=$MRC —— 崩溃造成的判红是假检出"
        fi
      fi
      # 自证 ③：篡改**真的生效**（产物与基线不同；归一化比较，忽略 generated_at）
      if [ "$STATUS" = "有效" ]; then
        CMP="$(node "$WORK/normcmp.mjs" "$PROJ_MAIN/test-assets/security" "$MUTOUT/test-assets/security" 2>/dev/null)"
        if [ "$CMP" = "SAME" ]; then
          STATUS="篡改未生效（变异产物与基线相同）—— 该变异对这份实现无效"
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
      printf '变异体 %s: 逃逸（目标 $TARGET 未出现在新增失败键集合里；新增=[%s]）\n' "$NAME" "$NEW_FAILS"
    fi
  done

  # ④ 负控 M0：打不到任何判据的**无害**篡改 —— 期望「未检出」。
  #    它检验的是探测器本身：若 M0 也被报成「已检出」，说明探测器恒真 ⇒ 本门失效。
  #    ⚠️ 无害字段放在 threat-model.json 的 `meta` 里（F2.1：meta 的字段集**开放**）⇒ 不触发任何判据。
  CTRL_NAME="负控 M0：往 threat-model.json 的 meta 里加一个无害字段（gate_note）"
  CTRLPKG="$WORK/mut-control"
  mkdir -p "$CTRLPKG"
  cp -r "$PKG"/. "$CTRLPKG"/ 2>/dev/null
  CTRL_STATUS="有效"
  if [ ! -f "$CTRLPKG/$ENTRY_REL" ]; then
    CTRL_STATUS="**实现缺失**：$ENTRY_REL 不存在 —— 变异体无法注入；这是实现未交付，不是门侧问题"
    MUT_MISSING_IMPL=1
  elif ! inject_shim "$CTRLPKG" "{ const f = path.join(sec, 'threat-model.json'); if (fs.existsSync(f)) { const t = readJson(f); if (t.meta) t.meta.gate_note = 'mutant-control'; writeJson(f, t); } }"; then
    CTRL_STATUS="包装层注入失败"
  fi
  if [ "$CTRL_STATUS" = "有效" ]; then
    node --check "$CTRLPKG/$ENTRY_REL" >/dev/null 2>&1 \
      || CTRL_STATUS="变异后 node --check 不通过"
  fi
  if [ "$CTRL_STATUS" = "有效" ]; then
    CTRLPROJ="$WORK/ctrlproj"
    mkdir -p "$CTRLPROJ"
    cp -r "$FX/proj"/. "$CTRLPROJ"/ 2>/dev/null
    node "$CTRLPKG/$ENTRY_REL" --context "$CTX" --cases "$FCASES" --scan "$BANDIT" --out-dir "$CTRLPROJ" >/dev/null 2>&1
    CRC=$?
    if [ "$CRC" -ne 0 ] || [ ! -s "$CTRLPROJ/test-assets/security/threat-model.json" ]; then
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
    MUT_WHY="**实现缺失**：$ENTRY_REL 不存在 —— 变异体无法注入；这是实现未交付，不是门侧问题"
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
printf '被验实现指纹（skills/security-plan/）: %s\n' "$(node "$WORK/fingerprint.mjs" "$TR" 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1)"
printf '实现侧追溯范围（动态取 decisions.md）: %s 条 [%s]\n' "$DECISION_COUNT" "$DECISION_IDS"
if [ "$MUT_NOTE" = "跳过" ]; then
  printf '变异体套件: 已跳过（REQ008_NO_MUT=1）—— 不可判定，检出率结论以完整模式为准\n'
elif [ -n "$MUT_ESCAPED" ]; then
  printf '变异体套件: %s —— 有变异体逃逸（真缺陷），整体判红\n' "$MUT_NOTE"
elif [ -n "$MUT_CONTROL_FAILED" ]; then
  printf '变异体套件: %s\n' "$MUT_NOTE"
  printf '负控失败：探测器疑似恒真 ⇒ 本门失效（门侧缺陷）—— %s\n' "$MUT_CONTROL_FAILED"
  printf '  （负控本该「未检出」；它被报成「已检出」说明检出判定恒真，本门结论不可采信）\n'
elif [ "$MUT_UNDEC" -eq 1 ]; then
  printf '不可判定: 1 项（变异体套件）—— %s\n' "$MUT_NOTE"
  if [ "$MUT_MISSING_IMPL" -eq 1 ]; then
    printf '  （这是**实现未交付**，不是门侧问题：变异体需要 `%s` 才能注入。退出码为 1，判据结论仍以上面的 PASS/FAIL 为准）\n' "$ENTRY_REL"
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
   && { [ "${REQ008_NO_MUT:-0}" = "1" ] || { [ "$MUT_UNDEC" -eq 0 ] \
        && [ "$MUT_TOTAL" -ge "$MUT_REQUIRED" ] && [ "$MUT_DETECTED" -eq "$MUT_TOTAL" ] \
        && [ "$MUT_CONTROL_OK" -eq 1 ]; }; }; then
  exit 0
fi
exit 1
