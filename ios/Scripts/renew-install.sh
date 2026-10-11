#!/bin/bash
# Renews the StreamSetu install on your iPhone.
#
# A free Apple ID signs apps for 7 days. Installing a freshly signed build before that ends starts a new 7 days, and your
# library, logins and settings stay (same bundle id, installed over the top). This script does exactly that:
#   rebuild (Release) -> sign with your Xcode account -> install on the connected iPhone.
#
#   Scripts/renew-install.sh            renew only if the last renewal is 5 or more days old
#   Scripts/renew-install.sh --force    renew now (also how to put a new build of the app on the phone)
#
# The iPhone must be unlocked-at-least-once-since-boot, trusted, and reachable: plugged in, or on the same Wi-Fi with
# "Connect via network" ticked for it in Xcode (Window > Devices and Simulators).
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
APP_ID="app.streamsetu.ios"
STATE="$HOME/Library/Application Support/StreamSetuRenew"; mkdir -p "$STATE"
STAMP="$STATE/last-renewal"
LOG() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# macOS does not let background jobs read ~/Documents, so the build runs from a snapshot kept outside it. Running this script
# from a terminal refreshes the snapshot from the project; a scheduled run reuses the last one.
PROJECT_ROOT="${STREAMSETU_PROJECT:-$HOME/Documents/iptv}"
SNAP="$STATE/snapshot"
if [ -d "$PROJECT_ROOT/ios" ] && ls "$PROJECT_ROOT/ios/StreamSetu" >/dev/null 2>&1; then
  mkdir -p "$SNAP/ios" "$SNAP/macos/Sources"
  rsync -a --delete --exclude 'build/' --exclude 'xcuserdata/' "$PROJECT_ROOT/ios/" "$SNAP/ios/"
  rsync -a --delete "$PROJECT_ROOT/macos/Sources/REDDY/" "$SNAP/macos/Sources/REDDY/"
  LOG "snapshot refreshed from $PROJECT_ROOT"
elif [ -d "$SNAP/ios/StreamSetu.xcodeproj" ]; then
  LOG "project folder not readable from here; using the last snapshot"
else
  LOG "no snapshot yet: run Scripts/renew-install.sh once from a terminal"; exit 1
fi
cd "$SNAP/ios"

if [ "${1:-}" != "--force" ] && [ -f "$STAMP" ]; then
  age=$(( ( $(date +%s) - $(stat -f %m "$STAMP") ) / 86400 ))
  if [ "$age" -lt 5 ]; then LOG "last renewal $age day(s) ago; nothing to do"; exit 0; fi
fi

# Find the phone: STREAMSETU_DEVICE (name or id) if set, else the first connected iPhone/iPad.
JSON="$(mktemp)"; trap 'rm -f "$JSON"' EXIT
xcrun devicectl list devices --json-output "$JSON" >/dev/null 2>&1 || { LOG "could not list devices"; exit 1; }
DEVICE=$(python3 - "$JSON" "${STREAMSETU_DEVICE:-}" <<'PY'
import json, sys
want = sys.argv[2].lower()
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hw, cp, dp = d.get("hardwareProperties", {}), d.get("connectionProperties", {}), d.get("deviceProperties", {})
    if hw.get("platform") not in ("iOS", "iPadOS"): continue
    if cp.get("tunnelState") not in ("connected",) and cp.get("pairingState") != "paired": continue
    if cp.get("tunnelState") == "unavailable": continue
    if want and want not in (dp.get("name", "").lower(), d.get("identifier", "").lower(), hw.get("udid", "").lower()): continue
    print(d["identifier"]); break
PY
)
[ -n "$DEVICE" ] || { LOG "no iPhone reachable; will try again later"; exit 0; }
LOG "renewing on device $DEVICE"

# Free-account profiles are cached by Xcode and reused until they expire; remove ours so a fresh 7-day one is issued.
for f in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.mobileprovision; do
  [ -f "$f" ] || continue
  id=$(security cms -D -i "$f" 2>/dev/null | plutil -extract Entitlements.application-identifier raw - 2>/dev/null || true)
  case "$id" in *".$APP_ID") rm -f "$f"; LOG "removed cached profile $(basename "$f")";; esac
done

OUT="$STATE/build"
xcodebuild -project StreamSetu.xcodeproj -scheme StreamSetu -configuration Release -destination "id=$DEVICE" \
  -allowProvisioningUpdates -derivedDataPath "$OUT" build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
APP="$OUT/Build/Products/Release-iphoneos/StreamSetu.app"
[ -d "$APP" ] || { LOG "build failed; nothing installed"; exit 1; }

xcrun devicectl device install app --device "$DEVICE" "$APP" 2>&1 | tail -3
touch "$STAMP"
LOG "installed on the phone (profile valid for a year with the paid account)"
