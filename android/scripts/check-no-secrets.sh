#!/bin/bash
# Fails when a built-in key (TMDB read token, fanart.tv key, TheTVDB key) or a piece of it appears in a file git can see (tracked or not ignored) or in a built APK's dex and resources.
# Prints PASS or FAIL and file names only, never the token. Safe in CI: with no token available it still looks for anything shaped like a JWT.
# The keys come from STREAMSETU_TMDB_TOKEN / STREAMSETU_FANART_KEY / STREAMSETU_TVDB_KEY, TMDB_TOKEN_FILE, or the private keys folder (STREAMSETU_KEYS_DIR); usage: scripts/check-no-secrets.sh [path/to/app.apk ...]
cd "$(dirname "$0")/.." || exit 2
fail=0
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
frags="$work/frags"; : > "$frags"
keys_dir="${STREAMSETU_KEYS_DIR:-$HOME/Documents/keys}"
add_key() {  # $1 = value; adds the key, 16-character pieces of it, and a base64 form
  local tok="$1" n i
  [ ${#tok} -ge 24 ] || return 0
  n=${#tok}; i=0
  while [ $((i+16)) -le "$n" ]; do printf '%s\n' "${tok:$i:16}" >> "$frags"; i=$((i+16)); done
  printf '%s\n' "${tok: -16}" >> "$frags"; printf '%s\n' "$tok" >> "$frags"
  printf '%s' "$tok" | base64 | tr -d '\n' | fold -w 24 | head -8 >> "$frags"
}
# TMDB token, fanart.tv key, TheTVDB key: from the environment, else (TMDB: TMDB_TOKEN_FILE or) the private keys folder
tmdb="${STREAMSETU_TMDB_TOKEN:-}"; [ -z "$tmdb" ] && [ -n "${TMDB_TOKEN_FILE:-}" ] && [ -f "$TMDB_TOKEN_FILE" ] && tmdb="$(tr -d '[:space:]' < "$TMDB_TOKEN_FILE")"
[ -z "$tmdb" ] && [ -f "$keys_dir/tmdb-read-token.txt" ] && tmdb="$(tr -d '[:space:]' < "$keys_dir/tmdb-read-token.txt")"
fanart="${STREAMSETU_FANART_KEY:-}"; [ -z "$fanart" ] && [ -f "$keys_dir/fanart-api-key.txt" ] && fanart="$(tr -d '[:space:]' < "$keys_dir/fanart-api-key.txt")"
tvdb="${STREAMSETU_TVDB_KEY:-}"; [ -z "$tvdb" ] && [ -f "$keys_dir/thetvdb-api-key.txt" ] && tvdb="$(tr -d '[:space:]' < "$keys_dir/thetvdb-api-key.txt")"
add_key "$tmdb"; add_key "$fanart"; add_key "$tvdb"
jwt='eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}'
scan() {  # $1 = file
  [ -s "$frags" ] && grep -aqF -f "$frags" "$1" 2>/dev/null && { echo "FAIL: key material in $1"; return 1; }
  grep -aqE "$jwt" "$1" 2>/dev/null && { echo "FAIL: something shaped like a token in $1"; return 1; }
  return 0
}
while IFS= read -r f; do [ -f "$f" ] && ! scan "$f" && fail=1; done < <(git ls-files -co --exclude-standard 2>/dev/null; true)
for apk in "$@"; do
  [ -f "$apk" ] || { echo "FAIL: no such APK: $apk"; fail=1; continue; }
  d="$work/$(basename "$apk")"; mkdir -p "$d"; unzip -qo "$apk" -d "$d" 2>/dev/null
  while IFS= read -r f; do
    case "$f" in *.dex|*.arsc|*.xml|*.json|*.txt|*.properties|*.kotlin_module|*.pro) ;; *) continue;; esac
    s="$work/strings.txt"; { strings -n 8 "$f" 2>/dev/null; strings -n 8 -e l "$f" 2>/dev/null; } > "$s"
    scan "$s" || { echo "      (in ${f#$d/} of $(basename "$apk"))"; fail=1; }
  done < <(find "$d" -type f)
done
if [ $fail -eq 0 ]; then echo "PASS: no built-in key in repository files${1:+ or in the APK}"; else echo "FAIL: see above"; fi
exit $fail
