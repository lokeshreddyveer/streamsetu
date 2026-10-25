#!/bin/bash
# Builds and signs the app and the DMG, then SENDS the DMG to Apple for notarization without waiting for the answer.
# Apple checks everything inside the DMG, so one submission covers the app too. Finish later with Scripts/finish-release.sh <version>.
#
#   Scripts/release-dmg.sh <version> <build>           e.g.  Scripts/release-dmg.sh 2.2.2 222
#
# One-time setup (in a terminal, because it asks for the app-specific password):
#   1. Xcode > Settings > Accounts > your team > Manage Certificates > + > Developer ID Application
#   2. appleid.apple.com > Sign-In and Security > App-Specific Passwords > create one named "StreamSetu notary"
#   3. xcrun notarytool store-credentials StreamSetu-NOTARY --apple-id <your Apple ID email> --team-id X4MH29QNRS
# Environment: SIGN_IDENTITY (default: the first "Developer ID Application" certificate found), NOTARY_PROFILE (default StreamSetu-NOTARY).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: release-dmg.sh <version> <build>}"; BUILD="${2:?usage: release-dmg.sh <version> <build>}"
export NOTARY_PROFILE="${NOTARY_PROFILE:-StreamSetu-NOTARY}"
# Signed by the certificate's hash, not its name: if the same certificate was created twice, the name is ambiguous.
export SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk '{print $2}')}"
# With an iCloud provisioning profile, sign with the very certificate the profile names (when there are duplicates).
PROFILE="Configuration/StreamSetu.provisionprofile"
if [ -f "$PROFILE" ] && [ -z "${SIGN_IDENTITY_FIXED:-}" ]; then
  FROM_PROFILE=$(security cms -D -i "$PROFILE" 2>/dev/null | python3 -c '
import sys, plistlib, hashlib
p = plistlib.loads(sys.stdin.buffer.read())
print(" ".join(hashlib.sha1(c).hexdigest().upper() for c in p.get("DeveloperCertificates", [])))' 2>/dev/null || true)
  for h in $FROM_PROFILE; do
    if security find-identity -v -p codesigning | grep -q "$h"; then SIGN_IDENTITY="$h"; break; fi
  done
fi
[ -n "$SIGN_IDENTITY" ] || { echo "✘ no 'Developer ID Application' certificate found. Create one in Xcode (see the top of this script)."; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || { echo "✘ notary profile '$NOTARY_PROFILE' not set up. Run step 3 at the top of this script."; exit 1; }
echo "▸ Signing as: $(security find-identity -v -p codesigning | grep "${SIGN_IDENTITY}" | head -1 | sed 's/.*"\(.*\)"/\1/') [${SIGN_IDENTITY}]"

# Known-vulnerability check: a release stops if a dependency has a reported vulnerability or could not be checked. After reading the report, ALLOW_DEPENDENCY_ISSUES=1 goes ahead anyway.
DEP_REPORT="$(mktemp)"; DEP_RC=0
python3 ../Scripts/audit-dependencies.py --strict > "$DEP_REPORT" 2>&1 || DEP_RC=$?
grep -v "^  - " "$DEP_REPORT" || true
if [ "$DEP_RC" -ne 0 ] && [ "${ALLOW_DEPENDENCY_ISSUES:-}" != "1" ]; then echo "✘ dependency check did not come back clean (exit $DEP_RC). Read the report above; ALLOW_DEPENDENCY_ISSUES=1 releases anyway."; exit 1; fi
REDDY_BUNDLE_MPV=1 Scripts/build-release.sh "$VERSION" "$BUILD"
Scripts/sign-app.sh dist/StreamSetu.app

echo "▸ Disk image…"
Scripts/create-dmg.sh                       # signs the DMG too, because SIGN_IDENTITY is set
DMG="dist/StreamSetu-$VERSION.dmg"
echo "▸ Sending the disk image to Apple (not waiting for the answer)…"
OUT="$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" 2>&1)"; echo "$OUT"
ID="$(echo "$OUT" | awk '/^ *id:/ {print $2; exit}')"
[ -n "$ID" ] || { echo "✘ could not read the submission id"; exit 1; }
echo "$ID" > "dist/notarization-$VERSION.id"
echo "✔ $DMG is built and signed. Submission $ID is with Apple."
echo "  When Apple has accepted it, run: Scripts/finish-release.sh $VERSION"
