enum SchemaV14 {
    /// A small log of when favorites, resume points and collections last changed, kept by triggers, for sync on this network. While a change from another device is
    /// being applied `lan_flag` is set, so that change is not logged as new. (This is separate from the iCloud change queue on purpose: a change that arrived from another
    /// device on this network is still news for iCloud.)
    static var sql: String {
        let now = "CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)"
        var out = """
        CREATE TABLE IF NOT EXISTS lan_log(kind TEXT NOT NULL, key TEXT NOT NULL, ts INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(kind, key));
        CREATE TABLE IF NOT EXISTS lan_flag(applying INTEGER NOT NULL);
        INSERT INTO lan_flag(applying) SELECT 0 WHERE NOT EXISTS (SELECT 1 FROM lan_flag);

        """
        let tables: [(table: String, kind: String, key: String)] = [
            ("favorites", "fav", "{r}.item_id"),
            ("watch_progress", "prog", "{r}.item_id"),
            ("collections", "col", "{r}.id"),
            ("collection_items", "colitem", "{r}.collection_id || char(1) || {r}.item_id"),
        ]
        for t in tables {
            func key(_ row: String) -> String { t.key.replacingOccurrences(of: "{r}", with: row) }
            func put(_ row: String, _ deleted: Int) -> String { "INSERT OR REPLACE INTO lan_log(kind, key, ts, deleted) VALUES('\(t.kind)', \(key(row)), \(now), \(deleted));" }
            let when = "WHEN (SELECT applying FROM lan_flag) = 0"
            out += "CREATE TRIGGER IF NOT EXISTS lan_\(t.table)_ai AFTER INSERT ON \(t.table) \(when) BEGIN \(put("NEW", 0)) END;\n"
            out += "CREATE TRIGGER IF NOT EXISTS lan_\(t.table)_au AFTER UPDATE ON \(t.table) \(when) BEGIN \(put("OLD", 1)) \(put("NEW", 0)) END;\n"
            out += "CREATE TRIGGER IF NOT EXISTS lan_\(t.table)_ad AFTER DELETE ON \(t.table) \(when) BEGIN \(put("OLD", 1)) END;\n"
        }
        return out
    }
}
