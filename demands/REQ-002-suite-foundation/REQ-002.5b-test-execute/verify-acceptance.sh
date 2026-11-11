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

# 造一个 v2 用例集：$1=输出文件 $2=steps 的 JSON 数组
make_cases() {
  local f="$1" steps="$2"
  printf '{\n  "schema_version": 2,\n  "meta": { "source": "qa-0025b", "generated_at": "2026-11-11T18:00:00+08:00", "case_count": 1 },\n  "requirements": [ { "id": "R-1", "title": "下单", "source_ref": "x", "testable": true } ],\n  "open_questions": [],\n  "coverage_matrix": [ { "requirement": "R-1", "methods_applied": ["M0.1"], "skipped": [], "dimensions": ["functional"] } ],\n  "cases": [ { "id": "TC-001", "title": "下单用例", "requirement_refs": ["R-1"], "dimension": "functional",\n    "priority": "P0", "method": ["M0.1"], "status": "active",\n    "steps": %s } ]\n}\n' "$steps" > "$f"
}

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
  console.log((allHas?"CFG_OK":"CFG_MISS")+(hasBoundary?" BND_OK":" BND_MISS"));
  ' "$IDX")"
  case "$DECL" in
    CFG_OK*BND_OK) ok "AC-002 执行器注册表声明可配置项与边界" ;;
    *) bad "AC-002 执行器注册表声明可配置项与边界" "$DECL（需 CFG_OK + BND_OK）" ;;
  esac
fi

# ---------------------------------------------------------------- AC-003
step "AC-003 执行器实现不可被 agent 修改（硬约束）"
LOCK="$(grep -c -E "不得(修改|改写|编辑).{0,12}(执行器|executors|skill 目录|脚本)|禁止(修改|改写).{0,12}(执行器|executors)" "$TE/SKILL.md" 2>/dev/null)"
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
make_cases "$WORK/proj/test-assets/suites/REQ-001-coupon/cases.json" \
  '[ { "action": "GET /ok", "expected": { "path": "$.status", "op": "equals", "expected": "ok" } } ]'

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

# ---------------------------------------------------------------- AC-007
step "AC-007 产物中不含凭证明文"
if [ -z "$RUN_DIR" ]; then
  bad "AC-007 产物中不含凭证明文" "无 run 目录"
else
  SECRET="${LOCAL_PASS_TEST_SECRET:-s3cr3t-p4ssw0rd-value}"
  export LOCAL_PASS="$SECRET"
  if grep -rq "$SECRET" "$RUN_DIR" 2>/dev/null; then
    bad "AC-007 产物中不含凭证明文" "产物里出现了凭证值"
  else
    ok "AC-007 产物中不含凭证明文"
  fi
fi

# ---------------------------------------------------------------- AC-006
step "AC-006 凭证缺失判 blocked 而非 failed"
D6="$WORK/ac006"; make_project "$D6"
make_cases "$D6/test-assets/suites/REQ-001-coupon/cases.json" \
  '[ { "action": "GET /ok", "expected": { "path": "$.status", "op": "equals", "expected": "ok" } } ]'
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
make_cases "$D13/test-assets/suites/REQ-001-coupon/cases.json" \
  '[ { "action": "GET /token", "expected": { "path": "$.id", "op": "equals", "expected": 1 } } ]'
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
make_cases "$D12/test-assets/suites/REQ-001-coupon/cases.json" \
  '[ { "action": "GET /ok", "expected": { "path": "$.status", "op": "equals", "expected": "ok" } } ]'
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
make_cases "$D17/test-assets/suites/REQ-001-coupon/cases.json" \
  '[ { "action": "GET /ok", "expected": { "path": "$.status", "op": "equals", "expected": "ok" } } ]'
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
