#!/usr/bin/env python3
"""Records a system trace (Perfetto) around one transition: main sidebar -> Movies, on an already-warm app. usage: perfetto_capture.py SERIAL LABEL"""
import os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_suite as R, tvtest as T
S, label = sys.argv[1], sys.argv[2]; HERE = os.path.dirname(os.path.abspath(__file__))
su = R.Suite(S, "/tmp/pf_out"); d = su.d; d.start_log(); d.start_injector()
su.ensure_app(); su.enter_library(); su.open_rail()
su.goto("Movies"); time.sleep(6); su.goto("Home"); time.sleep(5)              # warm: Movies has been open once, the app has been up a while
su.open_rail(); s_ = su.dump(); menu = su.rail_order(s_); cur = next((i for i, n in enumerate(menu) if s_["focus"] and n in s_["focus"][0]["text"]), 0); want = menu.index("Movies")
for _ in range(abs(want - cur)): d.key("DOWN" if want > cur else "UP"); d.settle(d.mark(), quiet=0.15, timeout=5)
time.sleep(1.5)
dev = "/data/misc/perfetto-traces/ss.pftrace"
d.adb("shell", f"rm -f {dev}")
subprocess.run([T.ADB, "-s", S, "shell", f"perfetto --background -c - --txt -o {dev}"], stdin=open(os.path.join(HERE, "perfetto.cfg")), capture_output=True)
time.sleep(1.5)                                  # the trace is running, the sidebar has settled
t_ok = time.time(); d.key("OK"); time.sleep(3.5)
subprocess.run([T.ADB, "-s", S, "shell", "kill -INT $(pidof perfetto)"], capture_output=True); time.sleep(3)
out = os.path.join(HERE, "results", "perfetto", f"{label}.pftrace")
d.adb("pull", dev, out)
print("saved", out, os.path.getsize(out) if os.path.exists(out) else "missing")
