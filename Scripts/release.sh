#!/bin/bash
# One GitHub release for every app. The Mac DMG and the Android and Fire TV APKs are files of the same release; its notes have a section for each app.
#
#   MAC=<version> MAC_BUILD=<build> ANDROID=<version> Scripts/release.sh <tag> <notes file>
#   e.g.  MAC=2.4.0 MAC_BUILD=240 ANDROID=0.9.1 Scripts/release.sh 2026.10.14 docs/releases/2026.10.14.md
#
# Build the files first: macos/Scripts/release-signed.sh <version> <build> (signs, notarizes) and android/build-release.sh <version> <code>.
# The website under web/ is refreshed at the end (its Download and What's new pages read this release).
# The notes file is written by hand (one section per app). This script adds the SHA-256 of every file, uploads everything, and adds the Mac DMG to the update feed.
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="${1:?usage: Scripts/release.sh <tag> <notes file>}"; NOTES="${2:?notes file}"
: "${MAC:?set MAC to the Mac version}" "${MAC_BUILD:?set MAC_BUILD}" "${ANDROID:?set ANDROID to the Android version}"
REPO="${RELEASES_REPO:-lokeshreddyveer/streamsetu}"
DMG="macos/dist/StreamSetu-$MAC.dmg"; TV="android/dist/$ANDROID/streamsetu-tv-$ANDROID.apk"; PHONE="android/dist/$ANDROID/StreamSetu-Android-$ANDROID.apk"
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
# The README's download table points at this release, so it is rewritten here; the feature table is edited by hand with the features.
IOS_VERSION="$(sed -n 's/^VERSION = "\(.*\)"/\1/p' ios/Scripts/generate-project.py | head -1)"
python3 - "$TAG" "$MAC" "$ANDROID" "$IOS_VERSION" <<'PY'
import re, sys
tag, mac, android, ios = sys.argv[1:5]
text = open("README.md").read()
text = re.sub(r"releases/download/[^/]+/StreamSetu-\d[\d.]*\.dmg", f"releases/download/{tag}/StreamSetu-{mac}.dmg", text)
text = text.replace(re.search(r"`StreamSetu-\d[\d.]*\.dmg`", text).group(0), f"`StreamSetu-{mac}.dmg`")
# The television file is streamsetu-tv-<version>.apk (it was StreamSetu-FireTV-<version>.apk before 0.20.0); the phone file is StreamSetu-Android-<version>.apk.
for old, new in ((r"(?:StreamSetu-FireTV|streamsetu-tv)", "streamsetu-tv"), (r"StreamSetu-Android", "StreamSetu-Android")):
    text = re.sub(rf"releases/download/[^/]+/{old}-\d[\d.]*\.apk", f"releases/download/{tag}/{new}-{android}.apk", text)
    text = re.sub(rf"`{old}-\d[\d.]*\.apk`", f"`{new}-{android}.apk`", text)
text = re.sub(r"(testflight\.apple\.com/join/\w+\), version )[\d.]+", rf"\g<1>{ios}", text)
open("README.md", "w").write(text)
PY
git add README.md && git commit -qm "README download table for $TAG" || true
# The website reads the same notes and version numbers, so it is refreshed with every release.
IOS="$(sed -n 's/^VERSION = "\(.*\)"/\1/p' ios/Scripts/generate-project.py | head -1)"
( cd web && node scripts/sync-releases.mjs --tag "$TAG" --mac "$MAC" --android "$ANDROID" --ios "$IOS" && ./host.sh restart ) || echo "! The website was not refreshed. Run web/host.sh start"
echo "✔ published: https://github.com/$REPO/releases/tag/$TAG"
