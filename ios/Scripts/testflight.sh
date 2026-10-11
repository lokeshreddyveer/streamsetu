#!/bin/bash
# Archives StreamSetu for the App Store and uploads it to TestFlight.
#
#   Scripts/testflight.sh [build-number] [--archive-only]       e.g.  Scripts/testflight.sh      (uses the next build number)
#
# Every upload needs a build number higher than the last one. The version shown to testers is MARKETING_VERSION in
# Scripts/generate-project.py.
#
# One-time setup (App Store Connect, in a browser):
#   appstoreconnect.apple.com > Apps > + > New App > iOS, name "StreamSetu" (or a variant if taken), Bundle ID app.streamsetu.ios,
#   any SKU. Then, after the first upload processes, TestFlight > Internal Testing > + > add yourself.
# Xcode must be signed in to your Apple ID (it creates the distribution certificate and profile on first use).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
TEAM="$(cat .signing-team)"
OUT="$HOME/Library/Application Support/StreamSetuRenew/testflight"; mkdir -p "$OUT"
ARG1="${1:-}"; [ "$ARG1" = "--archive-only" ] && ARG1=""
LAST=$(cat "$OUT/last-build" 2>/dev/null || echo 1)
BUILD="${ARG1:-$((LAST + 1))}"
case "$BUILD" in ''|*[!0-9]*) echo "build number must be a whole number"; exit 1;; esac
ARCHIVE="$OUT/StreamSetu-$BUILD.xcarchive"
python3 ../legal/sync-legal.py --check
python3 ../Scripts/audit-dependencies.py | grep -v "^  - " || true
python3 Scripts/generate-project.py >/dev/null

echo "▸ Archiving build ${BUILD}…"
xcodebuild archive -project StreamSetu.xcodeproj -scheme StreamSetu -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD" 2>&1 | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)"
[ -d "$ARCHIVE" ] || { echo "✘ archive failed"; exit 1; }
case " $* " in *" --archive-only "*) echo "✔ archived: $ARCHIVE"; exit 0;; esac

cat > "$OUT/ExportOptions.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
</dict></plist>
PL
echo "▸ Uploading to App Store Connect…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates 2>&1 | grep -E "error:|Upload|EXPORT (SUCCEEDED|FAILED)|Uploaded|There is no" 
echo "$BUILD" > "$OUT/last-build"
echo "Done. Build ${BUILD} is uploaded. It appears in TestFlight after Apple finishes processing it (usually 5-15 minutes)."
