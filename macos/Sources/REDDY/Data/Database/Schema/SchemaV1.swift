enum SchemaV1 {
    static let sql = """
    CREATE TABLE sources(
        id TEXT PRIMARY KEY, name TEXT NOT NULL, type TEXT NOT NULL, base_url TEXT NOT NULL,
        credential_ref TEXT, epg_url TEXT, enabled INTEGER NOT NULL DEFAULT 1,
        last_sync REAL, sync_status TEXT NOT NULL DEFAULT 'idle',
        created_at REAL NOT NULL, sort_order INTEGER NOT NULL DEFAULT 0);

    CREATE TABLE source_capabilities(
        source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
        live INTEGER NOT NULL DEFAULT 0, movies INTEGER NOT NULL DEFAULT 0,
        series INTEGER NOT NULL DEFAULT 0, epg INTEGER NOT NULL DEFAULT 0,
        output_formats TEXT);

    CREATE TABLE source_sync_state(
        source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE, scope TEXT NOT NULL,
        last_success REAL, last_attempt REAL, etag TEXT, last_modified TEXT,
        item_count INTEGER NOT NULL DEFAULT 0, error TEXT,
        PRIMARY KEY(source_id, scope));

    CREATE TABLE categories(
        id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
        kind TEXT NOT NULL, provider_id TEXT NOT NULL, name TEXT NOT NULL, normalized_name TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0, last_seen_at REAL NOT NULL);
    CREATE INDEX idx_categories_source ON categories(source_id, kind, sort_order);

    CREATE TABLE channels(
        id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
        provider_id TEXT NOT NULL, name TEXT NOT NULL, normalized_name TEXT NOT NULL,
        category_id TEXT, category_name TEXT, logo_url TEXT, epg_id TEXT, language TEXT, country TEXT,
        resolution_hint TEXT, sort_order INTEGER NOT NULL DEFAULT 0, stream_ref TEXT NOT NULL,
        group_key TEXT, is_primary INTEGER NOT NULL DEFAULT 1, last_seen_at REAL NOT NULL);
    CREATE INDEX idx_channels_source ON channels(source_id);
    CREATE INDEX idx_channels_category ON channels(source_id, category_id, sort_order);
    CREATE INDEX idx_channels_epg ON channels(source_id, epg_id);
    CREATE INDEX idx_channels_group ON channels(group_key);
    CREATE INDEX idx_channels_seen ON channels(source_id, last_seen_at);

    CREATE TABLE movies(
        id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
        provider_id TEXT NOT NULL, title TEXT NOT NULL, normalized_title TEXT NOT NULL,
        overview TEXT, poster_url TEXT, backdrop_url TEXT, release_year INTEGER, duration_seconds REAL,
        genre TEXT, rating TEXT, category_id TEXT, category_name TEXT, stream_ref TEXT NOT NULL,
        added_at REAL, detail_fetched_at REAL, created_at REAL NOT NULL, updated_at REAL NOT NULL,
        last_seen_at REAL NOT NULL);
    CREATE INDEX idx_movies_source ON movies(source_id, category_id);
    CREATE INDEX idx_movies_year ON movies(release_year);
    CREATE INDEX idx_movies_added ON movies(added_at);
    CREATE INDEX idx_movies_seen ON movies(source_id, last_seen_at);

    CREATE TABLE series(
        id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
        provider_id TEXT NOT NULL, title TEXT NOT NULL, normalized_title TEXT NOT NULL,
        overview TEXT, poster_url TEXT, backdrop_url TEXT, genre TEXT, release_year INTEGER, rating TEXT,
        category_id TEXT, category_name TEXT, added_at REAL, last_metadata_refresh REAL,
        last_seen_at REAL NOT NULL);
    CREATE INDEX idx_series_source ON series(source_id, category_id);
    CREATE INDEX idx_series_seen ON series(source_id, last_seen_at);

    CREATE TABLE seasons(
        id TEXT PRIMARY KEY, series_id TEXT NOT NULL REFERENCES series(id) ON DELETE CASCADE,
        number INTEGER NOT NULL, name TEXT);
    CREATE INDEX idx_seasons_series ON seasons(series_id, number);

    CREATE TABLE episodes(
        id TEXT PRIMARY KEY, series_id TEXT NOT NULL REFERENCES series(id) ON DELETE CASCADE,
        season_id TEXT, season_number INTEGER NOT NULL, provider_episode_id TEXT NOT NULL,
        episode_number INTEGER NOT NULL, title TEXT NOT NULL, overview TEXT, image_url TEXT,
        duration_seconds REAL, stream_ref TEXT NOT NULL);
    CREATE INDEX idx_episodes_series ON episodes(series_id, season_number, episode_number);

    CREATE TABLE stream_variants(
        channel_id TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
        variant_id TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
        label TEXT NOT NULL, PRIMARY KEY(channel_id, variant_id));

    CREATE TABLE epg_channels(
        source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE, xmltv_id TEXT NOT NULL,
        display_name TEXT, normalized_name TEXT, icon_url TEXT, PRIMARY KEY(source_id, xmltv_id));
    CREATE INDEX idx_epg_channels_name ON epg_channels(source_id, normalized_name);

    CREATE TABLE epg_programs(
        id INTEGER PRIMARY KEY, source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
        xmltv_channel_id TEXT NOT NULL, start_time REAL NOT NULL, end_time REAL NOT NULL,
        title TEXT NOT NULL, subtitle TEXT, description TEXT, category TEXT, image_url TEXT,
        import_id INTEGER NOT NULL DEFAULT 0);
    CREATE INDEX idx_epg_channel_time ON epg_programs(source_id, xmltv_channel_id, start_time, end_time);
    CREATE INDEX idx_epg_end ON epg_programs(source_id, end_time);

    CREATE TABLE epg_state(source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE, import_id INTEGER NOT NULL, updated_at REAL NOT NULL);

    CREATE TABLE epg_channel_mappings(
        channel_id TEXT PRIMARY KEY REFERENCES channels(id) ON DELETE CASCADE,
        source_id TEXT NOT NULL, xmltv_channel_id TEXT NOT NULL, method TEXT NOT NULL,
        confidence REAL NOT NULL DEFAULT 1);
    CREATE INDEX idx_epg_map_xmltv ON epg_channel_mappings(source_id, xmltv_channel_id);

    CREATE TABLE favorites(
        item_id TEXT PRIMARY KEY, kind TEXT NOT NULL, created_at REAL NOT NULL, sort_order INTEGER NOT NULL DEFAULT 0);
    CREATE INDEX idx_favorites_kind ON favorites(kind, sort_order);

    CREATE TABLE watch_history(
        id INTEGER PRIMARY KEY, item_id TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, played_at REAL NOT NULL);
    CREATE INDEX idx_watch_history_time ON watch_history(played_at DESC);

    CREATE TABLE recently_watched(
        item_id TEXT PRIMARY KEY, kind TEXT NOT NULL, last_played REAL NOT NULL, play_count INTEGER NOT NULL DEFAULT 1);
    CREATE INDEX idx_recent_time ON recently_watched(kind, last_played DESC);

    CREATE TABLE watch_progress(
        item_id TEXT PRIMARY KEY, kind TEXT NOT NULL, series_id TEXT, position_seconds REAL NOT NULL,
        duration_seconds REAL NOT NULL, updated_at REAL NOT NULL, completed INTEGER NOT NULL DEFAULT 0);
    CREATE INDEX idx_watch_progress_updated ON watch_progress(updated_at);
    CREATE INDEX idx_watch_progress_series ON watch_progress(series_id);

    CREATE TABLE collections(id TEXT PRIMARY KEY, name TEXT NOT NULL, created_at REAL NOT NULL);
    CREATE TABLE collection_items(
        collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
        item_id TEXT NOT NULL, kind TEXT NOT NULL, sort_order INTEGER NOT NULL DEFAULT 0, added_at REAL NOT NULL,
        PRIMARY KEY(collection_id, item_id));

    CREATE TABLE hidden_items(item_id TEXT PRIMARY KEY, kind TEXT NOT NULL, hidden_at REAL NOT NULL);

    CREATE TABLE metadata_overrides(
        item_id TEXT PRIMARY KEY, display_name TEXT, category_name TEXT, epg_id TEXT);

    CREATE TABLE playback_sessions(
        id INTEGER PRIMARY KEY, item_id TEXT NOT NULL, started_at REAL NOT NULL, ended_at REAL,
        engine TEXT NOT NULL, outcome TEXT, error TEXT);

    CREATE TABLE sync_jobs(
        id INTEGER PRIMARY KEY, source_id TEXT NOT NULL, started_at REAL NOT NULL, finished_at REAL,
        state TEXT NOT NULL, detail TEXT);

    CREATE TABLE search_history(term TEXT PRIMARY KEY, used_at REAL NOT NULL);

    CREATE TABLE search_docs(
        id INTEGER PRIMARY KEY, item_id TEXT NOT NULL UNIQUE, kind TEXT NOT NULL, source_id TEXT NOT NULL,
        title TEXT NOT NULL, normalized TEXT NOT NULL, category TEXT, genre TEXT, language TEXT, source_name TEXT);
    CREATE INDEX idx_search_docs_kind ON search_docs(kind, source_id);

    CREATE VIRTUAL TABLE catalog_fts USING fts5(
        title, normalized, category, genre, language, source_name,
        content='search_docs', content_rowid='id',
        tokenize='unicode61 remove_diacritics 2', prefix='1 2 3');

    CREATE TRIGGER search_docs_ai AFTER INSERT ON search_docs BEGIN
        INSERT INTO catalog_fts(rowid, title, normalized, category, genre, language, source_name)
        VALUES(new.id, new.title, new.normalized, new.category, new.genre, new.language, new.source_name);
    END;
    CREATE TRIGGER search_docs_ad AFTER DELETE ON search_docs BEGIN
        INSERT INTO catalog_fts(catalog_fts, rowid, title, normalized, category, genre, language, source_name)
        VALUES('delete', old.id, old.title, old.normalized, old.category, old.genre, old.language, old.source_name);
    END;
    CREATE TRIGGER search_docs_au AFTER UPDATE ON search_docs BEGIN
        INSERT INTO catalog_fts(catalog_fts, rowid, title, normalized, category, genre, language, source_name)
        VALUES('delete', old.id, old.title, old.normalized, old.category, old.genre, old.language, old.source_name);
        INSERT INTO catalog_fts(rowid, title, normalized, category, genre, language, source_name)
        VALUES(new.id, new.title, new.normalized, new.category, new.genre, new.language, new.source_name);
    END;
    """
}
