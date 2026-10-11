#!/bin/bash
# Builds and runs the test suite. Uses `swift test` when Xcode is installed; otherwise falls back to a small
# Swift Testing host (Command Line Tools only).
set -euo pipefail
cd "$(dirname "$0")/.."
if xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
  exec swift test "$@"
fi
swift build --build-tests >/dev/null
RUNNER="$(mktemp -d)/test-runner"
swiftc -O -o "$RUNNER" Scripts/TestRunner/main.swift
BIN=".build/debug/REDDYPackageTests.xctest/Contents/MacOS/REDDYPackageTests"
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
DYLD_FRAMEWORK_PATH="$FW" DYLD_LIBRARY_PATH="$FW/../usr/lib" "$RUNNER" "$BIN" "${1:-}"
