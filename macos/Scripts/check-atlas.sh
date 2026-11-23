#!/bin/bash
# Gate (a): every interactive control carries .atlas("id") or is exempt (Tools/AtlasScan/exemptions.json).
# Usage: Scripts/check-atlas.sh [--strict] [--only PATH_PREFIX] [--list] [--accept-exemptions] [FILE.swift ...]
# Default is warn-only (counts per folder, exit 0). The package builds on its own (swift-syntax), so the app build never pays for it.
# ATLAS_SCAN_BUILD overrides the build folder.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$HERE/Tools/AtlasScan"
BUILD="${ATLAS_SCAN_BUILD:-$TOOL/.build}"
swift build -c release --package-path "$TOOL" --scratch-path "$BUILD" 2>&1 | grep -E "error|Compiling|Build complete" | grep -v "^Compiling" || true
exec "$BUILD/release/atlas-scan" --repo "$(cd "$HERE/.." && pwd)" "$@"
