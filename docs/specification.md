# UplinC Specification

## Summary

UplinC is a macOS menu bar watchdog for Universal Control. It monitors the local Universal Control process, local TCP connections owned by Universal Control, related Unified Log events, and peer-to-peer UplinC heartbeats. When a strong local failure signal is detected, the elected Parent instance restarts the local Universal Control related services.

UplinC does not use private Universal Control APIs. Recovery is heuristic and local.

## Goals

- Detect Universal Control stalls and disconnects faster than manual troubleshooting.
- Avoid reset loops when UplinC runs on both Macs.
- Surface peer and heartbeat information for diagnosis.
- Keep the implementation small, local, and easy to inspect.
- Preserve manual control through a menu bar reset command.

## Non-Goals

- Repair a single remote peer through an Apple private API.
- Guarantee the exact Universal Control connection state.
- Maintain Universal Control's internal protocol session directly.
- Replace macOS Continuity, AWDL, Bluetooth, IDS, or Rapport behavior.

## Runtime Model

UplinC is an AppKit menu bar app. It runs as an accessory application and exposes all controls through an `NSStatusItem` menu.

The app checks health every 5 seconds. Each cycle updates local state, sends and receives heartbeat packets, and evaluates reset conditions.

## Monitored Local Services

UplinC resets these processes:

- `UniversalControl`
- `SidecarRelay`
- `sharingd`

The reset sequence is:

```sh
killall UniversalControl
killall SidecarRelay
killall sharingd
sleep 2
open -gj /System/Library/CoreServices/UniversalControl.app
```

Exit statuses are written to the diagnostic log.

## Menu Items

- Health status for `UniversalControl`.
- Last health check time.
- Unified Log watch status and failure count.
- TCP link status.
- Heartbeat status.
- Peer summary.
- Last reset time.
- `Open Log File`.
- `Reset Universal Control`.
- `Auto Heal`.
- `Mode: Auto/Parent/Child`.
- `Watch UC Logs`.
- `Watch TCP Link`.
- `Quit`.

## Modes

UplinC has a mode preference and an effective role.

Mode preferences:

- `Auto`
- `Parent`
- `Child`

Effective roles:

- `Parent`
- `Child`

Rules:

- Explicit `Parent` always becomes effective Parent.
- Explicit `Child` always becomes effective Child.
- In `Auto`, if any recent heartbeat peer advertises explicit `Parent`, this instance becomes Child.
- If all recent heartbeat peers are `Auto`, the lowest stable instance ID becomes Parent.
- If no peer is visible, an `Auto` instance treats itself as Parent.

Only an effective Parent can perform automatic resets. Child instances still monitor, log, display peer state, send heartbeat packets, and respond to heartbeat packets.

Manual reset always runs on the local machine.

## Identity

Each UplinC instance has a stable UUID stored in `NSUserDefaults` under `InstanceID`.

The mode preference is stored in `NSUserDefaults` under `ModePreference`.

## Heartbeat Protocol

UplinC listens on UDP port `54176` over IPv6.

Heartbeat packets are sent every 5 seconds to peer IPv6 addresses observed from `UniversalControl` TCP connections.

Payload format:

```text
UPLINC 1 id=<uuid> host=<host> mode=<auto|parent|child> effective=<parent|child> time=<unix_epoch_seconds>
```

Fields:

- `id`: stable UplinC instance UUID.
- `host`: sanitized local host name.
- `mode`: configured mode preference.
- `effective`: current effective role.
- `time`: sender timestamp.

Received heartbeats update the peer table with:

- peer ID
- host
- mode preference
- effective role
- sender address
- last seen time

Recent peers are peers seen within the last 30 seconds.

## Peer Display

The peer summary includes:

- Universal Control peer addresses discovered from local TCP ownership.
- UplinC heartbeat peers discovered from UDP heartbeat packets.
- Per-peer host, mode preference, effective role, compact address, and heartbeat age.

The menu display is compact and truncated for readability. The diagnostic log records the full peer summary.

## TCP Link Detection

UplinC runs:

```sh
/usr/sbin/lsof -nP -iTCP -sTCP:ESTABLISHED
```

It counts:

- established TCP connections owned by `UniversalControl`
- link-local established TCP connections owned by `rapportd`
- peer IPv6 addresses from `UniversalControl` connections

`rapportd` link-local count is diagnostic only. It does not trigger resets by itself.

If `UniversalControl` TCP links were seen and then the count remains zero for 12 consecutive health checks, UplinC treats this as a 60-second TCP disappearance.

## Unified Log Detection

UplinC streams Unified Log events with:

```sh
log stream --style compact --predicate 'process == "UniversalControl" OR process == "SidecarRelay" OR process == "sharingd"'
```

Failure-looking log phrases include:

- `disconnected`
- `connection interrupted`
- `connection failed`
- `connection refused`
- `connection reset`
- `timed out`
- `not reachable`
- `peer not found`
- `device not found`
- `receive failed`
- `activate failed`
- `p2pstream canceled`

Four hits within 2 minutes trigger a weak log-based reset.

Weak log-based resets are subject to the automatic reset cooldown.

## Reset Conditions

Strong reset signals:

- `UniversalControl` process is missing.
- `UniversalControl` TCP links were seen and then disappear for 60 seconds.
- UplinC heartbeat from a Universal Control TCP peer disappears for 30 seconds while that peer's TCP link is also missing. Per-peer evaluation: a heartbeat-stale peer whose TCP connection has dropped triggers a reset even if other peers remain healthy.

Weak reset signal:

- Four failure-looking Unified Log hits within 2 minutes.

Strong reset signals bypass the automatic reset cooldown when the local instance is allowed to auto-heal.

Weak log-based resets use a 5-minute cooldown.

Manual resets always run.

## Cooldown

The automatic cooldown is 300 seconds.

It applies only to weak log-based resets. Suppressed resets are logged with the reason and elapsed seconds since the previous reset.

## Notifications

UplinC requests notification permission on launch.

After each completed reset, it sends a macOS notification:

```text
Universal Control restarted
<reset reason>
```

Notifications are presented even while the app is active.

## Diagnostic Log

Log path:

```text
~/Library/Logs/UplinC.log
```

The log rotates to:

```text
~/Library/Logs/UplinC.log.1
```

Rotation threshold is 1 MB.

Logged events include:

- app start and stop
- process state changes
- mode changes
- effective role changes
- TCP connection count changes
- TCP missing and recovery events
- heartbeat peer count changes
- heartbeat sends and receives
- peer summaries
- Unified Log failure hits
- reset triggers
- cooldown suppression
- reset command exit statuses
- reset completion

## Build Output

Build command:

```sh
make build
```

Generated app:

```text
build/UplinC.app
```

The `build/` directory is ignored by git.

## Homebrew Cask

Release package command:

```sh
CODESIGN_IDENTITY="Developer ID Application: Example (TEAMID)" NOTARYTOOL_PROFILE=uplinc make package
```

Generated archive:

```text
dist/UplinC-0.1.5.zip
```

The `dist/` directory is ignored by git. The package command signs with the configured Developer ID identity, submits the app for notarization, staples the ticket, and verifies Gatekeeper assessment before creating the final archive. Upload the archive to the matching GitHub Release tag before updating the cask in `ichi0g0y/homebrew-tap`.

Homebrew install:

```sh
brew tap ichi0g0y/tap
brew install --cask uplinc
```

The cask installs only `UplinC.app`. LaunchAgent registration remains an explicit source-checkout action through `make install`.

## LaunchAgent

Install:

```sh
make install
```

Remove:

```sh
make uninstall
```

LaunchAgent label:

```text
local.uplinc
```

The installer removes older LaunchAgents from previous names:

- `local.uc-pulse`

## Project Layout

```text
Sources/UplinC/main.m                 AppKit menu bar app and recovery logic
Resources/Info.plist                  App bundle metadata
scripts/build_app.sh                  Builds build/UplinC.app
scripts/package_release.sh            Builds dist/UplinC-<version>.zip
scripts/install_launch_agent.sh       Installs the login LaunchAgent
scripts/uninstall_launch_agent.sh     Removes the login LaunchAgent
Makefile                              Common build/run/install/check commands
docs/specification.md                 Detailed app specification
build/                                Ignored build output
dist/                                 Ignored release archives
```

## Known Limitations

- macOS does not expose a public Universal Control health API.
- Peer-specific repair is not available; recovery restarts local services.
- Heartbeat packets may be blocked by firewall settings.
- Heartbeat routing follows observed Universal Control peer addresses, but it is not guaranteed to use the exact same internal Apple protocol path.
- Multiple Universal Control peers can be displayed, but reset is still local and affects the local Universal Control service as a whole.

## Future Improvements

- Add per-peer stale state in the menu instead of a single compact summary.
- Add a preference window for mode, heartbeat port, and cooldown tuning.
- Persist recent peer history across app restarts.
- Export diagnostics as a bundle for issue reports.
- Add notarized app packaging once distribution is needed.
