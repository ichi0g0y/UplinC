# UplinC

Geeky macOS menu bar watchdog for Universal Control links, heartbeats, and auto-recovery.

UplinC watches the local Universal Control stack, tracks peer link health, exchanges lightweight heartbeats with UplinC running on the other Mac, and restarts the relevant macOS services when the connection looks wedged.

## Features

- Menu bar status item with health, peer, heartbeat, and reset state.
- Manual reset for `UniversalControl`, `SidecarRelay`, and `sharingd`.
- Process check for `UniversalControl` every 5 seconds.
- TCP link monitoring for established connections owned by `UniversalControl`.
- Multi-peer display for Universal Control peer addresses and UplinC heartbeat peers.
- UDP heartbeat every 5 seconds over peer addresses observed from Universal Control TCP links.
- `Auto`, `Parent`, and `Child` modes to avoid reset loops across two Macs.
- Unified Log monitoring for repeated Universal Control failure patterns.
- macOS notifications after resets.
- Diagnostic log at `~/Library/Logs/UplinC.log`.

## Build

```sh
cd UplinC
make build
```

Run the app:

```sh
make run
```

The app bundle is generated at:

```text
build/UplinC.app
```

## Homebrew

Create the release archive:

```sh
make package
```

Upload the generated `dist/UplinC-0.1.0.zip` file to the matching GitHub Release tag, then update the `uplinc` cask in `ichi0g0y/homebrew-tap`.

Install with Homebrew:

```sh
brew tap ichi0g0y/tap
brew install --cask uplinc
```

Homebrew installs UplinC as an app only. To start it at login, use the LaunchAgent install step from a source checkout.

## Start At Login

Install the LaunchAgent:

```sh
make install
```

Remove the LaunchAgent:

```sh
make uninstall
```

The install script also removes older LaunchAgents from previous names.

## Modes

`Auto` elects exactly one Parent among recent UplinC heartbeat peers. If another peer is explicitly set to `Parent`, an `Auto` peer becomes Child. If all peers are `Auto`, the stable instance ID order decides the Parent.

`Parent` allows automatic resets when UplinC detects a strong local failure signal.

`Child` continues monitoring, logging, and responding to heartbeat packets, but does not automatically restart services.

## Reset Signals

Strong signals reset immediately when the local instance is allowed to auto-heal:

- `UniversalControl` process is missing.
- Universal Control TCP links were previously seen and then disappear for 60 seconds.
- UplinC heartbeat disappears while Universal Control TCP links are also missing.

Weak log-based resets use a 5-minute cooldown:

- 4 failure-looking Unified Log hits within 2 minutes.

Manual resets always run.

## Diagnostics

Open the log from the menu with `Open Log File`, or tail it directly:

```sh
tail -f ~/Library/Logs/UplinC.log
```

The log records process state changes, TCP connection counts, peer summaries, heartbeat sends/receives, reset triggers, cooldown suppression, and command exit statuses. It rotates to `UplinC.log.1` after 1 MB.

## Documentation

- [Detailed specification](docs/specification.md)

## Project Layout

```text
Sources/UplinC/main.m                 AppKit menu bar app and recovery logic
Resources/Info.plist                  App bundle metadata
scripts/build_app.sh                  Builds build/UplinC.app
scripts/package_release.sh            Builds dist/UplinC-<version>.zip
scripts/install_launch_agent.sh       Installs the login LaunchAgent
scripts/uninstall_launch_agent.sh     Removes the login LaunchAgent
docs/specification.md                 Detailed app specification
build/                                Ignored build output
dist/                                 Ignored release archives
```

## Limitations

macOS does not expose a public Universal Control connection-health API. UplinC uses process state, local TCP ownership, Unified Log signals, and same-path heartbeat probes as heuristics. It can identify which peers appear healthy or stale, but recovery is still local: it restarts the local Universal Control related services rather than repairing a single peer link through a private Apple API.
