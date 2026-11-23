#!/bin/bash
# Fails if a built-in key (TMDB, fanart.tv, TheTVDB) or a piece of it appears in files git can see, or in built apps/binaries given as arguments. Prints no secret. Safe in CI (no key needed).
# usage: Scripts/check-no-secrets.sh [app-or-binary ...]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
exec python3 -I "$HERE/check_no_secrets.py" --repo "$HERE/.." "$@"
