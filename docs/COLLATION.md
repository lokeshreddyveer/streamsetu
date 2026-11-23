# Sorting and collation

Names a person reads in a sorted list must sort the way their language does: case, accents and width ignored, numbers in order ("Part 2" before "Part 10").

## Apple (macOS and iOS share the database layer)
- Every connection registers `COLLATE SETU_LOCALE` (`Data/Database/SQLite.swift`, `Connection.localeCompare`): `String.compare` with caseInsensitive, diacriticInsensitive, widthInsensitive and numeric options in the device locale.
- Used where lists are short: folders (categories), collections, guide channel names, genres.
- NOT used for movie/series titles and channel names. SQLite's `COLLATE NOCASE` folds ASCII only, but those columns are indexed with NOCASE (`idx_movies_rating2` and friends) and a Swift callback per comparison would make a 66k-200k sort take seconds.
- Planned, additive, needs a schema version: Apple V26 adds `sort_key TEXT` to `movies`, `series`, `channels`, filled when rows are written (and backfilled once in the migration) with the same folding as `localeCompare` (NFKD, remove marks, lower case, zero-padded digit runs), plus an index on `(sort_key, id)`. Queries then `ORDER BY sort_key`. Until then the title sort is ASCII-folded only. Not applied: it touches the importer write paths and the migrator, which other work is changing.

## Android
- `BrowseRepository` sorts names with `COLLATE NOCASE` (ASCII only). Same plan: Room version 17 adds a nullable `sortKey` column to the movie, series and channel tables with a migration that backfills it using `java.text.Normalizer` plus `Collator` rules, populated by the existing normaliser at write time, and `SortField.NAME` orders by it. Not applied yet; needs an exported Room schema JSON and a migration test.

## Backlog: stored sort key (deferred by decision, not applied)
What it gives: movie, series and channel lists sort correctly for every script (accents, case, width, numbers in order, Arabic/Hebrew/Thai/CJK by the device locale) and stay fast on a 200k library, because the order comes from one indexed column instead of a comparison callback per row.
Risk: it touches every write path of the importer and the Xtream, M3U and local-file parsers (a row written without a key sorts first or last); a backfill over 200k rows in the migration takes seconds and must run once, off the main thread, with the old order used until it finishes; a key built with one OS version's ICU rules may order differently after an OS update, so the key must be rebuilt when a stored `sort_key_version` differs from the app's; the same rules must exist on Android (`Normalizer` plus `Collator`) so the two apps agree.
Safe plan:
1. Add the column nullable with no default (Apple V26, Android Room 17): `ALTER TABLE ... ADD COLUMN sort_key TEXT`, and the `sort_key_version` in the existing settings table. No index yet.
2. Write the key wherever a title or channel name is saved (one function, one fixture file of input and expected key shared by Swift and Kotlin, like `name-cleaning.json`).
3. Backfill in the background in batches of a few thousand rows; the queries use `ORDER BY COALESCE(sort_key, title COLLATE NOCASE), id` while any row is still empty.
4. When the backfill is complete, create the index on `(sort_key, id)` and switch the queries to `ORDER BY sort_key, id`.
5. Roll back by ignoring the column; nothing else reads it.
