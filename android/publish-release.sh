#!/bin/bash
# Builds, tests and signs the Android and Fire TV APK, then publishes it as the "android-v<version>" release of the one StreamSetu repo.
#
#   ./publish-release.sh <version> <version code> <notes file>      e.g.  ./publish-release.sh 0.8.0 80 notes.md
#
# Needs android/keystore.properties (the release key). Both downloads hold the same build; they are listed separately so each device has its own file.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:?usage: publish-release.sh <version> <version code> <notes file>}"; CODE="${2:?version code}"; NOTES="${3:?notes file}"
[ -f keystore.properties ] || { echo "✘ no keystore.properties: refusing to publish a debug-signed APK"; exit 1; }
export JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@17} ANDROID_HOME=${ANDROID_HOME:-$HOME/Library/Android/sdk}
./release.sh "$VERSION" "$CODE"
OUT="dist/$VERSION"; mkdir -p "$OUT"
cp app/build/outputs/apk/release/app-release.apk "$OUT/StreamSetu-FireTV-$VERSION.apk"
cp app/build/outputs/apk/release/app-release.apk "$OUT/StreamSetu-Android-$VERSION.apk"
( cd "$OUT" && shasum -a 256 StreamSetu-FireTV-$VERSION.apk StreamSetu-Android-$VERSION.apk > SHA256SUMS-$VERSION.txt )
SUM="$(cut -d' ' -f1 "$OUT/SHA256SUMS-$VERSION.txt" | head -1)"
BODY="$(mktemp)"; trap 'rm -f "$BODY"' EXIT
sed "s/__SHA256__/$SUM/g; s/__VERSION__/$VERSION/g" "$NOTES" > "$BODY"
gh release create "android-v$VERSION" "$OUT"/StreamSetu-*.apk "$OUT/SHA256SUMS-$VERSION.txt" --title "StreamSetu for Android and Fire TV $VERSION" --notes-file "$BODY" --latest=false
echo "✔ published: https://github.com/lokeshreddyveer/streamsetu/releases/tag/android-v$VERSION"
