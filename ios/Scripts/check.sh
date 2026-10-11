#!/bin/bash
# Builds everything that shares source: iOS Simulator SDK, iOS device SDK (no signing), and the Mac app + tests.
set -euo pipefail
cd "$(dirname "$0")/.."
XCODE=/Applications/Xcode.app/Contents/Developer
python3 ../legal/sync-legal.py --check
python3 Scripts/generate-project.py
for dest in "iphonesimulator|generic/platform=iOS Simulator" "iphoneos|generic/platform=iOS"; do
  sdk="${dest%%|*}"; d="${dest#*|}"
  DEVELOPER_DIR=$XCODE xcodebuild -project StreamSetu.xcodeproj -scheme StreamSetu -sdk "$sdk" -destination "$d" \
    -derivedDataPath "${TMPDIR:-/tmp}/streamsetu-ios-$sdk" CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
done
(cd ../macos && swift build 2>&1 | grep -E "error:|Build complete" || true)
