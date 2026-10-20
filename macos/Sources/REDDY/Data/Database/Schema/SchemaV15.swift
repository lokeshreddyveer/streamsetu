enum SchemaV15 {
    /// Replaces the change-log triggers of version 14. They wrote with `INSERT OR REPLACE`, but SQLite uses the conflict rule of the statement that fired a trigger instead of the
    /// trigger's own, so a row changed by a statement with its own rule (as the iCloud sync does) failed with "UNIQUE constraint failed: lan_log". An upsert in the trigger body is not
    /// overridden that way.
    static var sql: String {
        let now = "CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)"
        var out = ""
        let tables: [(table: String, kind: String, key: String)] = [
            ("favorites", "fav", "{r}.item_id"),
            ("watch_progress", "prog", "{r}.item_id"),
            ("collections", "col", "{r}.id"),
            ("collection_items", "colitem", "{r}.collection_id || char(1) || {r}.item_id"),
        ]
        for t in tables {
            func key(_ row: String) -> String { t.key.replacingOccurrences(of: "{r}", with: row) }
            func put(_ row: String, _ deleted: Int) -> String {
                "INSERT INTO lan_log(kind, key, ts, deleted) VALUES('\(t.kind)', \(key(row)), \(now), \(deleted)) ON CONFLICT(kind, key) DO UPDATE SET ts = excluded.ts, deleted = excluded.deleted;"
            }
            let when = "WHEN (SELECT applying FROM lan_flag) = 0"
            for suffix in ["ai", "au", "ad"] { out += "DROP TRIGGER IF EXISTS lan_\(t.table)_\(suffix);\n" }
            out += "CREATE TRIGGER lan_\(t.table)_ai AFTER INSERT ON \(t.table) \(when) BEGIN \(put("NEW", 0)) END;\n"
            out += "CREATE TRIGGER lan_\(t.table)_au AFTER UPDATE ON \(t.table) \(when) BEGIN \(put("OLD", 1)) \(put("NEW", 0)) END;\n"
            out += "CREATE TRIGGER lan_\(t.table)_ad AFTER DELETE ON \(t.table) \(when) BEGIN \(put("OLD", 1)) END;\n"
        }
        return out
    }
}
