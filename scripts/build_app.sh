#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/UplinC.app"
EXEC="$APP/Contents/MacOS/UplinC"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

rm -rf "$APP"
mkdir -p "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS"
clang -fobjc-arc -framework AppKit -framework UserNotifications -framework ServiceManagement "$ROOT"/Sources/UplinC/*.m -o "$EXEC"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$EXEC"
codesign --force --deep --options runtime --sign "$CODESIGN_IDENTITY" "$APP"

echo "$APP"
