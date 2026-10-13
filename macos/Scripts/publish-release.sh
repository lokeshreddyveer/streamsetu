#!/bin/bash
# Publishes a notarized DMG to the public releases repo (the source code repo stays private).
#
#   BUILD=<build number> Scripts/publish-release.sh <version> [notes]       e.g.  Scripts/publish-release.sh 2.2.2 "Trailers, app lock and more"
#
# Run it after release-signed.sh has produced and stapled dist/StreamSetu-<version>.dmg.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: publish-release.sh <version> [notes]}"; NOTES="${2:-StreamSetu $VERSION}"
REPO="${RELEASES_REPO:-lokeshreddyveer/streamsetu-releases}"
DMG="dist/StreamSetu-$VERSION.dmg"
[ -f "$DMG" ] || { echo "✘ $DMG not found. Run Scripts/release-signed.sh first."; exit 1; }
xcrun stapler validate "$DMG" >/dev/null 2>&1 || { echo "✘ $DMG is not stapled/notarized. Not publishing."; exit 1; }
SUMS="$(dirname "$DMG")/SHA256SUMS-$VERSION.txt"
( cd dist && shasum -a 256 "StreamSetu-$VERSION.dmg" ) > "$SUMS"
gh release create "v$VERSION" "$DMG" "$SUMS" --repo "$REPO" --title "StreamSetu $VERSION" --notes "$NOTES"
"$(dirname "$0")/update-appcast.sh" "$VERSION" "${BUILD:?set BUILD to the build number}" "$NOTES"
echo "✔ published: https://github.com/$REPO/releases/tag/v$VERSION"
