#!/bin/bash
# Per-release run of Setu's question bank. Regenerates the what's-new entries, replays the bank against the real entries, and writes the report.
# Usage: Scripts/atlas-bank-run.sh [report-dir]   (default: a folder under the temp directory; never inside the repository)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-${TMPDIR:-/tmp}/atlas-bank-$(date +%Y%m%d-%H%M)}"
mkdir -p "$OUT"
python3 Scripts/gen-atlas-whatsnew.py
cd macos
ATLAS_REPORT_DIR="$OUT" swift test --filter 'AtlasBankTests|AtlasModelTests|AtlasSubtitleRegressionTests' 2>&1 | tail -n 25
echo "--- report: $OUT/atlas-bank-report.txt"
grep -E "^  (tableAndTitles|table \+ same titles|same titles only|expected ids only)|^  tag:|^Decisions|^  all |HELD-OUT|held-out" "$OUT/atlas-bank-report.txt" || true
