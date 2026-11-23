#!/bin/bash
# selftest.sh - Tests for the dev scripts themselves: syntax, --help, bad input, --dry-run, lock and job behaviour, no sleeps, no key-shaped output.
# Usage: Scripts/dev/selftest.sh [--keep] [--timings]
#   --keep  keep the scratch folder (it is printed) instead of deleting it
# Runs nothing heavy: every script is exercised with --help and --dry-run only (commit-prep and check-all gates that are cheap run for real in a private work folder).
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
KEEP=0
while [ $# -gt 0 ]; do common_flag "$1" && { shift; continue; }; case "$1" in --keep) KEEP=1;; *) usage_error "unknown option: $1";; esac; shift; done
T="$(mktemp -d "${TMPDIR:-/tmp}/streamsetu-selftest.XXXXXX")"; mkdir -p "$T/out" "$T/work"
trap '[ $KEEP = 1 ] && echo "kept: $T" || rm -rf "$T"' RETURN 2>/dev/null || true
PASS=0; FAILN=0; N=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() { FAILN=$((FAILN + 1)); echo "  FAIL $1"; }
expect() { # name want-exit-codes(a|b) cmd...
  local name=$1 want=$2; shift 2; N=$((N + 1)); local out="$T/out/$N.txt" rc=0
  STREAMSETU_WORK="$T/work" "$@" >"$out" 2>&1 || rc=$?
  case "|$want|" in *"|$rc|"*) pass "$name (exit $rc)";; *) fail "$name: exit $rc, wanted $want (see $out)"; head -5 "$out" | sed 's/^/       /';; esac
}
SCRIPTS="mac-build mac-install ios-build ios-install android-build test-mac test-ios test-android check-all all-green commit-prep build-all bench"
echo "static checks"
for s in $SCRIPTS selftest; do
  f="$SD_DEV/$s.sh"
  bash -n "$f" && zsh -n "$f" && pass "$s: bash -n and zsh -n" || fail "$s: syntax"
  grep -q '^set -euo pipefail' "$f" && pass "$s: set -euo pipefail" || fail "$s: no set -euo pipefail"
  [ -x "$f" ] && pass "$s: executable" || fail "$s: not executable"
done
if command -v shellcheck >/dev/null 2>&1; then shellcheck -x -S warning "$SD_DEV"/*.sh "$SD_DEV"/lib/common.sh >"$T/out/shellcheck.txt" 2>&1 && pass "shellcheck clean" || { fail "shellcheck"; head -20 "$T/out/shellcheck.txt"; }
else log "shellcheck not installed: bash -n and zsh -n only"; fi
BAD1="cl""aude"; BAD2="anth""ropic"; BAD3="open""ai"; BAD4="cop""ilot"; BAD5="gem""ini"
if grep -rniE "$BAD1|$BAD2|$BAD3|$BAD4|$BAD5|/tmp/" "$SD_DEV" --include='*.sh' --include='*.py' --include='*.md' | grep -v -e 'selftest.sh' -e 'commit-prep.sh' >"$T/out/names.txt"; then fail "tool names or /tmp paths present"; head -3 "$T/out/names.txt"; else pass "no tool names or /tmp paths"; fi
if grep -nE '(^|[^a-z_])sleep [0-9]' "$SD_DEV"/[a-rt-z]*.sh "$SD_DEV"/lib/common.sh 2>/dev/null | grep -v 'sleep 0\.05' >"$T/out/sleeps.txt"; then fail "fixed sleep found"; cat "$T/out/sleeps.txt"; else pass "no fixed sleeps (only the 50 ms poll)"; fi

echo "help and bad input"
for s in $SCRIPTS selftest; do
  expect "$s --help" 0 "$SD_DEV/$s.sh" --help
  grep -q '^Usage:' "$T/out/$N.txt" && grep -q 'Exit codes' "$T/out/$N.txt" && pass "$s: help has usage and exit codes" || fail "$s: help text incomplete"
  expect "$s --bogus" 2 "$SD_DEV/$s.sh" --bogus
done
expect "mac-build bad version" 2 "$SD_DEV/mac-build.sh" "not-a-version" --dry-run
expect "mac-build bad build" 2 "$SD_DEV/mac-build.sh" 1.2.3 12x --dry-run
expect "ios-install bad device id" 2 "$SD_DEV/ios-install.sh" --device-id 'a b;c' --dry-run
expect "android-build bad code" 2 "$SD_DEV/android-build.sh" --code abc --dry-run
expect "bad STREAMSETU_WORK" 2 env STREAMSETU_WORK=relative "$SD_DEV/mac-build.sh" --help

echo "dry runs"
expect "mac-build --dry-run" 0 "$SD_DEV/mac-build.sh" 1.2.3 456 --dry-run --timings
expect "mac-install --dry-run" 0 "$SD_DEV/mac-install.sh" --adhoc --dry-run
for m in --simulator --device --generic; do expect "ios-build $m --dry-run" 0 "$SD_DEV/ios-build.sh" $m --dry-run; done
expect "ios-install --dry-run" 0 "$SD_DEV/ios-install.sh" --app "$T" --device-id TEST-1234 --dry-run
for m in --debug --release-check; do expect "android-build $m --dry-run" 0 "$SD_DEV/android-build.sh" $m --dry-run; done
expect "android-build --test-apk --dry-run" "0|3" "$SD_DEV/android-build.sh" --test-apk --dry-run
for m in --all "--filter Foo" --ui; do expect "test-mac $m --dry-run" "0|3" "$SD_DEV/test-mac.sh" $m --dry-run; done
for m in --unit --ui --walk --cleanup; do expect "test-ios $m --dry-run" 0 "$SD_DEV/test-ios.sh" $m --dry-run; done
for m in --unit --lint --r8 --all; do expect "test-android $m --dry-run" 0 "$SD_DEV/test-android.sh" $m --dry-run; done
expect "check-all --dry-run" 0 "$SD_DEV/check-all.sh" --dry-run
expect "build-all --dry-run" 0 "$SD_DEV/build-all.sh" --dry-run
expect "all-green --dry-run" 0 "$SD_DEV/all-green.sh" --dry-run
expect "bench --dry-run" 0 "$SD_DEV/bench.sh" --dry-run
expect "commit-prep (read-only, real)" "0|5" "$SD_DEV/commit-prep.sh"

echo "library behaviour"
LIB="$SD_DEV/lib/common.sh"
expect "lock: second holder refused" 4 bash -c ". '$LIB'; acquire_lock t1; bash -c \". '$LIB'; acquire_lock t1\""
expect "lock: stale lock reclaimed" 0 bash -c ". '$LIB'; mkdir -p \"\$WORK/locks/t2.lock\"; echo 99999999 > \"\$WORK/locks/t2.lock/pid\"; acquire_lock t2"
expect "lock: released at exit" 0 bash -c ". '$LIB'; bash -c \". '$LIB'; acquire_lock t3\" && acquire_lock t3"
expect "wait_until returns at once" 0 bash -c ". '$LIB'; t0=\$(now_ms); wait_until 5000 true; [ \$((\$(now_ms)-t0)) -lt 40 ]"
expect "wait_until times out" 0 bash -c ". '$LIB'; ! wait_until 200 false"
expect "wait_until sees a late condition" 0 bash -c ". '$LIB'; (sleep 0.2; touch '$T/flag') & wait_until 3000 test -e '$T/flag'"
expect "jobs: fail fast cancels the rest" 0 bash -c ". '$LIB'; job_start bad sh -c 'exit 3'; job_start slow sleep 30; t0=\$(now_ms); jobs_wait; [ \$((\$(now_ms)-t0)) -lt 5000 ] && [ \"\${JOB_RC[0]}\" = 3 ] && [ \"\${JOB_RC[1]}\" = CANCELLED ]"
expect "jobs: keep-going finishes all" 0 bash -c ". '$LIB'; KEEP_GOING=1; job_start bad sh -c 'exit 3'; job_start good true; jobs_wait; [ \"\${JOB_RC[1]}\" = 0 ]"
expect "stamp round trip" 0 bash -c ". '$LIB'; stamp_set x abc; [ \"\$(stamp_get x)\" = abc ]"
expect "excerpt masks key-shaped text" 0 bash -c ". '$LIB'; printf 'error: eyJ%s.%s.%s\n' aaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbb cccccccccccc > '$T/k.txt'; ! excerpt '$T/k.txt' | grep -q eyJa"

echo "no key values in any output"
python3 -I - "$T/out" "${STREAMSETU_KEYS_DIR:-$HOME/Documents/keys}" <<'PY' && pass "no key-shaped strings or key values in $N outputs" || fail "key-shaped output found (file names above; values are never printed)"
import os, re, sys
out, kd = sys.argv[1], sys.argv[2]
jwt = re.compile(r"eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}")
keys = [os.environ.get(e, "").strip() for e in ("STREAMSETU_TMDB_TOKEN", "STREAMSETU_FANART_KEY", "STREAMSETU_TVDB_KEY")]
for f in ("tmdb-read-token.txt", "fanart-api-key.txt", "thetvdb-api-key.txt"):
    p = os.path.join(kd, f)
    if os.path.isfile(p): keys.append(open(p).read().strip())
keys = [k for k in keys if len(k) >= 8]
bad = 0
for n in sorted(os.listdir(out)):
    t = open(os.path.join(out, n), errors="replace").read()
    if jwt.search(t) or any(k in t for k in keys): print("  key-shaped content in", n); bad = 1
sys.exit(bad)
PY
echo; log "$PASS passed, $FAILN failed"
[ $FAILN = 0 ] || exit $EX_FAIL
