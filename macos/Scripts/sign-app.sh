#!/bin/bash
# Re-signs dist/StreamSetu.app with your Developer ID for distribution (Hardened Runtime + entitlements).
# Requires an Apple Developer account: SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" Scripts/sign-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to your 'Developer ID Application: …' certificate name}"
APP="${1:-dist/StreamSetu.app}"
# sign nested code first (bundled libraries), then the app
find "$APP/Contents/Frameworks" -type f \( -name "*.dylib" -o -perm +111 \) 2>/dev/null | while read -r f; do
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$f"
done
ENTITLEMENTS="Configuration/REDDY.entitlements"
PROFILE="Configuration/StreamSetu.provisionprofile"
if [ -f "$PROFILE" ]; then
  # iCloud sync and the shared Keychain need the provisioning profile from developer.apple.com inside the app, plus the
  # matching entitlements. Without the profile the app is signed without them and simply has no iCloud.
  cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
  ENTITLEMENTS="Configuration/REDDY-iCloud.entitlements"
  echo "▸ Embedding the provisioning profile (iCloud sync enabled)"
fi
codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"
echo "✔ signed $APP"
