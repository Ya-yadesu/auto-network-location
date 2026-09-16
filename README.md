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

Both directions are automatic, but only leaving is unconditional.

| Current state | Probe result | Action |
|---|---|---|
| `Automatic` | matches a known network | switch to that location |
| in that location | matches, target device present | nothing (idempotent) |
| in that location | matches, target device missing | **notify**, do not switch |
| in any location | no known network found | **switch back to the default location** |

A network is described by two devices. The *characteristic* device answers "which
network is this"; the optional *target* device answers "is this still the network
my settings were written for". The target defaults to the characteristic device,
so a network that needs no separate check needs no extra configuration.

Leaving is assumed as soon as the characteristic device stops answering, and the
Mac is returned to the default location (`Automatic`, unless `WLC_DEFAULT` says
otherwise) so that it works on whatever network it is actually on. The default
location is DHCP, which is usable almost anywhere, so acting at once is cheap: if
it turns out to have been a single bad reading, the same run looks again after 15
seconds and switches back, silently.

A network that is still there but no longer matches — the device your settings
depend on is gone, or the address now belongs to something else — is a different
case. That one is reported rather than papered over, because switching away would
silently replace your static settings with DHCP, which is exactly the failure
this project exists to remove.

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

# Optional: the device this location's own settings depend on (its gateway or
# DNS). Omit it and the characteristic device above is used. If you give one,
# give it in full: a malformed target skips the whole group rather than being
# silently ignored.
# LOCATION_1_TARGET_IP="192.0.2.100"
# LOCATION_1_TARGET_MAC="00:00:5e:00:53:02"

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

Each location needs its own group collected on its own network. The
characteristic device must be present from both the `Automatic` and that
location's state — an upstream router satisfies that for a home network. If the
location's settings point at a different box (its gateway or DNS), name that box
as `LOCATION_n_TARGET_IP` / `_TARGET_MAC`; otherwise the two roles collapse into
one and the second check never fires.

When no group matches, the script falls back to the default location, which is
`Automatic` (override with the `WLC_DEFAULT` environment variable) — but only
after the characteristic device has been missing for two consecutive checks.

### 3. Try it

```sh
./wifi-loc-detect.sh            # dry run: prints the decision, changes nothing
./wifi-loc-detect.sh --apply    # performs the switch when the decision is safe
```

## Usage

```
./wifi-loc-detect.sh                    dry run, prints what it decided and why
./wifi-loc-detect.sh --apply            actually switch locations
./wifi-loc-detect.sh --apply --notify   also notify: once when this network no
                                        longer matches, and once per departure
./wifi-loc-detect.sh --print-mac <ip>   print the MAC for an IP (config helper)
```

Exit codes: `0` fine, `1` a switch or a MAC lookup failed, `2` bad usage, `3`
config missing.

## Running automatically

A LaunchAgent can apply the decision whenever the network changes, so you do
not have to run the script yourself:

```sh
touch ~/.wifi-loc-control/agent.log && chmod 600 ~/.wifi-loc-control/agent.log
sed "s|__REPO__|$PWD|; s|__HOME__|$HOME|" com.yayadesu.auto-network-location.plist \
  > ~/Library/LaunchAgents/com.yayadesu.auto-network-location.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.yayadesu.auto-network-location.plist
launchctl print gui/$(id -u)/com.yayadesu.auto-network-location
```

Run that from the root of this checkout: the plist ships with two placeholders
(`__REPO__` for the checkout path, `__HOME__` for your home directory) because
launchd expands neither `~` nor environment variables, so those paths must be
literal by the time launchd reads the file.

The first line pre-creates the log with mode 600. launchd creates the
`StandardOutPath` file itself and the plist's `Umask` key does not apply to it,
so a pre-existing file is the only way to keep the log private.

To remove it again:

```sh
launchctl bootout gui/$(id -u)/com.yayadesu.auto-network-location
rm ~/Library/LaunchAgents/com.yayadesu.auto-network-location.plist
```

The job watches `/Library/Preferences/SystemConfiguration` and also runs once
when it is loaded. It enters a known network when it appears, falls back to the
default location when the characteristic device stops answering (looking once
more after 15 seconds in case that was a single bad reading), and notifies when
the network it is on no longer matches the configured settings — once per state,
not once per trigger.

Two prerequisites and two caveats:

- `~/.wifi-loc-control/` must already exist; the job logs to
  `~/.wifi-loc-control/agent.log` there.
- The plist holds the absolute path to this checkout. Move the repo and you
  must reinstall; edit the plist and you must `bootout` then `bootstrap`
  again, because launchd does not re-read it.
- `WatchPaths` can miss events (`man launchd.plist` says it is "highly
  discouraged"), and this job deliberately has no periodic fallback: it is a
  one-shot script for a specific event, not a poller. A missed event therefore
  leaves the location wrong until the next network change, which is why the
  manual command below matters.
- The log file grows without bound and is safe to delete; the state file that
  records what has already been reported is separate.

### If it gets it wrong

macOS no longer exposes any location UI, so switching by hand is one command:

```sh
networksetup -listlocations     # the locations that exist, and the current one
scselect                        # the same, more briefly
scselect Home                   # switch to a location
```

Because the job only runs on a network change, a wrong guess stays until the next
one unless you run that by hand.

## Known limitations

- **Automatic operation is verified.** With the LaunchAgent loaded, the location
  is switched unattended when a known network is entered, and the machine is
  returned to the default location after leaving one. Waking from sleep was
  measured: a run happens about thirty seconds after the lid opens, because
  reconnecting raises a `WatchPaths` event.
- **Leaving is confirmed inside the same run**, 15 seconds after the fallback, so
  a single bad reading costs two quick interface reconfigurations instead of a
  wrong location. Nothing is reported when that happens.
- **Nothing is reported when you leave**, on purpose: the machine is already
  usable on the default location and this happens on every departure. Only a
  device that was replaced, or a location whose target device is gone, is worth
  a notice.
- Both devices must match address *and* MAC. A characteristic device that is
  powered off, or whose address has been taken over by something else, makes its
  network unidentifiable.
- Only one characteristic device and one target device per network; a collision
  needs a different device or a future multi-condition rule.
- IPv6 state is per location and must be set per location; it is not inferred.
- Both devices must match address *and* MAC. A characteristic device that is
  powered off, or whose address has been taken over by something else, makes its
  network unidentifiable.
- Only one characteristic device and one target device per network; a collision
  needs a different device or a future multi-condition rule.
- IPv6 state is per location and must be set per location; it is not inferred.

## Roadmap

1. **Detector** — this script. Decide, and switch with `--apply`. *(done)*
2. **Event-driven daemon** — a LaunchAgent on `WatchPaths` over
   `/Library/Preferences/SystemConfiguration/`, with de-duplication: switching a
   location rewrites that directory and therefore triggers the agent again.
   *(done)*
3. **Menu bar** — show the current location and allow switching from the menu,
   since macOS no longer exposes any location UI.

## License

MIT
