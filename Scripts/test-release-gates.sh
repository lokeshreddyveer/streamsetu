#!/bin/bash
# Tests the release gates themselves, with stand-ins for GitHub, codesign, Gatekeeper, notarization, apksigner and aapt, in a throwaway git repository.
# For every gate it proves the two things that matter: the release stops, and not one call that could change GitHub (create, upload, edit, delete) was made before it stopped.
# Touches nothing real: no network, no signing, no files outside a temporary folder.
#
#   Scripts/test-release-gates.sh
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ✔ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✘ $1"; }

PIN="aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"
PERMS="android.permission.INTERNET
android.permission.WAKE_LOCK"

make_stubs() {   # $1 = folder
  mkdir -p "$1"
  cat > "$1/hdiutil" <<'S'
#!/bin/bash
if [ "$1" = attach ]; then
  while [ $# -gt 0 ]; do [ "$1" = "-mountpoint" ] && MNT="$2"; shift; done
  mkdir -p "$MNT/StreamSetu.app/Contents"
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${FAKE_APP_VERSION:-9.9.9}" -c "Add :CFBundleVersion string ${FAKE_APP_BUILD:-999}" "$MNT/StreamSetu.app/Contents/Info.plist" >/dev/null 2>&1
fi
exit 0
S
  cat > "$1/codesign" <<'S'
#!/bin/bash
case "$1" in
  --verify) exit "${CODESIGN_VERIFY_RC:-0}" ;;
  -dv) [ "${NO_RUNTIME:-0}" = 1 ] || echo "CodeDirectory flags=0x10000(runtime)" >&2; exit 0 ;;
esac
exit 0
S
  cat > "$1/spctl" <<'S'
#!/bin/bash
case "$*" in
  *"--type open"*) exit "${SPCTL_OPEN_RC:-0}" ;;
  *"--type execute"*) exit "${SPCTL_EXEC_RC:-0}" ;;
esac
exit 0
S
  cat > "$1/xcrun" <<'S'
#!/bin/bash
[ "$1 $2" = "stapler validate" ] && exit "${STAPLER_RC:-0}"
exit 0
S
  cat > "$1/apksigner" <<'S'
#!/bin/bash
echo "Signer #1 certificate SHA-256 digest: ${SIGNER:-$FAKE_PIN}"
exit "${APKSIGNER_RC:-0}"
S
  cat > "$1/aapt" <<'S'
#!/bin/bash
case "$2" in
  badging) echo "package: name='${APK_PACKAGE:-app.streamsetu.tv}' versionCode='1' versionName='${APK_VERSION:-9.9.9}'" ;;
  permissions) echo "$FAKE_PERMS" | while read -r p; do [ -n "$p" ] && echo "uses-permission: name='$p'"; done; [ -n "${EXTRA_PERM:-}" ] && echo "uses-permission: name='$EXTRA_PERM'" ;;
esac
exit 0
S
  cat > "$1/python3" <<'S'
#!/bin/bash
case "$*" in *audit-dependencies*) exit "${AUDIT_RC:-0}" ;; esac
exec /usr/bin/python3 "$@"
S
  cat > "$1/gh" <<'S'
#!/bin/bash
# Records every call, in order. Release state lives in $GH_STORE.
echo "$*" >> "$GH_LOG"
[ "$1" = release ] || exit 0
sub="$2"; tag="$3"
case "$sub" in
  view)
    case "$*" in
      *"isDraft"*) [ -f "$GH_STORE/$tag.state" ] && { cat "$GH_STORE/$tag.state"; exit 0; }; [ -n "${GH_PRESET_STATE:-}" ] && { echo "$GH_PRESET_STATE"; exit 0; }; exit 1 ;;
      *"assets"*)
        want="$(echo "$*" | sed -n 's/.*select(\.name=="\([^"]*\)").*/\1/p')"
        f="$GH_STORE/$tag/$want"; [ -f "$f" ] || exit 0
        size=$(stat -f%z "$f"); [ "${GH_TAMPER:-0}" = 1 ] && size=$((size + 1))
        printf '%s\tsha256:%s\n' "$size" "$(shasum -a 256 "$f" | cut -d' ' -f1)"
        exit 0 ;;
    esac ;;
  create)
    mkdir -p "$GH_STORE/$tag"
    for a in "${@:4}"; do [ -f "$a" ] && cp "$a" "$GH_STORE/$tag/"; done
    case "$*" in *--draft*) echo true > "$GH_STORE/$tag.state" ;; *) echo false > "$GH_STORE/$tag.state" ;; esac ;;
  edit) case "$*" in *"--draft=false"*) echo false > "$GH_STORE/$tag.state" ;; esac ;;
  delete) rm -rf "$GH_STORE/$tag" "$GH_STORE/$tag.state" ;;
  download) ;;
esac
exit 0
S
  chmod +x "$1"/*
}

make_root() {   # builds a fake repository with good artifacts in $ROOT_DIR
  ROOT_DIR="$TMP/root-$1"; STUBS="$TMP/stubs"; [ -d "$STUBS" ] || make_stubs "$STUBS"
  rm -rf "$ROOT_DIR"; mkdir -p "$ROOT_DIR"; cd "$ROOT_DIR"
  mkdir -p macos/dist macos/Scripts android/dist/9.9.9 ios/Scripts Scripts docs/releases web windows
  cp "$SRC/Scripts/verify-release-artifacts.sh" "$SRC/Scripts/release.sh" Scripts/
  cp "$SRC/macos/Scripts/appcast_add.py" macos/Scripts/
  printf '#!/bin/bash\nexit "${VERIFY_RC:-0}"\n' > macos/Scripts/verify-release.sh
  printf '#!/bin/bash\necho "appcast $*" >> "$GH_LOG"\nexit "${APPCAST_RC:-0}"\n' > macos/Scripts/update-appcast.sh
  chmod +x Scripts/*.sh macos/Scripts/*.sh macos/Scripts/appcast_add.py
  echo 'VERSION = "1.0"' > ios/Scripts/generate-project.py
  printf 'Download `StreamSetu-1.0.dmg` here: https://x/releases/download/old/StreamSetu-1.0.dmg\n' > README.md
  echo "$PIN" > android/release-signer.sha256; echo "$PERMS" > android/release-permissions.txt
  echo "dmg bytes" > macos/dist/StreamSetu-9.9.9.dmg
  echo "apk bytes" > android/dist/9.9.9/streamsetu-tv-9.9.9.apk; cp android/dist/9.9.9/streamsetu-tv-9.9.9.apk android/dist/9.9.9/StreamSetu-Android-9.9.9.apk
  ( cd android/dist/9.9.9 && shasum -a 256 streamsetu-tv-9.9.9.apk StreamSetu-Android-9.9.9.apk > SHA256SUMS-9.9.9.txt )
  printf '# 9 November 2026\n\n- Mac 9.9.9 and Android 9.9.9.\n' > docs/releases/t1.md
  git init -q . && git config user.email t@example.com && git config user.name t && git add -A && git commit -qm base
  git rev-parse HEAD > macos/dist/StreamSetu-9.9.9.commit; git rev-parse HEAD > android/dist/9.9.9/BUILD-COMMIT.txt          # untracked, like the real dist folders
  export GH_LOG="$ROOT_DIR/gh.log" GH_STORE="$ROOT_DIR/gh-store" FAKE_PIN="$PIN" FAKE_PERMS="$PERMS"; : > "$GH_LOG"; mkdir -p "$GH_STORE"
  export RELEASE_ROOT="$ROOT_DIR" HDIUTIL="$STUBS/hdiutil" CODESIGN="$STUBS/codesign" SPCTL="$STUBS/spctl" XCRUN="$STUBS/xcrun" APKSIGNER="$STUBS/apksigner" AAPT="$STUBS/aapt" PYTHON3="$STUBS/python3" GH="$STUBS/gh"
  export MAC=9.9.9 MAC_BUILD=999 ANDROID=9.9.9
  unset SIGNER APKSIGNER_RC APK_VERSION APK_PACKAGE EXTRA_PERM STAPLER_RC SPCTL_OPEN_RC SPCTL_EXEC_RC CODESIGN_VERIFY_RC NO_RUNTIME FAKE_APP_VERSION FAKE_APP_BUILD VERIFY_RC AUDIT_RC GH_TAMPER GH_PRESET_STATE APPCAST_RC REPLACE
}

changes_github() { grep -qE "^release (create|upload|edit|delete)" "$GH_LOG"; }

# A gate must stop the release, say WHICH check failed ($3 is a piece of that check's message), and leave GitHub untouched.
expect_blocked() {
  local name="$1" setup="$2" message="$3"
  make_root "$name"; eval "$setup"
  if Scripts/release.sh t1 docs/releases/t1.md > "$ROOT_DIR/out.txt" 2>&1; then fail "$name: the release went through"; return; fi
  if changes_github; then fail "$name: stopped, but GitHub was changed first:"; grep -E "^release (create|upload|edit|delete)" "$GH_LOG" | sed 's/^/        /'; return; fi
  grep -q "✘.*$message" "$ROOT_DIR/out.txt" || { fail "$name: stopped, but not by the expected check ('$message'). It said:"; grep "✘" "$ROOT_DIR/out.txt" | head -4 | sed 's/^/        /'; return; }
  grep -q "Nothing was uploaded or published" "$ROOT_DIR/out.txt" && ok "$name: stopped by its own check, before any upload" || fail "$name: stopped, but without the expected message"
}

echo "A good release"
make_root good
if Scripts/release.sh t1 docs/releases/t1.md > "$ROOT_DIR/out.txt" 2>&1; then ok "goes through"; else fail "a good release was refused:"; grep "✘" "$ROOT_DIR/out.txt" | sed 's/^/        /'; fi
create=$(grep -n "^release create" "$GH_LOG" | head -1 | cut -d: -f1); publish=$(grep -n "^release edit .*--draft=false" "$GH_LOG" | head -1 | cut -d: -f1); feed=$(grep -n "^appcast" "$GH_LOG" | head -1 | cut -d: -f1)
[ -n "$create" ] && grep "^release create" "$GH_LOG" | grep -q -- "--draft" && ok "uploaded as a draft" || fail "the upload was not a draft"
[ -n "$publish" ] && [ "$publish" -gt "$create" ] && ok "published only after the upload" || fail "publish did not come after the upload"
[ -n "$feed" ] && [ -n "$publish" ] && [ "$feed" -gt "$publish" ] && ok "the update feed was touched only after publishing" || fail "the update feed was not updated after publishing"
grep -q "release delete" "$GH_LOG" && fail "a good release deleted something" || ok "nothing deleted"

echo "Every gate blocks, and GitHub is untouched"
expect_blocked "wrong signing certificate"       'export SIGNER=0000000000000000000000000000000000000000000000000000000000000000' "is not the pinned release certificate"
expect_blocked "APK signature does not verify"   'export APKSIGNER_RC=1' "signature does not verify"
expect_blocked "wrong Android version"           'export APK_VERSION=1.2.3' "version is not 9.9.9"
expect_blocked "wrong Android package"           'export APK_PACKAGE=com.example.other' "wrong package name"
expect_blocked "an extra permission"             'export EXTRA_PERM=android.permission.READ_SMS' "permissions differ"
expect_blocked "DMG not notarized"               'export STAPLER_RC=1' "DMG is not notarized"
expect_blocked "Gatekeeper refuses the DMG"      'export SPCTL_OPEN_RC=1' "Gatekeeper does not accept the DMG"
expect_blocked "Gatekeeper refuses the app"      'export SPCTL_EXEC_RC=1' "Gatekeeper does not accept the app"
expect_blocked "app signature invalid"           'export CODESIGN_VERIFY_RC=1' "app signature is not valid"
expect_blocked "Hardened Runtime off"            'export NO_RUNTIME=1' "Hardened Runtime is off"
expect_blocked "app is another version"          'export FAKE_APP_VERSION=1.0.0' "the app inside is version"
expect_blocked "packaged checks fail (privacy manifest or smoke test)" 'export VERIFY_RC=1' "packaged-app checks failed"
expect_blocked "dependency report not clean"     'export AUDIT_RC=1' "dependency report is not clean"
expect_blocked "uncommitted code"                'echo changed >> macos/uncommitted.txt; git add macos/uncommitted.txt; git config user.email t@example.com' "uncommitted changes"
expect_blocked "built from another commit"       'echo deadbeef > macos/dist/StreamSetu-9.9.9.commit' "built from another commit"
expect_blocked "the two APKs differ"             'echo other >> android/dist/9.9.9/StreamSetu-Android-9.9.9.apk' "the two APKs differ"
expect_blocked "checksums do not match the build" 'echo tampered >> android/dist/9.9.9/streamsetu-tv-9.9.9.apk; cp android/dist/9.9.9/streamsetu-tv-9.9.9.apk android/dist/9.9.9/StreamSetu-Android-9.9.9.apk' "checksum differs"
expect_blocked "notes do not name the version"   'printf "# Notes\n\n- nothing\n" > docs/releases/t1.md' "do not mention"
expect_blocked "tag already published"           'export GH_PRESET_STATE=false' "already published"
expect_blocked "no signer pin"                   'rm android/release-signer.sha256' "release-signer.sha256 is missing"
expect_blocked "no build commit record"          'rm android/dist/9.9.9/BUILD-COMMIT.txt' "BUILD-COMMIT.txt is missing"
echo "An upload that does not arrive intact is never published"
make_root tampered; export GH_TAMPER=1
if Scripts/release.sh t1 docs/releases/t1.md > "$ROOT_DIR/out.txt" 2>&1; then fail "a damaged upload was published"; else ok "the release stopped"; fi
grep -q "^release edit .*--draft=false" "$GH_LOG" && fail "the damaged draft was published" || ok "never published"
grep -q "^release delete" "$GH_LOG" && ok "the unpublished draft was removed" || fail "the draft was left behind"
grep -q "^appcast" "$GH_LOG" && fail "the update feed was touched" || ok "the update feed was not touched"

echo "A failed update feed after publishing says what to repeat"
make_root feedfail; export APPCAST_RC=1
if Scripts/release.sh t1 docs/releases/t1.md > "$ROOT_DIR/out.txt" 2>&1; then fail "a failed feed step was hidden"; else ok "reported as a failure"; fi
grep -q "update feed was not updated" "$ROOT_DIR/out.txt" && ok "and says what to run again" || fail "no instruction to repeat the feed step"
grep -q "^release delete" "$GH_LOG" && fail "the published release was deleted" || ok "the published release was left alone"

echo "The update feed cannot get a duplicate entry"
F="$TMP/appcast.xml"
python3 "$SRC/macos/Scripts/appcast_add.py" "$F" 1.2.3 123 "https://x/a.dmg" 'sparkle:edSignature="s" length="1"' "notes" | grep -q added && ok "first run adds" || fail "first run did not add"
python3 "$SRC/macos/Scripts/appcast_add.py" "$F" 1.2.3 123 "https://x/b.dmg" 'sparkle:edSignature="s2" length="1"' "notes" | grep -q "already offered" && ok "the same version again is not added" || fail "a duplicate was added"
python3 "$SRC/macos/Scripts/appcast_add.py" "$F" 1.2.4 124 "https://x/c.dmg" 'sparkle:edSignature="s3" length="1"' "notes" | grep -q added && ok "a new version is added" || fail "a new version was not added"
[ "$(grep -c '<item>' "$F")" = "2" ] && ok "two entries in all" || fail "wrong number of entries: $(grep -c '<item>' "$F")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
