#!/bin/bash
# Packages dist/StreamSetu.app into dist/StreamSetu-<version><suffix>.dmg with an Applications shortcut.
#   DMG_SUFFIX=-AppleSilicon | -Intel   names the two disk images; a release has no universal one.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-dist/StreamSetu.app}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="dist/StreamSetu-$VERSION${DMG_SUFFIX:-}.dmg"
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
# "Resource busy" comes from a disk image of the same name, or the volume "StreamSetu", still mounted from an earlier run or check. They are detached first, and the creation is tried
# three times (the volume can take a moment to let go) before it is given up.
for mounted in $(hdiutil info | awk -v n="$(basename "$DMG")" 'BEGIN{RS="================================================"} index($0, n) {for (i = 1; i <= NF; i++) if ($i ~ /^\/dev\/disk[0-9]+$/) {print $i; break}}'); do
  hdiutil detach "$mounted" -force >/dev/null 2>&1 || true
done
made=0
for attempt in 1 2 3; do
  if hdiutil create -volname "StreamSetu" -srcfolder "$STAGE" -ov -format UDZO -imagekey zlib-level=9 "$DMG" >/dev/null 2>&1; then made=1; break; fi
  echo "  (the disk image could not be created, attempt $attempt of 3; waiting)"; sleep $((attempt * 4)); rm -f "$DMG"
done
[ "$made" = 1 ] || { echo "✘ the disk image could not be created. Check 'hdiutil info' for a StreamSetu image that is still attached."; exit 1; }
rm -rf "$STAGE"
if [ -n "${SIGN_IDENTITY:-}" ]; then codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"; fi
echo "✔ $DMG ($(du -h "$DMG" | cut -f1))"
