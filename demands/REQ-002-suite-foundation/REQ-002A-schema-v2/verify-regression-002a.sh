#!/usr/bin/env bash
# REQ-002A 回归测试 —— 用例集校验器的行为护栏
#
# 用途: REQ-002A 的 validate-cases.mjs 已被后续 REQ 改动过
#       （REQ-002.5a 加 --init 骨架生成；REQ-002.5b 放宽 steps[].expected 的类型
#        以支持结构化断言对象）。每次改动都必须用本脚本证明旧行为未变。
#
# 用法: verify-regression-002a.sh <skill-dir>
#   <skill-dir> 指向含 SKILL.md 的 skill 目录
#
# 退出码: 0 = 全部符合预期; 1 = 有偏差
#
# 约定: 期望值 "通过" = 退出码 0; "拦截" = 退出码非 0
#
# ⚠️ 本脚本含 **REQ-004（原 REQ-002.5b）「结构化断言对象」扩展**的 5 条用例。
#    在 REQ-004 合并进 develop **之前**，对 develop 跑本脚本会有 **5 条 FAIL**（14 PASS / 5 FAIL）
#    —— 那是"功能还没到"，**不是回归**。REQ-004 合并后应为 19 PASS / 0 FAIL。
#    对 REQ-004 的分支跑（feature/REQ-004），从一开始就该 19/19。

set -uo pipefail

SKILL_DIR="${1:?用法: verify-regression-002a.sh <skill-dir>}"
SKILL_DIR="$(cd "$SKILL_DIR" 2>/dev/null && pwd)" || { echo "skill 目录不存在: $1" >&2; exit 2; }
VC="$SKILL_DIR/scripts/validate-cases.mjs"

FIXTURES="$(cd "$(dirname "$0")" && pwd)/fixtures"
[ -d "$FIXTURES" ] || { echo "找不到 fixtures 目录: $FIXTURES" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qa-002a-regress-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0; FAILED_LIST=()

check() { # $1=用例名 $2=期望 $3=文件
  local out rc; out="$(node "$VC" "$3" 2>&1)"; rc=$?
  local got="通过"; [ $rc -ne 0 ] && got="拦截"
  if [ "$got" = "$2" ]; then
    PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %-46s %s\n' "$1" "$2"
  else
    FAIL=$((FAIL+1)); FAILED_LIST+=("$1")
    printf '  \033[31mFAIL\033[0m  %-46s 期望=%s 实际=%s\n' "$1" "$2" "$got"
    echo "$out" | sed 's/^/      ↳ /' | head -4
  fi
}

# 造一个用例集：$1=输出文件 $2=expected 的 JSON 片段
mk() {
  local f="$1" exp="$2"
  # 用 printf 的 %s 而非 heredoc: heredoc 会把 $exp 展开后的内容二次展开，
  # 片段里的 "$status" / "$.status" 会被当成 shell 变量（set -u 下直接报错）。
  printf '{\n  "schema_version": 2,\n  "meta": { "source": "regression", "generated_at": "2026-11-11T18:00:00+08:00", "case_count": 1 },\n  "requirements": [ { "id": "R-1", "title": "回归样例", "source_ref": "x", "testable": true } ],\n  "open_questions": [],\n  "coverage_matrix": [ { "requirement": "R-1", "methods_applied": ["M0.1"], "skipped": [], "dimensions": ["functional"] } ],\n  "cases": [ { "id": "TC-001", "title": "样例", "requirement_refs": ["R-1"], "dimension": "functional",\n    "priority": "P0", "method": ["M0.1"], "status": "active",\n    "steps": [ { "action": "提交订单", "expected": %s } ] } ]\n}\n' "$exp" > "$f"
}

echo "REQ-002A 回归 —— skill: $SKILL_DIR"
echo

# ---------------------------------------------------------------- 旧行为不变
check "旧样本 v1 宽松产物仍通过"        "通过" "$FIXTURES/v1-legacy.json"
check "旧样本 显式 v2 但缺字段仍被拦"    "拦截" "$FIXTURES/v2-missing-matrix.json"
check "旧样本 SKILL.md v1 形态仍通过"    "通过" "$FIXTURES/v1-shaped.json"

# 旧行为的关键细节：显式 v2 缺字段时报的是哪些字段
OUT="$(node "$VC" "$FIXTURES/v2-missing-matrix.json" 2>&1)"
for F in open_questions coverage_matrix; do
  if echo "$OUT" | grep -q "$F"; then
    PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %-46s %s\n' "缺 $F 仍被点名" "拦截"
  else
    FAIL=$((FAIL+1)); FAILED_LIST+=("缺 $F 仍被点名")
    printf '  \033[31mFAIL\033[0m  %-46s 期望=拦截 实际=未点名\n' "缺 $F 仍被点名"
  fi
done

# ---------------------------------------------------------------- 断言对象形态（REQ-002.5b 扩展）
mk "$WORK/assert-ok.json" '{ "path": "$.status", "op": "equals", "expected": "ok" }'
check "断言对象形态合法则通过" "通过" "$WORK/assert-ok.json"

mk "$WORK/assert-http.json" '{ "path": "$status", "op": "equals", "expected": 200 }'
check '断言对象 $status 形态合法则通过' "通过" "$WORK/assert-http.json"

mk "$WORK/assert-exists.json" '{ "path": "$.data.id", "op": "exists" }'
check "op=exists 不带 expected 则通过" "通过" "$WORK/assert-exists.json"

mk "$WORK/assert-type.json" '{ "path": "$.data", "op": "type", "expected": "object" }'
check "op=type 带类型名则通过" "通过" "$WORK/assert-type.json"

# 非法断言对象必须被拦
mk "$WORK/assert-no-path.json" '{ "op": "equals", "expected": "ok" }'
check "断言对象缺 path 被拦" "拦截" "$WORK/assert-no-path.json"

mk "$WORK/assert-no-op.json" '{ "path": "$.status", "expected": "ok" }'
check "断言对象缺 op 被拦" "拦截" "$WORK/assert-no-op.json"

mk "$WORK/assert-bad-op.json" '{ "path": "$.status", "op": "equalsx", "expected": "ok" }'
check "断言对象 op 非法被拦" "拦截" "$WORK/assert-bad-op.json"

mk "$WORK/assert-no-exp.json" '{ "path": "$.status", "op": "equals" }'
check "op=equals 缺 expected 被拦" "拦截" "$WORK/assert-no-exp.json"

# 非法断言对象的报错应点名具体字段
# 注意: grep 的对象必须排除含"文件:"的行 —— 那一行带的是**文件路径**，
# 而测试文件名里含 path/op 等关键词，会造成假 PASS。
for CASE in "assert-no-path:path" "assert-no-op:op" "assert-bad-op:op"; do
  F="${CASE%%:*}"; KEY="${CASE##*:}"
  OUT="$(node "$VC" "$WORK/$F.json" 2>&1 | grep -v '文件:')"
  if echo "$OUT" | grep -q "$KEY"; then
    PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %-46s %s\n' "$F 报错点名 $KEY" "拦截"
  else
    FAIL=$((FAIL+1)); FAILED_LIST+=("$F 报错点名 $KEY")
    printf '  \033[31mFAIL\033[0m  %-46s 期望=点名 %s 实际=未点名\n' "$F 报错点名 $KEY" "$KEY"
    echo "$OUT" | sed 's/^/      ↳ /' | head -3
  fi
done

# 字符串形态的 expected 仍必须通过（旧行为）
mk "$WORK/assert-str.json" '"订单状态为已支付"'
check "expected 字符串形态仍通过" "通过" "$WORK/assert-str.json"

# ---------------------------------------------------------------- --init 骨架（REQ-002.5a）
node "$VC" --init > "$WORK/skel.json" 2>/dev/null
if node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$WORK/skel.json" 2>/dev/null; then
  SV="$(node -e 'const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(o.schema_version===2?"2":"other")' "$WORK/skel.json")"
  if [ "$SV" = "2" ]; then
    PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %-46s %s\n' "--init 骨架 schema_version=2" "通过"
  else
    FAIL=$((FAIL+1)); FAILED_LIST+=("--init 骨架 schema_version=2")
    printf '  \033[31mFAIL\033[0m  %-46s 期望=2 实际=%s\n' "--init 骨架 schema_version=2" "$SV"
  fi
  check "--init 骨架自校验通过" "通过" "$WORK/skel.json"
else
  FAIL=$((FAIL+1)); FAILED_LIST+=("--init 输出合法 JSON")
  printf '  \033[31mFAIL\033[0m  %-46s 期望=合法JSON 实际=解析失败\n' "--init 输出合法 JSON"
fi

echo
echo "────────────────────────────────────────"
printf '结论: %d PASS / %d FAIL\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "偏差用例:"
  for f in "${FAILED_LIST[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
