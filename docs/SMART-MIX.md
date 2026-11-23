# Smart Mix: genre shelves, ranking views and placement

The Smart Mix engine itself (scoring, tiers, seeded draw, repeat suppression, privacy gates) is specified by `smartmix/fixtures/README.md` and the reference
`smartmix/tools/smartmix_ref.py`. This page is the contract for what was added on top: **genre shelves**, the **All time top / Trending this week** view of a shelf,
the **The details service lists** behind them, and **where shelves sit on Home**. Apple (macOS, iPhone, iPad) is the reference: `Services/SmartMix/SmartMixGenres.swift`,
`SmartMixLists.swift`, `SmartMixEngine.swift`. Android phone, Android TV and Fire TV must match it; the fixtures `smartmix/fixtures/genre-shelves.json` and
`shelf-modes.json` pin every number. Integers only; strings compare by UTF-8 bytes.

## 1. Genre table (research summary)

Sources used: the details service movie genre list (19 genres, ids 28 Action, 12 Adventure, 16 Animation, 35 Comedy, 80 Crime, 99 Documentary, 18 Drama, 10751 Family, 14 Fantasy,
36 History, 27 Horror, 10402 Music, 9648 Mystery, 10749 Romance, 878 Science Fiction, 10770 TV Movie, 53 Thriller, 10752 War, 37 Western) and the details service TV genre list
(10759 Action & Adventure, 16, 35, 80, 99, 18, 10751, 10762 Kids, 9648, 10763 News, 10764 Reality, 10765 Sci-Fi & Fantasy, 10766 Soap, 10767 Talk, 10768 War & Politics, 37).
Big services title their rows the same way: "Top <Genre>", "Sci-Fi & Fantasy" for TV. Chosen: the 22 genres people browse most; News, Soap, Talk and TV Movie are left out
(not a taste people browse by). Biography and Anime are not the details service genres but providers use them, so they exist and rank locally.

Default order (also the order of the "Browse by genre" row): action, comedy, drama, thriller, scifi, horror, romance, crime, animation, documentary, family, fantasy,
mystery, adventure, war, western, history, music, biography, kids, anime, reality. The machine-readable table (keys, titles, aliases, scope, kids flag, the details service ids) is the
`table` array of `genre-shelves.json`; it is normative.

Per genre: `key`, `title` ("Top Thriller", "Top Science Fiction"; the name is the title without "Top "), `scope` (`both`, `movie`, `series`; only reality is `series`),
`aliases` (normalised phrases), `kids` (kid-safe: comedy, animation, family, fantasy, adventure, music, kids), `tmdbMovie`, `tmdbTV` (ids), `tmdbLang` (anime: `ja`).

### Text rules
- `norm(s)`: lowercase; every run of characters that are not letters or digits becomes one space; trim. "Sci-Fi & Fantasy" -> `sci fi fantasy`.
- `tokens(raw)`: split the provider genre text on `,` `/` `|` `;` (not on `&` or `-`), `norm` each part, drop empties and duplicates, keep order.
  The library's own genre text is used; where the details service details were matched and saved, the same names (the details service names are the aliases) arrive in that field. A title with no genre text belongs to no genre shelf.
- A token matches an alias when equal, or when the alias occurs in the token as whole words (`" "+token+" "` contains `" "+alias+" "`). "action adventure" matches both Action and Adventure; "sci fi fantasy" matches Science Fiction and Fantasy; "docudrama" matches nothing.
- A title matches a genre when any token matches any alias and the genre's `scope` allows the title's kind.

## 2. Genre shelf ranking

Shelf id `genre:<key>`. It is an ordinary non-folder shelf of the ranking contract with these differences.
- Source: the title clusters (after identity grouping, representative fields) that match the genre. Restricted (locked, hidden, Kids-restricted, twin of a restricted copy) and dismissed clusters never count (counters as for other shelves). CAM-only clusters and clusters without a poster are removed below tier 5 / tier 4 as on the other shelves. Watched titles are dropped while tier < 3 (Continue Watching rules are unchanged: nothing here changes what Continue Watching shows).
- Weights (percent; release, added, quality, language, rating, popularity, affinity, fresh): weekly view `15 10 10 5 25 25 0 10`; all-time view `5 0 15 5 50 15 0 10`. Sharp sampling weight, pool 2000, size 14, `mixesKinds` true. No affinity feature (the genre is the topic).
- Diversity: the "same genre twice" block is off (all share it); franchise, kind and language rules and penalties as usual.
- Minimum: fewer than **8** picks after the tier loop means the shelf is hidden. There is no recently-added or plain-library fallback for a genre shelf.
- Seed: `SmartMixPRNG.seed(profile, shelfSeed, dayKey, refreshCounter)` with `shelfSeed = "genre:<key>"` for the weekly view and `"genre:<key>|top"` for the all-time view.
- Rating: the existing rating feature (provider text parsed with the integer grammar, shrunk toward the middle by 40 %), so an unrated or odd rating cannot win a shelf alone.
- Candidate pool (SQL adapters): in addition to the normal home pool, for every genre the 60 best-rated titles per kind whose genre text matches (one scan per kind ordered by rating, bucketed by `keys`), so a small genre still has its titles in the pool.

### The details service order (when a list is cached)
`ranks` = the details service rank (1 = best) of each title that matched the list for this shelf and view (matcher: kind movie<->movie, tv<->series; title or original title through the identity key; year within 1 when both known; lowest rank wins).
Ranks are applied to the shelf's clusters (`trend`), never sent anywhere. If at least **6** eligible clusters have a rank the shelf is *ordered*:
1. matched clusters in the pool are sorted by (rank, id bytes);
2. one `next()` of the shelf's SplitMix64 stream is drawn per matched cluster in that order; clusters are then sorted by (`(rank-1)/3`, drawn value, id bytes): ranks in the same bucket of 3 are shuffled by the day-seeded stream, buckets keep their order;
3. the first 14 are the picks (no diversity rules for these); if fewer than 14 matched, the rest are drawn normally from the same stream.
Caption `trendingTMDB`. With fewer than 6 matches nothing is ordered, ranks are ignored and the local ranking above applies (caption `mostWatchedHere`).

## 3. Which genre shelves show today

`counts[key]` = number of clusters that are not restricted, not dismissed, not CAM-only, have a poster, whose kind the genre allows and which match it (`SmartMixEngine.genreCounts`).
`select(counts, profile, dayKey, refreshCounter, kids, affinityGenreKeys)`:
1. eligible = genres with `counts >= 8`; a Kids profile keeps only `kids` genres.
2. up to **3** from `affinityGenreKeys` (genres of the titles watched most lately, most first) that are eligible, in that order;
3. the remaining eligible genres in table order, rotated by `off = uniform(n)` of `SplitMix64(seed(profile, "genres:auto", dayKey, refreshCounter))` (n = how many remain); take the first `6 - already chosen`.
So at most 6 genre shelves, a different set each day and after a shuffle, the person's own genres first. `affinityGenreKeys` = the 3 genres (`keys`) most common among the 100 movies and 100 series most recently watched.
"Browse by genre" lists every eligible genre in table order (name, count); it is shown after all shelves and is never empty-looking: no row when nothing is eligible.

## 4. Views: All time top / Trending this week

Trending in Your Library and every genre shelf carry two chips in the **header row, right-aligned on the title line**: `All time top` and `Trending this week`; exactly one is on.
- Default `weekly`. The choice is stored **per profile and per shelf** (`smartmix.mode.<profile>.<shelfId>`; `weekly` removes the entry). It survives restarts; switching profile shows that profile's choice.
- `weekly` for Trending in Your Library is the existing behaviour. `allTime` uses the all-time list in place of the weekly list for the matching (trend mode when at least 3 matched, then only matched titles) and the all-time weights when nothing matched; seed `trending-library|top`.
- A genre shelf in `weekly` follows list `week:<key>`, in `allTime` list `top:<key>`. If that list is missing or has no matches it falls back to the whole-library list of the same view (`week` = weekly trending, `top` = all-time top); if that is missing too, the local ranking stands.
- Subtitle (one short line, secondary colour, never truncated): `Trending this week` (weekly, the details service ordered), `Popular here` (weekly, local ranking), `Best of all time` (all-time, the details service ordered), `Highest rated here` (all-time, local). At most 20 characters in every language.
- **Header contract** (one header for Trending in Your Library and every genre shelf; Mac, iPhone, iPad, Android phone/TV/Fire TV):
  - Row 1: shelf title, one or two lines, left (title style, semibold); `See all ›` right-aligned on the same row (genre shelves only; Mac also has the scroll arrows right of it).
  - Row 2 (minimum height 30, the same in both views): the subtitle on the left, a **small two-option segmented control** on the right: `All time | This week` (visible labels; spoken labels `All time top` and `Trending this week`). Equal-width segments (min 64), 26-28 high inside a 2 dp track; track = primary colour at 8 %; selected segment = accent at 30 % with a 1 dp accent border, text in primary colour, semibold. Theme tokens only, so every theme works.
  - The selection indicator **slides** between the segments (spring, about 0.28 s; Apple: `matchedGeometryEffect`; Compose: `animateDpAsState` on the indicator offset). Reduce Motion / animations off: no slide, instant. A light haptic on touch devices when the selection changes (not when the selected segment is tapped again).
  - Touch target 44 dp each, achieved by hit slop (the drawn control stays small; Compose `minimumInteractiveComponentSize` / `Modifier.padding` on the clickable, Apple `contentShape(inset -9)`). TV: both segments are D-pad focusable on row 2 (section 4 below); focus ring on the segment, not on the track.
  - Dynamic type / font scale: when the subtitle and the control no longer fit on one line (about Dynamic Type XXL and above), row 2 **stacks**: subtitle, then the control below it, left-aligned. Nothing truncates; the title may wrap to 2 lines before it shrinks. (Apple: `ViewThatFits`; Compose: `FlowRow` or a measured switch.)
  - Accessibility: the control is one container named `Ranking for <shelf title>`; each segment is a button with the spoken label above and the selected state; the title carries the heading trait.
  - Research basis: Apple HIG segmented controls (two or more equal-width segments for mutually exclusive views, introductory text beside them, keep other focusable items away) and Material 3 segmented buttons (2-5 mutually exclusive options; chips are for more or independent choices); other streaming apps, Prime and Apple TV put per-row switches at the row header's trailing edge, small and quiet.
- **The switch is section-local.** Tapping a segment must not rebuild Home. Order of events: (1) the control moves at once (only that shelf's `mode` changes in the screen's state); (2) the choice is saved (`smartmix.mode.<profile>.<shelfId>`) and **nothing is invalidated**: no revision bump, no catalog/Home reload, no skeleton, other shelves keep their rows, order and the scroll position; (3) only that shelf is built, alone (`shelves([shelfId])`, commit false so repeat suppression is untouched), and when it arrives its tiles are swapped in place with a short cross-fade (0.2 s; none with Reduce Motion); the header does not move. A newer tap on the same shelf cancels the older build (a stale result is dropped).
  - Both views of a shelf are cached under their own key (profile, shelf, view, day, refresh counter, lists present), so switching back is instant and builds nothing.
  - After Home has drawn, the other view of every switchable shelf is built in the background in one pass over the pool (`warmOtherViews`), so the first tap is also instant. Only a new day, a shuffle, a restriction/lock/profile change or a catalogue sync rebuilds Home.
  - Tests (Swift, `GenreShelfTests`): `switchingOneShelfsViewLeavesTheOthersAndReadsTheLibraryOnce` (one pool read for the switch, none when switching back and forth, every other shelf's ids unchanged), `replacingAShelfTouchesOnlyThatShelf`, `subtitlesAreShortEnoughToStayOnOneLine`; the build is wrapped in a `shelfView` signpost interval (category `SmartMix`). Ports: same three checks.
- Genre shelves also show **See all ›** at the right end of the title row: it opens the Movies list (the Series list for a series-only genre) with that genre filter chosen (the genre words are the alias words, matched against the provider genre text and folder name) and best rated first; the existing sort and filter menus stay available, and the filter menu has a Genre submenu.
- **TV / D-pad (Android TV, Fire TV):** the two chips are focusable items on the header row, reachable by D-pad right from the title or by D-pad up from the first tile; left/right moves between the chips; OK selects; after a selection, focus stays on the chosen chip until the person presses down, and down returns focus to the first tile of the same shelf (focus is remembered per shelf). Back from the "See all" list returns to the same shelf.

## 5. The details service lists (ranking, shuffle and "top" data)

List names: `week` (existing weekly trending: `/trending/movie/week` + `/trending/tv/week`), `top`, `week:<genre>`, `top:<genre>`.
- `top`: `/movie/top_rated` and `/tv/top_rated`, pages 1 and 2 of each; movie and tv interleaved (movie 1, tv 1, movie 2, ...) and renumbered.
- `week:<genre>`: `/discover/movie` and `/discover/tv` with `with_genres=<ids joined by |>`, `sort_by=popularity.desc`, `include_adult=false`, page 1 (movie ids from `tmdbMovie`, tv from `tmdbTV`; a kind with no ids is skipped; anime adds `with_original_language=ja`).
- `top:<genre>`: the same with `sort_by=vote_average.desc` and `vote_count.gte=300` (movies) / `150` (tv), so a few-vote title cannot top the list.
- Genres with no the details service ids (biography) have no list: local ranking.
- Credentials and activation exactly as the weekly list: own key first, then the built-in token; nothing is requested without a credential or with the switch off; a refused built-in token is set aside by the existing rule. A request carries only the list name (and sort/genre id): nothing about the person, library, history or device.
- Cache: one entry per list name, `fetchedAt` + entries. Used while at most 30 days old (`active`), kept at most **180 days** (older entries are deleted), refetched when `week*` is 24 h old and the others 7 days old; a failed fetch keeps the old entry. Turning the details service off or removing the key clears all of them. Lists for the genre shelves shown today (both views) are fetched in the background after Home has drawn (utility priority, one request at a time); a first launch therefore shows the local ranking and the next load uses the lists. Works offline from the cache.
- Matching is local; shuffle among equal ranks is the bucket shuffle in section 2.

## 6. Placement on Home (legacy template, superseded by section 10)

Kept because `genre-shelves.json` `placement` still pins `SMPlacement.order`. Home uses `SMPlacement.layout` (section 10).


Order, top to bottom (rows without titles are skipped): Continue Watching, **Top This Week**, **Trending in Your Library**, **Because You Watched**, preferred-language row, **Rediscover**; genre shelves are interleaved by this template, where `G` = next genre shelf in the order chosen in section 3:

`top-week, trending, G, for-you, G, G, lang-pref, G, rediscover, G, G`

Rules: a `G` is placed only if fewer than 2 genre shelves directly precede it; a genre shelf that does not fit is dropped (so with no personalised rows only 2 genre shelves show). "Browse by genre" follows the last shelf. Hero, Continue Watching and other Home rows (channels, provider shelves) keep their own places above/below this block as before. (`SMPlacement.order`, fixture `placement`.)
Kids profiles: the same template with the kid-safe genres only; every shelf is still restricted by the Kids and lock rules (a locked or hidden folder's titles never appear, whatever the genre).

## 7. Strings

All new text is looked up by its English text: shelf titles "Top <Name>" (22), the 22 names (Browse by genre chips, Genre filter), "Browse by genre", "See all", "All time top", "Trending this week", the four subtitles above, the segment labels "All time" and "This week", "Ranking for %@", "%@, %lld titles", "Shows all titles", "Shows all %@ titles", "Genre", "Any genre". English, Hindi and Telugu are in `macos/Resources/Localization/*.lproj/Localizable.strings`; Android adds the same keys to its string resources.

## 8. Fixtures

`genre-shelves.json`: constants, the table, `tokens` vectors, `matching` vectors, `counts`, `select` cases (ctx fields: profile, dayKey, refreshCounter, kids, affinityGenreKeys, counts), `placement` cases, and `steps` that build one genre shelf from `library` (candidate field `genres` = raw provider text; run `tokens` on it) and compare `ids` and the diagnostics `diag`.
`shelf-modes.json`: `steps` for both views (with and without `ranks`) for genre shelves and `trending-library`, `storage` (remembered choice per profile and shelf), `lists` (list names per shelf and view), `refetchHours`.
Neither file is read by the generic case runner. The expected values were produced by the Swift implementation (`SMARTMIX_WRITE_GENRE_FIXTURES=1` on `GenreShelfTests` rewrites them) and checked by hand against this page; there is no Python reference for them.

## 9. Android port checklist (phone, TV, Fire TV)

1. Port `SMGenres` (table, `norm`, `tokens`, `keys`, `select`), `SMPlacement`, the genre shelf build and `genreCounts` exactly as sections 1-3 and 6; load `genre-shelves.json` and `shelf-modes.json` in the Kotlin tests.
2. Port the lists (section 5): `SMListKey`, the details service client (same endpoints and parameters), the 180-day cache, refetch hours, background refresh for today's genre shelves; same credential order and the same "nothing sent about the person" rule.
3. Per-shelf view (section 4): stored per profile and shelf; `ctx.modes`; cache key contains the view; `shelfView(smartId, mode)` builds one shelf with no commit and no invalidation; `warmOtherViews` after Home has drawn.
4. UI: one shared header composable for Trending in Your Library and every genre shelf (section 4, "Header contract"): title row with `See all ›`, subtitle row with the small segmented control, sliding indicator, haptic (`HapticFeedbackType.TextHandleMove` or `KEYBOARD_TAP`), animations off respected (`Settings.Global.ANIMATOR_DURATION_SCALE == 0`), stacking at large font scale, 48 dp targets by hit slop (Material minimum), TalkBack labels. TV / Fire TV: segments are focusable on row 2, focus returns to the same shelf's first tile on down.
5. Section-local update: only that shelf's state in the Home view model changes (a `StateFlow` per shelf or a keyed list update); no `loadHome()` call, no skeleton; the lazy column keeps its scroll state (stable item keys = shelf ids).
6. Strings: add the keys of section 7 to `values/`, `values-hi/`, `values-te/` (text identical to the Apple files).


## 10. Home v2: names, order, composition, collections, default view (all apps)

Research: `scratchpad/home/research.md` summary. One large streaming service describes the page as thematically coherent rows where choosing and ordering rows is part of personalisation, with diversity and novelty as page-level
metrics; Plex and Jellyfin keep Continue Watching first and users dislike row sprawl; MMR is the standard cheap re-ranker. Gaps (no source found, so these are design choices): maximum rows before fatigue (12 here),
time-of-day rules, the "one in six" exploration slot. Owner rule: nothing is tuned to one library; every new row hides when it cannot fill 6 tiles, and thresholds scale with the library.
Machine-readable contract: `smartmix/fixtures/home-layout.json`, written by `smartmix/tools/make_home_fixtures.py` (integer-only reference of the pure parts). Not read by the generic case runner.

### 10.1 Row names (English text is the key; Hindi and Telugu in `Localizable.strings`)
Continue Watching = "Pick Up Where You Left Off" (subtitle "Movies and episodes you started"); top-week = "This Week's Top Picks" ("Popular right now" when the details service ordered, else "Most watched and best rated here");
trending-library = "Popular in Your Library" (subtitle = the view caption, section 4); for-you = "Because You Watched <title>" or "Picked for You"; rediscover = "Hidden Gems"; lang-pref = "<Language> Picks";
new rows "Fresh Additions", "Movie Night", "Binge-Worthy Series", "Collections", moods "With the Kids", "Edge of Your Seat", "Feel-Good Picks"; "Browse by Genre". Genre rows use friendly titles
(`titles.genres` in the fixture: "Thrillers Worth Watching", "Sci-Fi Picks", "Laugh Out Loud" ...). The table titles of section 1 ("Top Thriller") stay as data keys. Rules: plain words, title case, no two rows share a
title (tested), ranking-source wording lives in the subtitle only. "Because You Watched <title>" is used only when a real similarity engine (franchise, director, genre, cast, story) links the seed to at least 3 of the row's titles;
those titles lead the row. Otherwise the row is "Picked for You". The seed is one of the last 3 movies and 2 series watched.

### 10.2 New engine rows (all additive; every shared fixture of sections 1-8 and the Python-pinned files is unchanged)
Built like genre rows (seeded weighted draw, tiers) with: `fresh` (added within 14 days, weights 0 50 10 5 10 15 0 10, rating floor 5.5 if rated), `movie-night` (movies, quality >= 2, rating floor 6.5 if rated, weights 10 0 20 10 35 15 0 10),
`binge` (series, rating floor 6.5 if rated, weights 5 5 10 10 35 25 0 10), `mood:<key>` (union of genre keys: withKids = family, animation, kids, adventure; edge = thriller, crime, mystery; feelGood = comedy, romance, family, music;
a Kids profile uses kid-safe genres only, and only moods with `kidsOK`: withKids, feelGood; weights as genre rows). Unrated titles are allowed (neutral rating feature), so libraries without ratings still get rows.
Quality: no CAM-only, poster required: a row that needs tier 4 or 5 (poster-less or CAM-only titles) or has fewer than 6 picks is **hidden**, with no fallback. A mood needs at least `max(8, total * 15 / 1000)` matching showable titles
(total = showable titles in the pool). Seeds: `fresh`, `movie-night`, `binge`, `mood:<key>`.
Oversampling: `ctx.oversample` (0 in fixtures; Home uses 10) draws that many extra picks after the normal ones; the first `size` picks are identical with and without it (prefix property, tested). Repeat suppression records only the first `size` picks.

### 10.3 Collections
Franchise key (`SMFranchise.key(identityKey:)`): words of the identity key; trailing sequel markers removed (1-2 digit numbers, roman ii-x, part, chapter, vol, volume, episode); at least 2 words left; the second word is not a
function word (of the in on to a an for with and is at by); not two numbers; one of the first two words has 4+ letters and is not in the small-word list; key = first two words. Vectors: fixture `franchise`.
(No the details service collection id exists in the library data today; when the metadata hub stores `belongs_to_collection` it replaces the key.) The key also feeds the existing franchise diversity rules of every row.
`collections` row: groups of >= 3 distinct showable titles (not restricted, not dismissed, not CAM-only, with a poster); strength = titles * 100 + average rating tenths (60 when unrated); sorted by strength then key bytes; the first 24 get one
`next()` of `SplitMix64(seed(profile, "collections", dayKey, refreshCounter))` each, ordered by (position / 4, drawn value, key bytes); first 12 shown; hidden with fewer than 3 franchises. Tile = lead title (best rated) poster with two
cards peeking behind, the name (common leading words of the members' titles minus trailing small words / numbers, else the key title-cased), "N titles". Tap opens the members in release order (sheet on Mac, pushed grid on iPhone and iPad).

### 10.4 Composition (pure; `SMCompose`)
Input: the engine results (oversampled) for every row. Steps: (1) limit mood rows to 2 (Kids: table order, others: rotation by `uniform(n)` of `SplitMix64(seed(profile, "moods:auto", day, counter))`); (2) order rows by the template (10.5);
(3) in that order, each row drops titles already used by an earlier row; ordered rows (the details service order) keep their order and are cut to 14; other rows are re-ranked (MMR) and cut to 14; a row under its minimum (6; trending-library 3; genre 8) disappears
and its titles stay free; collections tiles are not title-excluded; (4) for-you only: exploration; (5) lay the survivors out again.
MMR re-rank (integers): relevance `1000 - 30 * drawPosition`; repeat greedy step over the first 8 unchosen; penalty against the last 3 chosen: same franchise 300, same decade 60; against the last 2: same primary genre 80, same language and kind 40;
highest score wins, ties the earlier draw position. Exploration: positions 6 and 12 (index 5, 11): when the title there lies inside the person's taste (a genre key among `affinityGenreKeys`, or language = first of `topLangs`) it is replaced by the first
leftover title outside it; nothing happens when the person has no history. Single-row rebuild (view switch): titles on the other rows are skipped when at least the minimum remain, else the plain row.

### 10.5 Placement by context (`SMPlacement.layout`)
Context = weekday (1 Monday ... 7 Sunday) and hour from the device clock. `movieNight` = Friday or Saturday from 17:00, plus Saturday and Sunday before 04:00. `weekend` = Saturday and Sunday. `morning` = 05:00-10:59.
Above the fold (after the hero and Continue Watching): one ranking row, then a personal row. Templates ("G" next genre row, "M" next mood row; absent rows skipped; movie-night only when `movieNight`, binge only when `weekend`):
- normal: top-week, for-you, movie-night, G, trending, M, G, lang-pref, binge, collections, G, rediscover, M, G, fresh, G, G
- morning: top-week, fresh, for-you, G, trending, M, G, lang-pref, collections, G, movie-night, binge, M, rediscover, G, G
- kids: M, top-week, G, for-you, G, fresh, collections, G, M, rediscover, lang-pref, G, trending, G
Kinds: ranking (top-week, trending), personal (for-you, rediscover, lang-pref), context (fresh, movie-night, binge), collection, mood, genre. Never two rows of the same kind adjacent: take the first of the next 3 queued rows whose kind differs
from the previous row, else set the head aside. At most 12 rows. When fewer than 6 rows would remain, set-aside rows return in order (a thin page beats a strict one). Extra genre/mood rows not in the template follow. "Browse by Genre" follows the last row.
Quick-watch rows ("under 90 minutes") are not built: the library has no runtime data on the Home path; add when it has.

### 10.6 Default view of a ranked row (All time / This week)
The person's choice wins (stored per profile and row; a tap on either segment stores it, including "This week"; an all-time value stored by an older version counts). Otherwise: `weekly`, unless this week's list matched fewer than 6 titles
(row not the details service-ordered) while the all-time list is ordered: then the row opens on `allTime`, is not stored, and its subtitle is "Quiet week: all time" (20 characters). Without any the details service list both views are local and "This week" stays. The decision is
re-evaluated on every load. "This month" was rejected: the details service trending exists for day and week only, a month view would be a local rank of sparse history, and the services reviewed use a quiet two-way switch.

## 11. Layout system (Mac, iPhone, iPad; Android uses the same numbers in dp)
`HomeLayout`: row gap 24, header-to-tiles 12, tile gap 12, subtitle row min height 30 (an 8-pt grid with 4-pt half steps). Title, subtitle, control, See all and the first tile share the content inset (iPhone 16, Mac gutter 12 plus the rail's own
compensated 6). Tile captions: title 2 lines reserved, quiet line 1, so tiles of a row are one height. Skeleton rows (`ShelfSkeleton`) have the same header and tile geometry as real rows (3 rows while loading, shimmer off with Reduce Motion).
Dynamic Type XXL: header row 2 stacks (section 4). iPad and Mac use the same row structure; tile width follows the size class (iPhone 120, iPad 160, Mac 150). Sidebar and safe areas come from the screen's own insets.

## 12. Android port notes (phone, TV, Fire TV)
1. Port `SMMoods`, `SMHomeRules`, `SMFranchise`, `SMCollections`, `SMNaming`, `SMDayContext`, `SMPlacement.layout`, `SMCompose` (limitMoods, rerank, explore, compose, single), `SMModeDefault` exactly as sections 10.1-10.6; integers only, strings by UTF-8 bytes.
2. Engine: new shelf ids, eligibility, weights, hidden rules (10.2), `oversample` (extra picks only), mood floor; `SMPick` gains genre, genres, lang, franchise.
3. Adapter: set `franchise` from `SMFranchise.key(identityKey)` for every candidate (this also drives the existing franchise diversity rule).
4. Tests: load `home-layout.json` (`layout`, `compose`, `franchise`, `modeDefault`, `titles`) and re-run the persona checks of `HomeLayoutTests` (new install, no genres/ratings/artwork, series only, kids household, 20,000 titles): no title twice on a screen, no empty row, at most 12 rows.
5. UI: one `Shelf` composable for all rows with the spacing of section 11 (24 / 12 / 12 dp, 48 dp targets), collection tile with two peeking cards, skeleton rows of identical geometry, per-row view switch with `chosen` stored on tap; row titles from `values/`, `values-hi/`, `values-te/` using the English text of `Localizable.strings` (keys under "Home v2 row names" at the end of `hi.lproj` and `te.lproj`).
6. Composition runs once per Home load and after a view switch only for that row (`single`); Home context (weekday, hour) comes from the device clock at load time.
