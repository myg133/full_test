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

# 本脚本自身的绝对路径。AC-026 需要**嵌套调用本脚本**（在副本上跑变异体），
# 必须保证子进程用的是同一个脚本文件；DEMAND_ROOT 是工作区根（用于解析 demand_dir）。
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/$(basename "${BASH_SOURCE[0]}")"
DEMAND_ROOT="$(cd "$SELF_DIR/../../../.." 2>/dev/null && pwd || echo "$SELF_DIR")"

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

# 同行判断：$1=文本 $2=词A $3=词B → 存在**同一行**同时含 A 与 B 则返回 0
# ⚠️ 为什么必须同行：脚本输出末尾常有"按维度分布:"这类汇总行，
#    只查"输出里出现过某个词"会被那行蒙混过关（恒真判据比不判还糟）。
# ⚠️ 不用 `| grep -q`：pipefail 下 grep -q 提前退出会给上游发 SIGPIPE → 假失败。
same_line() {
  printf '%s\n' "$1" | grep -F "$2" | grep -F -c "$3" >/dev/null
}

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
# ⚠️ 样本必须**只违反计数谓词**（D24）：M1.2 = min_cases_by_dimension(boundary,min=3)
#    **且**带 distinct_expected 子字段。若给 0 条 boundary 用例，计数谓词与 distinct
#    子字段**同时**违反 → 计数谓词失效后 distinct 子字段照样报错 → 测不出计数谓词
#    （独立验收实测的 C05 逃逸就是这个）。改为给 **2 条** boundary 用例且取值**互不相同**：
#    计数 2 < 3 违反、distinct 2 ≥ 2 满足 —— 只有计数谓词能触发报错。
CASES_A="[ \
$(mkcase TC-001 功能用例 functional "[ $(astep '输入密码' '$.code' 'equals' '"E001"') ]"), \
$(mkcase TC-002 边界下界 boundary "[ $(astep '长度7' '$.len' 'equals' '7') ]"), \
$(mkcase TC-003 边界上界 boundary "[ $(astep '长度8' '$.len' 'equals' '"8"') ]") ]"
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
REG2A="$SELF_DIR/../REQ-002A-schema-v2/verify-regression-002a.sh"
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
  // ⚠️ 覆盖口径必须把**用例级**声明的方法编号也算进来（D24）：
  //    只按 coverage_matrix 算 → 用例声明了某个方法、矩阵没声明时，
  //    那个 (需求条目 × 方法) 组合会被算成"本来就不该有结论" → 漏判无从发现。
  //    F5.1 硬约束 3：「verdicts 必须覆盖每一条 (需求条目 × 方法) 组合 —— 没有结论的组合等于漏判」
  for(const c of (cases.cases||[])){
    if(!c||!Array.isArray(c.method)) continue;
    const refs=Array.isArray(c.requirement_refs)?c.requirement_refs:[];
    const targets=refs.length>0?refs:[null];
    for(const mid of c.method){
      for(const rid of targets) combos.add(String(rid)+"|"+String(mid));
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
  # ⚠️ 必须**同行**判断：输出末尾有"按维度分布:"这类汇总行，
  #    只查"出现过 维度"会被那行蒙混过关 —— 那样本条就恒真了。
  # A：同一行里同时出现 M1.4 与"方法"
  if [ $RC_SM -ne 0 ] && same_line "$OUT_SM" "M1.4" "方法"; then SM_OK=1; fi
  # B：同一行里同时出现 concurrency 与"维度"
  if [ $RC_SD -ne 0 ] && same_line "$OUT_SD" "concurrency" "维度"; then SD_OK=1; fi
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

# ---------------------------------------------------------------- AC-023
step "AC-023 四个谓词分支必须真的生效（D17）"
# 根因：验收样本只用了 M1.1/M1.2 —— M1.3/M1.5/M1.6 的谓词从未进入任何判据，
# 把分支置空后验收脚本照样 23/0。本条给每个谓词各配一份"故意违反"的样本。
if [ ! -f "$CM" ]; then
  bad "AC-023 四个谓词分支生效" "缺 check-methods.mjs"
else
  # ⚠️ 每份样本必须**只违反一个谓词** —— 否则被测的谓词失效时，
  #    同一个方法上的另一个谓词仍会报错，"缺少必需产出"照样出现 → 测不出目标谓词。
  #    （第一版正是栽在这里：M1.4/M1.5/M1.3 各自还带第二个谓词，4 个场景只有 1 个真正隔离。）
  # 场景 1：M1.4 状态迁移要求 exception 维度（has_dimension）→ 给 2 条 functional 用例
  #         （min_cases_total(min=2) 满足、has_dimension(exception) 违反）
  C1='[ { "id": "TC-001", "title": "功能用例", "requirement_refs": ["R-1"], "dimension": "functional", "priority": "P0", "method": ["M1.4"], "status": "active", "steps": [ { "action": "下单", "expected": { "path": "$.code", "op": "equals", "expected": "E001" } } ] }, { "id": "TC-002", "title": "功能用例2", "requirement_refs": ["R-1"], "dimension": "functional", "priority": "P0", "method": ["M1.4"], "status": "active", "steps": [ { "action": "下单2", "expected": { "path": "$.code", "op": "equals", "expected": "E002" } } ] } ]'
  M1='[ { "requirement": "R-1", "methods_applied": ["M1.4"], "skipped": [], "dimensions": ["functional"] } ]'
  mkcases "$WORK/p23a.json" "$C1" "$M1"
  # 场景 2：M1.5 正交要求 functional+data 同时覆盖（dimension_pair_present）→ 给 4 条 functional 用例
  #         （min_cases_total(min=4) 满足、dimension_pair_present 违反）
  C2='[ { "id": "TC-001", "title": "功能用例", "requirement_refs": ["R-1"], "dimension": "functional", "priority": "P0", "method": ["M1.5"], "status": "active", "steps": [ { "action": "下单", "expected": { "path": "$.code", "op": "equals", "expected": "E001" } } ] }, { "id": "TC-002", "title": "功能用例2", "requirement_refs": ["R-1"], "dimension": "functional", "priority": "P0", "method": ["M1.5"], "status": "active", "steps": [ { "action": "下单2", "expected": { "path": "$.code", "op": "equals", "expected": "E002" } } ] }, { "id": "TC-003", "title": "功能用例3", "requirement_refs": ["R-1"], "dimension": "functional", "priority": "P0", "method": ["M1.5"], "status": "active", "steps": [ { "action": "下单3", "expected": { "path": "$.code", "op": "equals", "expected": "E003" } } ] }, { "id": "TC-004", "title": "功能用例4", "requirement_refs": ["R-1"], "dimension": "functional", "priority": "P0", "method": ["M1.5"], "status": "active", "steps": [ { "action": "下单4", "expected": { "path": "$.code", "op": "equals", "expected": "E004" } } ] } ]'
  M2='[ { "requirement": "R-1", "methods_applied": ["M1.5"], "skipped": [], "dimensions": ["functional"] } ]'
  mkcases "$WORK/p23b.json" "$C2" "$M2"
  # 场景 3：M1.3 判定表要求每例 ≥2 条断言（min_assertions_per_case）→ 给 2 条 functional 用例、
  #         每条只有 1 条断言，但两条的 expected 取值**互不相同**
  #         （min_cases_by_dimension(functional,min=2) 与 distinct_expected 都满足）
  C3='[ { "id": "TC-001", "title": "功能用例", "requirement_refs": ["R-1"], "dimension": "functional", "priority": "P0", "method": ["M1.3"], "status": "active", "steps": [ { "action": "下单", "expected": { "path": "$.code", "op": "equals", "expected": "E001" } } ] }, { "id": "TC-002", "title": "功能用例2", "requirement_refs": ["R-1"], "dimension": "functional", "priority": "P0", "method": ["M1.3"], "status": "active", "steps": [ { "action": "下单2", "expected": { "path": "$.code", "op": "equals", "expected": "E002" } } ] } ]'
  M3='[ { "requirement": "R-1", "methods_applied": ["M1.3"], "skipped": [], "dimensions": ["functional"] } ]'
  mkcases "$WORK/p23c.json" "$C3" "$M3"
  # 场景 4：M1.6 场景法要求 ≥2 条用例（min_cases_total）→ 只给 1 条 functional 用例
  #         （min_cases_by_dimension(functional,min=1) 满足、min_cases_total(min=2) 违反）
  C4='[ { "id": "TC-001", "title": "功能用例", "requirement_refs": ["R-1"], "dimension": "functional", "priority": "P0", "method": ["M1.6"], "status": "active", "steps": [ { "action": "下单", "expected": { "path": "$.code", "op": "equals", "expected": "E001" } } ] } ]'
  M4='[ { "requirement": "R-1", "methods_applied": ["M1.6"], "skipped": [], "dimensions": ["functional"] } ]'
  mkcases "$WORK/p23d.json" "$C4" "$M4"
  P23=0
  DET23=""
  for X in "a:M1.4" "b:M1.5" "c:M1.3" "d:M1.6"; do
    F="${X%%:*}"; MID="${X##*:}"
    OUT23="$(node "$CM" "$WORK/p23$F.json" --methods "$MTH" 2>&1)"; RC23=$?
    # 必须退出码≠0，且**同一行**点名该方法编号与"缺少必需产出"
    if [ $RC23 -ne 0 ] && printf '%s' "$OUT23" | grep -E "($MID).*缺少必需产出|缺少必需产出.*($MID)" >/dev/null; then
      P23=$((P23+1))
    else
      DET23="$DET23 [$MID rc=$RC23]"
    fi
  done
  if [ $P23 -eq 4 ]; then
    ok "AC-023 四个谓词分支都真的生效（has_dimension / dimension_pair_present / min_assertions_per_case / min_cases_total）"
  else
    bad "AC-023 四个谓词分支都真的生效" "4 个谓词只测出 $P23/4 失败详情:$DET23"
  fi
fi

# ---------------------------------------------------------------- AC-024
step "AC-024 M0.x/M4.x 判无法判定，不得默认通过（虚报类红线，D17）"
# 实测（独立验收）：把 M0.1 从"无法判定"改成 satisfied（假绿灯），验收脚本仍 23/0。
# 这条是"宁可漏报通过，不可虚报通过"的直接护栏。
if [ ! -f "$CM" ]; then
  bad "AC-024 M0.x 判无法判定" "缺 check-methods.mjs"
else
  # M0.1 属于 Layer 0 必选测试点段，不在设计方法库内 → 必须判"无法判定"
  # ⚠️ 场景 A 必须**只走矩阵级路径**：用例声明的是 M1.1（已登记），
  #    只有矩阵声明 M0.1 → 矩阵级那条 addUndecidable 是唯一来源（D24）。
  CASES_M0='[ { "id": "TC-001", "title": "功能用例", "requirement_refs": ["R-1"], "dimension": "functional", "priority": "P0", "method": ["M1.1"], "status": "active", "steps": [ { "action": "下单", "expected": { "path": "$.code", "op": "equals", "expected": "E001" } } ] } ]'
  MATRIX_M0='[ { "requirement": "R-1", "methods_applied": ["M0.1"], "skipped": [], "dimensions": ["functional"] } ]'
  mkcases "$WORK/m0.json" "$CASES_M0" "$MATRIX_M0"
  node "$CM" "$WORK/m0.json" --methods "$MTH" --json > "$WORK/m0.json.out" 2>/dev/null
  M0_CHK="$(node -e '
  const fs=require("fs");
  let o; try{ o=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); }catch(e){ console.log("parse_err=1|undecl=0|sat=0|err=0"); process.exit(0); }
  const undec=(Array.isArray(o.undecidable)?o.undecidable:[]);
  const verd=(Array.isArray(o.verdicts)?o.verdicts:[]);
  const errs=(Array.isArray(o.errors)?o.errors:[]);
  const isM0=(x)=>String(x&&x.method)==="M0.1"||String(x&&x.method)==="M4.5";
  // ① undecidable 里有 M0.1
  const u=undec.some(isM0)?1:0;
  // ② verdicts 里 M0.1 的 status 是 undecidable，绝不是 satisfied
  const v=verd.find(isM0);
  const s=(v&&v.status==="satisfied")?1:0;
  // ③ errors 里不该有 M0.1（它是"判不了"不是"产出缺失"）
  const e=errs.some(isM0)?1:0;
  console.log(u+"|"+s+"|"+e+"|"+undec.length);
  ' "$WORK/m0.json.out")"
  M0_U="$(printf '%s' "$M0_CHK" | cut -d'|' -f1)"
  M0_S="$(printf '%s' "$M0_CHK" | cut -d'|' -f2)"
  M0_E="$(printf '%s' "$M0_CHK" | cut -d'|' -f3)"
  M0_N="$(printf '%s' "$M0_CHK" | cut -d'|' -f4)"
  # ---- 场景 B：**用例级**声明的未登记编号（独立验收实测的 C10 逃逸）----
  # 场景 A 的样本里，矩阵与用例**都**声明了 M0.1 → 两条路径都会写 undecidable，
  # 删掉任何一条路径都还剩另一条 → 测不出"用例级"这一侧。场景 B 让**矩阵不声明**
  # M0.1、只有用例声明 → 只有用例级路径会触发。
  CASES_M0C='[ { "id": "TC-001", "title": "功能用例", "requirement_refs": ["R-1"], "dimension": "functional", "priority": "P0", "method": ["M0.1"], "status": "active", "steps": [ { "action": "下单", "expected": { "path": "$.code", "op": "equals", "expected": "E001" } } ] } ]'
  MATRIX_M0C='[ { "requirement": "R-1", "methods_applied": ["M1.1"], "skipped": [], "dimensions": ["functional"] } ]'
  mkcases "$WORK/m0c.json" "$CASES_M0C" "$MATRIX_M0C"
  node "$CM" "$WORK/m0c.json" --methods "$MTH" --json > "$WORK/m0c.json.out" 2>/dev/null
  M0C_CHK="$(node -e '
  const fs=require("fs");
  let o; try{ o=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); }catch(e){ console.log("u=0|s=1|v=0|e=1"); process.exit(0); }
  const undec=(Array.isArray(o.undecidable)?o.undecidable:[]);
  const verd=(Array.isArray(o.verdicts)?o.verdicts:[]);
  const errs=(Array.isArray(o.errors)?o.errors:[]);
  const isM0=(x)=>String(x&&x.method)==="M0.1";
  // ① undecidable 里必须有 M0.1
  const u=undec.some(isM0)?1:0;
  // ② verdicts 里 M0.1 的 status 必须是 undecidable（**不得**缺失、**不得** satisfied）
  const v=verd.find(isM0);
  const s=(v&&v.status==="satisfied")?1:0;
  const hasv=(v&&v.status==="undecidable")?1:0;
  // ③ errors 里不该有 M0.1
  const e=errs.some(isM0)?1:0;
  console.log(u+"|"+s+"|"+hasv+"|"+e);
  ' "$WORK/m0c.json.out")"
  M0C_U="$(printf '%s' "$M0C_CHK" | cut -d'|' -f1)"
  M0C_S="$(printf '%s' "$M0C_CHK" | cut -d'|' -f2)"
  M0C_V="$(printf '%s' "$M0C_CHK" | cut -d'|' -f3)"
  M0C_E="$(printf '%s' "$M0C_CHK" | cut -d'|' -f4)"
  if [ "${M0_U:-0}" -eq 1 ] && [ "${M0_S:-1}" -eq 0 ] && [ "${M0_E:-1}" -eq 0 ] && [ "${M0_N:-0}" -ge 1 ] \
     && [ "${M0C_U:-0}" -eq 1 ] && [ "${M0C_S:-1}" -eq 0 ] && [ "${M0C_V:-0}" -eq 1 ] && [ "${M0C_E:-1}" -eq 0 ]; then
    ok "AC-024 M0.x/M4.x 判无法判定、不判通过（矩阵级 + 用例级两条路径；undecidable 有、verdict 是 undecidable、errors 无、satisfied 无）"
  else
    bad "AC-024 M0.x/M4.x 判无法判定、不判通过" \
        "矩阵级: undecidable含M0.1=${M0_U:-?} 判成satisfied=${M0_S:-?} 误入errors=${M0_E:-?} undecidable数=${M0_N:-?}（期望 1/0/0/≥1）| 用例级: undecidable含M0.1=${M0C_U:-?} 判成satisfied=${M0C_S:-?} verdict=undecidable=${M0C_V:-?}（期望1）误入errors=${M0C_E:-?}（期望 1/0/1/0）"
  fi
fi

# ---------------------------------------------------------------- AC-025
step "AC-025 check-methods 侧跳过文案也区分方法/维度（D17 / D13 的另一侧）"
if [ ! -f "$CM" ]; then
  bad "AC-025 check-methods 侧文案区分" "缺 check-methods.mjs"
else
  MATRIX_CM_M='[ { "requirement": "R-1", "methods_applied": ["M1.1"], "skipped": [ { "method": "M1.4" } ], "dimensions": ["functional"] } ]'
  mkcases "$WORK/cmskipm.json" "$CASES_PLAIN" "$MATRIX_CM_M"
  OUT_CMM="$(node "$CM" "$WORK/cmskipm.json" --methods "$MTH" 2>&1)"; RC_CMM=$?
  MATRIX_CM_D='[ { "requirement": "R-1", "methods_applied": ["M1.1"], "skipped": [ { "method": "dimension:concurrency" } ], "dimensions": ["functional"] } ]'
  mkcases "$WORK/cmskipd.json" "$CASES_PLAIN" "$MATRIX_CM_D"
  OUT_CMD="$(node "$CM" "$WORK/cmskipd.json" --methods "$MTH" 2>&1)"; RC_CMD=$?
  CM1_OK=0; CM2_OK=0; CM2_NEG=0
  if [ $RC_CMM -ne 0 ] && same_line "$OUT_CMM" "M1.4" "方法"; then CM1_OK=1; fi
  if [ $RC_CMD -ne 0 ] && same_line "$OUT_CMD" "concurrency" "维度"; then CM2_OK=1; fi
  printf '%s' "$OUT_CMD" | grep -q "跳过方法" && CM2_NEG=1
  if [ $CM1_OK -eq 1 ] && [ $CM2_OK -eq 1 ] && [ $CM2_NEG -eq 0 ]; then
    ok "AC-025 check-methods 侧跳过文案也区分方法/维度"
  else
    bad "AC-025 check-methods 侧跳过文案也区分方法/维度" \
        "方法场景 rc=$RC_CMM(期望≠0,含M1.4+方法) ok=$CM1_OK | 维度场景 rc=$RC_CMD(期望≠0,含concurrency+维度) ok=$CM2_OK | 维度场景出现'跳过方法'=$CM2_NEG(期望0) out1=$OUT_CMM out2=$OUT_CMD"
  fi
fi

# ---------------------------------------------------------------- AC-026
step "AC-026 变异体必须 100% 被检出（合并前硬门槛，D17）"
# 判据语义：**跑本脚本**看护栏能不能测出变异体 —— 不是看实现自己的输出变没变。
# 理由（D17 的根因）：独立验收实测「把 M0.1 从"无法判定"改成 satisfied（假绿灯）后，
# 验收脚本仍 23 PASS / 0 FAIL」—— 逃逸的根因是**验收样本没覆盖那条规则**，
# 而不是实现的输出变了。所以本条的被测对象必须是**验收脚本的判定**。
#
# 两条注入纪律（BA 复现时踩过）：
#   ① 变异必须**保持语法正确** —— 做成语法错误 → 脚本崩溃 → 退出码非 0 → 被"测出"，
#      但那是**假检出**（测出的是崩溃，不是护栏失效）。
#   ② 变异必须让**分支真的失效**而非让 kind 字符串消失 —— 改 kind 字符串会先让
#      库结构校验失败，同样是被"崩溃"测出，不是真检出。
if [ "${QA005_NO_MUT:-0}" = "1" ]; then
  # 嵌套运行（子进程跑本脚本时）：本条在每层都跳过，基线与变异体同口径。
  ok "AC-026 变异体检测（嵌套运行，本层跳过以防递归）"
elif [ ! -f "$CM" ] || [ ! -f "$VC" ]; then
  bad "AC-026 变异体 100% 被检出" "缺 check-methods.mjs 或 validate-cases.mjs"
else
  MUTROOT="$WORK/mutroot"
  mkdir -p "$MUTROOT/skills"
  cp -r "$TCD" "$MUTROOT/skills/test-case-design"
  REPOROOT="$(cd "$TCD/../.." 2>/dev/null && pwd)"
  if [ -d "$REPOROOT/feature-meta" ]; then cp -r "$REPOROOT/feature-meta" "$MUTROOT/feature-meta"; fi
  MUT="$MUTROOT/skills/test-case-design"
  MM="$MUT/scripts/check-methods.mjs"
  MV="$MUT/scripts/validate-cases.mjs"
  MTHM="$MUT/references/methods.json"

  # 抽出「失败的 AC 键集合」—— 判定完全建立在它上面
  failkeys() {
    printf '%s\n' "$1" | sed 's/\x1b\[[0-9;]*m//g' | grep -E '^  FAIL' | grep -oE 'AC-[0-9]+[a-z]*' | sort -u
  }
  # 基线：未变异的副本跑本脚本（跳过 AC-026 自身以防递归）
  BASE_OUT="$(QA005_NO_MUT=1 bash "$SELF" "$MUT" 2>&1)"
  BASE_KEYS="$(failkeys "$BASE_OUT")"
  TOT26=0; DET26=0; ESCAPED=""; INVALID=""; LAST_OUT=""
  # 施加一个变异并判定是否被测出
  # $1=描述  $2=目标文件  $3=node 表达式  $4=cm|vc
  run_mut() {
    TOT26=$((TOT26+1))
    cp "$2" "$WORK/m26.bak"
    if ! node -e "$3" "$2" >/dev/null 2>&1; then
      cp "$WORK/m26.bak" "$2"; INVALID="$INVALID [$1:注入失败]"; return
    fi
    if ! node --check "$2" >/dev/null 2>&1; then
      cp "$WORK/m26.bak" "$2"; INVALID="$INVALID [$1:变异后语法错误=假检出,不计入]"; return
    fi
    # 崩溃检测：变异后的脚本必须还能正常跑 —— 异常栈 = 假检出，不计入
    if [ "$4" = "cm" ]; then
      node "$2" "$WORK/a.json" --methods "$MTHM" >/dev/null 2>"$WORK/m26.err"
    else
      node "$2" "$WORK/a.json" >/dev/null 2>"$WORK/m26.err"
    fi
    if grep -qE "SyntaxError|ReferenceError|TypeError|is not a function|at Object\." "$WORK/m26.err" 2>/dev/null; then
      cp "$WORK/m26.bak" "$2"; INVALID="$INVALID [$1:变异导致崩溃=假检出,不计入]"; return
    fi
    # 跑**本脚本**（嵌套）：护栏必须因为这个变异而多出一条失败
    LAST_OUT="$(QA005_NO_MUT=1 bash "$SELF" "$MUT" 2>&1)"
    K26="$(failkeys "$LAST_OUT")"
    cp "$WORK/m26.bak" "$2"
    # 判定口径：**失败项集合与基线不同**（对称差非空）——
    # 不能只比"基线之上新增"：基线本来就红的 AC（如尚未修的 AC-027）被变异弄坏时，
    # 集合没变 → 会被误判成"逃逸"。对称差同时覆盖两侧。
    NEW26="$(comm -3 <(printf '%s\n' "$BASE_KEYS" | grep -v '^$') <(printf '%s\n' "$K26" | grep -v '^$'))"
    if [ -n "$NEW26" ]; then
      DET26=$((DET26+1))
    else
      ESCAPED="$ESCAPED [$1]"
    fi
  }
  # ---- 1 min_cases_by_dimension 判定失效（kind 字符串保留，只让分支永不命中）----
  run_mut "min_cases_by_dimension判定失效" "$MM" 'const fs=require("fs"),f=process.argv[1];let s=fs.readFileSync(f,"utf8");const from="kind === \x27min_cases_by_dimension\x27";if(!s.includes(from))process.exit(3);fs.writeFileSync(f,s.split(from).join("kind === \x27min_cases_by_dimension_NEVER\x27"));' cm
  # ---- 2 ERROR 不再阻断（退出码恒 0）----
  run_mut "ERROR不再阻断退出码恒0" "$MM" 'const fs=require("fs"),f=process.argv[1];let s=fs.readFileSync(f,"utf8");const from="findings.errors.length > 0 ? 1 : 0";if(!s.includes(from))process.exit(3);fs.writeFileSync(f,s.split(from).join("0"));' cm
  # ---- 3 distinct_expected 子字段谓词失效 ----
  run_mut "distinct_expected谓词失效" "$MM" 'const fs=require("fs"),f=process.argv[1];let s=fs.readFileSync(f,"utf8");const from="predicate.distinct_expected";if(!s.includes(from))process.exit(3);fs.writeFileSync(f,s.split(from).join("predicate.distinct_expected_DISABLED"));' cm
  # ---- 4~7 四个谓词分支失效（kind 字符串保留）----
  run_mut "dimension_pair_present判定失效" "$MM" 'const fs=require("fs"),f=process.argv[1];let s=fs.readFileSync(f,"utf8");const k="dimension_pair_present";const from="kind === \x27"+k+"\x27";if(!s.includes(from))process.exit(3);fs.writeFileSync(f,s.split(from).join("kind === \x27"+k+"_NEVER\x27"));' cm
  run_mut "has_dimension判定失效" "$MM" 'const fs=require("fs"),f=process.argv[1];let s=fs.readFileSync(f,"utf8");const k="has_dimension";const from="kind === \x27"+k+"\x27";if(!s.includes(from))process.exit(3);fs.writeFileSync(f,s.split(from).join("kind === \x27"+k+"_NEVER\x27"));' cm
  run_mut "min_assertions_per_case判定失效" "$MM" 'const fs=require("fs"),f=process.argv[1];let s=fs.readFileSync(f,"utf8");const k="min_assertions_per_case";const from="kind === \x27"+k+"\x27";if(!s.includes(from))process.exit(3);fs.writeFileSync(f,s.split(from).join("kind === \x27"+k+"_NEVER\x27"));' cm
  run_mut "min_cases_total判定失效" "$MM" 'const fs=require("fs"),f=process.argv[1];let s=fs.readFileSync(f,"utf8");const k="min_cases_total";const from="kind === \x27"+k+"\x27";if(!s.includes(from))process.exit(3);fs.writeFileSync(f,s.split(from).join("kind === \x27"+k+"_NEVER\x27"));' cm
  # ---- 8 M0.x/M4.x 由"无法判定"改成默认通过（虚报类）----
  run_mut "M0.x默认通过假绿灯" "$MM" 'const fs=require("fs"),f=process.argv[1];let s=fs.readFileSync(f,"utf8");const anchor="`方法编号 ${methodId} 未在方法库中登记${numberingHint(methodId)}，无法核验`,";const i=s.indexOf(anchor);if(i<0)process.exit(3);const head=s.slice(0,i);const j=head.lastIndexOf("\x27undecidable\x27");if(j<0)process.exit(3);fs.writeFileSync(f,head.slice(0,j)+"\x27satisfied\x27"+s.slice(j+13));' cm
  # ---- 9 维度适用性检查不再报 DIMENSION_MISSING ----
  run_mut "维度适用性检查不再报DIMENSION_MISSING" "$MM" 'const fs=require("fs"),f=process.argv[1];let s=fs.readFileSync(f,"utf8");const from="\x27DIMENSION_MISSING\x27";if(!s.includes(from))process.exit(3);fs.writeFileSync(f,s.split(from).join("\x27DIMENSION_ABSENT\x27"));' cm
  # ---- 10 verdicts 漏判（不覆盖每个 需求×方法 组合）----
  run_mut "verdicts漏判" "$MM" 'const fs=require("fs"),f=process.argv[1];let s=fs.readFileSync(f,"utf8");const from="for (const method of methodsLibrary.methods) {";if(!s.includes(from))process.exit(3);fs.writeFileSync(f,s.split(from).join("for (const method of methodsLibrary.methods.slice(0, 1)) {"));' cm
  # ---- 11 undecidable 误判成 satisfied（虚报类）----
  run_mut "undecidable误判satisfied" "$MM" 'const fs=require("fs"),f=process.argv[1];let s=fs.readFileSync(f,"utf8");const from="\x27undecidable\x27";if(!s.includes(from))process.exit(3);fs.writeFileSync(f,s.split(from).join("\x27satisfied\x27"));' cm
  # ---- 12 check-methods 侧文案回退成"跳过方法" ----
  run_mut "check-methods文案回退成跳过方法" "$MM" 'const fs=require("fs"),f=process.argv[1];let s=fs.readFileSync(f,"utf8");const from="跳过的维度";if(!s.includes(from))process.exit(3);fs.writeFileSync(f,s.split(from).join("跳过的方法"));' cm
  # ---- 13 validate-cases 删掉 dimension: 前缀放宽 ----
  run_mut "VC删掉dimension前缀放宽" "$MV" 'const fs=require("fs"),f=process.argv[1];let s=fs.readFileSync(f,"utf8");const from="if (trimmed.startsWith(DIMENSION_SKIP_PREFIX)) return \x27dimension\x27;";if(!s.includes(from))process.exit(3);fs.writeFileSync(f,s.split(from).join("if (trimmed.startsWith(DIMENSION_SKIP_PREFIX)) return \x27invalid\x27;"));' vc
  # ---- 14 validate-cases 拼错维度名 ERROR 降回 WARN ----
  run_mut "VC拼错维度名ERROR降WARN" "$MV" 'const fs=require("fs"),f=process.argv[1];let s=fs.readFileSync(f,"utf8");const i=s.indexOf("DIMENSIONS.includes(dimName)");if(i<0)process.exit(3);const j=s.indexOf("fail(",i);if(j<0)process.exit(3);fs.writeFileSync(f,s.slice(0,j)+"warn("+s.slice(j+5));' vc
  # ---- 15 validate-cases 读不到 dimensions.json 改成静默降级到内置列表 ----
  run_mut "VC读不到库静默降级内置列表" "$MV" 'const fs=require("fs"),f=process.argv[1];let s=fs.readFileSync(f,"utf8");const from="  } catch (err) {\n    fatal(`无法读取 ${DIMENSIONS_PATH}（${err.message}）`);\n  }";if(!s.includes(from))process.exit(3);fs.writeFileSync(f,s.split(from).join("  } catch (err) {\n    return [\x27functional\x27,\x27boundary\x27,\x27exception\x27,\x27permission\x27,\x27data\x27,\x27concurrency\x27,\x27performance\x27,\x27compatibility\x27];\n  }"));' vc
  # ---- 16 validate-cases 文案统一回"跳过方法" ----
  run_mut "VC文案回退成跳过方法" "$MV" 'const fs=require("fs"),f=process.argv[1];let s=fs.readFileSync(f,"utf8");const from="跳过的维度";if(!s.includes(from))process.exit(3);fs.writeFileSync(f,s.split(from).join("跳过的方法"));' vc
  # ---- 17 validate-cases 放宽 cases[].method[] 接受 dimension: 前缀 ----
  run_mut "VC放宽cases.method接受dimension前缀" "$MV" 'const fs=require("fs"),f=process.argv[1];let s=fs.readFileSync(f,"utf8");const from="if (!METHOD_PATTERN.test(method)) {";const i=s.indexOf(from);if(i<0)process.exit(3);fs.writeFileSync(f,s.slice(0,i)+"if (!(METHOD_PATTERN.test(method) || method.startsWith(DIMENSION_SKIP_PREFIX))) {"+s.slice(i+from.length));' vc
  # ---- 18 validate-cases 放宽 coverage_matrix[].methods_applied[] 接受 dimension: 前缀 ----
  run_mut "VC放宽methods_applied接受dimension前缀" "$MV" 'const fs=require("fs"),f=process.argv[1];let s=fs.readFileSync(f,"utf8");const from="if (!METHOD_PATTERN.test(method)) {";const i=s.indexOf(from);if(i<0)process.exit(3);const j=s.indexOf(from,i+from.length);if(j<0)process.exit(3);fs.writeFileSync(f,s.slice(0,j)+"if (!(METHOD_PATTERN.test(method) || method.startsWith(DIMENSION_SKIP_PREFIX))) {"+s.slice(j+from.length));' vc
  # ---- 19 ERROR 的严重级别标签被改成 WARN ----
  run_mut "ERROR严重级别标签改成WARN" "$MM" 'const fs=require("fs"),f=process.argv[1];let s=fs.readFileSync(f,"utf8");const from="const SEVERITY_ERROR = \x27ERROR\x27;";if(!s.includes(from))process.exit(3);fs.writeFileSync(f,s.split(from).join("const SEVERITY_ERROR = \x27WARN\x27;"));' cm
  # 还原后必须回到基线（确认变异被还原干净）
  RB_OUT="$(QA005_NO_MUT=1 bash "$SELF" "$MUT" 2>&1)"
  RB_KEYS="$(failkeys "$RB_OUT")"
  RB_OK=0
  if [ "$RB_KEYS" = "$BASE_KEYS" ]; then RB_OK=1; fi
  if [ $DET26 -eq $TOT26 ] && [ $TOT26 -ge 19 ] && [ -z "$INVALID" ] && [ $RB_OK -eq 1 ]; then
    ok "AC-026 变异体 100% 被检出（$DET26/$TOT26，还原后回到基线）"
  else
    bad "AC-026 变异体 100% 被检出" \
        "检出 $DET26/$TOT26（要求 19/19 且无注入异常）逃逸:$ESCAPED 注入异常:$INVALID 还原后回到基线=$RB_OK 基线失败项=[$(printf '%s' "$BASE_KEYS" | tr '\n' ' ')] 最后一次嵌套输出尾部=[$(printf '%s' "$LAST_OUT" | tail -5 | tr '\n' ' ')]"
  fi
fi

# ---------------------------------------------------------------- AC-027
step "AC-027 注释不得与实现相反（D19）"
if [ ! -f "$VC" ]; then
  bad "AC-027 注释与实现一致" "缺 validate-cases.mjs"
else
  # 注释里若说"只报 WARN"，实现就必须用 warn；实现用 fail 时注释不得再说"只报 WARN"
  NOTE_SAYS_WARN="$(grep -c "只报 WARN" "$VC" 2>/dev/null)"
  IMPL_IS_FAIL="$(node -e '
  const fs=require("fs");
  let s; try{ s=fs.readFileSync(process.argv[1],"utf8"); }catch(e){ console.log("0"); process.exit(0); }
  // ⚠️ 定位必须用**代码唯一**的字面量，不能用注释散文（如"不在覆盖维度枚举内"）——
  //    注释一旦被改写（这正是本条要防的事），定位就会漂到别处，判据跟着失真。
  //    "DIMENSIONS.includes(dimName)" 只可能出现在代码里。
  const i=s.indexOf("DIMENSIONS.includes(dimName)");
  if(i<0){ console.log("0"); process.exit(0); }
  // 该分支里**第一个**严重级别调用就是实现本身
  const tail=s.slice(i,i+600);
  const f=tail.indexOf("fail(");
  const w=tail.indexOf("warn(");
  console.log((f>=0 && (w<0 || f<w))?1:0);
  ' "$VC" 2>/dev/null)"
  N27_OK=0
  if [ "${NOTE_SAYS_WARN:-0}" -eq 0 ] || [ "${IMPL_IS_FAIL:-0}" -eq 0 ]; then N27_OK=1; fi
  if [ $N27_OK -eq 1 ]; then
    ok "AC-027 注释与实现一致（无'只报 WARN'残留或实现确为 warn）"
  else
    bad "AC-027 注释与实现一致" "注释仍说'只报 WARN'出现${NOTE_SAYS_WARN:-?}次，但实现用的是 fail(ERROR) —— 后人照注释改回去即制造回归"
  fi
fi

# ---------------------------------------------------------------- AC-028
step "AC-028 feature-meta 不得张冠李戴（D19 / D20）"
# feature-meta 在**仓库根**（skills/<name>/ 的上上级），不是 skill 目录的同级。
FMETA="$(cd "$TCD/../.." 2>/dev/null && pwd)/feature-meta"
# 独立验收第四轮 A39：**删掉整个 feature-meta/ 目录 → 验收仍 35 PASS / 0 FAIL**。
# 根因：护栏在「找不到被护对象」时自我豁免（判"不适用"）。但追溯件
# （status.md / traceability.md / verification-report.md / manifest.json）
# 本身就是 REQ-005 的交付物之一（D19 / D20）——「找不到」不等于「不适用」，
# 缺失一律判 FAIL；单缺一个文件同理（否则删掉 traceability.md 即逃逸）。
FM_FILES="status.md traceability.md verification-report.md manifest.json"
FM_MISSING=""
for F in $FM_FILES; do
  [ -f "$FMETA/$F" ] || FM_MISSING="$FM_MISSING $F"
done
if [ ! -d "$FMETA" ]; then
  bad "AC-028 feature-meta 归属正确、demand_dir 存在" \
      "feature-meta/ 目录缺失（$FMETA）—— 追溯件是 REQ-005 的交付物之一，缺失不得判'不适用'放行"
elif [ -n "$FM_MISSING" ]; then
  bad "AC-028 feature-meta 归属正确、demand_dir 存在" \
      "feature-meta/ 缺少文件：$FM_MISSING —— 四件套（status.md / traceability.md / verification-report.md / manifest.json）缺一即追溯链断裂"
else
  # 每份追溯文件必须**自证是本 REQ 的**（第五轮 A47/A50、第六轮 A57~A60）
  # ⚠️ 第六轮实测：光查"含不含 REQ-005"是**存在性**检查 → 留一处 REQ-005 的 **token 骨架**照样判绿
  #（A57/A59/A60），整份改讲 REQ-002A 但留一处 REQ-005 也照样判绿（A58）。
  # 故本条从"存在性"升级为**主体性**：
  #   ① 每份文件的**首行**必须自证是本 REQ 的
  #   ② 每份文件里 REQ-005 的出现次数必须**多于**任何其它 REQ 编号（本 REQ 是主体，上游基线只能是配角）
  #   ③ manifest.json 的 req 必须 == REQ-005；branch 里**有且只有一个** REQ 编号且必须是 REQ-005
  #      （第六轮 A61：子串匹配 `feature/REQ-002A-REQ-005` 会漏过）
  FM_SELF="$(node -e '
  const fs=require("fs");
  const fmeta=process.argv[1];
  const files=["status.md","traceability.md","verification-report.md"];
  let bad=[];
  for(const F of files){
    let t=""; try{ t=fs.readFileSync(fmeta+"/"+F,"utf8"); }catch(e){ continue; }
    const first=(t.split(/\r?\n/).find(l=>l.trim().length>0)||"");
    if(first.indexOf("REQ-005")<0) bad.push(F+"(首行未自证 REQ-005)");
    const cnt={};
    for(const m of t.matchAll(/REQ-[0-9A-Za-z.]+/g)) cnt[m[0]]=(cnt[m[0]]||0)+1;
    const self=cnt["REQ-005"]||0;
    let maxOther=0, maxId="(无)";
    for(const id of Object.keys(cnt)){
      if(id==="REQ-005") continue;
      if(cnt[id]>maxOther){ maxOther=cnt[id]; maxId=id; }
    }
    if(self<=maxOther) bad.push(F+"(主体性不足: REQ-005 出现 "+self+" 次，未多于 "+maxId+" 的 "+maxOther+" 次)");
  }
  let mo=null; try{ mo=JSON.parse(fs.readFileSync(fmeta+"/manifest.json","utf8")); }catch(e){}
  if(!mo){ bad.push("manifest.json(不可解析)"); }
  else{
    if(mo.req!=="REQ-005") bad.push("manifest.json(req="+(mo.req||"空")+")");
    const bids=[...new Set(String(mo.branch||"").match(/REQ-[0-9A-Za-z.]+/g)||[])];
    if(bids.length!==1 || bids[0]!=="REQ-005") bad.push("manifest.json(branch="+(mo.branch||"空")+")");
  }
  console.log(bad.join("; "));
  ' "$FMETA" 2>/dev/null)"
  FM_OTHER=""
  for F in status.md traceability.md verification-report.md; do
    if [ -f "$FMETA/$F" ]; then
      # 出现**其它 REQ 编号** = 张冠李戴。
      # 允许出现：REQ-005（本体）、REQ-001 / REQ-002*（上游基线，REQ-005 依赖它们）。
      HIT="$(node -e '
      const fs=require("fs");
      let s; try{ s=fs.readFileSync(process.argv[1],"utf8"); }catch(e){ console.log(""); process.exit(0); }
      const allowed=(id)=> id==="REQ-005" || id==="REQ-001" || id.indexOf("REQ-002")===0;
      const bad=[...new Set((s.match(/REQ-[0-9A-Za-z.]+/g)||[]).filter((x)=>!allowed(x)))];
      console.log(bad.join(","));
      ' "$FMETA/$F" 2>/dev/null)"
      if [ -n "$HIT" ]; then FM_OTHER="$FM_OTHER [$F:$HIT]"; fi
    fi
  done
  # manifest.json 的 demand_dir 必须指向真实存在的目录
  DMISS=""
  if [ -f "$FMETA/manifest.json" ]; then
    DDIR="$(node -e 'const fs=require("fs");let o;try{o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));}catch(e){process.exit(0);}console.log(o.demand_dir||"");' "$FMETA/manifest.json" 2>/dev/null)"
    if [ -z "$DDIR" ]; then
      DMISS="(空 demand_dir)"
    else
      # demand_dir 必须指向**本 REQ 的需求目录**，而不只是「某个存在的目录」
      # （A39 同族漏洞：指向 REQ-004 的目录也能通过 = 追溯链张冠李戴）
      FOUND=0
      SELFDIR_ABS="$(cd "$SELF_DIR" 2>/dev/null && pwd -P)"
      for R in "$DEMAND_ROOT" "$(cd "$TCD/../../.." 2>/dev/null && pwd)" "$(cd "$TCD/../../../.." 2>/dev/null && pwd)"; do
        [ -n "$R" ] || continue
        if [ -d "$R/$DDIR" ]; then
          CAND="$(cd "$R/$DDIR" 2>/dev/null && pwd -P)"
          if [ -n "$CAND" ] && [ "$CAND" = "$SELFDIR_ABS" ]; then FOUND=1; break; fi
        fi
      done
      if [ $FOUND -eq 0 ]; then DMISS="$DDIR"; fi
    fi
  fi
  if [ -z "$FM_OTHER" ] && [ -z "$DMISS" ] && [ -z "$FM_SELF" ]; then
    ok "AC-028 feature-meta 归属正确、demand_dir 存在"
  else
    bad "AC-028 feature-meta 归属正确、demand_dir 存在" "其它REQ编号:$FM_OTHER demand_dir不存在:$DMISS 归属不对:$FM_SELF"
  fi
fi

# ---------------------------------------------------------------- AC-029
step "AC-029 ERROR 必须真的标成 ERROR（不得被降级成 WARN）"
# 为什么要有这条：AC-026 的变异清单第 19 条「ERROR 的严重级别标签被改成 WARN」
# **此前没有任何 AC 护栏** —— 改完之后验收脚本照样全绿。
# 后果不是"退出码变了"（退出码由 errors.length 决定，仍是 1），而是**输出骗人**：
# agent 看到 "WARN 明细" 就以为可以放过，而契约要求"ERROR 必须修、WARN 必须说明"。
# 这是 D9 的第四次应验：实现写了、验收没测 → 随时会被悄悄改回去。
#
# ⚠️ 查的是**人读输出**（不带 --json）：severity 标签只出现在人读报告里，
#    --json 的 findings 字段把 severity 裁掉了（errors[]/warnings[] 两个数组本身
#    已经表达了严重度，JSON 里再放一份是冗余）。查 JSON 会得到假阴性。
if [ ! -f "$CM" ]; then
  bad "AC-029 ERROR 必须真的标成 ERROR" "缺 check-methods.mjs"
else
  SEVOUT="$(node "$CM" "$WORK/a.json" --methods "$MTH" 2>&1)"
  node "$CM" "$WORK/a.json" --methods "$MTH" --json > "$WORK/sev.json" 2>/dev/null
  SEVJ="$(node -e '
  const fs=require("fs");
  let o; try{ o=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); }catch(e){ console.log("e=0"); process.exit(0); }
  console.log("e="+(o.summary&&Number(o.summary.errors)||0));
  ' "$WORK/sev.json" 2>/dev/null)"
  SE="$(printf '%s\n' "$SEVJ" | sed -n 's/^e=//p')"
  # ① 产出缺失那一节的标题必须是 "ERROR 明细"
  L1=0; printf '%s\n' "$SEVOUT" | grep -F "ERROR 明细" >/dev/null && L1=1
  # ② "结论:" 那一行里，错误计数必须标成 ERROR
  L2=0; same_line "$SEVOUT" "结论:" "个 ERROR" && L2=1
  # ③ 适用性存疑那一节的标题必须是 "WARN 明细"
  L3=0; printf '%s\n' "$SEVOUT" | grep -F "WARN 明细" >/dev/null && L3=1
  # ④ 人读输出里的错误条数必须与 --json 的 summary.errors 一致（标签对了、计数也得对）
  L4=0
  CNTN="$(printf '%s\n' "$SEVOUT" | grep -F "结论:" | head -1 | sed -n 's/.*结论: \([0-9][0-9]*\) 个.*/\1/p')"
  if [ -n "$CNTN" ] && [ "${SE:-0}" -gt 0 ] && [ "$CNTN" = "$SE" ]; then L4=1; fi
  if [ $L1 -eq 1 ] && [ $L2 -eq 1 ] && [ $L3 -eq 1 ] && [ $L4 -eq 1 ]; then
    ok "AC-029 ERROR/WARN 的严重级别标签与实际后果一致（产出缺失必须标成 ERROR）"
  else
    bad "AC-029 ERROR/WARN 的严重级别标签与实际后果一致" \
        "ERROR明细标题=$L1(期望1) 结论行标ERROR=$L2(期望1) WARN明细标题=$L3(期望1) 计数一致=$L4(期望1,人读=$CNTN json=${SE:-?}) 输出=[$(printf '%s' "$SEVOUT" | head -8 | tr '\n' ' ')]"
  fi
fi

# ---------------------------------------------------------------- AC-030
step "AC-030 --help 属用法错误：两个脚本都必须退出码 2 并给出用法（D19 第②项）"
# 为什么要有这条：D19 列的三项 P2 里，只有①（注释）和③（feature-meta）有 AC 护栏，
# ②（--help 退出码口径）**此前完全没有 AC** —— 实测两个脚本对同一个 --help
# 给出不同结论：check-methods rc=2（用法错误），validate-cases rc=1
# （把 --help 当成用例集文件路径 → "无法读取用例集文件"）。
# 两个脚本的脚本头都声明「2 = 调用方式错误」，所以 validate-cases 的 rc=1 是错的。
# 又一次 D9：实现写了、验收没测 → 随时会被改回去。
if [ ! -f "$CM" ] || [ ! -f "$VC" ]; then
  bad "AC-030 --help 退出码口径一致" "缺 check-methods.mjs 或 validate-cases.mjs"
else
  HCM="$(node "$CM" --help 2>&1)"; HCM_RC=$?
  HVC="$(node "$VC" --help 2>&1)"; HVC_RC=$?
  H1=0; H2=0
  if [ $HCM_RC -eq 2 ] && printf '%s\n' "$HCM" | grep -F "用法" >/dev/null; then H1=1; fi
  if [ $HVC_RC -eq 2 ] && printf '%s\n' "$HVC" | grep -F "用法" >/dev/null; then H2=1; fi
  if [ $H1 -eq 1 ] && [ $H2 -eq 1 ]; then
    ok "AC-030 --help 两个脚本都退出码 2 并给出用法"
  else
    bad "AC-030 --help 退出码口径一致" \
        "check-methods rc=$HCM_RC(期望2且含用法) ok=$H1 | validate-cases rc=$HVC_RC(期望2且含用法) ok=$H2 out1=[$(printf '%s' "$HCM" | head -3 | tr '\n' ' ')] out2=[$(printf '%s' "$HVC" | head -3 | tr '\n' ' ')]"
  fi
fi

# ---------------------------------------------------------------- AC-031
step "AC-031 独立的 distinct_expected 谓词种类必须真的被核验（D24）"
# 背景：契约 D6 定了「distinct_expected 以**子字段**形式为准」，但实现里**同时**保留了
# 「独立 kind」的分支（`kind === 'distinct_expected'`），而且 `PREDICATE_KINDS` 收录了它
# —— 即实现**对外承诺支持**这个 kind。可 methods.json 从没用它 → 那段分支**从未被执行**，
# 也就**没有任何 AC 保护**。独立验收实测：把该分支改成恒返回 ok，验收脚本仍 31 PASS / 0 FAIL。
# 两种处置：① 删掉（死代码）② **给它补上验收**。BA 选②（保留支持 + 补保护）：
#   删掉后，"有人写了这个 kind"会退化成**静默忽略**（校验器若不再报错、核验器也不再执行）
#   —— 那才是真正的虚报。保留并保护它，才能做到"写了就一定被核验"。
# 判据用**数据级**手段：给副本的 methods.json 加一个用独立 kind 的方法，验证它被真的核验。
if [ ! -f "$CM" ] || [ ! -f "$MTH" ]; then
  bad "AC-031 独立 distinct_expected kind 被核验" "缺 check-methods.mjs 或 methods.json"
else
  cp -r "$TCD" "$WORK/de-skill"
  node -e '
  const fs=require("fs"),f=process.argv[1];
  const o=JSON.parse(fs.readFileSync(f,"utf8"));
  o.methods.push({
    id:"M9.9",
    name:"区分度探针（AC-031 用）",
    aliases:[],
    purpose:"独立验收用的探针方法，验证 kind=distinct_expected 这条路径真的会被执行。",
    applies_when:["长度"],
    not_applies_when:[],
    required_outputs:[ { kind:"distinct_expected", dimension:"boundary", min:2 } ],
    typical_dimensions:["boundary"],
    anti_patterns:[]
  });
  fs.writeFileSync(f,JSON.stringify(o,null,2));
  ' "$WORK/de-skill/references/methods.json" 2>/dev/null
  MTH_DE="$WORK/de-skill/references/methods.json"
  # 需求文本含"长度" → 命中 M9.9 的适用信号
  REQ_LEN='[ { "id": "R-1", "title": "密码长度 8-20 位", "source_ref": "x", "testable": true } ]'
  # 反例：2 条 boundary 用例，expected 取值**完全相同** → 区分度不足，必须报错
  DE_BAD='[ { "id": "TC-001", "title": "功能用例", "requirement_refs": ["R-1"], "dimension": "functional", "priority": "P0", "method": ["M1.1"], "status": "active", "steps": [ { "action": "下单", "expected": { "path": "$.code", "op": "equals", "expected": "E001" } } ] }, { "id": "TC-002", "title": "边界下界", "requirement_refs": ["R-1"], "dimension": "boundary", "priority": "P0", "method": ["M1.1"], "status": "active", "steps": [ { "action": "长度7", "expected": { "path": "$.len", "op": "equals", "expected": "7" } } ] }, { "id": "TC-003", "title": "边界上界", "requirement_refs": ["R-1"], "dimension": "boundary", "priority": "P0", "method": ["M1.1"], "status": "active", "steps": [ { "action": "长度8", "expected": { "path": "$.len", "op": "equals", "expected": "7" } } ] } ]'
  # 正例：取值互不相同 → 区分度够，不该报错
  DE_OK='[ { "id": "TC-001", "title": "功能用例", "requirement_refs": ["R-1"], "dimension": "functional", "priority": "P0", "method": ["M1.1"], "status": "active", "steps": [ { "action": "下单", "expected": { "path": "$.code", "op": "equals", "expected": "E001" } } ] }, { "id": "TC-002", "title": "边界下界", "requirement_refs": ["R-1"], "dimension": "boundary", "priority": "P0", "method": ["M1.1"], "status": "active", "steps": [ { "action": "长度7", "expected": { "path": "$.len", "op": "equals", "expected": "7" } } ] }, { "id": "TC-003", "title": "边界上界", "requirement_refs": ["R-1"], "dimension": "boundary", "priority": "P0", "method": ["M1.1"], "status": "active", "steps": [ { "action": "长度8", "expected": { "path": "$.len", "op": "equals", "expected": "8" } } ] } ]'
  MATRIX_DE='[ { "requirement": "R-1", "methods_applied": ["M9.9"], "skipped": [], "dimensions": ["functional","boundary"] } ]'
  mkcases "$WORK/de_bad.json" "$DE_BAD" "$MATRIX_DE"
  mkcases "$WORK/de_ok.json" "$DE_OK" "$MATRIX_DE"
  OUT_DE_BAD="$(node "$WORK/de-skill/scripts/check-methods.mjs" "$WORK/de_bad.json" --methods "$MTH_DE" 2>&1)"; RC_DE_BAD=$?
  OUT_DE_OK="$(node "$WORK/de-skill/scripts/check-methods.mjs" "$WORK/de_ok.json" --methods "$MTH_DE" 2>&1)"; RC_DE_OK=$?
  DE_NEG=0; DE_POS=0
  # 反例：必须报错（且点名区分度）
  if [ $RC_DE_BAD -ne 0 ] && printf '%s' "$OUT_DE_BAD" | grep -q "区分度"; then DE_NEG=1; fi
  # 正例：不得报错（否则这条判据恒红）
  if [ $RC_DE_OK -eq 0 ]; then DE_POS=1; fi
  if [ $DE_NEG -eq 1 ] && [ $DE_POS -eq 1 ]; then
    ok "AC-031 独立 distinct_expected kind 真的被核验（取值全同→报错 / 取值互异→通过）"
  else
    bad "AC-031 独立 distinct_expected kind 被核验" \
        "反例 rc=$RC_DE_BAD(期望≠0且点名区分度) ok=$DE_NEG | 正例 rc=$RC_DE_OK(期望0) ok=$DE_POS out1=[$(printf '%s' "$OUT_DE_BAD" | grep -E '结论|METHOD_OUTPUT_MISSING' | head -2 | tr '\n' ' ')] out2=[$(printf '%s' "$OUT_DE_OK" | grep -E '结论' | head -1 | tr '\n' ' ')]"
  fi
fi

# ---------------------------------------------------------------- AC-032
step "AC-032 dimension: 前缀的适用范围：文档必须与实现一致（D12 / D24）"
# 为什么要有这条：独立验收第三轮实测 —— 把 case-schema.md 里 D12 那句契约
# （「`dimension:` 前缀只出现在 `skipped[]` 里」）改成「它可以出现在任何方法字段里」，
# **验收脚本仍然 31 PASS / 0 FAIL** —— 这句契约**完全没有验收护栏**（002A 回归脚本也不查）。
# 后果不是虚报通过，而是**契约与实现分叉**：agent 照文档把 `dimension:` 写进
# `cases[].method` → validate-cases 拒绝 → agent 以为自己写对了却老是被打回。
# 契约文档本身就是交付物（不是实现完成后的收尾）—— 这条是 D9 的第五次应验。
if [ ! -f "$TCD/references/case-schema.md" ] || [ ! -f "$VC" ]; then
  bad "AC-032 dimension: 前缀适用范围文档与实现一致" "缺 case-schema.md 或 validate-cases.mjs"
else
  DOCSCHEMA="$TCD/references/case-schema.md"
  # ① 必须存在把 `dimension:` 限定在 skipped[] 的说明（含 "dimension:" + "skipped" + 限定词）
  LIMIT_HIT=0
  if grep -F "dimension:" "$DOCSCHEMA" 2>/dev/null | grep -F "skipped" | grep -E "只|仅" >/dev/null; then LIMIT_HIT=1; fi
  # ② 不得出现把 dimension: 放宽到任意方法字段 / 任意位置的措辞
  LOOSE=""
  for P in "任何方法字段" "任意方法字段" "任何位置" "任意位置" "任何方法列表"; do
    if grep -F "$P" "$DOCSCHEMA" >/dev/null 2>&1; then LOOSE="$LOOSE [$P]"; fi
  done
  # ③ 正反对消：文档说"只在 skipped[]" → 实测 skipped[] 接受、cases[].method 拒绝
  #    （与实现一致；两处已有判据 AC-022 / AC-016，这里独立复核一遍，防止文档与实现同时被改）
  CASES_SK='[ { "id": "TC-001", "title": "功能用例", "requirement_refs": ["R-1"], "dimension": "functional", "priority": "P0", "method": ["M1.1"], "status": "active", "steps": [ { "action": "下单", "expected": { "path": "$.code", "op": "equals", "expected": "E001" } } ] } ]'
  MATRIX_SKD='[ { "requirement": "R-1", "methods_applied": ["M1.1"], "skipped": [ { "method": "dimension:concurrency", "reason": "无并发语义" } ], "dimensions": ["functional"] } ]'
  mkcases "$WORK/skd.json" "$CASES_SK" "$MATRIX_SKD"
  node "$VC" "$WORK/skd.json" >/dev/null 2>&1; RC_SKD=$?
  MATRIX_SKC='[ { "requirement": "R-1", "methods_applied": ["M1.1"], "skipped": [], "dimensions": ["functional"] } ]'
  CASES_SKC='[ { "id": "TC-001", "title": "功能用例", "requirement_refs": ["R-1"], "dimension": "functional", "priority": "P0", "method": ["dimension:concurrency"], "status": "active", "steps": [ { "action": "下单", "expected": { "path": "$.code", "op": "equals", "expected": "E001" } } ] } ]'
  mkcases "$WORK/skc.json" "$CASES_SKC" "$MATRIX_SKC"
  node "$VC" "$WORK/skc.json" >/dev/null 2>&1; RC_SKC=$?
  BEH_OK=0
  if [ $RC_SKD -eq 0 ] && [ $RC_SKC -ne 0 ]; then BEH_OK=1; fi
  if [ $LIMIT_HIT -eq 1 ] && [ -z "$LOOSE" ] && [ $BEH_OK -eq 1 ]; then
    ok "AC-032 dimension: 前缀适用范围：文档限定在 skipped[]、无放宽措辞、实现与之一致"
  else
    bad "AC-032 dimension: 前缀适用范围文档与实现一致" \
        "文档有限定说明=$LIMIT_HIT(期望1) 放宽措辞=$LOOSE(期望空) 行为一致(skipped接受/cases.method拒绝)=$BEH_OK(期望1,rc_skipped=$RC_SKD rc_cases=$RC_SKC)"
  fi
fi

# ---------------------------------------------------------------- AC-033
step "AC-033 coverage-dimensions.md 必须声明「以 dimensions.json 为准」（D16 / D24）"
# 为什么要有这条：独立验收第三轮实测 —— 把 coverage-dimensions.md 里 D16 那句契约
# （「**以 references/dimensions.json 为准** —— 它是维度枚举的唯一来源 /
#   本清单与它的一致性由脚本对照保证（不需要人工同步）」）
# 改成「**以本清单为准** … 需要人工同步」，
# **验收脚本在所有版本上都仍然全绿** —— 这句契约**完全没有验收护栏**
# （AC-021 只比"md 表格的 id 集合"与"json 的 id 集合"，不看这句"以谁为准"的声明）。
# 后果不是虚报通过，而是**契约与实现分叉**：SKILL.md 明让 agent 读这份清单当维度取值来源，
# 清单若自称权威、而实现只认 json → agent 照清单写一个库里没有的维度 → 校验器报错，
# agent 不知道自己该信哪个文件。这与 D16 要消灭的"三份副本"是同一个病根。
if [ ! -f "$DIMDOC" ] || [ ! -f "$DIM" ]; then
  bad "AC-033 维度清单声明以 dimensions.json 为准" "缺 coverage-dimensions.md 或 dimensions.json"
else
  # ① 必须声明 dimensions.json 是唯一来源
  SRC_HIT=0
  if grep -F "dimensions.json" "$DIMDOC" 2>/dev/null | grep -E "为准" | grep -E "唯一来源" >/dev/null; then SRC_HIT=1; fi
  # ② 不得把本清单抬成真相源 / 不得要求人工同步
  LOOSE=""
  for P in "以本清单为准" "以清单为准"; do
    if grep -F "$P" "$DIMDOC" >/dev/null 2>&1; then LOOSE="$LOOSE [$P]"; fi
  done
  # ⚠️ 「需要人工同步」必须用**负向后顾**判 —— 文档里正常写的是「**不需要**人工同步」，
  #    朴素子串匹配会把那句正确表述也当成放宽措辞（BA 侧第一版就这么写错的，
  #    第一次跑就被自己的判据误伤 —— 与 AC-017/AC-025 的"同行约束"同一个教训）。
  if grep -P "(?<!不)需要(人工|手动)同步" "$DIMDOC" >/dev/null 2>&1; then LOOSE="$LOOSE [需要人工同步(非'不需要')]"; fi
  # ③ 正反对消：清单与库不一致时**以库为准** —— 给副本的库加一个清单里没有的维度，
  #    对照检查必须报错并点名那个维度（即"以库为准"在行为上的体现）
  cp -r "$TCD" "$WORK/src-skill"
  node -e '
  const fs=require("fs"),f=process.argv[1];
  const o=JSON.parse(fs.readFileSync(f,"utf8"));
  o.dimensions.push({id:"audit",name:"审计",always_applies:false,applies_when:["审计"],skip_reason_required:true,skip_reason_hint:"无审计留痕要求",description:"审计留痕。"});
  fs.writeFileSync(f,JSON.stringify(o,null,2));
  ' "$WORK/src-skill/references/dimensions.json" 2>/dev/null
  SRC_OUT=""; SRC_RC=2; SRC_OK=0
  try_src() {
    local o r
    o="$(node "$WORK/src-skill/scripts/check-methods.mjs" "$@" 2>&1)"; r=$?
    if [ $r -ne 2 ] && [ $r -ne 0 ] && printf '%s' "$o" | grep -q "audit"; then
      SRC_OUT="$o"; SRC_RC=$r; SRC_OK=1; return 0
    fi
    return 1
  }
  try_src --methods "$WORK/src-skill/references/methods.json" --dimensions "$WORK/src-skill/references/dimensions.json" --dimensions-doc "$WORK/src-skill/references/coverage-dimensions.md" --check-dimensions-doc || \
  try_src --methods "$WORK/src-skill/references/methods.json" --dimensions "$WORK/src-skill/references/dimensions.json" --dimensions-doc "$WORK/src-skill/references/coverage-dimensions.md" --check-doc || \
  try_src --methods "$WORK/src-skill/references/methods.json" --dimensions "$WORK/src-skill/references/dimensions.json" --doc "$WORK/src-skill/references/coverage-dimensions.md" --check-doc || \
  try_src --methods "$WORK/src-skill/references/methods.json" --dimensions "$WORK/src-skill/references/dimensions.json" --check-doc || \
  try_src --methods "$WORK/src-skill/references/methods.json" --dimensions "$WORK/src-skill/references/dimensions.json" --dimensions-doc "$WORK/src-skill/references/coverage-dimensions.md" || \
  try_src --check-dimensions-doc --dimensions-doc "$WORK/src-skill/references/coverage-dimensions.md" --dimensions "$WORK/src-skill/references/dimensions.json"
  if [ $SRC_HIT -eq 1 ] && [ -z "$LOOSE" ] && [ $SRC_OK -eq 1 ]; then
    ok "AC-033 维度清单声明以 dimensions.json 为唯一来源、无「以清单为准」措辞、且不一致时以库为准"
  else
    bad "AC-033 维度清单声明以 dimensions.json 为准" \
        "声明唯一来源=$SRC_HIT(期望1) 放宽措辞=$LOOSE(期望空) 不一致时以库为准=$SRC_OK(期望1,rc=$SRC_RC) out=[$(printf '%s' "$SRC_OUT" | head -3 | tr '\n' ' ')]"
  fi
fi

# ---------------------------------------------------------------- AC-034
step "AC-034 feature-meta 里的判据条数 / 决策号 / 验收数字必须与实际一致（D25）"
# 为什么要有这条：独立验收第三轮发现 —— `feature-meta/` 三份文件里写的
# 「`acceptance.md` 31 条判据 / `decisions.md` D1~D22 / 主验收 31 PASS / 0 FAIL」
# 在 BA 侧判据扩到 34 条、决策写到 D25 之后**全部陈旧**，而**没有任何判据守这个**。
# 后果：追溯链上的数字是**没人核过的** —— 这正是本套件要消灭的那类"看着像已验、其实没验"。
# 这条把「元数据里的数字」也纳入机械核验：数字必须与**当前**的判据数、决策号、验收结果一致。
if [ ! -d "$FMETA" ]; then
  bad "AC-034 feature-meta 数字与实际一致" \
      "feature-meta/ 目录缺失（$FMETA）—— 没有追溯件可比对，不得判'不适用'放行"
elif [ -n "$FM_MISSING" ]; then
  bad "AC-034 feature-meta 数字与实际一致" \
      "feature-meta/ 缺少文件：$FM_MISSING —— 比对基线不完整，数字无处可核"
else
  M34="$(node -e '
  const fs=require("fs");
  const fmeta=process.argv[1], acc=process.argv[2], dec=process.argv[3];
  const mth=process.argv[4], dim=process.argv[5], tcd=process.argv[6];
  let prob=[];
  let accText=""; try{ accText=fs.readFileSync(acc,"utf8"); }catch(e){}
  const actual=(accText.match(/^### AC-/gm)||[]).length;
  let decText=""; try{ decText=fs.readFileSync(dec,"utf8"); }catch(e){}
  const dnums=[...decText.matchAll(/^\| D(\d+) \|/gm)].map(m=>Number(m[1]));
  const dmax=dnums.length?Math.max(...dnums):0;
  const files=["status.md","traceability.md","verification-report.md"];
  let nCount=0, dCount=0, repLine=null;
  const perFile={};
  for(const F of files){
    const p=fmeta+"/"+F;
    let t=""; try{ t=fs.readFileSync(p,"utf8"); }catch(e){ continue; }
    let fn=0, fd=0;
    for(const m of t.matchAll(/(\d+)\s*条判据/g)){
      nCount++; fn++;
      if(Number(m[1])!==actual) prob.push(F+": 判据条数写 "+m[1]+"，实际 "+actual);
    }
    for(const m of t.matchAll(/D1~D(\d+)/g)){
      dCount++; fd++;
      if(Number(m[1])!==dmax) prob.push(F+": 决策号写 D1~D"+m[1]+"，实际 D1~D"+dmax);
    }
    // 第五轮 A46：掏空其中一份仍能过（此前只查**合计**）→ 每份都要自己写清判据条数与决策号
    if(fn===0) prob.push(F+": 一处「N 条判据」都没有 —— 该文件自己的追溯链写空了");
    if(fd===0) prob.push(F+": 一处「D1~D<n>」都没有 —— 该文件自己的追溯链写空了");
    perFile[F]=t;
    if(F==="verification-report.md"){
      for(const ln of t.split(/\r?\n/)){
        if(ln.includes("主验收") && ln.includes("PASS")) { repLine=ln; break; }
      }
    }
  }
  // ---- 追溯链声明的**实现形状数字**必须与实际一致（第五轮 A52：矩阵写 methods[6]，实现变成 7 个）
  let mIds=[], dCount2=-1;
  try{ const o=JSON.parse(fs.readFileSync(mth,"utf8")); mIds=(o.methods||[]).map(m=>m.id); }catch(e){}
  const mN=mIds.length;
  const tr=perFile["traceability.md"]||"";
  const mTokens=[...tr.matchAll(/methods\[(\d+)\]/g)].map(m=>Number(m[1]));
  if(mTokens.length===0) prob.push("traceability.md: 没有写 methods[N]（方法数）—— 追溯链没记实现的形状");
  else if(mTokens.length>1) prob.push("traceability.md: methods[N] 写了 "+mTokens.length+" 处（应为恰好 1 处）");
  else if(mTokens[0]!==mN) prob.push("traceability.md: 写 methods["+mTokens[0]+"]，实际方法数 "+mN+" —— 追溯链与实现脱同步");
  // status.md 声明的方法 id 区间必须与实际方法 id 集合一致
  const st=perFile["status.md"]||"";
  const rg=[...st.matchAll(/M(\d+)\.(\d+)\s*~\s*M(\d+)\.(\d+)/g)];
  if(rg.length===0) prob.push("status.md: 没有写方法 id 区间（M<a>.<b>~M<c>.<d>）—— 追溯链没记方法清单");
  else{
    const g=rg[0]; const maj="M"+g[1];
    const lo=Number(g[2]), hi=Number(g[4]);
    const implied=[]; for(let i=lo;i<=hi;i++) implied.push(maj+"."+i);
    const same = implied.length===mIds.length && implied.every((x,i)=>x===mIds[i]);
    if(!same) prob.push("status.md: 写的方法区间 "+maj+"."+lo+"~"+maj+"."+hi+"，实际方法 id 为 ["+mIds.join(",")+"] —— 追溯链与实现脱同步");
  }
  // status.md 声明的维度数必须与 dimensions.json 实际维度数一致
  let dIds=[];
  try{ const o=JSON.parse(fs.readFileSync(dim,"utf8")); dIds=(o.dimensions||[]).map(d=>d.id); }catch(e){}
  const dN=dIds.length;
  const dTok=[...st.matchAll(/(\d+)\s*个维度/g)].map(m=>Number(m[1]));
  if(dTok.length===0) prob.push("status.md: 没有写维度数（「N 个维度」）—— 追溯链没记维度规模");
  else for(const v of dTok){ if(v!==dN) prob.push("status.md: 写 "+v+" 个维度，实际 "+dN+" —— 追溯链与实现脱同步"); }
  // ---- 第⑥子判据：追溯矩阵必须**逐条覆盖**判据集合（第六轮 A57/A63：掏空成 token 骨架仍判过）
  const trRows=tr.split(/\r?\n/).filter(l=>/^\|\s*AC-/.test(l));
  const trIds=trRows.map(l=>(l.match(/^\|\s*(AC-[0-9]+[a-z]*)/)||[])[1]).filter(Boolean);
  const accIds=[...accText.matchAll(/^### (AC-[0-9]+[a-z]*)/gm)].map(m=>m[1]);
  const uniq=a=>[...new Set(a)].sort();
  if(trRows.length===0) prob.push("traceability.md: 一条 AC 追溯行都没有 —— 追溯矩阵被掏空成骨架");
  else{
    const A=uniq(accIds), B=uniq(trIds);
    const miss=A.filter(x=>B.indexOf(x)<0), extra=B.filter(x=>A.indexOf(x)<0);
    if(miss.length) prob.push("traceability.md: 缺 AC 追溯行 "+miss.join(",")+" —— 矩阵没有逐条覆盖判据");
    if(extra.length) prob.push("traceability.md: 多出 acceptance.md 里没有的 AC 追溯行 "+extra.join(","));
    for(const l of trRows){
      const cells=l.split("|").slice(1,-1).map(s=>s.trim()).filter(s=>s.length>0);
      if(cells.length<3){ prob.push("traceability.md: 有 AC 行不足 3 个非空单元（空壳行）"); break; }
    }
  }
  // ---- 第⑦子判据：状态文件的实现清单必须非空，且列出的文件**真的存在**（第六轮 A59）
  const paths=[...st.matchAll(/`((?:references|scripts)\/[A-Za-z0-9._\-\/]+|SKILL\.md)`/g)].map(m=>m[1]);
  if(paths.length===0) prob.push("status.md: 实现清单为空（一个交付文件路径都没列）—— 状态文件写空了");
  else for(const p of paths){ if(!fs.existsSync(tcd+"/"+p)) prob.push("status.md: 清单里列的交付文件不存在："+p); }
  // ---- 第⑧子判据：验证报告必须有**逐层结论**与**能力结论表**（第六轮 A60）
  const vr=perFile["verification-report.md"]||"";
  const vrLines=vr.split(/\r?\n/);
  const layerDefs=[["主验收",/^\|\s*主验收/],["REQ-002A",/^\|\s*上游基线回归（REQ-002A）/],["REQ-002B",/^\|\s*上游基线回归（REQ-002B）/]];
  for(const pair of layerDefs){
    const rows=vrLines.filter(l=>pair[1].test(l));
    if(rows.length!==1) prob.push("verification-report.md: 验收层次「"+pair[0]+"」有 "+rows.length+" 行（应为恰好 1 行）");
    else if(!/\d+\s*PASS\s*\/\s*0\s*FAIL/.test(rows[0])) prob.push("verification-report.md: 验收层次「"+pair[0]+"」的结论不是「N PASS / 0 FAIL」");
  }
  let capRows=0, inCap=false;
  for(const l of vrLines){
    if(/^\|\s*能力\s*\|/.test(l)){ inCap=true; continue; }
    if(!inCap) continue;
    if(/^\|\s*-{2,}/.test(l)) continue;
    if(/^\|/.test(l)){ capRows++; continue; }
    break;
  }
  if(capRows<3) prob.push("verification-report.md: 能力结论表只有 "+capRows+" 行（应 ≥3）—— 报告的实质被掏空了");
  // 主验收那一行的 PASS/FAIL 计数：P+F 必须等于判据条数，且 F 必须为 0（交付态必须全绿）
  if(!repLine){ prob.push("verification-report.md: 找不到含「主验收」与「PASS」的结果行"); }
  else{
    const m=repLine.match(/(\d+)\s*PASS\s*\/\s*(\d+)\s*FAIL/);
    if(!m) prob.push("verification-report.md: 主验收行里没有「N PASS / N FAIL」");
    else{
      const P=Number(m[1]), F=Number(m[2]);
      if(P+F!==actual) prob.push("verification-report.md: 主验收 "+P+"+"+F+" ≠ 判据条数 "+actual);
      if(F!==0) prob.push("verification-report.md: 主验收写着 "+F+" 条 FAIL —— 交付态不应有 FAIL");
    }
  }
  if(nCount===0) prob.push("三份文件里一处「N 条判据」都没有 —— 追溯链缺判据条数");
  if(dCount===0) prob.push("三份文件里一处「D1~D<n>」都没有 —— 追溯链缺决策号");
  console.log("prob="+prob.length);
  console.log("actual="+actual+" dmax="+dmax+" nCount="+nCount+" dCount="+dCount);
  console.log("detail="+(prob.slice(0,4).join(" ; ")||"none"));
  ' "$FMETA" "$SELF_DIR/acceptance.md" "$SELF_DIR/decisions.md" "$TCD/references/methods.json" "$TCD/references/dimensions.json" "$TCD" 2>/dev/null)"
  P34="$(printf '%s\n' "$M34" | sed -n 's/^prob=//p')"
  D34="$(printf '%s\n' "$M34" | sed -n 's/^detail=//p')"
  # ---- 钉版自检：追溯链必须记下**当前验收脚本**的 sha256（D25 ⑤）
  # 动机：D25 ② —— BA 在验收期间改了 3 次脚本而钉版没同步，3 个变异体作废。
  # 「任何脚本全绿的结论都必须钉版本」此前只有人工纪律，没有机械护栏 → 本条把它变成脚本判定。
  CURSHA="$(sha256sum "$SELF" 2>/dev/null | awk '{print $1}')"
  SHALINES="$(grep -icE '验收脚本[[:space:]]*sha256' "$FMETA/verification-report.md" 2>/dev/null | tr -d ' ')"
  REPSHA="$(grep -iE '验收脚本[[:space:]]*sha256' "$FMETA/verification-report.md" 2>/dev/null | grep -oE '[0-9a-f]{64}' | head -1)"
  if [ -z "$CURSHA" ]; then
    P34=$(( ${P34:-1} + 1 )); D34="$D34; 算不出当前验收脚本的 sha256（sha256sum 不可用?）"
  elif [ "${SHALINES:-0}" != "1" ]; then
    P34=$(( ${P34:-1} + 1 )); D34="$D34; verification-report.md 里「验收脚本 sha256」记录了 ${SHALINES:-0} 处（应为恰好 1 处，只留当前值）"
  elif [ -z "$REPSHA" ]; then
    P34=$(( ${P34:-1} + 1 )); D34="$D34; verification-report.md 未记下当前验收脚本的 sha256 —— 追溯链没有钉版本"
  elif [ "$REPSHA" != "$CURSHA" ]; then
    P34=$(( ${P34:-1} + 1 )); D34="$D34; verification-report.md 记的验收脚本 sha256 与当前脚本不一致（报告不是本版脚本跑出来的）"
  fi
  if [ "${P34:-1}" -eq 0 ] 2>/dev/null; then
    ok "AC-034 feature-meta 的判据条数 / 决策号 / 验收数字与实际一致"
  else
    bad "AC-034 feature-meta 数字与实际一致" "问题数=$P34 明细=$D34"
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
