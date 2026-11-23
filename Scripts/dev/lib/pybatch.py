#!/usr/bin/env python3
"""Runs several Python gate scripts in ONE interpreter (one startup instead of one each).
usage: pybatch.py REPO "script.py args..." ["script2.py args..."]
Prints one line per script; the output of a failing one follows it. Exit 1 if any failed."""
import contextlib, io, os, runpy, shlex, sys, time

root, specs = sys.argv[1], sys.argv[2:]
os.chdir(root)
bad = 0
for spec in specs:
    argv = shlex.split(spec)
    out = io.StringIO()
    t0 = time.time()
    code = 0
    try:
        sys.argv = argv
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            runpy.run_path(argv[0], run_name="__main__")
    except SystemExit as e:
        code = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
    except Exception as e:  # a crashing gate is a failing gate
        code = 1; out.write("crashed: %s\n" % type(e).__name__)
    print("%s %-40s %.1fs" % ("ok  " if code == 0 else "FAIL", spec, time.time() - t0))
    if code:
        bad = 1
        print("".join("    " + l + "\n" for l in out.getvalue().splitlines()[:25]), end="")
sys.exit(bad)
