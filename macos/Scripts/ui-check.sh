#!/bin/bash
# Window-size matrix screenshots of the running StreamSetu window, without fixed sleeps: it resizes, then polls until the window reports the new size
# and the screen has settled, then captures. It refuses to run unless StreamSetu is the frontmost app (so no keystroke or click goes elsewhere).
# Usage: Scripts/ui-check.sh OUTDIR [width ...]      default widths: 1024 1150 1200 1420 1600
set -uo pipefail
OUT="${1:?usage: ui-check.sh OUTDIR [widths]}"; shift
WIDTHS=("$@"); [ ${#WIDTHS[@]} -eq 0 ] && WIDTHS=(1024 1150 1200 1420 1600)
mkdir -p "$OUT"
osascript -e 'tell application "StreamSetu" to activate' >/dev/null 2>&1
front=""
for _ in $(seq 1 50); do
  front=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null)
  [ "$front" = "StreamSetu" ] && break
done
[ "$front" = "StreamSetu" ] || { echo "StreamSetu is not frontmost ($front); aborting so nothing is typed or clicked elsewhere"; exit 2; }
size() { osascript -e 'tell application "System Events" to tell process "StreamSetu" to get size of window 1' 2>/dev/null | tr -d ' '; }
for w in "${WIDTHS[@]}"; do
  osascript -e "tell application \"System Events\" to tell process \"StreamSetu\" to set size of window 1 to {$w, 760}" >/dev/null 2>&1
  for _ in $(seq 1 100); do [ "$(size)" = "$w,760" ] && break; done          # poll: stops as soon as the size is applied
  prev=""; for _ in $(seq 1 40); do                                          # poll the picture until two captures in a row are identical
    screencapture -x "$OUT/.try.png"; cur=$(shasum "$OUT/.try.png" | cut -d' ' -f1)
    [ "$cur" = "$prev" ] && break; prev="$cur"
  done
  mv "$OUT/.try.png" "$OUT/w$w.png"; echo "w$w.png ($(size))"
done
