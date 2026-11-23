#!/usr/bin/env python3
"""Run every contract check in ONE process: one `git ls-files`, a small thread pool, results cached by file content hash.

  Scripts/checks/run_all.py [--no-cache] [--only name,name] [--selftest] [-v]

A check is skipped (cached result shown, marked 'cached') when none of its input files changed since the last run: content hashes come from
a stamp file (Scripts/checks/.stamp.json, git-ignored) that remembers each file's (mtime, size, sha1), so a warm run only stats files.
Exit 0 = every check passes (warnings allowed), 1 = a check failed. Standard library only; prints no secrets."""
import importlib, json, os, sys, time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parent))
import common

STAMP = Path(os.environ.get("CHECKS_STAMP") or HERE / ".stamp.json")


def load_checks():
    import importlib.util
    mods = [importlib.import_module(n) for n in ("fixture_contract", "smartmix_reference")]
    spec = importlib.util.spec_from_file_location("check_host_parity", HERE.parent / "check-host-parity.py")  # the network contract lives in the older script
    net = importlib.util.module_from_spec(spec); spec.loader.exec_module(net)
    return mods + [net] + [importlib.import_module(n) for n in ("provider_and_logging", "doc_drift")]


def main(argv):
    t0 = time.time()
    use_cache = "--no-cache" not in argv
    only = set(argv[argv.index("--only") + 1].split(",")) if "--only" in argv else None
    try: stamp = json.loads(STAMP.read_text()) if use_cache else {}
    except (OSError, ValueError): stamp = {}
    stamp.setdefault("files", {}); stamp.setdefault("checks", {})
    ctx = common.Ctx(stat_cache=stamp["files"])
    mods = [m for m in load_checks() if not only or m.NAME in only]
    t_list = time.time() - t0

    def one(mod):
        t = time.time()
        key = ctx.input_key(mod)
        old = stamp["checks"].get(mod.NAME)
        if use_cache and old and old["key"] == key:
            return mod, common.Result.from_json(old["result"]), time.time() - t, True, key
        try:
            res = mod.run(ctx)
        except Exception as e:  # a crashing check is a failing check
            res = common.Result(); res.err("check crashed: %s: %s" % (type(e).__name__, e))
        return mod, res, time.time() - t, False, key

    with ThreadPoolExecutor(max_workers=4) as pool:
        out = list(pool.map(one, mods))
    for mod, res, secs, cached, key in out:
        stamp["checks"][mod.NAME] = {"key": key, "result": res.to_json()}
    # drop stat entries of files that no longer exist (keeps the stamp small)
    live = {str(ctx.abs(f)) for f in ctx.files}
    stamp["files"] = {k: v for k, v in stamp["files"].items() if k in live}
    try:
        tmp = STAMP.with_suffix(".tmp"); tmp.write_text(json.dumps(stamp)); os.replace(tmp, STAMP)
    except OSError: pass
    w = max(len(m.NAME) for m in mods)
    print("%-*s  %-4s  %6s  %s" % (w, "check", "", "time", "detail"))
    failed = 0
    for mod, res, secs, cached, key in out:
        status = "FAIL" if res.errors else "PASS"
        failed += bool(res.errors)
        print("%-*s  %-4s  %5.2fs  %s%s" % (w, mod.NAME, status, secs, "(cached) " if cached else "", (res.note + ("; %d warning(s)" % len(res.warnings) if res.warnings else "")).strip("; ")))
    shown = 0
    for mod, res, secs, cached, key in out:
        for e in res.errors:
            if shown < 12 or "-v" in argv: print("  FAIL [%s] %s" % (mod.NAME, e))
            shown += 1
    if shown > 12 and "-v" not in argv: print("  ... %d more failures (use -v)" % (shown - 12))
    if "-v" in argv:
        for mod, res, secs, cached, key in out:
            for x in res.warnings: print("  warn [%s] %s" % (mod.NAME, x))
    print("%s: %d/%d passed in %.2fs (file list %.2fs, %d files)" % ("FAIL" if failed else "PASS", len(out) - failed, len(out), time.time() - t0, t_list, len(ctx.files)))
    return 1 if failed else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        import selftest; sys.exit(selftest.main())
    sys.exit(main(sys.argv[1:]))
