# Smart Mix shared fixtures

One set of JSON files, consumed by the Swift tests (`macos/Tests/REDDYTests/SmartMix*`) and the Kotlin tests. Every expected value was computed by the
reference script `smartmix/tools/smartmix_ref.py` (integer-only Python); regenerate with `python3 smartmix/tools/make_fixtures.py`.
Swift and Kotlin must reproduce every id list and every diagnostics field exactly. Contract: the ranking contract (05) plus the decisions below.
All numbers are Int64/UInt64; no floating point, no pow/log, no locale; strings compare by UTF-8 bytes.

## Files
`prng` (FNV-1a/SplitMix64/uniform vectors), `features` (every feature table row), `empty-library`, `tiny-library`, `duplicates-and-twins`,
`multilang-versions`, `bad-ratings`, `missing-artwork`, `offline-no-tmdb-key`, `trending-matched`, `expired-metadata`, `profile-switch`, `exclusions`
(locked/hidden/Kids-restricted, restricted twin, rec_dismissed), `repeat-suppression-5-loads`, `reshuffle-sequence`, `day-rollover`, `diversity-limits`,
`non-latin-ids-byte-order`, `relaxation-order`, `small-mixed-300`, `hundreds-of-folders` (700 folders), `large-66k`, `stress-200k`.

## Case file
```
{ name, description,
  library: [candidate...]   OR   generator: {name, seed, n, folders},
  steps: [ { profile, dayKey, refreshCounter, preferredLang?, affinity?, tmdb?, patch?, commit?, shelves:[...], poolCap?,
             expect: { "<shelfId>": { ids:[...], art:[...], diag:{...} } }   OR   { digest, counts, first } (generator cases) } ] }
```
Steps run in order against one fresh in-memory state store (shown-history, refresh counters). `patch` = `{ itemId: {field: value} }` applied to a copy
of the library for that step only (lock/dismiss toggles). `commit: true` records the shown items after the step (first render of a new load key).
`ids` = representative item id of each pick, in picking order. `art` (hero only) = `backdrop` or `poster` (poster-composition tier).
`digest` = SHA-256 hex of, for each shelf in `shelves` order, `"<shelfId>:" + ids joined by "\n" + "\n"` (UTF-8). `first` = first 14 ids of each non-folder shelf.

## Candidate fields (all optional except `id`; defaults in brackets)
id, kind [movie|series: movie], key (identity key, already normalised: grouping is `(kind,key)`) [""], year [nil], added (days before dayStart; nil = unknown) [nil],
rating (text) [nil], q (quality rank 0..5) [2], cam [false], lang [nil], folder (folderKey) [nil], franchise [nil], genre (primaryGenre) [nil],
poster [true], backdrop [false], watched [false], completed [false], lastWatched (days ago) [nil], p7, p30 [0] (identity-level play counts),
trend (TMDB rank, only set by the matcher, never in input; ignored if present), loadsAgo (ignored: derived from state), restricted [false], dismissed [false], src (preferred-source rank, lower is better) [0].

## Pipeline (what both platforms implement)
1. loadsAgo: from the state store for (profile, shelf), see State. 2. TMDB matcher assigns `trend` (only when active, see TMDB).
3. Grouping: candidates grouped by `(kind,key)`; inside a group, members sorted by (year nil last, year, id bytes) are split into clusters: a member whose year is more than 1
   above the cluster's FIRST year starts a new cluster; nil-year members join the first cluster. One cluster = one title (one card).
4. Cluster flags: restricted = any member restricted; dismissed = any member dismissed; watched/completed = any; lastWatched = min; p7/p30 = sums; trend = min; loadsAgo = min; camOnly = all members CAM.
5. Representative: members minus CAM members (if all CAM, all members); key = (lang == preferredLang first, q desc, src asc, added asc with nil last, id bytes). The representative's own fields are used for scoring, art, lang, folder, franchise, genre, year, kind.
6. Per shelf (shelf `folder:<k>` first restricts to clusters whose representative `folder == k`; all counters are then within that folder):
   restricted clusters removed (counter `restricted`; never relaxed); dismissed clusters removed on every shelf except folder rows (`dismissed`);
   then at relaxation tier t (below) the eligibility rules in this order, each removed cluster counted once under the first rule that removes it:
   `camOnly` (t<5), `noArtwork` (hero: needs backdrop or poster at every tier; other shelves: needs poster while t<4),
   `lang` (lang-pref: representative lang must equal preferredLang, never relaxed; no preferredLang = shelf hidden), `notTrending` (trending-library in trend mode),
   `watched`: rediscover keeps unwatched clusters and clusters that are completed with lastWatched nil or > 30; other non-folder shelves drop watched while t<3. Folder rows have none of the watched/dismissed rules.
7. Score S, weights, W, draw: exactly contract 05 sections 2, 3, 5, with these pinned details: S clamped to 0..1100; hero +50 backdrop, +60 trend;
   top-week and trending-library +100 trend; at t>=3 watched clusters (not rediscover) get S-200 (floor 0); fresh feature is constant 1000 at t>=1.
   Sampling weight sharp `1 + S*S/100`, folder rows soft `1 + S` (Int64). Pool = top `2000` (folder rows 200, `poolCap` if given and smaller) by (S desc, id UTF-8 bytes asc).
   Shelf sizes: hero 12, folder rows 12, others 14. Min counts for the tier loop: hero 3, rows 6, trending-library 3, folder 1, each capped by the number of clusters that survived restricted/dismissed.
   Blocked rule uses the last two picks (needs 2 picks): same non-nil franchise, same non-nil genre, same kind (hero only), same non-nil lang (every shelf except lang-pref). Penalties after a pick p
   (skip entries already picked, w==0): same non-nil franchise as p: w/4; same non-nil lang and same kind as p (not on lang-pref): w*3/4. Both diversity rules and penalties are off at t>=2. "/" truncates.
   `tiny` = eligible count <= shelf size: fresh is treated as constant (like tier 1) without raising the tier.
8. Tier loop: t = 0..5 (1 fresh const, 2 diversity off, 3 watched allowed, 4 poster-less allowed, 5 sole-CAM allowed); stop at the first tier with picks >= min. If none reaches min the tier 5 result stands.
9. Empty after tier 5 (and not lang-pref): fallback `recentlyAdded` (restricted/dismissed already removed; clusters with poster or backdrop, by added asc nil last then id; `plainLibrary` by id if none have art;
   hero with nothing at all = `existingFeatured`, the UI keeps its existing art). lang-pref empty = `hidden: true`.
10. top-week: with TMDB active and >= 6 non-restricted clusters matched, those eligible matched clusters in the pool are picked first in TMDB rank order (max 14, no PRNG draw, they count as the "last two" for diversity),
    the rest of the slots are drawn normally (same PRNG stream); caption `trendingTMDB`, otherwise `mostWatchedHere`. trending-library: trend mode iff >= 3 non-restricted matched clusters
    (then only matched clusters are eligible, caption `trendingTMDB`); otherwise it behaves like local top-week scoring under its own seed (caption `mostWatchedHere`).

## State (repeat suppression)
Per (profile, shelf): refreshCounter, loadKey, seq, rows (identityKey, year, itemId, rowSeq). loadKey = `dayKey|refreshCounter`.
Build with loadKey L: effSeq = seq if state.loadKey == L else seq+1; for each row ago = effSeq - rowSeq, rows with ago < 1 are ignored; per identityKey the smallest ago counts; fresh feature 1:100, 2:400, 3:700, else 1000.
`record(L, rows)` (first successful render only): no-op if state.loadKey == L; else loadKey = L, seq += 1, append rows with the new seq, keep the 48 newest rows (seq desc, stable). Rows never include restricted items.

## TMDB
Active only when `enabled` (default true) and `keyPresent` (the person's own key) and cache present and age <= 30 days. Age 31..180: `expired` (local only). Age > 180: `purged` (cache must be deleted; local only). No cache: `noCache`. Without key or switched off: `off`.
Matching (candidate `key` is the already-normalised identity key; entries are normalised with `fold_title`): kind movie<->movie, tv<->series; names = fold(title) and fold(original title); year must be within 1 if both are known;
lowest rank wins per candidate. `fold_title` = NFKD, drop combining marks, lowercase, every run of characters that are not ASCII letters/digits and not non-ASCII (code point >= 0x80) becomes one space, drop one leading the/a/an when more words follow. (Fixtures only use plain ASCII and one accented title.)

## Generator (cases with `generator`)
`SplitMix64(FNV1a64("smartmix1gen..."))`: seed string `"smartmix-gen1|<name>|<seed>"`; `u(n)` = uniform(n). For i in 0..<n, draws in exactly this order (see `generate()` in smartmix_ref.py, which is normative):
series?=u(100)<27; key `t<u(max(1,n*4/5))>`; year 2026-min(u(36),u(36)); added nil if u(100)<5 else u(700); rating via u(20); quality via u(100) (<8 CAM q0,<15 q1,<45 q2,<75 q3,<92 q4, else q5);
lang LANGS[min(u(6),u(6))] (nil if u(100)<3, the 3% draw happens after the two); folder `f<(u(folders)*u(folders))/folders>`; franchise `fr<u(n/50+1)>` if u(100)<20; genre index u(8), nil if u(100)<5 (index drawn first);
poster u(100)>=12; backdrop u(100)<55; watched u(100)<6; completed watched&&u(100)<70; lastWatched u(120) (drawn always, used if watched); p7 (1+u(5)) if u(100)<4; p30 = p7 + (u(8) if u(100)<8); restricted u(1000)<8; dismissed u(1000)<3; src u(2).
Python evaluates `a and b` lazily where written (`completed`), so draw `u(100)<70` only when watched is true; copy the Python short-circuit behaviour exactly. Ids: `m<i>` or `s<i>`.

## Diagnostics fields compared
inCount, groups, restricted, dismissed, camOnly, noArtwork, watched, lang, notTrending, pool, drawn, tier, tiny, hidden, fallback, diversityRelaxed, caption, tmdb, trendMode. Never any titles.
