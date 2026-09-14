#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?App bundle required}"
OUT="${2:?Icon scratch directory required}"
STYLE="${ALLOWANCE_ICON_STYLE:-auto}"
mkdir -p "$OUT" "$APP/Contents/Resources"
case "$STYLE" in auto|layered|legacy) ;; *) echo "Unknown icon style: $STYLE" >&2; exit 1 ;; esac
VERSION="$(xcrun actool --version --output-format xml1)"
MAJOR="$(printf '%s' "$VERSION" | /usr/libexec/PlistBuddy -c 'Print :com.apple.actool.version:short-bundle-version' /dev/stdin | cut -d. -f1)"
if [[ "$STYLE" == layered || ( "$STYLE" == auto && "$MAJOR" -ge 26 ) ]]; then
    [[ "$MAJOR" -ge 26 ]] || { echo "Layered icons require Xcode 26 or newer" >&2; exit 1; }
    # Apple's compiler preserves material layers in Assets.car and generates legacy ICNS.
    # A compilation failure is a failure, never silently replaced by a flat icon.
    xcrun actool "$ROOT/Assets/AppIcon.icon" --compile "$OUT" \
        --app-icon AppIcon --platform macosx --minimum-deployment-target 13.0 \
        --output-partial-info-plist "$OUT/icon-info.plist" --output-format human-readable-text
    [[ -s "$OUT/Assets.car" && -s "$OUT/AppIcon.icns" ]] || { echo "Missing compiled icon resources" >&2; exit 1; }
    cp "$OUT/Assets.car" "$OUT/AppIcon.icns" "$APP/Contents/Resources/"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconName string AppIcon' "$APP/Contents/Info.plist"
    echo 'Icon: layered Liquid Glass + generated legacy ICNS'
else
    swift "$ROOT/Scripts/make-icon.swift" "$ROOT" "$OUT/AppIcon.iconset"
    iconutil -c icns "$OUT/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
    echo 'Icon: legacy static SVG (older Xcode or explicitly requested)'
fi
