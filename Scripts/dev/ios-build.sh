#!/bin/bash
# ios-build.sh - Build the iPhone app with xcodebuild.
# Usage: Scripts/dev/ios-build.sh [--simulator | --device | --generic] [--release] [--clean] [--force] [--dry-run] [--timings]
#   --simulator  (default) generic iOS Simulator build, no signing
#   --device     iOS device build, signed, with -allowProvisioningUpdates (the only mode that uses it)
#   --generic    generic iOS build, no signing (compile check)
#   --clean      delete this mode's derived data first;  --force  build even if the stamp says nothing changed
# Derived data lives at $STREAMSETU_WORK/derived/ios-<mode> and is reused between runs. The Xcode project is regenerated only
# when the project generator or the file list changed; the whole build is skipped when sources, mode and configuration are unchanged.
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
MODE=simulator; CONFIG=Debug; CLEAN=0; FORCE=0
while [ $# -gt 0 ]; do
  common_flag "$1" && { shift; continue; }
  case "$1" in
    --simulator) MODE=simulator;; --device) MODE=device;; --generic) MODE=generic;;
    --release) CONFIG=Release;; --clean) CLEAN=1;; --force) FORCE=1;;
    *) usage_error "unknown option: $1";;
  esac; shift
done
need xcodebuild "Install Xcode 27.2"
acquire_lock "ios-build-$MODE"
DD="$WORK/derived/ios-$MODE"
case "$MODE" in
  simulator) DEST='generic/platform=iOS Simulator'; EXTRA="CODE_SIGNING_ALLOWED=NO"; PROD="$CONFIG-iphonesimulator";;
  generic)   DEST='generic/platform=iOS'; EXTRA="CODE_SIGNING_ALLOWED=NO"; PROD="$CONFIG-iphoneos";;
  device)    DEST='generic/platform=iOS'; EXTRA=""; PROD="$CONFIG-iphoneos";;
esac
APP="$DD/Build/Products/$PROD/StreamSetu.app"
[ $CLEAN = 0 ] || run_step "clean derived data" rm -rf "$DD"
# 1. project: regenerate only when the generator or the file list changed
ios_gen_project
# 2. whole-build stamp
BFP="$MODE $CONFIG $(fp_paths ios macos/Sources legal)"
if [ $FORCE = 0 ] && [ $CLEAN = 0 ] && [ "$(stamp_get "ios-build-$MODE")" = "$BFP" ] && [ -d "$APP" ]; then ok "up to date: $APP"; exit 0; fi
FLAGS=(-project "$ROOT/ios/StreamSetu.xcodeproj" -scheme StreamSetu -configuration "$CONFIG" -destination "$DEST" -derivedDataPath "$DD" -jobs "$(xcode_jobs)" -quiet)
[ $MODE != device ] || FLAGS+=(-allowProvisioningUpdates)
run_step "xcodebuild ($MODE, $CONFIG)" xcodebuild "${FLAGS[@]}" build $EXTRA
[ $DRY_RUN = 1 ] && exit 0
[ -d "$APP" ] || die $EX_FAIL "build finished but $APP is missing"
stamp_set "ios-build-$MODE" "$BFP"; printf '%s\n' "$APP" > "$WORK/cache/ios-last-app-$MODE"
ok "built $APP"
