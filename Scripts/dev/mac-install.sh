#!/bin/bash
# mac-install.sh - Sign, verify, secret-scan and install the built Mac app into /Applications.
# Usage: Scripts/dev/mac-install.sh [--adhoc] [--no-launch] [--wait] [--rollback] [--dry-run] [--timings]
#   --adhoc      sign ad hoc instead of with the Developer ID Application identity (found with `security find-identity`)
#   --no-launch  install without starting the app
#   --wait       after launching, wait until the app's process exists (default: return at once)
#   --rollback   restore the newest backup from $STREAMSETU_WORK/backup (the last 3 installs are kept)
# Fast path: signing is skipped when the app already carries the wanted signature, and the copy is skipped when the
# installed main binary and version are identical to the built ones. Backups use APFS clones (instant).
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"
ADHOC=0; LAUNCH=1; WAIT=0; ROLLBACK=0
while [ $# -gt 0 ]; do
  common_flag "$1" && { shift; continue; }
  case "$1" in --adhoc) ADHOC=1;; --no-launch) LAUNCH=0;; --wait) WAIT=1;; --rollback) ROLLBACK=1;; *) usage_error "unknown option: $1";; esac; shift
done
SRC="$ROOT/macos/dist/StreamSetu.app"; DEST="/Applications/StreamSetu.app"; BK="$WORK/backup"
acquire_lock mac-install
version_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || echo "?"; }
build_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$1/Contents/Info.plist" 2>/dev/null || echo "?"; }
stop_app() { # SIGTERM, wait for the process to be gone, escalate only if it ignores it
  pgrep -x StreamSetu >/dev/null 2>&1 || return 0
  pkill -x StreamSetu 2>/dev/null || true
  wait_until 5000 sh -c '! pgrep -x StreamSetu' || { pkill -9 -x StreamSetu 2>/dev/null || true; wait_until 2000 sh -c '! pgrep -x StreamSetu'; }
}
launch_app() { [ $LAUNCH = 1 ] || return 0; open -a "$DEST"; [ $WAIT = 0 ] || wait_until 10000 pgrep -x StreamSetu || warn "app process not seen within 10 s"; }
install_copy() { rm -rf "$DEST" && ditto "$1" "$DEST"; }

if [ $ROLLBACK = 1 ]; then
  LATEST="$(ls -1d "$BK"/StreamSetu-*.app 2>/dev/null | sort | tail -1 || true)"
  [ -n "$LATEST" ] || die $EX_MISSING "no backup in $BK"
  log "restoring $(basename "$LATEST") (version $(version_of "$LATEST"))"
  run_step "stop app" stop_app
  run_step "restore" install_copy "$LATEST"
  run_step "launch" launch_app
  [ "$DRY_RUN" = 1 ] || ok "installed version $(version_of "$DEST") ($(build_of "$DEST"))"; exit 0
fi

[ -d "$SRC" ] || [ "$DRY_RUN" = 1 ] || die $EX_MISSING "no built app at $SRC; run Scripts/dev/mac-build.sh first"
if [ $ADHOC = 0 ]; then
  IDENT="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1 || true)"
  [ -n "$IDENT" ] || [ "$DRY_RUN" = 1 ] || die $EX_MISSING "no Developer ID Application identity in the keychain. Use --adhoc for a local test install"
  log "signing identity: ${IDENT:-<Developer ID, looked up at run time>}"
fi
signed_ok() { local d; d="$(codesign -dvv "$SRC" 2>&1 || true)"; if [ $ADHOC = 1 ]; then grep -q 'Signature=adhoc' <<<"$d"; else grep -q 'Authority=Developer ID Application' <<<"$d"; fi && codesign --verify --deep --strict "$SRC" 2>/dev/null; }
if [ $DRY_RUN = 0 ] && signed_ok; then log "signature already as wanted: skipping re-sign"
elif [ $ADHOC = 1 ]; then run_step "sign (ad hoc)" codesign --force --deep --sign - "$SRC"
else run_step "sign (Developer ID)" env SIGN_IDENTITY="${IDENT:-}" "$ROOT/macos/Scripts/sign-app.sh" "$SRC"; fi
run_step "codesign verify" codesign --verify --deep --strict "$SRC"
if [ $DRY_RUN = 1 ]; then log "  [dry-run] secret scan (cached by hash), stop app, backup, copy, launch"; exit 0; fi
step "secret scan"; scan_secrets "$SRC" || exit $EX_GATE
BIN="Contents/MacOS/StreamSetu"
if [ -d "$DEST" ] && cmp -s "$SRC/$BIN" "$DEST/$BIN" && [ "$(version_of "$SRC")" = "$(version_of "$DEST")" ] && [ "$(build_of "$SRC")" = "$(build_of "$DEST")" ]; then
  log "installed app is identical to the built one: no copy"
else
  run_step "stop app" stop_app
  if [ -d "$DEST" ]; then
    mkdir -p "$BK"; B="$BK/StreamSetu-$(date +%Y%m%d-%H%M%S).app"
    run_step "backup previous (v$(version_of "$DEST"))" cp -Rc "$DEST" "$B"
    ls -1d "$BK"/StreamSetu-*.app | sort -r | tail -n +4 | while read -r old; do rm -rf "$old"; done || true
  fi
  run_step "install" install_copy "$SRC"
fi
run_step "launch" launch_app
ok "installed version $(version_of "$DEST") ($(build_of "$DEST"))"
