enum SchemaV16 {
    /// People who share one device and one playlist. Each has their own favourites, collections, watch history and resume points. The live tables always hold the active
    /// profile's rows; the rows of the others wait in `profile_rows` (see ProfileService). The first profile, "main", is the one that exists before any are added.
    static let sql = """
    CREATE TABLE IF NOT EXISTS profiles(
        id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL DEFAULT 'adult', pin_salt TEXT, pin_hash TEXT,
        color INTEGER NOT NULL DEFAULT 0, sort_order INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL);
    CREATE TABLE IF NOT EXISTS profile_rows(profile_id TEXT NOT NULL, tbl TEXT NOT NULL, data TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS idx_profile_rows ON profile_rows(profile_id, tbl);
    CREATE TABLE IF NOT EXISTS profile_state(active TEXT NOT NULL);
    INSERT INTO profile_state(active) SELECT 'main' WHERE NOT EXISTS (SELECT 1 FROM profile_state);
    INSERT OR IGNORE INTO profiles(id, name, kind, color, sort_order, created_at) VALUES('main', 'Me', 'adult', 0, 0, 0);
    """
}
