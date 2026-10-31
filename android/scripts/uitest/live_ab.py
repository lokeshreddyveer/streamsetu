#!/usr/bin/env python3
"""
A/B of the Live TV screen's frame cost, one thing switched off per configuration (see trace/Diag.kt for the switches).

  live_ab.py [--configs base,INDEXER,ARTWORK,...] [--reps 3] [--warm 35] [--serial ...]

Per configuration: all switches cleared, the one under test set, app restarted, library entered, Live TV opened, then `--warm` seconds are waited (the same for every configuration, so the
cast indexer is in the same state: running, unless it is the one being switched off), the list is warmed by one pass down and up, and then on the folder list and on the channel list:
  20 Down 30 ms apart / held Down 3 s / 10 x (Down, Up) 30 ms apart      each `--reps` times, from the same place
Frames come from the system's own statistics (dumpsys gfxinfo). The 30 ms interval is a stress workload from the system's input injection, not a physical remote.
Key thinning (a held key being thinned by the app) is not counted as an improvement: the number of frames drawn is printed so a configuration that merely drops keys shows up.
"""
import argparse, os, re, statistics, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_suite as R, tvtest as T

FLAGS = ["ARTWORK", "SCALE", "RING", "ONELINE", "META", "PREVIEW", "MARQUEE", "INDEXER"]
LISTS = ("folders", "channels")
WORKLOADS = [("20 Down", dict(keys=["DOWN"] * 20)), ("held Down 3 s", dict(hold=("DOWN", 3000))), ("10 x Down+Up", dict(keys=["DOWN", "UP"] * 10))]


def gfx(d):
    t = d.sh(f"dumpsys gfxinfo {T.PKG}")
    g = lambda rx: (lambda m: float(m[1]) if m else None)(re.search(rx, t))
    return dict(frames=g(r"Total frames rendered: (\d+)"), janky=g(r"Janky frames: (\d+)"), p50=g(r"50th percentile: (\d+)ms"), p90=g(r"90th percentile: (\d+)ms"), p95=g(r"95th percentile: (\d+)ms"), p99=g(r"99th percentile: (\d+)ms"))


def run_workload(d, w):
    name, kw = w
    d.sh(f"dumpsys gfxinfo {T.PKG} reset")
    if "hold" in kw: d.hold(kw["hold"][0], kw["hold"][1], 30)
    else: d.seq(kw["keys"], 30)
    time.sleep(1.0); return gfx(d)


def settle_top(d):
    d.seq(["UP"] * 30, 40); time.sleep(1.2)          # back to the top of whichever list has focus


def med(xs): xs = [x for x in xs if x is not None]; return statistics.median(xs) if xs else float("nan")


def measure(S, d, label, reps):
    out = {}
    for lst in LISTS:
        if lst == "channels":
            # settle_top leaves the remote on the buttons above the folders, where Right goes to the next button: step down to a folder row first
            d.seq(["DOWN"] * 5, 250); time.sleep(0.8)
            d.key("RIGHT")
            wide = lambda: (lambda f: bool(f) and (f[0]["b"][2] - f[0]["b"][0]) > 400 and (f[0]["b"][3] - f[0]["b"][1]) > 90)(S.dump()["focus"])          # a channel row is 456 x 114 px; a folder row 312 x 86
            if not d.wait_for(wide, 8): print("   (focus did not reach the channel list; skipping)"); continue
            time.sleep(0.5)
        # warm: one pass down and up so images and rows are composed and cached
        d.seq(["DOWN"] * 12, 60); time.sleep(0.6); d.seq(["UP"] * 12, 60); time.sleep(0.8)
        for w in WORKLOADS:
            runs = []
            for _ in range(reps):
                settle_top(d); runs.append(run_workload(d, w))
            fr = med([r["frames"] for r in runs]); jk = med([r["janky"] for r in runs])
            out[(lst, w[0])] = dict(frames=fr, jank_pct=100 * jk / fr if fr else float("nan"), p50=med([r["p50"] for r in runs]), p90=med([r["p90"] for r in runs]), p95=med([r["p95"] for r in runs]), p99=med([r["p99"] for r in runs]))
            o = out[(lst, w[0])]
            print(f"   {label:9} {lst:8} {w[0]:14} frames {o['frames']:5.0f}  janky {o['jank_pct']:3.0f}%  frame ms p50 {o['p50']:4.0f} p90 {o['p90']:4.0f} p95 {o['p95']:4.0f} p99 {o['p99']:4.0f}"); sys.stdout.flush()
        if lst == "folders": d.key("LEFT"); time.sleep(0.8)
    return out


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--serial", default="192.168.1.68:5555"); ap.add_argument("--reps", type=int, default=3); ap.add_argument("--warm", type=float, default=35)
    ap.add_argument("--lists", default="folders,channels"); ap.add_argument("--configs", default="base," + ",".join(FLAGS) + ",ALL"); a = ap.parse_args()
    global LISTS; LISTS = tuple(a.lists.split(","))
    S = R.Suite(a.serial, os.environ.get("TMPDIR", "/tmp") + "/live_ab"); d = S.d; d.sh("setprop log.tag.SSTRACE VERBOSE"); d.start_log(); d.start_injector()
    results = {}
    for cfg in a.configs.split(","):
        on = FLAGS if cfg == "ALL" else ([] if cfg == "base" else [cfg])
        for f in FLAGS: d.sh(f"setprop log.tag.SSDIAG_{f} {'VERBOSE' if f in on else 'INFO'}")
        d.sh(f"am force-stop {T.PKG}"); time.sleep(1.5); d.sh(f"am start -n {T.PKG}/.MainActivity"); d.wait_for(lambda: T.foreground(d), 40)
        print(f"== {cfg}: switched off: {on or 'nothing'}"); sys.stdout.flush()
        if not S.enter_library(): print("   could not enter the library"); continue
        ok, secs, scr = S.goto("Live TV")
        if not ok: print("   Live TV did not open"); continue
        time.sleep(a.warm)
        results[cfg] = measure(S, d, cfg, a.reps)
    print("\n== summary: janky % (frames drawn) on the folder list / the channel list")
    for lst in LISTS:
        for w, _ in WORKLOADS:
            print(f"  {lst:8} {w:14} " + "  ".join(f"{c}:{results[c][(lst, w)]['jank_pct']:.0f}%({results[c][(lst, w)]['frames']:.0f})" for c in results if (lst, w) in results))


if __name__ == "__main__":
    main()
