#!/usr/bin/env python3
"""Samples REAL chart records for randomly chosen countries and saves them as a test fixture.

The countries are drawn at random from the ones the app supports (read from the Swift source, never listed here), with a seed that is recorded in the file, so
a sample can be repeated exactly. Nothing is typed in by hand: every title, artist and id in the fixture came from the live chart service on the date in the file.

  python3 Scripts/music-sample-regions.py --seed 101 --regions 5
"""
import argparse, json, random, re, sys, time, urllib.request, datetime, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "Sources/REDDY/Services/Music/Providers/Discovery/MusicDiscoveryBuiltIns.swift"
OUT = ROOT / "Tests/REDDYTests/Fixtures/RandomRegions"
UA = {"User-Agent": "StreamSetu-fixture-sampler/1.0"}

def supported_regions():
    text = SRC.read_text()
    block = text[text.index("static let supported"):]
    block = block[:block.index("]\n")]
    return re.findall(r'\("([a-z]{2})",\s*"([^"]+)"\)', block)

def get(url, tries=4):
    """The chart service times out or answers 502 now and then: ask again a few times, with a pause, before giving up on one list."""
    last = None
    for n in range(tries):
        try:
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=25) as r:
                return json.load(r)
        except Exception as e:
            last = e
            time.sleep(1.5 * (n + 1))
    raise last

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--regions", type=int, default=5)
    a = ap.parse_args()
    rng = random.Random(a.seed)
    regions = supported_regions()
    picked = rng.sample(regions, min(a.regions, len(regions)))
    data = {"seed": a.seed, "fetchedAt": datetime.datetime.utcnow().isoformat() + "Z", "source": "rss.marketingtools.apple.com most-played", "regions": []}
    for code, name in picked:
        entry = {"code": code, "name": name, "songs": [], "albums": []}
        for kind in ("songs", "albums"):
            url = f"https://rss.marketingtools.apple.com/api/v2/{code}/music/most-played/25/{kind}.json"
            try:
                feed = get(url)
                entry[kind] = [{"id": r.get("id"), "name": r.get("name"), "artist": r.get("artistName"), "kind": r.get("kind"), "url": r.get("url")} for r in feed["feed"]["results"]]
            except Exception as e:
                entry[kind + "Error"] = str(e)
            time.sleep(0.6)
        data["regions"].append(entry)
    OUT.mkdir(parents=True, exist_ok=True)
    f = OUT / f"seed-{a.seed}.json"
    f.write_text(json.dumps(data, ensure_ascii=False, indent=1))
    print(f"seed {a.seed}: " + ", ".join(f"{r['code']}({len(r['songs'])}s/{len(r['albums'])}a)" for r in data["regions"]) + f" -> {f.relative_to(ROOT)}")

if __name__ == "__main__":
    main()
