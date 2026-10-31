#!/usr/bin/env python3
"""
Side-by-side smoothness of two apps on the same TV, measured the same way for both (only what any app exposes, so TiviMate can be measured too):
  frames   : the system's own frame statistics (dumpsys gfxinfo) while the same keys are injected: janky frames, 50th/90th/95th/99th percentile frame time
  screens  : time from the key that opens a screen to its texts being on the accessibility tree (polled; includes up to ~1 s of dump time on both apps)
  search   : time from the last typed letter to the first result text for the same query appearing

The 30 ms key interval is a stress workload from the system's input injection, not a physical remote. TiviMate has no key-to-frame probe, so latency to the frame is NOT compared here.

  compare_apps.py --app tivimate|streamsetu [--serial 192.168.1.68:5555]
"""
import argparse, os, re, subprocess, sys, time, xml.etree.ElementTree as ET
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tvtest as T

APPS = {"tivimate": dict(pkg="ar.tvplayer.tv", launch="monkey -p ar.tvplayer.tv -c android.intent.category.LEANBACK_LAUNCHER 1"),
        "streamsetu": dict(pkg="app.streamsetu.tv", launch="am start -n app.streamsetu.tv/.MainActivity")}


class Rig:
    def __init__(self, serial, app):
        self.d = T.Device(serial); self.app = APPS[app]; self.pkg = self.app["pkg"]; self.name = app

    def texts(self):
        raw = subprocess.run([T.ADB, "-s", self.d.serial, "exec-out", "uiautomator dump /dev/tty"], capture_output=True, text=True, timeout=90).stdout
        i, j = raw.find("<?xml"), raw.rfind("</hierarchy>")
        try: root = ET.fromstring(raw[i:j + 12])
        except Exception: return []
        return [(n.get("text") or n.get("content-desc") or "").strip() for n in root.iter("node") if (n.get("text") or n.get("content-desc") or "").strip()]

    def wait_text(self, words, timeout=30):
        t0 = time.time()
        while time.time() - t0 < timeout:
            s = " | ".join(self.texts())
            if any(w in s for w in words): return time.time() - t0
        return None

    def front(self): return self.pkg in self.d.sh("dumpsys window | grep mCurrentFocus")

    def gfx(self):
        t = self.d.sh(f"dumpsys gfxinfo {self.pkg}")
        g = lambda rx: (lambda m: float(m[1]) if m else None)(re.search(rx, t))
        return dict(frames=g(r"Total frames rendered: (\d+)"), janky=g(r"Janky frames: (\d+)"), p50=g(r"50th percentile: (\d+)ms"), p90=g(r"90th percentile: (\d+)ms"), p95=g(r"95th percentile: (\d+)ms"), p99=g(r"99th percentile: (\d+)ms"))

    def workload(self, label, keys=None, hold=None, interval=30):
        self.d.sh(f"dumpsys gfxinfo {self.pkg} reset"); m = self.d.mark()
        if hold: self.d.hold(hold[0], hold[1], interval)
        else: self.d.seq(keys, interval)
        time.sleep(1.2); g = self.gfx()
        pct = f"{100 * g['janky'] / g['frames']:.0f}%" if g["frames"] else "-"
        print(f"  {label:34} frames {int(g['frames'] or 0):4}  janky {int(g['janky'] or 0):4} ({pct:>4})  frame ms p50 {g['p50']} p90 {g['p90']} p95 {g['p95']} p99 {g['p99']}"); sys.stdout.flush()
        return g


    def stable(self, before, timeout=20):
        """Seconds until the screen's texts differ from `before` and then stop changing (two equal dumps in a row); None when they never settle."""
        t0 = time.time(); prev = None
        while time.time() - t0 < timeout:
            cur = self.texts()
            if cur != before and cur == prev: return time.time() - t0
            prev = cur
        return None

    def timed(self, label, press):
        before = self.texts(); t0 = time.time(); press(); el = self.stable(before)
        print(f"  {label:34} " + (f"screen stable after {el:4.1f} s (+/- 1 s: each look at the screen takes about 0.7 s)" if el is not None else "did not settle in 20 s")); sys.stdout.flush(); return el


def rail_streamsetu(r, target):
    import run_suite as RS
    S = RS.Suite(r.d.serial, os.environ.get("TMPDIR", "/tmp") + "/cmp"); S.d = r.d
    for _ in range(8):
        s = S.dump()
        if "TV Guide" in " ".join(s["texts"]) and "StreamSetu" in " ".join(s["texts"]): break
        r.d.key("BACK"); r.d.settle(r.d.mark(), quiet=0.3, timeout=4)
    s = S.dump(); cur = next((i for i, n in enumerate(RS.RAIL) if s["focus"] and n in s["focus"][0]["text"]), 0); want = RS.RAIL.index(target)
    for _ in range(abs(want - cur)): r.d.key("DOWN" if want > cur else "UP"); time.sleep(0.25)


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--app", required=True, choices=APPS); ap.add_argument("--serial", default="192.168.1.68:5555"); a = ap.parse_args()
    r = Rig(a.serial, a.app); d = r.d; d.start_injector()
    print(f"== {a.app}")
    if not r.front(): d.sh(r.app["launch"]); d.wait_for(r.front, 30); time.sleep(4)
    ts = a.app == "tivimate"
    if not ts:
        import run_suite as RS
        S = RS.Suite(a.serial, os.environ.get("TMPDIR", "/tmp") + "/cmp"); S.d = d; d.start_log(); S.enter_library(); S.goto("Live TV"); time.sleep(2)
    else:
        for _ in range(6): d.key("BACK"); time.sleep(0.4)
        d.sh(r.app["launch"]); time.sleep(5)
    print(" scrolling the list that has focus on the Live TV screen (30 ms apart = stress workload)")
    r.workload("20 Down, 30 ms apart", ["DOWN"] * 20); r.workload("20 Up, 30 ms apart", ["UP"] * 20)
    r.workload("alternating Down/Up x10, 30 ms", ["DOWN", "UP"] * 10)
    r.workload("held Down 3 s", hold=("DOWN", 3000)); r.workload("held Up 3 s", hold=("UP", 3000))
    print(" opening screens (OK on the rail entry; focus is placed first, only the OK is timed)")
    if ts:
        def to_rail(): [d.key("LEFT") or time.sleep(0.2) for _ in range(6)]
        to_rail(); d.key("DOWN"); time.sleep(0.4); r.timed("Live TV -> Movies", lambda: d.key("OK")); time.sleep(1)
        to_rail(); d.key("UP"); time.sleep(0.4); r.timed("Movies -> Live TV", lambda: d.key("OK")); time.sleep(1)
        to_rail(); d.key("UP"); time.sleep(0.4); r.timed("Live TV -> Search", lambda: d.key("OK")); time.sleep(1)
    else:
        rail_streamsetu(r, "Movies"); r.timed("Live TV -> Movies", lambda: d.key("OK")); time.sleep(1)
        rail_streamsetu(r, "Live TV"); r.timed("Movies -> Live TV", lambda: d.key("OK")); time.sleep(1)
        rail_streamsetu(r, "Search"); r.timed("Live TV -> Search", lambda: d.key("OK")); time.sleep(1)
    print(" searching: the same word typed into the open search")
    d.key("OK"); time.sleep(0.8)
    r.timed("type 'bigg' -> results settled", lambda: d.sh("input text bigg"))
    r.timed("add ' boss' -> results settled", lambda: d.sh("input text %sboss"))
    for _ in range(3): d.key("BACK"); time.sleep(0.5)


if __name__ == "__main__":
    main()
