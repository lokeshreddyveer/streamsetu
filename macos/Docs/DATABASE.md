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
- **v7** `metadata_matches`: which movies and series were looked up on the details service (`tmdb_id` NULL = no confident match; retried after 30 days).

- **v8** iCloud sync: a change log filled by triggers, the record of what was synced, and the sync engine's state.
- **v9** `title_details`: what the details service told us about a title (cast, trailers, recommendations), kept so the page opens at once and offline. Nothing from the details service is kept longer than 180 days (see v20).
- **v10** the sync triggers rebuilt with an upsert that an outer statement cannot override.
- **v11** `new_episodes`: episodes that appeared in a series being watched after its episode list was stored.
- **v12** `people` and `people_done`: who is in each title (cast, directors), so a person can be searched for.
- **v13** `downloads`: titles saved on the device to watch offline (the stream address is never stored).
- **v14** `lan_log` and `lan_flag`: the change log used for Wi-Fi sync between devices.
- **v15** the Wi-Fi sync triggers rebuilt as upserts.
- **v16** `profiles`, `profile_rows`, `profile_state`: people sharing one device; the live tables hold the active profile's rows.
- **v17** viewing sessions travel through iCloud (triggers for `playback_sessions`; existing sessions are queued).
- **v18** `catalog_fingerprints`: what was last written for each playlist, so an unchanged provider answer writes nothing.
- **v19** content identity and Smart Mix: `content_identity` (the same title across playlists, languages and qualities shares an `identity_key`; derived, never written to a playlist row), `source_twin` (playlists that mirror each other), `rec_dismissed` ("don't recommend this"; separate from Continue Watching, which it never touches), `smartmix_shown`, `smartmix_state`, `folder_recent`, and the indexes for folder reads. The launch migration builds only the small indexes (about 0.16 s on a 185,000-title library); four expression indexes for the newest and best-rated pools are built in the background after launch (`SchemaV19.ensureQueryIndexes`).
- **v20** `metadata_matches.filled`: which values the details service filled into a movie or series row (and what they were), so the 180-day limit takes back exactly those and never what the playlist provided.
- **v21** `continue_hidden`: "Remove from Continue Watching" writes only this marker; progress, resume position, watched state and history are never touched. Personal data (travels with the profile).
- **v22** `provider_ids`: the details service and IMDb ids the playlist itself lists (an exact match for artwork, no search).
- **v23** `rating_checks`: titles whose the details service rating was looked up once (found or not), so they are not asked about again until the record expires.
- **v24** the metadata hub: `hub_identity` (the id crosswalk, with `miss_until`: a service did not know the title's ids, cleared when new ids arrive) and `metadata_facts` (single facts with source, quality, expiry, `miss_until` and `fail_count`). Purged on expiry, when a folder is locked or hidden, and per service when it is switched off.
- **v25** the guide hub: a registry of guide sources, per-source channels and programmes, the channel-to-guide map, overrides, public channel-database enrichment, field provenance and diagnostics. Additive; the `epg_*` tables keep working.
- **v26** nothing: the number was used by development builds for a feature that was withdrawn before release, and stays taken so the versions are consecutive.
- **v27** removes the tables of a feature that was withdrawn before release (development builds had created them as v26). Nothing else refers to them; a database that never had them is unchanged.

`playback_sessions` keeps the latest 20,000 sessions; the statistics page is computed from it and nothing else.

## Metadata and identity tables: who owns what

Two places hold things learned from the details service and two families hold ids. Each has one job; nothing is stored in both with the same meaning.

| Table | Job | Lifetime |
|---|---|---|
| `title_details` (v9) | The whole the details service details reply for a title (cast, trailers, similar, rating and votes) as one JSON blob, plus person pages (`person:` keys). The title page reads it as it is (`maxAge: .infinity`); it is refreshed when older than `Retention.detailsRefresh`. | `Retention.maxKeep` (180 days); people `Retention.personKeepDays` (30 days) |
| `metadata_facts` (v24) | Single facts from several services (logo, backdrop, translations, next episode), each with its source, quality and expiry, so a worse value never replaces a better one. Written only through `HubStore`. | per source, `HubPolicy.keep` (the episode-data service 7 days, others 180) |
| `provider_ids` (v22) | The details service and IMDb ids the playlist itself lists. Kept as the playlist wrote them. | until the title is removed |
| `hub_identity` (v24) | The one crosswalk every feature reads: the details, episode-data, imdb and schedule ids per title. `ProviderIDStore.save` mirrors the playlist's ids into it in the same transaction; the artwork matcher's queue reads `provider_ids` first, then `hub_identity`. | until purged (`HubStore.purge`) |
| `content_identity` (v19) | A different thing: the derived key that says two playlist rows are the same title (languages and qualities of one film). Not an id from a service. | rebuilt when `IdentityKey.version` changes |
| `metadata_matches` (v7) | The artwork matcher's own result (`tmdb_id`, what it filled, when). | `Retention.maxKeep` |

Purging: `AppContainer` always calls `MetadataMatchService.purgeStored*` (title_details, matches) together with `HubStore.purge` (facts, crosswalk) for folders that become locked, hidden or removed. Every retention number is in `Retention` (Data/Cache/CachePolicy.swift).
Migrations here are additive only; the next free number is noted in the migrator.
