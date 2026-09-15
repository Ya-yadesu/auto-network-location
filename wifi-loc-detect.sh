#!/usr/bin/env bash
#
# wifi-loc-detect.sh - decide which network location the current network
# belongs to, based on whether a characteristic device is present.
#
# Design (settled 2026-09-15):
#   * Each known network is identified by ONE characteristic device: its IP and
#     its MAC. The device must be present in every location state on that
#     network (e.g. the upstream router, which stays reachable whether the Mac
#     is in "Automatic" or in "Home").
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
# Usage:
#   ./wifi-loc-detect.sh                    # dry run: print the decision only
#   ./wifi-loc-detect.sh --apply            # actually run scselect
#   ./wifi-loc-detect.sh --apply --notify   # also notify when the network
#                                           # cannot be identified
#   ./wifi-loc-detect.sh --print-mac <ip>   # helper: show the MAC for an IP,
#                                           # to fill in the config file
#
set -uo pipefail

CONFIG="${WLC_CONFIG:-$HOME/.wifi-loc-control/locations.conf}"
DEFAULT_LOCATION="Automatic"
ATTEMPTS=4          # probe attempts before giving up
RETRY_DELAY=1       # seconds between attempts (settling time after a change)
PROBE_PORT=33445    # UDP port used only to force an ARP lookup
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
      sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
  i=$((i + 1))
done

log() { printf '%s %s\n' "$(date +'[%Y-%m-%d %H:%M:%S]')" "$*"; }

current_location() {
  scselect 2>/dev/null | sed -n 's/^ \* .*(\(.*\))$/\1/p'
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

# Normalize a MAC for comparison. macOS ships bash 3.2, which has no
# ${var,,} lowercase expansion, so use tr.
norm_mac() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

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

read_config() {
  local line
  [[ -f "$CONFIG" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"                       # strip comments
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -z "$line" ]] && continue
    printf '%s\n' "$line"
  done < "$CONFIG"
}

notify() {
  local message="$1"
  log "NOTIFY: $message"
  if [[ "$NOTIFY" == 1 ]]; then
    osascript -e "display notification \"$message\" with title \"WiFiLocControl\"" \
      >/dev/null 2>&1 || log "notification failed"
  fi
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

if [[ ! -f "$CONFIG" ]]; then
  log "config not found: $CONFIG"
  log "create it with lines like: 192.0.2.1  00:00:5e:00:53:01 = Home"
  exit 3
fi

matched_location=""
matched_desc=""
identity_mismatch=""

while IFS= read -r line; do
  # Expected: <ip> <mac> = <location>   |   DEFAULT = <location>
  if [[ "$line" =~ ^DEFAULT[[:space:]]*=[[:space:]]*(.+)$ ]]; then
    DEFAULT_LOCATION="${BASH_REMATCH[1]}"
    continue
  fi
  if [[ "$line" =~ ^([0-9a-fA-F:.]+)[[:space:]]+([0-9a-fA-F:]{11,17})[[:space:]]*=[[:space:]]*(.+)$ ]]; then
    ip="${BASH_REMATCH[1]}"; mac="${BASH_REMATCH[2]}"; loc="${BASH_REMATCH[3]}"
  else
    log "skipping unparsable config line: '$line'"
    continue
  fi

  log "probing $ip for $loc (expect $mac)"
  if mac_seen="$(probe_device "$ip" "$mac")"; then
    log "  found $mac_seen at $ip -> '$loc'"
    matched_location="$loc"
    matched_desc="$ip $mac_seen"
    break
  elif [[ -n "$mac_seen" ]]; then
    log "  device at $ip has MAC $mac_seen, expected $mac (identity mismatch)"
    identity_mismatch="$ip $mac_seen"
  else
    log "  no answer from $ip"
  fi
done < <(read_config)

if [[ -n "$matched_location" ]]; then
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
  log "no characteristic device found; already in '$DEFAULT_LOCATION', nothing to do"
  exit 0
fi

if [[ -n "$identity_mismatch" ]]; then
  notify "A device answered at $identity_mismatch, but its MAC is not the one configured. Check the network settings."
else
  notify "Cannot identify the current network; the network settings may not match this environment."
fi
exit 0
