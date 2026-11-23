#!/bin/bash
# all-green.sh - The full pipeline for a quiet tree, with a PASS/FAIL table and elapsed time per stage.
# Usage: Scripts/dev/all-green.sh [--keep-going] [--dry-run] [--timings]
#   1. check-all.sh                         (cheap gates, parallel inside)
#   2. test-mac --all  |  test-android --all  |  test-ios --unit
#      run concurrently when the Mac has 24 GB RAM or more, otherwise Mac and Android together and iOS after them
# Stops at the first failing stage (running tests are cancelled) unless --keep-going. Exit 1 on any failure.
# Logs: $STREAMSETU_WORK/logs/<timestamp>/ (one file per script and per job).
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
while [ $# -gt 0 ]; do common_flag "$1" && { shift; continue; }; case "$1" in --keep-going) KEEP_GOING=1;; *) usage_error "unknown option: $1";; esac; shift; done
acquire_lock all-green
LOG_DIR="$WORK/logs/$(date +%Y%m%d-%H%M%S)"; export SD_LOG_DIR="$LOG_DIR"; mkdir -p "$LOG_DIR"
log "logs: $LOG_DIR"
FLAGS=(); [ $DRY_RUN = 0 ] || FLAGS+=(--dry-run); [ $KEEP_GOING = 0 ] || FLAGS+=(--keep-going)
CHILD=(); [ $DRY_RUN = 0 ] || CHILD+=(--dry-run)
OK=1
stage "check-all" "$SD_DEV/check-all.sh" ${FLAGS[@]+"${FLAGS[@]}"} || OK=0
if [ $OK = 0 ] && [ $KEEP_GOING = 0 ]; then skip_stage test-mac; skip_stage test-android; skip_stage test-ios; else
  job_start test-mac "$SD_DEV/test-mac.sh" --all ${CHILD[@]+"${CHILD[@]}"}
  job_start test-android "$SD_DEV/test-android.sh" --all ${CHILD[@]+"${CHILD[@]}"}
  parallel_ok && job_start test-ios "$SD_DEV/test-ios.sh" --unit ${CHILD[@]+"${CHILD[@]}"}
  jobs_wait; jobs_report || OK=0
  if ! parallel_ok; then
    if [ $OK = 0 ] && [ $KEEP_GOING = 0 ]; then skip_stage test-ios; else stage "test-ios" "$SD_DEV/test-ios.sh" --unit ${CHILD[@]+"${CHILD[@]}"} || OK=0; fi
  fi
fi
print_results || OK=0
[ $OK = 1 ] && { ok "ALL GREEN"; exit 0; }
die $EX_FAIL "not green (logs: $LOG_DIR)"
