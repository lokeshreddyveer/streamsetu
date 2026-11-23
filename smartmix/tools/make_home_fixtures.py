#!/usr/bin/env python3
"""Writes smartmix/fixtures/home-layout.json: the Home v2 contract (docs/SMART-MIX.md section 10) as integer-only reference code plus expected values.
Swift (`HomeLayoutTests`) and Kotlin must reproduce every expected value. Run: python3 smartmix/tools/make_home_fixtures.py"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TABLE = json.load(open(os.path.join(ROOT, "fixtures", "genre-shelves.json")))["table"]

# ---- kinds and layout -------------------------------------------------------------------------------------------------------------
def kind(i):
    if i in ("top-week", "trending"): return "ranking"
    if i in ("for-you", "rediscover", "lang-pref"): return "personal"
    if i in ("fresh", "movie-night", "binge"): return "context"
    if i == "collections": return "collection"
    return "mood" if i.startswith("mood:") else "genre"

def day_flags(wd, hr):
    movie = ((wd in (5, 6)) and hr >= 17) or ((wd in (6, 7)) and hr < 4)
    return movie, wd >= 6, 5 <= hr < 11

def layout(present, genres, moods, wd, hr, kids):
    movie_night, weekend, morning = day_flags(wd, hr)
    g, m = list(genres), list(moods)
    if kids: tokens = ["M", "top-week", "G", "for-you", "G", "fresh", "collections", "G", "M", "rediscover", "lang-pref", "G", "trending", "G"]
    elif morning: tokens = ["top-week", "fresh", "for-you", "G", "trending", "M", "G", "lang-pref", "collections", "G", "movie-night", "binge", "M", "rediscover", "G", "G"]
    else: tokens = ["top-week", "for-you", "movie-night", "G", "trending", "M", "G", "lang-pref", "binge", "collections", "G", "rediscover", "M", "G", "fresh", "G", "G"]
    queue = []
    for t in tokens:
        if t == "G":
            if g: queue.append(g.pop(0))
        elif t == "M":
            if m: queue.append(m.pop(0))
        elif t == "movie-night":
            if t in present and movie_night: queue.append(t)
        elif t == "binge":
            if t in present and weekend: queue.append(t)
        elif t in present: queue.append(t)
    queue += g + m
    out, dropped = [], []
    while queue and len(out) < 12:
        last = kind(out[-1]) if out else None
        pick = next((i for i in range(min(3, len(queue))) if kind(queue[i]) != last), None)
        if pick is None: dropped.append(queue.pop(0))
        else: out.append(queue.pop(pick))
    while len(out) < 6 and dropped: out.append(dropped.pop(0))
    return out

# ---- genres -----------------------------------------------------------------------------------------------------------------------
def matches(gd, tokens, kind_):
    if gd["scope"] == "movie" and kind_ != "movie": return False
    if gd["scope"] == "series" and kind_ != "series": return False
    for t in tokens:
        for a in gd["aliases"]:
            if t == a or (" " + a + " ") in (" " + t + " "): return True
    return False

def genre_keys(tokens, kind_): return [g["key"] for g in TABLE if matches(g, tokens, kind_)]

# ---- composition ------------------------------------------------------------------------------------------------------------------
def minimum(i): return 3 if i == "trending-library" else (8 if i.startswith("genre:") else 6)
def size(i): return 14

def rerank(picks, n):
    rest = list(enumerate(picks)); out = []
    while len(out) < n and rest:
        best, best_s = 0, None
        for i in range(min(len(rest), 8)):
            pos, c = rest[i]
            s = 1000 - 30 * pos
            for back, o in enumerate(reversed(out[-3:])):
                if c.get("franchise") and c["franchise"] == o.get("franchise"): s -= 300
                if c.get("year") is not None and o.get("year") is not None and c["year"] // 10 == o["year"] // 10: s -= 60
                if back < 2:
                    if c.get("genre") and c["genre"] == o.get("genre"): s -= 80
                    if c.get("lang") and c["lang"] == o.get("lang") and c["kind"] == o["kind"]: s -= 40
            if best_s is None or s > best_s: best, best_s = i, s
        out.append(rest.pop(best)[1])
    return out

def is_exploration(p, aff):
    keys = genre_keys(p.get("genres", []), p["kind"])
    if keys and any(k in aff["genreKeys"] for k in keys): return False
    if p.get("lang") and aff["topLangs"][:1] == [p["lang"]]: return False
    return True

def explore(main, left, aff):
    if not aff["genreKeys"] and not aff["topLangs"]: return main
    out = list(main); pool = [x for x in left if is_exploration(x, aff)]
    slot = 5
    while slot < len(out):
        if not is_exploration(out[slot], aff) and pool: out[slot] = pool.pop(0)
        slot += 6
    return out

def compose(results, aff, wd, hr, kids):
    shown = lambda r: not r.get("hidden") and r["picks"]
    by = {r["id"]: r for r in results}
    genre_ids = [r["id"] for r in results if r["id"].startswith("genre:") and shown(r)]
    mood_ids = [r["id"] for r in results if r["id"].startswith("mood:") and shown(r)]
    def present(ids):
        s = set()
        for r in results:
            i = r["id"]
            if shown(r) and i in ids and not i.startswith(("genre:", "mood:")) and i != "hero": s.add("trending" if i == "trending-library" else i)
        return s
    rid = lambda i: "trending-library" if i == "trending" else i
    first = [rid(i) for i in layout(present(set(by)), genre_ids, mood_ids, wd, hr, kids)]
    used, rows = set(), {}
    for i in first:
        r = by.get(i)
        if not r: continue
        if i == "collections": rows[i] = [p["id"] for p in r["picks"]]; continue
        free = [p for p in r["picks"] if p["id"] not in used]
        n = size(i)
        if r.get("ordered"): picks = free[:n]
        else:
            picks = rerank(free, n)
            if i == "for-you":
                left = [f for f in free if all(f["id"] != p["id"] for p in picks)]
                picks = explore(picks, left, aff)
        if len(picks) < minimum(i): continue
        used.update(p["id"] for p in picks)
        rows[i] = [p["id"] for p in picks]
    surv = set(rows)
    order = [rid(i) for i in layout(present(surv), [g for g in genre_ids if g in surv], [m for m in mood_ids if m in surv], wd, hr, kids)]
    return [{"row": i, "ids": rows[i]} for i in order if i in rows]

# ---- franchise, mode default ------------------------------------------------------------------------------------------------------
SMALL = set("its a an the i my me in on of to is are one all no you we our your this that with from for not too his her how what when who love man day night life".split())
ROMAN = {"ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x"}
MARK = {"part", "chapter", "vol", "volume", "episode"}
FUNCTION = {"of", "the", "in", "on", "to", "a", "an", "for", "with", "and", "is", "at", "by"}
def is_marker(w): return (len(w) <= 2 and w.isdigit()) or w in ROMAN or w in MARK
def franchise(key):
    w = key.split(" ")
    while len(w) > 1 and is_marker(w[-1]): w.pop()
    if len(w) < 2: return None
    a, b = w[0], w[1]
    if b in FUNCTION: return None
    if a.isdigit() and b.isdigit(): return None
    if not any(len(x) >= 4 and x not in SMALL for x in (a, b)): return None
    return a + " " + b

def mode_default(chosen, weekly, alltime):
    if chosen: return chosen, False
    if not weekly and alltime: return "allTime", True
    return "weekly", False

# ---- cases ------------------------------------------------------------------------------------------------------------------------
def pk(i, **kw): d = {"id": i, "kind": "movie"}; d.update(kw); return d

full = {"top-week", "trending", "for-you", "lang-pref", "rediscover", "fresh", "movie-night", "binge", "collections"}
G = ["genre:thriller", "genre:comedy", "genre:scifi", "genre:drama", "genre:action", "genre:horror"]
M = ["mood:edge", "mood:feelGood"]
layout_cases = [
    ("weekday afternoon, full library", full, G, M, 3, 14, False),
    ("friday evening: movie night", full, G, M, 5, 20, False),
    ("saturday morning: fresh first, binge on", full, G, M, 6, 8, False),
    ("sunday evening: binge, no movie night", full, G, M, 7, 20, False),
    ("kids profile", full - {"movie-night", "binge", "lang-pref"}, ["genre:comedy", "genre:animation", "genre:family"], ["mood:withKids", "mood:feelGood"], 5, 20, True),
    ("brand-new install: only popular row and genres", {"top-week", "collections"}, G[:3], [], 2, 12, False),
    ("no genre rows, no moods", {"top-week", "for-you", "rediscover"}, [], [], 2, 12, False),
    ("only genre rows: a thin page keeps six", set(), G, [], 2, 12, False),
    ("late night after Saturday: small hours keep movie night", full, G, M, 7, 2, False),
]
out_layout = [{"name": n, "present": sorted(p), "genres": g, "moods": m, "weekday": wd, "hour": hr, "kids": k, "expect": layout(p, g, m, wd, hr, k)} for n, p, g, m, wd, hr, k in layout_cases]

def mk(prefix, n, **kw): return [pk(f"{prefix}{i:02d}", **{k: (v(i) if callable(v) else v) for k, v in kw.items()}) for i in range(n)]
decade = lambda i: 2020 - 10 * (i % 3) + i % 7 % 3
res1 = [
    {"id": "top-week", "ordered": True, "picks": mk("a", 16, year=2024, genre="action", genres=["action"])},
    {"id": "trending-library", "ordered": False, "picks": [pk(f"a{i:02d}", year=2024, genre="action", genres=["action"]) for i in range(0, 6)] + mk("t", 10, year=lambda i: 2019 - i % 5, genre="drama", genres=["drama"])},
    {"id": "for-you", "ordered": False, "picks": mk("f", 24, year=lambda i: 2000 + (i * 3) % 24, genre=lambda i: ["thriller", "drama", "comedy", "sci-fi"][i % 4], genres=lambda i: [["thriller"], ["drama"], ["comedy"], ["science fiction"]][i % 4], lang="Hindi", franchise=lambda i: "saga" if i % 5 == 0 else None)},
    {"id": "genre:thriller", "ordered": False, "picks": mk("g", 24, year=lambda i: 2010 + i % 12, genre="thriller", genres=["thriller"])},
    {"id": "genre:comedy", "ordered": False, "picks": mk("f", 5) + mk("c", 4, genres=["comedy"], genre="comedy")},
    {"id": "movie-night", "ordered": False, "picks": mk("m", 14, year=2020, genre="drama", genres=["drama"])},
    {"id": "binge", "ordered": False, "picks": mk("b", 14, kind="series", year=2021, genre="drama", genres=["drama"])},
]
aff = {"genreKeys": ["thriller", "drama"], "topLangs": ["Hindi"]}
aff0 = {"genreKeys": [], "topLangs": []}
compose_cases = []
for name, a, wd, hr, kids in [("weekday: every title appears once; rows below the minimum disappear", aff, 3, 14, False),
                              ("friday evening adds movie night", aff, 5, 20, False),
                              ("no history: no exploration slots", aff0, 3, 14, False)]:
    compose_cases.append({"name": name, "results": res1, "affinity": a, "weekday": wd, "hour": hr, "kids": kids, "expect": compose(res1, a, wd, hr, kids)})

franchise_cases = [(k, franchise(k)) for k in ["john wick", "john wick 2", "john wick chapter 4", "harry potter chamber secrets", "iron man 3", "crash", "heat", "the", "fast furious 6", "ocean eleven", "a b", "12 34", "rocky ii", "mission impossible fallout", "rocky", "3 idiots", "lord of rings fellowship", "lord of war"]]
mode_cases = [{"chosen": c, "weeklyOrdered": w, "allTimeOrdered": a, "mode": mode_default(c, w, a)[0], "auto": mode_default(c, w, a)[1]}
              for c, w, a in [(None, True, True), (None, False, True), (None, False, False), (None, True, False), ("weekly", False, True), ("allTime", True, False)]]

TITLES = ["Pick Up Where You Left Off", "This Week's Top Picks", "Popular in Your Library", "Picked for You", "Hidden Gems", "Fresh Additions", "Movie Night", "Binge-Worthy Series", "Collections", "Browse by Genre",
          "With the Kids", "Edge of Your Seat", "Feel-Good Picks"]
GENRE_TITLES = {"action": "Action Packed", "comedy": "Laugh Out Loud", "drama": "Drama Worth Your Time", "thriller": "Thrillers Worth Watching", "scifi": "Sci-Fi Picks", "horror": "Horror After Dark",
                "romance": "Love Stories", "crime": "Crime Stories", "animation": "Animated Favourites", "documentary": "Real-World Docs", "family": "Family Time", "fantasy": "Fantasy Worlds",
                "mystery": "Mysteries to Solve", "adventure": "Adventure Awaits", "war": "War Stories", "western": "Westerns", "history": "History Comes Alive", "music": "Music and Musicals",
                "biography": "True Life Stories", "kids": "Kids' Corner", "anime": "Anime Picks", "reality": "Reality Favourites"}
assert len(set(TITLES + list(GENRE_TITLES.values()))) == len(TITLES) + len(GENRE_TITLES)
assert set(GENRE_TITLES) == {g["key"] for g in TABLE}

doc = {"name": "home-layout", "description": "Home v2: row placement by weekday and time, one-title-per-screen composition with re-rank and exploration slots, franchise keys, default view of a ranked row, row names. Written by smartmix/tools/make_home_fixtures.py.",
       "layout": out_layout, "compose": compose_cases,
       "franchise": [{"key": k, "expect": f} for k, f in franchise_cases], "modeDefault": mode_cases,
       "titles": {"rows": TITLES, "genres": GENRE_TITLES}}
with open(os.path.join(ROOT, "fixtures", "home-layout.json"), "w") as f: json.dump(doc, f, indent=1, ensure_ascii=False); f.write("\n")
for c in out_layout: print(c["name"], "->", c["expect"])
for c in compose_cases: print(c["name"], "->", [(r["row"], len(r["ids"])) for r in c["expect"]])
print([ (k,f) for k,f in franchise_cases])
