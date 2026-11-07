#!/bin/bash
# Every check a release must pass BEFORE anything is uploaded or published. Read-only: it changes nothing and talks to GitHub only to ask whether the tag is free.
#
#   MAC=<v> MAC_BUILD=<b> ANDROID=<v> TAG=<tag> NOTES=<file> Scripts/verify-release-artifacts.sh
#
# Hard gates (any one failing stops the release; all failures are listed, not only the first):
#   * the code the files were built from is the committed code (clean tree, and the build records the same commit)
#   * Mac: the DMG is notarized and stapled, the app inside is signed with the Hardened Runtime and accepted by Gatekeeper, its version is the one being released, and the packaged app passes
#          macos/Scripts/verify-release.sh (signature, privacy manifest equal to the source, no stray paths, and the smoke test that plays a video through the packaged app)
#   * Android: both APKs verify, are signed by the pinned release certificate (android/release-signer.sha256), carry exactly the allowed permissions (android/release-permissions.txt),
#              have the right package and version, are the same file, and match the checksums the build recorded
#   * the dependency report (Scripts/audit-dependencies.py --strict) is clean
#   * the notes describe this release; the tag is free (or REPLACE=1 says the person means to replace it)
#
# Tools can be replaced from the environment (HDIUTIL, CODESIGN, SPCTL, XCRUN, APKSIGNER, AAPT, GH, PYTHON3) so the gates themselves are tested with stand-ins (Scripts/test-release-gates.sh).
set -uo pipefail
ROOT="${RELEASE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"; cd "$ROOT"
: "${MAC:?set MAC}" "${MAC_BUILD:?set MAC_BUILD}" "${ANDROID:?set ANDROID}" "${TAG:?set TAG}" "${NOTES:?set NOTES}"
HDIUTIL="${HDIUTIL:-hdiutil}"; CODESIGN="${CODESIGN:-codesign}"; SPCTL="${SPCTL:-spctl}"; XCRUN="${XCRUN:-xcrun}"; GH="${GH:-gh}"; PYTHON3="${PYTHON3:-python3}"
BT="$(ls -d "$HOME"/Library/Android/sdk/build-tools/* 2>/dev/null | sort -V | tail -1)"
APKSIGNER="${APKSIGNER:-$BT/apksigner}"; AAPT="${AAPT:-$BT/aapt}"
REPO="${RELEASES_REPO:-lokeshreddyveer/streamsetu}"
DMG="${DMG:-macos/dist/StreamSetu-$MAC.dmg}"; TV="${TV:-android/dist/$ANDROID/streamsetu-tv-$ANDROID.apk}"; PHONE="${PHONE:-android/dist/$ANDROID/StreamSetu-Android-$ANDROID.apk}"
FAILED=0; MNT=""
ok()  { echo "  ✔ $1"; }
bad() { echo "  ✘ $1"; FAILED=$((FAILED + 1)); }
cleanup() { [ -n "$MNT" ] && "$HDIUTIL" detach "$MNT" -quiet >/dev/null 2>&1; [ -n "$MNT" ] && rmdir "$MNT" 2>/dev/null; true; }
trap cleanup EXIT

echo "Verifying release $TAG (Mac $MAC build $MAC_BUILD, Android $ANDROID)"

echo "Files"
for f in "$DMG" "$TV" "$PHONE" "$NOTES"; do [ -f "$f" ] && ok "$f" || bad "$f is missing"; done

echo "Source"
DIRTY="$(git status --porcelain -- macos android ios Scripts web windows 2>/dev/null | grep -v '^??.*dist/' | head -5)"
if [ -z "$DIRTY" ]; then ok "no uncommitted changes in the code"; else bad "uncommitted changes in the code (a release is built from committed code only):"; echo "$DIRTY" | sed 's/^/      /'; fi
HEAD_SHA="$(git rev-parse HEAD 2>/dev/null || echo none)"
for rec in "macos/dist/StreamSetu-$MAC.commit" "android/dist/$ANDROID/BUILD-COMMIT.txt"; do
  if [ -f "$rec" ]; then [ "$(tr -d '[:space:]' < "$rec")" = "$HEAD_SHA" ] && ok "$rec is this commit" || bad "$rec: the files were built from another commit than HEAD ($HEAD_SHA); build again"
  else bad "$rec is missing (the build records the commit it was made from)"; fi
done

echo "Mac"
if [ -f "$DMG" ]; then
  "$XCRUN" stapler validate "$DMG" >/dev/null 2>&1 && ok "DMG is notarized and stapled" || bad "DMG is not notarized and stapled"
  "$SPCTL" --assess --type open --context context:primary-signature "$DMG" >/dev/null 2>&1 && ok "Gatekeeper accepts the DMG" || bad "Gatekeeper does not accept the DMG"
  MNT="$(mktemp -d)"
  if "$HDIUTIL" attach -readonly -nobrowse -noautoopen -mountpoint "$MNT" "$DMG" -quiet >/dev/null 2>&1; then
    APP="$(ls -d "$MNT"/*.app 2>/dev/null | head -1)"
    if [ -n "$APP" ]; then
      "$CODESIGN" --verify --strict --deep "$APP" >/dev/null 2>&1 && ok "app signature is valid" || bad "app signature is not valid"
      # Read the whole output first: with pipefail, grep -q can stop early and make codesign fail on a closed pipe, which reported a false "off".
      SIGN_INFO="$("$CODESIGN" -dv "$APP" 2>&1)"
      grep -q "flags=.*runtime" <<<"$SIGN_INFO" && ok "Hardened Runtime is on" || bad "Hardened Runtime is off"
      "$SPCTL" --assess --type execute "$APP" >/dev/null 2>&1 && ok "Gatekeeper accepts the app" || bad "Gatekeeper does not accept the app"
      V="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null)"; B="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null)"
      [ "$V" = "$MAC" ] && [ "$B" = "$MAC_BUILD" ] && ok "app is version $V build $B" || bad "the app inside is version '$V' build '$B', not $MAC build $MAC_BUILD"
      if macos/Scripts/verify-release.sh "$APP" > "$(mktemp)" 2>&1; then ok "packaged checks pass (privacy manifest, paths, smoke test)"; else bad "the packaged-app checks failed (run macos/Scripts/verify-release.sh on the app)"; fi
    else bad "no app inside the DMG"; fi
  else bad "the DMG could not be opened"; MNT=""; fi
fi

echo "Android"
PIN="$(tr -d '[:space:]' < android/release-signer.sha256 2>/dev/null)"
[ -n "$PIN" ] && ok "signer pin present" || bad "android/release-signer.sha256 is missing"
for apk in "$TV" "$PHONE"; do
  [ -f "$apk" ] || continue
  N="$(basename "$apk")"
  OUT="$("$APKSIGNER" verify --print-certs "$apk" 2>&1)"; RC=$?
  if [ $RC -eq 0 ]; then ok "$N: signature verifies"; else bad "$N: signature does not verify"; fi
  SIG="$(grep -m1 "SHA-256 digest" <<<"$OUT" | awk '{print $NF}')"
  [ -n "$PIN" ] && [ "$SIG" = "$PIN" ] && ok "$N: signed by the pinned release certificate" || bad "$N: signer $SIG is not the pinned release certificate"
  BAD="$("$AAPT" dump badging "$apk" 2>/dev/null | head -1)"
  grep -q "name='app.streamsetu.tv'" <<<"$BAD" && ok "$N: package name" || bad "$N: wrong package name"
  grep -q "versionName='$ANDROID'" <<<"$BAD" && ok "$N: version $ANDROID" || bad "$N: version is not $ANDROID ($BAD)"
  PERMS="$("$AAPT" dump permissions "$apk" 2>/dev/null | grep '^uses-permission' | sed "s/.*name='\([^']*\)'.*/\1/" | sort)"
  if [ "$PERMS" = "$(sort android/release-permissions.txt 2>/dev/null)" ]; then ok "$N: permissions are exactly the allowed ones"; else bad "$N: permissions differ from android/release-permissions.txt:"; diff <(echo "$PERMS") <(sort android/release-permissions.txt 2>/dev/null) | sed 's/^/      /'; fi
done
if [ -f "$TV" ] && [ -f "$PHONE" ]; then cmp -s "$TV" "$PHONE" && ok "both APKs are the same file" || bad "the two APKs differ (the build makes one file and copies it)"; fi
SUMS="android/dist/$ANDROID/SHA256SUMS-$ANDROID.txt"
if [ -f "$SUMS" ]; then
  for apk in "$TV" "$PHONE"; do [ -f "$apk" ] || continue; want="$(grep -F "$(basename "$apk")" "$SUMS" | awk '{print $1}')"; have="$(shasum -a 256 "$apk" | awk '{print $1}')"
    [ -n "$want" ] && [ "$want" = "$have" ] && ok "$(basename "$apk"): checksum is the one the build recorded" || bad "$(basename "$apk"): checksum differs from what the build recorded"; done
else bad "$SUMS is missing"; fi

echo "Dependencies"
if "$PYTHON3" Scripts/audit-dependencies.py --strict >/dev/null 2>&1; then ok "dependency report is clean"; else bad "dependency report is not clean (vulnerable or could not be checked): run Scripts/audit-dependencies.py --strict"; fi

echo "Notes and tag"
if [ -f "$NOTES" ]; then
  grep -q '^# ' <<<"$(head -1 "$NOTES")" && ok "notes have a title" || bad "the notes' first line must be a '# title'"
  grep -q "$MAC" "$NOTES" && ok "notes name the Mac version" || bad "the notes do not mention Mac $MAC"
  grep -q "$ANDROID" "$NOTES" && ok "notes name the Android version" || bad "the notes do not mention Android $ANDROID"
fi
STATE="$("$GH" release view "$TAG" --repo "$REPO" --json isDraft --jq '.isDraft' 2>/dev/null || echo "none")"
case "$STATE" in
  none) ok "tag $TAG is free" ;;
  true) ok "tag $TAG exists only as an unpublished draft (it will be replaced)" ;;
  *) [ "${REPLACE:-0}" = "1" ] && ok "tag $TAG is published and REPLACE=1 was given" || bad "tag $TAG is already published (set REPLACE=1 only if replacing it is the intention)" ;;
esac

if [ $FAILED -eq 0 ]; then echo "✔ all release checks passed"; exit 0; fi
echo "✘ $FAILED release check(s) failed. Nothing was uploaded or published."; exit 1
