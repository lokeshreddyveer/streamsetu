#!/usr/bin/env python3
"""Kept for existing callers: writes the scrambled built-in TMDB token. usage: gen-builtin-tmdb.py OUT.swift  (see gen-builtin-key.py)"""
import os, subprocess, sys
sys.exit(subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "gen-builtin-key.py"), "tmdb", sys.argv[1]]).returncode)
