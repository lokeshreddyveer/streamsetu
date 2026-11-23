#!/bin/bash
# commit-prep.sh - Read-only helper before a commit. Never stages, commits or pushes.
# Usage: Scripts/dev/commit-prep.sh [--dry-run] [--timings]
# Shows git status grouped by area (macos, ios, android, windows, docs, legal, scripts, fixtures, other), runs the setu-guard
# check, the secret scan (skipped when nothing changed), flags files that must not be committed (agent notes and folders, hooks folder,
# generated key files, build products, signing material), and prints suggested commit groupings as plain text.
# Exit 5 when something is flagged or a check fails; 0 otherwise.
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
while [ $# -gt 0 ]; do common_flag "$1" && { shift; continue; }; usage_error "unknown option: $1"; done
cd "$ROOT"
area() { case "$1" in
  macos/*) echo macos;; ios/*) echo ios;; android/*) echo android;; windows/*) echo windows;; legal/*) echo legal;; Scripts/*) echo scripts;;
  docs/*|*.md) echo docs;; smartmix/*|artwork/*|epg/*|*ixtures*) echo fixtures;; *) echo other;; esac; }
flagged() { case "$1" in
  CLAUDE.md|*/CLAUDE.md|CLAUDE.local.md|*/CLAUDE.local.md|.claude/*|*/.claude/*|.githooks/*|*/.githooks/*) echo "agent notes or folder";;
  */Generated/Generated*.swift|*/Generated/*Key*) echo "generated key file";;
  */dist/*|*.app/*|*.apk|*.aab|*.dmg|*.ipa|*.xcarchive|*/.build/*|.build/*|*DerivedData*|*/build/*) echo "build product";;
  keystore.properties|*/keystore.properties|*.jks|*.keystore|*.p12|*.p8|.env|*/.env) echo "signing material or secret file";; esac; }
STATUS="$(git status --porcelain -uall)"
if [ -z "$STATUS" ]; then log "working tree is clean"; fi
BAD=0; FLAGGED=""; AREAS="macos ios android windows docs legal scripts fixtures other"
for a in $AREAS; do eval "G_$a=''"; done
while IFS= read -r line; do
  [ -n "$line" ] || continue
  code="${line:0:2}"; path="${line:3}"; path="${path##* -> }"; path="${path#\"}"; path="${path%\"}"
  a="$(area "$path")"; eval "G_$a=\"\${G_$a}  $code $path
\""
  why="$(flagged "$path")"; [ -z "$why" ] || FLAGGED="$FLAGGED  $path ($why)
"
done <<<"$STATUS"
for a in $AREAS; do eval "g=\$G_$a"; [ -z "$g" ] || { printf '\n== %s\n%s' "$a" "$g"; }; done
echo
if [ -n "$FLAGGED" ]; then err "MUST NOT be committed (unstage or add to .gitignore):"; printf '%s' "$FLAGGED" >&2; BAD=1; else log "no forbidden files in the change set"; fi
GUARD="$HOME/.config/setu-guard/check.py"
if [ -f "$GUARD" ]; then
  if python3 -I "$GUARD" >"$WORK/commit-prep-guard.log" 2>&1; then ok "setu-guard check clean"; else err "setu-guard check failed:"; excerpt "$WORK/commit-prep-guard.log" >&2; BAD=1; fi
else warn "setu-guard check.py not found; run the policy check by hand"; fi
scan_secrets || BAD=1
echo; log "suggested commits (nothing is run for you; keep messages free of tool trailers):"
for a in $AREAS; do eval "g=\$G_$a"; [ -z "$g" ] || printf '  git add -- %s   # then: git commit -m "%s: <what changed>"\n' "$([ "$a" = other ] && echo "<the other files above>" || { [ "$a" = fixtures ] && echo "smartmix artwork epg" || { [ "$a" = docs ] && echo "docs *.md" || { [ "$a" = scripts ] && echo Scripts || echo "$a"; }; }; })" "$a"; done
[ $BAD = 0 ] || exit $EX_GATE
