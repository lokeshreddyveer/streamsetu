#!/bin/bash
# Records an Instruments "Animation Hitches" trace of the running Mac app (signposts from category "Smooth" are included),
# then prints the hitch summary. Usage: Scripts/hitch-run.sh [seconds] [output.trace]
# Scroll Home, a folder row and a grid while it records. Open the .trace in Instruments for the detail.
# The trace can contain what was on screen: keep it local, never commit it.
set -euo pipefail
SECONDS_TO_RECORD="${1:-20}"
OUT="${2:-${TMPDIR:-/tmp}/streamsetu-hitches-$(date +%Y%m%d-%H%M%S).trace}"
APP_NAME="${STREAMSETU_APP_NAME:-REDDY}"
if ! xcrun xctrace list templates 2>/dev/null | grep -q "Animation Hitches"; then
  echo "The Animation Hitches template is not available (Xcode is required)." >&2; exit 1
fi
PID="$(pgrep -x "$APP_NAME" | head -1 || true)"
if [ -z "$PID" ]; then echo "Start the app first ($APP_NAME is not running), then run this again." >&2; exit 1; fi
echo "Recording $SECONDS_TO_RECORD s from pid $PID to $OUT"
xcrun xctrace record --template "Animation Hitches" --attach "$PID" --time-limit "${SECONDS_TO_RECORD}s" --output "$OUT" --no-prompt
echo "Hitch table (counts and durations only):"
xcrun xctrace export --input "$OUT" --xpath '/trace-toc/run[1]/data/table[@schema="hitches"]' 2>/dev/null | grep -c "<row" | sed 's/^/  hitches: /' || true
echo "Trace saved: $OUT"
