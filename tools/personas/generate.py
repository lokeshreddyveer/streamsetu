#!/usr/bin/env python3
"""Generates the synthetic persona libraries used to evaluate the matching, Smart Mix, search and guide-mapping engines.

Input : the public TMDB gold list written by fetch_tmdb.py (gold.json). No user data of any kind is read.
Output: OUT_DIR/<persona>.json (library with a gold standard), OUT_DIR/tmdb-index.json (what the fake TMDB transport serves) and OUT_DIR/guide.json.
Deterministic: the same gold list and seed give byte-identical output.
Usage: generate.py GOLD_JSON OUT_DIR [seed]"""
import json, os, random, re, sys, unicodedata

LANGNAME = {"en": "English", "hi": "Hindi", "te": "Telugu", "ta": "Tamil", "ml": "Malayalam", "kn": "Kannada", "bn": "Bengali", "mr": "Marathi", "pa": "Punjabi", "ur": "Urdu", "ko": "Korean",
            "ja": "Japanese", "zh": "Chinese", "tr": "Turkish", "ar": "Arabic", "es": "Spanish", "pt": "Portuguese", "fr": "French", "de": "German", "it": "Italian", "ru": "Russian", "id": "Indonesian", "th": "Thai"}
COUNTRY = {"en": ["US", "UK"], "hi": ["IN"], "te": ["IN"], "ta": ["IN"], "ml": ["IN"], "kn": ["IN"], "bn": ["IN", "BD"], "mr": ["IN"], "pa": ["IN", "PK"], "ur": ["PK"], "ko": ["KR"], "ja": ["JP"], "zh": ["CN"],
           "tr": ["TR"], "ar": ["AR", "SA"], "es": ["ES", "MX"], "pt": ["BR", "PT"], "fr": ["FR"], "de": ["DE"], "it": ["IT"], "ru": ["RU"], "id": ["ID"], "th": ["TH"]}
QUAL = ["1080p", "720p", "4K", "2160p", "FHD", "HD", "WEB-DL", "WEBRip", "HDRip", "BluRay", "BRRip", "x264", "x265", "HEVC", "H264", "CAM", "HDCAM", "HDTS", "DVDRip", "10bit", "5.1", "HDR"]
GROUPS = ["YIFY", "YTS.MX", "RARBG", "EVO", "FGT", "PSA", "NTb", "TGx", "ETRG", "MkvCage"]
TRANSLIT = [("aa", "a"), ("a", "aa"), ("ee", "i"), ("i", "ee"), ("oo", "u"), ("u", "oo"), ("th", "t"), ("v", "w"), ("w", "v"), ("ai", "ay"), ("sh", "s"), ("ph", "f"), ("kk", "k"), ("tt", "t"), ("ya", "iya")]
ROMAN = {"2": "II", "3": "III", "4": "IV", "5": "V"}

def is_latin(s): return bool(s) and all(ord(c) < 0x250 or not c.isalpha() for c in s)
def strip_acc(s): return "".join(c for c in unicodedata.normalize("NFD", s) if unicodedata.category(c) != "Mn")

class Gen:
    def __init__(self, seed): self.r = random.Random(seed)
    def p(self, x): return self.r.random() < x
    def pick(self, a): return self.r.choice(a)

    def translit(self, t):
        for _ in range(self.r.randint(1, 2)):
            a, b = self.pick(TRANSLIT)
            idx = [m.start() for m in re.finditer(a, t.lower())]
            if idx:
                i = self.pick(idx); t = t[:i] + b + t[i + len(a):]
        return t

    def sequel(self, t, tags):
        m = re.match(r"^(.*\S)\s+([2-5])$", t)
        if not m: return t
        base, n = m.groups(); tags.append("sequel")
        return self.pick([f"{base} Part {n}", f"{base} {ROMAN[n]}", f"{base} Chapter {n}", f"{base} {n}"])

    def name(self, item, lang_tag, prof, cat_country):
        """Returns (raw title, provider year, noise tags)."""
        tags = []
        t = item["title"]
        if item["original"] and is_latin(item["original"]) and item["original"] != t and self.p(prof.get("origTitle", 0.3)):
            t = item["original"]; tags.append("local-title")
        if item["lang"] in ("hi", "te", "ta", "ml", "kn", "bn", "mr", "pa", "ur", "ar", "ko", "ja", "zh", "th", "ru") and self.p(prof.get("translit", 0.3)):
            t2 = self.translit(t)
            if t2 != t: t = t2; tags.append("translit")
        if self.p(0.25): t = self.sequel(t, tags)
        if item["kind"] == "movie" and self.p(prof.get("colon", 0.2)) and ":" in t and self.p(0.5): t = t.replace(":", " -"); tags.append("subtitle-dash")
        year = item["year"]
        if year and self.p(prof.get("wrongYear", 0.12)): year += self.pick([-1, 1]); tags.append("wrong-year")
        if year and self.p(prof.get("noYear", 0.15)): year = None; tags.append("no-year")
        py = year if year else None
        mode = self.r.random()
        # year marks written into the name
        ytxt = item["year"]
        if ytxt and self.p(prof.get("yearInName", 0.55)):
            how = self.pick(["suffix-paren", "suffix-brack", "suffix-bare", "prefix-dash"])
            tags.append("year-" + how)
            if how == "suffix-paren": t = f"{t} ({ytxt})"
            elif how == "suffix-brack": t = f"{t} [{ytxt}]"
            elif how == "suffix-bare": t = f"{t} {ytxt}"
            else: t = f"{ytxt} - {t}"
        if self.p(prof.get("quality", 0.5)):
            q = " ".join(self.r.sample(QUAL, self.r.randint(1, 3))); tags.append("quality")
            t = f"{t} {q}" if not t.startswith(str(ytxt)) or self.p(0.7) else t
        if self.p(prof.get("group", 0.07)): t += self.pick([f"-{self.pick(GROUPS)}", f" [{self.pick(GROUPS)}]"]); tags.append("group")
        ln = LANGNAME.get(lang_tag, "")
        if self.p(prof.get("langTag", 0.4)):
            how = self.pick(["prefix-pipe", "prefix-dash", "suffix-paren", "dubbed", "multi", "code-prefix"])
            tags.append("lang-" + how)
            if how == "prefix-pipe": t = f"{ln.upper()} | {t}"
            elif how == "prefix-dash": t = f"{lang_tag.upper()} - {t}"
            elif how == "suffix-paren": t = f"{t} ({ln})"
            elif how == "dubbed": t = f"{t} {self.pick(['Hindi','Tamil','Telugu','English'])} Dubbed" if lang_tag != "en" else f"{t} ENGLISH DUBBED"
            elif how == "multi": t = f"{t} MULTI"
            else: t = f"|{lang_tag.upper()}| {t}"
        if self.p(prof.get("country", 0.2)):
            c = self.pick(cat_country or ["US"]); t = self.pick([f"{c}| {t}", f"{c}: {t}", f"{c} - {t}"]); tags.append("country")
        if self.p(prof.get("sep", 0.12)):
            t = t.replace(" ", self.pick([".", "_"])); tags.append("dots")
        if self.p(prof.get("caps", 0.15)): t = t.upper(); tags.append("caps")
        return t, py, tags

def build_index(gold):
    return [{"id": g["tmdb"], "kind": g["kind"], "title": g["title"], "original": g["original"], "year": g["year"], "pop": round(g["pop"], 2), "lang": g["lang"]} for g in gold["items"]]

NONTITLE = ["Official Trailer", "Sample Clip", "Behind The Scenes", "Teaser Video", "XXX Adults Only 18+", "Test Stream", "Intro Promo", "Making of Film"]
COLLECTIONS = ["007 | JAMES BOND COLLECTION", "MARVEL CINEMATIC UNIVERSE COLLECTION", "SOUTH INDIAN BLOCKBUSTER PACK", "ANIME MOVIES COLLECTION 4K", "DISNEY CLASSICS BOX SET", "NEW RELEASES THIS WEEK", "STAR WARS SAGA COLLECTION"]

def library(g, gold, spec, name):
    items_all = gold["items"]
    langs = spec["langs"]; n = spec["n"]
    pool = {}
    for it in items_all: pool.setdefault((it["lang"], it["kind"]), []).append(it)
    for k in pool: pool[k].sort(key=lambda x: -x["pop"])
    kinds = spec.get("kinds", {"movie": 0.7, "series": 0.3})
    prof = spec.get("noise", {})
    out, cats = [], {}
    weights = [langs[k] for k in langs]; lk = list(langs)
    base = min(n, spec.get("distinct", n))
    chosen = []
    for _ in range(base):
        lang = g.r.choices(lk, weights)[0]
        kind = "movie" if g.r.random() < kinds.get("movie", 0.7) else "series"
        lst = pool.get((lang, kind)) or pool.get((lang, "movie")) or []
        if not lst: continue
        # popular titles are likelier to be in a provider's library
        chosen.append(lst[min(int(g.r.random() ** 1.6 * len(lst)), len(lst) - 1)])
    seen = set()
    uniq = []
    for c in chosen:
        if (c["tmdb"], c["kind"]) in seen and not spec.get("dups"): continue
        seen.add((c["tmdb"], c["kind"])); uniq.append(c)
    rows = []
    idx = 0
    while len(rows) < n:
        it = uniq[idx % len(uniq)] if uniq else None
        idx += 1
        if it is None: break
        copies = 1 + (g.r.randint(1, spec["dups"]) if spec.get("dups") and g.p(0.6) else 0)
        for _ in range(copies):
            lang = it["lang"]; ct = COUNTRY.get(lang, ["US"])
            catname = g.pick([f"{LANGNAME[lang]} {'Movies' if it['kind']=='movie' else 'Series'}", f"{LANGNAME[lang].upper()} | {it['kind'].upper()}S", f"{it['year'] or 2020} {LANGNAME[lang]}", (it["genres"][0] if it["genres"] else "General") + (" Movies" if it["kind"] == "movie" else " Shows"), g.pick(["NETFLIX", "PRIME VIDEO", "HOTSTAR", "ZEE5", "MAX", "ANIME"]) + " " + it["kind"].upper()])
            raw, py, tags = g.name(it, lang, prof, ct)
            if spec.get("anime") and it["lang"] == "ja" and it["kind"] == "series" and g.p(0.5): raw += f" - {g.randint(1,180) if False else g.r.randint(1,180):03d}"; tags.append("absolute-ep")
            if it["kind"] == "series" and g.p(prof.get("episode", 0.25)):
                s, e = g.r.randint(1, 5), g.r.randint(1, 20)
                raw += g.pick([f" S{s:02d}E{e:02d}", f" {s}x{e:02d}", f" Season {s} Episode {e}", f".S{s:02d}E{e:02d}.1080p"]); tags.append("episode")
            if spec.get("noArtworkMeta"): rating, genre, poster = "", "", False
            else:
                rating = "" if g.p(0.15) else f"{max(0, min(10, it['vote'] + g.r.uniform(-1, 1))):.1f}"
                genre = ", ".join(it["genres"][:2]) if not g.p(0.1) else ""
                poster = g.p(0.85)
            rows.append({"id": f"{'m' if it['kind']=='movie' else 's'}{len(rows)}", "kind": it["kind"], "raw": raw, "year": py, "gold": it["tmdb"], "lang": lang, "category": catname,
                         "noise": tags, "genre": genre, "rating": rating, "poster": poster, "restricted": False, "addedDays": g.r.randint(0, 700),
                         "quality": g.r.randint(0, 5)})
            cats[catname] = cats.get(catname, 0) + 1
            if len(rows) >= n: break
    # non-title entries and collections
    extra = max(2, n // 40)
    for i in range(extra):
        if g.p(0.5): raw, tg = g.pick(COLLECTIONS), ["collection"]
        else:
            it = g.pick(uniq); raw, tg = f"{it['title']} {g.pick(NONTITLE)}", ["non-title"]
        adult = "Adults" in raw
        rows.append({"id": f"x{len(rows)}", "kind": "movie", "raw": raw, "year": None, "gold": None, "lang": None, "category": g.pick(list(cats) or ["Misc"]), "noise": tg, "genre": "", "rating": "", "poster": False,
                     "restricted": adult, "addedDays": 5, "quality": 2})
    # Names as real providers write them beyond the main patterns (separate random stream, so the rows above never change): an episode title after the marker, a year followed by a language
    # word or extra words, a bare language word at either end, fixtures of two sides and event recordings (no title: gold none), and one-letter slips on one-word titles.
    g2 = random.Random(f"extra-{name}")
    for _ in range(max(3, n // 12)):
        if not uniq: break
        it = g2.choice(uniq); lang = it["lang"]; ln = LANGNAME.get(lang, "English"); t = it["title"]; kind_pick = g2.random()
        if it["kind"] == "series" and kind_pick < 0.3:
            raw, tg = f"{t} Season {g2.randint(1, 5)} Episode {g2.randint(1, 20)} {g2.choice(['Pilot', 'The Return', 'Homecoming', 'Part One'])}", ["season-episode-title"]
        elif kind_pick < 0.5: raw, tg = f"{t} {it['year'] or 2020} {g2.choice([ln, 'Full Movie', 'HD Print', 'New'])}", ["year-extra"]
        elif kind_pick < 0.75: raw, tg = (f"{t} {ln}" if g2.random() < 0.5 else f"{ln} {t}"), ["bare-language"]
        elif len(t.split()) == 1 and len(t) >= 5:
            i = g2.randint(1, len(t) - 2); raw, tg = t[:i] + t[i + 1:], ["slip"]
        else: continue
        rows.append({"id": f"{'m' if it['kind']=='movie' else 's'}{len(rows)}", "kind": it["kind"], "raw": raw, "year": None, "gold": it["tmdb"], "lang": lang, "category": f"{ln} {'Movies' if it['kind']=='movie' else 'Series'}",
                     "noise": tg, "genre": "", "rating": "", "poster": False, "restricted": False, "addedDays": 3, "quality": 2})
    for _ in range(max(2, n // 60)):
        a_, b_ = g2.sample(["Rovers", "United", "City", "Lions", "Tigers", "Eagles", "Wanderers", "Giants"], 2)
        raw = g2.choice([f"{a_} vs {b_}", f"{a_} vs. {b_} Highlights", f"League Final Press Conference", f"Boxing Night PPV {g2.randint(1, 99)}"])
        rows.append({"id": f"x{len(rows)}", "kind": "movie", "raw": raw, "year": None, "gold": None, "lang": None, "category": "Sports Replays", "noise": ["fixture"], "genre": "", "rating": "", "poster": False,
                     "restricted": False, "addedDays": 2, "quality": 2})
    if spec.get("kids"):
        for r in rows:
            r["kidsSafe"] = True
    # filler titles unknown to TMDB, for large libraries
    if spec.get("filler"):
        words = [w for it in items_all for w in re.findall(r"[A-Za-z]{4,}", it["title"])]
        for i in range(spec["filler"]):
            raw = " ".join(g.r.choice(words) for _ in range(g.r.randint(2, 4))).title()
            rows.append({"id": f"f{i}", "kind": "movie" if g.p(0.75) else "series", "raw": raw + (f" ({g.r.randint(1990,2025)})" if g.p(0.5) else ""), "year": None, "gold": None, "lang": None, "category": "Misc",
                         "noise": ["filler"], "genre": g.pick(["Action", "Drama", "Comedy", ""]), "rating": "", "poster": g.p(0.6), "restricted": False, "addedDays": g.r.randint(0, 700), "quality": g.r.randint(0, 5)})
    return rows, cats

PERSONAS = {
  "english-small":   dict(n=250, langs={"en": 1.0}, noise={"origTitle": 0.0}),
  "telugu-hindi":    dict(n=3000, langs={"te": 0.4, "hi": 0.35, "en": 0.15, "ta": 0.1}, noise={"translit": 0.55, "langTag": 0.6, "country": 0.35}),
  "south-indian":    dict(n=2500, langs={"ta": 0.35, "ml": 0.3, "kn": 0.2, "te": 0.1, "hi": 0.05}, noise={"translit": 0.6, "langTag": 0.6}),
  "anime-fan":       dict(n=2500, langs={"ja": 0.8, "en": 0.1, "ko": 0.1}, kinds={"movie": 0.2, "series": 0.8}, anime=True, noise={"translit": 0.4, "episode": 0.4}),
  "asian-drama":     dict(n=2000, langs={"ko": 0.5, "ja": 0.2, "zh": 0.2, "th": 0.1}, kinds={"movie": 0.25, "series": 0.75}, noise={"translit": 0.4, "episode": 0.35}),
  "turkish-arabic":  dict(n=1500, langs={"tr": 0.5, "ar": 0.4, "ur": 0.1}, kinds={"movie": 0.4, "series": 0.6}, noise={"translit": 0.5, "origTitle": 0.5}),
  "latin-america":   dict(n=2000, langs={"es": 0.6, "pt": 0.4}, noise={"origTitle": 0.7, "langTag": 0.3}),
  "european":        dict(n=2500, langs={"fr": 0.3, "de": 0.3, "it": 0.25, "en": 0.15}, noise={"origTitle": 0.7}),
  "kids-household":  dict(n=1200, langs={"en": 0.7, "hi": 0.2, "es": 0.1}, kids=True, noise={}),
  "series-only":     dict(n=1800, langs={"en": 0.4, "ko": 0.2, "tr": 0.2, "hi": 0.2}, kinds={"movie": 0.0, "series": 1.0}, noise={"episode": 0.4}),
  "movies-only":     dict(n=2500, langs={"en": 0.4, "hi": 0.2, "te": 0.1, "fr": 0.1, "ko": 0.1, "es": 0.1}, kinds={"movie": 1.0, "series": 0.0}, noise={}),
  "new-user":        dict(n=400, langs={"en": 0.6, "hi": 0.4}, noise={}),
  "bare-library":    dict(n=2000, langs={"en": 0.5, "hi": 0.2, "es": 0.15, "ko": 0.15}, noArtworkMeta=True, noise={"quality": 0.7, "yearInName": 0.2}),
  "heavy-duplicates":dict(n=3000, langs={"en": 0.5, "hi": 0.2, "te": 0.1, "fr": 0.1, "es": 0.1}, dups=4, distinct=900, noise={"quality": 0.9}),
  "huge-200k":       dict(n=14000, langs={"en": 0.35, "hi": 0.1, "te": 0.05, "ta": 0.05, "ko": 0.08, "ja": 0.07, "es": 0.1, "fr": 0.08, "de": 0.06, "tr": 0.06}, dups=5, distinct=4000, filler=186000, noise={}),
  "large-66k":       dict(n=6000, langs={"en": 0.4, "hi": 0.15, "te": 0.1, "ko": 0.1, "es": 0.15, "fr": 0.1}, dups=3, distinct=2500, filler=60000, noise={}),
}

# (xmltv id, display names, country, language) - public channel names, written by hand for the evaluation
CH = """ESPN.us|ESPN|us|eng;ESPN2.us|ESPN 2|us|eng;CNN.us|CNN|us|eng;FoxNews.us|Fox News Channel|us|eng;HBO.us|HBO|us|eng;AMC.us|AMC|us|eng;DiscoveryChannel.us|Discovery Channel|us|eng;NationalGeographic.us|National Geographic|us|eng;CartoonNetwork.us|Cartoon Network|us|eng;Nickelodeon.us|Nickelodeon|us|eng;ComedyCentral.us|Comedy Central|us|eng;MTV.us|MTV|us|eng;BBCOne.uk|BBC One|uk|eng;BBCTwo.uk|BBC Two|uk|eng;BBCNews.uk|BBC News|uk|eng;ITV1.uk|ITV1|uk|eng;Channel4.uk|Channel 4|uk|eng;Channel5.uk|Channel 5|uk|eng;SkySportsMainEvent.uk|Sky Sports Main Event|uk|eng;SkySportsFootball.uk|Sky Sports Football|uk|eng;SkyNews.uk|Sky News|uk|eng;BTSport1.uk|BT Sport 1|uk|eng;StarSports1.in|Star Sports 1|in|eng;StarSports1Telugu.in|Star Sports 1 Telugu|in|tel;StarSports1Hindi.in|Star Sports 1 Hindi|in|hin;StarSports2.in|Star Sports 2|in|eng;StarPlus.in|Star Plus|in|hin;ZeeTV.in|Zee TV|in|hin;ZeeTelugu.in|Zee Telugu|in|tel;ZeeTamil.in|Zee Tamil|in|tam;ColorsTV.in|Colors|in|hin;SonyEntertainmentTelevision.in|Sony Entertainment Television|in|hin;SonySAB.in|Sony SAB|in|hin;StarMaa.in|Star Maa|in|tel;ETVTelugu.in|ETV Telugu|in|tel;GeminiTV.in|Gemini TV|in|tel;SunTV.in|Sun TV|in|tam;StarVijay.in|Star Vijay|in|tam;AsianetMalayalam.in|Asianet|in|mal;SuryaTV.in|Surya TV|in|mal;UdayaTV.in|Udaya TV|in|kan;ColorsKannada.in|Colors Kannada|in|kan;AajTak.in|Aaj Tak|in|hin;NDTV24x7.in|NDTV 24x7|in|eng;TF1.fr|TF1|fr|fra;France2.fr|France 2;France3.fr|France 3|fr|fra;Canal+.fr|Canal+|fr|fra;M6.fr|M6|fr|fra;ARD.de|Das Erste|de|deu;ZDF.de|ZDF|de|deu;RTL.de|RTL|de|deu;ProSieben.de|ProSieben|de|deu;Sat1.de|SAT.1|de|deu;RAI1.it|Rai 1|it|ita;RAI2.it|Rai 2|it|ita;Canale5.it|Canale 5|it|ita;La1.es|La 1|es|spa;Antena3.es|Antena 3|es|spa;Telecinco.es|Telecinco|es|spa;Televisa.mx|Las Estrellas|mx|spa;GloboBR.br|TV Globo|br|por;SBT.br|SBT|br|por;RecordTV.br|Record TV|br|por;TRT1.tr|TRT 1|tr|tur;ShowTV.tr|Show TV|tr|tur;ATV.tr|ATV|tr|tur;StarTV.tr|Star TV|tr|tur;AlJazeera.qa|Al Jazeera|qa|ara;MBC1.sa|MBC 1|sa|ara;MBC4.ae|MBC 4|ae|ara;KBS1.kr|KBS 1|kr|kor;MBC.kr|MBC|kr|kor;SBS.kr|SBS|kr|kor;tvN.kr|tvN|kr|kor;NHK.jp|NHK General|jp|jpn;FujiTV.jp|Fuji TV|jp|jpn;TVAsahi.jp|TV Asahi|jp|jpn;Channel1.ru|Channel One|ru|rus;RossiyaTV.ru|Russia 1|ru|rus;NTV.ru|NTV|ru|rus;HBOAsia.sg|HBO Asia|sg|eng;AXN.sg|AXN|sg|eng;ARYDigital.pk|ARY Digital|pk|urd;HumTV.pk|Hum TV|pk|urd;GeoNews.pk|Geo News|pk|urd;Dangal.in|Dangal|in|hin;DDNational.in|DD National|in|hin;DisneyChannel.us|Disney Channel|us|eng;DisneyJunior.us|Disney Junior|us|eng;BoomerangUS.us|Boomerang|us|eng;SuperRTL.de|Super RTL|de|deu;TeleToonPlus.fr|Teletoon+|fr|fra;ESPNUS.us|ESPN U|us|eng;FS1.us|Fox Sports 1|us|eng;TNT.us|TNT|us|eng;BeINSports1.qa|beIN Sports 1|qa|ara;BeINSports2.qa|beIN Sports 2|qa|ara;DAZN1.de|DAZN 1|de|deu;SkySportsF1.uk|Sky Sports F1|uk|eng;Eurosport1.fr|Eurosport 1|fr|fra;TNTSportsEn.uk|TNT Sports 1|uk|eng""".replace("France2.fr|France 2;", "France2.fr|France 2|fr|fra;").split(";")
CH = [c.split("|") for c in CH]

def channels(g, spec, name):
    rows = []
    sports = spec.get("sports")
    pool = [c for c in CH if (not sports or any(w in c[1].lower() for w in ("sport", "espn", "dazn", "fox sports", "eurosport", "tnt", "bein")))] if sports else CH
    for c in pool:
        for _ in range(spec.get("channelCopies", 1)):
            nm = c[1]
            tags = []
            if g.p(0.5): nm += g.pick([" HD", " FHD", " 4K", " SD", " HEVC", " 1080p", " UHD"]); tags.append("quality")
            if g.p(0.25): nm += " (backup)"; tags.append("backup")
            if g.p(0.2): nm = f"{c[2].upper()}: {nm}"; tags.append("country")
            if g.p(0.15): nm = f"{c[2].upper()}| {nm}"; tags.append("country")
            if g.p(0.15): nm = nm.upper(); tags.append("caps")
            if g.p(0.1): nm = nm + g.pick([" London", " Live", " East", " West"]); tags.append("suffix")
            if g.p(0.08): nm = nm.replace(" ", "."); tags.append("dots")
            r = g.r.random()
            tvg = c[0] if r < 0.5 else (None if r < 0.8 else g.pick(CH)[0])
            if tvg and tvg != c[0]: tags.append("wrong-tvg")
            elif tvg is None: tags.append("no-tvg")
            else: tags.append("tvg")
            rows.append({"name": nm, "tvg": tvg, "country": c[2] if g.p(0.6) else None, "gold": c[0], "noise": tags, "category": "Live " + c[2].upper()})
    # channels that are not in the guide at all (local/regional) must stay unmapped
    for i in range(max(3, len(rows) // 12)):
        rows.append({"name": g.pick(["Local News", "Radio Mirchi", "Shopping Deals", "Sunrise Weather", "City Info", "Bhakti Sagar", "Movies Now"]) + f" {i}", "tvg": None, "country": None, "gold": None, "noise": ["unknown"], "category": "Live Misc"})
    return rows

def main():
    gold = json.load(open(sys.argv[1])); out = sys.argv[2]; seed = int(sys.argv[3]) if len(sys.argv) > 3 else 7
    os.makedirs(out, exist_ok=True)
    gold["items"].sort(key=lambda x: (x["kind"], x["tmdb"]))
    json.dump({"items": build_index(gold)}, open(os.path.join(out, "tmdb-index.json"), "w"), ensure_ascii=False, separators=(",", ":"))
    json.dump({"guide": [{"id": c[0], "name": c[1], "country": c[2] if len(c) > 2 else None, "language": c[3] if len(c) > 3 else None} for c in CH]}, open(os.path.join(out, "guide.json"), "w"))
    summary = {}
    specs = dict(PERSONAS)
    specs["sports-live-only"] = dict(n=0, langs={"en": 1}, sports=True, channelCopies=3)
    specs["kids-household"]["channelCopies"] = 1
    for name, spec in specs.items():
        g = Gen(f"{seed}-{name}")
        if spec["n"] > 0: rows, cats = library(g, gold, spec, name)
        else: rows, cats = [], {}
        doc = {"persona": name, "kids": bool(spec.get("kids")), "items": rows, "folders": sorted(cats), "channels": channels(g, spec, name) if spec.get("sports") or name in ("telugu-hindi", "english-small", "european", "kids-household", "turkish-arabic", "latin-america", "south-indian", "asian-drama") else []}
        json.dump(doc, open(os.path.join(out, name + ".json"), "w"), ensure_ascii=False, separators=(",", ":"))
        summary[name] = (len(rows), len(doc["channels"]))
    json.dump(summary, open(os.path.join(out, "summary.json"), "w"))
    print(summary)

main()
