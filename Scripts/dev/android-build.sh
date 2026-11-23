#!/bin/bash
# android-build.sh - Build the Android app with the pinned toolchain (JDK 17, node on PATH, Gradle heap sized to this Mac's RAM, up to 5 GB).
# Usage: Scripts/dev/android-build.sh [--debug | --test-apk | --release-check] [--version V] [--code N] [--clean] [--force] [--dry-run] [--timings]
#   --debug          (default) :app:assembleDebug
#   --test-apk       the release flow (android/release.sh: tests, lint, dependency audit, signed release APK) with version name suffix -test,
#                    then apksigner verify, secret scan, sha256, copy to ~/Desktop/StreamSetu-android-test.apk (skipped when nothing changed)
#   --release-check  lintRelease + assembleRelease + apksigner verify + secret scan; copies nothing
#   --version V      base version name (default: last git tag);  --code N  version code (default: date based, kept while sources are unchanged)
#   --clean          run Gradle clean first (never done otherwise);  --force  start even if another Gradle run is active
# Refuses to start when another Gradle client is running (exit 4) unless --force. Uses the Gradle daemon and build cache.
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
MODE=debug; VER=""; CODE=""; CLEAN=0; FORCE=0
while [ $# -gt 0 ]; do
  common_flag "$1" && { shift; continue; }
  case "$1" in
    --debug) MODE=debug;; --test-apk) MODE=test-apk;; --release-check) MODE=release-check;;
    --version) [ $# -ge 2 ] || usage_error "--version needs a value"; VER=$2; shift;;
    --code) [ $# -ge 2 ] || usage_error "--code needs a value"; CODE=$2; shift;;
    --clean) CLEAN=1;; --force) FORCE=1;;
    *) usage_error "unknown option: $1";;
  esac; shift
done
[ -n "$VER" ] || { VER="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"; VER="${VER:-0.2.0}"; }
[[ "$VER" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || usage_error "version '$VER' must look like 2026.11.21"
[ -z "$CODE" ] || [[ "$CODE" =~ ^[0-9]{1,9}$ ]] || usage_error "version code must be digits (max 9)"
android_env
acquire_lock android
gradle_guard
GW() { cd "$ROOT/android" && ./gradlew $(gradle_flags) "$@"; }
signer() { local s; s="$(ls -d "$ANDROID_HOME"/build-tools/* 2>/dev/null | sort -V | tail -1)/apksigner"; [ -x "$s" ] || die $EX_MISSING "apksigner not found under $ANDROID_HOME/build-tools"; echo "$s"; }
APK="$ROOT/android/app/build/outputs/apk/release/app-release.apk"
[ $CLEAN = 0 ] || run_step "gradle clean" bash -c "cd '$ROOT/android' && ./gradlew clean"
case "$MODE" in
  debug) run_step "assembleDebug" GW :app:assembleDebug;;
  release-check|test-apk)
    if [ $MODE = test-apk ]; then
      FP="$(fp_paths android Scripts/audit-dependencies.py):$VER"
      read -r SFP SCODE <<<"$(stamp_get android-test-apk)" || true
      DEST="$HOME/Desktop/StreamSetu-android-test.apk"
      if [ "${SFP:-}" = "$FP" ] && [ -f "$APK" ] && [ -f "$DEST" ] && cmp -s "$APK" "$DEST" && [ $CLEAN = 0 ]; then ok "up to date: $DEST (sources unchanged)"; exit 0; fi
      [ -n "$CODE" ] || { [ "${SFP:-}" = "$FP" ] && CODE="$SCODE" || CODE="$(date +%y%m%d%H)"; }
      [ -f "$ROOT/android/keystore.properties" ] || die $EX_MISSING "android/keystore.properties missing: the test APK must be signed by the release flow"
      run_step "release flow ($VER-test, code $CODE)" bash -c "cd '$ROOT/android' && ./release.sh '$VER-test' '$CODE'"
    else
      run_step "lintRelease + assembleRelease" GW lintRelease :app:assembleRelease -PappVersionName="$VER-check" -PappVersionCode=1
    fi
    [ $DRY_RUN = 1 ] && { log "  [dry-run] apksigner verify, secret scan (cached), sha256$([ $MODE = test-apk ] && echo ", copy to ~/Desktop")"; exit 0; }
    [ -f "$APK" ] || die $EX_FAIL "no APK at $APK"
    run_step "apksigner verify" "$(signer)" verify "$APK"
    step "secret scan"; scan_secrets "$APK" || exit $EX_GATE
    log "sha256 $(shasum -a 256 "$APK" | cut -d' ' -f1)"
    if [ $MODE = test-apk ]; then cp "$APK" "$DEST"; stamp_set android-test-apk "$FP $CODE"; ok "copied to $DEST"; fi;;
esac
ok "android $MODE done"
