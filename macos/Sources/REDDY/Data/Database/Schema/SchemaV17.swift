enum SchemaV17 {
    /// Viewing sessions travel through iCloud like the other tables, so the Statistics page counts every device. The triggers for the new table are made here (the ones that exist are left
    /// alone), and the sessions already on this Mac are queued to be sent the next time sync runs.
    static var sql: String {
        SyncTable.migrationSQL + """

        INSERT OR IGNORE INTO sync_outbox(tbl, key, ts)
        SELECT 'playback_sessions', json_array(item_id, CAST(ROUND(started_at * 1000) AS INTEGER)), ((julianday('now') - 2440587.5) * 86400.0)
        FROM playback_sessions WHERE ended_at IS NOT NULL AND EXISTS (SELECT 1 FROM sync_state WHERE name = 'ck-engine');
        """
    }
}
