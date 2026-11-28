#!/bin/zsh
# Live soak of the playback failure and retry machinery (no audio is played).
#
# What it does: collects N tracks (default 200) from chart-style searches in Telugu, Hindi, Tamil and English on YouTube Music, from JioSaavn and
# Audius searches, and from Apple/iTunes metadata that has to be matched to audio. For each track it resolves a stream with the app's own
# MusicStreamResolver, proves the address with the app's own stream check, then fails that address ONCE on purpose (the call the player makes when a
# stream stops working) and resolves again. The retry must give a working address: a different one ("fresh"), or the same one proven again when the
# source has nothing else ("same-working"). Anything else is a failed retry and is listed with its reason. It writes a Markdown report.
#
# LIVE NETWORK, SILENT: real public services, about three requests per track plus the searches, spaced out (SOAK_SPACING, default 1 s). One
# visitor identity is reused for the whole run. If two bot checks or rate limits follow each other it pauses SOAK_BOT_PAUSE seconds (default 30)
# and continues with a fresh identity. No AVPlayer or audio engine exists in this program; nothing is sent to the app.
#
# How it builds: it links the real source files listed in MusicPlaybackMatrix/sources.txt into a small throw-away Swift package (the full app is
# not built), with the keychain and storage stubbed by MusicPlaybackMatrix/Stubs.swift so nothing touches the person's data.
#
# Run:    Scripts/music-playback-soak.sh [report.md]
# Knobs:  SOAK_N=200  SOAK_SPACING=1  SOAK_BOT_PAUSE=30  SOAK_LANES=ytm-telugu,jiosaavn,...  SOAK_WORK=<build dir>
#   lanes: ytm-telugu ytm-hindi ytm-tamil ytm-english jiosaavn audius itunes-matched
set -e
ROOT=${0:A:h:h}
SRC=$ROOT/Sources/REDDY
H=$ROOT/Scripts/MusicPlaybackMatrix
S=$ROOT/Scripts/MusicPlaybackSoak
WORK=${SOAK_WORK:-${TMPDIR:-/tmp}/music-playback-soak-build}
mkdir -p $WORK; rm -rf $WORK/Sources $WORK/Package.swift
mkdir -p $WORK/Sources/Soak/real
cat > $WORK/Package.swift <<P
// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "MusicPlaybackSoak", platforms: [.macOS(.v14)],
  targets: [.executableTarget(name: "Soak", path: "Sources/Soak", swiftSettings: [.swiftLanguageMode(.v6)])])
P
setopt null_glob
grep -v '^#' $H/sources.txt | while read pat; do
  [ -z "$pat" ] && continue
  for f in $SRC/${~pat}; do
    rel=${f#$SRC/}
    grep -qxF "$rel" $H/exclude.txt && continue
    mkdir -p $WORK/Sources/Soak/real/${rel:h}
    cp -f $f $WORK/Sources/Soak/real/$rel
  done
done
cp $H/Stubs.swift $WORK/Sources/Soak/Stubs.swift
cp $S/Soak.swift $WORK/Sources/Soak/Soak.swift
cd $WORK
rm -rf .build
swift build 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "^/.*error:|Build complete" | cut -c1-300 | sort -u | tail -25
[ -x .build/debug/Soak ] || { echo "build failed" >&2; exit 2; }
SOAK_OUT=${1:-} .build/debug/Soak
