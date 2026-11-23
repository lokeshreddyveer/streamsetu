"""Shared plumbing for the contract checks (standard library only, no secrets printed).

* Ctx: the file list comes from ONE `git ls-files` call (tracked + untracked-not-ignored), never a filesystem walk
  (a temporary copy without .git falls back to a walk of that small copy).
* Environment overrides: REPO_ROOT (whole tree), FIXTURE_ROOT (a folder holding smartmix/ artwork/ epg/ fixtures),
  CHECKS_OVERLAY (files here shadow the same relative path in the tree; used by selftest.py).
* Content hashes are cached by (mtime, size) in the stamp file, so a warm run only stats files.
Every check module defines NAME, INPUTS (regexes over repo-relative paths) and run(ctx) -> Result; main(module) runs it alone."""
import hashlib, json, os, re, subprocess, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_ROOT = HERE.parent.parent
FIXTURE_PREFIX = re.compile(r"^[^/]+/fixtures/")
sys.dont_write_bytecode = True


class Result:
    def __init__(self):
        self.errors, self.warnings, self.note = [], [], ""
    def err(self, m): self.errors.append(m)
    def warn(self, m): self.warnings.append(m)
    def to_json(self): return {"errors": self.errors, "warnings": self.warnings, "note": self.note}
    @staticmethod
    def from_json(d):
        r = Result(); r.errors, r.warnings, r.note = d["errors"], d["warnings"], d["note"]; return r


class Ctx:
    def __init__(self, root=None, fixture_root=None, overlay=None, stat_cache=None):
        self.root = Path(root or os.environ.get("REPO_ROOT") or DEFAULT_ROOT).resolve()
        fr = fixture_root or os.environ.get("FIXTURE_ROOT")
        self.fixture_root = Path(fr).resolve() if fr else None
        ov = overlay or os.environ.get("CHECKS_OVERLAY")
        self.overlay = Path(ov).resolve() if ov else None
        self.stat_cache = stat_cache if stat_cache is not None else {}
        self._text, self._hash = {}, {}
        self.files = self._list()
        self.fileset = set(self.files)

    def _list(self):
        paths = None
        if (self.root / ".git").exists():
            try:
                out = subprocess.run(["git", "-C", str(self.root), "ls-files", "-co", "--exclude-standard", "-z"],
                                     capture_output=True, check=True).stdout.decode("utf-8", "replace")
                paths = [p for p in out.split("\0") if p]
            except (OSError, subprocess.CalledProcessError):
                paths = None
        if paths is None:  # temporary copy: small, so a walk is fine
            paths = self._walk(self.root)
        if self.fixture_root:
            paths = [p for p in paths if not FIXTURE_PREFIX.match(p)] + self._walk(self.fixture_root, only_fixtures=True)
        if self.overlay:
            paths += [p for p in self._walk(self.overlay) if p not in set(paths)]
        return sorted({p for p in paths if self.abs(p).is_file()})

    @staticmethod
    def _walk(base, only_fixtures=False):
        out = []
        for d, dirs, fs in os.walk(base):
            dirs[:] = [x for x in dirs if x not in (".git", "node_modules", "build", ".build")]
            for f in fs:
                rel = os.path.relpath(os.path.join(d, f), base)
                if not only_fixtures or FIXTURE_PREFIX.match(rel): out.append(rel)
        return out

    def abs(self, rel):
        if self.overlay and (self.overlay / rel).is_file(): return self.overlay / rel
        if self.fixture_root and FIXTURE_PREFIX.match(rel): return self.fixture_root / rel
        return self.root / rel

    def select(self, patterns):
        rx = [re.compile(p) for p in patterns]
        return [f for f in self.files if any(r.search(f) for r in rx)]

    def read(self, rel):
        t = self._text.get(rel)
        if t is None:
            try: t = self.abs(rel).read_text(encoding="utf-8", errors="replace")
            except OSError: t = ""
            self._text[rel] = t
        return t

    def exists(self, rel): return rel in self.fileset

    def digest(self, rel):
        h = self._hash.get(rel)
        if h is None:
            p = self.abs(rel)
            try: st = p.stat()
            except OSError: return "missing"
            key = str(p); ent = self.stat_cache.get(key)
            if ent and ent[0] == st.st_mtime_ns and ent[1] == st.st_size: h = ent[2]
            else:
                h = hashlib.sha1(p.read_bytes()).hexdigest()
                self.stat_cache[key] = [st.st_mtime_ns, st.st_size, h]
            self._hash[rel] = h
        return h

    def input_key(self, mod):
        h = hashlib.sha1(Path(mod.__file__).read_bytes())
        h.update(Path(__file__).read_bytes())
        for f in self.select(mod.INPUTS): h.update(f.encode()); h.update(self.digest(f).encode())
        return h.hexdigest()


def report(name, res, secs):
    for e in res.errors: print("  FAIL  %s" % e)
    for w in res.warnings: print("  warn  %s" % w)
    print("%s %s (%.2fs)%s" % ("PASS" if not res.errors else "FAIL", name, secs, ("  " + res.note) if res.note else ""))


def main(mod):
    """Run one check alone (exit 0 = holds, 1 = violations)."""
    t = time.time(); ctx = Ctx(); res = mod.run(ctx)
    report(mod.NAME, res, time.time() - t)
    sys.exit(1 if res.errors else 0)
