#!/bin/bash
# test-ios.sh - iPhone tests on simulators this script owns.
# Usage: Scripts/dev/test-ios.sh [--unit | --ui | --walk] [--cleanup] [--dry-run] [--timings]
#   --unit     (default) StreamSetuTests         --ui    StreamSetuUITests except the Atlas walk
#   --walk     ios/Scripts/check-atlas-walk.sh on the owned iPhone and iPad simulators
#   --cleanup  shut down and delete ONLY the simulators named StreamSetu-dev-* (nothing else is touched), then exit
# Creates (once, then reuses) simulators StreamSetu-dev-iPhone and StreamSetu-dev-iPad. The shared default devices and physical devices are never used.
# Derived data: $STREAMSETU_WORK/derived/ios-test (kept between runs).
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
MODE=unit; CLEANUP=0
while [ $# -gt 0 ]; do
  common_flag "$1" && { shift; continue; }
  case "$1" in --unit) MODE=unit;; --ui) MODE=ui;; --walk) MODE=walk;; --cleanup) CLEANUP=1;; *) usage_error "unknown option: $1";; esac; shift
done
need xcrun "Install Xcode 27.2"
acquire_lock test-ios
PHONE=StreamSetu-dev-iPhone; PAD=StreamSetu-dev-iPad
SIMPY='
import json, subprocess, sys
name, kind = sys.argv[1], sys.argv[2]
q = lambda *a: json.loads(subprocess.check_output(["xcrun", "simctl", "list", "-j", *a]))
for rt, devs in q("devices")["devices"].items():
    for d in devs:
        if d["name"] == name and d.get("isAvailable", True): print("UDID", d["udid"]); sys.exit(0)
if kind == "all":
    sys.exit(0)
types = [t["identifier"] for t in q("devicetypes")["devicetypes"] if t["name"].startswith(kind)]
rts = [r["identifier"] for r in q("runtimes")["runtimes"] if r.get("isAvailable") and r["identifier"].split(".")[-1].startswith("iOS")]
if not types or not rts: sys.exit("no %s device type or iOS runtime installed" % kind)
print("NEW", types[-1], rts[-1])'
if [ $CLEANUP = 1 ]; then
  for n in $PHONE $PAD; do
    id="$(python3 -I -c "$SIMPY" "$n" all | sed -n 's/^UDID //p')"
    if [ -z "$id" ]; then log "$n: not present"; continue; fi
    run_step "delete $n" bash -c "xcrun simctl shutdown '$id' 2>/dev/null; xcrun simctl delete '$id'"
  done; exit 0
fi
ensure_sim() { # name kind -> udid on stdout (created only when absent)
  local out; out="$(python3 -I -c "$SIMPY" "$1" "$2")" || return 1
  case "$out" in UDID*) echo "${out#UDID }";; NEW*) set -- "$1" $out; xcrun simctl create "$1" "$3" "$4";; esac
}
if [ $DRY_RUN = 1 ]; then log "  [dry-run] would ensure simulators $PHONE$([ $MODE = walk ] && echo " and $PAD") and run $MODE tests"; ios_gen_project; exit 0; fi
step "simulator $PHONE"; UDID="$(ensure_sim $PHONE iPhone)" || die $EX_MISSING "could not create a simulator (is an iOS runtime installed? Xcode > Settings > Components)"
ios_gen_project
DD="$WORK/derived/ios-test"
case "$MODE" in
  unit) run_step "xcodebuild test (unit)" xcodebuild test -project "$ROOT/ios/StreamSetu.xcodeproj" -scheme StreamSetu -destination "id=$UDID" -derivedDataPath "$DD" -jobs "$(xcode_jobs)" -only-testing:StreamSetuTests CODE_SIGNING_ALLOWED=NO;;
  ui) run_step "xcodebuild test (UI)" xcodebuild test -project "$ROOT/ios/StreamSetu.xcodeproj" -scheme StreamSetu -destination "id=$UDID" -derivedDataPath "$DD" -jobs "$(xcode_jobs)" -only-testing:StreamSetuUITests -skip-testing:StreamSetuUITests/AtlasWalkTests CODE_SIGNING_ALLOWED=NO;;
  walk) ensure_sim $PAD iPad >/dev/null || die $EX_MISSING "could not create the iPad simulator"
    run_step "atlas walk" env WALK_IPHONE="$PHONE" WALK_IPAD="$PAD" WALK_DERIVED="$WORK/derived/ios-walk" WALK_SKIP_GEN=1 "$ROOT/ios/Scripts/check-atlas-walk.sh";;
esac
