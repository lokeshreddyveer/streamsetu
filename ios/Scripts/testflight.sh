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
# Dependency gate: a reported vulnerability, a failed lookup or an unidentified library stops the archive. The report is kept with the build.
mkdir -p "$OUT/reports"
python3 ../Scripts/audit-dependencies.py --strict --scope ios --report "$OUT/reports/dependencies-$BUILD.json" || { echo "✘ dependency check did not come back clean (see above). The only way past it is a signed, expiring entry in Scripts/risk-acceptances.json (docs/RELEASE-SECURITY.md)."; exit 1; }
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
# Entitlements gate: the source file says aps-environment "development" (Xcode rewrites it when it signs for distribution). Export the same archive to a local .ipa first and refuse
# to upload unless the signed app really carries production push, so a development entitlement can never reach TestFlight.
echo "▸ Checking the signed entitlements…"
CHECK="$(mktemp -d)"
sed 's|<string>upload</string>|<string>export</string>|' "$OUT/ExportOptions.plist" > "$CHECK/ExportOptions.plist"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$CHECK/ExportOptions.plist" -exportPath "$CHECK/out" -allowProvisioningUpdates >/dev/null 2>&1 || { echo "✘ could not export the archive to check its entitlements"; exit 1; }
IPA="$(ls "$CHECK"/out/*.ipa 2>/dev/null | head -1)"; [ -n "$IPA" ] || { echo "✘ no .ipa was produced to check"; exit 1; }
unzip -q -o "$IPA" -d "$CHECK/ipa"
APP_IN_IPA="$(ls -d "$CHECK"/ipa/Payload/*.app | head -1)"
ENT="$(codesign -d --entitlements :- "$APP_IN_IPA" 2>/dev/null)"
echo "$ENT" | grep -A1 "aps-environment" | grep -q "<string>production</string>" || { echo "✘ the signed app does not have production push (aps-environment). Not uploading."; rm -rf "$CHECK"; exit 1; }
echo "$ENT" | grep -q "com.apple.developer.icloud" && { echo "$ENT" | grep -A3 "icloud-container-environment" | grep -q "Production" || echo "  – iCloud container environment not marked Production in the signed app (check it)"; }
rm -rf "$CHECK"
echo "✔ production push entitlement confirmed in the signed app"
echo "▸ Uploading to App Store Connect…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates 2>&1 | grep -E "error:|Upload|EXPORT (SUCCEEDED|FAILED)|Uploaded|There is no" 
echo "$BUILD" > "$OUT/last-build"
echo "Done. Build ${BUILD} is uploaded. It appears in TestFlight after Apple finishes processing it (usually 5-15 minutes)."
