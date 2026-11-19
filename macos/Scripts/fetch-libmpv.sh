#!/bin/bash
# Downloads a prebuilt libmpv + FFmpeg + libplacebo + libass stack (from the official IINA release) into third_party/libmpv.
# This is what makes MKV, AVI, RTSP and DASH playable. Run once, then: REDDY_BUNDLE_MPV=1 Scripts/build-release.sh
#
# LICENSING: these builds include GPL-licensed components. Distributing StreamSetu with them means complying with the GPL
# for the combined work. Review before publishing; for private use there is nothing further to do.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=third_party/libmpv
[ -f "$OUT/libmpv.2.dylib" ] && { echo "✔ $OUT already present"; exit 0; }
WORK="$(mktemp -d)"
# Pinned: the files must be the ones recorded in release/libmpv-components.json, which the release check compares by SHA-256.
# To refresh, change both lines below, run this script on an empty third_party/libmpv, and update that file after review.
IINA_TAG="v1.5.1"; IINA_DMG_SHA256="f414507ec60bcfeda3a9f539f74470253e31b619d031e7a9e9a71519da1598cd"
URL="https://github.com/iina/iina/releases/download/$IINA_TAG/IINA.$IINA_TAG.dmg"
echo "▸ Downloading $URL"
curl -L --fail -o "$WORK/iina.dmg" "$URL"
[ "$(shasum -a 256 "$WORK/iina.dmg" | cut -d' ' -f1)" = "$IINA_DMG_SHA256" ] || { echo "✘ the IINA $IINA_TAG download does not match its pinned checksum"; exit 1; }
hdiutil attach -nobrowse -readonly -mountpoint "$WORK/vol" "$WORK/iina.dmg" >/dev/null
mkdir -p "$OUT"
cp "$WORK/vol/IINA.app/Contents/Frameworks/"*.dylib "$OUT/"
hdiutil detach "$WORK/vol" -quiet
cat > "$OUT/NOTICE.txt" <<'TXT'
These libraries (mpv, FFmpeg, libplacebo, libass, dav1d and their dependencies) are third-party software distributed
under their own licenses, including the GPL. Source: https://github.com/iina/iina (release dylibs).
TXT
for f in "$OUT"/*.dylib; do install_name_tool -add_rpath @loader_path "$f" 2>/dev/null || true; done
echo "✔ libmpv stack in $OUT ($(du -sh "$OUT" | cut -f1))"
