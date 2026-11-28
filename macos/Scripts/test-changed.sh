#!/bin/bash
# Runs the tests that belong to what changed: for every changed Swift file (git diff against HEAD) it finds the test files that mention its main type,
# collects their suite names and runs only those. Falls back to nothing when no test mentions the change (it says so).
# Usage: Scripts/test-changed.sh [-r N]
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(cd .. && pwd)"
RUNS=1; [ "${1:-}" = "-r" ] && RUNS="${2:?runs}"
changed=$(git -C "$ROOT" diff --name-only HEAD -- macos | grep -E "\.swift$" | sed 's#^macos/##')
[ -z "$changed" ] && { echo "no changed Swift files"; exit 0; }
suites=""
for f in $changed; do
  case "$f" in
    Tests/*) files="$f" ;;
    *) base=$(basename "$f" .swift); files=$(grep -rlE "\b$base\b" Tests 2>/dev/null) ;;
  esac
  for tf in $files; do
    suites="$suites $(grep -hoE "(struct|class|final class) [A-Za-z0-9_]+(Tests|Test)\b" "$tf" 2>/dev/null | awk '{print $NF}')"
  done
done
filter=$(echo $suites | tr ' ' '\n' | sort -u | grep . | paste -sd'|' -)
[ -z "$filter" ] && { echo "no test mentions the changed files; nothing to run (add a focused test)"; exit 0; }
echo "running: $filter"
exec Scripts/test-quick.sh -r "$RUNS" "$filter"
