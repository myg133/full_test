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

# 探测 mock 的启用方式
MOCK_MODE=""
detect_mock() {
  # 方案 B: 环境配置 driver=mock
  node -e '
  const fs=require("fs"),f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));
  o.driver="mock";fs.writeFileSync(f,JSON.stringify(o,null,2));
  ' "$WORK/proj/test-assets/environments/local.json" 2>/dev/null
  if run_suite "$WORK/proj" >/dev/null 2>&1; then MOCK_MODE="env-driver"; return; fi
  # 方案 A: suite.json executor=mock
  node -e '
  const fs=require("fs"),f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));
  o.executor="mock";fs.writeFileSync(f,JSON.stringify(o,null,2));
  ' "$WORK/proj/test-assets/suites/REQ-001-coupon/suite.json" 2>/dev/null
  if run_suite "$WORK/proj" >/dev/null 2>&1; then MOCK_MODE="executor-enum"; return; fi
  # 方案 C: 命令行覆盖
  if run_suite "$WORK/proj" --executor mock >/dev/null 2>&1; then MOCK_MODE="cli-flag"; return; fi
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
  bad "AC-014 离线可跑 —— mock 执行器跑通完整链路" "三种启用方式均未跑通（env-driver / executor-enum / cli-flag）"
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
if [ "$S21" = "blocked" ]; then
  ok "AC-021 载体冲突判 blocked（显式用例级载体 + 不同端点的 step，不得判 passed）"
else
  bad "AC-021 载体冲突判 blocked" "status=$S21（期望 blocked；若为 passed 说明 step 级请求被静默丢掉 —— 半个用例报通过）"
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
  if [ "$ST" = "blocked" ]; then
    ok "AC-006 凭证缺失判 blocked 而非 failed"
  else
    bad "AC-006 凭证缺失判 blocked 而非 failed" "实际 status=$ST（期望 blocked）"
  fi
else
  bad "AC-006 凭证缺失判 blocked 而非 failed" "执行未产出结果"
fi

# ---------------------------------------------------------------- AC-013
step "AC-013 脱敏在写入前完成，且留痕"
D13="$WORK/ac013"; make_project "$D13"
make_cases "$D13/test-assets/suites/REQ-001-coupon/cases.json" "[ $CASE_TOKEN ]"
if run_suite "$D13" >/dev/null 2>&1 && [ -n "$RUN_DIR" ]; then
  LEAK="$(grep -rl "secret-value" "$RUN_DIR" 2>/dev/null | wc -l)"
  RED="$(jget "$RUN_DIR/meta.json" redaction)"
  if [ "$LEAK" -eq 0 ] && echo "$RED" | grep -q "rules_applied"; then
    ok "AC-013 脱敏在写入前完成，且留痕"
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
  else
    bad "AC-012 与轮次状态集成" "带 --cycle 执行未产出结果"
  fi
  # 执行器不得直接写 cycle.json
  DIRECT="$(grep -c -E "writeFile.*cycle\.json|writeFileSync.*cycle\.json" "$TE"/executors/*.mjs "$EX"/*.mjs 2>/dev/null | grep -v ':0' | wc -l)"
  if [ "$DIRECT" -eq 0 ]; then
    ok "AC-012b 执行器/脚本中无直接写 cycle.json 的路径"
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
node "$EX/run-suite.mjs" "$D17/test-assets/suites/REQ-001-coupon/suite.json" --json > "$WORK/j3.json" 2>/dev/null; RC3=$?
cd - >/dev/null
J1="$(node -e 'try{JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log("ok")}catch(e){console.log("fail")}' "$WORK/j1.json")"
J2="$(node -e 'try{JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log("ok")}catch(e){console.log("fail")}' "$WORK/j2.json")"
if [ "$J1" = "ok" ] && [ "$J2" = "ok" ] && [ $RC2 -eq 2 ]; then
  ok "AC-017 --json 输出与退出码语义"
else
  bad "AC-017 --json 输出与退出码语义" "成功json=$J1(rc=$RC1) usage json=$J2(rc=$RC2，期望2)"
fi

# ---------------------------------------------------------------- AC-015
step "AC-015 零依赖 + 可移植"
PKG="$(cd "$TE" && cd ../.. && pwd)/package.json"
DEPS="0"
[ -f "$PKG" ] && DEPS="$(node -e 'const p=require(process.argv[1]);console.log(Object.keys(p.dependencies||{}).length)' "$PKG" 2>/dev/null)"
BADIMPORT="$(grep -h -E "^\s*import .*from ['\"]" "$EX"/*.mjs "$EX"/lib/*.mjs "$TE"/executors/*.mjs 2>/dev/null \
  | grep -v -E "from ['\"]node:" | grep -v -E "from ['\"]\./" | grep -v -E "from ['\"]\.\./" | wc -l)"
EXT="$(grep -c -E "child_process|execSync|spawnSync|/tmp/|python3" "$EX"/*.mjs "$TE"/executors/*.mjs 2>/dev/null | grep -v ':0' | wc -l)"
if [ "$DEPS" = "0" ] && [ "$BADIMPORT" = "0" ] && [ "$EXT" = "0" ]; then
  ok "AC-015 零依赖 + 可移植"
else
  bad "AC-015 零依赖 + 可移植" "deps=$DEPS 非内置import=$BADIMPORT 外部调用行=$EXT"
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
