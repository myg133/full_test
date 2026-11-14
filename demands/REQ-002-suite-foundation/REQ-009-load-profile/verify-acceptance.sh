#!/usr/bin/env bash
# REQ-009 验收脚本 —— `load-profile` skill（压测能力域：负载模型 + runner 适配）
#
# 判据集：AC-001~AC-029（条数从 acceptance.md 的 `### AC-` 实际条数动态取，不写死）
# 决策号：从 decisions.md 的 `^## D[0-9]+` 实际集合动态取，不写死。
#
# 用法: verify-acceptance.sh <package-dir>
#   <package-dir> 指向**被验包根目录**（含 skills/ 与 bin/，以及 feature-meta/、README.md）
#
# 退出码: 0 = 全部通过; 1 = 有 AC 未通过 / 不可判定 / 变异体有逃逸 / 负控失败 / sha 不符; 2 = 用法错误
#
# 环境变量:
#   REQ009_NO_MUT=1   跳过变异体套件（快跑 / 嵌套运行用）
#   QA009_SCRIPT_SHA  期望的**本脚本自身** sha256；不匹配即判红并中止
#   QA009_KEEP_WORK=1 保留工作目录（调试）
#   QA009_WORK_ROOT   工作目录的父目录（默认 ${TMPDIR:-/tmp}）
#
# 设计要点（门是被验对象，不是脚手架 —— D65）:
#   - 只读被验包；一切变异都在**副本**上做，绝不在原地改被验对象。
#   - 夹具（压测上下文 / 功能用例集 / 非法变体 / 最小项目根）一律造在临时目录里。
#   - 产物侧判据用**独立复算器**（内嵌 judge.mjs）：自己重算负载模型 / 套件 / 对账的判定口径，
#     **绝不 import 被验包**；自带独立的解析 / 集合运算 / 枚举实现。
#   - ⚠️ **上游加载层检查单独一个进程**（内嵌 loadcheck.mjs）：它 import 被验包的
#     suite-loader.mjs 调 loadSuite —— 因为「产品能不能被上游消费」的**唯一**真实答案
#     只能问上游本人（D145）。这与「复算器不 import 被验包」不冲突：复算保持纯净，兼容性问上游。
#   - 上游**目录校验器**同样是实跑（拿真实输出），按**相对路径** grep 该套件的判定行；
#     ⚠️ **不判**上游对整个项目根的 rc=0（那些前置条件不在本 REQ 的写入范围里）。
#   - 判据正文与本脚本的理解有出入时，以 acceptance.md 的判据正文为准；分歧写进本脚本注释。
#   - 变异体套件的注入方式：**入口脚本包装（shim）** —— 把副本里的
#     `skills/load-profile/scripts/make-load-profile.mjs` 换成一层包装，包装调用原实现
#     （原文件 move 到 make-load-profile.real.mjs）后再对**产物**做一处语义篡改。
#   - 变异检出走**新增失败键**（变异运行的失败键 减去 基线失败键，整行精确排除）；
#     **不用**对称差：对称差把「基线红、变异后绿」也算成变化，那是噪声不是检出。
#   - ⚠️ **基线失败键只取 `^FAIL` 行** —— PASS / UNDEC 行里也有 AC 编号，混进来会让基线键
#     集合变成**全集**，此后任何变异的「新增失败键」都恒等于全集 ⇒ 整套检测沦为橡皮章。
#   - 崩溃造成的判红是假检出，不计入检出率（结构合法性单独自证）。
#   - 变异体套件里有一个**负控 M0**（打不到任何判据的无害篡改）：它必须**未检出**。
#     若 M0 也被报成「已检出」⇒ 探测器恒真 ⇒ 本门失效（门侧缺陷，判红，退出码非 0）。
#   - 有效变异体不足 6 个 ⇒ **不可判定**（门侧注入问题），退出码非 0，但不算被验实现的失败。
#   - **门跑在「没有实现」的真包上必须优雅降级**（D65 第 2 项）：不崩溃，如实报 FAIL / 不可判定。

set -u

# ---------------------------------------------------------------- 用法

PKG_RAW="${1:-}"
if [ -z "$PKG_RAW" ] || [ "$#" -ne 1 ]; then
  printf '用法: %s <package-dir>\n' "$(basename "$0")" >&2
  exit 2
fi
PKG="$(cd "$PKG_RAW" 2>/dev/null && pwd)" || { echo "被验包目录不可读: $PKG_RAW" >&2; exit 2; }
if [ ! -d "$PKG" ]; then
  echo "被验包目录不可读: $PKG_RAW" >&2
  exit 2
fi

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/$(basename "${BASH_SOURCE[0]}")"
DEMAND_DIR="$SELF_DIR"
ACCEPTANCE="$DEMAND_DIR/acceptance.md"
DECISIONS="$DEMAND_DIR/decisions.md"

# ---------------------------------------------------------------- 判据条数（动态取）

AC_COUNT=0
if [ -f "$ACCEPTANCE" ]; then
  AC_COUNT="$(grep -cE '^### AC-[0-9]+' "$ACCEPTANCE" || true)"
fi

# ---------------------------------------------------------------- 决策号集合（动态取 —— D154）

DECISION_IDS=""
DECISION_COUNT=0
DECISION_MIN=""
DECISION_MAX=""
if [ -f "$DECISIONS" ]; then
  DECISION_RAW="$(grep -oE '^## D[0-9]+' "$DECISIONS" | sed 's/^## //' | sort -u || true)"
  DECISION_COUNT="$(printf '%s\n' $DECISION_RAW | grep -v '^$' | wc -l | tr -d ' ')"
  # ⚠️ 必须按**数值**排序（`sort -u` 是字典序，会把 D100 排在 D98 前面）
  DECISION_IDS="$(printf '%s\n' $DECISION_RAW | sort -t'D' -k2,2n | tr '\n' ' ' | sed 's/ $//')"
  DECISION_MIN="$(printf '%s\n' $DECISION_RAW | sort -t'D' -k2,2n | head -1)"
  DECISION_MAX="$(printf '%s\n' $DECISION_RAW | sort -t'D' -k2,2n | tail -1)"
fi

# ---------------------------------------------------------------- 门禁前置：脚本自身指纹

if [ -n "${QA009_SCRIPT_SHA:-}" ]; then
  SELF_SHA="$(sha256sum "$SELF" 2>/dev/null | cut -d' ' -f1)"
  if [ "$SELF_SHA" != "${QA009_SCRIPT_SHA}" ]; then
    printf 'FAIL GATE-SHA —— 验收脚本 sha256 不匹配（期望 %s，实际 %s）\n' "${QA009_SCRIPT_SHA}" "${SELF_SHA}"
    printf '\n结论: 0 PASS / 1 FAIL\n'
    printf '验收脚本 sha256: %s\n' "$SELF_SHA"
    exit 1
  fi
fi

# ---------------------------------------------------------------- 工作目录

WORK_PARENT="${QA009_WORK_ROOT:-${TMPDIR:-/tmp}}"
mkdir -p "$WORK_PARENT" 2>/dev/null || true
WORK="$(mktemp -d "$WORK_PARENT/qa-009-XXXXXX")" || { echo "无法创建工作目录" >&2; exit 2; }
cleanup() {
  if [ "${QA009_KEEP_WORK:-0}" = "1" ]; then
    printf '工作目录已保留: %s\n' "$WORK" >&2
    return
  fi
  # ⚠️ 本机 rm 是 shim（可恢复删除）：清理失败**不得**改变判定。
  mv "$WORK" "${WORK}.done.$$" 2>/dev/null || true
}
trap cleanup EXIT

RES_DIR="$WORK/res"
mkdir -p "$RES_DIR"

# ⚠️ 门自身的 stderr 全量留痕（可观测证据）：跑完之后检查有没有 bash 错误行
#    （`行 N:` / `line N:` 是 bash 自己的报错前缀）⇒ 有 ⇒ 门不干净 ⇒ 判定不可信 ⇒ 判红退出。
#    ⚠️ 这里**不**去 grep 门自己的源码（那是「判门长什么样」，可被绕过，也不是绝对事实）。
STDERR_LOG="$WORK/stderr.log"
exec 2>"$STDERR_LOG"

PKG_SKILLS="$PKG/skills"
TR="$PKG_SKILLS/load-profile"
TCD="$PKG_SKILLS/test-case-design"
TEX="$PKG_SKILLS/test-execute"
FEATURE_META="$PKG/feature-meta"
README="$PKG/README.md"
ENTRY_REL="skills/load-profile/scripts/make-load-profile.mjs"
ENTRY="$PKG/$ENTRY_REL"
LAYOUT_REL="skills/test-case-design/scripts/verify-layout.mjs"
LAYOUT="$PKG/$LAYOUT_REL"
LOADER_REL="skills/test-execute/scripts/lib/suite-loader.mjs"
LOADER="$PKG/$LOADER_REL"

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

ok()   { PASS=$((PASS+1)); printf '%s\n' "$1" > "$RES_DIR/$2.res"; }
bad()  { FAIL=$((FAIL+1)); printf '%s\n' "$1" > "$RES_DIR/$2.res"; }
undec(){ UNDEC=$((UNDEC+1)); printf '%s\n' "$1" > "$RES_DIR/$2.res"; }
step(){ printf '\n— %s\n' "$1"; }
# 列表归一化（压掉连续空白 + 去首尾空白）—— 比对集合时**必须**用，否则尾随空格会造成假红
norm_list() { printf '%s' "$1" | tr -s ' \t\n' ' ' | sed 's/^ *//; s/ *$//'; }

# ---------------------------------------------------------------- 夹具生成（内嵌 node）

cat > "$WORK/mkfixture.mjs" <<'FIXNODE'
// 夹具生成器：压测上下文 / 功能用例集 / 非法变体 / 最小项目根
import fs from 'node:fs';
import path from 'node:path';

const FX = process.argv[2];
const write = (rel, obj) => {
  const f = path.join(FX, rel);
  fs.mkdirSync(path.dirname(f), { recursive: true });
  fs.writeFileSync(f, typeof obj === 'string' ? obj : JSON.stringify(obj, null, 2) + '\n');
};

const context = {
  schema_version: 1,
  service: { name: 'order-api', description: '订单服务' },
  environments: [
    { name: 'local', base_url: 'http://127.0.0.1:8080' },
    { name: 'staging', base_url: 'https://staging.example.com' },
  ],
  workloads: [
    {
      id: 'WL-001', name: 'checkout', target: 'POST /api/v1/checkout', environment: 'local',
      profile: { type: 'ramp-up', steps: [{ duration_s: 60, concurrency: 10 }, { duration_s: 120, concurrency: 20 }] },
      thresholds: { p95_latency_ms: 800, error_rate: 0.01 },
      thresholds_source: '需求 REQ-005 性能指标',
      tool: { runner: 'loadtest', runtime: 'bun' },
      args: { rps: 100, keepalive: true, timeout_s: 10 },
      requirement_refs: ['R-1'],
    },
    {
      id: 'WL-002', name: 'order-query', target: 'GET /api/v1/orders', environment: 'local',
      profile: { type: 'constant', steps: [{ duration_s: 300, concurrency: 5 }] },
      tool: { runner: 'loadtest', runtime: 'bun' },
      requirement_refs: ['R-2'],
    },
    {
      id: 'WL-003', name: 'checkout-staging', target: 'POST /api/v1/checkout', environment: 'staging',
      profile: { type: 'spike', steps: [{ duration_s: 30, concurrency: 50 }] },
      thresholds: { p95_latency_ms: 1200 },
      thresholds_source: '需求 REQ-007 性能指标',
      tool: { runner: 'python', runtime: 'python' },
      requirement_refs: ['R-1'],
    },
    {
      id: 'WL-004', name: 'health-check', target: 'GET /api/v1/health', environment: 'local',
      profile: { type: 'soak', steps: [{ duration_s: 600, concurrency: 2 }] },
      thresholds: { p95_latency_ms: 200 },
      thresholds_source: '需求 REQ-008 性能指标',
      tool: { runner: 'loadtest', runtime: 'bun' },
      requirement_refs: ['R-2'],
    },
  ],
  open_questions: [],
};

const casesDoc = {
  schema_version: 2,
  meta: { suite: 'functional-baseline', requirement: 'REQ-004', generated_at: '2026-11-14T09:00:00+08:00' },
  requirements: [
    { id: 'R-1', title: '下单链路', source_ref: 'REQ-004#R-1' },
    { id: 'R-2', title: '订单查询', source_ref: 'REQ-004#R-2' },
  ],
  open_questions: [],
  coverage_matrix: [
    { requirement: 'R-1', cases: ['TC-001'] },
    { requirement: 'R-2', cases: ['TC-002', 'TC-003'] },
  ],
  defects: [],
  cases: [
    { id: 'TC-001', title: '下单成功返回订单号', dimension: 'functional', priority: 'P0', method: ['M1.1'],
      status: 'active', preconditions: [], data: {}, requirement_refs: ['R-1'], tags: ['functional'],
      steps: [{ action: 'POST /api/v1/checkout', expected: '返回 201 与 orderId' }] },
    { id: 'TC-002', title: '按订单号查询订单', dimension: 'functional', priority: 'P1', method: ['M1.1'],
      status: 'active', preconditions: [], data: {}, requirement_refs: ['R-2'], tags: ['functional'],
      steps: [{ action: 'GET /api/v1/orders/{id}', expected: '返回 200 与订单详情' }] },
    { id: 'TC-003', title: '查询用户资料', dimension: 'functional', priority: 'P2', method: ['M1.1'],
      status: 'active', preconditions: [], data: {}, requirement_refs: ['R-2'], tags: ['functional'],
      steps: [{ action: 'GET /api/v1/users/{id}/profile', expected: '返回 200 与用户资料' }] },
  ],
};

write('inputs/context.json', context);
write('inputs/cases.json', casesDoc);

// ---- 非法变体（V1~V8 + V1b + V8b） ----
const clone = (o) => JSON.parse(JSON.stringify(o));
const variants = {};
let v = clone(context); delete v.workloads; variants.V1 = v;
v = clone(context); v.load_scenario = 'scenarios/checkout.json'; variants.V2 = v;
v = clone(context); v.workloads[0].environment = 'prod'; variants.V3 = v;
v = clone(context); v.workloads[1].id = 'WL-001'; variants.V4 = v;
v = clone(context); v.workloads[0].profile.type = 'ramp'; variants.V5 = v;
v = clone(context); delete v.workloads[2].thresholds_source; variants.V6 = v;
v = clone(context); v.workloads[0].target = 'POST api/v1/checkout'; variants.V7 = v;
v = clone(context); v.workloads[1].id = 'WL-1'; variants.V8 = v;
v = clone(context); v.workloads = 'not-an-array'; variants.V1b = v;
v = clone(context); v.workloads[0].tool.runner = 'jmeter'; variants.V8b = v;
for (const [k, val] of Object.entries(variants)) write(`inputs/variants/${k}.json`, val);

// ---- 最小项目根 ----
write('proj/.gitignore', '.test-artifacts/\nnode_modules/\n');
write('proj/test-assets/environments/_schema.json', {
  type: 'object',
  properties: { name: { type: 'string' }, base_url: { type: 'string' } },
  required: ['name', 'base_url'],
});
write('proj/test-assets/environments/local.json', {
  name: 'local', base_url: 'http://127.0.0.1:8080', timeout_ms: 3000, retries: 0,
  credentials: { token_env: 'TEST_TOKEN' },
});
write('proj/test-assets/environments/staging.json', {
  name: 'staging', base_url: 'https://staging.example.com', timeout_ms: 5000, retries: 0,
  credentials: { token_env: 'TEST_TOKEN_STAGING' },
});
write('proj/test-assets/cycles/R1-REQ-009/cycle.json', {
  cycle_id: 'R1-REQ-009', requirement: 'REQ-009', status: 'planned', round: 'R1',
  round_type: 'new-requirement', scopes: ['functional', 'load'], stages: {},
  history: [{ at: '2026-11-14T09:00:00+08:00', from: 'planned', to: 'planned', by: 'ba' }],
  scopes_skipped: [],
});
write('proj/test-assets/cycles/index.json', {
  cycles: [{ id: 'R1-REQ-009', status: 'planned', round: 'R1' }],
});

process.stdout.write('FIXTURE-OK\n');
FIXNODE

# ---------------------------------------------------------------- 独立复算器（内嵌 judge.mjs）
# ⚠️ 零 import 被验包：自带解析 / 集合运算 / 枚举实现。

cat > "$WORK/judge.mjs" <<'JUDGENODE'
// 独立复算器：只读「产物 + 输入」，重算 AC-009~AC-017 / AC-020~AC-024 的判定口径。
// ⚠️ 绝不 import 被验包的任何模块（否则等于用被验实现验证被验实现）。
import fs from 'node:fs';
import path from 'node:path';

const [rootArg, ctxArg, casesArg] = process.argv.slice(2);
const root = path.resolve(rootArg);
const out = [];
const say = (status, ac, msg) => out.push(`${status} ${ac} ${msg}`);

const ALLOWED_SCENARIO = new Set(['schema_version','id','name','service','target','environment','profile','thresholds','thresholds_source','thresholds_status','tool','args','traceability','open_questions']);
const REQ_SCENARIO = ['schema_version','id','name','service','target','environment','profile','thresholds_status','tool','traceability','open_questions'];
const SUITE_ALLOWED = new Set(['suite','requirement','scope','environment','cases_file','executor','base_url_from','tags','report']);
const SUITE_REQUIRED = ['suite','requirement','scope','environment','cases_file','executor'];
const REPORT_KEYS = ['schema_version','service','suites','scenarios','open_questions'];
const FORBIDDEN_KEYS = new Set(['status','result','verdict','executed','passed','outcome','conclusion']);
const TOPICS = new Set(['thresholds','coverage','runner','other']);
const PROFILE_TYPES = new Set(['constant','ramp-up','ramp-down','spike','soak']);
const RUNNERS = new Set(['loadtest','python']);
const RUNTIMES = new Set(['bun','python','node']);
const THRESHOLD_KEYS = new Set(['p50_latency_ms','p95_latency_ms','p99_latency_ms','error_rate','throughput_rps','max_concurrency']);

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const deepEq = (a, b) => {
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false;
    return a.every((x, i) => deepEq(x, b[i]));
  }
  if (isObj(a) && isObj(b)) {
    const ka = Object.keys(a).sort(), kb = Object.keys(b).sort();
    if (ka.length !== kb.length) return false;
    if (ka.some((k, i) => k !== kb[i])) return false;
    return ka.every((k) => deepEq(a[k], b[k]));
  }
  return a === b;
};
const sameSet = (a, b) => {
  const sa = [...new Set(a)].sort(), sb = [...new Set(b)].sort();
  return sa.length === sb.length && sa.every((x, i) => x === sb[i]);
};
const nonEmpty = (v) => typeof v === 'string' && v.trim() !== '';
const readJson = (f) => JSON.parse(fs.readFileSync(f, 'utf8'));
const safeRead = (f) => { try { return readJson(f); } catch { return null; } };

// 归一化 action：取「方法 + 空格 + 路径」，删掉路径中所有 `{...}` 占位符段
const normalizeAction = (action) => {
  if (typeof action !== 'string') return null;
  const parts = action.trim().split(/\s+/);
  if (parts.length < 2) return null;
  const method = parts[0];
  const path = parts[1];
  const segs = path.split('/').filter((s) => !(s.startsWith('{') && s.endsWith('}')));
  return `${method} ${segs.join('/')}`;
};

const scanForbidden = (node, pathPrefix, hits) => {
  if (Array.isArray(node)) { node.forEach((v, i) => scanForbidden(v, `${pathPrefix}[${i}]`, hits)); return; }
  if (isObj(node)) {
    for (const [k, v] of Object.entries(node)) {
      if (FORBIDDEN_KEYS.has(k)) hits.push(`${pathPrefix}.${k}`);
      scanForbidden(v, `${pathPrefix}.${k}`, hits);
    }
  }
};

const ctx = safeRead(ctxArg);
const casesDoc = casesArg && fs.existsSync(casesArg) ? safeRead(casesArg) : null;
const loadDir = path.join(root, 'test-assets', 'load');
const scenDir = path.join(loadDir, 'scenarios');
const suitesDir = path.join(loadDir, 'suites');

if (!ctx) {
  say('FAIL', 'AC-009', '读不到上下文夹具（复算器无法工作）');
  process.stdout.write(out.join('\n') + '\n');
  process.exit(0);
}

const workloads = Array.isArray(ctx.workloads) ? ctx.workloads : [];
const wById = new Map();
for (const w of workloads) if (w && typeof w.id === 'string') wById.set(w.id, w);

const scenFiles = fs.existsSync(scenDir)
  ? fs.readdirSync(scenDir).filter((n) => n.endsWith('.json')).sort()
  : [];
const scenarios = [];
for (const n of scenFiles) {
  const f = path.join(scenDir, n);
  const doc = safeRead(f);
  scenarios.push({ file: n, full: f, doc: isObj(doc) ? doc : null });
}

const suiteDirs = fs.existsSync(suitesDir)
  ? fs.readdirSync(suitesDir).filter((n) => { try { return fs.statSync(path.join(suitesDir, n)).isDirectory(); } catch { return false; } }).sort()
  : [];
const suites = suiteDirs.map((d) => {
  const dir = path.join(suitesDir, d);
  return {
    dirName: d, dir,
    suiteDoc: safeRead(path.join(dir, 'suite.json')),
    refDoc: safeRead(path.join(dir, 'scenario.json')),
  };
});

// 引用件 → 本体
const refTargets = [];
for (const s of suites) {
  const refs = s.refDoc && Array.isArray(s.refDoc.scenarios) ? s.refDoc.scenarios : [];
  for (const r of refs) {
    if (!isObj(r) || typeof r.path !== 'string') { refTargets.push(null); continue; }
    const abs = path.resolve(s.dir, r.path);
    refTargets.push({ suite: s, ref: r, abs, body: safeRead(abs) });
  }
}

// 场景 → 所属套件（按引用件）
const suiteOfScenario = new Map();
for (const t of refTargets) {
  if (!t || !t.body) continue;
  const key = t.body.id;
  if (typeof key === 'string') suiteOfScenario.set(key, t.suite);
}

// ---------------------------------------------------------------- AC-009 字段集封闭
{
  const problems = [];
  if (scenarios.length === 0) problems.push('scenarios/ 下没有场景模型');
  for (const s of scenarios) {
    if (!s.doc) { problems.push(`${s.file} 不是合法 JSON 对象`); continue; }
    for (const k of Object.keys(s.doc)) if (!ALLOWED_SCENARIO.has(k)) problems.push(`${s.file} 多余顶层字段 "${k}"`);
    for (const k of REQ_SCENARIO) if (!(k in s.doc)) problems.push(`${s.file} 缺必填字段 "${k}"`);
    if (isObj(s.doc.profile)) {
      const pk = Object.keys(s.doc.profile).sort();
      if (pk.length !== 2 || pk[0] !== 'steps' || pk[1] !== 'type') problems.push(`${s.file} profile 字段集应为 {type, steps}，实际 {${pk.join(', ')}}`);
      if (Array.isArray(s.doc.profile.steps)) {
        for (const st of s.doc.profile.steps) {
          if (!isObj(st)) { problems.push(`${s.file} profile.steps 元素不是对象`); continue; }
          const sk = Object.keys(st).sort();
          if (sk.length !== 2 || sk[0] !== 'concurrency' || sk[1] !== 'duration_s') problems.push(`${s.file} profile.steps[] 字段集应为 {duration_s, concurrency}`);
        }
      } else problems.push(`${s.file} profile.steps 不是数组`);
    } else problems.push(`${s.file} profile 不是对象`);
    if (isObj(s.doc.tool)) {
      const tk = Object.keys(s.doc.tool).sort();
      if (tk.length !== 2 || tk[0] !== 'runner' || tk[1] !== 'runtime') problems.push(`${s.file} tool 字段集应为 {runner, runtime}`);
    } else problems.push(`${s.file} tool 不是对象`);
    if (isObj(s.doc.traceability)) {
      const tk = Object.keys(s.doc.traceability).sort();
      if (tk.length !== 3 || tk[0] !== 'case_refs' || tk[1] !== 'requirement_refs' || tk[2] !== 'workload_id') problems.push(`${s.file} traceability 字段集应为 {workload_id, requirement_refs, case_refs}`);
    } else problems.push(`${s.file} traceability 不是对象`);
  }
  const reportFile = path.join(loadDir, 'report.json');
  if (!fs.existsSync(reportFile)) problems.push('report.json 不存在');
  else {
    const rd = safeRead(reportFile);
    if (!rd) problems.push('report.json 不是合法 JSON');
    else {
      const rk = Object.keys(rd).sort();
      const want = [...REPORT_KEYS].sort();
      if (rk.length !== want.length || rk.some((k, i) => k !== want[i])) problems.push(`report.json 顶层字段集应为 {${want.join(', ')}}，实际 {${rk.join(', ')}}`);
    }
  }
  say(problems.length ? 'FAIL' : 'PASS', 'AC-009',
    problems.length ? problems.slice(0, 4).join('；') : `场景字段集封闭（${scenarios.length} 个场景，14 个顶层字段）+ report.json 字段集封闭`);
}

// ---------------------------------------------------------------- AC-010 逐字可追溯
{
  const problems = [];
  for (const s of scenarios) {
    if (!s.doc) continue;
    const w = wById.get(s.doc.id);
    if (!w) { problems.push(`${s.file} 的 id "${s.doc.id}" 不在上下文里`); continue; }
    if (s.doc.target !== w.target) problems.push(`${s.file} target 不等于输入`);
    if (s.doc.environment !== w.environment) problems.push(`${s.file} environment 不等于输入`);
    if (!deepEq(s.doc.tool, w.tool)) problems.push(`${s.file} tool 不等于输入`);
    if (!deepEq(s.doc.profile, w.profile)) problems.push(`${s.file} profile 不等于输入（含步序）`);
    // 阈值也必须逐字等于输入（AC-010 的「梯度**与阈值**」）
    if ('thresholds' in s.doc && !deepEq(s.doc.thresholds, w.thresholds)) problems.push(`${s.file} thresholds 不等于输入`);
    if ('thresholds_source' in s.doc && s.doc.thresholds_source !== w.thresholds_source) problems.push(`${s.file} thresholds_source 不等于输入`);
    if (s.doc.service !== (ctx.service && ctx.service.name)) problems.push(`${s.file} service 不等于输入 service.name`);
    const hasArgs = isObj(w.args);
    if (hasArgs) { if (!deepEq(s.doc.args, w.args)) problems.push(`${s.file} args 不等于输入`); }
    else if ('args' in s.doc) problems.push(`${s.file} 不该有 args 键（输入没有）`);
  }
  say(problems.length ? 'FAIL' : 'PASS', 'AC-010',
    problems.length ? problems.slice(0, 4).join('；') : '梯度 / 阈值 / tool / target 逐字等于输入');
}

// ---------------------------------------------------------------- AC-011 阈值二态
{
  const problems = [];
  for (const s of scenarios) {
    if (!s.doc) continue;
    const w = wById.get(s.doc.id);
    if (!w) continue;
    const hasSrc = isObj(w.thresholds) && nonEmpty(w.thresholds_source);
    const st = s.doc.thresholds_status;
    if (st !== 'provided' && st !== 'not_provided') { problems.push(`${s.file} thresholds_status 取值非法`); continue; }
    const hasTh = 'thresholds' in s.doc, hasTS = 'thresholds_source' in s.doc;
    if (hasSrc) {
      if (st !== 'provided') problems.push(`${s.file} 输入有来源但 thresholds_status=${st}`);
      if (!hasTh || !hasTS) problems.push(`${s.file} 输入有来源但产物缺 thresholds / thresholds_source`);
    } else {
      if (st !== 'not_provided') problems.push(`${s.file} 输入无来源但 thresholds_status=${st}`);
      if (hasTh || hasTS) problems.push(`${s.file} 输入无来源但产物有 thresholds / thresholds_source`);
    }
  }
  say(problems.length ? 'FAIL' : 'PASS', 'AC-011',
    problems.length ? problems.slice(0, 4).join('；') : 'thresholds_status 二态与键的有无一致');
}

// ---------------------------------------------------------------- AC-012 场景文件名
{
  const problems = [];
  for (const s of scenarios) {
    const base = s.file.replace(/\.json$/, '');
    if (!/^[a-z0-9][a-z0-9-]*$/.test(base)) problems.push(`文件名 "${s.file}" 不合命名约定`);
    if (s.doc && s.doc.name !== base) problems.push(`${s.file} 的 name("${s.doc.name}") != 文件名("${base}")`);
  }
  say(problems.length ? 'FAIL' : 'PASS', 'AC-012',
    problems.length ? problems.slice(0, 4).join('；') : '场景文件名合约定且与体内 name 一致');
}

// ---------------------------------------------------------------- AC-013 一一对应
{
  const ids = scenarios.map((s) => (s.doc ? s.doc.id : null));
  const problems = [];
  if (ids.length !== workloads.length) problems.push(`场景数 ${ids.length} != 容量目标数 ${workloads.length}`);
  if (!sameSet(ids, workloads.map((w) => w.id))) problems.push('场景 id 集合 != 容量目标 id 集合');
  if (new Set(ids).size !== ids.length) problems.push('场景 id 有重复');
  say(problems.length ? 'FAIL' : 'PASS', 'AC-013',
    problems.length ? problems.join('；') : `场景与容量目标一一对应（${ids.length} 个）`);
}

// ---------------------------------------------------------------- AC-014 不得凭空造阈值
{
  const problems = [];
  for (const s of scenarios) {
    if (!s.doc) continue;
    const w = wById.get(s.doc.id);
    if (!w) continue;
    if (s.doc.thresholds_status === 'provided') {
      if (!isObj(w.thresholds)) { problems.push(`${s.file} 声称有来源但输入没有 thresholds`); continue; }
      if (!deepEq(s.doc.thresholds, w.thresholds)) problems.push(`${s.file} thresholds 与输入不一致（加了键或改了值）`);
    } else if ('thresholds' in s.doc) {
      problems.push(`${s.file} 声称无来源却有 thresholds`);
    }
  }
  say(problems.length ? 'FAIL' : 'PASS', 'AC-014',
    problems.length ? problems.slice(0, 4).join('；') : '阈值键集与值逐字等于输入，无凭空阈值');
}

// ---------------------------------------------------------------- AC-015 套件落位与分组
{
  const problems = [];
  if (suites.length === 0) problems.push('没有套件目录');
  const envOrder = [];
  for (const e of (Array.isArray(ctx.environments) ? ctx.environments : [])) {
    if (e && typeof e.name === 'string' && !envOrder.includes(e.name)) envOrder.push(e.name);
  }
  const usedEnvs = envOrder.filter((e) => workloads.some((w) => w.environment === e));
  if (suites.length !== usedEnvs.length) problems.push(`套件数 ${suites.length} != 有容量目标的环境数 ${usedEnvs.length}`);
  const seenWorkload = new Map();
  suites.forEach((s, idx) => {
    const m = /^LOAD-(\d{3})-([a-z0-9][a-z0-9-]*)$/.exec(s.dirName);
    if (!m) { problems.push(`目录名 "${s.dirName}" 不合 ^LOAD-<三位编号>-<短名>$`); return; }
    const env = s.suiteDoc && s.suiteDoc.environment;
    if (!usedEnvs.includes(env)) problems.push(`${s.dirName} 的 environment "${env}" 不在有容量目标的环境里`);
    if (m[1] !== String(idx + 1).padStart(3, '0')) problems.push(`${s.dirName} 编号应为 ${String(idx + 1).padStart(3, '0')}`);
    if (s.suiteDoc && s.suiteDoc.suite !== s.dirName) problems.push(`${s.dirName} 的 suite 字段 "${s.suiteDoc.suite}" != 目录名`);
    // 套件内场景（按引用件）
    const refs = s.refDoc && Array.isArray(s.refDoc.scenarios) ? s.refDoc.scenarios : [];
    const bodies = refs.map((r) => (isObj(r) && typeof r.path === 'string' ? safeRead(path.resolve(s.dir, r.path)) : null)).filter((b) => isObj(b));
    for (const b of bodies) {
      if (b.environment !== env) problems.push(`${s.dirName} 内场景 ${b.id} 的 environment("${b.environment}") 与套件环境("${env}") 不同`);
      if (seenWorkload.has(b.id)) problems.push(`容量目标 ${b.id} 出现在多个套件里`);
      seenWorkload.set(b.id, s.dirName);
    }
    const expectedFirst = workloads.find((w) => w.environment === env);
    if (expectedFirst && bodies.length > 0) {
      const first = workloads.filter((w) => w.environment === env)[0];
      const firstBody = bodies.find((b) => b.id === first.id);
      if (firstBody && m[2] !== firstBody.name) problems.push(`${s.dirName} 的短名 "${m[2]}" != 第一个场景名 "${firstBody.name}"`);
    }
  });
  for (const w of workloads) if (!seenWorkload.has(w.id)) problems.push(`容量目标 ${w.id} 没有落到任何套件`);
  say(problems.length ? 'FAIL' : 'PASS', 'AC-015',
    problems.length ? problems.slice(0, 4).join('；') : `套件目录名合规且按环境分组（${suites.length} 个套件）`);
}

// ---------------------------------------------------------------- AC-016 suite.json
{
  const problems = [];
  for (const s of suites) {
    const d = s.suiteDoc;
    if (!d) { problems.push(`${s.dirName}/suite.json 不是合法 JSON`); continue; }
    for (const k of Object.keys(d)) if (!SUITE_ALLOWED.has(k)) problems.push(`${s.dirName}/suite.json 多余字段 "${k}"`);
    for (const k of SUITE_REQUIRED) if (!nonEmpty(d[k])) problems.push(`${s.dirName}/suite.json 缺必填 "${k}"`);
    if (d.scope !== 'load') problems.push(`${s.dirName}/suite.json scope != "load"`);
    if (d.executor !== 'load') problems.push(`${s.dirName}/suite.json executor != "load"`);
    if (d.cases_file !== 'scenario.json') problems.push(`${s.dirName}/suite.json cases_file != "scenario.json"`);
    if (nonEmpty(d.environment)) {
      const ef = path.join(root, 'test-assets', 'environments', `${d.environment}.json`);
      if (!fs.existsSync(ef)) problems.push(`${s.dirName} 的 environment "${d.environment}" 无同名环境文件`);
    }
  }
  say(problems.length ? 'FAIL' : 'PASS', 'AC-016',
    problems.length ? problems.slice(0, 4).join('；') : 'suite.json 字段集封闭 + scope/executor=load + cases_file=scenario.json');
}

// ---------------------------------------------------------------- AC-017 引用件与不漂移
{
  const problems = [];
  for (const s of suites) {
    const d = s.refDoc;
    if (!d) { problems.push(`${s.dirName}/scenario.json 不是合法 JSON`); continue; }
    const k = Object.keys(d).sort();
    const want = ['schema_version', 'scenarios', 'suite'].sort();
    if (k.length !== want.length || k.some((x, i) => x !== want[i])) problems.push(`${s.dirName}/scenario.json 顶层字段集应为 {schema_version, suite, scenarios}`);
    if (d.schema_version !== 1) problems.push(`${s.dirName}/scenario.json schema_version != 1`);
    if (d.suite !== s.dirName) problems.push(`${s.dirName}/scenario.json suite != 目录名`);
    if (!Array.isArray(d.scenarios) || d.scenarios.length < 1) { problems.push(`${s.dirName}/scenario.json scenarios 必须是非空数组`); continue; }
    for (const r of d.scenarios) {
      if (!isObj(r)) { problems.push(`${s.dirName}/scenario.json scenarios 元素不是对象`); continue; }
      const ek = Object.keys(r).sort();
      const wantE = ['id', 'name', 'path'];
      if (ek.length !== wantE.length || ek.some((x, i) => x !== wantE[i])) problems.push(`${s.dirName}/scenario.json 引用元素字段集应为 {path, id, name}`);
      if (typeof r.path !== 'string') { problems.push(`${s.dirName}/scenario.json 引用缺 path`); continue; }
      const abs = path.resolve(s.dir, r.path);
      if (!fs.existsSync(abs)) { problems.push(`${s.dirName}/scenario.json 引用指向不存在的文件 "${r.path}"`); continue; }
      if (!abs.startsWith(scenDir + path.sep)) problems.push(`${s.dirName}/scenario.json 引用越出 scenarios/`);
      const body = safeRead(abs);
      if (!isObj(body)) { problems.push(`${s.dirName}/scenario.json 引用指向的文件不是合法 JSON`); continue; }
      if (body.id !== r.id) problems.push(`${s.dirName}/scenario.json 引用 id "${r.id}" 与本体 "${body.id}" 漂移`);
      if (body.name !== r.name) problems.push(`${s.dirName}/scenario.json 引用 name "${r.name}" 与本体 "${body.name}" 漂移`);
    }
    // 套件内引用的场景集合 == 该套件应含的场景集合
    const refs = d.scenarios.map((r) => (isObj(r) ? r.id : null));
    const expect = workloads.filter((w) => w.environment === (s.suiteDoc && s.suiteDoc.environment)).map((w) => w.id);
    if (!sameSet(refs, expect)) problems.push(`${s.dirName}/scenario.json 引用的场景集合 != 该套件应含的场景集合`);
  }
  say(problems.length ? 'FAIL' : 'PASS', 'AC-017',
    problems.length ? problems.slice(0, 4).join('；') : '引用件字段集封闭 + 引用可解析 + 与本体不漂移');
}

// ---------------------------------------------------------------- AC-019 场景 ↔ 套件的双向覆盖完整性
{
  const problems = [];
  // 场景模型 id 索引
  const scenarioIds = scenarios.filter((s) => s.doc && typeof s.doc.id === 'string').map((s) => s.doc.id);
  const scenarioIdSet = new Set(scenarioIds);
  // 每个套件引用到的本体 id
  const refBySuite = new Map();
  for (const s of suites) {
    const refs = s.refDoc && Array.isArray(s.refDoc.scenarios) ? s.refDoc.scenarios : [];
    const ids = [];
    for (const r of refs) {
      if (!isObj(r) || typeof r.path !== 'string') { ids.push(null); continue; }
      const body = safeRead(path.resolve(s.dir, r.path));
      ids.push(isObj(body) && typeof body.id === 'string' ? body.id : null);
    }
    refBySuite.set(s.dirName, ids);
  }
  // ① 每个 workload 恰好被一个套件引用
  const refCount = new Map();
  for (const [suiteName, ids] of refBySuite) {
    for (const id of ids) {
      if (id === null) continue;
      refCount.set(id, (refCount.get(id) || 0) + 1);
    }
  }
  for (const w of workloads) {
    const n = refCount.get(w.id) || 0;
    if (n !== 1) problems.push(`容量目标 ${w.id} 被 ${n} 个套件引用（应为恰好 1 个）`);
  }
  // ② 每个套件至少引用一个场景模型
  for (const [suiteName, ids] of refBySuite) {
    if (ids.length < 1) problems.push(`套件 ${suiteName} 没有引用任何场景模型`);
  }
  // ③ 每个场景模型至少被一个套件引用（不得有孤儿场景）
  for (const id of scenarioIdSet) {
    const n = refCount.get(id) || 0;
    if (n < 1) problems.push(`场景模型 ${id} 是孤儿场景（没有任何套件引用）`);
  }
  // ④ 不得有孤儿套件（引用了不存在的场景模型）
  for (const [suiteName, ids] of refBySuite) {
    for (const id of ids) {
      if (id === null) { problems.push(`套件 ${suiteName} 引用解析不到场景模型`); continue; }
      if (!scenarioIdSet.has(id)) problems.push(`套件 ${suiteName} 引用了不存在的场景模型 ${id}`);
    }
  }
  // ⑤ 每个套件引用的 id 集合 == 该套件 environment 下应有的 workload id 集合
  for (const s of suites) {
    const env = s.suiteDoc && s.suiteDoc.environment;
    const ids = (refBySuite.get(s.dirName) || []).filter((x) => x !== null);
    const expect = workloads.filter((w) => w.environment === env).map((w) => w.id);
    if (!sameSet(ids, expect)) problems.push(`套件 ${s.dirName} 引用的场景集合 != 其 environment 下应有的容量目标集合`);
  }
  say(problems.length ? 'FAIL' : 'PASS', 'AC-019',
    problems.length ? problems.slice(0, 4).join('；') : '场景 ↔ 套件双向覆盖完整（无孤儿场景 / 无孤儿套件）');
}

// ---------------------------------------------------------------- AC-020 环境不得有 driver / executor=load / 不得有 cases.json
{
  const problems = [];
  for (const s of suites) {
    const env = s.suiteDoc && s.suiteDoc.environment;
    if (!nonEmpty(env)) continue;
    const ef = path.join(root, 'test-assets', 'environments', `${env}.json`);
    if (!fs.existsSync(ef)) { problems.push(`${s.dirName} 的环境文件不存在（无法核 driver）`); continue; }
    const ed = safeRead(ef);
    if (isObj(ed) && 'driver' in ed) problems.push(`${s.dirName} 指向的环境 "${env}.json" 含 driver 字段（合法枚举上游也放行 ⇒ 必须由门判）`);
    if (s.suiteDoc && s.suiteDoc.executor !== 'load') problems.push(`${s.dirName} executor != "load"`);
  }
  for (const s of suites) {
    if (fs.existsSync(path.join(s.dir, 'cases.json'))) problems.push(`${s.dirName} 里有 cases.json（压测套件不产出 cases.json）`);
  }
  // ④ 外部可观测证据：跑完之后不得产生任何执行产物（上游执行器的产物落点）
  const execHits = [];
  const scanExec = (dir) => {
    if (!fs.existsSync(dir)) return;
    for (const n of fs.readdirSync(dir)) {
      const f = path.join(dir, n);
      let st; try { st = fs.lstatSync(f); } catch { continue; }
      if (!st.isDirectory()) continue;
      if (n === 'runs' || n === 'evidence') { execHits.push(path.relative(root, f)); continue; }
      scanExec(f);
    }
  };
  scanExec(root);
  if (execHits.length > 0) problems.push(`跑完之后出现了执行产物目录: ${execHits.slice(0, 3).join(', ')}`);
  say(problems.length ? 'FAIL' : 'PASS', 'AC-020',
    problems.length ? problems.slice(0, 4).join('；') : '环境无 driver + executor=load + 无 cases.json + 跑完无执行产物');
}

// ---------------------------------------------------------------- AC-021 无来源 ⇒ 留未决问题
{
  const problems = [];
  for (const s of scenarios) {
    if (!s.doc) continue;
    const oq = Array.isArray(s.doc.open_questions) ? s.doc.open_questions : null;
    if (!oq) { problems.push(`${s.file} open_questions 不是数组`); continue; }
    const th = oq.filter((q) => isObj(q) && q.topic === 'thresholds');
    if (s.doc.thresholds_status === 'not_provided') {
      if (th.length < 1) problems.push(`${s.file} 无指标来源但没有 topic=thresholds 的未决问题`);
      else if (!th.some((q) => nonEmpty(q.question))) problems.push(`${s.file} thresholds 未决问题的 question 为空`);
    } else if (th.length > 0) {
      problems.push(`${s.file} 有来源却留了 topic=thresholds 的未决问题`);
    }
  }
  say(problems.length ? 'FAIL' : 'PASS', 'AC-021',
    problems.length ? problems.slice(0, 4).join('；') : '无来源必留痕 / 有来源不乱留');
}

// ---------------------------------------------------------------- AC-022 不得把未压测写成已通过
{
  const hits = [];
  const files = [];
  const collect = (dir) => {
    if (!fs.existsSync(dir)) return;
    for (const n of fs.readdirSync(dir).sort()) {
      const f = path.join(dir, n);
      let st; try { st = fs.statSync(f); } catch { continue; }
      if (st.isDirectory()) collect(f);
      else if (n.endsWith('.json')) files.push(f);
    }
  };
  collect(loadDir);
  for (const f of files) {
    const doc = safeRead(f);
    if (doc === null) continue;
    scanForbidden(doc, path.relative(root, f), hits);
  }
  say(hits.length ? 'FAIL' : 'PASS', 'AC-022',
    hits.length ? `产物里出现压测结论字段: ${hits.slice(0, 4).join(', ')}` : '全部产物无压测结论字段');
}

// ---------------------------------------------------------------- AC-023 未决问题合法性 + coverage 留痕
{
  const problems = [];
  const checkOq = (file, oq) => {
    if (!Array.isArray(oq)) { problems.push(`${file} open_questions 不是数组`); return; }
    const ids = new Set();
    for (const q of oq) {
      if (!isObj(q)) { problems.push(`${file} 未决问题条目不是对象`); continue; }
      const k = Object.keys(q).sort();
      const want = ['id', 'question', 'topic'];
      if (k.length !== want.length || k.some((x, i) => x !== want[i])) problems.push(`${file} 未决问题字段集应为 {id, topic, question}`);
      if (typeof q.id !== 'string' || !/^OQ-\d{3}$/.test(q.id)) problems.push(`${file} 未决问题 id 非法`);
      else if (ids.has(q.id)) problems.push(`${file} 未决问题 id 重复`);
      else ids.add(q.id);
      if (!TOPICS.has(q.topic)) problems.push(`${file} 未决问题 topic 非法`);
      if (!nonEmpty(q.question)) problems.push(`${file} 未决问题 question 为空`);
    }
  };
  for (const s of scenarios) {
    if (!s.doc) continue;
    checkOq(s.file, s.doc.open_questions);
    const refs = isObj(s.doc.traceability) && Array.isArray(s.doc.traceability.case_refs) ? s.doc.traceability.case_refs : [];
    if (refs.length === 0) {
      const oq = Array.isArray(s.doc.open_questions) ? s.doc.open_questions : [];
      if (!oq.some((q) => isObj(q) && q.topic === 'coverage')) problems.push(`${s.file} 没有对应用例但缺 topic=coverage 的未决问题`);
    }
  }
  const reportFile = path.join(loadDir, 'report.json');
  if (fs.existsSync(reportFile)) {
    const rd = safeRead(reportFile);
    if (isObj(rd)) checkOq('report.json', rd.open_questions);
  }
  say(problems.length ? 'FAIL' : 'PASS', 'AC-023',
    problems.length ? problems.slice(0, 4).join('；') : '未决问题字段齐全 / id 唯一 / coverage 留痕');
}

// ---------------------------------------------------------------- AC-024 对账 + 方法号口径
{
  const problems = [];
  // 独立复算期望的 case_refs
  const expectedRefs = new Map();
  for (const w of workloads) {
    const ids = [];
    if (casesDoc && Array.isArray(casesDoc.cases)) {
      for (const c of casesDoc.cases) {
        if (!isObj(c) || typeof c.id !== 'string') continue;
        const steps = Array.isArray(c.steps) ? c.steps : [];
        for (const st of steps) {
          const act = isObj(st) ? st.action : null;
          if (normalizeAction(act) === w.target && !ids.includes(c.id)) { ids.push(c.id); break; }
        }
      }
    }
    expectedRefs.set(w.id, ids);
  }
  for (const s of scenarios) {
    if (!s.doc) continue;
    const w = wById.get(s.doc.id);
    if (!w) continue;
    const tr = s.doc.traceability;
    if (!isObj(tr)) { problems.push(`${s.file} traceability 不是对象`); continue; }
    if (tr.workload_id !== w.id) problems.push(`${s.file} traceability.workload_id != 输入 workload.id`);
    const expReq = Array.isArray(w.requirement_refs) ? w.requirement_refs : [];
    if (!deepEq(tr.requirement_refs, expReq)) problems.push(`${s.file} traceability.requirement_refs != 输入`);
    const exp = expectedRefs.get(w.id) || [];
    const got = Array.isArray(tr.case_refs) ? tr.case_refs : [];
    if (!deepEq(got, exp)) problems.push(`${s.file} traceability.case_refs != 复算结果（期望 [${exp.join(', ')}]，实际 [${got.join(', ')}]）`);
  }
  // 方法号口径：产物不得有 method 字段
  const methodHits = [];
  const files = [];
  const collect = (dir) => {
    if (!fs.existsSync(dir)) return;
    for (const n of fs.readdirSync(dir).sort()) {
      const f = path.join(dir, n);
      let st; try { st = fs.statSync(f); } catch { continue; }
      if (st.isDirectory()) collect(f);
      else if (n.endsWith('.json')) files.push(f);
    }
  };
  collect(loadDir);
  for (const f of files) {
    const doc = safeRead(f);
    if (doc === null) continue;
    const walk = (node, p) => {
      if (Array.isArray(node)) { node.forEach((v, i) => walk(v, `${p}[${i}]`)); return; }
      if (isObj(node)) {
        for (const [k, v] of Object.entries(node)) {
          if (k === 'method') methodHits.push(`${path.relative(root, f)}${p}.method`);
          walk(v, `${p}.${k}`);
        }
      }
    };
    walk(doc, '');
  }
  if (methodHits.length > 0) problems.push(`产物出现 method 字段: ${methodHits.slice(0, 3).join(', ')}`);
  say(problems.length ? 'FAIL' : 'PASS', 'AC-024',
    problems.length ? problems.slice(0, 4).join('；') : 'case_refs 与复算一致 + traceability 逐字相等 + 无 method 字段');
}

process.stdout.write(out.join('\n') + '\n');
JUDGENODE

# ---------------------------------------------------------------- 上游加载层检查（loadcheck.mjs，另一个进程）
# ⚠️ 这个进程**故意** import 被验包的 suite-loader.mjs —— 「能不能被上游消费」只能问上游本人。

cat > "$WORK/loadcheck.mjs" <<'LOADCHECKNODE'
// 单独进程实跑上游加载层：对每个 load 套件调 loadSuite()，拿真实退出码。
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [pkgArg, ...suitePaths] = process.argv.slice(2);
const pkg = path.resolve(pkgArg);
const loaderPath = path.join(pkg, 'skills', 'test-execute', 'scripts', 'lib', 'suite-loader.mjs');
let mod;
try {
  mod = await import(pathToFileURL(loaderPath).href);
} catch (e) {
  process.stdout.write(JSON.stringify({ ok: false, error: `import 上游加载层失败: ${e && e.message ? e.message : String(e)}` }) + '\n');
  process.exit(0);
}
const results = [];
let okAll = true;
for (const sp of suitePaths) {
  try {
    const r = mod.loadSuite(sp);
    const cfg = (r && r.config) || {};
    const good = cfg.scope === 'load' && cfg.executor === 'load' && typeof r.casesFile === 'string';
    if (!good) okAll = false;
    results.push({ suite: sp, ok: good, config: cfg, casesFile: r && r.casesFile });
  } catch (e) {
    okAll = false;
    results.push({ suite: sp, ok: false, error: e && e.message ? e.message : String(e) });
  }
}
process.stdout.write(JSON.stringify({ ok: okAll, results }) + '\n');
LOADCHECKNODE

# ---------------------------------------------------------------- 目录指纹 / 小工具

cat > "$WORK/snapdir.mjs" <<'SNAPNODE'
// 目录指纹：递归列出「相对路径 + 内容 sha256」（排除 exclude 指定的相对路径前缀）
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const dir = path.resolve(process.argv[2]);
const exclude = process.argv[3] || '';
const lines = [];
const walk = (d) => {
  if (!fs.existsSync(d)) return;
  for (const n of fs.readdirSync(d).sort()) {
    const f = path.join(d, n);
    const rel = path.relative(dir, f);
    if (exclude && (rel === exclude || rel.startsWith(exclude + path.sep))) continue;
    let st; try { st = fs.lstatSync(f); } catch { continue; }
    if (st.isDirectory()) walk(f);
    else if (st.isFile()) {
      const h = crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');
      lines.push(`${rel} ${h}`);
    }
  }
};
walk(dir);
process.stdout.write(lines.join('\n') + '\n');
SNAPNODE

cat > "$WORK/treecmp.mjs" <<'TREECMPNODE'
// 两个目录树的指纹比对（排除 exclude 前缀）：输出 SAME / DIFF
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const [a, b, exclude] = process.argv.slice(2);
const snap = (dir) => {
  const map = new Map();
  const walk = (d) => {
    if (!fs.existsSync(d)) return;
    for (const n of fs.readdirSync(d).sort()) {
      const f = path.join(d, n);
      const rel = path.relative(dir, f);
      if (exclude && (rel === exclude || rel.startsWith(exclude + path.sep))) continue;
      let st; try { st = fs.lstatSync(f); } catch { continue; }
      if (st.isDirectory()) walk(f);
      else if (st.isFile()) map.set(rel, crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex'));
    }
  };
  walk(path.resolve(dir));
  return map;
};
const ma = snap(a), mb = snap(b);
if (ma.size !== mb.size) { process.stdout.write('DIFF\n'); process.exit(0); }
for (const [k, v] of ma) if (mb.get(k) !== v) { process.stdout.write('DIFF\n'); process.exit(0); }
process.stdout.write('SAME\n');
TREECMPNODE

cat > "$WORK/mutfp.mjs" <<'MUTFPNODE'
// mutfp.mjs —— 变异「可观测状态」的组合指纹（自证篡改真的生效）
// 覆盖四类变异落点：① 产物树 ② out-dir 里 test-assets/load 之外的部分（环境/轮次）
//                   ③ 输入文件 ④ 被验包里的若干记账件
// ⚠️ 刻意**不**覆盖 skills/load-profile/scripts/（包装层本身就换掉了入口脚本，比了没意义）。
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const [pkgDir, outDir, ctxFile, casesFile] = process.argv.slice(2);
const sha = (p) => {
  try { return crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex'); }
  catch { return 'MISSING'; }
};
const treeHash = (dir, exclude) => {
  const lines = [];
  const walk = (d) => {
    if (!fs.existsSync(d)) return;
    for (const n of fs.readdirSync(d).sort()) {
      const f = path.join(d, n);
      const rel = path.relative(dir, f);
      if (exclude && (rel === exclude || rel.startsWith(exclude + path.sep))) continue;
      let st; try { st = fs.lstatSync(f); } catch { continue; }
      if (st.isDirectory()) walk(f);
      else if (st.isFile()) lines.push(`${rel} ${sha(f)}`);
    }
  };
  walk(path.resolve(dir));
  const h = crypto.createHash('sha256');
  h.update(lines.join('\n'));
  return h.digest('hex');
};

const parts = [
  treeHash(path.join(outDir, 'test-assets', 'load'), ''),
  treeHash(outDir, path.join('test-assets', 'load')),
  sha(ctxFile),
  sha(casesFile),
  sha(path.join(pkgDir, 'skills', 'load-profile', 'skill-meta.json')),
  sha(path.join(pkgDir, 'README.md')),
  sha(path.join(pkgDir, 'feature-meta', 'load-profile', 'traceability.md')),
];
process.stdout.write(parts.join(' ') + '\n');
MUTFPNODE

cat > "$WORK/enumcheck.mjs" <<'ENUMCHECKNODE'
// enumcheck.mjs —— 产物侧的枚举取值合法性（AC-008 的产物侧条款）
import fs from 'node:fs';
import path from 'node:path';

const outDir = process.argv[2];
const PROFILE_TYPES = new Set(['constant', 'ramp-up', 'ramp-down', 'spike', 'soak']);
const RUNNERS = new Set(['loadtest', 'python']);
const RUNTIMES = new Set(['bun', 'python', 'node']);
const THRESHOLD_KEYS = new Set(['p50_latency_ms', 'p95_latency_ms', 'p99_latency_ms', 'error_rate', 'throughput_rps', 'max_concurrency']);
const scenDir = path.join(outDir, 'test-assets', 'load', 'scenarios');
const problems = [];
if (fs.existsSync(scenDir)) {
  for (const n of fs.readdirSync(scenDir).filter((x) => x.endsWith('.json')).sort()) {
    let t; try { t = JSON.parse(fs.readFileSync(path.join(scenDir, n), 'utf8')); } catch { continue; }
    if (t.profile && !PROFILE_TYPES.has(t.profile.type)) problems.push(`${n}: profile.type 取值非法 "${t.profile.type}"`);
    if (t.tool) {
      if (!RUNNERS.has(t.tool.runner)) problems.push(`${n}: tool.runner 取值非法 "${t.tool.runner}"`);
      if (!RUNTIMES.has(t.tool.runtime)) problems.push(`${n}: tool.runtime 取值非法 "${t.tool.runtime}"`);
    }
    if (t.thresholds && typeof t.thresholds === 'object') {
      for (const k of Object.keys(t.thresholds)) if (!THRESHOLD_KEYS.has(k)) problems.push(`${n}: thresholds 多余键 "${k}"`);
    }
  }
}
process.stdout.write(problems.join('; ') + '\n');
ENUMCHECKNODE

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

cat > "$WORK/pkgfiles.mjs" <<'PKGFILESNODE'
// 统计被验包内某个相对路径的文件数（用于变异注入锚点的唯一性自证）
import fs from 'node:fs';
import path from 'node:path';
const pkg = path.resolve(process.argv[2]);
const rel = process.argv[3];
let count = 0;
const walk = (d) => {
  for (const n of fs.readdirSync(d)) {
    const f = path.join(d, n);
    let st; try { st = fs.lstatSync(f); } catch { continue; }
    if (st.isDirectory()) walk(f);
    else if (st.isFile() && path.relative(pkg, f) === rel) count += 1;
  }
};
if (fs.existsSync(pkg)) walk(pkg);
process.stdout.write(String(count) + '\n');
PKGFILESNODE

cat > "$WORK/jsonpick.mjs" <<'JSONPICKNODE'
// 从 JSON 文本里取某个键的值（用于把 judge/loadcheck 的输出喂回 bash）
import fs from 'node:fs';
const file = process.argv[2];
const key = process.argv[3];
let doc = null;
try { doc = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { }
if (doc === null) { process.stdout.write(''); process.exit(0); }
const v = doc[key];
if (v === undefined || v === null) { process.stdout.write(''); process.exit(0); }
process.stdout.write(typeof v === 'object' ? JSON.stringify(v) : String(v));
JSONPICKNODE

# ---------------------------------------------------------------- 跑夹具

FX="$WORK/fx"
FIXOUT="$(node "$WORK/mkfixture.mjs" "$FX" 2>&1)"
if [ "$FIXOUT" != "FIXTURE-OK" ]; then
  printf '夹具生成失败: %s\n' "$FIXOUT" >&2
  exit 2
fi
CTX="$FX/inputs/context.json"
FCASES="$FX/inputs/cases.json"
VDIR="$FX/inputs/variants"

# 输入文件跑前快照（AC-027 用）
CTX_SHA_BEFORE="$(sha256sum "$CTX" 2>/dev/null | cut -d' ' -f1)"
CASES_SHA_BEFORE="$(sha256sum "$FCASES" 2>/dev/null | cut -d' ' -f1)"

# ---------------------------------------------------------------- 跑被验实现

IMPL_MISSING=0
if [ ! -f "$ENTRY" ]; then
  IMPL_MISSING=1
  printf '⚠️ 被验包没有入口脚本 %s —— 产物类判据将如实判红（实现未交付）\n' "$ENTRY_REL"
fi

new_proj() { # $1 = 目标目录名
  local d="$WORK/$1"
  mkdir -p "$d"
  cp -r "$FX/proj/." "$d/" 2>/dev/null
  printf '%s' "$d"
}

run_impl() { # $1 = out-dir, 其余 = 额外参数
  local out="$1"; shift
  if [ "$IMPL_MISSING" -eq 1 ]; then return 127; fi
  node "$ENTRY" "$@" --out-dir "$out" >/dev/null 2>"$WORK/impl.err"
  return $?
}

PROJ_MAIN="$(new_proj run-main)"
RC_MAIN=0; run_impl "$PROJ_MAIN" --context "$CTX" --cases "$FCASES" || RC_MAIN=$?
MAIN_ERR="$(cat "$WORK/impl.err" 2>/dev/null)"

PROJ_IDEM1="$(new_proj run-idem1)"
RC_IDEM1=0; run_impl "$PROJ_IDEM1" --context "$CTX" --cases "$FCASES" || RC_IDEM1=$?

PROJ_IDEM2="$(new_proj run-idem2)"
RC_IDEM2=0; run_impl "$PROJ_IDEM2" --context "$CTX" --cases "$FCASES" || RC_IDEM2=$?

# AC-028：同一 out-dir 跑两次
PROJ_EXIST="$(new_proj run-exist)"
RC_EXIST1=0; run_impl "$PROJ_EXIST" --context "$CTX" --cases "$FCASES" || RC_EXIST1=$?
EXIST_BEFORE="$(node "$WORK/snapdir.mjs" "$PROJ_EXIST/test-assets/load" 2>/dev/null)"
RC_EXIST2=0; run_impl "$PROJ_EXIST" --context "$CTX" --cases "$FCASES" || RC_EXIST2=$?
EXIST_AFTER="$(node "$WORK/snapdir.mjs" "$PROJ_EXIST/test-assets/load" 2>/dev/null)"

# 非法输入变体（B 组）
run_bad() { # $1 = 变体名
  local name="$1"
  local d="$WORK/bad-$name"
  mkdir -p "$d"; cp -r "$FX/proj/." "$d/" 2>/dev/null
  local rc=0
  if [ "$IMPL_MISSING" -eq 1 ]; then rc=127; else
    node "$ENTRY" --context "$VDIR/$name.json" --cases "$FCASES" --out-dir "$d" >"$WORK/bad-$name.out" 2>&1 || rc=$?
  fi
  printf '%s' "$rc"
}
RC_V1="$(run_bad V1)"; RC_V2="$(run_bad V2)"; RC_V3="$(run_bad V3)"; RC_V4="$(run_bad V4)"
RC_V5="$(run_bad V5)"; RC_V6="$(run_bad V6)"; RC_V7="$(run_bad V7)"; RC_V8="$(run_bad V8)"
RC_V1b="$(run_bad V1b)"; RC_V8b="$(run_bad V8b)"

# ---------------------------------------------------------------- A 组：交付物形状（门直接查文件）

step "A 组：交付物形状"

frontmatter_value() { # $1 = SKILL.md 路径, $2 = 键名
  node -e '
    const fs=require("fs");
    const [f,k]=process.argv.slice(1);
    const s=fs.readFileSync(f,"utf8");
    const m=/^---\r?\n([\s\S]*?)\r?\n---/.exec(s);
    if(!m){process.stdout.write("");process.exit(0);}
    const lines=m[1].split(/\r?\n/);
    for(let i=0;i<lines.length;i++){
      const mm=/^([A-Za-z0-9_-]+):\s*(.*)$/.exec(lines[i]);
      if(!mm||mm[1]!==k)continue;
      let v=mm[2].trim();
      if(v==="|"||v===">"||v==="|-"||v===">-"){
        const buf=[];let j=i+1;
        for(;j<lines.length;j++){
          const t=lines[j];
          if(t.trim()===""){buf.push("");continue;}
          if(/^\s+/.test(t)){buf.push(t.trim());continue;}
          break;
        }
        process.stdout.write(buf.join(" ").trim());process.exit(0);
      }
      v=v.replace(/^["'"'"']|["'"'"']$/g,"").trim();
      process.stdout.write(v);process.exit(0);
    }
    process.stdout.write("");
  ' "$1" "$2" 2>/dev/null
}

if [ -d "$TR" ] && [ -f "$TR/SKILL.md" ]; then
  A1_OK=1; A1_MSG=""
  FM_NAME="$(frontmatter_value "$TR/SKILL.md" name)"
  FM_DESC="$(frontmatter_value "$TR/SKILL.md" description)"
  [ "$FM_NAME" = "load-profile" ] || { A1_OK=0; A1_MSG="$A1_MSG SKILL.md frontmatter name != load-profile"; }
  [ -n "$FM_DESC" ] || { A1_OK=0; A1_MSG="$A1_MSG SKILL.md frontmatter description 为空"; }
  for f in skill-meta.json references/load-context-schema.md references/load-scenario-format.md \
           references/profile-rules.md scripts/make-load-profile.mjs scripts/check-load-profile.mjs; do
    if [ ! -s "$TR/$f" ]; then A1_OK=0; A1_MSG="$A1_MSG 缺/空 $f"; fi
  done
  LIBN=0
  if [ -d "$TR/scripts/lib" ]; then
    for f in "$TR/scripts/lib"/*.mjs; do [ -s "$f" ] && LIBN=$((LIBN+1)); done
  fi
  [ "$LIBN" -ge 3 ] || { A1_OK=0; A1_MSG="$A1_MSG scripts/lib 下非空 .mjs 少于 3 个（实际 $LIBN）"; }
  for s in make-load-profile.mjs check-load-profile.mjs; do
    p="$TR/scripts/$s"
    if [ ! -f "$p" ]; then continue; fi
    head -1 "$p" 2>/dev/null | grep -q '^#!/usr/bin/env node' || { A1_OK=0; A1_MSG="$A1_MSG $s 首行不是 shebang"; }
    [ -x "$p" ] || { A1_OK=0; A1_MSG="$A1_MSG $s 不可执行"; }
    node --check "$p" >/dev/null 2>&1 || { A1_OK=0; A1_MSG="$A1_MSG $s node --check 不通过"; }
  done
  if [ "$A1_OK" -eq 1 ]; then ok "PASS AC-001 load-profile skill 存在且结构合法" "AC-001"
  else bad "FAIL AC-001 $A1_MSG" "AC-001"; fi
else
  bad "FAIL AC-001 skills/load-profile/ 或 SKILL.md 不存在" "AC-001"
fi

A2_OK=1; A2_MSG=""
for d in "$PKG_SKILLS"/*/; do
  [ -f "$d/SKILL.md" ] || continue
  sn="$(basename "$d")"
  if [ ! -s "$d/skill-meta.json" ]; then A2_OK=0; A2_MSG="$A2_MSG $sn 缺 skill-meta.json"; continue; fi
  node -e '
    const fs=require("fs");
    const [f,dir]=process.argv.slice(1);
    let m;try{m=JSON.parse(fs.readFileSync(f,"utf8"));}catch(e){console.log("PARSE");process.exit(0);}
    const p=[];
    if(m.name!==dir)p.push("name!=目录名");
    if(!/^\d+\.\d+\.\d+$/.test(String(m.version||"")))p.push("version 非法");
    if(!m.requires||typeof m.requires!=="object")p.push("requires 非法");
    else for(const [k,v] of Object.entries(m.requires)) if(!/^(>=)?\d+\.\d+\.\d+$/.test(String(v)))p.push("requires["+k+"] 约束非法");
    console.log(p.join(","));
  ' "$d/skill-meta.json" "$sn" 2>/dev/null | while IFS= read -r line; do
      [ -n "$line" ] && { A2_OK=0; A2_MSG="$A2_MSG $sn: $line"; }
    done
done
# ⚠️ 上面用管道会开子 shell（变量丢失）—— 重新用一次不带管道的方式核 load-profile 的 requires
LP_META="$TR/skill-meta.json"
if [ -s "$LP_META" ]; then
  LP_REQ="$(node -e '
    const fs=require("fs");
    let m;try{m=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));}catch(e){process.stdout.write("PARSE-ERR");process.exit(0);}
    const r=m.requires;
    if(!r||typeof r!=="object"){process.stdout.write("NO-REQUIRES");process.exit(0);}
    const ks=Object.keys(r).sort();
    process.stdout.write(ks.join(","));
  ' "$LP_META" 2>/dev/null)"
  if [ "$LP_REQ" != "qa-toolchain,test-case-design" ]; then
    A2_OK=0; A2_MSG="$A2_MSG load-profile.requires 键集合应为 qa-toolchain,test-case-design（实际 ${LP_REQ:-空}）"
  fi
else
  A2_OK=0; A2_MSG="$A2_MSG load-profile 缺 skill-meta.json"
fi
if [ "$A2_OK" -eq 1 ]; then ok "PASS AC-002 每个 skill 都声明版本与依赖；load-profile.requires 恰为 test-case-design + qa-toolchain" "AC-002"
else bad "FAIL AC-002 $A2_MSG" "AC-002"; fi

A3_OK=1; A3_MSG=""
if [ -f "$README" ]; then
  PKG_SKILL_LIST="$(for d in "$PKG_SKILLS"/*/; do [ -f "$d/SKILL.md" ] && basename "$d"; done | sort -u | tr '\n' ' ')"
  README_JSON="$(node "$WORK/readme-skills.mjs" "$README" 2>/dev/null)"
  README_LIST="$(node -e 'try{const o=JSON.parse(process.argv[1]);process.stdout.write((o.names||[]).join(" "))}catch(e){process.stdout.write("")}' "$README_JSON" 2>/dev/null)"
  README_TABLE="$(node -e 'try{const o=JSON.parse(process.argv[1]);process.stdout.write((o.table||[]).join(" "))}catch(e){process.stdout.write("")}' "$README_JSON" 2>/dev/null)"
  README_TREE="$(node -e 'try{const o=JSON.parse(process.argv[1]);process.stdout.write((o.tree||[]).join(" "))}catch(e){process.stdout.write("")}' "$README_JSON" 2>/dev/null)"
  PKG_LIST_SORT="$(printf '%s\n' $PKG_SKILL_LIST | sort -u | tr '\n' ' ')"
  if [ "$(norm_list "$PKG_LIST_SORT")" != "$(norm_list "$README_LIST")" ]; then
    A3_OK=0; A3_MSG="$A3_MSG README skill 清单与实际目录不一致（实际目录: ${PKG_LIST_SORT}｜README: ${README_LIST}）"
  fi
  if ! printf '%s' "$README_TABLE" | grep -qw "load-profile"; then
    A3_OK=0; A3_MSG="$A3_MSG README 的 skill 表格里没有 load-profile"
  fi
  if ! printf '%s' "$README_TREE" | grep -qw "load-profile"; then
    A3_OK=0; A3_MSG="$A3_MSG README 的安装树代码块里没有 load-profile/"
  fi
else
  A3_OK=0; A3_MSG="$A3_MSG README.md 不存在"
fi
if [ "$A3_OK" -eq 1 ]; then ok "PASS AC-003 README 的 skill 清单与实际目录一致，load-profile 两处都在" "AC-003"
else bad "FAIL AC-003 $A3_MSG" "AC-003"; fi

# ---------------------------------------------------------------- 跑上游校验器（真实输出）

step "上游校验器与加载层（真实实跑）"

LAYOUT_OUT="$WORK/layout.out"
LAYOUT_RC=0
if [ -f "$LAYOUT" ]; then
  node "$LAYOUT" "$PROJ_MAIN" >"$LAYOUT_OUT" 2>&1 || LAYOUT_RC=$?
else
  LAYOUT_RC=127
  : > "$LAYOUT_OUT"
fi
LAYOUT_OUT="$(sed 's/\x1b\[[0-9;]*m//g' "$LAYOUT_OUT" 2>/dev/null)"

# 被 workload 引用的环境文件是否都存在（AC-004 / AC-019 的前置条件）
ENVS_USED="$(node -e '
  const fs=require("fs");
  const c=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  const s=new Set((c.workloads||[]).map(w=>w.environment));
  process.stdout.write([...s].join(" "));
' "$CTX" 2>/dev/null)"
ENV_PRECOND_OK=1
ENV_MISSING=""
for e in $ENVS_USED; do
  if [ ! -f "$PROJ_MAIN/test-assets/environments/$e.json" ]; then
    ENV_PRECOND_OK=0; ENV_MISSING="$ENV_MISSING $e.json"
  fi
done

# 每个套件在上游输出里的判定行
SUITE_RELS=""
if [ -d "$PROJ_MAIN/test-assets/load/suites" ]; then
  for sd in "$PROJ_MAIN/test-assets/load/suites"/*/; do
    [ -f "$sd/suite.json" ] || continue
    rel="test-assets/load/suites/$(basename "$sd")/suite.json"
    SUITE_RELS="$SUITE_RELS $rel"
  done
fi

judge_layout_suites() { # $1 = 输出文本, $2 = 输出变量名（通过 echo 行返回）
  local text="$1"
  local problems="" oks=0
  for rel in $SUITE_RELS; do
    if [ -z "$rel" ]; then continue; fi
    local hits
    hits="$(printf '%s\n' "$text" | grep -F "$rel" || true)"
    if [ -z "$hits" ]; then problems="$problems 上游没有对该套件输出任何判定行（$rel）"; continue; fi
    if printf '%s\n' "$hits" | grep -q '^\[FAIL\]'; then
      problems="$problems 上游对该套件判 FAIL（$rel）"
    else
      oks=$((oks+1))
    fi
  done
  printf '%s|%s' "$oks" "$problems"
}

# ---------------------------------------------------------------- B 组：输入解析与校验

step "B 组：输入解析与校验"

check_bad() { # $1 = 变体名, $2 = 期望 rc, $3.. = 可接受的 stderr 关键词（任一命中即可）
  local name="$1"; shift
  local want="$1"; shift
  local rcvar="RC_$name"
  # ⚠️ 用 `${!rcvar-}`（带默认值展开）：变体**压根没跑**时该变量未定义，
  #    在 `set -u` 下 `${!rcvar}` 会让**门自己**抛 bash 错误 ⇒ 门不干净、判定不可信。
  local rc="${!rcvar-}"
  local out; out="$(cat "$WORK/bad-$name.out" 2>/dev/null)"
  local d="$WORK/bad-$name"
  local problems=""
  if [ -z "$rc" ]; then
    # 变体**没跑**（通常意味着实现缺失）⇒ 单独记「未运行」，**不**混进「退出码不对」
    problems="变体 $name 未运行（没有退出码）"
  elif [ "$rc" != "$want" ]; then
    problems="退出码 $rc（期望 $want）"
  fi
  if [ -e "$d/test-assets/load" ]; then problems="$problems 留下了半份产物"; fi
  local hit=0
  for kw in "$@"; do
    if printf '%s' "$out" | grep -qiF -- "$kw"; then hit=1; break; fi
  done
  [ "$hit" -eq 1 ] || problems="$problems stderr 未点名坏点（期望提到: $*）"
  printf '%s' "$problems"
}

B5="$(check_bad V1 1 workloads)"; B5="$B5 $(check_bad V1b 1 workloads)"; B5="$B5 $(check_bad V2 1 load_scenario)"
B6="$(check_bad V3 1 prod environment)"; B6="$B6 $(check_bad V7 1 target)"
B7="$(check_bad V4 1 WL-001)"; B7="$B7 $(check_bad V8 1 WL-1)"
B8="$(check_bad V5 1 profile type)"; B8="$B8 $(check_bad V6 1 thresholds_source thresholds)"; B8="$B8 $(check_bad V8b 1 runner jmeter)"
# AC-008 的**产物侧**条款：产物里的枚举取值必须合法（输入侧拦不住的，产物侧要拦）
if [ "$IMPL_MISSING" -eq 1 ]; then
  B8="$B8 实现缺失（无产物可核枚举）"
else
  ENUM_PROBLEMS="$(node "$WORK/enumcheck.mjs" "$PROJ_MAIN" 2>/dev/null)"
  [ -n "$(norm_list "$ENUM_PROBLEMS")" ] && B8="$B8 产物枚举越界: $ENUM_PROBLEMS"
fi

if [ -z "$(norm_list "$B5")" ]; then ok "PASS AC-005 上下文的必填字段与顶层封闭集被校验（V1/V1b/V2）" "AC-005"
else bad "FAIL AC-005 $(norm_list "$B5")" "AC-005"; fi
if [ -z "$(norm_list "$B6")" ]; then ok "PASS AC-006 workload 的引用完整、target 格式合法（V3/V7）" "AC-006"
else bad "FAIL AC-006 $(norm_list "$B6")" "AC-006"; fi
if [ -z "$(norm_list "$B7")" ]; then ok "PASS AC-007 workload 的 id 唯一且格式合法（V4/V8）" "AC-007"
else bad "FAIL AC-007 $(norm_list "$B7")" "AC-007"; fi
if [ -z "$(norm_list "$B8")" ]; then ok "PASS AC-008 枚举合法且 thresholds/thresholds_source 成对（V5/V6/V8b）" "AC-008"
else bad "FAIL AC-008 $(norm_list "$B8")" "AC-008"; fi

# ---------------------------------------------------------------- C/D/E/F 组：复算器

step "C~F 组：独立复算器判定"

JUDGE_OUT="$WORK/judge.out"
: > "$JUDGE_OUT"
if [ "$IMPL_MISSING" -eq 1 ]; then
  for ac in AC-009 AC-010 AC-011 AC-012 AC-013 AC-014 AC-015 AC-016 AC-017 AC-019 AC-020 AC-021 AC-022 AC-023 AC-024; do
    printf 'FAIL %s 实现缺失（%s 不存在）\n' "$ac" "$ENTRY_REL" >> "$JUDGE_OUT"
  done
else
  node "$WORK/judge.mjs" "$PROJ_MAIN" "$CTX" "$FCASES" >> "$JUDGE_OUT" 2>"$WORK/judge.err" || true
fi

while IFS= read -r line; do
  case "$line" in
    PASS\ AC-*) ac="$(printf '%s' "$line" | grep -oE 'AC-[0-9]+' | head -1)"; ok "$line" "$ac" ;;
    FAIL\ AC-*) ac="$(printf '%s' "$line" | grep -oE 'AC-[0-9]+' | head -1)"; bad "$line" "$ac" ;;
    UNDEC\ AC-*) ac="$(printf '%s' "$line" | grep -oE 'AC-[0-9]+' | head -1)"; undec "$line" "$ac" ;;
  esac
done < "$JUDGE_OUT"

# ---------------------------------------------------------------- E 组：可消费（问上游本人）

step "E 组：可被上游消费（实跑上游）"

# AC-018：上游 loadSuite() 真实调用
LC_OUT="$WORK/loadcheck.out"
: > "$LC_OUT"
if [ ! -f "$LOADER" ]; then
  # ⚠️ 上游模块缺失 = **环境问题**，不是实现违约 ⇒ 判**不可判定**（≠ 通过 ⇒ 退出码仍非 0）
  undec "UNDEC AC-018 被验包里没有上游加载层 $LOADER_REL —— 环境问题，不是实现违约（不可判定 ≠ 通过）" "AC-018"
elif [ "$IMPL_MISSING" -eq 1 ]; then
  bad "FAIL AC-018 实现缺失（无产物可让上游解析）" "AC-018"
else
  SUITE_FILES=""
  if [ -d "$PROJ_MAIN/test-assets/load/suites" ]; then
    for sd in "$PROJ_MAIN/test-assets/load/suites"/*/; do
      [ -f "$sd/suite.json" ] && SUITE_FILES="$SUITE_FILES $sd/suite.json"
    done
  fi
  if [ -z "$SUITE_FILES" ]; then
    bad "FAIL AC-018 产物里没有 load 套件的 suite.json" "AC-018"
  else
    node "$WORK/loadcheck.mjs" "$PKG" $SUITE_FILES > "$LC_OUT" 2>"$WORK/loadcheck.err" || true
    LC_OK="$(node "$WORK/jsonpick.mjs" "$LC_OUT" ok 2>/dev/null)"
    LC_ERR="$(node "$WORK/jsonpick.mjs" "$LC_OUT" error 2>/dev/null)"
    if [ "$LC_OK" = "true" ]; then
      ok "PASS AC-018 上游 loadSuite() 真实调用解析 load 套件不抛错" "AC-018"
    else
      bad "FAIL AC-018 上游 loadSuite() 解析失败 ${LC_ERR}" "AC-018"
    fi
  fi
fi

# AC-004 / AC-019：上游校验器对该套件的判定行（三分支）
LAYOUT_RESULT="$(judge_layout_suites "$LAYOUT_OUT")"
LAYOUT_OKS="${LAYOUT_RESULT%%|*}"
LAYOUT_PROBLEMS="${LAYOUT_RESULT#*|}"

if [ ! -f "$LAYOUT" ]; then
  # ⚠️ 上游模块缺失 = **环境问题**，不是实现违约 ⇒ 判**不可判定**（≠ 通过 ⇒ 退出码仍非 0）
  undec "UNDEC AC-004 被验包里没有上游校验器 $LAYOUT_REL —— 环境问题，不是实现违约（不可判定 ≠ 通过）" "AC-004"
elif [ "$IMPL_MISSING" -eq 1 ]; then
  bad "FAIL AC-004 实现缺失（无产物可校验）" "AC-004"
elif [ "$ENV_PRECOND_OK" -ne 1 ]; then
  undec "UNDEC AC-004 前置条件不满足：被引用的环境文件缺失（${ENV_MISSING# }）—— 不算实现违约" "AC-004"
else
  if [ -n "$LAYOUT_PROBLEMS" ]; then
    bad "FAIL AC-004 $LAYOUT_PROBLEMS" "AC-004"
  else
    ok "PASS AC-004 上游校验器对该 load 套件的判定行全 [OK]（${LAYOUT_OKS} 个套件）" "AC-004"
  fi
fi

# AC-020 第 4 项（跑完无执行产物）由**复算器**一并判（它能扫到整个项目根）——
#    落点是**文件系统上的外部证据**，不是「门源码里没有某个字面量」。

# ---------------------------------------------------------------- G 组：追溯与写入权

step "G 组：追溯与写入权"

# AC-025 幂等
if [ "$IMPL_MISSING" -eq 1 ]; then
  bad "FAIL AC-025 实现缺失（无产物可比对）" "AC-025"
else
  IDEM_CMP="$(node "$WORK/treecmp.mjs" "$PROJ_IDEM1/test-assets/load" "$PROJ_IDEM2/test-assets/load" 2>/dev/null)"
  if [ "$IDEM_CMP" = "SAME" ]; then
    ok "PASS AC-025 两次跑（不同 out-dir）的产物逐字相同" "AC-025"
  else
    bad "FAIL AC-025 两次跑的产物不一致（存在非确定性内容）" "AC-025"
  fi
fi

# AC-026 只写自己的目录
if [ "$IMPL_MISSING" -eq 1 ]; then
  bad "FAIL AC-026 实现缺失（无产物可核）" "AC-026"
else
  OUTSIDE_BEFORE="$(node "$WORK/snapdir.mjs" "$PROJ_MAIN" "test-assets/load" 2>/dev/null)"
  # 主跑已经结束 ⇒ 用「跑前」快照不可得，这里改用：环境/周期文件的内容与夹具一致 ⇒ 未被改写
  ENV_NOW="$(sha256sum "$PROJ_MAIN/test-assets/environments/local.json" 2>/dev/null | cut -d' ' -f1)"
  ENV_REF="$(sha256sum "$FX/proj/test-assets/environments/local.json" 2>/dev/null | cut -d' ' -f1)"
  CYC_NOW="$(sha256sum "$PROJ_MAIN/test-assets/cycles/R1-REQ-009/cycle.json" 2>/dev/null | cut -d' ' -f1)"
  CYC_REF="$(sha256sum "$FX/proj/test-assets/cycles/R1-REQ-009/cycle.json" 2>/dev/null | cut -d' ' -f1)"
  EXTRA="$(node "$WORK/snapdir.mjs" "$PROJ_MAIN" "test-assets/load" 2>/dev/null | grep -v 'test-assets/environments/local.json' | grep -v 'test-assets/environments/staging.json' | grep -v 'test-assets/environments/_schema.json' | grep -v 'test-assets/cycles/index.json' | grep -v 'test-assets/cycles/R1-REQ-009/cycle.json' | grep -v '\.gitignore' || true)"
  if [ "$ENV_NOW" = "$ENV_REF" ] && [ "$CYC_NOW" = "$CYC_REF" ] && [ -z "$EXTRA" ]; then
    ok "PASS AC-026 只写 test-assets/load/，环境与轮次文件逐字未变" "AC-026"
  else
    bad "FAIL AC-026 写了 test-assets/load/ 之外的东西（环境/轮次被改写或出现新文件）" "AC-026"
  fi
fi

# AC-027 不改输入
CTX_SHA_AFTER="$(sha256sum "$CTX" 2>/dev/null | cut -d' ' -f1)"
CASES_SHA_AFTER="$(sha256sum "$FCASES" 2>/dev/null | cut -d' ' -f1)"
if [ "$CTX_SHA_BEFORE" = "$CTX_SHA_AFTER" ] && [ "$CASES_SHA_BEFORE" = "$CASES_SHA_AFTER" ]; then
  ok "PASS AC-027 输入文件跑前跑后 sha256 一致" "AC-027"
else
  bad "FAIL AC-027 输入文件被改写了" "AC-027"
fi

# AC-028 产物已存在即报错
if [ "$IMPL_MISSING" -eq 1 ]; then
  bad "FAIL AC-028 实现缺失（无产物可核）" "AC-028"
else
  if [ "$RC_EXIST1" != "0" ]; then
    bad "FAIL AC-028 第一次跑就没成功（rc=$RC_EXIST1），无法核「已存在即报错」" "AC-028"
  elif [ "$RC_EXIST2" != "1" ]; then
    bad "FAIL AC-028 产物已存在时第二次跑的退出码是 $RC_EXIST2（期望 1）" "AC-028"
  elif [ "$EXIST_BEFORE" != "$EXIST_AFTER" ]; then
    bad "FAIL AC-028 产物已存在时被覆盖了" "AC-028"
  else
    ok "PASS AC-028 产物已存在即报错（rc=1）且既有产物未被覆盖" "AC-028"
  fi
fi

# AC-029 交付侧记账
A29_OK=1; A29_MSG=""
FM_LP="$FEATURE_META/load-profile"
for f in status.md traceability.md verification-report.md manifest.json; do
  [ -s "$FM_LP/$f" ] || { A29_OK=0; A29_MSG="$A29_MSG feature-meta/load-profile/$f 缺失或为空"; }
done
if [ -s "$FM_LP/manifest.json" ]; then
  FM_REQ="$(node -e 'try{process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).req||""))}catch(e){process.stdout.write("")}' "$FM_LP/manifest.json" 2>/dev/null)"
  [ "$FM_REQ" = "REQ-009" ] || { A29_OK=0; A29_MSG="$A29_MSG feature-meta/load-profile/manifest.json 的 req 不是 REQ-009"; }
fi
if [ ! -s "$FEATURE_META/manifest.json" ]; then
  A29_OK=0; A29_MSG="$A29_MSG 根 feature-meta/manifest.json 缺失或为空"
else
  ROOT_REQ="$(node -e 'try{process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).req||""))}catch(e){process.stdout.write("")}' "$FEATURE_META/manifest.json" 2>/dev/null)"
  [ "$ROOT_REQ" = "REQ-006" ] || { A29_OK=0; A29_MSG="$A29_MSG 根 feature-meta/manifest.json 的 req 被改写成 $ROOT_REQ（应仍为 REQ-006）"; }
fi
for sub in test-report regression-plan defect-verify security-plan; do
  for f in status.md traceability.md verification-report.md manifest.json; do
    [ -s "$FEATURE_META/$sub/$f" ] || { A29_OK=0; A29_MSG="$A29_MSG feature-meta/$sub/$f 缺失或为空"; }
  done
done
# 追溯矩阵：行数 == 判据条数，编号集合 == 判据编号集合
if [ -s "$FM_LP/traceability.md" ]; then
  MATRIX="$(node -e '
    const fs=require("fs");
    const s=fs.readFileSync(process.argv[1],"utf8");
    const ids=[...s.matchAll(/AC-\d{3}/g)].map(m=>m[0]);
    const uniq=[...new Set(ids)].sort();
    process.stdout.write(uniq.join(" "));
  ' "$FM_LP/traceability.md" 2>/dev/null)"
  EXPECT_IDS="$(grep -oE '^### AC-[0-9]+' "$ACCEPTANCE" | grep -oE 'AC-[0-9]+' | sort -u | tr '\n' ' ')"
  if [ "$(norm_list "$MATRIX")" != "$(norm_list "$EXPECT_IDS")" ]; then
    A29_OK=0; A29_MSG="$A29_MSG traceability.md 的判据编号集合 != acceptance.md 的实际编号集合"
  fi
fi
# 三份 md：判据条数取值唯一、决策号取值唯一
if [ -n "$AC_COUNT" ] && [ -n "$DECISION_IDS" ]; then
  for f in status.md traceability.md verification-report.md; do
    [ -s "$FM_LP/$f" ] || continue
    NUMS="$(grep -oE '[0-9]+ 条判据|判据条数[：: ]*[0-9]+' "$FM_LP/$f" 2>/dev/null | grep -oE '[0-9]+' | sort -u | tr '\n' ' ')"
    if [ -n "$NUMS" ] && [ "$(norm_list "$NUMS")" != "$(norm_list "$AC_COUNT")" ]; then
      A29_OK=0; A29_MSG="$A29_MSG $f 的判据条数取值不唯一或不是 $AC_COUNT（实际: $NUMS）"
    fi
    # ⚠️ 决策号核对（**两道检查**，逐个字面量各算各的 —— REQ-007 的 F-01 同类漏洞）：
    #   ① 每个**范围字面量自身**展开后的集合必须 == 实际决策号集合（少报一个范围 ⇒ 判红）；
    #   ② 文件里出现的**决策号并集**（范围展开 ∪ 单独提及）必须 == 实际决策号集合；
    #   ③ 不得出现本 REQ 之外的决策号。
    #   ⚠️ ①必须**逐个字面量**判定：先把所有字面量并成一个大 set 再比，就退化成 ②，等于没加 ①
    #      （这正是 REQ-007 当年栽的坑：写 D127~D153，同文件别处补一句 D154/D155 ⇒ 并集对了 ⇒ 逃逸）。
    DN_PROBLEMS="$(node -e '
      const fs=require("fs");
      const [f, actualStr] = process.argv.slice(1);
      const actual = actualStr.trim().split(/\s+/).filter(Boolean);
      const s = fs.readFileSync(f, "utf8");
      const problems = [];
      const lits = [...s.matchAll(/D\d{2,4}~D\d{2,4}/g)].map(m=>m[0]);
      for (const l of lits) {
        const [a,b] = l.split("~");
        const x = parseInt(a.slice(1),10), y = parseInt(b.slice(1),10);
        const ids = [];
        if (Number.isFinite(x) && Number.isFinite(y) && x <= y) { for (let i=x;i<=y;i++) ids.push("D"+i); }
        else ids.push(a);
        if (ids.length !== actual.length || ids.some((v,i)=>v!==actual[i])) {
          problems.push("范围字面量 " + l + " 展开后（" + ids.length + " 个）!= 实际决策号集合（" + actual.length + " 个）");
        }
      }
      const union = new Set();
      for (const l of lits) {
        const [a,b] = l.split("~");
        const x = parseInt(a.slice(1),10), y = parseInt(b.slice(1),10);
        if (Number.isFinite(x) && Number.isFinite(y) && x <= y) { for (let i=x;i<=y;i++) union.add("D"+i); }
      }
      for (const m of s.matchAll(/\bD\d{2,4}\b/g)) union.add(m[0]);
      const us = [...union].sort();
      const as = [...actual].sort();
      if (us.length !== as.length || us.some((v,i)=>v!==as[i])) {
        problems.push("决策号并集（" + us.length + " 个）!= 实际决策号集合（" + as.length + " 个）");
      }
      for (const d of us) if (!as.includes(d)) problems.push("出现本 REQ 之外的决策号 " + d);
      process.stdout.write(problems.join("; "));
    ' "$FM_LP/$f" "$DECISION_IDS" 2>/dev/null)"
    if [ -n "$DN_PROBLEMS" ]; then
      A29_OK=0; A29_MSG="$A29_MSG $f 决策号核对不过: $DN_PROBLEMS"
    fi
  done
fi
if [ "$A29_OK" -eq 1 ]; then ok "PASS AC-029 交付侧记账与实际一致（追溯件四件套 / req / 矩阵 / 条数与决策号取值唯一）" "AC-029"
else bad "FAIL AC-029 $A29_MSG" "AC-029"; fi

# ---------------------------------------------------------------- 补齐没给结论的判据
# ⚠️ 判据编号集合**动态取** acceptance.md 的 `### AC-` 实际编号（不写死 29）

for ac in $(grep -oE '^### AC-[0-9]+' "$ACCEPTANCE" 2>/dev/null | grep -oE 'AC-[0-9]+' | sort -u); do
  [ -f "$RES_DIR/$ac.res" ] && continue
  undec "UNDEC $ac 本门没有给出该判据的结论（实现缺失或夹具不可用）" "$ac"
done

# ---------------------------------------------------------------- 变异体套件

if [ "${REQ009_NO_MUT:-0}" = "1" ]; then
  printf '\n变异体套件: 已跳过（REQ009_NO_MUT=1）—— 不可判定，不计入通过；检出率结论以完整模式为准\n'
  MUT_NOTE="跳过"
else
  step "变异体套件（正控 + 负控 M0；检测口径 = 新增失败键）"

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
    mout="$(REQ009_NO_MUT=1 QA009_SCRIPT_SHA= bash "$SELF" "$mpkg" 2>&1)"
    mf="$(printf '%s\n' "$mout" | sed 's/\x1b\[[0-9;]*m//g' | grep -E '^FAIL[[:space:]]' | grep -oE 'AC-[0-9]+' | LC_ALL=C sort -u | grep -v '^$' || true)"
    comm -13 "$WORK/base_fails.txt" <(printf '%s\n' "$mf") | tr '\n' ' ' | sed 's/ $//'
  }

  # ③ 注入包装层（shim）：原实现 move 到 make-load-profile.real.mjs，包装层跑完原实现后篡改产物
  #    $1 = 变异体包目录, $2 = 篡改代码（JavaScript；可给 MUT.pre / MUT.post 钩子）
  #    ⚠️ 包装层必须**保留原文件的权限位**（`cat >` 新建的文件会拿到 umask 默认值 644）——
  #    否则包装层自身「不可执行」，AC-001 的逐脚本判定会把每个变异体都判红，
  #    负控 M0 也会被误报成「已检出」⇒ 门自己把自己的工装当成了变异缺陷。
  #    ⚠️ 篡改未生效时**只打标记、不改退出码**（门会用同一入口脚本跑多种形态）。
  inject_shim() {
    local mpkg="$1" code="$2"
    local entry="$mpkg/skills/load-profile/scripts/make-load-profile.mjs"
    local mode; mode="$(stat -c '%a' "$entry" 2>/dev/null || echo 755)"
    mv "$entry" "$mpkg/skills/load-profile/scripts/make-load-profile.real.mjs" 2>/dev/null || return 1
    cat > "$entry" <<SHIMEOF
#!/usr/bin/env node
// 变异体包装层（仅存在于变异副本里）：先跑原实现，再对产物做一处语义篡改。
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const real = path.join(here, 'make-load-profile.real.mjs');
const args = process.argv.slice(2);
const MUT = { pre: null, post: null };
const readJson = (f) => JSON.parse(fs.readFileSync(f, 'utf8'));
const writeJson = (f, v) => fs.writeFileSync(f, JSON.stringify(v, null, 2) + '\n');
const argOf = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : null; };
const outDir = argOf('--out-dir') || '';
const loadDir = path.join(outDir, 'test-assets', 'load');
const pkgRoot = path.resolve(here, '..', '..', '..');
const ctxArg = argOf('--context');
const scenDir = path.join(loadDir, 'scenarios');
const suitesDir = path.join(loadDir, 'suites');
const listScen = () => { try { return fs.readdirSync(scenDir).filter(n => n.endsWith('.json')).sort(); } catch { return []; } };
const listSuites = () => { try { return fs.readdirSync(suitesDir).filter(n => { try { return fs.statSync(path.join(suitesDir, n)).isDirectory(); } catch { return false; } }).sort(); } catch { return []; } };

try {
${code}
} catch (e) {
  // ⚠️ 篡改代码本身出错：只打标记，**不改退出码**
  console.error('[mutant] 篡改代码异常（已忽略，不改退出码）: ' + (e && e.message ? e.message : String(e)));
}

if (MUT.pre) {
  try { MUT.pre(); } catch (e) { console.error('[mutant] pre 钩子异常: ' + (e && e.message ? e.message : String(e))); }
}

const run = spawnSync(process.execPath, [real, ...args], { stdio: 'inherit' });
const rc = run.status === null ? 1 : run.status;

if (rc === 0 && MUT.post) {
  try { MUT.post(); } catch (e) { console.error('[mutant] post 钩子异常: ' + (e && e.message ? e.message : String(e))); }
}
process.exit(rc);
SHIMEOF
    chmod "$mode" "$entry" 2>/dev/null || true
    return 0
  }

  MUT_NAMES=(
    "场景模型顶层多一个字段"
    "枚举越界：tool.runner 改成非法值"
    "无来源却声称有来源并拍出阈值"
    "阈值数值被改（凭空改阈值）"
    "场景文件名不合命名约定"
    "多出一个场景模型"
    "套件目录名编号不是三位"
    "executor 被改成 api（误配对）"
    "suite.json 多出 load_scenario 字段"
    "case_refs 里塞不存在的用例 id"
    "引用件漏掉一个场景引用"
    "环境文件里出现 driver 字段"
    "场景里出现 status: passed"
    "无来源场景的未决问题被清空"
    "无对应用例场景的未决问题被清空"
    "输入文件被改写"
    "每次跑给未决问题追加序号（破坏幂等）"
    "跑前把已有产物移走（模拟漏检「已存在」）"
    "环境文件被改写（写了不该写的目录）"
    "skill-meta.json 被删掉"
    "skill-meta.json 的 requires 多出 test-execute"
    "README 里的 load-profile 被删掉"
    "cases_file 指向不存在的文件"
    "suite 字段与目录名不一致"
    "suite.json 缺必填字段（让上游加载层抛错）"
    "feature-meta/load-profile/traceability.md 被删掉"
    "删掉一个套件目录（留下孤儿场景）"
  )
  MUT_CODE=(
    "MUT.post = () => { for (const n of listScen()) { const f = path.join(scenDir, n); const t = readJson(f); t.note = 'mutant'; writeJson(f, t); } };"
    "MUT.post = () => { for (const n of listScen()) { const f = path.join(scenDir, n); const t = readJson(f); if (t.tool) { t.tool.runner = 'jmeter'; writeJson(f, t); } } };"
    "MUT.post = () => { for (const n of listScen()) { const f = path.join(scenDir, n); const t = readJson(f); if (t.thresholds_status === 'not_provided') { t.thresholds_status = 'provided'; t.thresholds = { p95_latency_ms: 100 }; t.thresholds_source = '凭空造的来源'; writeJson(f, t); } } };"
    "MUT.post = () => { for (const n of listScen()) { const f = path.join(scenDir, n); const t = readJson(f); if (t.thresholds && typeof t.thresholds.p95_latency_ms === 'number') { t.thresholds.p95_latency_ms = 500; writeJson(f, t); } } };"
    "MUT.post = () => { const names = listScen(); for (const n of names) { if (!n.startsWith('checkout.')) continue; const oldP = path.join(scenDir, n); const newN = 'checkout_v2.json'; const newP = path.join(scenDir, newN); try { fs.renameSync(oldP, newP); } catch (e) { continue; } for (const sd of listSuites()) { const rf = path.join(suitesDir, sd, 'scenario.json'); if (!fs.existsSync(rf)) continue; const rd = readJson(rf); if (!Array.isArray(rd.scenarios)) continue; let ch = false; for (const r of rd.scenarios) { if (typeof r.path === 'string' && r.path.endsWith('scenarios/' + n)) { r.path = r.path.replace('scenarios/' + n, 'scenarios/' + newN); ch = true; } } if (ch) writeJson(rf, rd); } } };"
    "MUT.post = () => { const names = listScen(); if (!names.length) return; const src = path.join(scenDir, names[0]); const dst = path.join(scenDir, 'zzz.json'); try { fs.copyFileSync(src, dst); } catch (e) {} };"
    "MUT.post = () => { for (const sd of listSuites()) { const dir = path.join(suitesDir, sd); const sf = path.join(dir, 'suite.json'); if (!fs.existsSync(sf)) continue; const s = readJson(sf); const nn = sd.replace(/^LOAD-(\d{3})/, 'LOAD-\$1'.replace('\$1', '1')); try { fs.renameSync(dir, path.join(suitesDir, nn)); const nf = path.join(suitesDir, nn, 'suite.json'); const s2 = readJson(nf); s2.suite = nn; writeJson(nf, s2); } catch (e) {} break; } };"
    "MUT.post = () => { for (const sd of listSuites()) { const sf = path.join(suitesDir, sd, 'suite.json'); if (!fs.existsSync(sf)) continue; const s = readJson(sf); s.executor = 'api'; writeJson(sf, s); } };"
    "MUT.post = () => { for (const sd of listSuites()) { const sf = path.join(suitesDir, sd, 'suite.json'); if (!fs.existsSync(sf)) continue; const s = readJson(sf); s.load_scenario = 'scenarios/checkout.json'; writeJson(sf, s); } };"
    "MUT.post = () => { for (const n of listScen()) { const f = path.join(scenDir, n); const t = readJson(f); if (t.traceability && Array.isArray(t.traceability.case_refs)) { t.traceability.case_refs = ['TC-999']; writeJson(f, t); } } };"
    "MUT.post = () => { for (const sd of listSuites()) { const rf = path.join(suitesDir, sd, 'scenario.json'); if (!fs.existsSync(rf)) continue; const r = readJson(rf); if (Array.isArray(r.scenarios) && r.scenarios.length > 1) { r.scenarios = r.scenarios.slice(0, r.scenarios.length - 1); writeJson(rf, r); } } };"
    "MUT.post = () => { const ef = path.join(outDir, 'test-assets', 'environments', 'local.json'); if (!fs.existsSync(ef)) return; const e = readJson(ef); e.driver = 'api'; writeJson(ef, e); };"
    "MUT.post = () => { for (const n of listScen()) { const f = path.join(scenDir, n); const t = readJson(f); t.status = 'passed'; writeJson(f, t); } };"
    "MUT.post = () => { for (const n of listScen()) { const f = path.join(scenDir, n); const t = readJson(f); if (t.thresholds_status === 'not_provided') { t.open_questions = []; writeJson(f, t); } } };"
    "MUT.post = () => { for (const n of listScen()) { const f = path.join(scenDir, n); const t = readJson(f); const tr = t.traceability; if (tr && Array.isArray(tr.case_refs) && tr.case_refs.length === 0) { t.open_questions = []; writeJson(f, t); } } };"
    "MUT.post = () => { if (ctxArg && fs.existsSync(ctxArg)) { const c = readJson(ctxArg); fs.writeFileSync(ctxArg, JSON.stringify(c, null, 2) + ' '); } };"
    "MUT.post = () => { const seqFile = path.join(path.dirname(outDir), '.mutseq'); let n = 0; try { n = parseInt(fs.readFileSync(seqFile, 'utf8'), 10) || 0; } catch (e) {} n += 1; try { fs.writeFileSync(seqFile, String(n)); } catch (e) {} for (const s of listScen()) { const f = path.join(scenDir, s); const t = readJson(f); if (Array.isArray(t.open_questions) && t.open_questions.length > 0 && t.open_questions[0] && typeof t.open_questions[0].question === 'string') { t.open_questions[0].question = t.open_questions[0].question + ' #' + n; writeJson(f, t); } } };"
    "MUT.pre = () => { if (fs.existsSync(loadDir) && fs.readdirSync(loadDir).length > 0) { try { fs.renameSync(loadDir, path.join(path.dirname(outDir), '.mut-moved-load')); } catch (e) {} } };"
    "MUT.post = () => { const ef = path.join(outDir, 'test-assets', 'environments', 'local.json'); if (!fs.existsSync(ef)) return; const e = readJson(ef); e.timeout_ms = 9999; writeJson(ef, e); };"
    "MUT.post = () => { try { fs.unlinkSync(path.join(pkgRoot, 'skills', 'load-profile', 'skill-meta.json')); } catch (e) {} };"
    "MUT.post = () => { const f = path.join(pkgRoot, 'skills', 'load-profile', 'skill-meta.json'); if (!fs.existsSync(f)) return; const m = readJson(f); m.requires = Object.assign({}, m.requires, { 'test-execute': '>=0.1.0' }); writeJson(f, m); };"
    "MUT.post = () => { const f = path.join(pkgRoot, 'README.md'); if (!fs.existsSync(f)) return; const s = fs.readFileSync(f, 'utf8').split(/\\r?\\n/).filter(l => !l.includes('load-profile')).join('\\n'); fs.writeFileSync(f, s); };"
    "MUT.post = () => { for (const sd of listSuites()) { const sf = path.join(suitesDir, sd, 'suite.json'); if (!fs.existsSync(sf)) continue; const s = readJson(sf); s.cases_file = 'nonexistent.json'; writeJson(sf, s); } };"
    "MUT.post = () => { for (const sd of listSuites()) { const sf = path.join(suitesDir, sd, 'suite.json'); if (!fs.existsSync(sf)) continue; const s = readJson(sf); s.suite = sd + '-wrong'; writeJson(sf, s); } };"
    "MUT.post = () => { for (const sd of listSuites()) { const sf = path.join(suitesDir, sd, 'suite.json'); if (!fs.existsSync(sf)) continue; const s = readJson(sf); delete s.requirement; writeJson(sf, s); } };"
    "MUT.post = () => { try { fs.unlinkSync(path.join(pkgRoot, 'feature-meta', 'load-profile', 'traceability.md')); } catch (e) {} };"
    "MUT.post = () => { const sds = listSuites(); if (sds.length < 2) return; try { fs.rmSync(path.join(suitesDir, sds[sds.length - 1]), { recursive: true, force: true }); } catch (e) {} };"
  )
  MUT_TARGETS=(
    "AC-009"
    "AC-008"
    "AC-011"
    "AC-010"
    "AC-012"
    "AC-013"
    "AC-015"
    "AC-016"
    "AC-016"
    "AC-024"
    "AC-017"
    "AC-020"
    "AC-022"
    "AC-021"
    "AC-023"
    "AC-027"
    "AC-025"
    "AC-028"
    "AC-026"
    "AC-001"
    "AC-002"
    "AC-003"
    "AC-004"
    "AC-004"
    "AC-018"
    "AC-029"
    "AC-019"
  )
  # 自证/注入模式（与 MUT_NAMES / MUT_CODE / MUT_TARGETS **逐条对齐**）：
  #   fp    —— 入口脚本包装层 + 「可观测状态」组合指纹自证（产物型正控）
  #   twice —— 包装层 + **第二次**跑同一 out-dir 的退出码自证（AC-028 那一类）
  #   file  —— **先改副本再跑门**：直接改被验包副本里的静态文件（包装层碰不到静态文件）
  MUT_MODE=(
    "fp"      # 01 场景模型顶层多一个字段
    "fp"      # 02 枚举越界：tool.runner
    "fp"      # 03 无来源却声称有来源
    "fp"      # 04 阈值数值被改
    "fp"      # 05 场景文件名不合约定
    "fp"      # 06 多出一个场景模型
    "fp"      # 07 套件目录名编号不是三位
    "fp"      # 08 executor 改成 api
    "fp"      # 09 suite.json 多出 load_scenario
    "fp"      # 10 case_refs 塞不存在的 id
    "fp"      # 11 引用件漏掉一个场景引用
    "fp"      # 12 环境文件里出现 driver
    "fp"      # 13 场景里出现 status: passed
    "fp"      # 14 无来源场景的未决问题被清空
    "fp"      # 15 无对应用例场景的未决问题被清空
    "fp"      # 16 输入文件被改写
    "fp"      # 17 追加序号（破坏幂等）
    "twice"   # 18 跑前把已有产物移走
    "fp"      # 19 环境文件被改写
    "file"    # 20 skill-meta.json 被删掉
    "file"    # 21 requires 多出 test-execute
    "file"    # 22 README 里的 load-profile 被删掉
    "fp"      # 23 cases_file 指向不存在的文件
    "fp"      # 24 suite 字段与目录名不一致
    "fp"      # 25 suite.json 缺必填字段
    "file"    # 26 traceability.md 被删掉
    "fp"      # 27 删掉一个套件目录
  )
  # 静态文件型正控的改法（只在 MODE=file 时用；其余留空串）
  MUT_FILE=(
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    "fs.unlinkSync(path.join(pkgRoot, 'skills', 'load-profile', 'skill-meta.json'));"
    "const _f = path.join(pkgRoot, 'skills', 'load-profile', 'skill-meta.json'); const _m = JSON.parse(fs.readFileSync(_f, 'utf8')); _m.requires = Object.assign({}, _m.requires, { 'test-execute': '>=0.1.0' }); fs.writeFileSync(_f, JSON.stringify(_m, null, 2) + String.fromCharCode(10));"
    "const _f = path.join(pkgRoot, 'README.md'); fs.writeFileSync(_f, fs.readFileSync(_f, 'utf8').split(/\r?\n/).filter((l) => !l.includes('load-profile')).join(String.fromCharCode(10)));"
    ""
    ""
    ""
    "fs.unlinkSync(path.join(pkgRoot, 'feature-meta', 'load-profile', 'traceability.md'));"
    ""
  )
  MUT_REQUIRED=6

  # ⚠️ **数组长度自检**（门侧自洽）：三个数组（名字 / 篡改代码 / 目标判据）+ 模式数组必须**逐条对齐**。
  #    长度不一致 ⇒ 明确报红并退出，**不许**让 bash 崩在数组下标上（崩了后面什么都测不到）。
  MUT_N="${#MUT_NAMES[@]}"; MUT_C="${#MUT_CODE[@]}"; MUT_T="${#MUT_TARGETS[@]}"; MUT_M="${#MUT_MODE[@]}"
  if [ "$MUT_N" -ne "$MUT_C" ] || [ "$MUT_N" -ne "$MUT_T" ] || [ "$MUT_N" -ne "$MUT_M" ]; then
    printf 'FAIL GATE-MUT —— 门侧变异体定义不自洽：MUT_NAMES=%s MUT_CODE=%s MUT_TARGETS=%s MUT_MODE=%s\n' "$MUT_N" "$MUT_C" "$MUT_T" "$MUT_M"
    MUT_UNDEC=1
    MUT_NOTE="不可判定：门侧变异体数组长度不一致（门侧缺陷，不是被验实现的问题）"
    MUT_INVALID="[门侧缺陷: 变异体数组长度不一致]"
  else
  for i in "${!MUT_NAMES[@]}"; do
    NAME="${MUT_NAMES[$i]}"
    TARGET="${MUT_TARGETS[$i]}"
    CODE="${MUT_CODE[$i]}"
    MODE="${MUT_MODE[$i]}"
    MUTPKG="$WORK/mut-$i"
    mkdir -p "$MUTPKG"
    cp -r "$PKG"/. "$MUTPKG"/ 2>/dev/null
    STATUS="有效"
    if [ ! -f "$MUTPKG/$ENTRY_REL" ]; then
      STATUS="**实现缺失**：$ENTRY_REL 不存在 —— 变异体无法注入；这是实现未交付，不是门侧问题"
      MUT_MISSING_IMPL=1
    fi
    # 每个变异体用**自己的输入副本** ⇒ 篡改输入文件的正控不会污染门自己的夹具
    MUTCTX="$WORK/mutinput-$i/context.json"
    MUTCASES="$WORK/mutinput-$i/cases.json"
    mkdir -p "$WORK/mutinput-$i"
    cp "$CTX" "$MUTCTX" 2>/dev/null
    cp "$FCASES" "$MUTCASES" 2>/dev/null
    if [ "$MODE" = "file" ]; then
      # 静态文件型正控：**先改副本，再跑门**（不靠入口包装层 —— 包装层碰不到被验包的静态文件）
      FILE_CODE="${MUT_FILE[$i]}"
      if [ "$STATUS" = "有效" ]; then
        node -e "
          const fs = require('fs');
          const path = require('path');
          const pkgRoot = process.argv[1];
          const outDir = process.argv[2];
          const ctxArg = process.argv[3];
          const loadDir = path.join(outDir, 'test-assets', 'load');
          try { $FILE_CODE } catch (e) { console.error('[mutant] 文件篡改失败: ' + e.message); process.exit(3); }
        " "$MUTPKG" "$WORK/mutproj-$i" "$MUTCTX" >/dev/null 2>&1 || STATUS="静态文件篡改失败"
      fi
    elif [ "$STATUS" = "有效" ]; then
      HITS="$(node "$WORK/pkgfiles.mjs" "$MUTPKG" "$ENTRY_REL" 2>/dev/null)"
      if [ "${HITS:-0}" -ne 1 ]; then
        STATUS="门侧锚点不可达：入口锚点命中 $HITS 次，要求恰好 1 次"
      fi
    fi
    if [ "$STATUS" = "有效" ] && [ "$MODE" != "file" ]; then
      BEFORE_SHA="$(sha256sum "$MUTPKG/$ENTRY_REL" 2>/dev/null | cut -d' ' -f1)"
      inject_shim "$MUTPKG" "$CODE" || STATUS="包装层注入失败"
      AFTER_SHA="$(sha256sum "$MUTPKG/$ENTRY_REL" 2>/dev/null | cut -d' ' -f1)"
      if [ "$STATUS" = "有效" ]; then
        if [ -z "$BEFORE_SHA" ] || [ "$BEFORE_SHA" = "$AFTER_SHA" ]; then
          STATUS="注入前后 sha256 没变（注入未生效）"
        fi
      fi
      if [ "$STATUS" = "有效" ]; then
        node --check "$MUTPKG/$ENTRY_REL" >/dev/null 2>&1 || STATUS="变异后 node --check 不通过"
      fi
    fi
    if [ "$STATUS" = "有效" ]; then
      MUTPROJ="$WORK/mutproj-$i"
      mkdir -p "$MUTPROJ"
      cp -r "$FX/proj/." "$MUTPROJ/" 2>/dev/null
      node "$MUTPKG/$ENTRY_REL" --context "$MUTCTX" --cases "$MUTCASES" --out-dir "$MUTPROJ" >/dev/null 2>&1
      MRC=$?
      if [ "$MRC" -ne 0 ]; then
        STATUS="变异后脚本没正常跑完：rc=$MRC —— 崩溃造成的判红是假检出"
      elif [ ! -d "$MUTPROJ/test-assets/load" ]; then
        STATUS="变异后没有产物"
      fi
    fi
    # 自证：篡改真的生效
    #   模式 fp    —— 「可观测状态」的组合指纹（产物树 / 环境 / 输入 / 记账件）必须与基线不同
    #   模式 twice —— 该变异的效果体现在**第二次**跑同一 out-dir 的退出码上
    #   模式 file  —— 静态文件已改在副本上；指纹同样要比（证明改到位了）
    if [ "$STATUS" = "有效" ]; then
      if [ "$MODE" = "twice" ]; then
        node "$MUTPKG/$ENTRY_REL" --context "$MUTCTX" --cases "$MUTCASES" --out-dir "$MUTPROJ" >/dev/null 2>&1
        MRC2=$?
        if [ "$MRC2" -eq 0 ]; then
          : # 第二次跑居然成功了 ⇒ 变异生效（漏检「产物已存在」的行为被暴露出来）
        else
          STATUS="第二次跑仍然报错（rc=$MRC2）—— 该变异对这份实现无效"
        fi
      else
        MUTFP="$(node "$WORK/mutfp.mjs" "$MUTPKG" "$MUTPROJ" "$MUTCTX" "$MUTCASES" 2>/dev/null)"
        BASEFP="$(node "$WORK/mutfp.mjs" "$PKG" "$PROJ_MAIN" "$CTX" "$FCASES" 2>/dev/null)"
        if [ -z "$MUTFP" ] || [ "$MUTFP" = "$BASEFP" ]; then
          STATUS="篡改未生效（可观测状态与基线完全相同）—— 该变异对这份实现无效"
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
  fi

  # ④ 负控 M0：打不到任何判据的**无害**篡改 —— 期望「未检出」。
  #    ⚠️ 无害篡改固定不变（两次跑结果相同）⇒ 不破坏幂等；只动 open_questions 的文字。
  CTRL_NAME="负控 M0：给未决问题的文字追加一段固定无害说明"
  CTRLPKG="$WORK/mut-control"
  mkdir -p "$CTRLPKG"
  cp -r "$PKG"/. "$CTRLPKG"/ 2>/dev/null
  CTRL_STATUS="有效"
  if [ ! -f "$CTRLPKG/$ENTRY_REL" ]; then
    CTRL_STATUS="**实现缺失**：$ENTRY_REL 不存在 —— 变异体无法注入；这是实现未交付，不是门侧问题"
    MUT_MISSING_IMPL=1
  else
    inject_shim "$CTRLPKG" "MUT.post = () => { for (const n of listScen()) { const f = path.join(scenDir, n); const t = readJson(f); if (Array.isArray(t.open_questions) && t.open_questions.length > 0 && t.open_questions[0] && typeof t.open_questions[0].question === 'string') { t.open_questions[0].question = t.open_questions[0].question + '（无害标注 gate-control）'; writeJson(f, t); } } };" || CTRL_STATUS="包装层注入失败"
  fi
  if [ "$CTRL_STATUS" = "有效" ]; then
    node --check "$CTRLPKG/$ENTRY_REL" >/dev/null 2>&1 || CTRL_STATUS="变异后 node --check 不通过"
  fi
  if [ "$CTRL_STATUS" = "有效" ]; then
    CTRLPROJ="$WORK/ctrlproj"
    mkdir -p "$CTRLPROJ"
    cp -r "$FX/proj/." "$CTRLPROJ/" 2>/dev/null
    node "$CTRLPKG/$ENTRY_REL" --context "$CTX" --cases "$FCASES" --out-dir "$CTRLPROJ" >/dev/null 2>&1
    CRC=$?
    if [ "$CRC" -ne 0 ]; then
      CTRL_STATUS="变异后脚本没正常跑完：rc=$CRC"
    else
      # 负控也要**自证篡改真的落下了**（否则「未检出」是因为压根没改，不是因为无害）
      CTRLFP="$(node "$WORK/mutfp.mjs" "$CTRLPKG" "$CTRLPROJ" "$CTX" "$FCASES" 2>/dev/null)"
      BASEFP="$(node "$WORK/mutfp.mjs" "$PKG" "$PROJ_MAIN" "$CTX" "$FCASES" 2>/dev/null)"
      if [ -z "$CTRLFP" ] || [ "$CTRLFP" = "$BASEFP" ]; then
        CTRL_STATUS="无害篡改没生效 —— 负控无效（探测器的灵敏度不可判定）"
      fi
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
      printf '负控 %s: 被报成「已检出」（新增失败键=[%CTRL_NEW]）—— 门侧缺陷：探测器恒真\n' "$CTRL_NAME" "$CTRL_NEW"
    fi
  fi

  # ⑤ 结论（责任方要指对）
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

printf '\n———— 逐条结论 ————\n'
for f in $(ls "$RES_DIR"/*.res 2>/dev/null | LC_ALL=C sort); do
  cat "$f"
done

printf '\n结论: %s PASS / %s FAIL\n' "$PASS" "$FAIL"
if [ "$UNDEC" -gt 0 ]; then
  printf '不可判定: %s 条\n' "$UNDEC"
fi
printf '验收脚本 sha256: %s\n' "$(sha256sum "$SELF" 2>/dev/null | cut -d' ' -f1)"
printf '被验实现指纹（skills/load-profile/）: %s\n' "$(node "$WORK/pkgfiles.mjs" "$TR" '__fingerprint__' >/dev/null 2>&1; find "$TR" -type f 2>/dev/null | LC_ALL=C sort | xargs sha256sum 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1)"
printf '实现侧追溯范围（动态取 decisions.md）: %s 条 [%s]\n' "$DECISION_COUNT" "$DECISION_IDS"
printf '判据条数（动态取 acceptance.md）: %s\n' "$AC_COUNT"
if [ "$MUT_NOTE" = "跳过" ]; then
  printf '变异体套件: 已跳过（REQ009_NO_MUT=1）—— 不可判定，检出率结论以完整模式为准\n'
elif [ -n "$MUT_ESCAPED" ]; then
  printf '变异体套件: %s —— 有变异体逃逸（真缺陷），整体判红\n' "$MUT_NOTE"
elif [ -n "$MUT_CONTROL_FAILED" ]; then
  printf '变异体套件: %s\n' "$MUT_NOTE"
  printf '负控失败：探测器疑似恒真 ⇒ 本门失效（门侧缺陷）—— %s\n' "$MUT_CONTROL_FAILED"
elif [ "$MUT_UNDEC" -eq 1 ]; then
  printf '不可判定: 1 项（变异体套件）—— %s\n' "$MUT_NOTE"
  if [ "$MUT_MISSING_IMPL" -eq 1 ]; then
    printf '  （这是**实现未交付**，不是门侧问题：变异体需要 `%s` 才能注入。退出码为 1，判据结论仍以上面的 PASS/FAIL 为准）\n' "$ENTRY_REL"
  else
    printf '  （这是**门侧注入问题**，不是被验实现的缺陷；退出码为 1，判据结论仍以上面的 PASS/FAIL 为准）\n'
  fi
fi

# ---------------------------------------------------------------- 门自身 stderr 自检

BASH_ERR_LINES="$(grep -cE '行 [0-9]+:|line [0-9]+:|未绑定的变量|unbound variable' "$STDERR_LOG" 2>/dev/null || true)"
BASH_ERR_LINES="$(printf '%s' "${BASH_ERR_LINES:-0}" | tr -dc '0-9')"
[ -n "$BASH_ERR_LINES" ] || BASH_ERR_LINES=0
# 原样回放 stderr（门不该吞掉自己的输出）
cat "$STDERR_LOG" >&2
printf '门自身 stderr 的 bash 错误行: %s\n' "$BASH_ERR_LINES"

# 退出条件：
#   - 逃逸（MUT_ESCAPED）      ⇒ 判红（真缺陷）
#   - 负控失败（MUT_CONTROL_FAILED） ⇒ 判红（门侧缺陷：探测器恒真）
#   - 不可判定（MUT_UNDEC）     ⇒ 退出码非 0，但不判红也不判绿（门侧注入问题）
#   - 有效变异体必须全部检出（MUT_DETECTED == MUT_TOTAL）且数量达标（MUT_TOTAL >= MUT_REQUIRED）
#   - **门自身 stderr 有 bash 错误** ⇒ 门不干净 ⇒ 判定不可信 ⇒ 退出码非 0
if [ "$BASH_ERR_LINES" -gt 0 ]; then
  printf 'FAIL GATE-STDERR —— 门自身在执行过程中产生了 %s 行 bash 错误（见 stderr）—— 判定不可信\n' "$BASH_ERR_LINES"
  exit 1
fi
if [ "$FAIL" -eq 0 ] && [ "$UNDEC" -eq 0 ] && [ -z "$MUT_ESCAPED" ] && [ -z "$MUT_CONTROL_FAILED" ] \
   && { [ "${REQ009_NO_MUT:-0}" = "1" ] || { [ "$MUT_UNDEC" -eq 0 ] \
        && [ "$MUT_TOTAL" -ge "$MUT_REQUIRED" ] && [ "$MUT_DETECTED" -eq "$MUT_TOTAL" ] \
        && [ "$MUT_CONTROL_OK" -eq 1 ]; }; }; then
  exit 0
fi
exit 1
