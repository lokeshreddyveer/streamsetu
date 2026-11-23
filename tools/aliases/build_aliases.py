#!/usr/bin/env python3
"""Builds the offline alias index (aliases.tsv.gz) from public Wikidata (CC0).

Pipeline (resumable; every answer is cached on disk, so a stopped run continues where it was):
  1. ids:    films (P4947 = TMDB movie id) and TV series (P4983 = TMDB TV series id), best-known first
             (by number of sitelinks), in bands of sitelink counts, until --movies / --tv items are collected.
  2. labels: labels and aliases of those items in the persona languages (batches of --batch ids).
  3. write:  `key <TAB> kind <TAB> tmdb_id <TAB> sitelinks` lines, sorted by key then by sitelinks (highest first),
             gzip-compressed (mtime 0, no file name, so the bytes are reproducible).

Usage:  python3 build_aliases.py --cache DIR --out aliases.tsv.gz [--movies 24000 --tv 9000] [--fetch]
Without --fetch only the cache is read (offline rebuild).  Requests: one at a time, >= --delay seconds apart,
Retry-After honoured, descriptive User-Agent, as the query service's policy asks.
"""
import argparse, gzip, hashlib, json, os, re, sys, time, unicodedata, urllib.parse, urllib.request, urllib.error

ENDPOINT = "https://query.wikidata.org/sparql"
UA = "StreamSetu-index-builder/1.0"
LANGS = "en hi te ta ml kn bn mr gu pa ur tr ar ko ja zh th es fr de it pt ru id nl pl fa he vi mul".split()
BANDS = [(200, 10**6), (100, 199), (60, 99), (40, 59), (30, 39), (22, 29), (17, 21), (13, 16), (10, 12), (8, 9), (7, 7), (6, 6), (5, 5)]
KIND = {"P4947": "m", "P4983": "t"}

def fetch(cache, query, delay, live):
    key = hashlib.sha1(query.encode()).hexdigest()
    path = os.path.join(cache, key + ".json")
    if os.path.exists(path):
        return json.load(open(path, encoding="utf-8"))
    if not live:
        return None
    while True:
        req = urllib.request.Request(ENDPOINT, data=urllib.parse.urlencode({"query": query}).encode(),
                                     headers={"User-Agent": UA, "Accept": "application/sparql-results+json"})
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                data = json.load(r)
            break
        except urllib.error.HTTPError as e:
            wait = int(e.headers.get("Retry-After", "60")) + 5 if e.code in (429, 503) else 60
            print(f"http {e.code}, waiting {wait}s", file=sys.stderr); time.sleep(wait)
        except Exception as e:
            print(f"error {e!r}, waiting 60s", file=sys.stderr); time.sleep(60)
    json.dump(data, open(path, "w", encoding="utf-8"), ensure_ascii=False)
    time.sleep(delay)
    return data

def collect_ids(cache, prop, want, delay, live):
    out = []  # (qid, tmdb, sitelinks)
    for lo, hi in BANDS:
        if len(out) >= want: break
        q = f"SELECT ?i ?t ?s WHERE {{ ?i wdt:{prop} ?t; wikibase:sitelinks ?s FILTER(?s>={lo} && ?s<={hi}) }}"
        d = fetch(cache, q, delay, live)
        if d is None: break
        rows = [(b["i"]["value"].rsplit("/", 1)[1], b["t"]["value"], int(b["s"]["value"])) for b in d["results"]["bindings"] if b["t"]["value"].isdigit()]
        rows.sort(key=lambda r: -r[2])
        out += rows
    return out[:want]

def labels(cache, qids, batch, delay, live):
    res = {}
    langs = ",".join(f'"{l}"' for l in LANGS)
    for i in range(0, len(qids), batch):
        chunk = qids[i:i + batch]
        vals = " ".join("wd:" + q for q in chunk)
        q = (f"SELECT ?i ?x WHERE {{ VALUES ?i {{ {vals} }} {{ ?i rdfs:label ?x }} UNION {{ ?i skos:altLabel ?x }} FILTER(lang(?x) IN ({langs})) }}")
        d = fetch(cache, q, delay, live)
        if d is None: continue
        for b in d["results"]["bindings"]:
            res.setdefault(b["i"]["value"].rsplit("/", 1)[1], set()).add(b["x"]["value"])
    return res

# Key normalisation, mirrored by the apps (see fixtures/key-cases.json): compatibility-compose, lower case, "&" and "+" as words,
# apostrophes dropped, accents removed from Latin letters only, everything that is not a letter or digit is a separator,
# a leading article (the/a/an) dropped.
def key_of(s):
    t = unicodedata.normalize("NFKC", s).lower().replace("&", " and ").replace("+", " plus ").replace("'", "").replace("’", "").replace("ı", "i")
    t = "".join(c for c in unicodedata.normalize("NFD", t) if not (unicodedata.category(c) == "Mn" and ord(c) < 0x370)) 
    t = unicodedata.normalize("NFC", t)
    toks, cur = [], []
    for c in t:
        if unicodedata.category(c)[0] in "LNM": cur.append(c)      # letters, digits and combining marks stay; everything else separates
        elif cur: toks.append("".join(cur)); cur = []
    if cur: toks.append("".join(cur))
    if len(toks) > 1 and toks[0] in ("the", "a", "an"): toks = toks[1:]
    return " ".join(toks)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache", required=True); ap.add_argument("--out", required=True)
    ap.add_argument("--movies", type=int, default=24000); ap.add_argument("--tv", type=int, default=9000)
    ap.add_argument("--batch", type=int, default=250); ap.add_argument("--delay", type=float, default=15)
    ap.add_argument("--fetch", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.cache, exist_ok=True)
    rows = []
    for prop, want in (("P4947", a.movies), ("P4983", a.tv)):
        ids = collect_ids(a.cache, prop, want, a.delay, a.fetch)
        lab = labels(a.cache, [q for q, _, _ in ids], a.batch, a.delay, a.fetch)
        for q, t, s in ids:
            for x in lab.get(q, ()):
                k = key_of(x)
                if len(k) >= 2: rows.append((k, KIND[prop], int(t), s))
        print(prop, len(ids), "items", sum(1 for q, _, _ in ids if q in lab), "with labels", file=sys.stderr)
    rows = sorted(set(rows), key=lambda r: (r[0], -r[3], r[1], r[2]))
    body = "".join(f"{k}\t{kd}\t{t}\t{s}\n" for k, kd, t, s in rows).encode("utf-8")
    with open(a.out, "wb") as f:
        with gzip.GzipFile(filename="", mode="wb", fileobj=f, mtime=0, compresslevel=9) as g: g.write(body)
    print(len(rows), "lines,", len(body), "bytes raw,", os.path.getsize(a.out), "bytes gz", file=sys.stderr)

if __name__ == "__main__": main()
