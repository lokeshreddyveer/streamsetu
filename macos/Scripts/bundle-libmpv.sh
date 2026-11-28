#!/bin/bash
# Embeds the libmpv stack into StreamSetu.app so MKV/AVI/RTSP/DASH work without installing anything.
# Source: third_party/libmpv (Scripts/fetch-libmpv.sh) — or pass another folder of dylibs as the 2nd argument.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:?usage: bundle-libmpv.sh <StreamSetu.app> [dylib-folder]}"
SRC="${2:-third_party/libmpv}"
[ -f "$SRC/libmpv.2.dylib" ] || { echo "No libmpv in $SRC. Run Scripts/fetch-libmpv.sh first."; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
cp "$SRC"/*.dylib "$APP/Contents/Frameworks/"
# A single-architecture app (REDDY_ARCH=arm64 or x86_64, the Apple silicon and Intel downloads) carries only that half of each library, which about halves the bundle.
case "${REDDY_ARCH:-universal}" in
  arm64|x86_64)
    for f in "$APP"/Contents/Frameworks/*.dylib; do
      if [ "$(lipo -archs "$f" | wc -w | tr -d ' ')" -gt 1 ]; then lipo "$f" -thin "$REDDY_ARCH" -output "$f.thin" && mv "$f.thin" "$f"; fi
    done ;;
esac
# The libraries refer to each other through @rpath; let each one find its neighbours.
for f in "$APP"/Contents/Frameworks/*.dylib; do install_name_tool -add_rpath @loader_path "$f" 2>/dev/null || true; done
[ -f "$SRC/NOTICE.txt" ] && cp "$SRC/NOTICE.txt" "$APP/Contents/Resources/ThirdPartyNotices-libmpv.txt"
echo "✔ embedded $(ls "$APP/Contents/Frameworks"/*.dylib | wc -l | tr -d ' ') libraries in $APP/Contents/Frameworks"
