#!/bin/bash
# Builds, signs with your Developer ID, notarizes with Apple and staples: the DMGs that open with no Gatekeeper warning.
# A release has three Mac downloads: StreamSetu-<v>.dmg (universal, also what the in-app updater offers), StreamSetu-<v>-AppleSilicon.dmg (arm64 only) and StreamSetu-<v>-Intel.dmg (x86_64 only).
# RELEASE_FLAVOURS (default "arm64 x86_64 universal") picks which are built; the universal one goes last so dist/StreamSetu.app is left universal.
#
#   Scripts/release-signed.sh <version> <build>        e.g.  Scripts/release-signed.sh 2.2.0 220
#
# One-time setup (in a terminal, because it asks for the app-specific password):
#   1. Xcode > Settings > Accounts > your team > Manage Certificates > + > Developer ID Application
#   2. appleid.apple.com > Sign-In and Security > App-Specific Passwords > create one named "StreamSetu notary"
#   3. xcrun notarytool store-credentials StreamSetu-NOTARY --apple-id <your Apple ID email> --team-id X4MH29QNRS
# Environment: SIGN_IDENTITY (default: the first "Developer ID Application" certificate found), NOTARY_PROFILE (default StreamSetu-NOTARY).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: release-signed.sh <version> <build>}"; BUILD="${2:?usage: release-signed.sh <version> <build>}"
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

# Dependency gate: a release stops if a dependency has a reported vulnerability, could not be checked, or a bundled library is unidentified or unreviewed. There is no environment switch around it:
# the only override is a signed, expiring entry in Scripts/risk-acceptances.json (docs/RELEASE-SECURITY.md). The report and the SBOM are kept with the release.
mkdir -p dist/security
python3 ../Scripts/audit-dependencies.py --strict --scope mac --report "dist/security/dependencies-$VERSION-$BUILD.json" --sbom "dist/security/sbom-$VERSION-$BUILD.cdx.json" \
  || { echo "✘ dependency check did not come back clean (see above)."; exit 1; }
# Each build starts from an empty dist/, so the finished disk images and the dependency report wait in a staging folder and are put back at the end.
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
mv dist/security "$STAGE/security"
for FLAVOUR in ${RELEASE_FLAVOURS:-arm64 x86_64 universal}; do
  case "$FLAVOUR" in
    universal) SUFFIX="" ;; arm64) SUFFIX="-AppleSilicon" ;; x86_64) SUFFIX="-Intel" ;;
    *) echo "✘ unknown flavour '$FLAVOUR' (arm64, x86_64 or universal)"; exit 1 ;;
  esac
  echo "▸ ===== $FLAVOUR build ====="
  REDDY_ARCH="$FLAVOUR" REDDY_BUNDLE_MPV=1 Scripts/build-release.sh "$VERSION" "$BUILD"
  Scripts/sign-app.sh dist/StreamSetu.app

  echo "▸ Notarizing the $FLAVOUR app…"
  ZIP="$(mktemp -d)/StreamSetu.zip"
  ditto -c -k --keepParent dist/StreamSetu.app "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple dist/StreamSetu.app

  echo "▸ Disk image ($FLAVOUR)…"
  DMG_SUFFIX="$SUFFIX" Scripts/create-dmg.sh                       # signs the DMG too, because SIGN_IDENTITY is set
  Scripts/notarize-dmg.sh "dist/StreamSetu-$VERSION$SUFFIX.dmg"
  Scripts/verify-release.sh
  spctl --assess --type open --context context:primary-signature -v "dist/StreamSetu-$VERSION$SUFFIX.dmg" 2>&1 | tail -1
  mv "dist/StreamSetu-$VERSION$SUFFIX.dmg" "$STAGE/"
done
mkdir -p dist && mv "$STAGE"/StreamSetu-*.dmg dist/ && mv "$STAGE/security" dist/security
git -C .. rev-parse HEAD > "dist/StreamSetu-$VERSION.commit"          # the commit these DMGs were built from; the release checks that it is the one being released
for f in dist/StreamSetu-$VERSION*.dmg; do echo "✔ $f is signed, notarized and stapled"; done
