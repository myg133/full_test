#!/usr/bin/env bash
# REQ-002.4 验收脚本 —— .tools 工具链自举机制
#
# 用法: verify-acceptance.sh <包根目录>
#   <包根目录> 即 npm 包根（含 package.json 与 bin/qa）
#
# 退出码: 0 = 全部通过; 1 = 有 AC 未通过
#
# 说明: AC-006/007/010 需要真的安装工具，因此本脚本会产生真实网络访问与安装。
#       使用的工具（pyflakes / js-yaml / semver）都是极小的纯解释型包。

set -uo pipefail

ROOT="${1:?用法: verify-acceptance.sh <包根目录>}"
ROOT="$(cd "$ROOT" 2>/dev/null && pwd)" || { echo "目录不存在: $1" >&2; exit 2; }
QA="$ROOT/bin/qa"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qa-0024-XXXXXX")"
trap 'kill ${SRV_PID:-0} 2>/dev/null; rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- 环境可复现性
# uv **不认** PIP_INDEX_URL，也不读 /etc/pip.conf —— 默认走 pypi.org（本机时通时不通）。
# 不显式指定索引，"16 PASS" 就依赖当时的外网状态，换台机器/换个时段就不一样。
export UV_DEFAULT_INDEX="${UV_DEFAULT_INDEX:-https://mirrors.aliyun.com/pypi/simple}"
export UV_INDEX_URL="${UV_INDEX_URL:-$UV_DEFAULT_INDEX}"
export npm_config_registry="${npm_config_registry:-https://registry.npmmirror.com}"
# 前置体检：索引不可达时**明确提示"环境不满足"**，而不是让一堆 AC 莫名其妙地挂掉
ENV_NOTE=""
if ! curl -s -o /dev/null --max-time 8 "$UV_DEFAULT_INDEX" 2>/dev/null; then
  ENV_NOTE="索引源不可达: $UV_DEFAULT_INDEX（设 UV_DEFAULT_INDEX 指向可达镜像）"
  printf '\033[33m[warn]\033[0m %s —— 依赖安装的 AC 结果不可信\n' "$ENV_NOTE" >&2
fi

PASS=0; FAIL=0; FAILED_LIST=()
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED_LIST+=("$1"); printf '  \033[31mFAIL\033[0m  %s\n     ↳ %s\n' "$1" "${2:-}"; }
step(){ printf '\n\033[36m— %s\033[0m\n' "$1"; }

# 造一个清单：$1=项目根 $2=工具 JSON 数组
mkproj() {
  local P="$1" TOOLS="$2"
  mkdir -p "$P/.tools"
  printf '{\n  "version": 1,\n  "tools": %s\n}\n' "$TOOLS" > "$P/.tools/manifest.json"
  printf '# 工具链：除清单外都是安装产物\n.tools/*\n!.tools/manifest.json\n' > "$P/.gitignore"
}

PY_TOOL='{ "name":"pyflakes","kind":"python","spec":"pyflakes==3.2.0","purpose":"Python 静态检查","required_by":["QA"],"install":{"uv":"pip install --no-deps {spec}"},"verify":{"command":"pyflakes --help","match":"pyflakes"} }'
NODE_TOOL='{ "name":"js-yaml","kind":"node","spec":"js-yaml@4.1.0","purpose":"YAML 解析","required_by":["QA"],"install":{"bun":"bun add {spec}"},"verify":{"command":"js-yaml --help","match":"js-yaml"} }'
SEMVER_TOOL='{ "name":"semver","kind":"node","spec":"semver@7.7.2","purpose":"版本比较","required_by":["QA"],"install":{"bun":"bun add {spec}"},"verify":{"command":"semver --help","match":"SemVer"} }'

# npm pack --dry-run 的文件清单: 每行形如 "npm notice  1.5kB bin/qa"
packlist() {
  ( cd "$1" && npm pack --dry-run 2>&1 ) | sed -n 's/^npm notice *[0-9.]*[kMB]*B *//p' | grep -v '^$'
}

# ---------------------------------------------------------------- AC-001
step "AC-001 bin/qa 在包内且可执行"
PACKLIST="$WORK/pack.txt"
packlist "$ROOT" > "$PACKLIST"
node "$QA" --help > "$WORK/help.txt" 2>&1; RC=$?
if grep -q "bin/qa" "$PACKLIST" && [ $RC -eq 0 ] && grep -q "doctor" "$WORK/help.txt"; then
  ok "AC-001 bin/qa 在包内且可执行"
else
  bad "AC-001 bin/qa 在包内且可执行" "rc=$RC pack清单命中=$(grep -c 'bin/qa' "$PACKLIST")"
fi

# ---------------------------------------------------------------- AC-002
step "AC-002 qa list 列出清单工具与状态"
P="$WORK/p2"; mkproj "$P" "[$PY_TOOL,$NODE_TOOL]"
OUT="$(node "$QA" --project "$P" list 2>&1)"; RC=$?
# 锚定到"状态 + 工具名"同一行，而不是全文 grep —— 别的理由串里出现 missing 也会假通过
if [ $RC -eq 0 ] && echo "$OUT" | grep -qE "^missing[[:space:]]+pyflakes" \
   && echo "$OUT" | grep -qE "^missing[[:space:]]+js-yaml"; then
  ok "AC-002 qa list 列出清单工具与状态"
else
  bad "AC-002 qa list 列出清单工具与状态" "rc=$RC out=$OUT"
fi

# ---------------------------------------------------------------- AC-003
step "AC-003 qa doctor 区分四种状态 + failed/unavailable 边界"
P="$WORK/p3"
# 四种状态各造一个，外加 failed/unavailable 的边界各钉一次:
#   ok          —— 装好且 verify 通过（用一个已装好的 python 工具）
#   failed      —— 安装命令真的跑起来但失败（包不存在）
#   missing     —— 声明了但没安装（放在另一个项目里，只 doctor 不 install）
#   unavailable —— binary 路线且下载源【不可达】（连接被拒）
# 边界：
#   源【不可达】(ECONNREFUSED/DNS/网络受限) → unavailable
#   源【存在但地址/版本不对】(HTTP 404/410) → failed
# 注意：不能用"外部域名 404"来冒充"不可达"——404 是 failed，不是 unavailable。
# 这里全部用本地端口，不依赖外网，保证判定可复现。
cat > "$WORK/srv404.mjs" <<'PORTEOF'
import http from 'node:http';
const srv = http.createServer((_q, s) => { s.statusCode = 404; s.end('not found'); });
srv.listen(0, '127.0.0.1', () => { console.log(srv.address().port); });
PORTEOF
# 404 服务必须【活着】跑完整个场景（关掉就变成"连接被拒"，那就不是 404 了）
node "$WORK/srv404.mjs" > "$WORK/port404.txt" &
SRV_PID=$!
for _i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$WORK/port404.txt" ] && break; sleep 0.2; done
NOTFOUND_PORT="$(head -1 "$WORK/port404.txt")"
# 另取一个"起过又关掉"的端口 —— 连接必被拒，用来造"源不可达"
DEAD_PORT="$(node -e 'const net=require("net");const s=net.createServer();s.listen(0,"127.0.0.1",()=>{const p=s.address().port;s.close(()=>console.log(p));});')"
BAD_TOOL='{ "name":"broken","kind":"node","spec":"broken@1.0.0","purpose":"故意坏掉","required_by":["QA"],"install":{"bun":"bun add {spec}"},"verify":{"command":"definitely-not-a-real-binary-xyz","match":"nope"} }'
BIN_UNAVAIL='{ "name":"unreachable-xyz","kind":"binary","spec":"1.0.0","purpose":"源不可达","required_by":["QA"],"install":{"url":"http://127.0.0.1:'"$DEAD_PORT"'/tool-linux-amd64"},"verify":{"command":"unreachable-xyz --version","match":"v1"} }'
BIN_NOTFOUND='{ "name":"notfound-xyz","kind":"binary","spec":"1.0.0","purpose":"地址不存在","required_by":["QA"],"install":{"url":"http://127.0.0.1:'"$NOTFOUND_PORT"'/tool-linux-amd64"},"verify":{"command":"notfound-xyz --version","match":"v1"} }'
mkproj "$P" "[$PY_TOOL,$BAD_TOOL,$BIN_UNAVAIL,$BIN_NOTFOUND]"
node "$QA" --project "$P" install >/dev/null 2>&1
# 再造一个只有 missing 的项目
P3M="$WORK/p3m"; mkproj "$P3M" '['"$NODE_TOOL"']'
OUT="$(node "$QA" --project "$P" doctor 2>&1)"; RC=$?
OUTM="$(node "$QA" --project "$P3M" doctor 2>&1)"
# 逐工具锚定状态行判定（不能用全文 grep 匹配：别的原因串里也会出现这些词）
has_state() { printf '%s\n' "$1" | grep -qE "^\[$2\] $3(（|$)"; }
H_OK=0; H_FAILED=0; H_UNAVAIL=0; H_MISSING=0; H_BOUNDARY=0
has_state "$OUT" ok pyflakes && H_OK=1
has_state "$OUT" failed broken && H_FAILED=1
has_state "$OUT" unavailable unreachable-xyz && H_UNAVAIL=1
has_state "$OUTM" missing js-yaml && H_MISSING=1
# 边界：404 源必须是 failed，不能被误判成 unavailable
if has_state "$OUT" failed notfound-xyz && ! has_state "$OUT" unavailable notfound-xyz; then H_BOUNDARY=1; fi
if [ $RC -ne 0 ] && [ $H_OK -eq 1 ] && [ $H_FAILED -eq 1 ] && [ $H_UNAVAIL -eq 1 ] && [ $H_MISSING -eq 1 ] && [ $H_BOUNDARY -eq 1 ]; then
  ok "AC-003 qa doctor 区分四种状态 + failed/unavailable 边界"
else
  bad "AC-003 qa doctor 区分四种状态 + failed/unavailable 边界" "rc=$RC ok=$H_OK failed=$H_FAILED unavailable=$H_UNAVAIL missing=$H_MISSING 边界=$H_BOUNDARY out=$OUT"
fi

# ---------------------------------------------------------------- AC-004
step "AC-004 版本锁定是强制的"
P="$WORK/p4"
UNLOCKED='{ "name":"bandit","kind":"python","spec":"bandit>=1.7","purpose":"安全扫描","required_by":["QA"],"install":{"uv":"pip install --no-deps {spec}"},"verify":{"command":"bandit --version","match":"bandit"} }'
mkproj "$P" "[$UNLOCKED]"
OUT="$(node "$QA" --project "$P" install 2>&1)"; RC=$?
VENV_EXISTS="$([ -d "$P/.tools/.venv" ] && echo yes || echo no)"
if [ $RC -ne 0 ] && echo "$OUT" | grep -qiE "版本.*(未锁定|锁定)|锁定" && [ "$VENV_EXISTS" = "no" ]; then
  ok "AC-004 版本锁定是强制的"
else
  bad "AC-004 版本锁定是强制的" "rc=$RC venv=$VENV_EXISTS out=$OUT"
fi

# ---------------------------------------------------------------- AC-005
step "AC-005 install 命令不得写到 .tools/ 之外"
P="$WORK/p5"
OUTSIDE='{ "name":"outside","kind":"python","spec":"six==1.17.0","purpose":"越界安装","required_by":["QA"],"install":{"uv":"pip install --user {spec}"},"verify":{"command":"six --version","match":"six"} }'
mkproj "$P" "[$OUTSIDE]"
OUT="$(node "$QA" --project "$P" install 2>&1)"; RC=$?
if [ $RC -ne 0 ] && echo "$OUT" | grep -qiE "越界|路径|外部"; then
  ok "AC-005 install 命令不得写到 .tools/ 之外"
else
  bad "AC-005 install 命令不得写到 .tools/ 之外" "rc=$RC out=$OUT"
fi

# ---------------------------------------------------------------- AC-006 / AC-007 / AC-012 / AC-013
step "AC-006/007/012/013 真实安装 + 隔离 + 幂等 + state"
P="$WORK/p6"; mkproj "$P" "[$PY_TOOL,$NODE_TOOL,$SEMVER_TOOL]"
OUT="$(node "$QA" --project "$P" install 2>&1)"; RC=$?
A6=0; A7=0
[ -d "$P/.tools/.venv" ] && A6=1
[ -d "$P/.tools/node" ] && A7=1
# 负向隔离验证：系统侧必须看不到
SYS_PY="$(python3 -c "import pyflakes" 2>&1 >/dev/null; echo $?)"
SYS_NODE="$(command -v js-yaml 2>/dev/null || true)"
ISO_PY=1; [ "$SYS_PY" = "0" ] && ISO_PY=0
ISO_NODE=1; [ -n "$SYS_NODE" ] && ISO_NODE=0
if [ $RC -eq 0 ] && [ $A6 -eq 1 ] && [ $ISO_PY -eq 1 ]; then
  ok "AC-006 Python 工具装进 .venv 且不污染系统"
else
  bad "AC-006 Python 工具装进 .venv 且不污染系统" "install rc=$RC venv=$A6 系统import返回码=$SYS_PY"
fi
if [ $A7 -eq 1 ] && [ $ISO_NODE -eq 1 ]; then
  ok "AC-007 Node 工具装进 .tools/node 且不污染系统"
else
  bad "AC-007 Node 工具装进 .tools/node 且不污染系统" "node目录=$A7 系统which='$SYS_NODE'"
fi
# 幂等
SB="$(cat "$P/.tools/state.json" 2>/dev/null | md5sum | cut -d' ' -f1)"
OUT2="$(node "$QA" --project "$P" install 2>&1)"; RC2=$?
SA="$(cat "$P/.tools/state.json" 2>/dev/null | md5sum | cut -d' ' -f1)"
if [ $RC2 -eq 0 ] && [ "$SB" = "$SA" ] && echo "$OUT2" | grep -qiE "跳过|已安装"; then
  ok "AC-012 安装幂等"
else
  bad "AC-012 安装幂等" "rc=$RC2 state未变=$([ "$SB" = "$SA" ] && echo yes || echo no) out=$OUT2"
fi
# state.json 字段 —— 必须断**字段值**，不能只断键名存在。
# 键名存在但值为 null（安装其实失败）也算"记录了版本与来源"，那是假通过。
STATE_FILE="$P/.tools/state.json"
S13="$(node -e '
const fs=require("fs");
let o; try{o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));}catch(e){console.log("PARSE_ERR");process.exit(0);}
const t=(o.tools||{}).pyflakes||{};
const iso=(v)=>typeof v==="string" && /^\d{4}-\d{2}-\d{2}T/.test(v);
const okv = t.version==="3.2.0" && iso(t.installed_at) && typeof t.source==="string" && t.source!=="" && t.status==="ok";
console.log(JSON.stringify({ok:okv, version:t.version, installed_at:t.installed_at, source:t.source, status:t.status}));
' "$STATE_FILE" 2>/dev/null)"
if echo "$S13" | grep -q '"ok":true'; then
  ok "AC-013 state.json 记录版本与来源（字段值校验）"
else
  bad "AC-013 state.json 记录版本与来源" "字段值=$S13"
fi

# ---------------------------------------------------------------- AC-008
step "AC-008 qa which 指向 .tools/ 内的路径"
OUT="$(node "$QA" --project "$P" which pyflakes 2>&1)"; RC=$?
if [ $RC -eq 0 ] && echo "$OUT" | grep -q "$P/.tools/"; then
  ok "AC-008 qa which 指向 .tools/ 内的路径"
else
  bad "AC-008 qa which 指向 .tools/ 内的路径" "rc=$RC out=$OUT"
fi

# ---------------------------------------------------------------- AC-009
step "AC-009 qa run 是白名单式的"
MARK="$WORK/should-not-exist"
OUT="$(node "$QA" --project "$P" run definitely-not-in-manifest -- --version 2>&1)"; RC=$?
if [ $RC -ne 0 ] && echo "$OUT" | grep -qiE "不在清单|清单"; then
  ok "AC-009 qa run 是白名单式的（拒绝且未执行）"
else
  bad "AC-009 qa run 是白名单式的" "rc=$RC out=$OUT"
fi

# ---------------------------------------------------------------- AC-010
step "AC-010 qa run 执行的是 .tools/ 里那份"
OUT="$(node "$QA" --project "$P" run semver -- --help 2>&1)"; RC=$?
WHICH="$(node "$QA" --project "$P" which semver 2>&1)"
if [ $RC -eq 0 ] && echo "$WHICH" | grep -q "$P/.tools/" && echo "$OUT" | grep -q "7.7.2"; then
  ok "AC-010 qa run 执行的是 .tools/ 里那份"
else
  bad "AC-010 qa run 执行的是 .tools/ 里那份" "rc=$RC which=$WHICH out=$OUT"
fi

# ---------------------------------------------------------------- AC-011
step "AC-011 工具不可用时不得静默跳过"
P11="$WORK/p11"
# 清单必须**合法**（否则会先被清单校验拦掉，测不到"装不上"这条路径）
# 下载源用**本地死端口**（连接必被拒 → unavailable），不依赖任何外网域名。
# 外网域名会引入"当时通还是不通"的随机性，让验收结果不可复现。
DEAD_PORT11="$(node -e 'const net=require("net");const s=net.createServer();s.listen(0,"127.0.0.1",()=>{const p=s.address().port;s.close(()=>console.log(p));});')"
UNREACH='{ "name":"unreachable-xyz","kind":"binary","spec":"1.0.0","purpose":"源不可达","required_by":["QA"],"install":{"url":"http://127.0.0.1:'"$DEAD_PORT11"'/tool-linux-amd64"},"verify":{"command":"unreachable-xyz --version","match":"v1"} }'
mkproj "$P11" "[$UNREACH]"
OUT="$(node "$QA" --project "$P11" install 2>&1)"; RC1=$?
DOC="$(node "$QA" --project "$P11" doctor 2>&1)"; RC2=$?
# 关键: 不能是 ok，也不能是"跳过"，必须是 failed/unavailable 且给出原因
if [ $RC1 -ne 0 ] && [ $RC2 -ne 0 ] \
   && echo "$DOC" | grep -qiE "unavailable|failed" \
   && ! echo "$DOC" | grep -qiE "unreachable-xyz.*\[ok\]" \
   && echo "$DOC" | grep -qiE "unreachable-xyz"; then
  ok "AC-011 工具不可用时不得静默跳过"
else
  bad "AC-011 工具不可用时不得静默跳过" "install rc=$RC1 doctor rc=$RC2 doc=$DOC"
fi

# ---------------------------------------------------------------- AC-014
step "AC-014 .gitignore 精确忽略，manifest 进 Git"
P14="$WORK/p14"
# 关键：`.gitignore` 必须由**交付物的 `qa init`** 生成。
# 脚本自己手写规则 = 自证式测试，对交付物零检验力（把交付物的规则改坏也照样 PASS）。
mkdir -p "$P14/.tools"
printf '{\n  "version": 1,\n  "tools": [%s]\n}\n' "$PY_TOOL" > "$P14/.tools/manifest.json"
INIT_OUT="$(node "$QA" --project "$P14" init 2>&1)"; RC_INIT=$?
mkdir -p "$P14/.tools/.venv" && touch "$P14/.tools/.venv/x"
( cd "$P14" && git init -q 2>/dev/null && git add -A 2>/dev/null )
IGN="$(cd "$P14" && git check-ignore -v .tools/.venv/x 2>&1)"
IGN2="$(cd "$P14" && git check-ignore .tools/manifest.json 2>&1)"
LS="$(cd "$P14" && git status --porcelain -uall 2>/dev/null | grep "manifest.json")"
# 交付物写出的规则里必须**不含** `.tools/`（含它会让 `!.tools/manifest.json` 失效，清单静默丢失）
GITFILE="$(cat "$P14/.gitignore" 2>/dev/null)"
if [ $RC_INIT -eq 0 ] && echo "$IGN" | grep -q ".tools/" && [ -z "$IGN2" ] \
   && echo "$LS" | grep -q "manifest.json" \
   && ! printf '%s\n' "$GITFILE" | grep -qE "^\.tools/$"; then
  ok "AC-014 .gitignore 精确忽略，manifest 进 Git（规则来自 qa init）"
else
  bad "AC-014 .gitignore 精确忽略，manifest 进 Git" "init rc=$RC_INIT 规则='$GITFILE' venv被忽略=$(echo "$IGN" | head -1) manifest被忽略='$IGN2' manifest在待提交='$LS'"
fi

# ---------------------------------------------------------------- AC-017
# D3：qa doctor 是**只读体检** —— 体检命令却改了系统状态，是不可预期的副作用。
# 独立验收发现：把 doctor 改成"会触发安装"，BA 脚本原来只能靠 AC-003 顺带抓到。
# 这里给 D3 一条**专门**的断言。
step "AC-017 qa doctor 是只读的（不触发安装、不改 .tools/）"
P17="$WORK/p17"; mkproj "$P17" "[$PY_TOOL,$NODE_TOOL]"
BEFORE="$(find "$P17/.tools" -type f -o -type d 2>/dev/null | sort | md5sum | cut -d' ' -f1)"
OUT17="$(node "$QA" --project "$P17" doctor 2>&1)"; RC17=$?
AFTER="$(find "$P17/.tools" -type f -o -type d 2>/dev/null | sort | md5sum | cut -d' ' -f1)"
if [ "$BEFORE" = "$AFTER" ] && [ ! -d "$P17/.tools/.venv" ] && [ ! -f "$P17/.tools/state.json" ]; then
  ok "AC-017 qa doctor 是只读的（.tools/ 前后不变，未生成 venv/state.json）"
else
  bad "AC-017 qa doctor 是只读的" "rc=$RC17 前后一致=$([ "$BEFORE" = "$AFTER" ] && echo yes || echo no) venv=$([ -d "$P17/.tools/.venv" ] && echo yes || echo no) state=$([ -f "$P17/.tools/state.json" ] && echo yes || echo no)"
fi

# ---------------------------------------------------------------- AC-018
# P1-1：清单里的 entry 字段可以做路径穿越 —— 白名单只管"名字"，
# 真正被执行的文件却可以指向 .tools/ 之外（qa which 也把它当"隔离副本"报出来）。
# 契约的硬规则是"只跑 .tools/ 里那份"，越界入口必须被拒。
step "AC-018 qa run 拒绝执行 .tools/ 之外的入口（entry 路径穿越）"
P18="$WORK/p18"; mkdir -p "$P18/.tools"
printf '#!/bin/sh\necho PWNED\n' > "$P18/evil.sh"; chmod +x "$P18/evil.sh"
printf '{\n  "version": 1,\n  "tools": [{ "name":"innocent","kind":"binary","spec":"1.0.0","purpose":"越界入口","required_by":["QA"],"entry":"../../evil.sh",\n    "install":{"url":"http://127.0.0.1:1/x"},"verify":{"command":"true","match":""} }]\n}\n' > "$P18/.tools/manifest.json"
OUT18="$(node "$QA" --project "$P18" run innocent -- x 2>&1)"; RC18=$?
WHICH18="$(node "$QA" --project "$P18" which innocent 2>&1)"; RCW18=$?
# 三条都要满足：执行被拒(非0) + 没有出现 PWNED + which 不得把越界路径当隔离副本报出
if [ $RC18 -ne 0 ] && ! echo "$OUT18" | grep -q "PWNED" \
   && { [ $RCW18 -ne 0 ] || ! echo "$WHICH18" | grep -q "evil.sh"; }; then
  ok "AC-018 qa run 拒绝执行 .tools/ 之外的入口（entry 路径穿越）"
else
  bad "AC-018 qa run 拒绝执行 .tools/ 之外的入口" "run rc=$RC18 out=$OUT18 which rc=$RCW18 which=$WHICH18"
fi

# ---------------------------------------------------------------- AC-015
step "AC-015 零依赖 + 退出码语义"
PKG="$ROOT/package.json"
DEPS="$(node -e 'const p=require(process.argv[1]);console.log(Object.keys(p.dependencies||{}).length)' "$PKG" 2>/dev/null)"
BADIMPORT="$(grep -h -E "^\s*import .*from ['\"]" "$ROOT/bin/qa-impl.mjs" 2>/dev/null \
  | grep -v -E "from ['\"]node:" | grep -v -E "from ['\"]\./" | grep -v -E "from ['\"]\.\./" | wc -l)"
node "$QA" --project "$P" list >/dev/null 2>&1; RC0=$?
# doctor 在**全部健康**时退出码应为 0；有问题的项目才非 0
node "$QA" --project "$P" doctor >/dev/null 2>&1; RC_HEALTHY=$?
node "$QA" --project "$WORK/p3" doctor >/dev/null 2>&1; RC_SICK=$?
node "$QA" --project "$P" nosuchsubcommand >/dev/null 2>&1; RC2=$?
if [ "$DEPS" = "0" ] && [ "$BADIMPORT" = "0" ] && [ $RC0 -eq 0 ] && [ $RC_HEALTHY -eq 0 ] && [ $RC_SICK -ne 0 ] && [ $RC2 -eq 2 ]; then
  ok "AC-015 零依赖 + 退出码语义"
else
  bad "AC-015 零依赖 + 退出码语义" "deps=$DEPS 非内置import=$BADIMPORT list=$RC0 doctor健康=$RC_HEALTHY doctor异常=$RC_SICK usage=$RC2"
fi

# ---------------------------------------------------------------- AC-016
step "AC-016 全部交付文件都进了 npm 包"
PACKLIST2="$WORK/packlist.txt"
packlist "$ROOT" > "$PACKLIST2"
MISS=""
# 必须行尾锚定：否则 "bin/qa" 会被 "bin/qa-impl.mjs" 命中 —— 去掉 bin/qa 也照样 PASS。
for f in bin/qa bin/qa-impl.mjs skills/qa-toolchain/SKILL.md skills/qa-toolchain/references/tools-chain-contract.md; do
  grep -qE "(^|[[:space:]])$(printf '%s' "$f" | sed 's/[.[\*^$]/\\&/g')$" "$PACKLIST2" || MISS="$MISS $f"
done
if [ -z "$MISS" ]; then
  ok "AC-016 全部交付文件都进了 npm 包"
else
  bad "AC-016 全部交付文件都进了 npm 包" "缺:$MISS （清单共 $(wc -l < "$PACKLIST2") 项）"
fi

echo
echo "────────────────────────────────────────"
printf '结论: %d PASS / %d FAIL\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "未通过的 AC:"
  for f in "${FAILED_LIST[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
