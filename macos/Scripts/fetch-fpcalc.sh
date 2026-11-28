#!/bin/bash
# Fetches Chromaprint's own `fpcalc` (universal macOS build) so recognising songs by sound works with nothing installed. Opt-in: run once, then
# Scripts/build-release.sh copies Resources/Helpers/fpcalc into the app next to its executable, and Scripts/sign-app.sh signs it.
# The download is pinned to the size and SHA-256 that the official release page publishes (Chromaprint v1.6.2). fpcalc is only downloaded and
# checked here; it is never run by this script.
#
#   Scripts/fetch-fpcalc.sh            fetch it if it is not there yet
#   Scripts/fetch-fpcalc.sh --force    fetch it again
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=Resources/Helpers/fpcalc
if [ -x "$OUT" ] && [ "${1:-}" != "--force" ]; then echo "✔ $OUT already present"; exit 0; fi
URL="https://github.com/acoustid/chromaprint/releases/download/v1.6.2/chromaprint-fpcalc-1.6.2-macos-universal.tar.gz"
SIZE=2698274
SHA256="53d9368f96017fb288d74f6ed4d928f7bbbfb2ff81e69b4ef67b6ceeb217d9b2"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
echo "▸ Downloading $URL"
curl -L --fail -o "$WORK/fpcalc.tar.gz" "$URL"
[ "$(stat -f %z "$WORK/fpcalc.tar.gz")" = "$SIZE" ] || { echo "✘ the download is not the expected size"; exit 1; }
[ "$(shasum -a 256 "$WORK/fpcalc.tar.gz" | cut -d' ' -f1)" = "$SHA256" ] || { echo "✘ the download does not match its pinned SHA-256"; exit 1; }
tar -xzf "$WORK/fpcalc.tar.gz" -C "$WORK"
BIN="$(find "$WORK" -type f -name fpcalc | head -1)"
[ -n "$BIN" ] || { echo "✘ fpcalc is not in the archive"; exit 1; }
mkdir -p Resources/Helpers
cp "$BIN" "$OUT"; chmod 755 "$OUT"
LIC="$(find "$WORK" -type f \( -iname 'LICENSE*' -o -iname 'COPYING*' \) | head -1)"
[ -n "$LIC" ] && cp "$LIC" Resources/Helpers/fpcalc-LICENSE.txt || true
echo "✔ $OUT"
