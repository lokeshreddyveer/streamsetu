#!/usr/bin/env python3
"""Fetches public TMDB lists (top rated + popular, movies + series, per original language) into a local JSON cache.
Read-only. The token is read from a key file (default ~/Documents/keys/tmdb-read-token.txt, or $TMDB_TOKEN_FILE) and never printed.
Usage: fetch_tmdb.py CACHE_DIR [pages_per_list]"""
import json, os, sys, time, urllib.request, urllib.parse

LANGS = "en hi te ta ml kn bn mr pa ur ko ja zh tr ar es pt fr de it ru id th".split()
KEYFILE = os.environ.get("TMDB_TOKEN_FILE", os.path.expanduser("~/Documents/keys/tmdb-read-token.txt"))

def get(token, path, params, cache):
    key = path.strip("/").replace("/", "_") + "_" + "_".join(f"{k}-{v}" for k, v in sorted(params.items())) + ".json"
    f = os.path.join(cache, key)
    if os.path.exists(f):
        return json.load(open(f))
    url = "https://api.themoviedb.org/3" + path + "?" + urllib.parse.urlencode(params)
    for attempt in range(4):
        try:
            req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token, "accept": "application/json"})
            data = json.load(urllib.request.urlopen(req, timeout=20))
            json.dump(data, open(f, "w"))
            time.sleep(0.08)           # well inside TMDB's rate limit
            return data
        except Exception as e:
            time.sleep(1.5 * (attempt + 1))
    return {"results": []}

def main():
    cache = sys.argv[1]; pages = int(sys.argv[2]) if len(sys.argv) > 2 else 3
    os.makedirs(cache, exist_ok=True)
    token = open(KEYFILE).read().strip()
    out = {"genres": {}, "items": []}
    for kind, ep in (("movie", "movie"), ("series", "tv")):
        g = get(token, f"/genre/{ep}/list", {"language": "en-US"}, cache)
        out["genres"][kind] = {str(x["id"]): x["name"] for x in g.get("genres", [])}
    seen = set()
    for lang in LANGS:
        for kind, ep in (("movie", "movie"), ("series", "tv")):
            for sort in ("vote_average.desc", "popularity.desc"):
                for page in range(1, pages + 1):
                    p = {"language": "en-US", "with_original_language": lang, "sort_by": sort, "page": page, "include_adult": "false"}
                    if sort.startswith("vote"): p["vote_count.gte"] = 150 if lang in ("en", "ja", "ko", "hi", "fr", "es") else 25
                    d = get(token, f"/discover/{ep}", p, cache)
                    for r in d.get("results", []):
                        k = (kind, r["id"])
                        if k in seen: continue
                        seen.add(k)
                        date = r.get("release_date") or r.get("first_air_date") or ""
                        out["items"].append({"tmdb": r["id"], "kind": kind, "lang": r.get("original_language"),
                            "title": r.get("title") or r.get("name") or "", "original": r.get("original_title") or r.get("original_name") or "",
                            "year": int(date[:4]) if date[:4].isdigit() else None, "pop": r.get("popularity", 0), "vote": r.get("vote_average", 0),
                            "genres": [out["genres"][kind].get(str(i), "") for i in r.get("genre_ids", [])], "poster": bool(r.get("poster_path"))})
    json.dump(out, open(os.path.join(cache, "gold.json"), "w"), ensure_ascii=False)
    print("gold titles:", len(out["items"]))

main()
