enum SchemaV4 {
    /// A provider category is identified by (source, content type, provider id). The unique index makes that a database rule
    /// instead of a convention, and the stats table records what each sync saw so a missing folder can be traced.
    static let sql = """
    DELETE FROM categories WHERE rowid NOT IN (SELECT MIN(rowid) FROM categories GROUP BY source_id, kind, provider_id);
    CREATE UNIQUE INDEX IF NOT EXISTS idx_categories_identity ON categories(source_id, kind, provider_id);

    CREATE TABLE category_sync_stats(
        source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
        kind TEXT NOT NULL,
        provider_count INTEGER NOT NULL,
        parsed_count INTEGER NOT NULL,
        rejected_count INTEGER NOT NULL,
        rejected_reasons TEXT NOT NULL DEFAULT '',
        inserted INTEGER NOT NULL DEFAULT 0,
        updated INTEGER NOT NULL DEFAULT 0,
        removed INTEGER NOT NULL DEFAULT 0,
        kept_stale INTEGER NOT NULL DEFAULT 0,
        synthesized INTEGER NOT NULL DEFAULT 0,
        note TEXT,
        synced_at REAL NOT NULL,
        PRIMARY KEY(source_id, kind));
    """
}
