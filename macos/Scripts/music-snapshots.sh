#!/bin/bash
# Music responsive snapshots: draws the Music screens offscreen at seven window sizes (640x720 up to 2000x1200) plus a stress set at 1100x760,
# checks them (overflow, layout class, hit targets, player bar overlap, blank pictures) and writes PNGs, one contact sheet per scenario and report.txt.
#
# How to run (from anywhere):
#   Scripts/music-snapshots.sh                      # PNGs go to a new folder under the system temp directory
#   MUSIC_SNAPSHOT_DIR=/some/folder Scripts/music-snapshots.sh
#   Scripts/music-snapshots.sh --build              # build the tests first (the default reuses the last build: run `swift build --build-tests` once)
#
# The suite is skipped unless MUSIC_SNAPSHOTS=1, which this script sets. It needs a built test bundle (swift test --skip-build).
# Nothing here touches the running app: the windows are offscreen in the test process, the library is a throwaway folder and the catalogue is fixture data.
set -euo pipefail
cd "$(dirname "$0")/.."
export STREAMSETU_TESTING=1
export MUSIC_SNAPSHOTS=1
export MUSIC_SNAPSHOT_DIR="${MUSIC_SNAPSHOT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/music-snapshots.XXXXXX")}"
mkdir -p "$MUSIC_SNAPSHOT_DIR"
SKIP="--skip-build"
if [ "${1:-}" = "--build" ]; then SKIP=""; fi
status=0
swift test $SKIP --filter MusicSnapshot || status=$?
echo
echo "Music snapshots written to: $MUSIC_SNAPSHOT_DIR"
echo "  contact sheets: $MUSIC_SNAPSHOT_DIR/contact_*.png   single renders: <scenario>_<WxH>.png   timings and warnings: report.txt"
exit $status
