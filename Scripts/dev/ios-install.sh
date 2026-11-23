#!/bin/bash
# ios-install.sh - Install and launch the iPhone app on a paired device with devicectl. Never runs UI tests on the device.
# Usage: Scripts/dev/ios-install.sh [--device-id ID] [--app PATH] [--build] [--no-launch] [--force] [--dry-run] [--timings]
#   --device-id  CoreDevice identifier; default: the cached one, else the only paired iPhone (the id is cached in $STREAMSETU_WORK/cache)
#   --app PATH   default: the app built by ios-build.sh --device
#   --build      run ios-build.sh --device first (it skips itself when sources are unchanged)
#   --force      install again even though this exact build is already on that device (stamp)
# A locked phone stops the run with exit 6 and a one-line instruction. The app is secret-scanned (cached by hash) before install.
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
DEV=""; APP=""; BUILD=0; LAUNCH=1; FORCE=0
while [ $# -gt 0 ]; do
  common_flag "$1" && { shift; continue; }
  case "$1" in
    --device-id) [ $# -ge 2 ] || usage_error "--device-id needs a value"; DEV=$2; shift;;
    --app) [ $# -ge 2 ] || usage_error "--app needs a path"; APP=$2; shift;;
    --build) BUILD=1;; --no-launch) LAUNCH=0;; --force) FORCE=1;;
    *) usage_error "unknown option: $1";;
  esac; shift
done
[[ -z "$DEV" || "$DEV" =~ ^[A-Za-z0-9-]+$ ]] || usage_error "device id has unexpected characters"
need xcrun "Install Xcode 27.2"
acquire_lock ios-install
[ $BUILD = 0 ] || run_step "build for device" "$SD_DEV/ios-build.sh" --device
[ -n "$APP" ] || APP="$(cat "$WORK/cache/ios-last-app-device" 2>/dev/null || echo "$WORK/derived/ios-device/Build/Products/Debug-iphoneos/StreamSetu.app")"
[ -d "$APP" ] || [ $DRY_RUN = 1 ] || die $EX_MISSING "no app at $APP; run Scripts/dev/ios-build.sh --device (or pass --build)"
if [ $DRY_RUN = 1 ]; then log "  [dry-run] scan $APP; find paired device; devicectl install + launch"; exit 0; fi
step "secret scan"; scan_secrets "$APP" || exit $EX_GATE
list_device() { # prints the id of the only paired iPhone
  local j="$WORK/cache/devices.json"; mkdir -p "$WORK/cache"
  xcrun devicectl list devices --json-output "$j" >/dev/null 2>&1 || return 1
  python3 -I - "$j" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["result"]["devices"]
ok = [x["identifier"] for x in d if x.get("connectionProperties", {}).get("pairingState") == "paired" and x.get("hardwareProperties", {}).get("platform") == "iOS"]
if len(ok) != 1:
    sys.stderr.write("%d paired iOS devices\n" % len(ok)); sys.exit(1)
print(ok[0])
PY
}
CACHE="$WORK/cache/ios-device-id"
find_device() { [ -n "$DEV" ] && return 0; DEV="$(cat "$CACHE" 2>/dev/null || true)"; [ -z "$DEV" ] || return 0
  DEV="$(list_device)" || die $EX_DEVICE "no single paired iPhone found. Connect and trust the phone, or pass --device-id"; printf '%s\n' "$DEV" > "$CACHE"; }
find_device
locked_msg() { grep -qiE 'locked|unlock|passcode' "$1"; }
dc() { # title, then devicectl args; classifies a locked phone and a stale cached id
  local t=$1; shift; _exec "$t" xcrun devicectl "$@"
  [ "$LAST_RC" = 0 ] && return 0
  if locked_msg "$LAST_LOG"; then err "the phone is locked: unlock the phone, then run this again."; exit $EX_DEVICE; fi
  if grep -qiE 'no devices matched|not (found|connected)|unavailable' "$LAST_LOG"; then rm -f "$CACHE"; err "device $DEV is not reachable (cached id dropped). Connect the phone and run again."; exit $EX_DEVICE; fi
  err "$t failed:"; excerpt "$LAST_LOG" >&2; exit $EX_FAIL
}
BID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
STAMP="$DEV $(artifact_fp "$APP/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")")"
if [ $FORCE = 0 ] && [ "$(stamp_get ios-installed)" = "$STAMP" ]; then log "this build is already installed on the device"
else step "install"; dc install device install app --device "$DEV" "$APP"; ok "installed ($(fmt_ms "$LAST_MS"))"; stamp_set ios-installed "$STAMP"; fi
if [ $LAUNCH = 1 ]; then step "launch"; dc launch device process launch --device "$DEV" --terminate-existing "$BID"; ok "launched $BID"; fi
