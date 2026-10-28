#!/bin/bash
# Builds Breeze.app from source. Requires Xcode or the Command Line Tools (swift 5.9+).
#   ./build.sh            → build/Breeze.app
#   ./build.sh install    → also copies it to /Applications and opens it
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Breeze.app"
echo "▸ Compiling (release)…"
swift build -c release --arch arm64 2>&1 | grep -vE "^(\[|Building|Compiling|Write|Emitting|Planning)" || true
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Breeze"
[[ -x "$BIN" ]] || { echo "✗ Build failed"; exit 1; }

echo "▸ Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Breeze"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "▸ Building icon…"
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Signing (ad-hoc, for this Mac)…"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
xattr -cr "$APP" 2>/dev/null || true

echo "✓ Built $(pwd)/$APP"

if [[ "${1:-}" == "install" ]]; then
  osascript -e 'tell application "Breeze" to quit' >/dev/null 2>&1 || true
  rm -rf /Applications/Breeze.app
  cp -R "$APP" /Applications/
  echo "✓ Installed to /Applications/Breeze.app"
  open /Applications/Breeze.app
fi
