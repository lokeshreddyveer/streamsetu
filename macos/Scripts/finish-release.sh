#!/bin/bash
# Checks Apple's answer for a DMG sent by release-dmg.sh and, once accepted, staples it and verifies it.
#
#   Scripts/finish-release.sh <version>
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: finish-release.sh <version>}"
export NOTARY_PROFILE="${NOTARY_PROFILE:-StreamSetu-NOTARY}"
DMG="dist/StreamSetu-$VERSION.dmg"; ID_FILE="dist/notarization-$VERSION.id"
[ -f "$DMG" ] && [ -f "$ID_FILE" ] || { echo "✘ run Scripts/release-dmg.sh $VERSION <build> first"; exit 1; }
ID="$(cat "$ID_FILE")"
STATUS="$(xcrun notarytool info "$ID" --keychain-profile "$NOTARY_PROFILE" 2>&1 | awk '/^ *status:/ {print substr($0, index($0,$2)); exit}')"
echo "Apple says: ${STATUS:-unknown} (submission $ID)"
case "$STATUS" in
  Accepted)
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1 | tail -1
    echo "✔ $DMG is signed, notarized and stapled. Publish it with Scripts/publish-release.sh $VERSION" ;;
  Invalid|Rejected)
    xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" | head -40; exit 1 ;;
  *) echo "Not ready yet. Run this again later." ;;
esac
