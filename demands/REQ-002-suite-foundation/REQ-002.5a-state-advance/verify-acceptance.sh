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
  LAST="$(jget "$D/R1-REQ-001/cycle.json" history -1 2>/dev/null)"
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
  LAST="$(jget "$D/R1-REQ-001/cycle.json" history -1 2>/dev/null)"
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
node "$CS" skip-scope "$D/R1-REQ-001" --scope load >/dev/null 2>&1; RC1=$?
node "$CS" skip-scope "$D/R1-REQ-001" --scope load --reason "" >/dev/null 2>&1; RC2=$?
AFTER="$(sha "$D/R1-REQ-001/cycle.json")"
SKIPPED="$(jget "$D/R1-REQ-001/cycle.json" scopes_skipped)"
if [ $RC1 -eq 1 ] && [ $RC2 -eq 1 ] && [ "$BEFORE" = "$AFTER" ] && [ "$SKIPPED" = "[]" ] || [ -z "$SKIPPED" ]; then
  ok "AC-006 skip-scope 强制非空理由"
else
  bad "AC-006 skip-scope 强制非空理由" "rc1=$RC1 rc2=$RC2 sha相同=$([ "$BEFORE" = "$AFTER" ] && echo yes || echo no) skipped=$SKIPPED"
fi

# ---------------------------------------------------------------- AC-007
D="$WORK/ac007"; mkdir -p "$D"
node "$CS" init "$D/R1-REQ-001" --cycle-id R1-REQ-001 --round R1 --round-type new-requirement \
  --requirement REQ-001 --scope functional --by dev >/dev/null 2>&1
if node "$CS" skip-scope "$D/R1-REQ-001" --scope load --reason "需求未给性能指标，无阈值可依" >/dev/null 2>&1; then
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
try{
  const o=execFileSync("node",[process.argv[1],"show",process.argv[2],"--json"],{encoding:"utf8",stdio:["ignore","pipe","ignore"]});
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
# 不得回归: 空 history 与非法 from 仍须被拦
T="$D/regress"; make_project "$T"
node -e 'const fs=require("fs"),f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));o.history=[];fs.writeFileSync(f,JSON.stringify(o,null,2))' "$T/test-assets/cycles/R1-REQ-001/cycle.json"
R1=$?; node "$VL" "$T" >/dev/null 2>&1 || R1=0
node -e 'const fs=require("fs"),f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,"utf8"));o.history[0].from="bogus";fs.writeFileSync(f,JSON.stringify(o,null,2))' "$T/test-assets/cycles/R1-REQ-001/cycle.json"
node "$VL" "$T" >/dev/null 2>&1; R2=$?
if [ $FIELD_OK -eq 1 ] && [ $R1 -ne 0 ] && [ $R2 -ne 0 ]; then
  ok "AC-018 history 每条记录四个必填字段齐备"
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
