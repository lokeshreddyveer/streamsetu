#!/usr/bin/env python3
"""Fixture contract for every shared fixture folder (<top>/fixtures: smartmix, artwork, epg).
  1. README.md with an `Owner:` line that names every fixture file (file name or stem);
  2. every JSON parses, has the structure its schema requires, unique ids / case names;
  3. every file the README (in backticks) or a fixture names exists;
  4. each fixture is consumed by BOTH the Swift tests (macos/Tests, ios/*Tests) and the Kotlin tests (android/*/src/test, androidTest):
     the test sources must name the fixture (stem as a quoted string or file name). The Swift Smart Mix runner enumerates its folder,
     so a Smart Mix case file needs no Swift mention; the Kotlin side must name each file.
Windows (C#) consumers are on hold: listed with -v, never enforced.  Env: REPO_ROOT, FIXTURE_ROOT (folder that holds smartmix/ artwork/ epg/)."""
import json, re, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import common

NAME = "fixture-contract"
SWIFT_RX = r"^(macos/Tests|ios/[^/]*Tests|ios/[^/]*UITests|macos/UITests)/.*\.swift$"
KOTLIN_RX = r"^android/[^/]+/src/(test|androidTest)/.*\.kt$"
CS_RX = r"^windows/.*Tests.*/.*\.cs$"
INPUTS = [r"^[^/]+/fixtures/", SWIFT_RX, KOTLIN_RX, CS_RX]
SKIP_NAMES = {"README.md", "READY"}
LIST_SCHEMAS = {
    "name-cleaning": ["input", "year", "expectedClean", "notes"],
    "display-rating": ["tmdbAverage", "tmdbVotes", "provider", "expected", "notes"],
    "attribution": ["provenance", "onScreens", "expected"],
    "match-decision": ["libraryTitle", "year", "kind", "languageTag", "candidates", "expectedId", "notes"],
}
DICT_SCHEMAS = {
    "identity": ["merge", "queryID", "imdb"], "arbiter-poster": ["pick", "replace"], "arbiter-logo": ["pick"],
    "arbiter-episode-text": None, "mapping-cases": ["options", "guide", "cases"], "iptvorg-cases": ["cases"],
    "freshness-cases": ["now", "cases"], "timezone-cases": ["cases"],
    "genre-shelves": ["name", "description", "library", "select"], "shelf-modes": ["name", "description", "library", "steps"],
    "home-layout": ["name", "description", "layout", "compose", "franchise", "modeDefault", "titles"],
}
SM_NON_CASE = {"prng", "features", "genre-shelves", "shelf-modes", "home-layout"}


def run(ctx, verbose=False):
    R = common.Result()
    err = R.err
    swift = "\n".join(ctx.read(p) for p in ctx.select([SWIFT_RX]))
    kotlin = "\n".join(ctx.read(p) for p in ctx.select([KOTLIN_RX]))
    csharp = "\n".join(ctx.read(p) for p in ctx.select([CS_RX]))
    folders = sorted({m.group(0).rstrip("/") for f in ctx.files for m in [re.match(r"^[^/]+/fixtures/", f)] if m})
    swift_enumerates = "contentsOfDirectory" in swift and "smartmix/fixtures" in swift
    cs_enumerates = "GetFiles" in csharp or "EnumerateFiles" in csharp
    on_hold, total = [], 0

    def consumed(text, p, stem):
        # a quoted stem ("name"), "name.json" / "name.xml", a path ending in the file name, or the file name itself
        return re.search(r"[\"'/]%s(\.[a-z.]+)?[\"']|[\"'/]%s\b" % (re.escape(stem), re.escape(p.name)), text) is not None or p.name in text

    for folder in folders:
        rtext = ctx.read(folder + "/README.md")
        if not ctx.exists(folder + "/README.md"): err("%s: README.md missing" % folder)
        elif not re.search(r"(?mi)^\**owner\**:", rtext): err("%s/README.md: no 'Owner:' line stating who keeps the fixtures" % folder)
        files = [f for f in ctx.files if f.startswith(folder + "/") and Path(f).name not in SKIP_NAMES]
        base_names = {Path(f).name for f in ctx.files}
        for ref in re.findall(r"`([A-Za-z0-9_./*-]+\.(?:json|xml|gz|py))`", rtext):
            if "*" in ref:
                rx = re.compile(re.escape(folder + "/").replace(r"\*", ".*") + ref.replace(".", r"\.").replace("*", "[^/]*") + "$")
                if not any(rx.match(f) or f.endswith("/" + ref.replace("*", "")) for f in ctx.files) and not any(
                        re.fullmatch(ref.replace(".", r"\.").replace("*", ".*"), Path(f).name) for f in files):
                    err("%s/README.md: pattern `%s` matches nothing" % (folder, ref))
            elif (folder + "/" + ref) not in ctx.fileset and ref not in ctx.fileset and not any(f.endswith("/" + ref) for f in ctx.files):
                err("%s/README.md: names `%s`, which does not exist" % (folder, ref))
        for p in files:
            total += 1
            path = Path(p); stem = path.name.split(".")[0]; sub = p[len(folder) + 1:]
            names = {path.name, stem, sub, path.parent.name + "/*"}
            if path.parent.name != "fixtures": names.add(path.parent.name + "/")
            if not any(n in rtext for n in names): err("%s: not described in %s/README.md" % (p, folder))
            if path.suffix == ".json":
                doc = check_json(ctx, R, p, stem, folder)
                for r in referenced(doc):
                    if (folder + "/" + r) not in ctx.fileset and (str(path.parent) + "/" + r) not in ctx.fileset:
                        err("%s: refers to missing file '%s'" % (p, r))
            elif path.suffix == ".xml" and "<" not in ctx.read(p): err("%s: not XML" % p)
            case_file = folder == "smartmix/fixtures" and stem not in SM_NON_CASE
            sw = consumed(swift, path, stem) or (case_file and swift_enumerates)
            kt = consumed(kotlin, path, stem)
            cs = consumed(csharp, path, stem) or (case_file and cs_enumerates)
            if not sw: err("%s: no Swift test consumes it (documented as shared)" % p)
            if not kt: err("%s: no Kotlin test consumes it (documented as shared)" % p)
            if not cs: on_hold.append(p)
    R.note = "%d files in %d folders; Windows C# consumers on hold for %d" % (total, len(folders), len(on_hold))
    if verbose:
        for r in on_hold: print("   C# on hold:", r)
    if not folders: err("no fixture folders found")
    return R


def check_json(ctx, R, p, stem, folder):
    err = R.err
    try: doc = json.loads(ctx.read(p))
    except ValueError as e:
        err("%s: not valid JSON (%s)" % (p, e)); return None
    if doc in ({}, [], None): err("%s: empty fixture" % p)
    if stem in LIST_SCHEMAS:
        if not isinstance(doc, list): err("%s: must be a list" % p); return doc
        for i, it in enumerate(doc):
            for k in LIST_SCHEMAS[stem]:
                if not isinstance(it, dict) or k not in it: err("%s: item %d lacks key '%s'" % (p, i, k))
        if stem == "name-cleaning":
            keys = [repr((it.get("input"), it.get("year"))) for it in doc if isinstance(it, dict)]
            if len(keys) != len(set(keys)): err("%s: duplicate (input, year) cases" % p)
        if stem == "match-decision":
            for i, it in enumerate(doc):
                if not isinstance(it, dict): continue
                cid = [c.get("id") for c in it.get("candidates", [])]
                if len(cid) != len(set(cid)): err("%s: case %d has duplicate candidate ids" % (p, i))
                if it.get("expectedId") is not None and it.get("expectedId") not in cid:
                    err("%s: case %d expectedId is not among its candidates" % (p, i))
    elif stem in DICT_SCHEMAS and DICT_SCHEMAS[stem] is not None:
        if not isinstance(doc, dict): err("%s: must be an object" % p); return doc
        for k in DICT_SCHEMAS[stem]:
            if k not in doc: err("%s: lacks key '%s'" % (p, k))
    if folder.startswith("smartmix") and stem not in SM_NON_CASE and isinstance(doc, dict):
        for k in ("name", "description", "steps"):
            if k not in doc: err("%s: engine case lacks '%s'" % (p, k))
        if "library" not in doc and "generator" not in doc: err("%s: needs 'library' or 'generator'" % p)
        if doc.get("name") != stem: err("%s: 'name' (%r) must equal the file stem" % (p, doc.get("name")))
        steps = doc.get("steps")
        if not isinstance(steps, list) or not steps: err("%s: steps must be a non-empty list" % p)
        else:
            for i, s in enumerate(steps):
                for k in ("profile", "dayKey", "refreshCounter", "shelves", "expect"):
                    if k not in s: err("%s: step %d lacks '%s'" % (p, i, k))
    if isinstance(doc, dict) and isinstance(doc.get("library"), list):
        ids = [c.get("id") for c in doc["library"] if isinstance(c, dict)]
        if any(i is None for i in ids): err("%s: library candidate without id" % p)
        if len(ids) != len(set(ids)): err("%s: duplicate candidate ids in library" % p)
    return doc


def referenced(doc):
    found = []
    def walk(x):
        if isinstance(x, str):
            if re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_./-]*\.(json|xml|gz)", x): found.append(x)
        elif isinstance(x, list):
            for y in x: walk(y)
        elif isinstance(x, dict):
            for y in x.values(): walk(y)
    walk(doc)
    return found


if __name__ == "__main__":
    if "-v" in sys.argv or "--verbose" in sys.argv:
        t = common.time.time(); r = run(common.Ctx(), verbose=True); common.report(NAME, r, common.time.time() - t); sys.exit(1 if r.errors else 0)
    common.main(sys.modules[__name__])
