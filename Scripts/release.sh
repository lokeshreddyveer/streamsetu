#!/bin/bash
# One GitHub release for every app. The Mac DMG and the Android and Fire TV APKs are files of the same release; its notes have a section for each app.
#
#   MAC=<version> MAC_BUILD=<build> ANDROID=<version> Scripts/release.sh <tag> <notes file>
#   e.g.  MAC=2.4.0 MAC_BUILD=240 ANDROID=0.9.1 Scripts/release.sh 2026.10.14 docs/releases/2026.10.14.md
#
# Build the files first: macos/Scripts/release-signed.sh <version> <build> (signs, notarizes) and android/build-release.sh <version> <code>.
# The notes file is written by hand (one section per app). This script adds the SHA-256 of every file, uploads everything, and adds the Mac DMG to the update feed.
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="${1:?usage: Scripts/release.sh <tag> <notes file>}"; NOTES="${2:?notes file}"
: "${MAC:?set MAC to the Mac version}" "${MAC_BUILD:?set MAC_BUILD}" "${ANDROID:?set ANDROID to the Android version}"
REPO="${RELEASES_REPO:-lokeshreddyveer/streamsetu}"
DMG="macos/dist/StreamSetu-$MAC.dmg"; TV="android/dist/$ANDROID/StreamSetu-FireTV-$ANDROID.apk"; PHONE="android/dist/$ANDROID/StreamSetu-Android-$ANDROID.apk"
for f in "$DMG" "$TV" "$PHONE" "$NOTES"; do [ -f "$f" ] || { echo "✘ $f not found"; exit 1; }; done
xcrun stapler validate "$DMG" >/dev/null 2>&1 || { echo "✘ $DMG is not stapled/notarized. Not publishing."; exit 1; }
BODY="$(mktemp)"; trap 'rm -f "$BODY"' EXIT
{ cat "$NOTES"; printf '\n## Checksums (SHA-256)\n\n'; for f in "$DMG" "$TV" "$PHONE"; do printf '`%s`  %s\n\n' "$(basename "$f")" "$(shasum -a 256 "$f" | cut -d' ' -f1)"; done; } > "$BODY"
TITLE="StreamSetu $(sed -n 's/^# *//p' "$NOTES" | head -1)"; [ "$TITLE" = "StreamSetu " ] && TITLE="StreamSetu $TAG"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG" "$TV" "$PHONE" --repo "$REPO" --clobber
  gh release edit "$TAG" --repo "$REPO" --title "$TITLE" --notes-file "$BODY" --latest
else
  gh release create "$TAG" "$DMG" "$TV" "$PHONE" --repo "$REPO" --title "$TITLE" --notes-file "$BODY" --latest
fi
RELEASE_TAG="$TAG" macos/Scripts/update-appcast.sh "$MAC" "$MAC_BUILD" "$(sed -n 's/^- //p' "$NOTES" | head -1)"
echo "✔ published: https://github.com/$REPO/releases/tag/$TAG"
