#!/usr/bin/env python3
"""Entry path of Movies/Series from the main sidebar. usage: entry_measure.py SERIAL KIND(Movies|Series) MODE(cold|warm) LABEL
cold: the app is restarted, Movies/Series has not been opened. warm: it has been opened once, left for Home, and the app has been up a while.
Writes a device log marker, presses OK once on the entry, then reads what the app logged for the next 4 s: the entry timeline (Entry), every SQL statement (SQL), and memory and swap before the run."""
import os, re, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_suite as R, tvtest as T
S, kind, mode, label = sys.argv[1:5]
def adb(*a): return subprocess.run([T.ADB, "-s", S, *a], capture_output=True, text=True).stdout
mem = adb("shell", "grep -E 'MemAvailable|SwapFree' /proc/meminfo").replace("\n", " ")
su = R.Suite(S, "/tmp/entry_out"); d = su.d; d.start_log(); d.start_injector()
su.ensure_app(); su.enter_library(); su.open_rail()
if mode == "cold": time.sleep(7)          # the app is already running: its start-up work (profile tables, first reads) is over before the key is pressed
if mode == "warm":
    su.goto(kind); time.sleep(4); su.goto("Home"); time.sleep(4)
su.open_rail(); s_ = su.dump(); menu = su.rail_order(s_); cur = next((i for i, n in enumerate(menu) if s_["focus"] and n in s_["focus"][0]["text"]), 0); want = menu.index(kind)
for _ in range(abs(want - cur)): d.key("DOWN" if want > cur else "UP"); d.settle(d.mark(), quiet=0.15, timeout=5)
time.sleep(1.5)
adb("logcat", "-c"); adb("shell", f"dumpsys gfxinfo {T.PKG} reset"); adb("shell", "log -t MARK pressing-OK"); d.key("OK"); time.sleep(3.5)
fs = adb("shell", f"dumpsys gfxinfo {T.PKG} framestats")
raw = adb("logcat", "-d", "-v", "epoch", "-s", "MARK", "Entry", "SQL")
rows = []
for l in raw.splitlines():
    m = re.match(r"\s*(\d+\.\d+)\s+\d+\s+(\d+)\s+\w\s+(\w+)\s*:\s*(.*)", l)
    if m: rows.append((float(m[1]), int(m[2]), m[3], m[4]))
t0 = next((r[0] for r in rows if r[2] == "MARK"), None)
print(f"== {label}: {kind} {mode} | before: {mem.strip()}")
if t0 is None: print("  no marker"); sys.exit()
first_draw = next((r[0] for r in rows if r[2] == "Entry" and "first page drawn" in r[3]), None)
for r in rows:
    if r[2] == "Entry": print(f"  +{(r[0] - t0) * 1000:6.0f} ms  {r[3]}")
sql = [r for r in rows if r[2] == "SQL"]
before = [r for r in sql if first_draw is None or r[0] <= first_draw]; after = [r for r in sql if first_draw is not None and r[0] > first_draw]
print(f"  SQL statements: {len(sql)} in total | {len(before)} before the first page was drawn | {len(after)} after")
def tag(q):
    q = q.strip(); t = re.search(r"FROM (\w+)", q); return (q.split()[0] + " " + (t.group(1) if t else ""))[:34]
from collections import Counter
print("  before first draw:", dict(Counter(tag(r[3]) for r in before)))
print("  after first draw: ", dict(Counter(tag(r[3]) for r in after)))
print(f"  first SQL at +{(sql[0][0] - t0) * 1000:.0f} ms, last at +{(sql[-1][0] - t0) * 1000:.0f} ms" if sql else "  no SQL")
fr = []
for l in fs.splitlines():
    p_ = l.strip().split(",")
    if len(p_) >= 14 and p_[0] == "0":
        try: fr.append((int(p_[13]) - int(p_[1])) / 1e6)
        except ValueError: pass
if fr:
    import statistics as st
    print(f"  frames produced: {len(fr)} | duration median {st.median(fr):.1f} ms, worst {max(fr):.1f} ms, over 16.7 ms: {len([x for x in fr if x > 16.7])}")
print("  after:", adb("shell", "grep -E 'MemAvailable|SwapFree' /proc/meminfo").replace("\n", " ").strip(), "| pid", adb("shell", "pidof app.streamsetu.tv.benchmark").strip())
