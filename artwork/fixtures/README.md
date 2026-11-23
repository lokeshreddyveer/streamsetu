# Name-cleaning fixtures

Owner: the StreamSetu maintainer. The Apple and Android test owners keep both ports equal to these files; an expected value changes here first, then in both ports. Shared by Swift and Kotlin (enforced by `Scripts/check-fixtures.py`); the Windows (C#) port is on hold.

`name-cleaning.json` is a list of `{ "input", "year", "expectedClean", "notes" }`.

- `input`: the title exactly as a provider sends it.
- `year`: the year the library already knows for the title, or `null`.
- `expectedClean`: what the pure function `clean(input, year)` must return. All three apps (Apple, Android, Windows) must reproduce every case exactly (string equality).
- `notes`: why the case exists.

## Rules (applied in this order)
1. Unicode compatibility-compose (NFKC); curly quotes become ASCII, en/em dashes become `-`, no-break space becomes a space, `_` becomes a space. Trim.
2. A title with no whitespace and a `.` has its dots turned into spaces (`The.Matrix.1999.1080p`).
3. Remove every `(...)`, `[...]`, `{...}` group (an unclosed one drops its tail), remembering a 4-digit year (1900-2030) found inside as the year to search with when the library has none. Exception: a group at the very start holding only digits that is not a year, as in `(500) Days of Summer`, stays.
4. Remove a leading `|XX|`. Pad `|` with spaces and split on whitespace.
5. Unambiguous tags are removed anywhere (case-insensitive): 4k uhd fhd hevc x264 x265 h264 h265 avc hdr10 hdr10+ 1080p 720p 480p 360p 1440p 2160p 1080i web-dl webdl webrip bluray blu-ray brrip bdrip dvdrip hdtv hdrip hdcam hdts 10bit 5.1 atmos. Each leaves a marker that acts like a separator for steps 6-7.
6. Head: while the first word is a provider/country code (in, us, uk, en, fr, ... nf, amzn, dsnp, hotstar, zee5, hbo, top, new, vod ...), a language name (telugu hindi tamil malayalam kannada bengali marathi punjabi gujarati urdu english arabic spanish french german turkish korean japanese chinese italian russian portuguese ...) or a weak tag, AND it ends with `:` or `|` or is followed by a separator word (`-`, `|`, `:`), drop it and the separator. Never drop the last word.
7. Tail, repeatedly while more than one word remains: drop separators; weak tags (hd sd hq hdr cam dubbed dub subbed sub subs dual audio multi uncut extended remastered proper new dv vod original); a language name when the word before it is a separator/marker, a weak tag, or "dubbed/dub/audio" was just dropped; `S01` / `S01E02`; `Season N`/`Series N`; a 4-digit year (1900-2030) when it equals the library year or the word before it is a marker, weak tag or language. A bare trailing number such as `Wonder Woman 1984` or `Blade Runner 2049` is otherwise kept.
8. Join with single spaces, trim ` -:|.,~/` from both ends. `Matrix, The` becomes `The Matrix` (also `A`, `An`).
9. Never return empty: fall back to the trimmed original.

Untouched on purpose: case, accents, `&`, colons, roman numerals, non-Latin scripts, hyphens inside words.

## Matching (not part of the fixtures)
Search with the cleaned name and year, then year-1 and year+1, then without a year only when the name is distinctive (at least 2 words and 8 characters, or one word of 12+) and the top result's year is within 1 of the library year when one is known. Accept a result only with title similarity of at least 0.88 (normalised: lower case, no accents, `&` as `and`, no leading "the"); among acceptable results prefer the closest year, then popularity.

# Match-decision fixtures (engine v2)

`match-decision.json` is a list of `{ "libraryTitle", "year", "kind", "languageTag", "candidates", "expectedId", "notes" }`:
- `libraryTitle`: the title as the provider sends it (run it through the name cleaning above first, then decide).
- `year`: the library's year or `null`. `kind`: `movie` or `series`. `languageTag`: the library's language ("Telugu") or empty.
- `candidates`: the details service search results merged from all searches made for the title: `{id, title, originalTitle, year, popularity, originalLanguage}`.
- `expectedId`: the id the pure decision function must return, or `null` (leave the title unmatched). Every case must come out exactly.
All titles are synthetic or public. The Apple implementation is `ArtworkMatchDecision.decide`; the rules are:

1. Names are compared after: lower case, no accents, `&` as `and`, no apostrophes or punctuation, no leading `the/a/an`, roman numerals (after the first word) and `Part/Chapter/Vol N` as digits.
2. Similarity (0 to 1) is the best of: edit-distance ratio; sorted-words ratio (word order); the same two on a transliteration-folded form (sh->s ph->f th->t dh->d bh->b kh->k gh->g ch->c aa->a ee->i oo->u ii->i uu->u ou->u ae->e ai->e ay->e ey->e w->v z->j q->k x->ks, doubled letters collapsed; folded-equal = 0.98); the space-free folded form (x0.97); Jaro-Winkler of the space-free form >= 0.96 for names of 8+ letters (0.9). A consonant skeleton (vowels and h dropped, doubles collapsed, at least 4 consonants) that is equal gives 0.9 (phonetic). The text before a subtitle (`: `, ` - `, ` | `) is also tried on either side, x0.95. Both `title` and `originalTitle` are tried. A different number token ("Dhoom" and "Dhoom 2") caps similarity at 0.8. Accept only similarity >= 0.88.
3. Year: with a library year and a candidate year, the difference must be <= 1 for a film and <= 2 for a series; a near-exact (>= 0.97), non-phonetic, non-subtitle match in a distinctive title may be 2 out. A short title (one word, or 5 letters or fewer) needs the exact year. Phonetic and subtitle matches need the exact year (one out only for a longer name, not for subtitle matches). A candidate with no year is taken only when the title is distinctive, similarity >= 0.97 and it is the only candidate of that name; a library title with no year is only matched when it is not short and similarity >= 0.97.
4. Among the acceptable: closest year, then higher similarity (differences under 0.04 are ties), then original language equal to the library's language, then popularity. If the best two are equally good (same year distance, similarity within 0.04, same language match) the best must be at least twice as popular as the second, else no match. With no library year and different years among the top two, the lead must be at least 3x.

## display-rating.json
List of `{ tmdbAverage, tmdbVotes, provider, expected, notes }`. `expected` is the number a tile shows (one decimal) or null for no badge.
Rule: use the details service's average when it is > 0 and <= 10 and the vote count is at least 10; otherwise the provider's rating when it is credible (readable, greater than 0, not 10 / 10.0, at most 10); otherwise none. Round the details service to one decimal.
Stored when a title is matched (the search result carries both numbers), backfilled for matched titles on screen with one small request each, and removed with the rest of the details service data after 180 days.

# Metadata hub fixtures (all synthetic, no keys, no real payloads)
The hub (Apple: `Services/Hub/`) merges artwork, ids and episode text from several services. Provider names never appear on content screens. Kotlin must reproduce every case.

## arbiter-poster.json, arbiter-logo.json
`{ "pick": [ { ctx, candidates, expected, notes } ], "replace": [...] }`. `ctx`: `preferredLang`, optional `originalLang`. Candidate: `source` (details|artwork|episode-data), `url`, `lang` (ISO 639-1, `""`/`"00"`/null = textless), `width`, `height`, `likes`. `expected` is the `url` of the pick, or null.
Poster score = language (preferred 1000, textless 600, original language 500, en 400, other 0) + min(width,2000)/20 + likes bucket (min(100, 25*log2(1+likes))) - 300 if the aspect is not 2:3 within 8% - 500 if width < 500. Ties: the details service, then the artwork service, then the episode-data service, then list order.
Logo score = language (as above) + min(width,1500)/30 + likes bucket - 500 if width < 400 + source bonus (the artwork service 60, the details service 30); a logo that is not a `.png` is unusable. No usable logo: null (the plain title text is shown).
Backdrop: textless, 16:9 within 8%, at least 1920 wide, else unusable; score = min(width,3840)/20 + likes bucket (-150 over 2600 wide on phone sizes).
`replace` (poster file): `{ stored: {source, quality (number or "pinned"), expired, failCount} or null, candidateScore, expected }`. A stored value is replaced when nothing is stored, it expired, its address failed twice, or the candidate beats it by more than 50. Playlist art and pinned art are never replaced.
Fan-out rule: a title whose stored poster (>= 1075), logo (>= 1060) or backdrop (>= 96) is fresh never asks the artwork service or the episode-data service.

## identity.json
`merge`: `{existing, incoming, incomingSource, expected}` over ids `{details, episodeData, imdb, schedule}`: gaps are filled; a stored id is kept unless the playlist itself supplies one; ids must be positive and imdb ids `tt` + 6 to 10 digits. `queryID`: the id a service is asked about (`fanart` movie: details-service id else imdb; series: the episode-data service; `tvdb`: the episode-data service; `tvmaze`: its own id, else `tvdb:<id>`, else `imdb:<id>`), or null when the service cannot be asked yet. `imdb`: normalisation.

## arbiter-episode-text.json
`{stored, storedSource (null = the playlist), candidates [{source, text}], expectedSource, expectedText}`. Text is filled only when empty or a placeholder ("No description", "n/a", "tba", ...); HTML is stripped; order the details service, the episode-data service, the schedule service; a short (< 20) fetched text is upgraded by a text over 80 characters from a higher-ranked source; the person's own library text is never overwritten.

## attribution.json
`{provenance [sources behind the fields a screen shows], onScreens, expected}`: the footer "Data from the episode-data service" appears iff the episode-data service is among the sources and the build constant `tvdbAttributionOnScreens` is true; never for the details service, the artwork service or the schedule service data. Credits for all services also live in Settings and About ("Artwork from the artwork service", the schedule service CC BY-SA line).

## Service payload fixtures
`fanart-movie-603.json`, `fanart-tv-121361.json` (trimmed v3.2 shapes; `http://` addresses become `https://`; no size in the reply, nominal sizes per type; `season: "all"` ignored for season posters), `tvdb-artworks.json` (type ids: series 1 banner, 2 poster, 3 background, 7 season poster, 23 clearlogo; movies 14, 15, 16, 25; 3-letter languages map to 2-letter), `tmdb-images.json`, `tvmaze-show-82.json` (show with embedded seasons, episodes, nextepisode; episodes without a number are skipped; summaries lose their HTML), `tvmaze-schedule-web.json` (entries without a show are skipped).

## Budgets (not fixtures; the Apple tests assert them)
The schedule service: at most 10 calls in any 10 s (bucket 5, then 0.5/s); the artwork service: express lane only, 2 requests/s, 300/day per install, one request per title until expiry (180 days), no bulk; the episode-data service: stored data kept 7 days; breaker: 5 failures open 15 min, one probe; misses: not found 30 days, server error 6 h, offline none.

## `tmdb-details-extras.json`
`series` / `movie` are trimmed details replies asked with `append_to_response=...,external_ids,translations`; `expectedSeries` / `expectedMovie` are what the hub keeps: the ids (`tmdb`, `tvdb` for series only, `imdb`, read from `external_ids` or the top-level `imdb_id`) and the Hindi/Telugu translations as `title:<lang>` / `overview:<lang>` (empty strings and other languages skipped).

## Multilingual supplements and pending list
- `name-cleaning.json`: 10 cases for Spanish, German, Korean, Japanese, Turkish, French, Italian, Hebrew, Thai and a bracketed language were added at the end. Derived from the rules above, not yet run through the Apple and Android cleaners.
- `match-decision.json`: 16 cases (ids 9000-9031) for Korean, Japanese, Chinese, Arabic, Hebrew, Russian, Thai, Turkish, Spanish, Portuguese, French, German, Italian and Latin-script Hindi, Telugu and Tamil titles. Each has the exact name and year and a decoy with the same name five years later. Not yet run.
- Pending (outcome cannot be derived by reading, needs a run of the engines): spelling variants across scripts (for example a Latin transliteration against a native-script title), `smartmix/fixtures/small-mixed-300.json` supplemented with non-Indian-language titles (its expected shelves come from the engine), and extra cases in `AssistantTests` and `FilmographyTests`.

## match-decision.json: name-only policy (owner, final)
The match is decided by the cleaned NAME only. Year, language, runtime and popularity are not read; the kind only selects the movie or tv search. A candidate whose title or original title equals the cleaned name token for token wins, the first one in result order; otherwise the existing name-similarity tiers (spelling fold, consonant skeleton, subtitle head, >= 0.88) are used and the best name wins; a different name is never accepted.
Changed expectations (index in the file; each notes line starts "name only", with the old reason after "Was:"): 16 Pushpa, 17 Jawan, 94 Her, 96 Oppenheimer (single exact name, accepted); 19, 21, 83, 84, 85, 86, 90, 95, 116, 118 and 150-161 (namesakes, remakes and language or popularity or year ties: now the first result in order; the case ids 9041-9058 added earlier follow the same rule); 23, 25, 27-32, 154 (the year is off, which no longer matters); 57 Baahubali and 112 Silent Orchard Chronicles and 130 Karan Arjun (name close enough or a head of the title: accepted without a year); 117 Dawn (an undated result is no longer refused); 81 (two equal answers: first one).
Added: ids 9060-9065 (result order for remakes, exact name beats a sequel, near spelling, a different name stays unmatched).

## Persona and alias fixtures

- `name-cleaning-persona.json`: same shape as `name-cleaning.json` (`input`, `year`, `expectedClean`, `notes`), cases found by the persona evaluation (leading years, language and country heads, release groups). Apple: `PersonaFixesTests`; Android: `ArtworkNamesTests`.
- `alias-cases.json`: the alias-index key function and lookups (`keys`: title and expected key; then lookup cases against `alias-index-mini.tsv`). The alias index is off by default on both platforms. Apple: `AliasIndexTests`; Android: `AliasIndexTests`.
- `alias-index-mini.tsv` and `alias-index-mini.tsv.gz`: a tiny synthetic index in the plain and the gzip form of the shipped seed file, to test loading only.

## Query tiers

`query-tiers.json`: a list of `{ "text", "tiers", "expect" }`. `text` is a cleaned name, `tiers` the fallback query tiers switched on (`year`, `lang-tail`, `lang-head`), `expect` the extra search texts, in order, the fallback produces when the first search found nothing. Apple: `MetadataMatchService.extraQueries` (`QueryTierTests`); Android: `AliasIndexTests` (same cases).
