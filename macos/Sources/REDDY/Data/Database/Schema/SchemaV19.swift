import Foundation

enum SchemaV19 {
    /// Additive only: nothing here alters or rewrites a playlist table, so dropping these tables returns the app to how it behaved before.
    /// `content_identity` is derived data (the same film in two playlists, or in two languages, shares an `identity_key`); `rec_dismissed`
    /// is the marker for "do not recommend this again" and is separate from Continue Watching, which it never touches.
    static let sql = """
    CREATE TABLE IF NOT EXISTS content_identity(
        item_id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
        identity_key TEXT NOT NULL,
        year INTEGER,
        lang TEXT,
        quality_rank INTEGER NOT NULL DEFAULT 2,
        is_cam INTEGER NOT NULL DEFAULT 0,
        folder_key TEXT,
        in_hash INTEGER NOT NULL,
        ident_ver INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS idx_ci_key ON content_identity(kind, identity_key, year);
    CREATE INDEX IF NOT EXISTS idx_ci_source ON content_identity(source_id, kind);
    CREATE INDEX IF NOT EXISTS idx_ci_folder ON content_identity(folder_key);

    CREATE TABLE IF NOT EXISTS source_twin(
        kind TEXT NOT NULL, source_a TEXT NOT NULL, source_b TEXT NOT NULL,
        matched INTEGER NOT NULL, total_a INTEGER NOT NULL, total_b INTEGER NOT NULL, checked_at REAL NOT NULL,
        PRIMARY KEY(kind, source_a, source_b));

    CREATE TABLE IF NOT EXISTS rec_dismissed(
        profile_id TEXT NOT NULL, item_id TEXT NOT NULL, kind TEXT NOT NULL,
        identity_key TEXT NOT NULL, year INTEGER, dismissed_at REAL NOT NULL,
        PRIMARY KEY(profile_id, item_id));
    CREATE INDEX IF NOT EXISTS idx_dismissed_key ON rec_dismissed(profile_id, identity_key);

    CREATE TABLE IF NOT EXISTS smartmix_shown(
        profile_id TEXT NOT NULL, shelf_id TEXT NOT NULL, identity_key TEXT NOT NULL, year INTEGER,
        item_id TEXT NOT NULL, load_seq INTEGER NOT NULL, shown_at REAL NOT NULL,
        PRIMARY KEY(profile_id, shelf_id, identity_key, load_seq));
    CREATE INDEX IF NOT EXISTS idx_shown_load ON smartmix_shown(profile_id, shelf_id, load_seq DESC);
    CREATE INDEX IF NOT EXISTS idx_shown_item ON smartmix_shown(item_id);

    CREATE TABLE IF NOT EXISTS smartmix_state(
        profile_id TEXT NOT NULL, shelf_id TEXT NOT NULL,
        refresh_counter INTEGER NOT NULL DEFAULT 0, load_key TEXT NOT NULL DEFAULT '', load_seq INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(profile_id, shelf_id));

    CREATE TABLE IF NOT EXISTS folder_recent(
        profile_id TEXT NOT NULL, category_id TEXT NOT NULL, last_opened_at REAL NOT NULL, opens INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY(profile_id, category_id));

    """

    /// The indexes that serve the Smart Mix pools and the folder reads (the newest and best-rated expression indexes, and the plain ones on source, folder and date) (newest and best rated, id as the last tiebreak so every platform orders ties the same way). They are the slow part of
    /// this migration on a large library, so none of them is built inside it: `ensureQueryIndexes` builds them on a background connection after launch (the pools work without them, only slower, until they exist).
    static let lazyIndexSQL = """
    CREATE INDEX IF NOT EXISTS idx_movies_src_added ON movies(source_id, added_at DESC);
    CREATE INDEX IF NOT EXISTS idx_movies_src_cat_add ON movies(source_id, category_id, added_at DESC);
    CREATE INDEX IF NOT EXISTS idx_series_src_cat_fs ON series(source_id, category_id, first_seen_at DESC);
    CREATE INDEX IF NOT EXISTS idx_categories_family ON categories(kind, normalized_name);
    DROP INDEX IF EXISTS idx_movies_recent; DROP INDEX IF EXISTS idx_series_recent; DROP INDEX IF EXISTS idx_movies_rating; DROP INDEX IF EXISTS idx_series_rating;
    CREATE INDEX IF NOT EXISTS idx_movies_recent2 ON movies(COALESCE(added_at, created_at, 0) DESC, id);
    CREATE INDEX IF NOT EXISTS idx_series_recent2 ON series(COALESCE(added_at, first_seen_at, 0) DESC, id);
    CREATE INDEX IF NOT EXISTS idx_movies_rating2 ON movies(CAST(COALESCE(NULLIF(rating,''),'0') AS REAL) DESC, title COLLATE NOCASE, id);
    CREATE INDEX IF NOT EXISTS idx_series_rating2 ON series(CAST(COALESCE(NULLIF(rating,''),'0') AS REAL) DESC, title COLLATE NOCASE, id);
    """

    /// Builds them (idempotent). Never call this on the main thread.
    static func ensureQueryIndexes(db: DatabaseManager) {
        // One index per write turn, so a sync waiting for the writer is never kept waiting for all four.
        for stmt in lazyIndexSQL.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !stmt.isEmpty {
            try? db.maintenance { try $0.exec(stmt) }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}

enum SchemaV20 {
    /// What TMDB filled into a playlist row (field -> value), so the 180-day cap can take exactly that back and nothing the playlist itself provided. Additive.
    static let sql = """
    ALTER TABLE metadata_matches ADD COLUMN filled TEXT;
    """
}
