#!/bin/bash
# test-android.sh - Android checks that need no device.
# Usage: Scripts/dev/test-android.sh [--unit | --lint | --r8 | --all] [--force] [--dry-run] [--timings]
#   --unit  testDebugUnitTest    --lint  lintRelease    --r8  :app:minifyReleaseWithR8 (shrinker check)    --all  (default) all three in one Gradle run
# One Gradle invocation (daemon + build cache), so up-to-date work is skipped by Gradle itself. Same guard as android-build.sh:
# refuses to start while another Gradle run is active (exit 4) unless --force.
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
T=""; FORCE=0
add() { case " $T " in *" $1 "*) ;; *) T="$T $1";; esac; }
while [ $# -gt 0 ]; do
  common_flag "$1" && { shift; continue; }
  case "$1" in
    --unit) add testDebugUnitTest;; --lint) add lintRelease;; --r8) add :app:minifyReleaseWithR8;;
    --all) add testDebugUnitTest; add lintRelease; add :app:minifyReleaseWithR8;; --force) FORCE=1;;
    *) usage_error "unknown option: $1";;
  esac; shift
done
[ -n "$T" ] || { add testDebugUnitTest; add lintRelease; add :app:minifyReleaseWithR8; }
android_env
acquire_lock android
gradle_guard
GW() { cd "$ROOT/android" && ./gradlew $(gradle_flags) "$@"; }
# shellcheck disable=SC2086
run_step "gradle$T" GW $T
