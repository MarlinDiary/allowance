#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/Allowance.app}"
OUT="${2:-$ROOT/dist}"
[[ -d "$APP" ]] || { echo "Build the app first" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "${REQUIRE_NOTARIZATION:-0}" != 1 || -n "${NOTARY_PROFILE:-}" ]] || { echo "NOTARY_PROFILE is required for a notarized release" >&2; exit 1; }
mkdir -p "$OUT"
ZIP="$OUT/Allowance-$VERSION-macOS.zip"
DMG="$OUT/Allowance-$VERSION-macOS.dmg"
[[ ! -e "$ZIP" && ! -e "$DMG" ]] || { echo "Release output already exists" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
# Use an existing Keychain profile only when explicitly configured. Never save credentials.
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    ditto -c -k --keepParent "$APP" "$TEMP/submission.zip"
    xcrun notarytool submit "$TEMP/submission.zip" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$OUT/notary-app.json"
    plutil -extract status raw "$OUT/notary-app.json" | grep -qx Accepted
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
fi
ditto -c -k --keepParent "$APP" "$ZIP"
STAGE="$TEMP/stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Allowance.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname Allowance -srcfolder "$STAGE" -format UDZO "$DMG"
if [[ -n "${CODE_SIGN_IDENTITY:-}" && "$CODE_SIGN_IDENTITY" != "-" ]]; then
    codesign --sign "$CODE_SIGN_IDENTITY" --timestamp "$DMG"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$OUT/notary-dmg.json"
    plutil -extract status raw "$OUT/notary-dmg.json" | grep -qx Accepted
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
else
    echo 'Preview only: Developer ID signing does not imply Apple notarization.' >&2
fi
(cd "$OUT"; shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > SHA256SUMS)
echo "Packaged $ZIP and $DMG"
