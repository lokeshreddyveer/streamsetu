enum SchemaV12 {
    /// Who is in each movie and series (cast and directors), read from what the playlists offer, so a person can be searched for.
    /// `people_done` remembers which movies were asked about, so the slow background pass can stop and carry on later.
    static let sql = """
    CREATE TABLE IF NOT EXISTS people(
        item_id TEXT NOT NULL, kind TEXT NOT NULL, source_id TEXT NOT NULL, name TEXT NOT NULL, norm TEXT NOT NULL,
        PRIMARY KEY(item_id, norm));
    CREATE INDEX IF NOT EXISTS idx_people_norm ON people(norm);
    CREATE INDEX IF NOT EXISTS idx_people_source ON people(source_id);
    CREATE TABLE IF NOT EXISTS people_done(
        item_id TEXT PRIMARY KEY, source_id TEXT NOT NULL, done_at REAL NOT NULL);
    """
}
