enum SchemaV2 {
    /// Per-channel / per-title video layout overrides. The row with item_id '*' is the global default.
    static let sql = """
    CREATE TABLE video_layouts(
        item_id TEXT PRIMARY KEY, layout_json TEXT NOT NULL, updated_at REAL NOT NULL);
    """
}
