#!/bin/zsh
# Muted end-to-end playback matrix for the Music module.
#
# What it does: for each music source (Audius, JioSaavn, Apple/iTunes, YouTube Music full and basic, Piped, Invidious, a pasted signed-out
# Spotify track link, Local files) and each of four queries (English "Bohemian Rhapsody", Tamil "Kaavaalaa", Telugu "Dakko Dakko Meka", Hindi
# "Tum Hi Ho") it searches, resolves a stream with the app's own MusicStreamResolver (chain hook, provider health and playback log included),
# opens it in an AVPlayer exactly the way MusicPlayer does (direct, or through MusicStreamProxy with the same headers), plays for 8 seconds,
# measures how fast the position moves, seeks to 30 s when the song is long enough, then prints a PASS/FAIL table with the failing step and the
# error domain/code. It also runs negative tests: a provider that fails, one that hangs, a stream address that is dead, and every provider dead;
# each must end with a logged reason and the next candidate, never a hang.
#
# MUTED: every AVPlayer is created with volume 0 and isMuted before it plays; nothing is sent to the app or to any audio engine.
# LIVE NETWORK: it talks to the real public services, about one search plus one resolve plus one stream read per table cell. No account, no
# sign-in, no keys. Local files uses a few seconds of generated silence in a temporary folder that is deleted afterwards.
#
# How it builds: it links the real source files listed in MusicPlaybackMatrix/sources.txt into a small throw-away Swift package (the full app is
# not built), with the keychain and storage stubbed in MusicPlaybackMatrix/Stubs.swift so nothing touches the person's data.
#
# Run:    Scripts/music-playback-matrix.sh [output.md]
# Narrow: MATRIX_PROVIDERS=audius,ytmusic,negative MATRIX_QUERIES=english,hindi Scripts/music-playback-matrix.sh
#   providers: audius jiosaavn itunes ytmusic youtube-music piped invidious spotify local addon deezer negative
#   other knobs: MATRIX_PLAY_SECONDS (8), MATRIX_SEEK_TO (30), MATRIX_SPOTIFY="Tamil=<trackID>,..." (extra Spotify track ids), MATRIX_WORK (build dir)
set -e
ROOT=${0:A:h:h}
SRC=$ROOT/Sources/REDDY
H=$ROOT/Scripts/MusicPlaybackMatrix
WORK=${MATRIX_WORK:-${TMPDIR:-/tmp}/music-playback-matrix-build}
mkdir -p $WORK; rm -rf $WORK/Sources $WORK/Package.swift
mkdir -p $WORK/Sources/Matrix/real
cat > $WORK/Package.swift <<P
// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "MusicPlaybackMatrix", platforms: [.macOS(.v14)],
  targets: [.executableTarget(name: "Matrix", path: "Sources/Matrix", swiftSettings: [.swiftLanguageMode(.v6)])])
P
setopt null_glob
grep -v '^#' $H/sources.txt | while read pat; do
  [ -z "$pat" ] && continue
  for f in $SRC/${~pat}; do
    rel=${f#$SRC/}
    grep -qxF "$rel" $H/exclude.txt && continue
    mkdir -p $WORK/Sources/Matrix/real/${rel:h}
    ln -sf $f $WORK/Sources/Matrix/real/$rel
  done
done
for f in $H/*.swift; do ln -sf $f $WORK/Sources/Matrix/${f:t}; done
cd $WORK
# symlinked sources defeat the incremental build check, so always build clean
rm -rf .build
swift build 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "^/.*error:|Build complete" | cut -c1-300 | sort -u | tail -25
[ -x .build/debug/Matrix ] || { echo "build failed" >&2; exit 2; }
MATRIX_OUT=${1:-} .build/debug/Matrix
