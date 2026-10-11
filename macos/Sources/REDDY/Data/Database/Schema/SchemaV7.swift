enum SchemaV7 {
    /// Remembers which movies and series were looked up for artwork, so a lookup that found nothing isn't repeated on every run.
    /// `tmdb_id` is NULL when no confident match was found.
    static let sql = """
    CREATE TABLE IF NOT EXISTS metadata_matches(
        item_id TEXT PRIMARY KEY, kind TEXT NOT NULL, tmdb_id INTEGER, matched_at REAL NOT NULL);
    """
}
