#!/bin/bash
# Builds dist/StreamSetu.app (universal when the toolchain supports it) and an ad-hoc signed copy.
# Usage: Scripts/build-release.sh [version] [build-number]
#   SIGN_IDENTITY="Developer ID Application: …"  -> use Scripts/sign-app.sh afterwards for distribution
#   REDDY_BUNDLE_MPV=1                           -> also embed libmpv (see Scripts/bundle-libmpv.sh)
#   REDDY_ARCH=arm64 | x86_64 | universal       -> one architecture on its own (about half the build time; Apple silicon: arm64, Intel: x86_64). Default: universal.
#                                                  A single-architecture build also leaves a copy named dist/StreamSetu-<arch>.app next to dist/StreamSetu.app.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 ../legal/sync-legal.py --check
VERSION="${1:-1.0.0}"
BUILD="${2:-$(date +%Y%m%d%H%M)}"
DIST=dist
rm -rf "$DIST" && mkdir -p "$DIST"

# The optional built-in keys (TMDB token, fanart.tv key, TheTVDB key: from $STREAMSETU_* or the private keys folder), each scrambled into a gitignored Swift file; with none, the build has no built-in key.
python3 ../Scripts/gen-builtin-key.py tmdb Sources/REDDY/Generated/GeneratedTMDB.swift
python3 ../Scripts/gen-builtin-key.py fanart Sources/REDDY/Generated/GeneratedFanart.swift
python3 ../Scripts/gen-builtin-key.py tvdb Sources/REDDY/Generated/GeneratedTVDB.swift
python3 ../Scripts/gen-builtin-key.py lastfm Sources/REDDY/Generated/GeneratedLastFM.swift
python3 ../Scripts/gen-builtin-key.py lastfmsecret Sources/REDDY/Generated/GeneratedLastFMSecret.swift
python3 ../Scripts/gen-builtin-key.py acoustid Sources/REDDY/Generated/GeneratedAcoustID.swift
python3 ../Scripts/gen-builtin-key.py setlistfm Sources/REDDY/Generated/GeneratedSetlistFM.swift
echo "▸ Compiling (release)…"
ARCH_CHOICE="${REDDY_ARCH:-universal}"
if [ "$ARCH_CHOICE" = "arm64" ] || [ "$ARCH_CHOICE" = "x86_64" ]; then
  swift build -c release --arch "$ARCH_CHOICE"
  BIN="$(swift build -c release --arch "$ARCH_CHOICE" --show-bin-path)/REDDY"; echo "  $ARCH_CHOICE-only binary"
  ARCHS=" $(lipo -archs "$BIN" 2>/dev/null) "; [[ "$ARCHS" == *" $ARCH_CHOICE "* && "$ARCHS" != *" $([ "$ARCH_CHOICE" = arm64 ] && echo x86_64 || echo arm64) "* ]] || { echo "✘ $BIN is not a $ARCH_CHOICE-only binary:$ARCHS"; exit 1; }
elif swift build -c release --arch arm64 --arch x86_64 >/dev/null 2>&1; then
  # Where SwiftPM puts a multi-arch build depends on its version (.build/apple/... before Swift 6.4, .build/out/... from it), so it is asked.
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/REDDY"; echo "  universal binary via SwiftPM multi-arch build"
  ARCHS=" $(lipo -archs "$BIN" 2>/dev/null) "; [[ "$ARCHS" == *" arm64 "* && "$ARCHS" == *" x86_64 "* ]] || { echo "✘ $BIN is not a universal (arm64 + x86_64) binary:$ARCHS"; exit 1; }
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
# The offline alias index (read by name only; see tools/aliases/README.md). A build without it simply has no alias tier.
[ -f ../artwork/aliases/aliases.tsv.gz ] && cp ../artwork/aliases/aliases.tsv.gz "$APP/Contents/Resources/aliases.tsv.gz"
# The transparent TV symbol shown on the welcome screen (BrandSymbol in the code).
cp Resources/Branding/BrandSymbol.png "$APP/Contents/Resources/BrandSymbol.png"
cp Resources/Branding/TMDBLogo.png "$APP/Contents/Resources/TMDBLogo.png"
# The services' own icons for the Services list, decoded once at launch (ServiceIconStore).
mkdir -p "$APP/Contents/Resources/ServiceIcons" && cp Resources/ServiceIcons/*.png "$APP/Contents/Resources/ServiceIcons/"
# The YouTube ad-skipping rules (data only; checked name by name when loaded).
cp Resources/youtube-ads.json "$APP/Contents/Resources/youtube-ads.json"
# fpcalc (opt-in: Scripts/fetch-fpcalc.sh fetches it). With it, recognising songs by sound needs nothing installed; without it the app looks for the person's own.
if [ -x Resources/Helpers/fpcalc ]; then
  cp Resources/Helpers/fpcalc "$APP/Contents/MacOS/fpcalc"
  cp Resources/Notices/Chromaprint-NOTICE.txt "$APP/Contents/Resources/Chromaprint-NOTICE.txt"
  [ -f Resources/Helpers/fpcalc-LICENSE.txt ] && cp Resources/Helpers/fpcalc-LICENSE.txt "$APP/Contents/Resources/Chromaprint-LICENSE.txt"
  echo "  included fpcalc"
fi
# The karaoke model (opt-in: Scripts/fetch-karaoke-model.sh builds it). A build without it has karaoke "Not set up"; with it, karaoke works with no download.
if [ -d Resources/Models/SpleeterVocals2.mlmodelc ]; then
  mkdir -p "$APP/Contents/Resources/Models" && cp -R Resources/Models/SpleeterVocals2.mlmodelc "$APP/Contents/Resources/Models/"
  cp Resources/Notices/Spleeter-NOTICE.txt "$APP/Contents/Resources/Models/SpleeterVocals2-NOTICE.txt"
  echo "  included the karaoke model ($(du -sh Resources/Models/SpleeterVocals2.mlmodelc | cut -f1))"
fi
# The layers of the opening's television (TuneIn-<layer>.png), from the shared motion assets at the root of the repository.
for LAYER in ../motion/assets/tune-in/*.png; do cp "$LAYER" "$APP/Contents/Resources/TuneIn-$(basename "$LAYER")"; done
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
if [ "$ARCH_CHOICE" = "arm64" ] || [ "$ARCH_CHOICE" = "x86_64" ]; then
  rm -rf "$DIST/StreamSetu-$ARCH_CHOICE.app" && cp -R "$APP" "$DIST/StreamSetu-$ARCH_CHOICE.app"
  echo "✔ $DIST/StreamSetu-$ARCH_CHOICE.app  ($ARCH_CHOICE only)"
fi
