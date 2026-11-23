#!/bin/bash
# test-mac.sh - Run the Mac test suite.
# Usage: Scripts/dev/test-mac.sh [--all | --filter NAME | --ui] [--coverage] [--dry-run] [--timings]
#   --all        (default) every unit test       --filter NAME  only tests matching NAME (swift test --filter)
#   --ui         the Mac XCUITest wrapper macos/UITests/run-mac-uitests.sh (needs Accessibility permission and a built macos/dist app)
#   --coverage   enable code coverage
# Uses macos/Scripts/run-tests.sh (which also removes the throwaway test databases) with a stable scratch path under $STREAMSETU_WORK/build/mac-test, so reruns are incremental.
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
MODE=all; FILTER=""; COV=0
while [ $# -gt 0 ]; do
  common_flag "$1" && { shift; continue; }
  case "$1" in
    --all) MODE=all;; --ui) MODE=ui;; --coverage) COV=1;;
    --filter) [ $# -ge 2 ] || usage_error "--filter needs a name"; FILTER=$2; MODE=filter; shift;;
    *) usage_error "unknown option: $1";;
  esac; shift
done
[[ -z "$FILTER" || "$FILTER" =~ ^[A-Za-z0-9_./:\ -]+$ ]] || usage_error "filter has unexpected characters"
need swift "Install Xcode 27.2"
acquire_lock test-mac
if [ $MODE = ui ]; then
  U="$ROOT/macos/UITests/run-mac-uitests.sh"; [ -x "$U" ] || die $EX_MISSING "no Mac UI test wrapper at $U"
  [ -d "$ROOT/macos/dist/StreamSetu.app" ] || [ $DRY_RUN = 1 ] || die $EX_MISSING "build the app first: Scripts/dev/mac-build.sh"
  run_step "Mac UI tests" env UITEST_WORK="$WORK/mac-uitests" "$U"; exit 0
fi
ARGS=(--scratch-path "$WORK/build/mac-test"); [ -z "$FILTER" ] || ARGS+=(--filter "$FILTER"); [ $COV = 0 ] || ARGS+=(--enable-code-coverage)
run_step "swift test ($MODE)" bash -c "cd '$ROOT/macos' && exec Scripts/run-tests.sh \"\$@\"" _ "${ARGS[@]}"
