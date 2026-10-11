#!/bin/bash
# Submits the DMG to Apple's notary service and staples the ticket.
# One-time setup:  xcrun notarytool store-credentials REDDY-NOTARY --apple-id you@example.com --team-id TEAMID
# Then:            NOTARY_PROFILE=REDDY-NOTARY Scripts/notarize-dmg.sh dist/StreamSetu-1.0.0.dmg
set -euo pipefail
cd "$(dirname "$0")/.."
DMG="${1:?usage: notarize-dmg.sh <path-to.dmg>}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile name}"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
echo "✔ notarized and stapled $DMG"
