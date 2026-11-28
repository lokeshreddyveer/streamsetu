#!/bin/bash
# The one final regression run: the whole suite, serially (Swift Testing runs tests in parallel by default and the time-based tests need the machine to
# themselves). Freeze source edits and stop other builds while it runs. Writes the full log and a sorted failure summary next to each other.
# Usage: Scripts/test-serial.sh [log-prefix]      default prefix: /tmp/streamsetu-full
set -uo pipefail
cd "$(dirname "$0")/.."
P="${1:-/tmp/streamsetu-full}"
export STREAMSETU_TESTING=1
if pgrep -f "swift-build|swift-test|swift-frontend" >/dev/null; then echo "another build or test is running; stop it first"; exit 2; fi
swift build --build-tests 2>&1 | grep -E "error:|Build complete"
t0=$(date +%s)
swift test --skip-build --no-parallel > "$P.log" 2>&1
code=$?
grep -E "^✘ Test .* failed|^✘ Test run with|^✔ Test run with" "$P.log" | sed 's/ after.*//' | sort -u | cut -c1-200 > "$P.sum"
echo "exit $code in $(( $(date +%s) - t0 )) s"
cat "$P.sum"
echo "log: $P.log"
exit $code
