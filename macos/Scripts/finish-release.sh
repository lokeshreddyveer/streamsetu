#!/bin/bash
# Checks Apple's answer for the DMGs sent by release-dmg.sh (-AppleSilicon and -Intel) and, once each is accepted, staples and verifies it.
#
#   Scripts/finish-release.sh <version>
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: finish-release.sh <version>}"
export NOTARY_PROFILE="${NOTARY_PROFILE:-StreamSetu-NOTARY}"
PENDING=0; FAILED=0
for SUFFIX in "-AppleSilicon" "-Intel"; do
  DMG="dist/StreamSetu-$VERSION$SUFFIX.dmg"; ID_FILE="dist/notarization-$VERSION$SUFFIX.id"
  [ -f "$DMG" ] && [ -f "$ID_FILE" ] || { echo "✘ $DMG or its submission id is missing: run Scripts/release-dmg.sh $VERSION <build> first"; FAILED=1; continue; }
  ID="$(cat "$ID_FILE")"
  STATUS="$(xcrun notarytool info "$ID" --keychain-profile "$NOTARY_PROFILE" 2>&1 | awk '/^ *status:/ {print substr($0, index($0,$2)); exit}')"
  echo "Apple says: ${STATUS:-unknown} for $DMG (submission $ID)"
  case "$STATUS" in
    Accepted)
      xcrun stapler staple "$DMG"
      xcrun stapler validate "$DMG"
      spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1 | tail -1
      echo "✔ $DMG is signed, notarized and stapled" ;;
    Invalid|Rejected)
      xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" | head -40; FAILED=1 ;;
    *) echo "  Not ready yet."; PENDING=1 ;;
  esac
done
[ "$FAILED" = 0 ] || exit 1
[ "$PENDING" = 0 ] && echo "Both are done. Publish with Scripts/release.sh." || echo "Run this again later for the ones not ready."
