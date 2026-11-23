import Foundation

enum SchemaV25 {
    /// The guide hub: one registry of guide sources, per-source channels and programmes, the channel-to-guide map, per-channel overrides, public channel-database enrichment, field provenance and guide diagnostics.
    /// Additive: every existing table (`epg_*`) stays and keeps working; this copies the small ones (channels, mappings) and registers each playlist's guide as `provider:<id>`. Programmes are not copied: readers still use `epg_programs` until a later release moves them.
    /// Guide addresses of providers stay in `sources.epg_url` (never copied here); a user guide address is stored in `guide_sources.url` only when it carries no secret, otherwise only `url_ref` is set.
    static let sql = """
    CREATE TABLE IF NOT EXISTS guide_sources(
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        name TEXT NOT NULL DEFAULT '',
        url_ref TEXT,
        url TEXT,
        enabled INTEGER NOT NULL DEFAULT 1,
        priority INTEGER NOT NULL DEFAULT 10,
        refresh_hours INTEGER NOT NULL DEFAULT 6,
        tz_mode TEXT NOT NULL DEFAULT 'auto',
        tz_default TEXT,
        offset_minutes INTEGER NOT NULL DEFAULT 0,
        last_attempt REAL,
        last_success REAL,
        etag TEXT,
        last_modified TEXT,
        status TEXT NOT NULL DEFAULT 'idle',
        error TEXT,
        channels_count INTEGER NOT NULL DEFAULT 0,
        programmes_count INTEGER NOT NULL DEFAULT 0,
        window_start REAL,
        window_end REAL,
        created_at REAL NOT NULL DEFAULT 0
    );
    INSERT OR IGNORE INTO guide_sources(id, kind, name, enabled, priority, created_at, last_success)
        SELECT 'provider:' || s.id, 'provider', s.name, s.enabled, 10, s.created_at, (SELECT updated_at FROM epg_state e WHERE e.source_id = s.id)
        FROM sources s WHERE s.epg_url IS NOT NULL AND s.epg_url != '';

    CREATE TABLE IF NOT EXISTS guide_channels(
        guide_source_id TEXT NOT NULL,
        xmltv_id TEXT NOT NULL,
        display_name TEXT,
        normalized_name TEXT,
        icon_url TEXT,
        lang TEXT,
        country_hint TEXT,
        PRIMARY KEY(guide_source_id, xmltv_id)
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS idx_guide_channels_name ON guide_channels(guide_source_id, normalized_name);
    INSERT OR IGNORE INTO guide_channels(guide_source_id, xmltv_id, display_name, normalized_name, icon_url)
        SELECT 'provider:' || source_id, xmltv_id, display_name, normalized_name, icon_url FROM epg_channels;

    CREATE TABLE IF NOT EXISTS guide_programmes(
        id INTEGER PRIMARY KEY,
        guide_source_id TEXT NOT NULL,
        xmltv_id TEXT NOT NULL,
        start_time REAL NOT NULL,
        end_time REAL NOT NULL,
        title TEXT NOT NULL,
        subtitle TEXT,
        description TEXT,
        category TEXT,
        image_url TEXT,
        lang TEXT,
        episode_num TEXT,
        content_rating TEXT,
        import_id INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_guide_prog_channel_time ON guide_programmes(guide_source_id, xmltv_id, start_time);
    CREATE INDEX IF NOT EXISTS idx_guide_prog_end ON guide_programmes(guide_source_id, end_time);

    CREATE TABLE IF NOT EXISTS guide_import_state(
        guide_source_id TEXT PRIMARY KEY,
        import_id INTEGER NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS channel_guide_map(
        channel_id TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
        guide_source_id TEXT NOT NULL,
        xmltv_id TEXT NOT NULL,
        method TEXT NOT NULL,
        confidence REAL NOT NULL DEFAULT 1,
        reason TEXT,
        locked INTEGER NOT NULL DEFAULT 0,
        updated_at REAL NOT NULL DEFAULT 0,
        PRIMARY KEY(channel_id, guide_source_id)
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS idx_channel_guide_map_xmltv ON channel_guide_map(guide_source_id, xmltv_id);
    INSERT OR IGNORE INTO channel_guide_map(channel_id, guide_source_id, xmltv_id, method, confidence, locked, updated_at)
        SELECT channel_id, 'provider:' || source_id, xmltv_channel_id, method, confidence, CASE WHEN method = 'user' THEN 1 ELSE 0 END, 0 FROM epg_channel_mappings;

    CREATE TABLE IF NOT EXISTS channel_overrides(
        channel_id TEXT PRIMARY KEY REFERENCES channels(id) ON DELETE CASCADE,
        logo_choice TEXT,
        category_choice TEXT,
        tz_offset_minutes INTEGER,
        guide_off INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS channel_enrichment(
        channel_id TEXT PRIMARY KEY REFERENCES channels(id) ON DELETE CASCADE,
        db_id TEXT,
        logo_url TEXT,
        logo_src TEXT,
        category_key TEXT,
        country TEXT,
        language TEXT,
        tz TEXT,
        matched_by TEXT,
        confidence REAL,
        blocked INTEGER NOT NULL DEFAULT 0,
        fetched_at REAL NOT NULL DEFAULT 0,
        db_version TEXT
    );

    CREATE TABLE IF NOT EXISTS field_provenance(
        channel_id TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
        field TEXT NOT NULL,
        value TEXT,
        source TEXT NOT NULL,
        confidence REAL,
        user_locked INTEGER NOT NULL DEFAULT 0,
        updated_at REAL NOT NULL DEFAULT 0,
        PRIMARY KEY(channel_id, field)
    ) WITHOUT ROWID;

    CREATE TABLE IF NOT EXISTS public_db_cache(
        name TEXT PRIMARY KEY,
        etag TEXT,
        last_modified TEXT,
        bytes INTEGER NOT NULL DEFAULT 0,
        fetched_at REAL NOT NULL DEFAULT 0,
        record_count INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS iptvorg_channel(
        id TEXT PRIMARY KEY,
        name_norm TEXT NOT NULL,
        alt_norms TEXT,
        country TEXT,
        categories TEXT,
        languages TEXT,
        timezones TEXT,
        nsfw INTEGER NOT NULL DEFAULT 0,
        closed INTEGER NOT NULL DEFAULT 0
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS idx_iptvorg_channel_name ON iptvorg_channel(name_norm);
    CREATE TABLE IF NOT EXISTS iptvorg_logo(
        channel TEXT NOT NULL,
        url TEXT NOT NULL,
        width INTEGER,
        height INTEGER,
        format TEXT,
        tags TEXT,
        PRIMARY KEY(channel, url)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS iptvorg_block(
        channel TEXT PRIMARY KEY,
        reason TEXT
    ) WITHOUT ROWID;

    CREATE TABLE IF NOT EXISTS guide_reminders(
        id TEXT PRIMARY KEY,
        channel_id TEXT NOT NULL,
        programme_key TEXT NOT NULL,
        start_time REAL NOT NULL,
        title TEXT NOT NULL,
        lead_s INTEGER NOT NULL DEFAULT 300,
        status TEXT NOT NULL DEFAULT 'scheduled'
    );
    CREATE INDEX IF NOT EXISTS idx_guide_reminders_start ON guide_reminders(start_time);

    CREATE TABLE IF NOT EXISTS guide_diagnostics(
        guide_source_id TEXT PRIMARY KEY,
        last_attempt REAL NOT NULL,
        last_success REAL,
        outcome TEXT NOT NULL,
        http_status INTEGER,
        bytes INTEGER,
        channels INTEGER NOT NULL DEFAULT 0,
        mapped INTEGER NOT NULL DEFAULT 0,
        programmes_seen INTEGER NOT NULL DEFAULT 0,
        programmes_kept INTEGER NOT NULL DEFAULT 0,
        dropped_past INTEGER NOT NULL DEFAULT 0,
        dropped_future INTEGER NOT NULL DEFAULT 0,
        dropped_invalid INTEGER NOT NULL DEFAULT 0,
        file_first_start REAL,
        file_last_stop REAL,
        truncated INTEGER NOT NULL DEFAULT 0,
        error TEXT
    );
    """
}
