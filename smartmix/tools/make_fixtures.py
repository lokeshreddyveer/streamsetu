"""Regenerates every file in ../fixtures from smartmix_ref.py.   python3 make_fixtures.py"""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import smartmix_ref as R

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fixtures")
GLOBAL = ["hero", "for-you", "rediscover", "lang-pref", "top-week", "trending-library"]
AFF = {"topLangs": ["Telugu", "Hindi", "English"], "topFolders": ["f1", "f2"], "topGenres": ["action", "drama"], "topDecades": [2010, 2020]}

def step(profile="main", day="2026-11-21", counter=0, shelves=GLOBAL, **kw):
    s = dict(profile=profile, dayKey=day, refreshCounter=counter, shelves=list(shelves)); s.update(kw); return s

def write(name, obj):
    with open(os.path.join(OUT, name + ".json"), "w") as f: json.dump(obj, f, indent=1, sort_keys=True, ensure_ascii=False); f.write("\n")

def case(name, desc, library, steps, generator=None, digest_only=False):
    st = R.State(); out = []
    for s in steps:
        res = R.run_step(library, s, st)
        s = dict(s)
        if digest_only:
            s["expect"] = {"digest": R.digest(res, s["shelves"]), "counts": {k: len(v["ids"]) for k, v in res.items()},
                           "first": {k: v["ids"][:14] for k, v in res.items() if not k.startswith("folder:")}}
        else:
            s["expect"] = {k: {"ids": v["ids"], "art": v["art"], "diag": v["diag"]} for k, v in res.items()}
        out.append(s)
    doc = dict(name=name, description=desc, steps=out)
    if generator: doc["generator"] = generator
    else: doc["library"] = library
    write(name, doc)
    return out

def m(i, **kw):
    d = dict(id="m%d" % i, key="title %d" % i, year=2024, added=10); d.update(kw); return d
def sr(i, **kw):
    d = dict(id="s%d" % i, kind="series", key="show %d" % i, year=2023, added=40); d.update(kw); return d

# ---- prng + feature tables
g = R.SplitMix64(0); sm0 = ["%016X" % g.next() for _ in range(3)]
g = R.SplitMix64(1); sm1 = ["%016X" % g.next() for _ in range(2)]
seed = R.fnv1a64(R.ub("smartmix1|main|hero|2026-11-21|0"))
g = R.SplitMix64(seed); u5 = [g.uniform(1000) for _ in range(5)]
g = R.SplitMix64(7); big = [g.uniform((1 << 63) + 1) for _ in range(4)]
g = R.SplitMix64(7); odd = [g.uniform(n) for n in (1, 2, 3, 7, 10, 1000003)]
seeds = ["smartmix1|main|hero|2026-11-21|0", "smartmix1|తె|top-week|2026-01-01|12", "smartmix1|\U0001F3AC|folder:x|2026-12-31|0"]
write("prng", dict(name="prng", fnv1a64=[{"input": "", "hex": "%016X" % R.fnv1a64(b"")}, {"input": "a", "hex": "%016X" % R.fnv1a64(b"a")}] +
    [{"input": s, "hex": "%016X" % R.fnv1a64(R.ub(s))} for s in seeds],
    splitmix64=[{"seed": 0, "hex": sm0}, {"seed": 1, "hex": sm1}],
    uniform=[{"seedString": "smartmix1|main|hero|2026-11-21|0", "n": 1000, "values": u5},
             {"splitmixSeed": 7, "n": (1 << 63) + 1, "values": big},
             {"splitmixSeed": 7, "ns": [1, 2, 3, 7, 10, 1000003], "values": odd}],
    seedString={"profile": "main", "shelf": "hero", "day": "2026-11-21", "counter": 0, "value": "smartmix1|main|hero|2026-11-21|0"}))
feat = dict(
  release=[[y, 2026, R.f_release(y, 2026)] for y in [None, 2026, 2027, 2025, 2024, 2023, 2022, 2021, 2020, 2018, 2017, 2011, 2010, 1990]],
  added=[[d, R.f_added(d)] for d in [None, -3, 0, 7, 8, 30, 31, 90, 91, 180, 181, 365, 366, 2000]],
  quality=[[q, R.f_quality(q)] for q in range(6)],
  language=[[l, p, R.f_language(l, p)] for l, p in [("Telugu", None), ("Telugu", "Telugu"), (None, "Telugu"), ("Hindi", "Telugu")]],
  rating=[[t, R.f_rating(t)] for t in ["", "0", "0.0", "0.5", "1", "5", "6.0", "7.4", "8.25", "9.99", "9.9", "10", "10.0", "10.5", "99", ">10", "N/A", "abc", "-1", "7,5", "7.", ".5", "007", " 7.0"]] + [[None, R.f_rating(None)]],
  popularity=[[a, b, R.f_popularity(a, b)] for a, b in [(0, 0), (0, 1), (1, 0), (0, 2), (0, 3), (1, 2), (2, 1), (0, 5), (3, 3), (5, 0), (6, 0)]],
  fresh=[[a, R.f_fresh(a)] for a in [None, 1, 2, 3, 4, 9]])
aff_cases = [({"lang": "Telugu", "folder": "f1", "genre": "action", "year": 2024}, 400 + 200 + 100 + 150),
             ({"lang": "Hindi", "folder": None, "genre": None, "year": 1990}, 250),
             ({"lang": "Tamil", "folder": "zz", "genre": "horror", "year": 2005}, 0)]
feat["affinity"] = [[c, R.f_affinity(c, AFF)] for c, _ in aff_cases]
feat["affinityContext"] = AFF
write("features", feat)

# ---- empty / tiny
case("empty-library", "No candidates at all: every shelf empty, lang-pref hidden, nothing throws.", [], [step(preferredLang="Telugu", affinity=AFF)])
case("tiny-library", "3 titles: fewer picks than slots, no repeat penalty (tiny), hero >= 3 reached.",
     [m(1, lang="Telugu", backdrop=True), m(2, lang="Hindi"), sr(3, lang="Telugu", backdrop=True)],
     [step(preferredLang="Telugu"), step(counter=1, preferredLang="Telugu")])

# ---- duplicates, twins, restricted
lib = [m(1, key="dune", year=1984, src=0), m(2, key="dune", year=2021, src=0), m(3, key="alpha", src=0), m(4, key="alpha", src=1, q=5),
       m(5, key="beta", src=0, restricted=True), m(6, key="beta", src=1), m(7, key="gamma", src=0, dismissed=True), m(8, key="gamma", src=1),
       m(9, key="delta", year=2020), m(10, key="delta", year=2021, id="m10b"), m(11, key="delta", year=None, id="m11n"),
       sr(1, key="alpha"), m(12, key="eps", src=1, added=3), m(13, key="eps", src=0, added=1)] + [m(20 + i, key="filler %d" % i, year=2015 + i % 10, added=20 + i * 9, q=2 + i % 4) for i in range(20)]
case("duplicates-and-twins", "Same title in two sources (quality beats source), remake 37 years apart stays separate, +-1 year merged, nil year joins, restricted twin removes whole group, dismissed twin removes group on rec shelves, kind keeps movie/series apart.",
     lib, [step(shelves=GLOBAL + ["folder:f1"])])
lib = [m(1, key="film", lang="Hindi", q=5, folder="f1"), m(2, key="film", lang="Telugu", q=2, folder="f2"), m(3, key="film", lang="Telugu", q=0, cam=True),
       m(4, key="solo", lang="Hindi", q=0, cam=True), m(5, key="other", lang="Tamil", q=4, src=1), m(6, key="other", lang="Tamil", q=4, src=0)] + [m(30 + i, key="x%d" % i, lang=["Telugu", "Hindi", "English"][i % 3], q=1 + i % 5, added=i * 12) for i in range(18)]
case("multilang-versions", "Preferred language beats 4K; CAM member dropped when a better one exists; sole-CAM group excluded until relaxation tier 5.",
     lib, [step(preferredLang="Telugu"), step(preferredLang="Hindi"), step(preferredLang=None)])

# ---- bad ratings
ratings = ["", "0", "10", "10.0", "abc", "9.99", "-1", "7.4", None, "5.0", ">10", "8.2"]
lib = [m(i, key="r%d" % i, rating=ratings[i % len(ratings)], year=2020, added=100, q=3, lang="Telugu") for i in range(12)]
case("bad-ratings", "Ratings are weak evidence: junk values neutral (500), 40% shrink toward neutral, identical other features so only rating differs.",
     lib, [step(preferredLang="Telugu", shelves=["hero", "for-you", "rediscover", "lang-pref"])])

# ---- artwork
lib = [m(1, poster=False, backdrop=True), m(2, poster=True, backdrop=False), m(3, poster=False, backdrop=False), m(4, poster=True, backdrop=True),
       sr(5, poster=False, backdrop=False), sr(6, poster=True, backdrop=True)] + [m(50 + i, poster=i % 3 != 0, backdrop=i % 5 == 0, added=i * 7) for i in range(12)]
case("missing-artwork", "Hero accepts backdrop or poster (poster composition tier), never none; rows need a poster until relaxation tier 4.",
     lib, [step(), step(shelves=["hero", "for-you"], patch={x["id"]: {"poster": False, "backdrop": False} for x in lib[:15]})])

# ---- tmdb
tl = [m(i, key=k, year=y, added=i * 11, lang="Telugu", p30=i % 4) for i, (k, y) in enumerate([("dune part two", 2024), ("inside out 2", 2024), ("kalki", 2024), ("pushpa the rule", 2024), ("moana 2", 2024), ("gladiator ii", 2024), ("wicked", 2024), ("amaran", 2024), ("vettaiyan", 2024), ("other a", 2022), ("other b", 2021), ("other c", 2020), ("other d", 2019)])]
tl += [sr(1, key="the bear", year=2022, lang="English"), sr(2, key="squid game", year=2021), sr(3, key="shogun", year=2024)]
ents = [dict(rank=1, type="movie", title="Dune: Part Two", orig="Dune: Part Two", year=2024), dict(rank=2, type="tv", title="Shōgun", orig="Shōgun", year=2024),
        dict(rank=3, type="movie", title="Wicked", year=2024), dict(rank=4, type="movie", title="Kalki 2898 AD", orig="Kalki", year=2024),
        dict(rank=5, type="tv", title="The Bear", year=2022), dict(rank=6, type="movie", title="Moana 2", year=2024),
        dict(rank=7, type="movie", title="Gladiator II", year=2023), dict(rank=8, type="movie", title="Not In Library", year=2024),
        dict(rank=9, type="tv", title="Squid Game", year=2030), dict(rank=10, type="movie", title="Amaran", year=2024)]
tmdb_on = dict(keyPresent=True, enabled=True, cache=dict(fetchedDaysAgo=2, entries=ents))
case("trending-matched", "TMDB weekly list matched locally by normalised title (article/accent folded, original title too) + year +-1 + kind. >=6 matches: Top This Week ordered by TMDB rank then local fill, caption trendingTMDB. Second step has 2 matches: local order, caption mostWatchedHere, bonus still applied.",
     tl, [step(preferredLang="Telugu", tmdb=tmdb_on), step(preferredLang="Telugu", tmdb=dict(keyPresent=True, enabled=True, cache=dict(fetchedDaysAgo=3, entries=ents[:2] + ents[7:8])))])
off = [step(preferredLang="Telugu", tmdb=dict(keyPresent=False, enabled=True, cache=dict(fetchedDaysAgo=1, entries=ents))),
       step(preferredLang="Telugu", tmdb=dict(keyPresent=True, enabled=False, cache=dict(fetchedDaysAgo=1, entries=ents))),
       step(preferredLang="Telugu", tmdb=dict(keyPresent=True, enabled=True, cache=None)), step(preferredLang="Telugu")]
case("offline-no-tmdb-key", "No own key / switch off / offline with no cache / no tmdb field: identical local-only result, caption mostWatchedHere, nothing matched. A cache present without a key is ignored.", tl, off)
case("expired-metadata", "Cache 31 and 45 days old: local only (expired); 181 days: purged (local only). Items with no year/rating/added fall back to neutral features.",
     tl + [dict(id="mx%d" % i, key="nometa %d" % i, year=None, rating=None, added=None) for i in range(8)],
     [step(preferredLang="Telugu", tmdb=dict(keyPresent=True, enabled=True, cache=dict(fetchedDaysAgo=d, entries=ents))) for d in (30, 31, 45, 181)])

# ---- profile switch
lib = [m(i, key="p%d" % i, year=2018 + i % 8, added=i * 9, q=2 + i % 4, lang=["Telugu", "Hindi"][i % 2], folder="f%d" % (i % 3), p30=i % 3) for i in range(40)]
case("profile-switch", "Profile A, then B (different seed and a dismissal only on B via patch), then A again: A's output must be unchanged and state never crosses profiles (A commits shown rows, B has none).",
     lib, [step(profile="A", commit=True, shelves=["hero", "for-you"]), step(profile="B", patch={"m1": {"dismissed": True}, "m2": {"dismissed": True}}, commit=True, shelves=["hero", "for-you"]),
           step(profile="A", counter=0, shelves=["hero", "for-you"]), step(profile="A", counter=1, shelves=["hero", "for-you"])])
case("exclusions", "Locked/hidden/Kids restricted ('restricted'), restricted twin, rec_dismissed: none appear on any recommendation shelf; dismissed still appears in folder rows, restricted never.",
     lib, [step(shelves=GLOBAL + ["folder:f0"], patch={"m3": {"restricted": True}, "m4": {"dismissed": True}, "m5": {"restricted": True, "key": "p6"}, "m6": {"dismissed": True, "key": "p7"}})])

# ---- repeat suppression / reshuffle / day
lib = [m(i, key="rs%d" % i, year=2020 + i % 6, added=i * 5, q=2 + i % 4) for i in range(60)]
case("repeat-suppression-5-loads", "Five consecutive loads with commit: fresh weight (100/400/700) lowers repeats; a rebuild with the same loadKey is stable (step 2 repeats step 1's loadKey).",
     lib, [step(counter=0, commit=True, shelves=["hero", "for-you"]), step(counter=0, commit=True, shelves=["hero", "for-you"])] +
     [step(counter=c, commit=True, shelves=["hero", "for-you"]) for c in (1, 2, 3, 4)])
case("reshuffle-sequence", "Counters 0,1,2 on the same day give three different orders; same counter twice is identical.", lib, [step(counter=c, shelves=["hero", "for-you", "rediscover"]) for c in (0, 1, 2, 2)])
case("day-rollover", "Same library, three calendar days (incl. year change and a leap day): a new dayKey re-seeds.", lib, [step(day=d, shelves=["hero", "top-week"]) for d in ("2026-11-21", "2026-11-22", "2027-01-01", "2028-02-29")])

# ---- diversity
lib = [m(i, key="fr%d" % i, franchise="saga", genre="action", lang="Telugu", q=5, year=2025, added=1, backdrop=True) for i in range(10)] + \
      [sr(i, key="sh%d" % i, franchise=None, genre="drama", lang="Hindi", q=4, year=2025, added=2, backdrop=True) for i in range(10)] + \
      [m(40 + i, key="mm%d" % i, genre="comedy", lang="English", q=3, year=2024, added=3, backdrop=True) for i in range(10)]
case("diversity-limits", "Franchise-heavy and language-heavy top scorers: max 2 consecutive same franchise/genre/kind(hero)/language and the franchise /4, same-lang-kind x3/4 penalties.",
     lib, [step(preferredLang="Telugu", shelves=["hero", "for-you", "top-week", "lang-pref"]), step(counter=1, preferredLang="Telugu", shelves=["hero", "for-you"])])

# ---- byte order
ids = ["Ａ", "\U0001F3AC", "", "z", "Z", "a", "é", "త", "\U00010400", "￿"]
lib = [dict(id=i, key="tie %d" % n, year=2020, added=10, q=3) for n, i in enumerate(ids)]
case("non-latin-ids-byte-order", "All scores tie: order is by UTF-8 bytes of id (U+FF21 < U+10400 in UTF-8 but UTF-16 order differs), not locale or UTF-16.", lib, [step(shelves=["hero", "for-you", "top-week"])])

# ---- relaxation
lib = [m(1, key="a", watched=True, completed=True, lastWatched=3, backdrop=True), m(2, key="b", watched=True, poster=True), m(3, key="c", poster=False, backdrop=False),
       m(4, key="d", poster=False, q=0, cam=True), m(5, key="e", q=0, cam=True, poster=True), m(6, key="f", poster=False, backdrop=False, q=0, cam=True),
       m(7, key="g", loadsAgo=None, watched=True, poster=True), m(8, key="h", poster=True, lang="Telugu"), m(9, key="i", poster=False, backdrop=False)]
case("relaxation-order", "Too few eligible items so the tiers are reached in turn (fresh const, diversity off, watched allowed -200, poster-less, sole CAM). lang-pref is never relaxed (hidden). Diagnostics report the tier used.",
     lib, [step(preferredLang="Telugu", shelves=["hero", "for-you", "top-week", "lang-pref", "rediscover", "folder:f9"])])

# ---- generated
lib300 = R.generate("mixed", 1, 300, 20)
case("small-mixed-300", "300 synthetic titles (inline) covering every field: full six-shelf output, 3 loads with commit.", lib300,
     [step(preferredLang="Telugu", affinity=AFF, commit=True, shelves=GLOBAL + ["folder:f1", "folder:f3"]), step(counter=0, preferredLang="Telugu", affinity=AFF, commit=True, shelves=GLOBAL),
      step(counter=1, preferredLang="Telugu", affinity=AFF, commit=True, shelves=GLOBAL), step(counter=2, preferredLang="Telugu", affinity=AFF, shelves=GLOBAL)])
gen = dict(name="folders", seed=7, n=30000, folders=700)
lib = R.generate(**gen)
fshelves = ["folder:f%d" % i for i in range(700)]
case("hundreds-of-folders", "700 folders (skewed sizes) from the documented generator; the digest covers all 700 folder shelves, 'first' lists the six global shelves.",
     lib, [step(preferredLang="Telugu", affinity=AFF, shelves=GLOBAL + fshelves)], generator=gen, digest_only=True)
for nm, n, fl, seed_ in (("large-66k", 66540, 632, 11), ("stress-200k", 200000, 1500, 13)):
    gen = dict(name=nm, seed=seed_, n=n, folders=fl); lib = R.generate(**gen)
    case(nm, "%d candidates from the documented generator: top shelf outputs under pool cap 2000 (digest + first ids)." % n, lib,
         [step(preferredLang="Telugu", affinity=AFF, shelves=GLOBAL + ["folder:f1", "folder:f5"])], generator=gen, digest_only=True)
print("ok")
