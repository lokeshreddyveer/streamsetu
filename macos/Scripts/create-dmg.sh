#!/bin/bash
# Packages dist/StreamSetu.app into dist/StreamSetu-<version>.dmg with an Applications shortcut.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-dist/StreamSetu.app}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="dist/StreamSetu-$VERSION.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp -R Distribution/DMG/. "$STAGE/" 2>/dev/null || true
# The disk image shows the StreamSetu icon too.
if [ -f Resources/Branding/StreamSetu.icns ]; then
  cp Resources/Branding/StreamSetu.icns "$STAGE/.VolumeIcon.icns"
  SetFile -a C "$STAGE" 2>/dev/null || true
fi
rm -f "$DMG"
hdiutil create -volname "StreamSetu" -srcfolder "$STAGE" -ov -format UDZO -imagekey zlib-level=9 "$DMG" >/dev/null
rm -rf "$STAGE"
if [ -n "${SIGN_IDENTITY:-}" ]; then codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"; fi
echo "✔ $DMG ($(du -h "$DMG" | cut -f1))"
