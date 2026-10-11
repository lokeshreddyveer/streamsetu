#!/bin/bash
# Proves the bundled libmpv survives macOS's Hardened Runtime (the condition the shipped app runs under).
# usage: Scripts/verify-mpv-hardened.sh <media-file> [StreamSetu.app]
set -euo pipefail
cd "$(dirname "$0")/.."
MEDIA="${1:?usage: verify-mpv-hardened.sh <media-file> [StreamSetu.app]}"; APP="${2:-dist/StreamSetu.app}"
TMP="$(mktemp -d)"
swiftc -O -o "$TMP/check" Scripts/HardenedMPVCheck/main.swift
codesign --force -s - --options runtime --entitlements Configuration/REDDY.entitlements "$TMP/check"
"$TMP/check" "$(cd "$APP" && pwd)/Contents/Frameworks/libmpv.2.dylib" "$MEDIA"
