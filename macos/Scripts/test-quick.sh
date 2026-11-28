#!/bin/bash
# Fast targeted tests: incremental test build, then only the tests that match a filter. No sleeps, no full suite.
# Usage: Scripts/test-quick.sh "SearchRankPureTests|QueryRelaxTests"     (a regular expression on suite or test names)
#        Scripts/test-quick.sh -r 3 "LocalFilesFlowTests"                   (run the filter 3 times to expose flakiness)
# Prints only failures and one summary line; exit code is 0 when every run passed.
set -uo pipefail
cd "$(dirname "$0")/.."
RUNS=1
if [ "${1:-}" = "-r" ]; then RUNS="${2:?runs}"; shift 2; fi
FILTER="${1:?usage: test-quick.sh [-r N] \"FilterRegex\"}"
export STREAMSETU_TESTING=1
t0=$(date +%s)
if ! swift build --build-tests 2>&1 | grep -E "error:|Compiling|Build complete" | grep -E "error:|Build complete"; then :; fi
status=0
for i in $(seq 1 "$RUNS"); do
  out=$(swift test --skip-build --filter "$FILTER" 2>&1)
  echo "$out" | grep -E "^✘ Test .*(failed|recorded an issue)|^↳" | cut -c1-240
  line=$(echo "$out" | grep -E "Test run with" | tail -1 | cut -c1-160)
  echo "run $i: ${line:-no tests matched the filter}"
  echo "$out" | grep -q "✘ Test run" && status=1
  [ -z "$line" ] && status=1
done
echo "done in $(( $(date +%s) - t0 )) s, filter: $FILTER"
exit $status
