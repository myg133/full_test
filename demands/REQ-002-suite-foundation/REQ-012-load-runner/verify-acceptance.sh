#!/usr/bin/env bash
# REQ-012 验收脚本 —— `load-profile` skill 的 runner 适配（负载模型 → 压测计划，**零请求**）
#
# 判据集：AC-001~AC-029（条数从 acceptance.md 的 `### AC-` 实际条数动态取，**不写死**）
# 决策号：从 decisions.md 的 `^## D[0-9]+` **标题行**实际集合动态取（**不写死**）
#   ⚠️ **绝不可**用全文 `grep -oE 'D[0-9]+'` —— decisions.md 正文引用了 REQ-009 的 D127~D155
#      （正常溯源）⇒ 全文抓会得到 33 个，与实际 29 条不符 ⇒ **门自己判红**。
#
# 用法: verify-acceptance.sh <package-dir>
#   <package-dir> 指向**被验包根目录**（含 skills/ 与 bin/，以及 feature-meta/、README.md）
#
# 退出码: 0 = 全部通过; 1 = 有 AC 未通过 / 不可判定 / 变异体有逃逸 / 负控失败 / sha 不符 /
#               门自身 stderr 有 bash 错误 / 门写了被验包; 2 = 用法错误
#
# 环境变量:
#   REQ012_NO_MUT=1       跳过变异体套件（快跑 / 嵌套运行用）
#   REQ012_SKIP_SIBLING=1 跳过「其它同级门」扫描（**只给变异体探测跑用**：探测口径只看失败键）
#   QA012_SCRIPT_SHA      期望的**本脚本自身** sha256；不匹配即判红并中止
#   QA012_KEEP_WORK=1     保留工作目录（调试）
#   QA012_WORK_ROOT       工作目录的父目录（默认 ${TMPDIR:-/tmp}）
#
# 设计要点（门是被验对象，不是脚手架 —— D65）:
#   - 只读被验包；一切变异都在**副本**上做，绝不在原地改被验对象（跑前跑后全树指纹比对）。
#   - 夹具（负载模型 / 套件 / 环境 / 非法变体 / 尾斜杠环境变体 / 两个桩服务）一律造在临时目录里。
#   - 产物侧判据用**独立复算器**（内嵌 judge.mjs）：自己重算「模型 → argv」的映射口径，
#     **绝不 import 被验包**；自带独立的解析 / 集合运算 / 枚举实现。
#   - 上游 `verify-layout.mjs`、REQ-009 的验收门、组合门都是**单独进程实跑**，拿**真实退出码**。
#   - 变异检出走**新增失败键**（变异运行的失败键 减去 基线失败键，整行精确排除）；
#     **不用**对称差：对称差把「基线红、变异后绿」也算成变化，那是噪声不是检出。
#   - ⚠️ **基线失败键只取 `^FAIL` 行** —— PASS / UNDEC 行里也有 AC 编号，混进来会让基线键
#     集合变成**全集**，此后任何变异的「新增失败键」都恒等于全集 ⇒ 整套检测沦为橡皮章。
#   - 崩溃造成的判红是假检出，不计入检出率（结构合法性单独自证）。
#   - 变异体套件里有一个**负控**（打乱计划 JSON 的键序 —— 内容逐字不变）：它必须**未检出**。
#     若负控也被报成「已检出」⇒ 探测器恒真 ⇒ 本门失效（门侧缺陷，判红，退出码非 0）。
#   - 有效变异体不足 20 个 ⇒ **不可判定**（门侧注入问题），退出码非 0，但不算被验实现的失败。
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
SIBLING_DIR="$(cd "$SELF_DIR/.." && pwd)"

# ---------------------------------------------------------------- 判据条数（动态取）

AC_COUNT=0
if [ -f "$ACCEPTANCE" ]; then
  AC_COUNT="$(grep -cE '^### AC-[0-9]+' "$ACCEPTANCE" || true)"
fi

# ---------------------------------------------------------------- 决策号集合（动态取 —— 只认标题行）

DECISION_IDS=""
DECISION_COUNT=0
DECISION_MIN=""
DECISION_MAX=""
if [ -f "$DECISIONS" ]; then
  # ⚠️ **只按 `^## D[0-9]+` 标题行取** —— 正文里对 REQ-009（D127~D155）的引用**不是**本 REQ 的决策
  DECISION_RAW="$(grep -oE '^## D[0-9]+' "$DECISIONS" | sed 's/^## //' | sort -u || true)"
  DECISION_COUNT="$(printf '%s\n' $DECISION_RAW | grep -v '^$' | wc -l | tr -d ' ')"
  # ⚠️ 必须按**数值**排序（`sort -u` 是字典序，会把 D100 排在 D98 前面）
  DECISION_IDS="$(printf '%s\n' $DECISION_RAW | sort -t'D' -k2,2n | tr '\n' ' ' | sed 's/ $//')"
  DECISION_MIN="$(printf '%s\n' $DECISION_RAW | sort -t'D' -k2,2n | head -1)"
  DECISION_MAX="$(printf '%s\n' $DECISION_RAW | sort -t'D' -k2,2n | tail -1)"
fi

# ---------------------------------------------------------------- 门禁前置：脚本自身指纹

if [ -n "${QA012_SCRIPT_SHA:-}" ]; then
  SELF_SHA="$(sha256sum "$SELF" 2>/dev/null | cut -d' ' -f1)"
  if [ "$SELF_SHA" != "${QA012_SCRIPT_SHA:-}" ]; then
    printf 'FAIL GATE-SHA —— 验收脚本 sha256 不匹配（期望 %s，实际 %s）\n' "${QA012_SCRIPT_SHA:-}" "$SELF_SHA"
    printf '\n结论: 0 PASS / 1 FAIL\n'
    printf '验收脚本 sha256: %s\n' "$SELF_SHA"
    exit 1
  fi
fi

# ---------------------------------------------------------------- 工作目录

WORK_PARENT="${QA012_WORK_ROOT:-${TMPDIR:-/tmp}}"
mkdir -p "$WORK_PARENT" 2>/dev/null || true
WORK="$(mktemp -d "$WORK_PARENT/qa-012-XXXXXX")" || { echo "无法创建工作目录" >&2; exit 2; }
cleanup() {
  if [ "${QA012_KEEP_WORK:-0}" = "1" ]; then
    printf '工作目录已保留: %s\n' "$WORK" >&2
    return
  fi
  # ⚠️ 本机 rm 是 shim（可恢复删除）：清理失败**不得**改变判定
  mv "$WORK" "${WORK}.done.$$" 2>/dev/null || true
}
trap cleanup EXIT

RES_DIR="$WORK/res"
mkdir -p "$RES_DIR"

# ⚠️ 门自身的 stderr 全量留痕（可观测证据）：跑完之后检查有没有 bash 错误行
#    （`行 N:` / `line N:` 是 bash 自己的报错前缀）⇒ 有 ⇒ 门不干净 ⇒ 判定不可信 ⇒ 判红退出。
STDERR_LOG="$WORK/stderr.log"
exec 2>"$STDERR_LOG"

# ---------------------------------------------------------------- 计数器与记分

PASS=0
FAIL=0
UNDEC=0
GATE_READONLY_BROKEN=0
MUT_TOTAL=0
MUT_DETECTED=0
MUT_ESCAPED=""
MUT_INVALID=""
MUT_NOTE=""
MUT_UNDEC=0
MUT_CONTROL_OK=0
MUT_MISSING_IMPL=0
MUT_CONTROL_FAILED=""

clean_msg() { printf '%s' "${1:-}" | tr '\t\r\n' '   '; }
ok()   { PASS=$((PASS+1));   M="$(clean_msg "${2:-}")"; printf 'PASS %s %s\n' "$1" "$M" > "$RES_DIR/$1.res"; printf 'PASS %s %s\n' "$1" "$M"; }
bad()  { FAIL=$((FAIL+1));   M="$(clean_msg "${2:-}")"; printf 'FAIL %s %s\n' "$1" "$M" > "$RES_DIR/$1.res"; printf 'FAIL %s %s\n' "$1" "$M"; }
undec(){ UNDEC=$((UNDEC+1)); M="$(clean_msg "${2:-}")"; printf 'UNDEC %s %s\n' "$1" "$M" > "$RES_DIR/$1.res"; printf 'UNDEC %s %s\n' "$1" "$M"; }
step(){ printf '\n— %s\n' "$1"; }
# ---------------------------------------------------------------- 夹具 / 复算器（内嵌 node）

cat > "$WORK/stub.mjs" <<'QA012_STUB_EOF'
// REQ-012 桩服务（零请求的可观测证据）—— 每个收到的请求追加一行到日志文件
// 用法: node stub.mjs <日志文件> <端口文件>
// ⚠️ 只用于**计数**：本 REQ 的入口不该连它；被验实现若连了 ⇒ 计数 > 0 ⇒ 判红。
import fs from 'node:fs';
import http from 'node:http';

const [log, portFile] = process.argv.slice(2);
fs.writeFileSync(log, '');
const server = http.createServer((req, res) => {
  try { fs.appendFileSync(log, `${req.method} ${req.url}\n`); } catch { /* 计数失败也不能影响判定 */ }
  res.writeHead(200, { 'content-type': 'application/json' });
  res.end('{}');
});
server.listen(0, '127.0.0.1', () => {
  fs.writeFileSync(portFile, String(server.address().port));
});
QA012_STUB_EOF

cat > "$WORK/mkfixture.mjs" <<'QA012_FIX_EOF'
// 夹具生成器（REQ-012）—— 负载模型 / 套件 / 环境 / 最小项目根 / 非法变体 / 尾斜杠环境变体
// 用法: node mkfixture.mjs <FX目录> <P1端口> <P2端口>
// ⚠️ 只用 Node 内置模块；不写被验包（夹具全在临时目录）。
import fs from 'node:fs';
import path from 'node:path';

const FX = process.argv[2];
const P1 = process.argv[3];
const P2 = process.argv[4];

const writeJson = (f, obj) => {
  fs.mkdirSync(path.dirname(f), { recursive: true });
  fs.writeFileSync(f, JSON.stringify(obj, null, 2) + '\n');
};
const writeText = (f, s) => {
  fs.mkdirSync(path.dirname(f), { recursive: true });
  fs.writeFileSync(f, s);
};
const copyTree = (src, dst) => {
  fs.mkdirSync(dst, { recursive: true });
  for (const n of fs.readdirSync(src)) {
    const s = path.join(src, n);
    const d = path.join(dst, n);
    const st = fs.lstatSync(s);
    if (st.isDirectory()) copyTree(s, d);
    else if (st.isFile()) { fs.mkdirSync(path.dirname(d), { recursive: true }); fs.copyFileSync(s, d); }
  }
};

// ---------------------------------------------------------------- 负载模型本体（acceptance.md §0.3）

const models = {
  'checkout': {
    schema_version: 1,
    id: 'WL-001',
    name: 'checkout',
    service: 'order-api',
    target: 'POST /api/v1/checkout',
    environment: 'local',
    profile: { type: 'ramp-up', steps: [ { duration_s: 60, concurrency: 10 }, { duration_s: 120, concurrency: 20 } ] },
    thresholds: { p95_latency_ms: 800, error_rate: 0.01 },
    thresholds_source: '需求 REQ-005 性能指标',
    thresholds_status: 'provided',
    tool: { runner: 'loadtest', runtime: 'bun' },
    args: { rps: 100, keepalive: true, timeout_s: 10 },
    traceability: { workload_id: 'WL-001', requirement_refs: ['R-1'], case_refs: ['TC-001'] },
    open_questions: [],
  },
  'order-query': {
    schema_version: 1,
    id: 'WL-002',
    name: 'order-query',
    service: 'order-api',
    target: 'GET /api/v1/orders',
    environment: 'local',
    profile: { type: 'constant', steps: [ { duration_s: 300, concurrency: 5 } ] },
    thresholds_status: 'not_provided',
    tool: { runner: 'loadtest', runtime: 'bun' },
    traceability: { workload_id: 'WL-002', requirement_refs: ['R-2'], case_refs: ['TC-002'] },
    open_questions: [
      { id: 'OQ-001', topic: 'thresholds', question: '订单查询链路没有指标来源，未拍延迟/错误率阈值。' },
    ],
  },
  'checkout-staging': {
    schema_version: 1,
    id: 'WL-003',
    name: 'checkout-staging',
    service: 'order-api',
    target: 'POST /api/v1/checkout',
    environment: 'staging',
    profile: { type: 'spike', steps: [ { duration_s: 30, concurrency: 50 } ] },
    thresholds: { p95_latency_ms: 1200 },
    thresholds_source: '需求 REQ-007 性能指标',
    thresholds_status: 'provided',
    tool: { runner: 'python', runtime: 'python' },
    args: { command: ['python', '-m', 'mylab', '--duration', '{duration_s}', '--concurrency', '{concurrency}'] },
    traceability: { workload_id: 'WL-003', requirement_refs: ['R-1'], case_refs: ['TC-001'] },
    open_questions: [],
  },
  'health-check': {
    schema_version: 1,
    id: 'WL-004',
    name: 'health-check',
    service: 'order-api',
    target: 'GET /api/v1/health',
    environment: 'local',
    profile: { type: 'soak', steps: [ { duration_s: 600, concurrency: 2 } ] },
    thresholds: { p95_latency_ms: 200 },
    thresholds_source: '需求 REQ-008 性能指标',
    thresholds_status: 'provided',
    tool: { runner: 'loadtest', runtime: 'bun' },
    traceability: { workload_id: 'WL-004', requirement_refs: ['R-2'], case_refs: [] },
    open_questions: [
      { id: 'OQ-002', topic: 'coverage', question: '健康检查链路在功能用例集里没有对应用例。' },
    ],
  },
};

const suites = {
  'LOAD-001-checkout': {
    environment: 'local',
    scenarios: [
      { path: '../../scenarios/checkout.json', id: 'WL-001', name: 'checkout' },
      { path: '../../scenarios/order-query.json', id: 'WL-002', name: 'order-query' },
      { path: '../../scenarios/health-check.json', id: 'WL-004', name: 'health-check' },
    ],
  },
  'LOAD-002-checkout-staging': {
    environment: 'staging',
    scenarios: [
      { path: '../../scenarios/checkout-staging.json', id: 'WL-003', name: 'checkout-staging' },
    ],
  },
};

// ---------------------------------------------------------------- 最小项目根（acceptance.md §0.4）

function buildProject(root, p1, p2) {
  fs.rmSync === undefined; // 不删任何东西（夹具目录每次都是新的）
  for (const [name, m] of Object.entries(models)) {
    writeJson(path.join(root, 'test-assets/load/scenarios', `${name}.json`), m);
  }
  for (const [suite, spec] of Object.entries(suites)) {
    writeJson(path.join(root, 'test-assets/load/suites', suite, 'scenario.json'), {
      schema_version: 1,
      suite,
      scenarios: spec.scenarios,
    });
    writeJson(path.join(root, 'test-assets/load/suites', suite, 'suite.json'), {
      suite,
      requirement: 'REQ-009',
      scope: 'load',
      environment: spec.environment,
      cases_file: 'scenario.json',
      executor: 'load',
    });
  }
  writeJson(path.join(root, 'test-assets/load/report.json'), {
    schema_version: 1,
    service: 'order-api',
    suites: Object.keys(suites).map((s) => ({ suite: s, requirement: 'REQ-009', environment: suites[s].environment, scenarios: suites[s].scenarios.map((x) => ({ id: x.id, name: x.name, path: x.path })) })),
    scenarios: Object.values(models).map((m) => ({ id: m.id, name: m.name, path: `scenarios/${m.name}.json`, environment: m.environment, suite: m.environment === 'staging' ? 'LOAD-002-checkout-staging' : 'LOAD-001-checkout', thresholds_status: m.thresholds_status })),
    open_questions: [],
  });
  writeJson(path.join(root, 'test-assets/environments/_schema.json'), {
    type: 'object',
    properties: { name: { type: 'string' }, base_url: { type: 'string' } },
    required: ['name', 'base_url'],
  });
  writeJson(path.join(root, 'test-assets/environments/local.json'), {
    name: 'local', base_url: `http://127.0.0.1:${p1}`, timeout_ms: 3000, retries: 0,
    credentials: { token_env: 'TEST_TOKEN' },
  });
  writeJson(path.join(root, 'test-assets/environments/staging.json'), {
    name: 'staging', base_url: `http://127.0.0.1:${p2}`, timeout_ms: 5000, retries: 0,
    credentials: { token_env: 'TEST_TOKEN_STAGING' },
  });
  writeJson(path.join(root, 'test-assets/cycles/index.json'), {
    cycles: [ { id: 'R1-REQ-012', status: 'planned', round: 'R1' } ],
  });
  writeJson(path.join(root, 'test-assets/cycles/R1-REQ-012/cycle.json'), {
    cycle_id: 'R1-REQ-012', requirement: 'REQ-012', status: 'planned', round: 'R1',
    round_type: 'new-requirement', scopes: ['functional', 'load'], stages: {},
    history: [ { at: '2026-11-14T09:00:00+08:00', from: 'planned', to: 'planned', by: 'ba' } ],
    scopes_skipped: [],
  });
  writeText(path.join(root, '.gitignore'), '.test-artifacts/\nnode_modules/\n');
}

const PROJ = path.join(FX, 'proj');
buildProject(PROJ, P1, P2);

// ---------------------------------------------------------------- 尾斜杠环境变体（acceptance.md §0.4.2）

const PROJ_SLASH = path.join(FX, 'proj-slash');
copyTree(PROJ, PROJ_SLASH);
writeJson(path.join(PROJ_SLASH, 'test-assets/environments/local.json'), {
  name: 'local', base_url: `http://127.0.0.1:${P1}/`, timeout_ms: 3000, retries: 0,
  credentials: { token_env: 'TEST_TOKEN' },
});

// ---------------------------------------------------------------- 非法变体（acceptance.md §0.7）

const VDIR = path.join(FX, 'variants');
fs.mkdirSync(VDIR, { recursive: true });
const variantRoot = (name) => path.join(VDIR, name);
const modelPath = (root, name) => path.join(root, 'test-assets/load/scenarios', `${name}.json`);
const editModel = (root, name, fn) => {
  const f = modelPath(root, name);
  const doc = JSON.parse(fs.readFileSync(f, 'utf8'));
  fn(doc);
  writeJson(f, doc);
};
const editSuiteRef = (root, suite, fn) => {
  const f = path.join(root, 'test-assets/load/suites', suite, 'scenario.json');
  const doc = JSON.parse(fs.readFileSync(f, 'utf8'));
  fn(doc);
  writeJson(f, doc);
};

const VARIANTS = [
  ['V1', (root) => { editModel(root, 'order-query', (d) => { d.profile.steps[0].concurrency = 0; }); }],
  ['V2', (root) => { editModel(root, 'checkout', (d) => { d.target = 'POST api/v1/checkout'; }); }],
  ['V3', (root) => { editModel(root, 'health-check', (d) => { d.tool.runner = 'jmeter'; }); }],
  ['V4', (root) => { fs.unlinkSync(path.join(root, 'test-assets/environments/staging.json')); }],
  ['V5', (root) => {
    const f = path.join(root, 'test-assets/environments/local.json');
    const doc = JSON.parse(fs.readFileSync(f, 'utf8'));
    delete doc.base_url;
    writeJson(f, doc);
  }],
  ['V6', (root) => { editSuiteRef(root, 'LOAD-001-checkout', (d) => { d.scenarios[0].id = 'WL-999'; }); }],
  ['V7', (root) => { editSuiteRef(root, 'LOAD-001-checkout', (d) => { d.scenarios[0].path = '../../scenarios/nope.json'; }); }],
  ['V8', (root) => { editModel(root, 'checkout', (d) => { d.args.concurrency = 5; }); }],
  ['V9', (root) => { editModel(root, 'checkout-staging', (d) => { delete d.args.command; }); }],
  ['V9b', (root) => { editModel(root, 'checkout-staging', (d) => { d.args.command = 'python -m mylab'; }); }],
];
for (const [name, mutate] of VARIANTS) {
  const root = variantRoot(name);
  copyTree(PROJ, root);
  mutate(root);
}

process.stdout.write('FIXTURE-OK\n');
QA012_FIX_EOF

cat > "$WORK/judge.mjs" <<'QA012_JUDGE_EOF'
// REQ-012 独立复算器（judge.mjs）—— 判据的产物侧判定
// ⚠️ **绝不 import 被验包的任何模块**（否则等于用被验实现验证被验实现）。
//    自己重算负载模型 → argv 的映射口径，自带解析 / 集合运算 / 枚举实现。
// 用法: node judge.mjs <PKG> <WORK> <ACCEPTANCE> <DECISIONS> <SIBLING_DIR> <SKIP_SIBLING>
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync, spawn } from 'node:child_process';

const [PKG, WORK, ACCEPTANCE, DECISIONS, SIBLING_DIR, SKIP_SIBLING] = process.argv.slice(2);

const ENTRY_REL = 'skills/load-profile/scripts/plan-load-run.mjs';
const CHECKER_REL = 'skills/load-profile/scripts/check-load-run.mjs';
const TR_REL = 'skills/load-profile';
const ENTRY = path.join(PKG, ENTRY_REL);
const CHECKER = path.join(PKG, CHECKER_REL);
const IMPL_MISSING = !fs.existsSync(ENTRY);

// ---------------------------------------------------------------- 小工具

const sha256 = (f) => { try { return crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex'); } catch { return null; } };
const readJson = (f) => { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch { return null; } };
const isDir = (p) => { try { return fs.statSync(p).isDirectory(); } catch { return false; } };
const isFile = (p) => { try { return fs.statSync(p).isFile(); } catch { return false; } };
const sorted = (a) => a.slice().sort();
const sameSet = (a, b) => a.size === b.size && [...a].every((x) => b.has(x));
const copyTree = (src, dst) => {
  fs.mkdirSync(dst, { recursive: true });
  for (const n of fs.readdirSync(src)) {
    const s = path.join(src, n);
    const d = path.join(dst, n);
    const st = fs.lstatSync(s);
    if (st.isDirectory()) copyTree(s, d);
    else if (st.isFile()) { fs.mkdirSync(path.dirname(d), { recursive: true }); fs.copyFileSync(s, d); }
  }
};
const treeFingerprint = (root, excludeRel = '') => {
  const lines = [];
  const walk = (d) => {
    if (!isDir(d)) return;
    for (const n of fs.readdirSync(d).sort()) {
      const f = path.join(d, n);
      const rel = path.relative(root, f);
      if (excludeRel && (rel === excludeRel || rel.startsWith(excludeRel + path.sep))) continue;
      const st = fs.lstatSync(f);
      if (st.isDirectory()) walk(f);
      else if (st.isFile()) lines.push(`${rel} ${sha256(f)}`);
    }
  };
  walk(root);
  return lines.join('\n');
};
const runBash = (args, opts = {}) => {
  const r = spawnSync('bash', args, { encoding: 'utf8', maxBuffer: 128 * 1024 * 1024, ...opts });
  return { rc: r.status === null ? -1 : r.status, out: r.stdout || '', err: r.stderr || '' };
};
const runNode = (args, opts = {}) => {
  const r = spawnSync(process.execPath, args, { encoding: 'utf8', maxBuffer: 128 * 1024 * 1024, ...opts });
  return { rc: r.status === null ? -1 : r.status, out: r.stdout || '', err: r.stderr || '' };
};

// ---------------------------------------------------------------- 判据集合 / 决策号（动态取）

const accText = fs.readFileSync(ACCEPTANCE, 'utf8');
const decText = fs.readFileSync(DECISIONS, 'utf8');
// ⚠️ 决策号**只按 `^## D\d+` 标题行取** —— 正文里对 REQ-009（D127~D155）的引用**不是**本 REQ 的决策
const acIds = [...accText.matchAll(/^### (AC-\d+)/gm)].map((m) => m[1]);
const decIds = [...decText.matchAll(/^## (D\d+)/gm)].map((m) => m[1]);
const acNums = new Set(acIds.map((x) => Number(x.replace(/^AC-/, ''))));
const decNums = new Set(decIds.map((x) => Number(x.replace(/^D/, ''))));

function parseBaseline(marker) {
  const idx = accText.indexOf(marker);
  if (idx < 0) return null;
  const rest = accText.slice(idx + marker.length);
  const next = rest.search(/\n### /);
  const section = next >= 0 ? rest.slice(0, next) : rest;
  const rows = [...section.matchAll(/^\|\s*\d+\s*\|\s*`([^`]+)`\s*\|\s*`([0-9a-f]{64})`\s*\|/gm)];
  return rows.map((m) => [m[1], m[2]]);
}
const BASE14 = parseBaseline('### §0.8.1');
const BASE4 = parseBaseline('### §0.8.2');

// ---------------------------------------------------------------- 结论收集

const findings = new Map();
const add = (ac, msg) => { if (!findings.has(ac)) findings.set(ac, []); findings.get(ac).push(msg); };
const undecs = new Map();
const markUndec = (ac, msg) => { if (!undecs.has(ac)) undecs.set(ac, []); undecs.get(ac).push(msg); };

const IMPL_DEPS = ['AC-001','AC-004','AC-005','AC-006','AC-007','AC-008','AC-009','AC-010','AC-011','AC-012',
  'AC-013','AC-014','AC-015','AC-016','AC-017','AC-018','AC-019','AC-020','AC-021','AC-022','AC-023','AC-024','AC-025','AC-026'];

// ---------------------------------------------------------------- 夹具与桩服务

const FX = path.join(WORK, 'fx');
let STUB_LOGS = [];
const STUB_PROCS = [];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------- 主流程

async function main() {

  // ① 桩服务（两个，随机端口）
  const stubs = [];
  for (const name of ['p1', 'p2']) {
    const log = path.join(WORK, `stub-${name}.log`);
    fs.writeFileSync(log, '');
    const portFile = path.join(WORK, `stub-${name}.port`);
    try { fs.unlinkSync(portFile); } catch { /* 不存在即可 */ }
    const proc = spawn(process.execPath, [path.join(WORK, 'stub.mjs'), log, portFile], { stdio: 'ignore' });
    STUB_PROCS.push(proc);
    stubs.push({ name, log, portFile, proc });
  }
  for (const s of stubs) {
    for (let i = 0; i < 200; i++) {
      if (fs.existsSync(s.portFile)) {
        const txt = fs.readFileSync(s.portFile, 'utf8').trim();
        if (/^\d+$/.test(txt)) { s.port = Number(txt); break; }
      }
      await sleep(25);
    }
  }
  STUB_LOGS = stubs.map((s) => s.log);

  // ② 夹具
  const fx = runNode([path.join(WORK, 'mkfixture.mjs'), FX, String(stubs[0].port || 0), String(stubs[1].port || 0)]);
  if (fx.rc !== 0 || !isDir(FX)) {
    for (const ac of acIds) markUndec(ac, `夹具生成失败（rc=${fx.rc}）：${fx.err.slice(0, 200)}`);
    finish(stubs);
    return;
  }

  // ③ 主跑（读入侧与写出侧同根 —— 最自然的用法）
  const PROJ_MAIN = path.join(WORK, 'run-main');
  copyTree(path.join(FX, 'proj'), PROJ_MAIN);
  const beforeTree = treeFingerprint(PROJ_MAIN, path.join('test-assets', 'load', 'plans'));
  const inputFiles = listInputFiles(PROJ_MAIN);
  const beforeInputs = inputFiles.map((f) => [f, sha256(f)]);
  const MAIN = IMPL_MISSING ? { rc: 127, out: '', err: '[未交付] 入口脚本不存在' }
    : runNode([ENTRY, '--load-dir', PROJ_MAIN, '--out-dir', PROJ_MAIN]);
  const afterTree = treeFingerprint(PROJ_MAIN, path.join('test-assets', 'load', 'plans'));
  const afterInputs = beforeInputs.map(([f]) => [f, sha256(f)]);

  // ④ 尾斜杠环境变体（acceptance.md §0.4.2）
  const PROJ_SLASH = path.join(WORK, 'run-slash');
  copyTree(path.join(FX, 'proj-slash'), PROJ_SLASH);
  const SLASH = IMPL_MISSING ? { rc: 127, out: '', err: '[未交付] 入口脚本不存在' }
    : runNode([ENTRY, '--load-dir', PROJ_SLASH, '--out-dir', PROJ_SLASH]);

  const implOk = MAIN.rc === 0;

  // ================================================================ 逐条判据

  // ---- AC-001 两个新入口脚本形状合法 + 校验器行为护栏
  {
    for (const [rel, abs] of [[ENTRY_REL, ENTRY], [CHECKER_REL, CHECKER]]) {
      if (!isFile(abs)) { add('AC-001', `${rel} 不存在`); continue; }
      const st = fs.statSync(abs);
      if (st.size === 0) add('AC-001', `${rel} 为空文件`);
      const first = fs.readFileSync(abs, 'utf8').split('\n')[0].trim();
      if (first !== '#!/usr/bin/env node') add('AC-001', `${rel} 首行不是 shebang`);
      if ((st.mode & 0o111) === 0) add('AC-001', `${rel} 没有可执行位`);
      const chk = runNode(['--check', abs]);
      if (chk.rc !== 0) add('AC-001', `${rel} 的 node --check 不通过`);
    }
    if (!implOk) {
      add('AC-001', `主跑未成功（rc=${MAIN.rc}）⇒ 无法验证校验器行为护栏`);
    } else {
      const c1 = runNode([CHECKER, PROJ_MAIN]);
      if (c1.rc !== 0) add('AC-001', `校验器对合法项目根的退出码是 ${c1.rc}（应为 0）`);
      const tampered = path.join(WORK, 'run-tampered');
      copyTree(PROJ_MAIN, tampered);
      let tamperedOk = false;
      const plansDir = path.join(tampered, 'test-assets/load/plans');
      if (isDir(plansDir)) {
        for (const f of fs.readdirSync(plansDir).filter((n) => n.endsWith('.json')).sort()) {
          const p = path.join(plansDir, f);
          const doc = readJson(p);
          if (!doc || !Array.isArray(doc.scenarios)) continue;
          for (const s of doc.scenarios) {
            for (const inv of (s.invocations || [])) {
              const argv = inv.argv || [];
              const i = argv.indexOf('-t');
              if (i >= 0 && argv[i + 1] === '60') { argv[i + 1] = '61'; fs.writeFileSync(p, JSON.stringify(doc, null, 2) + '\n'); tamperedOk = true; break; }
            }
            if (tamperedOk) break;
          }
          if (tamperedOk) break;
        }
      }
      if (!tamperedOk) add('AC-001', '找不到可篡改的 argv（夹具异常）⇒ 无法验证校验器行为护栏');
      else {
        const c2 = runNode([CHECKER, tampered]);
        if (c2.rc !== 1) add('AC-001', `校验器对篡改副本的退出码是 ${c2.rc}（应为 1，且不得是 0 或 2）`);
      }
    }
  }

  // ---- AC-002 REQ-009 既有 14 文件逐字未改
  if (!BASE14) markUndec('AC-002', 'acceptance.md 的 §0.8.1 基线表解析失败');
  else for (const [rel, expected] of BASE14) {
    const got = sha256(path.join(PKG, TR_REL, rel));
    if (got === null) add('AC-002', `${rel} 不存在`);
    else if (got !== expected) add('AC-002', `${rel} 的 sha256 与基线不一致`);
  }

  // ---- AC-003 README 两处都在 + 提到两个新脚本
  {
    const readme = path.join(PKG, 'README.md');
    if (!isFile(readme)) add('AC-003', 'README.md 不存在');
    else {
      const parsed = parseReadmeSkills(readme);
      const skillsDir = path.join(PKG, 'skills');
      const actual = new Set();
      if (isDir(skillsDir)) {
        for (const d of fs.readdirSync(skillsDir)) if (isFile(path.join(skillsDir, d, 'SKILL.md'))) actual.add(d);
      }
      if (!sameSet(new Set(parsed.names), actual)) {
        add('AC-003', `README 的 skill 清单与实际目录不一致（README: ${parsed.names.join(',')}；实际: ${[...actual].sort().join(',')}）`);
      }
      if (!parsed.table.includes('load-profile')) add('AC-003', 'README 的 skill 表格里没有 load-profile');
      if (!parsed.tree.includes('load-profile')) add('AC-003', 'README 的安装树代码块里没有 load-profile');
      const text = fs.readFileSync(readme, 'utf8');
      if (!text.includes('plan-load-run.mjs')) add('AC-003', 'README 里没有提到 plan-load-run.mjs');
      if (!text.includes('check-load-run.mjs')) add('AC-003', 'README 里没有提到 check-load-run.mjs');
    }
  }

  // ---- 产物侧的公共数据
  const PLANS_DIR = path.join(PROJ_MAIN, 'test-assets/load/plans');
  const plans = [];
  if (isDir(PLANS_DIR)) {
    for (const f of fs.readdirSync(PLANS_DIR).filter((n) => n.endsWith('.json')).sort()) {
      plans.push({ file: f, name: f.replace(/\.json$/, ''), doc: readJson(path.join(PLANS_DIR, f)) });
    }
  }
  const side = loadSide(PROJ_MAIN);
  if (!implOk) {
    for (const ac of IMPL_DEPS) {
      if (ac === 'AC-001') continue;
      add(ac, `主跑未成功（rc=${MAIN.rc}）⇒ 没有产物可判`);
    }
  } else if (plans.length === 0) {
    for (const ac of IMPL_DEPS) { if (ac === 'AC-001') continue; add(ac, '主跑成功但没有计划产物'); }
  }

  // ---- AC-004 三层字段集封闭 + 枚举 + 整数
  {
    const TOP = ['schema_version', 'suite', 'environment', 'scenarios'];
    const SCEN_REQ = ['scenario_id', 'scenario_name', 'runner', 'runtime', 'target', 'base_url', 'profile_type', 'invocations', 'thresholds_status', 'open_questions'];
    const SCEN_COND = ['thresholds', 'thresholds_source'];
    const INV = ['step_index', 'duration_s', 'concurrency', 'argv'];
    const RUNNERS = new Set(['loadtest', 'python']);
    const RUNTIMES = new Set(['bun', 'python', 'node']);
    const PTYPES = new Set(['constant', 'ramp-up', 'ramp-down', 'spike', 'soak']);
    for (const p of plans) {
      if (!p.doc || typeof p.doc !== 'object') { add('AC-004', `${p.file}: 不是合法 JSON 对象`); continue; }
      const tk = Object.keys(p.doc);
      if (JSON.stringify(sorted(tk)) !== JSON.stringify(sorted(TOP))) add('AC-004', `${p.file}: 顶层字段集不是 4 个（实际 ${tk.join(',')}）`);
      if (p.doc.schema_version !== 1) add('AC-004', `${p.file}: schema_version 不是 1`);
      if (!Array.isArray(p.doc.scenarios) || p.doc.scenarios.length === 0) { add('AC-004', `${p.file}: scenarios 不是非空数组`); continue; }
      for (const s of p.doc.scenarios) {
        const where = `${p.file}/${s.scenario_id || '?'}`;
        const sk = Object.keys(s);
        const cond = s.thresholds_status === 'provided' ? SCEN_COND : [];
        const expect = sorted(SCEN_REQ.concat(cond));
        if (JSON.stringify(sorted(sk)) !== JSON.stringify(expect)) add('AC-004', `${where}: 场景条目字段集不封闭（实际 ${sk.join(',')}）`);
        if (!RUNNERS.has(s.runner)) add('AC-004', `${where}: runner 取值非法`);
        if (!RUNTIMES.has(s.runtime)) add('AC-004', `${where}: runtime 取值非法`);
        if (!PTYPES.has(s.profile_type)) add('AC-004', `${where}: profile_type 取值非法`);
        if (sk.includes('cases_file')) add('AC-004', `${where}: 出现了 cases_file 之类会被上游误认的字段`);
        if (!Array.isArray(s.invocations) || s.invocations.length === 0) { add('AC-004', `${where}: invocations 不是非空数组`); continue; }
        for (const inv of s.invocations) {
          const ik = Object.keys(inv);
          if (JSON.stringify(sorted(ik)) !== JSON.stringify(sorted(INV))) add('AC-004', `${where}: invocation 字段集不是 4 个（实际 ${ik.join(',')}）`);
          if (!Number.isInteger(inv.duration_s) || inv.duration_s < 1) add('AC-004', `${where}: duration_s 不是 ≥1 的整数`);
          if (!Number.isInteger(inv.concurrency) || inv.concurrency < 1) add('AC-004', `${where}: concurrency 不是 ≥1 的整数`);
          if (!Number.isInteger(inv.step_index) || inv.step_index < 0) add('AC-004', `${where}: step_index 不是 ≥0 的整数`);
        }
      }
    }
  }

  // ---- AC-005 用法错误 rc=2
  {
    if (!IMPL_MISSING) {
      const cases = [
        { name: '缺 --load-dir', args: ['--out-dir'] },
        { name: '缺 --out-dir', args: ['--load-dir'] },
        { name: '未知参数', args: ['--load-dir', '--out-dir', '--dry-run'] },
        { name: '多余位置参数', args: ['--load-dir', '--out-dir', 'extra-positional'] },
      ];
      for (let i = 0; i < cases.length; i++) {
        const c = cases[i];
        const root = path.join(WORK, `run-usage-${i}`);
        copyTree(path.join(FX, 'proj'), root);
        const argv = [];
        for (const a of c.args) {
          if (a === '--load-dir') argv.push('--load-dir', root);
          else if (a === '--out-dir') argv.push('--out-dir', root);
          else argv.push(a);
        }
        const r = runNode([ENTRY, ...argv]);
        if (r.rc !== 2) add('AC-005', `${c.name}: 退出码是 ${r.rc}（应为 2）`);
        if (isDir(path.join(root, 'test-assets/load/plans'))) add('AC-005', `${c.name}: 留下了 plans/ 目录`);
      }
    }
  }

  // ---- 非法变体（B 组）
  const variantRoot = (name) => path.join(FX, 'variants', name);
  const runVariant = (name) => {
    if (IMPL_MISSING) return { rc: 127, out: '', err: '[未交付] 入口脚本不存在' };
    return runNode([ENTRY, '--load-dir', variantRoot(name), '--out-dir', variantRoot(name)]);
  };
  const hasPlans = (root) => isDir(path.join(root, 'test-assets/load/plans'));

  // ---- AC-006 引用/环境必须读全
  {
    const cases = [
      { v: 'V4', ac: 'AC-006', must: ['staging'] },
      { v: 'V5', ac: 'AC-006', must: ['base_url'] },
      { v: 'V6', ac: 'AC-006', must: ['WL-999'] },
      { v: 'V7', ac: 'AC-006', must: ['nope.json'] },
    ];
    for (const c of cases) {
      const r = runVariant(c.v);
      if (r.rc !== 1) add(c.ac, `${c.v}: 退出码是 ${r.rc}（应为 1）`);
      const blob = `${r.out}\n${r.err}`;
      if (!c.must.some((m) => blob.includes(m))) add(c.ac, `${c.v}: stderr 没有点名坏点（期望提到 ${c.must.join(' 或 ')}）`);
      if (hasPlans(variantRoot(c.v))) add(c.ac, `${c.v}: 留下了 plans/ 目录`);
    }
  }

  // ---- AC-007 模型内容必须合法
  {
    const cases = [
      { v: 'V1', must: ['concurrency'] },
      { v: 'V2', must: ['target'] },
      { v: 'V3', must: ['runner', 'jmeter'] },
    ];
    for (const c of cases) {
      const r = runVariant(c.v);
      if (r.rc !== 1) add('AC-007', `${c.v}: 退出码是 ${r.rc}（应为 1）`);
      const blob = `${r.out}\n${r.err}`;
      if (!c.must.every((m) => blob.includes(m))) add('AC-007', `${c.v}: stderr 没有点名坏点（期望提到 ${c.must.join(' 与 ')}）`);
      if (hasPlans(variantRoot(c.v))) add('AC-007', `${c.v}: 留下了 plans/ 目录`);
    }
  }

  // ---- AC-008 非法输入不留半份产物（十份变体）
  {
    for (const v of ['V1', 'V2', 'V3', 'V4', 'V5', 'V6', 'V7', 'V8', 'V9', 'V9b']) {
      runVariant(v);
      if (hasPlans(variantRoot(v))) add('AC-008', `${v}: 留下了 plans/ 目录`);
    }
  }

  // ---- AC-009 argv 完整可跑（含尾斜杠环境变体）
  {
    for (const p of plans) {
      const suite = side.suites.find((x) => x.name === p.name);
      for (const s of (p.doc && Array.isArray(p.doc.scenarios) ? p.doc.scenarios : [])) {
        const model = suite ? (suite.entries.find((e) => e.model && e.model.id === s.scenario_id) || {}).model : null;
        if (!model) { add('AC-009', `${p.file}: 场景 ${s.scenario_id} 找不到对应模型`); continue; }
        const env = side.envs.get(suite ? suite.cfg.environment : '');
        const baseUrl = env ? env.base_url : '';
        const expectedUrl = baseUrl.replace(/\/+$/, '') + model.target.slice(model.target.indexOf(' ') + 1);
        if (s.base_url !== baseUrl) add('AC-009', `${p.file}/${s.scenario_id}: base_url 字段不等于环境文件里的值`);
        for (const inv of (s.invocations || [])) {
          const argv = inv.argv;
          const where = `${p.file}/${s.scenario_id}[${inv.step_index}]`;
          if (!Array.isArray(argv) || argv.length === 0) { add('AC-009', `${where}: argv 不是非空数组`); continue; }
          if (!argv.every((x) => typeof x === 'string' && x.length > 0)) add('AC-009', `${where}: argv 含空元素或非字符串元素`);
          const urls = argv.filter((x) => /^https?:\/\//.test(x) || /^wss?:\/\//.test(x));
          if (s.runner === 'loadtest') {
            if (argv[0] !== 'loadtest') add('AC-009', `${where}: argv[0] 不是工具名 loadtest`);
            if (urls.length !== 1) add('AC-009', `${where}: argv 里的完整绝对 URL 不恰好 1 个（实际 ${urls.length} 个）`);
            else if (urls[0] !== expectedUrl) add('AC-009', `${where}: URL 不等于 base_url 去尾斜杠 + 目标路径（实际 ${urls[0]}，期望 ${expectedUrl}）`);
            checkLoadtestShape(argv, where, add);
          } else {
            const cmd = (model.args && Array.isArray(model.args.command)) ? model.args.command : null;
            if (!cmd) add('AC-009', `${where}: 模型里没有可用的自陈命令`);
            else if (argv[0] !== cmd[0]) add('AC-009', `${where}: argv[0] 不是自陈命令的第 0 个元素`);
            if (urls.length > 1) add('AC-009', `${where}: argv 里的完整绝对 URL 多于 1 个`);
            if (urls.length === 1 && urls[0] !== expectedUrl) add('AC-009', `${where}: URL 与 base_url + 目标路径不一致`);
          }
        }
      }
    }
    // 尾斜杠变体（§0.4.2）：字段逐字带斜杠、URL 不带
    if (SLASH.rc === 0) {
      const slashPlans = readPlans(path.join(PROJ_SLASH, 'test-assets/load/plans'));
      const slashEnvs = new Map();
      const slashEnvDir = path.join(PROJ_SLASH, 'test-assets/environments');
      if (isDir(slashEnvDir)) {
        for (const f of fs.readdirSync(slashEnvDir).filter((n) => n.endsWith('.json') && n !== '_schema.json').sort()) {
          const d = readJson(path.join(slashEnvDir, f));
          if (d) slashEnvs.set(f.replace(/\.json$/, ''), d);
        }
      }
      let checked = 0;
      for (const p of slashPlans) {
        const slashEnv = slashEnvs.get(p.doc && p.doc.environment);
        const slashBase = slashEnv ? slashEnv.base_url : '';
        for (const s of (p.doc && Array.isArray(p.doc.scenarios) ? p.doc.scenarios : [])) {
          if (s.base_url !== slashBase) add('AC-009', `尾斜杠变体 ${p.file}/${s.scenario_id}: base_url 字段没有逐字等于环境文件里的值`);
          const model = side.suites.find((x) => x.name === p.name);
          const m = model ? (model.entries.find((e) => e.model && e.model.id === s.scenario_id) || {}).model : null;
          if (!m) continue;
          const exp = slashBase.replace(/\/+$/, '') + m.target.slice(m.target.indexOf(' ') + 1);
          for (const inv of (s.invocations || [])) {
            const urls = (inv.argv || []).filter((x) => /^https?:\/\//.test(x) || /^wss?:\/\//.test(x));
            if (s.runner === 'loadtest') {
              if (urls.length !== 1) add('AC-009', `尾斜杠变体 ${p.file}/${s.scenario_id}: URL 不恰好 1 个`);
              else if (urls[0] !== exp) add('AC-009', `尾斜杠变体 ${p.file}/${s.scenario_id}: URL 必须是去掉尾斜杠后的拼接（实际 ${urls[0]}，期望 ${exp}）`);
              if (urls.some((u) => u.includes('//api'))) add('AC-009', `尾斜杠变体 ${p.file}/${s.scenario_id}: URL 里出现了 //`);
            }
            checked += 1;
          }
        }
      }
      if (checked === 0) add('AC-009', '尾斜杠环境变体没有可核的 invocation');
    } else {
      add('AC-009', `尾斜杠环境变体主跑未成功（rc=${SLASH.rc}）`);
    }
  }

  // ---- AC-010 方法与路径分离
  {
    for (const p of plans) {
      for (const s of (p.doc && Array.isArray(p.doc.scenarios) ? p.doc.scenarios : [])) {
        if (s.runner !== 'loadtest') continue;
        const suite = side.suites.find((x) => x.name === p.name);
        const m = suite ? (suite.entries.find((e) => e.model && e.model.id === s.scenario_id) || {}).model : null;
        if (!m) continue;
        const pathPart = m.target.slice(m.target.indexOf(' ') + 1);
        const wantMethod = ((m.args && m.args.method) ? String(m.args.method) : m.target.slice(0, m.target.indexOf(' '))).toUpperCase();
        for (const inv of (s.invocations || [])) {
          const argv = inv.argv || [];
          const where = `${p.file}/${s.scenario_id}[${inv.step_index}]`;
          const idxs = argv.map((x, i) => (x === '-m' ? i : -1)).filter((i) => i >= 0);
          if (idxs.length !== 1) { add('AC-010', `${where}: -m 出现 ${idxs.length} 次（应为 1 次）`); continue; }
          const val = argv[idxs[0] + 1];
          if (typeof val !== 'string' || val !== val.toUpperCase()) add('AC-010', `${where}: -m 的值不是大写方法（实际 ${val}）`);
          if (val !== wantMethod) add('AC-010', `${where}: -m 的值与方法不符（实际 ${val}，期望 ${wantMethod}）`);
          const urlIdx = argv.findIndex((x) => /^https?:\/\//.test(x) || /^wss?:\/\//.test(x));
          for (let i = 0; i < argv.length; i++) {
            if (i === urlIdx) continue;
            if (typeof argv[i] === 'string' && argv[i].includes(pathPart)) add('AC-010', `${where}: 路径字符串出现在 URL 之外的元素里`);
          }
        }
      }
    }
  }

  // ---- AC-011 多段保真
  {
    for (const p of plans) {
      const suite = side.suites.find((x) => x.name === p.name);
      for (const s of (p.doc && Array.isArray(p.doc.scenarios) ? p.doc.scenarios : [])) {
        const m = suite ? (suite.entries.find((e) => e.model && e.model.id === s.scenario_id) || {}).model : null;
        if (!m) { add('AC-011', `${p.file}: 场景 ${s.scenario_id} 找不到对应模型`); continue; }
        const steps = m.profile.steps;
        const invs = s.invocations || [];
        if (invs.length !== steps.length) { add('AC-011', `${p.file}/${s.scenario_id}: invocations 条数 ${invs.length} ≠ steps 条数 ${steps.length}`); continue; }
        for (let i = 0; i < steps.length; i++) {
          const inv = invs[i];
          if (inv.step_index !== i) add('AC-011', `${p.file}/${s.scenario_id}: 第 ${i} 条的 step_index 不是 ${i}（实际 ${inv.step_index}）`);
          if (inv.duration_s !== steps[i].duration_s) add('AC-011', `${p.file}/${s.scenario_id}: 第 ${i} 条的 duration_s 与模型不符`);
          if (inv.concurrency !== steps[i].concurrency) add('AC-011', `${p.file}/${s.scenario_id}: 第 ${i} 条的 concurrency 与模型不符`);
        }
      }
    }
  }

  // ---- AC-012 --cores 1 恒定钉死
  {
    for (const p of plans) {
      for (const s of (p.doc && Array.isArray(p.doc.scenarios) ? p.doc.scenarios : [])) {
        if (s.runner !== 'loadtest') continue;
        for (const inv of (s.invocations || [])) {
          const argv = inv.argv || [];
          const idxs = argv.map((x, i) => (x === '--cores' ? i : -1)).filter((i) => i >= 0);
          const where = `${p.file}/${s.scenario_id}[${inv.step_index}]`;
          if (idxs.length !== 1) { add('AC-012', `${where}: --cores 出现 ${idxs.length} 次（应为 1 次）`); continue; }
          if (argv[idxs[0] + 1] !== '1') add('AC-012', `${where}: --cores 的下一个元素不是 "1"（实际 ${argv[idxs[0] + 1]}）`);
        }
      }
    }
  }

  // ---- AC-013 计划与套件一一对应
  {
    const suiteNames = side.suites.map((x) => x.name);
    const planNames = plans.map((x) => x.name);
    for (const sn of suiteNames) if (!planNames.includes(sn)) add('AC-013', `缺少套件 ${sn} 的计划文件`);
    for (const pn of planNames) if (!suiteNames.includes(pn)) add('AC-013', `多出没有对应套件的计划文件 ${pn}.json`);
    if (isDir(PLANS_DIR) && fs.existsSync(path.join(PLANS_DIR, 'suite.json'))) add('AC-013', 'plans/ 下出现了 suite.json');
    for (const p of plans) {
      const suite = side.suites.find((x) => x.name === p.name);
      if (!suite) continue;
      if (p.doc.suite !== p.name) add('AC-013', `${p.file}: suite 字段不等于文件名去 .json`);
      if (suite.cfg && p.doc.environment !== suite.cfg.environment) add('AC-013', `${p.file}: environment 不等于套件 suite.json 的 environment`);
      const wantIds = suite.entries.map((e) => e.ref.id);
      const gotIds = (p.doc.scenarios || []).map((s) => s.scenario_id);
      if (JSON.stringify(wantIds) !== JSON.stringify(gotIds)) add('AC-013', `${p.file}: scenarios 的 id 序列与引用件不一致`);
    }
  }

  // ---- AC-014 -t / -c 逐字映射
  {
    for (const p of plans) {
      for (const s of (p.doc && Array.isArray(p.doc.scenarios) ? p.doc.scenarios : [])) {
        if (s.runner !== 'loadtest') continue;
        for (const inv of (s.invocations || [])) {
          const argv = inv.argv || [];
          const where = `${p.file}/${s.scenario_id}[${inv.step_index}]`;
          const ti = argv.indexOf('-t');
          const ci = argv.indexOf('-c');
          if (ti < 0 || argv.filter((x) => x === '-t').length !== 1) add('AC-014', `${where}: -t 出现 ${argv.filter((x) => x === '-t').length} 次（应为 1 次）`);
          else if (argv[ti + 1] !== String(inv.duration_s)) add('AC-014', `${where}: -t 的值 ${argv[ti + 1]} ≠ duration_s ${inv.duration_s}`);
          if (ci < 0 || argv.filter((x) => x === '-c').length !== 1) add('AC-014', `${where}: -c 出现 ${argv.filter((x) => x === '-c').length} 次（应为 1 次）`);
          else if (argv[ci + 1] !== String(inv.concurrency)) add('AC-014', `${where}: -c 的值 ${argv[ci + 1]} ≠ concurrency ${inv.concurrency}`);
        }
      }
    }
  }

  // ---- AC-015 timeout_s → -d 毫秒
  {
    for (const p of plans) {
      const suite = side.suites.find((x) => x.name === p.name);
      for (const s of (p.doc && Array.isArray(p.doc.scenarios) ? p.doc.scenarios : [])) {
        if (s.runner !== 'loadtest') continue;
        const m = suite ? (suite.entries.find((e) => e.model && e.model.id === s.scenario_id) || {}).model : null;
        if (!m) continue;
        const args = m.args || {};
        for (const inv of (s.invocations || [])) {
          const argv = inv.argv || [];
          const where = `${p.file}/${s.scenario_id}[${inv.step_index}]`;
          const n = argv.filter((x) => x === '-d').length;
          if ('timeout_s' in args) {
            if (n !== 1) add('AC-015', `${where}: -d 出现 ${n} 次（应为 1 次）`);
            else {
              const want = String(Math.round(Number(args.timeout_s) * 1000));
              if (argv[argv.indexOf('-d') + 1] !== want) add('AC-015', `${where}: -d 的值 ${argv[argv.indexOf('-d') + 1]} ≠ ${want}`);
            }
          } else if (n !== 0) {
            add('AC-015', `${where}: 模型没有 timeout_s，却出现了 -d`);
          }
        }
      }
    }
  }

  // ---- AC-016 --rps / -k 逐字映射
  {
    for (const p of plans) {
      const suite = side.suites.find((x) => x.name === p.name);
      for (const s of (p.doc && Array.isArray(p.doc.scenarios) ? p.doc.scenarios : [])) {
        if (s.runner !== 'loadtest') continue;
        const m = suite ? (suite.entries.find((e) => e.model && e.model.id === s.scenario_id) || {}).model : null;
        if (!m) continue;
        const args = m.args || {};
        for (const inv of (s.invocations || [])) {
          const argv = inv.argv || [];
          const where = `${p.file}/${s.scenario_id}[${inv.step_index}]`;
          const nRps = argv.filter((x) => x === '--rps').length;
          if ('rps' in args) {
            if (nRps !== 1) add('AC-016', `${where}: --rps 出现 ${nRps} 次（应为 1 次）`);
            else if (argv[argv.indexOf('--rps') + 1] !== String(args.rps)) add('AC-016', `${where}: --rps 的值 ≠ 模型里的 rps`);
          } else if (nRps !== 0) add('AC-016', `${where}: 模型没有 rps，却出现了 --rps`);
          const nK = argv.filter((x) => x === '-k').length;
          if (args.keepalive === true) { if (nK !== 1) add('AC-016', `${where}: -k 出现 ${nK} 次（应为 1 次）`); }
          else if (nK !== 0) add('AC-016', `${where}: 模型没有 keepalive=true，却出现了 -k`);
        }
      }
    }
  }

  // ---- AC-017 未知 args 键必须拒绝
  {
    const r = runVariant('V8');
    if (r.rc !== 1) add('AC-017', `V8 的退出码是 ${r.rc}（应为 1）`);
    const blob = `${r.out}\n${r.err}`;
    if (!blob.includes('concurrency')) add('AC-017', 'V8 的 stderr 没有点名未知键 concurrency');
    if (hasPlans(variantRoot('V8'))) add('AC-017', 'V8 留下了 plans/ 目录');
    const hasArgsKey = (node) => {
      if (node === null || typeof node !== 'object') return false;
      if (Array.isArray(node)) return node.some(hasArgsKey);
      return Object.entries(node).some(([k, v]) => k === 'args' || hasArgsKey(v));
    };
    for (const p of plans) {
      if (hasArgsKey(p.doc)) add('AC-017', `${p.file}: 产物里出现了 args 键（未知 args 键被静默忽略/透传）`);
    }
  }

  // ---- AC-018 python runner 必须自陈完整命令
  {
    for (const v of ['V9', 'V9b']) {
      const r = runVariant(v);
      if (r.rc !== 1) add('AC-018', `${v} 的退出码是 ${r.rc}（应为 1）`);
      const blob = `${r.out}\n${r.err}`;
      if (!blob.includes('command')) add('AC-018', `${v} 的 stderr 没有点名 command`);
      if (hasPlans(variantRoot(v))) add('AC-018', `${v} 留下了 plans/ 目录`);
    }
    for (const p of plans) {
      const suite = side.suites.find((x) => x.name === p.name);
      for (const s of (p.doc && Array.isArray(p.doc.scenarios) ? p.doc.scenarios : [])) {
        if (s.runner !== 'python') continue;
        const m = suite ? (suite.entries.find((e) => e.model && e.model.id === s.scenario_id) || {}).model : null;
        if (!m) { add('AC-018', `${p.file}: 场景 ${s.scenario_id} 找不到对应模型`); continue; }
        const cmd = (m.args && Array.isArray(m.args.command)) ? m.args.command : null;
        if (!cmd) { add('AC-018', `${p.file}/${s.scenario_id}: 模型里没有自陈命令`); continue; }
        const seen = [];
        for (const inv of (s.invocations || [])) {
          const argv = inv.argv || [];
          const where = `${p.file}/${s.scenario_id}[${inv.step_index}]`;
          const substituted = cmd.map((x) => String(x).replace(/\{duration_s\}/g, String(inv.duration_s)).replace(/\{concurrency\}/g, String(inv.concurrency)));
          if (argv.length < substituted.length) { add('AC-018', `${where}: argv 比自陈命令还短`); continue; }
          for (let i = 0; i < substituted.length; i++) {
            if (argv[i] !== substituted[i]) { add('AC-018', `${where}: argv 前缀不是自陈命令（占位符替换后）`); break; }
          }
          if (!argv.includes(String(inv.duration_s))) add('AC-018', `${where}: argv 里没有该段的 duration_s 取值`);
          if (!argv.includes(String(inv.concurrency))) add('AC-018', `${where}: argv 里没有该段的 concurrency 取值`);
          if (argv.some((x) => /\{[^}]*\}/.test(x))) add('AC-018', `${where}: argv 里残留占位符`);
          seen.push(JSON.stringify(argv));
        }
        if (seen.length >= 2 && new Set(seen).size !== seen.length) add('AC-018', `${p.file}/${s.scenario_id}: 多段的 argv 相同（多段保真被破坏）`);
      }
    }
  }

  // ---- AC-019 不得出现任何压测结论
  {
    const BAD_KEYS = new Set(['status', 'result', 'verdict', 'executed', 'passed', 'outcome', 'conclusion']);
    const BAD_WORDS = ['已压测', '已达标', '已通过', '压测完成', '压测结果'];
    const walk = (node, pathStr, file) => {
      if (node === null || typeof node !== 'object') {
        if (typeof node === 'string') {
          for (const w of BAD_WORDS) if (node.includes(w)) add('AC-019', `${file}${pathStr}: 出现了禁表述「${w}」`);
        }
        return;
      }
      if (Array.isArray(node)) { node.forEach((v, i) => walk(v, `${pathStr}[${i}]`, file)); return; }
      for (const [k, v] of Object.entries(node)) {
        if (BAD_KEYS.has(k)) add('AC-019', `${file}${pathStr}.${k}: 出现了压测结论键`);
        if (k === 'ok' && v === true) add('AC-019', `${file}${pathStr}.${k}: 出现了值为 true 的结论键`);
        walk(v, `${pathStr}.${k}`, file);
      }
    };
    for (const p of plans) walk(p.doc, '', p.file);
  }

  // ---- AC-020 阈值二态
  {
    for (const p of plans) {
      const suite = side.suites.find((x) => x.name === p.name);
      for (const s of (p.doc && Array.isArray(p.doc.scenarios) ? p.doc.scenarios : [])) {
        const m = suite ? (suite.entries.find((e) => e.model && e.model.id === s.scenario_id) || {}).model : null;
        if (!m) continue;
        const hasT = Object.prototype.hasOwnProperty.call(s, 'thresholds');
        const hasS = Object.prototype.hasOwnProperty.call(s, 'thresholds_source');
        if (s.thresholds_status !== 'provided' && s.thresholds_status !== 'not_provided') { add('AC-020', `${p.file}/${s.scenario_id}: thresholds_status 取值非法`); continue; }
        if (m.thresholds_status === 'provided') {
          if (s.thresholds_status !== 'provided') add('AC-020', `${p.file}/${s.scenario_id}: thresholds_status 与模型不一致`);
          if (!hasT || !hasS) add('AC-020', `${p.file}/${s.scenario_id}: 模型 provided，但计划缺少 thresholds / thresholds_source`);
          else {
            if (JSON.stringify(s.thresholds) !== JSON.stringify(m.thresholds)) add('AC-020', `${p.file}/${s.scenario_id}: thresholds 与模型不逐字相等`);
            if (s.thresholds_source !== m.thresholds_source) add('AC-020', `${p.file}/${s.scenario_id}: thresholds_source 与模型不逐字相等`);
          }
        } else {
          if (s.thresholds_status !== 'not_provided') add('AC-020', `${p.file}/${s.scenario_id}: thresholds_status 与模型不一致`);
          if (hasT || hasS) add('AC-020', `${p.file}/${s.scenario_id}: 模型 not_provided，但计划里出现了阈值键`);
        }
      }
    }
  }

  // ---- AC-021 未决问题
  {
    const TOPICS = new Set(['thresholds', 'coverage', 'runner', 'other']);
    for (const p of plans) {
      const suite = side.suites.find((x) => x.name === p.name);
      const seenIds = new Set();
      for (const s of (p.doc && Array.isArray(p.doc.scenarios) ? p.doc.scenarios : [])) {
        const m = suite ? (suite.entries.find((e) => e.model && e.model.id === s.scenario_id) || {}).model : null;
        if (!m) continue;
        const where = `${p.file}/${s.scenario_id}`;
        if (!Object.prototype.hasOwnProperty.call(s, 'open_questions')) { add('AC-021', `${where}: 缺少 open_questions 字段`); continue; }
        const oqs = s.open_questions;
        if (!Array.isArray(oqs)) { add('AC-021', `${where}: open_questions 不是数组`); continue; }
        for (const q of oqs) {
          const qk = Object.keys(q || {});
          if (JSON.stringify(sorted(qk)) !== JSON.stringify(sorted(['id', 'topic', 'question']))) add('AC-021', `${where}: 未决问题字段集不是 id/topic/question（实际 ${qk.join(',')}）`);
          if (!/^OQ-\d{3}$/.test(String(q.id))) add('AC-021', `${where}: 未决问题 id 不合 ^OQ-\d{3}$`);
          if (seenIds.has(q.id)) add('AC-021', `${where}: 未决问题 id 在同一计划文件内不唯一（${q.id}）`);
          seenIds.add(q.id);
          if (!TOPICS.has(q.topic)) add('AC-021', `${where}: 未决问题 topic 取值非法`);
          if (typeof q.question !== 'string' || q.question.trim() === '') add('AC-021', `${where}: 未决问题 question 为空`);
        }
        const topics = oqs.map((q) => q.topic);
        if (m.thresholds_status === 'not_provided' && !topics.includes('thresholds')) add('AC-021', `${where}: 模型无阈值来源，但计划里没有 topic=thresholds 的未决问题`);
        if (m.thresholds_status === 'provided' && topics.includes('thresholds')) add('AC-021', `${where}: 模型有阈值来源，但计划里出现了 topic=thresholds 的未决问题`);
        const caseRefs = (m.traceability && Array.isArray(m.traceability.case_refs)) ? m.traceability.case_refs : null;
        if (caseRefs && caseRefs.length === 0 && !topics.includes('coverage')) add('AC-021', `${where}: 模型没有对应用例，但计划里没有 topic=coverage 的未决问题`);
        // ⑧ 承载一致性：条目数相等 + id/topic 逐字相等
        const moqs = Array.isArray(m.open_questions) ? m.open_questions : [];
        if (moqs.length !== oqs.length) add('AC-021', `${where}: 未决问题条目数与模型不一致（${oqs.length} ≠ ${moqs.length}）`);
        else {
          for (let i = 0; i < moqs.length; i++) {
            if (oqs[i].id !== moqs[i].id) add('AC-021', `${where}: 第 ${i} 条未决问题的 id 与模型不逐字相等`);
            if (oqs[i].topic !== moqs[i].topic) add('AC-021', `${where}: 第 ${i} 条未决问题的 topic 与模型不逐字相等`);
          }
        }
      }
    }
  }

  // ---- AC-022 零请求
  {
    for (const log of STUB_LOGS) {
      const n = isFile(log) ? fs.readFileSync(log, 'utf8').split('\n').filter((l) => l.trim() !== '').length : -1;
      if (n !== 0) add('AC-022', `桩服务 ${path.basename(log)} 收到了 ${n} 个请求（应为 0）`);
    }
    const TRACE_KEYS = ['executed', 'started_at', 'finished_at', 'timestamp', 'duration_ms', 'elapsed', 'latency', 'bytes', 'status_code', 'response', 'responses', 'samples', 'metrics', 'result_rows'];
    const walk = (node, pathStr, file) => {
      if (node === null || typeof node !== 'object') return;
      if (Array.isArray(node)) { node.forEach((v, i) => walk(v, `${pathStr}[${i}]`, file)); return; }
      for (const [k, v] of Object.entries(node)) {
        if (TRACE_KEYS.includes(k)) add('AC-022', `${file}${pathStr}.${k}: 出现了执行痕迹键`);
        walk(v, `${pathStr}.${k}`, file);
      }
    };
    for (const p of plans) walk(p.doc, '', p.file);
    for (const root of [PROJ_MAIN, PROJ_SLASH]) {
      for (const name of ['runs', 'evidence', '.test-artifacts']) {
        if (fs.existsSync(path.join(root, name))) add('AC-022', `${path.basename(root)}: 出现了 ${name} 目录/文件`);
        if (isDir(path.join(root, 'test-assets', 'load')) && fs.existsSync(path.join(root, 'test-assets', 'load', name))) add('AC-022', `${path.basename(root)}: 出现了 ${name} 目录/文件`);
      }
    }
  }

  // ---- AC-023 只写 plans/
  {
    if (beforeTree !== afterTree) add('AC-023', '主跑前后，项目根下（除 plans/ 外）的内容有变化');
  }

  // ---- AC-024 输入只读
  {
    for (let i = 0; i < beforeInputs.length; i++) {
      if (beforeInputs[i][1] !== afterInputs[i][1]) add('AC-024', `输入文件 ${path.relative(PROJ_MAIN, beforeInputs[i][0])} 在主跑前后 sha256 不一致`);
    }
  }

  // ---- AC-025 幂等
  {
    const P1 = path.join(WORK, 'run-idem1');
    const P2 = path.join(WORK, 'run-idem2');
    copyTree(path.join(FX, 'proj'), P1);
    copyTree(path.join(FX, 'proj'), P2);
    const r1 = IMPL_MISSING ? { rc: 127 } : runNode([ENTRY, '--load-dir', P1, '--out-dir', P1]);
    const r2 = IMPL_MISSING ? { rc: 127 } : runNode([ENTRY, '--load-dir', P2, '--out-dir', P2]);
    if (r1.rc === 0 && r2.rc === 0) {
      const f1 = treeFingerprint(path.join(P1, 'test-assets/load/plans'));
      const f2 = treeFingerprint(path.join(P2, 'test-assets/load/plans'));
      if (f1 !== f2) add('AC-025', '两次跑产生的 plans/ 不是逐字相同');
      if (f1.includes('generated_at') || /"timestamp"|"generated_at"|"created_at"/.test(f1)) add('AC-025', '计划里出现了生成时间戳之类的非确定性内容');
    }
  }

  // ---- AC-026 产物已存在 ⇒ rc=1 且不覆盖
  {
    if (implOk) {
      const plansBefore = treeFingerprint(PLANS_DIR);
      const r = runNode([ENTRY, '--load-dir', PROJ_MAIN, '--out-dir', PROJ_MAIN]);
      if (r.rc !== 1) add('AC-026', `第二次跑的退出码是 ${r.rc}（应为 1）`);
      const blob = `${r.out}\n${r.err}`;
      if (!/存在/.test(blob)) add('AC-026', '第二次跑的 stderr 没有点名「产物已存在」');
      const plansAfter = treeFingerprint(PLANS_DIR);
      if (plansBefore !== plansAfter) add('AC-026', '第二次跑覆盖/改动了既有产物');
    }
  }

  // ---- AC-027 交付侧记账
  {
    const fm = path.join(PKG, 'feature-meta/load-runner');
    const four = ['status.md', 'traceability.md', 'verification-report.md', 'manifest.json'];
    for (const f of four) {
      const p = path.join(fm, f);
      if (!isFile(p)) add('AC-027', `feature-meta/load-runner/${f} 不存在`);
      else if (fs.statSync(p).size === 0) add('AC-027', `feature-meta/load-runner/${f} 为空`);
    }
    const lm = readJson(path.join(fm, 'manifest.json'));
    if (lm && lm.req !== 'REQ-012') add('AC-027', `feature-meta/load-runner/manifest.json 的 req 是 ${lm.req}（应为 REQ-012）`);
    const rootm = readJson(path.join(PKG, 'feature-meta/manifest.json'));
    if (!rootm) add('AC-027', '包内根 feature-meta/manifest.json 不存在或不可解析');
    else if (rootm.req !== 'REQ-006') add('AC-027', `包内根 feature-meta/manifest.json 的 req 是 ${rootm.req}（应为 REQ-006，不得被改写）`);
    if (!BASE4) markUndec('AC-027', 'acceptance.md 的 §0.8.2 基线表解析失败');
    else for (const [rel, expected] of BASE4) {
      const got = sha256(path.join(PKG, 'feature-meta/load-profile', rel));
      if (got === null) add('AC-027', `feature-meta/load-profile/${rel} 不存在`);
      else if (got !== expected) add('AC-027', `feature-meta/load-profile/${rel} 的 sha256 与基线不一致（被改写）`);
    }
    // 追溯矩阵的编号集合 == acceptance.md 的实际 AC 集合
    const traceFile = path.join(fm, 'traceability.md');
    if (isFile(traceFile)) {
      const text = fs.readFileSync(traceFile, 'utf8');
      const ids = new Set([...text.matchAll(/AC-(\d+)/g)].map((m) => Number(m[1])));
      if (!sameSet(ids, acNums)) add('AC-027', 'traceability.md 的判据编号集合与 acceptance.md 的实际集合不相等');
    }
    // 三份 md 的判据条数取值唯一且等于实际条数；决策号取值唯一且恰好等于实际决策号集合（两道核对）
    for (const f of ['status.md', 'traceability.md', 'verification-report.md']) {
      const p = path.join(fm, f);
      if (!isFile(p)) continue;
      const text = fs.readFileSync(p, 'utf8');
      const counts = new Set([...text.matchAll(/判据条数[^\d]{0,8}(\d+)/g)].map((m) => Number(m[1])));
      if (counts.size === 0) add('AC-027', `${f}: 没有给出判据条数`);
      else if (counts.size > 1) add('AC-027', `${f}: 判据条数的取值不唯一（${[...counts].join(',')}）`);
      else if ([...counts][0] !== acIds.length) add('AC-027', `${f}: 判据条数 ${[...counts][0]} ≠ 实际条数 ${acIds.length}`);
      for (const msg of idSetProblems(text, acNums, decNums, f === 'traceability.md')) add('AC-027', `${f}: ${msg}`);
    }
  }

  // ---- AC-028 既有契约一个都不许被打破
  {
    // ① 上游目录校验器（单独进程实跑，拿真实退出码）
    const layout = path.join(PKG, 'skills/test-case-design/scripts/verify-layout.mjs');
    if (!isFile(layout)) markUndec('AC-028', '被验包里没有 skills/test-case-design/scripts/verify-layout.mjs ⇒ 上游校验不可判定');
    else {
      const r = runNode([layout, PROJ_MAIN]);
      const fails = (r.out.match(/\[FAIL\]/g) || []).length;
      if (r.rc !== 0) add('AC-028', `上游校验器退出码是 ${r.rc}（应为 0）`);
      if (fails > 0) add('AC-028', `上游校验器输出里有 ${fails} 条 FAIL`);
    }
    // ② REQ-009 的验收门（快跑模式）
    const req009 = path.join(SIBLING_DIR, 'REQ-009-load-profile/verify-acceptance.sh');
    if (!isFile(req009)) markUndec('AC-028', '同级目录里没有 REQ-009 的验收门 ⇒ 兼容性不可判定');
    else {
      const r = runBash([req009, PKG], { env: { ...process.env, REQ009_NO_MUT: '1', QA009_SCRIPT_SHA: '' } });
      const fails = (r.out.match(/^FAIL /gm) || []).length;
      if (r.rc !== 0) add('AC-028', `REQ-009 的门退出码是 ${r.rc}（应为 0）`);
      if (fails > 0) add('AC-028', `REQ-009 的门输出里有 ${fails} 条 FAIL`);
    }
    // ③ 组合门
    const combo = path.join(PKG, 'bin/test-agent-skills.mjs');
    if (!isFile(combo)) markUndec('AC-028', '被验包里没有 bin/test-agent-skills.mjs ⇒ 组合门不可判定');
    else {
      const root = path.join(WORK, 'combo-root');
      fs.mkdirSync(root, { recursive: true });
      const r = runNode([combo, 'verify', '--root', root]);
      if (r.rc !== 0) add('AC-028', `组合门退出码是 ${r.rc}（应为 0）`);
    }
    // ④ 其余**有快跑模式**的同级门（需求方 Q10 裁定：只跑有 NO_MUT 变量的门）
    if (SKIP_SIBLING === '1') {
      // 变异体探测跑：只跑快模式 ⇒ 跳过同级门扫描（探测口径只看失败键；不改变任何判据结论）
    } else if (isDir(SIBLING_DIR)) {
      const KEYWORDS = ['load-profile', 'plan-load-run', 'check-load-run', 'load/plans'];
      for (const d of fs.readdirSync(SIBLING_DIR).sort()) {
        if (d === 'REQ-009-load-profile' || d === 'REQ-012-load-runner') continue;
        const g = path.join(SIBLING_DIR, d, 'verify-acceptance.sh');
        if (!isFile(g)) continue;
        const src = fs.readFileSync(g, 'utf8');
        const m = src.match(/REQ[0-9]+_NO_MUT/);
        if (!m) continue; // 没有快跑模式的门不跑（需求方 Q10 裁定）
        const r = runBash([g, PKG], { env: { ...process.env, [m[0]]: '1' } });
        if (r.rc !== 0) {
          const blob = `${r.out}\n${r.err}`;
          const hit = KEYWORDS.filter((k) => blob.includes(k));
          if (hit.length > 0) add('AC-028', `同级门 ${d} 失败，且失败输出提到 ${hit.join('/')}（本 REQ 造成的回归）`);
        }
      }
    }
    // ⑤ not_implemented 仍含 load
    const idxFile = path.join(PKG, 'skills/test-execute/executors/index.json');
    if (!isFile(idxFile)) markUndec('AC-028', '被验包里没有 skills/test-execute/executors/index.json ⇒ 不可判定');
    else {
      const doc = readJson(idxFile);
      const ni = doc && Array.isArray(doc.not_implemented) ? doc.not_implemented : [];
      if (!ni.includes('load')) add('AC-028', 'not_implemented 里没有 load（本 REQ 不实现执行器，load 必须仍在其中）');
    }
  }

  // ---- AC-029 交付红线
  {
    // ⚠️ **公开仓库字面量清理**：内部运行时名在源码里不可直接出现（否则公开仓库会泄漏该名），
    //    故以**构造式**表达 —— 运行时得到的正则与原字面量**逐字等价**，判定行为**完全等价**。
    const RT = ['ma', 'vis'].join('');
    const BAD = [new RegExp(RT, 'i'), new RegExp('\\.local\\/share\\/' + RT, 'i')];
    const scanRoot = (root) => {
      if (!isDir(root)) return;
      for (const n of fs.readdirSync(root)) {
        const f = path.join(root, n);
        const st = fs.lstatSync(f);
        if (st.isDirectory()) scanRoot(f);
        else if (st.isFile()) {
          let text = '';
          try { text = fs.readFileSync(f, 'utf8'); } catch { continue; }
          for (const re of BAD) {
            const mm = text.match(re);
            if (mm) add('AC-029', `${path.relative(PKG, f)}: 出现了内部运行时字样「${mm[0]}」`);
          }
        }
      }
    };
    scanRoot(path.join(PKG, TR_REL));
    scanRoot(path.join(PKG, 'feature-meta'));
    // npm pack --dry-run --json ⇒ 打包清单里不得有 feature-meta/
    if (!isFile(path.join(PKG, 'package.json'))) markUndec('AC-029', '被验包里没有 package.json ⇒ npm pack 不可判定');
    else {
      const r = spawnSync('npm', ['pack', '--dry-run', '--json'], { cwd: PKG, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
      if (r.status !== 0) markUndec('AC-029', `npm pack --dry-run 失败（rc=${r.status}）`);
      else {
        let doc = null;
        try { doc = JSON.parse(r.stdout); } catch { /* 解析失败按不可判定 */ }
        let files = null;
        if (Array.isArray(doc) && doc[0] && Array.isArray(doc[0].files)) files = doc[0].files;
        else if (doc && typeof doc === 'object' && !Array.isArray(doc)) {
          const first = doc[Object.keys(doc)[0]];
          if (first && Array.isArray(first.files)) files = first.files;
        }
        if (!files) markUndec('AC-029', 'npm pack --dry-run --json 的输出无法解析');
        else {
          const bad = files.filter((f) => String(f.path || '').startsWith('feature-meta/'));
          if (bad.length > 0) add('AC-029', `npm 打包清单里有 ${bad.length} 条 feature-meta/ 条目`);
        }
      }
    }
  }

  finish(stubs);
}

function finish(stubs) {
  for (const s of (stubs || [])) { try { s.proc.kill('SIGTERM'); } catch { /* 已退出 */ } }
  for (const p of STUB_PROCS) { try { p.kill('SIGKILL'); } catch { /* 已退出 */ } }
  const out = [];
  for (const ac of acIds) {
    const f = findings.get(ac) || [];
    const u = undecs.get(ac) || [];
    if (f.length > 0) out.push({ ac, status: 'FAIL', msg: f.slice(0, 6).join('；') + (f.length > 6 ? `（共 ${f.length} 项）` : '') });
    else if (u.length > 0) out.push({ ac, status: 'UNDEC', msg: u.join('；') });
    else out.push({ ac, status: 'PASS', msg: '满足' });
  }
  process.stdout.write(JSON.stringify({ results: out }) + '\n');
  // ⚠️ 必须**显式退出**：桩服务是子进程，不杀掉的话事件循环不会收尾 ⇒ 门会一直等
  process.exit(0);
}

// ---------------------------------------------------------------- 辅助

function listInputFiles(root) {
  const out = [];
  const push = (dir) => {
    if (!isDir(dir)) return;
    for (const n of fs.readdirSync(dir).sort()) {
      const f = path.join(dir, n);
      const st = fs.lstatSync(f);
      if (st.isDirectory()) push(f);
      else if (st.isFile()) out.push(f);
    }
  };
  push(path.join(root, 'test-assets/load/scenarios'));
  push(path.join(root, 'test-assets/load/suites'));
  push(path.join(root, 'test-assets/environments'));
  return out;
}

function loadSide(root) {
  const scenDir = path.join(root, 'test-assets/load/scenarios');
  const suitesDir = path.join(root, 'test-assets/load/suites');
  const envDir = path.join(root, 'test-assets/environments');
  const models = new Map();
  if (isDir(scenDir)) {
    for (const f of fs.readdirSync(scenDir).filter((n) => n.endsWith('.json')).sort()) {
      const abs = path.join(scenDir, f);
      const doc = readJson(abs);
      if (doc) models.set(abs, doc);
    }
  }
  const suites = [];
  if (isDir(suitesDir)) {
    for (const d of fs.readdirSync(suitesDir).sort()) {
      const dir = path.join(suitesDir, d);
      if (!isDir(dir)) continue;
      const refDoc = readJson(path.join(dir, 'scenario.json'));
      const cfg = readJson(path.join(dir, 'suite.json'));
      const refs = refDoc && Array.isArray(refDoc.scenarios) ? refDoc.scenarios : [];
      const entries = refs.map((r) => {
        const abs = path.resolve(dir, r.path);
        return { ref: r, abs, model: models.get(abs) || null };
      });
      suites.push({ name: d, dir, cfg, entries });
    }
  }
  const envs = new Map();
  if (isDir(envDir)) {
    for (const f of fs.readdirSync(envDir).filter((n) => n.endsWith('.json') && n !== '_schema.json').sort()) {
      const doc = readJson(path.join(envDir, f));
      if (doc) envs.set(f.replace(/\.json$/, ''), doc);
    }
  }
  return { models, suites, envs };
}

function readPlans(dir) {
  const out = [];
  if (!isDir(dir)) return out;
  for (const f of fs.readdirSync(dir).filter((n) => n.endsWith('.json')).sort()) {
    out.push({ file: f, name: f.replace(/\.json$/, ''), doc: readJson(path.join(dir, f)) });
  }
  return out;
}

function parseReadmeSkills(file) {
  const text = fs.readFileSync(file, 'utf8');
  const names = new Set();
  const table = new Set();
  const tree = new Set();
  const lines = text.split(/\r?\n/);
  let inSkillTable = false;
  for (const line of lines) {
    if (!line.trim().startsWith('|')) { inSkillTable = false; continue; }
    const cells = line.split('|').slice(1, -1).map((c) => c.trim().replace(/`/g, ''));
    if (cells.length === 0) continue;
    if (!inSkillTable) { if (cells[0].toLowerCase() === 'skill') inSkillTable = true; continue; }
    if (cells[0] && /^[a-z][a-z0-9-]*$/.test(cells[0])) { names.add(cells[0]); table.add(cells[0]); }
  }
  for (const m of text.matchAll(/skills\/([A-Za-z0-9][A-Za-z0-9._-]*)/g)) names.add(m[1]);
  let inFence = false;
  let treeRootSeen = false;
  for (const line of lines) {
    if (line.trim().startsWith('```')) { inFence = !inFence; treeRootSeen = false; continue; }
    if (!inFence) continue;
    if (/skills\/?$/.test(line.trim())) { treeRootSeen = true; continue; }
    if (!treeRootSeen) continue;
    const m = line.match(/^[│├└─\s]*`?([a-z][a-z0-9-]*)`?\/\s*(#.*)?$/);
    if (m) { names.add(m[1]); tree.add(m[1]); }
  }
  return { names: [...names].sort(), table: [...table].sort(), tree: [...tree].sort() };
}

/** loadtest 的 argv 结构核（只查形态，不查取值 —— 取值由 AC-009④/010/012/014/015/016 各管） */
function checkLoadtestShape(argv, where, addFn) {
  const need = ['loadtest', '-t', null, '-c', null, '--cores', '1', null, '-m', null];
  if (argv.length < need.length) { addFn('AC-009', `${where}: argv 长度不足（${argv.length} < ${need.length}）`); return; }
  for (let i = 0; i < need.length; i++) {
    if (need[i] !== null && argv[i] !== need[i]) { addFn('AC-009', `${where}: argv 第 ${i} 个元素应是 ${need[i]}（实际 ${argv[i]}）`); return; }
  }
  let i = need.length;
  let stage = 0;
  while (i < argv.length) {
    const t = argv[i];
    if (stage === 0 && t === '--rps') { if (argv.length - i < 2) { addFn('AC-009', `${where}: --rps 缺少取值`); return; } i += 2; stage = 1; continue; }
    if (stage <= 1 && t === '-k') { i += 1; stage = 2; continue; }
    if (stage <= 2 && t === '-d') { if (argv.length - i < 2) { addFn('AC-009', `${where}: -d 缺少取值`); return; } i += 2; stage = 3; continue; }
    addFn('AC-009', `${where}: 出现了表外选项或顺序不对（${t}）`);
    return;
  }
}

/** 编号集合的两道核对（REQ-007 的 F-01 逃逸形态的补丁） */
function idSetProblems(text, acNums, decNums, checkAc) {
  const problems = [];
  const rangeOf = (re, prefix, actual) => {
    const out = [];
    for (const m of text.matchAll(re)) {
      const a = Number(m[1]);
      const b = Number(m[2]);
      const set = new Set();
      for (let i = Math.min(a, b); i <= Math.max(a, b); i++) set.add(i);
      if (!sameSet(set, actual)) out.push(`范围字面量 ${m[0]} 展开后的集合不等于实际${prefix}集合`);
    }
    return out;
  };
  problems.push(...rangeOf(/AC-(\d+)\s*[~～\-–—]\s*AC-(\d+)/g, '判据', acNums));
  problems.push(...rangeOf(/D(\d+)\s*[~～\-–—]\s*D(\d+)/g, '决策', decNums));
  const mentionedAc = new Set([...text.matchAll(/AC-(\d+)/g)].map((m) => Number(m[1])));
  for (const m of text.matchAll(/AC-(\d+)\s*[~～\-–—]\s*AC-(\d+)/g)) {
    const a = Number(m[1]); const b = Number(m[2]);
    for (let i = Math.min(a, b); i <= Math.max(a, b); i++) mentionedAc.add(i);
  }
  const mentionedDec = new Set([...text.matchAll(/\bD(\d+)\b/g)].map((m) => Number(m[1])));
  for (const m of text.matchAll(/D(\d+)\s*[~～\-–—]\s*D(\d+)/g)) {
    const a = Number(m[1]); const b = Number(m[2]);
    for (let i = Math.min(a, b); i <= Math.max(a, b); i++) mentionedDec.add(i);
  }
  if (checkAc && !sameSet(mentionedAc, acNums)) problems.push('文件里出现的判据编号并集不等于实际判据集合');
  if (!sameSet(mentionedDec, decNums)) problems.push('文件里出现的决策号并集不等于实际决策号集合');
  for (const n of mentionedAc) if (!acNums.has(n)) problems.push(`出现本 REQ 之外的判据编号 AC-${n}`);
  for (const n of mentionedDec) if (!decNums.has(n)) problems.push(`出现本 REQ 之外的决策号 D${n}`);
  return problems;
}

main().catch((e) => {
  for (const p of STUB_PROCS) { try { p.kill('SIGKILL'); } catch { /* 已退出 */ } }
  process.stdout.write(JSON.stringify({ results: acIds.map((ac) => ({ ac, status: 'UNDEC', msg: `复算器异常：${e && e.message ? e.message : String(e)}` })) }) + '\n');
  process.exit(0);
});
QA012_JUDGE_EOF

cat > "$WORK/fp.mjs" <<'QA012_FP_EOF'
// 可观测状态指纹（变异体自证用）—— **字节级 + 权限位**，不做语义归一化
// 用法: node fp.mjs <被验包目录> <项目根>
// 输出: "<项目根树指纹> <被验包树指纹>"
//
// ⚠️ **为什么不用语义归一化**：语义归一化（JSON 解析后按 key 排序再哈希）对**语义等价**的改动
//    恒不变 ⇒ ① 负控（键序重排）永远「没生效」⇒ 负控无效 ⇒ 门自己报「灵敏度不可判定」；
//    ② `chmod -x`（内容不变、权限位变了）也永远「没生效」⇒ 真检出被自证机制提前否决。
// ⇒ 本实现记 **原始字节 sha256 + 权限位**：任一条目变化 ⇒ 篡改生效。
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const [pkgDir, outRoot] = process.argv.slice(2);
const sha = (p) => {
  try { return crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex'); } catch { return 'MISSING'; }
};
const treeHash = (dir, skip) => {
  const lines = [];
  const base = path.resolve(dir);
  const walk = (d) => {
    if (!fs.existsSync(d)) return;
    lines.push(`D ${path.relative(base, d) || '.'}`);
    for (const n of fs.readdirSync(d).sort()) {
      const f = path.join(d, n);
      const rel = path.relative(base, f);
      if (skip && skip(rel)) continue;
      const st = fs.lstatSync(f);
      if (st.isDirectory()) walk(f);
      else if (st.isFile()) lines.push(`F ${rel} ${(st.mode & 0o7777).toString(8)} ${sha(f)}`);
    }
  };
  walk(base);
  return crypto.createHash('sha256').update(lines.join('\n')).digest('hex');
};
// 项目根树（夹具 + 产物 + 被改写的输入文件都在里面）
const root = treeHash(outRoot, null);
// 被验包树（**不做任何排除**）
//   ⚠️ 包装层（plan-load-run.mjs / .real.mjs）**不在这里排除**：排除掉就会把
//      「chmod -x」这类**权限位**改动一起藏掉（缺陷 2 的第二种形态）。
//      ⇒ 产物型（shim）变异体的自证改用**项目根树指纹**（包装层不在项目根里）；
//         静态文件型变异体用**被验包树指纹**（它压根不注入包装层）。
const pkg = treeHash(pkgDir, null);
process.stdout.write(`${root} ${pkg}\n`);
QA012_FP_EOF

# ---------------------------------------------------------------- 跑判据（独立复算器）

step "跑判据（独立复算器 judge.mjs —— 零 import 被验包）"

PKG_TREE_BEFORE="$(node "$WORK/fp.mjs" "$PKG" "$WORK" 2>/dev/null | cut -d' ' -f2)"
JUDGE_OUT="$WORK/judge.json"
node "$WORK/judge.mjs" "$PKG" "$WORK" "$ACCEPTANCE" "$DECISIONS" "$SIBLING_DIR" "${REQ012_SKIP_SIBLING:-0}" > "$JUDGE_OUT" 2> "$WORK/judge.err"
JUDGE_RC=$?
if [ "$JUDGE_RC" -ne 0 ]; then
  printf '⚠️ 复算器退出码 %s（stderr 见工作目录）—— 判据一律按不可判定处理\n' "$JUDGE_RC"
  cat "$WORK/judge.err" >&2 || true
fi

node -e '
const fs = require("fs");
let doc = { results: [] };
try { doc = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) { }
for (const r of (doc.results || [])) {
  process.stdout.write(`${r.status}\t${r.ac}\t${String(r.msg || "").replace(/[\t\r\n]+/g, " ")}\n`);
}
' "$JUDGE_OUT" > "$WORK/results.tsv" 2>/dev/null || true

SEEN_AC=0
while IFS=$'\t' read -r ST AC MSG; do
  [ -z "${AC:-}" ] && continue
  case "$ST" in
    PASS) ok "$AC" "$MSG"; SEEN_AC=$((SEEN_AC+1));;
    FAIL) bad "$AC" "$MSG"; SEEN_AC=$((SEEN_AC+1));;
    UNDEC) undec "$AC" "$MSG"; SEEN_AC=$((SEEN_AC+1));;
  esac
done < "$WORK/results.tsv"

# 复算器少给了判据 ⇒ 补「不可判定」（不可判定 ≠ 通过）
if [ "$SEEN_AC" -lt "$AC_COUNT" ]; then
  for ac in $(grep -oE '^### AC-[0-9]+' "$ACCEPTANCE" 2>/dev/null | sed 's/^### //'); do
    if [ ! -f "$RES_DIR/$ac.res" ]; then
      undec "$ac" "复算器没有给出这条判据的结论"
    fi
  done
fi

# ---------------------------------------------------------------- 只读被验包（门自身的硬约束）

PKG_TREE_AFTER="$(node "$WORK/fp.mjs" "$PKG" "$WORK" 2>/dev/null | cut -d' ' -f2)"
if [ -n "${PKG_TREE_BEFORE:-}" ] && [ "$PKG_TREE_BEFORE" != "$PKG_TREE_AFTER" ]; then
  printf 'FAIL GATE-READONLY —— 门跑前跑后，被验包的全树指纹变了（门写被验包了 ⇒ 门侧缺陷）\n'
  GATE_READONLY_BROKEN=1
else
  printf '被验包只读自检: 全树指纹未变 ✓\n'
fi
# ---------------------------------------------------------------- 变异体套件

MUT_TOTAL=0
MUT_DETECTED=0
MUT_ESCAPED=""
MUT_INVALID=""
MUT_NOTE=""
MUT_UNDEC=0
MUT_CONTROL_OK=0
MUT_MISSING_IMPL=0
MUT_CONTROL_FAILED=""

if [ "${REQ012_NO_MUT:-0}" = "1" ]; then
  printf '\n变异体套件: 已跳过（REQ012_NO_MUT=1）—— 不可判定，不计入通过；检出率结论以完整模式为准\n'
  MUT_NOTE="跳过"
else
  step "变异体套件（正控 + 负控；检测口径 = 新增失败键）"

  # ① 基线失败键（**只取 FAIL 行**）
  #    ⚠️ 失败键只取 `^FAIL` 行里的**第一个** AC 编号 —— PASS / UNDEC 行里也有 AC 编号，
  #    混进来 ⇒ 基线键集合变成全集 ⇒ 任何变异的「新增失败键」都恒为空 ⇒ 整套检测沦为橡皮章。
  BASE_FAILS="$(cat "$RES_DIR"/*.res 2>/dev/null | sed -n 's/^FAIL[[:space:]]\{1,\}\(AC-[0-9]\{3\}\).*/\1/p' | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//')"
  printf '%s\n' $BASE_FAILS | grep -v '^$' | LC_ALL=C sort -u > "$WORK/base_fails.txt"
  if [ -n "$BASE_FAILS" ]; then
    printf '基线本身不绿（失败键: [%s]）—— 变异检测以**新增失败键**为准\n' "$BASE_FAILS"
  else
    printf '基线失败键: []（基线全绿）\n'
  fi
  printf '检测口径: 新增失败键 = 变异运行的失败键 减去 基线失败键（整行精确排除；「消失的失败键」不算检出）\n'

  # ② 跑一次变异包，返回「新增失败键」（空格分隔）
  run_mutant_gate() { # $1 = 变异体包目录
    local mpkg="$1" mout
    mout="$(REQ012_NO_MUT=1 REQ012_SKIP_SIBLING=1 QA012_SCRIPT_SHA= bash "$SELF" "$mpkg" 2>&1)"
    printf '%s\n' "$mout" | sed -n 's/^FAIL[[:space:]]\{1,\}\(AC-[0-9]\{3\}\).*/\1/p' | LC_ALL=C sort -u | grep -v '^$' > "$WORK/mut_fails.txt"
    comm -13 "$WORK/base_fails.txt" "$WORK/mut_fails.txt" | tr '\n' ' ' | sed 's/ $//'
  }

  # ③ 注入包装层（shim）：原实现 move 到 plan-load-run.real.mjs，包装层跑完原实现后篡改产物
  #    ⚠️ 包装层必须**保留原文件的权限位**（否则「可执行位」判据把每个变异体都判红）。
  #    ⚠️ 篡改未生效时**只打标记、不改退出码**（否则门把「合法形态不被接受」判红 ⇒ 污染全部判定）。
  #    ⚠️ 篡改代码必须 **JS 内联**（node 跑 Python 语法的 .mjs 会 exit 3）。
  inject_shim() {
    local mpkg="$1" code="$2"
    local entry="$mpkg/skills/load-profile/scripts/plan-load-run.mjs"
    local mode; mode="$(stat -c '%a' "$entry" 2>/dev/null || echo 755)"
    mv "$entry" "$mpkg/skills/load-profile/scripts/plan-load-run.real.mjs" 2>/dev/null || return 1
    cat > "$entry" <<SHIMEOF
#!/usr/bin/env node
// 变异体包装层（只存在于变异副本里）：先跑原实现，再对产物做一处语义篡改。
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const real = path.join(here, 'plan-load-run.real.mjs');
const args = process.argv.slice(2);
const MUT = { pre: null, post: null };
const readJson = (f) => JSON.parse(fs.readFileSync(f, 'utf8'));
const writeJson = (f, v) => fs.writeFileSync(f, JSON.stringify(v, null, 2) + '\n');
const argOf = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : null; };
const outDir = argOf('--out-dir') || '';
const plansDir = path.join(outDir, 'test-assets', 'load', 'plans');
const listPlans = () => { try { return fs.readdirSync(plansDir).filter((n) => n.endsWith('.json')).sort(); } catch { return []; } };
const loadPlan = (n) => readJson(path.join(plansDir, n));
const savePlan = (n, v) => writeJson(path.join(plansDir, n), v);
const eachPlan = (fn) => { for (const n of listPlans()) { const p = loadPlan(n); if (!p) continue; fn(p, n); savePlan(n, p); } };

try {
${code}
} catch (e) {
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

  # ④ 变异体定义（**逐条对齐**；长度不一致 ⇒ 明确报红退出）
  MUT_NAMES=(
    "计划顶层多一个 note 字段"
    "场景条目少一个必填字段（删 profile_type）"
    "invocation 元素多一个键"
    "计划顶层出现 cases_file"
    "-t 的值被改（60→61）"
    "-d 的值被改（10000→10，秒当毫秒）"
    "--rps 被删掉"
    "-k 被删掉"
    "--cores 1 被改成 --cores 2"
    "URL 里丢掉 base_url（只留路径）"
    "多段画像被合并成一条 invocation"
    "-m POST 被改成 -m GET"
    "计划里出现 status: passed"
    "无来源的场景被补上阈值"
    "阈值数值被改（凭空改阈值）"
    "无来源场景的未决问题被清空"
    "无对应用例场景的未决问题被清空"
    "同一计划文件里未决问题 id 重复"
    "python 场景的 argv 残留占位符"
    "一个计划文件被删掉"
    "计划文件被改名成 suite.json"
    "计划里出现执行痕迹键 latency"
    "环境文件被改写（改 base_url）"
    "删掉 skills/load-profile/SKILL.md"
    "profile-rules.md 末尾被加了一行"
    "README 里的 load-profile 被删掉"
    "README 里的 plan-load-run.mjs 被删掉"
    "feature-meta/load-runner/traceability.md 被删掉"
    "feature-meta/load-runner/manifest.json 的 req 被改成 REQ-006"
    "feature-meta/load-profile/status.md 被改写"
    "plan-load-run.mjs 被删掉"
    "plan-load-run.mjs 被去掉可执行位"
    "test-execute 的 not_implemented 里 load 被删掉"
    "交付物里出现内部运行时字样"
    "package.json 的 files 里加了 feature-meta"
  )
  MUT_TARGETS=(
    "AC-004"
    "AC-004"
    "AC-004"
    "AC-004"
    "AC-014"
    "AC-015"
    "AC-016"
    "AC-016"
    "AC-012"
    "AC-009"
    "AC-011"
    "AC-010"
    "AC-019"
    "AC-020"
    "AC-020"
    "AC-021"
    "AC-021"
    "AC-021"
    "AC-018"
    "AC-013"
    "AC-013"
    "AC-022"
    "AC-024"
    "AC-002"
    "AC-002"
    "AC-003"
    "AC-003"
    "AC-027"
    "AC-027"
    "AC-027"
    "AC-001"
    "AC-001"
    "AC-028"
    "AC-029"
    "AC-029"
  )
  # 注入模式：shim = 入口脚本包装层（产物型）；file = 先改副本里的静态文件再跑门
  MUT_MODE=(
    "shim"
    "shim"
    "shim"
    "shim"
    "shim"
    "shim"
    "shim"
    "shim"
    "shim"
    "shim"
    "shim"
    "shim"
    "shim"
    "shim"
    "shim"
    "shim"
    "shim"
    "shim"
    "shim"
    "shim"
    "shim"
    "shim"
    "shim"
    "file"
    "file"
    "file"
    "file"
    "file"
    "file"
    "file"
    "file"
    "file"
    "file"
    "file"
    "file"
  )
  # 篡改代码（**JS 内联**）；shim 模式在包装层里执行，file 模式在被验包副本上执行
  MUT_CODE=(
    "MUT.post = () => { eachPlan((p) => { p.note = 'mutant'; }); };"
    "MUT.post = () => { eachPlan((p) => { for (const s of (p.scenarios || [])) delete s.profile_type; }); };"
    "MUT.post = () => { eachPlan((p) => { for (const s of (p.scenarios || [])) for (const inv of (s.invocations || [])) inv.mutated = true; }); };"
    "MUT.post = () => { eachPlan((p) => { p.cases_file = 'scenario.json'; }); };"
    "MUT.post = () => { eachPlan((p) => { for (const s of (p.scenarios || [])) for (const inv of (s.invocations || [])) { const i = inv.argv.indexOf('-t'); if (i >= 0 && inv.argv[i + 1] === '60') inv.argv[i + 1] = '61'; } }); };"
    "MUT.post = () => { eachPlan((p) => { for (const s of (p.scenarios || [])) for (const inv of (s.invocations || [])) { const i = inv.argv.indexOf('-d'); if (i >= 0) inv.argv[i + 1] = '10'; } }); };"
    "MUT.post = () => { eachPlan((p) => { for (const s of (p.scenarios || [])) for (const inv of (s.invocations || [])) { const i = inv.argv.indexOf('--rps'); if (i >= 0) { inv.argv.splice(i, 2); } } }); };"
    "MUT.post = () => { eachPlan((p) => { for (const s of (p.scenarios || [])) for (const inv of (s.invocations || [])) { const i = inv.argv.indexOf('-k'); if (i >= 0) { inv.argv.splice(i, 1); } } }); };"
    "MUT.post = () => { eachPlan((p) => { for (const s of (p.scenarios || [])) for (const inv of (s.invocations || [])) { const i = inv.argv.indexOf('--cores'); if (i >= 0) { inv.argv[i + 1] = '2'; } } }); };"
    "MUT.post = () => { eachPlan((p) => { for (const s of (p.scenarios || [])) { const u = s.base_url; for (const inv of (s.invocations || [])) { for (let k = 0; k < inv.argv.length; k++) { if (typeof inv.argv[k] === 'string' && inv.argv[k].startsWith('http')) inv.argv[k] = inv.argv[k].slice(u.length); } } } }); };"
    "MUT.post = () => { eachPlan((p) => { for (const s of (p.scenarios || [])) { if (Array.isArray(s.invocations) && s.invocations.length > 1) s.invocations = [s.invocations[0]]; } }); };"
    "MUT.post = () => { eachPlan((p) => { for (const s of (p.scenarios || [])) for (const inv of (s.invocations || [])) { const i = inv.argv.indexOf('-m'); if (i >= 0) inv.argv[i + 1] = 'GET'; } }); };"
    "MUT.post = () => { eachPlan((p) => { for (const s of (p.scenarios || [])) { s.status = 'passed'; } }); };"
    "MUT.post = () => { eachPlan((p) => { for (const s of (p.scenarios || [])) { if (s.thresholds_status === 'not_provided') { s.thresholds_status = 'provided'; s.thresholds = { p95_latency_ms: 1000 }; s.thresholds_source = '凭空造的来源'; } } }); };"
    "MUT.post = () => { eachPlan((p) => { for (const s of (p.scenarios || [])) { if (s.thresholds && typeof s.thresholds.p95_latency_ms === 'number') s.thresholds.p95_latency_ms = 500; } }); };"
    "MUT.post = () => { eachPlan((p) => { for (const s of (p.scenarios || [])) { if (s.thresholds_status === 'not_provided') s.open_questions = []; } }); };"
    "MUT.post = () => { eachPlan((p) => { for (const s of (p.scenarios || [])) { const oq = Array.isArray(s.open_questions) ? s.open_questions : []; if (oq.some((q) => q.topic === 'coverage')) s.open_questions = []; } }); };"
    "MUT.post = () => { eachPlan((p) => { for (const s of (p.scenarios || [])) { const oq = Array.isArray(s.open_questions) ? s.open_questions : []; if (oq.length > 0) { oq[0].id = 'OQ-001'; s.open_questions = oq; } } }); };"
    "MUT.post = () => { eachPlan((p) => { for (const s of (p.scenarios || [])) { if (s.runner !== 'python') continue; for (const inv of (s.invocations || [])) { for (let k = 0; k < inv.argv.length; k++) { if (inv.argv[k] === String(inv.duration_s)) inv.argv[k] = '{duration_s}'; } } } }); };"
    "MUT.post = () => { const ns = listPlans(); if (ns.length > 1) { try { fs.unlinkSync(path.join(plansDir, ns[ns.length - 1])); } catch (e) {} } };"
    "MUT.post = () => { const ns = listPlans(); if (ns.length > 0) { try { fs.renameSync(path.join(plansDir, ns[0]), path.join(plansDir, 'suite.json')); } catch (e) {} } };"
    "MUT.post = () => { eachPlan((p) => { for (const s of (p.scenarios || [])) s.latency = 12.5; }); };"
    "MUT.post = () => { const f = path.join(outDir, 'test-assets', 'environments', 'local.json'); if (!fs.existsSync(f)) return; const e = readJson(f); e.base_url = 'http://127.0.0.1:1/'; writeJson(f, e); };"
    "const fsx = require('fs'); try { fsx.unlinkSync(path.join(pkgRoot, 'skills', 'load-profile', 'SKILL.md')); } catch (e) {}"
    "const fsx = require('fs'); const f = path.join(pkgRoot, 'skills', 'load-profile', 'references', 'profile-rules.md'); fsx.appendFileSync(f, '\\n<!-- mutant -->\\n');"
    "const fsx = require('fs'); const f = path.join(pkgRoot, 'README.md'); fsx.writeFileSync(f, fsx.readFileSync(f, 'utf8').split(/\\r?\\n/).filter((l) => !l.includes('load-profile')).join('\\n'));"
    "const fsx = require('fs'); const f = path.join(pkgRoot, 'README.md'); fsx.writeFileSync(f, fsx.readFileSync(f, 'utf8').split(/\\r?\\n/).filter((l) => !l.includes('plan-load-run.mjs')).join('\\n'));"
    "const fsx = require('fs'); try { fsx.unlinkSync(path.join(pkgRoot, 'feature-meta', 'load-runner', 'traceability.md')); } catch (e) {}"
    "const fsx = require('fs'); const f = path.join(pkgRoot, 'feature-meta', 'load-runner', 'manifest.json'); const d = JSON.parse(fsx.readFileSync(f, 'utf8')); d.req = 'REQ-006'; fsx.writeFileSync(f, JSON.stringify(d, null, 2) + '\\n');"
    "const fsx = require('fs'); const f = path.join(pkgRoot, 'feature-meta', 'load-profile', 'status.md'); fsx.appendFileSync(f, '\\n<!-- mutant -->\\n');"
    "const fsx = require('fs'); try { fsx.unlinkSync(path.join(pkgRoot, 'skills', 'load-profile', 'scripts', 'plan-load-run.mjs')); } catch (e) {}"
    "const fsx = require('fs'); try { fsx.chmodSync(path.join(pkgRoot, 'skills', 'load-profile', 'scripts', 'plan-load-run.mjs'), 0o644); } catch (e) {}"
    "const fsx = require('fs'); const f = path.join(pkgRoot, 'skills', 'test-execute', 'executors', 'index.json'); const d = JSON.parse(fsx.readFileSync(f, 'utf8')); d.not_implemented = (d.not_implemented || []).filter((x) => x !== 'load'); fsx.writeFileSync(f, JSON.stringify(d, null, 2) + '\\n');"
    "const fsx = require('fs'); const f = path.join(pkgRoot, 'skills', 'load-profile', 'references', 'runner-adapters.md'); fsx.appendFileSync(f, '\\n<!-- '+['ma','vis'].join('')+'-data -->\\n');"
    "const fsx = require('fs'); const f = path.join(pkgRoot, 'package.json'); const d = JSON.parse(fsx.readFileSync(f, 'utf8')); d.files = (d.files || []).concat(['feature-meta']); fsx.writeFileSync(f, JSON.stringify(d, null, 2) + '\\n');"
  )
  MUT_REQUIRED=20

  # ⚠️ **数组长度自检**（门侧自洽）：名字 / 目标判据 / 模式 / 篡改代码必须**逐条对齐**。
  #    长度不一致 ⇒ 明确报红并退出，**不许**让 bash 崩在数组下标上。
  MUT_N="${#MUT_NAMES[@]}"; MUT_T="${#MUT_TARGETS[@]}"; MUT_M="${#MUT_MODE[@]}"; MUT_C="${#MUT_CODE[@]}"
  if [ "$MUT_N" -ne "$MUT_T" ] || [ "$MUT_N" -ne "$MUT_M" ] || [ "$MUT_N" -ne "$MUT_C" ]; then
    printf 'FAIL GATE-MUT —— 门侧变异体定义不自洽：NAMES=%s TARGETS=%s MODE=%s CODE=%s\n' "$MUT_N" "$MUT_T" "$MUT_M" "$MUT_C"
    MUT_UNDEC=1
    MUT_NOTE="不可判定：门侧变异体数组长度不一致（门侧缺陷，不是被验实现的问题）"
    MUT_INVALID="[门侧缺陷: 变异体数组长度不一致]"
  else
  # ⑤ 夹具自用的基准指纹（变异自证：变异后必须与基准不同）
  FXPROJ="$WORK/fx/proj"
  BASEFP=""
  BASEFP_PKG=""
  if [ -d "$FXPROJ" ] && [ -f "$PKG/skills/load-profile/scripts/plan-load-run.mjs" ]; then
    FPBASE="$WORK/fp-base"; mkdir -p "$FPBASE"; cp -r "$FXPROJ/." "$FPBASE/" 2>/dev/null
    node "$PKG/skills/load-profile/scripts/plan-load-run.mjs" --load-dir "$FPBASE" --out-dir "$FPBASE" >/dev/null 2>&1
    BASEFP="$(node "$WORK/fp.mjs" "$PKG" "$FPBASE" 2>/dev/null | cut -d' ' -f1)"
    BASEFP_PKG="$(node "$WORK/fp.mjs" "$PKG" "$FPBASE" 2>/dev/null | cut -d' ' -f2)"
  fi

  for i in "${!MUT_NAMES[@]}"; do
    NAME="${MUT_NAMES[$i]}"
    TARGET="${MUT_TARGETS[$i]}"
    CODE="${MUT_CODE[$i]}"
    MODE="${MUT_MODE[$i]}"
    MUTPKG="$WORK/mut-$i"
    mkdir -p "$MUTPKG"
    cp -r "$PKG"/. "$MUTPKG"/ 2>/dev/null
    STATUS="有效"
    if [ ! -f "$MUTPKG/skills/load-profile/scripts/plan-load-run.mjs" ]; then
      STATUS="**实现缺失**：入口脚本不存在 —— 变异体无法注入；这是实现未交付，不是门侧问题"
      MUT_MISSING_IMPL=1
    fi
    if [ "$STATUS" = "有效" ] && [ "$MODE" = "file" ]; then
      # 静态文件型：**先改副本里的文件，再跑门**（包装层碰不到被验包的静态文件）
      node -e "
        const fs = require('fs');
        const path = require('path');
        const pkgRoot = process.argv[1];
        try { $CODE } catch (e) { console.error('[mutant] 文件篡改失败: ' + e.message); process.exit(3); }
      " "$MUTPKG" >/dev/null 2>&1 || STATUS="静态文件篡改失败"
    fi
    if [ "$STATUS" = "有效" ] && [ "$MODE" = "shim" ]; then
      BEFORE_SHA="$(sha256sum "$MUTPKG/skills/load-profile/scripts/plan-load-run.mjs" 2>/dev/null | cut -d' ' -f1)"
      inject_shim "$MUTPKG" "$CODE" || STATUS="包装层注入失败"
      AFTER_SHA="$(sha256sum "$MUTPKG/skills/load-profile/scripts/plan-load-run.mjs" 2>/dev/null | cut -d' ' -f1)"
      if [ "$STATUS" = "有效" ] && { [ -z "${BEFORE_SHA:-}" ] || [ "${BEFORE_SHA:-}" = "${AFTER_SHA:-}" ]; }; then
        STATUS="注入前后 sha256 没变（注入未生效）"
      fi
      if [ "$STATUS" = "有效" ]; then
        node --check "$MUTPKG/skills/load-profile/scripts/plan-load-run.mjs" >/dev/null 2>&1 || STATUS="变异后 node --check 不通过"
      fi
    fi
    # 自证：变异**真的生效**（字节级 + 权限位的树指纹必须与基准不同）
    #   ⚠️ **自证与检测用两套可分离的观测量**：
    #     - 产物型（shim）：跑实现 + 比**项目根树指纹**（产物与被改写的输入文件都在里面）
    #     - 静态文件型：**不跑实现**（它改的就是静态文件，跑不起来恰恰是期望状态）+ 比**被验包树指纹**
    #   ⚠️ 跑失败时**不一律**判「崩溃假检出」：先看指纹变没变（变了 ⇒ 篡改生效 ⇒ 真检出）。
    if [ "$STATUS" = "有效" ]; then
      if [ -z "${BASEFP:-}" ] || [ -z "${BASEFP_PKG:-}" ]; then
        STATUS="基准指纹取不到（夹具或实现不可用）—— 该变异对这份实现无效"
      elif [ "$MODE" = "file" ]; then
        MUTFP_PKG="$(node "$WORK/fp.mjs" "$MUTPKG" "$WORK" 2>/dev/null | cut -d' ' -f2)"
        if [ -z "${MUTFP_PKG:-}" ] || [ "$MUTFP_PKG" = "$BASEFP_PKG" ]; then
          STATUS="篡改未生效（被验包树的字节级指纹与基准相同）—— 该变异对这份实现无效"
        fi
      else
        MUTPROJ="$WORK/mutproj-$i"
        mkdir -p "$MUTPROJ"
        cp -r "$FXPROJ/." "$MUTPROJ/" 2>/dev/null
        node "$MUTPKG/skills/load-profile/scripts/plan-load-run.mjs" --load-dir "$MUTPROJ" --out-dir "$MUTPROJ" >/dev/null 2>&1
        MRC=$?
        MUTFP="$(node "$WORK/fp.mjs" "$MUTPKG" "$MUTPROJ" 2>/dev/null | cut -d' ' -f1)"
        if [ "$MRC" -ne 0 ] && [ ! -d "$MUTPROJ/test-assets/load/plans" ]; then
          STATUS="变异后脚本没正常跑完：rc=$MRC 且没有产物 —— 崩溃造成的判红是假检出"
        elif [ -z "${MUTFP:-}" ] || [ "$MUTFP" = "$BASEFP" ]; then
          STATUS="篡改未生效（项目根树的字节级指纹与基准相同）—— 该变异对这份实现无效"
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

  # ⑥ 负控：打不到任何判据的**无害**篡改 —— 期望「未检出」。
  #    ⚠️ 无害篡改固定不变（两次跑结果相同）⇒ 不破坏幂等；只打乱计划的键序（内容不变）。
  CTRL_NAME="负控：把计划 JSON 的键序打乱（内容逐字不变）"
  CTRLPKG="$WORK/mut-control"
  mkdir -p "$CTRLPKG"
  cp -r "$PKG"/. "$CTRLPKG"/ 2>/dev/null
  CTRL_STATUS="有效"
  if [ ! -f "$CTRLPKG/skills/load-profile/scripts/plan-load-run.mjs" ]; then
    CTRL_STATUS="**实现缺失**：入口脚本不存在 —— 这是实现未交付，不是门侧问题"
    MUT_MISSING_IMPL=1
  else
    inject_shim "$CTRLPKG" "MUT.post = () => { for (const n of listPlans()) { const p = loadPlan(n); const out = {}; for (const k of Object.keys(p).reverse()) out[k] = p[k]; savePlan(n, out); } };" || CTRL_STATUS="包装层注入失败"
  fi
  if [ "$CTRL_STATUS" = "有效" ]; then
    node --check "$CTRLPKG/skills/load-profile/scripts/plan-load-run.mjs" >/dev/null 2>&1 || CTRL_STATUS="变异后 node --check 不通过"
  fi
  if [ "$CTRL_STATUS" = "有效" ]; then
    if [ -z "${BASEFP:-}" ]; then
      CTRL_STATUS="基准指纹取不到 —— 负控无效（探测器的灵敏度不可判定）"
    else
      CTRLPROJ="$WORK/ctrlproj"
      mkdir -p "$CTRLPROJ"
      cp -r "$FXPROJ/." "$CTRLPROJ/" 2>/dev/null
      node "$CTRLPKG/skills/load-profile/scripts/plan-load-run.mjs" --load-dir "$CTRLPROJ" --out-dir "$CTRLPROJ" >/dev/null 2>&1
      CRC=$?
      CTRLFP="$(node "$WORK/fp.mjs" "$CTRLPKG" "$CTRLPROJ" 2>/dev/null | cut -d' ' -f1)"
      if [ "$CRC" -ne 0 ]; then
        CTRL_STATUS="变异后脚本没正常跑完：rc=$CRC"
      elif [ -z "${CTRLFP:-}" ] || [ "$CTRLFP" = "$BASEFP" ]; then
        CTRL_STATUS="无害篡改没生效（项目根树的字节级指纹与基准相同）—— 负控无效（探测器的灵敏度不可判定）"
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

  # ⑦ 结论（责任方要指对）
  MUT_WHY="门侧注入问题：锚点不可达或注入不生效"
  if [ "$MUT_MISSING_IMPL" -eq 1 ]; then
    MUT_WHY="**实现缺失**：入口脚本不存在 —— 变异体无法注入；这是实现未交付，不是门侧问题"
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
printf '判据条数（动态取 acceptance.md 的 `### AC-`）: %s\n' "$AC_COUNT"
printf '决策号（动态取 decisions.md 的 `^## D` 标题行）: %s 条 [%s]\n' "$DECISION_COUNT" "$DECISION_IDS"
if [ "$MUT_NOTE" = "跳过" ]; then
  printf '变异体套件: 已跳过（REQ012_NO_MUT=1）—— 不可判定，检出率结论以完整模式为准\n'
elif [ -n "$MUT_ESCAPED" ]; then
  printf '变异体套件: %s —— 有变异体逃逸（真缺陷），整体判红\n' "$MUT_NOTE"
elif [ -n "$MUT_CONTROL_FAILED" ]; then
  printf '变异体套件: %s\n' "$MUT_NOTE"
  printf '负控失败：探测器疑似恒真 ⇒ 本门失效（门侧缺陷）—— %s\n' "$MUT_CONTROL_FAILED"
elif [ "$MUT_UNDEC" -eq 1 ]; then
  printf '不可判定: 1 项（变异体套件）—— %s\n' "$MUT_NOTE"
  if [ "$MUT_MISSING_IMPL" -eq 1 ]; then
    printf '  （这是**实现未交付**，不是门侧问题：变异体需要入口脚本才能注入。退出码为 1，判据结论仍以上面的 PASS/FAIL 为准）\n'
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
#   - 逃逸（MUT_ESCAPED）        ⇒ 判红（真缺陷）
#   - 负控失败（MUT_CONTROL_FAILED） ⇒ 判红（门侧缺陷：探测器恒真）
#   - 不可判定（MUT_UNDEC）       ⇒ 退出码非 0，但不判红也不判绿（门侧注入问题）
#   - 有效变异体必须全部检出（MUT_DETECTED == MUT_TOTAL）且数量达标（MUT_TOTAL >= MUT_REQUIRED）
#   - **门自身 stderr 有 bash 错误** ⇒ 门不干净 ⇒ 判定不可信 ⇒ 退出码非 0
#   - **门写了被验包** ⇒ 门不干净 ⇒ 退出码非 0
if [ "$BASH_ERR_LINES" -gt 0 ]; then
  printf 'FAIL GATE-STDERR —— 门自身在执行过程中产生了 %s 行 bash 错误（见 stderr）—— 判定不可信\n' "$BASH_ERR_LINES"
  exit 1
fi
if [ "$GATE_READONLY_BROKEN" -eq 1 ]; then
  printf 'FAIL GATE-READONLY —— 门写了被验包 —— 判定不可信\n'
  exit 1
fi
if [ "$FAIL" -eq 0 ] && [ "$UNDEC" -eq 0 ] && [ -z "$MUT_ESCAPED" ] && [ -z "$MUT_CONTROL_FAILED" ] \
   && { [ "${REQ012_NO_MUT:-0}" = "1" ] || { [ "$MUT_UNDEC" -eq 0 ] \
        && [ "$MUT_TOTAL" -ge "$MUT_REQUIRED" ] && [ "$MUT_DETECTED" -eq "$MUT_TOTAL" ] \
        && [ "$MUT_CONTROL_OK" -eq 1 ]; }; }; then
  exit 0
fi
exit 1
