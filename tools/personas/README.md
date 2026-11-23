# Persona corpus and engine evaluation

Synthetic libraries that imitate how IPTV / Xtream / M3U providers name things worldwide, each with a gold standard of truth, used to measure the matching, search, Smart Mix and guide-mapping engines for any user (not one person's library).

Privacy: only public data. Gold titles come from the details service lists (top rated and popular, movies and series, per original language: en hi te ta ml kn bn mr pa ur ko ja zh tr ar es pt fr de it ru id th). No user library, database or app data is ever read. The generated corpus is large and is not committed; regenerate it.

## Run
```
python3 -I tools/personas/fetch_tmdb.py  $WORK/tmdb-cache 3          # needs a TMDB read token file (default ~/Documents/keys/tmdb-read-token.txt, or $TMDB_TOKEN_FILE); cached, rate-limited, never prints it
python3 -I tools/personas/generate.py    $WORK/tmdb-cache/gold.json $WORK/personas 7
STREAMSETU_PERSONAS=$WORK/personas STREAMSETU_PERSONA_OUT=$WORK/metrics.json swift test --filter PersonaEvalTests   # in macos/
python3 -I tools/personas/report.py $WORK/baseline.json $WORK/metrics.json > $WORK/report.md
```
The evaluation test is skipped unless STREAMSETU_PERSONAS is set. Offline and deterministic: the details service search is served from the cached corpus by a fake transport (every query word must be a title word, a one-letter slip tolerated on long words, popular first). The full run takes well under two minutes.

## Personas
english-small, telugu-hindi, south-indian (ta/ml/kn), anime-fan, asian-drama (ko/ja/zh/th), turkish-arabic, latin-america (es/pt), european (fr/de/it), kids-household, series-only, movies-only, new-user, bare-library (no artwork / genre / ratings), heavy-duplicates, large-66k, huge-200k, sports-live-only (live channels only).

## Noise patterns
Year as `(2019)`, `[2019]`, ` 2019`, `2019 - `; wrong or missing year (+-1); quality and release tags (1080p, 4K, WEB-DL, HDRip, BluRay, x264, HEVC, CAM, HDCAM ...); language prefixes and suffixes (`TELUGU | `, `EN - `, `|FR| `, `(Hindi)`, `HINDI DUBBED`, `MULTI`); country prefixes (`IN| `, `UK: `); release-group junk; dots and underscores for spaces; ALL CAPS; transliteration spelling variants; local-language original titles; sequel numbering (`Part 2`, `II`, `Chapter 2`); series naming (`S01E02`, `1x02`, `Season 1 Episode 2`, absolute numbers); collections and non-title entries (trailers, samples, adult); duplicate copies in many qualities; category names by language, genre, year and provider brand; live channel names with quality, `(backup)`, country prefix, suffix and tvg-id present, missing or wrong.
