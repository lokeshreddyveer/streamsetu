enum SchemaV13 {
    /// Movies and episodes saved on this device to watch without a connection. The stream address is never stored: it is asked of the playlist when a
    /// download starts. `file_name` is a file in the Downloads folder.
    static let sql = """
    CREATE TABLE IF NOT EXISTS downloads(
        item_id TEXT PRIMARY KEY, kind TEXT NOT NULL, source_id TEXT NOT NULL, series_id TEXT,
        title TEXT NOT NULL, subtitle TEXT, artwork_url TEXT, file_name TEXT,
        state TEXT NOT NULL, bytes_done INTEGER NOT NULL DEFAULT 0, bytes_total INTEGER NOT NULL DEFAULT 0,
        added_at REAL NOT NULL, error TEXT);
    """
}
