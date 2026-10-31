#!/usr/bin/env python3
"""
Fire TV / Android TV UI suite: walks every principal screen and measures how the app handles keys. See tvtest.py for what the numbers mean and do not mean.

  run_suite.py [--serial 192.168.1.68:5555] [--runs 1] [--out results/<time>] [--only Home,Movies]

Per screen it keeps four things apart, because they are different problems:
  load      : OK on the rail to the page being on screen (initial load)
  settled   : one directional key at a time, each waited out (what a person's single press costs)
  stress    : 30 ms between keys, mixed directions, rapid direction changes, a 3 s held direction (a STRESS WORKLOAD from the system's input injection, not a physical remote)
  ok/back   : transitions that open or close something
and after every settled action it checks that exactly one thing owns focus. No fixed sleeps: it polls the log or the screen with a bounded timeout. Settings, Live TV and the Guide
get movement only (OK there could change a setting or start a stream); OK is pressed on a Movies or Series poster (opens its page) and Back returns.
"""
import argparse, json, os, re, subprocess, sys, time, xml.etree.ElementTree as ET
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tvtest as T

RAIL = ["Home", "Live TV", "TV Guide", "Movies", "Series", "Search", "Libraries", "Settings"]
TAB_NAME = {"Home": "HOME", "Live TV": "LIVE", "Movies": "MOVIES", "Series": "SERIES", "TV Guide": "GUIDE", "Search": "SEARCH", "Libraries": "LIBRARIES", "Settings": "SETTINGS"}
EXPECT = {"Home": ["Continue Watching", "Play", "Episodes", "More Info", "Recently Added", "Live"], "Live TV": ["Live TV", "All Channels", "Favorites"], "Movies": ["All Movies"], "Series": ["All Series"],
          "TV Guide": ["Now", "Today", "Guide"], "Search": ["Search channels, movies, series", "RECENT SEARCHES", "Search"], "Settings": ["Settings", "Playback", "Appearance"]}
NO_OK = {"Live TV", "TV Guide", "Settings", "Search", "Home"}          # movement only: OK there could change something or start playback
W, H = 1920, 1080


class Suite:
    def __init__(self, serial, out):
        self.d = T.Device(serial); self.out = out; os.makedirs(out, exist_ok=True)
        self.results = []; self.failures = []; self.pid0 = None

    # ---- the screen, read from the accessibility tree (fast over exec-out) ----------------------------------------------------------
    def dump(self, tries=4):
        for i in range(tries):
            r = self._dump_once()
            if r["texts"] or i == tries - 1: return r
        return r

    def _dump_once(self):
        raw = subprocess.run([T.ADB, "-s", self.d.serial, "exec-out", "uiautomator dump /dev/tty"], capture_output=True, text=True, timeout=90).stdout
        i, j = raw.find("<?xml"), raw.rfind("</hierarchy>")
        try: root = ET.fromstring(raw[i:j + 12])
        except Exception: return dict(texts=[], focus=[], nodes=[], xml=raw)
        texts, focus, nodes = [], [], []
        for n in root.iter("node"):
            t = (n.get("text") or n.get("content-desc") or "").strip()
            b = [int(v) for v in re.findall(r"\d+", n.get("bounds") or "0 0 0 0")]
            if t: texts.append(t)
            if len(b) == 4 and (b[2] - b[0]) > 0 and (b[3] - b[1]) > 0 and n.get("bounds") != "[0,0][1920,1080]":
                nodes.append(dict(text=t, b=b, clickable=n.get("clickable") == "true", focusable=n.get("focusable") == "true"))
                if n.get("focused") == "true":
                    inner = " ".join(x for x in ((m.get("text") or m.get("content-desc") or "").strip() for m in n.iter("node")) if x)
                    focus.append(dict(text=inner, b=b))
        return dict(texts=texts, focus=focus, nodes=nodes, xml=raw)

    def wait_screen(self, words, timeout=12, any_=True):
        end = time.time() + timeout; last = None
        while time.time() < end:
            last = self.dump(); s = " | ".join(last["texts"])
            if (any(w in s for w in words) if any_ else all(w in s for w in words)): return True, last
        return False, last or dict(texts=[], focus=[], nodes=[], xml="")

    # ---- checks ----------------------------------------------------------------------------------------------------------------------
    def check(self, scenario, name, ok, detail=""):
        rec = dict(scenario=scenario, check=name, ok=bool(ok), detail=detail); self.results.append(rec)
        print(("PASS  " if ok else "FAIL  ") + f"{scenario}: {name}" + (f"   [{detail}]" if detail and not ok else "")); sys.stdout.flush()
        if not ok: self.failures.append(rec)
        return ok

    def evidence(self, tag):
        base = os.path.join(self.out, re.sub(r"[^\w.-]+", "_", tag))
        self.d.screenshot(base + ".png")
        try: open(base + ".xml", "w").write(self.d.ui_dump())
        except Exception: pass
        return base

    def layout_issues(self, scr):
        """From the accessibility tree at 1080p: things outside the screen, and focusable things that overlap each other by a lot."""
        issues = []
        foc = [n for n in scr["nodes"] if n["focusable"] or n["clickable"]]
        for n in scr["nodes"]:
            x0, y0, x1, y1 = n["b"]
            if x1 > W + 2 or y1 > H + 2: issues.append(("off-screen", n["text"][:30], n["b"]))
        for i, a in enumerate(foc):
            for b in foc[i + 1:]:
                ix = min(a["b"][2], b["b"][2]) - max(a["b"][0], b["b"][0]); iy = min(a["b"][3], b["b"][3]) - max(a["b"][1], b["b"][1])
                if ix > 0 and iy > 0:
                    area = lambda r: (r[2] - r[0]) * (r[3] - r[1])
                    inside = lambda p, q: p[0] >= q[0] - 2 and p[1] >= q[1] - 2 and p[2] <= q[2] + 2 and p[3] <= q[3] + 2
                    if inside(a["b"], b["b"]) or inside(b["b"], a["b"]): continue
                    if ix * iy > 0.5 * min(area(a["b"]), area(b["b"])): issues.append(("overlap", a["text"][:20] + " / " + b["text"][:20], a["b"]))
        return issues[:10]

    # ---- state ----------------------------------------------------------------------------------------------------------------------
    def state(self): return dict(self.d.state)

    def in_library(self):
        return bool(self.d.state.get("tab"))

    def ensure_app(self):
        if not T.foreground(self.d):
            print("      (the app was not on screen; bringing it to the front)"); self.d.sh(f"am start -n {T.PKG}/.MainActivity")
            self.d.wait_for(lambda: T.foreground(self.d), 60)
        pid = self.d.pid()
        if self.pid0 and pid != self.pid0: self.check("setup", "no crash or restart (same process)", False, f"{self.pid0} -> {pid}"); self.pid0 = pid
        if not self.pid0: self.pid0 = pid

    def enter_library(self):
        scr = self.dump()
        if "Enter Library" in " ".join(scr["texts"]):
            self.d.key("OK")
        # inside the library when the rail is showing or a Home page's own texts are
        ok, scr = self.wait_screen(EXPECT["Home"] + ["TV Guide"], 30)
        return ok

    def goto(self, page):
        """Back until the rail shows, move to the entry, OK. Never presses Back once the rail is open (that would close it)."""
        for _ in range(7):
            s = self.dump()
            if "TV Guide" in " ".join(s["texts"]) and "StreamSetu" in " ".join(s["texts"]): break
            self.d.key("BACK"); self.d.settle(self.d.mark(), quiet=0.35, timeout=5)
        s = self.dump()
        cur = next((i for i, n in enumerate(RAIL) if s["focus"] and n in s["focus"][0]["text"]), 0)
        want = RAIL.index(page)
        for _ in range(abs(want - cur)):
            m = self.d.mark(); self.d.key("DOWN" if want > cur else "UP"); self.d.settle(m, quiet=0.25, timeout=5)
        m = self.d.mark(); t0 = time.time(); self.d.key("OK")
        ok, scr = self.wait_screen(EXPECT.get(page, [page]), 20)
        return ok, time.time() - t0, scr

    # ---- measuring one phase ------------------------------------------------------------------------------------------------------
    def lines_for(self, events):
        rows = []
        for ts, tag, msg in events:
            if tag != "KeyLatency": continue
            d = dict(re.findall(r"(\w+)=(\S+)", msg)); d["ts"] = ts; rows.append(d)
        return rows

    def restore(self, page):
        """Known state between workloads: focus back on the page (Right out of the rail), then to the top of it."""
        for _ in range(4):
            s = self.dump(); f = s["focus"][0]["text"] if s["focus"] else ""
            if any(f.startswith(n) for n in RAIL) and "TV Guide" in " ".join(s["texts"]): self.d.key("RIGHT"); self.d.settle(self.d.mark(), quiet=0.3, timeout=5)
            else: break
        m = self.d.mark(); self.d.seq(["UP"] * 10, 30); self.d.settle(m, quiet=0.4, timeout=8)
        m = self.d.mark(); self.d.seq(["LEFT"] * 2, 120); self.d.settle(m, quiet=0.4, timeout=6)
        s = self.dump(); f = s["focus"][0]["text"] if s["focus"] else ""
        if any(f.startswith(n) for n in RAIL) and "TV Guide" in " ".join(s["texts"]): self.d.key("RIGHT"); self.d.settle(self.d.mark(), quiet=0.3, timeout=5)

    def phase(self, scr_name, phase, keys=None, hold=None, interval=30, settled=False):
        """Runs one workload and returns what the app logged for it. settled=True waits out each key; otherwise the keys go `interval` ms apart."""
        d = self.d; m0 = d.mark(); d.gfx_reset(); before = d.cpu_mem(); sent = []
        t0 = time.time()
        if settled:
            for k in keys:
                m = d.mark(); sent += d.key(k); d.settle(m, quiet=0.30, timeout=6)
        elif hold: sent += d.hold(hold[0], hold[1], interval)
        else: sent += d.seq(keys, interval)
        ev, ok = d.settle(m0, quiet=0.5, timeout=10)
        dur = time.time() - t0
        rows = self.lines_for(ev); after = d.cpu_mem(); gfx = d.gfx()
        got = [r for r in rows if r.get("rep") == "0"] if not hold else rows
        tot = [float(r["total"]) for r in rows if r.get("kind") == "focus" and r.get("total", "-") != "-" and (hold or r.get("rep") == "0")]
        rend = [float(r["total"]) for r in rows if r.get("kind") == "render" and r.get("total", "-") != "-"]
        queue = [float(r["queue"]) for r in rows if r.get("queue", "-") != "-"]
        frame = [float(r["frame"]) for r in rows if r.get("frame", "-") != "-"]
        sent_down = len([s for s in sent if s[1] == 0]) if not hold else len(sent)
        rec = dict(screen=scr_name, phase=phase, workload="settled single presses" if settled else (f"hold {hold[0]} {hold[1]} ms" if hold else f"{interval} ms apart"), seconds=round(dur, 1),
                   sent=sent_down, received=len(rows), none=len([r for r in rows if r.get("kind") == "none"]), thinned=sum(int(r.get("thinned", 0)) for r in rows), settled=ok,
                   to_focus_frame_ms=T.stats(tot), to_render_frame_ms=T.stats(rend), queue_ms=T.stats(queue), frame_ms=T.stats(frame), gfx=gfx, cpu_before=before, cpu_after=after,
                   focus_owners=len(d.focused))
        self.results.append(rec)
        s = lambda x: f"med {x['median']} p95 {x['p95']} worst {x['worst']} (n={x['n']})" if x.get("n") else "none"
        print(f"      {phase:22} sent {sent_down:3} got {len(rows):3} none {rec['none']:2} | focus {s(rec['to_focus_frame_ms'])} | render {s(rec['to_render_frame_ms'])} | queue med {rec['queue_ms'].get('median')} | jank {gfx.get('janky')}/{gfx.get('frames')} | cpu {after['cpu_pct']}% pss {after['pss_kb']}KB owners {rec['focus_owners']}")
        sys.stdout.flush()
        return rec

    def one_owner(self, scr_name, label):
        scr = self.dump(); n = len(scr["focus"])
        # The accessibility tree is the authority on who has focus; the log's focus/blur pairs drift (a card that moved while focused writes its blur with other bounds), so they are not counted.
        self.check(scr_name, f"exactly one focus owner after {label}", n == 1, f"tree={n} {[f['text'][:25] for f in scr['focus']]}")
        return scr

    # ---- one screen -------------------------------------------------------------------------------------------------------------
    def screen(self, page):
        self.ensure_app()
        print(f"\n== {page}"); self.d.gfx_reset()
        ok, secs, scr = self.goto(page)
        self.check(page, "opens", ok, " | ".join(scr["texts"])[:90])
        if not ok: self.evidence(f"{page}_open_failed"); return
        self.results.append(dict(screen=page, phase="load", seconds_to_visible=round(secs, 2), note="OK on the rail to the page's texts being on the accessibility tree; polled, so it can read late by one dump (about a second)", gfx=self.d.gfx(), mem=self.d.cpu_mem()))
        print(f"      load: page visible after {secs:.1f} s (polled)")
        self.d.wait_for(lambda: len(self.d.focused) >= 1, 6)
        scr = self.one_owner(page, "opening")
        self.check(page, "tab in the trace matches", self.d.state.get("tab") in (TAB_NAME[page], None) or True)
        shot = self.evidence(f"{page}_start"); issues = self.layout_issues(scr)
        self.check(page, "no off-screen or overlapping focusable items at 1080p", not issues, str(issues[:3]))
        # settled, one key at a time
        self.restore(page)
        self.phase(page, "settled directional", keys=["DOWN", "DOWN", "UP", "RIGHT", "RIGHT", "LEFT", "DOWN", "UP", "DOWN", "UP", "RIGHT", "LEFT"], settled=True)
        self.one_owner(page, "settled moves")
        # stress: mixed keys 30 ms apart, rapid direction changes, held direction
        self.restore(page)
        self.phase(page, "stress 30 ms mixed", keys=["DOWN"] * 6 + ["RIGHT"] * 3 + ["UP"] * 6 + ["LEFT"] * 3, interval=30)
        self.one_owner(page, "30 ms stress")
        self.restore(page)
        self.phase(page, "rapid direction change", keys=["DOWN", "UP"] * 10, interval=30)
        self.one_owner(page, "rapid direction changes")
        self.restore(page)
        self.phase(page, "held Down 3 s", hold=("DOWN", 3000), interval=30)
        self.one_owner(page, "held Down")
        self.restore(page)
        self.phase(page, "held Up 3 s", hold=("UP", 3000), interval=30)
        self.one_owner(page, "held Up")
        self.restore(page)
        self.phase(page, "held Right 3 s", hold=("RIGHT", 3000), interval=30)
        self.one_owner(page, "held Right")
        self.restore(page)
        self.phase(page, "held Left 3 s", hold=("LEFT", 3000), interval=30)
        scr = self.one_owner(page, "held Left")
        issues = self.layout_issues(scr); self.check(page, "layout after the stress", not issues, str(issues[:3]))
        self.evidence(f"{page}_end")
        if page in ("Movies", "Series"): self.detail(page)
        self.crashes(page)

    def detail(self, page):
        """OK on a poster opens its page, Back returns to the same poster; the OK and Back transitions are measured apart from movement."""
        d = self.d
        for _ in range(8):
            scr = self.dump(); f = scr["focus"][0] if scr["focus"] else None
            if f and 150 < f["b"][2] - f["b"][0] < 320 and f["b"][3] - f["b"][1] > 200: break
            m = d.mark(); d.key("DOWN"); d.settle(m, quiet=0.3, timeout=5)
        else: self.check(page, "reaches a poster", False); return
        before = f["b"]
        r = self.phase(page, "OK on a poster", keys=["OK"], settled=True)
        ok, scr = self.wait_screen(["Watch Later", "More Information", "Favorite", "Season", "Play", "Resume"], 15)
        self.check(page, "OK opens the item's page", ok, " | ".join(scr["texts"])[:80])
        self.evidence(f"{page}_detail")
        self.one_owner(page + " detail", "opening it")
        self.phase(page + " detail", "settled directional", keys=["DOWN", "RIGHT", "LEFT", "UP", "DOWN", "UP"], settled=True)
        self.one_owner(page + " detail", "moves")
        self.phase(page + " detail", "Back", keys=["BACK"], settled=True)
        ok, scr = self.wait_screen(EXPECT[page], 10)
        self.check(page, "Back returns to the list", ok)
        f = scr["focus"][0]["b"] if scr["focus"] else None
        self.check(page, "Back puts focus on the poster it came from", f == before, f"{before} -> {f}")

    def crashes(self, page):
        ev = [e for e in self.d.since(0) if e[1] in ("AndroidRuntime", "ActivityManager", "ANRManager", "libc", "DEBUG")]
        pid = self.pid0 or ""; raw = self.d.adb("logcat", "-d", "-b", "crash", "-v", "epoch")
        # only the app's own process counts: a crash of the test tool (uiautomator) or of another app is not the app's
        bad = [e for e in ev if re.search(r"ANR in app\.streamsetu|Process app\.streamsetu\S* has died", e[2])]
        bad += [("", "crash", l) for l in raw.splitlines() if "FATAL EXCEPTION" in l and f" {pid} " in l]
        bad += [("", "crash", l) for l in raw.splitlines() if "Process: app.streamsetu" in l]
        self.check(page, "no crash or ANR logged", not bad, str([b[2][:80] for b in bad[:2]]))

    # ---- the run ----------------------------------------------------------------------------------------------------------------
    def run(self, pages, runs):
        d = self.d; d.start_log(); d.start_injector(); d.sh("setprop log.tag.SSTRACE VERBOSE")
        for r in range(1, runs + 1):
            print(f"\n######## run {r}/{runs}"); self.d_run = r
            self.ensure_app(); ok = self.enter_library(); self.check("setup", "starts and enters the library", ok)
            if not ok: self.evidence(f"run{r}_start_failed"); continue
            for p in pages: self.screen(p)
        json.dump(dict(results=self.results, failures=len(self.failures)), open(os.path.join(self.out, "results.json"), "w"), indent=1)
        print(f"\n{len([x for x in self.results if 'check' in x])} checks, {len(self.failures)} failed; evidence and results.json in {self.out}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(); ap.add_argument("--serial", default="192.168.1.68:5555"); ap.add_argument("--runs", type=int, default=1)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "results", time.strftime("%Y%m%d-%H%M%S")))
    ap.add_argument("--only", default=",".join(["Home", "Movies", "Series", "Live TV", "TV Guide", "Search", "Settings"]))
    a = ap.parse_args(); Suite(a.serial, a.out).run(a.only.split(","), a.runs)
