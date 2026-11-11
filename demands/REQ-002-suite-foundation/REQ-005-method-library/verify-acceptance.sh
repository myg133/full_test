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
MTH="$TCD/references/methods.json"
DIM="$TCD/references/dimensions.json"

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
  printf '{ "id": "%s", "title": "%s", "requirement_refs": ["R-1"], "dimension": "%s", "priority": "P0", "method": ["M0.1"], "status": "active", "steps": %s }' "$1" "$2" "$3" "$4"
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
# 场景 A：声明用了 M0.2（边界值），但该条目下**没有** boundary 维度的用例 → 应报错
CASES_A="[ $(mkcase TC-001 功能用例 functional "[ $(astep '输入密码' '$.code' 'equals' '"E001"') ]") ]"
MATRIX_A='[ { "requirement": "R-1", "methods_applied": ["M0.2"], "skipped": [], "dimensions": ["functional"] } ]'
mkcases "$WORK/a.json" "$CASES_A" "$MATRIX_A"
OUT_A="$(node "$CM" "$WORK/a.json" --methods "$MTH" 2>&1)"; RC_A=$?
# 场景 B：补上 3 条 boundary 用例，断言取值互不相同 → 不应再报"缺少必需产出"
CASES_B="[ \
$(mkcase TC-001 功能用例 functional "[ $(astep '输入密码' '$.code' 'equals' '"E001"') ]"), \
$(mkcase TC-002 边界下界 boundary "[ $(astep '长度7' '$.len' 'equals' '7') ]"), \
$(mkcase TC-003 边界上界 boundary "[ $(astep '长度8' '$.len' 'equals' '"8"') ]"), \
$(mkcase TC-004 边界越界 boundary "[ $(astep '长度21' '$.len' 'equals' '21') ]") ]"
MATRIX_B='[ { "requirement": "R-1", "methods_applied": ["M0.2"], "skipped": [], "dimensions": ["functional","boundary"] } ]'
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
if [ $RC_A -ne 0 ] && printf '%s' "$OUT_A" | grep -qE "M0\.2.*R-1|R-1.*M0\.2"; then A3=1; fi
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
# 需求文本含"长度 8-20 位"这类强边界信号，但 methods_applied 里没有 M0.2
CASES_C="[ $(mkcase TC-001 功能用例 functional "[ $(astep '输入密码' '$.code' 'equals' '"E001"') ]") ]"
MATRIX_C='[ { "requirement": "R-1", "methods_applied": ["M0.1"], "skipped": [], "dimensions": ["functional"] } ]'
mkcases "$WORK/c.json" "$CASES_C" "$MATRIX_C"
OUT_C="$(node "$CM" "$WORK/c.json" --methods "$MTH" 2>&1)"; RC_C=$?
# 必须点名类型 METHOD_MISSING（F3 定死的类型名）—— 只查 "M0.2" 可能命中别处的提及
if [ $RC_C -eq 0 ] && printf '%s' "$OUT_C" | grep -q "METHOD_MISSING" && printf '%s' "$OUT_C" | grep -q "M0.2"; then
  ok "AC-005 适用性检查能发现漏用方法（WARN，退出码仍 0）"
else
  bad "AC-005 适用性检查能发现漏用方法" "rc=$RC_C out=$OUT_C"
fi

# ---------------------------------------------------------------- AC-006
step "AC-006 跳过维度必须写理由"
MATRIX_D='[ { "requirement": "R-1", "methods_applied": ["M0.1"], "skipped": [ { "dimension": "concurrency" } ], "dimensions": ["functional"] } ]'
mkcases "$WORK/d.json" "$CASES_C" "$MATRIX_D"
OUT_D="$(node "$CM" "$WORK/d.json" --methods "$MTH" 2>&1)"; RC_D=$?
# 必须点名"缺 reason"这件事 —— 只查 "concurrency" 可能命中别处的提及
if [ $RC_D -ne 0 ] && printf '%s' "$OUT_D" | grep -q "concurrency" && printf '%s' "$OUT_D" | grep -qi "reason"; then
  ok "AC-006 跳过维度必须写理由"
else
  bad "AC-006 跳过维度必须写理由" "rc=$RC_D out=$OUT_D"
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
  for f in a b b2 c d e; do
    [ -f "$WORK/$f.json" ] || continue
    OUTV="$(node "$VC" "$WORK/$f.json" 2>&1)"; RCV=$?
    if [ $RCV -ne 0 ]; then
      BAD_SAMPLE="$BAD_SAMPLE $f(rc=$RCV)"
    fi
  done
  if [ -z "$BAD_SAMPLE" ]; then
    ok "AC-014 验收场景的样本本身必须合法（全部通过 REQ-002A 校验器）"
  else
    bad "AC-014 验收场景的样本本身必须合法" "非法样本:$BAD_SAMPLE —— 拿非法输入测出来的结论不算数"
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
}
console.log("problems="+prob.length);
console.log("detail="+(prob.slice(0,4).join(" ; ")||"none"));
' "$WORK/aj.json")"
P13="$(printf '%s\n' "$V13" | sed -n 's/^problems=//p')"
D13="$(printf '%s\n' "$V13" | sed -n 's/^detail=//p')"
if [ "${P13:-1}" -eq 0 ] 2>/dev/null; then
  ok "AC-013 --json 输出结构自洽"
else
  bad "AC-013 --json 输出结构自洽" "问题数=$P13 明细=$D13"
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

# ---------------------------------------------------------------- 结论
printf '\n────────────────────────────────────────\n'
printf '结论: %d PASS / %d FAIL\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '未通过的 AC:\n'
  for f in "${FAILED_LIST[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
