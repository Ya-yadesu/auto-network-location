# auto-network-location

Switches the macOS [network location](https://support.apple.com/en-us/105129)
automatically, so that connecting to a known network applies that network's
settings (static IPv4, gateway, DNS, IPv6 state) without doing anything by hand.

This is the macOS equivalent of what iPhone and Windows do per Wi-Fi network.
macOS cannot do it natively: IPv4/DNS settings exist only per *network service*,
never per SSID, so a static IP configured at home follows the Mac everywhere
until you change it back.

## Why not use an existing tool

Existing tools detect the network by reading the Wi-Fi SSID. On current macOS
that is not reliably possible: `ipconfig getsummary` and `system_profiler`
report SSID and BSSID as `<redacted>` for non-root users, `networksetup
-getairportnetwork` misreports "not associated", and the `airport` command was
removed. What remains either needs root or falls back to guessing from the
preferred-networks list.

This project does not read the SSID at all.

## How it decides

A network is identified by **one characteristic device** on it: a device that is
present and answering whether or not it is the Mac's current gateway. For a home
network that is typically the upstream router.

1. Send a packet to that device's address (a closed UDP socket is enough) so the
   kernel performs an ARP lookup.
2. Read the device's MAC from the kernel neighbour table (`arp -n`).
3. If the MAC matches the configured one, the Mac is on that network.

Properties of this probe:

- no root, no raw sockets, no ICMP — it works where `ping` is unavailable;
- unaffected by SSID redaction;
- works whether or not the Mac is in the location that uses that device as its
  gateway;
- a matching IP with a *different* MAC is reported as an identity mismatch
  instead of being accepted.

## Scope of the automation

Only one direction is automatic. Entering a known location is automatic;
leaving one is not.

| Current state | Probe result | Action |
|---|---|---|
| `Automatic` | matches a known network | switch to that location |
| in that location | matches | nothing (idempotent) |
| in a location | no match | **notify** the user, do not switch |
| `Automatic` | no match | nothing (already the default) |

Leaving a non-default location is not automated on purpose: a device that stops
answering ARP can mean a real change (cabling, router swap, MAC change) that a
script should not silently guess about. A notification tells you to check the
network settings — the failure mode this project exists to remove is exactly
"static settings applied to the wrong network", and silently switching away can
mask it.

To use the upstream router temporarily while staying in a location, edit that
location's settings directly. Location switching and temporary gateway changes
are separate operations.

## Requirements

- macOS (developed and verified on macOS 27.0, build 26A428)
- bash 3.2 (the system bash) — the script avoids bash 4+ features on purpose
- no third-party dependencies

## Setup

### 1. Create the locations

Create one location per network, with the settings that network needs:

- `Automatic` — the roaming default: DHCP, automatic DNS.
- e.g. `Home` — the static settings for that network.

`networksetup` creates an **empty** location with `-createlocation <name>`
(no services), and `-createlocation <name> populate` creates fresh default
services while **not** copying TCP/IP or DNS from the current location. Both
behaviours are surprising; see `AGENTS.md` for the measured details. A working
recipe per location is: switch to it, add a service bound to the hardware port,
then set the values.

### 2. Write the config

```sh
mkdir -p ~/.wifi-loc-control
```

`~/.wifi-loc-control/locations.env` — **one numbered group per network**:

```sh
# the macOS location to switch to, the device address, and the device MAC
LOCATION_1_NAME="Home"
LOCATION_1_IP="192.0.2.1"
LOCATION_1_MAC="00:00:5e:00:53:01"

# LOCATION_2_NAME="Office"
# LOCATION_2_IP="198.51.100.1"
# LOCATION_2_MAC="aa:bb:cc:dd:ee:ff"
```

Add a network by copying a group and incrementing the number. The location name
is a *value* rather than a variable name, so it may contain spaces and non-ASCII
characters (`LOCATION_1_NAME="My Home"` is fine).

The file is **sourced**, so it is code, not data: keep it owned by you with mode
600, and do not copy one in from an untrusted source. The script unsets the
`LOCATION_*` variables immediately after reading them.

Find the MAC from the network itself, while connected to it:

```sh
./wifi-loc-detect.sh --print-mac 192.0.2.1
```

Each location needs its own group collected on its own network. A location's
device must be present from both the `Automatic` and that location's state — an
upstream router satisfies that for a home network.

When no group matches, the script switches to the default location, which is
`Automatic` (override with the `WLC_DEFAULT` environment variable).

### 3. Try it

```sh
./wifi-loc-detect.sh            # dry run: prints the decision, changes nothing
./wifi-loc-detect.sh --apply    # performs the switch when the decision is safe
```

## Usage

```
./wifi-loc-detect.sh                    dry run, prints what it decided and why
./wifi-loc-detect.sh --apply            actually switch locations
./wifi-loc-detect.sh --apply --notify   also post a notification when the
                                        current network cannot be identified
./wifi-loc-detect.sh --print-mac <ip>   print the MAC for an IP (config helper)
```

Exit codes: `0` fine, `2` bad usage, `3` config missing.

## Known limitations

- **The "away" case is verified across a network change, not a real departure.**
  With the Mac left in a non-default location and joined to a different network,
  the characteristic device left the neighbour table — no stale entry remained —
  and the script reported it as absent and posted a notification instead of
  switching. Leaving Wi-Fi entirely is not covered by that run. Automatic
  *triggering* is a separate matter and still absent: there is no LaunchAgent
  yet, so the script is run by hand.
- Leaving a non-default location needs a human decision (a notification, not a
  switch), by design.
- A characteristic device that is powered off makes its network unidentifiable.
- Only one characteristic device per network is supported; a collision needs a
  different device or a future multi-condition rule.
- IPv6 state is per location and must be set per location; it is not inferred.

## Roadmap

1. **Detector** — this script. Decision only, `--apply` to switch. *(done)*
2. **Event-driven daemon** — a LaunchAgent on `WatchPaths` over
   `/Library/Preferences/SystemConfiguration/`, with de-duplication: switching a
   location rewrites that directory and therefore triggers the agent again.
3. **Menu bar** — show the current location and allow switching from the menu,
   since macOS no longer exposes any location UI.

## License

MIT
