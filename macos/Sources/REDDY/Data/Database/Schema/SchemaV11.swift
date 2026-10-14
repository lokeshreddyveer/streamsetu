enum SchemaV11 {
    /// Episodes that appeared in a series the person is watching after its episode list was last stored, and that have not been played.
    /// Whether one was played is worked out when it is read (from the progress and the play log), so playing never has to touch this table.
    static let sql = """
    CREATE TABLE IF NOT EXISTS new_episodes(
        episode_id TEXT PRIMARY KEY, series_id TEXT NOT NULL, discovered_at REAL NOT NULL);
    CREATE INDEX IF NOT EXISTS idx_new_episodes_series ON new_episodes(series_id);
    """
}
