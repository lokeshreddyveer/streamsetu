#!/bin/bash
# Every check a release must pass BEFORE anything is uploaded or published. Read-only: it changes nothing and talks to GitHub only to ask whether the tag is free.
#
#   MAC=<v> MAC_BUILD=<b> ANDROID=<v> TAG=<tag> NOTES=<file> Scripts/verify-release-artifacts.sh
#   Leave MAC unset for a release without a Mac file (the Mac checks are then skipped; every Android check still runs).
#   Leave ANDROID or WINDOWS (or MAC) unset to skip that app's checks (release.sh only allows it with PARTIAL=1). One of them must be given.
#
# Hard gates (any one failing stops the release; all failures are listed, not only the first):
#   * the code the files were built from is the committed code (clean tree, and the build records the same commit)
#   * Mac (each of the two DMGs, Apple silicon and Intel; there is no universal one): the DMG is notarized and stapled, the app inside has the architecture its name says (Apple silicon: arm64 only, build+1; Intel: x86_64 only), the app inside is signed with the Hardened Runtime and accepted by Gatekeeper, its version is the one being released, and the packaged app passes
#          macos/Scripts/verify-release.sh (signature, privacy manifest equal to the source, no stray paths, and the smoke test that plays a video through the packaged app)
#   * Android: both APKs verify, are signed by the pinned release certificate (android/release-signer.sha256), carry exactly the allowed permissions (android/release-permissions.txt),
#              have the right package and version, are the same file, and match the checksums the build recorded
#   * the dependency report (Scripts/audit-dependencies.py --strict) is clean
#   * the notes describe this release; the tag is free (or REPLACE=1 says the person means to replace it)
#
# Tools can be replaced from the environment (HDIUTIL, CODESIGN, SPCTL, XCRUN, LIPO, APKSIGNER, AAPT, GH, PYTHON3) so the gates themselves are tested with stand-ins (Scripts/test-release-gates.sh).
set -uo pipefail
ROOT="${RELEASE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"; cd "$ROOT"
MAC="${MAC:-}"; [ -n "$MAC" ] && : "${MAC_BUILD:?set MAC_BUILD}"
ANDROID="${ANDROID:-}"; WINDOWS="${WINDOWS:-}"; [ -n "$MAC$ANDROID$WINDOWS" ] || { echo "set MAC, ANDROID or WINDOWS"; exit 2; }
: "${TAG:?set TAG}" "${NOTES:?set NOTES}"
HDIUTIL="${HDIUTIL:-hdiutil}"; CODESIGN="${CODESIGN:-codesign}"; SPCTL="${SPCTL:-spctl}"; XCRUN="${XCRUN:-xcrun}"; LIPO="${LIPO:-lipo}"; GH="${GH:-gh}"; PYTHON3="${PYTHON3:-python3}"
BT="$(ls -d "$HOME"/Library/Android/sdk/build-tools/* 2>/dev/null | sort -V | tail -1)"
APKSIGNER="${APKSIGNER:-$BT/apksigner}"; AAPT="${AAPT:-$BT/aapt}"
REPO="${RELEASES_REPO:-lokeshreddyveer/streamsetu}"
DMG_ARM="${DMG_ARM:-macos/dist/StreamSetu-$MAC-AppleSilicon.dmg}"; DMG_INTEL="${DMG_INTEL:-macos/dist/StreamSetu-$MAC-Intel.dmg}"; TV="${TV:-${ANDROID:+android/dist/$ANDROID/streamsetu-tv-$ANDROID.apk}}"; PHONE="${PHONE:-${ANDROID:+android/dist/$ANDROID/StreamSetu-Android-$ANDROID.apk}}"
WIN="${WIN:-${WINDOWS:+windows/native/dist/StreamSetu-Windows-$WINDOWS.zip}}"; WIN_ARM="${WIN_ARM:-${WINDOWS:+windows/native/dist/StreamSetu-Windows-$WINDOWS-arm64.zip}}"
FAILED=0; MNT=""; MOUNTS=(); APPS=()
ok()  { echo "  ✔ $1"; }
bad() { echo "  ✘ $1"; FAILED=$((FAILED + 1)); }
cleanup() { for m in ${MOUNTS[@]+"${MOUNTS[@]}"}; do "$HDIUTIL" detach "$m" -quiet >/dev/null 2>&1; rmdir "$m" 2>/dev/null; done; true; }
trap cleanup EXIT

if [ -z "$MAC" ]; then DMG_ARM=""; DMG_INTEL=""; fi
echo "Verifying release $TAG (${MAC:+Mac $MAC build $MAC_BUILD}${ANDROID:+, Android $ANDROID}${WINDOWS:+, Windows $WINDOWS})"

echo "Files"
for f in ${DMG_ARM:+"$DMG_ARM" "$DMG_INTEL"} ${TV:+"$TV" "$PHONE"} ${WIN:+"$WIN" "$WIN_ARM"} "$NOTES"; do [ -f "$f" ] && ok "$f" || bad "$f is missing"; done

echo "Source"
DIRTY="$(git status --porcelain -- macos android ios Scripts web windows 2>/dev/null | grep -v '^??.*dist/' | head -5)"
if [ -z "$DIRTY" ]; then ok "no uncommitted changes in the code"; else bad "uncommitted changes in the code (a release is built from committed code only):"; echo "$DIRTY" | sed 's/^/      /'; fi
HEAD_SHA="$(git rev-parse HEAD 2>/dev/null || echo none)"
# A build must come from the code being released: the commit it records is HEAD, or the code of that app has not changed between that commit and HEAD (an app that did not change ships its
# existing files again).
same_source() {   # $1 the record file, $2 the app's source folder
  local rec="$1" dir="$2" sha
  if [ ! -f "$rec" ]; then bad "$rec is missing (the build records the commit it was made from)"; return; fi
  sha="$(tr -d '[:space:]' < "$rec")"
  if [ "$sha" = "$HEAD_SHA" ]; then ok "$rec is this commit"
  elif git cat-file -e "$sha^{commit}" 2>/dev/null && git diff --quiet "$sha" HEAD -- "$dir" 2>/dev/null; then ok "$rec: $dir has not changed since it was built ($(git rev-parse --short "$sha"))"
  else bad "$rec: the files were built from another commit than HEAD ($HEAD_SHA) and $dir has changed since; build again"; fi
}
[ -n "$MAC" ] && same_source "macos/dist/StreamSetu-$MAC.commit" macos
[ -n "$ANDROID" ] && same_source "android/dist/$ANDROID/BUILD-COMMIT.txt" android

# One Mac disk image: $1 the file, $2 the architectures the app inside must have (sorted, space separated), $3 the build number the app inside must carry.
verify_mac_dmg() {
  local file="$1" want="$2" wantbuild="$3" name; name="$(basename "$1")"
  echo "  $name"
  "$XCRUN" stapler validate "$file" >/dev/null 2>&1 && ok "$name: DMG is notarized and stapled" || bad "$name: DMG is not notarized and stapled"
  "$SPCTL" --assess --type open --context context:primary-signature "$file" >/dev/null 2>&1 && ok "$name: Gatekeeper accepts the DMG" || bad "$name: Gatekeeper does not accept the DMG"
  MNT="$(mktemp -d)"
  if "$HDIUTIL" attach -readonly -nobrowse -noautoopen -mountpoint "$MNT" "$file" -quiet >/dev/null 2>&1; then
    MOUNTS+=("$MNT")          # kept mounted until the end: the secrets scan below reads each app
    local APP; APP="$(ls -d "$MNT"/*.app 2>/dev/null | head -1)"
    if [ -n "$APP" ]; then
      APPS+=("$APP")
      "$CODESIGN" --verify --strict --deep "$APP" >/dev/null 2>&1 && ok "$name: app signature is valid" || bad "$name: app signature is not valid"
      # Read the whole output first: with pipefail, grep -q can stop early and make codesign fail on a closed pipe, which reported a false "off".
      local SIGN_INFO; SIGN_INFO="$("$CODESIGN" -dv "$APP" 2>&1)"
      grep -q "flags=.*runtime" <<<"$SIGN_INFO" && ok "$name: Hardened Runtime is on" || bad "$name: Hardened Runtime is off"
      "$SPCTL" --assess --type execute "$APP" >/dev/null 2>&1 && ok "$name: Gatekeeper accepts the app" || bad "$name: Gatekeeper does not accept the app"
      local V B; V="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null)"; B="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null)"
      [ "$V" = "$MAC" ] && [ "$B" = "$wantbuild" ] && ok "$name: app is version $V build $B" || bad "$name: the app inside is version '$V' build '$B', not $MAC build $wantbuild"
      local ARCHS; ARCHS="$("$LIPO" -archs "$APP/Contents/MacOS/StreamSetu" 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
      [ "$ARCHS" = "$want" ] && ok "$name: the app is $ARCHS" || bad "$name: the app has architectures '$ARCHS', not '$want'"
      if macos/Scripts/verify-release.sh "$APP" > "$(mktemp)" 2>&1; then ok "$name: packaged checks pass (privacy manifest, paths, smoke test)"; else bad "$name: the packaged-app checks failed (run macos/Scripts/verify-release.sh on the app)"; fi
    else bad "$name: no app inside the DMG"; fi
  else bad "$name: the DMG could not be opened"; rmdir "$MNT" 2>/dev/null; fi
  MNT=""
}
if [ -n "$MAC" ]; then
  echo "Mac"
  # The Apple silicon app is build+1 and the Intel app is the build given: the update feed relies on it (macos/Scripts/release-signed.sh).
  [ -f "$DMG_ARM" ] && verify_mac_dmg "$DMG_ARM" "arm64" "$((MAC_BUILD + 1))"
  [ -f "$DMG_INTEL" ] && verify_mac_dmg "$DMG_INTEL" "x86_64" "$MAC_BUILD"
fi

if [ -n "$ANDROID" ]; then
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
fi

if [ -n "$WINDOWS" ]; then
  echo "Windows"
  for z in "$WIN" "$WIN_ARM"; do
    [ -f "$z" ] || continue
    N="$(basename "$z")"
    unzip -tq "$z" >/dev/null 2>&1 && ok "$N: the zip is intact" || bad "$N: the zip is damaged"
    unzip -l "$z" 2>/dev/null | grep -q "StreamSetu.exe" && ok "$N: holds StreamSetu.exe" || bad "$N: no StreamSetu.exe inside"
    if [ -f "$z.sha256" ]; then
      want="$(awk '{print $1}' "$z.sha256")"; have="$(shasum -a 256 "$z" | awk '{print $1}')"
      [ "$want" = "$have" ] && ok "$N: the checksum is the recorded one" || bad "$N: the checksum differs from the recorded one"
    else bad "$z.sha256 is missing"; fi
  done
fi

echo "Secrets"
# No built-in key (TMDB, fanart.tv, TheTVDB) may be in a file git can see or in a shipped file (the scan never prints a key).
SCAN_ARGS=(); for f in ${TV:+"$TV" "$PHONE"} ${WIN:+"$WIN" "$WIN_ARM"}; do [ -f "$f" ] && SCAN_ARGS+=("$f"); done; for a in ${APPS[@]+"${APPS[@]}"}; do [ -d "$a" ] && SCAN_ARGS+=("$a"); done
if [ -f Scripts/check_no_secrets.py ]; then
  SECRET_OUT="$(python3 -I Scripts/check_no_secrets.py --repo . ${SCAN_ARGS[@]+"${SCAN_ARGS[@]}"} 2>&1)" && ok "no built-in key in the repository files or the release files" || { bad "a built-in key (or a piece of one) is visible: run Scripts/check-no-secrets.sh"; echo "$SECRET_OUT" | grep FAIL | sed 's/^/      /'; }
else bad "Scripts/check_no_secrets.py is missing"; fi

echo "Dependencies"
if "$PYTHON3" Scripts/audit-dependencies.py --strict >/dev/null 2>&1; then ok "dependency report is clean"; else bad "dependency report is not clean (vulnerable or could not be checked): run Scripts/audit-dependencies.py --strict"; fi

echo "Notes and tag"
if [ -f "$NOTES" ]; then
  grep -q '^# ' <<<"$(head -1 "$NOTES")" && ok "notes have a title" || bad "the notes' first line must be a '# title'"
  if [ -n "$MAC" ]; then grep -q "$MAC" "$NOTES" && ok "notes name the Mac version" || bad "the notes do not mention Mac $MAC"; fi
  if [ -n "$ANDROID" ]; then grep -q "$ANDROID" "$NOTES" && ok "notes name the Android version" || bad "the notes do not mention Android $ANDROID"; fi
  if [ -n "$WINDOWS" ]; then grep -q "$WINDOWS" "$NOTES" && ok "notes name the Windows version" || bad "the notes do not mention Windows $WINDOWS"; fi
fi
STATE="$("$GH" release view "$TAG" --repo "$REPO" --json isDraft --jq '.isDraft' 2>/dev/null || echo "none")"
case "$STATE" in
  none) ok "tag $TAG is free" ;;
  true) ok "tag $TAG exists only as an unpublished draft (it will be replaced)" ;;
  *) [ "${REPLACE:-0}" = "1" ] && ok "tag $TAG is published and REPLACE=1 was given" || bad "tag $TAG is already published (set REPLACE=1 only if replacing it is the intention)" ;;
esac

if [ $FAILED -eq 0 ]; then echo "✔ all release checks passed"; exit 0; fi
echo "✘ $FAILED release check(s) failed. Nothing was uploaded or published."; exit 1
