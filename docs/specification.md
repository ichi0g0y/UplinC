# UplinC Specification

## Summary

UplinC is a macOS menu bar watchdog for Universal Control. It monitors the local Universal Control process, local TCP connections owned by Universal Control, related Unified Log events, and peer-to-peer UplinC heartbeats. When a strong local failure signal is detected, any instance with Auto Heal enabled restarts the local Universal Control related services.

UplinC does not use private Universal Control APIs. Recovery is heuristic and local.

## Goals

- Detect Universal Control stalls and disconnects faster than manual troubleshooting.
- Coordinate restart timing across paired Macs so both sides recover together through the Sync Reset protocol.
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
- Unified Log watch status and failure score.
- TCP link status.
- Heartbeat status.
- Peer summary.
- Last reset time.
- `Diagnostic` submenu (read-only rolling state, see §Diagnostic Submenu).
- `Open Log File`.
- `Reset Universal Control`.
- `Auto Heal`.
- `Notifications`.
- `Sync Reset`.
- `Watch UC Logs`.
- `Watch TCP Link`.
- `Quit`.

## Identity

Each UplinC instance has a stable UUID stored in `NSUserDefaults` under `InstanceID`.

Auto Heal, Notifications, and Sync Reset preferences are stored in `NSUserDefaults`.

## Persistence

UplinC persists the canonical IPv6 addresses of past Universal Control TCP peers (`ucPeersEverSeen`) to `NSUserDefaults` under the key `UCPeersLastSeen`. The on-disk schema is a dictionary keyed by canonical address with `NSNumber` values holding `timeIntervalSince1970` of the most recent observation.

Entries older than 30 days are pruned at launch and on insert. Defaults writes are debounced: a write happens immediately when a new address is added, and otherwise at most once per 60 seconds during repeated observations of known addresses.

The persisted set keeps the heartbeat-disappearance reset trigger and Sync Reset broadcast targeting effective immediately after app launch, before any new TCP peer is observed in the current process.

If the persisted value is missing, malformed, or contains entries with unexpected types, UplinC clears the bad value, logs `persistence_load_fail`, and starts with an empty set rather than failing to launch.

## Address Canonicalization

All IPv6 addresses persisted, compared, or matched against `ucPeersEverSeen` flow through `canonicalIPv6String:`, which routes both numeric scope IDs (`fe80::xxx%4`) and named scope IDs (`fe80::xxx%en0`) through `if_nametoindex` and emits the numeric form. This applies to addresses observed via `lsof` for TCP discovery and to addresses observed in the IPv6 sockaddr of inbound UDP heartbeats and reset commands.

## Heartbeat Protocol

UplinC listens on UDP port `54176` over IPv6.

Heartbeat packets are sent every 5 seconds to peer IPv6 addresses observed from `UniversalControl` TCP connections.

Payload format:

```text
UPLINC 2 id=<uuid> host=<host> time=<unix_epoch_seconds>
```

Fields:

- `id`: stable UplinC instance UUID.
- `host`: sanitized local host name.
- `time`: sender timestamp.

Received heartbeats update the peer table with:

- peer ID
- host
- sender address
- last seen time

Recent peers are peers seen within the last 30 seconds.

## Peer Display

The peer summary includes:

- Universal Control peer addresses discovered from local TCP ownership.
- UplinC heartbeat peers discovered from UDP heartbeat packets.
- Per-peer host, compact address, and heartbeat age.

The menu display is compact and truncated for readability. The diagnostic log records the full peer summary.

The Machines submenu also annotates each row with the resolved interface name (for example `en0`, `en1`, `awdl0`) when the heartbeat arrived over a link-local IPv6 address with a known scope. This is observation only — UplinC cannot force which interface Universal Control uses.

Heartbeat peers older than 10 seconds are grouped under an "Offline" section in the Machines submenu, and entries older than 24 hours are removed from the in-memory peer table on a 60-second cadence so the table does not grow unboundedly during long uptimes. The 24 hour threshold applies only to the heartbeat peer table; the persisted `ucPeersEverSeen` history uses the 30 day TTL described in §Persistence.

## Sync Reset Protocol

When Sync Reset is enabled, manual resets and Auto Heal resets broadcast a reset command to UplinC peers whose addresses have previously been observed as Universal Control TCP peers. This limits reset coordination to paired Macs instead of every UplinC instance on the LAN.

Reset command payload format:

```text
UPLINCRST 1 id=<sender_uuid> host=<host> nonce=<uuid> reason=<single_token> time=<unix_epoch_seconds>
```

Reset commands use the same UDP port, Bonjour discovery, and IPv6 socket as heartbeat packets. A sender transmits each logical command three times at 0, 250, and 500 milliseconds with the same nonce. Receivers keep the most recent 64 nonces and drop duplicates.

Incoming reset commands are accepted only when all of these checks pass:

- Sync Reset is enabled locally.
- `id`, `nonce`, and `time` fields are present.
- The sender ID is not the local instance ID.
- The sender address is in `ucPeersEverSeen`.
- The timestamp is within 10 seconds of the local clock.
- The nonce has not already been processed.
- A local reset is not already in progress.

Accepted commands run the same local reset sequence with `force:YES`, `manual:NO`, and `broadcast:NO`. Remote reset handling never rebroadcasts, so reset fan-out is limited to the original sender.

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

Each matched line is assigned a weight. Strong markers are unambiguous failure signals and contribute a full hit; weak markers are also raised by ordinary disconnect or sleep flows and require a severity token on the same line to count as a full hit, otherwise they contribute a half hit.

Strong markers (weight `1.0`):

- `crashed`
- `died`
- `panic`
- `fatal error`
- `assertion failed`

Weak markers (weight `1.0` when a severity token co-occurs on the same line, otherwise `0.5`):

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

Severity tokens that promote a weak marker to a full hit:

- `error`
- `fail`
- `fatal`

Identical message text seen within 5 seconds is collapsed to a single hit (duplicate suppression). The dropped duplicate is logged as `failure_log dup_suppressed`.

Weighted hits accumulate in a 120 second sliding window. Events older than 120 seconds are dropped both before each new event is recorded and on every Diagnostic submenu rebuild, so the displayed score reflects window expiry even when no new failure log is arriving. The weak log-based reset triggers when the windowed score reaches `4.0`.

Weak log-based resets are subject to the automatic reset cooldown.

## Reset Conditions

Strong reset signals:

- `UniversalControl` process is missing.
- `UniversalControl` TCP links were seen and then disappear for 60 seconds.
- UplinC heartbeat from a Universal Control TCP peer disappears for 30 seconds while that peer's TCP link is also missing. Per-peer evaluation: a heartbeat-stale peer whose TCP connection has dropped triggers a reset even if other peers remain healthy.

Weak reset signal:

- Failure-looking Unified Log events whose weighted score reaches `4.0` within a sliding 2-minute window. Strong markers (`crashed`, `died`, `panic`, `fatal error`, `assertion failed`) contribute `1.0` each. Weak markers contribute `1.0` only when a severity token (`error`, `fail`, `fatal`) co-occurs on the same line, otherwise they contribute `0.5`. Duplicate lines within 5 seconds are suppressed. Hits older than 120 seconds are dropped before each evaluation, so spaced-out failures spanning more than 2 minutes do not accumulate to the trigger threshold.

Strong reset signals bypass the automatic reset cooldown when Auto Heal is enabled.

Weak log-based resets use a 5-minute cooldown.

Manual resets always run locally and broadcast a Sync Reset command when Sync Reset is enabled.

## Cooldown

The automatic cooldown is 300 seconds.

It applies only to weak log-based resets. Suppressed resets are logged with the reason and elapsed seconds since the previous reset.

## Grace Periods

Two short suppression windows prevent cascading or spurious resets:

- **Post-reset grace:** 60 seconds after a completed reset, all auto-reset triggers are suppressed and the transient counters (`failureLogEvents`, `failureLogScore`, `recentLogMessageHashes`, `missedTCPChecks`, `missedHeartbeatChecks`, `tcpLinkHasBeenSeen`, `heartbeatPeerHasBeenSeen`) are cleared. This avoids reset loops driven by post-`killall` failure logs or by the brief gap before `UniversalControl` restarts.
- **Post-wake grace:** 90 seconds after `NSWorkspaceDidWakeNotification`, the same suppression and counter clear apply. The macOS network stack typically takes a few seconds to a few tens of seconds to resume after wake; observed `lsof` and heartbeat gaps during that window are no longer treated as failures.

Status menu items continue to update during grace; only the auto-reset triggers are gated.

## Notifications

UplinC requests notification permission on launch.

After each completed reset, it sends a macOS notification:

```text
Universal Control restarted
<reset reason>
```

Notifications are presented even while the app is active.

## Diagnostic Submenu

The `Diagnostic` submenu exposes a read-only rolling view of the heuristics that drive auto-reset decisions. Samples are appended on the existing 5 second health tick and the submenu is rebuilt on the 1 Hz heartbeat tick — no extra timer is introduced — and it never accepts user input.

Each row holds the last 12 samples (≈ 1 minute at the 5 second sampling cadence):

- `pgrep UC`: per-sample presence of the `UniversalControl` process. `o` = running, `x` = missing.
- `TCP UC`: per-sample count of `UniversalControl` TCP connections, sourced from the most recent `lsof` snapshot taken on the same 5 second health tick.
- `HB peers`: per-sample count of fresh UplinC heartbeat peers (those seen within the last 30 seconds).

Two summary rows below the per-sample rows are recomputed at every 1 Hz rebuild so they reflect the sliding 120 second window even when no new failure log has arrived:

- `Failure score: %.1f/4.0 (window 120s)`: the current windowed weighted log score, with events older than 120 seconds pruned before each rebuild.
- `Last: <text>`: the most recent matched failure log line, truncated to 80 characters. Shows `none` when no line has been matched since launch.

The submenu is intended for in-app post-mortem inspection when the user wants to confirm whether a reset trigger fired (or should have fired) and is purely advisory — none of the displayed values are persisted.

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
- TCP connection count changes
- TCP missing and recovery events
- heartbeat peer count changes
- heartbeat sends and receives
- remote reset broadcasts, receives, and rejects
- peer summaries
- Unified Log failure hits, including the per-event `weight` and the windowed `score`, with `dup_suppressed` entries for lines collapsed by the 5 second duplicate suppression
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
- `local.universal-control-medic`

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
- Heartbeat and Sync Reset packets may be blocked by firewall settings.
- Heartbeat routing follows observed Universal Control peer addresses, but it is not guaranteed to use the exact same internal Apple protocol path.
- Multiple Universal Control peers can be displayed, but reset is still local and affects the local Universal Control service as a whole.
- Sync Reset depends on `ucPeersEverSeen`; immediately after app launch it may not broadcast until a Universal Control TCP peer has been observed.

## Future Improvements

- Add per-peer stale state in the menu instead of a single compact summary.
- Add a preference window for heartbeat port, Sync Reset, and cooldown tuning.
- Persist recent peer history across app restarts.
- Export diagnostics as a bundle for issue reports.
- Add notarized app packaging once distribution is needed.
