#!/bin/bash
# Builds the release APK. Usage: ./release.sh 1.0.0 12     (version name, version code)
# Needs android/keystore.properties for a distributable build; without it the APK is debug-signed and for testing only.
set -e
cd "$(dirname "$0")"
export JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@17} ANDROID_HOME=${ANDROID_HOME:-$HOME/Library/Android/sdk}
# Everything that can be checked without a device: every module's unit tests (navigation, network security, data, playback), Android lint, and the dependency report, which stops the build
# when a library has a reported vulnerability or could not be checked. There is no switch around it; the only override is a signed, expiring entry in Scripts/risk-acceptances.json.
./gradlew testDebugUnitTest lintRelease
python3 ../scripts/audit-dependencies.py --strict --scope android || { echo "✘ dependency check did not come back clean (see above)."; exit 1; }
# With a Fire TV or phone connected and CONNECTED=1, the tests that need a device run too.
[ "${CONNECTED:-}" = "1" ] && ./gradlew connectedDebugAndroidTest
./gradlew :app:assembleRelease -PappVersionName="${1:-0.2.0}" -PappVersionCode="${2:-1}"
APK=app/build/outputs/apk/release/app-release.apk
[ -f keystore.properties ] || echo "WARNING: no keystore.properties; this APK is signed with the debug key. Test only."
ls -l "$APK"
