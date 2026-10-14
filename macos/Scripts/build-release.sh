#!/bin/bash
# Builds dist/StreamSetu.app (universal when the toolchain supports it) and an ad-hoc signed copy.
# Usage: Scripts/build-release.sh [version] [build-number]
#   SIGN_IDENTITY="Developer ID Application: …"  -> use Scripts/sign-app.sh afterwards for distribution
#   REDDY_BUNDLE_MPV=1                           -> also embed libmpv (see Scripts/bundle-libmpv.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
python3 ../legal/sync-legal.py --check
VERSION="${1:-1.0.0}"
BUILD="${2:-$(date +%Y%m%d%H%M)}"
DIST=dist
rm -rf "$DIST" && mkdir -p "$DIST"

echo "▸ Compiling (release)…"
if swift build -c release --arch arm64 --arch x86_64 >/dev/null 2>&1; then
  BIN=".build/apple/Products/Release/REDDY"; echo "  universal binary via SwiftPM multi-arch build"
else
  # Command Line Tools only: build each architecture on its own and join them with lipo.
  swift build -c release --triple arm64-apple-macosx14.0 --scratch-path .build-arm64
  swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build-x86
  BIN="$DIST/StreamSetu-universal"
  lipo -create -output "$BIN" .build-arm64/arm64-apple-macosx/release/REDDY .build-x86/x86_64-apple-macosx/release/REDDY
  echo "  universal binary via lipo (arm64 + x86_64)"
fi

APP="$DIST/StreamSetu.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/StreamSetu"; rm -f "$DIST/StreamSetu-universal"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Configuration/Info.plist > "$APP/Contents/Info.plist"
cp Configuration/PrivacyInfo.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
# The app's wording in Hindi and Telugu (and the English marker): one folder per language, each with its Localizable.strings.
for LANG in en hi te; do cp -R "Resources/Localization/$LANG.lproj" "$APP/Contents/Resources/$LANG.lproj"; done
echo "APPL????" > "$APP/Contents/PkgInfo"

echo "▸ Icon…"
# The icon is Resources/Branding/StreamSetu.icns, supplied by the project owner. It is the one icon for the app, the disk image and
# everything else that needs one; to change the icon, replace that file. The generated placeholder is only a fallback if it is gone.
if [ -f Resources/Branding/StreamSetu.icns ]; then
  cp Resources/Branding/StreamSetu.icns "$APP/Contents/Resources/AppIcon.icns"
else
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  swiftc -O -o "$(dirname "$ICONSET")/make-icon" Scripts/make-icon.swift 2>/dev/null
  "$(dirname "$ICONSET")/make-icon" "$ICONSET"
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

# Sparkle (automatic updates): the framework ships inside the app and the program looks for it there.
SPARKLE="$(ls -d .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-*/Sparkle.framework | head -1)"
[ -d "$SPARKLE" ] || { echo "✘ Sparkle.framework not found. Run: swift package resolve"; exit 1; }
cp -R "$SPARKLE" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/StreamSetu" 2>/dev/null || true

if [ "${REDDY_BUNDLE_MPV:-0}" = "1" ]; then Scripts/bundle-libmpv.sh "$APP"; fi
rmdir "$APP/Contents/Frameworks" 2>/dev/null || true

# A stable signing identity keeps the Keychain from asking for permission again after every rebuild.
# Order: SIGN_IDENTITY (e.g. a Developer ID) > the local identity from Scripts/setup-local-signing.sh > ad-hoc.
LOCAL_KC="$HOME/Library/Keychains/reddy-signing.keychain-db"
if [ -z "${SIGN_IDENTITY:-}" ] && [ -f "$LOCAL_KC" ] && security find-identity -p codesigning "$LOCAL_KC" 2>/dev/null | grep -q "REDDY Local Signing"; then
  security unlock-keychain -p "reddy-local-signing" "$LOCAL_KC" 2>/dev/null || true
  echo "▸ Signing with the local identity…"
  codesign --force --deep --sign "REDDY Local Signing" --keychain "$LOCAL_KC" --options runtime --entitlements Configuration/REDDY.entitlements "$APP"
elif [ -n "${SIGN_IDENTITY:-}" ]; then
  echo "▸ Signing with ${SIGN_IDENTITY}…"
  codesign --force --deep --sign "$SIGN_IDENTITY" --options runtime --timestamp --entitlements Configuration/REDDY.entitlements "$APP"
else
  echo "▸ Ad-hoc signing…"
  codesign --force --deep --sign - --options runtime --entitlements Configuration/REDDY.entitlements "$APP"
fi
echo "✔ $APP  (version $VERSION, build $BUILD)"
