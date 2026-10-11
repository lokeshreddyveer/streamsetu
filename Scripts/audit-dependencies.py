#!/usr/bin/env python3
"""Looks up every pinned dependency in the public OSV vulnerability database, and runs npm audit for the website.

  Scripts/audit-dependencies.py            report only
  Scripts/audit-dependencies.py --strict   exit 1 if anything is reported (for release scripts)

Offline is not a failure: it says so and carries on. Pinned libraries are read from the Swift package files; the Mac app's bundled
libmpv stack is listed with its file names so it can be checked by hand, because it has no package manifest.
"""
import json, pathlib, subprocess, sys, urllib.request

repo = pathlib.Path(__file__).resolve().parent.parent
problems = 0

def osv(name, version):
    body = json.dumps({"package": {"name": name, "ecosystem": "SwiftURL"}, "version": version}).encode()
    req = urllib.request.Request("https://api.osv.dev/v1/query", body, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r).get("vulns", [])

print("Swift packages")
pins = []
for f in repo.glob("**/Package.resolved"):
    if "node_modules" in f.parts or ".build" in f.parts: continue
    for p in json.loads(f.read_text()).get("pins", []):
        pins.append((p["location"].removesuffix(".git").removeprefix("https://"), p["state"].get("version") or p["state"].get("revision", "")[:12]))
for name, version in sorted(set(pins)):
    try:
        v = osv(name, version)
    except Exception as e:
        print(f"  ? {name} {version}: could not check ({e.__class__.__name__}); are you online?"); continue
    if v:
        problems += len(v); print(f"  ✘ {name} {version}: " + ", ".join(x["id"] for x in v))
    else:
        print(f"  ✔ {name} {version}: no known vulnerabilities")
if not pins: print("  (none found)")

print("Website packages (npm audit)")
web = repo / "web"
if (web / "package-lock.json").exists():
    r = subprocess.run(["npm", "audit", "--omit=dev", "--json"], cwd=web, capture_output=True, text=True)
    try:
        t = json.loads(r.stdout)["metadata"]["vulnerabilities"]
        n = t.get("high", 0) + t.get("critical", 0) + t.get("moderate", 0) + t.get("low", 0)
        problems += n
        print(f"  {'✘' if n else '✔'} {n} known vulnerabilities (critical {t.get('critical',0)}, high {t.get('high',0)}, moderate {t.get('moderate',0)}, low {t.get('low',0)})")
    except Exception:
        print("  ? npm audit could not run")

mpv = repo / "macos/third_party/libmpv"
if mpv.exists():
    print("Mac bundled libraries (check these by hand against their projects' security notices):")
    for f in sorted(mpv.glob("*.dylib")): print("  -", f.name)

print("\nResult:", "vulnerabilities reported above" if problems else "nothing reported")
sys.exit(1 if problems and "--strict" in sys.argv else 0)
