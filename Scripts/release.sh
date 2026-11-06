#!/bin/bash
# One GitHub release for every app. The Mac DMG and the Android and Fire TV APKs are files of the same release; its notes have a section for each app.
#
#   MAC=<version> MAC_BUILD=<build> ANDROID=<version> Scripts/release.sh <tag> <notes file>
#   e.g.  MAC=2.4.0 MAC_BUILD=240 ANDROID=0.9.1 Scripts/release.sh 2026.10.14 docs/releases/2026.10.14.md
#
# Build the files first: macos/Scripts/release-signed.sh <version> <build> (signs, notarizes) and android/build-release.sh <version> <code>.
#
# The order is the safety:
#   1. VERIFY every file (Scripts/verify-release-artifacts.sh): signing, notarization, privacy manifest, smoke test, signer pin, permissions, versions, checksums, dependency report, committed code.
#      Nothing is uploaded, drafted or published unless all of it passes.
#   2. UPLOAD as a DRAFT (not visible to anyone), then check that what arrived is exactly what was sent (size and SHA-256).
#   3. PUBLISH the draft, and only then add the Mac DMG to the update feed (the feed must never point at a release that is not public). The feed step can be run again safely.
#   4. README download table and the website.
# A failure in 2 deletes the unpublished draft; a failure in 3 or 4 leaves a published release and says which step to repeat. REPLACE=1 is needed to replace a published tag.
set -euo pipefail
ROOT="${RELEASE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"; cd "$ROOT"
TAG="${1:?usage: Scripts/release.sh <tag> <notes file>}"; NOTES="${2:?notes file}"
: "${MAC:?set MAC to the Mac version}" "${MAC_BUILD:?set MAC_BUILD}" "${ANDROID:?set ANDROID to the Android version}"
GH="${GH:-gh}"; REPO="${RELEASES_REPO:-lokeshreddyveer/streamsetu}"
DMG="macos/dist/StreamSetu-$MAC.dmg"; TV="android/dist/$ANDROID/streamsetu-tv-$ANDROID.apk"; PHONE="android/dist/$ANDROID/StreamSetu-Android-$ANDROID.apk"
export MAC MAC_BUILD ANDROID TAG NOTES DMG TV PHONE

# 1. Verify. Read-only; a failure here has changed nothing anywhere.
Scripts/verify-release-artifacts.sh || { echo "✘ Verification failed. Nothing was uploaded or published."; exit 1; }

BODY="$(mktemp)"; DOWNLOADS="$(mktemp -d)"; DRAFT_MADE=0; PUBLISHED=0
cleanup() {
  rm -rf "$BODY" "$DOWNLOADS"
  if [ "$DRAFT_MADE" = "1" ] && [ "$PUBLISHED" = "0" ]; then
    echo "✘ Stopped before publishing: removing the unpublished draft $TAG (nothing was ever visible)."
    "$GH" release delete "$TAG" --repo "$REPO" --yes >/dev/null 2>&1 || echo "  ! could not remove the draft; remove it by hand: gh release delete $TAG"
  fi
}
trap cleanup EXIT

{ cat "$NOTES"; printf '\n## Checksums (SHA-256)\n\n'; for f in "$DMG" "$TV" "$PHONE"; do printf '`%s`  %s\n\n' "$(basename "$f")" "$(shasum -a 256 "$f" | cut -d' ' -f1)"; done; } > "$BODY"
TITLE="StreamSetu $(sed -n 's/^# *//p' "$NOTES" | head -1)"; [ "$TITLE" = "StreamSetu " ] && TITLE="StreamSetu $TAG"

# 2. Upload as a draft.
STATE="$("$GH" release view "$TAG" --repo "$REPO" --json isDraft --jq '.isDraft' 2>/dev/null || echo none)"
if [ "$STATE" = "true" ]; then "$GH" release delete "$TAG" --repo "$REPO" --yes >/dev/null 2>&1 || true; fi          # an earlier unpublished draft of the same tag
if [ "$STATE" = "false" ]; then
  [ "${REPLACE:-0}" = "1" ] || { echo "✘ $TAG is already published; set REPLACE=1 to replace its files."; exit 1; }
  "$GH" release delete "$TAG" --repo "$REPO" --yes
fi
DRAFT_MADE=1
"$GH" release create "$TAG" "$DMG" "$TV" "$PHONE" --repo "$REPO" --draft --title "$TITLE" --notes-file "$BODY"

# What arrived must be exactly what was sent.
for f in "$DMG" "$TV" "$PHONE"; do
  name="$(basename "$f")"; want_size="$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f")"; want_sha="$(shasum -a 256 "$f" | cut -d' ' -f1)"
  row="$("$GH" release view "$TAG" --repo "$REPO" --json assets --jq ".assets[] | select(.name==\"$name\") | [.size, (.digest // \"\")] | @tsv" 2>/dev/null || true)"
  size="$(cut -f1 <<<"$row")"; digest="$(cut -f2 <<<"$row")"
  [ "$size" = "$want_size" ] || { echo "✘ $name arrived with size '$size', not $want_size."; exit 1; }
  if [ -n "$digest" ]; then
    [ "$digest" = "sha256:$want_sha" ] || { echo "✘ $name arrived with a different checksum ($digest)."; exit 1; }
  else
    "$GH" release download "$TAG" --repo "$REPO" --pattern "$name" --dir "$DOWNLOADS" >/dev/null
    [ "$(shasum -a 256 "$DOWNLOADS/$name" | cut -d' ' -f1)" = "$want_sha" ] || { echo "✘ $name arrived with a different checksum."; exit 1; }
  fi
  echo "  ✔ $name arrived intact"
done

# 3. Publish, then the update feed.
"$GH" release edit "$TAG" --repo "$REPO" --draft=false --latest
PUBLISHED=1
RELEASE_TAG="$TAG" macos/Scripts/update-appcast.sh "$MAC" "$MAC_BUILD" "$(sed -n 's/^- //p' "$NOTES" | head -1)" \
  || { echo "! The release is published, but the Mac update feed was not updated. Run again: RELEASE_TAG=$TAG macos/Scripts/update-appcast.sh $MAC $MAC_BUILD"; exit 1; }

# 4. The README's download table points at this release, so it is rewritten here; the feature table (docs/FEATURES.md) is edited by hand with the features.
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
