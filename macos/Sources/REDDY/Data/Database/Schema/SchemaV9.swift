enum SchemaV9 {
    /// What TMDB told us about a movie or series (cast, trailers, ...), kept so the page opens instantly and works offline.
    static let sql = """
    CREATE TABLE IF NOT EXISTS title_details(
        item_id TEXT PRIMARY KEY, json TEXT NOT NULL, fetched_at REAL NOT NULL);
    """
}
