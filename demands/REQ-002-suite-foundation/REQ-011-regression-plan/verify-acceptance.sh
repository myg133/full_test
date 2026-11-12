#!/usr/bin/env bash
# REQ-011 验收脚本 —— R2 回归轮 `regression-plan` skill + 套件层组合门
#
# 判据集：AC-001~AC-028（条数从 acceptance.md 的 `### AC-` 实际条数动态取，不写死）
#
# 用法: verify-acceptance.sh <package-dir>
#   <package-dir> 指向**被验包根目录**（含 skills/ 与 bin/，以及 feature-meta/、README.md）
#
# 退出码: 0 = 全部通过; 1 = 有 AC 未通过; 2 = 用法错误
#
# 环境变量:
#   REQ011_NO_MUT=1   跳过 AC-025 的变异体套件（快跑 / 嵌套运行用）
#   QA011_SCRIPT_SHA  期望的**本脚本自身** sha256；不匹配即判红并中止
#
# 说明:
#   - 只读被验包；一切变异都在**副本**上做，绝不在原地改被验对象（D25 ⑪）。
#   - 夹具（用例集 / changelog / 最小项目）一律造在临时目录里。
#   - 判据正文与本脚本的理解有出入时，以 acceptance.md 的判据正文为准；
#     实现依赖与判据之间的分歧写在本脚本注释里（见 AC-010 / AC-026 段）。

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
# 工作区根（用于解析 demand_dir / acceptance.md / decisions.md）
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

if [ -n "${QA011_SCRIPT_SHA:-}" ]; then
  SELF_SHA="$(sha256sum "$SELF" 2>/dev/null | cut -d' ' -f1)"
  if [ "$SELF_SHA" != "$QA011_SCRIPT_SHA" ]; then
    echo "FAIL  门禁前置：验收脚本自身 sha256 不符（实际 $SELF_SHA，期望 $QA011_SCRIPT_SHA）" >&2
    echo "结论: 0 PASS / 1 FAIL" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------- 工作目录

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qa-011-XXXXXX")"
cleanup() {
  # ⚠️ 本机 rm 是 shim（可恢复删除）：清理失败**不得**改变判定，也不断言回收站为空。
  rm -rf "$WORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT

RP="$PKG/skills/regression-plan"
BINDIR="$PKG/bin"
INSTALLER="$BINDIR/test-agent-skills.mjs"
TCD="$PKG/skills/test-case-design"
DIM="$TCD/references/dimensions.json"
MTH="$TCD/references/methods.json"
FEATURE_META="$PKG/feature-meta"
README="$PKG/README.md"

PASS=0
FAIL=0
UNDEC=0
FAILED_LIST=()
UNDEC_LIST=()

ok()  { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED_LIST+=("$1"); printf 'FAIL  %s  %s\n' "$1" "${2:-}"; }
# 不可判定 —— 既不判红也不判绿（AC-025 的「有效变异不足」用）
# 但**不计入通过**：结论行与退出码都会体现「不可判定不等于通过」。
undec() { UNDEC=$((UNDEC+1)); UNDEC_LIST+=("$1"); printf 'UNDEC %s  %s\n' "$1" "${2:-}"; }
step(){ printf '\n— %s\n' "$1"; }

# 抽出「失败的 AC 键集合」—— 变异体判定完全建立在它上面
failkeys() {
  printf '%s\n' "$1" | sed 's/\x1b\[[0-9;]*m//g' | grep -E '^[[:space:]]*FAIL' | grep -oE 'AC-[0-9]+' | sort -u
}

# 抽出「失败行」的**归一化集合**（变异检测用；D45 / G-8）
#   - 归一化掉被验包路径与临时目录路径（否则两次跑必然不同 → 假检出）
#   - 保留**整行**（含判红原因）→ 基线本来就红的判据，变异把它改得更红时也能看出来
failsig() {
  printf '%s\n' "$1" \
    | sed -e "s#$2#<PKG>#g" -e "s#$PKG#<PKG>#g" -e 's/qa-011-[A-Za-z0-9]*/<WORK>/g' \
    | sed -e 's/^[[:space:]]*//' \
    | grep -E '^FAIL' | sort
}

# ---------------------------------------------------------------- 夹具

FX="$WORK/fx"
mkdir -p "$FX"
cat > "$FX/cases.json" <<'FIXCASES'
{
  "schema_version": 2,
  "meta": { "source": "qa-011", "generated_at": "2026-11-13T00:00:00+08:00", "case_count": 7 },
  "requirements": [
    { "id": "R-1", "title": "优惠券抵扣规则", "source_ref": "需求 3.1", "testable": true },
    { "id": "R-2", "title": "订单退款流转", "source_ref": "需求 3.2", "testable": true },
    { "id": "R-3", "title": "兑换码与留痕", "source_ref": "需求 3.3", "testable": true }
  ],
  "open_questions": [],
  "coverage_matrix": [
    { "requirement": "R-1", "methods_applied": ["M1.1"], "skipped": [], "dimensions": ["functional"] },
    { "requirement": "R-2", "methods_applied": ["M1.2"], "skipped": [], "dimensions": ["boundary"] },
    { "requirement": "R-3", "methods_applied": ["M1.3", "M1.6", "M2.1", "M2.3"], "skipped": [], "dimensions": ["data", "functional", "observability", "security"] }
  ],
  "cases": [
    { "id": "TC-001", "title": "抵扣主流程", "requirement_refs": ["R-1"], "dimension": "functional", "priority": "P0", "method": ["M1.1"], "status": "active", "steps": [ { "action": "下单", "expected": { "path": "$.code", "op": "equals", "expected": "E001" } } ] },
    { "id": "TC-002", "title": "令牌校验", "requirement_refs": ["R-3"], "dimension": "security", "priority": "P0", "method": ["M2.1"], "status": "active", "steps": [ { "action": "校验", "expected": { "path": "$.code", "op": "equals", "expected": "E002" } } ] },
    { "id": "TC-003", "title": "日志留痕", "requirement_refs": ["R-3"], "dimension": "observability", "priority": "P1", "method": ["M2.3"], "status": "active", "steps": [ { "action": "记录", "expected": { "path": "$.code", "op": "equals", "expected": "E003" } } ] },
    { "id": "TC-004", "title": "兑换码写入", "requirement_refs": ["R-3"], "dimension": "data", "priority": "P1", "method": ["M1.3"], "status": "active", "steps": [ { "action": "写入", "expected": { "path": "$.code", "op": "equals", "expected": "E004" } } ] },
    { "id": "TC-005", "title": "退款边界", "requirement_refs": ["R-2"], "dimension": "boundary", "priority": "P1", "method": ["M1.2"], "status": "active", "steps": [ { "action": "退款", "expected": { "path": "$.code", "op": "equals", "expected": "E005" } } ] },
    { "id": "TC-006", "title": "旧版抵扣", "requirement_refs": ["R-1"], "dimension": "functional", "priority": "P2", "method": ["M1.1"], "status": "deprecated", "steps": [ { "action": "抵扣", "expected": { "path": "$.code", "op": "equals", "expected": "E006" } } ] },
    { "id": "TC-007", "title": "退款查询", "requirement_refs": ["R-3"], "dimension": "functional", "priority": "P2", "method": ["M1.6"], "status": "active", "steps": [ { "action": "查询", "expected": { "path": "$.code", "op": "equals", "expected": "E007" } } ] }
  ]
}
FIXCASES
# changelog：6 条变更条目，覆盖四条命中路径 + 方法不适用 + 判不了
#   C-1 需求条目命中（@R-1）
#   C-2 维度显式命中（@dim:security）
#   C-3 维度信号命中（正文含 observability 的 applies_when 信号词）
#   C-4 用例显式命中（@TC-004）
#   C-5 需求条目命中（@R-2）+ 方法 not_applies_when 命中（逐字含 M1.2 的短语）
#   C-6 无引用无信号 → 判不了
#
# ⚠️ 夹具为什么是 3 个需求条目 / 7 条用例（不是 §0  sketches 的 2/6）：
#   AC-006（命中需求条目 → 在 selected）、AC-007（命中维度 → 在 selected）、
#   AC-008（显式引用的用例 → 在 selected）、AC-017（方法不适用 → 在 needs_review）、
#   AC-016（非 active → 不在 selected）**联合起来**要求夹具里至少有 7 个角色各占一条用例：
#   ① 命中需求且 active 不被方法挡；② 命中显式维度；③ 命中信号维度；④ 被 @TC- 引用；
#   ⑤ 与任何变更都无关联；⑥ 命中影响面但方法被挡（必须能进 needs_review）；
#   ⑦ 命中影响面、生命周期非 active、方法不被挡（否则"忽略 status"这个变异**逃逸**）。
#   而角色⑤必须有**一个没有被任何变更条目引用的需求条目**（schema v2 不允许空的
#   requirement_refs）→ 因此需要第 3 个需求条目 R-3。
cat > "$FX/CHANGELOG.md" <<'FIXCHANGELOG'
# 变更日志 2.3

## 修正优惠券抵扣规则

本次修订涉及 @R-1 条目。

## 收紧校验规则

本次收紧覆盖 @dim:security 方向。

## 补充可观测信息

本次在关键位置加上 日志 记录。

## 收口兑换码行为

本次只针对 @TC-004 用例做收口。

## 调整退款边界

本次修订涉及 @R-2 条目；本次场景属于 无明确边界的业务流程，相关方法不适用。

## 调整发布安排

本次按团队讨论结果做一些优化。
FIXCHANGELOG
cat > "$FX/bad-R.md" <<'FIXBADR'
# 变更日志 2.3

## 修正优惠券抵扣规则

本次修订涉及 @R-99 条目。
FIXBADR
cat > "$FX/bad-TC.md" <<'FIXBADTC'
# 变更日志 2.3

## 收口兑换码行为

本次只针对 @TC-999 用例做收口。
FIXBADTC
# D44：坏维度引用（@dim:<不存在的维度>）也必须报错 —— 维度库是唯一来源，
# 静默忽略等于悄悄漏测（D36 ③：坏引用是**输入错误**，该报错，不是"判不了"）。
cat > "$FX/bad-DIM.md" <<'FIXBADDIM'
# 变更日志 2.3

## 收口某未知维度

本次修订涉及 @dim:not-a-real-dimension 维度。
FIXBADDIM

# ---------------------------------------------------------------- 判据自带的独立实现（不复用被验代码）

cat > "$WORK/recompute.mjs" <<'FIXRECOMPUTE'
// recompute.mjs —— 判据自带的 F3 重算实现（**不复用被验代码**）
// 用法: node recompute.mjs <plan> <cases> <changelog> <dimensions> <methods>
// 输出: JSON（见下）
import fs from 'node:fs';

const [planFile, casesFile, changelogFile, dimFile, methodFile] = process.argv.slice(2);
const plan = JSON.parse(fs.readFileSync(planFile, 'utf8'));
const casesDoc = JSON.parse(fs.readFileSync(casesFile, 'utf8'));
const dimsDoc = JSON.parse(fs.readFileSync(dimFile, 'utf8'));
const methodsDoc = JSON.parse(fs.readFileSync(methodFile, 'utf8'));
const changelog = fs.readFileSync(changelogFile, 'utf8');

const unique = (list) => [...new Set(list)];

// --- 独立解析 changelog：按二级及以下标题切分 ---
const lines = changelog.split(/\r?\n/);
const entries = [];
let cur = null;
for (const line of lines) {
  const heading = /^(#{2,6})\s+(.*)$/.exec(line);
  if (heading) {
    if (cur) entries.push(cur);
    cur = { title: heading[2], text: line };
    continue;
  }
  if (cur) cur.text += `\n${line}`;
}
if (cur) entries.push(cur);
entries.forEach((entry, index) => { entry.id = `C-${index + 1}`; });

// --- 标记抽取 ---
for (const entry of entries) {
  entry.requirement_refs = unique([...entry.text.matchAll(/@R-(\d+)/g)].map((m) => `R-${m[1]}`));
  entry.case_refs = unique([...entry.text.matchAll(/@TC-(\d{3})/g)].map((m) => `TC-${m[1]}`));
  entry.dim_refs = unique([...entry.text.matchAll(/@dim:([A-Za-z0-9_-]+)/g)].map((m) => m[1]));
}

// --- 维度 / 方法命中（显式 + 信号）---
const dims = Array.isArray(dimsDoc.dimensions) ? dimsDoc.dimensions : [];
const methods = Array.isArray(methodsDoc.methods) ? methodsDoc.methods : [];
const explicitDims = [];
const signalDims = [];
const signalWord = {};
const methodHits = {};
const entrySignalDims = {};
for (const entry of entries) {
  for (const id of entry.dim_refs) if (!explicitDims.includes(id)) explicitDims.push(id);
  const own = [];
  for (const dim of dims) {
    for (const word of Array.isArray(dim.applies_when) ? dim.applies_when : []) {
      if (!entry.text.includes(word)) continue;
      if (!signalDims.includes(dim.id)) signalDims.push(dim.id);
      if (!signalWord[dim.id]) signalWord[dim.id] = word;
      if (!own.includes(dim.id)) own.push(dim.id);
      break;
    }
  }
  entrySignalDims[entry.id] = own;
  const hits = [];
  for (const method of methods) {
    for (const phrase of Array.isArray(method.not_applies_when) ? method.not_applies_when : []) {
      if (!phrase || !entry.text.includes(phrase)) continue;
      hits.push(method.id);
      break;
    }
  }
  methodHits[entry.id] = hits;
}

// --- 影响面（独立口径：只用 changelog + 输入 + 库）---
const cases = Array.isArray(casesDoc.cases) ? casesDoc.cases : [];
const affectedFromChangelog = [];
const notAffected = [];
for (const caseObj of cases) {
  const reqs = Array.isArray(caseObj.requirement_refs) ? caseObj.requirement_refs : [];
  const dim = typeof caseObj.dimension === 'string' ? caseObj.dimension : '';
  const hit = entries.some((entry) =>
    entry.requirement_refs.some((ref) => reqs.includes(ref)) ||
    entry.case_refs.includes(caseObj.id) ||
    entry.dim_refs.includes(dim) ||
    signalDims.includes(dim));
  if (hit) affectedFromChangelog.push(caseObj.id);
  else notAffected.push(caseObj.id);
}

// --- 计划自记 basis 的重算（AC-010 口径：以 P.changes 记录的 basis 为数据）---
const planChanges = Array.isArray(plan.changes) ? plan.changes : [];
const basisSelected = [];
const basisReview = [];
const mismatch = planChanges.length !== entries.length;
for (const caseObj of cases) {
  const reqs = Array.isArray(caseObj.requirement_refs) ? caseObj.requirement_refs : [];
  const dim = typeof caseObj.dimension === 'string' ? caseObj.dimension : '';
  const methodsOfCase = Array.isArray(caseObj.method) ? caseObj.method : [];
  let affected = false;
  for (const change of planChanges) {
    const hitReq = (Array.isArray(change.requirement_refs) ? change.requirement_refs : []).some((r) => reqs.includes(r));
    const hitCase = (Array.isArray(change.case_refs) ? change.case_refs : []).includes(caseObj.id);
    const hitDim = (Array.isArray(change.dimensions) ? change.dimensions : []).includes(dim);
    if (hitReq || hitCase || hitDim) affected = true;
  }
  if (!affected) continue;
  let blocked = false;
  for (let index = 0; index < entries.length; index += 1) {
    const hits = methodHits[entries[index].id] || [];
    if (hits.some((id) => methodsOfCase.includes(id))) blocked = true;
  }
  // 口径与判据一致：selected 要求 status == active；needs_review 是"方法适用性判不了"，
  // 不论生命周期（AC-016 只禁止非 active 进 selected）。
  if (blocked) basisReview.push(caseObj.id);
  else if (caseObj.status === 'active') basisSelected.push(caseObj.id);
}

// --- 判不了条目（D45 口径：推不出任何**用例级**影响面）---
//   影响用例(C) = 需求路径 ∨ 用例路径 ∨ 维度路径（显式 @dim: ∪ 信号词命中的维度）
//   全影响面     = 所有变更条目的影响用例之并
//   挡住的用例(C) = 全影响面里、用了被 C 的正文命中的 not_applies_when 方法的用例
//   C 判不了 ⟺ 影响用例(C) 为空 且 挡住的用例(C) 为空
//   （推论：只命中方法短语但对应不到任何用例、合法引用但无任何用例覆盖 → 都判不了）
const affectedByChange = {};
for (const entry of entries) {
  const dims = new Set([...entry.dim_refs, ...(entrySignalDims[entry.id] || [])]);
  affectedByChange[entry.id] = cases
    .filter((caseObj) => {
      const reqs = Array.isArray(caseObj.requirement_refs) ? caseObj.requirement_refs : [];
      const dim = typeof caseObj.dimension === 'string' ? caseObj.dimension : '';
      return entry.requirement_refs.some((ref) => reqs.includes(ref))
        || entry.case_refs.includes(caseObj.id)
        || dims.has(dim);
    })
    .map((caseObj) => caseObj.id);
}
const universe = [...new Set(Object.values(affectedByChange).flat())];
const blockedByChange = {};
for (const entry of entries) {
  const hits = methodHits[entry.id] || [];
  blockedByChange[entry.id] = cases
    .filter((caseObj) => universe.includes(caseObj.id)
      && (Array.isArray(caseObj.method) ? caseObj.method : []).some((m) => hits.includes(m)))
    .map((caseObj) => caseObj.id);
}
const undecidableFromChangelog = entries
  .filter((entry) =>
    (affectedByChange[entry.id] || []).length === 0 &&
    (blockedByChange[entry.id] || []).length === 0)
  .map((entry) => entry.id);

const out = {
  changes: entries.map((e) => ({
    id: e.id,
    text: e.text,
    requirement_refs: e.requirement_refs,
    case_refs: e.case_refs,
    dim_refs: e.dim_refs,
    method_hits: methodHits[e.id] || [],
  })),
  explicit_dims: explicitDims,
  signal_dims: signalDims,
  signal_word: signalWord,
  method_hits: methodHits,
  affected: affectedFromChangelog,
  not_affected: notAffected,
  undecidable_from_changelog: undecidableFromChangelog,
  affected_by_change: affectedByChange,
  blocked_by_change: blockedByChange,
  impact_universe: universe,
  basis_selected: basisSelected,
  basis_needs_review: basisReview,
  plan_change_count: planChanges.length,
  changelog_change_count: entries.length,
  basis_mismatch: mismatch,
  method_lib: methods.map((m) => ({ id: m.id, not_applies_when: Array.isArray(m.not_applies_when) ? m.not_applies_when : [] })),
  dim_lib: dims.map((d) => ({ id: d.id, applies_when: Array.isArray(d.applies_when) ? d.applies_when : [] })),
  case_ids: cases.map((c) => c.id),
  requirement_ids: (Array.isArray(casesDoc.requirements) ? casesDoc.requirements : []).map((r) => r.id),
  non_active_ids: cases.filter((c) => c.status !== 'active').map((c) => c.id),
  cases: cases.map((c) => ({
    id: c.id,
    status: c.status,
    dimension: c.dimension,
    requirement_refs: Array.isArray(c.requirement_refs) ? c.requirement_refs : [],
    method: Array.isArray(c.method) ? c.method : [],
  })),
};
process.stdout.write(`${JSON.stringify(out)}\n`);
FIXRECOMPUTE

cat > "$WORK/reason.mjs" <<'FIXREASON'
// reason.mjs —— AC-011 的独立核对：每条选样的来源标记必须能对上事实
// 用法: node reason.mjs <plan> <recompute.json>
import fs from 'node:fs';

const [planFile, recomputeFile] = process.argv.slice(2);
const plan = JSON.parse(fs.readFileSync(planFile, 'utf8'));
const rc = JSON.parse(fs.readFileSync(recomputeFile, 'utf8'));

const problems = [];
const planChanges = Array.isArray(plan.changes) ? plan.changes : [];
const changeById = new Map(planChanges.map((c) => [String(c.id), c]));
const changeText = new Map(rc.changes.map((c) => [String(c.id), String(c.text || '')]));
const caseById = new Map(rc.cases.map((c) => [String(c.id), c]));
const dimIds = new Set(rc.dim_lib.map((d) => String(d.id)));
const methodById = new Map(rc.method_lib.map((m) => [String(m.id), m]));

const items = [
  ...(Array.isArray(plan.selected) ? plan.selected : []).map((x) => ({ ...x, bucket: 'selected' })),
  ...(Array.isArray(plan.needs_review) ? plan.needs_review : []).map((x) => ({ ...x, bucket: 'needs_review' })),
];

for (const item of items) {
  const caseId = String(item.case_id);
  const label = `${item.bucket}:${caseId}`;
  const reason = typeof item.reason === 'string' ? item.reason.trim() : '';
  if (reason === '') {
    problems.push(`${label} 的 reason 为空`);
    continue;
  }
  const refs = Array.isArray(item.change_refs) ? item.change_refs.map(String) : [];
  if (refs.length === 0) {
    problems.push(`${label} 的 change_refs 为空`);
    continue;
  }
  for (const ref of refs) {
    if (!changeById.has(ref)) problems.push(`${label} 的 change_refs 指向不存在的变更条目 ${ref}`);
  }
  // D45（P-4）：来源标记必须指向**本用例自己的命中路径** ——
  // 实体存在还不够，它得是"这条用例为什么被选中"的那条路径。
  const caseObj = caseById.get(caseId);
  if (!caseObj) {
    problems.push(`${label} 的用例 ${caseId} 不在输入用例集里`);
    continue;
  }
  const caseReqs = Array.isArray(caseObj.requirement_refs) ? caseObj.requirement_refs : [];
  const caseDim = typeof caseObj.dimension === 'string' ? caseObj.dimension : '';
  const caseMethods = Array.isArray(caseObj.method) ? caseObj.method : [];
  // 来源标记逐个核对
  let markerCount = 0;
  const reqTokens = uniqueTokens(reason, /\bR-\d+\b/g);
  for (const token of reqTokens) {
    markerCount += 1;
    if (!rc.requirement_ids.includes(token)) {
      problems.push(`${label} 的 reason 提到需求条目 ${token}，但输入用例集里没有这个需求条目`);
      continue;
    }
    if (!caseReqs.includes(token)) {
      problems.push(`${label} 的 reason 提到需求条目 ${token}，但这条用例本身并不引用它（来源标记必须指向本用例自己的命中路径）`);
      continue;
    }
    if (!refs.some((ref) => {
      const change = changeById.get(ref);
      const text = changeText.get(ref) || '';
      return (Array.isArray(change?.requirement_refs) && change.requirement_refs.includes(token)) || text.includes(`@${token}`);
    })) {
      problems.push(`${label} 的 reason 提到需求条目 ${token}，但它不对应 change_refs 里的任何变更条目`);
    }
  }
  const caseTokens = uniqueTokens(reason, /\bTC-\d{3}\b/g);
  for (const token of caseTokens) {
    markerCount += 1;
    if (!rc.case_ids.includes(token)) {
      problems.push(`${label} 的 reason 提到用例 ${token}，但输入用例集里没有这个用例`);
      continue;
    }
    if (token !== caseId) {
      problems.push(`${label} 的 reason 提到用例 ${token}，但这不是本用例（来源标记必须指向本用例自己的命中路径）`);
      continue;
    }
    if (!refs.some((ref) => {
      const change = changeById.get(ref);
      const text = changeText.get(ref) || '';
      return (Array.isArray(change?.case_refs) && change.case_refs.includes(token)) || text.includes(`@${token}`);
    })) {
      problems.push(`${label} 的 reason 提到用例 ${token}，但它不对应 change_refs 里的任何变更条目`);
    }
  }
  for (const token of uniqueTokens(reason, /\bM\d+\.\d+\b/g)) {
    markerCount += 1;
    const method = methodById.get(token);
    if (!method) {
      problems.push(`${label} 的 reason 提到方法 ${token}，但方法库里没有这个方法`);
      continue;
    }
    if (!caseMethods.includes(token)) {
      problems.push(`${label} 的 reason 提到方法 ${token}，但这条用例没有用这个方法（来源标记必须指向本用例自己的命中路径）`);
      continue;
    }
    const hit = refs.some((ref) => {
      const text = changeText.get(ref) || '';
      return method.not_applies_when.some((phrase) => phrase && text.includes(phrase));
    });
    if (!hit) problems.push(`${label} 的 reason 提到方法 ${token}，但 change_refs 里没有变更条目命中它的 not_applies_when`);
  }
  for (const dim of rc.dim_lib) {
    const dimId = String(dim.id);
    if (!new RegExp(`\\b${dimId.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`).test(reason)) continue;
    markerCount += 1;
    if (!dimIds.has(dimId)) {
      problems.push(`${label} 的 reason 提到维度 ${dimId}，但维度库里没有这个维度`);
      continue;
    }
    if (caseDim !== dimId) {
      problems.push(`${label} 的 reason 提到维度 ${dimId}，但这条用例的维度是 ${caseDim}（来源标记必须指向本用例自己的命中路径）`);
      continue;
    }
    const hit = refs.some((ref) => {
      const change = changeById.get(ref);
      const text = changeText.get(ref) || '';
      return (Array.isArray(change?.dimensions) && change.dimensions.includes(dimId)) ||
        dim.applies_when.some((word) => word && text.includes(word));
    });
    if (!hit) problems.push(`${label} 的 reason 提到维度 ${dimId}，但它不对应 change_refs 里的任何变更条目`);
  }
  const caseDimEntry = rc.dim_lib.find((d) => String(d.id) === caseDim);
  const caseDimSignals = Array.isArray(caseDimEntry?.applies_when) ? caseDimEntry.applies_when : [];
  for (const dim of rc.dim_lib) {
    for (const word of dim.applies_when) {
      if (!word || !reason.includes(word)) continue;
      markerCount += 1;
      if (!caseDimSignals.includes(word)) {
        problems.push(`${label} 的 reason 提到信号词「${word}」，但它不是本用例所属维度（${caseDim}）的信号词（来源标记必须指向本用例自己的命中路径）`);
        continue;
      }
      const hit = refs.some((ref) => {
        const text = changeText.get(ref) || '';
        return text.includes(word);
      });
      if (!hit) problems.push(`${label} 的 reason 提到信号词「${word}」，但 change_refs 里的变更条目正文里没有这个词`);
    }
  }
  if (markerCount === 0) {
    problems.push(`${label} 的 reason 里没有任何可核对的来源标记（需求条目 id / 用例 id / 维度名 / 信号词 / 方法编号）`);
  }
}

function uniqueTokens(text, pattern) {
  const re = new RegExp(pattern.source, pattern.flags.includes('g') ? pattern.flags : `${pattern.flags}g`);
  return [...new Set(text.match(re) || [])];
}

process.stdout.write(`${JSON.stringify({ problems })}\n`);
FIXREASON

cat > "$WORK/scan.mjs" <<'FIXSCAN'
// scan.mjs —— AC-027：零第三方依赖 + 不联网
// 用法: node scan.mjs <dir> [<dir> ...]
//
// D45（G-3）：扫描必须覆盖**动态 import 表达式** ——
//   import('x') / import("x") / import(`x`)（含 await 前缀）。
//   此前只匹配静态 from '...' 与 require('...') → 动态 import 整个漏掉。
import fs from 'node:fs';
import path from 'node:path';

const roots = process.argv.slice(2);
const files = [];
const walk = (dir) => {
  let entries = [];
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full);
    else if (/\.(mjs|js|cjs)$/.test(entry.name)) files.push(full);
  }
};
for (const root of roots) {
  // 以 '[' 开头 → 直接给文件清单（JSON 数组），避免路径带空格时被拆开
  if (root.startsWith('[')) {
    try {
      for (const item of JSON.parse(root)) if (typeof item === 'string') files.push(item);
    } catch { /* 忽略 */ }
    continue;
  }
  walk(root);
}

// 内置模块 / 本地路径 —— 这些不算第三方依赖
const isBuiltinOrLocal = (spec) => {
  if (typeof spec !== 'string') return false;
  const s = spec.trim();
  if (s === '') return false;
  if (s.startsWith('node:')) return true;                                  // node: 内置
  if (s.startsWith('./') || s.startsWith('../') || s.startsWith('/')) return true;  // 本地路径
  if (s.includes('${')) {
    // 模板串带插值：只有前缀是本地路径才算本地，否则**无法静态判定归属** → 判红
    const prefix = s.split('${')[0];
    return prefix.startsWith('./') || prefix.startsWith('../') || prefix.startsWith('/');
  }
  return false;
};

const thirdParty = [];
const network = [];
for (const file of files) {
  const raw = fs.readFileSync(file, 'utf8');
  const src = raw.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
  src.split(/\r?\n/).forEach((line, index) => {
    const specs = [];
    const staticImport = line.match(/from\s+['"]([^'"]+)['"]/);
    if (staticImport) specs.push(staticImport[1]);
    const requireCall = line.match(/require\(\s*['"]([^'"]+)['"]\s*\)/);
    if (requireCall) specs.push(requireCall[1]);
    // 动态 import：import('x') / import("x") / import(`x`)
    const dynamicImport = line.match(/\bimport\s*\(\s*['"]([^'"]+)['"]\s*\)/);
    if (dynamicImport) specs.push(dynamicImport[1]);
    const dynamicTemplate = line.match(/\bimport\s*\(\s*`([^`]*)`\s*\)/);
    if (dynamicTemplate) specs.push(dynamicTemplate[1]);
    for (const spec of specs) {
      if (isBuiltinOrLocal(spec)) continue;
      thirdParty.push(`${file}:${index + 1}: ${spec}`);
    }
    if (/node:https?['"]/.test(line)) network.push(`${file}:${index + 1}: ${line.trim()}`);
    else if (/\bfetch\s*\(/.test(line)) network.push(`${file}:${index + 1}: ${line.trim()}`);
    else if (/XMLHttpRequest/.test(line)) network.push(`${file}:${index + 1}: ${line.trim()}`);
    else if (/https?\.(request|get)\s*\(/.test(line)) network.push(`${file}:${index + 1}: ${line.trim()}`);
  });
}
process.stdout.write(`${JSON.stringify({ files: files.length, thirdParty, network })}\n`);
FIXSCAN

cat > "$WORK/gate-files.mjs" <<'FIXGATE'
// gate-files.mjs —— AC-027 ③：识别 bin/ 下的「**组合门实现文件**」
// 用法: node gate-files.mjs <dir>
// 输出: JSON 数组（文件绝对路径）
//
// D45（G-5 / P-16）：识别规则**写死**为 —— 文件文本里同时出现
//   ① 「skill 标记」：/skill/i
//   ② 「skill-meta / meta.json 标记」：/meta\.json/i 或 /skill[-_]?meta/i
// 该规则覆盖等价写法（如 ['skill','meta.json'].join('-') —— 只要 meta.json 片段在文本里可见），
// 且**不会**把 bin/qa-impl.mjs（既无 skill 也无 meta.json）误认成组合门实现文件。
import fs from 'node:fs';
import path from 'node:path';

const dir = process.argv[2];
const out = [];
let entries = [];
try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { entries = []; }
for (const entry of entries) {
  if (!entry.isFile()) continue;
  if (!/\.(mjs|js|cjs)$/.test(entry.name)) continue;
  const full = path.join(dir, entry.name);
  let text = '';
  try { text = fs.readFileSync(full, 'utf8'); } catch { continue; }
  const hasSkill = /skill/i.test(text);
  const hasMeta = /meta\.json/i.test(text) || /skill[-_]?meta/i.test(text);
  if (hasSkill && hasMeta) out.push(full);
}
process.stdout.write(`${JSON.stringify(out)}\n`);
FIXGATE

cat > "$WORK/skill-mentions.mjs" <<'FIXMENTION'
// skill-mentions.mjs —— AC-028 ①/②：区分「**文件提及**」与「**可执行调用**」
// 用法: node skill-mentions.mjs <file> <script1> <script2> ...
// 输出: JSON { "<script>": { mentions, calls, callsWithArgs } }
//
// D45（G-10）：① 与 ② 的检查串此前互为子串 → 删掉任一处两条原因同时出现（不可分别证伪）。
// 现在两者**互斥**：
//   mentions      = 该脚本名出现在**非命令语境**的行里（同一逻辑行里没有 `node … <脚本名>`）
//   calls         = 该脚本名以 `node … <脚本名>` 形式出现（逻辑行，含续行拼接）
//   callsWithArgs = 上述调用里**带至少一个 `--参数`**的（照着能跑）
import fs from 'node:fs';

const [file, ...scripts] = process.argv.slice(2);
let text = '';
try { text = fs.readFileSync(file, 'utf8'); } catch { text = ''; }
const lines = text.split(/\r?\n/);

// 逻辑行：行尾带续行符 `\` 的行与下一行合并（命令常写成多行）
const logical = [];
let buffer = '';
for (const line of lines) {
  const piece = buffer === '' ? line : `${buffer}\n${line}`;
  if (/\\\s*$/.test(line)) { buffer = piece; continue; }
  logical.push(piece);
  buffer = '';
}
if (buffer !== '') logical.push(buffer);

const out = {};
for (const script of scripts) {
  const escaped = String(script).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const callRe = new RegExp(`node\\s+(?:\\S*/)?${escaped}(?![A-Za-z0-9_.-])`);
  let mentions = 0;
  let calls = 0;
  let callsWithArgs = 0;
  for (const block of logical) {
    if (!block.includes(script)) continue;
    if (callRe.test(block)) {
      calls += 1;
      if (/--[A-Za-z]/.test(block)) callsWithArgs += 1;
    } else {
      mentions += 1;
    }
  }
  out[script] = { mentions, calls, callsWithArgs };
}
process.stdout.write(`${JSON.stringify(out)}\n`);
FIXMENTION

cat > "$WORK/frontmatter.mjs" <<'FIXFM'
// frontmatter.mjs —— 取 YAML frontmatter 里某个 key 的**值**（AC-001 的「非空 description」）
// 用法: node frontmatter.mjs <file> <key>
// 输出: JSON { found, raw, value, empty }
//
// D45（G-1）：判空必须判到**值**上 ——
//   块标量（| / |- / > / >-）→ 取其后的缩进块内容，块为空即判空；
//   普通标量 → 剥掉首尾引号后判非空（"" / '' 判空）。
//   不得用"该行有没有非空白字符"这种近似判定。
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
  // 块标量：其后所有缩进行都是它的内容
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

cat > "$WORK/plan-diff.mjs" <<'FIXDIFF'
// plan-diff.mjs —— 两份 JSON 的语义比对（AC-020 / AC-025 复用）
// 用法: node plan-diff.mjs <fileA> <fileB>
// 输出: "SAME" 或 "DIFF: ..."
//
// D45（P-10）：豁免依据是**值的形态**，不是字段名 ——
//   形似 ISO-8601 / epoch 秒（10 位） / epoch 毫秒（13 位）的值才当时间戳；
//   名为 time 但值不是时间戳的字段**不得**豁免；名不叫时间戳但值形似时间戳的**必须**豁免。
//   豁免必须**成对**（两份里都是时间戳形态）。
import fs from 'node:fs';

const [fileA, fileB] = process.argv.slice(2);

const isIso = (v) => typeof v === 'string'
  && /^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2}(\.\d{1,6})?)?(Z|[+-]\d{2}:?\d{2})?)?$/.test(v);
const isEpochSec = (v) => (typeof v === 'number' && Number.isInteger(v) && v >= 1e9 && v < 1e11)
  || (typeof v === 'string' && /^\d{10}$/.test(v));
const isEpochMs = (v) => (typeof v === 'number' && Number.isInteger(v) && v >= 1e12 && v < 1e14)
  || (typeof v === 'string' && /^\d{13}$/.test(v));
const isTimestampLike = (v) => isIso(v) || isEpochSec(v) || isEpochMs(v);

const diffs = [];
const walk = (x, y, at) => {
  if (diffs.length >= 6) return;
  if (x === y) return;
  const bothObjects = x && y && typeof x === 'object' && typeof y === 'object'
    && Array.isArray(x) === Array.isArray(y);
  if (!bothObjects) {
    if (isTimestampLike(x) && isTimestampLike(y)) return;   // 时间戳差异：豁免
    diffs.push(`${at}: [${JSON.stringify(x)}] vs [${JSON.stringify(y)}]`);
    return;
  }
  if (Array.isArray(x)) {
    if (x.length !== y.length) { diffs.push(`${at}: 数组长度 ${x.length} vs ${y.length}`); return; }
    for (let i = 0; i < x.length; i += 1) walk(x[i], y[i], `${at}[${i}]`);
    return;
  }
  const keys = [...new Set([...Object.keys(x), ...Object.keys(y)])].sort();
  for (const k of keys) {
    if (!(k in x)) { diffs.push(`${at}.${k}: 缺失 vs ${JSON.stringify(y[k])}`); continue; }
    if (!(k in y)) { diffs.push(`${at}.${k}: ${JSON.stringify(x[k])} vs 缺失`); continue; }
    walk(x[k], y[k], `${at}.${k}`);
  }
};

let a; let b;
try {
  a = JSON.parse(fs.readFileSync(fileA, 'utf8'));
  b = JSON.parse(fs.readFileSync(fileB, 'utf8'));
} catch (err) {
  process.stdout.write(`DIFF: 解析失败 ${err && err.message ? err.message : String(err)}\n`);
  process.exit(0);
}
walk(a, b, '$');
process.stdout.write(diffs.length === 0 ? 'SAME\n' : `DIFF: ${diffs.join(' ; ')}\n`);
FIXDIFF

cat > "$WORK/fingerprint.mjs" <<'FIXFP'
// fingerprint.mjs —— 目录内容的 sha256 清单（目录名 + 相对路径 + 文件 sha256）
// 用法: node fingerprint.mjs <dir>
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const root = process.argv[2];
const lines = [];
const walk = (dir) => {
  let entries = [];
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const entry of entries) {
    if (entry.name === '.git' || entry.name === 'node_modules') continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full);
    else if (entry.isFile()) {
      const hash = crypto.createHash('sha256').update(fs.readFileSync(full)).digest('hex');
      lines.push(`${path.relative(root, full)} ${hash}`);
    }
  }
};
walk(root);
lines.sort();
process.stdout.write(`${lines.join('\n')}\n`);
FIXFP

cat > "$WORK/readme-skills.mjs" <<'FIXREADME'
// readme-skills.mjs —— AC-003：从 README 里抽「**skill 清单**集合」
// 口径（写死在此，避免"README 说了几个"这种自报口径；D45：基准是**清单**，不是"提到的一切"）：
//   ① 表头首格是 Skill 的表格 → 取其每一行的首格；
//   ② 正文里的 skills/<name> 路径；
//   ③ 安装树代码块里 skills/ 根之后的条目。
//   三者取**并集** = README 的 skill 清单。
import fs from 'node:fs';

const text = fs.readFileSync(process.argv[2], 'utf8');
const names = new Set();
const lines = text.split(/\r?\n/);

// ① 表头首格是 Skill 的表格
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

// ② skills/<name> 路径
for (const match of text.matchAll(/skills\/([A-Za-z0-9][A-Za-z0-9._-]*)/g)) names.add(match[1]);

// ③ 安装树代码块里 skills/ 根之后的条目
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

cat > "$WORK/mutate.mjs" <<'FIXMUTATE'
// mutate.mjs —— 在**副本**上注入一个变异（结构合法优先：注入后必须仍是合法 JS）
// 用法: node mutate.mjs <dir> <regex> <replacement>
// 输出: JSON {changed: n, files: [...]}（changed=0 → 注入未生效）
import fs from 'node:fs';
import path from 'node:path';

const [dir, pattern, replacement] = process.argv.slice(2);
const files = [];
const walk = (current) => {
  let entries = [];
  try { entries = fs.readdirSync(current, { withFileTypes: true }); } catch { return; }
  for (const entry of entries) {
    const full = path.join(current, entry.name);
    if (entry.isDirectory()) walk(full);
    else if (/\.(mjs|js|cjs)$/.test(entry.name)) files.push(full);
  }
};
walk(dir);

const re = new RegExp(pattern, 'g');
const touched = [];
for (const file of files) {
  const src = fs.readFileSync(file, 'utf8');
  if (!re.test(src)) { re.lastIndex = 0; continue; }
  re.lastIndex = 0;
  const next = src.replace(re, replacement);
  if (next !== src) {
    fs.writeFileSync(file, next, 'utf8');
    touched.push(file);
  }
}
process.stdout.write(`${JSON.stringify({ changed: touched.length, files: touched })}\n`);
FIXMUTATE

cat > "$WORK/plan-keys.mjs" <<'FIXKEYS'
// plan-keys.mjs —— 取计划 JSON 的顶层键集合（用于"变异后结构是否被破坏"的自检）
import fs from 'node:fs';
try {
  const plan = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  process.stdout.write(`${JSON.stringify(Object.keys(plan).sort())}\n`);
} catch {
  process.stdout.write('[]\n');
}
FIXKEYS

# ---------------------------------------------------------------- 基线计划

step "准备夹具与基线计划"
# D45（G-9）：被验对象的指纹**起点**取在基线计划跑之前 —— 这样"整个验收过程中被改动"才是可触发的检查
# （此前起点取在变异阶段中间，且 $RP 只被读取 → 该子项恒真）。
RP_FP_START="$(node "$WORK/fingerprint.mjs" "$RP" 2>/dev/null)"
BASE_CYC="$WORK/cyc/R2-CHANGELOG-2.3"
mkdir -p "$BASE_CYC"
PLAN="$BASE_CYC/regression-plan.json"
PLAN_OUT=""
PLAN_RC=1
if [ -f "$RP/scripts/plan-regression.mjs" ]; then
  PLAN_OUT="$(node "$RP/scripts/plan-regression.mjs" --changelog "$FX/CHANGELOG.md" --cases "$FX/cases.json" --cycle-dir "$BASE_CYC" 2>&1)"
  PLAN_RC=$?
else
  PLAN_OUT="缺 scripts/plan-regression.mjs"
fi
PLAN_OK=0
if [ "$PLAN_RC" -eq 0 ] && [ -f "$PLAN" ]; then PLAN_OK=1; fi
printf '基线计划: rc=%s %s\n' "$PLAN_RC" "$([ "$PLAN_OK" = "1" ] && echo 可用 || echo 不可用)"

RC_JSON=""
if [ "$PLAN_OK" = "1" ] && [ -f "$DIM" ] && [ -f "$MTH" ]; then
  RC_JSON="$(node "$WORK/recompute.mjs" "$PLAN" "$FX/cases.json" "$FX/CHANGELOG.md" "$DIM" "$MTH" 2>/dev/null)"
fi
RC_FILE="$WORK/recompute.json"
printf '%s' "$RC_JSON" > "$RC_FILE"

plan_guard() {
  if [ "$PLAN_OK" != "1" ]; then
    bad "$1" "计划未产出（plan-regression 退出码 $PLAN_RC：$PLAN_OUT）"
    return 1
  fi
  if [ ! -s "$RC_FILE" ]; then
    bad "$1" "判据自带的重算实现不可用（维度库/方法库缺失或不可读）"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------- AC-001

step "AC-001 regression-plan skill 存在且结构合法"
A1="AC-001 regression-plan skill 存在且结构合法"
if [ ! -d "$RP" ]; then
  bad "$A1" "缺目录 skills/regression-plan/"
else
  MISSING=""
  for f in "SKILL.md" "references/regression-plan-schema.md" "references/impact-rules.md" "scripts/plan-regression.mjs" "scripts/check-plan.mjs"; do
    [ -s "$RP/$f" ] || MISSING="$MISSING $f"
  done
  NAME_OK=0; DESC_OK=0; DESC_VAL=""
  if [ -s "$RP/SKILL.md" ]; then
    # D45（G-1）：frontmatter 的 name / description 必须取**值**再判 ——
    # 此前 `grep -qE '^description:[[:space:]]*[^[:space:]]'` 会把 `description: ""` 放行
    # （`""` 的第一个引号就满足"非空白字符"）。
    FM_NAME="$(node "$WORK/frontmatter.mjs" "$RP/SKILL.md" name 2>/dev/null)"
    FM_DESC="$(node "$WORK/frontmatter.mjs" "$RP/SKILL.md" description 2>/dev/null)"
    FM_NAME_VAL="$(node -e 'try{const o=JSON.parse(process.argv[1]);console.log(String(o.value||""))}catch(e){console.log("")}' "$FM_NAME")"
    [ "$FM_NAME_VAL" = "regression-plan" ] && NAME_OK=1
    DESC_EMPTY="$(node -e 'try{const o=JSON.parse(process.argv[1]);console.log(o.found&&!o.empty?"0":"1")}catch(e){console.log("1")}' "$FM_DESC")"
    [ "$DESC_EMPTY" = "0" ] && DESC_OK=1
    DESC_VAL="$(node -e 'try{const o=JSON.parse(process.argv[1]);console.log(String(o.value||"").replace(/\s+/g," ").slice(0,40))}catch(e){console.log("")}' "$FM_DESC")"
  fi
  SHEBANG_OK=0; NODECHK_OK=0
  for f in "scripts/plan-regression.mjs" "scripts/check-plan.mjs"; do
    head -1 "$RP/$f" 2>/dev/null | grep -q '^#!' && SHEBANG_OK=$((SHEBANG_OK+1))
    node --check "$RP/$f" >/dev/null 2>&1 && NODECHK_OK=$((NODECHK_OK+1))
  done
  if [ -z "$MISSING" ] && [ "$NAME_OK" -eq 1 ] && [ "$DESC_OK" -eq 1 ] && { [ "$SHEBANG_OK" -eq 2 ] || [ "$NODECHK_OK" -eq 2 ]; }; then
    ok "$A1"
  else
    bad "$A1" "缺失或空文件=[$MISSING] frontmatter name=$NAME_OK($FM_NAME_VAL) description=$DESC_OK(值=[$DESC_VAL]) shebang=$SHEBANG_OK/2 node --check=$NODECHK_OK/2"
  fi
fi

# ---------------------------------------------------------------- AC-002

step "AC-002 每个 skill 都声明版本与依赖（skill-meta.json）"
A2="AC-002 每个 skill 都声明版本与依赖（skill-meta.json）"
SKILL_DIRS=""
for d in "$PKG"/skills/*/; do
  [ -d "$d" ] || continue
  [ -f "$d/SKILL.md" ] || continue
  SKILL_DIRS="$SKILL_DIRS $d"
done
A2_PROBLEMS=""
A2_COUNT=0
TE_REQUIRES_OK=0
for d in $SKILL_DIRS; do
  A2_COUNT=$((A2_COUNT+1))
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
// SKILL.md frontmatter 的 name 必须与 meta.name 一致
let fm=""; try{fm=fs.readFileSync(process.argv[3]+"/SKILL.md","utf8").slice(0,2000);}catch(e){}
const m=fm.match(/^---\s*$[\s\S]*?^name:\s*(\S+)\s*$/m);
const skillName=m?m[1]:null;
if(skillName!==o.name)problems.push("SKILL.md name="+skillName+" vs meta.name="+o.name);
console.log(JSON.stringify({problems,requires:o.requires||{}}));
' "$META" "$NAME" "$d" 2>/dev/null)"
  if [ -z "$RES" ]; then A2_PROBLEMS="$A2_PROBLEMS [$NAME 解析失败]"; continue; fi
  P="$(node -e 'try{const o=JSON.parse(process.argv[1]);console.log((o.problems||[]).join(";"))}catch(e){console.log("PARSE_ERR")}' "$RES")"
  REQ="$(node -e 'try{const o=JSON.parse(process.argv[1]);console.log(Object.keys(o.requires||{}).join(","))}catch(e){console.log("")}' "$RES")"
  [ -n "$P" ] && A2_PROBLEMS="$A2_PROBLEMS [$NAME $P]"
  if [ "$NAME" = "test-execute" ]; then
    case ",$REQ," in *,test-case-design,*) TE_REQUIRES_OK=1 ;; esac
  fi
done
if [ "$A2_COUNT" -eq 0 ]; then
  bad "$A2" "被验包里没有任何含 SKILL.md 的 skill 目录"
elif [ -n "$A2_PROBLEMS" ]; then
  bad "$A2" "$A2_PROBLEMS"
elif [ "$TE_REQUIRES_OK" -ne 1 ]; then
  bad "$A2" "test-execute 的 requires 里没有 test-case-design（硬跨 skill 依赖必须声明）"
else
  ok "$A2"
fi

# ---------------------------------------------------------------- AC-003

step "AC-003 README 的 skill 清单与实际目录一致"
A3="AC-003 README 的 skill 清单与实际目录一致"
if [ ! -s "$README" ]; then
  bad "$A3" "缺 README.md 或为空"
else
  README_NAMES="$(node "$WORK/readme-skills.mjs" "$README" 2>/dev/null)"
  DIR_NAMES="$(for d in $SKILL_DIRS; do basename "$d"; done | sort | tr '\n' ' ' | sed 's/ $//')"
  R_SET="$(printf '%s' "$README_NAMES" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).sort().join(" "))}catch(e){console.log("__PARSE_ERR__")}})')"
  if [ "$R_SET" = "__PARSE_ERR__" ]; then
    bad "$A3" "README 抽取失败"
  elif [ "$R_SET" = "$DIR_NAMES" ]; then
    ok "$A3"
  else
    bad "$A3" "README 的 skill 清单集合=[$R_SET] 与实际目录集合=[$DIR_NAMES] 不相等"
  fi
fi

# ---------------------------------------------------------------- AC-004

step "AC-004 新产物不得打破既有目录契约"
A4="AC-004 新产物不得打破既有目录契约"
VL="$TCD/scripts/verify-layout.mjs"
if [ ! -f "$VL" ]; then
  bad "$A4" "缺 $VL（前置条件不满足）"
else
  PROJ="$WORK/proj"
  mkdir -p "$PROJ/test-assets/environments" "$PROJ/test-assets/suites/REQ-001-coupon" "$PROJ/test-assets/cycles/R1-REQ-001" "$PROJ/test-assets/cycles/R2-CHANGELOG-2.3"
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
  cat > "$PROJ/test-assets/cycles/R2-CHANGELOG-2.3/cycle.json" <<'EOF'
{ "cycle_id":"R2-CHANGELOG-2.3","round":"R2","round_type":"regression","requirement":"REQ-001",
  "scopes":["functional"],"scopes_skipped":[],"status":"in_progress",
  "stages":{"clarify":{"status":"done"},"design":{"status":"in_progress"}},
  "history":[{"at":"2026-11-11T18:00:00+08:00","from":"planned","to":"in_progress","by":"seed"}] }
EOF
  cat > "$PROJ/test-assets/cycles/index.json" <<'EOF'
{ "cycles":[{"id":"R1-REQ-001","round":"R1","status":"in_progress","cases_total":0,"cases_passed":0,"bugs_found":0},
            {"id":"R2-CHANGELOG-2.3","round":"R2","status":"in_progress","cases_total":0,"cases_passed":0,"bugs_found":0}] }
EOF
  printf '.test-artifacts/\n' > "$PROJ/.gitignore"
  # 新产物放在**轮次目录内**（与 cycle.json 同级）
  printf '{"schema_version":1,"cycle_id":"R2-CHANGELOG-2.3"}\n' > "$PROJ/test-assets/cycles/R2-CHANGELOG-2.3/regression-plan.json"
  VL_OUT="$(node "$VL" "$PROJ" 2>&1)"; VL_RC=$?
  VL_FAILS="$(printf '%s\n' "$VL_OUT" | grep -c '^\[FAIL\]' || true)"
  case "$VL_FAILS" in ''|*[!0-9]*) VL_FAILS=99 ;; esac
  # D45（P-3）：**错误位置探针** —— 必须给出明确结论（二选一），不得两种结论都不给
  A4_CONC="不可判定：错误位置探针没布置成功"
  PROJ2="$WORK/proj-wrongpos"
  cp -r "$PROJ" "$PROJ2" 2>/dev/null
  if [ -f "$PROJ2/test-assets/cycles/R2-CHANGELOG-2.3/regression-plan.json" ]; then
    mv "$PROJ2/test-assets/cycles/R2-CHANGELOG-2.3/regression-plan.json" "$PROJ2/test-assets/regression-plan.json" 2>/dev/null
  fi
  if [ -f "$PROJ2/test-assets/regression-plan.json" ]; then
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
      位置不受约束*) ok "$A4" ;;
      *) bad "$A4" "$A4_CONC" ;;
    esac
  else
    bad "$A4" "verify-layout 退出码=$VL_RC FAIL 级问题数=$VL_FAILS 输出=$(printf '%s' "$VL_OUT" | grep '^\[FAIL\]' | head -3 | tr '\n' ' ')"
  fi
fi

# ---------------------------------------------------------------- AC-005 ~ AC-020（依赖基线计划）

step "AC-005 不得凭空造用例"
A5="AC-005 不得凭空造用例"
if plan_guard "$A5"; then
  R5="$(node -e '
const fs=require("fs");
const plan=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
const rc=JSON.parse(fs.readFileSync(process.argv[2],"utf8"));
const known=new Set(rc.case_ids);
const bad=[];
for(const list of [plan.selected||[],plan.needs_review||[]]) for(const item of list) if(!known.has(String(item.case_id))) bad.push(String(item.case_id));
console.log(bad.join(","));
' "$PLAN" "$RC_FILE" 2>/dev/null)"
  if [ -z "$R5" ]; then ok "$A5"; else bad "$A5" "计划里出现输入中不存在的用例 id: $R5"; fi
fi

step "AC-006 命中需求条目的用例必须在 selected"
A6="AC-006 命中需求条目的用例必须在 selected"
if plan_guard "$A6"; then
  R6="$(node -e '
const fs=require("fs");
const plan=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
const rc=JSON.parse(fs.readFileSync(process.argv[2],"utf8"));
const selected=new Set((plan.selected||[]).map(x=>String(x.case_id)));
// 夹具里带 @R-<n> 的变更 → 其 requirement_refs
const refs=new Set();
for(const ch of rc.changes) for(const r of ch.requirement_refs||[]) refs.add(r);
// ⚠️ AC-006 与 AC-017 ③ / AC-018 的**联合读法**：
//    方法被 not_applies_when 挡住的用例**不得**在 selected（AC-017 ③ + AC-018 互斥），
//    它归 needs_review —— 这种用例不可能同时满足"在 selected"，故不纳入本条。
//    （这不是放宽：挡住的用例由 AC-017 单独兜住。）
const blockedMethods=new Set();
for(const ch of rc.changes) for(const m of ch.method_hits||[]) blockedMethods.add(m);
const missing=rc.cases.filter(c=>{
  if(c.status!=="active") return false;
  if(!(c.requirement_refs||[]).some(r=>refs.has(r))) return false;
  if((c.method||[]).some(m=>blockedMethods.has(m))) return false;
  return !selected.has(String(c.id));
}).map(c=>c.id);
console.log(missing.join(","));
' "$PLAN" "$RC_FILE" 2>/dev/null)"
  if [ -z "$R6" ]; then ok "$A6"; else bad "$A6" "命中需求条目的 active 用例没进 selected: $R6"; fi
fi

step "AC-007 命中维度的用例必须在 selected（显式与隐式两条路径）"
A7="AC-007 命中维度的用例必须在 selected（显式与隐式两条路径）"
if plan_guard "$A7"; then
  R7="$(node -e '
const fs=require("fs");
const plan=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
const rc=JSON.parse(fs.readFileSync(process.argv[2],"utf8"));
const selected=new Set((plan.selected||[]).map(x=>String(x.case_id)));
const problems=[];
for(const dim of rc.explicit_dims||[]){
  const miss=rc.cases.filter(c=>c.status==="active"&&c.dimension===dim&&!selected.has(String(c.id))).map(c=>c.id);
  if(miss.length) problems.push("显式路径["+dim+"] 漏: "+miss.join(","));
}
for(const dim of rc.signal_dims||[]){
  const miss=rc.cases.filter(c=>c.status==="active"&&c.dimension===dim&&!selected.has(String(c.id))).map(c=>c.id);
  if(miss.length) problems.push("信号路径["+dim+"] 漏: "+miss.join(","));
}
console.log(problems.join(" ; "));
' "$PLAN" "$RC_FILE" 2>/dev/null)"
  if [ -z "$R7" ]; then ok "$A7"; else bad "$A7" "$R7"; fi
fi

step "AC-008 显式引用用例的变更条目必须把该用例选进来"
A8="AC-008 显式引用用例的变更条目必须把该用例选进来"
if plan_guard "$A8"; then
  R8="$(node -e '
const fs=require("fs");
const plan=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
const rc=JSON.parse(fs.readFileSync(process.argv[2],"utf8"));
const selected=new Set((plan.selected||[]).map(x=>String(x.case_id)));
const refs=new Set();
for(const ch of rc.changes) for(const r of ch.case_refs||[]) refs.add(r);
const missing=[...refs].filter(id=>!selected.has(id));
console.log(missing.join(","));
' "$PLAN" "$RC_FILE" 2>/dev/null)"
  if [ -z "$R8" ]; then ok "$A8"; else bad "$A8" "被 @TC-xxx 显式引用的用例没进 selected: $R8"; fi
fi

step "AC-009 不在影响面内的用例不得进 selected"
A9="AC-009 不在影响面内的用例不得进 selected"
if plan_guard "$A9"; then
  R9="$(node -e '
const fs=require("fs");
const plan=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
const rc=JSON.parse(fs.readFileSync(process.argv[2],"utf8"));
const selected=(plan.selected||[]).map(x=>String(x.case_id));
const over=selected.filter(id=>rc.not_affected.includes(id));
console.log(over.join(","));
' "$PLAN" "$RC_FILE" 2>/dev/null)"
  if [ -z "$R9" ]; then ok "$A9"; else bad "$A9" "不在影响面内的用例被多选: $R9"; fi
fi

step "AC-010 selected 必须等于按计划自记 basis 重算的并集"
A10="AC-010 selected 必须等于按计划自记 basis 重算的并集"
if plan_guard "$A10"; then
  R10="$(node -e '
const fs=require("fs");
const plan=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
const rc=JSON.parse(fs.readFileSync(process.argv[2],"utf8"));
const problems=[];
if(rc.basis_mismatch) problems.push("计划里的变更条数("+rc.plan_change_count+")与 changelog 实际条数("+rc.changelog_change_count+")不等");
const sel=(plan.selected||[]).map(x=>String(x.case_id)).sort();
const rev=(plan.needs_review||[]).map(x=>String(x.case_id)).sort();
const es=[...rc.basis_selected].sort(), er=[...rc.basis_needs_review].sort();
if(sel.join(",")!==es.join(",")) problems.push("selected 差集: 多["+sel.filter(x=>!es.includes(x)).join(",")+"] 少["+es.filter(x=>!sel.includes(x)).join(",")+"]");
if(rev.join(",")!==er.join(",")) problems.push("needs_review 差集: 多["+rev.filter(x=>!er.includes(x)).join(",")+"] 少["+er.filter(x=>!rev.includes(x)).join(",")+"]");
// D45（P-7）：undecidable_changes 也要与**同一个独立重算**比对 —— 凭空多报一个判不了条目不能全绿
const und=(plan.undecidable_changes||[]).map(x=>String(x.change_id)).sort();
const eu=[...(rc.undecidable_from_changelog||[])].sort();
if(und.join(",")!==eu.join(",")) problems.push("undecidable_changes 差集: 多["+und.filter(x=>!eu.includes(x)).join(",")+"] 少["+eu.filter(x=>!und.includes(x)).join(",")+"]");
console.log(problems.join(" ; "));
' "$PLAN" "$RC_FILE" 2>/dev/null)"
  if [ -z "$R10" ]; then ok "$A10"; else bad "$A10" "$R10"; fi
fi

step "AC-011 每条选样都必须有可解释的来源"
A11="AC-011 每条选样都必须有可解释的来源"
if plan_guard "$A11"; then
  R11="$(node "$WORK/reason.mjs" "$PLAN" "$RC_FILE" 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log((JSON.parse(s).problems||[]).slice(0,4).join(" ; "))}catch(e){console.log("PARSE_ERR")}})')"
  if [ -z "$R11" ] || [ "$R11" = "PARSE_ERR" ]; then ok "$A11"; else bad "$A11" "$R11"; fi
fi

step "AC-012 判不了的变更必须显式列出"
A12="AC-012 判不了的变更必须显式列出"
if plan_guard "$A12"; then
  R12="$(node -e '
const fs=require("fs");
const plan=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
const rc=JSON.parse(fs.readFileSync(process.argv[2],"utf8"));
const und=Array.isArray(plan.undecidable_changes)?plan.undecidable_changes:[];
const expected=(rc.undecidable_from_changelog||[]).map(String);
const actual=und.map(x=>String(x.change_id));
const problems=[];
// ① 集合相等：不得多报，也不得漏报（D45 / P-5）
for(const id of expected) if(!actual.includes(id)) problems.push("判不了条目 "+id+" 没出现在 undecidable_changes");
for(const id of actual) if(!expected.includes(id)) problems.push("undecidable_changes 多报了 "+id+"（独立重算的判不了集合里没有它）");
// ② reason 非空 + 可核对（实体必须在权威来源里存在 + 必须含判不了依据标记）
const MARK=/无显式引用|未命中|没有命中|未引用|无引用|没有引用|无维度|无方法|无信号|没有信号|判不了|无法判定|无法判断|无法推出|推不出|信息不足|缺少|没有影响面|无影响面/;
const dimIds=(rc.dim_lib||[]).map(d=>String(d.id));
const methodIds=(rc.method_lib||[]).map(m=>String(m.id));
for(const item of und){
  const id=String(item.change_id);
  const reason=typeof item.reason==="string"?item.reason.trim():"";
  if(reason===""){problems.push("判不了条目 "+id+" 的 reason 为空");continue;}
  for(const t of (reason.match(/\bR-\d+\b/g)||[])) if(!(rc.requirement_ids||[]).includes(t)) problems.push("判不了条目 "+id+" 的 reason 提到需求条目 "+t+"，但输入用例集里没有这个需求条目");
  for(const t of (reason.match(/\bTC-\d{3}\b/g)||[])) if(!(rc.case_ids||[]).includes(t)) problems.push("判不了条目 "+id+" 的 reason 提到用例 "+t+"，但输入用例集里没有这个用例");
  for(const t of (reason.match(/\bM\d+\.\d+\b/g)||[])) if(!methodIds.includes(t)) problems.push("判不了条目 "+id+" 的 reason 提到方法 "+t+"，但方法库里没有这个方法");
  for(const m of reason.matchAll(/\b(requirement_ref|case_ref|dim_ref|dim_signal|method_not_applies)\s*:\s*([A-Za-z0-9_.\-]+)/g)){
    const key=m[1], val=m[2];
    if(key==="requirement_ref" && !(rc.requirement_ids||[]).includes(val)) problems.push("判不了条目 "+id+" 的 reason 里的 "+key+":"+val+" 在输入用例集里不存在");
    if(key==="case_ref" && !(rc.case_ids||[]).includes(val)) problems.push("判不了条目 "+id+" 的 reason 里的 "+key+":"+val+" 在输入用例集里不存在");
    if(key==="dim_ref" && !dimIds.includes(val)) problems.push("判不了条目 "+id+" 的 reason 里的 "+key+":"+val+" 在维度库里不存在");
    if(key==="dim_signal" && !dimIds.includes(val.replace(/\(.*$/,""))) problems.push("判不了条目 "+id+" 的 reason 里的 "+key+":"+val+" 在维度库里不存在");
    if(key==="method_not_applies" && !methodIds.includes(val)) problems.push("判不了条目 "+id+" 的 reason 里的 "+key+":"+val+" 在方法库里不存在");
  }
  if(!MARK.test(reason)) problems.push("判不了条目 "+id+" 的 reason 里没有可核对的判不了依据标记（应说明为什么判不了：无显式引用 / 未命中 / 判不了 / 推不出 等）");
}
console.log(problems.join(" ; "));
' "$PLAN" "$RC_FILE" 2>/dev/null)"
  # ③ D45 子项（判不了的定义 = 推不出任何用例级影响面）：独立夹具
  D45_DIR="$WORK/d45"
  mkdir -p "$D45_DIR/cyc/R2-CHANGELOG-2.4"
  cat > "$D45_DIR/cases.json" <<'FIXD45CASES'
{
  "schema_version": 2,
  "requirements": [
    { "id": "R-1", "title": "有用例覆盖的需求", "source_ref": "需求 1", "testable": true },
    { "id": "R-9", "title": "没有任何用例覆盖的需求", "source_ref": "需求 9", "testable": true }
  ],
  "open_questions": [],
  "coverage_matrix": [],
  "cases": [
    { "id": "TC-901", "title": "唯一有覆盖的用例", "requirement_refs": ["R-1"], "dimension": "functional", "priority": "P1", "method": ["M1.1"], "status": "active", "steps": [] }
  ]
}
FIXD45CASES
  cat > "$D45_DIR/CHANGELOG.md" <<'FIXD45LOG'
# 变更日志 2.4

## 只命中方法短语的条目

本次场景属于 无明确边界的业务流程，相关方法不适用。

## 引用了没有用例覆盖的需求条目

本次修订涉及 @R-9 条目。
FIXD45LOG
  node "$RP/scripts/plan-regression.mjs" --changelog "$D45_DIR/CHANGELOG.md" --cases "$D45_DIR/cases.json" --cycle-dir "$D45_DIR/cyc/R2-CHANGELOG-2.4" >/dev/null 2>&1
  D45_RC=$?
  D45_PLAN="$D45_DIR/cyc/R2-CHANGELOG-2.4/regression-plan.json"
  if [ "$D45_RC" -ne 0 ] || [ ! -s "$D45_PLAN" ]; then
    R12="$R12 ; D45 探针：plan-regression 对独立夹具退出码=$D45_RC（期望 0）"
  else
    D45_PROBLEMS="$(node -e '
const fs=require("fs");
const plan=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
const problems=[];
const und=(plan.undecidable_changes||[]).map(x=>String(x.change_id)).sort();
const expect=["C-1","C-2"];
const why={"C-1":"只命中方法短语、对应不到任何用例","C-2":"合法引用但无任何用例覆盖"};
for(const id of expect) if(!und.includes(id)) problems.push("条目 "+id+"（"+why[id]+"）没有进 undecidable_changes");
for(const id of und) if(!expect.includes(id)) problems.push("undecidable_changes 多报了 "+id);
if((plan.selected||[]).length!==0) problems.push("selected 非空（这两条都推不出用例级影响面）");
if((plan.needs_review||[]).length!==0) problems.push("needs_review 非空");
if(plan.summary && plan.summary.impact_complete!==false) problems.push("summary.impact_complete="+plan.summary.impact_complete+"（有判不了条目时必须是 false）");
console.log(problems.join(" ; "));
' "$D45_PLAN" 2>/dev/null)"
    [ -n "$D45_PROBLEMS" ] && R12="$R12 ; D45 探针: $D45_PROBLEMS"
  fi
  if [ -z "$R12" ]; then ok "$A12"; else bad "$A12" "$R12"; fi
fi

step "AC-013 判不了的变更不得让任何用例进 selected"
A13="AC-013 判不了的变更不得让任何用例进 selected"
if plan_guard "$A13"; then
  R13="$(node -e '
const fs=require("fs");
const plan=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
const rc=JSON.parse(fs.readFileSync(process.argv[2],"utf8"));
const und=(Array.isArray(plan.undecidable_changes)?plan.undecidable_changes:[]).map(x=>String(x.change_id));
const problems=[];
for(const item of plan.selected||[]){
  for(const ref of item.change_refs||[]) if(und.includes(String(ref))) problems.push("selected: "+String(item.case_id)+" 的 change_refs 含判不了条目 "+String(ref));
}
// D45（P-6）：同一约束必须覆盖 needs_review 侧 —— 只影响 needs_review 的条目不得被挂上判不了条目
for(const item of plan.needs_review||[]){
  for(const ref of item.change_refs||[]) if(und.includes(String(ref))) problems.push("needs_review: "+String(item.case_id)+" 的 change_refs 含判不了条目 "+String(ref));
}
console.log(problems.join(" ; "));
' "$PLAN" "$RC_FILE" 2>/dev/null)"
  if [ -z "$R13" ]; then ok "$A13"; else bad "$A13" "$R13"; fi
fi

step "AC-014 坏引用必须报错，不得静默"
A14="AC-014 坏引用必须报错，不得静默"
if [ ! -f "$RP/scripts/plan-regression.mjs" ]; then
  bad "$A14" "缺 scripts/plan-regression.mjs"
else
  BAD_RC1=99; BAD_RC2=99; BAD_RC3=99; BAD_OUT1=""; BAD_OUT2=""; BAD_OUT3=""
  mkdir -p "$WORK/bad1/R2-CHANGELOG-2.3" "$WORK/bad2/R2-CHANGELOG-2.3" "$WORK/bad3/R2-CHANGELOG-2.3"
  BAD_OUT1="$(node "$RP/scripts/plan-regression.mjs" --changelog "$FX/bad-R.md" --cases "$FX/cases.json" --cycle-dir "$WORK/bad1/R2-CHANGELOG-2.3" 2>&1)"; BAD_RC1=$?
  BAD_OUT2="$(node "$RP/scripts/plan-regression.mjs" --changelog "$FX/bad-TC.md" --cases "$FX/cases.json" --cycle-dir "$WORK/bad2/R2-CHANGELOG-2.3" 2>&1)"; BAD_RC2=$?
  BAD_OUT3="$(node "$RP/scripts/plan-regression.mjs" --changelog "$FX/bad-DIM.md" --cases "$FX/cases.json" --cycle-dir "$WORK/bad3/R2-CHANGELOG-2.3" 2>&1)"; BAD_RC3=$?
  P1=0; P2=0; P3=0
  [ "$BAD_RC1" -eq 1 ] && printf '%s' "$BAD_OUT1" | grep -q 'R-99' && P1=1
  [ "$BAD_RC2" -eq 1 ] && printf '%s' "$BAD_OUT2" | grep -q 'TC-999' && P2=1
  # D44：第三种坏引用 —— 指向维度库里不存在的维度。退出码必须是 1（不是 2 用法错、不是 0 静默放过），
  # 且输出必须点名那个不存在的维度名。
  [ "$BAD_RC3" -eq 1 ] && printf '%s' "$BAD_OUT3" | grep -q 'not-a-real-dimension' && P3=1
  if [ "$P1" -eq 1 ] && [ "$P2" -eq 1 ] && [ "$P3" -eq 1 ]; then
    ok "$A14"
  else
    bad "$A14" "@R-99: rc=$BAD_RC1(期望1) 点名=$P1 out=$(printf '%s' "$BAD_OUT1" | head -2 | tr '\n' ' ') | @TC-999: rc=$BAD_RC2(期望1) 点名=$P2 out=$(printf '%s' "$BAD_OUT2" | head -2 | tr '\n' ' ') | @dim:不存在: rc=$BAD_RC3(期望1) 点名=$P3 out=$(printf '%s' "$BAD_OUT3" | head -2 | tr '\n' ' ')"
  fi
fi

step "AC-015 摘要数字与影响面完整声明"
A15="AC-015 摘要数字与影响面完整声明"
if plan_guard "$A15"; then
  R15="$(node -e '
const fs=require("fs");
const plan=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
const rc=JSON.parse(fs.readFileSync(process.argv[2],"utf8"));
const sel=Array.isArray(plan.selected)?plan.selected:[];
const rev=Array.isArray(plan.needs_review)?plan.needs_review:[];
const und=Array.isArray(plan.undecidable_changes)?plan.undecidable_changes:[];
const s=plan.summary||{};
const problems=[];
if(Number(s.total_cases)!==rc.case_ids.length) problems.push("summary.total_cases="+s.total_cases+" 实际用例数="+rc.case_ids.length);
if(Number(s.selected)!==sel.length) problems.push("summary.selected="+s.selected+" 实际="+sel.length);
if(Number(s.needs_review)!==rev.length) problems.push("summary.needs_review="+s.needs_review+" 实际="+rev.length);
if(Number(s.undecidable_changes)!==und.length) problems.push("summary.undecidable_changes="+s.undecidable_changes+" 实际="+und.length);
if(s.impact_complete!==(und.length===0)) problems.push("summary.impact_complete="+s.impact_complete+" 与判不了条数矛盾");
console.log(problems.join(" ; "));
' "$PLAN" "$RC_FILE" 2>/dev/null)"
  if [ -z "$R15" ]; then ok "$A15"; else bad "$A15" "$R15"; fi
fi

step "AC-016 非 active 的用例不得进 selected"
A16="AC-016 非 active 的用例不得进 selected"
if plan_guard "$A16"; then
  R16="$(node -e '
const fs=require("fs");
const plan=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
const rc=JSON.parse(fs.readFileSync(process.argv[2],"utf8"));
const selected=new Set((plan.selected||[]).map(x=>String(x.case_id)));
const bad=(rc.non_active_ids||[]).filter(id=>selected.has(id));
console.log(bad.join(","));
' "$PLAN" "$RC_FILE" 2>/dev/null)"
  if [ -z "$R16" ]; then ok "$A16"; else bad "$A16" "非 active 的用例进了 selected: $R16"; fi
fi

step "AC-017 方法 not_applies_when 命中的用例必须进 needs_review"
A17="AC-017 方法 not_applies_when 命中的用例必须进 needs_review"
if plan_guard "$A17"; then
  R17="$(node -e '
const fs=require("fs");
const plan=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
const rc=JSON.parse(fs.readFileSync(process.argv[2],"utf8"));
const review=new Set((plan.needs_review||[]).map(x=>String(x.case_id)));
const selected=new Set((plan.selected||[]).map(x=>String(x.case_id)));
const problems=[];
// 找出（方法 m, 变更条目 C）：C 的正文逐字含 m.not_applies_when 的某一条短语
const pairs=[];
for(const ch of rc.changes||[]){
  for(const m of rc.method_lib||[]){
    for(const phrase of m.not_applies_when||[]){
      if(phrase&&String(ch.text||"").includes(phrase)){pairs.push({m:m.id,c:ch.id});break;}
    }
  }
}
if(pairs.length===0) problems.push("夹具前提不成立：没有任何变更条目逐字命中某个方法的 not_applies_when");
const hitMethods=new Set(pairs.map(p=>p.m));
for(const c of rc.cases||[]){
  const uses=(c.method||[]).some(m=>hitMethods.has(m));
  if(!uses) continue;
  if(!rc.affected.includes(String(c.id))) continue;
  if(!review.has(String(c.id))) problems.push("用例 "+c.id+" 用了方法 "+c.method.join(",")+"（命中 not_applies_when）却不在 needs_review");
  if(selected.has(String(c.id))) problems.push("用例 "+c.id+" 用了方法 "+c.method.join(",")+"（命中 not_applies_when）却还在 selected");
}
console.log(problems.join(" ; "));
' "$PLAN" "$RC_FILE" 2>/dev/null)"
  if [ -z "$R17" ]; then ok "$A17"; else bad "$A17" "$R17"; fi
fi

step "AC-018 selected 与 needs_review 两个用例集合必须互斥"
A18="AC-018 selected 与 needs_review 两个用例集合必须互斥"
if plan_guard "$A18"; then
  R18="$(node -e '
const fs=require("fs");
const plan=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
const sel=(plan.selected||[]).map(x=>String(x.case_id));
const rev=(plan.needs_review||[]).map(x=>String(x.case_id));
console.log(sel.filter(id=>rev.includes(id)).join(","));
' "$PLAN" 2>/dev/null)"
  if [ -z "$R18" ]; then ok "$A18"; else bad "$A18" "同时出现在 selected 与 needs_review 的用例: $R18"; fi
fi

step "AC-019 不得修改输入用例集与变更日志"
A19="AC-019 不得修改输入用例集与变更日志"
# D45（G-2 / P-9）：**自己复制一份输入、用副本跑** ——
#   ① 变更日志也必须被指纹覆盖（此前只指纹 cases.json，而 SKILL.md 的硬约束是「两者一律不改」）；
#   ② before 指纹必须取自**副本** —— 此前取自共享夹具，而门在更早的步骤里已经跑过一次
#      plan-regression.mjs，污染会被"前一次跑"吸收掉 → **幂等写回**（写回内容与原文件相同）查不出来。
AC19_DIR="$WORK/ac19"
mkdir -p "$AC19_DIR/R2-CHANGELOG-2.3"
cp "$FX/cases.json" "$AC19_DIR/cases.json"
cp "$FX/CHANGELOG.md" "$AC19_DIR/CHANGELOG.md"
C_BEFORE="$(sha256sum "$AC19_DIR/cases.json" 2>/dev/null | cut -d' ' -f1)"
L_BEFORE="$(sha256sum "$AC19_DIR/CHANGELOG.md" 2>/dev/null | cut -d' ' -f1)"
node "$RP/scripts/plan-regression.mjs" --changelog "$AC19_DIR/CHANGELOG.md" --cases "$AC19_DIR/cases.json" --cycle-dir "$AC19_DIR/R2-CHANGELOG-2.3" >/dev/null 2>&1
C_AFTER="$(sha256sum "$AC19_DIR/cases.json" 2>/dev/null | cut -d' ' -f1)"
L_AFTER="$(sha256sum "$AC19_DIR/CHANGELOG.md" 2>/dev/null | cut -d' ' -f1)"
A19_PROBLEMS=""
if [ -z "$C_BEFORE" ] || [ "$C_BEFORE" != "$C_AFTER" ]; then
  A19_PROBLEMS="$A19_PROBLEMS [cases.json 的 sha256 变了: $C_BEFORE → $C_AFTER]"
fi
if [ -z "$L_BEFORE" ] || [ "$L_BEFORE" != "$L_AFTER" ]; then
  A19_PROBLEMS="$A19_PROBLEMS [CHANGELOG.md 的 sha256 变了: $L_BEFORE → $L_AFTER]"
fi
if [ -z "$A19_PROBLEMS" ]; then ok "$A19"; else bad "$A19" "$A19_PROBLEMS"; fi

step "AC-020 同一输入两次跑输出必须逐字相同（除时间戳）"
A20="AC-020 同一输入两次跑输出必须逐字相同（除时间戳）"
mkdir -p "$WORK/idem1/R2-CHANGELOG-2.3" "$WORK/idem2/R2-CHANGELOG-2.3"
node "$RP/scripts/plan-regression.mjs" --changelog "$FX/CHANGELOG.md" --cases "$FX/cases.json" --cycle-dir "$WORK/idem1/R2-CHANGELOG-2.3" >/dev/null 2>&1
node "$RP/scripts/plan-regression.mjs" --changelog "$FX/CHANGELOG.md" --cases "$FX/cases.json" --cycle-dir "$WORK/idem2/R2-CHANGELOG-2.3" >/dev/null 2>&1
P1F="$WORK/idem1/R2-CHANGELOG-2.3/regression-plan.json"
P2F="$WORK/idem2/R2-CHANGELOG-2.3/regression-plan.json"
if [ ! -s "$P1F" ] || [ ! -s "$P2F" ]; then
  bad "$A20" "两次跑没有都产出计划"
else
  # D45（P-10）：豁免依据是**值的形态**（ISO8601 / epoch 秒 / epoch 毫秒），不是字段名清单 ——
  # 名为 time 的非时间戳字段不得被误剥，别名字的真时间戳也不得被保留。
  DIFF="$(node "$WORK/plan-diff.mjs" "$P1F" "$P2F" 2>/dev/null)"
  if [ -z "$DIFF" ]; then
    bad "$A20" "比对工具不可用（不可判定，不判通过）"
  elif [ "$DIFF" = "SAME" ]; then
    ok "$A20"
  else
    bad "$A20" "两次输出有差异: $DIFF"
  fi
fi

# ---------------------------------------------------------------- AC-021 ~ AC-024（组合门）

step "AC-021 安装器提供组合校验子命令，且它把包装到临时根并校验依赖图"
A21="AC-021 安装器提供组合校验子命令，且它把包装到临时根并校验依赖图"
VERIFY_ROOT="$WORK/verifyroot"
mkdir -p "$VERIFY_ROOT"
A21_PROBLEMS=""
if [ ! -f "$INSTALLER" ]; then
  A21_PROBLEMS="缺 bin/test-agent-skills.mjs"
else
  HELP_OUT="$(node "$INSTALLER" --help 2>&1)"
  SUB_OK=0
  # D45（G-4 / P-11）：命令名**钉死为 verify**（与 README 文档化的命令名一致）——
  # 必须是独立词（`verify-suite` 这类更长的名字不算），且下面还要 dispatch 实跑一遍。
  printf '%s' "$HELP_OUT" | grep -qE '(^|[^A-Za-z0-9_-])verify([^A-Za-z0-9_-]|$)' && SUB_OK=1
  [ "$SUB_OK" -eq 0 ] && A21_PROBLEMS="$A21_PROBLEMS --help 的命令列表里没有列出组合校验子命令 verify"
  VERIFY_OUT="$(node "$INSTALLER" verify --root "$VERIFY_ROOT" 2>&1)"; VERIFY_RC=$?
  [ "$VERIFY_RC" -ne 0 ] && A21_PROBLEMS="$A21_PROBLEMS verify 退出码=$VERIFY_RC out=$(printf '%s' "$VERIFY_OUT" | head -3 | tr '\n' ' ')"
  # ③ 临时目录里必须出现**全部** skill 目录
  for d in $SKILL_DIRS; do
    NAME="$(basename "$d")"
    [ -d "$VERIFY_ROOT/skills/$NAME" ] || A21_PROBLEMS="$A21_PROBLEMS [临时根缺 $NAME]"
  done
  # ④ 依赖图校验：把某个 requires 改成不可能满足的版本 → 必须判红
  BADPKG="$WORK/badpkg"
  mkdir -p "$BADPKG"
  cp -r "$PKG"/bin "$PKG"/skills "$PKG"/package.json "$BADPKG"/ 2>/dev/null
  if [ -f "$BADPKG/skills/test-execute/skill-meta.json" ]; then
    node -e '
const fs=require("fs");const f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));
o.requires=o.requires||{};o.requires["test-case-design"]=">=99.0.0";fs.writeFileSync(f,JSON.stringify(o,null,2));
' "$BADPKG/skills/test-execute/skill-meta.json" 2>/dev/null
    mkdir -p "$WORK/badroot"
    BADV_OUT="$(node "$BADPKG/bin/test-agent-skills.mjs" verify --root "$WORK/badroot" 2>&1)"; BADV_RC=$?
    if [ "$BADV_RC" -eq 0 ]; then
      A21_PROBLEMS="$A21_PROBLEMS [把 requires 改成 >=99.0.0 后 verify 仍然退出码 0 —— 依赖图没校验]"
    fi
  else
    A21_PROBLEMS="$A21_PROBLEMS [副本里没有 test-execute/skill-meta.json，无法做依赖图探针]"
  fi
  # ⑤ D45（G-6）：版本比较必须**逐段数值** —— 1.10.0 满足 >=1.2.0（字典序会说"不满足"）
  OKPKG="$WORK/okpkg"
  mkdir -p "$OKPKG"
  cp -r "$PKG"/bin "$PKG"/skills "$PKG"/package.json "$OKPKG"/ 2>/dev/null
  if [ -f "$OKPKG/skills/test-case-design/skill-meta.json" ] && [ -f "$OKPKG/skills/test-execute/skill-meta.json" ]; then
    node -e '
const fs=require("fs");
const mf=process.argv[1], tf=process.argv[2];
const m=JSON.parse(fs.readFileSync(mf,"utf8")); m.version="1.10.0"; fs.writeFileSync(mf,JSON.stringify(m,null,2));
const t=JSON.parse(fs.readFileSync(tf,"utf8")); t.requires=t.requires||{}; t.requires["test-case-design"]=">=1.2.0"; fs.writeFileSync(tf,JSON.stringify(t,null,2));
' "$OKPKG/skills/test-case-design/skill-meta.json" "$OKPKG/skills/test-execute/skill-meta.json" 2>/dev/null
    mkdir -p "$WORK/okroot"
    OKV_OUT="$(node "$OKPKG/bin/test-agent-skills.mjs" verify --root "$WORK/okroot" 2>&1)"; OKV_RC=$?
    if [ "$OKV_RC" -ne 0 ]; then
      A21_PROBLEMS="$A21_PROBLEMS [1.10.0 满足 >=1.2.0，但 verify 退出码=$OKV_RC —— 版本比较不是逐段数值（字典序会误判不满足）]"
    fi
  else
    A21_PROBLEMS="$A21_PROBLEMS [副本里没有 test-case-design / test-execute 的 skill-meta.json，无法做逐段边界探针]"
  fi
fi
if [ -z "$A21_PROBLEMS" ]; then ok "$A21"; else bad "$A21" "$A21_PROBLEMS"; fi

step "AC-022 组合门必须实跑跨 skill 组合场景"
A22="AC-022 组合门必须实跑跨 skill 组合场景"
A22_PROBLEMS=""
TR="$VERIFY_ROOT/skills"
if [ ! -d "$TR" ]; then
  A22_PROBLEMS="临时根里没有安装出来的 skill（先跑 AC-021）"
else
  OFFLINE="$TR/test-execute/examples/offline"
  SUITE="$OFFLINE/test-assets/suites/REQ-DEMO-demo/suite.json"
  RUNOUT="$WORK/gate-exec-offline"
  if [ -f "$SUITE" ] && [ -f "$TR/test-execute/scripts/run-suite.mjs" ]; then
    node "$TR/test-execute/scripts/run-suite.mjs" "$SUITE" --project-root "$OFFLINE" --output-dir "$RUNOUT" --run-id gate-offline >/dev/null 2>&1
    if [ -s "$RUNOUT/meta.json" ]; then
      COUNTS="$(node -e 'const o=require(process.argv[1]);console.log([o.cases_passed,o.cases_failed,o.cases_blocked,o.cases_skipped].join("/"));' "$RUNOUT/meta.json" 2>/dev/null)"
      [ "$COUNTS" = "4/1/1/0" ] || A22_PROBLEMS="$A22_PROBLEMS [offline 夹具结果=$COUNTS，期望 4/1/1/0]"
    else
      A22_PROBLEMS="$A22_PROBLEMS [offline 夹具没有产出 meta.json]"
    fi
  else
    A22_PROBLEMS="$A22_PROBLEMS [临时根里没有 test-execute 的 offline 夹具]"
  fi
  # 轮次推进：cycle-state init → run-suite --cycle → cycle.json 的 execute 阶段推进
  CYC="$WORK/gate-cycle/R2-GATE"
  mkdir -p "$CYC"
  if [ -f "$TR/test-case-design/scripts/cycle-state.mjs" ] && [ -f "$TR/test-execute/scripts/run-suite.mjs" ] && [ -f "$SUITE" ]; then
    node "$TR/test-case-design/scripts/cycle-state.mjs" init "$CYC" --cycle-id R2-GATE --round R2 --round-type regression --requirement REQ-GATE --scope functional --by gate >/dev/null 2>&1
    INIT_RC=$?
    if [ "$INIT_RC" -ne 0 ]; then
      A22_PROBLEMS="$A22_PROBLEMS [cycle-state init 退出码=$INIT_RC]"
    else
      node "$TR/test-execute/scripts/run-suite.mjs" "$SUITE" --project-root "$OFFLINE" --output-dir "$WORK/gate-exec-cycle" --run-id gate-cycle --cycle "$CYC" >/dev/null 2>&1
      if [ -s "$CYC/cycle.json" ]; then
        CYCINFO="$(node -e '
const fs=require("fs");const c=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
const st=c.stages&&c.stages.execute?c.stages.execute:{};
const runs=Array.isArray(st.runs)?st.runs:[];
console.log((st.status||"无")+"|"+runs.join(","));
' "$CYC/cycle.json" 2>/dev/null)"
        ST="${CYCINFO%%|*}"; RUNS="${CYCINFO#*|}"
        [ "$ST" = "in_progress" ] || A22_PROBLEMS="$A22_PROBLEMS [execute 阶段状态=$ST，期望 in_progress]"
        printf '%s' "$RUNS" | grep -q 'gate-cycle' || A22_PROBLEMS="$A22_PROBLEMS [stages.execute.runs 里没有本次 run_id: $RUNS]"
      else
        A22_PROBLEMS="$A22_PROBLEMS [没有产出 cycle.json]"
      fi
    fi
  else
    A22_PROBLEMS="$A22_PROBLEMS [临时根里缺 cycle-state.mjs / run-suite.mjs]"
  fi
fi
if [ -z "$A22_PROBLEMS" ]; then ok "$A22"; else bad "$A22" "$A22_PROBLEMS"; fi

step "AC-023 依赖不满足时必须报版本问题"
A23="AC-023 依赖不满足时必须报版本问题"
A23_PROBLEMS=""
BADPKG2="$WORK/badpkg2"
mkdir -p "$BADPKG2"
cp -r "$PKG"/bin "$PKG"/skills "$PKG"/package.json "$BADPKG2"/ 2>/dev/null
if [ ! -f "$BADPKG2/bin/test-agent-skills.mjs" ] || [ ! -f "$BADPKG2/skills/test-execute/skill-meta.json" ]; then
  A23_PROBLEMS="缺安装器或 test-execute/skill-meta.json"
else
  # D45（G-6 / P-12）：反向逐段边界探针 —— 1.2.0 **不满足** >=1.10.0
  # （字典序比较会说"满足" → 一个语义错误的版本比较能一路全绿通过）。
  node -e '
const fs=require("fs");
const mf=process.argv[1], tf=process.argv[2];
const m=JSON.parse(fs.readFileSync(mf,"utf8")); m.version="1.2.0"; fs.writeFileSync(mf,JSON.stringify(m,null,2));
const t=JSON.parse(fs.readFileSync(tf,"utf8")); t.requires=t.requires||{}; t.requires["test-case-design"]=">=1.10.0"; fs.writeFileSync(tf,JSON.stringify(t,null,2));
' "$BADPKG2/skills/test-case-design/skill-meta.json" "$BADPKG2/skills/test-execute/skill-meta.json" 2>/dev/null
  mkdir -p "$WORK/badroot2"
  BADV2_OUT="$(node "$BADPKG2/bin/test-agent-skills.mjs" verify --root "$WORK/badroot2" 2>&1)"; BADV2_RC=$?
  [ "$BADV2_RC" -ne 0 ] || A23_PROBLEMS="$A23_PROBLEMS [退出码=0，期望非 0]"
  printf '%s' "$BADV2_OUT" | grep -q 'test-execute' || A23_PROBLEMS="$A23_PROBLEMS [输出没有点名出问题的 skill]"
  printf '%s' "$BADV2_OUT" | grep -q '1\.10\.0' || A23_PROBLEMS="$A23_PROBLEMS [输出没有给出要求的版本值]"
  printf '%s' "$BADV2_OUT" | grep -q '1\.2\.0' || A23_PROBLEMS="$A23_PROBLEMS [输出没有给出实际版本值]"
  if printf '%s' "$BADV2_OUT" | grep -qiE '缺少必填字段|expected'; then
    A23_PROBLEMS="$A23_PROBLEMS [输出里出现了下游业务错的特征串]"
  fi
fi
if [ -z "$A23_PROBLEMS" ]; then ok "$A23"; else bad "$A23" "$A23_PROBLEMS"; fi

step "AC-024 组合门必须隔离，不得改动真实安装根"
A24="AC-024 组合门必须隔离，不得改动真实安装根"
REAL_ROOT="${TEST_AGENT_SKILLS_DIR:-$HOME/.agents}"
REAL_SKILLS="$REAL_ROOT/skills"
FP_BEFORE=""; FP_AFTER=""
if [ -d "$REAL_SKILLS" ]; then
  FP_BEFORE="$(node "$WORK/fingerprint.mjs" "$REAL_SKILLS" 2>/dev/null)"
fi
# 再跑一次组合门（这一轮专门看真实安装根有没有被动过）
mkdir -p "$WORK/verifyroot3"
if [ -f "$INSTALLER" ]; then
  node "$INSTALLER" verify --root "$WORK/verifyroot3" >/dev/null 2>&1
fi
if [ -d "$REAL_SKILLS" ]; then
  FP_AFTER="$(node "$WORK/fingerprint.mjs" "$REAL_SKILLS" 2>/dev/null)"
fi
if [ -z "$FP_BEFORE" ] && [ -z "$FP_AFTER" ]; then
  bad "$A24" "真实安装根不存在或不可读（$REAL_SKILLS）—— 不可判定，不判通过"
elif [ "$FP_BEFORE" = "$FP_AFTER" ]; then
  ok "$A24"
else
  CHANGED="$(diff <(printf '%s\n' "$FP_BEFORE") <(printf '%s\n' "$FP_AFTER") 2>/dev/null | head -6 | tr '\n' ' ')"
  bad "$A24" "真实安装根下的文件变了: $CHANGED"
fi

# ---------------------------------------------------------------- AC-025（变异体）

step "AC-025 选样核心逻辑必须被变异体测出差异（8 个变异）"
A25="AC-025 选样核心逻辑必须被变异体测出差异"
if [ "${REQ011_NO_MUT:-0}" = "1" ]; then
  ok "$A25（快跑/嵌套模式：本层跳过变异体套件 —— 8/8 的结论以完整模式为准）"
else
  # ⚠️ D25 ⑪：变异**不得在原地改被验对象** —— 一律在整包的**副本**上注入，
  #    并做注入前后指纹比对（注入未生效即判红：变异没打上 → 校验器放行 → 假 PASS）。
  BASE_KEYS=""
  MUT_TOTAL=0; MUT_DETECTED=0; MUT_ESCAPED=""; MUT_INVALID=""; MUT_POLLUTED=""; MUT_NOTE=""
  # 变异清单：每个变异给若干候选注入方式（正则 → 替换），
  # 依次尝试，取第一个「注入生效 + 变异后仍结构合法 + 变异后仍能正常产出计划」的。
  # 候选锚点全部来自**契约里的字面量**（输出字段名 / 库字段名 / 状态字面量），
  # 不依赖实现内部变量名。
  MUT_NAMES=(
    "选样忽略 case_refs"
    "选样忽略维度信号命中"
    "不做 not_applies_when 检查"
    "选样忽略 status"
    "判不了的变更被悄悄丢弃"
    "坏引用被静默忽略"
    "summary.selected 写成固定值"
    "selected 里塞进不存在的用例 id"
  )
  MUT_CANDS=(
    '(^|\n)([ \t]*)case_refs\s*:[^\n]*'@@@'$1$2case_refs: [],'
    'case_refs\s*:\s*\[[^\]]*\]'@@@'case_refs: []'
    '\.case_refs\b'@@@'.case_refs_MUT'
    '\bcase_refs\b'@@@'case_refs_MUT'
    "['\"]case_refs['\"]"@@@"'case_refs_MUT'"
    '(^|\n)([ \t]*)applies_when\s*:[^\n]*'@@@'$1$2applies_when: [],'
    '\bapplies_when\b'@@@'applies_when_MUT'
    'signal_dimensions\s*:\s*\[[^\]]*\]'@@@'signal_dimensions: []'
    '\.signal_dimensions\b'@@@'.signal_dimensions_MUT'
    '(^|\n)([ \t]*)not_applies_when\s*:[^\n]*'@@@'$1$2not_applies_when: [],'
    '\bnot_applies_when\b'@@@'not_applies_when_MUT'
    'method_hits\s*:\s*\[[^\]]*\]'@@@'method_hits: []'
    '\.method_hits\b'@@@'.method_hits_MUT'
    '([A-Za-z_$][A-Za-z0-9_$]*\.status\s*===\s*.active.)'@@@'true'
    '([A-Za-z_$][A-Za-z0-9_$]*\.status\s*!==\s*.active.)'@@@'false'
    '([A-Za-z_$][A-Za-z0-9_$]*\s*===\s*.active.)'@@@'true'
    "([A-Za-z_\$][A-Za-z0-9_\$]*\\[['\\\"]status['\\\"]\\]\\s*===\\s*['\\\"]active['\\\"])"@@@'true'
    "(\\[['\\\"]status['\\\"]\\]\\s*===\\s*['\\\"]active['\\\"])"@@@'true'
    "([A-Za-z_\$][A-Za-z0-9_\$]*(\\[['\\\"]status['\\\"]\\]|\\.status)\\s*!==\\s*['\\\"]active['\\\"])"@@@'false'
    '(^|\n)([ \t]*)undecidable_changes\s*:[^\n]*'@@@'$1$2undecidable_changes: [],'
    'undecidable_changes\s*:\s*\[[^\]]*\]'@@@'undecidable_changes: []'
    'undecidable_changes\s*:\s*[A-Za-z_$][A-Za-z0-9_$]*'@@@'undecidable_changes: []'
    '\bprocess\.exitCode\s*=\s*1\b'@@@'process.exitCode = 0'
    '\bprocess\.exit\(1\)'@@@'process.exit(0)'
    'selected\s*:\s*[A-Za-z_$][A-Za-z0-9_$]*\.length'@@@'selected: 42'
    'selected\.push\('@@@'selected.push({case_id:"TC-999",reason:"mutant",change_refs:[]},'
    'const\s+selected\s*=\s*\[\]'@@@'const selected = [{case_id:"TC-999",reason:"mutant",change_refs:[]}]'
  )
  # 变异 → 候选下标区间（按上面的顺序切段；D45/G-7：每个变异给**多个**备选锚点，
  # 主锚点不可达时依次尝试；锚点要覆盖等价写法，如 obj.status 与 obj['status']）
  MUT_RANGES=(
    "0 1 2 3 4"
    "5 6 7 8"
    "9 10 11 12"
    "13 14 15 16 17 18"
    "19 20 21"
    "22 23"
    "24"
    "25 26"
  )
  BASE_OUT="$(REQ011_NO_MUT=1 bash "$SELF" "$PKG" 2>&1)"
  BASE_KEYS="$(failkeys "$BASE_OUT")"
  BASE_SIG="$(failsig "$BASE_OUT" "$PKG")"
  MUT_NOTE=""
  if [ -n "$BASE_KEYS" ]; then
    MUT_NOTE="基线本身不绿（失败键: $(printf '%s' "$BASE_KEYS" | tr '\n' ' ')）—— 变异检测以「失败行集合差异」为准"
  fi
  for i in "${!MUT_NAMES[@]}"; do
    NAME="${MUT_NAMES[$i]}"
    RANGE="${MUT_RANGES[$i]}"
    INJECTED=0; USED=""; COPY_CHANGED=0
    for idx in $RANGE; do
      CAND="${MUT_CANDS[$idx]}"
      REGEX="${CAND%%@@@*}"; REPL="${CAND#*@@@}"
      MUTPKG="$WORK/mut-$i"
      mkdir -p "$MUTPKG"
      cp -r "$PKG"/bin "$PKG"/skills "$PKG"/feature-meta "$PKG"/package.json "$PKG"/README.md "$MUTPKG"/ 2>/dev/null
      BEFORE_FP="$(node "$WORK/fingerprint.mjs" "$MUTPKG/skills/regression-plan" 2>/dev/null)"
      MUTRES="$(node "$WORK/mutate.mjs" "$MUTPKG/skills/regression-plan" "$REGEX" "$REPL" 2>/dev/null)"
      CHANGED="$(node -e 'try{console.log(JSON.parse(process.argv[1]).changed)}catch(e){console.log(0)}' "$MUTRES")"
      AFTER_FP="$(node "$WORK/fingerprint.mjs" "$MUTPKG/skills/regression-plan" 2>/dev/null)"
      # 自证 ①（G-9）：注入必须落在**副本**里 —— 副本内目标文件指纹变化
      if [ "${CHANGED:-0}" -eq 0 ] || [ "$BEFORE_FP" = "$AFTER_FP" ]; then
        continue   # 注入未生效 → 换下一个候选（指纹比对是硬要求）
      fi
      COPY_CHANGED=1
      # 自证 ②：语法必须仍然合法（语法错/崩溃 = 假检出，不计入）
      SYNTAX_BAD=0
      for f in "$MUTPKG"/skills/regression-plan/scripts/*.mjs "$MUTPKG"/skills/regression-plan/scripts/lib/*.mjs; do
        [ -f "$f" ] || continue
        node --check "$f" >/dev/null 2>&1 || { SYNTAX_BAD=1; break; }
      done
      [ "$SYNTAX_BAD" -eq 1 ] && continue
      # 自证 ③：变异后的脚本必须还能正常产出计划（崩溃 = 假检出，不计入）
      mkdir -p "$WORK/mutcheck-$i/R2-CHANGELOG-2.3"
      node "$MUTPKG/skills/regression-plan/scripts/plan-regression.mjs" --changelog "$FX/CHANGELOG.md" --cases "$FX/cases.json" --cycle-dir "$WORK/mutcheck-$i/R2-CHANGELOG-2.3" >/dev/null 2>"$WORK/mutcheck-$i.err"
      MUT_RC=$?
      if [ "$MUT_RC" -ne 0 ] || [ ! -s "$WORK/mutcheck-$i/R2-CHANGELOG-2.3/regression-plan.json" ]; then
        continue
      fi
      KEYS_BEFORE="$(node "$WORK/plan-keys.mjs" "$BASE_CYC/regression-plan.json" 2>/dev/null)"
      KEYS_AFTER="$(node "$WORK/plan-keys.mjs" "$WORK/mutcheck-$i/R2-CHANGELOG-2.3/regression-plan.json" 2>/dev/null)"
      [ "$KEYS_BEFORE" = "$KEYS_AFTER" ] || continue
      # 自证 ④（D45 / G-8）：**行为必须真的变了** —— 变异后的计划与基线不同。
      #   计划与基线相同 = 注入后行为等价（例如实现会过滤掉不存在的用例 id）
      #   → 这是**无效变异**，不是逃逸 → 换下一个锚点。
      BEHAVIOR="$(node "$WORK/plan-diff.mjs" "$BASE_CYC/regression-plan.json" "$WORK/mutcheck-$i/R2-CHANGELOG-2.3/regression-plan.json" 2>/dev/null)"
      case "$BEHAVIOR" in
        SAME|"") continue ;;
      esac
      INJECTED=1; USED="$REGEX"
      break
    done
    if [ "$INJECTED" -ne 1 ]; then
      # 无效变异：锚点都不可达 / 语法不合法 / 行为等价 → **不计入分母**，不判红
      MUT_INVALID="$MUT_INVALID [$NAME: 所有候选锚点都不可用（不可达 / 语法不合法 / 行为等价）]"
      continue
    fi
    if [ "$COPY_CHANGED" -ne 1 ]; then
      MUT_INVALID="$MUT_INVALID [$NAME: 没有拿到「注入落在副本上」的证据]"
      continue
    fi
    MUT_TOTAL=$((MUT_TOTAL+1))   # 有效变异数（分母）
    # 跑**本脚本**（嵌套）：护栏必须因为这个变异而多出一条失败
    MUT_OUT="$(REQ011_NO_MUT=1 bash "$SELF" "$MUTPKG" 2>&1)"
    MUT_SIG="$(failsig "$MUT_OUT" "$MUTPKG")"
    if [ "$MUT_SIG" != "$BASE_SIG" ]; then
      MUT_DETECTED=$((MUT_DETECTED+1))
    else
      MUT_ESCAPED="$MUT_ESCAPED [$NAME]"
    fi
  done
  # G-9：被验对象在整个验收过程中不得被改动（起点 = 基线计划跑之前）
  NOW_FP="$(node "$WORK/fingerprint.mjs" "$RP" 2>/dev/null)"
  if [ -n "$RP_FP_START" ] && [ "$RP_FP_START" != "$NOW_FP" ]; then
    MUT_POLLUTED="被验对象 skills/regression-plan/ 在验收过程中被改动（指纹 $RP_FP_START → $NOW_FP）—— 变异必须只在副本上做"
  fi
  # 三种结果分开（D45 / G-8）：逃逸 → 判红；有效变异不足 → 不可判定（不判红也不判绿）
  if [ -n "$MUT_ESCAPED" ]; then
    bad "$A25" "检出 $MUT_DETECTED/$MUT_TOTAL；逃逸:$MUT_ESCAPED；${MUT_NOTE:-}"
  elif [ -n "$MUT_POLLUTED" ]; then
    bad "$A25" "$MUT_POLLUTED"
  elif [ "$MUT_TOTAL" -eq 8 ] && [ "$MUT_DETECTED" -eq 8 ]; then
    ok "$A25（变异检出 $MUT_DETECTED/$MUT_TOTAL）"
  elif [ "$MUT_TOTAL" -lt 8 ]; then
    undec "$A25" "不可判定（有效变异仅 $MUT_TOTAL/8）；无效变异:$MUT_INVALID"
  else
    bad "$A25" "检出 $MUT_DETECTED/$MUT_TOTAL（要求 8/8）；无效变异:$MUT_INVALID"
  fi
fi

# ---------------------------------------------------------------- AC-026（交付侧追溯）

step "AC-026 追溯件必须与实际一致，且不得改写 REQ-006 的追溯件"
A26="AC-026 追溯件必须与实际一致，且不得改写 REQ-006 的追溯件"
A26_PROBLEMS=""
RP_META="$FEATURE_META/regression-plan"
for f in status.md traceability.md verification-report.md manifest.json; do
  [ -s "$RP_META/$f" ] || A26_PROBLEMS="$A26_PROBLEMS [缺 feature-meta/regression-plan/$f 或为空]"
done
# ② 根目录 manifest.json 的 req 必须仍是 REQ-006
ROOT_MANIFEST="$FEATURE_META/manifest.json"
if [ ! -s "$ROOT_MANIFEST" ]; then
  A26_PROBLEMS="$A26_PROBLEMS [缺 feature-meta/manifest.json]"
else
  ROOT_REQ="$(node -e 'try{console.log(String(require(process.argv[1]).req||""))}catch(e){console.log("__ERR__")}' "$ROOT_MANIFEST" 2>/dev/null)"
  [ "$ROOT_REQ" = "REQ-006" ] || A26_PROBLEMS="$A26_PROBLEMS [feature-meta/manifest.json 的 req=$ROOT_REQ，必须仍是 REQ-006]"
fi
# 判据条数（动态）与决策号集合（动态）
AC_ACTUAL=0
[ -f "$ACCEPTANCE" ] && AC_ACTUAL="$(grep -cE '^### AC-' "$ACCEPTANCE" 2>/dev/null || true)"
DEC_SET="$(grep -oE '^\| D[0-9]+' "$DECISIONS" 2>/dev/null | grep -oE 'D[0-9]+' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
DEC_MIN="$(printf '%s' "$DEC_SET" | tr ' ' '\n' | grep -E '^D[0-9]+$' | sed 's/D//' | sort -n | head -1)"
DEC_MAX="$(printf '%s' "$DEC_SET" | tr ' ' '\n' | grep -E '^D[0-9]+$' | sed 's/D//' | sort -n | tail -1)"
# ③ 追溯矩阵行数与编号集合（**动态**：从 acceptance.md 的实际判据集合推导，不得写死）
# ⚠️ D43 订正：此前本子判据把「25 行 / AC-001~AC-025」**写死**，而判据集已增至 28 条 ——
#    模拟实现与脚本**一致地**停在 25 → 干跑仍然全绿（这正是 REQ-005 D25 ⑫ 点名的
#    「两份一致地漏掉一个交付文件时仍会判绿」）。改为动态推导后，判据集一变即判红。
if [ -s "$RP_META/traceability.md" ]; then
  MATRIX_IDS="$(grep -E '^\|[[:space:]]*AC-0[0-9]+' "$RP_META/traceability.md" 2>/dev/null | grep -oE 'AC-[0-9]+' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  MATRIX_ROWS="$(grep -cE '^\|[[:space:]]*AC-0[0-9]+' "$RP_META/traceability.md" 2>/dev/null || true)"
  case "$MATRIX_ROWS" in ''|*[!0-9]*) MATRIX_ROWS=0 ;; esac
  EXPECT_IDS="$(grep -oE '^### (AC-[0-9]+)' "$ACCEPTANCE" 2>/dev/null | grep -oE 'AC-[0-9]+' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  EXPECT_ROWS="$(printf '%s' "$EXPECT_IDS" | tr ' ' '\n' | grep -cE '^AC-[0-9]+$')"
  [ "$MATRIX_ROWS" -eq "$EXPECT_ROWS" ] || A26_PROBLEMS="$A26_PROBLEMS [追溯矩阵行数=$MATRIX_ROWS，要求 $EXPECT_ROWS 行（== acceptance.md 的实际判据条数）]"
  [ "$MATRIX_IDS" = "$EXPECT_IDS" ] || A26_PROBLEMS="$A26_PROBLEMS [追溯矩阵的 AC 编号集合=[$MATRIX_IDS]，要求恰好 [$EXPECT_IDS]]"
fi
# ④ 三份 md 里恰好各有一处「N 条判据」，且 N == acceptance.md 的实际条数
for f in status.md traceability.md verification-report.md; do
  if [ ! -s "$RP_META/$f" ]; then continue; fi
  OCC="$(grep -oE '[0-9]+[[:space:]]*条判据' "$RP_META/$f" 2>/dev/null | wc -l | tr -d ' ')"
  NUM="$(grep -oE '[0-9]+[[:space:]]*条判据' "$RP_META/$f" 2>/dev/null | head -1 | grep -oE '[0-9]+' | head -1)"
  [ "$OCC" = "1" ] || A26_PROBLEMS="$A26_PROBLEMS [$f 里「N 条判据」出现 $OCC 次，要求恰好 1 次]"
  [ "$NUM" = "$AC_ACTUAL" ] || A26_PROBLEMS="$A26_PROBLEMS [$f 的条数声明=$NUM，与 acceptance.md 的实际条数 $AC_ACTUAL 不符]"
done
# ⑤ 三份 md 写明的决策号范围必须与 decisions.md 的实际集合一致
for f in status.md traceability.md verification-report.md; do
  if [ ! -s "$RP_META/$f" ]; then continue; fi
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
' "$RP_META/$f" 2>/dev/null)"
  [ "$MDS" = "$DEC_SET" ] || A26_PROBLEMS="$A26_PROBLEMS [$f 的决策号集合=[$MDS]，与 decisions.md 的实际集合=[$DEC_SET] 不符]"
done
# ⑥ 本 REQ 的 manifest：req == REQ-011，demand_dir 指向的目录真实存在
if [ -s "$RP_META/manifest.json" ]; then
  MY_REQ="$(node -e 'try{console.log(String(require(process.argv[1]).req||""))}catch(e){console.log("__ERR__")}' "$RP_META/manifest.json" 2>/dev/null)"
  [ "$MY_REQ" = "REQ-011" ] || A26_PROBLEMS="$A26_PROBLEMS [feature-meta/regression-plan/manifest.json 的 req=$MY_REQ，要求 REQ-011]"
  MY_DD="$(node -e 'try{console.log(String(require(process.argv[1]).demand_dir||""))}catch(e){console.log("")}' "$RP_META/manifest.json" 2>/dev/null)"
  if [ -z "$MY_DD" ]; then
    A26_PROBLEMS="$A26_PROBLEMS [manifest.json 没有 demand_dir]"
  else
    case "$MY_DD" in
      /*) DD_ABS="$MY_DD" ;;
      *) DD_ABS="$DEMAND_ROOT/$MY_DD" ;;
    esac
    [ -d "$DD_ABS" ] || A26_PROBLEMS="$A26_PROBLEMS [demand_dir=$MY_DD 指向的目录不存在: $DD_ABS]"
  fi
fi
if [ -z "$A26_PROBLEMS" ]; then ok "$A26"; else bad "$A26" "$A26_PROBLEMS"; fi

# ---------------------------------------------------------------- AC-027（实现约束）

step "AC-027 零第三方依赖 + 可移植（不联网）"
A27="AC-027 零第三方依赖 + 可移植（不联网）"
A27_PROBLEMS=""
SCAN_RP="$(node "$WORK/scan.mjs" "$RP" 2>/dev/null)"
TP_RP="$(node -e 'try{const o=JSON.parse(process.argv[1]);console.log((o.thirdParty||[]).length)}catch(e){console.log(-1)}' "$SCAN_RP")"
NET_RP="$(node -e 'try{const o=JSON.parse(process.argv[1]);console.log((o.network||[]).length)}catch(e){console.log(-1)}' "$SCAN_RP")"
[ "${TP_RP:-1}" -eq 0 ] || A27_PROBLEMS="$A27_PROBLEMS [\$RP 里的非内置 import: $(node -e 'try{const o=JSON.parse(process.argv[1]);console.log((o.thirdParty||[]).slice(0,3).join(" ; "))}catch(e){console.log("解析失败")}' "$SCAN_RP")]"
[ "${NET_RP:-1}" -eq 0 ] || A27_PROBLEMS="$A27_PROBLEMS [\$RP 里的网络调用: $(node -e 'try{const o=JSON.parse(process.argv[1]);console.log((o.network||[]).slice(0,3).join(" ; "))}catch(e){console.log("解析失败")}' "$SCAN_RP")]"
# ③ bin/ 下「本次新增的组合门实现文件」= 必然读写 skill-meta 的 .mjs
#    D45（G-5 / P-16）：识别规则放宽到等价写法 —— 同时含「skill 标记」与「skill-meta / meta.json 标记」
#    （覆盖 ['skill','meta.json'].join('-') 这类拼接）；不把 bin/qa-impl.mjs 误认进来（它两者皆无）。
BIN_GATE_FILES="$(node "$WORK/gate-files.mjs" "$BINDIR" 2>/dev/null)"
BIN_GATE_COUNT="$(node -e 'try{console.log(JSON.parse(process.argv[1]).length)}catch(e){console.log(0)}' "$BIN_GATE_FILES" 2>/dev/null)"
case "$BIN_GATE_COUNT" in ''|*[!0-9]*) BIN_GATE_COUNT=0 ;; esac
if [ "$BIN_GATE_COUNT" -eq 0 ]; then
  A27_PROBLEMS="$A27_PROBLEMS [bin/ 下没有识别到组合门实现文件（含 skill 标记 + skill-meta/meta.json 标记的 .mjs）]"
else
  SCAN_BIN="$(node "$WORK/scan.mjs" "$BIN_GATE_FILES" 2>/dev/null)"
  TP_BIN="$(node -e 'try{const o=JSON.parse(process.argv[1]);console.log((o.thirdParty||[]).length)}catch(e){console.log(-1)}' "$SCAN_BIN")"
  NET_BIN="$(node -e 'try{const o=JSON.parse(process.argv[1]);console.log((o.network||[]).length)}catch(e){console.log(-1)}' "$SCAN_BIN")"
  [ "${TP_BIN:-1}" -eq 0 ] || A27_PROBLEMS="$A27_PROBLEMS [组合门实现里的非内置 import: $(node -e 'try{const o=JSON.parse(process.argv[1]);console.log((o.thirdParty||[]).slice(0,3).join(" ; "))}catch(e){console.log("解析失败")}' "$SCAN_BIN")]"
  [ "${NET_BIN:-1}" -eq 0 ] || A27_PROBLEMS="$A27_PROBLEMS [组合门实现里的网络调用: $(node -e 'try{const o=JSON.parse(process.argv[1]);console.log((o.network||[]).slice(0,3).join(" ; "))}catch(e){console.log("解析失败")}' "$SCAN_BIN")]"
fi
if [ -z "$A27_PROBLEMS" ]; then ok "$A27"; else bad "$A27" "$A27_PROBLEMS"; fi

# ---------------------------------------------------------------- AC-028（SKILL.md）

step "AC-028 SKILL.md 必须把影响面判定落在脚本上"
A28="AC-028 SKILL.md 必须把影响面判定落在脚本上"
A28_PROBLEMS=""
SK="$RP/SKILL.md"
if [ ! -s "$SK" ]; then
  A28_PROBLEMS="缺 $SK"
else
  # D45（G-10）：①「文件提及」（非命令语境）与 ②「可执行调用」（带参数）**互斥** → 可分别证伪
  MENT="$(node "$WORK/skill-mentions.mjs" "$SK" plan-regression.mjs check-plan.mjs 2>/dev/null)"
  ment_field() { node -e 'try{const o=JSON.parse(process.argv[1]);const v=o[process.argv[2]]||{};console.log(Number(v[process.argv[3]]||0))}catch(e){console.log(0)}' "$1" "$2" "$3"; }
  MP_M="$(ment_field "$MENT" plan-regression.mjs mentions)"
  MP_C="$(ment_field "$MENT" plan-regression.mjs callsWithArgs)"
  MC_M="$(ment_field "$MENT" check-plan.mjs mentions)"
  MC_C="$(ment_field "$MENT" check-plan.mjs callsWithArgs)"
  [ "${MP_M:-0}" -ge 1 ] || A28_PROBLEMS="$A28_PROBLEMS [没有在非命令语境里提到 plan-regression.mjs（只出现在命令里不算"提到"）]"
  [ "${MC_M:-0}" -ge 1 ] || A28_PROBLEMS="$A28_PROBLEMS [没有在非命令语境里提到 check-plan.mjs（只出现在命令里不算"提到"）]"
  [ "${MP_C:-0}" -ge 1 ] || A28_PROBLEMS="$A28_PROBLEMS [没有可执行的调用序列 node scripts/plan-regression.mjs --<参数>]"
  [ "${MC_C:-0}" -ge 1 ] || A28_PROBLEMS="$A28_PROBLEMS [没有可执行的调用序列 node scripts/check-plan.mjs --<参数>]"
  FORBIDDEN="$(grep -cE '自行判断影响面|人工分析后手写|由 agent 推断|自行推断受影响用例|手工写[[:space:]]*`?regression-plan\.json' "$SK" 2>/dev/null || true)"
  [ "${FORBIDDEN:-0}" -eq 0 ] || A28_PROBLEMS="$A28_PROBLEMS [出现了让 agent 自行判断影响面的措辞（$FORBIDDEN 处）]"
  # 三类后果各是什么
  grep -q 'selected' "$SK" 2>/dev/null || A28_PROBLEMS="$A28_PROBLEMS [没有写清 selected 的后果]"
  grep -q 'needs_review' "$SK" 2>/dev/null || A28_PROBLEMS="$A28_PROBLEMS [没有写清 needs_review 的后果]"
  grep -q 'undecidable_changes' "$SK" 2>/dev/null || A28_PROBLEMS="$A28_PROBLEMS [没有写清 undecidable_changes 的后果]"
  grep -q '重跑' "$SK" 2>/dev/null || A28_PROBLEMS="$A28_PROBLEMS [没有写清 selected = 确定重跑]"
  grep -q '复核' "$SK" 2>/dev/null || A28_PROBLEMS="$A28_PROBLEMS [没有写清 needs_review = 需人工复核]"
  grep -q '判不了' "$SK" 2>/dev/null || A28_PROBLEMS="$A28_PROBLEMS [没有写清 undecidable_changes = 判不了]"
  # 判不了不得当成没影响
  JUDGE="$(grep -cE '判不了[^。；\n]*(不得当成|不等于|不能当成|不得当作)[^。；\n]*(没影响|无影响|没有影响)' "$SK" 2>/dev/null || true)"
  [ "${JUDGE:-0}" -ge 1 ] || A28_PROBLEMS="$A28_PROBLEMS [没有写清「判不了不得当成没影响」]"
fi
if [ -z "$A28_PROBLEMS" ]; then ok "$A28"; else bad "$A28" "$A28_PROBLEMS"; fi

# ---------------------------------------------------------------- 结论

EVAL_COUNT=$((PASS + FAIL + UNDEC))
if [ "$EVAL_COUNT" -ne "$AC_COUNT" ]; then
  printf '\n⚠️ 判据条数不符：本脚本评了 %s 条，acceptance.md 的 `### AC-` 实际条数是 %s 条\n' "$EVAL_COUNT" "$AC_COUNT"
  FAIL=$((FAIL+1))
fi
printf '\n结论: %s PASS / %s FAIL / %s 不可判定\n' "$PASS" "$FAIL" "$UNDEC"
if [ "$FAIL" -eq 0 ] && [ "$UNDEC" -eq 0 ]; then
  exit 0
fi
exit 1
