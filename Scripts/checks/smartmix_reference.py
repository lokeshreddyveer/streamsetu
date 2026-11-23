#!/usr/bin/env python3
"""Replay the Smart Mix fixtures through the Python reference (smartmix/tools/smartmix_ref.py) and compare every expected value:
PRNG vectors, feature tables and each engine case (library or generator, every step's ids / artwork / diagnostics or digest).
Generated libraries above 20000 titles are skipped (seconds each; the Swift/Kotlin stress tests and make_fixtures.py own them). In-process, no subprocess."""
import importlib.util, json, re, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import common

NAME = "smartmix-reference"
INPUTS = [r"^smartmix/tools/smartmix_ref\.py$", r"^smartmix/fixtures/.*\.json$"]
BIG = 20000
NON_CASE = {"prng", "features", "genre-shelves", "shelf-modes", "home-layout"}


def load_ref(ctx):
    spec = importlib.util.spec_from_file_location("smartmix_ref_under_check", ctx.abs("smartmix/tools/smartmix_ref.py"))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m


def run(ctx):
    R = common.Result()
    if not ctx.exists("smartmix/tools/smartmix_ref.py"):
        R.err("smartmix/tools/smartmix_ref.py missing"); return R
    ref = load_ref(ctx)
    fx = lambda n: json.loads(ctx.read("smartmix/fixtures/%s.json" % n))
    ran = skipped = 0
    if ctx.exists("smartmix/fixtures/prng.json"):
        d = fx("prng")
        for e in d["fnv1a64"]:
            if "%016X" % ref.fnv1a64(ref.ub(e["input"])) != e["hex"]: R.err("prng: fnv1a64(%r) differs" % e["input"])
        for e in d["splitmix64"]:
            g = ref.SplitMix64(e["seed"])
            if ["%016X" % g.next() for _ in e["hex"]] != e["hex"]: R.err("prng: splitmix64 seed %s differs" % e["seed"])
        for e in d["uniform"]:
            if "seedString" in e: g = ref.SplitMix64(ref.fnv1a64(ref.ub(e["seedString"]))); ns = [e["n"]] * len(e["values"])
            else: g = ref.SplitMix64(e["splitmixSeed"]); ns = e.get("ns") or [e["n"]] * len(e["values"])
            if [g.uniform(n) for n in ns] != e["values"]: R.err("prng: uniform %s differs" % (e.get("seedString") or e.get("splitmixSeed")))
        s = d["seedString"]
        if ref.seed_string(s["profile"], s["shelf"], s["day"], s["counter"]) != s["value"]: R.err("prng: seedString differs")
        ran += 1
    if ctx.exists("smartmix/fixtures/features.json"):
        f = fx("features"); aff = f["affinityContext"]
        table = {"release": lambda r: ref.f_release(r[0], r[1]), "added": lambda r: ref.f_added(r[0]), "quality": lambda r: ref.f_quality(r[0]),
                 "language": lambda r: ref.f_language(r[0], r[1]), "rating": lambda r: ref.f_rating(r[0]),
                 "popularity": lambda r: ref.f_popularity(r[0], r[1]), "fresh": lambda r: ref.f_fresh(r[0]),
                 "affinity": lambda r: ref.f_affinity(r[0], aff)}
        for k, fn in table.items():
            for row in f.get(k, []):
                if fn(row) != row[-1]: R.err("features.%s: %r expects %r, reference gives %r" % (k, row[:-1], row[-1], fn(row)))
        ran += 1
    for p in ctx.select([r"^smartmix/fixtures/[^/]+\.json$"]):
        name = Path(p).stem
        if name in NON_CASE: continue
        d = json.loads(ctx.read(p)); gen = d.get("generator")
        if gen and gen.get("n", 0) > BIG: skipped += 1; continue
        lib = ref.generate(gen["name"], gen["seed"], gen["n"], gen["folders"]) if gen else d.get("library", [])
        st = ref.State()
        for i, s in enumerate(d.get("steps", [])):
            if "expect" not in s: continue
            res = ref.run_step(lib, {k: v for k, v in s.items() if k != "expect"}, st); e = s["expect"]
            if "digest" in e:
                if ref.digest(res, s["shelves"]) != e["digest"]: R.err("%s step %d: digest differs" % (p, i))
                if {k: len(v["ids"]) for k, v in res.items()} != e["counts"]: R.err("%s step %d: counts differ" % (p, i))
            else:
                for shelf, want in e.items():
                    got = res.get(shelf)
                    if got is None: R.err("%s step %d: shelf %s not produced" % (p, i, shelf))
                    elif got["ids"] != want["ids"] or got["art"] != want["art"] or got["diag"] != want["diag"]:
                        R.err("%s step %d shelf %s: reference output differs from the fixture" % (p, i, shelf))
        ran += 1
    R.note = "%d fixtures replayed, %d large generated ones skipped" % (ran, skipped)
    return R


if __name__ == "__main__":
    common.main(sys.modules[__name__])
