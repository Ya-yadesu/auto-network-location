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
#         to the default location at once, so the machine works on whatever
#         network it is on, then look once more inside the same run after 15
#         seconds: if the device turns up, that was a single bad reading and we
#         go straight back, silently;
#       - the location matches but its TARGET device is gone -> notify and
#         leave the settings alone, because the network itself changed and
#         switching would silently replace them with DHCP.
#   * Switching locations is hot: scselect applies the new configuration
#     immediately, without changing the Wi-Fi network.
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

current_location() {
  scselect 2>/dev/null | sed -n 's/^ \* .*(\(.*\))$/\1/p'
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

# Probe one characteristic device.
#   exit 0 + prints MAC  -> present and MAC matches the configured one
#   exit 1 + prints MAC  -> present but a different device (identity mismatch)
#   exit 1 + no output   -> not present
probe_device() {
  local ip="$1" want_mac="$2" attempt mac
  want_mac="$(norm_mac "$want_mac")"
  for (( attempt = 1; attempt <= ATTEMPTS; attempt++ )); do
    mac="$(arp_lookup "$ip")"
    if [[ -z "$mac" ]]; then
      trigger_arp "$ip"
      sleep "$RETRY_DELAY"
      mac="$(arp_lookup "$ip")"
    fi
    if [[ -n "$mac" ]]; then
      printf '%s\n' "$mac"
      [[ "$(norm_mac "$mac")" == "$want_mac" ]] && return 0
      return 1
    fi
    [[ $attempt -lt $ATTEMPTS ]] && sleep "$RETRY_DELAY"
  done
  return 1
}

# Load the rules from the sourced config file into parallel arrays.
# Returns 0 on success, non-zero when the file is missing or unusable.
# 0-255 in each octet. A shape-only check accepts 999.1.1.1 and then spends the
# whole probe budget on an address that cannot exist.
valid_ipv4() {
  local ip="$1" oct
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  local IFS=.
  for oct in $ip; do
    (( 10#$oct <= 255 )) || return 1   # 10# forces base 10, so "08" is eight
  done
  return 0
}

load_config() {
  [[ -f "$CONFIG" ]] || return 1

  # The config is sourced: it is code, not data. Variables are unset right
  # after reading so they cannot leak into anything this script runs later.
  # shellcheck disable=SC1090
  source "$CONFIG" || return 2

  LOC_NAMES=()
  LOC_IPS=()
  LOC_MACS=()
  LOC_TARGET_IPS=()
  LOC_TARGET_MACS=()
  local n name ip mac tip tmac
  for (( n = 1; n <= 64; n++ )); do
    name="LOCATION_${n}_NAME"; ip="LOCATION_${n}_IP"; mac="LOCATION_${n}_MAC"
    tip="LOCATION_${n}_TARGET_IP"; tmac="LOCATION_${n}_TARGET_MAC"
    name="${!name:-}"; ip="${!ip:-}"; mac="${!mac:-}"
    tip="${!tip:-}"; tmac="${!tmac:-}"
    unset "LOCATION_${n}_NAME" "LOCATION_${n}_IP" "LOCATION_${n}_MAC" \
          "LOCATION_${n}_TARGET_IP" "LOCATION_${n}_TARGET_MAC"

    [[ -z "$name$ip$mac$tip$tmac" ]] && continue
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

# The state file records what the user has been told about the current state:
#   state=default|ok|broken
# Only the literal value "broken" counts as "already told": a missing, empty or
# unknown value reads as "not told yet", so the failure direction is one notice
# too many rather than one silently swallowed. Older formats -- a bare value, or
# a miss= line from the two-round valve this replaced -- also read as "not told
# yet", so no migration is needed.
# See docs/2026-09-16-decision-model-design.md.
read_state() {
  [[ -f "$STATE" ]] || return 0
  sed -n 's/^state=//p' "$STATE" 2>/dev/null | head -n 1
}

# write_state <state>
# Written through a temporary file in the same directory: a reader must never
# see a half-written state, because two triggers can overlap.
write_state() {
  local tmp="${STATE}.tmp.$$"
  if printf 'state=%s\n' "$1" > "$tmp" 2>/dev/null; then
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
current="${WLC_CUR:-$(current_location)}"
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

# Probe every rule. Sets matched_* and returns 0 as soon as one matches.
probe_rules() {
  local idx=0 loc ip mac seen
  while [[ $idx -lt ${#LOC_NAMES[@]} ]]; do
    loc="${LOC_NAMES[$idx]}"
    ip="${LOC_IPS[$idx]}"
    mac="${LOC_MACS[$idx]}"

    log "probing $ip for '$loc' (expect $mac)"
    if seen="$(probe_device "$ip" "$mac")"; then
      log "  found $seen at $ip -> '$loc'"
      matched_location="$loc"
      matched_idx="$idx"
      matched_desc="$ip $seen"
      return 0
    elif [[ -n "$seen" ]]; then
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

# --- Leaving. Go to the default location first: it is DHCP, so the machine
# --- works on whatever network it is actually on. A single reading can be a
# --- transient, so look once more inside this same run -- if the device turns
# --- up, we never left and we go straight back.
# --- See the design, section 8.
leave_to_default() {
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

  sleep "$CONFIRM_DELAY"
  matched_location=""
  matched_idx=-1
  matched_desc=""
  feature_state="absent"
  if probe_rules; then
    log "the device is back after all; switching back to '$matched_location'"
    if ! scselect "$matched_location"; then
      log "scselect '$matched_location' failed"
      exit 1
    fi
    log "switched back to '$matched_location'"
    current="$matched_location"
    return 0
  fi

  # Really gone. Stay quiet: the machine is already usable and this happens on
  # every departure. Only a device that was replaced is worth telling the user.
  log "feature device still $feature_state after ${CONFIRM_DELAY}s; we have left"
  if [[ "$feature_state" == "mismatch" ]]; then
    notify "The device at the configured address is not the one expected. Switched to the default location."
  fi
  write_state default
  exit 0
}

if ! probe_rules; then
  if [[ "$current" == "$DEFAULT_LOCATION" ]]; then
    log "not on a known network (feature device $feature_state); already in '$DEFAULT_LOCATION', nothing to do"
    write_state default
    exit 0
  fi
  # Either exits (we really left) or returns with matched_* set because the
  # device came back; in that case fall through to the target check.
  leave_to_default
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
