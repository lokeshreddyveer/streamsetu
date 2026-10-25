#!/bin/bash
# Builds and runs the test suite. Uses `swift test` when Xcode is installed; otherwise falls back to a small
# Swift Testing host (Command Line Tools only).
set -euo pipefail
# Tells the app code it is under test, so it never sends a report to the real server or writes the real playback log.
export STREAMSETU_TESTING=1
cd "$(dirname "$0")/.."
# The tests make many throwaway databases ("reddy-*") in the system temp folder and do not remove them: they once filled the disk (tens of
# thousands of files, gigabytes). So every run removes what it created, whatever the outcome.
STAMP="$(mktemp)"
# Another test run (or anything else using the reddy-* names) may be going at the same time, and the folders are told apart only by when they were made. So nothing is removed
# while any other run of this script is alive: those leftovers are taken away by whichever run ends last.
other_runs() {
  local mine=" $$"; local p=$$
  while [ "$p" -gt 1 ]; do p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"; [ -n "$p" ] || break; mine="$mine $p"; done     # this run and whatever started it
  for pid in $(pgrep -f "Scripts/run-tests.sh" || true); do case "$mine " in *" $pid "*) ;; *) echo "$pid"; return;; esac; done
}
cleanup() {
  if [ -n "$(other_runs || true)" ]; then rm -f "$STAMP"; return; fi
  for dir in "${TMPDIR:-/tmp}" "$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"; do
    [ -d "$dir" ] && find "$dir" -maxdepth 1 -name 'reddy-*' -newer "$STAMP" -exec rm -rf {} + 2>/dev/null || true
  done
  rm -f "$STAMP"
}
trap cleanup EXIT
if xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
  swift test "$@"
  exit $?
fi
swift build --build-tests >/dev/null
RUNNER="$(mktemp -d)/test-runner"
swiftc -O -o "$RUNNER" Scripts/TestRunner/main.swift
BIN=".build/debug/REDDYPackageTests.xctest/Contents/MacOS/REDDYPackageTests"
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
DYLD_FRAMEWORK_PATH="$FW" DYLD_LIBRARY_PATH="$FW/../usr/lib" "$RUNNER" "$BIN" "${1:-}"
