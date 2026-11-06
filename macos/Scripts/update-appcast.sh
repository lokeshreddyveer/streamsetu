#!/bin/bash
# Adds a release to the update feed (appcast.xml at the root of the StreamSetu repo) so installed copies of the Mac app offer it.
# The DMG is signed with the update key kept in this Mac's Keychain (account "streamsetu"; made by Sparkle's generate_keys).
#
#   RELEASE_TAG=<tag of the release that holds the DMG> Scripts/update-appcast.sh <version> <build> [notes]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: update-appcast.sh <version> <build> [notes]}"; BUILD="${2:?usage: update-appcast.sh <version> <build> [notes]}"; NOTES="${3:-StreamSetu $VERSION}"
REPO="${RELEASES_REPO:-lokeshreddyveer/streamsetu}"
DMG="dist/StreamSetu-$VERSION.dmg"
[ -f "$DMG" ] || { echo "✘ $DMG not found"; exit 1; }
SIGN="$(.build/artifacts/sparkle/Sparkle/bin/sign_update --account streamsetu "$DMG")"     # sparkle:edSignature="…" length="…"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
gh repo clone "$REPO" "$WORK/repo" -- --depth 1 --filter=blob:none >/dev/null 2>&1
URL="https://github.com/$REPO/releases/download/${RELEASE_TAG:-mac-v$VERSION}/StreamSetu-$VERSION.dmg"
RESULT="$(python3 "$(dirname "$0")/appcast_add.py" "$WORK/repo/appcast.xml" "$VERSION" "$BUILD" "$URL" "$SIGN" "$NOTES")"
[ "$RESULT" = "already offered" ] && { echo "✔ the update feed already offers $VERSION; nothing to add"; exit 0; }
cd "$WORK/repo" && git add appcast.xml && git commit -qm "Update feed for StreamSetu $VERSION" && git push -q origin HEAD
echo "✔ update feed now offers $VERSION"
