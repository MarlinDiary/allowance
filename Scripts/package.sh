#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/Allowance.app}"
OUT="${2:-$ROOT/dist}"
[[ -d "$APP" ]] || { echo "Build the app first" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
mkdir -p "$OUT"
ZIP="$OUT/Allowance-$VERSION-macOS.zip"
DMG="$OUT/Allowance-$VERSION-macOS.dmg"
[[ ! -e "$ZIP" && ! -e "$DMG" ]] || { echo "Release output already exists" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
# Use an existing Keychain profile only when explicitly configured. Never save credentials.
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    TEMP="$(mktemp -d)"
    trap 'rm -rf "$TEMP"' EXIT
    ditto -c -k --keepParent "$APP" "$TEMP/submission.zip"
    xcrun notarytool submit "$TEMP/submission.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
fi
ditto -c -k --keepParent "$APP" "$ZIP"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Allowance.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname Allowance -srcfolder "$STAGE" -format UDZO "$DMG"
if [[ -n "${CODE_SIGN_IDENTITY:-}" && "$CODE_SIGN_IDENTITY" != "-" ]]; then
    codesign --sign "$CODE_SIGN_IDENTITY" --timestamp "$DMG"
fi
(cd "$OUT"; shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > SHA256SUMS)
echo "Packaged $ZIP and $DMG"
