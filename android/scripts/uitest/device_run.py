#!/usr/bin/env python3
"""The device measurements for the entry path, in one go. usage: device_run.py SERIAL
 1. Movies and Series from the main sidebar, cold (app already running, never opened) and warm, three runs each (entry_measure.py)
 2. Five same-key returns to Movies: statements counted only after the key
 3. Folder A -> B -> A on Movies: key -> page published, statements after the key
 4. The write probe (an interactive write while a catalog-sized transaction runs)"""
import os, re, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_suite as R, tvtest as T
S = sys.argv[1]; HERE = os.path.dirname(os.path.abspath(__file__))
def adb(*a): return subprocess.run([T.ADB, "-s", S, *a], capture_output=True, text=True).stdout
def mem(): return adb("shell", "grep -E 'MemAvailable|SwapFree' /proc/meminfo").replace("\n", " ").strip()
def entry(kind, mode):
    adb("shell", f"am force-stop {T.PKG}")
    print(subprocess.run([sys.executable, "-u", os.path.join(HERE, "entry_measure.py"), S, kind, mode, "final"], capture_output=True, text=True, env=dict(os.environ, PKG=T.PKG)).stdout.strip()); sys.stdout.flush()
print("##### 1. entry from the main sidebar")
for kind in ("Movies", "Series"):
    for i in range(3): entry(kind, "cold")


print("\n##### 2 and 3. same-key returns and folder A -> B -> A (one session)")
adb("shell", f"am force-stop {T.PKG}")
su = R.Suite(S, "/tmp/dr_out"); d = su.d; d.start_log(); d.start_injector()
su.ensure_app(); su.enter_library(); su.open_rail(); time.sleep(8)
def window(label, action, wait=3.0):
    adb("logcat", "-c"); adb("shell", f"log -t MARK {label}"); action(); time.sleep(wait)
    raw = adb("logcat", "-d", "-v", "epoch", "-s", "MARK", "Entry", "SQL"); rows = []
    for l in raw.splitlines():
        m = re.match(r"\s*(\d+\.\d+)\s+\d+\s+\d+\s+\w\s+(\w+)\s*:\s*(.*)", l)
        if m: rows.append((float(m[1]), m[2], m[3]))
    t0 = next((r[0] for r in rows if r[1] == "MARK"), None)
    sql = [r for r in rows if r[1] == "SQL"]; ent = [(round((r[0] - t0) * 1000), r[2]) for r in rows if r[1] == "Entry"] if t0 else []
    print(f"  {label:34} SQL after the key: {len(sql):3} | " + " | ".join(f"+{t} ms {m[:42]}" for t, m in ent)); sys.stdout.flush()
for kind in ("Movies", "Series"):
    su.goto(kind); time.sleep(3); su.goto("Home"); time.sleep(3)          # opened once, so every entry below is a return
    for i in range(5):
        su.open_rail(); s_ = su.dump(); menu = su.rail_order(s_)
        cur = next((j for j, n in enumerate(menu) if s_["focus"] and n in s_["focus"][0]["text"]), 0); want = menu.index(kind)
        for _ in range(abs(want - cur)): d.key("DOWN" if want > cur else "UP"); d.settle(d.mark(), quiet=0.15, timeout=5)
        time.sleep(1.0)
        window(f"same-key return {i + 1} ({kind})", lambda: d.key("OK"), wait=2.2)
        time.sleep(1.0); su.goto("Home"); time.sleep(1.5)
# folders: the folder panel is open on entry; move down to a folder, OK, then back to the first and OK
su.goto("Movies"); time.sleep(3)
for step, keys in (("folder B (down 3, OK)", ["DOWN"] * 3), ("back to folder A (Left, up 3, OK)", None)):
    pass
def pick(downs, label):
    if label.startswith("folder A") or label.startswith("back"): d.key("LEFT"); d.settle(d.mark(), quiet=0.3, timeout=5)
    for _ in range(downs[0]): d.key("DOWN"); d.settle(d.mark(), quiet=0.15, timeout=5)
    for _ in range(downs[1]): d.key("UP"); d.settle(d.mark(), quiet=0.15, timeout=5)
    time.sleep(0.5); window(label, lambda: d.key("OK"))
d.key("LEFT"); d.settle(d.mark(), quiet=0.3, timeout=5); time.sleep(1)
for _ in range(6): d.key("DOWN"); d.settle(d.mark(), quiet=0.15, timeout=5)
time.sleep(0.5); window("folder A -> B (OK on 6th row)", lambda: d.key("OK")); time.sleep(1.0)
d.key("LEFT"); d.settle(d.mark(), quiet=0.3, timeout=5); time.sleep(1)
for _ in range(3): d.key("UP"); d.settle(d.mark(), quiet=0.15, timeout=5)
time.sleep(0.5); window("folder B -> C (OK on 3rd row)", lambda: d.key("OK")); time.sleep(1.0)
d.key("LEFT"); d.settle(d.mark(), quiet=0.3, timeout=5); time.sleep(1)
for _ in range(3): d.key("DOWN"); d.settle(d.mark(), quiet=0.15, timeout=5)
time.sleep(0.5); window("folder C -> B again (OK on 6th row)", lambda: d.key("OK"))
print("  memory:", mem())


print("\n##### 4. write probe")
adb("logcat", "-c"); adb("shell", f"am broadcast -a app.streamsetu.tv.benchmark.PROBE_WRITES -p {T.PKG}"); time.sleep(25)
print(adb("logcat", "-d", "-s", "WriteProbe").replace("\n", "\n  ").strip()[:2600])
print("  memory:", mem())
