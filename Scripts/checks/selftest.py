#!/usr/bin/env python3
"""Prove each check bites: apply one injected violation at a time to a temporary copy of the few involved files (an overlay folder that shadows
the same relative paths; the real tree is never touched), run the check, and require the expected failure. The real tree must pass first.
   Scripts/checks/run_all.py --selftest      (or run this file)      Env: none needed (it sets CHECKS_OVERLAY / FIXTURE_ROOT itself)."""
import importlib, json, os, re, shutil, subprocess, sys, tempfile, time
from pathlib import Path
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parent))
import common, run_all

FIX = "smartmix/fixtures/tiny-library.json"
KOT_UI = "android/app/src/main/kotlin/app/streamsetu/tv/ui/screens/InjectedScreen.kt"
SWIFT_SRC = "macos/Sources/REDDY/Services/InjectedService.swift"
KOT_NET = "android/data/src/main/kotlin/app/streamsetu/core/data/InjectedNet.kt"


def sub(old, new, count=1):
    def f(t):
        assert old in t, "injection anchor not found: %r" % old
        return t.replace(old, new, count)
    return f


def bump(rx, delta=1, group=1):
    """transform: add delta to the number captured by rx (derived from the current text, never hard-coded)"""
    def f(t):
        m = re.search(rx, t); assert m, "injection anchor not found: %r" % rx
        return t[:m.start(group)] + str(int(m.group(group)) + delta) + t[m.end(group):]
    return f


def bump_version(rx):
    def f(t):
        m = re.search(rx, t); assert m, "injection anchor not found: %r" % rx
        a, b, c = m.group(1).split("."); return t[:m.start(1)] + "%s.%d.%s" % (a, int(b) + 1, c) + t[m.end(1):]
    return f


def swap_two_ids(t):
    d = json.loads(t); ids = d["steps"][0]["expect"]["hero"]["ids"]
    assert len(ids) >= 2; ids[0], ids[1] = ids[1], ids[0]; return json.dumps(d, indent=1)


def dup_library_id(t):
    d = json.loads(t); d["library"][1]["id"] = d["library"][0]["id"]; return json.dumps(d)


# (check module name, label, {path: transform(text) | new text}, expected substring in an error)
CASES = [
    ("fixture-contract", "duplicate candidate id", {FIX: dup_library_id}, "duplicate candidate ids"),
    ("fixture-contract", "fixture missing from README", {"artwork/fixtures/README.md": lambda t: t.replace("name-cleaning", "n-c")}, "name-cleaning.json: not described"),
    ("fixture-contract", "README without Owner line", {"epg/fixtures/README.md": lambda t: re.sub(r"(?m)^Owner:", "Keeper:", t)}, "no 'Owner:' line"),
    ("fixture-contract", "new fixture nobody consumes", {"artwork/fixtures/zz-orphan.json": '[{"a": 1}]'}, "no Kotlin test consumes it"),
    ("fixture-contract", "README names a missing file", {"smartmix/fixtures/README.md": lambda t: t + "\nSee `ghost-case.json`.\n"}, "ghost-case.json"),
    ("fixture-contract", "broken JSON", {"artwork/fixtures/identity.json": "{not json"}, "not valid JSON"),
    ("smartmix-reference", "fixture expectation swapped", {FIX: swap_two_ids}, "differs from the fixture"),
    ("smartmix-reference", "reference changed", {"smartmix/tools/smartmix_ref.py": sub("{5: 1000, 4: 800", "{5: 999, 4: 800")}, "features.quality"),
    ("network-contract", "host dropped from Android config", {"android/app/src/main/res/xml/network_security_config.xml": sub('<domain includeSubdomains="true">tmdb.org</domain>', "")}, "tmdb.org"),
    ("network-contract", "http:// literal", {KOT_NET: 'package x\nval u = "http://api.tmdb-metadata.net/3/movie"\n'}, "http:// literal for api.tmdb-metadata.net"),
    ("network-contract", "unlisted https host", {SWIFT_SRC: 'let u = "https://tracker.badhost.io/x"\n'}, "tracker.badhost.io"),
    ("network-contract", "privacy text drops a service", {"legal/privacy.md": lambda t: re.sub(r"(?i)tvmaze", "tvm", t)}, "does not name TVmaze"),
    ("network-contract", "credit dropped", {"legal/licenses.md": lambda t: re.sub(r"(?i)fanart\.tv", "f", t)}, "no credit for fanart.tv"),
    ("network-contract", "manifest turns tracking on", {"ios/StreamSetu/PrivacyInfo.xcprivacy": sub("<key>NSPrivacyTracking</key><false/>", "<key>NSPrivacyTracking</key><true/>")}, "NSPrivacyTracking must be false"),
    ("network-contract", "iOS and macOS lists drift", {"macos/Configuration/Info.plist": sub("<key>trakt.tv</key>", "<key>trakt.example.tv</key>")}, "ATS lists differ"),
    ("provider-names-logging", "provider name in a UI string", {KOT_UI: 'package a\nfun f() { Text("Ratings come from TheTVDB today") }\n'}, "provider name TheTVDB"),
    ("provider-names-logging", "provider name allowed in Settings", {"android/app/src/main/kotlin/app/streamsetu/tv/ui/screens/settings/InjectedSettings.kt": 'package a\nfun f() { Text("Ratings come from TheTVDB today") }\n'}, None),
    ("provider-names-logging", "provider name in a README", {"docs/FEATURES.md": lambda t: t + "\nArtwork comes from TMDB today.\n"}, "provider name TMDB in a markdown file"),
    ("provider-names-logging", "provider name allowed in legal text", {"legal/privacy.md": lambda t: t + "\nTMDB receives a title.\n"}, None),
    ("provider-names-logging", "token in a Kotlin log call", {KOT_NET: 'package x\nfun f(apiKey: String) { Log.d("net", "key=$apiKey") }\n'}, "sensitive value (apikey)"),
    ("provider-names-logging", "token in a Swift print", {SWIFT_SRC: 'func f(token: String) { print("auth \\(token)") }\n'}, "sensitive value (token)"),
    ("provider-names-logging", "redacted token is fine", {SWIFT_SRC: 'func f(token: String) { print("token set: \\(token.isEmpty)") }\n'}, None),
    ("doc-code-drift", "README Mac version drifts", {"README.md": bump_version(r"/StreamSetu-(\d+\.\d+\.\d+)\.dmg\)")}, "appcast.xml newest item"),
    ("doc-code-drift", "test APK code wrong", {"docs/RELEASING.md": bump(r"with code `(\d+)`", 9)}, "test code"),
    ("doc-code-drift", "Room version bumped without schema", {"android/core-database/src/main/kotlin/app/streamsetu/core/data/db/AppDatabase.kt": bump(r"version\s*=\s*(\d+),")}, "Room version"),
    ("doc-code-drift", "Apple migration list ahead of docs", {"macos/Sources/REDDY/Data/Database/DatabaseMigrator.swift": bump(r"(?s).*Migration\(version:\s*(\d+)")}, "Apple schema"),
    ("doc-code-drift", "coverage totals disagree", {"docs/assistant-coverage.md": bump(r"\| \*\*All\*\* \| \*\*(\d+)\*\*")}, "'All' total"),
    ("doc-code-drift", "release doc names a missing script", {"docs/RELEASING.md": lambda t: t + "\nRun `Scripts/ghost-release.sh` first.\n"}, "ghost-release.sh"),
    ("doc-code-drift", "atlas changed, coverage doc not regenerated", {"macos/Sources/REDDY/Atlas/InjectedEntry.swift": "// new atlas entry\n"}, "atlas inputs changed"),
    ("doc-code-drift", "iPhone version drifts from Xcode", {"ios/StreamSetu.xcodeproj/project.pbxproj": bump_version(r"MARKETING_VERSION = (\d+\.\d+);") if False else (lambda t: re.sub(r"MARKETING_VERSION = [\d.]+;", "MARKETING_VERSION = 9.9;", t))}, "MARKETING_VERSION"),
]


DOC = "docs/assistant-coverage.md"
ATLAS_NEW = "macos/Sources/REDDY/Atlas/InjectedEntry.swift"


def hash_cases(base, mod, rows):
    """The embedded-fingerprint contract of docs/assistant-coverage.md: (label, files written to the overlay, expected error substring or None).
    A callable value receives (overlay Ctx, current doc bytes) and returns the new doc bytes (it runs the real post-step, so regeneration is what is tested)."""
    import atlas_fingerprint as af
    doc = base.abs(DOC).read_bytes()
    def regen(tmp): # what `atlas_fingerprint.py --write` does, against the overlay
        return af.render(common.Ctx(overlay=tmp), doc)
    def edit(f): return lambda tmp: f(doc)
    L1, L2 = doc.split(b"\n", 2)[:2]
    cases = [
        ("hash: atlas input changed, doc not regenerated", {ATLAS_NEW: b"// new atlas entry\n"}, None, "atlas inputs changed"),
        ("hash: regenerated, body identical (header rewritten)", {}, regen, None),
        ("hash: atlas input changed and regenerated (post-step)", {ATLAS_NEW: b"// new atlas entry\n"}, regen, None),
        ("hash: inputs line deleted", {}, edit(lambda d: d.split(b"\n", 1)[1]), "missing"),
        ("hash: body line deleted", {}, edit(lambda d: d.replace(L2 + b"\n", b"", 1)), "missing"),
        ("hash: inputs line duplicated", {}, edit(lambda d: L1 + b"\n" + d), "duplicated"),
        ("hash: line malformed (uppercase hex)", {}, edit(lambda d: re.sub(rb"[0-9a-f]{64}", lambda m: m.group(0).upper().replace(b"E", b"A") if re.search(rb"[a-f]", m.group(0)) else b"G" * 64, d, 1)), "not the first two lines"),
        ("hash: line malformed (63 hex digits)", {}, edit(lambda d: re.sub(rb"[0-9a-f]{64}", lambda m: m.group(0)[:63], d, 1)), "not the first two lines"),
        ("hash: header lines swapped", {}, edit(lambda d: d.replace(L1 + b"\n" + L2, L2 + b"\n" + L1, 1)), "not the first two lines"),
        ("hash: stale inputs value kept", {}, edit(lambda d: d.replace(L1, L1[:30] + (b"0" if L1[30:31] != b"0" else b"1") + L1[31:], 1)), "atlas inputs changed"),
        ("hash: a table row edited, totals still add up", {}, edit(lambda d: d.replace(b"| no |", b"| yes |", 1)), "does not match its embedded"),
        ("hash: a total edited, valid hash left", {}, edit(lambda d: re.sub(rb"(\| \*\*All\*\* \| \*\*)(\d+)", lambda m: m.group(1) + str(int(m.group(2)) + 1).encode(), d, 1)), "'All' total"),
    ]
    bad = 0
    for label, files, how, expect in cases:
        tmp = Path(tempfile.mkdtemp(prefix="checks-overlay-"))
        try:
            for rel, content in files.items():
                (tmp / rel).parent.mkdir(parents=True, exist_ok=True); (tmp / rel).write_bytes(content)
            if how: (tmp / DOC).parent.mkdir(parents=True, exist_ok=True); (tmp / DOC).write_bytes(how(tmp))
            ctx = common.Ctx(overlay=tmp); t = time.time(); res = mod.run(ctx); secs = time.time() - t
            good = (not res.errors) if expect is None else any(expect in e for e in res.errors)
            bad += not good; rows.append((label, "doc-code-drift", "ok" if good else "NOT CAUGHT", secs, "" if good else "expected %r; got %s" % (expect, res.errors[:2])))
        finally: shutil.rmtree(tmp, ignore_errors=True)
    # the original false failure: regenerated-but-identical doc with a stale or absent stamp, through run_all itself, must PASS
    tmp = Path(tempfile.mkdtemp(prefix="checks-overlay-"))
    try:
        (tmp / ATLAS_NEW).parent.mkdir(parents=True, exist_ok=True); (tmp / ATLAS_NEW).write_bytes(b"// new atlas entry\n")
        (tmp / DOC).parent.mkdir(parents=True, exist_ok=True); (tmp / DOC).write_bytes(af.render(common.Ctx(overlay=tmp), doc))
        stale = tmp / "stale-stamp.json"; stale.write_text(json.dumps({"files": {}, "checks": {}, "state": {"assistant-coverage": {"atlas": "0" * 40, "doc": base.digest(DOC)}}}))
        for label, stamp in (("stale stamp", stale), ("no stamp", Path("/nonexistent-dir/x.json"))):
            t = time.time()
            p = subprocess.run([sys.executable, "-I", str(HERE / "run_all.py"), "--only", "doc-code-drift"], env=dict(os.environ, CHECKS_OVERLAY=str(tmp), CHECKS_STAMP=str(stamp)), capture_output=True, text=True)
            good = p.returncode == 0; bad += not good
            rows.append(("hash: regenerated-identical doc, %s (run_all)" % label, "doc-code-drift", "ok" if good else "NOT CAUGHT", time.time() - t, "" if good else p.stdout[-300:]))
    finally: shutil.rmtree(tmp, ignore_errors=True)
    return bad


def main():
    mods = {m.NAME: m for m in run_all.load_checks()}
    base = common.Ctx(); rows = []; bad = 0
    t = time.time(); real = {n: m.run(base) for n, m in mods.items()}
    for n, r in real.items():
        ok = not r.errors; bad += not ok
        rows.append(("real tree", n, "PASS" if ok else "FAIL", 0, "; ".join(r.errors[:2])))
    print("real tree: %s (%.2fs)" % ("all pass" if not bad else "FAILURES", time.time() - t))
    for name, label, edits, expect in CASES:
        tmp = Path(tempfile.mkdtemp(prefix="checks-overlay-"))
        try:
            for rel, how in edits.items():
                orig = base.read(rel) if rel in base.fileset else ""
                new = how(orig) if callable(how) else how
                if callable(how): assert new != orig, "injection changed nothing: " + rel
                (tmp / rel).parent.mkdir(parents=True, exist_ok=True); (tmp / rel).write_text(new)
            t = time.time()
            ctx = common.Ctx(overlay=tmp)
            ctx._text = {k: v for k, v in base._text.items() if k not in edits}
            res = mods[name].run(ctx)
            secs = time.time() - t
            if expect is None: good, why = not res.errors, "no failure expected"
            else: good = any(expect in e for e in res.errors); why = "expected %r" % expect
            if not good: bad += 1
            rows.append((label, name, "ok" if good else "NOT CAUGHT", secs, "" if good else "%s; got %s" % (why, res.errors[:2])))
        finally: shutil.rmtree(tmp, ignore_errors=True)
    bad += hash_cases(base, mods["doc-code-drift"], rows)
    # end to end through the environment overrides: a temporary copy of the three fixture folders
    tmp = Path(tempfile.mkdtemp(prefix="checks-fixtures-"))
    try:
        for top in ("smartmix", "artwork", "epg"): shutil.copytree(base.root / top / "fixtures", tmp / top / "fixtures")
        env = dict(os.environ, FIXTURE_ROOT=str(tmp)); script = str(HERE / "fixture_contract.py")
        t = time.time(); p1 = subprocess.run([sys.executable, script], env=env, capture_output=True, text=True)
        (tmp / "epg/fixtures/README.md").unlink()
        p2 = subprocess.run([sys.executable, script], env=env, capture_output=True, text=True); secs = time.time() - t
        good = p1.returncode == 0 and p2.returncode == 1 and "README.md missing" in p2.stdout
        bad += not good
        rows.append(("FIXTURE_ROOT copy: passes, then README deleted", "fixture-contract", "ok" if good else "NOT CAUGHT", secs, ""))
    finally: shutil.rmtree(tmp, ignore_errors=True)
    w = max(len(r[0]) for r in rows)
    print("%-*s  %-22s  %-10s  %s" % (w, "injected violation", "check", "result", "time"))
    for label, name, res, secs, extra in rows:
        print("%-*s  %-22s  %-10s  %.2fs  %s" % (w, label, name, res, secs, extra))
    print("selftest: %s (%d injections)" % ("FAIL" if bad else "PASS, every check bites and the real tree passes", len(CASES) + 1 + 13))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
