#!/bin/bash
# Packages a notarized Breeze.app (exported from Xcode Organizer → "Export Notarized App")
# into build/release/<version>/Breeze-<version>.dmg, ready for the website.
#
# Usage: ./scripts/package-notarized.sh [path/to/exported/folder-or-Breeze.app]
#        (default: ~/Desktop/Breeze/build/notarized)
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:-build/notarized}"
APP="$SRC"; [[ "$APP" == *.app ]] || APP=$(find "$SRC" -maxdepth 2 -name "Breeze.app" -type d | head -1)
[[ -d "$APP" ]] || { echo "✗ Couldn't find Breeze.app in $SRC. In Xcode Organizer click 'Export Notarized App' and save it there."; exit 1; }

echo "▸ Checking notarization ticket…"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
OUT="build/release/$VERSION"
DMG="$OUT/Breeze-$VERSION.dmg"
mkdir -p "$OUT"
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/Breeze.app"
ln -s /Applications "$STAGE/Applications"

echo "▸ Building $DMG…"
rm -f "$DMG"
hdiutil create -volname "Breeze $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --sign "Developer ID Application" --timestamp "$DMG"
rm -rf "$STAGE"

echo "▸ Installing the notarized build in /Applications…"
osascript -e 'tell application "Breeze" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf /Applications/Breeze.app && ditto "$APP" /Applications/Breeze.app

shasum -a 256 "$DMG" | tee "$OUT/SHA256.txt"
echo "✓ Done: $DMG  (next: publish it to the website)"
open "$OUT"
