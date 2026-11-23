#!/bin/bash
# Mac UI tests for StreamSetu. Runs a COPY of the app (never /Applications) with a throwaway data folder and a fixture playlist.
#   usage: UITests/run-mac-uitests.sh [-only-testing:StreamSetuMacUITests/Class/test ...]
# The copy is a debug build (so it holds the Atlas markers and the fixture loader, which release builds do not have) dropped into a copy of dist/StreamSetu.app,
# given another bundle id (so it has its own UserDefaults and does not collide with an installed copy) and Sparkle switched off.
# The test runner needs Accessibility permission (System Settings > Privacy & Security > Accessibility) for Xcode / xcodebuild's runner.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; MAC="$HERE/.."
WORK="${UITEST_WORK:-${TMPDIR:-/tmp}/streamsetu-mac-uitests}"
mkdir -p "$WORK"
echo "work folder: $WORK"
APP="$WORK/StreamSetuUITest.app"
if [ -z "${UITEST_REUSE_APP:-}" ]; then
swift build --package-path "$MAC" --scratch-path "$WORK/build" >"$WORK/build.log" 2>&1 || { tail -30 "$WORK/build.log"; exit 1; }
rm -rf "$APP"; cp -R "$MAC/dist/StreamSetu.app" "$APP"
cp "$WORK/build/debug/REDDY" "$APP/Contents/MacOS/StreamSetu"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/StreamSetu" 2>/dev/null || true
PL="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.streamsetu.mac.uitest" "$PL"
/usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$PL" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks false" "$PL" 2>/dev/null || true
rm -f "$APP/Contents/embedded.provisionprofile"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
fi
# Fixture: a few seconds of video served from localhost, and a playlist of live channels and movies that points at it.
swiftc -O -o "$WORK/make-media" "$MAC/Scripts/make-test-media.swift" 2>/dev/null
"$WORK/make-media" "$WORK/test.mp4" >/dev/null; mkdir -p "$WORK/movie"; cp "$WORK/test.mp4" "$WORK/movie/test.mp4"
PORT=18765
python3 -m http.server $PORT --bind 127.0.0.1 --directory "$WORK" >/dev/null 2>&1 & SRV=$!
trap 'kill $SRV 2>/dev/null; pkill -f "StreamSetuUITest.app/Contents/MacOS" 2>/dev/null || true' EXIT
python3 "$HERE/make-fixture.py" "$WORK/fixture.m3u" "http://127.0.0.1:$PORT/test.mp4"
(cd "$HERE" && xcodegen generate --quiet)
export TEST_RUNNER_STREAMSETU_UITEST_APP="$APP" TEST_RUNNER_STREAMSETU_UITEST_M3U="$WORK/fixture.m3u" TEST_RUNNER_STREAMSETU_UITEST_OUT="${UITEST_OUT:-$WORK/out}"
mkdir -p "$TEST_RUNNER_STREAMSETU_UITEST_OUT"
RES="$WORK/result-$(date +%H%M%S).xcresult"
set +e
xcodebuild test -project "$HERE/StreamSetuMacUITests.xcodeproj" -scheme StreamSetuMacUITests -destination 'platform=macOS' \
  -derivedDataPath "$WORK/dd" -resultBundlePath "$RES" "$@" 2>&1 | grep -E "error:|warning: .*(Accessib|permission)|Test Case|Executed|TEST (SUCC|FAIL)|\*\* "

CODE=${PIPESTATUS[0]}
xcrun xcresulttool export attachments --path "$RES" --output-path "$TEST_RUNNER_STREAMSETU_UITEST_OUT" >/dev/null 2>&1 || true
python3 - "$TEST_RUNNER_STREAMSETU_UITEST_OUT" <<'PY' || true
import json, os, shutil, sys
out = sys.argv[1]
for t in json.load(open(os.path.join(out, "manifest.json"))):
    for a in t["attachments"]:
        name = a["suggestedHumanReadableName"].rsplit("_0_", 1)[0]
        ext = os.path.splitext(a["exportedFileName"])[1]
        src = os.path.join(out, a["exportedFileName"])
        if os.path.exists(src) and ext in (".png", ".txt", ".md"): shutil.move(src, os.path.join(out, (name if name.endswith(ext) else name + ext)))
PY
exit $CODE
