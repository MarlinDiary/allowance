#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:-$ROOT/dist/Allowance.app}"
BUILD="${ALLOWANCE_BUILD_DIR:-$ROOT/.build-app}"
[[ ! -e "$DEST" ]] || { echo "Output already exists: $DEST" >&2; exit 1; }
ARCHS="${ALLOWANCE_ARCHS:-arm64 x86_64}"
BINARIES=()
for ARCH in $ARCHS; do
    case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; esac
    swift build --package-path "$ROOT" --scratch-path "$BUILD/$ARCH" --triple "$ARCH-apple-macosx13.0" -c release
    BIN="$(swift build --package-path "$ROOT" --scratch-path "$BUILD/$ARCH" --triple "$ARCH-apple-macosx13.0" -c release --show-bin-path)"
    BINARIES+=("$BIN/QuotaMenu")
    RESOURCE_BUNDLE="$BIN/QuotaMenu_QuotaMenu.bundle"
done
[[ -d "$RESOURCE_BUNDLE" ]] || { echo "Missing provider artwork bundle" >&2; exit 1; }
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
lipo -create "${BINARIES[@]}" -output "$DEST/Contents/MacOS/Allowance"
ditto "$RESOURCE_BUNDLE" "$DEST/Contents/Resources/QuotaMenu_QuotaMenu.bundle"
cp "$ROOT/Info.plist" "$DEST/Contents/Info.plist"
bash "$ROOT/Scripts/build-icons.sh" "$DEST" "$BUILD/icons"
chmod +x "$DEST/Contents/MacOS/Allowance"
IDENTITY="${CODE_SIGN_IDENTITY:--}"
if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --sign - "$DEST"
else
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$DEST"
fi
codesign --verify --deep --strict "$DEST"
plutil -lint "$DEST/Contents/Info.plist"
printf 'Built Allowance: %s\n' "$DEST"
