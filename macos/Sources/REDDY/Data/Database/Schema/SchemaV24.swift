import Foundation

enum SchemaV24 {
    /// The metadata hub (`content_identity` of SchemaV19 is derived, rewritten data and stays untouched): one crosswalk of a title's ids (tmdb, tvdb, imdb, tvmaze; extends `provider_ids` of SchemaV22, which is copied in) and one table of
    /// facts with their source, quality and expiry. Additive: nothing existing is changed. Purged as a whole (expiry, locked folders, switching the hub off).
    static let sql = """
    CREATE TABLE IF NOT EXISTS hub_identity(
        item_id TEXT PRIMARY KEY,
        tmdb_id INTEGER,
        tvdb_id INTEGER,
        imdb_id TEXT,
        tvmaze_id INTEGER,
        kind TEXT,
        resolved_at REAL NOT NULL DEFAULT 0,
        miss_until REAL
    );
    INSERT OR IGNORE INTO hub_identity(item_id, tmdb_id, imdb_id, resolved_at) SELECT item_id, tmdb_id, imdb_id, 0 FROM provider_ids;
    CREATE TABLE IF NOT EXISTS metadata_facts(
        item_id TEXT NOT NULL,
        field TEXT NOT NULL,
        value TEXT,
        source TEXT NOT NULL,
        quality REAL NOT NULL DEFAULT 0,
        fetched_at REAL NOT NULL,
        expires_at REAL NOT NULL,
        miss_until REAL,
        fail_count INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(item_id, field)
    );
    CREATE INDEX IF NOT EXISTS idx_metadata_facts_expiry ON metadata_facts(expires_at);
    """
}
