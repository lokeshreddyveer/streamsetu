#!/bin/bash
# bench.sh - Cold vs warm timings of the cheap gates (and, with --builds, of no-op builds).
# Usage: Scripts/dev/bench.sh [--builds] [--dry-run] [--timings]
#   cold = a fresh empty work folder (no stamps, no scan cache);  warm = the immediately following second run
#   --builds   also time a second, no-op run of mac-build, ios-build --simulator and android-build --debug (needs a prior real build; can take minutes)
# Runs against a private work folder $STREAMSETU_WORK/bench, so your real caches are untouched.
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
BUILDS=0
while [ $# -gt 0 ]; do common_flag "$1" && { shift; continue; }; case "$1" in --builds) BUILDS=1;; *) usage_error "unknown option: $1";; esac; shift; done
acquire_lock bench
B="$WORK/bench"
timeit() { local t0; t0=$(now_ms); "$@" >/dev/null 2>&1 && local rc=0 || local rc=$?; echo "$(($(now_ms) - t0)) $rc"; }
if [ $DRY_RUN = 1 ]; then log "  [dry-run] cold and warm runs of check-all.sh in $B$([ $BUILDS = 1 ] && echo ', plus no-op builds')"; exit 0; fi
rm -rf "$B"; mkdir -p "$B"
read -r c1 r1 <<<"$(timeit env STREAMSETU_WORK="$B" "$SD_DEV/check-all.sh" --keep-going)"
read -r c2 r2 <<<"$(timeit env STREAMSETU_WORK="$B" "$SD_DEV/check-all.sh" --keep-going)"
printf '\n%-34s %10s %10s %s\n' STEP COLD WARM "(exit codes)"
printf '%-34s %10s %10s (%s/%s)\n' "check-all (cheap gates)" "$(fmt_ms "$c1")" "$(fmt_ms "$c2")" "$r1" "$r2"
if [ $BUILDS = 1 ]; then
  for s in "mac-build.sh" "ios-build.sh --simulator" "android-build.sh --debug"; do
    # shellcheck disable=SC2086
    read -r a ra <<<"$(timeit "$SD_DEV/"${s%% *} ${s#"${s%% *}"})"; printf '%-34s %10s %10s (no-op rerun; exit %s)\n' "${s%% *}" "-" "$(fmt_ms "$a")" "$ra"
  done
fi
