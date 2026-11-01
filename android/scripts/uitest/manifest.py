#!/usr/bin/env python3
"""Labels a test run: which build, which focus setting, which source, what state the TV was in. Printed and saved as manifest.json in the given folder (or the newest results folder)."""
import json, os, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
def sh(*a, **k): return subprocess.run(a, capture_output=True, text=True, **k).stdout.strip()
def main():
    serial = os.environ.get("SERIAL", "192.168.1.67:5555"); adb = ["adb", "-s", serial, "shell"]
    apk = os.path.join(ROOT, "app/build/outputs/apk/benchmark/app-benchmark.apk")
    diff = subprocess.run(["git", "-C", ROOT, "diff", "HEAD"], capture_output=True).stdout
    meminfo = sh(*adb, "grep -E 'MemTotal|MemAvailable|SwapTotal|SwapFree' /proc/meminfo")
    temps = sh(*adb, "for z in /sys/class/thermal/thermal_zone*; do echo $(cat $z/type) $(cat $z/temp); done 2>/dev/null")
    m = dict(
        taken=time.strftime("%Y-%m-%d %H:%M:%S"), serial=serial,
        apk=dict(path=apk, bytes=os.path.getsize(apk), built=time.strftime("%H:%M:%S", time.localtime(os.path.getmtime(apk))), sha1=sh("shasum", apk).split()[0]),
        installed=sh(*adb, "dumpsys package app.streamsetu.tv.benchmark | grep -E 'versionName|lastUpdateTime'").replace("\n", "; "),
        fast_focus_property=sh(*adb, "getprop debug.streamsetu.fastfocus") or "(unset: instant focus on)",
        source=dict(commit=sh("git", "-C", ROOT, "rev-parse", "--short", "HEAD"), changed_files=len(sh("git", "-C", ROOT, "status", "--short").splitlines()),
                    working_tree_diff_sha1=__import__("hashlib").sha1(diff).hexdigest()),
        memory_kb={l.split(":")[0]: int(l.split()[1]) for l in meminfo.splitlines() if ":" in l},
        thermal=temps.splitlines() if temps else "not readable on this TV",
    )
    out = sys.argv[1] if len(sys.argv) > 1 else None
    if out is None:
        base = os.path.join(HERE, "results"); out = os.path.join(base, sorted(os.listdir(base), key=lambda d: os.path.getmtime(os.path.join(base, d)))[-1])
    os.makedirs(out, exist_ok=True); json.dump(m, open(os.path.join(out, "manifest.json"), "w"), indent=1)
    print(json.dumps(m, indent=1)); print("saved in", out)
main()
