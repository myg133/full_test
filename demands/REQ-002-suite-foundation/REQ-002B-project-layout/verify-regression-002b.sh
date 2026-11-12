#!/usr/bin/env bash
# REQ-002B 回归测试 —— 契约 ↔ 实现一致性变异测试
#
# 做法: 把契约文档 project-layout.md 声明的每一条「必须」逐个破坏，
#       看校验器是否真的拦。这一类缺陷（文档写了必须、校验器没拦）
#       在 REQ-002B 交付时手工验收阶段漏掉了三个，是靠这个思路挖出来的。
#
# 用法: verify-regression-002b.sh <skill-dir>
#   <skill-dir> 指向含 SKILL.md 的 skill 目录
#
# 退出码: 0 = 全部符合预期; 1 = 有偏差
#
# 约定: 期望值 "拦截" = 校验器应报错(exit 1); "放行" = 校验器应通过(exit 0)

set -uo pipefail

SKILL_DIR="${1:?用法: verify-regression-002b.sh <skill-dir>}"
SKILL_DIR="$(cd "$SKILL_DIR" 2>/dev/null && pwd)" || { echo "skill 目录不存在: $1" >&2; exit 2; }
VL="$SKILL_DIR/scripts/verify-layout.mjs"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qa-002b-regress-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0; FAILED_LIST=()

# 构造一个满足 REQ-002B 契约的完整项目
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

mut() { # $1=用例名 $2=期望 $3=变异命令
  # ⚠️ D25 ⑪：夹具必须**自证** —— 变异到底有没有真的打上。
  # 背景：本机 rm 被宿主的「可恢复删除」运行时接管（rm → RECOVERABLE_DELETE_RUNTIME），该运行时在
  # 高并发下会失败（RECOVERABLE_DELETE_RUNTIME: failed to trash ...）→ 删除没发生 → 变异没打上 →
  # 校验器「放行」→ 用例被记成**交付缺陷**。实测 8 路并发下 8 次里有 7 次是这种假红。
  # 修法：① 删除型变异改成「移开」（mv，同盘 rename，不经删除运行时）；
  #      ② 施加变异后比对被测树与基线树：树没变 = 变异没生效 = 夹具问题 → 重试；
  #         树变了还判错 = 真偏差 → 不再重试（**不掩盖真缺陷**）。
  local expect="$2" cmd="$3" attempt d got out rc changed
  for attempt in 1 2 3; do
    d="$WORK/$1"
    [ "$attempt" -gt 1 ] && d="$WORK/$1.r$attempt"
    cp -r "$WORK/_base" "$d" || { sleep 0.2; continue; }
    CASE_DIR_NAME="$(basename "$d")"; export CASE_DIR_NAME
    ( cd "$d" && eval "$cmd" ) 2>/dev/null
    if diff -r -q "$WORK/_base" "$d" >/dev/null 2>&1; then changed=0; else changed=1; fi
    out="$(node "$VL" "$d" 2>&1)"; rc=$?
    got="放行"; [ $rc -ne 0 ] && got="拦截"
    if [ "$got" = "$expect" ]; then
      PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %-42s %s\n' "$1" "$expect"; return 0
    fi
    if [ "$changed" = "1" ]; then
      FAIL=$((FAIL+1)); FAILED_LIST+=("$1")
      printf '  \033[31mFAIL\033[0m  %-42s 期望=%s 实际=%s\n' "$1" "$expect" "$got"
      echo "$out" | sed 's/^/      ↳ /' | head -4
      return 1
    fi
    sleep 0.2
  done
  FAIL=$((FAIL+1)); FAILED_LIST+=("$1")
  printf '  \033[31mFAIL\033[0m  %-42s 夹具未生效：变异命令没有改变被测树（已重试 3 次）\n' "$1"
  return 1
}

make_project "$WORK/_base"

CYC="test-assets/cycles/R1-REQ-001/cycle.json"
ENV="test-assets/environments/local.json"
SUI="test-assets/suites/REQ-001-coupon/suite.json"
J() { node -e "
const fs=require('fs'),f=process.argv[1];const o=JSON.parse(fs.readFileSync(f,'utf8'));
$2
fs.writeFileSync(f,JSON.stringify(o,null,2));
" "$1"; }

echo "REQ-002B 回归 —— skill: $SKILL_DIR"
echo

mut "00-基线-未变异" "放行" "true"

# --- 目录与文档存在性 ---
mut "01-缺 test-assets 目录" "拦截" 'mv test-assets "../$CASE_DIR_NAME.gone"'  # D25 ⑪：移开而非删除
mut "02-缺 environments 目录" "拦截" 'mv test-assets/environments "../$CASE_DIR_NAME.gone"'  # D25 ⑪：移开而非删除
mut "03-缺 _schema.json" "拦截" 'mv test-assets/environments/_schema.json "../$CASE_DIR_NAME.gone"'  # D25 ⑪：移开而非删除
mut "04-_schema.json 不可解析" "拦截" "printf 'not json' > test-assets/environments/_schema.json"

# --- 环境配置 ---
mut "05-环境缺 base_url" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$ENV\";const o=JSON.parse(fs.readFileSync(f));delete o.base_url;fs.writeFileSync(f,JSON.stringify(o))'"
mut "06-timeout_ms 类型错" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$ENV\";const o=JSON.parse(fs.readFileSync(f));o.timeout_ms=\"5000\";fs.writeFileSync(f,JSON.stringify(o))'"
mut "07-环境多余顶层字段" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$ENV\";const o=JSON.parse(fs.readFileSync(f));o.extra=\"x\";fs.writeFileSync(f,JSON.stringify(o))'"
mut "08-credentials 明文凭证" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$ENV\";const o=JSON.parse(fs.readFileSync(f));o.credentials.password=\"hunter2\";fs.writeFileSync(f,JSON.stringify(o))'"
mut "09-环境名非法环境变量" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$ENV\";const o=JSON.parse(fs.readFileSync(f));o.credentials.username_env=\"bad name\";fs.writeFileSync(f,JSON.stringify(o))'"
mut "10-环境 name 与文件名不一致" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$ENV\";const o=JSON.parse(fs.readFileSync(f));o.name=\"other\";fs.writeFileSync(f,JSON.stringify(o))'"

# --- suite.json ---
mut "11-suite 缺 executor" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$SUI\";const o=JSON.parse(fs.readFileSync(f));delete o.executor;fs.writeFileSync(f,JSON.stringify(o))'"
mut "12-scope 枚举非法" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$SUI\";const o=JSON.parse(fs.readFileSync(f));o.scope=\"perf\";fs.writeFileSync(f,JSON.stringify(o))'"
mut "13-executor 枚举非法" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$SUI\";const o=JSON.parse(fs.readFileSync(f));o.executor=\"curl\";fs.writeFileSync(f,JSON.stringify(o))'"
mut "14-suite 字段与目录名不一致" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$SUI\";const o=JSON.parse(fs.readFileSync(f));o.suite=\"OTHER\";fs.writeFileSync(f,JSON.stringify(o))'"
mut "15-environment 悬空引用" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$SUI\";const o=JSON.parse(fs.readFileSync(f));o.environment=\"prod\";fs.writeFileSync(f,JSON.stringify(o))'"
mut "16-cases_file 指向不存在" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$SUI\";const o=JSON.parse(fs.readFileSync(f));o.cases_file=\"nope.json\";fs.writeFileSync(f,JSON.stringify(o))'"
mut "17-cases_file 越出项目根" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$SUI\";const o=JSON.parse(fs.readFileSync(f));o.cases_file=\"../../../../etc/passwd\";fs.writeFileSync(f,JSON.stringify(o))'"
mut "18-report.output_dir 越界" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$SUI\";const o=JSON.parse(fs.readFileSync(f));o.report.output_dir=\"public/report\";fs.writeFileSync(f,JSON.stringify(o))'"

# --- cycle.json ---
mut "19-cycle 缺 cycle_id" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$CYC\";const o=JSON.parse(fs.readFileSync(f));delete o.cycle_id;fs.writeFileSync(f,JSON.stringify(o))'"
mut "20-cycle 缺 requirement" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$CYC\";const o=JSON.parse(fs.readFileSync(f));delete o.requirement;fs.writeFileSync(f,JSON.stringify(o))'"
mut "21-cycle_id 与目录名不一致" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$CYC\";const o=JSON.parse(fs.readFileSync(f));o.cycle_id=\"R9-XXX\";fs.writeFileSync(f,JSON.stringify(o))'"
mut "22-round 枚举非法" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$CYC\";const o=JSON.parse(fs.readFileSync(f));o.round=\"R9\";fs.writeFileSync(f,JSON.stringify(o))'"
mut "23-round_type 枚举非法" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$CYC\";const o=JSON.parse(fs.readFileSync(f));o.round_type=\"whatever\";fs.writeFileSync(f,JSON.stringify(o))'"
mut "24-status 枚举非法" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$CYC\";const o=JSON.parse(fs.readFileSync(f));o.status=\"finished\";fs.writeFileSync(f,JSON.stringify(o))'"
mut "25-status 缺失" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$CYC\";const o=JSON.parse(fs.readFileSync(f));delete o.status;fs.writeFileSync(f,JSON.stringify(o))'"
mut "26-stage 状态枚举非法" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$CYC\";const o=JSON.parse(fs.readFileSync(f));o.stages.design.status=\"finished\";fs.writeFileSync(f,JSON.stringify(o))'"
mut "27-scopes_skipped 理由为空" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$CYC\";const o=JSON.parse(fs.readFileSync(f));o.scopes_skipped=[{scope:\"load\",reason:\"\"}];fs.writeFileSync(f,JSON.stringify(o))'"
mut "28-scopes_skipped scope 枚举非法" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$CYC\";const o=JSON.parse(fs.readFileSync(f));o.scopes_skipped=[{scope:\"perf\",reason:\"x\"}];fs.writeFileSync(f,JSON.stringify(o))'"
mut "28b-scopes_skipped 缺 at" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$CYC\";const o=JSON.parse(fs.readFileSync(f));o.scopes_skipped=[{scope:\"load\",reason:\"x\",by:\"dev\"}];fs.writeFileSync(f,JSON.stringify(o))'"
mut "28c-scopes_skipped 缺 by" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$CYC\";const o=JSON.parse(fs.readFileSync(f));o.scopes_skipped=[{scope:\"load\",reason:\"x\",at:\"2026-11-11T18:00:00+08:00\"}];fs.writeFileSync(f,JSON.stringify(o))'"
mut "28d-scopes_skipped 四字段齐备" "放行" "node -e 'const fs=require(\"fs\"),f=\"$CYC\";const o=JSON.parse(fs.readFileSync(f));o.scopes_skipped=[{scope:\"load\",reason:\"无阈值可依\",at:\"2026-11-11T18:00:00+08:00\",by:\"dev-agent-1\"}];fs.writeFileSync(f,JSON.stringify(o))'"
mut "29-status 与 history 不一致" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$CYC\";const o=JSON.parse(fs.readFileSync(f));o.status=\"completed\";fs.writeFileSync(f,JSON.stringify(o))'"
mut "30-history 为空数组" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$CYC\";const o=JSON.parse(fs.readFileSync(f));o.history=[];fs.writeFileSync(f,JSON.stringify(o))'"
mut "31-history 缺 at" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$CYC\";const o=JSON.parse(fs.readFileSync(f));delete o.history[0].at;fs.writeFileSync(f,JSON.stringify(o))'"
mut "32-history 缺 from" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$CYC\";const o=JSON.parse(fs.readFileSync(f));delete o.history[0].from;fs.writeFileSync(f,JSON.stringify(o))'"
mut "33-history 缺 to" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$CYC\";const o=JSON.parse(fs.readFileSync(f));delete o.history[0].to;fs.writeFileSync(f,JSON.stringify(o))'"
mut "34-history 缺 by" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$CYC\";const o=JSON.parse(fs.readFileSync(f));delete o.history[0].by;fs.writeFileSync(f,JSON.stringify(o))'"
mut "35-history.from 枚举非法" "拦截" "node -e 'const fs=require(\"fs\"),f=\"$CYC\";const o=JSON.parse(fs.readFileSync(f));o.history[0].from=\"bogus\";fs.writeFileSync(f,JSON.stringify(o))'"

# --- cycles/index.json ---
mut "36-index 悬空 id" "拦截" "node -e 'const fs=require(\"fs\"),f=\"test-assets/cycles/index.json\";const o=JSON.parse(fs.readFileSync(f));o.cycles.push({id:\"R9-NOPE\",round:\"R1\",status:\"planned\"});fs.writeFileSync(f,JSON.stringify(o))'"

# --- .gitignore ---
mut "37-gitignore 未忽略产物目录" "拦截" "printf 'node_modules/\n' > .gitignore"

echo
echo "────────────────────────────────────────"
printf '结论: %d PASS / %d FAIL\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "偏差用例:"
  for f in "${FAILED_LIST[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
