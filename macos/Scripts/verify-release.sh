#!/bin/bash
# Release checks: signature, architectures, bundle metadata, privacy manifest, and no stray secrets or tool traces.
set -uo pipefail
cd "$(dirname "$0")/.."
APP="${1:-dist/StreamSetu.app}"; FAIL=0
ok()   { echo "  ✔ $1"; }
bad()  { echo "  ✘ $1"; FAIL=1; }
echo "Verifying $APP"
[ -d "$APP" ] && ok "bundle exists" || { bad "bundle missing"; exit 1; }
codesign --verify --strict --deep "$APP" 2>/dev/null && ok "code signature valid" || bad "code signature invalid"
SIG="$(codesign -dv "$APP" 2>&1)"
grep -q "flags=.*runtime" <<<"$SIG" && ok "Hardened Runtime enabled" || bad "Hardened Runtime missing"
echo "  architectures: $(lipo -archs "$APP/Contents/MacOS/StreamSetu" 2>/dev/null)"
/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist" | grep -q "app.streamsetu.mac" && ok "bundle identifier" || bad "bundle identifier"
[ -f "$APP/Contents/Resources/AppIcon.icns" ] && ok "app icon" || bad "app icon missing"
[ -f "$APP/Contents/Resources/PrivacyInfo.xcprivacy" ] && plutil -lint "$APP/Contents/Resources/PrivacyInfo.xcprivacy" >/dev/null && ok "privacy manifest valid" || bad "privacy manifest"
vtool -show-build "$APP/Contents/MacOS/StreamSetu" 2>/dev/null | grep -q "minos 14" && ok "minimum macOS 14" || echo "  – could not confirm minimum macOS"
if [ -n "${REDDY_FORBIDDEN_PATTERN:-}" ]; then
  if strings -a "$APP/Contents/MacOS/StreamSetu" | grep -qiE "$REDDY_FORBIDDEN_PATTERN"; then bad "binary contains a forbidden string"; else ok "no forbidden strings in binary"; fi
fi
if strings -a "$APP/Contents/MacOS/StreamSetu" | grep -qE "/Users/[A-Za-z0-9._-]+/"; then bad "binary contains a local home path"; else ok "no local paths in binary"; fi
if [ "${SKIP_SMOKE_TEST:-0}" != "1" ]; then
  if Scripts/smoke-test-app.sh "$APP" > /tmp/streamsetu-smoke.txt 2>&1; then ok "smoke test (plays a video through MPV and AVPlayer in the packaged app)"; else bad "smoke test failed"; cat /tmp/streamsetu-smoke.txt; fi
fi
if spctl --assess --type execute "$APP" 2>&1 | grep -q accepted; then ok "Gatekeeper accepts (Developer ID / notarized)"; else echo "  – Gatekeeper: not accepted (expected for ad-hoc builds; sign + notarize for distribution)"; fi
[ $FAIL -eq 0 ] && echo "✔ release checks passed" || { echo "✘ release checks failed"; exit 1; }
