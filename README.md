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
./wifi-loc-detect.sh --apply --notify   also notify when the current network
                                        cannot be identified, once per departure
./wifi-loc-detect.sh --print-mac <ip>   print the MAC for an IP (config helper)
```

Exit codes: `0` fine, `2` bad usage, `3` config missing.

## Running automatically

A LaunchAgent can apply the decision whenever the network changes, so you do
not have to run the script yourself:

```sh
touch ~/.wifi-loc-control/agent.log && chmod 600 ~/.wifi-loc-control/agent.log
cp com.yayadesu.auto-network-location.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.yayadesu.auto-network-location.plist
launchctl print gui/$(id -u)/com.yayadesu.auto-network-location
```

The first line pre-creates the log with mode 600. launchd creates the
`StandardOutPath` file itself and the plist's `Umask` key does not apply to it,
so a pre-existing file is the only way to keep the log private.

To remove it again:

```sh
launchctl bootout gui/$(id -u)/com.yayadesu.auto-network-location
rm ~/Library/LaunchAgents/com.yayadesu.auto-network-location.plist
```

The job watches `/Library/Preferences/SystemConfiguration` and also runs every
300 seconds as a safety net. It switches only when a known network is entered;
when the current network cannot be identified it notifies **once per
departure**, not once per trigger.

Two prerequisites and two caveats:

- `~/.wifi-loc-control/` must already exist; the job logs to
  `~/.wifi-loc-control/agent.log` there.
- The plist holds the absolute path to this checkout. Move the repo and you
  must reinstall; edit the plist and you must `bootout` then `bootstrap`
  again, because launchd does not re-read it.
- `WatchPaths` can miss events (`man launchd.plist` says it is "highly
  discouraged"), and the 300-second fallback does not fire while the system
  is asleep. Expect the switch to happen on the next event or within five
  minutes of waking.
- The log file grows without bound and is safe to delete; the state file that
  tracks the away notice is separate.

## Known limitations

- **Automatic operation is verified, with one gap: waking from sleep.** With the
  LaunchAgent loaded, the location is switched unattended when a known network
  is entered, and an unidentifiable network is reported once per departure
  rather than once per trigger. `WatchPaths` is race-prone and the 300-second
  fallback does not fire while the system is asleep, so expect the switch on the
  next event or within five minutes of waking; whether waking itself triggers a
  run has not been measured yet.
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
