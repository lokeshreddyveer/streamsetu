#!/bin/bash
# Launches the packaged app headlessly and plays a generated test video through MPV and AVPlayer (see Sources/.../SelfTest.swift).
# This catches the failures unit tests can't see: Hardened Runtime kills, thread-safety traps in system callbacks, a broken libmpv.
#   usage: Scripts/smoke-test-app.sh [dist/StreamSetu.app]
set -uo pipefail
cd "$(dirname "$0")/.."
APP="${1:-dist/StreamSetu.app}"
BIN="$APP/Contents/MacOS/StreamSetu"
[ -x "$BIN" ] || { echo "no app at $APP"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
swiftc -O -o "$WORK/make-media" Scripts/make-test-media.swift 2>/dev/null || { echo "could not build the media generator"; exit 2; }
"$WORK/make-media" "$WORK/test.mp4" >/dev/null || { echo "could not generate the test video"; exit 2; }
STREAMSETU_SELFTEST_MEDIA="$WORK/test.mp4" "$BIN" > "$WORK/out.txt" 2>&1 &
PID=$!
for _ in $(seq 1 90); do kill -0 $PID 2>/dev/null || break; sleep 1; done
if kill -0 $PID 2>/dev/null; then kill -9 $PID 2>/dev/null; echo "✘ smoke test timed out"; cat "$WORK/out.txt"; exit 1; fi
wait $PID; CODE=$?
cat "$WORK/out.txt" | grep -E "SELFTEST|^  (ok|FAIL|skip)" 
if [ $CODE -eq 0 ] && grep -q "^SELFTEST OK" "$WORK/out.txt"; then echo "✔ smoke test passed"; exit 0; fi
echo "✘ smoke test failed (exit $CODE)"; tail -20 "$WORK/out.txt"; exit 1
