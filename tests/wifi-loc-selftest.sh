#!/bin/bash
#
# Self-test for wifi-loc-detect.sh.
#
# Nothing here touches the machine: the script under test only ever calls
# `scselect`, `osascript` and `arp`, and every suite stubs the ones it needs:
#
#   osascript  records that it was called instead of delivering a notice
#   scselect   records its argument instead of changing this Mac's location; it
#              never runs the real one, so no suite can move the machine
#   arp        only in the cases that need the feature address to look absent:
#              it reports nothing for the first N lookups, N being what one
#              sweep (2 lookups per rule) or one whole pass (8) costs
#
# Suites (WLC_CONFIRM_DELAY is forced to 1 so the 15s in-run confirmation does
# not dominate the runtime):
#
#   config     17 assertions  the target fields, strict addresses, the leak sweep
#   guard       6 assertions  refuses to switch when the location cannot be read
#   state      24 assertions  the notice state machine, minus the decision
#   decision   49 assertions  the decision table: N1-N8, N10-N14   (~2 minutes)
#   reconfirm  13 assertions  N9: the in-run confirmation when the target
#                             device is a different box. The decision suite
#                             cannot see this: its target IS the feature
#                             device, so the run takes the "one device answers
#                             for both" shortcut and never probes a target.
#
# config, state, decision and reconfirm take their devices from the live
# neighbour table (that is the only thing that exercises the real `arp` output
# parsing); on a Mac with no neighbour entry they cannot build a fixture, and
# the runner reports that and fails rather than passing silently.
#
# Usage:
#   tests/wifi-loc-selftest.sh              every suite
#   tests/wifi-loc-selftest.sh decision     one suite by name
#
# Assertion labels stay in Chinese: they are the case names used in AGENTS.md.
#
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/wifi-loc-detect.sh"
ORIG_PATH="$PATH"
DEAD=203.0.113.7               # RFC 5737 test address: nothing answers it
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

# Seconds between a run's first log line and its fallback line, read from the
# log's own timestamps. Prints -1 when either line is missing.
fallback_delay() {
  awk '
    function sec(t, a) { split(t, a, ":"); return a[1]*3600 + a[2]*60 + a[3] }
    /current location:/ { if (!start) start = sec(substr($2, 1, 8)) }
    /falling back to/   { if (!fin) fin = sec(substr($2, 1, 8)) }
    END { if (start && fin) print fin - start; else print -1 }
  ' "$1"
}

# A stub arp that reports nothing for the first <n> lookups of the feature
# address and then falls through to the real one. One sweep spends two lookups
# per rule, so n=2 is exactly one sweep and n=8 is one whole pass. The argument
# is matched exactly: a substring match would also swallow the target address,
# which is a different device.
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

# A stub bin directory plus the two stubs every suite needs. Echoes the
# directory it made, so the caller keeps the recipe's short "$T" names.
mk_stubs() {
  local t; t=$(mktemp -d); mkdir -p "$t/bin"
  cat > "$t/bin/osascript" <<'STUB'
#!/bin/sh
echo called >> "$WLC_NOTIFY_LOG"
STUB
  cat > "$t/bin/scselect" <<'STUB'
#!/bin/sh
printf '%s\n' "${1:-<read>}" >> "$WLC_SCSELECT_LOG"
STUB
  chmod +x "$t/bin/osascript" "$t/bin/scselect"
  printf '%s\n' "$t"
}

# Pick two live neighbour entries: the feature device, and a second device that
# is not it. F2 must not contain F1 as a substring, or an arp stub that matched
# substrings would swallow the target address too (the committed stub matches
# the exact argument instead; this keeps the fixture honest as well).
pick_devices() {
  FIP=$(arp -an | sed -n 's/^? (\([0-9.]*\)) at \([0-9a-fA-F:]*\) on [a-z0-9]* .*/\1 \2/p' \
        | grep -vE '^(224|239)\.| ff:ff:ff:ff:ff:ff' | head -1 | awk '{print $1}')
  FMAC=$(arp -n "$FIP" 2>/dev/null | sed -n 's/.* at \([0-9a-fA-F:]*\) on .*/\1/p')
  F2IP=$(arp -an | sed -n 's/^? (\([0-9.]*\)) at \([0-9a-fA-F:]*\) on [a-z0-9]* .*/\1 \2/p' \
         | grep -vE '^(224|239)\.| ff:ff:ff:ff:ff:ff' \
         | awk -v skip="$FIP" '$1 != skip && index($1, skip) == 0 {print $1; exit}')
  F2MAC=$(arp -n "$F2IP" 2>/dev/null | sed -n 's/.* at \([0-9a-fA-F:]*\) on .*/\1/p')
}

mkcfg() { printf 'LOCATION_1_NAME="Home"\nLOCATION_1_IP="%s"\nLOCATION_1_MAC="%s"\nLOCATION_1_TARGET_IP="%s"\nLOCATION_1_TARGET_MAC="%s"\n' \
            "$2" "$3" "$4" "$5" > "$1"; }

# --- config: the target fields, their defaults and their validation ----------
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

  # Strict addresses. Measured: arp reads a leading zero as octal, so
  # 192.168.010.1 resolves to 192.168.8.1 -- a different device than the one
  # written down -- while 0.0.0.0 returns the gateway's entry, which would match
  # the gateway MAC on whatever network the Mac happens to be on. Both have to
  # be refused, not probed.
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

  # Everything the config leaves behind with a LOCATION_ prefix must be gone
  # before the script runs a child process (`log` runs `date`). Measured with an
  # `export` in the config: LOCATION_65_NAME used to reach that child.
  cat > "$T/bin/date" <<'STUB'
#!/bin/sh
env | grep '^LOCATION_' >> "$WLC_LEAK_LOG"
exec /bin/date "$@"
STUB
  chmod +x "$T/bin/date"
  cat > "$T/leak.env" <<'EOF'
export LOCATION_1_NAME="Home"
export LOCATION_1_IP="192.0.2.1"
export LOCATION_1_MAC="00:00:5e:00:53:01"
export LOCATION_65_NAME="BeyondTheCap"
export LOCATION_SOMETHING="x"
EOF
  : > "$T/leak.log"
  PATH="$T/bin:$ORIG_PATH" WLC_LEAK_LOG="$T/leak.log" WLC_STATE="$T/state" \
    WLC_CONFIG="$T/leak.env" "$SCRIPT" > "$T/o11" 2>&1
  hasnt "配置里其它 LOCATION_* 不泄漏给子进程" "$T/leak.log" "LOCATION_"

  rm -rf "$T"
}

# --- guard: never switch when the current location cannot be read ------------
# The current location has exactly one use: deciding whether to call scselect.
# Every scselect rewrites SystemConfiguration and therefore triggers another
# run -- measured 2026-09-16, even one naming the location we are already in. So
# a read that fails must stop the run: guessing "not in the default location"
# would switch, and re-trigger, once a minute forever.
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

# --- state: what is delivered, what is remembered, what is retried -----------
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

  # The one departure worth a notice can fail to be delivered -- or never be
  # asked for. Both leave the notice owed rather than recorded as delivered:
  # `state` says where we are (the default location, truthfully), `pending` says
  # what the user has not been told yet, and `pending_rule` says which location
  # it is about. Nothing but delivery, or that location's own device coming
  # back, settles it.
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

  # Matching a different location must not erase a debt about another one: with
  # several networks configured, only that location's own feature device coming
  # back settles it.
  TWO="$T/two.env"
  printf 'LOCATION_1_NAME="Home"\nLOCATION_1_IP="%s"\nLOCATION_1_MAC="%s"\nLOCATION_2_NAME="Office"\nLOCATION_2_IP="%s"\nLOCATION_2_MAC="%s"\n' \
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

# --- decision: the decision table, N1-N8 and N10-N14 -------------------------
suite_decision() {
  echo "### decision"
  local T; T=$(mk_stubs); pass=0; fail=0
  export WLC_NOTIFY_LOG="$T/notify.log" WLC_SCSELECT_LOG="$T/ss.log" WLC_STATE="$T/state"
  export WLC_CONFIRM_DELAY=1
  pick_devices
  [ -z "$FIP" ] && { echo "no live neighbour entry to build the fixture from" >&2; return 1; }

  # Two opt-in stubs: 8 lookups of silence is one whole pass, 2 is one sweep.
  mk_arp_stub 8
  mk_arp_stub 2

  notify_count() { wc -l < "$WLC_NOTIFY_LOG" 2>/dev/null | tr -d ' '; }
  ss_count()     { grep -c "^$1\$" "$WLC_SCSELECT_LOG" 2>/dev/null | tr -d ' '; }
  st()           { sed -n 's/^state=//p' "$WLC_STATE" 2>/dev/null | head -1; }
  # $4 = how many lookups of the feature address stay silent (empty = none).
  run() { local p="$T/bin:$ORIG_PATH"; [ -n "${4:-}" ] && p="$T/arpbin$4:$p"
          WLC_CONFIG="$1" WLC_DEFAULT="$2" WLC_CUR="$3" PATH="$p" \
            "$SCRIPT" --apply --notify > "$T/out" 2>&1; }
  reset() { : > "$WLC_NOTIFY_LOG"; : > "$WLC_SCSELECT_LOG"; rm -f "$WLC_STATE"; rm -f "$T"/arpbin*/count; }

  OK_CFG="$T/ok.env"; mkcfg "$OK_CFG" "$FIP" "$FMAC" "$FIP" "$FMAC"
  BR_CFG="$T/br.env"; mkcfg "$BR_CFG" "$FIP" "$FMAC" "$DEAD" "$DEAD_MAC"
  MM_CFG="$T/mm.env"; mkcfg "$MM_CFG" "$FIP" "$DEAD_MAC" "$FIP" "$DEAD_MAC"
  NO_CFG="$T/no.env"; mkcfg "$NO_CFG" "$DEAD" "$DEAD_MAC" "$DEAD" "$DEAD_MAC"

  # N1/N2 -- hit + target present (the target defaults to the feature device)
  reset; run "$OK_CFG" Automatic Home
  has   "N2 判定为匹配"               "$T/out" "settings match"
  hasnt "N1 目标等于特征时不重复探测" "$T/out" "target device, expect"
  eq    "N2 不通知"                   0 "$(notify_count)"
  eq    "N2 不切换"                   0 "$(ss_count Home)"
  eq    "N2 状态 ok"                  ok "$(st)"

  # N3/N5 -- hit + target gone: broken notices once, recovers, can report again
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

  # N4 -- hit from the default location: switch first, then check the target
  reset; run "$BR_CFG" Automatic Automatic
  has   "N4 识别并切换"        "$T/out" "switched to 'Home'"
  eq    "N4 真的调用了切换"    1 "$(ss_count Home)"
  order "N4 先切换后核对目标"  "switched to 'Home'" "$T/out" "target device, expect"
  has   "N4 目标掉线判 broken"  "$T/out" "NOTIFY:"

  # N10 -- feature unconfirmed and already in the default location: do nothing
  reset; run "$NO_CFG" Automatic Automatic
  has "N10 无动作"       "$T/out" "nothing to do"
  eq  "N10 不通知"       0 "$(notify_count)"
  eq  "N10 状态 default" default "$(st)"
  eq  "N10 不切换"       0 "$(ss_count Automatic)"

  # N6 -- absent in every sweep: one fallback on the first one, no notice, and
  # the run ends on the default location
  reset; run "$NO_CFG" Automatic Home
  has "N6 确认离开"        "$T/out" "we have left"
  eq  "N6 回落一次"        1 "$(ss_count Automatic)"
  eq  "N6 不通知"          0 "$(notify_count)"
  eq  "N6 状态 default"    default "$(st)"

  # N7 -- silent for the whole first pass (8 lookups = 4 sweeps), answered in
  # the confirmation pass: fall back, switch back, silent throughout
  reset; run "$OK_CFG" Automatic Home 8
  has "N7 复探命中并切回"  "$T/out" "the device is back after all"
  eq  "N7 回落了一次"      1 "$(ss_count Automatic)"
  eq  "N7 也切回了一次"    1 "$(ss_count Home)"
  eq  "N7 全程不通知"      0 "$(notify_count)"
  eq  "N7 状态 ok"         ok "$(st)"

  # N8 -- another device took the feature address: fall back AND notify once
  reset; run "$MM_CFG" Automatic Home
  eq  "N8 通知一次"        1 "$(notify_count)"
  has "N8 文案说明换了设备" "$T/out" "not the one expected"
  eq  "N8 回落一次"        1 "$(ss_count Automatic)"
  eq  "N8 状态 default"    default "$(st)"

  # N13 -- the fallback is decided after the first sweep, not after the whole
  # budget, and a device that answers later in the same pass goes straight back
  # without paying the confirmation wait. Silent for the first 2 lookups is one
  # sweep; CONFIRM_DELAY stays at 20s, so a run that needed the confirmation
  # could not finish in less than 20 seconds.
  export WLC_CONFIRM_DELAY=20
  reset; t_begin=$(date +%s); run "$OK_CFG" Automatic Home 2; elapsed=$(( $(date +%s) - t_begin ))
  eq    "N13 首轮扫描未命中就回落" 1 "$(ss_count Automatic)"
  eq    "N13 剩余预算内静默切回"   1 "$(ss_count Home)"
  order "N13 先回落再切回"         "falling back to 'Automatic'" "$T/out" "the device is back after all"
  lt    "N13 没有等确认窗口"       "$elapsed" 20
  eq    "N13 不通知"               0 "$(notify_count)"
  eq    "N13 状态 ok"              ok "$(st)"
  export WLC_CONFIRM_DELAY=1

  # N14 -- moving the decision earlier must not shorten the search: a device
  # that never answers still costs both passes, four sweeps each, so the run
  # stays long while the fallback line is timestamped seconds after the start.
  # CONFIRM_DELAY=0 keeps the wait out of the measurement.
  reset; t_begin=$(date +%s)
  WLC_CONFIG="$NO_CFG" WLC_DEFAULT=Automatic WLC_CUR=Home WLC_CONFIRM_DELAY=0 \
    PATH="$T/bin:$ORIG_PATH" "$SCRIPT" --apply --notify > "$T/out" 2>&1
  elapsed=$(( $(date +%s) - t_begin ))
  has "N14 确认离开"        "$T/out" "we have left"
  eq  "N14 回落一次"        1 "$(ss_count Automatic)"
  ge  "N14 探测预算没缩短"  "$elapsed" 12
  # Both lines have to be there for the delay to mean anything: -1 when missing.
  le  "N14 回落决策提前"    "$(fallback_delay "$T/out")" 3
  ge  "N14 回落时刻可读"    "$(fallback_delay "$T/out")" 0

  # N11 -- an old state file with a miss= line neither suppresses nor blocks
  reset; printf 'state=ok\nmiss=1\n' > "$WLC_STATE"; run "$BR_CFG" Automatic Home
  eq "N11 旧 miss 行被忽略" 1 "$(notify_count)"
  eq "N11 状态写为 broken"  broken "$(st)"

  # N12 -- the older still format: a single bare value
  reset; printf 'away\n' > "$WLC_STATE"; run "$BR_CFG" Automatic Home
  eq "N12 裸值不阻止通知"   1 "$(notify_count)"

  # Hygiene: the runner never read the real location
  eq "全程没有误用真实 scselect" 0 "$(grep -c '^<read>$' "$WLC_SCSELECT_LOG" 2>/dev/null | tr -d ' ')"

  unset WLC_NOTIFY_LOG WLC_SCSELECT_LOG WLC_STATE WLC_CONFIRM_DELAY
  rm -rf "$T"
}

# --- reconfirm: N9, with a target device that is not the feature device ------
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

  # A: the target is a different, live device -- the check must run and pass
  OK_T="$T/okt.env"; mkcfg "$OK_T" "$FIP" "$FMAC" "$F2IP" "$F2MAC"
  reset; run "$OK_T"
  has   "N9 复探命中，静默切回"        "$T/out" "the device is back after all"
  order "N9 先切回原位置，再核对目标"  "switched back to 'Home'" "$T/out" "target device, expect"
  has   "N9 独立目标设备被判在场"      "$T/out" "target present"
  eq    "N9 状态 ok"                   ok "$(st)"
  eq    "N9 全程不通知"                0 "$(notify_count)"
  eq    "N9 回落一次"                  1 "$(ss_count Automatic)"
  eq    "N9 切回一次"                  1 "$(ss_count Home)"

  # B: the target is gone -- still switch back, then broken + one notice
  BR_T="$T/brt.env"; mkcfg "$BR_T" "$FIP" "$FMAC" "$DEAD" "$DEAD_MAC"
  reset; run "$BR_T"
  has "N9b 复探命中，仍切回原位置"    "$T/out" "the device is back after all"
  has "N9b 目标缺席被探测到"          "$T/out" "no answer from"
  eq  "N9b 状态 broken"               broken "$(st)"
  eq  "N9b 通知一次"                  1 "$(notify_count)"
  eq  "N9b 只切回一次"                1 "$(ss_count Home)"

  # Hygiene: the runner never read the real location
  eq "全程没有误用真实 scselect" 0 "$(grep -c '^<read>$' "$WLC_SCSELECT_LOG" 2>/dev/null | tr -d ' ')"

  unset WLC_NOTIFY_LOG WLC_SCSELECT_LOG WLC_STATE WLC_CONFIRM_DELAY
  rm -rf "$T"
}

SUITES="config guard state decision reconfirm"
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
    # A suite that cannot build its fixture has to fail the run: several suites
    # take their devices from the live neighbour table, and on a Mac with no
    # neighbour entry every assertion in them would silently not run at all.
    echo "--- $s: FIXTURE UNUSABLE (rc=$rc): needs one live neighbour entry"
    total_fail=$((total_fail + 1))
  fi
  total_pass=$((total_pass + pass)); total_fail=$((total_fail + fail))
done
echo "=== $total_pass passed, $total_fail failed ($(( $(date +%s) - start ))s) ==="
[ "$total_fail" = 0 ]
