#!/bin/bash
# One GitHub release for EVERY app. The two Mac DMGs (Apple silicon and Intel; there is no universal one), the Android and Fire TV APKs and the two Windows zips (x64 and arm64) are files of the same release; its notes have a section for each app.
# An app that did not change still ships: its existing files go into the release again (the checks confirm that its source has not changed since they were built). iPhone and iPad are on the App Store.
#
#   MAC=<version> MAC_BUILD=<build> ANDROID=<version> WINDOWS=<version> Scripts/release.sh <tag> <notes file>
#   e.g.  MAC=2.19.1 MAC_BUILD=363 ANDROID=0.28.0 WINDOWS=0.2.0 Scripts/release.sh 2026.11.27 docs/releases/2026.11.27.md
#   PARTIAL=1 lets one of MAC, ANDROID and WINDOWS be left out on purpose (the Mac update feed, and the README rows of the app left out, are then left as they are). Without it a missing one stops the release.
#
# Build the files first: macos/Scripts/release-signed.sh <version> <build> (signs, notarizes), android/build-release.sh <version> <code>, and put the two Windows zips in windows/native/dist/.
#
# The order is the safety:
#   1. VERIFY every file (Scripts/verify-release-artifacts.sh): signing, notarization, privacy manifest, smoke test, signer pin, permissions, versions, checksums, dependency report, committed code.
#      Nothing is uploaded, drafted or published unless all of it passes.
#   2. UPLOAD as a DRAFT (not visible to anyone), then check that what arrived is exactly what was sent (size and SHA-256).
#   3. PUBLISH the draft, and only then add both Mac DMGs to the update feed (the feed must never point at a release that is not public). The feed step can be run again safely.
#   4. README download table and the website.
# A failure in 2 deletes the unpublished draft; a failure in 3 or 4 leaves a published release and says which step to repeat. REPLACE=1 is needed to replace a published tag.
set -euo pipefail
ROOT="${RELEASE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"; cd "$ROOT"
TAG="${1:?usage: Scripts/release.sh <tag> <notes file>}"; NOTES="${2:?notes file}"
MAC="${MAC:-}"; MAC_BUILD="${MAC_BUILD:-}"
if [ -n "$MAC" ] && [ -z "$MAC_BUILD" ]; then echo "✘ MAC is set but MAC_BUILD is not. Nothing was uploaded or published."; exit 1; fi
ANDROID="${ANDROID:-}"; WINDOWS="${WINDOWS:-}"
[ -n "$MAC$ANDROID$WINDOWS" ] || { echo "✘ set MAC (and MAC_BUILD), ANDROID and WINDOWS. Nothing was uploaded or published."; exit 1; }
if [ "${PARTIAL:-0}" != "1" ] && { [ -z "$MAC" ] || [ -z "$ANDROID" ] || [ -z "$WINDOWS" ]; }; then
  echo "✘ A release holds every app: MAC, ANDROID and WINDOWS must all be set (PARTIAL=1 leaves one out on purpose). Nothing was uploaded or published."; exit 1
fi
GH="${GH:-gh}"; REPO="${RELEASES_REPO:-lokeshreddyveer/streamsetu}"
DMG_ARM="${MAC:+macos/dist/StreamSetu-$MAC-AppleSilicon.dmg}"; DMG_INTEL="${MAC:+macos/dist/StreamSetu-$MAC-Intel.dmg}"; TV="${ANDROID:+android/dist/$ANDROID/streamsetu-tv-$ANDROID.apk}"; PHONE="${ANDROID:+android/dist/$ANDROID/StreamSetu-Android-$ANDROID.apk}"
# Windows: two zips (x64 and arm64) in windows/native/dist/, built elsewhere (the verification opens them and checks their .sha256 files).
WIN="${WINDOWS:+windows/native/dist/StreamSetu-Windows-$WINDOWS.zip}"; WIN_ARM="${WINDOWS:+windows/native/dist/StreamSetu-Windows-$WINDOWS-arm64.zip}"
export MAC MAC_BUILD ANDROID WINDOWS TAG NOTES DMG_ARM DMG_INTEL TV PHONE WIN WIN_ARM

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

{ cat "$NOTES"; printf '\n## Checksums (SHA-256)\n\n'; for f in ${DMG_ARM:+"$DMG_ARM" "$DMG_INTEL"} ${TV:+"$TV" "$PHONE"} ${WIN:+"$WIN" "$WIN_ARM"}; do printf '`%s`  %s\n\n' "$(basename "$f")" "$(shasum -a 256 "$f" | cut -d' ' -f1)"; done; } > "$BODY"
TITLE="StreamSetu $(sed -n 's/^# *//p' "$NOTES" | head -1)"; [ "$TITLE" = "StreamSetu " ] && TITLE="StreamSetu $TAG"

# 2. Upload as a draft.
STATE="$("$GH" release view "$TAG" --repo "$REPO" --json isDraft --jq '.isDraft' 2>/dev/null || echo none)"
if [ "$STATE" = "true" ]; then "$GH" release delete "$TAG" --repo "$REPO" --yes >/dev/null 2>&1 || true; fi          # an earlier unpublished draft of the same tag
if [ "$STATE" = "false" ]; then
  [ "${REPLACE:-0}" = "1" ] || { echo "✘ $TAG is already published; set REPLACE=1 to replace its files."; exit 1; }
  "$GH" release delete "$TAG" --repo "$REPO" --yes
fi
DRAFT_MADE=1
"$GH" release create "$TAG" ${DMG_ARM:+"$DMG_ARM" "$DMG_INTEL"} ${TV:+"$TV" "$PHONE"} ${WIN:+"$WIN" "$WIN_ARM"} --repo "$REPO" --draft --title "$TITLE" --notes-file "$BODY"

# What arrived must be exactly what was sent.
for f in ${DMG_ARM:+"$DMG_ARM" "$DMG_INTEL"} ${TV:+"$TV" "$PHONE"} ${WIN:+"$WIN" "$WIN_ARM"}; do
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
if [ -n "$MAC" ]; then
  RELEASE_TAG="$TAG" macos/Scripts/update-appcast.sh "$MAC" "$MAC_BUILD" "$(sed -n 's/^- //p' "$NOTES" | head -1)" \
    || { echo "! The release is published, but the Mac update feed was not updated. Run again: RELEASE_TAG=$TAG macos/Scripts/update-appcast.sh $MAC $MAC_BUILD"; exit 1; }
fi

# 4. The README's download table points at this release, so it is rewritten here; the feature table (docs/FEATURES.md) is edited by hand with the features.
IOS_VERSION="$(sed -n 's/^VERSION = "\(.*\)"/\1/p' ios/Scripts/generate-project.py | head -1)"
python3 - "$TAG" "$MAC" "$ANDROID" "$IOS_VERSION" "${WINDOWS:-}" <<'PY'
import re, sys
tag, mac, android, ios, windows = sys.argv[1:6]
text = open("README.md").read()
if mac:   # a release without a Mac file leaves the Mac row pointing at the last Mac release
    # Two Mac files, Apple silicon and Intel (there is no universal one): the whole Mac row is written again, so it is right whatever it said before.
    base = f"../../releases/download/{tag}/StreamSetu-{mac}"
    row = (f"| **Mac** | [`StreamSetu-{mac}-AppleSilicon.dmg`]({base}-AppleSilicon.dmg) (M-series Macs), [`StreamSetu-{mac}-Intel.dmg`]({base}-Intel.dmg) (Intel Macs); "
           f"one release holds every app | Signed and notarized by Apple. Updates itself, with the file for your Mac. |")
    text, n = re.subn(r"(?m)^\| \*\*Mac\*\* \|.*$", lambda m: row, text, count=1)
    if n == 0: sys.exit("the README has no Mac row to update")
# The television file is streamsetu-tv-<version>.apk (it was StreamSetu-FireTV-<version>.apk before 0.20.0); the phone file is StreamSetu-Android-<version>.apk.
for old, new in (((r"(?:StreamSetu-FireTV|streamsetu-tv)", "streamsetu-tv"), (r"StreamSetu-Android", "StreamSetu-Android")) if android else ()):
    text = re.sub(rf"releases/download/[^/]+/{old}-\d[\d.]*\.apk", f"releases/download/{tag}/{new}-{android}.apk", text)
    text = re.sub(rf"`{old}-\d[\d.]*\.apk`", f"`{new}-{android}.apk`", text)
if windows:   # the x64 zip and the arm64 zip (the suffix is kept)
    text = re.sub(r"releases/download/[^/]+/StreamSetu-Windows-\d[\d.]*(-arm64)?\.zip", lambda m: f"releases/download/{tag}/StreamSetu-Windows-{windows}{m.group(1) or ''}.zip", text)
    text = re.sub(r"`StreamSetu-Windows-\d[\d.]*(-arm64)?\.zip`", lambda m: f"`StreamSetu-Windows-{windows}{m.group(1) or ''}.zip`", text)
text = re.sub(r"(testflight\.apple\.com/join/\w+\), version )[\d.]+", rf"\g<1>{ios}", text)
open("README.md", "w").write(text)
PY
git add README.md && git commit -qm "README download table for $TAG" || true
# The website reads the same notes and version numbers, so it is refreshed with every release.
IOS="$(sed -n 's/^VERSION = "\(.*\)"/\1/p' ios/Scripts/generate-project.py | head -1)"
SITE_ANDROID="${ANDROID:-$(sed -n 's/.*`StreamSetu-Android-\([0-9][0-9.]*[0-9]\)\.apk`.*/\1/p' README.md | head -1)}"   # the Android version still current when this release has none
SITE_MAC="${MAC:-$(sed -nE 's/.*`StreamSetu-([0-9][0-9.]*[0-9])(-AppleSilicon|-Intel)?\.dmg`.*/\1/p' README.md | head -1)}"   # the Mac version still current when this release has none
( cd web && node scripts/sync-releases.mjs --tag "$TAG" --mac "$SITE_MAC" --android "$SITE_ANDROID" --ios "$IOS" && ./host.sh restart ) || echo "! The website was not refreshed. Run web/host.sh start"
echo "✔ published: https://github.com/$REPO/releases/tag/$TAG"
