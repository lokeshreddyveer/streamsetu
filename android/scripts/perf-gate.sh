#!/bin/bash
# Measures the release build on a connected device against the targets below and exits non-zero if one is missed.
# Usage: scripts/perf-gate.sh [adb-serial]      (the app must be installed; the screen must be on)
S=${1:-192.168.1.68:5555}; PKG=app.streamsetu.tv; ACT=$PKG/.MainActivity
adb() { command adb -s "$S" "$@"; }
fail=0
check() { # name value limit
  if [ "$2" -le "$3" ]; then echo "PASS $1: $2 ms (limit $3)"; else echo "FAIL $1: $2 ms (limit $3)"; fail=1; fi
}
launch_ms() { adb shell am start -W -n $ACT | awk '/TotalTime/ {print $2}'; }

adb shell am force-stop $PKG; sleep 2
check "cold launch (to first frame)" "$(launch_ms)" 1800
sleep 6
adb shell input keyevent 3; sleep 2          # Home: the app goes to the background
check "warm launch (to first frame)" "$(launch_ms)" 700

# Frames while moving through the screen with the remote (key repeats, 40 presses), from the system's own frame statistics.
adb shell dumpsys gfxinfo $PKG reset >/dev/null
adb shell "for i in \$(seq 1 10); do input keyevent 20; input keyevent 20; input keyevent 19; input keyevent 22; done"; sleep 1
G=$(adb shell dumpsys gfxinfo $PKG)
echo "$G" | grep -E "Total frames rendered|Janky frames|90th percentile|99th percentile"
J=$(echo "$G" | awk -F'[ (]' '/Janky frames:/ {print $3}'); T=$(echo "$G" | awk '/Total frames rendered/ {print $4}')
[ -n "$T" ] && [ "$T" -gt 0 ] && echo "jank: $J of $T frames"
exit $fail
