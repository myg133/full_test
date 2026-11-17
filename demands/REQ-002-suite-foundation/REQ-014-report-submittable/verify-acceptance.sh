#!/usr/bin/env bash
# REQ-014 验收脚本 —— `test-report` 的**可提交化**（输出位置 + 证据内联 + 报告内脱敏）
#
# 判据集：AC-001~AC-020（条数从 acceptance.md 的 `### AC-` 实际条数动态取，不写死）
#
# 用法: verify-acceptance.sh <package-dir>
#   <package-dir> 指向**被验包根目录**（含 skills/ 与 bin/，以及 feature-meta/、README.md）
#
# 退出码: 0 = 全部通过; 1 = 有 AC 未通过 / 不可判定 / 变异体有逃逸; 2 = 用法错误
#
# 环境变量:
#   REQ014_NO_MUT=1   跳过变异体套件（快跑 / 嵌套运行用）
#   QA014_SCRIPT_SHA  期望的**本脚本自身** sha256；不匹配即判红并中止
#
# 设计要点（门是被验对象，不是脚手架 —— D65）:
#   - 只读被验包；一切变异都在**副本**上做，绝不在原地改被验对象。
#   - 夹具一律造在临时目录里；**指纹由本脚本自己算**，内嵌一份**独立**的指纹实现，
#     **绝不 import 被验包里的 fingerprint.mjs**（被验实现坏了会把门一起带偏）。
#   - 判据正文与本脚本的理解有出入时，以 acceptance.md 的判据正文为准；
#     分歧写进本脚本注释，并在 $WORK/OPEN-ISSUES.md 留档待裁定。
#   - 变异体套件的注入方式：**入口脚本包装（shim）** —— 把副本里的
#     `skills/test-report/scripts/make-report.mjs` 换成一层包装，包装调用原实现
#     （原文件 move 到 make-report.real.mjs）后再对**产物**做一处语义篡改。
#     为什么不用「源码字面量锚点」：本门在 Dev 实现之前就写好（先自测门、再派 Dev），
#     实现源码的字面量此刻不存在，无法预置锚点；包装式注入对任意实现都成立。
#   - 变异检出走**新增失败键**（变异运行的失败键 减去 基线失败键，整行精确排除）；
#     **不用**对称差：对称差把「基线红、变异后绿」也算成变化，那是噪声不是检出。
#   - 变异体套件里有一个**负控 M0**（打不到任何判据的无害篡改）：它必须**未检出**。
#     若 M0 也被报成「已检出」⇒ 探测器恒真 ⇒ 本门失效（门侧缺陷，判红）。
#
# ⚠️ 本门只判 REQ-014 的 20 条判据；`test-report` 的**既有**行为（计数重算、
#   回归对账、报告指纹、零依赖等）由 REQ-010 的门负责。本门**不重复**那些判据。

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
  AC_COUNT="$(grep -cE '^### AC-[0-9]+:' "$ACCEPTANCE" 2>/dev/null || echo 0)"
fi
[ -n "$AC_COUNT" ] || AC_COUNT=0

# ---------------------------------------------------------------- 自身 sha 前置检查

EXPECT_SHA="${QA014_SCRIPT_SHA:-}"
if [ -n "$EXPECT_SHA" ]; then
  SELF_SHA="$(sha256sum "$SELF" 2>/dev/null | cut -d' ' -f1)"
  if [ "$SELF_SHA" != "$EXPECT_SHA" ]; then
    echo "[FAIL] 验收脚本 sha 不匹配：期望 $EXPECT_SHA，实得 ${SELF_SHA:-<读不到>}" >&2
    echo "结论: 0 PASS / 1 FAIL" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------- 工作根

WORK="${QA014_WORK_ROOT:-}"
if [ -z "$WORK" ]; then
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/req014-verify.XXXXXX" 2>/dev/null || echo "")"
fi
if [ -z "$WORK" ] || ! mkdir -p "$WORK" 2>/dev/null; then
  echo "[error] 无法建立工作根（QA014_WORK_ROOT=$WORK）" >&2
  exit 1
fi
KEEP_WORK="${QA014_KEEP_WORK:-0}"
cleanup() {
  if [ "$KEEP_WORK" != "1" ]; then
    rm -rf "$WORK" 2>/dev/null || true
  fi
}
trap cleanup EXIT

RES_DIR="$WORK/res"
mkdir -p "$RES_DIR"
echo "[info] 判据条数（动态取 acceptance.md 的 \`### AC-\` 标题行）: $AC_COUNT"
echo "[info] 工作根: $WORK"

# ---------------------------------------------------------------- 被验实现定位

TR="$PKG/skills/test-report"
MAKE="$TR/scripts/make-report.mjs"
if [ ! -d "$TR" ]; then
  echo "[FAIL] 缺 skills/test-report/（前置条件不满足）" >&2
  echo "结论: 0 PASS / 1 FAIL" >&2
  exit 1
fi
if [ ! -f "$MAKE" ]; then
  echo "[FAIL] 缺 skills/test-report/scripts/make-report.mjs" >&2
  echo "结论: 0 PASS / 1 FAIL" >&2
  exit 1
fi

PASS_COUNT=0
FAIL_COUNT=0
UND_COUNT=0
FAIL_KEYS=""

# 记一条通过
ok() {
  local ac="$1"; shift
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS %s 满足\n' "$ac"
  printf 'PASS %s\n' "$ac" >> "$RES_DIR/keys.txt"
}

# 记一条不通过
bad() {
  local ac="$1"; shift
  local msg="$*"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAIL_KEYS="$FAIL_KEYS$ac
"
  printf 'FAIL %s 不满足\n' "$ac"
  printf '  · %s\n' "$msg"
  printf '%s\n' "$msg" >> "$RES_DIR/$ac.res"
  printf 'FAIL %s\n' "$ac" >> "$RES_DIR/keys.txt"
}

# 记一条不可判定
und() {
  local ac="$1"; shift
  local msg="$*"
  UND_COUNT=$((UND_COUNT + 1))
  printf 'UND %s 不可判定\n' "$ac"
  printf '  · %s\n' "$msg"
  printf '%s\n' "$msg" >> "$RES_DIR/$ac.res"
  printf 'UND %s\n' "$ac" >> "$RES_DIR/keys.txt"
}

step() { printf '\n--- %s\n' "$*"; }

# ---------------------------------------------------------------- 工装：独立指纹实现

cat > "$WORK/fingerprint.mjs" <<'FIXFP'
// fingerprint.mjs —— 判据自带的**独立**指纹实现；**不** import 被验包里的实现。
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

export const sha256Hex = (data) => createHash('sha256').update(data).digest('hex');

/** 目录内容的 sha256 清单（逐字快照用）。 */
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

// 命令行用法: node fingerprint.mjs <dir>
if (process.argv[1] && /fingerprint\.mjs$/.test(process.argv[1]) && process.argv[2]) {
  process.stdout.write(`${dirFingerprint(process.argv[2])}\n`);
}
FIXFP

# ---------------------------------------------------------------- 工装：目录快照

cat > "$WORK/snapdir.mjs" <<'FIXSNAP'
// snapdir.mjs —— 目录内每个文件的「相对路径 + sha256」清单（用于「输入产物逐字未变」）。
// 用法: node snapdir.mjs <dir>
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

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
      lines.push(`${path.relative(root, full)} ${hash}`);
    }
  }
};
if (root) walk(root);
lines.sort();
process.stdout.write(`${lines.join('\n')}\n`);
FIXSNAP

# ---------------------------------------------------------------- 工装：夹具

cat > "$WORK/mkfixture.mjs" <<'FIXMK'
// mkfixture.mjs —— 造 REQ-014 的夹具（acceptance.md §0.1 / §0.5 / §0.6）+ 真值 truth.json。
//
// ⚠️ 所有期望值（sha256 / 字节数 / 计数）**由本脚本在造完夹具后现算**，
//    **不写死任何臆测值**（判据纪律第 4 条）。
//
// 用法: node mkfixture.mjs <workdir>
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const WORK = process.argv[2];
if (!WORK) { console.error('用法: node mkfixture.mjs <workdir>'); process.exit(2); }

const sha = (data) => createHash('sha256').update(data).digest('hex');

function write(file, text) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text, 'utf8');
}

// ---------------------------------------------------------------- 证据内容（§0.3）

// TC-001：passed，**无敏感内容** ⇒ 验证「脱敏器不误伤」+ **验证追踪标识豁免（D219）**
// ⚠️ 故意放 32 位 hex（x-trace-id / trace_id / items[].id）：它们是业务标识，**不是**凭证，
//    按 D219 必须原样保留 ⇒ 抹掉就判红（AC-011 + AC-013 双向探针）。
const EV_TC001 = `${JSON.stringify({
  driver: 'api',
  request: { method: 'GET', path: '/api/v1/items', url: 'http://10.0.0.9:8080/api/v1/items', auth_mode: 'none' },
  response: {
    status_code: 200,
    headers: { 'content-type': 'application/json', 'x-trace-id': '0123456789abcdef0123456789abcdef' },
    body: {
      code: 'OK',
      trace_id: '0123456789abcdef0123456789abcdef',
      items: [{ id: 'fedcba9876543210fedcba9876543210', name: '样例' }],
    },
  },
}, null, 2)}\n`;

// TC-002：failed，含**内嵌明文口令** ⇒ 验证「值模式能兜住口令」
const EV_TC002 = `${JSON.stringify({
  driver: 'api',
  request: { method: 'POST', path: '/api/v1/login', url: 'http://10.0.0.9:8080/api/v1/login', auth_mode: 'basic (user:pass)' },
  response: {
    status_code: 401,
    headers: { 'content-type': 'application/json' },
    body: {
      code: 'UNAUTHENTICATED',
      user: { username: 'demo.user', password: 'PlainTextPwd123' },
      credential: 'PlainTextPwd123',
      note: '登录失败',
      permissions: ['page.secrets.view', 'page.secrets.manage'],
    },
  },
}, null, 2)}\n`;

// TC-003：blocked，含**敏感字段名** + 环境变量引用 + 长 hex 形态 ⇒ 验证「R1 换值但不动业务权限点」
const EV_TC003 = `${JSON.stringify({
  driver: 'api',
  request: { method: 'GET', path: '/api/v1/deps', url: 'http://10.0.0.9:8080/api/v1/deps', auth_mode: 'bearer (env: DEMO_TEST_TOKEN)' },
  response: {
    status_code: 503,
    headers: { 'content-type': 'application/json' },
    body: {
      code: 'DEPENDENCY_UNAVAILABLE',
      access_token: 'tok_live_ABCDEF0123456789ABCDEF0123456789',
      must_change_password: 'PlainTextPwd123',
      env_hint: 'DEMO_TEST_TOKEN',
      // ⚠️ **非豁免键**下的 32 位 hex ⇒ 属「疑似凭证」⇒ **必须被脱敏**（AC-014 的牙齿；
      //    与 TC-001 豁免键下的同类 hex 形成对照 ⇒ 证明豁免不是「一律放过长 hex」）。
      cache_key: 'aaaabbbbccccddddaaaabbbbccccdddd',
    },
  },
}, null, 2)}\n`;

// TC-004：skipped，**完全无敏感内容** ⇒ 验证「content_sha256 == sha256」
const EV_TC004 = `${JSON.stringify({
  driver: 'api',
  request: { method: 'GET', path: '/api/v1/health', url: 'http://10.0.0.9:8080/api/v1/health', auth_mode: 'none' },
  response: { status_code: 200, headers: { 'content-type': 'application/json' }, body: { status: 'UP' } },
}, null, 2)}\n`;

// §0.6 负控产物：同样四份，但**全部无敏感串**
const EV_NP001 = `${JSON.stringify({
  driver: 'api',
  request: { method: 'GET', path: '/api/v1/items', url: 'http://10.0.0.9:8080/api/v1/items', auth_mode: 'none' },
  response: {
    status_code: 200,
    headers: { 'content-type': 'application/json', 'x-trace-id': '0123456789abcdef0123456789abcdef' },
    body: {
      code: 'OK',
      trace_id: '0123456789abcdef0123456789abcdef',
      items: [{ id: 'fedcba9876543210fedcba9876543210', name: '样例' }],
    },
  },
}, null, 2)}\n`;
const EV_NP002 = `${JSON.stringify({
  driver: 'api',
  request: { method: 'POST', path: '/api/v1/login', url: 'http://10.0.0.9:8080/api/v1/login', auth_mode: 'basic (not-a-secret)' },
  response: { status_code: 401, headers: { 'content-type': 'application/json' }, body: { code: 'UNAUTHENTICATED', note: '登录失败' } },
}, null, 2)}\n`;
const EV_NP003 = `${JSON.stringify({
  driver: 'api',
  request: { method: 'GET', path: '/api/v1/deps', url: 'http://10.0.0.9:8080/api/v1/deps', auth_mode: 'none' },
  response: { status_code: 503, headers: { 'content-type': 'application/json' }, body: { code: 'DEPENDENCY_UNAVAILABLE' } },
}, null, 2)}\n`;
const EV_NP004 = EV_NP001;

// ---------------------------------------------------------------- 造一个产物目录

/**
 * 造一份执行产物目录。
 * @param {string} runDir 产物目录绝对路径
 * @param {string} runId run_id
 * @param {object} evMap case_id → 证据文本
 * @param {string[]} missingIds 声称有但文件故意缺失的 case_id
 * @returns {object} {meta, results, evidenceEntries}
 */
function buildRun(runDir, runId, evMap, missingIds, opts = {}) {
  const negative = opts.negative === true;
  const evidenceEntries = [];
  const caseIds = ['TC-001', 'TC-002', 'TC-003', 'TC-004', 'TC-005'];
  const statusOf = {
    'TC-001': 'passed', 'TC-002': 'failed', 'TC-003': 'blocked', 'TC-004': 'skipped', 'TC-005': 'failed',
  };
  const durationOf = {
    'TC-001': 50, 'TC-002': 80, 'TC-003': 60, 'TC-004': 10, 'TC-005': 100,
  };
  const titleOf = {
    'TC-001': '正常查询', 'TC-002': '登录失败', 'TC-003': '依赖不可用', 'TC-004': '跳过用例', 'TC-005': '证据缺失用例',
  };
  const errorOf = {
    'TC-001': null,
    'TC-002': { type: 'assertion_failed', message: 'status 期望 200 实得 401' },
    'TC-003': { type: 'dependency_unavailable', message: '上游服务不可达' },
    'TC-004': null,
    'TC-005': { type: 'assertion_failed', message: '产物缺证据' },
  };
  // ⚠️ D220：负控夹具（§0.6）声明「所有内容均无敏感串」⇒ `reproduction.command` 里
  //    **不得**出现敏感字段名（`password` 等）与内嵌明文口令。
  //    原实现三份夹具硬编码了**同一条**带 `"password":"PlainTextPwd123"` 的 command
  //    ⇒ 负控产物其实含敏感串，「脱敏器不凭空替换」这条判据根本无法成立
  //    （且判定类型写错 ⇒ 该分支永不触发）。
  //    按 §0.6 原文「口令改成 not-a-secret」保留一个**无害的**口令形态值，
  //    但键名不是敏感字段名（`passwd_hint`）⇒ R1/R2 都不命中。
  const reproOf = {
    'TC-001': null,
    'TC-002': {
      steps: ['POST /api/v1/login'],
      command: negative
        ? 'curl -X POST \'http://10.0.0.9:8080/api/v1/login\' -d \'{"username":"demo.user","passwd_hint":"not-a-secret","remember":false}\''
        : 'curl -X POST \'http://10.0.0.9:8080/api/v1/login\' -d \'{"username":"demo.user","password":"PlainTextPwd123","remember":false}\'',
      expected: null,
    },
    'TC-003': null, 'TC-004': null, 'TC-005': null,
  };

  const results = [];
  for (const caseId of caseIds) {
    const rel = `evidence/${caseId}/step-1-response.json`;
    const abs = path.join(runDir, rel);
    let sha256;
    let bytes;
    if (missingIds.includes(caseId)) {
      // 文件**故意不存在**；sha256 用一个确定性的占位（说明「声称有」）
      sha256 = sha(`missing:${caseId}`);
      bytes = 0;
    } else {
      const text = evMap[caseId];
      write(abs, text);
      const buf = Buffer.from(text, 'utf8');
      sha256 = sha(buf);
      bytes = buf.length;
      evidenceEntries.push({
        case_id: caseId,
        step: '1',
        path: rel,
        sha256,
        bytes,
        media_type: 'application/json',
      });
    }
    results.push({
      case_id: caseId,
      title: titleOf[caseId],
      requirement_refs: ['R-001'],
      status: statusOf[caseId],
      started_at: '2026-01-01T00:00:00.000Z',
      finished_at: '2026-01-01T00:00:00.000Z',
      duration_ms: durationOf[caseId],
      evidence: [{ path: rel, sha256, bytes, media_type: 'application/json' }],
      reproduction: reproOf[caseId],
      error: errorOf[caseId],
    });
  }

  const resultsText = `${JSON.stringify(results, null, 2)}\n`;
  write(path.join(runDir, 'results.json'), resultsText);

  // 证据清单指纹（§0.4）：按 path 排序，path\0sha256\0bytes\n 连接
  const parts = [];
  for (const e of evidenceEntries.slice().sort((a, b) => (a.path < b.path ? -1 : 1))) {
    parts.push(`${e.path}\u0000${e.sha256}\u0000${e.bytes}\n`);
  }
  const manifestSha = sha(parts.join(''));

  const meta = {
    run_id: runId,
    suite: 'REQ-DEMO-demo',
    scope: 'functional',
    requirement: 'REQ-DEMO',
    environment: 'mock-local',
    started_at: '2026-01-01T00:00:00.000Z',
    finished_at: '2026-01-01T00:00:01.000Z',
    duration_ms: 300,
    agent: 'demo-agent',
    executor: { name: 'mock', version: '0.1.0' },
    tool_versions: {},
    cases_total: 5,
    cases_passed: 1,
    cases_failed: 2,
    cases_blocked: 1,
    cases_skipped: 1,
    evidence_manifest_sha256: manifestSha,
    results_sha256: sha(Buffer.from(resultsText, 'utf8')),
    cases_file: 'test-assets/suites/REQ-DEMO-demo/cases.json',
    cycle: null,
    redaction: { rules_applied: [], redacted_fields: 0 },
  };
  write(path.join(runDir, 'meta.json'), `${JSON.stringify(meta, null, 2)}\n`);
  write(path.join(runDir, 'logs/runner.log'), 'demo runner log\n');

  return { meta, results, evidenceEntries };
}

// ---------------------------------------------------------------- 造夹具

const TPL = path.join(WORK, 'tpl');
const TPL2 = path.join(WORK, 'tpl2');
const TPL3 = path.join(WORK, 'tpl3');

// §0.1 形态合法（<root>/.test-artifacts/<id>）
const runA = path.join(TPL, '.test-artifacts', 'run-demo-0001');
const a = buildRun(runA, 'run-demo-0001', {
  'TC-001': EV_TC001, 'TC-002': EV_TC002, 'TC-003': EV_TC003, 'TC-004': EV_TC004,
}, ['TC-005']);

// §0.5 形态不合法（不在 .test-artifacts/ 下 ⇒ 反推不成立）
const runB = path.join(TPL2, 'ART');
const b = buildRun(runB, 'run-demo-0002', {
  'TC-001': EV_TC001, 'TC-002': EV_TC002, 'TC-003': EV_TC003, 'TC-004': EV_TC004,
}, ['TC-005']);

// §0.6 负控产物：全部无敏感串
const runC = path.join(TPL3, '.test-artifacts', 'run-demo-0003');
const c = buildRun(runC, 'run-demo-0003', {
  'TC-001': EV_NP001, 'TC-002': EV_NP002, 'TC-003': EV_NP003, 'TC-004': EV_NP004,
}, ['TC-005'], { negative: true });

// ---------------------------------------------------------------- 真值

const truth = {
  run_id: 'run-demo-0001',
  run_id2: 'run-demo-0002',
  run_id3: 'run-demo-0003',
  cases: { total: 5, passed: 1, failed: 2, blocked: 1, skipped: 1 },
  evidence_present: a.evidenceEntries.length,
  evidence_missing: 1,
  missing_path: 'evidence/TC-005/step-1-response.json',
  secret_plain: 'PlainTextPwd123',
  placeholder_field: '[REDACTED:field]',
  placeholder_secret: '[REDACTED:secret]',
  business_permission: 'page.secrets.view',
  env_hint: 'DEMO_TEST_TOKEN',
  trace_hex: '0123456789abcdef0123456789abcdef',
  id_hex: 'fedcba9876543210fedcba9876543210',
  artifact_rel: '.test-artifacts/run-demo-0001',
  evidence: a.evidenceEntries.map((e) => ({
    case_id: e.case_id,
    step: e.step,
    path: e.path,
    sha256: e.sha256,
    bytes: e.bytes,
    media_type: e.media_type,
  })),
};
write(path.join(WORK, 'truth.json'), `${JSON.stringify(truth, null, 2)}\n`);

process.stdout.write(`[ok] 夹具已造：tpl / tpl2 / tpl3；证据 ${truth.evidence_present} 份，缺失 ${truth.evidence_missing} 份\n`);
FIXMK

# ---------------------------------------------------------------- 工装：判定器

cat > "$WORK/judge.mjs" <<'FIXJUDGE'
// judge.mjs —— REQ-014 的 20 条判据判定（**独立**实现，不 import 被验包任何模块）。
//
// 用法: node judge.mjs <ctx.json>
// 输出: 每条判据一行 `PASS AC-xxx` / `FAIL AC-xxx` / `UND AC-xxx`，失败原因行以 `  · ` 开头。
//
// ctx.json 字段（见门的主流程）：
//   { ac_filter?: string[] | null, scenario: string, project_root, artifact_dir, run_id,
//     expected_out_dir, expected_artifacts_rel, report_json, report_md,
//     report_json2?, report_md2?, exit_code, stderr, default_report_dir_exists,
//     reports_root_created, snapshot_before, snapshot_after, neg_redaction_zero, truth }
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const ctx = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const truth = ctx.truth || {};
const filter = Array.isArray(ctx.ac_filter) ? new Set(ctx.ac_filter) : null;
const skip = Array.isArray(ctx.skip) ? new Set(ctx.skip) : null;

const sha = (data) => createHash('sha256').update(data).digest('hex');
const exists = (p) => { try { return fs.existsSync(p); } catch { return false; } };

/**
 * 读一个 JSON 文件。
 * @param {string} file 路径
 * @returns {{ok: boolean, value: *, raw: string, error: string}}
 */
function readJson(file) {
  if (!exists(file)) return { ok: false, value: null, raw: '', error: `文件不存在: ${file}` };
  let raw = '';
  try { raw = fs.readFileSync(file, 'utf8'); } catch (e) { return { ok: false, value: null, raw: '', error: `读不了: ${file}` }; }
  try { return { ok: true, value: JSON.parse(raw), raw, error: '' }; }
  catch (e) { return { ok: false, value: null, raw, error: `不是合法 JSON: ${file}` }; }
}

function readText(file) {
  if (!exists(file)) return null;
  try { return fs.readFileSync(file, 'utf8'); } catch { return null; }
}

const results = [];
/**
 * 记一条判定。
 * @param {string} ac 判据号
 * @param {boolean} ok 是否通过
 * @param {string[]} reasons 不通过的理由（可多条）
 */
function verdict(ac, ok, reasons) {
  if (filter && !filter.has(ac)) return;
  if (skip && skip.has(ac)) return;
  if (ok) results.push({ ac, status: 'PASS', reasons: [] });
  else results.push({ ac, status: 'FAIL', reasons: reasons && reasons.length ? reasons : ['（未给出理由）'] });
}

const RJ = ctx.report_json ? readJson(ctx.report_json) : { ok: false, value: null, raw: '', error: '无报告' };
const RM = ctx.report_md ? readText(ctx.report_md) : null;
const report = RJ.ok ? RJ.value : null;
const truthEvidence = new Map((truth.evidence || []).map((e) => [e.case_id, e]));

// ---------------------------------------------------------------- 判定主体
// ⚠️ 全局兜底：任何一条判据的实现里出错（抛异常）都**不许**让整个判定崩掉 ——
//    崩掉会让所有判据变成「判定器没有产出结果」的不可判定，掩盖真正的被验缺陷。
//    兜底做法：把出错信息记成一条 FAIL（归属到该场景的首条判据），其余照常输出。
try {
// ---------------------------------------------------------------- AC-001 默认输出位置

if (ctx.scenario === 'A') {
  const rj = exists(ctx.report_json);
  const rm = exists(ctx.report_md);
  const reasons = [];
  if (!rj) reasons.push(`默认输出目录下没有 report.json（期望 ${ctx.expected_out_dir}/report.json）`);
  if (!rm) reasons.push(`默认输出目录下没有 report.md（期望 ${ctx.expected_out_dir}/report.md）`);
  if (rj && path.dirname(path.resolve(ctx.report_json)) !== path.resolve(ctx.expected_out_dir)) {
    reasons.push(`report.json 不在预期输出目录 ${ctx.expected_out_dir}`);
  }
  if (ctx.default_report_dir_exists) {
    reasons.push(`旧默认位置 ${ctx.artifact_dir}/report/ 仍存在（新默认不该写那里）`);
  }
  if (report && report.source && typeof report.source.run_id === 'string'
      && report.source.run_id !== ctx.run_id) {
    reasons.push(`source.run_id=${report.source.run_id}，期望 ${ctx.run_id}`);
  }
  verdict('AC-001', reasons.length === 0, reasons);
}

// ---------------------------------------------------------------- AC-002 显式 --project-root

if (ctx.scenario === 'B') {
  const reasons = [];
  if (!exists(ctx.report_json)) reasons.push(`--project-root 指定后没有 report.json（期望 ${ctx.expected_out_dir}/report.json）`);
  if (!exists(ctx.report_md)) reasons.push(`--project-root 指定后没有 report.md`);
  if (report && report.source && report.source.run_id !== ctx.run_id) {
    reasons.push(`source.run_id=${report.source.run_id}，期望 ${ctx.run_id}（run_id 必须取自 meta.json，不是目录名）`);
  }
  verdict('AC-002', reasons.length === 0, reasons);
}

// ---------------------------------------------------------------- AC-003 形态合法时能反推

if (ctx.scenario === 'A') {
  const reasons = [];
  if (ctx.exit_code !== 0) reasons.push(`退出码 ${ctx.exit_code}（形态合法时不该要求显式 --project-root）`);
  if (typeof ctx.stderr === 'string' && ctx.stderr.includes('--project-root')) {
    reasons.push('stderr 提示必须给 --project-root（形态合法时不该要求）');
  }
  if (!exists(ctx.report_json)) reasons.push(`反推后没有产出 report.json（期望 ${ctx.expected_out_dir}）`);
  verdict('AC-003', reasons.length === 0, reasons);
}

// ---------------------------------------------------------------- AC-004 反推不成立 ⇒ 报错

if (ctx.scenario === 'C') {
  const reasons = [];
  if (ctx.exit_code !== 1) reasons.push(`退出码 ${ctx.exit_code}，期望 1（反推不成立时必须报错，不许猜项目根）`);
  if (!(typeof ctx.stderr === 'string' && ctx.stderr.includes('--project-root'))) {
    reasons.push('stderr 没有点名 --project-root');
  }
  if (exists(ctx.report_json) || exists(ctx.report_md)) {
    reasons.push('留下了半份报告（report.json / report.md 存在即算留下，0 字节也算）');
  }
  if (ctx.snapshot_before !== ctx.snapshot_after) reasons.push('输入产物目录没有逐字未变');
  const guesses = [
    path.join(ctx.project_root, 'reports', ctx.run_id, 'report.json'),
    path.join(ctx.artifact_dir, 'report', 'report.json'),
  ];
  for (const g of guesses) if (exists(g)) reasons.push(`在猜测的位置产出了报告: ${g}`);
  verdict('AC-004', reasons.length === 0, reasons);
}

// ---------------------------------------------------------------- AC-005 --out-dir 覆盖

if (ctx.scenario === 'D') {
  const reasons = [];
  if (!exists(ctx.report_json)) reasons.push(`--out-dir 指定的目录里没有 report.json（期望 ${ctx.expected_out_dir}）`);
  if (!exists(ctx.report_md)) reasons.push(`--out-dir 指定的目录里没有 report.md`);
  if (ctx.reports_root_created) reasons.push('用了 --out-dir 仍在项目根下创建了 reports/');
  verdict('AC-005', reasons.length === 0, reasons);
}

// ---------------------------------------------------------------- AC-006 files[] 覆盖全部实存证据

if (ctx.scenario === 'A') {
  const reasons = [];
  const files = report && report.evidence && Array.isArray(report.evidence.files) ? report.evidence.files : null;
  if (!files) {
    verdict('AC-006', false, ['report.evidence.files 不存在或不是数组']);
  } else {
    if (files.length !== truth.evidence_present) {
      reasons.push(`evidence.files 条数 ${files.length}，期望 ${truth.evidence_present}（实查存在的证据文件数）`);
    }
    const wantKeys = ['case_id', 'step', 'path', 'sha256', 'bytes', 'media_type', 'content', 'content_sha256'];
    for (const e of files) {
      const keys = e && typeof e === 'object' ? Object.keys(e).sort() : [];
      const want = wantKeys.slice().sort();
      if (JSON.stringify(keys) !== JSON.stringify(want)) {
        reasons.push(`条目键集不符：实得 [${keys.join(',')}]，期望 [${want.join(',')}]`);
      }
      const cid = e && e.case_id;
      const t = truthEvidence.get(cid);
      if (!t) { reasons.push(`出现了夹具里没有的 case_id=${cid}`); continue; }
      if (e.sha256 !== t.sha256) reasons.push(`${cid} 的 sha256 与实算不符（期望 ${t.sha256}，实得 ${e.sha256}）`);
      if (typeof e.path === 'string' && (e.path.startsWith('/') || e.path.includes(ctx.project_root))) {
        reasons.push(`${cid} 的 path 不是相对项目根的路径: ${e.path}`);
      }
      if (typeof e.bytes !== 'number' || e.bytes !== t.bytes) {
        reasons.push(`${cid} 的 bytes 与实算不符（期望 ${t.bytes}，实得 ${e.bytes}）`);
      }
    }
    for (const cid of ['TC-001', 'TC-004']) {
      if (!files.some((e) => e && e.case_id === cid)) {
        reasons.push(`${cid}（passed / skipped 用例）的证据没有内联 —— 不许只内联失败用例的`);
      }
    }
    verdict('AC-006', reasons.length === 0, reasons);
  }
}

// ---------------------------------------------------------------- AC-007 content / content_sha256

if (ctx.scenario === 'A') {
  const reasons = [];
  const files = report && report.evidence && Array.isArray(report.evidence.files) ? report.evidence.files : [];
  // ⚠️ 空集合不得**空洞通过**（D45：判据不许恒真）—— 没有条目可核时必须判红。
  if (files.length === 0) {
    reasons.push('evidence.files 为空，没有可核的条目（不许空洞通过）');
  }
  for (const e of files) {
    if (typeof e.content !== 'string' || e.content.length === 0) {
      reasons.push(`${e.case_id} 的 content 不是非空字符串`);
      continue;
    }
    const actual = sha(Buffer.from(e.content, 'utf8'));
    if (actual !== e.content_sha256) {
      reasons.push(`${e.case_id} 的 content_sha256 与 content 重算不符（重算 ${actual}，报告 ${e.content_sha256}）`);
    }
  }
  verdict('AC-007', reasons.length === 0, reasons);
}

// ---------------------------------------------------------------- AC-008 报告自包含

if (ctx.scenario === 'A' && ctx.self_contained_check) {
  const reasons = [];
  const files = report && report.evidence && Array.isArray(report.evidence.files) ? report.evidence.files : [];
  if (files.length === 0) reasons.push('没有内联证据内容');
  let tc002 = null;
  for (const e of files) {
    if (!e || typeof e.content !== 'string') continue;
    let parsed = null;
    try { parsed = JSON.parse(e.content); } catch { parsed = null; }
    if (parsed === null) {
      reasons.push(`${e.case_id} 的 content 不是可解析的 JSON（自包含要求内容可独立读取）`);
      continue;
    }
    if (e.case_id === 'TC-002') tc002 = parsed;
  }
  if (!tc002) reasons.push('TC-002 的证据内容读不到（移走产物目录后仍须可读）');
  else if (!tc002.response || !tc002.response.body || tc002.response.body.code !== 'UNAUTHENTICATED') {
    reasons.push('TC-002 的证据内容里读不到 body.code=UNAUTHENTICATED');
  }
  verdict('AC-008', reasons.length === 0, reasons);
}

// ---------------------------------------------------------------- AC-009 md 内联证据内容

if (ctx.scenario === 'A') {
  const reasons = [];
  if (RM === null) reasons.push('没有 report.md');
  else {
    if (!RM.includes('UNAUTHENTICATED')) reasons.push('md 正文里没有 TC-002 的证据内容（只列文件名不算）');
    if (!RM.includes('样例')) reasons.push('md 正文里没有 TC-001（passed）的证据内容');
  }
  verdict('AC-009', reasons.length === 0, reasons);
}

// ---------------------------------------------------------------- AC-010 缺失证据照旧点名

if (ctx.scenario === 'A') {
  const reasons = [];
  const ev = report && report.evidence ? report.evidence : {};
  const files = Array.isArray(ev.files) ? ev.files : [];
  if (files.some((e) => e && e.case_id === 'TC-005')) reasons.push('TC-005 的证据文件不存在，却进了 evidence.files[]');
  if (ev.files_missing !== truth.evidence_missing) {
    reasons.push(`evidence.files_missing=${ev.files_missing}，期望 ${truth.evidence_missing}`);
  }
  const mp = Array.isArray(ev.missing_paths) ? ev.missing_paths : [];
  if (!mp.some((p) => typeof p === 'string' && p.includes(truth.missing_path))) {
    reasons.push(`evidence.missing_paths 没有点名 ${truth.missing_path}`);
  }
  const findings = Array.isArray(ev.findings) ? ev.findings : [];
  const miss = findings.find((f) => f && f.kind === 'missing_evidence'
    && typeof f.message === 'string' && f.message.includes(truth.missing_path));
  if (!miss) reasons.push('evidence.findings 里没有一条 kind=missing_evidence 且点名缺失路径');
  if (report && report.verdict && report.verdict.evidence_layer !== 'fail') {
    reasons.push(`evidence_layer=${report.verdict.evidence_layer}，期望 fail`);
  }
  verdict('AC-010', reasons.length === 0, reasons);
}

// ---------------------------------------------------------------- AC-011 脱敏器不误伤

if (ctx.scenario === 'A') {
  const reasons = [];
  const files = report && report.evidence && Array.isArray(report.evidence.files) ? report.evidence.files : [];
  for (const cid of ['TC-001', 'TC-004']) {
    const e = files.find((x) => x && x.case_id === cid);
    if (!e) { reasons.push(`${cid} 的证据条目不在 files[] 里`); continue; }
    if (e.content_sha256 !== e.sha256) {
      reasons.push(`${cid} 无敏感内容却被改动（content_sha256 ${e.content_sha256} != sha256 ${e.sha256}）`);
    }
    // ⚠️ files[].path 是**相对项目根**的（契约 F2.2），不是相对产物目录 ⇒ 拼 artifact_dir 会找不到。
    const orig = readText(path.join(ctx.project_root, e.path));
    if (orig === null) {
      reasons.push(`${cid} 的原始证据文件读不到（按项目根 + path 拼：${path.join(ctx.project_root, e.path)}）`);
    } else if (orig !== e.content) {
      reasons.push(`${cid} 的 content 与原始文件不逐字相同`);
    }
  }
  verdict('AC-011', reasons.length === 0, reasons);
}

// ---------------------------------------------------------------- AC-012 明文口令不得出现

if (ctx.scenario === 'A') {
  const reasons = [];
  const combined = `${RJ.raw}\n${RM === null ? '' : RM}`;
  if (combined.includes(truth.secret_plain)) {
    reasons.push(`报告全文出现了明文口令 ${truth.secret_plain}`);
  }
  if (!combined.includes('[REDACTED:')) {
    reasons.push('报告全文没有占位符（口令没被替换？）');
  }
  verdict('AC-012', reasons.length === 0, reasons);
}

// ---------------------------------------------------------------- AC-013 敏感字段名换值但不误伤业务字段

if (ctx.scenario === 'A') {
  const reasons = [];
  const files = report && report.evidence && Array.isArray(report.evidence.files) ? report.evidence.files : [];
  const parsed = new Map();
  for (const e of files) {
    if (!e || typeof e.content !== 'string') continue;
    try { parsed.set(e.case_id, JSON.parse(e.content)); } catch { parsed.set(e.case_id, null); }
  }
  const tc003 = parsed.get('TC-003');
  const tc002 = parsed.get('TC-002');
  if (!tc003 || !tc003.response || !tc003.response.body) {
    reasons.push('TC-003 的证据内容解析不出来');
  } else {
    const body = tc003.response.body;
    for (const key of ['access_token', 'must_change_password']) {
      const v = body[key];
      if (typeof v !== 'string') reasons.push(`TC-003 的 body.${key} 不是字符串`);
      else if (v.includes(truth.secret_plain) || v.includes('tok_live_')) {
        reasons.push(`TC-003 的 body.${key} 没有被替换: ${v}`);
      } else if (!v.includes('[REDACTED:')) {
        reasons.push(`TC-003 的 body.${key} 不是占位符: ${v}`);
      }
    }
    if (body.env_hint !== truth.env_hint) {
      reasons.push(`TC-003 的 body.env_hint=${JSON.stringify(body.env_hint)}，期望逐字保留 ${truth.env_hint}（环境变量引用不该被抹掉）`);
    }
  }
  if (!tc002 || !tc002.response || !tc002.response.body) {
    reasons.push('TC-002 的证据内容解析不出来');
  } else {
    const perms = tc002.response.body.permissions;
    if (!Array.isArray(perms) || perms.length !== 2
        || perms[0] !== truth.business_permission || perms[1] !== 'page.secrets.manage') {
      reasons.push(`TC-002 的 body.permissions=${JSON.stringify(perms)}，期望逐字保留两个业务权限点`);
    }
  }
  // ⚠️ md 侧也要查：只看 json 会漏掉「md 过度脱敏」（json 干净、md 把业务权限点抹了）
  if (RM === null) {
    reasons.push('没有 report.md');
  } else {
    if (!RM.includes(truth.business_permission)) {
      reasons.push(`md 里没有 ${truth.business_permission}（业务权限点被过度脱敏了）`);
    }
    if (!RM.includes(truth.env_hint)) {
      reasons.push(`md 里没有 ${truth.env_hint}（环境变量引用被过度脱敏了）`);
    }
  }
  // ⚠️ D219 追踪/业务标识豁免：TC-001 的三个 32 位 hex 必须逐字保留
  const tc001 = parsed.get('TC-001');
  if (!tc001 || !tc001.response) {
    reasons.push('TC-001 的证据内容解析不出来');
  } else {
    const hdr = tc001.response.headers || {};
    const body = tc001.response.body || {};
    const item0 = Array.isArray(body.items) && body.items.length > 0 ? body.items[0] : {};
    if (hdr['x-trace-id'] !== truth.trace_hex) {
      reasons.push(`TC-001 的 headers.x-trace-id=${JSON.stringify(hdr['x-trace-id'])}，期望逐字保留 ${truth.trace_hex}（D219 豁免）`);
    }
    if (body.trace_id !== truth.trace_hex) {
      reasons.push(`TC-001 的 body.trace_id=${JSON.stringify(body.trace_id)}，期望逐字保留 ${truth.trace_hex}（D219 豁免）`);
    }
    if (item0.id !== truth.id_hex) {
      reasons.push(`TC-001 的 body.items[0].id=${JSON.stringify(item0.id)}，期望逐字保留 ${truth.id_hex}（D219 豁免）`);
    }
  }
  verdict('AC-013', reasons.length === 0, reasons);
}

// ---------------------------------------------------------------- AC-014 凭证字面量形态被替换

if (ctx.scenario === 'A') {
  const reasons = [];
  const combined = `${RJ.raw}\n${RM === null ? '' : RM}`;
  // 收集报告里所有「指纹字段」的值（这些是合法的长 hex）
  const allowed = new Set();
  const collect = (node) => {
    if (Array.isArray(node)) { for (const x of node) collect(x); return; }
    if (!node || typeof node !== 'object') return;
    for (const [k, v] of Object.entries(node)) {
      if (typeof v === 'string' && /sha256/i.test(k)) allowed.add(v);
      else collect(v);
    }
  };
  collect(report);
  // ⚠️ D219：追踪 / 业务标识**豁免**（trace_id / x-trace-id / id / uuid …）下的值
  //    也算合法 —— 否则 AC-014 与 D219 互相矛盾（豁免要保留，AC-014 却要抹）。
  const EXEMPT_KEY = /^(?:trace[_-]?id|x-trace-id|request[_-]?id|x-request-id|span[_-]?id|correlation[_-]?id|id|uuid)$/i;
  const collectExempt = (node) => {
    if (Array.isArray(node)) { for (const x of node) collectExempt(x); return; }
    if (!node || typeof node !== 'object') return;
    for (const [k, v] of Object.entries(node)) {
      if (EXEMPT_KEY.test(k) && typeof v === 'string') allowed.add(v);
      else collectExempt(v);
    }
  };
  collectExempt(report);
  // ⚠️ D222：本报告**自身算出的指纹**（findings 消息里会引用「meta.json 记 X，重算为 Y」）
  //    也是**合法**的长 hex —— 否则 AC-014 与 D221 互相矛盾（D221 要保留指纹，AC-014 却要抹）。
  //    口径：**从产物侧独立取**（读 meta.json / results.json，不抄报告里的值 ⇒ 判据保持独立），
  //    再加上**实存证据文件**的字节指纹（实现里 evidence.files[].sha256 是实算的）。
  const artDir = ctx.artifact_dir;
  try {
    const addHex = (v) => { if (typeof v === 'string' && /^[0-9a-f]{32,}$/i.test(v)) allowed.add(v); };
    const metaRaw = JSON.parse(fs.readFileSync(path.join(artDir, 'meta.json'), 'utf8'));
    addHex(metaRaw.results_sha256);
    addHex(metaRaw.evidence_manifest_sha256);
    const resRaw = JSON.parse(fs.readFileSync(path.join(artDir, 'results.json'), 'utf8'));
    for (const e of resRaw) {
      const ev = e && Array.isArray(e.evidence) ? e.evidence : [];
      for (const it of ev) {
        if (!it || typeof it.path !== 'string') continue;
        addHex(it.sha256);
        const abs = path.join(artDir, it.path);
        if (fs.existsSync(abs) && fs.statSync(abs).isFile()) allowed.add(sha(fs.readFileSync(abs)));
      }
    }
  } catch { /* 产物读不到就不补白名单，判据照常执行 */ }
  // 内联证据的 content 是 JSON **文本** ⇒ 也要解析后收集豁免值
  const files = report && report.evidence && Array.isArray(report.evidence.files) ? report.evidence.files : [];
  for (const e of files) {
    if (!e || typeof e.content !== 'string') continue;
    try { collectExempt(JSON.parse(e.content)); } catch { /* 不是 JSON 就跳过 */ }
  }
  const hexRe = /(?<![0-9a-fA-F])[0-9a-fA-F]{32,}(?![0-9a-fA-F])/g;
  const hits = combined.match(hexRe) || [];
  for (const h of hits) {
    if (!allowed.has(h)) reasons.push(`报告里出现了未豁免的长十六进制串（疑似凭证）: ${h.slice(0, 12)}…`);
  }
  if (/Bearer\s+[A-Za-z0-9._-]{16,}/.test(combined)) reasons.push('报告里出现了 Bearer <token> 形态');
  if (/[a-zA-Z0-9._%+-]+:[^@\s/]+@/.test(combined)) reasons.push('报告里出现了 user:pass@ 形态');
  verdict('AC-014', reasons.length === 0, reasons);
}

// ---------------------------------------------------------------- AC-015 报告内无绝对路径

if (ctx.scenario === 'A') {
  const reasons = [];
  const combined = `${RJ.raw}\n${RM === null ? '' : RM}`;
  if (combined.includes(ctx.project_root)) {
    reasons.push('报告全文出现了项目根的绝对路径');
  }
  if (report && report.source && typeof report.source.artifacts === 'string') {
    const a = report.source.artifacts;
    if (a.startsWith('/')) reasons.push(`source.artifacts 是绝对路径: ${a}`);
    else if (ctx.expected_artifacts_rel && a !== ctx.expected_artifacts_rel) {
      reasons.push(`source.artifacts=${a}，期望相对项目根的 ${ctx.expected_artifacts_rel}`);
    }
  } else {
    reasons.push('source.artifacts 缺失或不是字符串');
  }
  const files = report && report.evidence && Array.isArray(report.evidence.files) ? report.evidence.files : [];
  for (const e of files) {
    if (typeof e.path === 'string' && e.path.startsWith('/')) reasons.push(`${e.case_id} 的 path 是绝对路径: ${e.path}`);
  }
  verdict('AC-015', reasons.length === 0, reasons);
}

// ---------------------------------------------------------------- AC-016 redaction 段如实计数

if (ctx.scenario === 'A') {
  const reasons = [];
  const red = report ? report.redaction : undefined;
  if (!red || typeof red !== 'object') {
    verdict('AC-016', false, ['report.redaction 段不存在']);
  } else {
    const keys = Object.keys(red).sort();
    const want = ['redacted_fields', 'redacted_values', 'rules_applied'].slice().sort();
    if (JSON.stringify(keys) !== JSON.stringify(want)) {
      reasons.push(`redaction 键集不符：实得 [${keys.join(',')}]，期望 [${want.join(',')}]`);
    }
    if (!Array.isArray(red.rules_applied) || red.rules_applied.length === 0) {
      reasons.push('redaction.rules_applied 不是非空数组');
    } else {
      for (const r of red.rules_applied) {
        if (typeof r !== 'string' || r.length === 0) reasons.push('redaction.rules_applied 里有空/非字符串条目');
      }
    }
    if (typeof red.redacted_fields !== 'number' || red.redacted_fields <= 0) {
      reasons.push(`redaction.redacted_fields=${red.redacted_fields}，期望 > 0（本夹具确实有敏感内容）`);
    }
    if (typeof red.redacted_values !== 'number' || red.redacted_values <= 0) {
      reasons.push(`redaction.redacted_values=${red.redacted_values}，期望 > 0`);
    }
    const combined = `${RJ.raw}\n${RM === null ? '' : RM}`;
    if (!combined.includes(truth.placeholder_field)) {
      reasons.push(`报告里没有 ${truth.placeholder_field}（敏感字段名规则没生效）`);
    }
    if (!combined.includes(truth.placeholder_secret)) {
      reasons.push(`报告里没有 ${truth.placeholder_secret}（值模式规则没生效 —— 内嵌明文口令只可能被值模式抓住）`);
    }
    // ⚠️ D220：`ctx.neg_redaction_zero` 是**字符串**（'true' / 'false' / 'missing'）——
    //    原判定写成 `=== false`（布尔）⇒ 该分支**永不触发**（形同虚设的判据，D45/D71）。
    if (ctx.neg_redaction_zero === 'false') {
      reasons.push('负控夹具（全部无敏感串）仍报了非零替换计数 ⇒ 脱敏器凭空替换');
    } else if (ctx.neg_redaction_zero === 'missing') {
      reasons.push('负控夹具（全部无敏感串）没有 redaction 段 ⇒ 脱敏段缺失');
    }
    verdict('AC-016', reasons.length === 0, reasons);
  }
}

// ---------------------------------------------------------------- AC-017 自陈两个指纹的关系

if (ctx.scenario === 'A') {
  const reasons = [];
  if (RM === null) reasons.push('没有 report.md');
  else {
    if (!RM.includes('sha256')) reasons.push('md 里没有出现 sha256');
    if (!RM.includes('content_sha256')) reasons.push('md 里没有出现 content_sha256');
    if (!RM.includes('脱敏')) reasons.push('md 里没有解释「两者不等是因为脱敏」');
  }
  verdict('AC-017', reasons.length === 0, reasons);
}

// ---------------------------------------------------------------- AC-018 脱敏不影响证据层判定

if (ctx.scenario === 'A') {
  const reasons = [];
  const v = report && report.verdict ? report.verdict : {};
  if (v.evidence_layer !== 'fail') reasons.push(`evidence_layer=${v.evidence_layer}，期望 fail（脱敏不得影响判定）`);
  if (v.overall === 'pass') reasons.push('overall=pass（证据层已 fail，overall 不该为 pass）');
  const findings = report && report.evidence && Array.isArray(report.evidence.findings) ? report.evidence.findings : [];
  if (!findings.some((f) => f && typeof f.message === 'string' && f.message.includes(truth.missing_path))) {
    reasons.push('findings 里没有点名缺失证据路径');
  }
  verdict('AC-018', reasons.length === 0, reasons);
}

// ---------------------------------------------------------------- AC-019 输入产物逐字未变

if (ctx.scenario === 'A') {
  const reasons = [];
  if (ctx.snapshot_before !== ctx.snapshot_after) reasons.push('输入产物目录没有逐字未变（文件被新增/修改/删除）');
  verdict('AC-019', reasons.length === 0, reasons);
}

// ---------------------------------------------------------------- AC-020 幂等

if (ctx.scenario === 'A') {
  const reasons = [];
  if (report === null) {
    reasons.push(`报告没产出或读不出来（${ctx.report_json} 不存在或不是合法 JSON）`);
  } else {
    const rj2 = ctx.report_json2 ? readJson(ctx.report_json2) : { ok: false, value: null, raw: '', error: '无第二份' };
    if (!rj2.ok) {
      reasons.push(`第二份报告读不出来: ${rj2.error}`);
    } else {
      const strip = (o) => { const c = JSON.parse(JSON.stringify(o)); delete c.generated_at; return JSON.stringify(c); };
      if (strip(report) !== strip(rj2.value)) reasons.push('两份 report.json 剔除 generated_at 后不逐字相同');
    }
    const rm2 = ctx.report_md2 ? readText(ctx.report_md2) : null;
    if (RM === null || rm2 === null) reasons.push('缺一份 report.md');
    else {
      const tsRe = /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z/g;
      const a = RM.replace(tsRe, '<TS>');
      const b = rm2.replace(tsRe, '<TS>');
      if (a !== b) reasons.push('两份 report.md 剔除时间戳后不逐字相同');
    }
  }
  verdict('AC-020', reasons.length === 0, reasons);
}
} catch (err) {
  // 兜底：把异常记成一条 FAIL（归属到该场景的首条判据），不让整个判定崩掉
  const msg = err && err.message ? err.message : String(err);
  const owner = ctx.scenario === 'C' ? 'AC-004'
    : ctx.scenario === 'D' ? 'AC-005'
      : ctx.scenario === 'B' ? 'AC-002'
        : 'AC-001';
  if (!results.some((r) => r.ac === owner)) {
    results.push({ ac: owner, status: 'FAIL', reasons: [`判定器内部异常（门侧缺陷）: ${msg}`] });
  }
}

// ---------------------------------------------------------------- 输出

for (const r of results) {
  process.stdout.write(`${r.status} ${r.ac}\n`);
  for (const reason of r.reasons) process.stdout.write(`  · ${reason}\n`);
}
FIXJUDGE

# ---------------------------------------------------------------- 工装：变异注入包装

cat > "$WORK/mutant-shim.mjs" <<'FIXMUT'
// mutant-shim.mjs —— 变异注入包装（替换被验副本里的 make-report.mjs）。
//
// 注入方式（沿用 REQ-010 的「入口脚本包装」）：原实现 move 到 make-report.real.mjs，
// 本包装先调原实现，再对**产物**做一处语义篡改。
// 为什么在产物层注入：门在 Dev 实现之前就写好，实现源码的字面量此刻不存在。
//
// 变异标签（环境变量 REQ014_MUTANT_TAG）：
//   M1_outdir      报告写到 <run_dir>/report/（旧默认）
//   M2_guess_root  反推失败时不报错，瞎用 cwd 当项目根
//   M3_no_content  不内联证据内容
//   M4_bad_hash    content_sha256 算错
//   M5_abs_path    source.artifacts 保留绝对路径
//   M6_no_redact   明文口令不脱敏
//   M7_over_redact 脱敏器误伤（把业务权限点 / 环境变量引用也抹掉）
//   M8_no_exempt  D219 豁免不生效（把追踪/业务标识的 32 位 hex 也当凭证抹掉）
//   M0_neg        **负控**：顶层加一个无害字段（打不到任何判据）
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const TAG = process.env.REQ014_MUTANT_TAG || 'none';
const realPath = new URL('./make-report.real.mjs', import.meta.url).pathname;
const argv = process.argv.slice(2);

const argOf = (name) => {
  const i = argv.indexOf(name);
  if (i >= 0 && argv[i + 1] && !argv[i + 1].startsWith('--')) return argv[i + 1];
  const inline = argv.find((a) => a.startsWith(`${name}=`));
  return inline ? inline.slice(name.length + 1) : null;
};
const artifacts = argOf('--artifacts');

let r = spawnSync(process.execPath, [realPath, ...argv], { encoding: 'utf8' });
process.stdout.write(r.stdout || '');
process.stderr.write(r.stderr || '');

// M2：原实现因「反推不成立」报错时，**不报错**，改用 cwd 当项目根再跑一次
if (TAG === 'M2_guess_root' && r.status === 1 && !argv.includes('--project-root')) {
  const r2 = spawnSync(process.execPath, [realPath, ...argv, '--project-root', process.cwd()], { encoding: 'utf8' });
  process.stdout.write(r2.stdout || '');
  process.stderr.write(r2.stderr || '');
  r = r2;
}

if (TAG === 'M0_neg') {
  const m = /\[ok\] 报告已产出：(.+report\.json)/.exec(r.stdout || '');
  if (m) {
    const file = m[1].trim();
    try {
      const obj = JSON.parse(fs.readFileSync(file, 'utf8'));
      obj.note = 'harmless-note';
      fs.writeFileSync(file, `${JSON.stringify(obj, null, 2)}\n`, 'utf8');
    } catch { /* 保持原样 */ }
  }
  process.exit(r.status === null ? 1 : r.status);
}

const m = /\[ok\] 报告已产出：(.+report\.json)/.exec(r.stdout || '');
if (!m) process.exit(r.status === null ? 1 : r.status);
const reportJson = m[1].trim();
const reportMd = path.join(path.dirname(reportJson), 'report.md');

try {
  const obj = JSON.parse(fs.readFileSync(reportJson, 'utf8'));
  const files = obj.evidence && Array.isArray(obj.evidence.files) ? obj.evidence.files : [];
  // ⚠️ M6 / M7 是**文本级**篡改（改的是序列化后的原文）⇒ 必须标记出来，
  //    否则末尾把 obj 重新序列化会把文本篡改**覆盖掉**，变异体等于没注入（假逃逸）。
  let textModified = false;

  if (TAG === 'M1_outdir' && artifacts) {
    // 把报告挪回旧默认位置
    const oldDir = path.join(artifacts, 'report');
    fs.mkdirSync(oldDir, { recursive: true });
    for (const f of [reportJson, reportMd]) {
      if (fs.existsSync(f)) fs.copyFileSync(f, path.join(oldDir, path.basename(f)));
      if (fs.existsSync(f)) fs.unlinkSync(f);
    }
    fs.rmSync(path.dirname(reportJson), { recursive: true, force: true });
  }

  if (TAG === 'M3_no_content') {
    for (const e of files) delete e.content;
  }

  if (TAG === 'M4_bad_hash' && files.length > 0) {
    files[0].content_sha256 = 'f'.repeat(64);
  }

  if (TAG === 'M5_abs_path' && artifacts) {
    obj.source.artifacts = path.resolve(artifacts);
  }

  if (TAG === 'M6_no_redact') {
    textModified = true;
    const text = fs.readFileSync(reportJson, 'utf8');
    const restored = text
      .split('[REDACTED:field]').join('PlainTextPwd123')
      .split('[REDACTED:secret]').join('PlainTextPwd123');
    fs.writeFileSync(reportJson, restored, 'utf8');
    if (fs.existsSync(reportMd)) {
      const md = fs.readFileSync(reportMd, 'utf8')
        .split('[REDACTED:field]').join('PlainTextPwd123')
        .split('[REDACTED:secret]').join('PlainTextPwd123');
      fs.writeFileSync(reportMd, md, 'utf8');
    }
  }

  if (TAG === 'M7_over_redact') {
    textModified = true;
    const text = fs.readFileSync(reportJson, 'utf8');
    const over = text
      .split('page.secrets.view').join('[REDACTED:field]')
      .split('page.secrets.manage').join('[REDACTED:field]')
      .split('DEMO_TEST_TOKEN').join('[REDACTED:field]');
    fs.writeFileSync(reportJson, over, 'utf8');
    if (fs.existsSync(reportMd)) {
      const md = fs.readFileSync(reportMd, 'utf8')
        .split('page.secrets.view').join('[REDACTED:field]')
        .split('page.secrets.manage').join('[REDACTED:field]')
        .split('DEMO_TEST_TOKEN').join('[REDACTED:field]');
      fs.writeFileSync(reportMd, md, 'utf8');
    }
  }

  if (TAG === 'M8_no_exempt') {
    // D219 豁免不生效：把追踪/业务标识的 32 位 hex 也当凭证抹掉
    textModified = true;
    const text = fs.readFileSync(reportJson, 'utf8');
    fs.writeFileSync(reportJson, text.split('0123456789abcdef0123456789abcdef').join('[REDACTED:secret]'), 'utf8');
    if (fs.existsSync(reportMd)) {
      const md = fs.readFileSync(reportMd, 'utf8');
      fs.writeFileSync(reportMd, md.split('0123456789abcdef0123456789abcdef').join('[REDACTED:secret]'), 'utf8');
    }
  }

  if (!textModified) {
    fs.writeFileSync(reportJson, `${JSON.stringify(obj, null, 2)}\n`, 'utf8');
  }
} catch { /* 注入失败就保持原样 */ }

process.exit(r.status === null ? 1 : r.status);
FIXMUT

# ---------------------------------------------------------------- 造夹具

node "$WORK/mkfixture.mjs" "$WORK" || { echo "[FAIL] 夹具造失败" >&2; echo "结论: 0 PASS / 1 FAIL" >&2; exit 1; }
TRUTH="$WORK/truth.json"

# ---------------------------------------------------------------- 判定辅助

# 跑一次判定，把结果落到 $WORK/judge-<tag>.out
run_judge() {
  local ctxf="$1"; shift
  local tag="$1"; shift
  node "$WORK/judge.mjs" "$ctxf" > "$WORK/judge-$tag.out" 2>"$WORK/judge-$tag.err"
}

# 取某次判定里 FAIL 的判据键（整行精确）
fail_keys_of() {
  local tag="$1"
  grep -E '^FAIL AC-[0-9]+$' "$WORK/judge-$tag.out" 2>/dev/null | sort -u
}

# ---------------------------------------------------------------- 场景 E（负控夹具：全部无敏感串）

step "场景 E · 负控夹具（全部无敏感串）"
FXE="$WORK/fxE"
cp -r "$WORK/tpl3" "$FXE"
ARTE="$FXE/.test-artifacts/run-demo-0003"
node "$MAKE" --artifacts "$ARTE" >"$WORK/e.out" 2>"$WORK/e.err"
RC_E=$?
NEG_ZERO="missing"
if [ "$RC_E" -eq 0 ] && [ -f "$FXE/reports/run-demo-0003/report.json" ]; then
  NZ="$(node -e '
    const fs=require("fs");
    try{
      const o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      const r=o.redaction||{};
      if (typeof r.redacted_fields!=="number") { process.stdout.write("missing"); }
      else {
        const ok = r.redacted_fields===0 && r.redacted_values===0;
        process.stdout.write(ok?"true":"false");
      }
    }catch(e){process.stdout.write("missing");}
  ' "$FXE/reports/run-demo-0003/report.json")"
  NEG_ZERO="$NZ"
fi
echo "[info] 负控夹具替换计数为零: $NEG_ZERO（rc=$RC_E）"

# ---------------------------------------------------------------- 场景 A（默认输出 + 主体判据）

step "场景 A · 默认输出（形态合法，反推项目根）"
FXA="$WORK/fxA"
cp -r "$WORK/tpl" "$FXA"
ART_A="$FXA/.test-artifacts/run-demo-0001"
OUT_A="$FXA/reports/run-demo-0001"
# ⚠️ 快照 before 必须在**跑之前**取
node "$WORK/snapdir.mjs" "$ART_A" > "$WORK/snap_before.txt"
node "$MAKE" --artifacts "$ART_A" >"$WORK/a.out" 2>"$WORK/a.err"
RC_A=$?
# 幂等用的另两次运行（不同输出目录）
node "$MAKE" --artifacts "$ART_A" --out-dir "$WORK/idem1" >"$WORK/a2.out" 2>"$WORK/a2.err"
node "$MAKE" --artifacts "$ART_A" --out-dir "$WORK/idem2" >"$WORK/a3.out" 2>"$WORK/a3.err"
node "$WORK/snapdir.mjs" "$ART_A" > "$WORK/snap_after.txt"
DEF_REPORT_DIR_EXISTS="false"
if [ -d "$ART_A/report" ]; then DEF_REPORT_DIR_EXISTS="true"; fi

node -e '
  const fs = require("fs");
  const truth = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const ctx = {
    scenario: "A",
    project_root: process.argv[2],
    artifact_dir: process.argv[3],
    run_id: "run-demo-0001",
    expected_out_dir: process.argv[4],
    expected_artifacts_rel: ".test-artifacts/run-demo-0001",
    report_json: process.argv[4] + "/report.json",
    report_md: process.argv[4] + "/report.md",
    report_json2: process.argv[5] + "/report.json",
    report_md2: process.argv[5] + "/report.md",
    exit_code: Number(process.argv[6]),
    stderr: fs.readFileSync(process.argv[7], "utf8"),
    default_report_dir_exists: fs.existsSync(process.argv[3] + "/report"),
    reports_root_created: true,
    snapshot_before: fs.readFileSync(process.argv[8], "utf8"),
    snapshot_after: fs.readFileSync(process.argv[9], "utf8"),
    neg_redaction_zero: process.argv[10],
    truth,
  };
  fs.writeFileSync(process.argv[11], JSON.stringify(ctx, null, 2));
' "$TRUTH" "$FXA" "$ART_A" "$OUT_A" "$WORK/idem2" "$RC_A" "$WORK/a.err" "$WORK/snap_before.txt" "$WORK/snap_after.txt" "$NEG_ZERO" "$WORK/ctxA.json"

run_judge "$WORK/ctxA.json" A

# ---------------------------------------------------------------- 场景 A'（自包含：移走产物目录）

step "场景 A' · 自包含（移走产物目录后再读报告）"
mv "$FXA/.test-artifacts" "$WORK/hidden-artifacts"
node -e '
  const fs = require("fs");
  const ctx = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  ctx.ac_filter = ["AC-008"];
  ctx.self_contained_check = true;
  fs.writeFileSync(process.argv[2], JSON.stringify(ctx, null, 2));
' "$WORK/ctxA.json" "$WORK/ctxA8.json"
run_judge "$WORK/ctxA8.json" A8
mv "$WORK/hidden-artifacts" "$FXA/.test-artifacts"

# ---------------------------------------------------------------- 场景 B（显式 --project-root）

step "场景 B · 显式 --project-root"
FXB="$WORK/fxB"
cp -r "$WORK/tpl2" "$FXB"
ART_B="$FXB/ART"
OUT_B="$FXB/reports/run-demo-0002"
node "$MAKE" --artifacts "$ART_B" --project-root "$FXB" >"$WORK/b.out" 2>"$WORK/b.err"
RC_B=$?
node -e '
  const fs = require("fs");
  const truth = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  fs.writeFileSync(process.argv[8], JSON.stringify({
    scenario: "B",
    project_root: process.argv[2],
    artifact_dir: process.argv[3],
    run_id: "run-demo-0002",
    expected_out_dir: process.argv[4],
    expected_artifacts_rel: "ART",
    report_json: process.argv[4] + "/report.json",
    report_md: process.argv[4] + "/report.md",
    exit_code: Number(process.argv[5]),
    stderr: fs.readFileSync(process.argv[6], "utf8"),
    truth,
  }, null, 2));
' "$TRUTH" "$FXB" "$ART_B" "$OUT_B" "$RC_B" "$WORK/b.err" "" "$WORK/ctxB.json"
run_judge "$WORK/ctxB.json" B

# ---------------------------------------------------------------- 场景 C（反推不成立 ⇒ 报错）

step "场景 C · 反推不成立（必须报错，不许猜）"
FXC="$WORK/fxC"
cp -r "$WORK/tpl2" "$FXC"
ART_C="$FXC/ART"
node "$WORK/snapdir.mjs" "$ART_C" > "$WORK/snapC_before.txt"
node "$MAKE" --artifacts "$ART_C" >"$WORK/c.out" 2>"$WORK/c.err"
RC_C=$?
node "$WORK/snapdir.mjs" "$ART_C" > "$WORK/snapC_after.txt"
node -e '
  const fs = require("fs");
  const truth = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  fs.writeFileSync(process.argv[8], JSON.stringify({
    scenario: "C",
    project_root: process.argv[2],
    artifact_dir: process.argv[3],
    run_id: "run-demo-0002",
    expected_out_dir: process.argv[2] + "/reports/run-demo-0002",
    expected_artifacts_rel: "ART",
    exit_code: Number(process.argv[4]),
    stderr: fs.readFileSync(process.argv[5], "utf8"),
    snapshot_before: fs.readFileSync(process.argv[6], "utf8"),
    snapshot_after: fs.readFileSync(process.argv[7], "utf8"),
    truth,
  }, null, 2));
' "$TRUTH" "$FXC" "$ART_C" "$RC_C" "$WORK/c.err" "$WORK/snapC_before.txt" "$WORK/snapC_after.txt" "$WORK/ctxC.json"
run_judge "$WORK/ctxC.json" C

# ---------------------------------------------------------------- 场景 D（--out-dir 覆盖）

step "场景 D · --out-dir 覆盖"
FXD="$WORK/fxD"
cp -r "$WORK/tpl" "$FXD"
ART_D="$FXD/.test-artifacts/run-demo-0001"
OUT_D="$WORK/elsewhere"
rm -rf "$OUT_D"; mkdir -p "$OUT_D"
node "$MAKE" --artifacts "$ART_D" --out-dir "$OUT_D" >"$WORK/d.out" 2>"$WORK/d.err"
RC_D=$?
REPORTS_ROOT_CREATED="false"
if [ -d "$FXD/reports" ]; then REPORTS_ROOT_CREATED="true"; fi
node -e '
  const fs = require("fs");
  const truth = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  fs.writeFileSync(process.argv[8], JSON.stringify({
    scenario: "D",
    project_root: process.argv[2],
    artifact_dir: process.argv[3],
    run_id: "run-demo-0001",
    expected_out_dir: process.argv[4],
    report_json: process.argv[4] + "/report.json",
    report_md: process.argv[4] + "/report.md",
    exit_code: Number(process.argv[5]),
    stderr: fs.readFileSync(process.argv[6], "utf8"),
    reports_root_created: process.argv[7] === "true",
    truth,
  }, null, 2));
' "$TRUTH" "$FXD" "$ART_D" "$OUT_D" "$RC_D" "$WORK/d.err" "$REPORTS_ROOT_CREATED" "$WORK/ctxD.json"
run_judge "$WORK/ctxD.json" D

# ---------------------------------------------------------------- 汇总各场景判定

step "汇总判定结果"
for pair in "A:AC-001 AC-003 AC-006 AC-007 AC-009 AC-010 AC-011 AC-012 AC-013 AC-014 AC-015 AC-016 AC-017 AC-018 AC-019 AC-020" \
            "A8:AC-008" \
            "B:AC-002" \
            "C:AC-004" \
            "D:AC-005"; do
  tag="${pair%%:*}"; acs="${pair#*:}"
  for ac in $acs; do
    line="$(grep -E "^(PASS|FAIL|UND) ${ac}$" "$WORK/judge-$tag.out" 2>/dev/null | head -1)"
    if [ -z "$line" ]; then
      und "$ac" "判定器没有产出该判据的结果（门侧问题）"
    else
      status="${line%% *}"
      if [ "$status" = "PASS" ]; then
        ok "$ac" ""
      else
        reasons="$(grep -A20 -E "^(FAIL|UND) ${ac}$" "$WORK/judge-$tag.out" | sed -n '2,20p' | grep '^  · ' | sed 's/^  · //' | tr '\n' ' ')"
        if [ "$status" = "FAIL" ]; then bad "$ac" "${reasons:-（判定器未给出理由）}"; else und "$ac" "${reasons:-不可判定}"; fi
      fi
    fi
  done
done

# ---------------------------------------------------------------- 变异体套件

MUT_N=0
MUT_DETECTED=0
MUT_ESCAPED=0
MUT_INVALID=0
MUT_LIST=""

if [ "${REQ014_NO_MUT:-0}" = "1" ]; then
  echo "[info] 变异体套件: 已跳过（REQ014_NO_MUT=1）—— 不可判定，检出率结论以完整模式为准"
else
  step "变异体套件"

  # 基线失败键（场景 A + B + C + D 全部判定的 FAIL 键；**只取判据号**，不含 PASS/FAIL 前缀）
  cat "$WORK/judge-A.out" "$WORK/judge-A8.out" "$WORK/judge-B.out" "$WORK/judge-C.out" "$WORK/judge-D.out" 2>/dev/null \
    | grep -E '^FAIL AC-[0-9]+$' | sed -E 's/^FAIL //' | sort -u > "$WORK/baseline-fails.txt"
  BASELINE_FAILS="$(cat "$WORK/baseline-fails.txt")"
  if [ -n "$BASELINE_FAILS" ]; then
    echo "[warn] 基线本身有失败键（变异检出会被噪声污染）："
    printf '%s\n' "$BASELINE_FAILS" | sed 's/^/  · /'
  fi

  # 变异体定义：标签|目标判据
  MUTANTS="M1_outdir|AC-001
M2_guess_root|AC-004
M3_no_content|AC-006
M4_bad_hash|AC-007
M5_abs_path|AC-015
M6_no_redact|AC-012
M7_over_redact|AC-013
M8_no_exempt|AC-011
M0_neg|(负控)"

  while IFS='|' read -r tag target; do
    [ -n "$tag" ] || continue
    MUT_N=$((MUT_N + 1))
    MDIR="$WORK/mut/$tag"
    rm -rf "$MDIR"; mkdir -p "$MDIR"
    cp -r "$PKG" "$MDIR/pkg"
    MMAKE="$MDIR/pkg/skills/test-report/scripts/make-report.mjs"
    if [ ! -f "$MMAKE" ]; then
      MUT_INVALID=$((MUT_INVALID + 1))
      echo "变异体 $tag: 注入失败（副本里没有 make-report.mjs）"
      continue
    fi
    mv "$MMAKE" "$MDIR/pkg/skills/test-report/scripts/make-report.real.mjs"
    cp "$WORK/mutant-shim.mjs" "$MMAKE"

    # 场景 A 副本
    cp -r "$WORK/tpl" "$MDIR/fxA"
    MART_A="$MDIR/fxA/.test-artifacts/run-demo-0001"
    MOUT_A="$MDIR/fxA/reports/run-demo-0001"
    REQ014_MUTANT_TAG="$tag" node "$MMAKE" --artifacts "$MART_A" >"$MDIR/a.out" 2>"$MDIR/a.err"
    MRC_A=$?
    # 场景 C 副本（反推不成立）
    cp -r "$WORK/tpl2" "$MDIR/fxC"
    MART_C="$MDIR/fxC/ART"
    REQ014_MUTANT_TAG="$tag" node "$MMAKE" --artifacts "$MART_C" >"$MDIR/c.out" 2>"$MDIR/c.err"
    MRC_C=$?

    node -e '
      const fs = require("fs");
      const truth = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const root = process.argv[2];
      fs.writeFileSync(root + "/ctxA.json", JSON.stringify({
        scenario: "A", project_root: root + "/fxA", artifact_dir: root + "/fxA/.test-artifacts/run-demo-0001",
        run_id: "run-demo-0001", expected_out_dir: root + "/fxA/reports/run-demo-0001",
        expected_artifacts_rel: ".test-artifacts/run-demo-0001",
        report_json: root + "/fxA/reports/run-demo-0001/report.json",
        report_md: root + "/fxA/reports/run-demo-0001/report.md",
        exit_code: Number(process.argv[3]), stderr: fs.readFileSync(root + "/a.err", "utf8"),
        default_report_dir_exists: fs.existsSync(root + "/fxA/.test-artifacts/run-demo-0001/report"),
        reports_root_created: true, snapshot_before: "", snapshot_after: "", neg_redaction_zero: "true",
        skip: ["AC-020"], truth,
      }, null, 2));
      fs.writeFileSync(root + "/ctxC.json", JSON.stringify({
        scenario: "C", project_root: root + "/fxC", artifact_dir: root + "/fxC/ART",
        run_id: "run-demo-0002", expected_out_dir: root + "/fxC/reports/run-demo-0002",
        expected_artifacts_rel: "ART",
        exit_code: Number(process.argv[4]), stderr: fs.readFileSync(root + "/c.err", "utf8"),
        snapshot_before: "", snapshot_after: "", truth,
      }, null, 2));
    ' "$TRUTH" "$MDIR" "$MRC_A" "$MRC_C"

    run_judge "$MDIR/ctxA.json" "${tag}-A"
    run_judge "$MDIR/ctxC.json" "${tag}-C"

    NEW_FAILS="$(cat "$WORK/judge-${tag}-A.out" "$WORK/judge-${tag}-C.out" 2>/dev/null | grep -E '^FAIL AC-[0-9]+$' | sed -E 's/^FAIL //' | sort -u | grep -vxF -f "$WORK/baseline-fails.txt" || true)"
    if [ "$target" = "(负控)" ]; then
      if [ -z "$NEW_FAILS" ]; then
        echo "负控 负控 M0（顶层加一个无害字段）: 未检出（新增失败键为空）—— 符合预期，探测器不是恒真"
      else
        MUT_ESCAPED=$((MUT_ESCAPED + 1))
        echo "负控 负控 M0: **被检出**（新增失败键: $(printf '%s' "$NEW_FAILS" | tr '\n' ' '))—— 探测器恒真，本门失效"
      fi
    else
      if printf '%s\n' "$NEW_FAILS" | grep -qx "$target"; then
        MUT_DETECTED=$((MUT_DETECTED + 1))
        echo "变异体 $tag: 已检出（目标 $target 出现在新增失败键集合里；新增=$(printf '%s' "$NEW_FAILS" | tr '\n' ' '))"
      else
        MUT_ESCAPED=$((MUT_ESCAPED + 1))
        echo "变异体 $tag: **未检出**（目标 $target 不在新增失败键集合里；新增=$(printf '%s' "$NEW_FAILS" | tr '\n' ' '))"
      fi
    fi
  done <<EOF
$MUTANTS
EOF

  echo "变异体套件: 检出 $MUT_DETECTED/$((MUT_N - 1))（有效变异体）；负控未检出；逃逸 $MUT_ESCAPED"
fi

# ---------------------------------------------------------------- 结论

echo ""
echo "结论: $PASS_COUNT PASS / $FAIL_COUNT FAIL / $UND_COUNT 不可判定"
if [ "$FAIL_COUNT" -gt 0 ] || [ "$UND_COUNT" -gt 0 ]; then
  echo "（失败键）"
  printf '%s' "$FAIL_KEYS"
fi
echo "验收脚本 sha256: $(sha256sum "$SELF" | cut -d' ' -f1)"

if [ "$FAIL_COUNT" -gt 0 ] || [ "$UND_COUNT" -gt 0 ]; then
  exit 1
fi
if [ "${REQ014_NO_MUT:-0}" != "1" ] && [ "$MUT_ESCAPED" -gt 0 ]; then
  exit 1
fi
exit 0

