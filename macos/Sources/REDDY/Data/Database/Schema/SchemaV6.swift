enum SchemaV6 {
    /// Folders locked behind the parental PIN, and whether a live channel offers catch-up (days of archive the provider keeps).
    static let sql = """
    CREATE TABLE IF NOT EXISTS locked_categories(category_id TEXT PRIMARY KEY);
    ALTER TABLE channels ADD COLUMN archive_days INTEGER NOT NULL DEFAULT 0;
    """
}
