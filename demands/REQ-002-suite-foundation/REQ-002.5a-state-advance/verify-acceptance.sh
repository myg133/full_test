#!/usr/bin/env bash
# REQ-002.5a 验收脚本 —— 逐条机械验证 acceptance.md 的 16 条 AC
#
# 用法: verify-acceptance.sh <skill-dir>
#   <skill-dir> 指向包含 SKILL.md 的 skill 目录，例如
#   <REPO_ROOT>/feature-REQ-002.5A/skills/test-case-design
#
# 退出码: 0 = 全部 AC 通过；1 = 有 AC 未通过
#
# 设计原则:
#   - 只读 skill 目录，测试样例一律造在临时目录里，不污染仓库
#   - 每条 AC 独立判定，失败不中断（一次跑完看全貌）
#   - 源码级判据（AC-012/013/015）标注为"保守判据"，必要处需人工复核

set -uo pipefail

SKILL_DIR="${1:?用法: verify-acceptance.sh <skill-dir>}"
SKILL_DIR="$(cd "$SKILL_DIR" 2>/dev/null && pwd)" || { echo "skill 目录不存在: $1" >&2; exit 2; }
SCRIPTS="$SKILL_DIR/scripts"
REFS="$SKILL_DIR/references"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qa-0025a-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
FAILED_LIST=()

ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED_LIST+=("$1"); printf '  \033[31mFAIL\033[0m  %s\n     ↳ %s\n' "$1" "${2:-}"; }

# jq 未必可用，统一走 node 处理 JSON
jget() { node -e '
  const fs=require("fs");
  const [file,...path]=process.argv.slice(1);
  let o; try{o=JSON.parse(fs.readFileSync(file,"utf8"));}catch(e){console.log("__PARSE_ERR__");process.exit(0);}
  for(const p of path){ if(o===undefined||o===null){console.log("__UNDEF__");process.exit(0);} o=o[p]; }
  console.log(typeof o==="object"?JSON.stringify(o):String(o));
' "$@"; }

sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# 取数组最后一条（jget 不支持负数索引）
jlast() { node -e '
  const fs=require("fs");
  const [file,key]=process.argv.slice(1);
  let o; try{o=JSON.parse(fs.readFileSync(file,"utf8"));}catch(e){console.log("__PARSE_ERR__");process.exit(0);}
  const a=Array.isArray(o[key])?o[key]:null;
  console.log(!a||a.length===0?"__EMPTY__":JSON.stringify(a[a.length-1]));
' "$@"; }

# 构造一个满足 REQ-002B 契约的完整项目（供 verify-layout 使用）
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
{ "name":"local","base_url":"http://127.0.0.1:8080","timeout_ms":5000,"retries":0,
  "credentials":{"username_env":"LOCAL_USER","password_env":"LOCAL_PASS"},"verify_tls":false }
EOF
  cat > "$P/test-assets/suites/REQ-001-coupon/cases.json" <<'EOF'
{ "requirements":[], "cases":[] }
EOF
  cat > "$P/test-assets/suites/REQ-001-coupon/suite.json" <<'EOF'
{ "suite":"REQ-001-coupon","requirement":"REQ-001","scope":"functional","environment":"local",
  "cases_file":"cases.json","executor":"api",
  "report":{"format":["html"],"output_dir":".test-artifacts/REQ-001"} }
EOF
  cat > "$P/test-assets/cycles/R1-REQ-001/cycle.json" <<'EOF'
{ "cycle_id":"R1-REQ-001","round":"R1","round_type":"new-requirement","requirement":"REQ-001",
  "scopes":["functional"],"scopes_skipped":[],"status":"in_progress",
  "stages":{"clarify":{"status":"done"},"design":{"status":"in_progress"}},
  "history":[{"at":"2026-11-11T18:00:00+08:00","from":"planned","to":"in_progress","by":"seed"}] }
EOF
  cat > "$P/test-assets/cycles/index.json" <<'EOF'
{ "cycles":[{"id":"R1-REQ-001","round":"R1","status":"in_progress","cases_total":0,"cases_passed":0,"bugs_found":0}] }
EOF
  printf '.test-artifacts/\n' > "$P/.gitignore"
}

# 依据文档字段表构造的 cycle.json（AC-014 的样本）
make_cycle_from_doc() {
  local C="$1"
  mkdir -p "$(dirname "$C")"
  cat > "$C" <<'EOF'
{ "cycle_id":"R1-REQ-001","round":"R1","round_type":"new-requirement","requirement":"REQ-001",
  "scopes":["functional"],"scopes_skipped":[],"status":"in_progress",
  "stages":{"clarify":{"status":"done"}},
  "history":[{"at":"2026-11-11T18:00:00+08:00","from":"planned","to":"in_progress","by":"seed"}] }
EOF
}

echo "REQ-002.5a 验收 —— skill: $SKILL_DIR"
echo "临时工作目录: $WORK"
echo

CS="$SCRIPTS/cycle-state.mjs"
VL="$SCRIPTS/verify-layout.mjs"

# ---------------------------------------------------------------- 前置检查
if [ ! -f "$CS" ]; then
  echo "致命：找不到 $CS —— 实现尚未交付，验收中止。" >&2
  exit 2
fi

# ---------------------------------------------------------------- AC-001
D="$WORK/ac001"; mkdir -p "$D"
if node "$CS" init "$D/cycles/R1-REQ-001" --cycle-id R1-REQ-001 --round R1 \
      --round-type new-requirement --requirement REQ-001 --scope functional --by dev >/dev/null 2>&1 \
   && node "$CS" show "$D/cycles/R1-REQ-001" --json > "$D/show.json" 2>/dev/null; then
  ST="$(jget "$D/show.json" status)"
  NEXT="$(jget "$D/show.json" allowed_next 2>/dev/null || jget "$D/show.json" next 2>/dev/null)"
  if [ "$ST" = "planned" ] && echo "$NEXT" | grep -q "in_progress" && echo "$NEXT" | grep -q "cancelled"; then
    ok "AC-001 show 读出当前状态与允许的下一步"
  else
    bad "AC-001 show 读出当前状态与允许的下一步" "status=$ST next=$NEXT（应为 planned 且含 in_progress/cancelled）"
  fi
else
  bad "AC-001 show 读出当前状态与允许的下一步" "init 或 show 执行失败"
fi

# ---------------------------------------------------------------- AC-002
D="$WORK/ac002"; mkdir -p "$D"
node "$CS" init "$D/R1-REQ-001" --cycle-id R1-REQ-001 --round R1 --round-type new-requirement \
  --requirement REQ-001 --scope functional --by dev >/dev/null 2>&1
if node "$CS" advance "$D/R1-REQ-001" --to in_progress --by dev-agent-1 >/dev/null 2>&1; then
  ST="$(jget "$D/R1-REQ-001/cycle.json" status)"
  LAST="$(jlast "$D/R1-REQ-001/cycle.json" history)"
  N="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).history.length)' "$D/R1-REQ-001/cycle.json")"
  if [ "$ST" = "in_progress" ] && echo "$LAST" | grep -q '"from":"planned"' && echo "$LAST" | grep -q '"to":"in_progress"' && [ "$N" = "2" ]; then
    ok "AC-002 合法推进同时更新 status 与 history"
  else
    bad "AC-002 合法推进同时更新 status 与 history" "status=$ST len=$N last=$LAST"
  fi
else
  bad "AC-002 合法推进同时更新 status 与 history" "advance 退出码非 0"
fi

# ---------------------------------------------------------------- AC-003
D="$WORK/ac003"; mkdir -p "$D"
node "$CS" init "$D/R1-REQ-001" --cycle-id R1-REQ-001 --round R1 --round-type new-requirement \
  --requirement REQ-001 --scope functional --by dev >/dev/null 2>&1
BEFORE="$(sha "$D/R1-REQ-001/cycle.json")"
OUT="$(node "$CS" advance "$D/R1-REQ-001" --to completed --by dev-agent-1 2>&1)"; RC=$?
AFTER="$(sha "$D/R1-REQ-001/cycle.json")"
if [ $RC -eq 1 ] && [ "$BEFORE" = "$AFTER" ] && echo "$OUT" | grep -qi "in_progress"; then
  ok "AC-003 非法转移被拒绝且文件零改动"
else
  bad "AC-003 非法转移被拒绝且文件零改动" "rc=$RC sha相同=$([ "$BEFORE" = "$AFTER" ] && echo yes || echo no) out=$OUT"
fi

# ---------------------------------------------------------------- AC-004
D="$WORK/ac004"; mkdir -p "$D"
node "$CS" init "$D/R1-REQ-001" --cycle-id R1-REQ-001 --round R1 --round-type new-requirement \
  --requirement REQ-001 --scope functional --by dev >/dev/null 2>&1
node "$CS" advance "$D/R1-REQ-001" --to in_progress --by dev >/dev/null 2>&1
node "$CS" advance "$D/R1-REQ-001" --to blocked --by dev >/dev/null 2>&1
if node "$CS" advance "$D/R1-REQ-001" --to in_progress --by dev-agent-1 >/dev/null 2>&1; then
  ST="$(jget "$D/R1-REQ-001/cycle.json" status)"
  LAST="$(jlast "$D/R1-REQ-001/cycle.json" history)"
  if [ "$ST" = "in_progress" ] && echo "$LAST" | grep -q '"to":"in_progress"'; then
    ok "AC-004 blocked → in_progress 允许解除阻塞"
  else
    bad "AC-004 blocked → in_progress 允许解除阻塞" "status=$ST last=$LAST"
  fi
else
  bad "AC-004 blocked → in_progress 允许解除阻塞" "advance 退出码非 0"
fi

# ---------------------------------------------------------------- AC-005
D="$WORK/ac005"; mkdir -p "$D"
TERM_OK=1
for TERM in completed cancelled; do
  T="$D/$TERM"; mkdir -p "$T"
  node "$CS" init "$T/R1-$TERM" --cycle-id "R1-$TERM" --round R1 --round-type new-requirement \
    --requirement REQ-001 --scope functional --by dev >/dev/null 2>&1
  node "$CS" advance "$T/R1-$TERM" --to in_progress --by dev >/dev/null 2>&1
  node "$CS" advance "$T/R1-$TERM" --to "$TERM" --by dev >/dev/null 2>&1
  BEFORE="$(sha "$T/R1-$TERM/cycle.json")"
  node "$CS" advance "$T/R1-$TERM" --to in_progress --by dev >/dev/null 2>&1; RC=$?
  AFTER="$(sha "$T/R1-$TERM/cycle.json")"
  if [ $RC -ne 1 ] || [ "$BEFORE" != "$AFTER" ]; then
    TERM_OK=0
    bad "AC-005 终态不可离开" "$TERM 未被正确拒绝 (rc=$RC)"
  fi
done
[ $TERM_OK -eq 1 ] && ok "AC-005 终态不可离开"

# ---------------------------------------------------------------- AC-006
D="$WORK/ac006"; mkdir -p "$D"
node "$CS" init "$D/R1-REQ-001" --cycle-id R1-REQ-001 --round R1 --round-type new-requirement \
  --requirement REQ-001 --scope functional --by dev >/dev/null 2>&1
BEFORE="$(sha "$D/R1-REQ-001/cycle.json")"
# 两例都带 --by：缺 --by 会以 exit 2（调用方式错误）退出，那测的是参数必填而非理由非空
node "$CS" skip-scope "$D/R1-REQ-001" --scope load --by dev-agent-1 >/dev/null 2>&1; RC1=$?
node "$CS" skip-scope "$D/R1-REQ-001" --scope load --reason "" --by dev-agent-1 >/dev/null 2>&1; RC2=$?
AFTER="$(sha "$D/R1-REQ-001/cycle.json")"
SKIPPED="$(jget "$D/R1-REQ-001/cycle.json" scopes_skipped)"
if [ $RC1 -ne 0 ] && [ $RC2 -ne 0 ] && [ "$BEFORE" = "$AFTER" ] && { [ "$SKIPPED" = "[]" ] || [ -z "$SKIPPED" ]; }; then
  ok "AC-006 skip-scope 强制非空理由"
else
  bad "AC-006 skip-scope 强制非空理由" "rc1=$RC1 rc2=$RC2 sha相同=$([ "$BEFORE" = "$AFTER" ] && echo yes || echo no) skipped=$SKIPPED"
fi

# ---------------------------------------------------------------- AC-007
D="$WORK/ac007"; mkdir -p "$D"
node "$CS" init "$D/R1-REQ-001" --cycle-id R1-REQ-001 --round R1 --round-type new-requirement \
  --requirement REQ-001 --scope functional --by dev >/dev/null 2>&1
if node "$CS" skip-scope "$D/R1-REQ-001" --scope load --reason "需求未给性能指标，无阈值可依" --by dev-agent-1 >/dev/null 2>&1; then
  SK="$(jget "$D/R1-REQ-001/cycle.json" scopes_skipped 0)"
  if echo "$SK" | grep -q '"scope":"load"' && echo "$SK" | grep -q '需求未给性能指标'; then
    ok "AC-007 skip-scope 正常写入"
  else
    bad "AC-007 skip-scope 正常写入" "scopes_skipped[0]=$SK"
  fi
else
  bad "AC-007 skip-scope 正常写入" "skip-scope 退出码非 0"
fi

# ---------------------------------------------------------------- AC-008
D="$WORK/ac008"; mkdir -p "$D"
node "$CS" init "$D/R1-REQ-001" --cycle-id R1-REQ-001 --round R1 --round-type new-requirement \
  --requirement REQ-001 --scope functional --by dev >/dev/null 2>&1
if node "$CS" set-stage "$D/R1-REQ-001" --stage design --status done >/dev/null 2>&1; then
  SS="$(jget "$D/R1-REQ-001/cycle.json" stages design status)"
  if [ "$SS" = "done" ]; then
    ok "AC-008 set-stage 写入阶段状态"
  else
    bad "AC-008 set-stage 写入阶段状态" "stages.design.status=$SS"
  fi
else
  bad "AC-008 set-stage 写入阶段状态" "set-stage 退出码非 0"
fi

# ---------------------------------------------------------------- AC-009
D="$WORK/ac009"; mkdir -p "$D"
if node "$CS" init "$D/cycles/R1-REQ-002" --cycle-id R1-REQ-002 --round R1 \
      --round-type new-requirement --requirement REQ-002 --scope functional --by dev-agent-1 >/dev/null 2>&1; then
  CID="$(jget "$D/cycles/R1-REQ-002/cycle.json" cycle_id)"
  RQ="$(jget "$D/cycles/R1-REQ-002/cycle.json" requirement)"
  ST="$(jget "$D/cycles/R1-REQ-002/cycle.json" status)"
  HN="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).history.length)' "$D/cycles/R1-REQ-002/cycle.json")"
  H0="$(jget "$D/cycles/R1-REQ-002/cycle.json" history 0)"
  if [ "$CID" = "R1-REQ-002" ] && [ "$RQ" = "REQ-002" ] && [ "$ST" = "planned" ] && [ "$HN" = "1" ] \
     && echo "$H0" | grep -q '"from":"planned"' && echo "$H0" | grep -q '"to":"planned"'; then
    ok "AC-009 init 造出契约合法的新轮次"
  else
    bad "AC-009 init 造出契约合法的新轮次" "id=$CID req=$RQ status=$ST history_len=$HN h0=$H0"
  fi
else
  bad "AC-009 init 造出契约合法的新轮次" "init 退出码非 0"
fi

# ---------------------------------------------------------------- AC-010
D="$WORK/ac010"; mkdir -p "$D"
node "$CS" init "$D/R1-REQ-001" --cycle-id R1-REQ-001 --round R1 --round-type new-requirement \
  --requirement REQ-001 --scope functional --by dev >/dev/null 2>&1
node "$CS" advance "$D/R1-REQ-001" --to in_progress --by dev >/dev/null 2>&1
PARSE="$(node -e 'try{JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log("ok")}catch(e){console.log("fail")}' "$D/R1-REQ-001/cycle.json")"
LEFTOVER="$(ls -a "$D/R1-REQ-001" | grep -Ev '^(\.|\.\.|cycle\.json)$' | tr '\n' ' ')"
if [ "$PARSE" = "ok" ] && [ -z "$(echo "$LEFTOVER" | tr -d ' ')" ]; then
  ok "AC-010 原子写 —— 合法 JSON 且无残留临时文件"
else
  bad "AC-010 原子写 —— 合法 JSON 且无残留临时文件" "parse=$PARSE 残留=$LEFTOVER"
fi

# ---------------------------------------------------------------- AC-011
D="$WORK/ac011"; mkdir -p "$D"
make_project "$D/proj"
# 篡改: status 与 history 最后一条 to 不一致
node -e '
const fs=require("fs");const f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));
o.status="completed";fs.writeFileSync(f,JSON.stringify(o,null,2));
' "$D/proj/test-assets/cycles/R1-REQ-001/cycle.json"
VL_OUT="$(node "$VL" "$D/proj" 2>&1)"; VL_RC=$?
CS_OUT="$(node "$CS" show "$D/proj/test-assets/cycles/R1-REQ-001" 2>&1)"; CS_RC=$?
if [ $VL_RC -eq 1 ] && echo "$VL_OUT" | grep -qi "history" && echo "$CS_OUT" | grep -qi "history"; then
  ok "AC-011 推进器与校验器行为一致（status↔history）"
else
  bad "AC-011 推进器与校验器行为一致（status↔history）" "vl_rc=$VL_RC vl_out=$VL_OUT / cs_rc=$CS_RC cs_out=$CS_OUT"
fi

# ---------------------------------------------------------------- AC-012
# 保守判据: 转移表/终态判定的实现必须只出现在 lib/state-machine.mjs；
# verify-layout.mjs 必须 import 它，且不得自带状态字面量（否则存在第二份实现）
SM="$SCRIPTS/lib/state-machine.mjs"
if [ ! -f "$SM" ]; then
  bad "AC-012 校验器复用共享状态机模块" "缺少 $SM"
elif ! grep -q "state-machine" "$VL"; then
  bad "AC-012 校验器复用共享状态机模块" "verify-layout.mjs 未 import state-machine"
else
  SM_STATES="$(grep -o -E "'(planned|in_progress|completed|blocked|cancelled)'|\"(planned|in_progress|completed|blocked|cancelled)\"" "$SM" | sort -u | wc -l)"
  VL_LITERALS="$(grep -c -E "'(planned|in_progress|completed|blocked|cancelled)'|\"(planned|in_progress|completed|blocked|cancelled)\"" "$VL")"
  if [ "$SM_STATES" -ge 5 ] && [ "$VL_LITERALS" -eq 0 ]; then
    ok "AC-012 校验器复用共享状态机模块（无第二份实现）"
  else
    bad "AC-012 校验器复用共享状态机模块（无第二份实现）" "state-machine 中状态数=$SM_STATES，verify-layout 中状态字面量行数=$VL_LITERALS"
  fi
fi

# ---------------------------------------------------------------- AC-013
DOC="$REFS/project-layout.md"
if [ ! -f "$DOC" ]; then
  bad "AC-013 契约文档补齐 cycle.json 字段表" "缺少 $DOC"
else
  HAS_TABLE="$(grep -c -E '^\|.*`cycle_id`|^\|.*cycle_id.*\|' "$DOC")"
  HAS_REQ="$(grep -c -E '^\|.*`requirement`' "$DOC")"
  HAS_FIELD_ROW="$(grep -c -E '^\| *`?(cycle_id|requirement)`? *\|' "$DOC")"
  if [ "$HAS_REQ" -ge 1 ] && [ "$HAS_FIELD_ROW" -ge 1 ]; then
    ok "AC-013 契约文档补齐 cycle.json 字段表"
  else
    bad "AC-013 契约文档补齐 cycle.json 字段表" "cycle_id 行=$HAS_TABLE requirement 行=$HAS_REQ 字段表行=$HAS_FIELD_ROW"
  fi
fi

# ---------------------------------------------------------------- AC-014
D="$WORK/ac014"; mkdir -p "$D"
make_project "$D/proj"
make_cycle_from_doc "$D/proj/test-assets/cycles/R1-REQ-001/cycle.json"
OUT="$(node "$VL" "$D/proj" 2>&1)"; RC=$?
if [ $RC -eq 0 ] && ! echo "$OUT" | grep -q "requirement 缺少必填字段"; then
  ok "AC-014 按文档构造的 cycle.json 能通过校验（原缺陷回归验证）"
else
  bad "AC-014 按文档构造的 cycle.json 能通过校验（原缺陷回归验证）" "rc=$RC out=$OUT"
fi

# ---------------------------------------------------------------- AC-015
SK="$SKILL_DIR/SKILL.md"
MISSING=""
for tok in "verify-layout.mjs" "cycle-state.mjs" "project-layout.md" "state-machine.md"; do
  grep -q "$tok" "$SK" 2>/dev/null || MISSING="$MISSING $tok"
done
LOCK="$(grep -c -E "只由脚本写|不得(直接)?(手)?改|禁止(直接)?(手)?改|唯一写入" "$SK")"
if [ -z "$MISSING" ] && [ "$LOCK" -ge 1 ]; then
  ok "AC-015 SKILL.md 含全部脚本入口与写入权硬约束"
else
  bad "AC-015 SKILL.md 含全部脚本入口与写入权硬约束" "缺少入口:$MISSING 写入权约束命中数=$LOCK"
fi

# ---------------------------------------------------------------- AC-016
PKG="$(cd "$SKILL_DIR" && cd ../.. && pwd)/package.json"
DEPS="n/a"
[ -f "$PKG" ] && DEPS="$(node -e 'const p=require(process.argv[1]);console.log(Object.keys(p.dependencies||{}).length)' "$PKG" 2>/dev/null)"
EXT="$(grep -c -E "child_process|execSync|spawnSync|/tmp/" "$CS" 2>/dev/null)"
BASHY="$(grep -c -E "python3|grep |sed " "$CS" 2>/dev/null)"
JSONOK="$(node -e '
const {execFileSync}=require("child_process");
const cs=process.argv[1], dir=process.argv[2];
try{
  execFileSync("node",[cs,"init",dir,"--cycle-id","R1-REQ-001","--round","R1",
    "--round-type","new-requirement","--requirement","REQ-001","--scope","functional","--by","dev"],
    {encoding:"utf8",stdio:["ignore","pipe","ignore"]});
  const o=execFileSync("node",[cs,"show",dir,"--json"],{encoding:"utf8",stdio:["ignore","pipe","ignore"]});
  JSON.parse(o);console.log("ok");
}catch(e){console.log("fail");}
' "$CS" "$WORK/ac016c/R1-REQ-001" 2>/dev/null)"
if [ "$DEPS" = "0" ] && [ "$EXT" = "0" ] && [ "$BASHY" = "0" ] && [ "$JSONOK" = "ok" ]; then
  ok "AC-016 零依赖 + 可移植 + agent 友好"
else
  bad "AC-016 零依赖 + 可移植 + agent 友好" "deps=$DEPS 外部调用行=$EXT bash式行=$BASHY json=$JSONOK"
fi

# ---------------------------------------------------------------- AC-017
# 既有缺陷 2: 环境 name 与文件名不一致未被拦截
D="$WORK/ac017"; mkdir -p "$D"
make_project "$D/proj"
node -e '
const fs=require("fs"),f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));
o.name="other";fs.writeFileSync(f,JSON.stringify(o,null,2));
' "$D/proj/test-assets/environments/local.json"
OUT="$(node "$VL" "$D/proj" 2>&1)"; RC=$?
if [ $RC -eq 1 ] && echo "$OUT" | grep -qi "name"; then
  ok "AC-017 环境 name 与文件名必须一致"
else
  bad "AC-017 环境 name 与文件名必须一致" "rc=$RC out=$OUT"
fi

# ---------------------------------------------------------------- AC-018
# 既有缺陷 3: history 每条缺 at/from/to/by 未被拦截
D="$WORK/ac018"; mkdir -p "$D"
FIELD_OK=1
for F in at from to by; do
  T="$D/$F"; make_project "$T"
  node -e '
  const fs=require("fs"),f=process.argv[1],k=process.argv[2];
  const o=JSON.parse(fs.readFileSync(f,"utf8"));
  delete o.history[0][k];
  fs.writeFileSync(f,JSON.stringify(o,null,2));
  ' "$T/test-assets/cycles/R1-REQ-001/cycle.json" "$F"
  OUT="$(node "$VL" "$T" 2>&1)"; RC=$?
  if [ $RC -ne 1 ] || ! echo "$OUT" | grep -qi "$F"; then
    FIELD_OK=0
    bad "AC-018 history 每条记录四个必填字段齐备" "缺 $F 时 rc=$RC（应为 1 且报错含字段名）out=$OUT"
  fi
done
# 不得回归: 空 history 与非法 from 仍须被拦（两例各用独立副本）
T1="$D/regress-empty"; make_project "$T1"
node -e 'const fs=require("fs"),f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));o.history=[];fs.writeFileSync(f,JSON.stringify(o,null,2))' "$T1/test-assets/cycles/R1-REQ-001/cycle.json"
node "$VL" "$T1" >/dev/null 2>&1; R1=$?
T2="$D/regress-enum"; make_project "$T2"
node -e 'const fs=require("fs"),f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));o.history[0].from="bogus";fs.writeFileSync(f,JSON.stringify(o,null,2))' "$T2/test-assets/cycles/R1-REQ-001/cycle.json"
node "$VL" "$T2" >/dev/null 2>&1; R2=$?
if [ $FIELD_OK -eq 1 ] && [ $R1 -ne 0 ] && [ $R2 -ne 0 ]; then
  ok "AC-018 history 每条记录四个必填字段齐备"
fi

# ---------------------------------------------------------------- AC-019
# skip-scope 的记录须含 at 与 by；--by 必填
D="$WORK/ac019"; mkdir -p "$D"
node "$CS" init "$D/R1-REQ-001" --cycle-id R1-REQ-001 --round R1 --round-type new-requirement \
  --requirement REQ-001 --scope functional --by dev >/dev/null 2>&1
# 1) 带 --by 应成功且四字段齐备
if node "$CS" skip-scope "$D/R1-REQ-001" --scope load --reason "需求未给性能指标，无阈值可依" --by dev-agent-1 >/dev/null 2>&1; then
  SK="$(jget "$D/R1-REQ-001/cycle.json" scopes_skipped 0)"
  if echo "$SK" | grep -q '"scope":"load"' && echo "$SK" | grep -q '"reason"' \
     && echo "$SK" | grep -q '"at"' && echo "$SK" | grep -q '"by":"dev-agent-1"'; then
    ok "AC-019 skip-scope 记录含 at 与 by"
  else
    bad "AC-019 skip-scope 记录含 at 与 by" "scopes_skipped[0]=$SK（应含 scope/reason/at/by 四字段）"
  fi
else
  bad "AC-019 skip-scope 记录含 at 与 by" "带 --by 的 skip-scope 退出码非 0"
fi
# 2) 不带 --by 应被拒绝且文件不修改
D2="$WORK/ac019-noby"; mkdir -p "$D2"
node "$CS" init "$D2/R1-REQ-001" --cycle-id R1-REQ-001 --round R1 --round-type new-requirement \
  --requirement REQ-001 --scope functional --by dev >/dev/null 2>&1
BEFORE="$(sha "$D2/R1-REQ-001/cycle.json")"
node "$CS" skip-scope "$D2/R1-REQ-001" --scope load --reason "x" >/dev/null 2>&1; RC=$?
AFTER="$(sha "$D2/R1-REQ-001/cycle.json")"
if [ $RC -ne 0 ] && [ "$BEFORE" = "$AFTER" ]; then
  ok "AC-019 skip-scope 缺 --by 被拒且文件零改动"
else
  bad "AC-019 skip-scope 缺 --by 被拒且文件零改动" "rc=$RC sha相同=$([ "$BEFORE" = "$AFTER" ] && echo yes || echo no)"
fi

# ---------------------------------------------------------------- AC-020
# 缺陷 4: SKILL.md 的 Output contract 未同步 schema v2
SK="$SKILL_DIR/SKILL.md"
V2MISS=""
for tok in "schema_version" "open_questions" "coverage_matrix" "method" "status"; do
  grep -q "$tok" "$SK" 2>/dev/null || V2MISS="$V2MISS $tok"
done
# 声明 v2 后缺字段必须 ERROR（证明 SKILL.md 说的"声明了就会被严格校验"为真）
D="$WORK/ac020"; mkdir -p "$D"
node -e '
const fs=require("fs"),f=process.argv[1];
const o={schema_version:2,
  meta:{source:"t",generated_at:"2026-11-11T18:00:00+08:00",case_count:1},
  requirements:[{id:"R-1",title:"t",source_ref:"x",testable:true}],
  cases:[{id:"TC-001",title:"t",requirement_refs:["R-1"],dimension:"functional",priority:"P0",
    method:["M0.1"],status:"active",steps:[{action:"a",expected:"b"}]}]};
fs.writeFileSync(f,JSON.stringify(o,null,2));
' "$D/nov2fields.json"
node "$SKILL_DIR/scripts/validate-cases.mjs" "$D/nov2fields.json" >/dev/null 2>&1; RC_STRICT=$?
# 不声明 v2 时只 WARN，exit 0（向后兼容）
node -e '
const fs=require("fs"),f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));
delete o.schema_version;fs.writeFileSync(f,JSON.stringify(o,null,2));
' "$D/nov2fields.json"
node "$SKILL_DIR/scripts/validate-cases.mjs" "$D/nov2fields.json" >/dev/null 2>&1; RC_LOOSE=$?
if [ -z "$V2MISS" ] && [ $RC_STRICT -eq 1 ] && [ $RC_LOOSE -eq 0 ]; then
  ok "AC-020 SKILL.md 的 Output contract 已同步 schema v2"
else
  bad "AC-020 SKILL.md 的 Output contract 已同步 schema v2" "未提及:$V2MISS 声明v2后exit=$RC_STRICT(期望1) 不声明exit=$RC_LOOSE(期望0)"
fi

# ---------------------------------------------------------------- AC-021
# 缺陷 4: 校验器可生成字段齐备的 v2 骨架
D="$WORK/ac021"; mkdir -p "$D"
INIT_OUT=""
for FLAG in "--init" "--template" "init" "--skeleton"; do
  node "$SKILL_DIR/scripts/validate-cases.mjs" $FLAG > "$D/skel.json" 2>/dev/null
  if node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$D/skel.json" 2>/dev/null; then
    INIT_OUT="$FLAG"; break
  fi
done
if [ -n "$INIT_OUT" ]; then
  HAS_SV="$(node -e 'const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(o.schema_version===2?"yes":"no")' "$D/skel.json")"
  HAS_KEYS="$(node -e '
  const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const need=["schema_version","requirements","open_questions","coverage_matrix","cases"];
  console.log(need.every(k=>k in o)?"yes":"no");
  ' "$D/skel.json")"
  node "$SKILL_DIR/scripts/validate-cases.mjs" "$D/skel.json" >/dev/null 2>&1; RC_SKEL=$?
  if [ "$HAS_SV" = "yes" ] && [ "$HAS_KEYS" = "yes" ] && [ $RC_SKEL -eq 0 ]; then
    ok "AC-021 校验器可生成字段齐备的 v2 骨架（$INIT_OUT）"
  else
    bad "AC-021 校验器可生成字段齐备的 v2 骨架" "flag=$INIT_OUT schema_version=$HAS_SV 字段齐备=$HAS_KEYS 骨架校验exit=$RC_SKEL(期望0)"
  fi
else
  bad "AC-021 校验器可生成字段齐备的 v2 骨架" "未找到可用的骨架生成入口（试过 --init/--template/init/--skeleton）"
fi

# ---------------------------------------------------------------- AC-022
# QA P1: cycle.json 与 index.json 的状态一致性 + 失败回滚
D="$WORK/ac022"; mkdir -p "$D"
make_project "$D/proj"
# (a) index 与 cycle 状态不一致 -> 校验器必须拦
node -e '
const fs=require("fs"),f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));
o.cycles[0].status="planned";fs.writeFileSync(f,JSON.stringify(o,null,2));
' "$D/proj/test-assets/cycles/index.json"
OUT="$(node "$VL" "$D/proj" 2>&1)"; RC=$?
A_OK=0
if [ $RC -eq 1 ]; then A_OK=1; fi
# (b) index 写失败时 cycle.json 必须回滚
D2="$WORK/ac022b"; mkdir -p "$D2"
make_project "$D2/proj"
chmod 555 "$D2/proj/test-assets/cycles" 2>/dev/null
BEFORE="$(sha "$D2/proj/test-assets/cycles/R1-REQ-001/cycle.json")"
node "$CS" advance "$D2/proj/test-assets/cycles/R1-REQ-001" --to completed --by dev >/dev/null 2>&1; RC2=$?
AFTER="$(sha "$D2/proj/test-assets/cycles/R1-REQ-001/cycle.json")"
chmod 755 "$D2/proj/test-assets/cycles" 2>/dev/null
B_OK=0
if [ $RC2 -ne 0 ] && [ "$BEFORE" = "$AFTER" ]; then B_OK=1; fi
if [ $A_OK -eq 1 ] && [ $B_OK -eq 1 ]; then
  ok "AC-022 cycle.json 与 index.json 的状态一致性（含失败回滚）"
else
  bad "AC-022 cycle.json 与 index.json 的状态一致性（含失败回滚）" "index不一致拦截=$A_OK 失败回滚=$B_OK (rc=$RC2 sha相同=$([ "$BEFORE" = "$AFTER" ] && echo yes || echo no)) out=$OUT"
fi

# ---------------------------------------------------------------- AC-023
# QA P2: 推进器与校验器对 scopes_skipped 缺陷报告一致
# 注意: 校验器对注入缺陷必须"拦"(退出码非0)。用 && 判"被放行"(退出码0)才是逃逸。
D="$WORK/ac023"; mkdir -p "$D"
INJ_OK=1
for DEF in "delete o.scopes_skipped[0].at" "delete o.scopes_skipped[0].by" "o.scopes_skipped[0].reason=''"; do
  T="$D/$(echo "$DEF" | md5sum | cut -c1-8)"; mkdir -p "$T"
  # 造合法项目（轮次必须在 test-assets/cycles/ 下，否则校验器只会报 test-assets 缺失，
  # 那样 fail 的原因就不是注入的缺陷，信号无效）
  make_project "$T"
  CYC2="$T/test-assets/cycles/R1-REQ-001"
  node -e "
const fs=require('fs'),f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,'utf8'));
o.scopes_skipped=[{scope:'load',reason:'无阈值可依',at:'2026-11-11T18:00:00+08:00',by:'dev-agent-1'}];
$DEF
fs.writeFileSync(f,JSON.stringify(o,null,2));
" "$CYC2/cycle.json"
  # 校验器必须拦: 退出码 0 = 放行 = 逃逸
  if node "$VL" "$T" >/dev/null 2>&1; then
    INJ_OK=0; echo "    逃逸(校验器未拦): $DEF"; continue
  fi
  # 推进器四个子命令必须全部拒绝(退出码非0)，且不得写坏文件
  SB="$(sha "$CYC2/cycle.json")"
  node "$CS" show "$CYC2" --json >/dev/null 2>&1 && { INJ_OK=0; echo "    推进器未拦: show"; }
  node "$CS" advance "$CYC2" --to completed --by dev >/dev/null 2>&1 && { INJ_OK=0; echo "    推进器未拦: advance"; }
  node "$CS" skip-scope "$CYC2" --scope load --reason "again" --by dev >/dev/null 2>&1 && { INJ_OK=0; echo "    推进器未拦: skip-scope"; }
  node "$CS" set-stage "$CYC2" --stage design --status done >/dev/null 2>&1 && { INJ_OK=0; echo "    推进器未拦: set-stage"; }
  SA="$(sha "$CYC2/cycle.json")"
  [ "$SB" = "$SA" ] || { INJ_OK=0; echo "    推进器写坏了文件: $DEF"; }
done
if [ $INJ_OK -eq 1 ]; then
  ok "AC-023 推进器与校验器对 scopes_skipped 缺陷报告一致"
else
  bad "AC-023 推进器与校验器对 scopes_skipped 缺陷报告一致" "存在推进器未拒绝或写坏文件的注入用例"
fi

# ---------------------------------------------------------------- AC-024
# QA P3: 契约字段缺失/类型错/非法枚举被拦（8 例）
D="$WORK/ac024"; mkdir -p "$D"
TYP_OK=1
run_mut() { # $1=用例名 $2=变异 JS
  local d="$D/$1"; mkdir -p "$D"; make_project "$d"
  node -e "
const fs=require('fs'),f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,'utf8'));
$2
fs.writeFileSync(f,JSON.stringify(o,null,2));
" "$d/test-assets/cycles/R1-REQ-001/cycle.json" 2>/dev/null
  # 校验器必须拦: 退出码 0 = 放行 = 逃逸
  if node "$VL" "$d" >/dev/null 2>&1; then TYP_OK=0; echo "    逃逸: $1"; fi
}
run_mut "stages-status缺失"   "o.stages.design={};"
run_mut "stages-status类型错" "o.stages.design.status=123;"
run_mut "stages-status枚举非法" "o.stages.design.status='finished';"
run_mut "artifacts非数组"      "o.stages.design.artifacts='notarray';"
run_mut "scopes非数组"         "o.scopes='string';"
run_mut "scopes_skipped非数组"  "o.scopes_skipped='string';"
run_mut "trigger非对象"        "o.trigger='string';"
run_mut "round类型错"          "o.round=123;"
if [ $TYP_OK -eq 1 ]; then
  ok "AC-024 stages/status/类型错与非法枚举被拦（8 例）"
else
  bad "AC-024 stages/status/类型错与非法枚举被拦（8 例）" "有逃逸项"
fi

# ---------------------------------------------------------------- AC-025
# QA P3: suite.json 顶层字段封闭
D="$WORK/ac025"; mkdir -p "$D"
make_project "$D/proj"
node -e '
const fs=require("fs"),f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));
o.load_scenario="scenarios/checkout.json";fs.writeFileSync(f,JSON.stringify(o,null,2));
' "$D/proj/test-assets/suites/REQ-001-coupon/suite.json"
OUT="$(node "$VL" "$D/proj" 2>&1)"; RC=$?
if [ $RC -eq 1 ]; then
  ok "AC-025 suite.json 顶层字段封闭"
else
  bad "AC-025 suite.json 顶层字段封闭" "rc=$RC（期望1）out=$OUT"
fi

# ---------------------------------------------------------------- AC-026
# QA P4: SKILL.md 含全部子命令与可复制调用序列
SK="$SKILL_DIR/SKILL.md"
CMDMISS=""
for c in init show advance skip-scope set-stage; do
  grep -q -- "$c" "$SK" 2>/dev/null || CMDMISS="$CMDMISS $c"
done
SEQ="$(grep -c -E 'cycle-state\.mjs (init|show|advance|skip-scope|set-stage)' "$SK")"
if [ -z "$CMDMISS" ] && [ "$SEQ" -ge 2 ]; then
  ok "AC-026 SKILL.md 含全部子命令与可复制的完整调用序列"
else
  bad "AC-026 SKILL.md 含全部子命令与可复制的完整调用序列" "缺子命令:$CMDMISS 可复制命令行数=$SEQ"
fi

# ---------------------------------------------------------------- AC-027
# QA P5: --json 在 usage 错误时 stdout 仍是合法 JSON
D="$WORK/ac027"; mkdir -p "$D"
node "$CS" init "$D/R1-REQ-001" --cycle-id R1-REQ-001 --round R1 --round-type new-requirement \
  --requirement REQ-001 --scope functional --by dev >/dev/null 2>&1
node "$CS" advance "$D/R1-REQ-001" --json --bogus 1 > "$D/out.json" 2>/dev/null; RC=$?
JSONOK="$(node -e 'try{JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log("ok")}catch(e){console.log("fail")}' "$D/out.json")"
if [ $RC -eq 2 ] && [ "$JSONOK" = "ok" ]; then
  ok "AC-027 --json 在 usage 错误时 stdout 仍是合法 JSON"
else
  bad "AC-027 --json 在 usage 错误时 stdout 仍是合法 JSON" "rc=$RC(期望2) json=$JSONOK"
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
