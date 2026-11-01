#!/usr/bin/env python3
"""Per-frame phase times (dumpsys gfxinfo framestats) for one action: which part of the frame is slow. Usage: trace_frames.py SERIAL what   (what = movies_ok | guide_down | live_moves | stats_down)"""
import os, sys, statistics, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_suite as R, tvtest as T
serial, what = sys.argv[1], sys.argv[2]
su = R.Suite(serial, "/tmp/trace_out"); d = su.d; d.start_log(); d.start_injector()
su.ensure_app(); su.enter_library(); su.open_rail()

def frames():
    t = d.sh(f"dumpsys gfxinfo {T.PKG} framestats")
    rows = []
    for l in t.splitlines():
        p = l.strip().split(",")
        if len(p) >= 17 and p[0].isdigit() and p[0] in ("0", "1"):
            try: rows.append([int(x) for x in p[:17]])
            except ValueError: pass
    return rows

def report(label):
    fr = frames(); print(f"\n== {label}: {len(fr)} frames")
    if not fr: return
    ms = lambda a, b: [(r[b] - r[a]) / 1e6 for r in fr if r[a] and r[b] and r[b] >= r[a]]
    phases = [("input->animation start", 5, 6), ("animation callbacks", 6, 7), ("measure+layout", 7, 8), ("draw record", 8, 9), ("sync/upload", 10, 11), ("issue draw cmds", 11, 12), ("swap buffers", 12, 13), ("total (vsync->completed)", 1, 13), ("GPU done", 1, 16)]
    t0 = fr[0][1]; buckets = {}
    for r in fr: buckets.setdefault(int((r[1] - t0) / 1e8), []).append((r[13] - r[1]) / 1e6)
    print("  per 100 ms: " + "  ".join(f"{k * 100}:{len(v)}f/{sum(v) / len(v):.0f}ms" for k, v in sorted(buckets.items())))
    for r in sorted(fr, key=lambda r: r[13] - r[1], reverse=True)[:3]:
        g = lambda a, b: (r[b] - r[a]) / 1e6 if r[a] and r[b] and r[b] >= r[a] else 0
        print(f"  worst frame at +{(r[1] - t0) / 1e6:.0f} ms: total {g(1, 13):.0f} | input->vsync wait {g(1, 5):.0f} | handle input {g(5, 6):.0f} | animation {g(6, 7):.0f} | measure/layout {g(7, 8):.0f} | draw record {g(8, 9):.0f} | sync {g(10, 11):.0f} | issue {g(11, 12):.0f} | swap {g(12, 13):.0f} | GPU done at {g(1, 16):.0f}")
    tot = [(r[13] - r[1]) / 1e6 for r in fr]; slow = [r for r in fr if (r[13] - r[1]) / 1e6 > 16.7]
    print(f"  total frame ms: median {statistics.median(tot):.1f}  p95 {sorted(tot)[int(len(tot) * .95) - 1]:.1f}  worst {max(tot):.1f}   slow (>16.7): {len(slow)}")
    for name, a, b in phases:
        v = ms(a, b); sv = [(r[b] - r[a]) / 1e6 for r in slow if r[a] and r[b] and r[b] >= r[a]]
        if v: print(f"  {name:26} all: median {statistics.median(v):6.1f}  worst {max(v):6.1f}   slow frames: median {statistics.median(sv) if sv else 0:6.1f}  worst {max(sv) if sv else 0:6.1f}")

def to_page(name):
    ok, _, scr = su.goto(name); d.wait_for(lambda: len(d.focused) >= 1, 6); su.restore(name); return ok

if what == "movies_ok":
    to_page("Movies")
    if any(f["b"][0] < 100 and f["b"][3] - f["b"][1] < 150 for f in su.dump()["focus"][:1]): d.key("RIGHT"); d.settle(d.mark(), quiet=0.25, timeout=6)
    for n in range(10):
        s = su.dump(); f = s["focus"][0] if s["focus"] else None
        if f and 150 < f["b"][2] - f["b"][0] < 320 and f["b"][3] - f["b"][1] > 200: break
        d.seq(["DOWN"] * (3 if n == 0 else 2), 120); d.settle(d.mark(), quiet=0.2, timeout=5)
    time.sleep(1.5); d.sh(f"dumpsys gfxinfo {T.PKG} reset"); d.key("OK"); time.sleep(1.8); report("Movies: OK on a poster (1.8 s)")
elif what == "movies_idle":
    to_page("Movies")
    if any(f["b"][0] < 100 and f["b"][3] - f["b"][1] < 150 for f in su.dump()["focus"][:1]): d.key("RIGHT"); d.settle(d.mark(), quiet=0.25, timeout=6)
    for n in range(10):
        s = su.dump(); f = s["focus"][0] if s["focus"] else None
        if f and 150 < f["b"][2] - f["b"][0] < 320 and f["b"][3] - f["b"][1] > 200: break
        d.seq(["DOWN"] * (3 if n == 0 else 2), 120); d.settle(d.mark(), quiet=0.2, timeout=5)
    d.key("OK"); time.sleep(4); d.sh(f"dumpsys gfxinfo {T.PKG} reset"); time.sleep(2); report("Movies detail, untouched for 2 s (idle)")
    d.sh(f"dumpsys gfxinfo {T.PKG} reset"); d.hold("DOWN", 1500, 30); time.sleep(0.6); report("Movies detail, held Down 1.5 s")
elif what == "guide_down":
    to_page("TV Guide"); time.sleep(1); d.sh(f"dumpsys gfxinfo {T.PKG} reset"); d.hold("DOWN", 2000, 30); time.sleep(0.6); report("TV Guide: held Down 2 s")
elif what == "live_moves":
    to_page("Live TV"); time.sleep(1); d.sh(f"dumpsys gfxinfo {T.PKG} reset")
    for k in ["DOWN", "DOWN", "UP", "RIGHT", "RIGHT", "LEFT", "DOWN", "UP", "DOWN", "UP"]: d.key(k); d.settle(d.mark(), quiet=0.15, timeout=6)
    time.sleep(0.4); report("Live TV: settled moves")
elif what == "tabs":
    to_page("Home"); time.sleep(1)
    for name in ["Movies", "Live TV", "Settings", "Home", "Movies", "Search"]:
        d.sh(f"dumpsys gfxinfo {T.PKG} reset"); ok, secs, _ = su.goto(name); time.sleep(0.8); report(f"switch to {name} (interactive after {secs:.1f} s, polled)")
elif what == "settings_moves":
    to_page("Settings"); time.sleep(1); d.sh(f"dumpsys gfxinfo {T.PKG} reset")
    for k in ["DOWN"] * 8 + ["UP"] * 8: d.key(k); d.settle(d.mark(), quiet=0.15, timeout=6)
    time.sleep(0.5); report("Settings: 16 category moves")
elif what == "folders":
    to_page("Movies"); time.sleep(1); d.sh(f"dumpsys gfxinfo {T.PKG} reset")
    d.key("LEFT"); d.settle(d.mark(), quiet=0.3, timeout=5)
    for k in ["DOWN"] * 6 + ["UP"] * 6: d.key(k); d.settle(d.mark(), quiet=0.15, timeout=6)
    time.sleep(0.5); report("Movies folder panel: 12 folder moves")
elif what == "folders_raw":
    to_page("Movies"); time.sleep(1.5)
    d.key("LEFT"); d.settle(d.mark(), quiet=0.3, timeout=5)
    time.sleep(1.0); d.sh(f"dumpsys gfxinfo {T.PKG} reset")          # the folders are open and settled; only the moves are measured
    mk = d.mark(); sent = 0
    for k in ["DOWN"] * 6 + ["UP"] * 6: sent += len(d.key(k)); d.settle(d.mark(), quiet=0.15, timeout=6)
    time.sleep(0.5)
    ev = d.since(mk); foc = [e[2] for e in ev if e[2].startswith("focus l=")]
    print("MOVES", f"keys_sent={sent} focus_events={len(foc)} distinct_places={len(set(foc))}")
    for r in frames():
        ui = (r[6] - r[5] + r[7] - r[6] + r[8] - r[7] + r[9] - r[8]) / 1e6 if r[5] and r[9] else 0.0          # animation + measure/layout + draw record
        rt = (r[12] - r[10]) / 1e6 if r[10] and r[12] else 0.0                                                 # sync + issue draw commands + swap
        print("ROW", f"{ui:.2f} {rt:.2f} {(r[16] - r[1]) / 1e6 if r[16] else 0.0:.2f} {(r[13] - r[1]) / 1e6:.2f}")
elif what == "folder_open":
    to_page("Movies"); time.sleep(1.5); d.sh(f"dumpsys gfxinfo {T.PKG} reset")
    d.key("LEFT"); time.sleep(1.4)
    g = d.gfx(); gt = d.sh(f"dumpsys gfxinfo {T.PKG}")          # the GPU's own time per frame (what the GPU spent, not how far behind the display it is)
    import re as _re
    gp = {p_: (_re.search(p_ + r"th gpu percentile: (\d+)ms", gt) or [None, "-"])[1] for p_ in ("50", "90", "95", "99")}
    print("GPUPCT", gp["50"], gp["90"], gp["95"], gp["99"])
    fr_ = sorted(frames(), key=lambda r: r[13])          # how the frames were actually put on screen: the gap between one frame completing and the next (a 16.7 ms gap is a smooth refresh)
    gaps = [(b[13] - a_[13]) / 1e6 for a_, b in zip(fr_, fr_[1:])]
    print("GAPS", " ".join(f"{g_:.1f}" for g_ in gaps))
    for r in frames():
        ui = (r[6] - r[5] + r[7] - r[6] + r[8] - r[7] + r[9] - r[8]) / 1e6 if r[5] and r[9] else 0.0
        rt = (r[12] - r[10]) / 1e6 if r[10] and r[12] else 0.0
        print("ROW", f"{ui:.2f} {rt:.2f} {(r[16] - r[1]) / 1e6 if r[16] else 0.0:.2f} {(r[13] - r[1]) / 1e6:.2f}")
elif what.startswith("wf_"):
    import statistics as _st
    def _gaps():
        fr_ = sorted(frames(), key=lambda r: r[13]); g = [(b[13] - a_[13]) / 1e6 for a_, b in zip(fr_, fr_[1:])]
        for r in sorted(fr_, key=lambda r: r[13] - r[1], reverse=True)[:3]:
            gg = lambda a, b: (r[b] - r[a]) / 1e6 if r[a] and r[b] and r[b] >= r[a] else 0
            print("WFWORST", f"+{(r[1] - fr_[0][1]) / 1e6:.0f} ms: total {gg(1, 13):.0f} | wait before frame {gg(1, 5):.0f} | animation(compose) {gg(6, 7):.0f} | measure/layout {gg(7, 8):.0f} | draw record {gg(8, 9):.0f} | sync {gg(10, 11):.0f} | issue {gg(11, 12):.0f} | swap {gg(12, 13):.0f}")
        print("WF", what, f"{len(fr_)} frames | gaps median {(_st.median(g) if g else 0):.1f} max {(max(g) if g else 0):.1f} | skipped refreshes {sum(max(0, round(x / 16.67) - 1) for x in g)} | gaps", " ".join(f"{x:.0f}" for x in g))
    if what == "wf_sidebar_warm":
        to_page("Movies"); time.sleep(6); su.goto("Home"); time.sleep(6)           # Movies has been opened once and the app has been up a while: this is the second time
    if what in ("wf_sidebar", "wf_sidebar_warm"):
        su.open_rail(); s_ = su.dump(); menu = su.rail_order(s_); cur = next((i for i, n in enumerate(menu) if s_["focus"] and n in s_["focus"][0]["text"]), 0); want = menu.index("Movies")
        for _ in range(abs(want - cur)): d.key("DOWN" if want > cur else "UP"); d.settle(d.mark(), quiet=0.15, timeout=5)
        time.sleep(1.2); d.sh(f"dumpsys gfxinfo {T.PKG} reset"); d.key("OK"); time.sleep(1.6); _gaps()
    else:
        to_page("Movies"); time.sleep(1.5)
        if what == "wf_back": d.key("RIGHT"); d.settle(d.mark(), quiet=0.3, timeout=5)           # into the content with the folder list closed (when it was open)
        time.sleep(0.8); d.sh(f"dumpsys gfxinfo {T.PKG} reset")
        if what == "wf_noop": d.send("tap 0")
        elif what == "wf_back": d.key("BACK")
        else: d.key("LEFT")
        time.sleep(1.6); _gaps()
elif what == "stats_down":
    to_page("Settings")
    if su.tap("Statistics"):
        time.sleep(1.2); d.sh(f"dumpsys gfxinfo {T.PKG} reset"); d.hold("DOWN", 1500, 30); time.sleep(0.6); report("Statistics: held Down 1.5 s")
