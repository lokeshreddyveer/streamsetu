#!/bin/bash
# Adds a release to the update feed (appcast.xml at the root of the StreamSetu repo) so installed copies of the Mac app offer it: one item for the Apple silicon DMG and one for the Intel DMG.
# Both are signed with the update key kept in this Mac's Keychain (account "streamsetu"; made by Sparkle's generate_keys).
# <build> is the Intel build; the Apple silicon app is <build>+1 (macos/Scripts/release-signed.sh).
#
#   RELEASE_TAG=<tag of the release that holds the DMGs> Scripts/update-appcast.sh <version> <build> [notes]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"          # where this script and appcast_add.py live, before the directory changes
cd "$HERE/.."
VERSION="${1:?usage: update-appcast.sh <version> <build> [notes]}"; BUILD="${2:?usage: update-appcast.sh <version> <build> [notes]}"; NOTES="${3:-StreamSetu $VERSION}"
REPO="${RELEASES_REPO:-lokeshreddyveer/streamsetu}"
for f in "dist/StreamSetu-$VERSION-AppleSilicon.dmg" "dist/StreamSetu-$VERSION-Intel.dmg"; do [ -f "$f" ] || { echo "✘ $f not found"; exit 1; }; done
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
gh repo clone "$REPO" "$WORK/repo" -- --depth 1 --filter=blob:none >/dev/null 2>&1
ADDED=0
for ENTRY in "arm64:-AppleSilicon:$((BUILD + 1))" "x86_64:-Intel:$BUILD"; do
  ARCH="${ENTRY%%:*}"; REST="${ENTRY#*:}"; SUFFIX="${REST%%:*}"; FBUILD="${REST#*:}"
  DMG="dist/StreamSetu-$VERSION$SUFFIX.dmg"
  SIGN="$(.build/artifacts/sparkle/Sparkle/bin/sign_update --account streamsetu "$DMG")"     # sparkle:edSignature="…" length="…"
  URL="https://github.com/$REPO/releases/download/${RELEASE_TAG:-mac-v$VERSION}/StreamSetu-$VERSION$SUFFIX.dmg"
  RESULT="$(python3 "$HERE/appcast_add.py" "$WORK/repo/appcast.xml" "$VERSION" "$FBUILD" "$URL" "$SIGN" "$NOTES" "$ARCH")"
  [ "$RESULT" = "added" ] && ADDED=1
done
[ "$ADDED" = 1 ] || { echo "✔ the update feed already offers $VERSION; nothing to add"; exit 0; }
cd "$WORK/repo" && git add appcast.xml && git commit -qm "Update feed for StreamSetu $VERSION" && git push -q origin HEAD
echo "✔ update feed now offers $VERSION (Apple silicon and Intel)"
