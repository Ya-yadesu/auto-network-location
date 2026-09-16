#!/bin/bash
#
# Self-test for wifi-loc-detect.sh.
#
# Nothing here touches the machine: the script under test only ever calls
# `scselect`, `osascript` and `arp`, and every suite stubs the ones it needs:
#
#   osascript  records that it was called instead of delivering a notice
#   scselect   records its argument instead of changing this Mac's location
#   arp        only in the two "absent device" suites: the first 8 lookups of
#              the feature address report nothing, which is exactly one failing
#              probe_device (4 attempts x 2 lookups)
#
# Suites (WLC_CONFIRM_DELAY is forced to 1 so the 15s in-run confirmation does
# not dominate the runtime):
#
#   config     10 assertions  the target fields: defaults and validation
#   state      14 assertions  the notice state machine, minus the decision
#   decision   38 assertions  the decision table: N1-N8, N10-N12   (~2 minutes)
#   reconfirm  13 assertions  N9: the in-run confirmation when the target
#                             device is a different box. The decision suite
#                             cannot see this: its target IS the feature
#                             device, so the run takes the "one device answers
#                             for both" shortcut and never probes a target.
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
  [ -z "$FIP" ] && { echo "no live neighbour entry to build the fixture from" >&2; return 1; }

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

  unset WLC_NOTIFY_LOG WLC_SCSELECT_LOG WLC_STATE WLC_CONFIRM_DELAY
  rm -rf "$T"
}

# --- decision: the decision table, N1-N8 and N10-N12 -------------------------
suite_decision() {
  echo "### decision"
  local T; T=$(mk_stubs); pass=0; fail=0
  mkdir -p "$T/arpbin"
  export WLC_NOTIFY_LOG="$T/notify.log" WLC_SCSELECT_LOG="$T/ss.log" WLC_STATE="$T/state"
  export WLC_CONFIRM_DELAY=1
  pick_devices
  [ -z "$FIP" ] && { echo "no live neighbour entry to build the fixture from" >&2; return 1; }

  # Opt-in arp stub: the first 8 lookups of the feature address report nothing,
  # so the first probe round fails and the post-fallback round succeeds. Eight
  # is exactly what one failing probe_device costs: 4 attempts x 2 lookups.
  # Match the exact argument: a substring match would also swallow the target.
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
  # $4 = "arp" prepends the stub that makes the first probe round fail.
  run() { local p="$T/bin:$ORIG_PATH"; [ "${4:-}" = "arp" ] && p="$T/arpbin:$p"
          WLC_CONFIG="$1" WLC_DEFAULT="$2" WLC_CUR="$3" PATH="$p" \
            "$SCRIPT" --apply --notify > "$T/out" 2>&1; }
  reset() { : > "$WLC_NOTIFY_LOG"; : > "$WLC_SCSELECT_LOG"; rm -f "$WLC_STATE" "$T/arpcount"; }

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

  # N6 -- feature unconfirmed, still absent on the retry: one silent fallback
  reset; run "$NO_CFG" Automatic Home
  has "N6 确认离开"        "$T/out" "we have left"
  eq  "N6 回落一次"        1 "$(ss_count Automatic)"
  eq  "N6 不通知"          0 "$(notify_count)"
  eq  "N6 状态 default"    default "$(st)"

  # N7 -- first round missing but the retry hits: fall back, switch back, silent
  reset; run "$OK_CFG" Automatic Home arp
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

SUITES="config state decision reconfirm"
if [ $# -gt 0 ]; then
  case " $SUITES " in
    *" $1 "*) SUITES="$1" ;;
    *) echo "unknown suite: $1 (have:$SUITES)" >&2; exit 2 ;;
  esac
fi

start=$(date +%s)
for s in $SUITES; do
  t0=$(date +%s)
  "suite_$s"
  rc=$?
  echo "--- $s: $pass passed, $fail failed ($(( $(date +%s) - t0 ))s)"
  [ "$rc" != 0 ] && echo "--- $s: fixture unusable (rc=$rc)"
  total_pass=$((total_pass + pass)); total_fail=$((total_fail + fail))
done
echo "=== $total_pass passed, $total_fail failed ($(( $(date +%s) - start ))s) ==="
[ "$total_fail" = 0 ]
