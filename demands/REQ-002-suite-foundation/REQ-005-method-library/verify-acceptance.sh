#!/usr/bin/env bash
# REQ-005 验收脚本 —— 测试方法库（数据化）+ SKILL.md 重写
#
# 用法: verify-acceptance.sh <test-case-design-dir>
#   <test-case-design-dir> 即 skills/test-case-design/ 的路径
#
# 退出码: 0 = 全部通过; 1 = 有 AC 未通过
#
# 说明:
#   - AC-011 会**注入变异**验证本脚本不是恒真：每条护栏都必须"拦得住"，
#     否则对应 AC 判 FAIL。
#   - 只读 skill 目录；测试用例集一律造在临时目录里。
#   - 本脚本会造几组合法/非法用例集来驱动 check-methods.mjs。

set -uo pipefail

TCD="${1:?用法: verify-acceptance.sh <test-case-design-dir>}"
TCD="$(cd "$TCD" 2>/dev/null && pwd)" || { echo "目录不存在: $1" >&2; exit 2; }

CM="$TCD/scripts/check-methods.mjs"
VC="$TCD/scripts/validate-cases.mjs"
MTH="$TCD/references/methods.json"
DIM="$TCD/references/dimensions.json"
DIMDOC="$TCD/references/coverage-dimensions.md"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qa-005-XXXXXX")"
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

# ---------------------------------------------------------------- 用例集工厂
# 造一个 schema v2 用例集：$1=输出文件 $2=用例 JSON 数组 $3=coverage_matrix JSON 数组
mkcases() {
  local f="$1" cases="$2" matrix="$3"
  local n
  n="$(printf '%s' "$cases" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).length)}catch(e){console.log(0)}})')"
  printf '{\n  "schema_version": 2,\n  "meta": { "source": "qa-005", "generated_at": "2026-11-11T19:00:00+08:00", "case_count": %s },\n  "requirements": [ { "id": "R-1", "title": "密码长度 8-20 位", "source_ref": "x", "testable": true } ],\n  "open_questions": [],\n  "coverage_matrix": %s,\n  "cases": %s\n}\n' "$n" "$matrix" "$cases" > "$f"
}

# 一条用例：$1=id $2=title $3=dimension $4=steps JSON
mkcase() {
  printf '{ "id": "%s", "title": "%s", "requirement_refs": ["R-1"], "dimension": "%s", "priority": "P0", "method": ["M1.1"], "status": "active", "steps": %s }' "$1" "$2" "$3" "$4"
}

# 一条断言式 step：$1=action $2=path $3=op $4=expected
astep() {
  printf '{ "action": "%s", "expected": { "path": "%s", "op": "%s", "expected": %s } }' "$1" "$2" "$3" "$4"
}

# ---------------------------------------------------------------- AC-001
step "AC-001 methods.json 存在且结构合法"
if [ ! -f "$MTH" ]; then
  bad "AC-001 methods.json 存在且结构合法" "缺 references/methods.json"
else
  OUT="$(node "$CM" --methods "$MTH" --selftest 2>&1)"; RC=$?
  N="$(jget "$MTH" methods | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const a=JSON.parse(s);console.log(Array.isArray(a)?a.length:0)}catch(e){console.log(0)}})')"
  # ⚠️ 不能只信实现的 --selftest（那是实现自己验自己）—— BA 侧独立查每条方法的必填字段
  FIELDS="$(node -e '
  const fs=require("fs");
  let o; try{ o=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); }catch(e){ console.log("0 99"); process.exit(0); }
  const ms=Array.isArray(o.methods)?o.methods:[];
  const need=["id","name","applies_when","required_outputs"];
  let bad=0, emptyOut=0, noId=0;
  for(const m of ms){
    if(!m){ bad++; continue; }
    if(!need.every(k=>m[k]!==undefined)) bad++;
    if(!Array.isArray(m.required_outputs)||m.required_outputs.length===0) emptyOut++;
    if(typeof m.id!=="string"||m.id==="") noId++;
  }
  console.log(ms.length+" "+bad+" "+emptyOut+" "+noId);
  ' "$MTH" 2>/dev/null)"
  FN="$(printf '%s' "$FIELDS" | cut -d" " -f1)"
  FB="$(printf '%s' "$FIELDS" | cut -d" " -f2)"
  FE="$(printf '%s' "$FIELDS" | cut -d" " -f3)"
  FI="$(printf '%s' "$FIELDS" | cut -d" " -f4)"
  if [ $RC -eq 0 ] && [ "${N:-0}" -ge 6 ] && [ "${FN:-0}" -eq "${N:-0}" ] \
     && [ "${FB:-99}" -eq 0 ] && [ "${FE:-99}" -eq 0 ] && [ "${FI:-99}" -eq 0 ]; then
    ok "AC-001 methods.json 存在且结构合法（$N 种方法，字段与必填产出齐全）"
  else
    bad "AC-001 methods.json 存在且结构合法" \
        "rc=$RC 方法数=$N 字段缺失=$FB(方法数$FN) 空产出=$FE 无id=$FI out=$OUT"
  fi
fi

# ---------------------------------------------------------------- AC-002
step "AC-002 方法库与说明文档一致"
DOC="$TCD/references/design-methods.md"
if [ ! -f "$MTH" ] || [ ! -f "$DOC" ]; then
  bad "AC-002 方法库与说明文档一致" "缺 methods.json 或 design-methods.md"
else
  OUT="$(node "$CM" --methods "$MTH" --doc "$DOC" --check-doc 2>&1)"; RC=$?
  # ⚠️ --check-doc 是实现自己比自己 —— BA 侧再独立查一遍：
  #    说明文档里必须**提到每个方法的 id**（这是"文档跟着数据走"的可判形式）
  MISSING_DOC="$(node -e '
  const fs=require("fs");
  let o; try{ o=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); }catch(e){ console.log("__PARSE_ERR__"); process.exit(0); }
  const doc=fs.readFileSync(process.argv[2],"utf8");
  const ms=Array.isArray(o.methods)?o.methods:[];
  const miss=ms.filter(m=>m&&typeof m.id==="string"&&m.id!==""&&!doc.includes(m.id)).map(m=>m.id);
  console.log(miss.join(","));
  ' "$MTH" "$DOC" 2>/dev/null)"
  if [ $RC -eq 0 ] && [ -z "$MISSING_DOC" ]; then
    ok "AC-002 方法库与说明文档一致"
  else
    bad "AC-002 方法库与说明文档一致" "rc=$RC 文档未提及的方法id=[$MISSING_DOC] out=$OUT"
  fi
fi

# ---------------------------------------------------------------- AC-003 / AC-004
step "AC-003/004 声称用了方法但无对应产出 → 被发现（且不误报）"
# 场景 A：声明用了 M1.2（边界值），但该条目下**没有** boundary 维度的用例 → 应报错
CASES_A="[ $(mkcase TC-001 功能用例 functional "[ $(astep '输入密码' '$.code' 'equals' '"E001"') ]") ]"
MATRIX_A='[ { "requirement": "R-1", "methods_applied": ["M1.2"], "skipped": [], "dimensions": ["functional"] } ]'
mkcases "$WORK/a.json" "$CASES_A" "$MATRIX_A"
OUT_A="$(node "$CM" "$WORK/a.json" --methods "$MTH" 2>&1)"; RC_A=$?
# 场景 B：补上 3 条 boundary 用例，断言取值互不相同 → 不应再报"缺少必需产出"
CASES_B="[ \
$(mkcase TC-001 功能用例 functional "[ $(astep '输入密码' '$.code' 'equals' '"E001"') ]"), \
$(mkcase TC-002 边界下界 boundary "[ $(astep '长度7' '$.len' 'equals' '7') ]"), \
$(mkcase TC-003 边界上界 boundary "[ $(astep '长度8' '$.len' 'equals' '"8"') ]"), \
$(mkcase TC-004 边界越界 boundary "[ $(astep '长度21' '$.len' 'equals' '21') ]") ]"
MATRIX_B='[ { "requirement": "R-1", "methods_applied": ["M1.2"], "skipped": [], "dimensions": ["functional","boundary"] } ]'
mkcases "$WORK/b.json" "$CASES_B" "$MATRIX_B"
OUT_B="$(node "$CM" "$WORK/b.json" --methods "$MTH" 2>&1)"; RC_B=$?
# 场景 B2：三条 boundary 用例的 expected 取值**完全相同** → distinct_expected 谓词必须报错
# （场景 B 的取值互不相同，所以 B 测不出 distinct_expected 是否真的生效；B2 才测得出）
CASES_B2="[ \
$(mkcase TC-002 边界下界 boundary "[ $(astep '长度7' '$.len' 'equals' '7') ]"), \
$(mkcase TC-003 边界上界 boundary "[ $(astep '长度8' '$.len' 'equals' '7') ]"), \
$(mkcase TC-004 边界越界 boundary "[ $(astep '长度21' '$.len' 'equals' '7') ]") ]"
mkcases "$WORK/b2.json" "$CASES_B2" "$MATRIX_B"
OUT_B2="$(node "$CM" "$WORK/b2.json" --methods "$MTH" 2>&1)"; RC_B2=$?

A3=0; A4=0
# 判据：脚本必须**点名**那条方法与那条需求条目，而不是泛泛说"有问题"
# ⚠️ 必须**同行**出现 —— 只查"输出里有两个词"可能命中的是别处的提及
if [ $RC_A -ne 0 ] && printf '%s' "$OUT_A" | grep -qE "M1\.2.*R-1|R-1.*M1\.2"; then A3=1; fi
if [ $RC_B -eq 0 ]; then A4=1; fi
if [ $A3 -eq 1 ]; then
  ok "AC-003 声称用了方法但没有对应产出 → 被发现"
else
  bad "AC-003 声称用了方法但没有对应产出 → 被发现" "rc=$RC_A out=$OUT_A"
fi
if [ $A4 -eq 1 ]; then
  ok "AC-004 方法确实应用了 → 不误报"
else
  bad "AC-004 方法确实应用了 → 不误报" "rc=$RC_B out=$OUT_B"
fi
# AC-003b：distinct_expected 谓词必须**真的生效** —— 同一维度下 expected 取值全相同 → 报错
# （AC-004 的场景 B 取值互不相同，恒成立，查不出这个谓词有没有被实现）
if [ $RC_B2 -ne 0 ]; then
  ok "AC-003b distinct_expected 谓词生效（取值全相同 → 被发现）"
else
  bad "AC-003b distinct_expected 谓词生效" "rc=$RC_B2（期望非0）out=$OUT_B2"
fi

# ---------------------------------------------------------------- AC-005
step "AC-005 适用性检查能发现漏用方法（WARN 不阻断）"
# 需求文本含"长度 8-20 位"这类强边界信号，但 methods_applied 里没有 M1.2
CASES_C="[ $(mkcase TC-001 功能用例 functional "[ $(astep '输入密码' '$.code' 'equals' '"E001"') ]") ]"
MATRIX_C='[ { "requirement": "R-1", "methods_applied": ["M1.1"], "skipped": [], "dimensions": ["functional"] } ]'
mkcases "$WORK/c.json" "$CASES_C" "$MATRIX_C"
OUT_C="$(node "$CM" "$WORK/c.json" --methods "$MTH" 2>&1)"; RC_C=$?
# 必须点名类型 METHOD_MISSING（F3 定死的类型名）—— 只查 "M1.2" 可能命中别处的提及
if [ $RC_C -eq 0 ] && printf '%s' "$OUT_C" | grep -q "METHOD_MISSING" && printf '%s' "$OUT_C" | grep -q "M1.2"; then
  ok "AC-005 适用性检查能发现漏用方法（WARN，退出码仍 0）"
else
  bad "AC-005 适用性检查能发现漏用方法" "rc=$RC_C out=$OUT_C"
fi

# ---------------------------------------------------------------- AC-006
step "AC-006 跳过必须写理由（方法跳过 / 维度跳过两种写法）"
# D7：维度跳过也用 skipped[].method 记（"dimension:<维度名>"），
#     元素结构仍以 REQ-002A 为准（只有 method + reason）—— 两种写法都必须被发现。
MATRIX_D='[ { "requirement": "R-1", "methods_applied": ["M1.1"], "skipped": [ { "method": "M1.4" } ], "dimensions": ["functional"] } ]'
mkcases "$WORK/d.json" "$CASES_C" "$MATRIX_D"
OUT_D="$(node "$CM" "$WORK/d.json" --methods "$MTH" 2>&1)"; RC_D=$?
# 场景 D2：跳过**维度**（用 dimension: 前缀），同样缺 reason
MATRIX_D2='[ { "requirement": "R-1", "methods_applied": ["M1.1"], "skipped": [ { "method": "dimension:concurrency" } ], "dimensions": ["functional"] } ]'
mkcases "$WORK/d2.json" "$CASES_C" "$MATRIX_D2"
OUT_D2="$(node "$CM" "$WORK/d2.json" --methods "$MTH" 2>&1)"; RC_D2=$?
# 必须点名"缺 reason"这件事 —— 只查一个关键词可能命中别处的提及
D_OK=0
if [ $RC_D -ne 0 ] && printf '%s' "$OUT_D" | grep -q "M1.4" && printf '%s' "$OUT_D" | grep -qi "reason"; then D_OK=1; fi
D2_OK=0
if [ $RC_D2 -ne 0 ] && printf '%s' "$OUT_D2" | grep -q "concurrency" && printf '%s' "$OUT_D2" | grep -qi "reason"; then D2_OK=1; fi
if [ $D_OK -eq 1 ] && [ $D2_OK -eq 1 ]; then
  ok "AC-006 跳过必须写理由（方法跳过 / 维度跳过两种写法）"
else
  bad "AC-006 跳过必须写理由" "方法跳过 rc=$RC_D(期望≠0,点名M1.4+reason) 维度跳过 rc=$RC_D2(期望≠0,点名concurrency+reason) out1=$OUT_D out2=$OUT_D2"
fi

# ---------------------------------------------------------------- AC-007
step "AC-007 --json 输出与退出码语义"
if [ ! -f "$CM" ]; then
  bad "AC-007 --json 输出与退出码语义" "缺 check-methods.mjs"
else
  node "$CM" "$WORK/b.json" --methods "$MTH" --json > "$WORK/j1.json" 2>/dev/null; RC1=$?
  node "$CM" "$WORK/a.json" --methods "$MTH" --json > "$WORK/j2.json" 2>/dev/null; RC2=$?
  node "$CM" "$WORK/b.json" --methods "$MTH" --json --bogus 1 > "$WORK/j3.json" 2>/dev/null; RC3=$?
  J1="$(node -e 'try{JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log("ok")}catch(e){console.log("fail")}' "$WORK/j1.json")"
  J2="$(node -e 'try{JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log("ok")}catch(e){console.log("fail")}' "$WORK/j2.json")"
  J3="$(node -e 'try{JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log("ok")}catch(e){console.log("fail")}' "$WORK/j3.json")"
  if [ "$J1" = "ok" ] && [ "$J2" = "ok" ] && [ "$J3" = "ok" ] && [ $RC1 -eq 0 ] && [ $RC2 -eq 1 ] && [ $RC3 -eq 2 ]; then
    ok "AC-007 --json 输出与退出码语义（0/1/2）"
  else
    bad "AC-007 --json 输出与退出码语义" "成功 json=$J1(rc=$RC1) 错误 json=$J2(rc=$RC2) 用法 json=$J3(rc=$RC3)"
  fi
fi

# ---------------------------------------------------------------- AC-008
step "AC-008 判不了就说「判不了」"
# 用例的 expected 是普通字符串（人读）→ distinct_expected 无法判定 → 必须报"无法判定"，不得报通过
CASES_E="[ \
$(mkcase TC-002 边界下界 boundary '[ { "action": "长度7", "expected": "长度不足应拒绝" } ]'), \
$(mkcase TC-003 边界上界 boundary '[ { "action": "长度8", "expected": "长度达标应接受" } ]'), \
$(mkcase TC-004 边界越界 boundary '[ { "action": "长度21", "expected": "超出应拒绝" } ]') ]"
mkcases "$WORK/e.json" "$CASES_E" "$MATRIX_B"
OUT_E="$(node "$CM" "$WORK/e.json" --methods "$MTH" 2>&1)"; RC_E=$?
# 机器可读复核（F5.1 契约）：判不了的组合必须落在 undecidable，
# 且**不得**同时被判成 satisfied —— "判不了"绝不等于"通过"
node "$CM" "$WORK/e.json" --methods "$MTH" --json > "$WORK/e.json.out" 2>/dev/null
V8="$(node -e '
const fs=require("fs");
let o; try{o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));}catch(e){console.log("parse_err");process.exit(0);}
const und=Array.isArray(o.undecidable)?o.undecidable:[];
const vd=Array.isArray(o.verdicts)?o.verdicts:[];
let leak=0;
for(const u of und){
  const hit=vd.find(x=>x&&x.requirement===u.requirement&&x.method===u.method);
  if(hit&&hit.status==="satisfied") leak++;
}
console.log("undecidable="+und.length);
console.log("verdict_undecidable="+vd.filter(x=>x&&x.status==="undecidable").length);
console.log("leak="+leak);
' "$WORK/e.json.out")"
U8="$(printf '%s\n' "$V8" | sed -n 's/^undecidable=//p')"
VU8="$(printf '%s\n' "$V8" | sed -n 's/^verdict_undecidable=//p')"
LK8="$(printf '%s\n' "$V8" | sed -n 's/^leak=//p')"
if printf '%s' "$OUT_E" | grep -qE "无法判定|UNDECIDABLE|undeterminable" \
   && [ "${U8:-0}" -ge 1 ] 2>/dev/null && [ "${VU8:-0}" -ge 1 ] 2>/dev/null && [ "${LK8:-1}" -eq 0 ] 2>/dev/null; then
  ok "AC-008 判不了就说「判不了」（且不得被判成通过）"
else
  bad "AC-008 判不了就说「判不了」" "rc=$RC_E undecidable=$U8 verdict_undecidable=$VU8 判成通过的泄漏=$LK8 out=$OUT_E"
fi

# ---------------------------------------------------------------- AC-009
step "AC-009 零依赖 + 可移植"
PKG="$(cd "$TCD" && cd ../.. && pwd)/package.json"
DEPS="0"
if [ -f "$PKG" ]; then
  DEPS="$(node -e 'const p=require(process.argv[1]);const d=Object.keys(p.dependencies||{}).length;console.log(d)' "$PKG")"
fi
# 检索范围必须覆盖**整个 skill 目录**（不只 scripts/）且**去注释后**检索 ——
# 旧版只 grep "$TCD/scripts"，把实现挪到 scripts/lib/ 或根目录就测不出来了。
EXT="$(node -e '
const fs=require("fs"),path=require("path");
const root=process.argv[1];const files=[];
const walk=(d)=>{ for(const e of fs.readdirSync(d,{withFileTypes:true})){ const p=path.join(d,e.name);
  if(e.isDirectory()) walk(p); else if(/\.(mjs|js|cjs)$/.test(e.name)) files.push(p); } };
if(fs.existsSync(root)) walk(root);
const hits=[];
for(const f of files){
  const src=fs.readFileSync(f,"utf8").replace(/\/\*[\s\S]*?\*\//g,"").replace(/^\s*\/\/.*$/gm,"");
  src.split(/\r?\n/).forEach((ln,i)=>{
    if(/child_process|execSync|spawnSync|execFile|\/bin\/bash|python3/.test(ln)) hits.push(f+":"+(i+1));
  });
}
console.log(hits.length);
if(hits.length) console.error(hits.slice(0,5).join("\n"));
' "$TCD" 2>/dev/null | head -1)"
# 非内置 import（引第三方包）也算依赖
BADIMPORT="$(node -e '
const fs=require("fs"),path=require("path");
const root=process.argv[1];const files=[];
const walk=(d)=>{ for(const e of fs.readdirSync(d,{withFileTypes:true})){ const p=path.join(d,e.name);
  if(e.isDirectory()) walk(p); else if(/\.(mjs|js|cjs)$/.test(e.name)) files.push(p); } };
if(fs.existsSync(root)) walk(root);
let n=0;
for(const f of files){
  const src=fs.readFileSync(f,"utf8").replace(/\/\*[\s\S]*?\*\//g,"").replace(/^\s*\/\/.*$/gm,"");
  src.split(/\r?\n/).forEach((ln)=>{
    if(/^\s*import\s+.*from\s+[\x27\x22]/.test(ln)){
      const m=ln.match(/from\s+[\x27\x22]([^\x27\x22]+)[\x27\x22]/);
      const spec=m?m[1]:"";
      if(spec && !spec.startsWith("node:") && !spec.startsWith("./") && !spec.startsWith("../")) n++;
    }
  });
}
console.log(n);
' "$TCD" 2>/dev/null | head -1)"
if [ "${DEPS:-1}" -eq 0 ] && [ "${EXT:-1}" -eq 0 ] && [ "${BADIMPORT:-1}" -eq 0 ]; then
  ok "AC-009 零依赖 + 可移植"
else
  bad "AC-009 零依赖 + 可移植" "deps=$DEPS 命中外部调用的行数=$EXT 非内置import=$BADIMPORT"
fi

# ---------------------------------------------------------------- AC-010
step "AC-010 REQ-002A 回归不受影响"
REG2A="$(cd "$(dirname "$0")" && pwd)/../REQ-002A-schema-v2/verify-regression-002a.sh"
if [ -f "$REG2A" ]; then
  bash "$REG2A" "$TCD" > "$WORK/reg2a.log" 2>&1
  if [ $? -eq 0 ]; then
    ok "AC-010 REQ-002A 回归不受影响"
  else
    bad "AC-010 REQ-002A 回归不受影响" "$(tail -6 "$WORK/reg2a.log" | tr '\n' ' ')"
  fi
else
  bad "AC-010 REQ-002A 回归不受影响" "找不到 REQ-002A 回归脚本"
fi

# ---------------------------------------------------------------- AC-014
step "AC-014 验收场景的样本本身必须合法（不能拿非法输入去测）"
# 为什么要有这条：本脚本造的场景样本用了**结构化断言对象**形式的 expected。
# 若那份样本**通不过 REQ-002A 的校验器**，那么"check-methods 报错了"这件事
# 可能只是因为输入非法，而不是因为判据生效 —— 测出来的结论是假的。
VC="$TCD/scripts/validate-cases.mjs"
if [ ! -f "$VC" ]; then
  bad "AC-014 验收场景的样本本身必须合法" "缺 validate-cases.mjs"
else
  BAD_SAMPLE=""
  for f in a b b2 c e; do
    [ -f "$WORK/$f.json" ] || continue
    OUTV="$(node "$VC" "$WORK/$f.json" 2>&1)"; RCV=$?
    if [ $RCV -ne 0 ]; then
      BAD_SAMPLE="$BAD_SAMPLE $f(rc=$RCV)"
    fi
  done
  # d.json 是**故意的反例**（AC-006 的测试对象：跳过项缺 reason）——
  # 对它的正确期望是「被 REQ-002A 拦截」，不是「通过」。
  D_BLOCKED=0
  if [ -f "$WORK/d.json" ]; then
    node "$VC" "$WORK/d.json" >/dev/null 2>&1
    [ $? -ne 0 ] && D_BLOCKED=1
  fi
  if [ -z "$BAD_SAMPLE" ] && [ "$D_BLOCKED" -eq 1 ]; then
    ok "AC-014 验收场景的样本本身必须合法（d 是反例、须被拦截，其余全部通过）"
  else
    bad "AC-014 验收场景的样本本身必须合法" \
        "非法样本:$BAD_SAMPLE d.json被拦截=$D_BLOCKED(期望1) —— 拿非法输入测出来的结论不算数"
  fi
fi

# ---------------------------------------------------------------- AC-011
step "AC-011 本脚本自身要被验收（变异必须被测出差异）"
if [ ! -f "$CM" ]; then
  bad "AC-011 本脚本自身要被验收" "缺 check-methods.mjs"
else
  # ⚠️ 绝不能**原地改被验对象** —— 旧版把 $CM 备份后原地改再还原，
  #    一旦中途出错就留下改坏的实现（验收脚本污染被验物，比假 PASS 更糟）。
  #    正确做法：把整个 skill 目录**复制一份**，在副本上做变异。
  cp -r "$TCD" "$WORK/mutant-skill"
  CMM="$WORK/mutant-skill/scripts/check-methods.mjs"
  MTHM="$WORK/mutant-skill/references/methods.json"
  # 检测信号用**「退出码 + 输出」的组合** —— 只看退出码会漏：
  # 变异让实现崩溃时退出码同样是 1，与基线的"报 ERROR"退出码一样，看不出差异。
  pair() { printf '%s\n--\n%s' "$1" "$2"; }
  # 基线
  OUT_RA="$(node "$CM" "$WORK/a.json" --methods "$MTH" 2>&1)"; RC_RA=$?
  OUT_RB2="$(node "$CM" "$WORK/b2.json" --methods "$MTH" 2>&1)"; RC_RB2=$?
  BASE_A="$(pair "$RC_RA" "$OUT_RA")"
  BASE_B2="$(pair "$RC_RB2" "$OUT_RB2")"

  # 变异 1：让 required_outputs 的核验失效
  # （键名由 F1/F2 的 JSON 契约定死，不是实现内部命名 —— 实现方改内部变量名不该让验收失效）
  node -e '
  const fs=require("fs"),f=process.argv[1];let s=fs.readFileSync(f,"utf8");
  s=s.replace(/required_outputs/g,"required_outputs_DISABLED");
  fs.writeFileSync(f,s);
  ' "$CMM"
  OUT_V1="$(node "$CMM" "$WORK/a.json" --methods "$MTHM" 2>&1)"; RC_V1=$?
  V1="$(pair "$RC_V1" "$OUT_V1")"
  # 还原
  cp "$WORK/mutant-skill/scripts/check-methods.mjs" "$WORK/m1.bak"

  # 变异 2：把 ERROR 降级成 WARN（退出码应从 1 变 0）
  node -e '
  const fs=require("fs"),f=process.argv[1];let s=fs.readFileSync(f,"utf8");
  s=s.replace(/[\x27\x22]ERROR[\x27\x22]/g,"\x27WARN\x27");
  fs.writeFileSync(f,s);
  ' "$CMM"
  OUT_V2="$(node "$CMM" "$WORK/a.json" --methods "$MTHM" 2>&1)"; RC_V2=$?
  V2="$(pair "$RC_V2" "$OUT_V2")"
  cp "$WORK/m1.bak" "$CMM"

  # 变异 3：让 distinct_expected 谓词失效（场景 B2 的取值全相同，应从"报错"变成"不报错"）
  node -e '
  const fs=require("fs"),f=process.argv[1];let s=fs.readFileSync(f,"utf8");
  s=s.replace(/distinct_expected/g,"distinct_expected_DISABLED");
  fs.writeFileSync(f,s);
  ' "$CMM"
  OUT_V3="$(node "$CMM" "$WORK/b2.json" --methods "$MTHM" 2>&1)"; RC_V3=$?
  V3="$(pair "$RC_V3" "$OUT_V3")"

  # 还原后必须回到基线（确认变异被还原干净）
  OUT_RB="$(node "$CM" "$WORK/a.json" --methods "$MTH" 2>&1)"; RC_RB=$?
  DET=0
  [ "$V1" != "$BASE_A" ] && DET=$((DET+1))
  [ "$V2" != "$BASE_A" ] && DET=$((DET+1))
  [ "$V3" != "$BASE_B2" ] && DET=$((DET+1))
  # 必须 3/3 全测出 —— 旧版只要 2/3 就算过，等于给"漏测一处"留了后门
  if [ "$DET" -eq 3 ] && [ "$RC_RB" -eq "$RC_RA" ]; then
    ok "AC-011 本脚本自身要被验收（变异测出差异 $DET/3）"
  else
    bad "AC-011 本脚本自身要被验收" \
        "检出差异 $DET/3（要求 3/3）基线A rc=$RC_RA 基线B2 rc=$RC_RB2 v1=$RC_V1 v2=$RC_V2 v3=$RC_V3 还原后 rc=$RC_RB"
  fi
fi

# ---------------------------------------------------------------- AC-013
step "AC-013 --json 输出结构自洽（三分类互斥 + 计数一致 + 判不了不等于通过）"
if [ ! -f "$CM" ]; then
  bad "AC-013 --json 输出结构自洽" "缺 check-methods.mjs"
else
  node "$CM" "$WORK/a.json" --methods "$MTH" --json > "$WORK/aj.json" 2>/dev/null
  V13="$(node -e '
const fs=require("fs");
let o; try{o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));}catch(e){console.log("parse_err=1");process.exit(0);}
let cases={requirements:[],coverage_matrix:[]};
try{ cases=JSON.parse(fs.readFileSync(process.argv[2],"utf8")); }catch(e){}
const matrix=cases.coverage_matrix||[];
const arr=(k)=>Array.isArray(o[k])?o[k]:null;
const E=arr("errors"),W=arr("warnings"),U=arr("undecidable"),V=arr("verdicts"),S=o.summary||{};
let prob=[];
if(!E||!W||!U||!V) prob.push("缺数组字段");
else {
  // 1) summary 计数必须与数组长度一致
  if(Number(S.errors)!==E.length) prob.push("summary.errors≠errors.length");
  if(Number(S.warnings)!==W.length) prob.push("summary.warnings≠warnings.length");
  if(Number(S.undecidable)!==U.length) prob.push("summary.undecidable≠undecidable.length");
  // 2) 三分类互斥：同一条 (requirement, method) 不得同时在 errors 与 warnings
  const key=(x)=>String(x.requirement)+"|"+String(x.method);
  const ek=new Set(E.map(key)),wk=new Set(W.map(key));
  for(const k of ek) if(wk.has(k)) prob.push("errors/warnings 互斥被破: "+k);
  // 3) 判不了的不许同时被判成通过
  for(const u of U){
    const hit=V.find(x=>x&&key(x)===key(u));
    if(hit&&hit.status==="satisfied") prob.push("undecidable 被判成 satisfied: "+key(u));
  }
  // 4) verdicts 的 status 只能是约定的五个取值
  const allow=new Set(["satisfied","missing_output","undecidable","suspect","not_applicable"]);
  for(const v of V) if(v&&!allow.has(v.status)) prob.push("verdict.status 越界: "+v.status);
  // 5) 每个 (requirement, method) 组合只能有一个 verdict
  const seen=new Set();
  for(const v of V){ const k=key(v); if(seen.has(k)) prob.push("verdict 重复: "+k); seen.add(k); }
  // 6) 覆盖完整性：每个 (需求条目 × 方法) 组合都必须有结论 ——
  //    只给"有问题"的组合写结论 = 漏判（D9：此前没有验收保护）
  const combos=new Set();
  for(const r of (cases.requirements||[])){
    if(!r||r.testable===false) continue;
    for(const m of (matrix||[])){
      if(!m||m.requirement!==r.id) continue;
      for(const mid of (m.methods_applied||[])) combos.add(String(r.id)+"|"+String(mid));
    }
  }
  for(const c of combos){ if(!seen.has(c)) prob.push("verdict 漏判: "+c); }
}
console.log("problems="+prob.length);
console.log("detail="+(prob.slice(0,4).join(" ; ")||"none"));
' "$WORK/aj.json" "$WORK/a.json")"
P13="$(printf '%s\n' "$V13" | sed -n 's/^problems=//p')"
D13="$(printf '%s\n' "$V13" | sed -n 's/^detail=//p')"
if [ "${P13:-1}" -eq 0 ] 2>/dev/null; then
  ok "AC-013 --json 输出结构自洽"
else
  bad "AC-013 --json 输出结构自洽" "问题数=$P13 明细=$D13"
fi
fi

# ---------------------------------------------------------------- AC-015
step "AC-015 维度适用性检查能被测出（F4 的 DIMENSION_MISSING / METHOD_SUSPECT）"
# 为什么要有这条：F4 的这段检查此前**没有任何 AC 直接测** ——
# 把整段代码删掉，15 条 AC 仍全绿。实现方写了、验收没测 → 下次重构就会悄悄删掉。
# 没有验收保护的代码等于不存在。
if [ ! -f "$CM" ]; then
  bad "AC-015 维度适用性检查能被测出" "缺 check-methods.mjs"
else
  # 场景 1：需求条目命中某维度的强适用信号，但该条目下**一条用例都没有** → DIMENSION_MISSING（WARN）
  MATRIX_E='[ { "requirement": "R-1", "methods_applied": ["M1.1"], "skipped": [], "dimensions": [] } ]'
  mkcases "$WORK/e2.json" "[]" "$MATRIX_E"
  OUT_E2="$(node "$CM" "$WORK/e2.json" --methods "$MTH" 2>&1)"; RC_E2=$?
  # 场景 2：声明了 M1.2（边界值分析），需求文本里**没有**边界信号，但**必需产出齐备**
  #         → METHOD_SUSPECT（WARN，适用性存疑）
  # ⚠️ 两个前提都得满足，缺一个都测不到 SUSPECT：
  #    ① 需求标题**不含** M1.2 的适用信号词（长度/范围/上限/下限/最多/至少/不超过/不少于/
  #       位数/数量/阈值/到期/间隔）—— 之前用"密码长度 8-20 位"，那条**恰恰含边界信号**，
  #       判的是"适用"而不是"存疑"。
  #    ② **必需产出必须齐备**（3 条 boundary 用例、取值互不相同）—— 实现的判定顺序是
  #       "产出缺失 → ERROR（更根本）→ 才轮到适用性存疑"（与 D26/D27 同一条原则）。
  #       产出也缺时，报的是 missing_output，根本走不到 SUSPECT 分支。
  SUSPECT_CASES="[ \
$(mkcase TC-001 功能用例 functional "[ $(astep '输入账号' '$.code' 'equals' '"E001"') ]"), \
$(mkcase TC-002 边界下界 boundary "[ $(astep '长度7' '$.len' 'equals' '7') ]"), \
$(mkcase TC-003 边界上界 boundary "[ $(astep '长度8' '$.len' 'equals' '8') ]"), \
$(mkcase TC-004 边界越界 boundary "[ $(astep '长度21' '$.len' 'equals' '21') ]") ]"
  MATRIX_F='[ { "requirement": "R-1", "methods_applied": ["M1.2"], "skipped": [], "dimensions": ["functional","boundary"] } ]'
  printf '{\n  "schema_version": 2,\n  "meta": { "source": "qa-005", "generated_at": "2026-11-11T19:00:00+08:00", "case_count": 4 },\n  "requirements": [ { "id": "R-1", "title": "用户登录", "source_ref": "x", "testable": true } ],\n  "open_questions": [],\n  "coverage_matrix": %s,\n  "cases": %s\n}\n' "$MATRIX_F" "$SUSPECT_CASES" > "$WORK/f.json"
  OUT_F="$(node "$CM" "$WORK/f.json" --methods "$MTH" 2>&1)"; RC_F=$?
  E1=0; E2=0
  printf '%s' "$OUT_E2" | grep -q "DIMENSION_MISSING" && E1=1
  printf '%s' "$OUT_F" | grep -q "METHOD_SUSPECT" && E2=1
  if [ $E1 -eq 1 ] && [ $E2 -eq 1 ]; then
    ok "AC-015 维度适用性检查能被测出（DIMENSION_MISSING / METHOD_SUSPECT）"
  else
    bad "AC-015 维度适用性检查能被测出" \
        "DIMENSION_MISSING=$E1(期望1,rc=$RC_E2) METHOD_SUSPECT=$E2(期望1,rc=$RC_F) out1=$OUT_E2 out2=$OUT_F"
  fi
fi

# ---------------------------------------------------------------- AC-012
step "AC-012 SKILL.md 把方法选择落在脚本上"
SK="$TCD/SKILL.md"
if [ ! -f "$SK" ]; then
  bad "AC-012 SKILL.md 把方法选择落在脚本上" "缺 SKILL.md"
else
  HAS_SCRIPT="$(grep -c "check-methods.mjs" "$SK" 2>/dev/null)"
  HAS_SEQ="$(grep -c -E '^\s*(node |# ).*check-methods\.mjs' "$SK" 2>/dev/null)"
  # ERROR 与 WARN 必须**分别**出现 —— 旧版用 "ERROR|WARN" 一个正则，
  # 只要文档里出现"ERROR/WARN"这个词就判绿，等于没查后果。
  # 按 F6 的要求，两类结论**各自**要写清后果：ERROR 必须修；WARN 必须在报告里说明。
  HAS_ERROR="$(grep -c "ERROR" "$SK" 2>/dev/null)"
  HAS_WARN="$(grep -c "WARN" "$SK" 2>/dev/null)"
  HAS_ERRFIX="$(grep -c -E "ERROR.*(必须|要)?修|修.*ERROR|阻断|block" "$SK" 2>/dev/null)"
  HAS_WARNTELL="$(grep -c -E "WARN.*(说明|报告|列出|不得忽略)|(说明|报告|列出|不得忽略).*WARN" "$SK" 2>/dev/null)"
  if [ "$HAS_SCRIPT" -ge 1 ] && [ "$HAS_SEQ" -ge 1 ] && [ "$HAS_ERROR" -ge 1 ]      && [ "$HAS_WARN" -ge 1 ] && [ "$HAS_ERRFIX" -ge 1 ] && [ "$HAS_WARNTELL" -ge 1 ]; then
    ok "AC-012 SKILL.md 把方法选择落在脚本上"
  else
    bad "AC-012 SKILL.md 把方法选择落在脚本上" \
        "脚本提及=$HAS_SCRIPT 调用序列=$HAS_SEQ ERROR=$HAS_ERROR WARN=$HAS_WARN ERROR后果=$HAS_ERRFIX WARN后果=$HAS_WARNTELL"
  fi
fi

# ---------------------------------------------------------------- AC-016
step "AC-016 cases[].method[] 与 methods_applied[] 只接受方法编号（D12）"
# D12：dimension: 前缀只允许出现在 coverage_matrix[].skipped[].method。
# 若这两处也放宽，dimension: 前缀就会渗进"用了哪些方法"的语义里。
if [ ! -f "$VC" ]; then
  bad "AC-016 method[] 只接受方法编号" "缺 validate-cases.mjs"
else
  # 场景 1：cases[0].method[] 里塞 dimension: 前缀
  CASES_DIM_METH='[ { "id": "TC-001", "title": "功能用例", "requirement_refs": ["R-1"], "dimension": "functional", "priority": "P0", "method": ["dimension:concurrency"], "status": "active", "steps": [ { "action": "输入密码", "expected": { "path": "$.code", "op": "equals", "expected": "E001" } } ] } ]'
  MATRIX_OK='[ { "requirement": "R-1", "methods_applied": ["M1.1"], "skipped": [], "dimensions": ["functional"] } ]'
  mkcases "$WORK/dimmeth.json" "$CASES_DIM_METH" "$MATRIX_OK"
  OUT_DM="$(node "$VC" "$WORK/dimmeth.json" 2>&1)"; RC_DM=$?
  # 场景 2：coverage_matrix[0].methods_applied[] 里塞 dimension: 前缀
  CASES_PLAIN='[ { "id": "TC-001", "title": "功能用例", "requirement_refs": ["R-1"], "dimension": "functional", "priority": "P0", "method": ["M1.1"], "status": "active", "steps": [ { "action": "输入密码", "expected": { "path": "$.code", "op": "equals", "expected": "E001" } } ] } ]'
  MATRIX_DIM_APPLIED='[ { "requirement": "R-1", "methods_applied": ["dimension:concurrency"], "skipped": [], "dimensions": ["functional"] } ]'
  mkcases "$WORK/dimappl.json" "$CASES_PLAIN" "$MATRIX_DIM_APPLIED"
  OUT_DA="$(node "$VC" "$WORK/dimappl.json" 2>&1)"; RC_DA=$?
  # 判据：必须点名**具体 JSON 路径** —— 只查 "dimension:concurrency" 可能命中别处的提及
  DM_OK=0; DA_OK=0
  if [ $RC_DM -ne 0 ] && printf '%s' "$OUT_DM" | grep -q "cases\[0\].method\[0\]"; then DM_OK=1; fi
  if [ $RC_DA -ne 0 ] && printf '%s' "$OUT_DA" | grep -q "methods_applied\[0\]"; then DA_OK=1; fi
  if [ $DM_OK -eq 1 ] && [ $DA_OK -eq 1 ]; then
    ok "AC-016 method[] 与 methods_applied[] 只接受方法编号"
  else
    bad "AC-016 method[] 与 methods_applied[] 只接受方法编号" \
        "cases.method rc=$RC_DM(期望≠0,点名cases[0].method[0]) ok=$DM_OK | methods_applied rc=$RC_DA(期望≠0,点名methods_applied[0]) ok=$DA_OK out1=$OUT_DM out2=$OUT_DA"
  fi
fi

# ---------------------------------------------------------------- AC-017
step "AC-017 跳过缺 reason 的报错文案区分方法/维度（D13）"
if [ ! -f "$VC" ]; then
  bad "AC-017 跳过文案区分方法/维度" "缺 validate-cases.mjs"
else
  # 场景 A：跳过的是**方法**（M1.4），缺 reason
  MATRIX_SKIP_M='[ { "requirement": "R-1", "methods_applied": ["M1.1"], "skipped": [ { "method": "M1.4" } ], "dimensions": ["functional"] } ]'
  mkcases "$WORK/skipm.json" "$CASES_PLAIN" "$MATRIX_SKIP_M"
  OUT_SM="$(node "$VC" "$WORK/skipm.json" 2>&1)"; RC_SM=$?
  # 场景 B：跳过的是**维度**（dimension:concurrency），缺 reason
  MATRIX_SKIP_D='[ { "requirement": "R-1", "methods_applied": ["M1.1"], "skipped": [ { "method": "dimension:concurrency" } ], "dimensions": ["functional"] } ]'
  mkcases "$WORK/skipd.json" "$CASES_PLAIN" "$MATRIX_SKIP_D"
  OUT_SD="$(node "$VC" "$WORK/skipd.json" 2>&1)"; RC_SD=$?
  SM_OK=0; SD_OK=0; SD_NEG=0
  # A：点名 M1.4 + 出现"方法"二字
  if [ $RC_SM -ne 0 ] && printf '%s' "$OUT_SM" | grep -q "M1.4" && printf '%s' "$OUT_SM" | grep -q "方法"; then SM_OK=1; fi
  # B：点名 concurrency + 出现"维度"二字
  if [ $RC_SD -ne 0 ] && printf '%s' "$OUT_SD" | grep -q "concurrency" && printf '%s' "$OUT_SD" | grep -q "维度"; then SD_OK=1; fi
  # B：不得出现"跳过方法"（那正是要修的措辞错误）
  if printf '%s' "$OUT_SD" | grep -q "跳过方法"; then SD_NEG=1; fi
  if [ $SM_OK -eq 1 ] && [ $SD_OK -eq 1 ] && [ $SD_NEG -eq 0 ]; then
    ok "AC-017 跳过缺 reason 的报错文案区分方法/维度"
  else
    bad "AC-017 跳过缺 reason 的报错文案区分方法/维度" \
        "方法场景 rc=$RC_SM(期望≠0,含M1.4+方法) ok=$SM_OK | 维度场景 rc=$RC_SD(期望≠0,含concurrency+维度) ok=$SD_OK | 维度场景出现'跳过方法'=$SD_NEG(期望0) out1=$OUT_SM out2=$OUT_SD"
  fi
fi

# ---------------------------------------------------------------- AC-018
step "AC-018 skipped[].dimension 旧写法：两个脚本都判非法且指明正确写法（D14）"
# 实测（BA 侧）：当前 check-methods.mjs **静默接受**该写法并让维度跳过真实生效，
# 而 validate-cases.mjs 判它非法 —— 两个脚本对同一份文件结论相反，且宽松方静默放行。
if [ ! -f "$VC" ] || [ ! -f "$CM" ]; then
  bad "AC-018 legacy 写法两脚本一致判非法" "缺 validate-cases.mjs 或 check-methods.mjs"
else
  # legacy 写法：只有 dimension 字段，没有 method
  MATRIX_LEGACY='[ { "requirement": "R-1", "methods_applied": ["M1.1"], "skipped": [ { "dimension": "concurrency", "reason": "无并发语义" } ], "dimensions": ["functional"] } ]'
  mkcases "$WORK/legacy.json" "$CASES_PLAIN" "$MATRIX_LEGACY"
  OUT_LV="$(node "$VC" "$WORK/legacy.json" 2>&1)"; RC_LV=$?
  OUT_LC="$(node "$CM" "$WORK/legacy.json" --methods "$MTH" 2>&1)"; RC_LC=$?
  LV_OK=0; LC_OK=0; LC_HINT=0
  [ $RC_LV -ne 0 ] && LV_OK=1
  [ $RC_LC -ne 0 ] && LC_OK=1
  # check-methods 必须**指明正确写法** —— 只报错不指路，agent 仍然改不对
  printf '%s' "$OUT_LC" | grep -q "dimension:" && LC_HINT=1
  if [ $LV_OK -eq 1 ] && [ $LC_OK -eq 1 ] && [ $LC_HINT -eq 1 ]; then
    ok "AC-018 legacy 写法两脚本一致判非法且指明正确写法"
  else
    bad "AC-018 legacy 写法两脚本一致判非法且指明正确写法" \
        "validate rc=$RC_LV(期望≠0) ok=$LV_OK | check-methods rc=$RC_LC(期望≠0) ok=$LC_OK | 指明正确写法=$LC_HINT(期望1) out2=$OUT_LC"
  fi
fi

# ---------------------------------------------------------------- AC-019
step "AC-019 未知维度名（拼错）→ ERROR，两个脚本都点名（D15）"
if [ ! -f "$VC" ] || [ ! -f "$CM" ]; then
  bad "AC-019 未知维度名判 ERROR" "缺 validate-cases.mjs 或 check-methods.mjs"
else
  # 拼错的维度名：concurrancy 是 concurrency 的错拼
  MATRIX_TYPO='[ { "requirement": "R-1", "methods_applied": ["M1.1"], "skipped": [ { "method": "dimension:concurrancy", "reason": "拼错了" } ], "dimensions": ["functional"] } ]'
  mkcases "$WORK/typo.json" "$CASES_PLAIN" "$MATRIX_TYPO"
  OUT_TV="$(node "$VC" "$WORK/typo.json" 2>&1)"; RC_TV=$?
  OUT_TC="$(node "$CM" "$WORK/typo.json" --methods "$MTH" 2>&1)"; RC_TC=$?
  TV_OK=0; TC_OK=0
  # 两个脚本都**必须点名那个拼错的名字**
  if [ $RC_TV -ne 0 ] && printf '%s' "$OUT_TV" | grep -q "concurrancy"; then TV_OK=1; fi
  if [ $RC_TC -ne 0 ] && printf '%s' "$OUT_TC" | grep -q "concurrancy"; then TC_OK=1; fi
  if [ $TV_OK -eq 1 ] && [ $TC_OK -eq 1 ]; then
    ok "AC-019 未知维度名判 ERROR 且两个脚本都点名"
  else
    bad "AC-019 未知维度名判 ERROR 且两个脚本都点名" \
        "validate rc=$RC_TV(期望≠0,含concurrancy) ok=$TV_OK | check-methods rc=$RC_TC(期望≠0,含concurrancy) ok=$TC_OK out1=$OUT_TV out2=$OUT_TC"
  fi
fi

# ---------------------------------------------------------------- AC-020
step "AC-020 维度枚举单一来源：validate-cases 不再自带副本（D16）"
# 实测（BA 侧）：给 dimensions.json 加第 9 个维度后，
# validate-cases 判非法（读的是硬编码常量）、check-methods 照常认 → 同文件两脚本结论相反。
# 判据是**两个副本的退出码必须不同**：都 0 = 还在读硬编码；都 1 = 根本没读文件。
if [ ! -f "$VC" ] || [ ! -f "$DIM" ]; then
  bad "AC-020 维度枚举单一来源" "缺 validate-cases.mjs 或 dimensions.json"
else
  cp -r "$TCD" "$WORK/ss-skill"
  # 给副本的 dimensions.json 加第 9 个维度
  node -e '
  const fs=require("fs"),f=process.argv[1];
  const o=JSON.parse(fs.readFileSync(f,"utf8"));
  o.dimensions.push({id:"audit",name:"审计",always_applies:false,applies_when:["审计"],skip_reason_required:true,skip_reason_hint:"无审计留痕要求",description:"审计留痕。"});
  fs.writeFileSync(f,JSON.stringify(o,null,2));
  ' "$WORK/ss-skill/references/dimensions.json" 2>/dev/null
  # 造一份用了 audit 维度的用例集
  CASES_AUDIT='[ { "id": "TC-001", "title": "审计用例", "requirement_refs": ["R-1"], "dimension": "audit", "priority": "P0", "method": ["M1.1"], "status": "active", "steps": [ { "action": "执行", "expected": { "path": "$.code", "op": "equals", "expected": "E001" } } ] } ]'
  MATRIX_AUDIT='[ { "requirement": "R-1", "methods_applied": ["M1.1"], "skipped": [], "dimensions": ["audit"] } ]'
  mkcases "$WORK/audit.json" "$CASES_AUDIT" "$MATRIX_AUDIT"
  # 副本（库里有 audit）→ 应当认；原目录（库里没有 audit）→ 应当不认
  OUT_SS="$(node "$WORK/ss-skill/scripts/validate-cases.mjs" "$WORK/audit.json" 2>&1)"; RC_SS=$?
  OUT_OR="$(node "$VC" "$WORK/audit.json" 2>&1)"; RC_OR=$?
  # 源码检查：validate-cases.mjs 里不得再出现那 8 个维度 id 组成的硬编码枚举
  HARDCODED="$(node -e '
  const fs=require("fs");
  let s; try{ s=fs.readFileSync(process.argv[1],"utf8"); }catch(e){ console.log("__ERR__"); process.exit(0); }
  // 去掉注释与字符串后，检索是否还有一个含 3 个以上维度 id 的数组字面量
  const ids=["functional","boundary","exception","permission","data","concurrency","performance","compatibility"];
  const stripped=s.replace(/\/\*[\s\S]*?\*\//g,"").replace(/\/\/.*$/gm,"");
  const m=stripped.match(/\[[^\]]*\]/g)||[];
  let hit=0;
  for(const arr of m){
    const n=ids.filter(id=>arr.includes("\x27"+id+"\x27")||arr.includes("\x22"+id+"\x22")).length;
    if(n>=3) hit++;
  }
  console.log(hit);
  ' "$VC" 2>/dev/null)"
  SS_OK=0; OR_OK=0; HC_OK=0
  [ $RC_SS -eq 0 ] && SS_OK=1
  [ $RC_OR -ne 0 ] && OR_OK=1
  [ "${HARDCODED:-1}" -eq 0 ] && HC_OK=1
  # 副本与原目录的退出码**必须不同** —— 这是"确实在读文件"的判据
  if [ $SS_OK -eq 1 ] && [ $OR_OK -eq 1 ] && [ $HC_OK -eq 1 ]; then
    ok "AC-020 维度枚举单一来源（副本认新维度，原目录不认，无硬编码副本）"
  else
    bad "AC-020 维度枚举单一来源" \
        "副本rc=$RC_SS(期望0) 原目录rc=$RC_OR(期望≠0) 硬编码枚举数=$HARDCODED(期望0) out1=$OUT_SS out2=$OUT_OR"
  fi
fi

# ---------------------------------------------------------------- AC-021
step "AC-021 维度清单文档与库一致（D16）"
if [ ! -f "$DIM" ] || [ ! -f "$DIMDOC" ]; then
  bad "AC-021 维度清单文档与库一致" "缺 dimensions.json 或 coverage-dimensions.md"
else
  # ① BA 侧独立比对：md 表格里的取值集合 与 json 的 id 集合 必须完全相等
  SETDIFF="$(node -e '
  const fs=require("fs");
  let o; try{ o=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); }catch(e){ console.log("__ERR__|__ERR__"); process.exit(0); }
  const doc=fs.readFileSync(process.argv[2],"utf8");
  const ids=(Array.isArray(o.dimensions)?o.dimensions:[]).map(d=>String(d.id)).sort();
  // md 表格行形如：| `functional` | 功能 | ... |
  const mdIds=[...doc.matchAll(/^\|\s*`([a-z_]+)`\s*\|/gm)].map(m=>m[1]);
  const uniq=[...new Set(mdIds)].sort();
  const inMd=ids.filter(i=>!uniq.includes(i));
  const inJson=uniq.filter(i=>!ids.includes(i));
  console.log(inMd.join(",")+"|"+inJson.join(","));
  ' "$DIM" "$DIMDOC" 2>/dev/null)"
  MD_MISSING="$(printf '%s' "$SETDIFF" | cut -d'|' -f1)"
  MD_EXTRA="$(printf '%s' "$SETDIFF" | cut -d'|' -f2)"
  # ② 副本上删掉 md 表格里的一行 → 对照检查必须报错并点名被删掉的 id
  cp -r "$TCD" "$WORK/dd-skill"
  node -e '
  const fs=require("fs"),f=process.argv[1];
  let s=fs.readFileSync(f,"utf8");
  s=s.replace(/^\|\s*`performance`\s*\|.*\n/m,"");
  fs.writeFileSync(f,s);
  ' "$WORK/dd-skill/references/coverage-dimensions.md" 2>/dev/null
  # 入口名由实现自定（契约只要求"能单独触发"）→ 依次尝试可能的组合，
  # **任一**组合能点名被删掉的维度即算通过（不把实现绑死在某个参数名上）。
  DD_OUT=""; DD_RC=2; DD_OK=0
  try_dd() {
    local o r
    o="$(node "$WORK/dd-skill/scripts/check-methods.mjs" "$@" 2>&1)"; r=$?
    # 用法错误（码 2）= 这个入口不存在 → 试下一个
    if [ $r -ne 2 ] && [ $r -ne 0 ] && printf '%s' "$o" | grep -q "performance"; then
      DD_OUT="$o"; DD_RC=$r; DD_OK=1; return 0
    fi
    return 1
  }
  MTH_D="$WORK/dd-skill/references/methods.json"
  DIM_D="$WORK/dd-skill/references/dimensions.json"
  DOC_D="$WORK/dd-skill/references/coverage-dimensions.md"
  try_dd --methods "$MTH_D" --dimensions "$DIM_D" --dimensions-doc "$DOC_D" --check-dimensions-doc || \
  try_dd --methods "$MTH_D" --dimensions "$DIM_D" --dimensions-doc "$DOC_D" --check-doc || \
  try_dd --methods "$MTH_D" --dimensions "$DIM_D" --doc "$DOC_D" --check-doc || \
  try_dd --methods "$MTH_D" --dimensions "$DIM_D" --check-doc || \
  try_dd --methods "$MTH_D" --dimensions "$DIM_D" --dimensions-doc "$DOC_D" || \
  try_dd --check-dimensions-doc --dimensions-doc "$DOC_D" --dimensions "$DIM_D"
  if [ -z "$MD_MISSING" ] && [ -z "$MD_EXTRA" ] && [ $DD_OK -eq 1 ]; then
    ok "AC-021 维度清单文档与库一致"
  else
    bad "AC-021 维度清单文档与库一致" \
        "库有文档无=[$MD_MISSING] 文档有库无=[$MD_EXTRA] 删行后rc=$DD_RC(期望≠0且≠2) 点名performance=$DD_OK out=$DD_OUT"
  fi
fi

# ---------------------------------------------------------------- AC-022
step "AC-022 新增契约自身要被验收（正反对消 + 数据级变异）"
# 为什么要有这条：AC-016~AC-021 是本轮新增的契约。**新写的判据也可能恒真**
# （例：check-methods 若对任何 skipped 项都报错，AC-018 照样绿；若 dimensions.json
#  被删了它照常读硬编码兜底，AC-020 照样绿）。
# 本条用两种手段证伪：
#   ① 正反对消 —— 同一脚本对**合法**写法必须不报错（否则就是恒红误伤）
#   ② 数据级变异 —— 改**数据**而不是改代码（不依赖实现内部变量名）
if [ ! -f "$VC" ] || [ ! -f "$CM" ]; then
  bad "AC-022 新增契约自身要被验收" "缺 validate-cases.mjs 或 check-methods.mjs"
else
  # ---------- ① 正反对消：合法写法必须被接受，且跳过真实生效 ----------
  # 需求文本故意命中 concurrency 的适用信号（并发/重复提交）
  REQ_CONC='[ { "id": "R-1", "title": "用户可以并发下单并重复提交", "source_ref": "x", "testable": true } ]'
  printf '{\n  "schema_version": 2,\n  "meta": { "source": "qa-005", "generated_at": "2026-11-11T19:00:00+08:00", "case_count": 1 },\n  "requirements": %s,\n  "open_questions": [],\n  "coverage_matrix": [ { "requirement": "R-1", "methods_applied": ["M1.1"], "skipped": [ { "method": "dimension:concurrency", "reason": "该条目无共享资源，无并发语义" } ], "dimensions": ["functional"] } ],\n  "cases": [ { "id": "TC-001", "title": "功能用例", "requirement_refs": ["R-1"], "dimension": "functional", "priority": "P0", "method": ["M1.1"], "status": "active", "steps": [ { "action": "下单", "expected": { "path": "$.code", "op": "equals", "expected": "E001" } } ] } ]\n}\n' "$REQ_CONC" > "$WORK/valid_skip.json"
  OUT_VS_CM="$(node "$CM" "$WORK/valid_skip.json" --methods "$MTH" 2>&1)"; RC_VS_CM=$?
  OUT_VS_VC="$(node "$VC" "$WORK/valid_skip.json" 2>&1)"; RC_VS_VC=$?
  POS_OK=0
  # 合法写法：check-methods 不得因跳过项报错，且跳过**真实生效**
  #（需求文本命中 concurrency 信号 → 若跳过未生效，必报 DIMENSION_MISSING）
  if [ $RC_VS_CM -eq 0 ] && ! printf '%s' "$OUT_VS_CM" | grep -q "DIMENSION_MISSING"; then POS_OK=$((POS_OK+1)); fi
  # 合法写法：validate-cases 不得因维度名报错
  if [ $RC_VS_VC -eq 0 ] && ! printf '%s' "$OUT_VS_VC" | grep -q "dimension"; then POS_OK=$((POS_OK+1)); fi
  # ---------- ② 数据级变异 1：删掉 dimensions.json → 不得静默降级 ----------
  cp -r "$TCD" "$WORK/nolib-skill"
  rm -f "$WORK/nolib-skill/references/dimensions.json"
  OUT_NL="$(node "$WORK/nolib-skill/scripts/validate-cases.mjs" "$WORK/valid_skip.json" 2>&1)"; RC_NL=$?
  M1_OK=0
  # 库缺失 → 必须**明确报错**（码 2 或输出点名 dimensions.json）；若 rc=0 照常通过 = 有硬编码兜底
  if [ $RC_NL -ne 0 ] && { [ $RC_NL -eq 2 ] || printf '%s' "$OUT_NL" | grep -q "dimensions.json"; }; then M1_OK=1; fi
  # ---------- ② 数据级变异 2：dimensions.json 加一个文档里没有的维度 → 对照检查必须报错 ----------
  cp -r "$TCD" "$WORK/drift-skill"
  node -e '
  const fs=require("fs"),f=process.argv[1];
  const o=JSON.parse(fs.readFileSync(f,"utf8"));
  o.dimensions.push({id:"audit",name:"审计",always_applies:false,applies_when:["审计"],skip_reason_required:true,skip_reason_hint:"无审计留痕要求",description:"审计留痕。"});
  fs.writeFileSync(f,JSON.stringify(o,null,2));
  ' "$WORK/drift-skill/references/dimensions.json" 2>/dev/null
  DR_OUT=""; DR_RC=2; DR_OK=0
  try_drift() {
    local o r
    o="$(node "$WORK/drift-skill/scripts/check-methods.mjs" "$@" 2>&1)"; r=$?
    if [ $r -ne 2 ] && [ $r -ne 0 ] && printf '%s' "$o" | grep -q "audit"; then
      DR_OUT="$o"; DR_RC=$r; DR_OK=1; return 0
    fi
    return 1
  }
  MTH_G="$WORK/drift-skill/references/methods.json"
  DIM_G="$WORK/drift-skill/references/dimensions.json"
  DOC_G="$WORK/drift-skill/references/coverage-dimensions.md"
  try_drift --methods "$MTH_G" --dimensions "$DIM_G" --dimensions-doc "$DOC_G" --check-dimensions-doc || \
  try_drift --methods "$MTH_G" --dimensions "$DIM_G" --dimensions-doc "$DOC_G" --check-doc || \
  try_drift --methods "$MTH_G" --dimensions "$DIM_G" --doc "$DOC_G" --check-doc || \
  try_drift --methods "$MTH_G" --dimensions "$DIM_G" --check-doc || \
  try_drift --methods "$MTH_G" --dimensions "$DIM_G" --dimensions-doc "$DOC_G" || \
  try_drift --check-dimensions-doc --dimensions-doc "$DOC_G" --dimensions "$DIM_G"
  # 汇总：4 项全过才算本条成立
  DET2=$(( POS_OK + M1_OK + DR_OK ))
  if [ $POS_OK -eq 2 ] && [ $M1_OK -eq 1 ] && [ $DR_OK -eq 1 ]; then
    ok "AC-022 新增契约自身要被验收（正反对消 2/2 + 数据级变异 2/2）"
  else
    bad "AC-022 新增契约自身要被验收" \
        "正反对消=$POS_OK/2(期望2) 删库变异=$M1_OK/1(期望1,rc=$RC_NL) 库文档漂移变异=$DR_OK/1(期望1,rc=$DR_RC) 漂移输出=$DR_OUT 删库输出=$OUT_NL 合法写法输出=$OUT_VS_CM"
  fi
fi

# ---------------------------------------------------------------- 结论
printf '\n────────────────────────────────────────\n'
printf '结论: %d PASS / %d FAIL\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '未通过的 AC:\n'
  for f in "${FAILED_LIST[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
