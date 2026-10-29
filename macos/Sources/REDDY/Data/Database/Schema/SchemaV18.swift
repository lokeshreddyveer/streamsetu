enum SchemaV18 {
    /// What was last written for each playlist's channels, movies and series: a fingerprint of everything shown or played (in order), and how many rows that was. A provider that sends
    /// exactly what is already saved then writes nothing, even after a restart.
    static let sql = """
    CREATE TABLE IF NOT EXISTS catalog_fingerprints(
        source_id TEXT NOT NULL, kind TEXT NOT NULL, fingerprint TEXT NOT NULL, version INTEGER NOT NULL, rows INTEGER NOT NULL,
        PRIMARY KEY(source_id, kind));
    """
}
