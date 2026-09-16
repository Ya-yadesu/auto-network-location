#!/usr/bin/env bash
#
# wifi-loc-detect.sh - decide which network location the current network
# belongs to, based on whether a characteristic device is present.
#
# Design (settled 2026-09-16):
#   * Each known network is identified by ONE characteristic device: its
#     address and its MAC. The device must be present while the Mac is on that
#     network, whether or not it is the Mac's current gateway (an upstream
#     router is a good choice).
#   * The probe is done at layer 2, without ICMP and without raw sockets:
#     a packet is sent to the address to make the kernel resolve it, then the
#     MAC is read from the neighbour table (`arp -n`). This works even when
#     the device is not the current gateway, and it works in restricted
#     environments where ping/traceroute are unavailable.
#   * A second, optional device answers a different question: the TARGET
#     device, normally the one this location's own settings depend on (its
#     gateway or DNS). It defaults to the characteristic device, so a network
#     that needs no separate check needs no separate configuration.
#   * Both directions are automatic, but only leaving is unconditional:
#       - the characteristic device is present -> enter that location;
#       - it is gone, or the address now belongs to another device -> fall back
#         to the default location as soon as the first sweep is over, so the
#         machine works on whatever network it is on. The rest of the probe
#         budget still runs, in this same run: if the device answers there, it
#         was a single bad reading and we go straight back, silently; if it does
#         not, the run looks once more after a delay and then leaves for good;
#       - the location matches but its TARGET device is gone -> notify and
#         leave the settings alone, because the network itself changed and
#         switching would silently replace them with DHCP.
#   * Switching locations is hot: scselect applies the new configuration
#     immediately, without changing the Wi-Fi network.
#   * A location is never switched on a guess: if the current location cannot be
#     read (scselect failing, or output this script does not recognise), the run
#     exits non-zero without calling scselect at all. Every scselect rewrites
#     SystemConfiguration and therefore triggers another run, so guessing there
#     would turn a broken read into a switch, and a re-trigger, once a minute.
#
# Config: ~/.wifi-loc-control/locations.env (override with WLC_CONFIG).
# It is sourced, one numbered group per network:
#
#     LOCATION_1_NAME="Home"
#     LOCATION_1_IP="192.0.2.1"
#     LOCATION_1_MAC="00:00:5e:00:53:01"
#     # optional; defaults to the device above
#     LOCATION_1_TARGET_IP="192.0.2.100"
#     LOCATION_1_TARGET_MAC="00:00:5e:00:53:02"
#
# The location name is a value, not a variable name, so it may contain spaces
# and non-ASCII characters. Because the file is sourced, it is code: keep it
# owned by you, mode 600, and do not copy one in from an untrusted source.
#
# Usage:
#   ./wifi-loc-detect.sh                    # dry run: print the decision only
#   ./wifi-loc-detect.sh --apply            # actually run scselect
#   ./wifi-loc-detect.sh --apply --notify   # notify when the network no longer
#                                           # matches the settings (leaving is
#                                           # silent unless a device changed)
#   ./wifi-loc-detect.sh --print-mac <ip>   # helper: show the MAC for an IP,
#                                           # to fill in the config file
#
set -uo pipefail

CONFIG="${WLC_CONFIG:-$HOME/.wifi-loc-control/locations.env}"
DEFAULT_LOCATION="${WLC_DEFAULT:-Automatic}"
ATTEMPTS=4          # probe attempts before giving up
RETRY_DELAY=1       # seconds between attempts (settling time after a change)
PROBE_PORT=33445    # UDP port used only to force an ARP lookup
STATE="${WLC_STATE:-$HOME/.wifi-loc-control/state}"
CONFIRM_DELAY="${WLC_CONFIRM_DELAY:-15}"   # second look after a fallback, seconds
APPLY=0
NOTIFY=0

i=1
while [[ $i -le $# ]]; do
  arg="${!i}"
  case "$arg" in
    --apply)  APPLY=1 ;;
    --notify) NOTIFY=1 ;;
    --print-mac)
      i=$((i + 1))
      [[ $i -gt $# ]] && { echo "--print-mac needs an IP" >&2; exit 2; }
      PRINT_MAC_IP="${!i}" ;;
    -h|--help)
      # Print the leading comment block. Stopping at the first code line
      # instead of a fixed line number means editing the header can no longer
      # silently truncate or overrun the help text.
      awk 'NR > 1 && /^set -uo pipefail/ { exit }
           NR > 1 { sub(/^# ?/, ""); print }' "$0"
      exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
  i=$((i + 1))
done

log() { printf '%s %s\n' "$(date +'[%Y-%m-%d %H:%M:%S]')" "$*"; }

# The current location, or non-zero when it cannot be determined: 1 when
# `scselect` itself failed, 2 when its output did not match what this script
# expects. Both mean the same thing to the caller -- unknown -- and unknown must
# not be guessed at. The only use of this value is deciding whether to call
# `scselect`, and every `scselect` rewrites SystemConfiguration and therefore
# triggers another run: measured 2026-09-16, even `scselect` naming the location
# we are already in does it. Treating a broken read as "not in the default
# location" would therefore switch, and re-trigger, once a minute forever.
current_location() {
  local out parsed
  out="$(scselect 2>/dev/null)" || return 1
  parsed="$(printf '%s\n' "$out" | sed -n 's/^ \* .*(\(.*\))$/\1/p')"
  [[ -n "$parsed" ]] || return 2
  printf '%s\n' "$parsed"
}

# Normalize a MAC so that equivalent spellings compare equal. Two things can
# differ between a hand-written config and `arp -n` output: the case, and
# leading zeros, which arp omits ("0:0:5e:0:53:1" vs "00:00:5e:00:53:01").
# macOS ships bash 3.2, which has no ${var,,} lowercase expansion, so use tr.
# One pass over the six octets; no external command beyond tr.
norm_mac() {
  local mac out="" oct sep=""
  mac="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  local IFS=:
  for oct in $mac; do
    [[ ${#oct} -eq 1 ]] && oct="0$oct"
    out="$out$sep$oct"
    sep=":"
  done
  printf '%s' "$out"
}

# Send one packet to <ip> so the kernel performs an ARP lookup and fills the
# neighbour table. A closed UDP socket is enough: what matters is that the
# packet forces resolution, and no answer is required. This avoids ping and
# other raw-socket tools, which are not always available (and are blocked in
# the agent sandbox).
# NOTE: this deliberately contacts the configured address on udp/PROBE_PORT.
trigger_arp() {
  local ip="$1"
  ( : > "/dev/udp/$ip/$PROBE_PORT" ) 2>/dev/null
  return 0
}

# Read the MAC for <ip> from the kernel neighbour table, or nothing when the
# entry is missing or still "incomplete".
arp_lookup() {
  local ip="$1" line
  line="$(arp -n "$ip" 2>/dev/null)" || return 1
  [[ "$line" == *"(incomplete)"* ]] && return 1
  printf '%s\n' "$line" | sed -n 's/.* at \([0-9a-fA-F:]\{11,17\}\) on .*/\1/p'
}

# One attempt at one device. Prints the MAC that answered, if any:
#   exit 0 + prints MAC -> present and MAC matches the configured one
#   exit 1 + prints MAC -> present but a different device (identity mismatch)
#   exit 2 + no output  -> nothing in the neighbour table
# A missing entry is not free: the packet is sent first, because the kernel only
# resolves on demand, and then the table is read again after RETRY_DELAY. A
# stale entry and a departed network look exactly the same on the first read,
# which is why the outgoing packet comes before the verdict.
probe_once() {
  local ip="$1" want_mac="$2" mac
  want_mac="$(norm_mac "$want_mac")"
  mac="$(arp_lookup "$ip")"
  if [[ -z "$mac" ]]; then
    trigger_arp "$ip"
    sleep "$RETRY_DELAY"
    mac="$(arp_lookup "$ip")"
  fi
  [[ -z "$mac" ]] && return 2
  printf '%s\n' "$mac"
  [[ "$(norm_mac "$mac")" == "$want_mac" ]] && return 0
  return 1
}

# Probe one device over the whole attempt budget. Used for the target device,
# where nothing can be decided before the budget is out: its answer is the
# difference between "fine" and "notify". The characteristic device is searched
# sweep by sweep instead (probe_sweep), because there the first miss already
# means the machine is standing on settings that do not fit.
probe_device() {
  local ip="$1" want_mac="$2" attempt rc
  for (( attempt = 1; attempt <= ATTEMPTS; attempt++ )); do
    probe_once "$ip" "$want_mac"
    rc=$?
    [[ $rc -eq 0 ]] && return 0
    [[ $rc -eq 1 ]] && return 1
    [[ $attempt -lt $ATTEMPTS ]] && sleep "$RETRY_DELAY"
  done
  return 1
}

# Load the rules from the sourced config file into parallel arrays.
# Returns 0 on success, non-zero when the file is missing or unusable.
# Four dotted octets, each 0-255 written in plain decimal, and a unicast first
# octet. Two measured reasons for being stricter than "looks like an IPv4":
#
#   * leading zeros are read as octal by arp and by the resolver. 010 is eight,
#     so an address ending in .010 was measured to resolve to the .8 address --
#     a different device than the one written in the config, while .01 quietly
#     resolved to the .1 that was meant. 08 is not even octal, and the resolver
#     refuses it outright; a shape-only check with 10# would call it eight.
#   * arp -n 0.0.0.0 was measured to return the *gateway's* entry, so a config
#     with 0.0.0.0 would match the gateway MAC on whatever network the Mac is
#     on. Multicast and the broadcast address are just as meaningless here.
valid_ipv4() {
  local ip="$1" oct first="" n=0
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  local IFS=.
  for oct in $ip; do
    n=$((n + 1))
    [[ ${#oct} -gt 1 && "${oct:0:1}" == "0" ]] && return 1
    (( 10#$oct <= 255 )) || return 1
    [[ $n -eq 1 ]] && first="$oct"
  done
  (( 10#$first >= 1 && 10#$first <= 223 ))
}

load_config() {
  [[ -f "$CONFIG" ]] || return 1

  # The config is sourced: it is code, not data. Copy the groups out first, and
  # only then remove every LOCATION_* variable in one sweep -- not just the five
  # known fields of groups 1-64. A config may carry LOCATION_65_* or any other
  # name with that prefix, and `log` runs `date` as a child process, which
  # inherits whatever is still exported: measured 2026-09-16, with an `export`
  # in the config, LOCATION_65_NAME reached that child before this sweep existed.
  # shellcheck disable=SC1090
  source "$CONFIG" || return 2

  local n name ip mac tip tmac v gi
  local g_idx=() g_names=() g_ips=() g_macs=() g_tips=() g_tmacs=()
  for (( n = 1; n <= 64; n++ )); do
    local vn="LOCATION_${n}_NAME" vi="LOCATION_${n}_IP" vm="LOCATION_${n}_MAC"
    local vt="LOCATION_${n}_TARGET_IP" vc="LOCATION_${n}_TARGET_MAC"
    name="${!vn:-}"; ip="${!vi:-}"; mac="${!vm:-}"; tip="${!vt:-}"; tmac="${!vc:-}"
    [[ -z "$name$ip$mac$tip$tmac" ]] && continue
    g_idx+=("$n"); g_names+=("$name"); g_ips+=("$ip")
    g_macs+=("$mac"); g_tips+=("$tip"); g_tmacs+=("$tmac")
  done
  for v in $(compgen -v | grep '^LOCATION_'); do unset "$v"; done

  LOC_NAMES=()
  LOC_IPS=()
  LOC_MACS=()
  LOC_TARGET_IPS=()
  LOC_TARGET_MACS=()
  for (( gi = 0; gi < ${#g_names[@]}; gi++ )); do
    n="${g_idx[$gi]}"; name="${g_names[$gi]}"; ip="${g_ips[$gi]}"
    mac="${g_macs[$gi]}"; tip="${g_tips[$gi]}"; tmac="${g_tmacs[$gi]}"

    if [[ -z "$name" || -z "$ip" || -z "$mac" ]]; then
      log "config: LOCATION_$n is incomplete (need NAME, IP and MAC), skipping"
      continue
    fi
    if ! valid_ipv4 "$ip"; then
      log "config: LOCATION_$n has an invalid IP '$ip', skipping"
      continue
    fi
    if [[ ! "$mac" =~ ^[0-9a-fA-F]{1,2}(:[0-9a-fA-F]{1,2}){5}$ ]]; then
      log "config: LOCATION_$n has an invalid MAC '$mac', skipping"
      continue
    fi

    # The target device answers a different question than the feature device:
    # "is this still the network my settings were written for?" It defaults to
    # the feature device, so a network that needs no separate check needs no
    # separate configuration. See docs/2026-09-16-decision-model-design.md.
    [[ -z "$tip" ]] && tip="$ip"
    [[ -z "$tmac" ]] && tmac="$mac"
    if ! valid_ipv4 "$tip"; then
      log "config: LOCATION_$n has an invalid TARGET_IP '$tip', skipping"
      continue
    fi
    if [[ ! "$tmac" =~ ^[0-9a-fA-F]{1,2}(:[0-9a-fA-F]{1,2}){5}$ ]]; then
      log "config: LOCATION_$n has an invalid TARGET_MAC '$tmac', skipping"
      continue
    fi

    # Compare name by name. Testing the joined list for a substring would
    # wrongly drop "Home" when "Home Office" came first, and both are valid
    # names (a location name may contain spaces).
    local i dup=0
    for (( i = 0; i < ${#LOC_NAMES[@]}; i++ )); do
      [[ "${LOC_NAMES[$i]}" == "$name" ]] && { dup=1; break; }
    done
    if [[ "$dup" == 1 ]]; then
      log "config: duplicate location name '$name', skipping the later one"
      continue
    fi

    LOC_NAMES+=("$name")
    LOC_IPS+=("$ip")
    LOC_MACS+=("$mac")
    LOC_TARGET_IPS+=("$tip")
    LOC_TARGET_MACS+=("$tmac")
    log "config: rule '$name': feature $ip, target $tip"
  done

  [[ ${#LOC_NAMES[@]} -gt 0 ]]
}

# read_state / read_pending: the two things the state file records.
#   state=default|ok|broken  where we are, and what has been reported about it
#   pending=feature-mismatch a notice that is owed because delivery failed
# See docs/2026-09-16-decision-model-design.md.
read_state() {
  [[ -f "$STATE" ]] || return 0
  sed -n 's/^state=//p' "$STATE" 2>/dev/null | head -n 1
}

read_pending() {
  [[ -f "$STATE" ]] || return 0
  sed -n 's/^pending=//p' "$STATE" 2>/dev/null | head -n 1
}

# write_state <state> [pending]
# Written through a temporary file in the same directory: a reader must never
# see a half-written state, because two triggers can overlap. Omitting the
# second argument clears any pending notice.
write_state() {
  local tmp="${STATE}.tmp.$$"
  if { printf 'state=%s\n' "$1"
       if [[ -n "${2:-}" ]]; then printf 'pending=%s\n' "$2"; fi
     } > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$STATE" 2>/dev/null || { rm -f "$tmp"; log "could not write state file: $STATE"; }
  else
    log "could not write state file: $STATE"
  fi
}

# Print the notice to the log and, with --notify, deliver it. Returning
# non-zero for a failed delivery lets the caller avoid recording a notice the
# user never received, so the next trigger tries again.
notify() {
  local message="$1"
  log "NOTIFY: $message"
  if [[ "$NOTIFY" == 1 ]]; then
    if ! osascript -e "display notification \"$message\" with title \"auto-network-location\"" \
         >/dev/null 2>&1; then
      log "notification failed"
      return 1
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------

# Helper mode: report the MAC for an IP, to fill in the config file. Used while
# setting up a new location: connect to that network, then run this.
if [[ -n "${PRINT_MAC_IP:-}" ]]; then
  mac="$(arp_lookup "$PRINT_MAC_IP")"
  if [[ -z "$mac" ]]; then
    trigger_arp "$PRINT_MAC_IP"
    sleep 1
    mac="$(arp_lookup "$PRINT_MAC_IP")"
  fi
  if [[ -n "$mac" ]]; then
    printf '%s  %s\n' "$PRINT_MAC_IP" "$mac"
    exit 0
  fi
  echo "no answer from $PRINT_MAC_IP" >&2
  exit 1
fi

# WLC_CUR lets the decision logic be tested without changing the machine's
# real location; it is not meant to be set in normal use.
if [[ -n "${WLC_CUR:-}" ]]; then
  current="$WLC_CUR"
else
  current="$(current_location)"; rc=$?
  if [[ "$rc" != 0 ]]; then
    if [[ "$rc" == 1 ]]; then why="scselect failed"; else why="its output did not parse"; fi
    log "cannot determine the current location ($why); not switching"
    exit 1
  fi
fi
log "current location: '${current:-?}'"

if ! load_config; then
  log "cannot use config: $CONFIG"
  log "expected a sourced file with groups like LOCATION_1_NAME / _IP / _MAC"
  exit 3
fi

log "loaded ${#LOC_NAMES[@]} location rule(s) from $CONFIG"

matched_location=""
matched_idx=-1
matched_desc=""
feature_state="absent"   # absent | mismatch -- only meaningful when nothing matched

# One sweep: one attempt at every rule. Sets matched_* and returns 0 as soon as
# a rule matches. feature_state keeps the reason the sweep failed -- "absent" or
# "mismatch" -- for the log line and for the one notice that depends on it.
probe_sweep() {
  local idx=0 loc ip mac seen rc
  feature_state="absent"
  while [[ $idx -lt ${#LOC_NAMES[@]} ]]; do
    loc="${LOC_NAMES[$idx]}"
    ip="${LOC_IPS[$idx]}"
    mac="${LOC_MACS[$idx]}"

    log "probing $ip for '$loc' (expect $mac)"
    seen="$(probe_once "$ip" "$mac")"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      log "  found $seen at $ip -> '$loc'"
      matched_location="$loc"
      matched_idx="$idx"
      matched_desc="$ip $seen"
      return 0
    elif [[ $rc -eq 1 ]]; then
      # The address and both MACs stay in this local log line only: nothing
      # identifying goes into a notification (see AGENTS.md, section 8).
      log "  device at $ip has MAC $seen, expected $mac (identity mismatch)"
      feature_state="mismatch"
    else
      log "  no answer from $ip"
    fi
    idx=$((idx + 1))
  done
  return 1
}

# --- Leaving. While we are standing in a known location, the first sweep
# --- without an answer is already enough to fall back: the default location is
# --- DHCP, so the machine is usable on whatever network it is actually on, and
# --- waiting out the rest of the budget only prolongs the time spent on
# --- settings that do not fit. The budget itself is not shortened -- the
# --- remaining sweeps run right here, in this same run, as the first chance to
# --- come back -- and one more sweep after CONFIRM_DELAY is the last chance.
# --- See the design, section 8.
switch_back() {
  log "the device is back after all; switching back to '$matched_location'"
  if ! scselect "$matched_location"; then
    log "scselect '$matched_location' failed"
    exit 1
  fi
  log "switched back to '$matched_location'"
  current="$matched_location"
}

fell_back=0
sweep=1
while [[ $sweep -le $ATTEMPTS ]]; do
  if probe_sweep; then
    # The device answered somewhere in this pass. If we had already fallen back
    # for it, go straight back; nobody needs to hear about a transient reading.
    [[ $fell_back -eq 1 ]] && switch_back
    break
  fi
  if [[ $sweep -eq 1 && "$current" != "$DEFAULT_LOCATION" ]]; then
    log "not on a known network (feature device $feature_state); falling back to '$DEFAULT_LOCATION'"
    if [[ "$APPLY" != 1 ]]; then
      log "dry run: would switch to '$DEFAULT_LOCATION' (use --apply)"
      exit 0
    fi
    if ! scselect "$DEFAULT_LOCATION"; then
      log "scselect '$DEFAULT_LOCATION' failed"
      exit 1
    fi
    log "switched to '$DEFAULT_LOCATION'"
    fell_back=1
  fi
  [[ $sweep -lt $ATTEMPTS ]] && sleep "$RETRY_DELAY"
  sweep=$((sweep + 1))
done

if [[ -z "$matched_location" ]]; then
  if [[ "$fell_back" != 1 ]]; then
    # Nothing to switch, but a notice may still be owed from an earlier run: the
    # user has not been told that the configured address changed hands. Retry it
    # whenever the anomaly is observable from here, which is when this branch
    # sees the same mismatch again.
    pend="$(read_pending)"
    if [[ "$feature_state" == "mismatch" && "$pend" == "feature-mismatch" ]]; then
      log "still in '$DEFAULT_LOCATION' with the device changed; retrying the notice"
      if notify "The device at the configured address is not the one expected. Switched to the default location."; then
        pend=""
      fi
    fi
    log "not on a known network (feature device $feature_state); already in '$DEFAULT_LOCATION', nothing to do"
    write_state default "$pend"
    exit 0
  fi

  log "feature device $feature_state in $ATTEMPTS sweeps; looking once more in ${CONFIRM_DELAY}s"
  sleep "$CONFIRM_DELAY"
  sweep=1
  while [[ $sweep -le $ATTEMPTS ]]; do
    if probe_sweep; then
      switch_back
      break
    fi
    [[ $sweep -lt $ATTEMPTS ]] && sleep "$RETRY_DELAY"
    sweep=$((sweep + 1))
  done
fi

if [[ -z "$matched_location" ]]; then
  # Really gone. Stay quiet: the machine is already usable and this happens on
  # every departure. Only a device that was replaced is worth telling the user.
  log "feature device still $feature_state after ${CONFIRM_DELAY}s; we have left"
  if [[ "$feature_state" == "mismatch" ]]; then
    # The one departure worth a notice (section 7). If delivery fails, record the
    # notice as owed rather than writing it down as delivered: `state` says where
    # we are, `pending` says what the user has not been told yet.
    if notify "The device at the configured address is not the one expected. Switched to the default location."; then
      write_state default
    else
      write_state default feature-mismatch
    fi
  else
    write_state default
  fi
  exit 0
fi

# --- On a known network. The target device answers a second question: is this
# --- still the network our settings were written for?
if [[ "$matched_location" != "$current" ]]; then
  log "identified network as '$matched_location' ($matched_desc)"
  if [[ "$APPLY" == 1 ]]; then
    if scselect "$matched_location"; then
      log "switched to '$matched_location'"
    else
      log "scselect '$matched_location' failed"
      exit 1
    fi
  else
    log "dry run: would switch to '$matched_location' (use --apply)"
    exit 0
  fi
else
  log "already in '$matched_location', nothing to do"
fi

tip="${LOC_TARGET_IPS[$matched_idx]}"
tmac="${LOC_TARGET_MACS[$matched_idx]}"
if [[ "$tip" == "${LOC_IPS[$matched_idx]}" ]] \
   && [[ "$(norm_mac "$tmac")" == "$(norm_mac "${LOC_MACS[$matched_idx]}")" ]]; then
  # Default case: both roles are the same device, so the probe above already
  # answered for both. Do not probe twice.
  target_ok=1
  log "target device is the feature device; its answer stands for both"
else
  log "probing $tip for '$matched_location' (target device, expect $tmac)"
  if tmac_seen="$(probe_device "$tip" "$tmac")"; then
    log "  found $tmac_seen at $tip -> target present"
    target_ok=1
  elif [[ -n "$tmac_seen" ]]; then
    log "  device at $tip has MAC $tmac_seen, expected $tmac (target identity mismatch)"
    target_ok=0
  else
    log "  no answer from $tip"
    target_ok=0
  fi
fi

if [[ "$target_ok" == 1 ]]; then
  log "target device present; settings match this network"
  write_state ok
  exit 0
fi

# The network itself changed under us. Tell the user; do not quietly swap
# their static settings for DHCP.
if [[ "$NOTIFY" == 1 && "$(read_state)" == "broken" ]]; then
  log "broken already reported, not notifying again"
  exit 0
fi
if notify "The current network no longer matches the configured settings. Check the network settings."; then
  [[ "$NOTIFY" == 1 ]] && write_state broken
fi
exit 0
