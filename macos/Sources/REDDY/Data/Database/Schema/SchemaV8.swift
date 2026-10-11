enum SchemaV8 {
    /// iCloud sync: a change log filled by triggers, the record of what was synced, and engine state. See `SyncTable`.
    static var sql: String { SyncTable.migrationSQL }
}
