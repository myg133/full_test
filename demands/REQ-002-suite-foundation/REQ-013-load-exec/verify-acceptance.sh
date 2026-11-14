#!/usr/bin/env bash
# REQ-013 验收脚本 —— `load-profile` skill 的**负载级执行与判定链**（只打本地桩）
#
# 判据集：AC-001~AC-041（条数从 acceptance.md 的 `^#+ AC-` 实际条数**动态取**，不写死）
# 决策号：从 decisions.md 的 `^#+ D` **标题行**实际集合动态取（不写死）
#
# 用法: verify-acceptance.sh <package-dir>
#   <package-dir> 指向**被验包根目录**（含 skills/ 与 bin/，以及 feature-meta/、README.md）
#
# 退出码: 0 = 全部通过; 1 = 有 AC 未通过 / 不可判定 / 变异体有逃逸 / 负控失败 / sha 不符 /
#               门自身 stderr 有 bash 错误 / 门写了被验包; 2 = 用法错误
#
# 环境变量:
#   QA013_NO_MUT=1        跳过变异体套件（**快跑**模式 / 嵌套运行用）
#   QA013_SCRIPT_SHA      期望的**本脚本自身** sha256；不匹配即判红并中止
#   QA013_WORK_ROOT       工作目录的父目录（默认 $HOME/.local/share/agent-runtime-data/tmp/req013）
#   QA013_KEEP_WORK=1     保留工作目录（调试）
#   QA013_LOADTEST_SRC    **已装好**的 loadtest 目录（其下有 node_modules/loadtest）；
#                         门**不执行任何包管理器安装**，只把这份已装好的树拷进夹具的 .tools/
#   QA013_MUT             （内部）变异体编号，供变异包装层使用
#   QA013_MUT_MARKER      （内部）变异体自证标记文件路径
#
# 设计要点（门是被验对象，不是脚手架 —— D65）:
#   - 只读被验包；一切变异都在**副本**上做（跑前跑后全树指纹比对）。
#   - 夹具（完整夹具 / 最小夹具 / 四个非法夹具）一律造在临时目录里。
#   - 产物侧判据用**独立复算器**（内嵌 judge.mjs）：自己重算「argv → API 选项」「阈值键 → 观测量」
#     「sha256」「证据清单」等口径，**绝不 import 被验包**。
#   - 变异检出走**新增失败键**（变异运行的失败键 减去 基线失败键，整行精确排除）；
#     不用对称差（对称差把「基线红、变异后绿」也算成变化，那是噪声）。
#   - ⚠️ **基线失败键只取 `^FAIL` 行** —— PASS / UNDEC 行里也有 AC 编号，混进来会让基线键集合
#     变成全集，此后任何变异的「新增失败键」都恒等于全集 ⇒ 整套检测沦为橡皮章。
#   - 变异必须**自证生效**：包树指纹（字节级 + 权限位）变化 **且** 变异体自己写下「已生效」标记；
#     缺任一项 ⇒ 该变异体**无效**（不计入分母），并如实报「不可判定」。
#   - 变异体**串行**跑（每路独立 QA013_WORK_ROOT）⇒ 不产生无因果关系的额外失败键。
#   - 负控（改 `generated_at` 的取值，内容语义不变）必须**未检出**；被检出 ⇒ 门失效（门侧缺陷）。
#   - **门跑在「没有实现」的真包上必须优雅降级**：不崩溃，如实报 FAIL。

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
  AC_COUNT="$(grep -cE '^#+[[:space:]]+AC-[0-9]+' "$ACCEPTANCE" || true)"
fi
AC_COUNT="$(printf '%s' "${AC_COUNT:-0}" | tr -dc '0-9')"
[ -n "$AC_COUNT" ] || AC_COUNT=0

# ---------------------------------------------------------------- 决策号集合（动态取 —— 只认标题行）

DECISION_IDS=""
DECISION_COUNT=0
if [ -f "$DECISIONS" ]; then
  DECISION_RAW="$(grep -oE '^#+[[:space:]]+D[0-9]+' "$DECISIONS" | sed -E 's/^#+[[:space:]]+//' | sort -u || true)"
  DECISION_COUNT="$(printf '%s\n' $DECISION_RAW | grep -v '^$' | wc -l | tr -d ' ')"
  DECISION_IDS="$(printf '%s\n' $DECISION_RAW | sort -t'D' -k2,2n | tr '\n' ' ' | sed 's/ $//')"
fi

# ---------------------------------------------------------------- 门禁前置：脚本自身指纹

if [ -n "${QA013_SCRIPT_SHA:-}" ]; then
  SELF_SHA="$(sha256sum "$SELF" 2>/dev/null | cut -d' ' -f1)"
  if [ "$SELF_SHA" != "${QA013_SCRIPT_SHA:-}" ]; then
    printf 'FAIL GATE-SHA —— 验收脚本 sha256 不匹配（期望 %s，实际 %s）\n' "${QA013_SCRIPT_SHA:-}" "$SELF_SHA"
    printf '\n结论: 0 PASS / 1 FAIL\n'
    printf '验收脚本 sha256: %s\n' "$SELF_SHA"
    exit 1
  fi
fi

# ---------------------------------------------------------------- 工作目录

WORK_PARENT="${QA013_WORK_ROOT:-$HOME/.local/share/agent-runtime-data/tmp/req013}"
mkdir -p "$WORK_PARENT" 2>/dev/null || true
WORK="$(mktemp -d "$WORK_PARENT/qa013-XXXXXX")" || { echo "无法创建工作目录" >&2; exit 2; }
cleanup() {
  if [ "${QA013_KEEP_WORK:-0}" = "1" ]; then
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
STDERR_LOG="$WORK/stderr.log"
# ⚠️ 用 fd 3 保留**原始 stderr**：回放自己的 stderr 时不能写回同一个文件（否则 cat 报错、且回放丢失）
exec 3>&2 2>"$STDERR_LOG"

# ---------------------------------------------------------------- 计数器与记分

PASS=0
FAIL=0
UNDEC=0
GATE_READONLY_BROKEN=0
GATE_BROKEN=0
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

# ---------------------------------------------------------------- 夹具 / 复算器 / 变异包装层（内嵌 node）

cat > "$WORK/mkfixture.mjs" <<'QA013_FIX_EOF'
// REQ-013 夹具生成器（先独立成文件跑通，再内嵌进门脚本）
// 用法: node mkfixture.mjs <FX目录> <loadtest源目录(含 node_modules/)>
import fs from 'node:fs';
import path from 'node:path';

const FX = process.argv[2];
const TOOL_SRC = process.argv[3];

const writeJson = (f, obj) => {
  fs.mkdirSync(path.dirname(f), { recursive: true });
  fs.writeFileSync(f, JSON.stringify(obj, null, 2) + '\n');
};
const writeText = (f, s) => {
  fs.mkdirSync(path.dirname(f), { recursive: true });
  fs.writeFileSync(f, s);
};
const copyTree = (src, dst) => {
  // ⚠️ 必须用 cpSync：**符号链接**（.bin/loadtest 就是软链）必须原样复制
  fs.cpSync(src, dst, { recursive: true, dereference: false, force: true });
};
const installTool = (root) => {
  if (!TOOL_SRC) return;
  const src = path.join(TOOL_SRC, 'node_modules');
  if (!fs.existsSync(src)) return;
  const dst = path.join(root, '.tools', 'node');
  fs.mkdirSync(dst, { recursive: true });
  copyTree(src, path.join(dst, 'node_modules'));
};

// ---------------------------------------------------------------- 负载模型（与计划逐字一致）

const models = {
  'checkout': {
    schema_version: 1, id: 'WL-001', name: 'checkout', service: 'order-api',
    target: 'POST /api/v1/checkout', environment: 'local',
    profile: { type: 'ramp-up', steps: [{ duration_s: 2, concurrency: 4 }, { duration_s: 2, concurrency: 8 }] },
    thresholds: { p95_latency_ms: 200, error_rate: 0.01, throughput_rps: 1, max_concurrency: 16 },
    thresholds_source: 'capacity-targets', thresholds_status: 'provided',
    tool: { runner: 'loadtest', runtime: 'node' },
    args: { method: 'POST' }, traceability: { workload_id: 'WL-001', requirement_refs: [], case_refs: [] },
    open_questions: [],
  },
  'order-query': {
    schema_version: 1, id: 'WL-002', name: 'order-query', service: 'order-api',
    target: 'GET /api/v1/orders', environment: 'local',
    profile: { type: 'constant', steps: [{ duration_s: 2, concurrency: 2 }] },
    thresholds_status: 'not_provided', tool: { runner: 'loadtest', runtime: 'node' },
    traceability: { workload_id: 'WL-002', requirement_refs: [], case_refs: [] },
    open_questions: [{ id: 'OQ-001', topic: 'thresholds', question: '订单查询链路的延迟阈值尚未确定。' }],
  },
  'checkout-staging': {
    schema_version: 1, id: 'WL-003', name: 'checkout-staging', service: 'order-api',
    target: 'POST /api/v1/checkout', environment: 'local',
    profile: { type: 'spike', steps: [{ duration_s: 1, concurrency: 2 }] },
    thresholds_status: 'not_provided', tool: { runner: 'python', runtime: 'python' },
    args: { command: ['python', '-c', 'import sys,time;time.sleep(0.05)', '1', '2'] },
    traceability: { workload_id: 'WL-003', requirement_refs: [], case_refs: [] },
    open_questions: [{ id: 'OQ-003', topic: 'thresholds', question: 'staging 环境的压测阈值尚未确定。' }],
  },
  'health-check': {
    schema_version: 1, id: 'WL-004', name: 'health-check', service: 'order-api',
    target: 'GET /api/v1/health', environment: 'local',
    profile: { type: 'constant', steps: [{ duration_s: 2, concurrency: 1 }] },
    thresholds_status: 'not_provided', tool: { runner: 'loadtest', runtime: 'node' },
    traceability: { workload_id: 'WL-004', requirement_refs: [], case_refs: [] },
    open_questions: [{ id: 'OQ-002', topic: 'coverage', question: '健康检查是否需要单独压测尚未确认。' }],
  },
};

// ---------------------------------------------------------------- 计划产物（demand.md §3.2 逐字）

const plan = {
  schema_version: 1,
  suite: 'LOAD-001-checkout',
  environment: 'local',
  scenarios: [
    {
      scenario_id: 'WL-001', scenario_name: 'checkout', runner: 'loadtest', runtime: 'node',
      target: 'POST /api/v1/checkout', base_url: 'http://127.0.0.1:8080/',
      profile_type: 'ramp-up',
      invocations: [
        { step_index: 0, duration_s: 2, concurrency: 4,
          argv: ['loadtest', '-t', '2', '-c', '4', '--cores', '1', 'http://127.0.0.1:8080/api/v1/checkout', '-m', 'POST'] },
        { step_index: 1, duration_s: 2, concurrency: 8,
          argv: ['loadtest', '-t', '2', '-c', '8', '--cores', '1', 'http://127.0.0.1:8080/api/v1/checkout', '-m', 'POST'] },
      ],
      thresholds_status: 'provided',
      thresholds: { p95_latency_ms: 200, error_rate: 0.01, throughput_rps: 1, max_concurrency: 16 },
      thresholds_source: 'capacity-targets',
      open_questions: [],
    },
    {
      scenario_id: 'WL-002', scenario_name: 'order-query', runner: 'loadtest', runtime: 'node',
      target: 'GET /api/v1/orders', base_url: 'http://127.0.0.1:8080/',
      profile_type: 'constant',
      invocations: [
        { step_index: 0, duration_s: 2, concurrency: 2,
          argv: ['loadtest', '-t', '2', '-c', '2', '--cores', '1', 'http://127.0.0.1:8080/api/v1/orders', '-m', 'GET'] },
      ],
      thresholds_status: 'not_provided',
      open_questions: [{ id: 'OQ-001', topic: 'thresholds', question: '订单查询的延迟阈值尚未确定。' }],
    },
    {
      scenario_id: 'WL-003', scenario_name: 'checkout-staging', runner: 'python', runtime: 'python',
      target: 'POST /api/v1/checkout', base_url: 'http://127.0.0.1:8080/',
      profile_type: 'spike',
      invocations: [
        { step_index: 0, duration_s: 1, concurrency: 2,
          argv: ['python', '-c', 'import sys,time;time.sleep(0.05)', '1', '2'] },
      ],
      thresholds_status: 'not_provided',
      open_questions: [{ id: 'OQ-003', topic: 'thresholds', question: 'staging 环境的压测阈值尚未确定。' }],
    },
    {
      scenario_id: 'WL-004', scenario_name: 'health-check', runner: 'loadtest', runtime: 'node',
      target: 'GET /api/v1/health', base_url: 'http://127.0.0.1:8080/',
      profile_type: 'constant',
      invocations: [
        { step_index: 0, duration_s: 2, concurrency: 1,
          argv: ['loadtest', '-t', '2', '-c', '1', '--cores', '1', 'http://127.0.0.1:8080/api/v1/health', '-m', 'GET'] },
      ],
      thresholds_status: 'not_provided',
      open_questions: [{ id: 'OQ-002', topic: 'coverage', question: '健康检查是否需要单独压测尚未确认。' }],
    },
  ],
};

// ---------------------------------------------------------------- 最小夹具（acceptance.md §0.4）

const miniPlan = {
  schema_version: 1,
  suite: 'LOAD-900-mini',
  environment: 'local',
  scenarios: [
    {
      scenario_id: 'WL-900', scenario_name: 'mini', runner: 'loadtest', runtime: 'node',
      target: 'POST /api/v1/checkout', base_url: 'http://127.0.0.1:8080/',
      profile_type: 'constant',
      invocations: [
        { step_index: 0, duration_s: 1, concurrency: 2,
          argv: ['loadtest', '-t', '1', '-c', '2', '--cores', '1', 'http://127.0.0.1:8080/api/v1/checkout', '-m', 'POST'] },
      ],
      thresholds_status: 'provided',
      thresholds: { p95_latency_ms: 200, error_rate: 0.01, throughput_rps: 1, max_concurrency: 16 },
      thresholds_source: 'capacity-targets',
      open_questions: [],
    },
  ],
};

// 门自造的**补充**最小夹具（阈值键取满 6 个 ⇒ AC-040 的 p50/p95/p99 三者可核）
const miniLatPlan = {
  schema_version: 1,
  suite: 'LOAD-901-mini-lat',
  environment: 'local',
  scenarios: [
    {
      scenario_id: 'WL-901', scenario_name: 'mini-lat', runner: 'loadtest', runtime: 'node',
      target: 'POST /api/v1/checkout', base_url: 'http://127.0.0.1:8080/',
      profile_type: 'constant',
      invocations: [
        { step_index: 0, duration_s: 1, concurrency: 2,
          argv: ['loadtest', '-t', '1', '-c', '2', '--cores', '1', 'http://127.0.0.1:8080/api/v1/checkout', '-m', 'POST'] },
      ],
      thresholds_status: 'provided',
      thresholds: {
        p50_latency_ms: 200, p95_latency_ms: 200, p99_latency_ms: 200,
        error_rate: 0.01, throughput_rps: 1, max_concurrency: 16,
      },
      thresholds_source: 'capacity-targets',
      open_questions: [],
    },
  ],
};

const miniModel = {
  schema_version: 1, id: 'WL-900', name: 'mini', service: 'order-api',
  target: 'POST /api/v1/checkout', environment: 'local',
  profile: { type: 'constant', steps: [{ duration_s: 1, concurrency: 2 }] },
  thresholds: { p95_latency_ms: 200, error_rate: 0.01, throughput_rps: 1, max_concurrency: 16 },
  thresholds_source: 'capacity-targets', thresholds_status: 'provided',
  tool: { runner: 'loadtest', runtime: 'node' },
  traceability: { workload_id: 'WL-900', requirement_refs: [], case_refs: [] }, open_questions: [],
};
const miniLatModel = {
  schema_version: 1, id: 'WL-901', name: 'mini-lat', service: 'order-api',
  target: 'POST /api/v1/checkout', environment: 'local',
  profile: { type: 'constant', steps: [{ duration_s: 1, concurrency: 2 }] },
  thresholds: {
    p50_latency_ms: 200, p95_latency_ms: 200, p99_latency_ms: 200,
    error_rate: 0.01, throughput_rps: 1, max_concurrency: 16,
  },
  thresholds_source: 'capacity-targets', thresholds_status: 'provided',
  tool: { runner: 'loadtest', runtime: 'node' },
  traceability: { workload_id: 'WL-901', requirement_refs: [], case_refs: [] }, open_questions: [],
};

const MANIFEST = {
  version: 1,
  tools: [
    {
      name: 'loadtest', kind: 'node', spec: 'loadtest@8.2.1', purpose: '压测 runner',
      required_by: ['REQ-002.9'], install: { bun: 'bun add {spec}' },
      verify: { command: 'loadtest --version', match: 'Loadtest' },
    },
  ],
};

function baseProject(root) {
  writeJson(path.join(root, '.tools', 'manifest.json'), MANIFEST);
  writeText(path.join(root, '.gitignore'), '.tools/*\n!.tools/manifest.json\n');
  writeJson(path.join(root, 'test-assets', 'environments', 'local.json'), {
    name: 'local', base_url: 'http://127.0.0.1:8080/', timeout_ms: 3000, retries: 0,
  });
  for (const [name, m] of Object.entries(models)) {
    writeJson(path.join(root, 'test-assets', 'load', 'scenarios', `${name}.json`), m);
  }
  writeJson(path.join(root, 'test-assets', 'load', 'suites', 'LOAD-001-checkout', 'suite.json'), {
    suite: 'LOAD-001-checkout', requirement: 'REQ-009', scope: 'load', environment: 'local',
    cases_file: 'scenario.json', executor: 'load',
  });
  writeJson(path.join(root, 'test-assets', 'load', 'suites', 'LOAD-001-checkout', 'scenario.json'), {
    schema_version: 1, suite: 'LOAD-001-checkout',
    scenarios: [
      { path: '../../scenarios/checkout.json', id: 'WL-001', name: 'checkout' },
      { path: '../../scenarios/order-query.json', id: 'WL-002', name: 'order-query' },
      { path: '../../scenarios/checkout-staging.json', id: 'WL-003', name: 'checkout-staging' },
      { path: '../../scenarios/health-check.json', id: 'WL-004', name: 'health-check' },
    ],
  });
  writeJson(path.join(root, 'test-assets', 'load', 'plans', 'LOAD-001-checkout.json'), plan);
}

// ---------------------------------------------------------------- 全部夹具

const PROJ = path.join(FX, 'proj');
baseProject(PROJ);
installTool(PROJ);

const MINI = path.join(FX, 'mini');
fs.mkdirSync(MINI, { recursive: true });
writeJson(path.join(MINI, '.tools', 'manifest.json'), MANIFEST);
writeText(path.join(MINI, '.gitignore'), '.tools/*\n!.tools/manifest.json\n');
writeJson(path.join(MINI, 'test-assets', 'environments', 'local.json'), {
  name: 'local', base_url: 'http://127.0.0.1:8080/', timeout_ms: 3000, retries: 0,
});
writeJson(path.join(MINI, 'test-assets', 'load', 'scenarios', 'mini.json'), miniModel);
writeJson(path.join(MINI, 'test-assets', 'load', 'plans', 'LOAD-900-mini.json'), miniPlan);
installTool(MINI);

const MINI_LAT = path.join(FX, 'mini-lat');
fs.mkdirSync(MINI_LAT, { recursive: true });
writeJson(path.join(MINI_LAT, '.tools', 'manifest.json'), MANIFEST);
writeText(path.join(MINI_LAT, '.gitignore'), '.tools/*\n!.tools/manifest.json\n');
writeJson(path.join(MINI_LAT, 'test-assets', 'environments', 'local.json'), {
  name: 'local', base_url: 'http://127.0.0.1:8080/', timeout_ms: 3000, retries: 0,
});
writeJson(path.join(MINI_LAT, 'test-assets', 'load', 'scenarios', 'mini-lat.json'), miniLatModel);
writeJson(path.join(MINI_LAT, 'test-assets', 'load', 'plans', 'LOAD-901-mini-lat.json'), miniLatPlan);
installTool(MINI_LAT);

// ---- 非法夹具（§0.5）
const badNosuite = path.join(FX, 'bad-nosuite');
baseProject(badNosuite);
installTool(badNosuite);
fs.unlinkSync(path.join(badNosuite, 'test-assets', 'load', 'plans', 'LOAD-001-checkout.json'));

const badThreshold = path.join(FX, 'bad-threshold');
baseProject(badThreshold);
installTool(badThreshold);
{
  const f = path.join(badThreshold, 'test-assets', 'load', 'plans', 'LOAD-001-checkout.json');
  const doc = JSON.parse(fs.readFileSync(f, 'utf8'));
  doc.scenarios[0].thresholds.p42_latency_ms = 100;
  writeJson(f, doc);
}

const badArgv = path.join(FX, 'bad-argv');
baseProject(badArgv);
installTool(badArgv);
{
  const f = path.join(badArgv, 'test-assets', 'load', 'plans', 'LOAD-001-checkout.json');
  const doc = JSON.parse(fs.readFileSync(f, 'utf8'));
  doc.scenarios[0].invocations[0].argv[6] = '4';   // --cores 4
  writeJson(f, doc);
}

const badUrl = path.join(FX, 'bad-url');
baseProject(badUrl);
installTool(badUrl);
{
  const f = path.join(badUrl, 'test-assets', 'load', 'plans', 'LOAD-001-checkout.json');
  const doc = JSON.parse(fs.readFileSync(f, 'utf8'));
  doc.scenarios[0].invocations[0].argv[7] = 'http://example.com/api/v1/checkout';
  writeJson(f, doc);
}

process.stdout.write('FIXTURE-OK\n');

QA013_FIX_EOF

cat > "$WORK/judge.mjs" <<'QA013_JUDGE_EOF'
// REQ-013 独立复算器（judge.mjs）—— 判据的产物侧判定
// ⚠️ **绝不 import 被验包的任何模块**（否则等于用被验实现验证被验实现）。
//    自己重算「argv → API 选项」「阈值键 → 观测量」「sha256」等口径，自带解析 / 集合运算 / 枚举实现。
// 用法: node judge.mjs <PKG> <WORK> <ACCEPTANCE> <DECISIONS> <TOOL_SRC>
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import net from 'node:net';
import { spawnSync } from 'node:child_process';

const [PKG, WORK, ACCEPTANCE, DECISIONS, TOOL_SRC] = process.argv.slice(2);

const ENTRY_REL = 'skills/load-profile/scripts/run-load-test.mjs';
const CHECKER_REL = 'skills/load-profile/scripts/check-load-test.mjs';
const STUB_REL = 'skills/load-profile/scripts/lib/stub.mjs';
const EXEC_REL = 'skills/load-profile/scripts/lib/load-exec.mjs';
const CONTRACT_REL = 'skills/load-profile/references/load-exec-contract.md';
const ENTRY = path.join(PKG, ENTRY_REL);
const CHECKER = path.join(PKG, CHECKER_REL);
const IMPL_MISSING = !fs.existsSync(ENTRY);

// ---------------------------------------------------------------- 小工具

const sha256 = (buf) => crypto.createHash('sha256').update(buf).digest('hex');
const sha256File = (f) => { try { return sha256(fs.readFileSync(f)); } catch { return null; } };
const readJson = (f) => { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch { return null; } };
const isDir = (p) => { try { return fs.statSync(p).isDirectory(); } catch { return false; } };
const isFile = (p) => { try { return fs.statSync(p).isFile(); } catch { return false; } };
const sorted = (a) => a.slice().sort();
const sameSet = (a, b) => a.size === b.size && [...a].every((x) => b.has(x));
const copyTree = (src, dst) => { fs.cpSync(src, dst, { recursive: true, dereference: false, force: true }); };
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
      else if (st.isFile()) lines.push(`${rel} ${st.mode & 0o7777} ${sha256File(f)}`);
    }
  };
  walk(root);
  return lines.join('\n');
};
const listFiles = (root) => {
  const out = [];
  const walk = (d) => {
    if (!isDir(d)) return;
    for (const n of fs.readdirSync(d).sort()) {
      const f = path.join(d, n);
      const st = fs.lstatSync(f);
      if (st.isDirectory()) walk(f);
      else if (st.isFile()) out.push(path.relative(root, f));
    }
  };
  walk(root);
  return out.sort();
};
const runNode = (args, opts = {}) => {
  const r = spawnSync(process.execPath, args, { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024, ...opts });
  return { rc: r.status === null ? -1 : r.status, out: r.stdout || '', err: r.stderr || '' };
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------- 结论收集

const findings = new Map();
const add = (ac, msg) => { if (!findings.has(ac)) findings.set(ac, []); findings.get(ac).push(msg); };
const undecs = new Map();
const markUndec = (ac, msg) => { if (!undecs.has(ac)) undecs.set(ac, []); undecs.get(ac).push(msg); };
/** 门级发现（不属于任何一条 AC，但**必须**让门判红）：AC 号带 "GATE-" 前缀 */
const gateFindings = [];
const addGate = (id, msg) => gateFindings.push({ ac: id, msg });

// ---------------------------------------------------------------- 判据常量（与契约一致）

const TOP_KEYS = ['schema_version', 'suite', 'environment', 'generated_at', 'execution', 'scenarios', 'verdict', 'results_sha256'];
const EXEC_REQUIRED = ['mode', 'started_at', 'finished_at', 'duration_ms', 'tool', 'stub'];
const EXEC_CLI = EXEC_REQUIRED.concat(['cli']);
const TOOL_KEYS = ['name', 'version', 'resolved_from'];
const STUB_KEYS = ['origin', 'delay_ms', 'error_rate', 'status'];
const SCENARIO_REQUIRED = ['scenario_id', 'scenario_name', 'runner', 'target', 'base_url', 'thresholds_status', 'invocations', 'verdict'];
const SCENARIO_COND = ['thresholds', 'thresholds_source'];
const INVOKE_KEYS = ['step_index', 'duration_s', 'concurrency', 'argv', 'executed_url', 'executed_params', 'observed', 'stub_observed', 'thresholds', 'verdict'];
const OBSERVED_KEYS = ['total_requests', 'total_errors', 'error_codes', 'error_rate', 'mean_latency_ms', 'effective_rps', 'percentiles', 'max_latency_ms', 'min_latency_ms', 'elapsed_seconds'];
const STUB_OBS_KEYS = ['requests', 'errors', 'error_rate', 'mean_ms', 'min_ms', 'max_ms', 'histogram_ms', 'first_at_ms', 'last_at_ms'];
const THRESHOLD_ENTRY_KEYS = ['key', 'threshold', 'observed', 'verdict', 'reason'];
const VERDICT_SECTION_KEYS = ['suite', 'invocations_total', 'invocations_met', 'invocations_not_met', 'invocations_undetermined', 'undetermined_keys'];
const VERDICTS = ['met', 'not_met', 'undetermined'];
const THRESHOLD_KEYS = ['p50_latency_ms', 'p95_latency_ms', 'p99_latency_ms', 'error_rate', 'throughput_rps', 'max_concurrency'];
const FORBIDDEN_WORDS = ['生产', '生产环境', '容量达标', '可承载', '上线', 'production', 'production-ready'];
const PERCENTILE_KEYS = ['50', '90', '95', '99'];

const isLoopback = (host) => {
  if (!host) return false;
  const h = String(host).toLowerCase().replace(/^\[/, '').replace(/\]$/, '');
  if (h === '::1' || h === '0:0:0:0:0:0:0:1') return true;
  return /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(h);
};
const urlParts = (u) => {
  try {
    const x = new URL(u);
    return { origin: `${x.protocol}//${x.host}`, path: x.pathname, query: x.search, host: x.hostname, port: x.port };
  } catch { return null; }
};
/** 规范化序列化（排序键 + 紧凑分隔符）—— 与 REQ-010 / 需求方复算器同款口径 */
const canonicalJson = (obj) => {
  if (obj === null || typeof obj !== 'object') return JSON.stringify(obj);
  if (Array.isArray(obj)) return `[${obj.map(canonicalJson).join(',')}]`;
  const keys = Object.keys(obj).sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${canonicalJson(obj[k])}`).join(',')}}`;
};

/** 门自己反解 REQ-012 的规范 argv（AC-026 用） */
const reverseArgv = (argv) => {
  if (!Array.isArray(argv) || argv.length < 10) return null;
  if (argv[0] !== 'loadtest' || argv[1] !== '-t' || argv[3] !== '-c' || argv[5] !== '--cores' || argv[6] !== '1' || argv[8] !== '-m') return null;
  const spec = {
    maxSeconds: Number(argv[2]),
    concurrency: Number(argv[4]),
    method: String(argv[9]),
    requestsPerSecond: null,
    agentKeepAlive: false,
    timeout: null,
  };
  let i = 10;
  let stage = 0;
  while (i < argv.length) {
    const t = argv[i];
    if (stage === 0 && t === '--rps') { if (argv.length - i < 2) return null; spec.requestsPerSecond = Number(argv[i + 1]); i += 2; stage = 1; continue; }
    if (stage <= 1 && t === '-k') { spec.agentKeepAlive = true; i += 1; stage = 2; continue; }
    if (stage <= 2 && t === '-d') { if (argv.length - i < 2) return null; spec.timeout = Number(argv[i + 1]); i += 2; stage = 3; continue; }
    return null;
  }
  return { spec, url: String(argv[7]) };
};

// ---------------------------------------------------------------- 归一化（AC-030：结构级幂等）
//  ⚠️ 契约只说了「数值型叶子 → 占位」「时间戳 → 占位」。本门另外把两处**每跑必变**的
//     **nonce** 也归一化（否则 AC-030 对任何实现都不可满足）：
//       ① 桩的随机端口（`execution.stub.origin` 里的端口）
//       ② 项目根路径（不同输出目录 ⇒ 绝对路径必然不同）
//     以及「键全为数字的对象」（延迟直方图的 ms 桶键集随运行变化 ⇒ 键集不稳定）。
const normalizeArtifact = (doc, projectRoot) => {
  const clone = JSON.parse(JSON.stringify(doc));
  let port = null;
  try { port = new URL(clone.execution.stub.origin).port; } catch { /* 无 origin */ }
  const walk = (node) => {
    if (Array.isArray(node)) { node.forEach(walk); return; }
    if (!node || typeof node !== 'object') return;
    const keys = Object.keys(node);
    if (keys.length > 0 && keys.every((k) => /^\d+$/.test(k))) {
      for (const k of keys) delete node[k];
      node['__numeric_keyed__'] = '<numeric-keyed>';
      return;
    }
    for (const [k, v] of Object.entries(node)) {
      if (typeof v === 'number') { node[k] = '#'; continue; }
      if (typeof v === 'string') {
        let s = v.replace(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z/g, '<ts>');
        // ⚠️ `results_sha256` 是**易变内容的摘要** ⇒ 两次跑必然不同 ⇒ 结构比对时必须一并归一化
        s = s.replace(/^[0-9a-f]{64}$/, '<sha256>');
        if (projectRoot) s = s.split(projectRoot).join('<root>');
        if (port) s = s.split(`:${port}`).join(':<port>');
        node[k] = s;
        continue;
      }
      walk(v);
    }
  };
  walk(clone);
  return JSON.stringify(clone);
};

// ---------------------------------------------------------------- 主流程

async function main() {
  const accText = fs.readFileSync(ACCEPTANCE, 'utf8');
  const decText = fs.readFileSync(DECISIONS, 'utf8');
  const acIds = [...accText.matchAll(/^#+\s+(AC-\d+)/gm)].map((m) => m[1]);
  const decIds = [...decText.matchAll(/^#+\s+(D\d+)/gm)].map((m) => m[1]);

  if (IMPL_MISSING) {
    for (const ac of acIds) add(ac, '实现未交付：入口脚本 skills/load-profile/scripts/run-load-test.mjs 不存在');
    finish(acIds);
    return;
  }

  // ① 夹具
  const FX = path.join(WORK, 'fx');
  const fx = runNode([path.join(WORK, 'mkfixture.mjs'), FX, TOOL_SRC || '']);
  if (fx.rc !== 0 || !isDir(FX)) {
    for (const ac of acIds) markUndec(ac, `夹具生成失败（rc=${fx.rc}）：${fx.err.slice(0, 200)}`);
    finish(acIds);
    return;
  }

  const PLAN = readJson(path.join(FX, 'proj', 'test-assets', 'load', 'plans', 'LOAD-001-checkout.json'));
  const MINI_PLAN = readJson(path.join(FX, 'mini', 'test-assets', 'load', 'plans', 'LOAD-900-mini.json'));
  const MINI_LAT_PLAN = readJson(path.join(FX, 'mini-lat', 'test-assets', 'load', 'plans', 'LOAD-901-mini-lat.json'));

  // ② 跑：主夹具（api 模式）
  const MAIN = path.join(WORK, 'run-main');
  copyTree(path.join(FX, 'proj'), MAIN);
  const beforeTree = treeFingerprint(MAIN, path.join('test-assets', 'load', 'results'));
  const beforeFiles = listFiles(MAIN).filter((f) => !f.startsWith(`test-assets${path.sep}load${path.sep}results`));
  const MAIN_RUN = runNode([ENTRY, '--load-dir', MAIN, '--out-dir', MAIN, '--suite', 'LOAD-001-checkout']);
  const afterTree = treeFingerprint(MAIN, path.join('test-assets', 'load', 'results'));
  const afterFiles = listFiles(MAIN).filter((f) => !f.startsWith(`test-assets${path.sep}load${path.sep}results`));

  // ③ 跑：最小夹具（api / cli / 注入错误 / 注入延迟）
  const mkRun = (src, name) => { const d = path.join(WORK, name); copyTree(path.join(FX, src), d); return d; };
  const MINI = mkRun('mini', 'run-mini');
  const MINI_API = runNode([ENTRY, '--load-dir', MINI, '--out-dir', MINI, '--suite', 'LOAD-900-mini']);
  const MINI_CLI_DIR = mkRun('mini', 'run-mini-cli');
  const MINI_CLI = runNode([ENTRY, '--load-dir', MINI_CLI_DIR, '--out-dir', MINI_CLI_DIR, '--suite', 'LOAD-900-mini', '--mode', 'cli']);
  const MINI_ERR_DIR = mkRun('mini', 'run-mini-err');
  const MINI_ERR = runNode([ENTRY, '--load-dir', MINI_ERR_DIR, '--out-dir', MINI_ERR_DIR, '--suite', 'LOAD-900-mini', '--stub-error-rate', '1']);
  const MINI_DLY_DIR = mkRun('mini', 'run-mini-delay');
  const MINI_DLY = runNode([ENTRY, '--load-dir', MINI_DLY_DIR, '--out-dir', MINI_DLY_DIR, '--suite', 'LOAD-900-mini', '--stub-delay-ms', '50']);
  const MINI_LAT_DIR = mkRun('mini-lat', 'run-mini-lat');
  const MINI_LAT = runNode([ENTRY, '--load-dir', MINI_LAT_DIR, '--out-dir', MINI_LAT_DIR, '--suite', 'LOAD-901-mini-lat', '--stub-delay-ms', '50']);

  // ④ 跑：幂等（第二个输出目录）
  const IDEM = path.join(WORK, 'run-idem');
  copyTree(path.join(FX, 'proj'), IDEM);
  const IDEM_RUN = runNode([ENTRY, '--load-dir', IDEM, '--out-dir', IDEM, '--suite', 'LOAD-001-checkout']);

  const resultsDir = (root) => path.join(root, 'test-assets', 'load', 'results');
  const artifactPath = (root, suite) => path.join(resultsDir(root), `${suite}.json`);
  const ART = readJson(artifactPath(MAIN, 'LOAD-001-checkout'));
  const ART_CLI = readJson(artifactPath(MINI_CLI_DIR, 'LOAD-900-mini'));
  const ART_ERR = readJson(artifactPath(MINI_ERR_DIR, 'LOAD-900-mini'));
  const ART_DLY = readJson(artifactPath(MINI_DLY_DIR, 'LOAD-900-mini'));
  const ART_DLY_LAT = readJson(artifactPath(MINI_LAT_DIR, 'LOAD-901-mini-lat'));
  const ART_IDEM = readJson(artifactPath(IDEM, 'LOAD-001-checkout'));

  const implOk = MAIN_RUN.rc === 0 && ART !== null;
  if (!implOk) {
    const why = `主跑未成功（rc=${MAIN_RUN.rc}）⇒ 没有产物可判：${(MAIN_RUN.err || '').slice(0, 200)}`;
    for (const ac of acIds) {
      if (['AC-036', 'AC-037', 'AC-038'].includes(ac)) continue;
      add(ac, why);
    }
  }

  const invocationsOf = (art) => {
    const out = [];
    for (const sc of (art && Array.isArray(art.scenarios) ? art.scenarios : [])) {
      for (const inv of (sc.invocations || [])) out.push({ sc, inv });
    }
    return out;
  };

  // ================================================================ A 组：产物形状与封闭

  // ---- AC-001 落点与文件名
  {
    const f = artifactPath(MAIN, 'LOAD-001-checkout');
    if (!isFile(f)) add('AC-001', `结果产物不存在：test-assets/load/results/LOAD-001-checkout.json`);
    else {
      if (path.basename(f).replace(/\.json$/, '') !== 'LOAD-001-checkout') add('AC-001', '结果产物文件名与套件名不一致');
      const rd = resultsDir(MAIN);
      for (const n of fs.readdirSync(rd)) {
        if (n === 'suite.json') add('AC-001', 'results/ 下出现了 suite.json（上游对 suite.json 的顶层字段集封闭）');
        if (n === 'LOAD-001-checkout-result.json') add('AC-001', 'results/ 下出现了 LOAD-001-checkout-result.json');
      }
    }
  }

  // ---- AC-002 顶层字段集封闭 8 个
  if (ART) {
    const tk = Object.keys(ART);
    if (JSON.stringify(sorted(tk)) !== JSON.stringify(sorted(TOP_KEYS))) add('AC-002', `结果产物顶层键集不是封闭的 8 个（实际 ${tk.join(',')}）`);
  }

  // ---- AC-003 顶层标量取值
  if (ART && PLAN) {
    if (ART.schema_version !== 1) add('AC-003', 'schema_version 不是数字 1');
    if (ART.suite !== PLAN.suite) add('AC-003', 'suite 与计划不一致');
    if (ART.environment !== PLAN.environment) add('AC-003', 'environment 与计划不一致');
    if (typeof ART.generated_at !== 'string' || Number.isNaN(new Date(ART.generated_at).getTime())) add('AC-003', 'generated_at 不是合法 ISO-8601');
  }

  // ---- AC-004 results_sha256 可被独立复算
  if (ART) {
    if (!/^[0-9a-f]{64}$/.test(String(ART.results_sha256))) add('AC-004', 'results_sha256 不是 64 位小写十六进制');
    else {
      const basis = { ...ART };
      delete basis.generated_at;
      delete basis.results_sha256;
      const canonical = canonicalJson(basis);
      const candidates = new Set([
        sha256(canonical),                       // 排序键 + 紧凑分隔符（REQ-010 同款口径 / 需求方复算器口径）
        sha256(JSON.stringify(basis)),           // 文件键序 + 紧凑
        sha256(JSON.stringify(basis, null, 2)),  // 文件键序 + 2 空格缩进
        sha256(JSON.stringify(basis, null, 2) + '\n'),
      ]);
      if (!candidates.has(ART.results_sha256)) add('AC-004', 'results_sha256 复算不一致（剔除 generated_at 与 results_sha256 后的内容对不上）');
    }
  }

  // ---- AC-005 execution 段：6 必填 + 1 条件（api 模式恰好 6；cli 模式恰好 7）
  {
    const checkExec = (art, ac, expectCli) => {
      if (!art || !art.execution) { add(ac, 'execution 段缺席'); return; }
      const ex = art.execution;
      const want = expectCli ? EXEC_CLI : EXEC_REQUIRED;
      const got = Object.keys(ex);
      if (JSON.stringify(sorted(got)) !== JSON.stringify(sorted(want))) add(ac, `execution 键集不封闭（实际 ${got.join(',')}，期望 ${want.join(',')}）`);
      if (!['api_equivalent', 'cli_verbatim'].includes(ex.mode)) add(ac, `mode 取值非法（${ex.mode}）`);
      if (!isFile(path.join(PKG, STUB_REL)) && false) { /* 占位（不判） */ }
      if (ex.tool && JSON.stringify(sorted(Object.keys(ex.tool))) !== JSON.stringify(sorted(TOOL_KEYS))) add(ac, `execution.tool 键集不是 3 个（实际 ${Object.keys(ex.tool || {}).join(',')}）`);
      if (ex.stub && JSON.stringify(sorted(Object.keys(ex.stub))) !== JSON.stringify(sorted(STUB_KEYS))) add(ac, `execution.stub 键集不是 4 个（实际 ${Object.keys(ex.stub || {}).join(',')}）`);
      if (!Number.isInteger(ex.duration_ms) || ex.duration_ms < 0) add(ac, 'duration_ms 不是 ≥ 0 的整数');
      if (expectCli) {
        if (!ex.cli) add(ac, 'cli 模式缺少 execution.cli 段');
        else {
          if (JSON.stringify(sorted(Object.keys(ex.cli))) !== JSON.stringify(['error_code_resolution', 'percentile_source'])) add(ac, `execution.cli 键集不是 2 个（实际 ${Object.keys(ex.cli).join(',')}）`);
          if (ex.cli.error_code_resolution !== 'unavailable') add(ac, 'execution.cli.error_code_resolution 不是 "unavailable"');
          if (ex.cli.percentile_source !== 'stdout_text') add(ac, 'execution.cli.percentile_source 不是 "stdout_text"');
        }
      } else if ('cli' in ex) {
        add(ac, 'api_equivalent 模式出现了 execution.cli 段（条件键必须缺席）');
      }
    };
    checkExec(ART, 'AC-005', false);
    checkExec(ART_CLI, 'AC-005', true);
  }

  // ---- AC-006 scenarios 长度与顺序
  if (ART && PLAN) {
    const asc = Array.isArray(ART.scenarios) ? ART.scenarios : [];
    if (asc.length !== PLAN.scenarios.length) add('AC-006', `scenarios 长度与计划不一致（实际 ${asc.length}，计划 ${PLAN.scenarios.length}）`);
    else asc.forEach((s, i) => {
      const p = PLAN.scenarios[i];
      for (const k of ['scenario_id', 'scenario_name', 'runner', 'target', 'base_url', 'thresholds_status']) {
        if (s[k] !== p[k]) add('AC-006', `第 ${i} 个场景的 ${k} 与计划不逐字相同`);
      }
    });
  }

  // ---- AC-007 场景条目字段集与条件字段
  if (ART && PLAN) {
    const asc = Array.isArray(ART.scenarios) ? ART.scenarios : [];
    asc.forEach((s, i) => {
      const p = PLAN.scenarios[i] || {};
      const want = sorted(SCENARIO_REQUIRED.concat(p.thresholds_status === 'provided' ? SCENARIO_COND : []));
      const got = sorted(Object.keys(s));
      if (JSON.stringify(got) !== JSON.stringify(want)) add('AC-007', `第 ${i} 个场景的键集不是封闭的（实际 ${got.join(',')}，期望 ${want.join(',')}）`);
      if (p.thresholds_status === 'provided') {
        if (JSON.stringify(s.thresholds) !== JSON.stringify(p.thresholds)) add('AC-007', `第 ${i} 个场景的 thresholds 与计划不逐字相同`);
        if (s.thresholds_source !== p.thresholds_source) add('AC-007', `第 ${i} 个场景的 thresholds_source 与计划不逐字相同`);
      } else {
        if ('thresholds' in s) add('AC-007', `第 ${i} 个场景 thresholds_status=not_provided 却出现了 thresholds 键`);
        if ('thresholds_source' in s) add('AC-007', `第 ${i} 个场景 thresholds_status=not_provided 却出现了 thresholds_source 键`);
      }
    });
  }

  // ---- AC-008 invocation 条目字段集与逐字保真
  if (ART && PLAN) {
    const asc = Array.isArray(ART.scenarios) ? ART.scenarios : [];
    asc.forEach((s, i) => {
      const p = PLAN.scenarios[i] || {};
      const pInvs = p.invocations || [];
      (s.invocations || []).forEach((inv, j) => {
        const pinv = pInvs[j];
        const isPython = s.runner === 'python';
        // ⚠️ `python` runner：`observed` **必须缺席**（F7.5 / AC-041）；`executed_params` 只对 loadtest argv 有意义
        //    ⇒ 允许 9 键（含 executed_params）或 8 键（不含 executed_params），但 `observed` 不得出现
        const want = sorted(INVOKE_KEYS);
        const wantAlt = sorted(INVOKE_KEYS.filter((k) => k !== 'observed'));
        const wantAlt2 = sorted(INVOKE_KEYS.filter((k) => k !== 'observed' && k !== 'executed_params'));
        const got = sorted(Object.keys(inv));
        const okSet = JSON.stringify(got) === JSON.stringify(want)
          || (isPython && (JSON.stringify(got) === JSON.stringify(wantAlt) || JSON.stringify(got) === JSON.stringify(wantAlt2)));
        if (!okSet) add('AC-008', `第 ${i} 个场景第 ${j} 条 invocation 的键集不是封闭的（实际 ${got.join(',')}，期望 ${want.join(',')}）`);
        if (!pinv) { add('AC-008', `第 ${i} 个场景第 ${j} 条 invocation 在计划里不存在`); return; }
        if (inv.step_index !== j) add('AC-008', `第 ${i} 个场景第 ${j} 条 invocation 的 step_index 不是数组下标`);
        if (inv.duration_s !== pinv.duration_s) add('AC-008', `第 ${i} 个场景第 ${j} 条 invocation 的 duration_s 与计划不逐字相同`);
        if (inv.concurrency !== pinv.concurrency) add('AC-008', `第 ${i} 个场景第 ${j} 条 invocation 的 concurrency 与计划不逐字相同`);
        if (JSON.stringify(inv.argv) !== JSON.stringify(pinv.argv)) add('AC-008', `第 ${i} 个场景第 ${j} 条 invocation 的 argv 与计划不逐字相同`);
      });
    });
  }

  // ================================================================ B 组：执行真实性

  // ---- AC-009 客户端侧观测存在且有请求完成（只对 loadtest runner）
  for (const { sc, inv } of invocationsOf(ART)) {
    if (sc.runner !== 'loadtest') continue;
    const where = `${sc.scenario_id}[${inv.step_index}]`;
    if (!inv.observed) { add('AC-009', `${where}: observed 缺席`); continue; }
    const ok = sorted(Object.keys(inv.observed));
    if (JSON.stringify(ok) !== JSON.stringify(sorted(OBSERVED_KEYS))) add('AC-009', `${where}: observed 的键集不是封闭的 10 个（实际 ${ok.join(',')}）`);
    if (!(Number(inv.observed.total_requests) > 0)) add('AC-009', `${where}: observed.total_requests 不是 > 0`);
    const pk = sorted(Object.keys(inv.observed.percentiles || {}));
    if (JSON.stringify(pk) !== JSON.stringify(sorted(PERCENTILE_KEYS))) add('AC-009', `${where}: observed.percentiles 的键集不是 50/90/95/99 四个（实际 ${pk.join(',')}）`);
    else for (const k of PERCENTILE_KEYS) if (typeof inv.observed.percentiles[k] !== 'number') add('AC-009', `${where}: observed.percentiles["${k}"] 不是 number`);
    if (typeof inv.observed.error_rate !== 'number') add('AC-009', `${where}: observed.error_rate 不是 number`);
  }

  // ---- AC-010 桩确实收到了请求（只对 loadtest runner；python runner 豁免）
  for (const { sc, inv } of invocationsOf(ART)) {
    if (sc.runner !== 'loadtest') continue;
    if (!(Number(inv.stub_observed && inv.stub_observed.requests) > 0)) add('AC-010', `${sc.scenario_id}[${inv.step_index}]: stub_observed.requests 不是 > 0`);
  }

  // ---- AC-011 两侧请求数的差有界
  for (const { sc, inv } of invocationsOf(ART)) {
    if (!inv.observed) continue;
    const c = Number(inv.concurrency);
    const diff = Math.abs(Number(inv.stub_observed.requests) - Number(inv.observed.total_requests));
    if (!(diff <= c + 5)) add('AC-011', `${sc.scenario_id}[${inv.step_index}]: 两侧请求数的差超过了 concurrency+5 的上界`);
  }

  // ---- AC-012 URL 只换 origin，path 与 query 逐字保留
  for (const { sc, inv } of invocationsOf(ART)) {
    const where = `${sc.scenario_id}[${inv.step_index}]`;
    const parts = urlParts(String(inv.executed_url || ''));
    if (!parts) { add('AC-012', `${where}: executed_url 不是可解析的 URL`); continue; }
    const origin = ART && ART.execution && ART.execution.stub ? ART.execution.stub.origin : null;
    if (origin && parts.origin !== origin) add('AC-012', `${where}: executed_url 的 origin 与 execution.stub.origin 不一致`);
    if (!isLoopback(parts.host)) add('AC-012', `${where}: executed_url 的 host 不是回环地址`);
    if (sc.runner === 'python') continue;   // python runner 的自陈命令里没有 URL ⇒ 不比 path
    const rev = reverseArgv(inv.argv);
    if (!rev) { add('AC-012', `${where}: 计划的 argv 不是 REQ-012 规范形态，无法核对 path`); continue; }
    const planParts = urlParts(rev.url);
    if (!planParts) { add('AC-012', `${where}: 计划的 URL 不可解析`); continue; }
    if (parts.path !== planParts.path || parts.query !== planParts.query) add('AC-012', `${where}: executed_url 的 path+query 与计划不逐字相同`);
  }

  // ---- AC-013 顺序执行且无时间重叠
  {
    const invs = invocationsOf(ART);
    for (let i = 1; i < invs.length; i++) {
      const a = invs[i - 1].inv.stub_observed || {};
      const b = invs[i].inv.stub_observed || {};
      if (!(Number(a.requests) > 0) || !(Number(b.requests) > 0)) continue;   // 零请求的 invocation 没有时序窗口可比
      if (Number(a.last_at_ms) > Number(b.first_at_ms)) add('AC-013', `第 ${i - 1} 条与第 ${i} 条 invocation 的桩侧时序窗口重叠（顺序执行被破坏）`);
    }
  }

  // ---- AC-014 桩侧观测是本次增量
  //  ⚠️ 契约原文是「不存在 i 使 requests[i] ≥ sum(requests[0..i-1])」——该式在 i=1 时对**任何**实现都成立
  //     （requests[1] 与 requests[0] 量级相当 ⇒ 必然 ≥）⇒ 照抄会把正确实现判红。
  //     门采用**可判别**的等价口径：从第 3 条起，本次增量必须**小于**前面各条之和（累计口径则必然 ≥）。
  {
    const invs = invocationsOf(ART);
    const reqs = invs.map((x) => Number(x.inv.stub_observed && x.inv.stub_observed.requests));
    let prefix = reqs.length > 0 ? reqs[0] : 0;
    for (let i = 1; i < reqs.length; i++) {
      if (i >= 2 && reqs[i] >= prefix) add('AC-014', `第 ${i} 条 invocation 的桩侧请求数不小于前面各条之和 ⇒ 像是累计口径而不是本次增量`);
      prefix += reqs[i];
    }
  }

  // ---- AC-015 桩只监听回环地址
  if (ART && ART.execution && ART.execution.stub) {
    const parts = urlParts(String(ART.execution.stub.origin || ''));
    if (!parts) add('AC-015', 'execution.stub.origin 不是可解析的 URL');
    else if (!isLoopback(parts.host)) add('AC-015', 'execution.stub.origin 的 host 不是回环地址');
  }

  // ================================================================ C 组：判定语义

  // ---- AC-016 阈值判定条数与键的对应
  for (const { sc, inv } of invocationsOf(ART)) {
    const pTh = (sc.thresholds_status === 'provided' && sc.thresholds) ? sc.thresholds : {};
    const entries = Array.isArray(inv.thresholds) ? inv.thresholds : [];
    if (entries.length !== Object.keys(pTh).length) add('AC-016', `${sc.scenario_id}[${inv.step_index}]: 阈值判定条数与该场景的阈值键数不一致`);
    const got = new Set(entries.map((e) => e.key));
    if (!sameSet(got, new Set(Object.keys(pTh)))) add('AC-016', `${sc.scenario_id}[${inv.step_index}]: 阈值判定键集合与计划的阈值键集合不相等`);
  }

  // ---- AC-017 阈值判定条目的字段集与取值保真
  for (const { sc, inv } of invocationsOf(ART)) {
    const pTh = (sc.thresholds_status === 'provided' && sc.thresholds) ? sc.thresholds : {};
    for (const e of (inv.thresholds || [])) {
      const where = `${sc.scenario_id}[${inv.step_index}]/${e.key}`;
      const got = sorted(Object.keys(e));
      if (JSON.stringify(got) !== JSON.stringify(sorted(THRESHOLD_ENTRY_KEYS))) add('AC-017', `${where}: 阈值判定条目的键集不是 5 个（实际 ${got.join(',')}）`);
      if (!VERDICTS.includes(e.verdict)) add('AC-017', `${where}: verdict 取值不在封闭的 3 个枚举内（${e.verdict}）`);
      if (typeof e.reason !== 'string' || e.reason.trim() === '') add('AC-017', `${where}: reason 不是非空字符串`);
      if (Object.prototype.hasOwnProperty.call(pTh, e.key)) {
        if (e.key !== e.key) add('AC-017', `${where}: 阈值键与计划不一致`);
        if (e.threshold !== pTh[e.key]) add('AC-017', `${where}: 阈值值与计划不逐字相同`);
      } else {
        add('AC-017', `${where}: 出现了计划里没有的阈值键`);
      }
    }
  }

  // ---- AC-018 max_concurrency 恒判不可判定
  for (const { sc, inv } of invocationsOf(ART)) {
    for (const e of (inv.thresholds || [])) {
      if (e.key !== 'max_concurrency') continue;
      const where = `${sc.scenario_id}[${inv.step_index}]/max_concurrency`;
      if (e.verdict !== 'undetermined') add('AC-018', `${where}: verdict 不是 "undetermined"（无对应观测量 ⇒ 恒不可判定）`);
      if (e.observed !== null) add('AC-018', `${where}: observed 不是 null`);
      if (typeof e.reason !== 'string' || !e.reason.includes('max_concurrency')) add('AC-018', `${where}: reason 没有点名 max_concurrency`);
    }
  }

  // ---- AC-019 默认桩下延迟类与错误率类判不可判定
  {
    const stub = ART && ART.execution && ART.execution.stub;
    const isDefault = stub && Number(stub.delay_ms) === 0 && Number(stub.error_rate) === 0;
    if (isDefault) {
      for (const { sc, inv } of invocationsOf(ART)) {
        for (const e of (inv.thresholds || [])) {
          if (!['p50_latency_ms', 'p95_latency_ms', 'p99_latency_ms', 'error_rate'].includes(e.key)) continue;
          const where = `${sc.scenario_id}[${inv.step_index}]/${e.key}`;
          if (e.verdict !== 'undetermined') add('AC-019', `${where}: 默认桩下的判定不是 "undetermined"（凭空判达标/不达标）`);
          if (typeof e.reason !== 'string' || e.reason.trim() === '') add('AC-019', `${where}: reason 不是非空字符串`);
        }
      }
    }
  }

  // ---- AC-020 默认桩下 throughput_rps 仍可判
  {
    const stub = ART && ART.execution && ART.execution.stub;
    const isDefault = stub && Number(stub.delay_ms) === 0 && Number(stub.error_rate) === 0;
    if (isDefault) {
      for (const { sc, inv } of invocationsOf(ART)) {
        for (const e of (inv.thresholds || [])) {
          if (e.key !== 'throughput_rps') continue;
          const where = `${sc.scenario_id}[${inv.step_index}]/throughput_rps`;
          if (!['met', 'not_met'].includes(e.verdict)) add('AC-020', `${where}: 默认桩下的判定不是 met/not_met（过度保守 ⇒ 判定链形同虚设）`);
          if (typeof e.observed !== 'number') add('AC-020', `${where}: observed 不是 number`);
          else if (inv.observed && e.observed !== inv.observed.effective_rps) add('AC-020', `${where}: observed 与 observed.effective_rps 不相等`);
        }
      }
    }
  }

  // ---- AC-021 延迟分位映射正确
  for (const { sc, inv } of invocationsOf(ART)) {
    for (const e of (inv.thresholds || [])) {
      if (!['p50_latency_ms', 'p95_latency_ms', 'p99_latency_ms'].includes(e.key)) continue;
      const where = `${sc.scenario_id}[${inv.step_index}]/${e.key}`;
      const pk = e.key.replace('_latency_ms', '').replace(/^p/, '');
      if (e.verdict === 'undetermined') {
        if (e.observed !== null) add('AC-021', `${where}: 判 undetermined 时 observed 不是 null`);
        continue;
      }
      if (!inv.observed || !inv.observed.percentiles) { add('AC-021', `${where}: 没有客户端侧观测可比对`); continue; }
      if (e.observed !== inv.observed.percentiles[pk]) add('AC-021', `${where}: observed 与 observed.percentiles["${pk}"] 不相等`);
    }
  }

  // ---- AC-022 错误率映射正确
  for (const { sc, inv } of invocationsOf(ART)) {
    for (const e of (inv.thresholds || [])) {
      if (e.key !== 'error_rate') continue;
      const where = `${sc.scenario_id}[${inv.step_index}]/error_rate`;
      if (!inv.observed) continue;
      const tr = Number(inv.observed.total_requests);
      const te = Number(inv.observed.total_errors);
      if (tr === 0) {
        if (inv.observed.error_rate !== null) add('AC-022', `${where}: total_requests 为 0 时 observed.error_rate 必须是 null`);
      } else if (typeof inv.observed.error_rate !== 'number' || Math.abs(inv.observed.error_rate - te / tr) > 1e-9) {
        add('AC-022', `${where}: observed.error_rate 与 total_errors/total_requests 重算不一致`);
      }
      if (e.verdict === 'undetermined') {
        if (e.observed !== null) add('AC-022', `${where}: 判 undetermined 时 observed 不是 null`);
      } else if (typeof e.observed === 'number' && typeof inv.observed.error_rate === 'number') {
        if (Math.abs(e.observed - inv.observed.error_rate) > 1e-9) add('AC-022', `${where}: observed 与 observed.error_rate 不相等`);
      }
    }
  }

  // ---- AC-023 汇总判定不掩盖失败
  {
    const v = ART && ART.verdict;
    const invs = invocationsOf(ART);
    if (!v) add('AC-023', 'verdict 段缺席');
    else {
      const got = sorted(Object.keys(v));
      if (JSON.stringify(got) !== JSON.stringify(sorted(VERDICT_SECTION_KEYS))) add('AC-023', `verdict 段的键集不是封闭的 6 个（实际 ${got.join(',')}）`);
      const counts = (Number(v.invocations_met) || 0) + (Number(v.invocations_not_met) || 0) + (Number(v.invocations_undetermined) || 0);
      if (counts !== Number(v.invocations_total)) add('AC-023', 'verdict 的三类计数之和不等于 invocations_total');
      if (Number(v.invocations_total) !== invs.length) add('AC-023', 'verdict.invocations_total 与结果产物里的 invocation 总条数不一致');
      const real = { met: 0, not_met: 0, undetermined: 0 };
      for (const { inv } of invs) if (real[inv.verdict] !== undefined) real[inv.verdict] += 1;
      if (real.met !== Number(v.invocations_met) || real.not_met !== Number(v.invocations_not_met) || real.undetermined !== Number(v.invocations_undetermined)) {
        add('AC-023', 'verdict 的三类计数与逐条 invocation 的判定对不上');
      }
      if (real.not_met > 0 && v.suite === 'met') add('AC-023', '存在判 not_met 的 invocation，但套件汇总判成了 met（掩盖失败）');
      const undet = new Set();
      for (const { inv } of invs) for (const t of (inv.thresholds || [])) if (t.verdict === 'undetermined') undet.add(t.key);
      const listed = new Set(Array.isArray(v.undetermined_keys) ? v.undetermined_keys : []);
      for (const k of undet) if (!listed.has(k)) add('AC-023', `verdict.undetermined_keys 漏了 ${k}`);
    }
    // 联合口径（契约 F6.3）：错误率判 not_met ⇒ 同一次 invocation 的吞吐不得判 met
    for (const art of [ART, ART_ERR]) {
      if (!art) continue;
      for (const { sc, inv } of invocationsOf(art)) {
        const er = (inv.thresholds || []).find((t) => t.key === 'error_rate');
        const tp = (inv.thresholds || []).find((t) => t.key === 'throughput_rps');
        if (er && tp && er.verdict === 'not_met' && tp.verdict === 'met') {
          add('AC-023', `${sc.scenario_id}[${inv.step_index}]: error_rate 判 not_met 但 throughput_rps 判 met（违反联合口径）`);
        }
      }
    }
  }

  // ================================================================ D 组：诚实性

  // ---- AC-024 产物不得出现生产容量表述
  if (ART) {
    const texts = [];
    const walk = (node, p) => {
      if (node === null || node === undefined) return;
      if (typeof node === 'string') { texts.push(node); return; }
      if (typeof node === 'number' || typeof node === 'boolean') return;
      if (Array.isArray(node)) { node.forEach((v, i) => walk(v, `${p}[${i}]`)); return; }
      for (const [k, v] of Object.entries(node)) { texts.push(k); walk(v, `${p}.${k}`); }
    };
    walk(ART, '');
    const blob = texts.join('\n');
    const low = blob.toLowerCase();
    for (const w of FORBIDDEN_WORDS) if (low.includes(w.toLowerCase())) add('AC-024', `结果产物里出现了禁表述「${w}」`);
    if (!blob.includes('本地桩') && !blob.includes('127.0.0.1')) add('AC-024', '结果产物里没有出现「本地桩」或 127.0.0.1 的限定语');
  }

  // ---- AC-025 判定用词不与用例级混用
  if (ART) {
    const bad = [];
    const walk = (node) => {
      if (node === null || node === undefined) return;
      if (typeof node === 'string') {
        if (['passed', 'failed', 'blocked', 'skipped'].includes(node)) bad.push(`判定取值「${node}」`);
        for (const f of ['results.json', 'meta.json', 'cases.json', 'case_id', 'verdict.mjs']) if (node.includes(f)) bad.push(`用例级文件名/键名「${f}」`);
        return;
      }
      if (typeof node === 'number' || typeof node === 'boolean') return;
      if (Array.isArray(node)) { node.forEach(walk); return; }
      for (const [k, v] of Object.entries(node)) {
        if (['passed', 'failed', 'blocked', 'skipped'].includes(k)) bad.push(`判定键名「${k}」`);
        for (const f of ['results.json', 'meta.json', 'cases.json', 'case_id', 'verdict.mjs']) if (k.includes(f)) bad.push(`用例级键名「${k}」`);
        walk(v);
      }
    };
    walk(ART);
    for (const b of bad) add('AC-025', `结果产物里出现了 ${b}`);
  }

  // ---- AC-026 API 模式标 api_equivalent 且实际执行参数可核
  if (ART) {
    if (ART.execution && ART.execution.mode !== 'api_equivalent') add('AC-026', 'api 模式下 execution.mode 不是 "api_equivalent"');
    for (const { sc, inv } of invocationsOf(ART)) {
      if (sc.runner !== 'loadtest') continue;
      const where = `${sc.scenario_id}[${inv.step_index}]`;
      const rev = reverseArgv(inv.argv);
      if (!rev) { add('AC-026', `${where}: 计划的 argv 不是 REQ-012 规范形态，无法反解`); continue; }
      const ep = inv.executed_params;
      if (!ep) { add('AC-026', `${where}: 缺少 executed_params`); continue; }
      const want = ['maxSeconds', 'concurrency', 'requestsPerSecond', 'agentKeepAlive', 'timeout', 'method'];
      const got = sorted(Object.keys(ep));
      if (JSON.stringify(got) !== JSON.stringify(sorted(want))) add('AC-026', `${where}: executed_params 的键集不是封闭的 6 个（实际 ${got.join(',')}）`);
      if (ep.maxSeconds !== rev.spec.maxSeconds) add('AC-026', `${where}: executed_params.maxSeconds 与 argv 的 -t 不一致`);
      if (ep.concurrency !== rev.spec.concurrency) add('AC-026', `${where}: executed_params.concurrency 与 argv 的 -c 不一致`);
      if (ep.method !== rev.spec.method) add('AC-026', `${where}: executed_params.method 与 argv 的 -m 不一致`);
      if ((ep.requestsPerSecond === null ? null : Number(ep.requestsPerSecond)) !== rev.spec.requestsPerSecond) add('AC-026', `${where}: executed_params.requestsPerSecond 与 argv 的 --rps 不一致`);
      if (ep.agentKeepAlive !== rev.spec.agentKeepAlive) add('AC-026', `${where}: executed_params.agentKeepAlive 与 argv 里有没有 -k 不一致`);
      if ((ep.timeout === null ? null : Number(ep.timeout)) !== rev.spec.timeout) add('AC-026', `${where}: executed_params.timeout 与 argv 的 -d 不一致`);
    }
  }

  // ---- AC-027 CLI 模式逐字执行且能力降级如实标注
  if (ART_CLI) {
    if (ART_CLI.execution && ART_CLI.execution.mode !== 'cli_verbatim') add('AC-027', 'cli 模式下 execution.mode 不是 "cli_verbatim"');
    for (const { sc, inv } of invocationsOf(ART_CLI)) {
      const where = `${sc.scenario_id}[${inv.step_index}]`;
      if ('executed_params' in inv) add('AC-027', `${where}: cli 模式出现了 executed_params（必须缺席）`);
      if (!inv.observed) { add('AC-027', `${where}: observed 缺席`); continue; }
      const codes = Object.keys(inv.observed.error_codes || {});
      if (codes.length !== 1 || codes[0] !== '-1') add('AC-027', `${where}: observed.error_codes 不是只有 "-1" 一个桶（实际 ${codes.join(',')}）`);
      const pk = sorted(Object.keys(inv.observed.percentiles || {}));
      if (JSON.stringify(pk) !== JSON.stringify(sorted(PERCENTILE_KEYS))) add('AC-027', `${where}: observed.percentiles 的键集不是 50/90/95/99 四个`);
      else for (const k of PERCENTILE_KEYS) if (typeof inv.observed.percentiles[k] !== 'number') add('AC-027', `${where}: observed.percentiles["${k}"] 不是 number`);
    }
  } else if (MINI_CLI.rc === 0) {
    add('AC-027', 'cli 模式跑成功但没有产物');
  }

  // ================================================================ E 组：写入纪律与幂等

  // ---- AC-028 只写 results/，输入只读
  {
    if (beforeTree !== afterTree) add('AC-028', '主跑前后项目根下（除 results/ 外）的内容有变化');
    const added = afterFiles.filter((f) => !beforeFiles.includes(f));
    if (added.length > 0) add('AC-028', `主跑在 results/ 之外新增了文件：${added.join(',')}`);
  }

  // ---- AC-029 产物已存在 ⇒ 报错不覆盖
  {
    const f = artifactPath(MAIN, 'LOAD-001-checkout');
    const before = sha256File(f);
    const again = runNode([ENTRY, '--load-dir', MAIN, '--out-dir', MAIN, '--suite', 'LOAD-001-checkout']);
    const after = sha256File(f);
    if (again.rc !== 1) add('AC-029', `第二次跑的退出码是 ${again.rc}（应为 1）`);
    if (before === null || before !== after) add('AC-029', '第二次跑覆盖/改动了既有产物（sha256 变了）');
  }

  // ---- AC-030 结构级幂等
  {
    if (!ART || !ART_IDEM) add('AC-030', '两次跑里至少有一次没有产物 ⇒ 无法比对');
    else {
      const a = normalizeArtifact(ART, MAIN);
      const b = normalizeArtifact(ART_IDEM, IDEM);
      if (a !== b) add('AC-030', '两次跑的产物在归一化后不一致（结构/键序/字符串值有差异）');
    }
  }

  // ================================================================ F 组：入口行为与退出码

  // ---- AC-031 用法错误 ⇒ 退出码 2
  {
    const cases = [
      { name: '缺 --load-dir', args: ['--out-dir', '{root}', '--suite', 'LOAD-001-checkout'] },
      { name: '未知参数 --bogus', args: ['--load-dir', '{root}', '--out-dir', '{root}', '--suite', 'LOAD-001-checkout', '--bogus'] },
      { name: '多余位置参数 extra', args: ['--load-dir', '{root}', '--out-dir', '{root}', '--suite', 'LOAD-001-checkout', 'extra'] },
    ];
    cases.forEach((c, i) => {
      const root = path.join(WORK, `run-usage-${i}`);
      copyTree(path.join(FX, 'mini'), root);
      const args = c.args.map((a) => a.replace('{root}', root));
      const r = runNode([ENTRY, ...args]);
      if (r.rc !== 2) add('AC-031', `${c.name}: 退出码是 ${r.rc}（应为 2）`);
      if (isDir(resultsDir(root))) add('AC-031', `${c.name}: 留下了 results/ 目录`);
    });
  }

  // ---- AC-032 输入非法 ⇒ 退出码 1 且点名
  {
    const cases = [
      { dir: 'bad-nosuite', must: ['LOAD-001-checkout', '不存在'], label: '计划不存在' },
      { dir: 'bad-threshold', must: ['p42_latency_ms'], label: '阈值键越界' },
      { dir: 'bad-argv', must: ['argv', '--cores'], label: 'argv 不合规' },
      { dir: 'bad-url', must: ['example.com', '回环'], label: 'URL 非回环' },
    ];
    for (const c of cases) {
      const root = path.join(FX, c.dir);
      const r = runNode([ENTRY, '--load-dir', root, '--out-dir', root, '--suite', 'LOAD-001-checkout']);
      if (r.rc !== 1) add('AC-032', `${c.label}: 退出码是 ${r.rc}（应为 1）`);
      const blob = `${r.out}\n${r.err}`;
      if (!c.must.some((m) => blob.includes(m))) add('AC-032', `${c.label}: stderr 没有点名出问题的键/文件（期望提到 ${c.must.join(' 或 ')}）`);
      if (isDir(resultsDir(root))) add('AC-032', `${c.label}: 留下了 results/ 目录`);
    }
  }

  // ---- AC-033 工具不可用 ⇒ 明确报错且不产产物
  {
    const root = path.join(WORK, 'run-notool');
    copyTree(path.join(FX, 'mini'), root);
    const toolsDir = path.join(root, '.tools');
    const moved = path.join(root, '.tools-moved');
    try { fs.renameSync(toolsDir, moved); } catch { /* 忽略 */ }
    const r = runNode([ENTRY, '--load-dir', root, '--out-dir', root, '--suite', 'LOAD-900-mini']);
    if (r.rc !== 1) add('AC-033', `工具不可用时的退出码是 ${r.rc}（应为 1）`);
    const blob = `${r.out}\n${r.err}`;
    if (!blob.includes('loadtest')) add('AC-033', 'stderr 没有点名缺 loadtest');
    if (!blob.includes('qa install')) add('AC-033', 'stderr 没有点名怎么装（缺 "qa install"）');
    if (isDir(resultsDir(root))) add('AC-033', '工具不可用时仍产出了 results/ 目录');
  }

  // ================================================================ G 组：桩与证据链

  // ---- AC-034 证据目录与 sha256 清单可复算
  {
    const evRoot = path.join(resultsDir(MAIN), 'evidence', 'LOAD-001-checkout');
    const invs = invocationsOf(ART);
    // ① 每个 invocation 恰好一个 basename == step_index 的叶子目录
    const leafDirs = [];
    const walk = (d) => {
      if (!isDir(d)) return;
      for (const n of fs.readdirSync(d).sort()) {
        const f = path.join(d, n);
        if (!isDir(f)) continue;
        if (isFile(path.join(f, 'result.json'))) leafDirs.push(f);
        walk(f);
      }
    };
    walk(evRoot);
    const used = new Set();
    for (const { sc, inv } of invs) {
      const cand = leafDirs.filter((d) => path.basename(d) === String(inv.step_index) && !used.has(d));
      if (cand.length === 0) { add('AC-034', `${sc.scenario_id}[${inv.step_index}]: 证据目录里没有以 step_index 命名的子目录`); continue; }
      used.add(cand[0]);
      // ② 恰好 3 个文件
      const names = fs.readdirSync(cand[0]).sort();
      const want = ['result.json', 'stdout.txt', 'stub-observations.json'];
      if (JSON.stringify(names) !== JSON.stringify(want)) add('AC-034', `${sc.scenario_id}[${inv.step_index}]: 证据子目录里的文件不是恰好 3 个（实际 ${names.join(',')}）`);
    }
    // ③ manifest 逐个列出 sha256 且门自己复算一致
    const manifestFile = path.join(evRoot, 'manifest.json');
    if (!isFile(manifestFile)) add('AC-034', '证据目录里没有 manifest.json');
    else {
      const manifest = readJson(manifestFile);
      if (!manifest) add('AC-034', 'manifest.json 不可解析');
      else {
        const listed = new Map();
        const addPair = (p, s) => {
          if (typeof p !== 'string' || typeof s !== 'string') return;
          if (!/^[0-9a-f]{64}$/.test(s)) return;
          listed.set(p.split(path.sep).join('/'), s);
        };
        // 形态 A：`files` 是「路径 → sha256」的映射；形态 B：`files` 是 [{path, sha256}] 数组
        const filesNode = (manifest && typeof manifest === 'object' && manifest.files !== undefined) ? manifest.files : manifest;
        if (Array.isArray(filesNode)) {
          for (const e of filesNode) {
            if (!e || typeof e !== 'object') continue;
            const p = e.path || e.file || e.name || e.key;
            const s = e.sha256 || e.sha || e.hash || e.digest;
            if (p && s) addPair(String(p), String(s));
          }
        } else if (filesNode && typeof filesNode === 'object') {
          for (const [k, v] of Object.entries(filesNode)) {
            if (typeof v === 'string') addPair(k, v);
            else if (v && typeof v === 'object') {
              const s = v.sha256 || v.sha || v.hash || v.digest;
              if (s) addPair(k, String(s));
            }
          }
        }
        // 形态 C：兜底（任意嵌套里成对出现的「路径 + 64 位十六进制」）
        if (listed.size === 0) {
          const walkM = (node) => {
            if (node === null || typeof node !== 'object') return;
            if (Array.isArray(node)) { node.forEach(walkM); return; }
            let p = null;
            let s = null;
            for (const [k, v] of Object.entries(node)) {
              if (typeof v === 'string') {
                if (/^[0-9a-f]{64}$/.test(v) && s === null) s = v;
                if ((/[\/\\]/.test(v) || /\.(json|txt)$/.test(v)) && p === null) p = v;
              } else walkM(v);
            }
            if (p && s) addPair(p, s);
          };
          walkM(manifest);
        }
        const actual = listFiles(evRoot).filter((f) => f !== 'manifest.json');
        for (const rel of actual) {
          const abs = path.join(evRoot, rel);
          const real = sha256File(abs);
          const norm = rel.split(path.sep).join('/');
          const rec = listed.get(norm) || listed.get(rel);
          if (!rec) { add('AC-034', `manifest.json 没有列出证据文件 ${norm}`); continue; }
          if (rec !== real) add('AC-034', `manifest.json 里 ${norm} 的 sha256 与门自己复算的不一致`);
        }
        if (listed.size === 0) add('AC-034', 'manifest.json 里解析不出「路径 → sha256」的对应关系');
      }
    }
  }

  // ---- AC-035 执行结束后桩已停
  {
    const origin = ART && ART.execution && ART.execution.stub ? ART.execution.stub.origin : null;
    const parts = origin ? urlParts(String(origin)) : null;
    if (!parts || !parts.port) add('AC-035', '拿不到桩的端口，无法核对桩是否已停');
    else {
      const alive = await probePort('127.0.0.1', Number(parts.port));
      if (alive) add('AC-035', '执行结束后桩的端口仍连得上 ⇒ 桩没停');
      // 进程表里不得有残留桩进程
      const ps = spawnSync('ps', ['-eo', 'pid,args'], { encoding: 'utf8' });
      const stubPath = path.join(PKG, STUB_REL);
      const residuals = (ps.stdout || '').split('\n').filter((l) => l.includes(stubPath));
      if (residuals.length > 0) {
        add('AC-035', `进程表里还有 ${residuals.length} 个残留的桩进程`);
        for (const l of residuals) {
          const pid = Number(l.trim().split(/\s+/)[0]);
          if (Number.isInteger(pid) && pid > 1) { try { process.kill(pid, 'SIGKILL'); } catch { /* 已退出 */ } }
        }
      }
    }
  }

  // ================================================================ H 组：交付红线与交付物

  // ---- AC-036 交付包不含内部运行时字样 + B 阶段交付物齐备 + 校验器行为
  {
    const scanRoots = ['skills', 'bin'].map((d) => path.join(PKG, d)).filter((d) => isDir(d));
    for (const f of ['README.md', 'LICENSE']) if (isFile(path.join(PKG, f))) scanRoots.push(path.join(PKG, f));
    for (const root of scanRoots) {
      const walk = (d) => {
        if (!isDir(d)) return;
        for (const n of fs.readdirSync(d)) {
          const f = path.join(d, n);
          const st = fs.lstatSync(f);
          if (st.isDirectory()) walk(f);
          else if (st.isFile()) {
            let text = '';
            try { text = fs.readFileSync(f, 'utf8'); } catch { continue; }
            if (/internal-rt/i.test(text)) add('AC-036', `${path.relative(PKG, f)}: 出现了内部运行时字样「internal-rt」`);
          }
        }
      };
      walk(root);
    }
    for (const rel of [ENTRY_REL, CHECKER_REL, STUB_REL, EXEC_REL, CONTRACT_REL]) {
      if (!isFile(path.join(PKG, rel))) add('AC-036', `B 阶段交付物缺失：${rel}`);
    }
    if (isFile(CHECKER)) {
      const ok = runNode([CHECKER, MAIN, '--suite', 'LOAD-001-checkout']);
      if (ok.rc !== 0) add('AC-036', `产物自洽校验器对合法项目根的退出码是 ${ok.rc}（应为 0）`);
      const tampered = path.join(WORK, 'run-tampered');
      if (isDir(MAIN)) {
        copyTree(MAIN, tampered);
        const pf = path.join(tampered, 'test-assets', 'load', 'plans', 'LOAD-001-checkout.json');
        const doc = readJson(pf);
        if (doc && doc.scenarios && doc.scenarios[0] && doc.scenarios[0].invocations) {
          doc.scenarios[0].invocations[0].argv[6] = '2';
          fs.writeFileSync(pf, JSON.stringify(doc, null, 2) + '\n');
          const bad = runNode([CHECKER, tampered, '--suite', 'LOAD-001-checkout']);
          if (bad.rc !== 1) add('AC-036', `产物自洽校验器对篡改副本的退出码是 ${bad.rc}（应为 1）`);
        }
      }
    }
  }

  // ---- AC-037 追溯件四件套含本 REQ 的条目
  {
    const fm = path.join(PKG, 'feature-meta', 'load-runner');
    const four = ['verification-report.md', 'traceability.md', 'feature.json', 'feature-meta.json'];
    for (const f of four) {
      const p = path.join(fm, f);
      if (!isFile(p)) { add('AC-037', `feature-meta/load-runner/${f} 不存在`); continue; }
      const text = fs.readFileSync(p, 'utf8');
      if (!text.includes('REQ-013')) add('AC-037', `feature-meta/load-runner/${f} 里没有 REQ-013 的条目`);
    }
    const traceFile = path.join(fm, 'traceability.md');
    if (isFile(traceFile)) {
      const text = fs.readFileSync(traceFile, 'utf8');
      // 取「当前 REQ 上下文 == REQ-013」的行里出现的决策号并集
      let cur = null;
      const got = new Set();
      for (const line of text.split(/\r?\n/)) {
        const reqs = [...line.matchAll(/REQ-\d+/g)].map((m) => m[0]);
        if (reqs.length > 0) cur = reqs[reqs.length - 1];
        if (cur !== 'REQ-013') continue;
        for (const m of line.matchAll(/\bD\d{2,4}\b/g)) got.add(m[0]);
      }
      const want = new Set(decIds);
      if (!sameSet(got, want)) {
        const missing = [...want].filter((d) => !got.has(d));
        const extra = [...got].filter((d) => !want.has(d));
        add('AC-037', `traceability.md 里 REQ-013 的决策号并集与 decisions.md 的实际集合不相等（缺 ${missing.join(',') || '无'}；多 ${extra.join(',') || '无'}）`);
      }
    }
  }

  // ---- AC-038 SKILL.md 追加了 B 阶段说明
  {
    const p = path.join(PKG, 'skills', 'load-profile', 'SKILL.md');
    if (!isFile(p)) add('AC-038', 'skills/load-profile/SKILL.md 不存在');
    else {
      const text = fs.readFileSync(p, 'utf8');
      if (!text.includes('run-load-test')) add('AC-038', 'SKILL.md 里没有提到 B 阶段入口 run-load-test');
      if (!text.includes('本地桩') && !text.includes('127.0.0.1')) add('AC-038', 'SKILL.md 里没有「只打本地桩」的边界表述');
    }
  }

  // ================================================================ I 组：注入生效与 runner 覆盖

  // ---- AC-039 注入错误后，错误码是真实 HTTP 状态码
  {
    const stub = ART_ERR && ART_ERR.execution ? ART_ERR.execution.stub : null;
    if (!stub) add('AC-039', '注入错误率的那次跑没有产物');
    else {
      if (Number(stub.error_rate) !== 1) add('AC-039', '注入错误率的那次跑里 execution.stub.error_rate 不是 1');
      for (const { sc, inv } of invocationsOf(ART_ERR)) {
        if (sc.runner !== 'loadtest') continue;
        const where = `${sc.scenario_id}[${inv.step_index}]`;
        if (!inv.observed) { add('AC-039', `${where}: observed 缺席`); continue; }
        const codes = Object.keys(inv.observed.error_codes || {});
        if (codes.includes('-1')) add('AC-039', `${where}: observed.error_codes 里出现了 "-1"（漏设 statusCallback ⇒ 错误码塌成 -1）`);
        if (!codes.includes('500')) add('AC-039', `${where}: observed.error_codes 里没有真实状态码 "500"（实际 ${codes.join(',')}）`);
        else if (inv.observed.error_codes['500'] !== inv.observed.total_requests) add('AC-039', `${where}: error_codes["500"] 的计数不等于 total_requests`);
        if (inv.observed.error_rate !== 1) add('AC-039', `${where}: observed.error_rate 不是 1`);
      }
    }
  }

  // ---- AC-040 注入延迟后，延迟类与错误率类恢复可判
  {
    const checkDelay = (art, ac, label) => {
      if (!art) { add(ac, `${label}：没有产物`); return; }
      const stub = art.execution ? art.execution.stub : null;
      if (!stub || Number(stub.delay_ms) !== 50) add(ac, `${label}：execution.stub.delay_ms 不是 50`);
      for (const { sc, inv } of invocationsOf(art)) {
        for (const e of (inv.thresholds || [])) {
          const where = `${label}/${sc.scenario_id}[${inv.step_index}]/${e.key}`;
          if (['p50_latency_ms', 'p95_latency_ms', 'p99_latency_ms', 'error_rate'].includes(e.key)) {
            if (!['met', 'not_met'].includes(e.verdict)) add(ac, `${where}: 注入后判定不是 met/not_met（仍是 undetermined ⇒ 过度保守）`);
            if (typeof e.observed !== 'number') add(ac, `${where}: 注入后 observed 不是 number`);
          }
        }
      }
    };
    checkDelay(ART_DLY, 'AC-040', '最小夹具注入 50ms');
    checkDelay(ART_DLY_LAT, 'AC-040', '补充夹具注入 50ms');
  }

  // ---- AC-041 python runner 的 invocation 一律不可判定
  {
    const py = invocationsOf(ART).filter((x) => x.sc.runner === 'python');
    if (py.length === 0) add('AC-041', '结果产物里没有 python runner 的 invocation');
    for (const { sc, inv } of py) {
      const where = `${sc.scenario_id}[${inv.step_index}]`;
      if ('observed' in inv) add('AC-041', `${where}: python runner 的 invocation 出现了 observed（凭空造观测量）`);
      if (inv.verdict !== 'undetermined') add('AC-041', `${where}: python runner 的 invocation 判定不是 "undetermined"`);
      if (!Array.isArray(inv.thresholds) || inv.thresholds.length !== 0) add('AC-041', `${where}: python runner 的 invocation 的 thresholds 不是空数组`);
      if (!inv.stub_observed || typeof inv.stub_observed.requests !== 'number') add('AC-041', `${where}: stub_observed.requests 不是 number`);
      // 证据目录里必须有它的 step_index 子目录
      const evRoot = path.join(resultsDir(MAIN), 'evidence', 'LOAD-001-checkout');
      let found = false;
      const walk = (d) => {
        if (found || !isDir(d)) return;
        for (const n of fs.readdirSync(d)) {
          const f = path.join(d, n);
          if (!isDir(f)) continue;
          if (path.basename(f) === String(inv.step_index) && isFile(path.join(f, 'result.json'))) { found = true; return; }
          walk(f);
        }
      };
      walk(evRoot);
      if (!found) add('AC-041', `${where}: 证据目录里没有它的 step_index 子目录（python runner 也必须产生证据）`);
    }
  }

  // ================================================================ 门级探针：D202 `.loadtestrc` 渗透
  //
  //  ⚠️ API 路径**也会**读宿主目录下的 `.loadtestrc`（B12 / D202）⇒ 执行器必须**显式覆盖**每个相关
  //     选项并**显式禁 `proxy`**。本探针在**独立的一次跑**里放一个敌意的 `.loadtestrc`
  //     （改 concurrency / method + 指向一个关着的端口的 proxy）⇒ 渗透会让这次跑直接失败或让桩收不到请求。
  {
    const probeDir = path.join(WORK, 'rc-probe');
    fs.mkdirSync(probeDir, { recursive: true });
    fs.writeFileSync(path.join(probeDir, '.loadtestrc'), JSON.stringify({ concurrency: 64, method: 'DELETE', proxy: 'http://127.0.0.1:1' }));
    const root = path.join(WORK, 'run-rcprobe');
    copyTree(path.join(FX, 'mini'), root);
    const r = runNode([ENTRY, '--load-dir', root, '--out-dir', root, '--suite', 'LOAD-900-mini'], { cwd: probeDir });
    const art = readJson(artifactPath(root, 'LOAD-900-mini'));
    if (r.rc !== 0 || !art) {
      addGate('GATE-D202', `宿主目录下的 .loadtestrc 疑似渗透进执行（这次跑失败了，rc=${r.rc}）—— D202 要求显式覆盖每个相关选项并显式禁 proxy`);
    } else {
      let reached = false;
      for (const { sc, inv } of invocationsOf(art)) {
        if (sc.runner !== 'loadtest') continue;
        if (Number(inv.stub_observed && inv.stub_observed.requests) > 0) reached = true;
      }
      if (!reached) addGate('GATE-D202', '宿主目录下的 .loadtestrc 疑似渗透进执行（桩侧没有收到请求）—— D202 要求显式覆盖每个相关选项并显式禁 proxy');
    }
  }

  finish(acIds);
}

const probePort = (host, port) => new Promise((resolve) => {
  const s = net.connect({ host, port });
  let done = false;
  const fin = (v) => { if (!done) { done = true; try { s.destroy(); } catch { /* 忽略 */ } resolve(v); } };
  s.on('connect', () => fin(true));
  s.on('error', () => fin(false));
  setTimeout(() => fin(false), 2000);
});

function finish(acIds) {
  const out = [];
  for (const ac of acIds) {
    const f = findings.get(ac) || [];
    const u = undecs.get(ac) || [];
    if (f.length > 0) out.push({ ac, status: 'FAIL', msg: f.slice(0, 6).join('；') + (f.length > 6 ? `（共 ${f.length} 项）` : '') });
    else if (u.length > 0) out.push({ ac, status: 'UNDEC', msg: u.join('；') });
    else out.push({ ac, status: 'PASS', msg: '满足' });
  }
  for (const g of gateFindings) out.push({ ac: g.ac, status: 'GATE', msg: g.msg });
  process.stdout.write(JSON.stringify({ results: out }) + '\n');
  process.exit(0);
}

main().catch((e) => {
  const msg = e && e.message ? e.message : String(e);
  process.stdout.write(JSON.stringify({ results: [{ ac: 'GATE', status: 'UNDEC', msg: `复算器异常：${msg}` }] }) + '\n');
  process.exit(0);
});

QA013_JUDGE_EOF

cat > "$WORK/fp.mjs" <<'QA013_FP_EOF'
// 可观测状态指纹 —— 变异体自证 + 只读自检用
// 用法: node fp.mjs <目录>
// 输出: 该目录的**字节级 + 权限位**树指纹（sha256）
//
// ⚠️ **为什么不做语义归一化**：语义归一化（JSON 解析后按 key 排序再哈希）对**语义等价**的改动恒不变
//    ⇒ ① 负控永远「没生效」⇒ 负控无效；② `chmod -x`（内容不变、权限位变了）也永远「没生效」。
//    ⇒ 本实现记 **原始字节 sha256 + 权限位**：任一条目变化 ⇒ 篡改生效。
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const sha = (p) => {
  try { return crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex'); } catch { return 'MISSING'; }
};

const treeHash = (dir) => {
  const lines = [];
  const base = path.resolve(dir);
  const walk = (d) => {
    if (!fs.existsSync(d)) return;
    lines.push(`D ${path.relative(base, d) || '.'}`);
    for (const n of fs.readdirSync(d).sort()) {
      const f = path.join(d, n);
      const st = fs.lstatSync(f);
      if (st.isDirectory()) walk(f);
      else if (st.isFile()) lines.push(`F ${path.relative(base, f)} ${(st.mode & 0o7777).toString(8)} ${sha(f)}`);
    }
  };
  walk(base);
  return crypto.createHash('sha256').update(lines.join('\n')).digest('hex');
};

process.stdout.write(`${treeHash(process.argv[2])}\n`);

QA013_FP_EOF

cat > "$WORK/mut-shim.mjs" <<'QA013_SHIM_EOF'
#!/usr/bin/env node
// 变异体包装层（**只存在于变异副本里**）：先跑原实现，再对产物/输入/退出码做一处语义篡改。
// ⚠️ 由门注入到**变异副本**的 skills/load-profile/scripts/run-load-test.mjs；
//    原实现被移到同目录的 run-load-test.real.mjs（权限位保留）。
// ⚠️ 篡改**自证生效**：改动生效时写一行 "<变异体编号>:applied" 到 $QA013_MUT_MARKER。
//    门据此判定「变异真的生效了」⇒ 没写标记的变异体一律**无效**（不计入分母）。
import { spawnSync, spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const real = path.join(here, 'run-load-test.real.mjs');
const args = process.argv.slice(2);
const MUT = process.env.QA013_MUT || '';
const MARKER = process.env.QA013_MUT_MARKER || '';

const THRESHOLD_KEYS = ['p50_latency_ms', 'p95_latency_ms', 'p99_latency_ms', 'error_rate', 'throughput_rps', 'max_concurrency'];
const argOf = (n) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : null; };
const loadDir = argOf('--load-dir') || '';
const outDir = argOf('--out-dir') || '';
const suite = argOf('--suite') || '';
const mode = argOf('--mode') || 'api';
const errRate = argOf('--stub-error-rate');
const delayMs = argOf('--stub-delay-ms');
const isMain = suite === 'LOAD-001-checkout';
const isMini = suite === 'LOAD-900-mini';
const resultsDir = path.join(outDir, 'test-assets', 'load', 'results');
const resultFile = path.join(resultsDir, `${suite}.json`);
const evidenceRoot = path.join(resultsDir, 'evidence', suite);

const readJson = (f) => { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch { return null; } };
const writeJson = (f, v) => { fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, JSON.stringify(v, null, 2) + '\n'); };
const applied = (extra) => {
  if (!MARKER) return;
  try { fs.appendFileSync(MARKER, `${MUT}:applied${extra ? ' ' + extra : ''}\n`); } catch { /* 标记失败也不改退出码 */ }
};

// ---------------------------------------------------------------- 前置：拦截 / 改输入

const looksUsageError = () => {
  const i = args.indexOf('--load-dir');
  if (i < 0) return true;
  const v = args[i + 1];
  if (v === undefined || String(v).startsWith('--')) return true;
  if (args.includes('--bogus')) return true;
  if (args.some((a) => a === 'extra')) return true;
  return false;
};

const planInvalid = () => {
  const planFile = path.join(loadDir, 'test-assets', 'load', 'plans', `${suite}.json`);
  const plan = readJson(planFile);
  if (!plan) return true;
  for (const sc of (plan.scenarios || [])) {
    for (const k of Object.keys(sc.thresholds || {})) if (!THRESHOLD_KEYS.includes(k)) return true;
    for (const inv of (sc.invocations || [])) {
      if (sc.runner !== 'loadtest') continue;
      const a = inv.argv || [];
      if (a[5] !== '--cores' || a[6] !== '1') return true;
      let host = '';
      try { host = new URL(String(a[7])).hostname; } catch { return true; }
      if (!/^127\./.test(host)) return true;
    }
  }
  return false;
};

const toolMissing = () => {
  const mod = path.join(loadDir, '.tools', 'node', 'node_modules', 'loadtest');
  const bin = path.join(loadDir, '.tools', 'node', 'node_modules', '.bin', 'loadtest');
  return !fs.existsSync(mod) && !fs.existsSync(bin);
};

if (MUT === 'ac031' && looksUsageError()) {
  // 把「用法错误」当成「输入非法」（退出码 1 而不是 2）
  applied();
  process.stderr.write('[mutant] 用法错误当成输入非法\n');
  process.exit(1);
}
if (MUT === 'ac032' && planInvalid()) {
  // 静默忽略非法输入：退出码对，但不点名
  applied();
  process.exit(1);
}
if (MUT === 'ac033' && toolMissing()) {
  // 工具缺失时「假装压过」：直接成功退出，不产任何产物
  applied();
  process.exit(0);
}
if (MUT === 'ac028' && isMain) {
  // 顺手把计划文件改写（内容语义不变，只是多了一个换行 ⇒ sha256 变了）
  const pf = path.join(loadDir, 'test-assets', 'load', 'plans', `${suite}.json`);
  if (fs.existsSync(pf)) {
    const before = fs.readFileSync(pf, 'utf8');
    fs.writeFileSync(pf, `${before}\n`);
    applied();
  }
}
if (MUT === 'ac029' && isMain && fs.existsSync(resultFile)) {
  // 产物已存在 ⇒ 直接删掉，让原实现覆盖写
  try { fs.unlinkSync(resultFile); } catch { /* 忽略 */ }
  applied();
}
if (MUT === 'ac039' && errRate !== null) {
  // 「漏设 statusCallback」的等效注入：让 loadtest 忽略 statusCallback ⇒ 错误码塌成 "-1"
  const tf = path.join(loadDir, '.tools', 'node', 'node_modules', 'loadtest', 'lib', 'httpClient.js');
  try {
    const src = fs.readFileSync(tf, 'utf8');
    const needle = 'if (!this.options.statusCallback && !this.options.contentInspector) {';
    if (src.includes(needle)) {
      fs.writeFileSync(tf, src.replace(needle, 'if (true) {'));
      applied('patched-statuscallback');
    }
  } catch { /* 忽略 */ }
}

// ---------------------------------------------------------------- 跑原实现

const run = spawnSync(process.execPath, [real, ...args], { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
if (run.stdout) process.stdout.write(run.stdout);
if (run.stderr) process.stderr.write(run.stderr);
let rc = run.status === null ? 1 : run.status;

// ---------------------------------------------------------------- 后置：篡改产物

if (rc === 0) {
  const doc = readJson(resultFile);
  const invs = (doc && Array.isArray(doc.scenarios)) ? doc.scenarios.flatMap((s) => (s.invocations || []).map((iv) => ({ s, iv }))) : [];
  const loadtestInvs = invs.filter((x) => x.s.runner === 'loadtest');
  const pyInvs = invs.filter((x) => x.s.runner === 'python');
  const save = () => writeJson(resultFile, doc);

  switch (MUT) {
    case 'ac001': {
      // 落点错：results/ 下多出一个 suite.json（上游对 suite.json 的顶层字段集封闭）
      if (doc && isMain) { fs.copyFileSync(resultFile, path.join(resultsDir, 'suite.json')); applied(); }
      break;
    }
    case 'ac002': {
      if (doc && isMain) { doc.status = 'ok'; save(); applied(); }
      break;
    }
    case 'ac003': {
      if (doc && isMain) { doc.schema_version = '1'; save(); applied(); }
      break;
    }
    case 'ac004': {
      if (doc && isMain) { doc.results_sha256 = '0'.repeat(64); save(); applied(); }
      break;
    }
    case 'ac005': {
      if (doc && isMain) { doc.execution.tool.path = '/usr/local/bin/loadtest'; save(); applied(); }
      break;
    }
    case 'ac006': {
      if (doc && isMain && doc.scenarios.length >= 3) {
        const t = doc.scenarios[1]; doc.scenarios[1] = doc.scenarios[2]; doc.scenarios[2] = t; save(); applied();
      }
      break;
    }
    case 'ac007': {
      if (doc && isMain) {
        const sc = doc.scenarios.find((s) => s.thresholds_status === 'not_provided');
        if (sc) { sc.thresholds = {}; sc.thresholds_source = '凭空造的来源'; save(); applied(); }
      }
      break;
    }
    case 'ac008': {
      if (doc && isMain) {
        for (const { iv } of loadtestInvs) {
          const a = iv.argv || [];
          const i = a.indexOf('--cores');
          if (i >= 0 && a[i + 1] === '1') { a[i + 1] = '2'; applied(); }
        }
        save();
      }
      break;
    }
    case 'ac009': {
      if (doc && isMain && loadtestInvs.length) { loadtestInvs[0].iv.observed.total_requests = 0; save(); applied(); }
      break;
    }
    case 'ac010': {
      if (doc && isMain && loadtestInvs.length) { loadtestInvs[0].iv.stub_observed.requests = 0; save(); applied(); }
      break;
    }
    case 'ac011': {
      if (doc && isMain && loadtestInvs.length) { loadtestInvs[0].iv.stub_observed.requests = 999999; save(); applied(); }
      break;
    }
    case 'ac012': {
      if (doc && isMain && loadtestInvs.length) {
        loadtestInvs[0].iv.executed_url = String(loadtestInvs[0].iv.executed_url).replace('/api/v1/', '/api/v2/'); save(); applied();
      }
      break;
    }
    case 'ac013': {
      if (doc && isMain && loadtestInvs.length >= 2) {
        loadtestInvs[1].iv.stub_observed.first_at_ms = 0; save(); applied();
      }
      break;
    }
    case 'ac014': {
      if (doc && isMain && loadtestInvs.length >= 3) {
        const sum = loadtestInvs.slice(0, 3).reduce((a, x) => a + Number(x.iv.stub_observed.requests), 0);
        loadtestInvs[2].iv.stub_observed.requests = sum; save(); applied();
      }
      break;
    }
    case 'ac015': {
      if (doc && isMain) {
        const o = doc.execution.stub.origin;
        const port = (String(o).match(/:(\d+)$/) || [])[1] || '0';
        doc.execution.stub.origin = `http://0.0.0.0:${port}`; save(); applied();
      }
      break;
    }
    case 'ac016': {
      if (doc && isMain && loadtestInvs.length) {
        const t = loadtestInvs[0].iv.thresholds.filter((x) => x.key !== 'max_concurrency');
        loadtestInvs[0].iv.thresholds = t; save(); applied();
      }
      break;
    }
    case 'ac017': {
      if (doc && isMain && loadtestInvs.length) {
        const e = loadtestInvs[0].iv.thresholds.find((x) => x.key === 'p95_latency_ms');
        if (e) { e.verdict = 'passed'; save(); applied(); }
      }
      break;
    }
    case 'ac018': {
      if (doc && isMain && loadtestInvs.length) {
        const e = loadtestInvs[0].iv.thresholds.find((x) => x.key === 'max_concurrency');
        if (e) { e.verdict = 'met'; e.observed = 8; save(); applied(); }
      }
      break;
    }
    case 'ac019': {
      if (doc && isMain && loadtestInvs.length) {
        const e = loadtestInvs[0].iv.thresholds.find((x) => x.key === 'p95_latency_ms');
        const o = loadtestInvs[0].iv.observed;
        if (e && o) { e.verdict = 'met'; e.observed = o.percentiles['95']; save(); applied(); }
      }
      break;
    }
    case 'ac020': {
      if (doc && isMain && loadtestInvs.length) {
        const e = loadtestInvs[0].iv.thresholds.find((x) => x.key === 'throughput_rps');
        if (e) { e.verdict = 'undetermined'; save(); applied(); }
      }
      break;
    }
    case 'ac021': {
      if (doc && isMain && loadtestInvs.length) {
        const e = loadtestInvs[0].iv.thresholds.find((x) => x.key === 'p95_latency_ms');
        const o = loadtestInvs[0].iv.observed;
        if (e && o) { e.observed = o.percentiles['99']; save(); applied(); }
      }
      break;
    }
    case 'ac022': {
      if (doc && isMain && loadtestInvs.length) {
        const e = loadtestInvs[0].iv.thresholds.find((x) => x.key === 'error_rate');
        if (e) { e.observed = 0.5; save(); applied(); }
      }
      break;
    }
    case 'ac023': {
      if (doc && isMain) { doc.verdict.invocations_not_met = 99; save(); applied(); }
      break;
    }
    case 'ac024': {
      if (doc && isMain) { doc.verdict.note = '生产环境容量达标'; save(); applied(); }
      break;
    }
    case 'ac025': {
      if (doc && isMain) { doc.verdict.status = 'passed'; save(); applied(); }
      break;
    }
    case 'ac026': {
      if (doc && isMain && loadtestInvs.length) { loadtestInvs[0].iv.executed_params.maxSeconds = 999; save(); applied(); }
      break;
    }
    case 'ac027': {
      if (doc && mode === 'cli') { doc.execution.mode = 'api_equivalent'; save(); applied(); }
      break;
    }
    case 'ac030': {
      if (doc && isMain) { doc.execution.run_tag = path.basename(outDir); save(); applied(); }
      break;
    }
    case 'ac034': {
      if (doc && isMain) {
        const mf = path.join(evidenceRoot, 'manifest.json');
        const m = readJson(mf);
        if (m) {
          const walk = (node) => {
            if (!node || typeof node !== 'object') return false;
            if (Array.isArray(node)) return node.some(walk);
            for (const [k, v] of Object.entries(node)) {
              if (typeof v === 'string' && /^[0-9a-f]{64}$/.test(v)) { node[k] = 'f'.repeat(64); return true; }
              if (walk(v)) return true;
            }
            return false;
          };
          if (walk(m)) { writeJson(mf, m); applied(); }
        }
      }
      break;
    }
    case 'ac035': {
      // 「桩没停」的等效注入：执行结束后仍占着桩的端口（起一个脱离的监听器）
      if (doc && isMain) {
        const origin = doc.execution.stub.origin;
        const port = (String(origin).match(/:(\d+)$/) || [])[1];
        if (port) {
          const code = `const net=require('net');let n=0;function go(){const s=net.createServer(()=>{});s.on('error',()=>{n++;if(n<40)setTimeout(go,100);});s.listen(${port},'127.0.0.1',()=>{});}go();`;
          const child = spawn(process.execPath, ['-e', code], { detached: true, stdio: 'ignore' });
          child.unref();
          applied('listener-held');
        }
      }
      break;
    }
    case 'ac040': {
      if (doc && delayMs !== null) {
        for (const { iv } of loadtestInvs) {
          for (const e of (iv.thresholds || [])) {
            if (['p50_latency_ms', 'p95_latency_ms', 'p99_latency_ms'].includes(e.key)) {
              e.verdict = 'undetermined'; e.observed = null;
            }
          }
        }
        save(); applied();
      }
      break;
    }
    case 'ac041': {
      if (doc && isMain && pyInvs.length) {
        pyInvs[0].iv.observed = { total_requests: 10, total_errors: 0, error_codes: {}, error_rate: 0, mean_latency_ms: 1, effective_rps: 10, percentiles: { '50': 1, '90': 1, '95': 1, '99': 1 }, max_latency_ms: 2, min_latency_ms: 1, elapsed_seconds: 1 };
        save(); applied();
      }
      break;
    }
    case 'control': {
      // 负控：只改 `generated_at` 的取值（语义不变 ⇒ 不该让任何判据变红）
      if (doc && isMain) {
        const t = new Date(Date.now() + 3600 * 1000).toISOString();
        doc.generated_at = t; save(); applied(t);
      }
      break;
    }
    default:
      break;
  }
}

process.exit(rc);

QA013_SHIM_EOF

# ---------------------------------------------------------------- 工具前置（门**不装工具**）
#
# ⚠️ 契约 §0.1：门本身**不装工具**（工具安装是验收前置）。本门只把**已经装好的** loadtest 树
#    **拷贝**进夹具的 .tools/，以满足该前置；找不到已装好的 loadtest ⇒ 明确报错，
#    工具类判据判红（不静默跳过，也不偷偷装）。

TOOL_SRC=""
for cand in "${QA013_LOADTEST_SRC:-}" "$WORK_PARENT/toolchain" "$WORK_PARENT/lt" "$PKG/.tools/node" \
            "$HOME/.local/share/agent-runtime-data/tmp/req013/toolchain"; do
  [ -n "$cand" ] || continue
  if [ -f "$cand/node_modules/loadtest/index.js" ]; then TOOL_SRC="$cand"; break; fi
done
if [ -z "$TOOL_SRC" ]; then
  printf '⚠️ 找不到**已装好的** loadtest（找过: %s / %s / %s）—— 门不装工具 ⇒ 工具相关判据会判红\n' \
    "${QA013_LOADTEST_SRC:-<未设>}" "$WORK_PARENT/toolchain" "$PKG/.tools/node" >&2
else
  printf '工具前置: 使用已装好的 loadtest（%s）\n' "$TOOL_SRC"
fi

# ---------------------------------------------------------------- 跑判据（独立复算器）

step "跑判据（独立复算器 judge.mjs —— 零 import 被验包）"

PKG_TREE_BEFORE="$(node "$WORK/fp.mjs" "$PKG" 2>/dev/null)"
JUDGE_OUT="$WORK/judge.json"
node "$WORK/judge.mjs" "$PKG" "$WORK" "$ACCEPTANCE" "$DECISIONS" "$TOOL_SRC" > "$JUDGE_OUT" 2> "$WORK/judge.err"
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
    GATE) printf 'FAIL %s %s\n' "$AC" "$MSG"; GATE_BROKEN=1;;
  esac
done < "$WORK/results.tsv"

# 复算器少给了判据 ⇒ 补「不可判定」（不可判定 ≠ 通过）
if [ "$SEEN_AC" -lt "$AC_COUNT" ]; then
  for ac in $(grep -oE '^#+[[:space:]]+AC-[0-9]+' "$ACCEPTANCE" 2>/dev/null | sed -E 's/^#+[[:space:]]+//'); do
    if [ ! -f "$RES_DIR/$ac.res" ]; then
      undec "$ac" "复算器没有给出这条判据的结论"
    fi
  done
fi

# ---------------------------------------------------------------- 只读被验包（门自身的硬约束）

PKG_TREE_AFTER="$(node "$WORK/fp.mjs" "$PKG" 2>/dev/null)"
if [ -n "${PKG_TREE_BEFORE:-}" ] && [ "$PKG_TREE_BEFORE" != "$PKG_TREE_AFTER" ]; then
  printf 'FAIL GATE-READONLY —— 门跑前跑后，被验包的全树指纹变了（门写被验包了 ⇒ 门侧缺陷）\n'
  GATE_READONLY_BROKEN=1
else
  printf '被验包只读自检: 全树指纹未变 ✓\n'
fi

# ---------------------------------------------------------------- 变异体套件
#
# 机制（沿用 REQ-012 同款）：
#   - 检测口径 = **新增失败键**（变异运行的失败键 减去 基线失败键，整行精确排除）
#   - 变异体**串行**跑（每路独立 QA013_WORK_ROOT）⇒ 不产生无因果关系的额外失败键
#   - 变异必须**自证生效**：包树指纹（字节级 + 权限位）变化 **且** 变异体写下「已生效」标记
#   - 负控（改 generated_at 的取值，语义不变）必须**未检出**

MUT_TOTAL=0
MUT_DETECTED=0
MUT_ESCAPED=""
MUT_INVALID=""
MUT_NOTE=""
MUT_UNDEC=0
MUT_CONTROL_OK=0
MUT_MISSING_IMPL=0
MUT_CONTROL_FAILED=""

if [ "${QA013_NO_MUT:-0}" = "1" ]; then
  printf '\n变异体套件: 已跳过（QA013_NO_MUT=1）—— 不可判定，不计入通过；检出率结论以完整模式为准\n'
  MUT_NOTE="跳过"
else
  step "变异体套件（正控 + 负控；检测口径 = 新增失败键）"

  # ① 基线失败键（**只取 FAIL 行**）
  BASE_FAILS="$(cat "$RES_DIR"/*.res 2>/dev/null | sed -n 's/^FAIL[[:space:]]\{1,\}\(AC-[0-9]\{3\}\).*/\1/p' | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//')"
  printf '%s\n' $BASE_FAILS | grep -v '^$' | LC_ALL=C sort -u > "$WORK/base_fails.txt"
  if [ -n "$BASE_FAILS" ]; then
    printf '基线本身不绿（失败键: [%s]）—— 变异检测以**新增失败键**为准\n' "$BASE_FAILS"
  else
    printf '基线失败键: []（基线全绿）\n'
  fi
  printf '检测口径: 新增失败键 = 变异运行的失败键 减去 基线失败键（整行精确排除；「消失的失败键」不算检出）\n'

  # ② 跑一次变异包，返回「新增失败键」
  run_mutant_gate() { # $1 = 变异体包目录  $2 = 变异体编号
    local mpkg="$1" mid="$2" mout
    mkdir -p "$WORK/mutwork-$mid" 2>/dev/null || true
    mout="$(QA013_NO_MUT=1 QA013_MUT="$mid" QA013_MUT_MARKER="$WORK/marker-$mid.txt" \
            QA013_WORK_ROOT="$WORK/mutwork-$mid" QA013_SCRIPT_SHA= QA013_LOADTEST_SRC="$TOOL_SRC" \
            bash "$SELF" "$mpkg" 2>&1)"
    printf '%s\n' "$mout" | sed -n 's/^FAIL[[:space:]]\{1,\}\(AC-[0-9]\{3\}\).*/\1/p' | LC_ALL=C sort -u | grep -v '^$' > "$WORK/mut_fails-$mid.txt"
    comm -13 "$WORK/base_fails.txt" "$WORK/mut_fails-$mid.txt" | tr '\n' ' ' | sed 's/ $//'
  }

  # ③ 变异体定义（**逐条对齐**；长度不一致 ⇒ 明确报红退出）
  MUT_IDS=(
    "ac002"
    "ac003"
    "ac004"
    "ac005"
    "ac006"
    "ac007"
    "ac008"
    "ac009"
    "ac010"
    "ac011"
    "ac012"
    "ac013"
    "ac014"
    "ac015"
    "ac016"
    "ac017"
    "ac018"
    "ac019"
    "ac020"
    "ac021"
    "ac022"
    "ac023"
    "ac024"
    "ac025"
    "ac026"
    "ac027"
    "ac028"
    "ac029"
    "ac030"
    "ac031"
    "ac032"
    "ac033"
    "ac034"
    "ac035"
    "ac039"
    "ac040"
    "ac041"
    "ac001"
    "ac036"
    "ac037"
    "ac038"
  )
  MUT_NAMES=(
    "结果产物顶层多一个键"
    "schema_version 写成字符串"
    "results_sha256 被改坏"
    "execution.tool 多一个键"
    "场景顺序被调换"
    "not_provided 场景被补上 thresholds"
    "产物里的 argv 被改（--cores 1 → 2）"
    "observed.total_requests 被写成 0"
    "stub_observed.requests 被写成 0"
    "stub_observed.requests 被写成 999999"
    "executed_url 的 path 被换掉"
    "桩侧时序窗口被改成重叠"
    "桩侧计数被改成累计口径"
    "stub origin 变成 0.0.0.0"
    "阈值判定条目被漏掉一个"
    "阈值 verdict 写成 passed"
    "max_concurrency 被判成 met"
    "默认桩下 p95 被判成 met"
    "吞吐被判成 undetermined"
    "p95 的 observed 填成 p99 的值"
    "error_rate 的 observed 填成随手编的数"
    "汇总计数对不上"
    "产物里出现「生产环境容量达标」"
    "产物里出现 passed"
    "executed_params 被改"
    "cli 模式被标成 api_equivalent"
    "顺手把计划文件改写了"
    "产物已存在时直接覆盖"
    "每次跑多写一个随目录变化的键"
    "用法错误被当成输入非法"
    "非法输入被静默（不点名）"
    "工具缺失时假装成功"
    "证据清单里的 sha256 被改坏"
    "执行结束后桩的端口仍被占用"
    "漏设 statusCallback（错误码塌成 -1）"
    "注入延迟后仍判 undetermined"
    "给 python invocation 编一个 observed"
    "results/ 下多出一个 suite.json"
    "SKILL.md 里出现内部运行时字样"
    "追溯件里漏掉一条决策号"
    "SKILL.md 删掉 B 阶段入口说明"
  )
  MUT_TARGETS=(
    "AC-002"
    "AC-003"
    "AC-004"
    "AC-005"
    "AC-006"
    "AC-007"
    "AC-008"
    "AC-009"
    "AC-010"
    "AC-011"
    "AC-012"
    "AC-013"
    "AC-014"
    "AC-015"
    "AC-016"
    "AC-017"
    "AC-018"
    "AC-019"
    "AC-020"
    "AC-021"
    "AC-022"
    "AC-023"
    "AC-024"
    "AC-025"
    "AC-026"
    "AC-027"
    "AC-028"
    "AC-029"
    "AC-030"
    "AC-031"
    "AC-032"
    "AC-033"
    "AC-034"
    "AC-035"
    "AC-039"
    "AC-040"
    "AC-041"
    "AC-001"
    "AC-036"
    "AC-037"
    "AC-038"
  )
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
  )
  MUT_CODE=(
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
    "const fsx=require('fs');const f=path.join(pkgRoot,'skills','load-profile','SKILL.md');fsx.appendFileSync(f,'\\\\n<!-- internal-rt -->\\\\n');"
    "const fsx=require('fs');const f=path.join(pkgRoot,'feature-meta','load-runner','traceability.md');fsx.writeFileSync(f,fsx.readFileSync(f,'utf8').split('D207').join('D999'));"
    "const fsx=require('fs');const f=path.join(pkgRoot,'skills','load-profile','SKILL.md');fsx.writeFileSync(f,fsx.readFileSync(f,'utf8').split(/\\\\r?\\\\n/).filter((l)=>!l.includes('run-load-test')).join('\\\\n'));"
  )
  MUT_REQUIRED=41

  # ⚠️ **数组长度自检**（门侧自洽）
  MUT_N="${#MUT_IDS[@]}"; MUT_T="${#MUT_TARGETS[@]}"; MUT_M="${#MUT_MODE[@]}"; MUT_C="${#MUT_NAMES[@]}"; MUT_K="${#MUT_CODE[@]}"
  if [ "$MUT_N" -ne "$MUT_T" ] || [ "$MUT_N" -ne "$MUT_M" ] || [ "$MUT_N" -ne "$MUT_C" ] || [ "$MUT_N" -ne "$MUT_K" ]; then
    printf 'FAIL GATE-MUT —— 门侧变异体定义不自洽：IDS=%s NAMES=%s TARGETS=%s MODE=%s CODE=%s\n' "$MUT_N" "$MUT_C" "$MUT_T" "$MUT_M" "$MUT_K"
    MUT_UNDEC=1
    MUT_NOTE="不可判定：门侧变异体数组长度不一致（门侧缺陷，不是被验实现的问题）"
    MUT_INVALID="[门侧缺陷: 变异体数组长度不一致]"
  else

  for i in "${!MUT_IDS[@]}"; do
    ID="${MUT_IDS[$i]}"
    NAME="${MUT_NAMES[$i]}"
    TARGET="${MUT_TARGETS[$i]}"
    MODE="${MUT_MODE[$i]}"
    CODE="${MUT_CODE[$i]}"
    MUTPKG="$WORK/mut-$i"
    mkdir -p "$MUTPKG"
    cp -r "$PKG"/. "$MUTPKG"/ 2>/dev/null
    STATUS="有效"

    ENTRY_REL="skills/load-profile/scripts/run-load-test.mjs"
    if [ ! -f "$MUTPKG/$ENTRY_REL" ]; then
      STATUS="**实现缺失**：入口脚本不存在 —— 变异体无法注入；这是实现未交付，不是门侧问题"
      MUT_MISSING_IMPL=1
    fi

    FP_BEFORE="$(node "$WORK/fp.mjs" "$MUTPKG" 2>/dev/null)"
    if [ "$STATUS" = "有效" ] && [ "$MODE" = "file" ]; then
      node -e "
        const fsx = require('fs');
        const path = require('path');
        const pkgRoot = process.argv[1];
        try { $CODE } catch (e) { console.error('[mutant] 文件篡改失败: ' + e.message); process.exit(3); }
      " "$MUTPKG" >/dev/null 2>&1 || STATUS="静态文件篡改失败"
    fi
    if [ "$STATUS" = "有效" ] && [ "$MODE" = "shim" ]; then
      ENTRY="$MUTPKG/$ENTRY_REL"
      MODEBITS="$(stat -c '%a' "$ENTRY" 2>/dev/null || echo 755)"
      mv "$ENTRY" "$MUTPKG/skills/load-profile/scripts/run-load-test.real.mjs" 2>/dev/null || { STATUS="包装层注入失败"; }
      if [ "$STATUS" = "有效" ]; then
        cp "$WORK/mut-shim.mjs" "$ENTRY"
        chmod "$MODEBITS" "$ENTRY" 2>/dev/null || true
        node --check "$ENTRY" >/dev/null 2>&1 || STATUS="变异后 node --check 不通过"
      fi
    fi
    # 自证（第一层）：**包树指纹**（字节级 + 权限位）必须与注入前不同 ⇒ 注入真的落盘了
    FP_AFTER="$(node "$WORK/fp.mjs" "$MUTPKG" 2>/dev/null)"
    if [ "$STATUS" = "有效" ]; then
      if [ -z "${FP_BEFORE:-}" ] || [ -z "${FP_AFTER:-}" ] || [ "$FP_BEFORE" = "$FP_AFTER" ]; then
        STATUS="注入前后包树指纹没变（注入未生效）"
      fi
    fi

    if [ "$STATUS" != "有效" ]; then
      MUT_INVALID="$MUT_INVALID [$ID/$NAME: $STATUS]"
      printf '变异体 %s（%s）: 无效变异（%s）—— 不计入分母\n' "$ID" "$NAME" "$STATUS"
      continue
    fi

    NEW_FAILS="$(run_mutant_gate "$MUTPKG" "$ID")"

    # 自证（第二层）：变异体必须自己写下「已生效」标记 ⇒ 篡改真的作用到了产物/输入/退出码
    if [ "$MODE" = "shim" ]; then
      if ! grep -q "^${ID}:applied" "$WORK/marker-$ID.txt" 2>/dev/null; then
        STATUS="变异体没有写下「已生效」标记 ⇒ 篡改没有真正作用（该变异对这份实现无效）"
        MUT_INVALID="$MUT_INVALID [$ID/$NAME: $STATUS]"
        printf '变异体 %s（%s）: 无效变异（%s）—— 不计入分母\n' "$ID" "$NAME" "$STATUS"
        continue
      fi
    fi

    MUT_TOTAL=$((MUT_TOTAL+1))
    if printf '%s' " $NEW_FAILS " | grep -q " $TARGET "; then
      MUT_DETECTED=$((MUT_DETECTED+1))
      printf '变异体 %s（%s）: 已检出（目标 %s 出现在新增失败键集合里）\n' "$ID" "$NAME" "$TARGET"
    else
      MUT_ESCAPED="$MUT_ESCAPED [$ID → 目标 $TARGET 未出现在新增失败键集合（新增=[$NEW_FAILS]）]"
      printf '变异体 %s（%s）: 逃逸（目标 %s 未出现在新增失败键集合里；新增=[%s]）\n' "$ID" "$NAME" "$TARGET" "$NEW_FAILS"
    fi
  done
  fi

  # ④ 负控：改 `generated_at` 的取值（**语义不变**）⇒ 期望「未检出」
  CTRL_NAME="负控：只改结果产物的 generated_at 取值（语义不变）"
  CTRLPKG="$WORK/mut-control"
  mkdir -p "$CTRLPKG"
  cp -r "$PKG"/. "$CTRLPKG"/ 2>/dev/null
  CTRL_STATUS="有效"
  CTRL_ENTRY="$CTRLPKG/skills/load-profile/scripts/run-load-test.mjs"
  if [ ! -f "$CTRL_ENTRY" ]; then
    CTRL_STATUS="**实现缺失**：入口脚本不存在 —— 这是实现未交付，不是门侧问题"
    MUT_MISSING_IMPL=1
  else
    MODEBITS="$(stat -c '%a' "$CTRL_ENTRY" 2>/dev/null || echo 755)"
    mv "$CTRL_ENTRY" "$CTRLPKG/skills/load-profile/scripts/run-load-test.real.mjs" 2>/dev/null || CTRL_STATUS="包装层注入失败"
    if [ "$CTRL_STATUS" = "有效" ]; then
      cp "$WORK/mut-shim.mjs" "$CTRL_ENTRY"
      chmod "$MODEBITS" "$CTRL_ENTRY" 2>/dev/null || true
      node --check "$CTRL_ENTRY" >/dev/null 2>&1 || CTRL_STATUS="变异后 node --check 不通过"
    fi
  fi
  if [ "$CTRL_STATUS" = "有效" ]; then
    CTRL_NEW="$(run_mutant_gate "$CTRLPKG" "control")"
    if ! grep -q "^control:applied" "$WORK/marker-control.txt" 2>/dev/null; then
      CTRL_STATUS="负控没有写下「已生效」标记 ⇒ 负控无效（探测器的灵敏度不可判定）"
    fi
  fi
  if [ "$CTRL_STATUS" != "有效" ]; then
    MUT_INVALID="$MUT_INVALID [$CTRL_NAME: $CTRL_STATUS]"
    printf '负控 %s: 无效变异（%s）—— 探测器的灵敏度不可判定\n' "$CTRL_NAME" "$CTRL_STATUS"
  else
    if [ -z "$CTRL_NEW" ]; then
      MUT_CONTROL_OK=1
      printf '负控 %s: 未检出（新增失败键为空）—— 符合预期，探测器不是恒真\n' "$CTRL_NAME"
    else
      MUT_CONTROL_FAILED="[$CTRL_NAME → 本不该让任何判据变红，却出现新增失败键 [$CTRL_NEW] —— 探测器疑似恒真]"
      printf '负控 %s: 被报成「已检出」（新增失败键=[%s]）—— 门侧缺陷：探测器恒真\n' "$CTRL_NAME" "$CTRL_NEW"
    fi
  fi

  # ⑤ 结论（责任方要指对）
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
  printf '\n⚠️ 判据条数不符：本门评了 %s 条，acceptance.md 的 `AC-` 实际条数是 %s 条\n' "$EVAL_COUNT" "$AC_COUNT"
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
printf '判据条数（动态取 acceptance.md 的 `AC-` 标题行）: %s\n' "$AC_COUNT"
printf '决策号（动态取 decisions.md 的 `D` 标题行）: %s 条 [%s]\n' "$DECISION_COUNT" "$DECISION_IDS"
if [ "$MUT_NOTE" = "跳过" ]; then
  printf '变异体套件: 已跳过（QA013_NO_MUT=1）—— 不可判定，检出率结论以完整模式为准\n'
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
# 原样回放 stderr（门不该吞掉自己的输出）—— 写到 fd 3（原始 stderr），不是回写日志文件
cat "$STDERR_LOG" >&3
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
if [ "$GATE_BROKEN" -eq 1 ]; then
  printf 'FAIL GATE-D202 —— 门级探针发现契约违反（见上）—— 判定不可信\n'
  exit 1
fi
if [ "$FAIL" -eq 0 ] && [ "$UNDEC" -eq 0 ] && [ -z "$MUT_ESCAPED" ] && [ -z "$MUT_CONTROL_FAILED" ] \
   && { [ "${QA013_NO_MUT:-0}" = "1" ] || { [ "$MUT_UNDEC" -eq 0 ] \
        && [ "$MUT_TOTAL" -ge "$MUT_REQUIRED" ] && [ "$MUT_DETECTED" -eq "$MUT_TOTAL" ] \
        && [ "$MUT_CONTROL_OK" -eq 1 ]; }; }; then
  exit 0
fi
exit 1
