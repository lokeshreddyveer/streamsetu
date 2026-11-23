#!/usr/bin/env python3
"""Fails when a built-in service key (TMDB read token, fanart.tv key, TheTVDB key) or a piece of it is visible: in a tracked or untracked-but-not-ignored file,
or in the readable strings of built binaries. Never prints a key or any part of it: only file names, the service name and the word 'present'.
usage: check_no_secrets.py [--repo DIR] [binary-or-app ...]
Where the keys come from: $STREAMSETU_TMDB_TOKEN / $STREAMSETU_FANART_KEY / $STREAMSETU_TVDB_KEY, or the files tmdb-read-token.txt, fanart-api-key.txt and
thetvdb-api-key.txt in ~/Documents/keys (the folder can be moved with $STREAMSETU_KEYS_DIR). Without a TMDB token, only token-shaped strings (JWTs) are looked for.
"""
import os, re, subprocess, sys

args = sys.argv[1:]
repo = os.getcwd()
if args[:1] == ["--repo"]:
    repo, args = args[1], args[2:]

SERVICES = [("TMDB", "STREAMSETU_TMDB_TOKEN", "tmdb-read-token.txt"),
            ("fanart.tv", "STREAMSETU_FANART_KEY", "fanart-api-key.txt"),
            ("TheTVDB", "STREAMSETU_TVDB_KEY", "thetvdb-api-key.txt")]
keys_dir = os.environ.get("STREAMSETU_KEYS_DIR") or os.path.expanduser("~/Documents/keys")

def load(env, fname):
    v = os.environ.get(env, "").strip()
    if not v:
        p = os.path.join(keys_dir, fname)
        if os.path.isfile(p):
            v = open(p).read().strip()
    return v

def fragments(tok):
    out = set()
    if len(tok) < 24: return out
    out.add(tok)
    body = tok.split(".", 1)[1] if tok.startswith("eyJ") and "." in tok else tok      # the standard JWT header is common to every token and proves nothing
    for i in range(0, len(body) - 11, 6):
        out.add(body[i:i + 12])
    out.add(body[-12:])
    return out

found = {}        # service -> [fragment bytes]
for name, env, fname in SERVICES:
    t = load(env, fname)
    if len(t) >= 24: found[name] = [f.encode() for f in fragments(t)]
jwt = re.compile(rb"eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}")
bad = []

def scan(name, data):
    for svc, frs in found.items():
        if any(f in data for f in frs): bad.append(f"{name}: the {svc} key or a piece of it is present")
    if jwt.search(data) and "test" not in name.lower(): bad.append(f"{name}: a token-shaped string is present")

files = subprocess.run(["git", "-C", repo, "ls-files", "-co", "--exclude-standard", "-z"], capture_output=True).stdout.split(b"\0")
for f in files:
    if not f: continue
    path = os.path.join(repo, f.decode(errors="replace"))
    try:
        if os.path.isfile(path) and os.path.getsize(path) < 8_000_000: scan(f.decode(errors="replace"), open(path, "rb").read())
    except OSError: pass
for target in args:
    bins = []
    if os.path.isdir(target):
        for dp, _, fn in os.walk(target):
            for x in fn: bins.append(os.path.join(dp, x))
    elif os.path.isfile(target): bins.append(target)
    for b in bins:
        try: data = open(b, "rb").read()
        except OSError: continue
        scan(os.path.relpath(b, os.path.dirname(target.rstrip("/")) or "."), data)
        # readable strings, as `strings` shows them (the scrambled bytes must not decode to the token)
        for m in re.finditer(rb"[\x20-\x7e]{8,}", data):
            if any(f in m.group(0) for frs in found.values() for f in frs): bad.append(f"{os.path.basename(b)}: readable string holds a piece of a key"); break
print(f"checking against {len(found)} of {len(SERVICES)} keys" + ("" if found else " (none in this environment: token-shaped strings only)"))
if bad:
    for b in sorted(set(bad)): print("  FAIL", b)
    sys.exit(1)
print("  ok: no key or token-shaped string in files or binaries checked")
