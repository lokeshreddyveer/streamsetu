#!/usr/bin/env python3
"""Records a system trace around one held direction on a poster grid (Movies or Series), then lists where the main thread and the render thread spend the time.
usage: perfetto_hold.py SERIAL PAGE LABEL     (PAGE: Movies or Series)"""
import os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_suite as R, tvtest as T
S, page, label = sys.argv[1], sys.argv[2], sys.argv[3]; HERE = os.path.dirname(os.path.abspath(__file__))
su = R.Suite(S, "/tmp/pf_out"); d = su.d; d.start_log(); d.start_injector()
su.ensure_app(); su.enter_library(); su.open_rail(); su.goto(page); time.sleep(6)
if any(f["b"][0] < 100 and f["b"][3] - f["b"][1] < 150 for f in su.dump()["focus"][:1]): d.key("RIGHT"); time.sleep(1)
for n in range(10):
    f = (su.dump()["focus"] or [None])[0]
    if f and 150 < f["b"][2] - f["b"][0] < 320 and f["b"][3] - f["b"][1] > 200: break
    d.seq(["DOWN"] * (3 if n == 0 else 2), 120); time.sleep(0.6)
d.seq(["DOWN"] * 8, 150); time.sleep(1.5)          # room above to hold Up through
dev = "/data/misc/perfetto-traces/ss.pftrace"; d.adb("shell", f"rm -f {dev}")
subprocess.run([T.ADB, "-s", S, "shell", f"perfetto --background -c - --txt -o {dev}"], stdin=open(os.path.join(HERE, "perfetto.cfg")), capture_output=True)
time.sleep(1.5)
d.hold("UP", 3000, 30); time.sleep(1.0)
subprocess.run([T.ADB, "-s", S, "shell", "kill -INT $(pidof perfetto)"], capture_output=True); time.sleep(3)
out = os.path.join(HERE, "results", "perfetto", f"{label}.pftrace"); os.makedirs(os.path.dirname(out), exist_ok=True); d.adb("pull", dev, out)
print("saved", out, os.path.getsize(out) if os.path.exists(out) else "missing")
d.sh("pkill -f 'app_process /system/bin Inj'")
