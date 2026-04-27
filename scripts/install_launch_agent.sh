#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/UplinC.app"
PLIST="$HOME/Library/LaunchAgents/local.uplinc.plist"
OLD_UC_PULSE_PLIST="$HOME/Library/LaunchAgents/local.uc-pulse.plist"
OLD_MEDIC_PLIST="$HOME/Library/LaunchAgents/local.universal-control-medic.plist"

if [[ ! -d "$APP" ]]; then
  "$ROOT/scripts/build_app.sh" >/dev/null
fi

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>local.uplinc</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-gja</string>
    <string>$APP</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootout "gui/$(id -u)" "$OLD_UC_PULSE_PLIST" 2>/dev/null || true
launchctl bootout "gui/$(id -u)" "$OLD_MEDIC_PLIST" 2>/dev/null || true
rm -f "$OLD_UC_PULSE_PLIST" "$OLD_MEDIC_PLIST"
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/local.uplinc"
echo "$PLIST"
