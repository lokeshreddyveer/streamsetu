#!/usr/bin/env python3
"""Turns the metrics JSON of PersonaEvalTests (optionally a baseline too) into a one-page table per engine. Usage: report.py [baseline.json] current.json"""
import json, sys
cur = json.load(open(sys.argv[-1])); base = json.load(open(sys.argv[1])) if len(sys.argv) > 2 else {}
def v(d, p, e, k):
    x = d.get(p, {}).get(e, {}).get(k); return x
def cell(p, e, k, pct=False, ms=False):
    c, b = v(cur, p, e, k), v(base, p, e, k)
    if c is None: return "-"
    f = (lambda x: f"{x*100:.1f}%") if pct else (lambda x: f"{x:.1f}" if ms else f"{x:g}")
    return f(c) if b is None or abs(b - c) < 1e-9 else f"{f(b)} -> {f(c)}"
personas = [p for p in cur if p != "ALL"]
out = []
def table(title, engine, cols):
    out.append(f"\n## {title}\n"); out.append("| persona | " + " | ".join(c[0] for c in cols) + " |"); out.append("|---|" + "---|" * len(cols))
    for p in personas:
        if engine in cur[p]: out.append(f"| {p} | " + " | ".join(cell(p, engine, c[1], c[2], c[3]) for c in cols) + " |")
table("Metadata matching", "match", [("n", "n", False, False), ("precision", "precision", True, False), ("recall", "recall", True, False), ("wrong rate", "wrongRate", True, False)])
for grp, title in (("match.noise", "by noise type"), ("match.lang", "by language")):
    keys = sorted({k.rsplit(".", 1)[0] for k in cur.get("ALL", {}).get(grp, {})})
    out.append(f"\nMatching {title} (all personas): recall / wrong rate\n"); out.append("| key | n | recall | wrong |"); out.append("|---|---|---|---|")
    def rw(d, key):
        g = d.get("ALL", {}).get(grp, {}); c, w, m = g.get(key + ".correct"), g.get(key + ".wrong"), g.get(key + ".miss")
        if c is None: return None
        n = c + w + m; return n, c / max(1, n), w / max(1, n)
    for k in keys:
        a, b = rw(cur, k), rw(base, k)
        out.append(f"| {k} | {a[0]:g} | " + (f"{b[1]*100:.1f}% -> " if b and abs(b[1] - a[1]) > 1e-9 else "") + f"{a[1]*100:.1f}% | " + (f"{b[2]*100:.1f}% -> " if b and abs(b[2] - a[2]) > 1e-9 else "") + f"{a[2]*100:.1f}% |")
table("Smart Mix", "mix", [("empty shelves", "emptyShelfRate", True, False), ("shelf fill", "shelfFill", True, False), ("cross-row dups", "crossRowDupRate", True, False), ("twins in shelf", "twinsInShelf", False, False),
                            ("reload repeat", "reloadRepeat", True, False), ("deterministic", "deterministic", False, False), ("restricted leaks", "restrictedLeaks", False, False), ("distinct genres", "distinctGenres", False, False), ("pref-lang share", "prefLangShare", True, False)])
table("Search (in-memory index + typo corrector)", "search", [("exact r@1", "exact.r1", True, False), ("typo r@1", "typo.r1", True, False), ("typo r@5", "typo.r5", True, False), ("prefix r@5", "prefix.r5", True, False),
                            ("translit r@5", "translit.r5", True, False), ("p95 ms", "p95ms", False, True), ("short max ms", "shortMaxMs", False, True), ("correct ms", "correctMs", False, True)])
table("Guide mapping", "guide", [("channels", "n", False, False), ("precision", "precision", True, False), ("recall", "recall", True, False), ("wrong rate", "wrongRate", True, False)])
sys.stdout.write("\n".join(out) + "\n")
