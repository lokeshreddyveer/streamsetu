#!/usr/bin/env python3
"""
Every screen, every time, on every TV that is connected, at once.

  run_all.py [--devices 192.168.1.67:5555,192.168.1.68:5555] [--apk path] [--quick] [--pkg app.streamsetu.tv.benchmark]

The screens are split between the TVs (the heavy ones apart), each TV runs run_suite.py on its share at the same time, and one report is printed at the end: every failed check, the timing lines
that matter (a held key, OK on a poster, Back), and a total. --apk installs the build on every TV first and compiles it fully, so every TV starts from the same footing.
Exit code 1 when anything failed.
"""
import argparse, concurrent.futures as cf, os, re, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
ADB = "adb"
ALL = ["Home", "Movies", "Series", "Live TV", "TV Guide", "Search", "Settings", "Settings pages", "Libraries"]
SPLIT = [["Home", "Movies", "Search", "Libraries"], ["Series", "Live TV", "TV Guide", "Settings", "Settings pages"]]          # Movies and Series on different TVs


def prepare(serial, apk, pkg):
    if apk:
        # a build that is already installed and fully compiled on this TV is not installed again (the sum of the apk is kept on the TV)
        sha = subprocess.run(["shasum", apk], capture_output=True, text=True).stdout.split()[0]
        have = subprocess.run([ADB, "-s", serial, "shell", "cat /sdcard/.suite_apk 2>/dev/null"], capture_output=True, text=True).stdout.strip()
        if have != sha:
            subprocess.run([ADB, "-s", serial, "install", "-r", apk], capture_output=True, timeout=300)
            subprocess.run([ADB, "-s", serial, "shell", "cmd", "package", "compile", "-f", "-m", "speed", pkg], capture_output=True, timeout=300)
            subprocess.run([ADB, "-s", serial, "shell", f"echo {sha} > /sdcard/.suite_apk"], capture_output=True, timeout=30)
    subprocess.run([ADB, "-s", serial, "shell", "input keyevent 224; am force-stop " + pkg + "; am start -n " + pkg + "/app.streamsetu.tv.MainActivity"], capture_output=True, timeout=60)
    time.sleep(3)


def run_one(serial, pages, out, pkg, quick):
    cmd = [sys.executable, "-u", os.path.join(HERE, "run_suite.py"), "--serial", serial, "--out", out, "--only", ",".join(pages)] + (["--quick"] if quick else [])
    r = subprocess.run(cmd, capture_output=True, text=True, env=dict(os.environ, PKG=pkg), timeout=3600)
    return serial, pages, r.stdout + r.stderr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--devices", default="192.168.1.67:5555,192.168.1.68:5555"); ap.add_argument("--apk"); ap.add_argument("--quick", action="store_true")
    ap.add_argument("--pkg", default="app.streamsetu.tv.benchmark"); ap.add_argument("--pages", default=",".join(ALL))
    a = ap.parse_args()
    devs = [d for d in a.devices.split(",") if d]; pages = a.pages.split(",")
    live = [d for d in devs if subprocess.run([ADB, "-s", d, "get-state"], capture_output=True, text=True).stdout.strip() == "device"]
    if not live: print("no TV is connected"); return 2
    shares = [[p for p in grp if p in pages] for grp in SPLIT] if len(live) > 1 else [pages]
    if len(live) > 1 and any(p not in sum(SPLIT, []) for p in pages): shares[0] += [p for p in pages if p not in sum(SPLIT, [])]
    stamp = time.strftime("%H%M%S"); t0 = time.time()
    with cf.ThreadPoolExecutor() as ex: list(ex.map(lambda d: prepare(d, a.apk, a.pkg), live))
    jobs = [(d, sh, os.path.join(HERE, "results", f"all_{stamp}_{i}")) for i, (d, sh) in enumerate(zip(live, shares)) if sh]
    with cf.ThreadPoolExecutor() as ex: outs = list(ex.map(lambda j: run_one(j[0], j[1], j[2], a.pkg, a.quick), jobs))
    fails = 0; total = 0
    for serial, share, text in outs:
        print(f"\n==== {serial}: {', '.join(share)}")
        for l in text.splitlines():
            if l.startswith("FAIL"): print(l[:200])
            elif re.search(r"(held Down|held Up|OK on a poster|^\s+Back  )", l): print("   " + l.strip()[:175])
            elif l.startswith("time spent"): print(l[:200])
            m = re.search(r"(\d+) checks, (\d+) failed", l)
            if m: total += int(m.group(1)); fails += int(m.group(2))
    print(f"\nALL SCREENS: {total} checks, {fails} failed, {time.time() - t0:.0f} s on {len(live)} TV(s)")
    return 1 if fails else 0


if __name__ == "__main__": sys.exit(main())
