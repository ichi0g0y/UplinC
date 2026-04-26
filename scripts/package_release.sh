#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/UplinC.app"
DIST_DIR="$ROOT/dist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
ARCHIVE="$DIST_DIR/UplinC-$VERSION.zip"

"$ROOT/scripts/build_app.sh" >/dev/null
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Normalize timestamps so repeated packaging of identical app contents is stable.
find "$APP" -exec touch -t 202601010000 {} +
COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ARCHIVE"

shasum -a 256 "$ARCHIVE"
