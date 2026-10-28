#!/bin/bash
# Builds a signed, notarized, stapled Breeze-<version>.dmg ready to publish,
# plus an appcast.json for the in-app update checker.
#
# The script checks for your Developer ID certificate and notarization login, and walks
# you through the one-time setup if either is missing (see docs/RELEASE.md).
#
# Usage (Team ID is detected from your Developer ID certificate):
#   ./scripts/release.sh
#   TEAM_ID=ABCDE12345 NOTARY_PROFILE=breeze-notary DOWNLOAD_BASE=https://example.com/breeze ./scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARY_PROFILE="${NOTARY_PROFILE:-breeze-notary}"
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://nanket.github.io/breeze}"
IDENTITY="Developer ID Application"

# ── Pre-flight: signing certificate ────────────────────────────────────────────
CERT_LINE=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 || true)
if [[ -z "$CERT_LINE" ]]; then
  cat <<MSG
✗ No "Developer ID Application" certificate found in your keychain.
  Create one (takes a minute):
    1. Xcode → Settings… → Accounts → add your Apple ID if it isn't listed.
    2. Select your team → Manage Certificates… → "+" → Developer ID Application.
  Then run this script again.
MSG
  exit 1
fi
if [[ -z "${TEAM_ID:-}" ]]; then
  TEAM_ID=$(echo "$CERT_LINE" | sed -E 's/.*\(([A-Z0-9]{10})\)".*/\1/')
fi
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || { echo "✗ Couldn't read your Team ID. Run: TEAM_ID=XXXXXXXXXX ./scripts/release.sh"; exit 1; }
echo "▸ Signing as: $(echo "$CERT_LINE" | sed -E 's/.*"(.*)".*/\1/')"

# ── Pre-flight: notarization credentials ───────────────────────────────────────
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  cat <<MSG
▸ One-time setup: save your notarization login in the keychain.
  You need an app-specific password: https://account.apple.com → Sign-In and Security → App-Specific Passwords.
MSG
  read -r -p "  Apple ID email: " APPLE_ID
  xcrun notarytool store-credentials "$NOTARY_PROFILE" --apple-id "$APPLE_ID" --team-id "$TEAM_ID"
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Resources/Info.plist)
OUT="build/release/$VERSION"
ARCHIVE="$OUT/Breeze.xcarchive"
EXPORT="$OUT/export"
DMG="$OUT/Breeze-$VERSION.dmg"

if grep -q '"https://example.com\|@example.com"' Sources/Breeze/Core/AppConfig.swift; then
  echo "⚠︎ AppConfig.swift still has example.com placeholders (support email, website, update feed)."
  read -r -p "Continue anyway? [y/N] " ok; [[ "$ok" == "y" ]] || exit 1
fi

rm -rf "$OUT" && mkdir -p "$OUT"

echo "▸ Archiving $VERSION ($BUILD)…"
xcodebuild -project Breeze.xcodeproj -scheme Breeze -configuration Release -quiet \
  -archivePath "$ARCHIVE" archive \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp"
[[ -d "$ARCHIVE" ]] || { echo "✗ Archive failed"; exit 1; }

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$IDENTITY</string>
</dict></plist>
PLIST

echo "▸ Exporting signed app…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist "$OUT/ExportOptions.plist" -quiet
APP="$EXPORT/Breeze.app"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "▸ Building DMG…"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Breeze $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --sign "$IDENTITY" --timestamp "$DMG"

echo "▸ Notarizing (a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

echo "▸ Installing the signed build in /Applications…"
osascript -e 'tell application "Breeze" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf /Applications/Breeze.app && ditto "$APP" /Applications/Breeze.app

echo "▸ Writing appcast.json…"
cat > "$OUT/appcast.json" <<JSON
{
  "version": "$VERSION",
  "build": $BUILD,
  "url": "$DOWNLOAD_BASE/Breeze-$VERSION.dmg",
  "minimumOS": "14.0",
  "notes": "Edit me: what's new in $VERSION."
}
JSON

shasum -a 256 "$DMG" | tee "$OUT/SHA256.txt"
echo "✓ Done: $DMG"
echo "  Next: publish the DMG and appcast.json at $DOWNLOAD_BASE (for example, the GitHub Pages site)."
open "$OUT"
