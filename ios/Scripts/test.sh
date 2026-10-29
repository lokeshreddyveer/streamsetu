#!/bin/bash
# Builds the iPhone app with its test bundles and runs them on a simulator. With no simulator on this Mac it still compiles everything (build-for-testing), which is the part that
# can run here; the tests themselves then have to be run from a Mac or a CI machine that has an iOS Simulator (or from Xcode on a device).
#
#   Scripts/test.sh                 # simulator tests if one exists, otherwise compile only
#   Scripts/test.sh "iPhone 16"     # a named simulator
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 Scripts/generate-project.py >/dev/null
DD="${TMPDIR:-/tmp}/streamsetu-ios-tests"
SIM="${1:-$(xcrun simctl list devices available 2>/dev/null | sed -n 's/^ *\(iPhone[^(]*\) (.*/\1/p' | head -1 | sed 's/ *$//')}"
if [ -n "$SIM" ]; then
  xcodebuild test -project StreamSetu.xcodeproj -scheme StreamSetu -destination "platform=iOS Simulator,name=$SIM" -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Test Suite|Test Case.*(passed|failed)|\*\* TEST"
else
  echo "No iOS Simulator is installed here: compiling the app and both test bundles only."
  xcodebuild build-for-testing -project StreamSetu.xcodeproj -scheme StreamSetu -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|\*\* TEST BUILD"
fi
