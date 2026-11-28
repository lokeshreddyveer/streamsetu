#!/bin/bash
# mac-fresh-launch.sh - Start StreamSetu as a brand-new install (full opening, welcome, Get Set Up) WITHOUT losing anything, then put everything back.
#   Scripts/dev/mac-fresh-launch.sh            quit the app, move this Mac's StreamSetu data and settings aside (an instant rename; nothing is deleted), launch fresh
#   Scripts/dev/mac-fresh-launch.sh --again    while your data is set aside: quit the app, clear only what the fresh run made, launch as a new install once more
#   Scripts/dev/mac-fresh-launch.sh --restore  quit the app, remove what the fresh run made, put the data and settings back, launch
#   --logs-accepted   with the first launch or --again: the "Share Logs" notice starts as already accepted (the same as pressing Share Logs), so it is not shown
# The data folder is ~/Library/Application Support/REDDY; the settings are the preferences of app.streamsetu.mac. Provider logins kept in the Keychain are not touched.
set -euo pipefail
APP="/Applications/StreamSetu.app"; DOMAIN="app.streamsetu.mac"
DATA="$HOME/Library/Application Support/REDDY"
SAVE="${STREAMSETU_FRESH_BACKUP:-$HOME/Library/Application Support/StreamSetu-data-aside}"   # in Library, never in Documents (which can sync to iCloud): it holds logins
LOGS_ACCEPTED=0; for a in "$@"; do [ "$a" = "--logs-accepted" ] && LOGS_ACCEPTED=1; done
accept_logs() { [ "$LOGS_ACCEPTED" = 1 ] && { defaults write "$DOMAIN" diagnostics.share -bool true; defaults write "$DOMAIN" diagnostics.noticeShown -bool true; echo "  the Share Logs notice starts as accepted."; } || true; }
quit_app() {
  pgrep -x StreamSetu >/dev/null 2>&1 || return 0
  osascript -e 'tell application "StreamSetu" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do pgrep -x StreamSetu >/dev/null 2>&1 || return 0; sleep 0.25; done
  echo "✘ StreamSetu did not quit; nothing was changed."; exit 1
}
if [ "${1:-}" = "--restore" ]; then
  [ -d "$SAVE/REDDY" ] || { echo "✘ nothing to restore: $SAVE/REDDY does not exist."; exit 1; }
  quit_app
  rm -rf "$DATA"; mv "$SAVE/REDDY" "$DATA"
  defaults delete "$DOMAIN" >/dev/null 2>&1 || true
  [ -f "$SAVE/settings.plist" ] && defaults import "$DOMAIN" "$SAVE/settings.plist"
  rm -f "$SAVE/settings.plist"; rmdir "$SAVE" 2>/dev/null || true
  echo "✔ your data and settings are back."; open -a "$APP"; exit 0
fi
if [ "${1:-}" = "--again" ]; then
  [ -d "$SAVE/REDDY" ] || { echo "✘ nothing is set aside, so --again would delete your real data. Run without options first."; exit 1; }
  quit_app
  rm -rf "$DATA"                                # only what the fresh run made: the real data is in $SAVE
  defaults delete "$DOMAIN" >/dev/null 2>&1 || true
  accept_logs
  echo "✔ cleared the fresh run (your data is still safe in $SAVE). Launching as a new install again."
  open -a "$APP"; exit 0
fi
[ ! -d "$SAVE/REDDY" ] || { echo "✘ $SAVE/REDDY already holds data set aside. Run with --restore first (so nothing is overwritten)."; exit 1; }
[ -d "$DATA" ] || { echo "✘ $DATA does not exist: the app is already fresh."; exit 1; }
quit_app
mkdir -p "$SAVE"
defaults export "$DOMAIN" "$SAVE/settings.plist"
mv "$DATA" "$SAVE/REDDY"                      # the same disk: an instant rename, nothing is copied or deleted
defaults delete "$DOMAIN" >/dev/null 2>&1 || true
accept_logs
echo "✔ set aside in $SAVE. Launching StreamSetu as a new install."
echo "  Put everything back with:  Scripts/dev/mac-fresh-launch.sh --restore"
open -a "$APP"
