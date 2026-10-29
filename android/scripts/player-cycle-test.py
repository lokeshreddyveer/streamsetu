#!/usr/bin/env python3
"""
Opens and closes the fullscreen player from Live TV 20 times on a connected device and checks, from the app's own test log:

  * how long each open takes (OK pressed -> player on screen -> picture surface attached -> remote given to the player -> picture playing),
  * how long each close takes (Back pressed -> overlay gone -> remote back on a channel),
  * the remote returns to the exact channel it left,
  * ExoPlayer is never rebuilt while cycling ("player rebuilt" is not logged),
  * the stream is never stopped or restarted (the same channel keeps playing),
  * the number of Views in the app does not grow from cycle to cycle (a leaked video parent would show here).

Usage:  scripts/player-cycle-test.py <adb-serial> [cycles]        (release build installed, screen on, a library with live channels open)
Exit status is non-zero if a check fails. The app only writes the test log when the device has been told `setprop log.tag.SSTRACE VERBOSE`, which this script does.
"""
import re, subprocess, sys, threading, time, statistics as st

if len(sys.argv) < 2: sys.exit("usage: player-cycle-test.py <adb serial, e.g. host:5555> [cycles]")
D = sys.argv[1]
CYCLES = int(sys.argv[2]) if len(sys.argv) > 2 else 20
PKG = "app.streamsetu.tv"
KEY = dict(UP=19, DOWN=20, LEFT=21, RIGHT=22, OK=23, BACK=4)

def adb(*a, t=60):
    return subprocess.run(["adb", "-s", D] + list(a), capture_output=True, text=True, timeout=t).stdout

LOCK = threading.Lock()
EV = []                      # (kind, device ms, payload)
STATE = {}
def reader():
    p = subprocess.Popen(["adb", "-s", D, "logcat", "-v", "epoch", "-s", "SSTRACE:V", "Playback:I"], stdout=subprocess.PIPE, text=True, bufsize=1)
    for line in p.stdout:
        m = re.search(r"SSTRACE\s*: (.*)$", line)
        if m:
            msg = m.group(1)
            now = re.search(r"now=(\d+)", msg)
            t = int(now.group(1)) if now else 0
            with LOCK:
                if msg.startswith("state "):
                    kv = dict(x.split("=", 1) for x in msg[6:].split())
                    STATE.update(kv); EV.append(("state", t, dict(kv)))
                elif msg.startswith("focus l="):
                    kv = dict(x.split("=", 1) for x in msg[6:].split())
                    EV.append(("focus", t, (int(kv["l"]), int(kv["t"]), int(kv["r"]), int(kv["b"]))))
                elif msg.startswith("key "):
                    kv = dict(x.split("=", 1) for x in msg.split()[2:])
                    EV.append(("key", int(kv["ev"]), int(msg.split()[1])))
                else:
                    EV.append(("mark", t, msg.split(" now=")[0]))
        elif "player rebuilt" in line or "pacing:" in line or ("start " in line and "Playback" in line):
            with LOCK: EV.append(("playback", 0, line.strip()[-120:]))

def press(name, gap=0.25):
    adb("shell", "input keyevent %d" % KEY[name]); time.sleep(gap)

def wait(pred, timeout=8.0):
    end = time.time() + timeout
    while time.time() < end:
        with LOCK:
            r = pred()
        if r is not None and r is not False: return r
        time.sleep(0.02)
    return None

def back_out(limit=3):
    """Back until the player is gone. The first Back may only hide the controls."""
    for _ in range(limit):
        press("BACK", 0.0)
        if wait(lambda: STATE.get("overlay") == "none" or None, 2.0): return True
    return False

def memory():
    """The app's total memory (PSS, MB) and what the whole device still has free (MB), so a steady climb from cycle to cycle shows up."""
    out = adb("shell", "dumpsys meminfo %s" % PKG)
    m = re.search(r"TOTAL PSS:\s+(\d+)", out) or re.search(r"TOTAL\s+(\d+)", out)
    a = re.search(r"MemAvailable:\s+(\d+)", adb("shell", "cat /proc/meminfo"))
    return (int(m.group(1)) // 1024 if m else -1), (int(a.group(1)) // 1024 if a else -1)

def views():
    out = adb("shell", "dumpsys meminfo %s" % PKG)
    m = re.search(r"Views:\s+(\d+)", out)
    return int(m.group(1)) if m else -1

def last_focus():
    with LOCK:
        for e in reversed(EV):
            if e[0] == "focus": return e[2]
    return None

def main():
    threading.Thread(target=reader, daemon=True).start()
    import atexit; atexit.register(lambda: subprocess.run(['pkill', '-f', 'adb -s %s logcat' % D]))
    adb("shell", "setprop log.tag.SSTRACE VERBOSE"); adb("shell", "input keyevent 224"); adb("shell", "am force-stop " + PKG); time.sleep(1)
    adb("shell", "am start -n %s/.MainActivity" % PKG)
    # The library chooser opens the last library with UP then OK; the log's first "state" line says the library is open.
    if not wait(lambda: STATE.get("tab") or None, 15):
        press("UP", 0.3); press("OK", 0.3)
        if not wait(lambda: STATE.get("tab") or None, 25): print("FAIL the library did not open"); return 1

    # A release build shortens class names, so "an overlay is open" (not its name) means the fullscreen player here.
    # Live TV from the sidebar: Left until the sidebar has the remote (Back where Left does not reach it), then Live TV is the second entry.
    for i in range(8):
        if STATE.get("sidebarFocused") == "true": break
        press("BACK" if i >= 2 and STATE.get("sidebarFocused") != "true" else "LEFT", 0.3)
    for _ in range(9): press("UP", 0.1)
    press("DOWN", 0.15); press("OK", 1.5)
    if not wait(lambda: STATE.get("tab") == "LIVE" or None, 10): print("FAIL could not open Live TV, state:", dict(STATE)); return 1
    press("RIGHT", 0.4); press("OK", 4.0)               # the channel list, then play the channel under the remote
    press("OK", 0.1)                                    # OK on the playing channel opens fullscreen
    if not wait(lambda: (STATE.get("overlay") not in (None, "none")) or None, 10): print("FAIL fullscreen did not open, state:", dict(STATE)); return 1
    time.sleep(2.0)
    if not back_out(): print("FAIL could not return from fullscreen"); return 1
    time.sleep(1.0)
    baseline = last_focus(); v0 = views()
    with LOCK: EV.clear()
    opens, closes, back_ok, bad = [], [], 0, []
    for i in range(1, CYCLES + 1):
        n0 = len(EV)
        press("OK", 0.0)
        key = wait(lambda: next((e for e in EV[n0:] if e[0] == "key"), None), 3)
        opened = wait(lambda: next((e for e in EV[n0:] if e[0] == "state" and e[2].get("overlay") not in (None, "none")), None), 6)
        attached = wait(lambda: next((e for e in EV[n0:] if e[0] == "mark" and e[2] == "surface attached"), None), 6)
        focus = wait(lambda: next((e for e in EV[n0:] if e[0] == "mark" and e[2] == "player focus"), None), 6)
        playing = wait(lambda: next((e for e in EV[n0:] if e[0] == "mark" and e[2] == "player playing"), None), 6)
        if not (key and opened):
            bad.append("cycle %d: the player did not open" % i); press("BACK", 1.0); continue
        t0 = key[1]
        row = "open %4s ms | surface %4s | focus %4s | playing %4s" % (opened[1] - t0, (attached[1] - t0) if attached else "-", (focus[1] - t0) if focus else "-", (playing[1] - t0) if playing else "-")
        opens.append(opened[1] - t0)
        time.sleep(1.2)
        # The first Back may only hide the controls, so the close time is taken from the Back that leaves the player.
        press("BACK", 0.5)
        if STATE.get("overlay") == "none": m0 = len(EV) - 1; bkey = None; closed = next((e for e in EV[m0:] if e[0] == "state" and e[2].get("overlay") == "none"), None)
        else:
            m0 = len(EV); press("BACK", 0.0)
            bkey = wait(lambda: next((e for e in EV[m0:] if e[0] == "key"), None), 3)
            closed = wait(lambda: next((e for e in EV[m0:] if e[0] == "state" and e[2].get("overlay") == "none"), None), 5)
        time.sleep(0.8)
        f = last_focus()
        if bkey and closed: closes.append(closed[1] - bkey[1])
        same = baseline is not None and f == baseline
        back_ok += 1 if same else 0
        if not same: bad.append("cycle %d: the remote came back to %s, not %s" % (i, f, baseline))
        pss, avail = memory()
        print("cycle %2d | app %d MB, device free %d MB | %s | close %s ms | focus %s" % (i, pss, avail, row, (closed[1] - bkey[1]) if (bkey and closed) else "-", "same channel" if same else "DIFFERENT"), flush=True)
        time.sleep(0.5)
    v1 = views()
    with LOCK:
        rebuilt = [e for e in EV if e[0] == "playback" and "player rebuilt" in e[2]]
        restarted = [e for e in EV if e[0] == "playback" and " start " in e[2]]
    print()
    if opens: print("open  ms: median %d, worst %d" % (st.median(opens), max(opens)))
    if closes: print("close ms: median %d, worst %d" % (st.median(closes), max(closes)))
    print("focus returned to the same channel: %d of %d" % (back_ok, CYCLES))
    print("ExoPlayer rebuilt during the cycles: %d" % len(rebuilt))
    print("streams started during the cycles: %d (should be 0: the channel keeps playing)" % len(restarted))
    print("Views in the app: %d before, %d after (a leak shows as steady growth)" % (v0, v1))
    fails = list(bad)
    if rebuilt: fails.append("ExoPlayer was rebuilt")
    if restarted: fails.append("the stream was restarted")
    if v0 > 0 and v1 > v0 + 40: fails.append("the number of Views grew by %d" % (v1 - v0))
    for f in fails: print("FAIL", f)
    print("RESULT", "FAIL" if fails else "PASS")
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())
