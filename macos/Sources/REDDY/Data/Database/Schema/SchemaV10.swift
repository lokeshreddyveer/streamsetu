enum SchemaV10 {
    /// The sync triggers wrote to the change log with INSERT OR REPLACE, which an outer upsert (for example a replay bumping a play count) overrides,
    /// so the second play of anything failed. Rebuilt with an upsert that cannot be overridden.
    static var sql: String {
        SyncTable.all.map { t in ["ai", "au", "ad"].map { "DROP TRIGGER IF EXISTS sync_\(t.name)_\($0);" }.joined(separator: "\n") }.joined(separator: "\n") + "\n" + SyncTable.migrationSQL
    }
}
