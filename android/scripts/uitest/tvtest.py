"""
Reusable Fire TV / Android TV UI test library (standard library only).

What it does: sends keys into the real input pipeline from a small on-device injector (injector/Inj.java, built by build-injector.sh) so keys can be 30 ms apart,
reads the app's own trace from logcat (SSTRACE: focus, blur, navigation state; KeyLatency: key to first finished frame; Motion: frame totals) and waits for the screen
to settle by polling that log with a bounded timeout. There are no fixed sleeps between steps.

What it is not: a remote. Keys come from InputManager.injectInputEvent, so a 30 ms interval is a STRESS WORKLOAD for the app's handling of keys, not the latency a person feels with a
physical remote. Report it as that.

The app must be a debuggable build with the key recorder (KeyLatency) and the trace switched on:  adb shell setprop log.tag.SSTRACE VERBOSE  (read when the app starts).
"""
import json, os, re, statistics, subprocess, sys, threading, time

KEY = dict(UP=19, DOWN=20, LEFT=21, RIGHT=22, OK=23, BACK=4, HOME=3)
PKG = os.environ.get("PKG", "app.streamsetu.tv")
ADB = os.environ.get("ADB", os.path.expanduser("~/Library/Android/sdk/platform-tools/adb"))


def pct(values, p):
    v = sorted(values)
    if not v: return None
    k = (len(v) - 1) * p; i = int(k); j = min(i + 1, len(v) - 1)
    return v[i] + (v[j] - v[i]) * (k - i)


def stats(values):
    return dict(n=len(values), median=round(statistics.median(values), 1), p95=round(pct(values, .95), 1), worst=round(max(values), 1)) if values else dict(n=0)


class Device:
    def __init__(self, serial):
        self.serial = serial
        self.lock = threading.Lock()
        self.events = []                       # (epoch_seconds, tag, message), in arrival order
        self.focused = set()                   # bounds of everything that has taken focus and not yet lost it
        self.state = {}                        # the last "state tab=... overlay=..." line, as a dict
        self.last_focus = None
        self._logcat = None; self.inj = None; self.inj_out = []

    # ---- adb -------------------------------------------------------------------------------------------------------------------------
    def adb(self, *args, timeout=60, binary=False):
        r = subprocess.run([ADB, "-s", self.serial, *args], capture_output=True, timeout=timeout)
        return r.stdout if binary else r.stdout.decode("utf8", "replace")

    def sh(self, cmd, timeout=60): return self.adb("shell", cmd, timeout=timeout)

    def pid(self): return self.sh(f"pidof {PKG}").strip()

    # ---- log reader ------------------------------------------------------------------------------------------------------------------
    def start_log(self):
        self.adb("logcat", "-c")
        self._logcat = subprocess.Popen([ADB, "-s", self.serial, "logcat", "-v", "epoch", "-s", "KeyLatency:I", "SSTRACE:V", "Motion:I", "AndroidRuntime:E", "ActivityManager:E", "ANRManager:E", "libc:F", "DEBUG:F"],
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
        threading.Thread(target=self._read_log, daemon=True).start()

    def _read_log(self):
        rx = re.compile(r"^\s*(\d+\.\d+)\s+\d+\s+\d+\s+([A-Z])\s+(\S+)\s*:\s?(.*)$")
        for line in self._logcat.stdout:
            m = rx.match(line.rstrip("\n"))
            if not m: continue
            ts, _, tag, msg = float(m[1]), m[2], m[3], m[4]
            with self.lock:
                self.events.append((ts, tag, msg))
                if tag == "SSTRACE": self._trace(msg)

    def _trace(self, msg):
        if msg.startswith("state "): self.state = dict(re.findall(r"(\w+)=(\S+)", msg))
        elif msg.startswith("focus ") or msg.startswith("blur "):
            b = tuple(int(x) for x in re.findall(r"[ltrb]=(-?\d+)", msg)[:4])
            if len(b) == 4:
                if msg.startswith("focus"): self.focused.add(b); self.last_focus = b
                else: self.focused.discard(b)
        # a focus line carries no owner id: an element that loses focus writes "blur" with its own bounds

    def mark(self):
        with self.lock: return len(self.events)

    def since(self, mark, tag=None):
        with self.lock: ev = self.events[mark:]
        return [e for e in ev if tag is None or e[1] == tag]

    # ---- injector --------------------------------------------------------------------------------------------------------------------
    def start_injector(self):
        dex = os.path.join(os.path.dirname(__file__), "injector", "inj.dex")
        self.adb("push", dex, "/data/local/tmp/inj.dex")
        self.inj = subprocess.Popen([ADB, "-s", self.serial, "shell", "CLASSPATH=/data/local/tmp/inj.dex app_process /system/bin Inj"],
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        self._inj_lines = []; self._inj_cv = threading.Condition()
        threading.Thread(target=self._read_inj, daemon=True).start()
        self._wait_inj(lambda l: l == "ready", 20)

    def _read_inj(self):
        for line in self.inj.stdout:
            with self._inj_cv: self._inj_lines.append(line.strip()); self._inj_cv.notify_all()

    def _wait_inj(self, pred, timeout):
        end = time.time() + timeout
        with self._inj_cv:
            while True:
                for i, l in enumerate(self._inj_lines):
                    if pred(l): return self._inj_lines[:i + 1]
                left = end - time.time()
                if left <= 0: raise TimeoutError("injector did not answer")
                self._inj_cv.wait(left)

    def send(self, cmd, timeout=30, _retry=True):
        """Run one injector command and return the 'sent ...' lines it produced (code, repeat, uptime ms the key was stamped). A dead injector is started again once."""
        try:
            with self._inj_cv: self._inj_lines.clear()
            self.inj.stdin.write(cmd + "\n"); self.inj.stdin.flush()
            lines = self._wait_inj(lambda l: l.startswith("done"), timeout)
        except (TimeoutError, BrokenPipeError, OSError):
            if not _retry: raise
            print("      (the key injector stopped answering; starting it again)"); sys.stdout.flush()
            try: self.inj.kill()
            except Exception: pass
            self.sh("pkill -f 'app_process /system/bin Inj'"); self.start_injector()
            return self.send(cmd, timeout, _retry=False)
        return [tuple(int(x) for x in re.findall(r"(\d+)", l)) for l in lines if l.startswith("sent")]

    def key(self, name): return self.send(f"tap {KEY[name]}")
    def seq(self, names, interval_ms=30): return self.send("seq %d %s" % (interval_ms, " ".join(str(KEY[n]) for n in names)), timeout=30 + len(names) * interval_ms // 1000)
    def hold(self, name, ms=3000, period=30): return self.send(f"hold {KEY[name]} {ms} {period}", timeout=ms // 1000 + 20)

    # ---- waiting: poll the log, never sleep for a fixed time -----------------------------------------------------------------------
    def settle(self, mark, quiet=0.30, timeout=8.0):
        """Wait until the app has written nothing about keys, focus or navigation for `quiet` seconds. Returns (events_since_mark, settled?)."""
        t0 = time.time(); last = time.time(); n = self.mark()
        while time.time() - t0 < timeout:
            time.sleep(0.01)                     # the poll interval, not a wait for the app
            m = self.mark()
            if m != n: n = m; last = time.time()
            elif time.time() - last >= quiet: return self.since(mark), True
        return self.since(mark), False

    def wait_for(self, pred, timeout=8.0):
        t0 = time.time()
        while time.time() - t0 < timeout:
            if pred(): return True
            time.sleep(0.01)
        return False

    # ---- measurements ----------------------------------------------------------------------------------------------------------------
    def gfx_reset(self): self.sh(f"dumpsys gfxinfo {PKG} reset")

    def gfx(self):
        t = self.sh(f"dumpsys gfxinfo {PKG}")
        g = lambda rx: (lambda m: float(m[1]) if m else None)(re.search(rx, t))
        return dict(frames=g(r"Total frames rendered: (\d+)"), janky=g(r"Janky frames: (\d+)"), p50=g(r"50th percentile: (\d+)ms"), p90=g(r"90th percentile: (\d+)ms"),
                    p95=g(r"95th percentile: (\d+)ms"), p99=g(r"99th percentile: (\d+)ms"), missed_vsync=g(r"Number Missed Vsync: (\d+)"), slow_ui=g(r"Number Slow UI thread: (\d+)"))

    def cpu_mem(self):
        """CPU and memory of the app in one trip to the TV (the four reads used to be four)."""
        out = self.sh(f"P=$(pidof {PKG}); echo PID $P; top -b -n 1 -d 1 -p $P; echo ==MEM; dumpsys meminfo $P; echo ==AVAIL; grep MemAvailable /proc/meminfo")
        pid = (re.search(r"^PID\s+(\d+)", out, re.M) or [None, ""])[1]
        top, _, rest = out.partition("==MEM"); mem, _, avail_s = rest.partition("==AVAIL")
        cpu = re.search(r"^\s*\d+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S\s+(\d+(?:\.\d+)?)", top, re.M)
        pss = re.search(r"TOTAL PSS:\s+(\d+)", mem); gfx = re.search(r"Graphics:\s+(\d+)", mem); java = re.search(r"Java Heap:\s+(\d+)", mem); nat = re.search(r"Native Heap:\s+(\d+)", mem)
        avail = re.search(r"MemAvailable:\s+(\d+)", avail_s)
        return dict(pid=pid, cpu_pct=float(cpu[1]) if cpu else None, pss_kb=int(pss[1]) if pss else None, graphics_kb=int(gfx[1]) if gfx else None,
                    java_kb=int(java[1]) if java else None, native_kb=int(nat[1]) if nat else None, mem_available_kb=int(avail[1]) if avail else None)

    def screenshot(self, path):
        with open(path, "wb") as f: f.write(self.adb("exec-out", "screencap", "-p", binary=True))

    def ui_dump(self, path=None):
        """The screen's accessibility tree: every node's bounds, and which one has focus."""
        self.sh("uiautomator dump /sdcard/uitest.xml", timeout=90)
        xml = self.adb("exec-out", "cat", "/sdcard/uitest.xml", timeout=30)
        if path: open(path, "w").write(xml)
        return xml


# ---- reading where the app is ----------------------------------------------------------------------------------------------------------
def _screen_of(ev):
    """Screen name and key of the last KeyLatency line in a list of log events."""
    for e in reversed(ev):
        if e[1] == "KeyLatency":
            m = re.match(r"screen=(\S+) key=(\S+)", e[2])
            if m: return m[1]
    return None


def ping(d, timeout=3.0):
    """Sends KEYCODE_UNKNOWN (changes nothing in the app) and returns the screen name the app reports for it, or None."""
    m = d.mark(); d.send("tap 0")
    d.wait_for(lambda: any(e[1] == "KeyLatency" and "key=UNKNOWN" in e[2] for e in d.since(m)), timeout)
    return _screen_of(d.since(m))


def foreground(d): return PKG in d.sh("dumpsys window | grep mCurrentFocus")


def launch(d, timeout=60):
    """Brings the app to the front (starting it when it is not running) and waits until something on screen has focus."""
    if not foreground(d): d.sh(f"am start -n {PKG}/app.streamsetu.tv.MainActivity")
    d.wait_for(lambda: foreground(d), timeout)
    return d.wait_for(lambda: len(d.focused) >= 1, timeout)
