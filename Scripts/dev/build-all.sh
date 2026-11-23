#!/bin/bash
# build-all.sh - Mac, iOS (simulator) and Android (debug) builds, concurrently when this Mac has the RAM (24 GB or more), else one after another.
# Usage: Scripts/dev/build-all.sh [--keep-going] [--dry-run] [--timings]
# When parallel, xcodebuild gets half the CPUs and Gradle its usual capped heap. Each build has its own log under $STREAMSETU_WORK/logs. Fails fast unless --keep-going.
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
while [ $# -gt 0 ]; do common_flag "$1" && { shift; continue; }; case "$1" in --keep-going) KEEP_GOING=1;; *) usage_error "unknown option: $1";; esac; shift; done
acquire_lock build-all
if parallel_ok; then log "RAM ${MEM_GB} GB: building in parallel"; export XCODE_JOBS=$((NCPU / 2 > 0 ? NCPU / 2 : 1)); else log "RAM ${MEM_GB} GB: building one after another"; fi
PAR=0; parallel_ok && PAR=1
FAIL=0
for t in "mac|mac-build.sh" "ios|ios-build.sh --simulator" "android|android-build.sh --debug"; do
  n="${t%%|*}"; c="${t#*|}"; [ $DRY_RUN = 0 ] || c="$c --dry-run"
  # shellcheck disable=SC2086
  job_start "$n" env SD_LOG_DIR="$LOG_DIR" "$SD_DEV/"$c
  if [ $PAR = 0 ]; then jobs_wait; jobs_report || { FAIL=1; [ $KEEP_GOING = 1 ] || break; }; fi
done
if [ $PAR = 1 ]; then jobs_wait; jobs_report || FAIL=1; fi
[ $FAIL = 0 ] && ok "all builds done" || die $EX_FAIL "a build failed"
