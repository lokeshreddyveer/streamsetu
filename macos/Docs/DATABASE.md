# Database

SQLite in WAL mode, accessed through a small purpose-built layer (`Data/Database/SQLite.swift`,
`DatabaseManager`): one serialized writer connection and one reader connection, so UI reads are never blocked by a
long import. Location: `~/Library/Application Support/REDDY/Database/reddy.sqlite`
(inside the app container for a sandboxed build). Override with `REDDY_DB` (tests).

Search uses **FTS5**. Migrations are versioned with `PRAGMA user_version` (`DatabaseMigrator`; append only).

## Tables

`sources` `source_capabilities` `source_sync_state` · `categories` `channels` `movies` `series` `seasons` `episodes`
`stream_variants` · `epg_channels` `epg_programs` `epg_state` `epg_channel_mappings` · `favorites` `watch_history`
`recently_watched` `watch_progress` `collections` `collection_items` `hidden_items` `metadata_overrides`
`playback_sessions` `sync_jobs` `search_history` · `search_docs` + `catalog_fts` (FTS5).

## Identity

`id = "<source uuid>|<kind>|<provider id>"`. Xtream uses the provider's stream/series/episode id. M3U uses a hash of
`tvg-id + normalized name + normalized group` (never the URL, which may carry rotating tokens), with a counter for
true collisions. Streams are resolved to URLs at playback time.

## Indexes

- SQL: `(playlist/source, category, order)`, `(source, epg_id)`, `(source, last_seen_at)`, year/added, history/progress by time.
- EPG: `(source, xmltv_channel, start, end)` for per-channel windows, `(source, end, start)` for now/next sweeps.
- Search: `search_docs` is the content table of `catalog_fts` (prefixes 1–3, `unicode61 remove_diacritics 2`).
  Triggers keep FTS in step, and the upsert only writes when a field actually changed — refreshing an unchanged
  catalog touches no index rows.

## Writes

- Catalog commits are one transaction: upsert, delete rows not seen (`last_seen_at`), rebuild variants, update search docs.
  Empty refreshes, or refreshes under 10% of a previous catalog of 50+ items, are rejected.
- The guide is imported under a fresh `import_id`; readers only see the import named in `epg_state`. The switch is a
  single transaction, so a cancelled or failed import leaves the previous guide intact.
- Programs are kept for a 7-day forward window (and 3 hours back); `EPGRepository.purge` trims.

## Health & recovery

`IndexHealthMonitor` runs `quick_check`, the FTS5 integrity check, counts documents against catalog rows and finds
orphans; `repair()` removes orphans and rebuilds the FTS index. Settings → Library shows the result.

## Not stored here

Logins and tokens (Keychain), artwork (disk cache under `~/Library/Caches/REDDY`), preferences (UserDefaults).

## Later migrations

- **v5** `folder_order`: the order the person arranged sidebar folders in.
- **v6** `locked_categories` (folders behind the parental PIN) and `channels.archive_days` (catch-up depth the provider offers).
- **v7** `metadata_matches`: which movies and series were looked up on TMDB (`tmdb_id` NULL = no confident match; retried after 30 days).

`playback_sessions` keeps the latest 20,000 sessions; the statistics page is computed from it and nothing else.
