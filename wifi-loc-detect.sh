#!/usr/bin/env bash
#
# wifi-loc-detect.sh - decide which network location the current network
# belongs to, based on whether a characteristic device is present.
#
# Design (settled 2026-09-15):
#   * Each known network is identified by ONE characteristic device: its
#     address and its MAC. The device must be present while the Mac is on that
#     network, whether or not it is the Mac's current gateway (an upstream
#     router is a good choice).
#   * The probe is done at layer 2, without ICMP and without raw sockets:
#     a packet is sent to the address to make the kernel resolve it, then the
#     MAC is read from the neighbour table (`arp -n`). This works even when
#     the device is not the current gateway, and it works in restricted
#     environments where ping/traceroute are unavailable.
#   * Only ONE direction is automatic: a known network is entered
#     (Automatic -> that location). If the characteristic device is absent
#     while in a non-default location, the user is notified instead of being
#     switched, because at layer-2 level that can mean a real configuration
#     change that a script should not guess about.
#   * Switching locations is hot: scselect applies the new configuration
#     immediately, without changing the Wi-Fi network.
#
# Config: ~/.wifi-loc-control/locations.env (override with WLC_CONFIG).
# It is sourced, one numbered group per network:
#
#     LOCATION_1_NAME="Home"
#     LOCATION_1_IP="192.0.2.1"
#     LOCATION_1_MAC="00:00:5e:00:53:01"
#
# The location name is a value, not a variable name, so it may contain spaces
# and non-ASCII characters. Because the file is sourced, it is code: keep it
# owned by you, mode 600, and do not copy one in from an untrusted source.
#
# Usage:
#   ./wifi-loc-detect.sh                    # dry run: print the decision only
#   ./wifi-loc-detect.sh --apply            # actually run scselect
#   ./wifi-loc-detect.sh --apply --notify   # notify once when the network
#                                           # cannot be identified
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
APPLY=0
NOTIFY=0

HELP_LAST_LINE=41   # last line of the comment block shown by --help

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
      sed -n "2,${HELP_LAST_LINE}p" "$0" | sed 's/^# \{0,1\}//'
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
load_config() {
  [[ -f "$CONFIG" ]] || return 1

  # The config is sourced: it is code, not data. Variables are unset right
  # after reading so they cannot leak into anything this script runs later.
  # shellcheck disable=SC1090
  source "$CONFIG" || return 2

  LOC_NAMES=()
  LOC_IPS=()
  LOC_MACS=()
  local n name ip mac
  for (( n = 1; n <= 64; n++ )); do
    name="LOCATION_${n}_NAME"; ip="LOCATION_${n}_IP"; mac="LOCATION_${n}_MAC"
    name="${!name:-}"; ip="${!ip:-}"; mac="${!mac:-}"
    unset "LOCATION_${n}_NAME" "LOCATION_${n}_IP" "LOCATION_${n}_MAC"

    [[ -z "$name$ip$mac" ]] && continue
    if [[ -z "$name" || -z "$ip" || -z "$mac" ]]; then
      log "config: LOCATION_$n is incomplete (need NAME, IP and MAC), skipping"
      continue
    fi
    if [[ ! "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      log "config: LOCATION_$n has an invalid IP '$ip', skipping"
      continue
    fi
    if [[ ! "$mac" =~ ^[0-9a-fA-F]{1,2}(:[0-9a-fA-F]{1,2}){5}$ ]]; then
      log "config: LOCATION_$n has an invalid MAC '$mac', skipping"
      continue
    fi
    # bash 3.2 + set -u errors on ${arr[*]} for an empty array, so guard it.
    if [[ ${#LOC_NAMES[@]} -gt 0 && " ${LOC_NAMES[*]} " == *" $name "* ]]; then
      log "config: duplicate location name '$name', skipping the later one"
      continue
    fi

    LOC_NAMES+=("$name")
    LOC_IPS+=("$ip")
    LOC_MACS+=("$mac")
  done

  [[ ${#LOC_NAMES[@]} -gt 0 ]]
}

# The state file records whether the user has already been told that the
# current network cannot be identified, so a repeatedly triggered agent does
# not repeat the notice. Only the literal value "away" counts: a missing,
# empty or unknown value reads as "not told yet", so the failure direction is
# one notice too many rather than one silently swallowed.
# See docs/2026-09-16-launchagent-design.md.
read_state() {
  [[ -f "$STATE" ]] || return 0
  head -n 1 "$STATE" 2>/dev/null
}

write_state() {
  printf '%s\n' "$1" > "$STATE" 2>/dev/null || log "could not write state file: $STATE"
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

current="$(current_location)"
log "current location: '${current:-?}'"

if ! load_config; then
  log "cannot use config: $CONFIG"
  log "expected a sourced file with groups like LOCATION_1_NAME / _IP / _MAC"
  exit 3
fi

log "loaded ${#LOC_NAMES[@]} location rule(s) from $CONFIG"

matched_location=""
matched_desc=""
identity_mismatch=0

idx=0
while [[ $idx -lt ${#LOC_NAMES[@]} ]]; do
  loc="${LOC_NAMES[$idx]}"
  ip="${LOC_IPS[$idx]}"
  mac="${LOC_MACS[$idx]}"
  idx=$((idx + 1))

  log "probing $ip for '$loc' (expect $mac)"
  if mac_seen="$(probe_device "$ip" "$mac")"; then
    log "  found $mac_seen at $ip -> '$loc'"
    matched_location="$loc"
    matched_desc="$ip $mac_seen"
    break
  elif [[ -n "$mac_seen" ]]; then
    # The address and both MACs stay in this local log line only: nothing
    # identifying goes into a notification (see AGENTS.md, section 8).
    log "  device at $ip has MAC $mac_seen, expected $mac (identity mismatch)"
    identity_mismatch=1
  else
    log "  no answer from $ip"
  fi
done

if [[ -n "$matched_location" ]]; then
  write_state ok
  if [[ "$matched_location" == "$current" ]]; then
    log "already in '$matched_location', nothing to do"
    exit 0
  fi
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
  fi
  exit 0
fi

# No characteristic device answered.
if [[ "$current" == "$DEFAULT_LOCATION" ]]; then
  write_state ok
  log "no characteristic device found; already in '$DEFAULT_LOCATION', nothing to do"
  exit 0
fi

# No characteristic device answered and the current location is not the
# default one: the user is away from every network we know about. Say so
# once per departure.
if [[ "$identity_mismatch" == 1 ]]; then
  away_message="A configured address answered with an unexpected MAC. Check the network settings."
else
  away_message="Cannot identify the current network; the network settings may not match this environment."
fi

if [[ "$NOTIFY" == 1 && "$(read_state)" == "away" ]]; then
  log "away already reported, not notifying again"
else
  if notify "$away_message"; then
    # Remember it only when the user was actually told: a manual run without
    # --notify must not swallow the notice the agent would send later, and a
    # failed delivery must be retried rather than recorded as delivered.
    [[ "$NOTIFY" == 1 ]] && write_state away
  fi
fi
exit 0
