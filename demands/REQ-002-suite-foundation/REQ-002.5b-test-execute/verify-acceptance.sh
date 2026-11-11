#!/usr/bin/env bash
# REQ-002.5b 验收脚本 —— 执行 skill 与证据链
#
# 用法: verify-acceptance.sh <test-execute-dir> <test-case-design-dir>
#   test-execute-dir      skills/test-execute/ 的路径
#   test-case-design-dir  skills/test-case-design/ 的路径（断言对象校验要用它的 validate-cases.mjs）
#
# 退出码: 0 = 全部通过; 1 = 有 AC 未通过
#
# 设计说明:
#   - mock 执行器的**启用机制**由实现方选择（executor 枚举 / 环境配置 driver / 命令行覆盖），
#     本脚本自适应探测: 三种都试，哪个能跑通用哪个。验收的是「离线可跑」这个能力本身。
#   - 只读 skill 目录，测试项目一律造在临时目录里。

set -uo pipefail

TE="${1:?用法: verify-acceptance.sh <test-execute-dir> <test-case-design-dir>}"
TCD="${2:?用法: verify-acceptance.sh <test-execute-dir> <test-case-design-dir>}"
TE="$(cd "$TE" 2>/dev/null && pwd)" || { echo "目录不存在: $1" >&2; exit 2; }
TCD="$(cd "$TCD" 2>/dev/null && pwd)" || { echo "目录不存在: $2" >&2; exit 2; }

EX="$TE/scripts"
VC="$TCD/scripts/validate-cases.mjs"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qa-0025b-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0; FAILED_LIST=()
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED_LIST+=("$1"); printf '  \033[31mFAIL\033[0m  %s\n     ↳ %s\n' "$1" "${2:-}"; }
step(){ printf '\n\033[36m— %s\033[0m\n' "$1"; }

jget() { node -e '
  const fs=require("fs");
  const [file,...path]=process.argv.slice(1);
  let o; try{o=JSON.parse(fs.readFileSync(file,"utf8"));}catch(e){console.log("__PARSE_ERR__");process.exit(0);}
  for(const p of path){ if(o===undefined||o===null){console.log("__UNDEF__");process.exit(0);} o=o[p]; }
  console.log(typeof o==="object"?JSON.stringify(o):String(o));
' "$@"; }

# ---------------------------------------------------------------- 项目与样例
# 造一个符合 REQ-002B 契约的完整项目
make_project() {
  local P="$1"
  mkdir -p "$P/test-assets/environments" "$P/test-assets/suites/REQ-001-coupon" "$P/test-assets/cycles/R1-REQ-001"
  printf '# 测试资产\n' > "$P/test-assets/README.md"
  cat > "$P/test-assets/environments/_schema.json" <<'EOF'
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
  cat > "$P/test-assets/environments/local.json" <<'EOF'
{ "name":"local","base_url":"http://127.0.0.1:9","timeout_ms":5000,"retries":0,
  "credentials":{"username_env":"LOCAL_USER","password_env":"LOCAL_PASS"},"verify_tls":false }
EOF
  cat > "$P/test-assets/suites/REQ-001-coupon/suite.json" <<'EOF'
{ "suite":"REQ-001-coupon","requirement":"REQ-001","scope":"functional","environment":"local",
  "cases_file":"cases.json","executor":"api" }
EOF
  cat > "$P/test-assets/cycles/R1-REQ-001/cycle.json" <<'EOF'
{ "cycle_id":"R1-REQ-001","round":"R1","round_type":"new-requirement","requirement":"REQ-001",
  "scopes":["functional"],"scopes_skipped":[],"status":"in_progress",
  "stages":{"clarify":{"status":"done"},"design":{"status":"done"},"execute":{"status":"pending"}},
  "history":[{"at":"2026-11-11T18:00:00+08:00","from":"planned","to":"in_progress","by":"seed"}] }
EOF
  cat > "$P/test-assets/cycles/index.json" <<'EOF'
{ "cycles":[{"id":"R1-REQ-001","round":"R1","status":"in_progress","cases_total":0,"cases_passed":0,"bugs_found":0}] }
EOF
  printf '.test-artifacts/\n' > "$P/.gitignore"
}

# 造一个 v2 用例集：$1=输出文件 $2=cases 的 JSON 数组
make_cases() {
  local f="$1" cases="$2"
  local n
  n="$(printf '%s' "$cases" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).length)}catch(e){console.log(0)}})')"
  printf '{\n  "schema_version": 2,\n  "meta": { "source": "qa-0025b", "generated_at": "2026-11-11T18:00:00+08:00", "case_count": %s },\n  "requirements": [ { "id": "R-1", "title": "下单", "source_ref": "x", "testable": true } ],\n  "open_questions": [],\n  "coverage_matrix": [ { "requirement": "R-1", "methods_applied": ["M0.1"], "skipped": [], "dimensions": ["functional"] } ],\n  "cases": %s\n}\n' "$n" "$cases" > "$f"
}

# 造一条用例：$1=id $2=title $3=steps 的 JSON 数组
mkcase() {
  printf '{ "id": "%s", "title": "%s", "requirement_refs": ["R-1"], "dimension": "functional", "priority": "P0", "method": ["M0.1"], "status": "active", "steps": %s }' "$1" "$2" "$3"
}

# 一条通过的用例（单步）
CASE_OK="$(mkcase TC-001 正常下单 '[ { "action": "GET /ok", "expected": { "path": "$.status", "op": "equals", "expected": "ok" } } ]')"
# 一条失败的单步用例：请求打 /notfound（404），却期望 status 为 ok
CASE_FAIL="$(mkcase TC-002 故意失败 '[ { "action": "GET /notfound", "expected": { "path": "$.status", "op": "equals", "expected": "ok" } } ]')"
# 一条多步用例：第 1 步断言成立，第 2 步断言不成立 —— 必须判 failed，绝不能判 passed
CASE_MULTI="$(mkcase TC-003 多步用例 '[ { "action": "GET /ok", "expected": { "path": "$.status", "op": "equals", "expected": "ok" } }, { "action": "GET /notfound", "expected": { "path": "$.status", "op": "equals", "expected": "ok" } } ]')"
# 一条打 /token 的用例（脱敏用）
CASE_TOKEN="$(mkcase TC-001 取令牌 '[ { "action": "GET /token", "expected": { "path": "$.id", "op": "equals", "expected": 1 } } ]')"

# ---------------------------------------------------------------- AC-001
step "AC-001 test-execute skill 目录结构完整"
MISS=""
for p in SKILL.md references scripts executors/index.json; do
  [ -e "$TE/$p" ] || MISS="$MISS $p"
done
FM="$(head -3 "$TE/SKILL.md" 2>/dev/null | grep -c '^---')"
if [ -z "$MISS" ] && [ "$FM" -ge 1 ]; then
  ok "AC-001 test-execute skill 目录结构完整"
else
  bad "AC-001 test-execute skill 目录结构完整" "缺:$MISS frontmatter=$FM"
fi

# ---------------------------------------------------------------- AC-002
step "AC-002 执行器注册表声明可配置项与边界"
IDX="$TE/executors/index.json"
if [ ! -f "$IDX" ]; then
  bad "AC-002 执行器注册表声明可配置项与边界" "缺 executors/index.json"
else
  DECL="$(node -e '
  const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const list=Array.isArray(o)?o:(o.executors||o.tools||[]);
  if(!Array.isArray(list)||!list.length){console.log("EMPTY");process.exit(0);}
  const need=["request","assertions","extract","auth","timeout_ms","retries"];
  let allHave=true, hasBoundary=false;
  for(const e of list){
    const cfg=JSON.stringify(e.configurable||e.config||e.supported||[]);
    if(!need.every(k=>cfg.includes(k))) allHave=false;
    if(e.not_supported||e.unsupported||e.limits) hasBoundary=true;
  }
  console.log((allHave?"CFG_OK":"CFG_MISS")+(hasBoundary?" BND_OK":" BND_MISS"));
  ' "$IDX")"
  case "$DECL" in
    CFG_OK*BND_OK) ok "AC-002 执行器注册表声明可配置项与边界" ;;
    *) bad "AC-002 执行器注册表声明可配置项与边界" "$DECL（需 CFG_OK + BND_OK）" ;;
  esac
fi

# ---------------------------------------------------------------- AC-003
step "AC-003 执行器实现不可被 agent 修改（硬约束）"
# 三类词必须出现在**同一行**：禁止词(不得/禁止/不允许) + 改动词(修改/改写/编辑/改动) + 执行器。
# 早先的写法要求「不得修改」后面紧跟「执行器」，措辞一变就漏判 —— 那是脚本的脆弱，不是契约的。
LOCK="$(grep -E "不得|禁止|不允许" "$TE/SKILL.md" 2>/dev/null \
        | grep -E "修改|改写|编辑|改动" \
        | grep -c -E "执行器|executors")"
if [ "$LOCK" -ge 1 ]; then
  ok "AC-003 执行器实现不可被 agent 修改（硬约束）"
else
  bad "AC-003 执行器实现不可被 agent 修改（硬约束）" "SKILL.md 未见不可修改约束（命中 $LOCK）"
fi

# ---------------------------------------------------------------- AC-004b~004e（断言载体，走 validate-cases）
step "AC-004b/004d/004e 断言载体 —— expected 支持结构化断言对象"
REG2A="$(cd "$(dirname "$0")" && pwd)/../REQ-002A-schema-v2/verify-regression-002a.sh"
if [ -f "$REG2A" ]; then
  bash "$REG2A" "$TCD" > "$WORK/reg2a.log" 2>&1
  if [ $? -eq 0 ]; then
    ok "AC-004b/004d/004e 断言载体（REQ-002A 回归全绿）"
  else
    bad "AC-004b/004d/004e 断言载体（REQ-002A 回归全绿）" "$(tail -6 "$WORK/reg2a.log" | tr '\n' ' ')"
  fi
else
  bad "AC-004b/004d/004e 断言载体（REQ-002A 回归全绿）" "找不到 REQ-002A 回归脚本"
fi

# ---------------------------------------------------------------- AC-005
step "AC-005 判定口径由执行外壳统一"
VERDICT_IN_EXEC="$(grep -l -E "['\"]passed['\"]|['\"]failed['\"]" "$TE"/executors/*.mjs 2>/dev/null | wc -l)"
if [ "$VERDICT_IN_EXEC" -eq 0 ]; then
  ok "AC-005 判定口径由执行外壳统一"
else
  bad "AC-005 判定口径由执行外壳统一" "$VERDICT_IN_EXEC 个执行器文件里出现了 passed/failed 字面量"
fi

# ---------------------------------------------------------------- 执行（离线 mock）
step "准备离线 mock 执行场景"
make_project "$WORK/proj"
# 场景里同时有：一条通过、一条失败（供 AC-018 验证复现信息）。
# 凭证环境变量必须给上 —— 否则用例判 blocked，根本不会发请求，
# 证据目录是空的，AC-009/010/011 的篡改检测就无从谈起（假通过）。
export LOCAL_USER="qa-local-user"
export LOCAL_PASS="qa-local-pass"
make_cases "$WORK/proj/test-assets/suites/REQ-001-coupon/cases.json" "[ $CASE_OK, $CASE_FAIL ]"

# mock 的启用方式**按 D16 写死一种**：环境配置的 `driver` 字段。
# 早先这里做"三路自适应探测"，是验收方不该有的自由度 —— 契约必须唯一，
# 否则实现方改掉任一种写法，验收仍会通过（契约与实现可以悄悄分叉）。
MOCK_MODE=""
detect_mock() {
  node -e '
  const fs=require("fs"),f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));
  o.driver="mock";fs.writeFileSync(f,JSON.stringify(o,null,2));
  ' "$WORK/proj/test-assets/environments/local.json" 2>/dev/null
  if run_suite "$WORK/proj" >/dev/null 2>&1; then MOCK_MODE="env-driver"; return; fi
  MOCK_MODE=""
}

RUN_DIR=""
run_suite() {
  local proj="$1"; shift
  local out
  out="$(cd "$proj" && node "$EX/run-suite.mjs" "$proj/test-assets/suites/REQ-001-coupon/suite.json" "$@" 2>&1)"
  local rc=$?
  # 从输出里找 run_id
  local rid
  rid="$(printf '%s' "$out" | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    const m=s.match(/run_id["\x27:=\s]+([A-Za-z0-9._-]+)/);
    console.log(m?m[1]:"");
  });')"
  if [ -n "$rid" ] && [ -d "$proj/.test-artifacts/$rid" ]; then
    RUN_DIR="$proj/.test-artifacts/$rid"; return 0
  fi
  # 兜底: 目录里最新的一个
  rid="$(ls -t "$proj/.test-artifacts" 2>/dev/null | head -1)"
  if [ -n "$rid" ] && [ -d "$proj/.test-artifacts/$rid" ]; then
    RUN_DIR="$proj/.test-artifacts/$rid"; return 0
  fi
  return 1
}

detect_mock
if [ -n "$MOCK_MODE" ] && [ -n "$RUN_DIR" ]; then
  ok "AC-014 离线可跑 —— mock 执行器跑通完整链路（启用方式: $MOCK_MODE）"
else
  bad "AC-014 离线可跑 —— mock 执行器跑通完整链路" "按契约（环境配置 driver=mock，D16）未跑通"
fi

# ---------------------------------------------------------------- AC-008
step "AC-008 证据链结构完整"
if [ -z "$RUN_DIR" ]; then
  bad "AC-008 证据链结构完整" "无 run 目录"
else
  M="$RUN_DIR/meta.json"; R="$RUN_DIR/results.json"
  MISS=""
  [ -f "$M" ] || MISS="$MISS meta.json"
  [ -f "$R" ] || MISS="$MISS results.json"
  for k in run_id suite scope requirement environment started_at finished_at duration_ms agent executor tool_versions cases_total cases_passed cases_failed cases_blocked cases_skipped; do
    jget "$M" "$k" 2>/dev/null | grep -q '__UNDEF__' && MISS="$MISS meta.$k"
  done
  [ -z "$MISS" ] && ok "AC-008 证据链结构完整" || bad "AC-008 证据链结构完整" "缺:$MISS"
fi

# ---------------------------------------------------------------- AC-018
step "AC-018 失败用例必须有复现信息"
if [ -z "$RUN_DIR" ]; then
  bad "AC-018 失败用例必须有复现信息" "无 run 目录"
else
  REPRO="$(node -e '
  const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const arr=Array.isArray(o)?o:(o.results||o.cases||[]);
  const failed=arr.filter(c=>c.status==="failed");
  if(!failed.length){console.log("NO_FAILED");process.exit(0);}
  const okAll=failed.every(c=>c.reproduction && Array.isArray(c.reproduction.steps) && c.reproduction.steps.length>0);
  console.log(okAll?"REPRO_OK":"REPRO_MISS");
  ' "$RUN_DIR/results.json" 2>/dev/null)"
  case "$REPRO" in
    REPRO_OK) ok "AC-018 失败用例必须有复现信息" ;;
    NO_FAILED) bad "AC-018 失败用例必须有复现信息" "场景里没有失败用例，无法验证" ;;
    *) bad "AC-018 失败用例必须有复现信息" "REPRO_MISS" ;;
  esac
fi

# ---------------------------------------------------------------- AC-009 / 010 / 011
step "AC-009/010/011 证据篡改检测"
if [ -z "$RUN_DIR" ] || [ ! -f "$EX/verify-evidence.mjs" ]; then
  bad "AC-009/010/011 证据篡改检测" "无 run 目录或缺 verify-evidence.mjs"
else
  VE="$EX/verify-evidence.mjs"
  node "$VE" "$RUN_DIR" >/dev/null 2>&1; RC0=$?
  # 篡改一个 evidence 文件
  EVF="$(find "$RUN_DIR/evidence" -type f 2>/dev/null | head -1)"
  if [ -n "$EVF" ]; then
    cp "$EVF" "$WORK/ev.bak"; printf 'x' >> "$EVF"
    node "$VE" "$RUN_DIR" >/dev/null 2>&1; RC1=$?
    cp "$WORK/ev.bak" "$EVF"
  else
    RC1="NOEVIDENCE"
  fi
  # 删除一个 evidence 文件
  if [ -n "$EVF" ]; then
    mv "$EVF" "$WORK/ev.moved"
    node "$VE" "$RUN_DIR" >/dev/null 2>&1; RC2=$?
    mv "$WORK/ev.moved" "$EVF"
  else
    RC2="NOEVIDENCE"
  fi
  # 篡改 results.json
  cp "$RUN_DIR/results.json" "$WORK/res.bak"
  node -e 'const fs=require("fs"),f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));const a=Array.isArray(o)?o:(o.results||o.cases||[]);if(a[0])a[0].status="failed";fs.writeFileSync(f,JSON.stringify(o,null,2));' "$RUN_DIR/results.json"
  node "$VE" "$RUN_DIR" >/dev/null 2>&1; RC3=$?
  cp "$WORK/res.bak" "$RUN_DIR/results.json"
  # 篡改 meta.json 计数
  cp "$RUN_DIR/meta.json" "$WORK/meta.bak"
  node -e 'const fs=require("fs"),f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));o.cases_total=999;fs.writeFileSync(f,JSON.stringify(o,null,2));' "$RUN_DIR/meta.json"
  node "$VE" "$RUN_DIR" >/dev/null 2>&1; RC4=$?
  cp "$WORK/meta.bak" "$RUN_DIR/meta.json"
  node "$VE" "$RUN_DIR" >/dev/null 2>&1; RC5=$?

  if [ $RC0 -eq 0 ] && [ "$RC1" = "1" ] && [ "$RC2" = "1" ] && [ "$RC3" = "1" ] && [ "$RC4" = "1" ] && [ $RC5 -eq 0 ]; then
    ok "AC-009/010/011 证据篡改检测（改文件/删文件/改 results/改计数 四类均被发现）"
  else
    bad "AC-009/010/011 证据篡改检测" "基线=$RC0 改文件=$RC1 删文件=$RC2 改results=$RC3 改计数=$RC4 恢复后=$RC5"
  fi
fi

# ---------------------------------------------------------------- AC-019 / AC-020
# 多步用例：必须逐步执行、逐步判定。
# 这是本 REQ 最容易出"虚报通过"的地方 —— 只跑第一步、把后面步骤的断言
# 拿第一个响应当判据，会让"半个用例"报 passed。
# 客观判据：每一步都要有一份证据（证明请求真的发出去了），且判定要落在正确的步骤上。
step "AC-019/020 多步用例逐步执行、逐步判定"
D19="$WORK/ac019"; make_project "$D19"
# TC-003: 第 1 步成立、第 2 步不成立 → 必须 failed
# TC-004: 两步都成立 → 必须 passed
CASE_MULTI2="$(mkcase TC-004 多步全通过 '[ { "action": "GET /ok", "expected": { "path": "$.status", "op": "equals", "expected": "ok" } }, { "action": "GET /created", "expected": { "path": "$.status", "op": "equals", "expected": "created" } } ]')"
make_cases "$D19/test-assets/suites/REQ-001-coupon/cases.json" "[ $CASE_MULTI, $CASE_MULTI2 ]"
node -e '
const fs=require("fs"),f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));
o.driver="mock";fs.writeFileSync(f,JSON.stringify(o,null,2));
' "$D19/test-assets/environments/local.json"
if run_suite "$D19" >/dev/null 2>&1 && [ -n "$RUN_DIR" ]; then
  M19="$(node -e '
  const fs=require("fs");
  const o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  const arr=Array.isArray(o)?o:(o.results||o.cases||[]);
  const get=(id)=>arr.find(c=>c.case_id===id||c.id===id)||{};
  const tc3=get("TC-003"), tc4=get("TC-004");
  const evCount=(c)=>Array.isArray(c.evidence)?c.evidence.length:0;
  console.log(JSON.stringify({
    s3:tc3.status||"NONE", e3:evCount(tc3),
    s4:tc4.status||"NONE", e4:evCount(tc4),
    t3:tc3.error&&tc3.error.type||null
  }));
  ' "$RUN_DIR/results.json" 2>/dev/null)"
  S3="$(printf '%s' "$M19" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).s3)}catch(e){console.log("PARSE_ERR")}})')"
  E3="$(printf '%s' "$M19" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).e3)}catch(e){console.log(0)}})')"
  S4="$(printf '%s' "$M19" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).s4)}catch(e){console.log("PARSE_ERR")}})')"
  E4="$(printf '%s' "$M19" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).e4)}catch(e){console.log(0)}})')"
  A19=0; A20=0
  # 第 2 步断言不成立 → 必须判 failed，且两步都有证据（证明两个请求都发了）
  [ "$S3" = "failed" ] && [ "$E3" -ge 2 ] && A19=1
  # 两步都成立 → 判 passed，且同样要有两步证据
  [ "$S4" = "passed" ] && [ "$E4" -ge 2 ] && A20=1
  if [ $A19 -eq 1 ]; then
    ok "AC-019 多步用例逐步判定（第 2 步断言不成立 → failed，两步各有证据）"
  else
    bad "AC-019 多步用例逐步判定" "TC-003 status=$S3 证据数=$E3（期望 failed 且证据>=2 —— 只跑首步会得到 passed）"
  fi
  if [ $A20 -eq 1 ]; then
    ok "AC-020 多步用例全通过（passed，两步各有证据）"
  else
    bad "AC-020 多步用例全通过" "TC-004 status=$S4 证据数=$E4（期望 passed 且证据>=2）"
  fi
else
  bad "AC-019 多步用例逐步判定" "执行未产出结果"
  bad "AC-020 多步用例全通过" "执行未产出结果"
fi

# ---------------------------------------------------------------- AC-021 / AC-022
# D20/D21：显式用例级载体 + step 级请求，是原 P0「半个用例报通过」的**另一个入口**。
# 场景：用例声明 request=GET /ok，steps 却是两条不同端点的可执行步骤。
#       实现若丢掉 step 级请求，后续 step 的断言会被拿去判那一次响应 → 报 passed。
step "AC-021/022 载体冲突判 blocked + 复现信息如实"
D21="$WORK/ac021"; make_project "$D21"
# 场景 A：端点不一致 → 必须 blocked（不得 passed）
cat > "$D21/test-assets/suites/REQ-001-coupon/cases.json" <<'CASE21'
{ "schema_version": 2, "meta": {"source":"qa-0025b","generated_at":"2026-11-11T18:00:00+08:00","case_count":1},
  "requirements":[{"id":"R-1","title":"多端点","source_ref":"x","testable":true}], "open_questions": [],
  "coverage_matrix":[{"requirement":"R-1","methods_applied":["M0.1"],"skipped":[],"dimensions":["functional"]}],
  "cases":[{"id":"TC-001","title":"载体冲突","requirement_refs":["R-1"],"dimension":"functional","priority":"P0","method":["M0.1"],"status":"active",
    "request":{"method":"GET","path":"/ok"},
    "steps":[
      {"action":"GET /ok","expected":{"path":"$.status","op":"equals","expected":"ok"}},
      {"action":"GET /notfound","expected":{"path":"$.status","op":"equals","expected":"ok"}}
    ]}]}
CASE21
node -e '
const fs=require("fs"),f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));
o.driver="mock";fs.writeFileSync(f,JSON.stringify(o,null,2));
' "$D21/test-assets/environments/local.json"
S21="NOPROJ"; EV21=0; RP21=""
if run_suite "$D21" >/dev/null 2>&1 && [ -n "$RUN_DIR" ]; then
  S21="$(node -e '
  const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const a=Array.isArray(o)?o:(o.results||o.cases||[]);
  console.log(a.length?(a[0].status||"NONE"):"NO_CASES");
  ' "$RUN_DIR/results.json" 2>/dev/null)"
  EV21="$(find "$RUN_DIR/evidence" -type f 2>/dev/null | wc -l)"
  RP21="$(node -e '
  const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const a=Array.isArray(o)?o:(o.results||o.cases||[]);
  const r=a[0]||{};const s=r.reproduction&&Array.isArray(r.reproduction.steps)?r.reproduction.steps:[];
  console.log(s.length);
  ' "$RUN_DIR/results.json" 2>/dev/null)"
fi
# 必须同时校验 error.type：冲突被误诊成 incomplete 时 status 仍是 blocked，
# 只判 status 会放过去（独立验收 M9：误诊 → 脚本仍 23/0 全绿）
T21="$(node -e '
  const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const a=Array.isArray(o)?o:(o.results||o.cases||[]);
  const r=a[0]||{};
  console.log(r.error&&r.error.type?r.error.type:"NONE");
' "$RUN_DIR/results.json" 2>/dev/null)"
if [ "$S21" = "blocked" ] && [ "$T21" = "conflicting_request_carrier" ]; then
  ok "AC-021 载体冲突判 blocked（error.type=conflicting_request_carrier，不得判 passed）"
else
  bad "AC-021 载体冲突判 blocked" "status=$S21 error.type=$T21（期望 blocked + conflicting_request_carrier）"
fi

# 场景 B：端点一致 → 视为同一次请求，证据条数必须与复现步骤数一致
D22="$WORK/ac022"; make_project "$D22"
cat > "$D22/test-assets/suites/REQ-001-coupon/cases.json" <<'CASE22'
{ "schema_version": 2, "meta": {"source":"qa-0025b","generated_at":"2026-11-11T18:00:00+08:00","case_count":1},
  "requirements":[{"id":"R-1","title":"同端点","source_ref":"x","testable":true}], "open_questions": [],
  "coverage_matrix":[{"requirement":"R-1","methods_applied":["M0.1"],"skipped":[],"dimensions":["functional"]}],
  "cases":[{"id":"TC-001","title":"同端点重复描述","requirement_refs":["R-1"],"dimension":"functional","priority":"P0","method":["M0.1"],"status":"active",
    "request":{"method":"GET","path":"/ok"},
    "steps":[
      {"action":"GET /ok","expected":{"path":"$.status","op":"equals","expected":"ok"}},
      {"action":"GET /ok","expected":{"path":"$.status","op":"equals","expected":"ok"}}
    ]}]}
CASE22
node -e '
const fs=require("fs"),f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));
o.driver="mock";fs.writeFileSync(f,JSON.stringify(o,null,2));
' "$D22/test-assets/environments/local.json"
S22="NOPROJ"; EV22=0; RP22=""
if run_suite "$D22" >/dev/null 2>&1 && [ -n "$RUN_DIR" ]; then
  S22="$(node -e '
  const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const a=Array.isArray(o)?o:(o.results||o.cases||[]);
  console.log(a.length?(a[0].status||"NONE"):"NO_CASES");
  ' "$RUN_DIR/results.json" 2>/dev/null)"
  EV22="$(find "$RUN_DIR/evidence" -type f 2>/dev/null | wc -l)"
  RP22="$(node -e '
  const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const a=Array.isArray(o)?o:(o.results||o.cases||[]);
  const r=a[0]||{};const s=r.reproduction&&Array.isArray(r.reproduction.steps)?r.reproduction.steps:[];
  console.log(s.length);
  ' "$RUN_DIR/results.json" 2>/dev/null)"
fi
if [ "$S22" != "blocked" ] && [ "${EV22:-0}" -ge 1 ] && [ "${EV22:-0}" = "${RP22:-x}" ]; then
  ok "AC-022 reproduction.steps 如实（证据条数 $EV22 == 复现步骤数 $RP22）"
else
  bad "AC-022 reproduction.steps 如实" "status=$S22 证据条数=$EV22 复现步骤数=$RP22（两者必须相等：说跑了几步就得有几份证据）"
fi

# ---------------------------------------------------------------- AC-023
# D23：用例级载体缺 path 与"载体冲突"是两种不同的修法（补齐 vs 二选一），
# 不能混成一个错误类型 —— 误诊会让调用方去找一个不存在的冲突。
step "AC-023 用例级载体缺 path 判 incomplete_request_carrier"
D23="$WORK/ac023"; make_project "$D23"
cat > "$D23/test-assets/suites/REQ-001-coupon/cases.json" <<'CASE23'
{ "schema_version": 2, "meta": {"source":"qa-0025b","generated_at":"2026-11-11T18:00:00+08:00","case_count":1},
  "requirements":[{"id":"R-1","title":"载体缺 path","source_ref":"x","testable":true}], "open_questions": [],
  "coverage_matrix":[{"requirement":"R-1","methods_applied":["M0.1"],"skipped":[],"dimensions":["functional"]}],
  "cases":[{"id":"TC-001","title":"载体只有 query","requirement_refs":["R-1"],"dimension":"functional","priority":"P0","method":["M0.1"],"status":"active",
    "request":{"query":{"a":"1"}},
    "steps":[{"action":"GET /ok","expected":{"path":"$.status","op":"equals","expected":"ok"}}]}]}
CASE23
node -e '
const fs=require("fs"),f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));
o.driver="mock";fs.writeFileSync(f,JSON.stringify(o,null,2));
' "$D23/test-assets/environments/local.json"
S23="NOPROJ"; T23="NONE"
if run_suite "$D23" >/dev/null 2>&1 && [ -n "$RUN_DIR" ]; then
  T23="$(node -e '
  const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const a=Array.isArray(o)?o:(o.results||o.cases||[]);
  const r=a[0]||{};
  console.log((r.status||"NONE")+"|"+(r.error&&r.error.type?r.error.type:"NONE"));
  ' "$RUN_DIR/results.json" 2>/dev/null)"
  S23="${T23%%|*}"; T23="${T23##*|}"
fi
if [ "$S23" = "blocked" ] && [ "$T23" = "incomplete_request_carrier" ]; then
  ok "AC-023 用例级载体缺 path 判 incomplete_request_carrier"
else
  bad "AC-023 用例级载体缺 path 判 incomplete_request_carrier" "status=$S23 error.type=$T23（缺 path 是「补齐」，不是「二选一」—— 不该与 conflicting 混同）"
fi

# ---------------------------------------------------------------- AC-024
# D25：step 级载体缺 path，与用例级载体缺 path 是同一类问题（补齐，不是二选一）。
step "AC-024 step 级载体缺 path 判 incomplete_request_carrier"
D24="$WORK/ac024"; make_project "$D24"
cat > "$D24/test-assets/suites/REQ-001-coupon/cases.json" <<'CASE24'
{ "schema_version": 2, "meta": {"source":"qa-0025b","generated_at":"2026-11-11T18:00:00+08:00","case_count":1},
  "requirements":[{"id":"R-1","title":"step 载体缺 path","source_ref":"x","testable":true}], "open_questions": [],
  "coverage_matrix":[{"requirement":"R-1","methods_applied":["M0.1"],"skipped":[],"dimensions":["functional"]}],
  "cases":[{"id":"TC-001","title":"step 载体只有 method","requirement_refs":["R-1"],"dimension":"functional","priority":"P0","method":["M0.1"],"status":"active",
    "request":{"method":"GET","path":"/ok"},
    "steps":[{"action":"第一步","request":{"method":"GET"},"expected":{"path":"$.status","op":"equals","expected":"ok"}}]}]}
CASE24
node -e '
const fs=require("fs"),f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));
o.driver="mock";fs.writeFileSync(f,JSON.stringify(o,null,2));
' "$D24/test-assets/environments/local.json"
S24="NOPROJ"; T24="NONE"
if run_suite "$D24" >/dev/null 2>&1 && [ -n "$RUN_DIR" ]; then
  T24="$(node -e '
  const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const a=Array.isArray(o)?o:(o.results||o.cases||[]);
  const r=a[0]||{};
  console.log((r.status||"NONE")+"|"+(r.error&&r.error.type?r.error.type:"NONE"));
  ' "$RUN_DIR/results.json" 2>/dev/null)"
  S24="${T24%%|*}"; T24="${T24##*|}"
fi
if [ "$S24" = "blocked" ] && [ "$T24" = "incomplete_request_carrier" ]; then
  ok "AC-024 step 级载体缺 path 判 incomplete_request_carrier"
else
  bad "AC-024 step 级载体缺 path 判 incomplete_request_carrier" "status=$S24 error.type=$T24（缺 path 是「补齐」，不是「二选一」—— 规则对两类载体一视同仁）"
fi

# ---------------------------------------------------------------- AC-007
step "AC-007 产物中不含凭证明文"
# 关键：密钥必须在**执行之前**就位，并且用例真的带鉴权走一遍请求。
# 否则凭证压根没被用过，"产物里搜不到密钥"就是空测 —— 恒真。
# 所以这里既要断言 (a) 凭证确实被用上了（用例不是 blocked、证据存在），
# 也要断言 (b) 明文确实不在产物里。
D7="$WORK/ac007"; make_project "$D7"
SECRET="${LOCAL_PASS_TEST_SECRET:-s3cr3t-p4ssw0rd-value}"
export LOCAL_PASS="$SECRET"
# 用例带 bearer 鉴权，凭证取自 LOCAL_PASS
cat > "$D7/test-assets/suites/REQ-001-coupon/cases.json" <<'CASEAUTH'
{ "schema_version": 2, "meta": {"source":"qa-0025b","generated_at":"2026-11-11T18:00:00+08:00","case_count":1},
  "requirements":[{"id":"R-1","title":"下单","source_ref":"x","testable":true}], "open_questions": [],
  "coverage_matrix":[{"requirement":"R-1","methods_applied":["M0.1"],"skipped":[],"dimensions":["functional"]}],
  "cases":[{"id":"TC-001","title":"带鉴权","requirement_refs":["R-1"],"dimension":"functional","priority":"P0","method":["M0.1"],"status":"active",
    "auth":{"type":"bearer","env":"LOCAL_PASS"},
    "steps":[{"action":"GET /echo","expected":{"path":"$.method","op":"equals","expected":"GET"}}]}]}
CASEAUTH
node -e '
const fs=require("fs"),f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));
o.driver="mock";fs.writeFileSync(f,JSON.stringify(o,null,2));
' "$D7/test-assets/environments/local.json"
if run_suite "$D7" >/dev/null 2>&1 && [ -n "$RUN_DIR" ]; then
  ST7="$(node -e '
  const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const arr=Array.isArray(o)?o:(o.results||o.cases||[]);
  console.log(arr.length?arr[0].status:"NO_CASES");
  ' "$RUN_DIR/results.json" 2>/dev/null)"
  EVC="$(find "$RUN_DIR/evidence" -type f 2>/dev/null | wc -l)"
  if [ "$ST7" = "blocked" ] || [ "$EVC" -eq 0 ]; then
    bad "AC-007 产物中不含凭证明文" "场景无效：用例 status=$ST7 证据文件数=$EVC（凭证没被真正用上，测了空气）"
  elif grep -rq "$SECRET" "$RUN_DIR" 2>/dev/null; then
    bad "AC-007 产物中不含凭证明文" "产物里出现了凭证值"
  else
    ok "AC-007 产物中不含凭证明文（凭证已实际用于请求，产物中无明文）"
  fi
else
  bad "AC-007 产物中不含凭证明文" "执行未产出结果"
fi

# ---------------------------------------------------------------- AC-006
step "AC-006 凭证缺失判 blocked 而非 failed"
D6="$WORK/ac006"; make_project "$D6"
make_cases "$D6/test-assets/suites/REQ-001-coupon/cases.json" "[ $CASE_OK ]"
# 指向一个不存在的环境变量
node -e '
const fs=require("fs"),f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));
o.credentials={username_env:"NO_SUCH_ENV_XYZ"};fs.writeFileSync(f,JSON.stringify(o,null,2));
' "$D6/test-assets/environments/local.json"
if run_suite "$D6" >/dev/null 2>&1 && [ -n "$RUN_DIR" ]; then
  ST="$(node -e '
  const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const arr=Array.isArray(o)?o:(o.results||o.cases||[]);
  console.log(arr.length?arr[0].status:"NO_CASES");
  ' "$RUN_DIR/results.json" 2>/dev/null)"
  ET6="$(node -e '
  const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const a=Array.isArray(o)?o:(o.results||o.cases||[]);
  const r=a[0]||{};
  console.log(r.error&&r.error.type?r.error.type:"NONE");
  ' "$RUN_DIR/results.json" 2>/dev/null)"
  if [ "$ST" = "blocked" ] && [ "$ET6" = "credential_missing" ]; then
    ok "AC-006 凭证缺失判 blocked 而非 failed（error.type=credential_missing）"
  else
    bad "AC-006 凭证缺失判 blocked 而非 failed" "status=$ST error.type=$ET6（期望 blocked + credential_missing）"
  fi
else
  bad "AC-006 凭证缺失判 blocked 而非 failed" "执行未产出结果"
fi

# ---------------------------------------------------------------- AC-013
step "AC-013 脱敏在写入前完成，且留痕"
D13="$WORK/ac013"; make_project "$D13"
make_cases "$D13/test-assets/suites/REQ-001-coupon/cases.json" "[ $CASE_TOKEN ]"
# ⚠️ 必须显式启用 mock：否则走 api 打 127.0.0.1:9 → network_error → 0 份证据，
#    /token 根本没被请求，脱敏断言恒真（独立验收 M7：删掉脱敏脚本仍 23/0 全绿）。
node -e '
const fs=require("fs"),f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));
o.driver="mock";fs.writeFileSync(f,JSON.stringify(o,null,2));
' "$D13/test-assets/environments/local.json"
if run_suite "$D13" >/dev/null 2>&1 && [ -n "$RUN_DIR" ]; then
  LEAK="$(grep -rl "secret-value" "$RUN_DIR" 2>/dev/null | wc -l)"
  RED="$(jget "$RUN_DIR/meta.json" redaction)"
  EVD13="$(find "$RUN_DIR/evidence" -type f 2>/dev/null | wc -l)"
  # 场景有效性闸：没有证据 = /token 根本没被请求 = 脱敏场景是空的，断言会恒真
  if [ "$EVD13" -eq 0 ]; then
    bad "AC-013 脱敏在写入前完成，且留痕" "场景无效：证据 0 份，/token 未被请求（脱敏场景被掏空，断言恒真）"
  elif [ "$LEAK" -eq 0 ] && echo "$RED" | grep -q "rules_applied" \
       && grep -rq "REDACTED" "$RUN_DIR/evidence" 2>/dev/null; then
    # 必须看到**脱敏痕迹**，不能只查 rules_applied 这个键名 ——
    # 否则 mock 端点不再返回敏感字段时，会因为"没东西可脱敏"而判绿（独立验收 M13）。
    ok "AC-013 脱敏在写入前完成，且留痕（证据 $EVD13 份，场景非空且有脱敏痕迹）"
  elif [ "$LEAK" -ne 0 ]; then
    bad "AC-013 脱敏在写入前完成，且留痕" "产物里出现了 secret-value（$LEAK 个文件）"
  else
    bad "AC-013 脱敏在写入前完成，且留痕" "meta.json 缺 redaction.rules_applied"
  fi
else
  bad "AC-013 脱敏在写入前完成，且留痕" "执行未产出结果"
fi

# ---------------------------------------------------------------- AC-012
step "AC-012 与轮次状态集成（状态只经 cycle-state.mjs 写）"
D12="$WORK/ac012"; make_project "$D12"
make_cases "$D12/test-assets/suites/REQ-001-coupon/cases.json" "[ $CASE_OK ]"
CS="$TCD/scripts/cycle-state.mjs"
if [ -f "$CS" ]; then
  if run_suite "$D12" --cycle "$D12/test-assets/cycles/R1-REQ-001" >/dev/null 2>&1 && [ -n "$RUN_DIR" ]; then
    RID="$(jget "$RUN_DIR/meta.json" run_id)"
    RUNS="$(jget "$D12/test-assets/cycles/R1-REQ-001/cycle.json" stages execute runs)"
    if echo "$RUNS" | grep -q "$RID"; then
      ok "AC-012 与轮次状态集成（run_id 记入 stages.execute.runs[]）"
    else
      bad "AC-012 与轮次状态集成" "runs[] 未含 run_id=$RID（实际=$RUNS）"
    fi
    # 幂等：同一个 run_id 写两次，runs[] 不得出现重复项
    # （独立验收 M8：去掉幂等判断 → runs=["RUN-QA-1","RUN-QA-1"]，原脚本判绿）
    CY="$D12/test-assets/cycles/R1-REQ-001"
    node "$CS" set-stage "$CY" --stage execute --status in_progress --run RUN-QA-1 >/dev/null 2>&1
    node "$CS" set-stage "$CY" --stage execute --status in_progress --run RUN-QA-1 >/dev/null 2>&1
    RUNS2="$(jget "$CY/cycle.json" stages execute runs)"
    N2="$(printf '%s' "$RUNS2" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const a=JSON.parse(s);console.log(Array.isArray(a)?a.length:-1)}catch(e){console.log(-1)}})')"
    UNIQ="$(printf '%s' "$RUNS2" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const a=JSON.parse(s);console.log(Array.isArray(a)?new Set(a).size:-1)}catch(e){console.log(-1)}})')"
    if [ "${N2:-0}" -ge 1 ] && [ "$N2" = "$UNIQ" ]; then
      ok "AC-012b set-stage --run 幂等（同一 run_id 重复写不产生重复项）"
    else
      bad "AC-012b set-stage --run 幂等" "runs[]=$RUNS2（条数=$N2 去重后=$UNIQ —— 重复项说明幂等判断没了）"
    fi
  else
    bad "AC-012 与轮次状态集成" "带 --cycle 执行未产出结果"
  fi
  # 执行器与脚本不得直接写 cycle.json。
  # 检索范围要**覆盖 scripts/lib/**（独立验收 M11：在 lib/ 里绕过推进器直写 cycle.json → 原脚本判绿）。
  # 并且要先**去掉注释**再检索 —— 否则源码里的注释示例会被误判。
  DIRECT="$(node -e '
  const fs=require("fs"), path=require("path");
  const roots=process.argv.slice(1);
  const files=[];
  const walk=(d)=>{ for(const e of fs.readdirSync(d,{withFileTypes:true})){ const p=path.join(d,e.name);
    if(e.isDirectory()) walk(p); else if(/\.(mjs|js|cjs)$/.test(e.name)) files.push(p); } };
  for(const r of roots){ if(fs.existsSync(r)) walk(r); }
  const hits=[];
  for(const f of files){
    let src=fs.readFileSync(f,"utf8");
    src=src.replace(/\/\*[\s\S]*?\*\//g,"").replace(/^\s*\/\/.*$/gm,"");
    // 写 cycle.json 的各种写法：writeFile(Sync)? / rename / copyFile 目的地含 cycle.json
    const lines=src.split(/\r?\n/);
    lines.forEach((ln,i)=>{
      if(/(writeFile|writeFileSync|rename|copyFile|appendFile|createWriteStream|openSync)\s*\([^)]*cycle\.json/.test(ln)){
        hits.push(f+":"+(i+1)+" "+ln.trim().slice(0,80));
      }
    });
  }
  console.log(hits.length);
  if(hits.length) console.error(hits.slice(0,5).join("\n"));
  ' "$TE/executors" "$EX" "$TCD/scripts" 2>/dev/null | head -1)"
  if [ "${DIRECT:-1}" -eq 0 ]; then
    ok "AC-012b 执行器/脚本中无直接写 cycle.json 的路径（含 scripts/lib/，去注释后检索）"
  else
    bad "AC-012b 执行器/脚本中无直接写 cycle.json 的路径" "命中 $DIRECT 处"
  fi
else
  bad "AC-012 与轮次状态集成" "找不到 cycle-state.mjs"
fi

# ---------------------------------------------------------------- AC-016
step "AC-016 执行器完整性自检能发现源码被改"
if [ ! -f "$EX/verify-integrity.mjs" ]; then
  bad "AC-016 执行器完整性自检能发现源码被改" "缺 verify-integrity.mjs"
else
  VI="$EX/verify-integrity.mjs"
  node "$VI" >/dev/null 2>&1; RC0=$?
  EF="$(find "$TE/executors" -name "*.mjs" -type f 2>/dev/null | head -1)"
  if [ -n "$EF" ]; then
    cp "$EF" "$WORK/exec.bak"; printf '\n// tampered\n' >> "$EF"
    node "$VI" >/dev/null 2>&1; RC1=$?
    cp "$WORK/exec.bak" "$EF"
  else
    RC1="NOEXEC"
  fi
  node "$VI" >/dev/null 2>&1; RC2=$?
  if [ $RC0 -eq 0 ] && [ "$RC1" = "1" ] && [ $RC2 -eq 0 ]; then
    ok "AC-016 执行器完整性自检能发现源码被改"
  else
    bad "AC-016 执行器完整性自检能发现源码被改" "基线=$RC0 篡改后=$RC1 恢复后=$RC2"
  fi
fi

# ---------------------------------------------------------------- AC-017
step "AC-017 --json 输出与退出码语义"
D17="$WORK/ac017"; make_project "$D17"
make_cases "$D17/test-assets/suites/REQ-001-coupon/cases.json" "[ $CASE_OK ]"
cd "$D17"
node "$EX/run-suite.mjs" "$D17/test-assets/suites/REQ-001-coupon/suite.json" --json > "$WORK/j1.json" 2>/dev/null; RC1=$?
node "$EX/run-suite.mjs" "$D17/test-assets/suites/REQ-001-coupon/suite.json" --json --bogus 1 > "$WORK/j2.json" 2>/dev/null; RC2=$?
# exit 1 场景：suite.json 缺必填字段 → 校验失败
D17B="$WORK/ac017b"; make_project "$D17B"
printf '{ "suite":"REQ-001-coupon" }' > "$D17B/test-assets/suites/REQ-001-coupon/suite.json"
make_cases "$D17B/test-assets/suites/REQ-001-coupon/cases.json" "[ $CASE_OK ]"
node "$EX/run-suite.mjs" "$D17B/test-assets/suites/REQ-001-coupon/suite.json" --json > "$WORK/j4.json" 2>/dev/null; RC4=$?
cd - >/dev/null
J1="$(node -e 'try{JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log("ok")}catch(e){console.log("fail")}' "$WORK/j1.json")"
J2="$(node -e 'try{JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log("ok")}catch(e){console.log("fail")}' "$WORK/j2.json")"
J4="$(node -e 'try{JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log("ok")}catch(e){console.log("fail")}' "$WORK/j4.json")"
# ⚠️ 必须断言**成功路径的退出码是 0** —— 原来只采集不断言，
#    成功路径返回 1 也照样判绿（独立验收 M10）。
if [ "$J1" = "ok" ] && [ "$J2" = "ok" ] && [ "$J4" = "ok" ] \
   && [ $RC1 -eq 0 ] && [ $RC2 -eq 2 ] && [ $RC4 -eq 1 ]; then
  ok "AC-017 --json 输出与退出码语义（成功0 / 校验失败1 / 用法错误2，stdout 均可 JSON.parse）"
else
  bad "AC-017 --json 输出与退出码语义" "成功json=$J1(rc=$RC1，期望0) 校验失败json=$J4(rc=$RC4，期望1) usage json=$J2(rc=$RC2，期望2)"
fi

# ---------------------------------------------------------------- AC-015
step "AC-015 零依赖 + 可移植"
PKG="$(cd "$TE" && cd ../.. && pwd)/package.json"
DEPS="0"
[ -f "$PKG" ] && DEPS="$(node -e 'const p=require(process.argv[1]);console.log(Object.keys(p.dependencies||{}).length)' "$PKG" 2>/dev/null)"
BADIMPORT="$(grep -h -E "^\s*import .*from ['\"]" "$EX"/*.mjs "$EX"/lib/*.mjs "$TE"/executors/*.mjs 2>/dev/null \
  | grep -v -E "from ['\"]node:" | grep -v -E "from ['\"]\./" | grep -v -E "from ['\"]\.\./" | wc -l)"
# ⚠️ 检索范围必须**递归覆盖 scripts/lib/**（独立验收 M12：在 lib/ 里引 child_process → 原脚本判绿）
EXT="$(node -e '
const fs=require("fs"),path=require("path");
const roots=process.argv.slice(1);const files=[];
const walk=(d)=>{ for(const e of fs.readdirSync(d,{withFileTypes:true})){ const p=path.join(d,e.name);
  if(e.isDirectory()) walk(p); else if(/\.(mjs|js|cjs)$/.test(e.name)) files.push(p); } };
for(const r of roots){ if(fs.existsSync(r)) walk(r); }
const hits=[];
for(const f of files){
  const src=fs.readFileSync(f,"utf8").replace(/\/\*[\s\S]*?\*\//g,"").replace(/^\s*\/\/.*$/gm,"");
  src.split(/\r?\n/).forEach((ln,i)=>{
    if(/child_process|execSync|spawnSync|execFile|\/bin\/bash|python3/.test(ln)) hits.push(f+":"+(i+1));
  });
}
console.log(hits.length);
if(hits.length) console.error(hits.slice(0,5).join("\n"));
' "$EX" "$TE/executors" 2>/dev/null | head -1)"
if [ "$DEPS" = "0" ] && [ "$BADIMPORT" = "0" ] && [ "$EXT" = "0" ]; then
  ok "AC-015 零依赖 + 可移植"
else
  bad "AC-015 零依赖 + 可移植" "deps=$DEPS 非内置import=$BADIMPORT 外部调用行=$EXT"
fi

# ---------------------------------------------------------------- AC-025
step "AC-025 判 skipped 的用例不得发出请求"
D25="$WORK/ac025"; make_project "$D25"
# 计数 HTTP 服务器：记录收到的每一个请求 —— 用来证明"某条用例到底有没有真发请求"，
# 而不是靠证据条数间接推断（间接推断会被"发了但没记账"绕过）。
cat > "$WORK/count-server.mjs" <<'EOF'
import { createServer } from 'node:http';
import { writeFileSync } from 'node:fs';
const hits = [];
const server = createServer((req, res) => {
  const url = req.url || '/';
  if (url.startsWith('/__stats')) {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ count: hits.length, hits }));
    return;
  }
  hits.push(`${req.method} ${url}`);
  res.writeHead(200, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ status: 'ok' }));
});
server.listen(0, '127.0.0.1', () => {
  writeFileSync(process.argv[2], String(server.address().port), 'utf8');
});
EOF
node "$WORK/count-server.mjs" "$WORK/port25" >/dev/null 2>&1 &
CNT_PID=$!
CNT_WAIT=0
while [ ! -s "$WORK/port25" ] && [ "$CNT_WAIT" -lt 100 ]; do sleep 0.1; CNT_WAIT=$((CNT_WAIT+1)); done
PORT25="$(cat "$WORK/port25" 2>/dev/null || true)"
if [ -z "$PORT25" ]; then
  bad "AC-025 判 skipped 的用例不得发出请求" "计数服务器没起来（无法判定请求是否发出）"
else
  node -e '
  const fs=require("fs");const f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));
  o.base_url="http://127.0.0.1:"+process.argv[2];
  fs.writeFileSync(f,JSON.stringify(o,null,2));
  ' "$D25/test-assets/environments/local.json" "$PORT25"
  CASE_ACT25='{ "id":"TC-ACT","title":"活跃用例","requirement_refs":["R-1"],"dimension":"functional","priority":"P0","method":["M0.1"],"status":"active","steps":[ { "action":"GET /ok","expected":{ "path":"$.status","op":"equals","expected":"ok" } } ] }'
  CASE_DEP25='{ "id":"TC-DEP","title":"废弃用例","requirement_refs":["R-1"],"dimension":"functional","priority":"P0","method":["M0.1"],"status":"deprecated","revision":{ "previous_status":"active","change":"需求变更，用例废弃" },"steps":[ { "action":"GET /notfound","expected":{ "path":"$.status","op":"equals","expected":"ok" } } ] }'
  CASE_BLK25='{ "id":"TC-BLK","title":"阻塞用例","requirement_refs":["R-1"],"dimension":"functional","priority":"P0","method":["M0.1"],"status":"blocked","revision":{ "previous_status":"active","change":"环境未就绪，标记阻塞" },"steps":[ { "action":"GET /created","expected":{ "path":"$.status","op":"equals","expected":"ok" } } ] }'
  make_cases "$D25/test-assets/suites/REQ-001-coupon/cases.json" "[ $CASE_ACT25, $CASE_DEP25, $CASE_BLK25 ]"
  if run_suite "$D25" >/dev/null 2>&1 && [ -n "$RUN_DIR" ]; then
    STATS="$(curl -s "http://127.0.0.1:$PORT25/__stats" 2>/dev/null || true)"
    printf '%s' "$STATS" > "$WORK/stats25.json"
    node -e '
    const fs=require("fs");
    const [resFile,casesFile,statsFile]=process.argv.slice(1);
    const out=[];
    let results=[],cases={cases:[]},hits=[];
    try{ results=JSON.parse(fs.readFileSync(resFile,"utf8")); }catch(e){}
    try{ cases=JSON.parse(fs.readFileSync(casesFile,"utf8")); }catch(e){}
    try{ hits=(JSON.parse(fs.readFileSync(statsFile,"utf8")).hits)||[]; }catch(e){}
    const dep=results.find(r=>r.case_id==="TC-DEP");
    const act=results.find(r=>r.case_id==="TC-ACT");
    out.push("dep_status="+(dep?dep.status:"__MISSING__"));
    out.push("act_status="+(act?act.status:"__MISSING__"));
    // 被判 skipped 的用例：证据条数必须为 0，且它声明的路径一个都没被请求过
    let withEv="",hitPath="";
    for(const r of results){
      if(r.status!=="skipped") continue;
      if((r.evidence||[]).length>0) withEv=withEv+r.case_id+" ";
      const c=(cases.cases||[]).find(x=>x.id===r.case_id);
      const paths=((c&&Array.isArray(c.steps))?c.steps:[]).map(s=>{
        const a=(s&&typeof s.action==="string")?s.action:"";
        const m=a.match(/^[A-Z]+\s+(\S+)/);return m?m[1]:null;
      }).filter(Boolean);
      for(const p of paths){ if(hits.some(h=>h.endsWith(" "+p))) hitPath=hitPath+r.case_id+":"+p+" "; }
    }
    out.push("skipped_with_evidence="+(withEv.trim()||"none"));
    out.push("skipped_path_requested="+(hitPath.trim()||"none"));
    // 对照组：活跃用例必须真跑过（否则"什么都没发"也能让上面几条判绿）
    out.push("act_requested="+(hits.some(h=>h.endsWith(" /ok"))?"yes":"no"));
    out.push("hit_count="+hits.length);
    console.log(out.join("\n"));
    ' "$RUN_DIR/results.json" "$D25/test-assets/suites/REQ-001-coupon/cases.json" "$WORK/stats25.json" > "$WORK/v25.txt"
    V25="$(cat "$WORK/v25.txt")"
    DEP_S="$(printf '%s\n' "$V25" | sed -n 's/^dep_status=//p')"
    ACT_S="$(printf '%s\n' "$V25" | sed -n 's/^act_status=//p')"
    SK_EV="$(printf '%s\n' "$V25" | sed -n 's/^skipped_with_evidence=//p')"
    SK_HIT="$(printf '%s\n' "$V25" | sed -n 's/^skipped_path_requested=//p')"
    ACT_REQ="$(printf '%s\n' "$V25" | sed -n 's/^act_requested=//p')"
    if [ "$DEP_S" = "skipped" ] && [ "$ACT_S" = "passed" ] && [ "$SK_EV" = "none" ] \
       && [ "$SK_HIT" = "none" ] && [ "$ACT_REQ" = "yes" ]; then
      ok "AC-025 判 skipped 的用例不得发出请求"
    else
      bad "AC-025 判 skipped 的用例不得发出请求" \
          "TC-DEP=$DEP_S(期望skipped) TC-ACT=$ACT_S(期望passed) 跳过但有证据=$SK_EV 跳过却发了请求=$SK_HIT 活跃用例未发出请求=$ACT_REQ"
    fi
  else
    bad "AC-025 判 skipped 的用例不得发出请求" "套件未跑通（无产物目录）"
  fi
fi
kill "$CNT_PID" 2>/dev/null || true
wait "$CNT_PID" 2>/dev/null || true

# ---------------------------------------------------------------- AC-026
step "AC-026 传输层错误时，已执行步骤的证据必须保留"
D26="$WORK/ac026"; make_project "$D26"
node -e '
const fs=require("fs");const f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));
o.driver="mock";fs.writeFileSync(f,JSON.stringify(o,null,2));
' "$D26/test-assets/environments/local.json"
CASE_ERR26='{ "id":"TC-ERR","title":"传输层错误","requirement_refs":["R-1"],"dimension":"functional","priority":"P0","method":["M0.1"],"status":"active","timeout_ms":300,"steps":[ { "action":"GET /ok","expected":{ "path":"$.status","op":"equals","expected":"ok" } }, { "action":"GET /slow?ms=3000","expected":{ "path":"$.status","op":"equals","expected":"ok" } } ] }'
make_cases "$D26/test-assets/suites/REQ-001-coupon/cases.json" "[ $CASE_ERR26 ]"
if run_suite "$D26" >/dev/null 2>&1 && [ -n "$RUN_DIR" ]; then
  V26="$(node -e '
  const fs=require("fs");
  const results=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  const r=results.find(x=>x.case_id==="TC-ERR");
  if(!r){console.log("status=__MISSING__\nerror=__MISSING__\nevidence=-1\nrepro=-1");process.exit(0);}
  const ev=(r.evidence||[]).length;
  const rp=(r.reproduction&&Array.isArray(r.reproduction.steps))?r.reproduction.steps.length:-1;
  console.log("status="+r.status);
  console.log("error="+(r.error&&r.error.type?r.error.type:"none"));
  console.log("evidence="+ev);
  console.log("repro="+rp);
  ' "$RUN_DIR/results.json")"
  S26="$(printf '%s\n' "$V26" | sed -n 's/^status=//p')"
  E26="$(printf '%s\n' "$V26" | sed -n 's/^error=//p')"
  N26="$(printf '%s\n' "$V26" | sed -n 's/^evidence=//p')"
  P26="$(printf '%s\n' "$V26" | sed -n 's/^repro=//p')"
  # 证据条数 ≥ 1（第 1 步成功的响应必须留下）；证据条数 == 复现步骤数（D21/D24）
  if [ "$S26" = "failed" ] && [ "$E26" = "timeout" ] && [ "$N26" -ge 1 ] 2>/dev/null \
     && [ "$P26" -ge 1 ] 2>/dev/null && [ "$N26" -eq "$P26" ]; then
    ok "AC-026 传输层错误时，已执行步骤的证据必须保留"
  else
    bad "AC-026 传输层错误时，已执行步骤的证据必须保留" \
        "status=$S26(期望failed) error=$E26(期望timeout) 证据条数=$N26(期望≥1) 复现步骤数=$P26(期望=证据条数且≥1)"
  fi
else
  bad "AC-026 传输层错误时，已执行步骤的证据必须保留" "套件未跑通（无产物目录）"
fi

# ---------------------------------------------------------------- AC-027
step "AC-027 执行器生命周期必须收尾（异常路径也要停）"
D27="$WORK/ac027"; make_project "$D27"
node -e '
const fs=require("fs");const f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));
o.driver="mock";fs.writeFileSync(f,JSON.stringify(o,null,2));
' "$D27/test-assets/environments/local.json"
make_cases "$D27/test-assets/suites/REQ-001-coupon/cases.json" "[ $CASE_OK ]"
# 变异体：把判定层改成"一进来就抛异常" —— 模拟判定层崩溃。
# 若执行外壳的收尾钩子只在正常路径上调用（没有 finally），桩服务会一直持有
# 事件循环，进程永不退出 → 被 timeout 杀掉（退出码 124）。
rm -rf "$WORK/mutant"
cp -r "$TE" "$WORK/mutant"
MUT_OK=1
node -e '
const fs=require("fs");const p=process.argv[1];
let s=fs.readFileSync(p,"utf8");
const needle="export function decide(";
if(!s.includes(needle)){process.exit(3);}
s=s.replace(needle,"export function decide(){ throw new Error(\"mutant-abort\"); }"+String.fromCharCode(10)+"function _decide_unused(");
fs.writeFileSync(p,s);
' "$WORK/mutant/scripts/lib/verdict.mjs" || MUT_OK=0
if [ "$MUT_OK" -ne 1 ]; then
  bad "AC-027 执行器生命周期必须收尾（异常路径也要停）" "变异体没造出来（判定层入口找不到）"
else
  T0="$(date +%s%3N)"
  ( cd "$D27" && timeout 20 node "$WORK/mutant/scripts/run-suite.mjs" \
      "$D27/test-assets/suites/REQ-001-coupon/suite.json" --json ) >/dev/null 2>&1
  RC27=$?
  T1="$(date +%s%3N)"
  MS27=$((T1 - T0))
  # 124 = 被 timeout 杀掉 = 进程挂死
  # ⚠️ 光看退出码不够 —— "卡住 19 秒然后自己退出"也能判绿（独立验收/实现方都指出了这一点）。
  #    所以再加一道**耗时上限**：判定层一进来就抛异常，收尾必须在 15 秒内完成。
  if [ "$RC27" -ne 124 ] && [ "$RC27" -ne 137 ] && [ "$MS27" -le 15000 ]; then
    ok "AC-027 执行器生命周期必须收尾（异常路径也要停）"
  else
    bad "AC-027 执行器生命周期必须收尾（异常路径也要停）" \
        "退出码=$RC27（124/137 = 进程挂死，判定层异常后执行器没被收尾）耗时=${MS27}ms（上限15000ms）"
  fi
fi

# ---------------------------------------------------------------- AC-028
step "AC-028 meta.cycle 段不得谎报推进结果"
D28="$WORK/ac28"; make_project "$D28"
node -e '
const fs=require("fs");const f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));
o.driver="mock";fs.writeFileSync(f,JSON.stringify(o,null,2));
' "$D28/test-assets/environments/local.json"
make_cases "$D28/test-assets/suites/REQ-001-coupon/cases.json" "[ $CASE_OK ]"
# 子场景①：轮次目录不存在 → 推进必然失败
( cd "$D28" && node "$EX/run-suite.mjs" "$D28/test-assets/suites/REQ-001-coupon/suite.json" \
    --cycle "$WORK/no-such-cycle" --json ) > "$WORK/cyc-fail.json" 2>/dev/null
RC28F=$?
# 子场景②：轮次目录存在 → 推进应当成功
( cd "$D28" && node "$EX/run-suite.mjs" "$D28/test-assets/suites/REQ-001-coupon/suite.json" \
    --cycle "$D28/test-assets/cycles/R1-REQ-001" --json ) > "$WORK/cyc-ok.json" 2>/dev/null
RC28O=$?
V28="$(node -e '
const fs=require("fs");
function read(f){ try{ return JSON.parse(fs.readFileSync(f,"utf8")); }catch(e){ return null; } }
const bad=read(process.argv[1]), ok=read(process.argv[2]);
const c=(bad&&bad.cycle)?bad.cycle:{};
const d=(ok&&ok.cycle)?ok.cycle:{};
console.log("fail_ok="+String(c.ok));
console.log("fail_recorded="+String(c.runs_recorded));
console.log("fail_stage="+String(c.stage_status));
console.log("fail_rc="+String(bad?bad.exit_code:"__PARSE_ERR__"));
console.log("ok_ok="+String(d.ok));
console.log("ok_recorded="+String(d.runs_recorded));
console.log("ok_stage="+String(d.stage_status));
console.log("ok_rc="+String(ok?ok.exit_code:"__PARSE_ERR__"));
' "$WORK/cyc-fail.json" "$WORK/cyc-ok.json")"
F_OK="$(printf '%s\n' "$V28" | sed -n 's/^fail_ok=//p')"
F_REC="$(printf '%s\n' "$V28" | sed -n 's/^fail_recorded=//p')"
F_STG="$(printf '%s\n' "$V28" | sed -n 's/^fail_stage=//p')"
F_RC="$(printf '%s\n' "$V28" | sed -n 's/^fail_rc=//p')"
O_OK="$(printf '%s\n' "$V28" | sed -n 's/^ok_ok=//p')"
O_REC="$(printf '%s\n' "$V28" | sed -n 's/^ok_recorded=//p')"
O_STG="$(printf '%s\n' "$V28" | sed -n 's/^ok_stage=//p')"
O_RC="$(printf '%s\n' "$V28" | sed -n 's/^ok_rc=//p')"
# ⚠️ 失败场景的 stage_status 必须**锁死为 null**（状态未知）——
#    旧版只查"不等于 in_progress"，那 "pending" 这类同样误导人的值也能判绿。
if [ "$F_OK" = "false" ] && [ "$F_REC" = "false" ] && [ "$F_STG" = "null" ] && [ "$F_RC" = "1" ] \
   && [ "$O_OK" = "true" ] && [ "$O_REC" = "true" ] && [ "$O_STG" = "in_progress" ] && [ "$O_RC" = "0" ]; then
  ok "AC-028 meta.cycle 段不得谎报推进结果"
else
  bad "AC-028 meta.cycle 段不得谎报推进结果" \
      "失败场景: ok=$F_OK(期望false) runs_recorded=$F_REC(期望false) stage_status=$F_STG(期望null) 退出码=$F_RC(期望1) || 成功场景: ok=$O_OK(期望true) runs_recorded=$O_REC(期望true) stage_status=$O_STG(期望in_progress) 退出码=$O_RC(期望0)"
fi

# ---------------------------------------------------------------- 汇总
echo
echo "────────────────────────────────────────"
printf '结论: %d PASS / %d FAIL\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "未通过的 AC:"
  for f in "${FAILED_LIST[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
