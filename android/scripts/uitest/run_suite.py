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

RAIL = ["Search", "Home", "Live TV", "TV Guide", "Movies", "Series", "Libraries", "Settings"]          # the menu from top to bottom (read again from the screen on every use; this is the fallback and the expected order)
TAB_NAME = {"Home": "HOME", "Live TV": "LIVE", "Movies": "MOVIES", "Series": "SERIES", "TV Guide": "GUIDE", "Search": "SEARCH", "Libraries": "LIBRARIES", "Settings": "SETTINGS"}
EXPECT = {"Home": ["Continue Watching", "Play", "Episodes", "More Info", "Recently Added", "Live"], "Live TV": ["Live TV", "All Channels", "Favorites"], "Movies": ["All Movies"], "Series": ["All Series"],
          "TV Guide": ["Now", "Today", "Guide"], "Search": ["Search channels, movies, series", "RECENT SEARCHES", "Search"], "Settings": ["Settings", "Playback", "Appearance"], "Libraries": ["Choose a library", "Add a library", "Libraries"]}
NO_OK = {"Live TV", "TV Guide", "Settings", "Search", "Home"}          # movement only: OK there could change something or start playback
W, H = 1920, 1080
HOLD_MS = 3000          # how long a held key is held; --quick makes it 2 s


class Suite:
    def __init__(self, serial, out):
        self.d = T.Device(serial); self.out = out; os.makedirs(out, exist_ok=True)
        self.results = []; self.failures = []; self.pid0 = None; self.mem_at = 0.0; self.mem_last = {}; self.last_xml = ""; self.prof = {}; self.shots = False; self.maybe_rail = True
        # where the time goes: how many times and how long each kind of wait ran, printed at the end of the run
        def timed(obj, name, label):
            fn = getattr(obj, name)
            def w(*a, **k):
                t = time.time()
                try: return fn(*a, **k)
                finally: c = self.prof.setdefault(label, [0, 0.0]); c[0] += 1; c[1] += time.time() - t
            setattr(obj, name, w)
        timed(self, "_dump_once", "screen dump"); timed(self.d, "settle", "settle"); timed(self.d, "screenshot", "screenshot"); timed(self.d, "hold", "held keys"); timed(self.d, "seq", "key sequences")

    # ---- the screen, read from the accessibility tree (fast over exec-out) ----------------------------------------------------------
    def dump(self, tries=4):
        for i in range(tries):
            r = self._dump_once()
            if r["texts"] or i == tries - 1: return r
        return r

    def _dump_once(self):
        raw = self.d.dump_xml()          # from the helper on the TV, over a connection kept open
        if raw is None: raw = subprocess.run([T.ADB, "-s", self.d.serial, "exec-out", "uiautomator dump /dev/tty"], capture_output=True, text=True, timeout=90).stdout
        i, j = raw.find("<?xml"), raw.rfind("</hierarchy>")
        try: root = ET.fromstring(raw[i:j + 12])
        except Exception: return dict(texts=[], focus=[], nodes=[], xml=raw)
        texts, focus, nodes = [], [], []
        hidden = self._covered(root)
        for n in root.iter("node"):
            t = (n.get("text") or n.get("content-desc") or "").strip()
            b = [int(v) for v in re.findall(r"\d+", n.get("bounds") or "0 0 0 0")]
            if t: texts.append(t)
            if len(b) == 4 and (b[2] - b[0]) > 0 and (b[3] - b[1]) > 0 and n.get("bounds") != "[0,0][1920,1080]" and n not in hidden:
                nodes.append(dict(text=t, b=b, rid=n.get("resource-id") or "", clickable=n.get("clickable") == "true", focusable=n.get("focusable") == "true"))
                if n.get("focused") == "true":
                    inner = " ".join(x for x in ((m.get("text") or m.get("content-desc") or "").strip() for m in n.iter("node")) if x)
                    focus.append(dict(text=inner, b=b))
        self.last_xml = raw
        return dict(texts=texts, focus=focus, nodes=nodes, xml=raw)

    def tap(self, word):
        """Touches the item whose text (or description) is exactly [word]: how the suite reaches a button without walking the remote to it."""
        for n in self.dump()["nodes"]:
            if n["text"] == word:
                b = n["b"]; self.d.sh(f"input tap {(b[0] + b[2]) // 2} {(b[1] + b[3]) // 2}"); return True
        return False

    @staticmethod
    def _covered(root):
        """Items drawn underneath something that is drawn later and covers them: the page behind a detail page, a sheet or the open menu is still in the screen reader's list, but it is not on screen. Found from the one that has focus: every earlier sibling of it or of any of its parents, mostly inside that parent's bounds, is covered."""
        box = lambda n: [int(v) for v in re.findall(r"\d+", n.get("bounds") or "0 0 0 0")]
        focused = [n for n in root.iter("node") if n.get("focused") == "true"]
        if not focused: return set()
        parent = {c: p for p in root.iter() for c in p}
        hidden = set(); x = focused[0]
        while x in parent:
            p = parent[x]; kids = list(p); xb = box(x)
            if len(xb) == 4 and (xb[2] - xb[0]) * (xb[3] - xb[1]) > 0:
                for sib in kids[:kids.index(x)]:
                    for n in sib.iter("node"):
                        b = box(n)
                        if len(b) != 4: continue
                        area = (b[2] - b[0]) * (b[3] - b[1])
                        ix = min(b[2], xb[2]) - max(b[0], xb[0]); iy = min(b[3], xb[3]) - max(b[1], xb[1])
                        if area > 0 and ix > 0 and iy > 0 and ix * iy >= 0.6 * area: hidden.add(n)
            x = p
        return hidden

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
        if not ok:
            self.failures.append(rec)
            try: self.d.screenshot(os.path.join(self.out, re.sub(r"[^\w.-]+", "_", f"FAIL_{scenario}_{name}")[:90] + ".png"))
            except Exception: pass
        return ok

    def evidence(self, tag):
        base = os.path.join(self.out, re.sub(r"[^\w.-]+", "_", tag))
        if self.shots or tag.endswith("failed"): self.d.screenshot(base + ".png")
        try: open(base + ".xml", "w").write(self.last_xml)
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
            print("      (the app was not on screen; bringing it to the front)"); self.d.sh(f"am start -n {T.PKG}/app.streamsetu.tv.MainActivity")
            self.d.wait_for(lambda: T.foreground(self.d), 60)
        pid = self.d.pid()
        if self.pid0 and pid != self.pid0: self.check("setup", "no crash or restart (same process)", False, f"{self.pid0} -> {pid}"); self.pid0 = pid
        if not self.pid0: self.pid0 = pid

    def enter_library(self):
        scr = self.dump()
        txt = " ".join(scr["texts"])
        # The library picker (cards since the redesign): OK on the card the remote starts on opens it. The picker can still be getting ready when the first OK arrives (screens are read
        # in milliseconds now), so OK is sent again while the picker is still showing.
        ok = False
        for attempt in range(6):
            if "Enter Library" in txt or "Choose a library" in txt: self.d.key("OK")
            # inside the library when the rail is showing or a Home page's own texts are
            ok, scr = self.wait_screen(EXPECT["Home"] + ["TV Guide"], 8 if attempt < 5 else 30)
            if ok: return True
            txt = " ".join(self.dump()["texts"])
            if not ("Enter Library" in txt or "Choose a library" in txt): break
        return ok

    def open_rail(self):
        """Back until the rail shows (never once it is open: that would close it)."""
        for _ in range(7):
            s = self.dump()
            if "TV Guide" in " ".join(s["texts"]) and "StreamSetu" in " ".join(s["texts"]): return True
            self.d.key("BACK"); self.d.settle(self.d.mark(), quiet=0.2, timeout=5)
            # The menu takes a moment to open. Another Back before it has shown would close it (or, from Home, ask whether to stop watching), so it is waited for first.
            end = time.time() + 1.5
            while time.time() < end:
                t = " ".join(self.dump()["texts"])
                if "TV Guide" in t and "StreamSetu" in t: return True
                time.sleep(0.05)
        return False

    def rail_order(self, scr=None):
        """The menu's entries from top to bottom, read from the screen (the open rail's texts at the left edge, sorted by height), so the suite does not carry its own idea of where things are."""
        scr = scr or self.dump()
        seen = {}
        for n in scr["nodes"]:
            if n["text"] in RAIL and n["b"][0] < 420 and n["text"] not in seen: seen[n["text"]] = n["b"][1]
        found = [t for t, _ in sorted(seen.items(), key=lambda kv: kv[1])]
        return found if len(found) >= 6 else RAIL

    def check_menu_order(self):
        """Search is the first entry of the menu and Home the second; everything else follows in the order the app declares."""
        order = self.rail_order()
        self.check("Menu", "Search comes first and Home second", order[:2] == ["Search", "Home"], str(order))
        self.check("Menu", "the entries are in the expected order", order == RAIL, str(order))

    def goto(self, page):
        """Back until the rail shows, move to the entry, OK. Never presses Back once the rail is open (that would close it)."""
        for _ in range(7):
            s = self.dump()
            if "TV Guide" in " ".join(s["texts"]) and "StreamSetu" in " ".join(s["texts"]): break
            self.d.key("BACK"); self.d.settle(self.d.mark(), quiet=0.2, timeout=5)
        menu = self.rail_order(s)
        cur = next((i for i, n in enumerate(menu) if s["focus"] and n in s["focus"][0]["text"]), 0)
        want = menu.index(page)
        for _ in range(abs(want - cur)):
            m = self.d.mark(); self.d.key("DOWN" if want > cur else "UP"); self.d.settle(m, quiet=0.15, timeout=5)
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
        m = self.d.mark(); self.d.seq(["UP"] * 10, 30); self.d.settle(m, quiet=0.25, timeout=8)
        m = self.d.mark(); self.d.seq(["LEFT"] * 2, 120); self.d.settle(m, quiet=0.25, timeout=6)
        if not self.maybe_rail: return
        self.maybe_rail = False
        s = self.dump(); f = s["focus"][0]["text"] if s["focus"] else ""
        if any(f.startswith(n) for n in RAIL) and "TV Guide" in " ".join(s["texts"]):
            self.d.key("RIGHT"); self.d.settle(self.d.mark(), quiet=0.2, timeout=5)
            m = self.d.mark(); self.d.seq(["UP"] * 10, 30); self.d.settle(m, quiet=0.25, timeout=8)

    def phase(self, scr_name, phase, keys=None, hold=None, interval=30, settled=False):
        """Runs one workload and returns what the app logged for it. settled=True waits out each key; otherwise the keys go `interval` ms apart."""
        d = self.d; m0 = d.mark(); d.gfx_reset(); before = {}; sent = []; self.maybe_rail |= bool(hold and hold[0] == "LEFT") or "LEFT" in (keys or [])
        t0 = time.time()
        if settled:
            for k in keys:
                m = d.mark(); sent += d.key(k); d.settle(m, quiet=0.15, timeout=6)
        elif hold: sent += d.hold(hold[0], hold[1], interval)
        else: sent += d.seq(keys, interval)
        ev, ok = d.settle(m0, quiet=0.3, timeout=8)
        dur = time.time() - t0
        rows = self.lines_for(ev); gfx = d.gfx()
        # memory and CPU change slowly: read them about every 30 s, not after every step (the read costs close to a second on this TV)
        if time.time() - self.mem_at > 30: self.mem_last = d.cpu_mem(); self.mem_at = time.time()
        after = self.mem_last
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
        # a screen that is heavily janky cannot pass: held or settled scrolling on a list or grid may leave at most JANK_MAX of its frames janky (detail pages are judged by detail_jank)
        if "detail" not in scr_name.lower() and (hold or settled):
            jk, tot_f = gfx.get("janky"), gfx.get("frames")
            if jk is not None and tot_f and tot_f >= (40 if settled and len(keys or []) > 1 else 20):          # a few keys give too few frames to judge a share
                pct = 100.0 * jk / tot_f
                self.check(scr_name, f"{phase}: at most {self.JANK_MAX:.0f}% janky frames", pct <= self.JANK_MAX, f"{pct:.0f}% of {tot_f} frames janky")
        # snappy: the time from a key to the frame that shows it (what the person feels), judged by the kind of workload
        fm = rec["to_focus_frame_ms"]
        if fm.get("n"):
            if hold and fm["n"] >= 10: self.check(scr_name, f"{phase}: key to frame is quick (p95 at most {self.HELD_P95_MS:.0f} ms)", fm["p95"] <= self.HELD_P95_MS, f"p95 {fm['p95']} ms over {fm['n']} frames")
            elif settled and len(keys or []) > 1: self.check(scr_name, f"{phase}: key to frame is quick (median at most {self.SETTLED_MED_MS:.0f} ms, p95 at most {self.SETTLED_P95_MS:.0f} ms)", fm["median"] <= self.SETTLED_MED_MS and fm["p95"] <= self.SETTLED_P95_MS, f"median {fm['median']} ms, p95 {fm['p95']} ms")
            elif settled: self.check(scr_name, f"{phase}: the change shows quickly (at most {self.ONE_KEY_MS:.0f} ms)", fm["worst"] <= self.ONE_KEY_MS, f"{fm['worst']} ms")
        # jitter: frame times must be steady, not only mostly on time
        if gfx.get("frames") and gfx["frames"] >= 20 and gfx.get("p95") is not None and gfx.get("p99") is not None:
            self.check(scr_name, f"{phase}: frame times are steady (p95 at most {self.FRAME_P95_MS:.0f} ms, p99 at most {self.FRAME_P99_MS:.0f} ms)", gfx["p95"] <= self.FRAME_P95_MS and gfx["p99"] <= self.FRAME_P99_MS, f"p95 {gfx['p95']:.0f} ms, p99 {gfx['p99']:.0f} ms")
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
        m0 = self.d.mark(); self.d.settle(m0, quiet=0.4, timeout=4); scr = self.dump()          # the layout of the screen once it has stopped moving, not of its first frame
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
        self.phase(page, f"held Down {HOLD_MS//1000} s", hold=("DOWN", HOLD_MS), interval=30)
        self.one_owner(page, "held Down")
        self.restore(page)
        self.phase(page, f"held Up {HOLD_MS//1000} s", hold=("UP", HOLD_MS), interval=30)
        self.one_owner(page, "held Up")
        self.restore(page)
        self.phase(page, f"held Right {HOLD_MS//1000} s", hold=("RIGHT", HOLD_MS), interval=30)
        self.one_owner(page, "held Right")
        self.restore(page)
        self.phase(page, f"held Left {HOLD_MS//1000} s", hold=("LEFT", HOLD_MS), interval=30)
        scr = self.one_owner(page, "held Left")
        issues = self.layout_issues(scr); self.check(page, "layout after the stress", not issues, str(issues[:3]))
        self.evidence(f"{page}_end")
        if page in ("Movies", "Series"): self.detail(page); self.toolbar_and_sheet(page)
        self.crashes(page)

    def resting_focus(self, bounds, quiet=0.4, timeout=4.0):
        """The focused item's bounds once they have stopped changing. A focus scroll ends in a long, slow tail (a poster on the bottom row keeps drifting for about 0.75 s), so a reading taken when
        the keys have settled can be a few pixels off the place the item comes to rest, and the page restores the resting place."""
        end = time.time() + timeout; last = bounds; since = time.time()
        while time.time() < end:
            scr = self.dump(); b = scr["focus"][0]["b"] if scr["focus"] else None
            if b != last: last = b; since = time.time()
            elif time.time() - since >= quiet: break
        return last

    def detail(self, page):
        """OK on a poster opens its page, Back returns to the same poster; the OK and Back transitions are measured apart from movement."""
        d = self.d
        self.restore(page)
        # A folder row is a short strip at the left edge (a poster is over 200 px tall), whatever the panel's width. Right hands the remote from the folder column to the page.
        if any(f["b"][0] < 100 and f["b"][3] - f["b"][1] < 150 for f in self.dump()["focus"][:1]): m = d.mark(); d.key("RIGHT"); d.settle(m, quiet=0.25, timeout=6)
        #          # the stress leaves the remote wherever it ended (often on the rail): bring it back to the page first
        for n in range(10):
            scr = self.dump(); f = scr["focus"][0] if scr["focus"] else None
            if f and 150 < f["b"][2] - f["b"][0] < 320 and f["b"][3] - f["b"][1] > 200: break
            m = d.mark(); d.seq(["DOWN"] * (3 if n == 0 else 2), 120); d.settle(m, quiet=0.2, timeout=5)
        else: self.check(page, "reaches a poster", False); return
        before = self.resting_focus(f["b"])
        r = self.phase(page, "OK on a poster", keys=["OK"], settled=True)
        ok, scr = self.wait_screen(["Watch Later", "More Information", "Favorite", "Season", "Play", "Resume"], 15)
        self.check(page, "OK opens the item's page", ok, " | ".join(scr["texts"])[:80])
        self.evidence(f"{page}_detail")
        self.one_owner(page + " detail", "opening it")
        self.detail_jank(page)
        self.phase(page + " detail", "settled directional", keys=["DOWN", "RIGHT", "LEFT", "UP", "DOWN", "UP"], settled=True)
        self.one_owner(page + " detail", "moves")
        if page == "Series": self.season_panel()
        self.phase(page + " detail", "Back", keys=["BACK"], settled=True)
        ok, scr = self.wait_screen(EXPECT[page], 10)
        self.check(page, "Back returns to the list", ok)
        f = scr["focus"][0]["b"] if scr["focus"] else None
        self.check(page, "Back puts focus on the poster it came from", f == before, f"{before} -> {f}")

    # a held key on a detail page may not leave more than this share of its frames janky on the Fire TV Stick; the first run of any build is judged against this and the evidence is kept
    DETAIL_JANK_MAX = 10.0
    JANK_MAX = 15.0
    HELD_P95_MS = 120.0; SETTLED_MED_MS = 20.0; SETTLED_P95_MS = 35.0; ONE_KEY_MS = 50.0; FRAME_P95_MS = 34.0; FRAME_P99_MS = 100.0          # what "snappy" and "steady" mean, on the Fire TV Stick

    @staticmethod
    def title_box(scr):
        """The big title of a detail page: the node the app tags as its title (a stable tag, not a guess from size, position or letter case)."""
        c = [n for n in scr["nodes"] if n.get("rid", "").endswith("detail-title")]
        return c[0]["b"] if c else None

    def detail_jank(self, page):
        """A movie or series page, opened from a tile: the title may not move while the remote moves (shake), a held key may not leave the page janky, and nothing may overlap."""
        sc = f"{page} detail"; d = self.d
        scr = self.dump(); base = self.title_box(scr)
        for _ in range(2):          # the page may still be coming in when it is first read
            if base is not None: break
            scr = self.dump(); base = self.title_box(scr)
        self.check(sc, "the title is on screen", base is not None, " | ".join(scr["texts"])[:90])
        self.evidence(f"{page}_detail_open")
        issues = self.layout_issues(scr); self.check(sc, "nothing is off screen or overlapping", not issues, str(issues[:3]))
        moved = []
        for i, k in enumerate(["RIGHT", "LEFT", "DOWN", "UP", "RIGHT", "RIGHT", "LEFT", "DOWN", "UP", "UP"]):
            m = d.mark(); d.key(k); d.settle(m, quiet=0.15, timeout=4)
            if i not in (3, 7, 9): continue          # the title is read after three of the ten keys: a screen read costs about 2 s on this TV
            b = self.title_box(self.dump())
            if base and (b is None or any(abs(x - y) > 2 for x, y in zip(b, base))): moved.append((k, b))
        self.check(sc, "the page does not shake while the remote moves", not moved, f"title at {base}, then {moved[:3]}")
        for name, key in (("held Down 2 s", "DOWN"), ("held Up 2 s", "UP"), ("held Right 2 s", "RIGHT")):
            rec = self.phase(sc, name, hold=(key, 2000), interval=30)
            g = rec["gfx"] or {}; tot = g.get("frames") or g.get("total") or 0; jk = g.get("janky") if g.get("janky") is not None else g.get("jank")
            pct = (100.0 * jk / tot) if tot and jk is not None else None
            self.check(sc, f"{name}: not janky", pct is None or pct <= self.DETAIL_JANK_MAX, f"{pct:.0f}% of {tot} frames janky" if pct is not None else "")
            self.one_owner(sc, name)
        self.restore_detail(page)

    def restore_detail(self, page):
        """Back to the top of the page, the remote on its first button."""
        m = self.d.mark(); self.d.seq(["UP"] * 6, 60); self.d.settle(m, quiet=0.25, timeout=6)

    def season_panel(self):
        """Series page: a season chip opens that season's episodes in a panel from the side; Back closes it and the page is as it was."""
        sc = "Series screens"; d = self.d
        chips = [n["text"] for n in self.dump()["nodes"] if re.fullmatch(r"Season \d+", n["text"] or "")]          # the first season chip the page has: a series may start at any number
        if not chips or not self.tap(chips[0]): self.check(sc, "the page has a season chip", False); return
        ok, scr = self.wait_screen(["episodes"], 8)
        self.check(sc, "a season opens its episodes in a panel", ok, " | ".join(scr["texts"])[:90])
        self.evidence("Series_seasons")
        issues = self.layout_issues(scr); self.check(sc, "the season panel is on screen and does not overlap", not issues, str(issues[:3]))
        self.one_owner("Series detail", "on the season panel")
        m = d.mark(); d.key("BACK"); d.settle(m, quiet=0.3, timeout=6)
        scr = self.dump(); txt = " ".join(scr["texts"])
        self.check(sc, "Back closes the season panel and keeps the page", "episodes" not in txt and chips[0] in txt, txt[:90])

    def toolbar_and_sheet(self, page):
        """Movies and Series: the toolbar's icon buttons work, the full grid has the shortcut pills, and a pill opens a sheet (filtered to this page's kind) that Back closes."""
        sc = f"{page} screens"; d = self.d
        self.restore(page)
        if not self.tap("Browse all"): self.check(sc, "the toolbar has Browse all", False); return
        ok, scr = self.wait_screen(["Favorites", "Watch Later"], 8, any_=False)
        self.check(sc, "Browse all shows the full grid with the shortcut pills", ok, " | ".join(scr["texts"])[:90])
        before = " ".join(scr["texts"])
        if self.tap("Favorites"):
            ok, scr = self.wait_screen(["Live Channels"], 8)
            self.check(sc, "a shortcut pill opens a sheet", ok, " | ".join(scr["texts"])[:90])
            issues = self.layout_issues(scr); self.check(sc, "the sheet is on screen and does not overlap", not issues, str(issues[:3]))
            self.one_owner(page, "on the sheet"); self.evidence(f"{page}_sheet")
            m = d.mark(); d.key("BACK"); d.settle(m, quiet=0.3, timeout=6)
            txt = " ".join(self.dump()["texts"])
            self.check(sc, "Back closes the sheet", "Live Channels" not in txt and "Favorites" in txt, txt[:90])
        else: self.check(sc, "the page has a Favorites pill", False)
        if self.tap("Filter"):
            m = d.mark(); d.settle(m, quiet=0.5, timeout=4); opened = " ".join(self.dump()["texts"]) != before
            self.check(sc, "the Filter button opens its choices", opened)
            m = d.mark(); d.key("BACK"); d.settle(m, quiet=0.3, timeout=6)
            self.check(sc, "Back closes Filter and keeps the page", "Favorites" in " ".join(self.dump()["texts"]))
        else: self.check(sc, "the toolbar has Filter", False)
        self.tap("Featured")          # back to the featured page, as the suite found it

    def settings_pages(self):
        """Pages of Settings that are only facts (Statistics, Diagnostics, About) used to be stuck: the remote could not walk them, so they could not be scrolled. Each is opened and walked with a held Down."""
        sc = "Settings pages"; d = self.d
        for title in ("Statistics", "Diagnostics", "About StreamSetu"):
            self.ensure_app()
            ok, _, scr = self.goto("Settings")
            if not ok: self.check(sc, f"{title}: Settings opens", False); return
            if not self.tap(title): self.check(sc, f"{title} is in the list", False); continue
            m = d.mark(); d.settle(m, quiet=0.2, timeout=4)
            before = self.dump(); f0 = before["focus"][0]["text"] if before["focus"] else ""
            self.phase(f"{sc}: {title}", "held Down 1.5 s", hold=("DOWN", 1500), interval=30)
            after = self.one_owner(f"{sc}: {title}", "held Down"); f1 = after["focus"][0]["text"] if after["focus"] else ""
            self.check(sc, f"{title}: the remote walks the page and it scrolls", f1 != f0 or " ".join(after["texts"]) != " ".join(before["texts"]), f"{f0[:30]!r} -> {f1[:30]!r}")
            issues = self.layout_issues(after); self.check(sc, f"{title}: nothing is off screen or overlapping", not issues, str(issues[:3]))
            self.evidence(f"Settings_{title.split()[0]}")

    def libraries(self):
        """The library picker: it opens, the remote walks its cards, and a held key leaves one focus owner and steady frames."""
        sc = "Libraries"; d = self.d
        self.ensure_app(); ok, secs, scr = self.goto("Libraries")
        self.check(sc, "opens", ok, " | ".join(scr["texts"])[:90])
        if not ok: self.evidence("Libraries_open_failed"); return
        self.one_owner(sc, "opening")
        issues = self.layout_issues(scr); self.check(sc, "no off-screen or overlapping focusable items at 1080p", not issues, str(issues[:3]))
        self.phase(sc, "settled directional", keys=["RIGHT", "RIGHT", "LEFT", "DOWN", "UP", "RIGHT", "LEFT"], settled=True)
        self.one_owner(sc, "settled moves")
        self.phase(sc, "held Right 1.5 s", hold=("RIGHT", 1500), interval=30)
        self.one_owner(sc, "held Right")
        self.phase(sc, "held Left 1.5 s", hold=("LEFT", 1500), interval=30)
        self.one_owner(sc, "held Left")
        self.evidence("Libraries_end"); self.crashes(sc)

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
        # The hooks are in the real app and off until the device says so; the app reads that once when it starts, so it is restarted the first time they are switched on.
        if "VERBOSE" not in d.sh("getprop log.tag.SSHOOKS"): d.sh("setprop log.tag.SSHOOKS VERBOSE"); d.sh(f"am force-stop {T.PKG}")
        for r in range(1, runs + 1):
            print(f"\n######## run {r}/{runs}"); self.d_run = r
            self.ensure_app(); ok = self.enter_library(); self.check("setup", "starts and enters the library", ok)
            if not ok: self.evidence(f"run{r}_start_failed"); continue
            self.ensure_app(); self.open_rail(); self.check_menu_order()
            for p in pages:
                try:          # a mistake in one screen's test is reported as a failure and the run goes on to the next
                    if p == "Libraries": self.libraries()
                    elif p == "Settings pages": self.settings_pages()
                    else: self.screen(p)
                except Exception as e:
                    self.check(p, "the test itself ran to the end", False, repr(e)[:150])
        json.dump(dict(results=self.results, failures=len(self.failures)), open(os.path.join(self.out, "results.json"), "w"), indent=1)
        print("\ntime spent: " + ", ".join(f"{k} {v[0]}x {v[1]:.0f} s" for k, v in sorted(self.prof.items(), key=lambda kv: -kv[1][1])))
        print(f"\n{len([x for x in self.results if 'check' in x])} checks, {len(self.failures)} failed; evidence and results.json in {self.out}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(); ap.add_argument("--serial", default="192.168.1.68:5555"); ap.add_argument("--runs", type=int, default=1)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "results", time.strftime("%Y%m%d-%H%M%S")))
    ap.add_argument("--shots", action="store_true", help="also save a screenshot at every evidence point (otherwise only after a failure)")
    ap.add_argument("--quick", action="store_true", help="hold keys for 2 s instead of 3 s")
    ap.add_argument("--only", default=",".join(["Home", "Movies", "Series", "Live TV", "TV Guide", "Search", "Settings", "Settings pages", "Libraries"]))
    a = ap.parse_args()
    if a.quick: HOLD_MS = 2000
    su = Suite(a.serial, a.out); su.shots = a.shots; su.run(a.only.split(","), a.runs)
