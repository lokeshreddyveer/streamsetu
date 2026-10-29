#!/usr/bin/env python3
"""Looks up every pinned dependency in the public OSV vulnerability database, runs npm audit for the website, and checks the Mac app's bundled media libraries.

  Scripts/audit-dependencies.py                        report only (always exits 0; the report says which of the three outcomes it is)
  Scripts/audit-dependencies.py --strict               exit 1 if a vulnerability is reported, 2 if something could not be checked (for release scripts)
  Scripts/audit-dependencies.py --report FILE          also write the result as JSON (kept with the release)
  Scripts/audit-dependencies.py --scope mac|ios|android  only what that product ships (the bundled Mac libraries are checked for "mac" and when no scope is given)
  Scripts/audit-dependencies.py --sbom FILE            also write a CycloneDX SBOM of the Mac app's bundled libraries

Three outcomes are kept apart: clean (0), vulnerable (1) and unknown (2: offline, a lookup failed, or something could not be identified).

Bundled Mac libraries (macos/third_party/libmpv/*.dylib) have no package manifest, so they are identified from the files themselves (install name, version, SHA-256) and
checked against macos/third_party/libmpv-components.json, which records for each library its upstream project, exact upstream revision, and the date its security advisories were
last reviewed. A library is "unknown" (blocks a strict run) when it is missing from that file, its file or version differs from what was reviewed, no exact upstream revision is
recorded, or the review is older than 30 days. A recorded revision is also looked up in OSV by commit.

Overrides: a finding can be accepted only through Scripts/risk-acceptances.json, signed (ssh-keygen -Y sign, namespace "streamsetu-risk") by a key listed in Scripts/allowed_signers,
each entry with an owner, a reason and an expiry at most 90 days after it was accepted. Anything else is not an override. See docs/RELEASE-SECURITY.md.
"""
import datetime, hashlib, json, pathlib, re, subprocess, sys, tempfile, urllib.request

repo = pathlib.Path(__file__).resolve().parent.parent
problems = 0
unknown = 0
results = {"generated": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"), "swift": [], "web": None, "mac": [], "accepted": []}
REVIEW_MAX_DAYS = 30
ACCEPT_MAX_DAYS = 90

def arg(name):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv and sys.argv.index(name) + 1 < len(sys.argv) else None

def load_acceptances():
    """The accepted finding ids with their entries, only if the file's signature verifies and each entry is complete and unexpired."""
    f, sig, signers = repo / "Scripts/risk-acceptances.json", repo / "Scripts/risk-acceptances.json.sig", repo / "Scripts/allowed_signers"
    if not f.exists(): return {}
    if not (sig.exists() and signers.exists()):
        print("  ! Scripts/risk-acceptances.json is ignored: it has no signature or no Scripts/allowed_signers"); return {}
    try:
        who = f.read_text()
        entries = json.loads(who)
    except Exception:
        print("  ! Scripts/risk-acceptances.json is ignored: not valid JSON"); return {}
    ok = False
    for line in signers.read_text().splitlines():
        ident = line.split()[0] if line.strip() and not line.startswith("#") else None
        if not ident: continue
        r = subprocess.run(["ssh-keygen", "-Y", "verify", "-f", str(signers), "-I", ident, "-n", "streamsetu-risk", "-s", str(sig)], input=who, capture_output=True, text=True)
        if r.returncode == 0: ok = True; break
    if not ok:
        print("  ! Scripts/risk-acceptances.json is ignored: its signature does not verify"); return {}
    out, today = {}, datetime.date.today()
    for e in entries:
        try:
            given, until = datetime.date.fromisoformat(e["accepted_on"]), datetime.date.fromisoformat(e["expires"])
            assert e["id"] and e["owner"].strip() and len(e["reason"].strip()) >= 20 and (until - given).days <= ACCEPT_MAX_DAYS
        except Exception:
            print(f"  ! an entry in the risk acceptances is incomplete or lasts more than {ACCEPT_MAX_DAYS} days and is ignored: {e.get('id')}"); continue
        if until < today: print(f"  ! the risk acceptance for {e['id']} expired on {e['expires']}"); continue
        out[e["id"]] = e
    return out

import json, pathlib, subprocess, sys, urllib.request

repo = pathlib.Path(__file__).resolve().parent.parent
problems = 0
unknown = 0

def osv(name, version):
    body = json.dumps({"package": {"name": name, "ecosystem": "SwiftURL"}, "version": version}).encode()
    req = urllib.request.Request("https://api.osv.dev/v1/query", body, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r).get("vulns", [])

def osv_commit(commit):
    body = json.dumps({"commit": commit}).encode()
    req = urllib.request.Request("https://api.osv.dev/v1/query", body, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r).get("vulns", [])

print("Risk acceptances")
accepted = load_acceptances()
print("  " + (", ".join(sorted(accepted)) if accepted else "(none)"))

def count_vuln(label, ids):
    """Counts the ids that are not accepted; returns whether any remain."""
    global problems
    left = [i for i in ids if i not in accepted]
    for i in ids:
        if i in accepted: results["accepted"].append({"id": i, "for": label, "owner": accepted[i]["owner"], "expires": accepted[i]["expires"]})
    problems += len(left)
    return left

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
        unknown += 1; print(f"  ? {name} {version}: could not check ({e.__class__.__name__}); are you online?"); continue
    left = count_vuln(f"{name} {version}", [x["id"] for x in v])
    results["swift"].append({"package": name, "version": version, "vulnerabilities": [x["id"] for x in v], "unaccepted": left})
    if left:
        print(f"  ✘ {name} {version}: " + ", ".join(left))
    else:
        print(f"  ✔ {name} {version}: " + ("only accepted findings" if v else "no known vulnerabilities"))
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
        unknown += 1; print("  ? npm audit could not run")

def mac_libraries():
    """Each bundled dylib as the files themselves say: install name, current version and SHA-256."""
    mpv = repo / "macos/third_party/libmpv"
    libs = []
    for f in sorted(mpv.glob("*.dylib")) if mpv.exists() else []:
        out = subprocess.run(["otool", "-arch", "all", "-L", str(f)], capture_output=True, text=True).stdout
        m = re.search(r"\(compatibility version [\d.]+, current version ([\d.]+)\)", out.split("\n", 3)[1] + "\n" + (out.split("\n")[2] if len(out.split("\n")) > 2 else ""))
        libs.append({"file": f.name, "version": m.group(1) if m else None, "sha256": hashlib.sha256(f.read_bytes()).hexdigest()})
    return libs

scope = arg("--scope") or "all"
print("Mac bundled libraries")
libs = mac_libraries() if scope in ("all", "mac") else []
manifest_path = repo / "macos/third_party/libmpv-components.json"
manifest = {c["file"]: c for c in json.loads(manifest_path.read_text()).get("components", [])} if manifest_path.exists() else {}
today = datetime.date.today()
for lib in libs:
    c, why = manifest.get(lib["file"]), None
    if c is None: why = "not in macos/third_party/libmpv-components.json (no known upstream project)"
    elif c.get("sha256") != lib["sha256"] or c.get("version") != lib["version"]: why = "the file is not the one that was reviewed (version or hash differs)"
    elif not c.get("upstream_revision"): why = "no exact upstream revision recorded, so it cannot be looked up"
    else:
        try: reviewed = datetime.date.fromisoformat(c.get("advisories_reviewed", ""))
        except Exception: reviewed = None
        if not reviewed or (today - reviewed).days > REVIEW_MAX_DAYS: why = f"advisories not reviewed in the last {REVIEW_MAX_DAYS} days"
    entry = {**lib, "upstream": (c or {}).get("project"), "upstream_revision": (c or {}).get("upstream_revision"), "vulnerabilities": [], "problem": why}
    if why is None:
        try:
            v = [x["id"] for x in osv_commit(c["upstream_revision"])]
            entry["vulnerabilities"] = v
            left = count_vuln(lib["file"], v)
            if left: why = "vulnerabilities reported: " + ", ".join(left)
        except Exception as e:
            why = f"could not check ({e.__class__.__name__})"
    if why is not None and f"mac:{lib['file']}" in accepted:
        results["accepted"].append({"id": f"mac:{lib['file']}", "for": why, "owner": accepted[f"mac:{lib['file']}"]["owner"], "expires": accepted[f"mac:{lib['file']}"]["expires"]}); why = None
    entry["problem"] = why
    if why is not None:
        if why.startswith("vulnerabilities"): pass            # already counted
        else: unknown += 1
        print(f"  {'✘' if why.startswith('vulnerabilities') else '?'} {lib['file']} {lib['version']}: {why}")
    results["mac"].append(entry)
if not libs: print("  (none for this scope)")
else: print(f"  {sum(1 for e in results['mac'] if not e['problem'])} of {len(libs)} libraries checked and clean")

sbom = arg("--sbom")
if sbom:
    comps = [{"type": "library", "name": l["file"], "version": l["version"] or "unknown", "hashes": [{"alg": "SHA-256", "content": l["sha256"]}],
              "properties": [{"name": "upstream", "value": e.get("upstream") or "unidentified"}, {"name": "upstream_revision", "value": e.get("upstream_revision") or "unrecorded"}]}
             for l, e in zip(libs, results["mac"])]
    pathlib.Path(sbom).write_text(json.dumps({"bomFormat": "CycloneDX", "specVersion": "1.5", "version": 1, "metadata": {"timestamp": results["generated"], "component": {"type": "application", "name": "StreamSetu (macOS)"}}, "components": comps}, indent=2))
    print("SBOM written:", sbom)

outcome = "vulnerable" if problems else "unknown" if unknown else "clean"
print("\nResult:", {"vulnerable": "vulnerabilities reported above", "unknown": "some could not be checked or identified (see ? above)", "clean": "nothing reported"}[outcome])
results["outcome"] = outcome
if arg("--report"): pathlib.Path(arg("--report")).write_text(json.dumps(results, indent=2))
if "--strict" in sys.argv:
    sys.exit(1 if problems else 2 if unknown else 0)
