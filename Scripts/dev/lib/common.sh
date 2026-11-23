#!/bin/bash
# Shared helpers for Scripts/dev (sourced, never run). bash 3.2 compatible (macOS /bin/bash).
# Exit codes: 0 ok | 1 a step failed | 2 usage | 3 missing requirement | 4 lock busy | 5 gate or secret scan failed | 6 device not ready
[ -n "${SD_LIB_LOADED:-}" ] && return 0
SD_LIB_LOADED=1
SD_SELF="$0"; SD_NAME="$(basename "$SD_SELF" .sh)"
SD_DEV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$SD_DEV/../.." && pwd)"
WORK="${STREAMSETU_WORK:-$HOME/Library/Caches/StreamSetu-dev}"
case "$WORK" in /|"$HOME"|"") echo "refusing STREAMSETU_WORK=$WORK" >&2; exit 2;; /*) ;; *) echo "STREAMSETU_WORK must be absolute" >&2; exit 2;; esac
EX_FAIL=1; EX_USAGE=2; EX_MISSING=3; EX_BUSY=4; EX_GATE=5; EX_DEVICE=6
DRY_RUN=0; TIMINGS=0; KEEP_GOING=0; SD_QUIET=0
KEYS_DIR="${STREAMSETU_KEYS_DIR:-$HOME/Documents/keys}"
LOG_DIR="${SD_LOG_DIR:-$WORK/logs/adhoc}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SD_T0=$SECONDS
TIMES=(); LOCKS=(); RESULTS=()
JOB_NAMES=(); JOB_PIDS=(); JOB_RC=(); JOB_LOG=()

# ---- time and logging -------------------------------------------------------------------------
now_ms() { if [ -n "${EPOCHREALTIME:-}" ]; then local t=${EPOCHREALTIME/[.,]/}; echo $((t / 1000)); else perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'; fi; }
fmt_ms() { printf '%d.%ds' $(($1 / 1000)) $(($1 % 1000 / 100)); }
log()  { printf '[%s] %s\n' "$SD_NAME" "$*"; }
step() { printf '[%s] > %s\n' "$SD_NAME" "$*"; }
ok()   { printf '[%s] ok %s\n' "$SD_NAME" "$*"; }
warn() { printf '[%s] warning: %s\n' "$SD_NAME" "$*" >&2; }
err()  { printf '[%s] error: %s\n' "$SD_NAME" "$*" >&2; }
die()  { local c=$1; shift; err "$*"; exit "$c"; }
record_time() { TIMES+=("$1|$2|$3"); }
redact() { sed -E 's/eyJ[A-Za-z0-9_-]{20,}(\.[A-Za-z0-9_-]+)*/<redacted>/g; s/[A-Fa-f0-9]{40,}/<hex>/g'; }
excerpt() { # first error lines of a log, else its tail; key-shaped strings masked
  { grep -m15 -E 'error|✘|FAILED|FAIL|fatal' "$1" 2>/dev/null || tail -n 15 "$1" 2>/dev/null || true; } | redact | sed 's/^/    /'
}
print_timings() {
  local t; [ ${#TIMES[@]} -gt 0 ] || return 0
  log "timings:"
  for t in "${TIMES[@]}"; do IFS='|' read -r a b c <<<"$t"; printf '    %-9s %8s  %s\n' "$c" "$(fmt_ms "$b")" "$a"; done
}
_sd_exit() {
  local rc=$?; trap - EXIT
  local d; for d in ${LOCKS[@]+"${LOCKS[@]}"}; do rm -rf "$d"; done
  if [ "$SD_QUIET" != 1 ]; then
    [ "$TIMINGS" = 1 ] && print_timings
    if [ $rc -eq 0 ]; then log "OK in $((SECONDS - SD_T0))s"; else log "FAILED (exit $rc) after $((SECONDS - SD_T0))s"; fi
  fi
  exit $rc
}
trap _sd_exit EXIT
trap 'exit 130' INT TERM

# ---- usage and common flags --------------------------------------------------------------------
usage() {
  sed -n '2,/^$/p' "$SD_SELF" | sed -e '/^$/d' -e 's/^# \{0,1\}//'
  printf '\nCommon flags: --help  --dry-run (show what would run, change nothing)  --timings (per-step breakdown)\n'
  printf 'Exit codes: 0 ok, 1 step failed, 2 usage, 3 missing requirement, 4 another run holds the lock, 5 gate/secret scan failed, 6 device not ready\n'
  printf 'Work folder: $STREAMSETU_WORK (default ~/Library/Caches/StreamSetu-dev)\n'
}
usage_error() { SD_QUIET=1; err "$*"; echo "run with --help for usage" >&2; exit $EX_USAGE; }
common_flag() { # consumes a flag every script shares; returns 1 when it is not one
  case "$1" in
    -h|--help) SD_QUIET=1; usage; exit 0;;
    --dry-run) DRY_RUN=1;;
    --timings) TIMINGS=1;;
    *) return 1;;
  esac
}
need() { command -v "$1" >/dev/null 2>&1 || die $EX_MISSING "$1 not found. $2"; }

# ---- lock (mkdir is atomic) ---------------------------------------------------------------------
acquire_lock() { # name; skipped in --dry-run
  [ "$DRY_RUN" = 1 ] && return 0
  local d="$WORK/locks/$1.lock" pid tries=0
  mkdir -p "$WORK/locks"
  while ! mkdir "$d" 2>/dev/null; do
    pid="$(cat "$d/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then die $EX_BUSY "another '$1' run is active (pid $pid); wait for it or stop it"; fi
    tries=$((tries + 1)); [ $tries -lt 3 ] || die $EX_BUSY "cannot take lock $d"
    rm -rf "$d"
  done
  echo $$ > "$d/pid"; LOCKS+=("$d")
}

# ---- polling (the only place that sleeps; 50 ms interval, bounded) ------------------------------
wait_until() { # timeout_ms cmd... ; returns at once when cmd succeeds
  local n=$(($1 / 50)); shift
  while ! "$@" >/dev/null 2>&1; do n=$((n - 1)); [ $n -ge 0 ] || return 1; sleep 0.05; done
}

# ---- running steps ------------------------------------------------------------------------------
_exec() { # title cmd... ; sets LAST_RC LAST_MS LAST_LOG
  local title=$1; shift
  mkdir -p "$LOG_DIR"
  LAST_LOG="$LOG_DIR/$SD_NAME-$(printf %s "$title" | tr -c 'A-Za-z0-9\n' '-' | cut -c1-40).log"
  local t0; t0=$(now_ms)
  if "$@" >"$LAST_LOG" 2>&1; then LAST_RC=0; else LAST_RC=$?; fi
  LAST_MS=$(($(now_ms) - t0))
  record_time "$title" "$LAST_MS" "$([ $LAST_RC = 0 ] && echo ok || echo FAIL)"
}
_show_cmd() { printf '%q ' "$@"; }
run_step() { # title cmd... ; stops the script on failure
  local title=$1; shift
  step "$title"
  if [ "$DRY_RUN" = 1 ]; then log "  [dry-run] $(_show_cmd "$@")"; return 0; fi
  _exec "$title" "$@"
  if [ "$LAST_RC" != 0 ]; then err "$title failed (exit $LAST_RC). First error lines:"; excerpt "$LAST_LOG" >&2; err "full log: $LAST_LOG"; exit $EX_FAIL; fi
  ok "$title ($(fmt_ms "$LAST_MS"))"
}
stage() { # title cmd... ; records PASS/FAIL/SKIP in RESULTS and returns the status; never exits
  local title=$1; shift
  if [ "$DRY_RUN" = 1 ]; then log "  [dry-run] $title: $(_show_cmd "$@")"; RESULTS+=("$title|SKIP|0"); return 0; fi
  step "$title"
  _exec "$title" "$@"
  if [ "$LAST_RC" = 0 ]; then RESULTS+=("$title|PASS|$LAST_MS"); ok "$title ($(fmt_ms "$LAST_MS"))"; return 0; fi
  RESULTS+=("$title|FAIL|$LAST_MS"); err "$title failed (exit $LAST_RC):"; excerpt "$LAST_LOG" >&2; err "full log: $LAST_LOG"; return 1
}
skip_stage() { RESULTS+=("$1|SKIP|0"); }
print_results() { # returns 1 if any FAIL
  local r bad=0 n s m
  printf '\n%-34s %-6s %9s\n' STAGE RESULT TIME
  for r in "${RESULTS[@]}"; do IFS='|' read -r n s m <<<"$r"; printf '%-34s %-6s %9s\n' "$n" "$s" "$(fmt_ms "$m")"; [ "$s" = FAIL ] && bad=1; done
  return $bad
}

# ---- parallel jobs: per-job logs, deterministic report, fail fast unless KEEP_GOING ---------------
job_start() { # name cmd...
  local n=$1; shift
  local lf="$LOG_DIR/$SD_NAME-job-$n.log"; mkdir -p "$LOG_DIR"; rm -f "$lf.done"
  if [ "$DRY_RUN" = 1 ]; then log "  [dry-run] job $n: $(_show_cmd "$@")"; return 0; fi
  ( t0=$(now_ms); rc=0; "$@" || rc=$?; echo "$(($(now_ms) - t0)) $rc" > "$lf.done"; exit "$rc" ) >"$lf" 2>&1 &
  JOB_NAMES+=("$n"); JOB_PIDS+=($!); JOB_RC+=("-"); JOB_LOG+=("$lf")
}
jobs_wait() { # waits for all started jobs; completion is signalled by <log>.done (a finished child stays a zombie until waited)
  local n=${#JOB_NAMES[@]} i j pending=1 failed=0
  [ $n -gt 0 ] || return 0
  while [ $pending -gt 0 ]; do
    pending=0
    for ((i = 0; i < n; i++)); do
      [ "${JOB_RC[$i]}" = "-" ] || continue
      if [ -e "${JOB_LOG[$i]}.done" ]; then
        wait "${JOB_PIDS[$i]}" 2>/dev/null && JOB_RC[$i]=0 || JOB_RC[$i]=$?
        if [ "${JOB_RC[$i]}" != 0 ] && [ "$KEEP_GOING" != 1 ] && [ $failed = 0 ]; then
          failed=1
          for ((j = 0; j < n; j++)); do
            [ "${JOB_RC[$j]}" = "-" ] || continue
            pkill -P "${JOB_PIDS[$j]}" 2>/dev/null || true; kill "${JOB_PIDS[$j]}" 2>/dev/null || true
            wait "${JOB_PIDS[$j]}" 2>/dev/null || true; JOB_RC[$j]=CANCELLED
          done
        fi
      else pending=$((pending + 1)); fi
    done
    [ $pending -gt 0 ] && sleep 0.05
  done
  return 0
}
jobs_report() { # prints in start order; returns 1 if any job failed
  local n=${#JOB_NAMES[@]} i ms bad=0 st
  for ((i = 0; i < n; i++)); do
    ms=0; [ -e "${JOB_LOG[$i]}.done" ] && ms=$(cut -d' ' -f1 "${JOB_LOG[$i]}.done")
    case "${JOB_RC[$i]}" in 0) st=PASS;; CANCELLED) st=CANCEL;; *) st=FAIL; bad=1;; esac
    RESULTS+=("${JOB_NAMES[$i]}|$st|$ms"); record_time "${JOB_NAMES[$i]}" "$ms" "$st"
    printf '  %-6s %-24s %8s  %s\n' "$st" "${JOB_NAMES[$i]}" "$(fmt_ms "$ms")" "${JOB_LOG[$i]}"
    [ "$st" = FAIL ] && excerpt "${JOB_LOG[$i]}" >&2
  done
  JOB_NAMES=(); JOB_PIDS=(); JOB_RC=(); JOB_LOG=()
  return $bad
}

# ---- fingerprints, stamps, cached secret scan -----------------------------------------------------
fp_paths() { # content fingerprint of tracked + untracked-not-ignored files under the given pathspecs
  { git -C "$ROOT" ls-files -z -co --exclude-standard -- "$@" | tr '\0' '\n' || true
    git -C "$ROOT" ls-files -z -co --exclude-standard -- "$@" | (cd "$ROOT" && xargs -0 git hash-object --stdin-paths 2>/dev/null) || true; } 2>/dev/null | shasum -a 256 | cut -d' ' -f1
}
tree_fp() { { git -C "$ROOT" rev-parse HEAD 2>/dev/null || true; git -C "$ROOT" ls-files -z -m -o --exclude-standard | (cd "$ROOT" && xargs -0 git hash-object --stdin-paths 2>/dev/null) || true; } | shasum -a 256 | cut -d' ' -f1; }
keys_fp() { { stat -f '%N %z %m' "$KEYS_DIR"/* 2>/dev/null; printf %s "${STREAMSETU_TMDB_TOKEN:-}${STREAMSETU_FANART_KEY:-}${STREAMSETU_TVDB_KEY:-}" | shasum -a 256; } | shasum -a 256 | cut -d' ' -f1; }
artifact_fp() { if [ -d "$1" ]; then find "$1" -type f -print0 | xargs -0 stat -f '%N %z %m' | shasum -a 256 | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
stamp_get() { cat "$WORK/cache/stamps/$1" 2>/dev/null || true; }
stamp_set() { mkdir -p "$WORK/cache/stamps"; printf '%s\n' "$2" > "$WORK/cache/stamps/$1"; }
scan_secrets() { # [artifact ...] ; repo + artifacts, skipped when nothing changed since the last pass (never prints a key)
  local key a; key="$({ for a in "$@"; do artifact_fp "$a"; done; keys_fp; tree_fp; } | shasum -a 256 | cut -c1-40)"
  if [ -e "$WORK/cache/scan/$key" ]; then log "secret scan: unchanged since the last pass (cached)"; return 0; fi
  mkdir -p "$LOG_DIR" "$WORK/cache/scan"
  if "$ROOT/Scripts/check-no-secrets.sh" "$@" >"$LOG_DIR/$SD_NAME-secret-scan.log" 2>&1; then : > "$WORK/cache/scan/$key"; log "secret scan: clean"; return 0; fi
  err "secret scan FAILED (values are never printed):"; excerpt "$LOG_DIR/$SD_NAME-secret-scan.log" >&2; return $EX_GATE
}

# ---- machine resources and toolchains --------------------------------------------------------------
MEM_GB=$(($(sysctl -n hw.memsize 2>/dev/null || echo 17179869184) / 1073741824)); NCPU=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
gradle_xmx() { local g=$((MEM_GB / 4)); [ $MEM_GB -ge 20 ] && g=5; [ $g -lt 2 ] && g=2; echo "${g}g"; }
xcode_jobs() { echo "${XCODE_JOBS:-$NCPU}"; }
parallel_ok() { [ "$MEM_GB" -ge 24 ]; }
android_env() {
  export JAVA_HOME="${STREAMSETU_JAVA_HOME:-$HOME/.local/opt/jdk-17/Contents/Home}"
  export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
  export PATH="$JAVA_HOME/bin:$HOME/.local/opt/node/bin:$PATH"
  export GRADLE_OPTS="-Xmx$(gradle_xmx) -Dorg.gradle.jvmargs=-Xmx$(gradle_xmx)"
  [ "$DRY_RUN" = 1 ] || [ -x "$JAVA_HOME/bin/java" ] || die $EX_MISSING "JDK 17 not found at $JAVA_HOME (set STREAMSETU_JAVA_HOME)"
}
gradle_flags() { local f="--build-cache"; grep -qs '^org.gradle.configuration-cache=true' "$ROOT/android/gradle.properties" && f="$f --configuration-cache"; echo "$f"; }
gradle_guard() { # refuses when another Gradle client is running, unless FORCE=1
  [ "${FORCE:-0}" = 1 ] || [ "$DRY_RUN" = 1 ] && return 0
  local p; p="$(pgrep -f 'org.gradle.wrapper.GradleWrapperMain' 2>/dev/null | head -1 || true)"
  [ -z "$p" ] || die $EX_BUSY "another Gradle run is active (pid $p). Wait for it, or pass --force"
}

# ---- iOS project generation (stamped: only when the generator or the file list changed) -------------
ios_gen_project() {
  local g; g="$(git -C "$ROOT" ls-files -co --exclude-standard -- ios ':!ios/StreamSetu.xcodeproj' | shasum -a 256 | cut -c1-20)$(shasum -a 256 "$ROOT/ios/Scripts/generate-project.py" | cut -c1-20)$(shasum -a 256 "$ROOT/ios/SharedSources.txt" | cut -c1-20)"
  if [ "$(stamp_get ios-gen)" = "$g" ] && [ -d "$ROOT/ios/StreamSetu.xcodeproj" ]; then log "project: up to date (not regenerated)"; return 0; fi
  run_step "generate project" bash -c "cd '$ROOT/ios' && python3 Scripts/generate-project.py >/dev/null"
  [ "$DRY_RUN" = 1 ] || stamp_set ios-gen "$g"
  return 0
}
