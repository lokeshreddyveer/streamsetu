#!/bin/bash
# Builds, tests and signs the Android and Fire TV APK into dist/<version>/. Publishing is done for every app at once by Scripts/release.sh.
#
#   ./build-release.sh <version> <version code>      e.g.  ./build-release.sh 0.9.1 91
#
# Needs android/keystore.properties (the release key). Both downloads hold the same build; they are listed separately so each device has its own file.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:?usage: build-release.sh <version> <version code>}"; CODE="${2:?version code}"
[ -f keystore.properties ] || { echo "✘ no keystore.properties: refusing to publish a debug-signed APK"; exit 1; }
export JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@17} ANDROID_HOME=${ANDROID_HOME:-$HOME/Library/Android/sdk}
./release.sh "$VERSION" "$CODE"
OUT="dist/$VERSION"; mkdir -p "$OUT"
cp app/build/outputs/apk/release/app-release.apk "$OUT/StreamSetu-FireTV-$VERSION.apk"
cp app/build/outputs/apk/release/app-release.apk "$OUT/StreamSetu-Android-$VERSION.apk"
( cd "$OUT" && shasum -a 256 StreamSetu-FireTV-$VERSION.apk StreamSetu-Android-$VERSION.apk > SHA256SUMS-$VERSION.txt )
echo "✔ built: $OUT (publish with Scripts/release.sh from the top of the repository)"
