#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/UplinC.app"
DIST_DIR="$ROOT/dist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
ARCHIVE="$DIST_DIR/UplinC-$VERSION.zip"
NOTARY_ARCHIVE="$DIST_DIR/UplinC-$VERSION-notary.zip"

if [[ -z "${CODESIGN_IDENTITY:-}" || "$CODESIGN_IDENTITY" == "-" ]]; then
  echo "CODESIGN_IDENTITY must be a Developer ID Application signing identity for release packaging." >&2
  exit 1
fi
if [[ -z "${NOTARYTOOL_PROFILE:-}" && ( -z "${APPLE_ID:-}" || -z "${APPLE_TEAM_ID:-}" || -z "${APPLE_APP_SPECIFIC_PASSWORD:-}" ) ]]; then
  echo "Set NOTARYTOOL_PROFILE, or set APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_SPECIFIC_PASSWORD." >&2
  exit 1
fi

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
CODESIGN_IDENTITY="$CODESIGN_IDENTITY" "$ROOT/scripts/build_app.sh" >/dev/null
codesign --verify --deep --strict "$APP"

COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --keepParent "$APP" "$NOTARY_ARCHIVE"
if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
  xcrun notarytool submit "$NOTARY_ARCHIVE" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
else
  xcrun notarytool submit "$NOTARY_ARCHIVE" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --wait
fi
xcrun stapler staple "$APP"
spctl --assess --type execute "$APP"
rm -f "$NOTARY_ARCHIVE"

# Normalize timestamps so repeated packaging of identical app contents is stable.
find "$APP" -exec touch -t 202601010000 {} +
COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ARCHIVE"

shasum -a 256 "$ARCHIVE"
