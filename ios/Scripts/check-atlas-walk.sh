#!/bin/bash
# Gate (c): walks every screen the Atlas declares on an iPhone and an iPad simulator (never a physical device) and reports drift.
#   Scripts/check-atlas-walk.sh                 # iPhone and iPad, new drift fails
#   Scripts/check-atlas-walk.sh iphone|ipad     # one of them
#   Scripts/check-atlas-walk.sh --prove <atlas id> iphone   # leaves one declaration out: the run must FAIL (proves the gate bites)
#   Scripts/check-atlas-walk.sh --accept        # writes today's drift into StreamSetuUITests/atlas-walk-known.json (reviewed by hand, then committed)
# Nightly: run it from a scheduler on a Mac with Xcode. Needs a booted-or-bootable simulator; set WALK_IPHONE / WALK_IPAD to the device names to override the defaults.
set -uo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
OUT=/tmp/streamsetu-atlas-walk; mkdir -p "$OUT"
DD="${WALK_DERIVED:-${TMPDIR:-/tmp}/streamsetu-ios-walk}"
IPHONE="${WALK_IPHONE:-iPhone 17}"; IPAD="${WALK_IPAD:-iPad Pro 11-inch (M5)}"
ACCEPT=0; WHICH="iphone ipad"
PROVE=""; prev=""
for a in "$@"; do case "$a" in --accept) ACCEPT=1;; iphone|ipad) WHICH="$a";; esac; [ "$prev" = "--prove" ] && PROVE="$a"; prev="$a"; done
[ -n "$PROVE" ] && export TEST_RUNNER_ATLAS_WALK_DROP="$PROVE"
[ -n "${WALK_SKIP_GEN:-}" ] || python3 Scripts/generate-project.py >/dev/null || { echo "could not generate the project"; exit 2; }
# The ids the source marks, so the walk can tell "declared and marked but not on screen" from "declared, never marked".
grep -rhoE '\.atlas(Optional|Covers|Screen)?\("[A-Za-z0-9._-]+"\)|atlas: "[A-Za-z0-9._-]+"' StreamSetu ../macos/Sources/REDDY 2>/dev/null | grep -oE '"[A-Za-z0-9._-]+"' | tr -d '"' | sort -u > "$OUT/marked.txt"
status=0
for kind in $WHICH; do
  if [ "$kind" = iphone ]; then NAME="$IPHONE"; else NAME="$IPAD"; fi
  echo "== atlas walk on $NAME"
  xcodebuild test -project StreamSetu.xcodeproj -scheme StreamSetu -destination "platform=iOS Simulator,name=$NAME" -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO \
    -only-testing:StreamSetuUITests/AtlasWalkTests > "$OUT/xcodebuild-$kind.log" 2>&1
  rc=$?
  [ -f "$OUT/report-$kind.txt" ] && cat "$OUT/report-$kind.txt" || { echo "no report written; see $OUT/xcodebuild-$kind.log"; rc=1; }
  if [ $ACCEPT = 1 ] && [ -f "$OUT/drift-$kind.json" ]; then
    python3 - "$kind" <<'PY'
import json, sys
k = sys.argv[1]; p = "StreamSetuUITests/atlas-walk-known.json"
d = json.load(open(p)); d[k] = json.load(open(f"/tmp/streamsetu-atlas-walk/drift-{k}.json")); json.dump(d, open(p, "w"), indent=1); print("accepted", len(d[k]), "known drift items for", k)
PY
    rc=0
  fi
  [ $rc -ne 0 ] && status=1
done
[ $status -eq 0 ] && echo "atlas walk: ok" || echo "atlas walk: FAILED"
exit $status
