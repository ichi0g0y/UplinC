#!/bin/zsh
set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/local.uplinc.plist"
OLD_UC_PULSE_PLIST="$HOME/Library/LaunchAgents/local.uc-pulse.plist"
OLD_MEDIC_PLIST="$HOME/Library/LaunchAgents/local.universal-control-medic.plist"

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootout "gui/$(id -u)" "$OLD_UC_PULSE_PLIST" 2>/dev/null || true
launchctl bootout "gui/$(id -u)" "$OLD_MEDIC_PLIST" 2>/dev/null || true
rm -f "$PLIST"
rm -f "$OLD_UC_PULSE_PLIST" "$OLD_MEDIC_PLIST"
echo "Removed $PLIST"
