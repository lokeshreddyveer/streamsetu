enum SchemaV3 {
    /// Real "recently added" ordering: the time an item was first imported (existing rows start from their last sync).
    static let sql = """
    ALTER TABLE channels ADD COLUMN first_seen_at REAL;
    UPDATE channels SET first_seen_at = last_seen_at;
    CREATE INDEX idx_channels_added ON channels(source_id, first_seen_at DESC);
    ALTER TABLE series ADD COLUMN first_seen_at REAL;
    UPDATE series SET first_seen_at = last_seen_at;
    CREATE INDEX idx_series_added ON series(source_id, first_seen_at DESC);
    CREATE INDEX idx_recently_watched_kind ON recently_watched(kind, last_played DESC);
    """
}
