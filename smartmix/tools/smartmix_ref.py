"""Smart Mix reference implementation (integer only). Defines the expected outputs of the shared fixtures.
Swift and Kotlin must reproduce every fixture exactly. Contract: the README in ../fixtures and the engine sources (SmartMixEngine.swift and its Kotlin twin)."""
import hashlib, re, unicodedata

M64 = (1 << 64) - 1

def fnv1a64(data: bytes) -> int:
    h = 0xcbf29ce484222325
    for b in data:
        h ^= b
        h = (h * 0x100000001b3) & M64
    return h

class SplitMix64:
    def __init__(self, state): self.state = state & M64
    def next(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & M64
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & M64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & M64
        return z ^ (z >> 31)
    def uniform(self, n):
        limit = ((M64 + 1) - n) % n if n > 0 else 0   # (0 &- n) % n
        while True:
            x = self.next()
            if x >= limit: return x % n

def seed_string(profile, shelf, day, counter):
    return "smartmix1|%s|%s|%s|%d" % (profile, shelf, day, counter)

def tdiv(a, b):  # truncating division like Swift / Kotlin
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q

def ub(s): return s.encode("utf-8")

# ---------------- features (0..1000)
def f_release(year, now_year):
    if year is None: return 300
    age = max(0, now_year - year)
    for lim, v in ((0, 1000), (1, 850), (2, 700), (3, 560), (4, 450), (5, 360)):
        if age == lim: return v
    if age <= 8: return 260
    if age <= 15: return 150
    return 80

def f_added(d):
    if d is None: return 300
    d = max(0, d)
    for lim, v in ((7, 1000), (30, 800), (90, 600), (180, 450), (365, 300)):
        if d <= lim: return v
    return 150

def f_quality(r): return {5: 1000, 4: 800, 3: 600, 2: 450, 1: 250, 0: 0}.get(r, 0)

def f_language(lang, pref):
    if pref is None: return 500
    if lang is None: return 500
    return 1000 if lang == pref else 150

RATING_RE = re.compile(r'^[0-9]{1,2}(\.[0-9]{1,2})?$', re.ASCII)
def f_rating(text):
    if text is None or RATING_RE.fullmatch(text) is None: return 500
    whole, _, frac = text.partition(".")
    tenths = int(whole) * 10 + (int(frac[0]) if frac else 0)
    if tenths < 1 or tenths > 99: return 500
    raw = min(1000, max(0, 500 + (tenths - 60) * 12))
    return 500 + tdiv((raw - 500) * 40, 100)

def f_popularity(p7, p30):
    c = p7 * 2 + p30
    if c <= 0: return 0
    if c == 1: return 400
    if c == 2: return 600
    if c <= 4: return 750
    if c <= 9: return 900
    return 1000

def f_affinity(c, aff):
    s = 0
    langs = aff.get("topLangs", [])
    if c["lang"] is not None:
        if len(langs) > 0 and c["lang"] == langs[0]: s += 400
        elif c["lang"] in langs[1:3]: s += 250
    if c["folder"] is not None and c["folder"] in aff.get("topFolders", [])[:5]: s += 200
    if c["genre"] is not None and c["genre"] in aff.get("topGenres", [])[:5]: s += 100
    if c["year"] is not None and (c["year"] // 10) * 10 in aff.get("topDecades", [])[:2]: s += 150
    return min(1000, s)

def f_fresh(ago):
    if ago is None: return 1000
    return {1: 100, 2: 400, 3: 700}.get(ago, 1000)

# ---------------- weights: release added quality language rating popularity affinity fresh
SHELVES = {
 "hero":      dict(w=(10,10,15,15,5,10,20,15), sharp=True,  pool=2000, size=12, minc=3, mixes=True),
 "for-you":   dict(w=(5,5,10,15,5,10,40,10),   sharp=True,  pool=2000, size=14, minc=6, mixes=False),
 "rediscover":dict(w=(10,0,15,15,10,0,35,15),  sharp=True,  pool=2000, size=14, minc=6, mixes=False),
 "lang-pref": dict(w=(15,15,25,0,5,15,15,10),  sharp=True,  pool=2000, size=14, minc=6, mixes=False),
 "top-week":  dict(w=(10,15,10,10,5,40,0,10),  sharp=True,  pool=2000, size=14, minc=6, mixes=False),
 "trending-library": dict(w=(10,15,10,10,5,40,0,10), sharp=True, pool=2000, size=14, minc=3, mixes=False),
 "folder":    dict(w=(10,25,30,20,0,0,0,15),   sharp=False, pool=200,  size=12, minc=1, mixes=False),
}
def shelf_def(shelf_id): return SHELVES["folder" if shelf_id.startswith("folder:") else shelf_id]

DEFAULTS = dict(kind="movie", key="", year=None, added=None, rating=None, q=2, cam=False, lang=None, folder=None,
                franchise=None, genre=None, poster=True, backdrop=False, watched=False, completed=False,
                lastWatched=None, p7=0, p30=0, trend=None, loadsAgo=None, restricted=False, dismissed=False, src=0)
def norm(c):
    d = dict(DEFAULTS); d.update(c); return d

# ---------------- prepare (restriction filter + identity grouping + representative)
def group_clusters(members):
    members = sorted(members, key=lambda m: (m["year"] is None, m["year"] or 0, ub(m["id"])))
    clusters = []
    nily = []
    for m in members:
        if m["year"] is None: nily.append(m); continue
        if clusters and m["year"] - clusters[-1][0] <= 1: clusters[-1][1].append(m)
        else: clusters.append((m["year"], [m]))
    out = [c[1] for c in clusters]
    if nily:
        if out: out[0].extend(nily)
        else: out.append(nily)
    return out

def pick_rep(members, pref_lang):
    pool = [m for m in members if not m["cam"]] or members
    def k(m):
        langrank = 0 if (pref_lang is not None and m["lang"] == pref_lang) else 1
        return (langrank, -m["q"], m["src"], m["added"] is None, m["added"] or 0, ub(m["id"]))
    return min(pool, key=k)

def prepare(cands, pref_lang):
    groups = {}
    for c in cands:
        groups.setdefault((c["kind"], c["key"]), []).append(c)
    reps = []
    for key in sorted(groups, key=lambda k: (k[0], ub(k[1]))):
        for cl in group_clusters(groups[key]):
            rep = dict(pick_rep(cl, pref_lang))
            rep["restricted"] = any(m["restricted"] for m in cl)
            rep["dismissed"] = any(m["dismissed"] for m in cl)
            rep["camOnly"] = all(m["cam"] for m in cl)
            rep["watched"] = any(m["watched"] for m in cl)
            rep["completed"] = any(m["completed"] for m in cl)
            lw = [m["lastWatched"] for m in cl if m["lastWatched"] is not None]
            rep["lastWatched"] = min(lw) if lw else None
            rep["p7"] = sum(m["p7"] for m in cl); rep["p30"] = sum(m["p30"] for m in cl)
            tr = [m["trend"] for m in cl if m["trend"] is not None]
            rep["trend"] = min(tr) if tr else None
            la = [m["loadsAgo"] for m in cl if m["loadsAgo"] is not None]
            rep["loadsAgo"] = min(la) if la else None
            reps.append(rep)
    return dict(inCount=len(cands), groups=reps)

# ---------------- scoring
def score(c, shelf_id, sd, ctx, relax):
    feats = (f_release(c["year"], ctx["nowYear"]), f_added(c["added"]), f_quality(c["q"]),
             f_language(c["lang"], ctx.get("preferredLang")), f_rating(c["rating"]),
             f_popularity(c["p7"], c["p30"]), f_affinity(c, ctx.get("affinity", {})),
             1000 if relax >= 1 else f_fresh(c["loadsAgo"]))
    s = sum(w * f for w, f in zip(sd["w"], feats)) // 100
    if shelf_id == "hero":
        if c["backdrop"]: s += 50
        if c["trend"] is not None: s += 60
    elif shelf_id in ("top-week", "trending-library"):
        if c["trend"] is not None: s += 100
    if relax >= 3 and c["watched"] and shelf_id != "rediscover": s -= 200
    return max(0, min(1100, s))

def weight(s, sharp): return 1 + (s * s) // 100 if sharp else 1 + s

# ---------------- draw
def draw(items, ws, k, rng, sd, relax, shelf_id, forced=()):
    n = len(items); w = list(ws); picks = []
    div = relax < 2
    lang_rule = shelf_id != "lang-pref"
    for i in forced: w[i] = 0; picks.append(i)
    diag_relaxed = False
    while len(picks) < k:
        def blocked(i):
            if not div or len(picks) < 2: return False
            a, b = items[picks[-1]], items[picks[-2]]; c = items[i]
            if c["franchise"] is not None and a["franchise"] == c["franchise"] and b["franchise"] == c["franchise"]: return True
            if c["genre"] is not None and a["genre"] == c["genre"] and b["genre"] == c["genre"]: return True
            if sd["mixes"] and a["kind"] == c["kind"] and b["kind"] == c["kind"]: return True
            if lang_rule and c["lang"] is not None and a["lang"] == c["lang"] and b["lang"] == c["lang"]: return True
            return False
        elig = [i for i in range(n) if w[i] > 0 and not blocked(i)]
        if not elig:
            elig = [i for i in range(n) if w[i] > 0]
            if elig: diag_relaxed = True
        total = sum(w[i] for i in elig)
        if total == 0: break
        r = rng.uniform(total); acc = 0; p = elig[-1]
        for i in elig:
            acc += w[i]
            if r < acc: p = i; break
        w[p] = 0; picks.append(p)
        if div:
            pc = items[p]
            for j in range(n):
                if w[j] == 0: continue
                cj = items[j]
                if pc["franchise"] is not None and cj["franchise"] == pc["franchise"]: w[j] = w[j] // 4
                if lang_rule and pc["lang"] is not None and cj["lang"] == pc["lang"] and cj["kind"] == pc["kind"]: w[j] = (w[j] * 3) // 4
    return picks, diag_relaxed

# ---------------- shelf build
def index_folders(groups):
    d = {}
    for c in groups:
        if c["folder"] is not None: d.setdefault(c["folder"], []).append(c)
    return d

def build_shelf(prep, shelf_id, ctx, trending_ordered):
    sd = shelf_def(shelf_id); is_folder = shelf_id.startswith("folder:")
    folder_key = shelf_id[7:] if is_folder else None
    groups = prep["groups"]
    diag = dict(inCount=prep["inCount"], groups=len(groups), restricted=0, dismissed=0, camOnly=0, noArtwork=0,
                watched=0, lang=0, notTrending=0, pool=0, drawn=0, tier=0, tiny=False, hidden=False,
                fallback="none", diversityRelaxed=False, caption="", trendMode=False)
    base = []
    if is_folder:
        groups = prep.setdefault("byFolder", index_folders(groups)).get(folder_key, [])
        diag["groups"] = len(groups)
    for c in groups:
        if c["restricted"]: diag["restricted"] += 1; continue
        base.append(c)
    if not is_folder:
        keep = []
        for c in base:
            if c["dismissed"]: diag["dismissed"] += 1
            else: keep.append(c)
        base = keep
    if shelf_id == "lang-pref" and not ctx.get("preferredLang"):
        diag["hidden"] = True; return [], diag
    result = None
    need = min(sd["minc"], len(base))
    trend_mode = shelf_id == "trending-library" and sum(1 for c in base if c["trend"] is not None) >= 3
    diag["trendMode"] = trend_mode
    for tier in range(0, 6):
        elig = []; counts = dict(camOnly=0, noArtwork=0, watched=0, lang=0, notTrending=0)
        for c in base:
            if c["camOnly"] and tier < 5: counts["camOnly"] += 1; continue
            if shelf_id == "hero":
                if not (c["backdrop"] or c["poster"]): counts["noArtwork"] += 1; continue
            elif not c["poster"] and tier < 4: counts["noArtwork"] += 1; continue
            if shelf_id == "lang-pref" and c["lang"] != ctx.get("preferredLang"): counts["lang"] += 1; continue
            if trend_mode and c["trend"] is None: counts["notTrending"] += 1; continue
            if not is_folder:
                if shelf_id == "rediscover":
                    if c["watched"] and (not c["completed"] or (c["lastWatched"] is not None and c["lastWatched"] <= 30)):
                        counts["watched"] += 1; continue
                elif c["watched"] and tier < 3: counts["watched"] += 1; continue
            elig.append(c)
        tiny = len(elig) <= sd["size"]
        eff = max(tier, 1) if tiny else tier
        scored = [(score(c, shelf_id, sd, ctx, eff), c) for c in elig]
        scored.sort(key=lambda t: (-t[0], ub(t[1]["id"])))
        pool = scored[:ctx.get("poolCap", sd["pool"]) if not is_folder else min(sd["pool"], ctx.get("poolCap", sd["pool"]))]
        items = [c for _, c in pool]; ws = [weight(s, sd["sharp"]) for s, _ in pool]
        forced = []
        if trending_ordered and shelf_id == "top-week":
            order = sorted([i for i, c in enumerate(items) if c["trend"] is not None], key=lambda i: (items[i]["trend"], ub(items[i]["id"])))
            forced = order[:sd["size"]]
        k = min(sd["size"], len(items))
        rng = SplitMix64(fnv1a64(ub(seed_string(ctx["profile"], shelf_id, ctx["dayKey"], ctx["refreshCounter"]))))
        picks, dr = draw(items, ws, k, rng, sd, eff, shelf_id, forced) if k else ([], False)
        result = (tier, counts, tiny, items, picks, dr, len(elig))
        if len(picks) >= need: break
    tier, counts, tiny, items, picks, dr, nel = result
    for kx, v in counts.items(): diag[kx] = v
    diag.update(tier=tier, tiny=tiny, pool=len(items), drawn=len(picks), diversityRelaxed=dr)
    out = [items[i] for i in picks]
    if not out and shelf_id != "lang-pref":
        # never empty: recently added (restricted already removed), then plain library
        rec = sorted([c for c in base if c["poster"] or c["backdrop"]], key=lambda c: (c["added"] is None, c["added"] or 0, ub(c["id"])))
        diag["fallback"] = "recentlyAdded"
        if not rec and shelf_id != "hero":
            rec = sorted(base, key=lambda c: ub(c["id"])); diag["fallback"] = "plainLibrary"
        out = rec[:sd["size"]]
        if not out: diag["fallback"] = "existingFeatured" if shelf_id == "hero" else "none"
    elif not out: diag["hidden"] = True
    return out, diag

# ---------------- trending
def fold_title(s):
    s = unicodedata.normalize("NFKD", s)
    s = "".join(ch for ch in s if not unicodedata.combining(ch)).lower()
    s = re.sub(r"[^0-9a-z\u0080-￿\U00010000-\U0010ffff]+", " ", s)
    # (ASCII letters/digits kept, other scripts kept; punctuation and symbols become spaces)
    words = s.split()
    if words and words[0] in ("the", "a", "an") and len(words) > 1: words = words[1:]
    return " ".join(words)

def match_trending(entries, cands):
    """entries: [{rank,type,title,orig,year}], cands: normalised candidates. Returns {candidate id: rank} (lowest rank wins)."""
    idx = {}
    for c in cands: idx.setdefault((c["kind"], c["key"]), []).append(c)
    res = {}
    for e in sorted(entries, key=lambda e: e["rank"]):
        kind = "movie" if e["type"] == "movie" else "series"
        names = {fold_title(e["title"])}
        if e.get("orig"): names.add(fold_title(e["orig"]))
        for nm in sorted(names):
            for c in idx.get((kind, nm), []):
                if e.get("year") is not None and c["year"] is not None and abs(e["year"] - c["year"]) > 1: continue
                if c["id"] not in res: res[c["id"]] = e["rank"]
    return res

TMDB_DISPLAY_DAYS = 30; TMDB_MAX_DAYS = 180; TMDB_MIN_MATCHES = 6

def day_number(day):  # days since 0000-03-01 style civil count, integer only
    y, m, d = int(day[0:4]), int(day[5:7]), int(day[8:10])
    if m <= 2: y -= 1; m += 12
    return 365 * y + y // 4 - y // 100 + y // 400 + (153 * (m - 3) + 2) // 5 + d

# ---------------- state store
class State:
    def __init__(self): self.s = {}
    def get(self, p, sh): return self.s.setdefault((p, sh), dict(refresh=0, loadKey="", seq=0, rows=[]))
    def loads_ago(self, p, sh, load_key):
        st = self.get(p, sh); eff = st["seq"] if st["loadKey"] == load_key else st["seq"] + 1
        m = {}
        for ik, yr, iid, seq in st["rows"]:
            a = eff - seq
            if a >= 1: m[ik] = min(m.get(ik, a), a)
        return m
    def record(self, p, sh, load_key, rows):
        st = self.get(p, sh)
        if st["loadKey"] == load_key: return
        st["loadKey"] = load_key; st["seq"] += 1
        st["rows"] = (st["rows"] + [(ik, yr, iid, st["seq"]) for ik, yr, iid in rows])
        st["rows"].sort(key=lambda r: -r[3]); st["rows"] = st["rows"][:48]

# ---------------- run a step
def run_step(library, step, state):
    lib = [norm(c) for c in library]
    for cid, patch in step.get("patch", {}).items():
        for c in lib:
            if c["id"] == cid: c.update(patch)
    ctx = dict(profile=step["profile"], dayKey=step["dayKey"], refreshCounter=step.get("refreshCounter", 0),
               nowYear=int(step["dayKey"][:4]), preferredLang=step.get("preferredLang"), affinity=step.get("affinity", {}))
    if "poolCap" in step: ctx["poolCap"] = step["poolCap"]
    load_key = "%s|%d" % (ctx["dayKey"], ctx["refreshCounter"])
    tm = step.get("tmdb", {}); entries = None; tdiag = "off"
    if tm.get("enabled", True) and tm.get("keyPresent", False):
        cache = tm.get("cache")
        if cache is None: tdiag = "noCache"
        elif cache["fetchedDaysAgo"] > TMDB_MAX_DAYS: tdiag = "purged"
        elif cache["fetchedDaysAgo"] > TMDB_DISPLAY_DAYS: tdiag = "expired"
        else: entries = cache["entries"]; tdiag = "active"
    out = {}; cache_box = {}
    pref = ctx["preferredLang"]
    for shelf_id in step["shelves"]:
        lk = state.loads_ago(ctx["profile"], shelf_id, load_key)
        cs = []
        for c in lib:
            d = dict(c); d["loadsAgo"] = lk.get(c["key"]); d["trend"] = None; cs.append(d)
        matched = {}
        if entries is not None:
            matched = match_trending(entries, cs)
            for d in cs: d["trend"] = matched.get(d["id"])
        if entries is None and not lk:
            if "_plain" not in cache_box: cache_box["_plain"] = prepare(cs, pref)
            prep = cache_box["_plain"]
        else: prep = prepare(cs, pref)
        ordered = False
        if shelf_id == "top-week" and entries is not None:
            cnt = sum(1 for g in prep["groups"] if not g["restricted"] and g["trend"] is not None)
            ordered = cnt >= TMDB_MIN_MATCHES
        items, diag = build_shelf(prep, shelf_id, ctx, ordered)
        diag["caption"] = ("trendingTMDB" if ordered else "mostWatchedHere") if shelf_id == "top-week" else (("trendingTMDB" if diag["trendMode"] else "mostWatchedHere") if shelf_id == "trending-library" else "")
        diag["tmdb"] = tdiag if shelf_id in ("top-week", "trending-library", "hero") else ""
        out[shelf_id] = dict(ids=[c["id"] for c in items], diag=diag,
                             art=[("backdrop" if c["backdrop"] else "poster") for c in items] if shelf_id == "hero" else [])
        if step.get("commit", False):
            state.record(ctx["profile"], shelf_id, load_key, [(c["key"], c["year"], c["id"]) for c in items if not c["restricted"]])
    return out

# ---------------- synthetic library generator (documented in README, integer only)
LANGS = ["Telugu", "Hindi", "English", "Tamil", "Malayalam", "Kannada"]
GENRES = ["action", "drama", "comedy", "thriller", "family", "horror", "romance", "scifi"]
def generate(name, seed, n, folders):
    g = SplitMix64(fnv1a64(ub("smartmix-gen1|%s|%d" % (name, seed))))
    u = g.uniform
    out = []
    for i in range(n):
        series = u(100) < 27
        c = dict(id=("s%d" if series else "m%d") % i, kind="series" if series else "movie")
        c["key"] = "t%d" % u(max(1, n * 4 // 5))
        c["year"] = 2026 - min(u(36), u(36))
        c["added"] = None if u(100) < 5 else u(700)
        r = u(20)
        if r == 0: c["rating"] = ""
        elif r == 1: c["rating"] = "0"
        elif r == 2: c["rating"] = "10"
        elif r == 3: c["rating"] = "10.0"
        else:
            t = 30 + u(60); c["rating"] = "%d.%d" % (t // 10, t % 10)
        r = u(100)
        if r < 8: c["q"], c["cam"] = 0, True
        elif r < 15: c["q"] = 1
        elif r < 45: c["q"] = 2
        elif r < 75: c["q"] = 3
        elif r < 92: c["q"] = 4
        else: c["q"] = 5
        a, b = u(6), u(6); lang = LANGS[min(a, b)]
        c["lang"] = None if u(100) < 3 else lang
        fa, fb = u(folders), u(folders); c["folder"] = "f%d" % ((fa * fb) // folders)
        c["franchise"] = ("fr%d" % u(n // 50 + 1)) if u(100) < 20 else None
        gi = u(8); c["genre"] = None if u(100) < 5 else GENRES[gi]
        c["poster"] = u(100) >= 12
        c["backdrop"] = u(100) < 55
        c["watched"] = u(100) < 6
        c["completed"] = c["watched"] and u(100) < 70
        lw = u(120); c["lastWatched"] = lw if c["watched"] else None
        c["p7"] = (1 + u(5)) if u(100) < 4 else 0
        c["p30"] = c["p7"] + (u(8) if u(100) < 8 else 0)
        c["restricted"] = u(1000) < 8
        c["dismissed"] = u(1000) < 3
        c["src"] = u(2)
        out.append(c)
    return out

def digest(step_out, shelves):
    h = hashlib.sha256()
    for s in shelves:
        h.update(("%s:" % s).encode()); h.update("\n".join(step_out[s]["ids"]).encode()); h.update(b"\n")
    return h.hexdigest()
