import Foundation

/// A table whose rows are kept in step across the person's devices (through iCloud). Everything about syncing a table (the
/// database triggers that notice a change, how a row is turned into a record, and how an incoming record is applied) comes from
/// this one description.
struct SyncTable: Sendable {
    let name: String
    /// SQL expressions that identify a row; `{r}` stands for `NEW` / `OLD` / the table. They must be stable text or integers,
    /// never floating point, so the same row has the same identity on every device.
    let keyExprs: [String]
    /// The columns that make up the key when the row is created from an incoming record (parallel to `keyExprs`).
    let keyColumns: [String]
    /// The other columns that travel with the row.
    let values: [String]
    /// An UPDATE only counts as a change when one of these columns is touched (so device-local status columns never sync).
    var watched: [String]?
    /// There is no unique index on the key, so rows are matched by it instead of upserted (the watch log).
    var naturalKey = false

    func key(_ prefix: String) -> String { "json_array(" + keyExprs.map { $0.replacingOccurrences(of: "{r}", with: prefix) }.joined(separator: ", ") + ")" }
    var whereClause: String { keyExprs.enumerated().map { "\($1.replacingOccurrences(of: "{r}.", with: "")) = json_extract(?1, '$[\($0)]')" }.joined(separator: " AND ") }
    var valueObject: String { values.isEmpty ? "'{}'" : "json_object(" + values.map { "'\($0)', \($0)" }.joined(separator: ", ") + ")" }

    static let all: [SyncTable] = [
        SyncTable(name: "sources", keyExprs: ["{r}.id"], keyColumns: ["id"],
                  values: ["name", "type", "base_url", "credential_ref", "epg_url", "enabled", "created_at", "sort_order"]),
        SyncTable(name: "favorites", keyExprs: ["{r}.item_id"], keyColumns: ["item_id"], values: ["kind", "created_at", "sort_order"]),
        SyncTable(name: "collections", keyExprs: ["{r}.id"], keyColumns: ["id"], values: ["name", "created_at"]),
        SyncTable(name: "collection_items", keyExprs: ["{r}.collection_id", "{r}.item_id"], keyColumns: ["collection_id", "item_id"],
                  values: ["kind", "sort_order", "added_at"]),
        SyncTable(name: "watch_progress", keyExprs: ["{r}.item_id"], keyColumns: ["item_id"],
                  values: ["kind", "series_id", "position_seconds", "duration_seconds", "updated_at", "completed"]),
        SyncTable(name: "watch_history", keyExprs: ["{r}.item_id", "CAST({r}.played_at * 1000 AS INTEGER)"], keyColumns: ["item_id", "played_at"],
                  values: ["kind", "title"], naturalKey: true),
        // Viewing sessions behind the Statistics page. Device-wide (not part of a profile); only when and what, never the player used or an error text.
        SyncTable(name: "playback_sessions", keyExprs: ["{r}.item_id", "CAST(ROUND({r}.started_at * 1000) AS INTEGER)"], keyColumns: ["item_id", "started_at"],
                  values: ["ended_at"], watched: ["ended_at"], naturalKey: true),
        SyncTable(name: "recently_watched", keyExprs: ["{r}.item_id"], keyColumns: ["item_id"], values: ["kind", "last_played", "play_count"]),
        SyncTable(name: "hidden_items", keyExprs: ["{r}.item_id"], keyColumns: ["item_id"], values: ["kind", "hidden_at"]),
        SyncTable(name: "metadata_overrides", keyExprs: ["{r}.item_id"], keyColumns: ["item_id"], values: ["display_name", "category_name", "epg_id"]),
        SyncTable(name: "folder_order", keyExprs: ["{r}.category_id"], keyColumns: ["category_id"], values: ["position"]),
        SyncTable(name: "locked_categories", keyExprs: ["{r}.category_id"], keyColumns: ["category_id"], values: []),
    ].map { t in
        var t = t
        if t.name == "sources" { t.watched = ["name", "type", "base_url", "credential_ref", "epg_url", "enabled", "sort_order"] }   // not last_sync / sync_status
        return t
    }

    static func named(_ n: String) -> SyncTable? { all.first { $0.name == n } }

    /// Settings are not a database table; they travel as rows of this pseudo-table.
    static let settingsName = "settings"

    /// Schema v8: the change log, what has been synced, and the triggers that fill the log.
    static var migrationSQL: String {
        var sql = """
        CREATE TABLE IF NOT EXISTS sync_outbox(tbl TEXT NOT NULL, key TEXT NOT NULL, ts REAL NOT NULL, PRIMARY KEY(tbl, key));
        CREATE TABLE IF NOT EXISTS sync_meta(tbl TEXT NOT NULL, key TEXT NOT NULL, modified REAL NOT NULL, deleted INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(tbl, key));
        CREATE TABLE IF NOT EXISTS sync_flags(applying INTEGER NOT NULL);
        INSERT INTO sync_flags(applying) SELECT 0 WHERE NOT EXISTS (SELECT 1 FROM sync_flags);
        CREATE TABLE IF NOT EXISTS sync_state(name TEXT PRIMARY KEY, value BLOB);
        CREATE TABLE IF NOT EXISTS sync_settings_seen(key TEXT PRIMARY KEY, json TEXT NOT NULL);

        """
        let now = "((julianday('now') - 2440587.5) * 86400.0)"
        for t in all {
            let when = "WHEN (SELECT applying FROM sync_flags) = 0"
            let put: (String) -> String = { prefix in "INSERT INTO sync_outbox(tbl, key, ts) VALUES('\(t.name)', \(t.key(prefix)), \(now)) ON CONFLICT(tbl, key) DO UPDATE SET ts = excluded.ts;" }
            sql += "CREATE TRIGGER IF NOT EXISTS sync_\(t.name)_ai AFTER INSERT ON \(t.name) \(when) BEGIN \(put("NEW")) END;\n"
            let of = t.watched.map { " OF " + $0.joined(separator: ", ") } ?? ""
            sql += "CREATE TRIGGER IF NOT EXISTS sync_\(t.name)_au AFTER UPDATE\(of) ON \(t.name) \(when) BEGIN \(put("OLD")) \(put("NEW")) END;\n"
            sql += "CREATE TRIGGER IF NOT EXISTS sync_\(t.name)_ad AFTER DELETE ON \(t.name) \(when) BEGIN \(put("OLD")) END;\n"
        }
        return sql
    }
}
