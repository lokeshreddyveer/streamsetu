#!/usr/bin/env python3
"""
Time from OK on "TV Guide" to its first rows, right after a cold start of the app (force-stop, launch, enter the library, go to the Guide as fast as the remote can).
Every wait is bounded and the app is brought back to the front at the end, so a failed step never leaves the TV on the launcher.

  cold_guide.py [--serial 192.168.1.68:5555] [--runs 3] [--settle 0]     (--settle N waits N seconds after the library opens, to compare with a settled app)
"""
import argparse, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_suite as R, tvtest as T


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--serial", default="192.168.1.68:5555"); ap.add_argument("--runs", type=int, default=3); ap.add_argument("--settle", type=float, default=0)
    a = ap.parse_args()
    S = R.Suite(a.serial, os.path.join(os.environ.get("TMPDIR", "/tmp"), "cold_guide")); d = S.d
    d.sh("setprop log.tag.SSSAMPLE INFO"); d.sh("setprop log.tag.SSTRACE VERBOSE")
    d.start_log(); d.start_injector()
    results = []
    try:
        for n in range(1, a.runs + 1):
            d.sh("am force-stop app.streamsetu.tv"); time.sleep(1)
            t_start = time.time(); d.sh(f"am start -W -n {T.PKG}/.MainActivity")
            if not d.wait_for(lambda: T.foreground(d), 30): print(f"run {n}: the app did not come to the front"); continue
            ok, scr = S.wait_screen(["Enter Library", "TV Guide", "Continue Watching", "Live"], 40)
            if "Enter Library" in " ".join(scr["texts"]): d.key("OK"); ok, scr = S.wait_screen(["Continue Watching", "TV Guide", "Live", "Episodes", "Play"], 40)
            t_lib = time.time() - t_start
            if not ok: print(f"run {n}: never reached the library ({' | '.join(scr['texts'])[:80]})"); continue
            if a.settle: time.sleep(a.settle)
            for _ in range(6):                                          # Back until the rail shows
                s = S.dump()
                if "TV Guide" in " ".join(s["texts"]) and "StreamSetu" in " ".join(s["texts"]): break
                d.key("BACK"); d.settle(d.mark(), quiet=0.3, timeout=4)
            s = S.dump(); cur = next((k for k, x in enumerate(R.RAIL) if s["focus"] and x in s["focus"][0]["text"]), 0)
            for _ in range(abs(2 - cur)): d.key("DOWN" if 2 > cur else "UP"); d.settle(d.mark(), quiet=0.25, timeout=4)
            m = d.mark(); t0 = time.time(); d.key("OK")
            got = d.wait_for(lambda: any("guide rows" in e[2] for e in d.since(m)), 120); el = time.time() - t0
            results.append(el if got else None)
            print(f"cold start {n}: library after {t_lib:4.1f} s, Guide pressed at +{t0 - t_start:4.1f} s, rows " + (f"after {el:5.1f} s" if got else "NOT within 120 s")); sys.stdout.flush()
    finally:
        if not T.foreground(d): d.sh(f"am start -n {T.PKG}/.MainActivity")
    vals = [r for r in results if r is not None]
    if vals: print(f"rows after: min {min(vals):.1f}  max {max(vals):.1f}  of {len(results)} runs ({len(results) - len(vals)} never)")


if __name__ == "__main__":
    main()
