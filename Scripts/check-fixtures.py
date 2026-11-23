#!/usr/bin/env python3
"""Fixture contract (smartmix/, artwork/, epg/ fixture folders). The logic lives in Scripts/checks/fixture_contract.py (also run by
Scripts/checks/run_all.py). Options: -v lists the fixtures without a Windows (C#) consumer (on hold). Env: REPO_ROOT, FIXTURE_ROOT."""
import runpy, sys
from pathlib import Path
sys.argv[0] = str(Path(__file__).resolve().parent / "checks" / "fixture_contract.py")
runpy.run_path(sys.argv[0], run_name="__main__")
