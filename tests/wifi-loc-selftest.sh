#!/bin/bash
#
# wifi-loc-detect.sh 的自测。
#
# 这里不碰本机：被测脚本只会调 `scselect`、`osascript` 与 `arp`，每份套件都把自己需要的
# 那些换成桩：
#
#   osascript  记下整条调用参数（含通知正文）而不是真的弹通知
#   scselect   只记下参数，从不改变本机位置；它从不执行真的那个，所以没有套件能挪动机器
#   arp        只在需要「特征地址看起来不在场」的用例里出现：前 N 次查询什么都不报，
#              N 取一遍扫描（每条规则 2 次查询）或一整趟预算（8 次）的花费
#
# 套件（WLC_CONFIRM_DELAY 统一压到 1，免得那一轮 15 秒的复探等待占满运行时间）：
#
#   config     18 条断言  目标字段、严格地址、泄漏 sweep
#   guard       6 条断言  位置读不出来时一次都不切换
#   state      24 条断言  通知状态机（不含判定）
#   lang       20 条断言  SCRIPT_LANG：帮助与通知正文分语言，日志仍固定英文
#   decision   49 条断言  判定表：N1-N8、N10-N14（约 2 分钟）
#   reconfirm  13 条断言  N9：目标设备是另一台机器时的轮内复探。决定套件看不见这条：
#                        它的目标就是特征设备，于是走「一台设备管两个角色」的捷径，
#                        从来没有真的探测过目标
#
# config、state、lang、decision、reconfirm 的夹具都从真实邻居表里取设备（那是唯一检验
# 真实 `arp` 输出解析的地方）；机器上没有邻居条目时它们造不出夹具，runner 会把那一份记为
# 失败并写明 FIXTURE UNUSABLE，而不是静默跳过。
#
# 用法：
#   tests/wifi-loc-selftest.sh              全部套件
#   tests/wifi-loc-selftest.sh decision     按名字跑一份
#
# 断言标签沿用中文：它们就是 AGENTS.md 里的用例名。
#
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/wifi-loc-detect.sh"
ORIG_PATH="$PATH"
DEAD=203.0.113.7               # RFC 5737 测试地址：没有任何设备会应答它
DEAD_MAC="de:ad:be:ef:00:01"
cd "$ROOT" || exit 1

pass=0; fail=0; total_pass=0; total_fail=0

eq()    { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS  $1";
          else fail=$((fail+1)); echo "FAIL  $1 (want [$2], got [$3])"; fi; }
has()   { if grep -q "$3" "$2" 2>/dev/null; then pass=$((pass+1)); echo "PASS  $1";
          else fail=$((fail+1)); echo "FAIL  $1 (no /$3/)"; sed 's/^/      | /' "$2"; fi; }
hasnt() { if grep -q "$3" "$2" 2>/dev/null; then fail=$((fail+1)); echo "FAIL  $1 (unexpected /$3/)";
          else pass=$((pass+1)); echo "PASS  $1"; fi; }
order() { local a b; a=$(grep -n "$2" "$3" | head -1 | cut -d: -f1)
          b=$(grep -n "$4" "$3" | head -1 | cut -d: -f1)
          if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then pass=$((pass+1)); echo "PASS  $1"
          else fail=$((fail+1)); echo "FAIL  $1 (line $a vs $b)"; fi; }
lt()    { if [ "$2" -lt "$3" ]; then pass=$((pass+1)); echo "PASS  $1 (${2}s < ${3}s)"
          else fail=$((fail+1)); echo "FAIL  $1 (${2}s not < ${3}s)"; fi; }
ge()    { if [ "$2" -ge "$3" ]; then pass=$((pass+1)); echo "PASS  $1 (${2}s >= ${3}s)"
          else fail=$((fail+1)); echo "FAIL  $1 (${2}s not >= ${3}s)"; fi; }
le()    { if [ "$2" -le "$3" ]; then pass=$((pass+1)); echo "PASS  $1 (${2}s <= ${3}s)"
          else fail=$((fail+1)); echo "FAIL  $1 (${2}s not <= ${3}s)"; fi; }

# 一轮运行的第一行日志到回落那行之间的秒数，时间戳取自日志自身。缺任一行时打印 -1。
# 匹配的是英文原文——日志固定英文，不随 SCRIPT_LANG 变（这是有意为之，见 AGENTS.md 第 11 条）。
fallback_delay() {
  awk '
    function sec(t, a) { split(t, a, ":"); return a[1]*3600 + a[2]*60 + a[3] }
    /current location:/ { if (!start) start = sec(substr($2, 1, 8)) }
    /falling back to/   { if (!fin) fin = sec(substr($2, 1, 8)) }
    END { if (start && fin) print fin - start; else print -1 }
  ' "$1"
}

# 桩 arp：对特征地址的前 <n> 次查询什么都不报，之后落回真的 arp。一遍扫描每条规则花 2 次
# 查询，所以 n=2 恰好是一遍，n=8 是一整趟预算。参数做精确匹配（$2）：子串匹配会把目标
# 地址也一起吞掉，而那是另一台设备。
mk_arp_stub() {
  local n="$1" dir="$T/arpbin$1"
  mkdir -p "$dir"
  cat > "$dir/arp" <<EOF
#!/bin/sh
if [ "\$2" = "$FIP" ]; then
  c="$dir/count"
  k=\$(cat "\$c" 2>/dev/null || echo 0)
  if [ "\$k" -lt $n ]; then
    echo \$((k + 1)) > "\$c"
    echo "? ($FIP) -- no entry"
    exit 0
  fi
fi
exec /usr/sbin/arp "\$@"
EOF
  chmod +x "$dir/arp"
}

# 一个桩 bin 目录，加上每份套件都要的那两个桩。它把建好的目录打印出来，好让调用方沿用
# 配方里那个简短的 "$T" 命名。
# osascript 桩记的是整条参数（`$*`）而不是「调用过一次」：lang 套件要据此断言真正投递出去
# 的正文长什么样。每次调用仍只写一行，所以各套件按行计数（wc -l）不受影响。
mk_stubs() {
  local t; t=$(mktemp -d); mkdir -p "$t/bin"
  cat > "$t/bin/osascript" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$WLC_NOTIFY_LOG"
STUB
  cat > "$t/bin/scselect" <<'STUB'
#!/bin/sh
printf '%s\n' "${1:-<read>}" >> "$WLC_SCSELECT_LOG"
STUB
  chmod +x "$t/bin/osascript" "$t/bin/scselect"
  printf '%s\n' "$t"
}

# 从真实邻居表里挑两台在线设备：特征设备，以及一台不是它的第二台。F2 不能包含 F1 作为
# 子串，否则一个按子串匹配的 arp 桩会把目标地址也吞掉（仓库里的桩按精确参数匹配；这条
# 让夹具本身也保持诚实）。
pick_devices() {
  FIP=$(arp -an | sed -n 's/^? (\([0-9.]*\)) at \([0-9a-fA-F:]*\) on [a-z0-9]* .*/\1 \2/p' \
        | grep -vE '^(224|239)\.| ff:ff:ff:ff:ff:ff' | head -1 | awk '{print $1}')
  FMAC=$(arp -n "$FIP" 2>/dev/null | sed -n 's/.* at \([0-9a-fA-F:]*\) on .*/\1/p')
  F2IP=$(arp -an | sed -n 's/^? (\([0-9.]*\)) at \([0-9a-fA-F:]*\) on [a-z0-9]* .*/\1 \2/p' \
         | grep -vE '^(224|239)\.| ff:ff:ff:ff:ff:ff' \
         | awk -v skip="$FIP" '$1 != skip && index($1, skip) == 0 {print $1; exit}')
  F2MAC=$(arp -n "$F2IP" 2>/dev/null | sed -n 's/.* at \([0-9a-fA-F:]*\) on .*/\1/p')
}

# 判定类套件统一钉住英文：SCRIPT_LANG 只影响帮助与通知正文，而套件里有断言直接匹配通知
# 正文（决定套件的 N8：`not the one expected`）。语言本身由 lang 套件专门覆盖。
mkcfg() { printf 'SCRIPT_LANG="en"\nLOCATION_1_NAME="Home"\nLOCATION_1_IP="%s"\nLOCATION_1_MAC="%s"\nLOCATION_1_TARGET_IP="%s"\nLOCATION_1_TARGET_MAC="%s"\n' \
            "$2" "$3" "$4" "$5" > "$1"; }

# --- config：目标字段、它们的默认值与校验 ------------------------------------
suite_config() {
  echo "### config"
  local T; T=$(mk_stubs); pass=0; fail=0
  run() { WLC_STATE="$T/state" WLC_CONFIG="$1" "$SCRIPT" > "$2" 2>&1; }

  cat > "$T/def.env" <<'EOF'
LOCATION_1_NAME="Home"
LOCATION_1_IP="192.0.2.1"
LOCATION_1_MAC="00:00:5e:00:53:01"
EOF
  run "$T/def.env" "$T/o1"
  has "省略目标字段时默认等于特征设备" "$T/o1" "config: rule 'Home': feature 192.0.2.1, target 192.0.2.1"

  cat > "$T/exp.env" <<'EOF'
LOCATION_1_NAME="Home"
LOCATION_1_IP="192.0.2.1"
LOCATION_1_MAC="00:00:5e:00:53:01"
LOCATION_1_TARGET_IP="192.0.2.100"
LOCATION_1_TARGET_MAC="00:00:5e:00:53:02"
EOF
  run "$T/exp.env" "$T/o2"
  has "显式目标设备被采用" "$T/o2" "target 192.0.2.100"
  has "特征设备仍被采用"   "$T/o2" "feature 192.0.2.1"

  cat > "$T/half.env" <<'EOF'
LOCATION_1_NAME="Home"
LOCATION_1_IP="192.0.2.1"
LOCATION_1_MAC="00:00:5e:00:53:01"
LOCATION_1_TARGET_IP="192.0.2.100"
EOF
  run "$T/half.env" "$T/o3"
  has "只给 TARGET_IP 时仍加载" "$T/o3" "target 192.0.2.100"

  cat > "$T/bad.env" <<'EOF'
LOCATION_1_NAME="Home"
LOCATION_1_IP="192.0.2.1"
LOCATION_1_MAC="00:00:5e:00:53:01"
LOCATION_1_TARGET_IP="999.1.1"
EOF
  run "$T/bad.env" "$T/o4"
  has   "非法 TARGET_IP 报错并跳过整组" "$T/o4" "invalid TARGET_IP"
  hasnt "非法组没有进入规则表"          "$T/o4" "config: rule"

  cat > "$T/names.env" <<'EOF'
LOCATION_1_NAME="Home Office"
LOCATION_1_IP="192.0.2.1"
LOCATION_1_MAC="00:00:5e:00:53:01"
LOCATION_2_NAME="Home"
LOCATION_2_IP="192.0.2.2"
LOCATION_2_MAC="00:00:5e:00:53:02"
EOF
  run "$T/names.env" "$T/o5"
  hasnt "子串名字不算重名（P1）" "$T/o5" "duplicate"
  has   "两条规则都加载"         "$T/o5" "loaded 2 location rule(s)"

  cat > "$T/range.env" <<'EOF'
LOCATION_1_NAME="Home"
LOCATION_1_IP="999.1.1.1"
LOCATION_1_MAC="00:00:5e:00:53:01"
EOF
  run "$T/range.env" "$T/o6"
  has   "越界 IP 被跳过（P3）" "$T/o6" "invalid IP"
  hasnt "越界组未加载"         "$T/o6" "config: rule"

  # 严格地址。实测：arp 把前导零当八进制读，所以 192.168.010.1 解析到 192.168.8.1——与
  # 写下的不是同一台设备；而 0.0.0.0 返回的是网关条目，那会「在哪个网络都匹配上网关 MAC」。
  # 两者都必须被拒绝，而不是拿去探测。
  cat > "$T/octal.env" <<'EOF'
LOCATION_1_NAME="Home"
LOCATION_1_IP="198.51.100.010"
LOCATION_1_MAC="00:00:5e:00:53:01"
EOF
  run "$T/octal.env" "$T/o7"
  has   "前导零的 IP 被跳过" "$T/o7" "invalid IP"
  hasnt "前导零组未加载"     "$T/o7" "config: rule"

  cat > "$T/octal-t.env" <<'EOF'
LOCATION_1_NAME="Home"
LOCATION_1_IP="192.0.2.1"
LOCATION_1_MAC="00:00:5e:00:53:01"
LOCATION_1_TARGET_IP="010.0.2.1"
EOF
  run "$T/octal-t.env" "$T/o8"
  has   "前导零的 TARGET_IP 被跳过" "$T/o8" "invalid TARGET_IP"
  hasnt "前导零目标组未加载"        "$T/o8" "config: rule"

  cat > "$T/zero.env" <<'EOF'
LOCATION_1_NAME="Home"
LOCATION_1_IP="0.0.0.0"
LOCATION_1_MAC="00:00:5e:00:53:01"
EOF
  run "$T/zero.env" "$T/o9"
  has "0.0.0.0 被跳过（arp 会返回网关条目）" "$T/o9" "invalid IP"

  cat > "$T/mcast.env" <<'EOF'
LOCATION_1_NAME="Home"
LOCATION_1_IP="224.0.0.1"
LOCATION_1_MAC="00:00:5e:00:53:01"
EOF
  run "$T/mcast.env" "$T/o10"
  has "多播地址被跳过" "$T/o10" "invalid IP"

  # 配置留下的、带 LOCATION_ 前缀的一切都必须在脚本执行子进程（`log` 会跑 `date`）之前
  # 消失。实测（配置里带 `export`）：LOCATION_65_NAME 曾经到达那个子进程。SCRIPT_LANG 是
  # 同一个文件里的代码，同样不允许漏出去。
  cat > "$T/bin/date" <<'STUB'
#!/bin/sh
env | grep -E '^(LOCATION_|SCRIPT_LANG)' >> "$WLC_LEAK_LOG"
exec /bin/date "$@"
STUB
  chmod +x "$T/bin/date"
  cat > "$T/leak.env" <<'EOF'
export LOCATION_1_NAME="Home"
export LOCATION_1_IP="192.0.2.1"
export LOCATION_1_MAC="00:00:5e:00:53:01"
export LOCATION_65_NAME="BeyondTheCap"
export LOCATION_SOMETHING="x"
export SCRIPT_LANG="en"
EOF
  : > "$T/leak.log"
  PATH="$T/bin:$ORIG_PATH" WLC_LEAK_LOG="$T/leak.log" WLC_STATE="$T/state" \
    WLC_CONFIG="$T/leak.env" "$SCRIPT" > "$T/o11" 2>&1
  hasnt "配置里其它 LOCATION_* 不泄漏给子进程" "$T/leak.log" "LOCATION_"
  hasnt "配置里的 SCRIPT_LANG 不泄漏给子进程"  "$T/leak.log" "SCRIPT_LANG"

  rm -rf "$T"
}

# --- guard：位置读不出来时绝不切换 ------------------------------------------
# 当前位置只有一个用途：决定要不要调 scselect。每次 scselect 都会改写 SystemConfiguration、
# 因而再触发一轮——2026-09-16 实测，连「切到当前所在的位置」都会。所以读失败必须让这一轮
# 停下来：猜成「不在默认位置」会变成每分钟切一次、再触发一次，永远循环。
suite_guard() {
  echo "### guard"
  local T; T=$(mk_stubs); pass=0; fail=0
  mkdir -p "$T/bin2"
  cat > "$T/bin2/scselect" <<'STUB'
#!/bin/sh
printf '%s\n' "${1:-<read>}" >> "$WLC_SCSELECT_LOG"
[ -n "${SCSELECT_FAIL:-}" ] && exit 1
[ -n "${SCSELECT_GARBAGE:-}" ] && { echo "unexpected shape"; exit 0; }
exit 0
STUB
  chmod +x "$T/bin2/scselect"
  export WLC_SCSELECT_LOG="$T/ss.log" WLC_STATE="$T/state"
  cat > "$T/c.env" <<'EOF'
LOCATION_1_NAME="Home"
LOCATION_1_IP="192.0.2.1"
LOCATION_1_MAC="00:00:5e:00:53:01"
EOF

  : > "$WLC_SCSELECT_LOG"
  PATH="$T/bin2:$ORIG_PATH" SCSELECT_FAIL=1 WLC_CONFIG="$T/c.env" "$SCRIPT" --apply > "$T/out" 2>&1
  rc=$?
  eq  "scselect 失败 -> 退出 1"        1 "$rc"
  eq  "scselect 失败 -> 没有发起切换"  0 "$(grep -c -v '^<read>$' "$WLC_SCSELECT_LOG" | tr -d ' ')"
  has "scselect 失败 -> 记一行说明"    "$T/out" "cannot determine the current location"

  : > "$WLC_SCSELECT_LOG"
  PATH="$T/bin2:$ORIG_PATH" SCSELECT_GARBAGE=1 WLC_CONFIG="$T/c.env" "$SCRIPT" --apply > "$T/out" 2>&1
  rc=$?
  eq  "输出无法解析 -> 退出 1"         1 "$rc"
  eq  "输出无法解析 -> 没有发起切换"   0 "$(grep -c -v '^<read>$' "$WLC_SCSELECT_LOG" | tr -d ' ')"
  has "输出无法解析 -> 记一行说明"     "$T/out" "did not parse"

  unset WLC_SCSELECT_LOG WLC_STATE
  rm -rf "$T"
}

# --- state：投递了什么、记住了什么、重试什么 ---------------------------------
suite_state() {
  echo "### state"
  local T; T=$(mk_stubs); pass=0; fail=0
  mkdir -p "$T/badbin"
  cat > "$T/badbin/osascript" <<'STUB'
#!/bin/sh
exit 1
STUB
  chmod +x "$T/badbin/osascript"
  export WLC_NOTIFY_LOG="$T/notify.log" WLC_SCSELECT_LOG="$T/ss.log" WLC_STATE="$T/state"
  export WLC_CONFIRM_DELAY=1
  pick_devices
  [ -z "$FIP" ] || [ -z "$F2MAC" ] && { echo "need two live neighbour entries to build the fixtures from" >&2; return 1; }

  count() { wc -l < "$WLC_NOTIFY_LOG" 2>/dev/null | tr -d ' '; }
  st()    { sed -n 's/^state=//p' "$WLC_STATE" 2>/dev/null | head -1; }
  OK="$T/ok.env"; mkcfg "$OK" "$FIP" "$FMAC" "$FIP" "$FMAC"
  BR="$T/br.env"; mkcfg "$BR" "$FIP" "$FMAC" "$DEAD" "$DEAD_MAC"
  NO="$T/no.env"; mkcfg "$NO" "$DEAD" "$DEAD_MAC" "$DEAD" "$DEAD_MAC"
  agent()  { WLC_CONFIG="$1" WLC_DEFAULT=Automatic WLC_CUR="${2:-Home}" \
               PATH="$T/bin:$ORIG_PATH" "$SCRIPT" --apply --notify > "$T/out" 2>&1; }
  manual() { WLC_CONFIG="$1" WLC_DEFAULT=Automatic WLC_CUR="${2:-Home}" \
               PATH="$T/bin:$ORIG_PATH" "$SCRIPT" --apply > "$T/out" 2>&1; }
  reset()  { : > "$WLC_NOTIFY_LOG"; rm -f "$WLC_STATE"; }

  reset; agent "$OK"
  eq "目标在场 -> 状态 ok"     ok "$(st)"
  eq "目标在场 -> 不通知"      0 "$(count)"

  reset; agent "$BR"
  eq "目标掉线 -> 通知一次"    1 "$(count)"
  eq "目标掉线 -> 状态 broken" broken "$(st)"
  agent "$BR"
  has "同一状态 -> 不重复通知" "$T/out" "already reported"
  eq "同一状态 -> 通知仍是 1"  1 "$(count)"

  reset; manual "$BR"
  eq "手动跑（无 --notify）不投递" 0 "$(count)"
  eq "手动跑不写状态"              "" "$(st)"
  agent "$BR"
  eq "随后 agent 仍会通知"         1 "$(count)"

  reset; WLC_CONFIG="$BR" WLC_DEFAULT=Automatic WLC_CUR=Home PATH="$T/badbin:$T/bin:$ORIG_PATH" \
    "$SCRIPT" --apply --notify > "$T/out" 2>&1
  eq  "投递失败 -> 不写状态"   "" "$(st)"
  has "投递失败 -> 记一行日志" "$T/out" "notification failed"
  agent "$BR"
  eq "下一轮重试成功"          1 "$(count)"

  reset; agent "$NO"
  eq "特征未确认 -> 不通知"       0 "$(count)"
  eq "特征未确认 -> 状态 default" default "$(st)"

  # 唯一值得通知的那种离开可能投递失败——也可能根本没人请求投递。两者都让这条通知继续
  # 欠着，而不是被记成已送达：`state` 如实说我们在哪儿（默认位置），`pending` 说用户还
  # 没被告知什么，`pending_rule` 说那是关于哪个位置的。除了送达、或那个位置自己的设备
  # 回来，什么都不销账。
  MM="$T/mm.env"; mkcfg "$MM" "$FIP" "$DEAD_MAC" "$FIP" "$DEAD_MAC"
  pend()     { sed -n 's/^pending=//p' "$WLC_STATE" 2>/dev/null | head -1; }
  pendrule() { sed -n 's/^pending_rule=//p' "$WLC_STATE" 2>/dev/null | head -1; }

  reset
  PATH="$T/badbin:$T/bin:$ORIG_PATH" WLC_CONFIG="$MM" WLC_DEFAULT=Automatic WLC_CUR=Home \
    "$SCRIPT" --apply --notify > "$T/out" 2>&1
  eq "回落通知投递失败 -> 状态仍如实记 default" default "$(st)"
  eq "回落通知投递失败 -> 记下欠着的通知"       feature-mismatch "$(pend)"
  eq "欠账记着是哪个位置"                        Home "$(pendrule)"

  reset; manual "$MM" Home
  eq "手动跑（无 --notify）-> 也算欠账" feature-mismatch "$(pend)"
  : > "$WLC_NOTIFY_LOG"
  agent "$MM" Automatic
  has "随后 agent 补发那条通知"        "$T/out" "retrying the notice"
  eq  "补发 -> 送达一次"               1 "$(count)"
  eq  "补发成功 -> pending 清空"       "" "$(pend)"

  # 命中另一个位置不能抹掉关于别处的欠账：配置了多张网络时，只有那个位置自己的特征设备
  # 回来才销账。
  TWO="$T/two.env"
  printf 'SCRIPT_LANG="en"\nLOCATION_1_NAME="Home"\nLOCATION_1_IP="%s"\nLOCATION_1_MAC="%s"\nLOCATION_2_NAME="Office"\nLOCATION_2_IP="%s"\nLOCATION_2_MAC="%s"\n' \
    "$FIP" "$DEAD_MAC" "$F2IP" "$F2MAC" > "$TWO"
  printf 'state=default\npending=feature-mismatch\npending_rule=Home\n' > "$WLC_STATE"
  agent "$TWO" Automatic
  eq "命中别的位置 -> 欠账保留"        feature-mismatch "$(pend)"
  agent "$OK" Home
  eq "同一位置特征设备恢复 -> 清空"    "" "$(pend)"

  printf 'state=default\npending=feature-mismatch\n' > "$WLC_STATE"
  agent "$NO" Automatic
  eq "异常不可观察 -> pending 保留" feature-mismatch "$(pend)"

  unset WLC_NOTIFY_LOG WLC_SCSELECT_LOG WLC_STATE WLC_CONFIRM_DELAY
  rm -rf "$T"
}

# --- lang：SCRIPT_LANG 只改变帮助与通知正文，日志固定英文 ---------------------
# 语言的三条硬规矩：
#   * 只认 "en" 与 "zh_CN"（大小写不敏感），缺省 zh_CN；不兼容 zh-CN 这种横杠写法；
#   * 取值不认识时**不**中断判定，回落到 zh_CN 并在日志里说明一次；
#   * 投递出去的正文里不得出现地址或 MAC（AGENTS.md 第 8 条），两种语言都要查。
# 断言的正文取自 osascript 桩记下的那条调用（WLC_NOTIFY_LOG），也就是真正交给通知中心的
# 文本，而不是日志里 `NOTIFY:` 后面那串。
suite_lang() {
  echo "### lang"
  local T; T=$(mk_stubs); pass=0; fail=0
  export WLC_NOTIFY_LOG="$T/notify.log" WLC_SCSELECT_LOG="$T/ss.log" WLC_STATE="$T/state"
  export WLC_CONFIRM_DELAY=1
  pick_devices
  [ -z "$FIP" ] && { echo "no live neighbour entry to build the fixture from" >&2; return 1; }

  # 特征设备在场、目标设备缺席：走「目标掉线」那条通知（notify_broken）。
  cfg_broken() {
    { [ -n "${2:-}" ] && printf 'SCRIPT_LANG="%s"\n' "${2:-}"
      printf 'LOCATION_1_NAME="Home"\nLOCATION_1_IP="%s"\nLOCATION_1_MAC="%s"\n' "$FIP" "$FMAC"
      printf 'LOCATION_1_TARGET_IP="%s"\nLOCATION_1_TARGET_MAC="%s"\n' "$DEAD" "$DEAD_MAC"
    } > "$1"
  }
  # 特征地址以另一个 MAC 应答：走「换了设备」那条通知（notify_mismatch）。这条路径全是
  # 命中，一秒都不等，所以语言相关的多数断言都用它。
  cfg_mismatch() {
    { [ -n "${2:-}" ] && printf 'SCRIPT_LANG="%s"\n' "${2:-}"
      printf 'LOCATION_1_NAME="Home"\nLOCATION_1_IP="%s"\nLOCATION_1_MAC="%s"\n' "$FIP" "$DEAD_MAC"
      printf 'LOCATION_1_TARGET_IP="%s"\nLOCATION_1_TARGET_MAC="%s"\n' "$FIP" "$DEAD_MAC"
    } > "$1"
  }
  run() { WLC_CONFIG="$1" WLC_DEFAULT=Automatic WLC_CUR=Home PATH="$T/bin:$ORIG_PATH" \
            "$SCRIPT" --apply --notify > "$T/out" 2>&1; }
  reset() { : > "$WLC_NOTIFY_LOG"; : > "$WLC_SCSELECT_LOG"; rm -f "$WLC_STATE"; }
  # 帮助文本里提到的选项名数量（去重后），用来证明两份帮助都没有漏掉用法。
  help_opts() { grep -o -e '--apply' -e '--notify' -e '--print-mac' "$1" | sort -u | wc -l | tr -d ' '; }

  # 缺省就是简体中文（配置里没有该字段）
  reset; cfg_mismatch "$T/mm-def.env"; run "$T/mm-def.env"
  has   "默认语言：换了设备那条通知是中文" "$WLC_NOTIFY_LOG" "配置地址上的设备与预期不符"
  hasnt "默认语言：不是英文正文"           "$WLC_NOTIFY_LOG" "not the one expected"
  hasnt "默认语言：正文不含 IP"            "$WLC_NOTIFY_LOG" '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]'
  hasnt "默认语言：正文不含 MAC"           "$WLC_NOTIFY_LOG" '[0-9a-fA-F]\{2\}:[0-9a-fA-F]\{2\}:'

  # SCRIPT_LANG="en" 切回英文，隐私约束同样成立
  reset; cfg_mismatch "$T/mm-en.env" en; run "$T/mm-en.env"
  has   "SCRIPT_LANG=en：正文是英文"       "$WLC_NOTIFY_LOG" "not the one expected"
  hasnt "SCRIPT_LANG=en：不是中文正文"     "$WLC_NOTIFY_LOG" "配置地址上的设备与预期不符"
  hasnt "SCRIPT_LANG=en：正文不含 IP"      "$WLC_NOTIFY_LOG" '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]'

  # 大小写不敏感（归一化只能用 tr：bash 3.2 没有 ${var,,}）
  reset; cfg_mismatch "$T/mm-case.env" ZH_cn; run "$T/mm-case.env"
  has "SCRIPT_LANG=ZH_cn 被认作中文"       "$WLC_NOTIFY_LOG" "配置地址上的设备与预期不符"

  # 环境变量优先于配置字段
  reset; cfg_mismatch "$T/mm-ovr.env" zh_CN
  WLC_LANG=en WLC_CONFIG="$T/mm-ovr.env" WLC_DEFAULT=Automatic WLC_CUR=Home \
    PATH="$T/bin:$ORIG_PATH" "$SCRIPT" --apply --notify > "$T/out" 2>&1
  has "WLC_LANG=en 覆盖配置里的 zh_CN"     "$WLC_NOTIFY_LOG" "not the one expected"

  # 取值不认识：回落到 zh_CN，并在这一轮记一行英文说明（日志固定英文）
  reset; cfg_mismatch "$T/mm-bad.env" zh-CN; run "$T/mm-bad.env"
  has "横杠写法不被接受 -> 回落到中文"     "$WLC_NOTIFY_LOG" "配置地址上的设备与预期不符"
  has "未知取值 -> 日志说明一次"           "$T/out" "SCRIPT_LANG='zh-CN' is not supported"

  # 另一条通知（目标设备掉线）也分语言
  reset; cfg_broken "$T/br-def.env"; run "$T/br-def.env"
  has   "目标掉线通知默认是中文"           "$WLC_NOTIFY_LOG" "当前网络与已配置的设置不符"
  hasnt "目标掉线通知默认不是英文"         "$WLC_NOTIFY_LOG" "no longer matches"
  reset; cfg_broken "$T/br-en.env" en; run "$T/br-en.env"
  has   "目标掉线通知 en 是英文"           "$WLC_NOTIFY_LOG" "no longer matches"

  # --help 跟着语言走。这条路径比读位置还早，所以语言由配置里的字段或环境变量决定；
  # WLC_CONFIG 显式指向不存在的文件，免得读到这台机器上真实的配置。
  WLC_CONFIG="$T/none.env" "$SCRIPT" --help > "$T/help-zh" 2>&1
  has   "默认帮助是中文"                   "$T/help-zh" "用法："
  hasnt "默认帮助不是英文"                 "$T/help-zh" "Usage:"
  WLC_LANG=en WLC_CONFIG="$T/none.env" "$SCRIPT" --help > "$T/help-en" 2>&1
  has   "WLC_LANG=en 时帮助是英文"         "$T/help-en" "Usage:"
  hasnt "英文帮助不是中文"                 "$T/help-en" "用法："
  eq    "中文帮助提到全部三个选项"         3 "$(help_opts "$T/help-zh")"
  eq    "英文帮助提到全部三个选项"         3 "$(help_opts "$T/help-en")"

  unset WLC_NOTIFY_LOG WLC_SCSELECT_LOG WLC_STATE WLC_CONFIRM_DELAY
  rm -rf "$T"
}

# --- decision：判定表，N1-N8 与 N10-N14 --------------------------------------
suite_decision() {
  echo "### decision"
  local T; T=$(mk_stubs); pass=0; fail=0
  export WLC_NOTIFY_LOG="$T/notify.log" WLC_SCSELECT_LOG="$T/ss.log" WLC_STATE="$T/state"
  export WLC_CONFIRM_DELAY=1
  pick_devices
  [ -z "$FIP" ] && { echo "no live neighbour entry to build the fixture from" >&2; return 1; }

  # 两个可选桩：8 次查询的沉默 = 一整趟预算，2 次 = 一遍扫描。
  mk_arp_stub 8
  mk_arp_stub 2

  notify_count() { wc -l < "$WLC_NOTIFY_LOG" 2>/dev/null | tr -d ' '; }
  ss_count()     { grep -c "^$1\$" "$WLC_SCSELECT_LOG" 2>/dev/null | tr -d ' '; }
  st()           { sed -n 's/^state=//p' "$WLC_STATE" 2>/dev/null | head -1; }
  # $4 = 特征地址前多少次查询保持沉默（空 = 不沉默）。
  run() { local p="$T/bin:$ORIG_PATH"; [ -n "${4:-}" ] && p="$T/arpbin$4:$p"
          WLC_CONFIG="$1" WLC_DEFAULT="$2" WLC_CUR="$3" PATH="$p" \
            "$SCRIPT" --apply --notify > "$T/out" 2>&1; }
  reset() { : > "$WLC_NOTIFY_LOG"; : > "$WLC_SCSELECT_LOG"; rm -f "$WLC_STATE"; rm -f "$T"/arpbin*/count; }

  OK_CFG="$T/ok.env"; mkcfg "$OK_CFG" "$FIP" "$FMAC" "$FIP" "$FMAC"
  BR_CFG="$T/br.env"; mkcfg "$BR_CFG" "$FIP" "$FMAC" "$DEAD" "$DEAD_MAC"
  MM_CFG="$T/mm.env"; mkcfg "$MM_CFG" "$FIP" "$DEAD_MAC" "$FIP" "$DEAD_MAC"
  NO_CFG="$T/no.env"; mkcfg "$NO_CFG" "$DEAD" "$DEAD_MAC" "$DEAD" "$DEAD_MAC"

  # N1/N2 —— 命中且目标在场（目标缺省等于特征设备）
  reset; run "$OK_CFG" Automatic Home
  has   "N2 判定为匹配"               "$T/out" "settings match"
  hasnt "N1 目标等于特征时不重复探测" "$T/out" "target device, expect"
  eq    "N2 不通知"                   0 "$(notify_count)"
  eq    "N2 不切换"                   0 "$(ss_count Home)"
  eq    "N2 状态 ok"                  ok "$(st)"

  # N3/N5 —— 命中但目标不在：broken 通知一次，恢复后再坏能再通知
  reset; run "$BR_CFG" Automatic Home
  has "N3 进入 broken 并通知" "$T/out" "NOTIFY:"
  eq  "N3 通知一次"           1 "$(notify_count)"
  eq  "N3 状态 broken"        broken "$(st)"
  eq  "N3 不切换"             0 "$(ss_count Home)"
  run "$BR_CFG" Automatic Home
  has "N3 第二轮被抑制"       "$T/out" "already reported"
  eq  "N3 通知仍是 1 次"      1 "$(notify_count)"
  run "$OK_CFG" Automatic Home
  eq  "N5 目标恢复回 ok"      ok "$(st)"
  run "$BR_CFG" Automatic Home
  eq  "N5 再坏会再通知"       2 "$(notify_count)"

  # N4 —— 从默认位置命中：先切换，再核对目标
  reset; run "$BR_CFG" Automatic Automatic
  has   "N4 识别并切换"        "$T/out" "switched to 'Home'"
  eq    "N4 真的调用了切换"    1 "$(ss_count Home)"
  order "N4 先切换后核对目标"  "switched to 'Home'" "$T/out" "target device, expect"
  has   "N4 目标掉线判 broken"  "$T/out" "NOTIFY:"

  # N10 —— 特征未确认且已在默认位置：什么都不做
  reset; run "$NO_CFG" Automatic Automatic
  has "N10 无动作"       "$T/out" "nothing to do"
  eq  "N10 不通知"       0 "$(notify_count)"
  eq  "N10 状态 default" default "$(st)"
  eq  "N10 不切换"       0 "$(ss_count Automatic)"

  # N6 —— 每一遍都缺席：第一遍就回落一次，不通知，这一轮停在默认位置
  reset; run "$NO_CFG" Automatic Home
  has "N6 确认离开"        "$T/out" "we have left"
  eq  "N6 回落一次"        1 "$(ss_count Automatic)"
  eq  "N6 不通知"          0 "$(notify_count)"
  eq  "N6 状态 default"    default "$(st)"

  # N7 —— 第一趟全程沉默（8 次查询 = 4 遍），在复探那一趟应答：回落、切回，全程安静
  reset; run "$OK_CFG" Automatic Home 8
  has "N7 复探命中并切回"  "$T/out" "the device is back after all"
  eq  "N7 回落了一次"      1 "$(ss_count Automatic)"
  eq  "N7 也切回了一次"    1 "$(ss_count Home)"
  eq  "N7 全程不通知"      0 "$(notify_count)"
  eq  "N7 状态 ok"         ok "$(st)"

  # N8 —— 另一台设备占了特征地址：回落，并且通知一次
  reset; run "$MM_CFG" Automatic Home
  eq  "N8 通知一次"        1 "$(notify_count)"
  has "N8 文案说明换了设备" "$T/out" "not the one expected"
  eq  "N8 回落一次"        1 "$(ss_count Automatic)"
  eq  "N8 状态 default"    default "$(st)"

  # N13 —— 回落在第一遍扫描之后就决定，而不是等完整趟预算；同一趟里稍后应答的设备直接
  # 切回，不付复探等待。前 2 次查询沉默恰好是一遍扫描；CONFIRM_DELAY 保持 20 秒，所以
  # 真要走复探的轮次不可能在 20 秒内结束。
  export WLC_CONFIRM_DELAY=20
  reset; t_begin=$(date +%s); run "$OK_CFG" Automatic Home 2; elapsed=$(( $(date +%s) - t_begin ))
  eq    "N13 首轮扫描未命中就回落" 1 "$(ss_count Automatic)"
  eq    "N13 剩余预算内静默切回"   1 "$(ss_count Home)"
  order "N13 先回落再切回"         "falling back to 'Automatic'" "$T/out" "the device is back after all"
  lt    "N13 没有等确认窗口"       "$elapsed" 20
  eq    "N13 不通知"               0 "$(notify_count)"
  eq    "N13 状态 ok"              ok "$(st)"
  export WLC_CONFIRM_DELAY=1

  # N14 —— 把决策提前不得缩短搜索：始终不应答的设备仍要花掉两趟、每趟四遍，所以轮次仍然
  # 很长，而回落那一行的时刻只比开头晚几秒。CONFIRM_DELAY=0 把等待排除在测量之外。
  reset; t_begin=$(date +%s)
  WLC_CONFIG="$NO_CFG" WLC_DEFAULT=Automatic WLC_CUR=Home WLC_CONFIRM_DELAY=0 \
    PATH="$T/bin:$ORIG_PATH" "$SCRIPT" --apply --notify > "$T/out" 2>&1
  elapsed=$(( $(date +%s) - t_begin ))
  has "N14 确认离开"        "$T/out" "we have left"
  eq  "N14 回落一次"        1 "$(ss_count Automatic)"
  ge  "N14 探测预算没缩短"  "$elapsed" 12
  # 两行都在，这个延迟才有意义：缺任一行时 fallback_delay 返回 -1。
  le  "N14 回落决策提前"    "$(fallback_delay "$T/out")" 3
  ge  "N14 回落时刻可读"    "$(fallback_delay "$T/out")" 0

  # N11 —— 带 miss= 行的旧状态文件既不抑制也不阻塞通知
  reset; printf 'state=ok\nmiss=1\n' > "$WLC_STATE"; run "$BR_CFG" Automatic Home
  eq "N11 旧 miss 行被忽略" 1 "$(notify_count)"
  eq "N11 状态写为 broken"  broken "$(st)"

  # N12 —— 更老的格式：一个裸值
  reset; printf 'away\n' > "$WLC_STATE"; run "$BR_CFG" Automatic Home
  eq "N12 裸值不阻止通知"   1 "$(notify_count)"

  # 卫生：runner 从未读过真实位置
  eq "全程没有误用真实 scselect" 0 "$(grep -c '^<read>$' "$WLC_SCSELECT_LOG" 2>/dev/null | tr -d ' ')"

  unset WLC_NOTIFY_LOG WLC_SCSELECT_LOG WLC_STATE WLC_CONFIRM_DELAY
  rm -rf "$T"
}

# --- reconfirm：N9，目标设备不是特征设备的那条路径 ---------------------------
suite_reconfirm() {
  echo "### reconfirm"
  local T; T=$(mk_stubs); pass=0; fail=0
  mkdir -p "$T/arpbin"
  export WLC_NOTIFY_LOG="$T/notify.log" WLC_SCSELECT_LOG="$T/ss.log" WLC_STATE="$T/state"
  export WLC_CONFIRM_DELAY=1
  pick_devices
  if [ -z "$FIP" ] || [ -z "$F2IP" ] || [ -z "$F2MAC" ]; then
    echo "need two live neighbour entries to run this suite (found '$FIP' and '$F2IP')" >&2
    return 1
  fi

  cat > "$T/arpbin/arp" <<EOF
#!/bin/sh
if [ "\$2" = "$FIP" ]; then
  n=\$(cat "$T/arpcount" 2>/dev/null || echo 0)
  if [ "\$n" -lt 8 ]; then
    echo \$((n + 1)) > "$T/arpcount"
    echo "? ($FIP) -- no entry"
    exit 0
  fi
fi
exec /usr/sbin/arp "\$@"
EOF
  chmod +x "$T/arpbin/arp"

  notify_count() { wc -l < "$WLC_NOTIFY_LOG" 2>/dev/null | tr -d ' '; }
  ss_count()     { grep -c "^$1\$" "$WLC_SCSELECT_LOG" 2>/dev/null | tr -d ' '; }
  st()           { sed -n 's/^state=//p' "$WLC_STATE" 2>/dev/null | head -1; }
  run() { PATH="$T/arpbin:$T/bin:$ORIG_PATH" WLC_CONFIG="$1" WLC_DEFAULT=Automatic WLC_CUR=Home \
            "$SCRIPT" --apply --notify > "$T/out" 2>&1; }
  reset() { : > "$WLC_NOTIFY_LOG"; : > "$WLC_SCSELECT_LOG"; rm -f "$WLC_STATE" "$T/arpcount"; }

  # A：目标是一台不同的、在线的设备——这次核对必须真的跑，而且通过
  OK_T="$T/okt.env"; mkcfg "$OK_T" "$FIP" "$FMAC" "$F2IP" "$F2MAC"
  reset; run "$OK_T"
  has   "N9 复探命中，静默切回"        "$T/out" "the device is back after all"
  order "N9 先切回原位置，再核对目标"  "switched back to 'Home'" "$T/out" "target device, expect"
  has   "N9 独立目标设备被判在场"      "$T/out" "target present"
  eq    "N9 状态 ok"                   ok "$(st)"
  eq    "N9 全程不通知"                0 "$(notify_count)"
  eq    "N9 回落一次"                  1 "$(ss_count Automatic)"
  eq    "N9 切回一次"                  1 "$(ss_count Home)"

  # B：目标不在了——仍要切回原位置，然后 broken + 一条通知
  BR_T="$T/brt.env"; mkcfg "$BR_T" "$FIP" "$FMAC" "$DEAD" "$DEAD_MAC"
  reset; run "$BR_T"
  has "N9b 复探命中，仍切回原位置"    "$T/out" "the device is back after all"
  has "N9b 目标缺席被探测到"          "$T/out" "no answer from"
  eq  "N9b 状态 broken"               broken "$(st)"
  eq  "N9b 通知一次"                  1 "$(notify_count)"
  eq  "N9b 只切回一次"                1 "$(ss_count Home)"

  # 卫生：runner 从未读过真实位置
  eq "全程没有误用真实 scselect" 0 "$(grep -c '^<read>$' "$WLC_SCSELECT_LOG" 2>/dev/null | tr -d ' ')"

  unset WLC_NOTIFY_LOG WLC_SCSELECT_LOG WLC_STATE WLC_CONFIRM_DELAY
  rm -rf "$T"
}

SUITES="config guard state lang decision reconfirm"
if [ $# -gt 0 ]; then
  case " $SUITES " in
    *" $1 "*) SUITES="$1" ;;
    *) echo "unknown suite: $1 (have:$SUITES)" >&2; exit 2 ;;
  esac
fi

start=$(date +%s)
for s in $SUITES; do
  suite_start=$(date +%s)
  "suite_$s"
  rc=$?
  echo "--- $s: $pass passed, $fail failed ($(( $(date +%s) - suite_start ))s)"
  if [ "$rc" != 0 ]; then
    # 造不出夹具的套件必须让整轮失败：好几份套件从真实邻居表里取设备，机器上没有邻居
    # 条目时它们里的每条断言都会静默地一次都不跑。
    echo "--- $s: FIXTURE UNUSABLE (rc=$rc): needs one live neighbour entry"
    total_fail=$((total_fail + 1))
  fi
  total_pass=$((total_pass + pass)); total_fail=$((total_fail + fail))
done
echo "=== $total_pass passed, $total_fail failed ($(( $(date +%s) - start ))s) ==="
[ "$total_fail" = 0 ]
