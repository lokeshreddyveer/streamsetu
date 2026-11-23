#!/bin/bash
# check-all.sh - The cheap gates, run concurrently, with a per-gate timing table. Target: under 60 s on a warm machine.
# Usage: Scripts/dev/check-all.sh [--full] [--strict-atlas] [--keep-going] [--dry-run] [--timings]
#   gates (parallel): host parity + fixtures + legal sync (one Python process), secret scan (skipped when nothing changed),
#                     setu-guard check.py, Atlas scan (only with --full: it compiles Swift), Scripts/smoke.sh when present
#   --full           also run the Atlas scan (builds its tool incrementally), and run test-release-gates.sh (also stands in for smoke.sh when that is absent)
#   --strict-atlas   Atlas findings fail the run (default: warn only, as Scripts/check-atlas.sh does)
#   --keep-going     let the remaining gates finish after one fails (default: stop them at the first failure)
# Exit 5 when a gate failed.
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
FULL=0; STRICT=0
while [ $# -gt 0 ]; do
  common_flag "$1" && { shift; continue; }
  case "$1" in --full) FULL=1;; --strict-atlas) STRICT=1;; --keep-going) KEEP_GOING=1;; *) usage_error "unknown option: $1";; esac; shift
done
acquire_lock check-all
gate_secrets() { scan_secrets; }
gate_guard() { cd "$ROOT" && python3 -I "$HOME/.config/setu-guard/check.py"; }
gate_atlas() { if [ $STRICT = 1 ]; then "$ROOT/macos/Scripts/check-atlas.sh" --strict; else "$ROOT/macos/Scripts/check-atlas.sh"; fi; }
SPECS=()
for s in "Scripts/check-host-parity.py" "Scripts/check-fixtures.py" "legal/sync-legal.py --check"; do [ -f "$ROOT/${s%% *}" ] && SPECS+=("$s"); done
[ ${#SPECS[@]} -eq 0 ] || job_start python-gates python3 -I "$SD_DEV/lib/pybatch.py" "$ROOT" "${SPECS[@]}"
job_start secret-scan gate_secrets
[ -f "$HOME/.config/setu-guard/check.py" ] && job_start setu-guard gate_guard || warn "setu-guard check.py not found; skipped"
if [ $FULL = 1 ]; then job_start atlas gate_atlas; else log "atlas: skipped (it compiles Swift, so it is opt-in: --full)"; fi
if [ -x "$ROOT/Scripts/smoke.sh" ]; then job_start smoke "$ROOT/Scripts/smoke.sh"
elif [ $FULL = 1 ] && [ -x "$ROOT/Scripts/test-release-gates.sh" ]; then job_start release-gates "$ROOT/Scripts/test-release-gates.sh"; fi
jobs_wait
if jobs_report; then ok "all gates passed"; else die $EX_GATE "a gate failed (logs above)"; fi
