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
# Every call is logged (HDIUTIL_LOG). ATTACH_FAILS and DETACH_FAILS make the first N attach or detach calls fail the way macOS does when it is busy;
# FAKE_STALE=<image name> makes `info` report an earlier mount of that image.
[ -n "${HDIUTIL_LOG:-}" ] && echo "$*" >> "$HDIUTIL_LOG"
count() { local f="$STUB_STATE/$1" n; n=$(cat "$f" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$f"; echo "$n"; }
if [ "$1" = info ] && [ -n "${FAKE_STALE:-}" ]; then
  printf '================================================\nimage-path      : /somewhere/macos/dist/%s\n/dev/disk9\tGUID_partition_scheme\n/dev/disk9s1\tApple_HFS\t/Volumes/StreamSetu\n' "$FAKE_STALE"; exit 0
fi
if [ "$1" = detach ] && [ "${DETACH_FAILS:-0}" -gt 0 ] && [ "$(count detach)" -le "$DETACH_FAILS" ]; then
  echo "hdiutil: couldn't unmount: Simulators are still shutting down. Please try again in a few moments." >&2; exit 16
fi
if [ "$1" = attach ]; then
  if [ "${ATTACH_FAILS:-0}" -gt 0 ] && [ "$(count attach)" -le "$ATTACH_FAILS" ]; then echo "hdiutil: attach failed - Resource busy" >&2; exit 16; fi
  DMGFILE="$*"
  while [ $# -gt 0 ]; do [ "$1" = "-mountpoint" ] && MNT="$2"; shift; done
  # Two disk images, no universal one: the Apple silicon app is arm64 and build+1, the Intel app is x86_64 and the build itself.
  case "$DMGFILE" in
    *-AppleSilicon.dmg*) A="arm64"; B=$(( ${FAKE_APP_BUILD:-999} + 1 )) ;;
    *) A="x86_64"; B="${FAKE_APP_BUILD:-999}" ;;
  esac
  ARCHS="${FAKE_ARCHS:-$A}"
  mkdir -p "$MNT/StreamSetu.app/Contents/MacOS"; echo "$ARCHS" > "$MNT/StreamSetu.app/Contents/MacOS/StreamSetu"
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${FAKE_APP_VERSION:-9.9.9}" -c "Add :CFBundleVersion string $B" "$MNT/StreamSetu.app/Contents/Info.plist" >/dev/null 2>&1
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
  cat > "$1/lipo" <<'S'
#!/bin/bash
cat "$2"
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
  upload)
    # UPLOAD_FAILS=N: the first N uploads fail the way a timed-out one does (counted in $STUB_STATE)
    if [ "${UPLOAD_FAILS:-0}" -gt 0 ]; then n=$(cat "$STUB_STATE/upload" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STUB_STATE/upload"
      [ "$n" -le "$UPLOAD_FAILS" ] && { echo "HTTP 408: Upload body timed out due to inactivity" >&2; exit 1; }; fi
    mkdir -p "$GH_STORE/$tag"; [ -f "$4" ] && cp "$4" "$GH_STORE/$tag/" ;;
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
  mkdir -p macos/dist macos/Scripts android/dist/9.9.9 ios/Scripts Scripts docs/releases web windows/native/dist
  cp "$SRC/Scripts/verify-release-artifacts.sh" "$SRC/Scripts/release.sh" Scripts/
  cp "$SRC/macos/Scripts/appcast_add.py" macos/Scripts/
  cp "$SRC/Scripts/check_no_secrets.py" Scripts/
  printf '#!/bin/bash\nexit "${VERIFY_RC:-0}"\n' > macos/Scripts/verify-release.sh
  printf '#!/bin/bash\necho "appcast $*" >> "$GH_LOG"\nexit "${APPCAST_RC:-0}"\n' > macos/Scripts/update-appcast.sh
  chmod +x Scripts/*.sh macos/Scripts/*.sh macos/Scripts/appcast_add.py
  echo 'VERSION = "1.0"' > ios/Scripts/generate-project.py
  printf '| **Mac** | [`StreamSetu-1.0.dmg`](../../releases/download/old/StreamSetu-1.0.dmg) | Signed. |\n| **Windows** | [`StreamSetu-Windows-0.1.zip`](../../releases/download/old/StreamSetu-Windows-0.1.zip); [`StreamSetu-Windows-0.1-arm64.zip`](../../releases/download/old/StreamSetu-Windows-0.1-arm64.zip) | Zip. |\n' > README.md
  echo "$PIN" > android/release-signer.sha256; echo "$PERMS" > android/release-permissions.txt
  echo "dmg bytes arm" > macos/dist/StreamSetu-9.9.9-AppleSilicon.dmg; echo "dmg bytes intel" > macos/dist/StreamSetu-9.9.9-Intel.dmg
  for z in StreamSetu-Windows-8.8.8.zip StreamSetu-Windows-8.8.8-arm64.zip; do
    ( cd windows/native/dist && mkdir -p w && echo exe > w/StreamSetu.exe && zip -qr "$z" w && rm -rf w && shasum -a 256 "$z" > "$z.sha256" )
  done
  echo "apk bytes" > android/dist/9.9.9/streamsetu-tv-9.9.9.apk; cp android/dist/9.9.9/streamsetu-tv-9.9.9.apk android/dist/9.9.9/StreamSetu-Android-9.9.9.apk
  ( cd android/dist/9.9.9 && shasum -a 256 streamsetu-tv-9.9.9.apk StreamSetu-Android-9.9.9.apk > SHA256SUMS-9.9.9.txt )
  printf '# 9 November 2026\n\n- Mac 9.9.9, Android 9.9.9 and Windows 8.8.8.\n' > docs/releases/t1.md
  git init -q . && git config user.email t@example.com && git config user.name t && git add -A && git commit -qm base
  git rev-parse HEAD > macos/dist/StreamSetu-9.9.9.commit; git rev-parse HEAD > android/dist/9.9.9/BUILD-COMMIT.txt          # untracked, like the real dist folders
  export GH_LOG="$ROOT_DIR/gh.log" GH_STORE="$ROOT_DIR/gh-store" FAKE_PIN="$PIN" FAKE_PERMS="$PERMS"; : > "$GH_LOG"; mkdir -p "$GH_STORE"
  export RELEASE_ROOT="$ROOT_DIR" HDIUTIL="$STUBS/hdiutil" CODESIGN="$STUBS/codesign" SPCTL="$STUBS/spctl" XCRUN="$STUBS/xcrun" LIPO="$STUBS/lipo" APKSIGNER="$STUBS/apksigner" AAPT="$STUBS/aapt" PYTHON3="$STUBS/python3" GH="$STUBS/gh"
  export MAC=9.9.9 MAC_BUILD=999 ANDROID=9.9.9 WINDOWS=8.8.8
  # The disk-image stand-in keeps its counters here and logs every call; no pause between the retries (they would only slow the tests).
  export STUB_STATE="$ROOT_DIR/stub-state" HDIUTIL_LOG="$ROOT_DIR/hdiutil.log" DMG_RETRY_SLEEP=0 UPLOAD_RETRY_SLEEP=0; mkdir -p "$STUB_STATE"; : > "$HDIUTIL_LOG"
  unset PARTIAL SIGNER APKSIGNER_RC APK_VERSION APK_PACKAGE EXTRA_PERM STAPLER_RC SPCTL_OPEN_RC SPCTL_EXEC_RC CODESIGN_VERIFY_RC NO_RUNTIME FAKE_APP_VERSION FAKE_APP_BUILD FAKE_ARCHS VERIFY_RC AUDIT_RC GH_TAMPER GH_PRESET_STATE APPCAST_RC REPLACE ATTACH_FAILS DETACH_FAILS FAKE_STALE UPLOAD_FAILS
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
[ -n "$create" ] && grep -E "^release (create|upload)" "$GH_LOG" | grep -q -- "--draft" && ok "uploaded as a draft" || fail "the upload was not a draft"
[ -n "$publish" ] && [ "$publish" -gt "$create" ] && ok "published only after the upload" || fail "publish did not come after the upload"
[ -n "$feed" ] && [ -n "$publish" ] && [ "$feed" -gt "$publish" ] && ok "the update feed was touched only after publishing" || fail "the update feed was not updated after publishing"
grep -q "release delete" "$GH_LOG" && fail "a good release deleted something" || ok "nothing deleted"
grep -E "^release (create|upload)" "$GH_LOG" | grep -q "StreamSetu-9.9.9-AppleSilicon.dmg" && grep -E "^release (create|upload)" "$GH_LOG" | grep -q "StreamSetu-9.9.9-Intel.dmg" && ok "both DMGs were uploaded" || fail "both DMGs were not uploaded"
grep -E "^release (create|upload)" "$GH_LOG" | grep -q "StreamSetu-9.9.9.dmg" && fail "a universal DMG was uploaded" || ok "no universal DMG is uploaded"
grep -q "releases/download/t1/StreamSetu-9.9.9-AppleSilicon.dmg" README.md && grep -q "releases/download/t1/StreamSetu-9.9.9-Intel.dmg" README.md && ok "the README's Mac row links both new DMGs" || fail "the README's Mac row does not link both new DMGs"
grep -q "^appcast" "$GH_LOG" && [ "$(grep -c "^appcast" "$GH_LOG")" = "1" ] && ok "the update feed is told once (it adds the Apple silicon and the Intel item)" || fail "the update feed was not told exactly once"

echo "Uploads go one file at a time and are retried"
# `gh release create <files>` sent 780 MB at once and a timed-out upload (HTTP 408) stopped release 2026.11.28. The draft is created empty, then each file goes up on its own.
make_root upload-one-by-one
if Scripts/release.sh t1 docs/releases/t1.md > "$ROOT_DIR/out.txt" 2>&1; then ok "a release goes through with one upload per file"; else fail "the one-file-at-a-time upload broke a good release"; fi
grep "^release create" "$GH_LOG" | grep -qE "\.(dmg|apk|zip)" && fail "the draft was created with the files on the same command (all at once)" || ok "the draft is created empty, with no files on the command"
[ "$(grep -c "^release upload" "$GH_LOG")" = "6" ] && ok "each of the six files has its own upload ($(grep -c "^release upload" "$GH_LOG"))" || fail "wrong number of uploads: $(grep -c "^release upload" "$GH_LOG")"
make_root upload-retry; export UPLOAD_FAILS=2
if Scripts/release.sh t1 docs/releases/t1.md > "$ROOT_DIR/out.txt" 2>&1; then ok "an upload that times out twice is retried and the release goes through"; else fail "a timed-out upload stopped the release:"; grep "✘" "$ROOT_DIR/out.txt" | sed 's/^/        /'; fi
grep -q "failed (try 2 of 4); trying again" "$ROOT_DIR/out.txt" && ok "...and each failed try is reported" || fail "the failed tries were not reported"
make_root upload-dead; export UPLOAD_FAILS=99
if Scripts/release.sh t1 docs/releases/t1.md > "$ROOT_DIR/out.txt" 2>&1; then fail "a release went through although a file never uploaded"; else ok "a file that never uploads stops the release"; fi
grep -q "would not upload after 4 tries" "$ROOT_DIR/out.txt" && ok "...and says which file and how many tries" || fail "the message for a file that never uploads is missing"
grep -q "^release delete" "$GH_LOG" && ok "...and the unpublished draft is removed" || fail "the draft was left behind"
grep -q "^release edit .*--draft=false" "$GH_LOG" && fail "it published although a file was missing" || ok "...and nothing was published"
grep -q "^appcast" "$GH_LOG" && fail "the update feed was touched although a file was missing" || ok "...and the update feed was not touched"

echo "A busy disk image does not leave anything mounted, and never hides it"
# macOS is sometimes busy for a moment (Resource busy; "Simulators are still shutting down"). Those are retried; a mount that will not let go is reported, not hidden.
detaches() { grep -c "^detach " "$HDIUTIL_LOG"; }
make_root busy-detach; export DETACH_FAILS=2
if Scripts/release.sh t1 docs/releases/t1.md > "$ROOT_DIR/out.txt" 2>&1; then ok "a detach that fails twice does not stop the release"; else fail "a busy detach stopped the release:"; grep "✘" "$ROOT_DIR/out.txt" | sed 's/^/        /'; fi
! grep -q "would not detach" "$ROOT_DIR/out.txt" && ok "...and the detach is retried until it works (nothing left mounted, nothing reported)" || fail "a detach that works on the third try was reported as stuck"
[ "$(detaches)" -ge 3 ] && grep -q "^detach .* -force" "$HDIUTIL_LOG" && ok "the detach was tried twice, then forced ($(detaches) calls)" || fail "the detach was not retried ($(detaches) calls)"
make_root stuck-detach; export DETACH_FAILS=99
if Scripts/release.sh t1 docs/releases/t1.md > "$ROOT_DIR/out.txt" 2>&1; then ok "an image that never detaches does not block a good release"; else fail "a stuck mount blocked a release whose files are fine"; fi
grep -q "would not detach. Free it with: hdiutil detach" "$ROOT_DIR/out.txt" && ok "...but it is reported, with the command that frees it" || fail "a mount that would not detach was not reported"
grep -q "^detach .* -force" "$HDIUTIL_LOG" && ok "...after a forced detach was tried" || fail "a forced detach was not tried"
make_root busy-attach; export ATTACH_FAILS=2
if Scripts/release.sh t1 docs/releases/t1.md > "$ROOT_DIR/out.txt" 2>&1; then ok "an attach that fails twice (Resource busy) is retried and the release goes through"; else fail "a busy attach stopped the release:"; grep "✘" "$ROOT_DIR/out.txt" | sed 's/^/        /'; fi
make_root dead-attach; export ATTACH_FAILS=99
if Scripts/release.sh t1 docs/releases/t1.md > "$ROOT_DIR/out.txt" 2>&1; then fail "a DMG that cannot be opened was accepted"; else grep -q "✘.*the DMG could not be opened" "$ROOT_DIR/out.txt" && ok "a DMG that never opens still blocks the release" || fail "the block for an unopenable DMG says something else"; fi
make_root stale; export FAKE_STALE="StreamSetu-9.9.8-AppleSilicon.dmg"   # an OLD version: its file was already gone from dist/, as with the real stuck 2.19.1 image
if Scripts/release.sh t1 docs/releases/t1.md > "$ROOT_DIR/out.txt" 2>&1; then ok "an earlier mount of the same image does not stop the release"; else fail "a stale mount stopped the release"; fi
grep -q "detached an earlier mount of a StreamSetu disk image" "$ROOT_DIR/out.txt" && grep -q "^detach /dev/disk9 -force" "$HDIUTIL_LOG" && ok "...and it was detached first" || fail "an earlier mount of the image was left in place"

echo "A real-size Windows zip passes"
# The real zips hold about 500 files. With pipefail, `unzip -l | grep -q` stops at the first match, unzip then dies on the closed pipe (status 141) and a zip that DOES hold
# StreamSetu.exe was reported as not holding it (release 2026.11.28 was stopped by that, correctly, but for the wrong reason). StreamSetu.exe is listed first here, then thousands of files.
make_root bigzip
( cd windows/native/dist && rm -f StreamSetu-Windows-8.8.8*.zip* && mkdir -p w/data && echo exe > w/StreamSetu.exe && for i in $(seq 1 4000); do : > "w/data/file-$i.txt"; done \
  && for z in StreamSetu-Windows-8.8.8.zip StreamSetu-Windows-8.8.8-arm64.zip; do zip -q "$z" w/StreamSetu.exe && zip -qr "$z" w/data && shasum -a 256 "$z" > "$z.sha256"; done; rm -rf w )
git add windows/native/dist && git commit -qm "big zips" && git rev-parse HEAD > macos/dist/StreamSetu-9.9.9.commit && git rev-parse HEAD > android/dist/9.9.9/BUILD-COMMIT.txt
if Scripts/release.sh t1 docs/releases/t1.md > "$ROOT_DIR/out.txt" 2>&1; then ok "a Windows zip with thousands of files that holds StreamSetu.exe goes through"; else fail "a big Windows zip that holds StreamSetu.exe was refused:"; grep "✘" "$ROOT_DIR/out.txt" | sed 's/^/        /'; fi
make_root nozip
( cd windows/native/dist && rm -f StreamSetu-Windows-8.8.8*.zip* && mkdir -p w/data && echo x > w/other.exe && for i in $(seq 1 4000); do : > "w/data/file-$i.txt"; done \
  && for z in StreamSetu-Windows-8.8.8.zip StreamSetu-Windows-8.8.8-arm64.zip; do zip -qr "$z" w && shasum -a 256 "$z" > "$z.sha256"; done; rm -rf w )
git add windows/native/dist && git commit -qm "zips without the exe" && git rev-parse HEAD > macos/dist/StreamSetu-9.9.9.commit && git rev-parse HEAD > android/dist/9.9.9/BUILD-COMMIT.txt
if Scripts/release.sh t1 docs/releases/t1.md > "$ROOT_DIR/out.txt" 2>&1; then fail "a Windows zip without StreamSetu.exe was accepted"; else grep -q "✘.*no StreamSetu.exe inside" "$ROOT_DIR/out.txt" && ok "a big Windows zip WITHOUT StreamSetu.exe is still refused" || fail "the block for a zip without StreamSetu.exe says something else"; fi

echo "Every gate blocks, and GitHub is untouched"
expect_blocked "wrong signing certificate"       'export SIGNER=0000000000000000000000000000000000000000000000000000000000000000' "is not the pinned release certificate"
expect_blocked "APK signature does not verify"   'export APKSIGNER_RC=1' "signature does not verify"
expect_blocked "wrong Android version"           'export APK_VERSION=1.2.3' "version is not 9.9.9"
expect_blocked "wrong Android package"           'export APK_PACKAGE=com.example.other' "wrong package name"
expect_blocked "an extra permission"             'export EXTRA_PERM=android.permission.READ_SMS' "permissions differ"
expect_blocked "the Apple silicon DMG is missing" 'rm macos/dist/StreamSetu-9.9.9-AppleSilicon.dmg' "StreamSetu-9.9.9-AppleSilicon.dmg is missing"
expect_blocked "the Intel DMG is missing"         'rm macos/dist/StreamSetu-9.9.9-Intel.dmg' "StreamSetu-9.9.9-Intel.dmg is missing"
expect_blocked "an app has the wrong architecture" 'export FAKE_ARCHS="arm64 x86_64"' "has architectures"
expect_blocked "the Apple silicon app has the wrong build" 'export FAKE_APP_BUILD=500' "not 9.9.9 build"
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
expect_blocked "a built-in key leaks into a file" 'mkdir -p "$TMP/k"; printf "%s" "0123456789abcdef0123456789abcdef" > "$TMP/k/fanart-api-key.txt"; export STREAMSETU_KEYS_DIR="$TMP/k"; echo "api_key=0123456789abcdef0123456789abcdef" >> android/dist/9.9.9/leak.txt' "built-in key"
unset STREAMSETU_KEYS_DIR
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

echo "A release without a Mac file"
make_root nomac; unset MAC MAC_BUILD; export PARTIAL=1
if Scripts/release.sh t1 docs/releases/t1.md > "$ROOT_DIR/out.txt" 2>&1; then ok "goes through"; else fail "an Android-only release was refused:"; grep "✘" "$ROOT_DIR/out.txt" | sed 's/^/        /'; fi
grep -E "^release (create|upload)" "$GH_LOG" | grep -q "\.dmg" && fail "a DMG was uploaded" || ok "no DMG uploaded"
grep -E "^release (create|upload)" "$GH_LOG" | grep -q "streamsetu-tv-9.9.9.apk" && ok "the APKs were uploaded" || fail "the APKs were not uploaded"
grep -q "^appcast" "$GH_LOG" && fail "the Mac update feed was touched" || ok "the Mac update feed was left alone"
grep -q "releases/download/old/StreamSetu-1.0.dmg" README.md && ok "the README's Mac row still points at the last Mac release" || fail "the README's Mac row was changed"
expect_blocked "without a Mac file, a wrong signing certificate still blocks" 'unset MAC MAC_BUILD; export PARTIAL=1; export SIGNER=0000000000000000000000000000000000000000000000000000000000000000' "is not the pinned release certificate"
expect_blocked "MAC without MAC_BUILD"           'unset MAC_BUILD' "MAC_BUILD"

echo "A Mac-only release (no Android files)"
make_root maconly; unset ANDROID WINDOWS; export PARTIAL=1
if Scripts/release.sh t1 docs/releases/t1.md > "$ROOT_DIR/out.txt" 2>&1; then ok "goes through"; else fail "a Mac-only release was refused:"; grep "✘" "$ROOT_DIR/out.txt" | sed 's/^/        /'; fi
grep -E "^release (create|upload)" "$GH_LOG" | grep -q "StreamSetu-9.9.9-AppleSilicon.dmg" && grep -E "^release (create|upload)" "$GH_LOG" | grep -q "StreamSetu-9.9.9-Intel.dmg" && ok "both DMGs were uploaded" || fail "both DMGs were not uploaded"
grep -E "^release (create|upload)" "$GH_LOG" | grep -q "\.apk" && fail "an APK was uploaded" || ok "no APK uploaded"
grep -q "^appcast" "$GH_LOG" && ok "the update feed was told" || fail "the update feed was not told"
expect_blocked "Mac-only: a wrong-architecture app still blocks" 'unset ANDROID WINDOWS; export PARTIAL=1 FAKE_ARCHS=x86_64' "has architectures"
expect_blocked "nothing given"                   'unset MAC MAC_BUILD ANDROID WINDOWS; export PARTIAL=1' "set MAC"

echo "A release holds every app"
expect_blocked "an app left out without PARTIAL"  'unset ANDROID' "A release holds every app"
expect_blocked "no Windows version without PARTIAL" 'unset WINDOWS' "A release holds every app"
expect_blocked "the arm64 Windows zip is missing" 'rm windows/native/dist/StreamSetu-Windows-8.8.8-arm64.zip' "StreamSetu-Windows-8.8.8-arm64.zip is missing"
expect_blocked "a Windows zip is damaged"        'echo junk > windows/native/dist/StreamSetu-Windows-8.8.8.zip; shasum -a 256 windows/native/dist/StreamSetu-Windows-8.8.8.zip > windows/native/dist/StreamSetu-Windows-8.8.8.zip.sha256' "the zip is damaged"
expect_blocked "a Windows checksum differs"      'echo tampered >> windows/native/dist/StreamSetu-Windows-8.8.8.zip' "checksum differs"
expect_blocked "the notes do not name Windows"   'printf "# Notes\n\n- Mac 9.9.9 and Android 9.9.9.\n" > docs/releases/t1.md' "do not mention Windows"
make_root all
if Scripts/release.sh t1 docs/releases/t1.md > "$ROOT_DIR/out.txt" 2>&1; then ok "a release of every app goes through"; else fail "a full release was refused:"; grep "✘" "$ROOT_DIR/out.txt" | sed 's/^/        /'; fi
for f in StreamSetu-9.9.9-AppleSilicon.dmg StreamSetu-9.9.9-Intel.dmg streamsetu-tv-9.9.9.apk StreamSetu-Android-9.9.9.apk StreamSetu-Windows-8.8.8.zip StreamSetu-Windows-8.8.8-arm64.zip; do grep -E "^release (create|upload)" "$GH_LOG" | grep -q "$f" && ok "$f was uploaded" || fail "$f was not uploaded"; done
for f in StreamSetu-Windows-8.8.8.zip StreamSetu-Windows-8.8.8-arm64.zip; do grep -q "releases/download/t1/$f" README.md && ok "the README's Windows row links $f" || fail "the README's Windows row does not link $f"; done
echo "An app that did not change ships its existing files again"
make_root unchanged; echo "// later" > android/unrelated.txt; git add android/unrelated.txt; git commit -qm "a change to the Android code"
# android/ is a folder of the app: a change there after the build is a change of the app. The Android build record points at the base commit.
BASE="$(git rev-parse HEAD~1)"; echo "$BASE" > android/dist/9.9.9/BUILD-COMMIT.txt; git rev-parse HEAD > macos/dist/StreamSetu-9.9.9.commit
if Scripts/release.sh t1 docs/releases/t1.md > "$ROOT_DIR/out.txt" 2>&1; then fail "an Android build from before a change to android/ was accepted"; else grep -q "android has changed since" "$ROOT_DIR/out.txt" && ok "an Android build older than a change to android/ is refused" || fail "refused, but not for the right reason"; fi
make_root unchanged2; git rev-parse HEAD > android/dist/9.9.9/BUILD-COMMIT.txt; git rev-parse HEAD > macos/dist/StreamSetu-9.9.9.commit; echo "docs only" > docs/later.md; git add docs/later.md; git commit -qm "docs"
if Scripts/release.sh t1 docs/releases/t1.md > "$ROOT_DIR/out.txt" 2>&1; then grep -q "has not changed since it was built" "$ROOT_DIR/out.txt" && ok "an unchanged app ships its existing build (its source did not change)" || fail "went through without saying why the older build is fine"; else fail "an unchanged Android build was refused:"; grep "✘" "$ROOT_DIR/out.txt" | sed 's/^/        /'; fi

echo "The update feed cannot get a duplicate entry"
F="$TMP/appcast.xml"
python3 "$SRC/macos/Scripts/appcast_add.py" "$F" 1.2.3 123 "https://x/a.dmg" 'sparkle:edSignature="s" length="1"' "notes" x86_64 | grep -q added && ok "first run adds" || fail "first run did not add"
python3 "$SRC/macos/Scripts/appcast_add.py" "$F" 1.2.3 123 "https://x/b.dmg" 'sparkle:edSignature="s2" length="1"' "notes" x86_64 | grep -q "already offered" && ok "the same version again is not added" || fail "a duplicate was added"
python3 "$SRC/macos/Scripts/appcast_add.py" "$F" 1.2.4 124 "https://x/c.dmg" 'sparkle:edSignature="s3" length="1"' "notes" x86_64 | grep -q added && ok "a new version is added" || fail "a new version was not added"
python3 "$SRC/macos/Scripts/appcast_add.py" "$F" 1.2.5 124 "https://x/d.dmg" 'sparkle:edSignature="s4" length="1"' "notes" x86_64 >/dev/null 2>&1 && fail "a build no higher than the feed's was added" || ok "a build no higher than the feed's is refused"
python3 "$SRC/macos/Scripts/appcast_add.py" "$F" 1.2.5 1x "https://x/d.dmg" 'sparkle:edSignature="s4" length="1"' "notes" x86_64 >/dev/null 2>&1 && fail "a build that is not a number was added" || ok "a build that is not a number is refused"
# The Apple silicon file of a version is its own item: it requires Apple silicon and carries the higher build; asked twice it is added once; the Intel file of that version is still there.
python3 "$SRC/macos/Scripts/appcast_add.py" "$F" 1.2.4 125 "https://x/e.dmg" 'sparkle:edSignature="s5" length="1"' "notes" arm64 | grep -q added && ok "the Apple silicon file of the same version is added" || fail "the Apple silicon file was not added"
python3 "$SRC/macos/Scripts/appcast_add.py" "$F" 1.2.4 125 "https://x/e.dmg" 'sparkle:edSignature="s5" length="1"' "notes" arm64 | grep -q "already offered" && ok "the Apple silicon file again is not added" || fail "the Apple silicon file was added twice"
[ "$(grep -c '<sparkle:hardwareRequirements>arm64' "$F")" = "1" ] && ok "only the Apple silicon item requires Apple silicon" || fail "the hardware requirement is on the wrong number of items"
python3 "$SRC/macos/Scripts/appcast_add.py" "$F" 1.2.6 130 "https://x/f.dmg" 'sparkle:edSignature="s6" length="1"' "notes" universal >/dev/null 2>&1 && fail "a universal file was added" || ok "there is no universal file"
[ "$(grep -c '<item>' "$F")" = "3" ] && ok "three entries in all" || fail "wrong number of entries: $(grep -c '<item>' "$F")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
