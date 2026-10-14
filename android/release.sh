#!/bin/bash
# Builds the release APK. Usage: ./release.sh 1.0.0 12     (version name, version code)
# Needs android/keystore.properties for a distributable build; without it the APK is debug-signed and for testing only.
set -e
cd "$(dirname "$0")"
export JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@17} ANDROID_HOME=${ANDROID_HOME:-$HOME/Library/Android/sdk}
./gradlew :data:testDebugUnitTest :core-media:testDebugUnitTest
./gradlew :app:assembleRelease -PappVersionName="${1:-0.2.0}" -PappVersionCode="${2:-1}"
APK=app/build/outputs/apk/release/app-release.apk
[ -f keystore.properties ] || echo "WARNING: no keystore.properties; this APK is signed with the debug key. Test only."
ls -l "$APK"
