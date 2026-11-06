import Foundation
import CryptoKit

/// One row on its way to or from iCloud. Every synced table travels as the same kind of record, so there is one record type in
/// CloudKit however many tables are synced.
struct SyncRow: Sendable, Equatable {
    var table: String
    /// JSON array identifying the row (see `SyncTable.keyExprs`).
    var key: String
    /// JSON object of the row's other columns; nil when the row was deleted.
    var values: String?
    var modified: Double
    var deleted: Bool { values == nil }

    var recordName: String { Self.recordName(table: table, key: key) }
    static func recordName(table: String, key: String) -> String {
        table + "-" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The part of the settings that syncs: stored in UserDefaults, not in the database.
protocol SyncSettingsStore: AnyObject, Sendable {
    /// JSON for the setting, or nil when it isn't set.
    func json(forKey key: String) -> String?
    /// Stores (or clears, for nil) a setting that arrived from another device. Unknown keys and odd values are ignored.
    func apply(json: String?, forKey key: String)
    /// Keys whose value is not what was last synced.
    func changedKeys() -> [String]
    func markSeen(key: String)
}

struct SyncApplyResult: Equatable, Sendable {
    var applied = 0
    var skipped = 0
    /// Rows that could not be applied (kept aside and tried again later, never dropped).
    var failed = 0
    var tables: Set<String> = []
    var newSources: [String] = []
    var removedSources: [String] = []
}

/// Finds out what changed here, turns it into rows to send, and merges rows that arrive. No networking: the CloudKit side only
/// moves rows to and from this. Conflicts are settled per row, the later change wins.
final class SyncCore: @unchecked Sendable {
    let db: DatabaseManager
    var settings: SyncSettingsStore?
    private static let nowSQL = "((julianday('now') - 2440587.5) * 86400.0)"

    init(db: DatabaseManager, settings: SyncSettingsStore? = nil) { self.db = db; self.settings = settings }

    struct Pending: Hashable, Sendable { let table: String; let key: String; let ts: Double }

    // MARK: sending

    /// Notices changed settings and queues them like any other change.
    func detectSettingsChanges() throws {
        guard let settings else { return }
        let keys = settings.changedKeys()
        guard !keys.isEmpty else { return }
        try db.write { c in
            for k in keys {
                let key = try Self.jsonArray([k])
                try c.execute("INSERT OR REPLACE INTO sync_outbox(tbl, key, ts) VALUES(?, ?, \(Self.nowSQL))", [SyncTable.settingsName, key])
            }
        }
        keys.forEach { settings.markSeen(key: $0) }
    }

    /// Queues everything that has never been synced, for the first time sync is switched on.
    ///
    /// A change keeps the time it was really made at. The database already logged every change in the outbox with its own time, whether sync was on or not, and those entries are kept
    /// (they used to be overwritten with "now", so a device switched on later claimed that all its old rows were the newest, replaced newer data from other devices and brought deleted rows back).
    /// A row the log never saw (it is older than the log) is queued with the time stored in the row itself, or with 0 ("age unknown") when the table has none, which
    /// any change made anywhere beats; such a row is still sent when no other device has one like it.
    func enqueueEverything() throws {
        try db.write { c in
            for t in SyncTable.all {
                let stamp = t.timeColumn.map { "COALESCE(\($0), 0)" } ?? "0"
                try c.execute("""
                    INSERT OR IGNORE INTO sync_outbox(tbl, key, ts)
                    SELECT '\(t.name)', \(t.key(t.name)), \(stamp) FROM \(t.name)
                    WHERE NOT EXISTS (SELECT 1 FROM sync_meta m WHERE m.tbl = '\(t.name)' AND m.key = \(t.key(t.name)))
                    """)
            }
        }
        if let settings {
            for k in settings.changedKeys() {
                try db.write { c in try c.execute("INSERT OR IGNORE INTO sync_outbox(tbl, key, ts) VALUES(?, ?, 0)", [SyncTable.settingsName, try Self.jsonArray([k])]) }
                settings.markSeen(key: k)
            }
        }
    }

    func pending(limit: Int = 400) throws -> [Pending] {
        try db.read { c in try c.query("SELECT tbl, key, ts FROM sync_outbox ORDER BY ts LIMIT ?", [limit]) { Pending(table: $0.string(0), key: $0.string(1), ts: $0.double(2)) } }
    }

    func pendingCount() -> Int { (try? db.read { try $0.scalarInt("SELECT COUNT(*) FROM sync_outbox") }) ?? 0 }

    /// Rows from other devices that could not be applied here (a record from a newer version of the app, a damaged one). They are kept, not dropped, and tried again with every later batch.
    func quarantinedCount() -> Int { (try? db.read { try $0.scalarInt("SELECT COUNT(*) FROM sync_quarantine") }) ?? 0 }

    /// The rows to send for these changes, read from the current state of the database. A change whose row no longer exists
    /// becomes a deletion.
    func rows(for pending: [Pending]) throws -> [SyncRow] {
        try db.read { c in
            try pending.map { p in
                if p.table == SyncTable.settingsName {
                    let k = (try? Self.firstString(p.key)) ?? ""
                    return SyncRow(table: p.table, key: p.key, values: self.settings?.json(forKey: k), modified: p.ts)
                }
                guard let t = SyncTable.named(p.table) else { return SyncRow(table: p.table, key: p.key, values: nil, modified: p.ts) }
                let values = try c.queryOne("SELECT \(t.valueObject) FROM \(t.name) WHERE \(t.whereClause)", [p.key]) { $0.string(0) }
                return SyncRow(table: p.table, key: p.key, values: values, modified: p.ts)
            }
        }
    }

    /// Records that these were delivered. A change made again while the send was in flight stays queued.
    func markPushed(_ rows: [SyncRow]) throws {
        try db.write { c in
            for r in rows {
                try c.execute("INSERT OR REPLACE INTO sync_meta(tbl, key, modified, deleted) VALUES(?, ?, ?, ?)", [r.table, r.key, r.modified, r.deleted ? 1 : 0])
                try c.execute("DELETE FROM sync_outbox WHERE tbl = ? AND key = ? AND ts <= ?", [r.table, r.key, r.modified])
            }
        }
    }

    // MARK: receiving

    /// Merges rows from another device. A row older than what is here (or than a change waiting to be sent) is ignored.
    ///
    /// Every row is applied on its own: one that cannot be (a record from a newer version of the app, a damaged one) is kept aside in `sync_quarantine` and tried again with the next batch, and
    /// the rows around it are applied as usual. Before, one bad row made the whole batch fail; the failure was not reported, the batch was never fetched again, and everything in it was lost.
    @discardableResult
    func apply(_ incoming: [SyncRow]) throws -> SyncApplyResult {
        var result = SyncApplyResult()
        // rows that could not be applied earlier get another try, unless a newer version of the same row has arrived in this batch
        let heldAgain = (try? heldRows(excluding: incoming)) ?? []
        if incoming.isEmpty && heldAgain.isEmpty { return result }
        // parents before children, so a collection exists before the things in it
        let order = Dictionary(uniqueKeysWithValues: (SyncTable.all.map(\.name) + [SyncTable.settingsName]).enumerated().map { ($1, $0) })
        let rows = (incoming + heldAgain).sorted { (order[$0.table] ?? 99, $0.deleted ? 1 : 0) < (order[$1.table] ?? 99, $1.deleted ? 1 : 0) }
        var settingsToApply: [(String, String?)] = []
        try db.write { c in
            try c.execute("CREATE TABLE IF NOT EXISTS sync_quarantine(tbl TEXT NOT NULL, key TEXT NOT NULL, vals TEXT, modified REAL NOT NULL, reason TEXT, PRIMARY KEY(tbl, key))")
            try c.execute("UPDATE sync_flags SET applying = 1")
            for r in rows {
                let meta = try c.queryOne("SELECT modified FROM sync_meta WHERE tbl = ? AND key = ?", [r.table, r.key]) { $0.double(0) }
                let queued = try c.queryOne("SELECT ts FROM sync_outbox WHERE tbl = ? AND key = ?", [r.table, r.key]) { $0.double(0) }
                let here = max(meta ?? -.infinity, queued ?? -.infinity)
                // The later change wins. Two rows of unknown age (0) that have never been exchanged: the one already in the zone wins, so the devices end up equal instead of each keeping its own.
                let theirsWins = r.modified > here || (r.modified == here && here == 0 && meta == nil)
                guard theirsWins else {
                    try c.execute("DELETE FROM sync_quarantine WHERE tbl = ? AND key = ?", [r.table, r.key])
                    result.skipped += 1; continue
                }
                let before = result
                var setting: (String, String?)?
                try c.execute("SAVEPOINT apply_row")
                do {
                    if r.table == SyncTable.settingsName {
                        setting = (try Self.firstString(r.key), r.values)
                    } else if let t = SyncTable.named(r.table) {
                        try Self.write(r, to: t, c, &result)
                    } else { try c.execute("RELEASE apply_row"); result.skipped += 1; continue }
                    try c.execute("INSERT OR REPLACE INTO sync_meta(tbl, key, modified, deleted) VALUES(?, ?, ?, ?)", [r.table, r.key, r.modified, r.deleted ? 1 : 0])
                    try c.execute("DELETE FROM sync_outbox WHERE tbl = ? AND key = ?", [r.table, r.key])
                    try c.execute("DELETE FROM sync_quarantine WHERE tbl = ? AND key = ?", [r.table, r.key])
                    try c.execute("RELEASE apply_row")
                    if let setting { settingsToApply.append(setting) }
                    result.applied += 1; result.tables.insert(r.table)
                } catch {
                    result = before                                         // what this row had noted (a new source, say) did not happen
                    try c.execute("ROLLBACK TO apply_row"); try c.execute("RELEASE apply_row")
                    try Self.hold(r, reason: String(describing: error).prefix(200), c)
                    result.failed += 1
                }
            }
            try c.execute("UPDATE sync_flags SET applying = 0")
        }
        for (k, json) in settingsToApply { settings?.apply(json: json, forKey: k); settings?.markSeen(key: k) }
        return result
    }

    /// For a batch that failed as a whole (the database could not be written at all): everything in it is kept aside, so it is not lost, and goes through `apply` again with the next batch.
    func holdForRetry(_ rows: [SyncRow], reason: String) {
        try? db.write { c in
            try c.execute("CREATE TABLE IF NOT EXISTS sync_quarantine(tbl TEXT NOT NULL, key TEXT NOT NULL, vals TEXT, modified REAL NOT NULL, reason TEXT, PRIMARY KEY(tbl, key))")
            for r in rows { try Self.hold(r, reason: reason.prefix(200), c) }
        }
    }

    private static let quarantineLimit = 5_000

    private static func hold(_ r: SyncRow, reason: Substring, _ c: Connection) throws {
        let held = try c.scalarInt("SELECT COUNT(*) FROM sync_quarantine")
        let known = try c.scalarInt("SELECT COUNT(*) FROM sync_quarantine WHERE tbl = ? AND key = ?", [r.table, r.key]) > 0
        guard held < quarantineLimit || known else { return }                  // bounded: a flood of unusable rows must not fill the database
        try c.execute("INSERT OR REPLACE INTO sync_quarantine(tbl, key, vals, modified, reason) VALUES(?, ?, ?, ?, ?)", [r.table, r.key, r.values, r.modified, String(reason)])
    }

    private func heldRows(excluding incoming: [SyncRow]) throws -> [SyncRow] {
        let skip = Set(incoming.map { $0.table + "\u{1}" + $0.key })
        return try db.read { c in
            try c.query("SELECT tbl, key, vals, modified FROM sync_quarantine ORDER BY modified LIMIT 500") { SyncRow(table: $0.string(0), key: $0.string(1), values: $0.optString(2), modified: $0.double(3)) }
        }.filter { !skip.contains($0.table + "\u{1}" + $0.key) }
    }

    private static func write(_ r: SyncRow, to t: SyncTable, _ c: Connection, _ result: inout SyncApplyResult) throws {
        let first = (try? firstString(r.key)) ?? ""
        if t.name == "sources" {
            let existed = try c.scalarInt("SELECT COUNT(*) FROM sources WHERE id = ?", [first]) > 0
            if r.deleted { if existed { result.removedSources.append(first) } } else if !existed { result.newSources.append(first) }
        }
        guard let values = r.values else {
            try c.execute("DELETE FROM \(t.name) WHERE \(t.whereClause)", [r.key])
            return
        }
        let keyParams = t.keyColumns.indices.map { "json_extract(?1, '$[\($0)]')" }
        let valueParams = t.values.map { "json_extract(?2, '$.\($0)')" }
        if t.name == "playback_sessions" {      // a session from another device: added once, and its end filled in when it arrives later
            try c.execute("""
                INSERT INTO playback_sessions(item_id, started_at, ended_at, engine, outcome)
                SELECT json_extract(?1, '$[0]'), json_extract(?1, '$[1]') / 1000.0, json_extract(?2, '$.ended_at'), 'other device', NULL
                WHERE NOT EXISTS (SELECT 1 FROM playback_sessions WHERE \(t.whereClause))
                """, [r.key, values])
            try c.execute("UPDATE playback_sessions SET ended_at = json_extract(?2, '$.ended_at') WHERE \(t.whereClause) AND ended_at IS NULL AND json_extract(?2, '$.ended_at') IS NOT NULL", [r.key, values])
            return
        }
        if t.naturalKey {            // the watch log: add it unless this play is already there
            try c.execute("""
                INSERT INTO watch_history(item_id, played_at, kind, title)
                SELECT json_extract(?1, '$[0]'), json_extract(?1, '$[1]') / 1000.0, json_extract(?2, '$.kind'), json_extract(?2, '$.title')
                WHERE NOT EXISTS (SELECT 1 FROM watch_history WHERE \(t.whereClause))
                """, [r.key, values])
            return
        }
        if t.name == "collection_items" {   // the collection may not have arrived yet: keep a placeholder, its own row names it later
            try c.execute("INSERT OR IGNORE INTO collections(id, name, created_at) VALUES(json_extract(?1, '$[0]'), 'Collection', \(nowSQL))", [r.key])
        }
        let columns = (t.keyColumns + t.values).joined(separator: ", ")
        let params = (keyParams + valueParams).joined(separator: ", ")
        if t.values.isEmpty {
            try c.execute("INSERT OR IGNORE INTO \(t.name)(\(columns)) VALUES(\(params))", [r.key, values])
        } else {
            let update = t.values.map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
            try c.execute("INSERT INTO \(t.name)(\(columns)) VALUES(\(params)) ON CONFLICT(\(t.keyColumns.joined(separator: ", "))) DO UPDATE SET \(update)", [r.key, values])
        }
        if t.name == "sources" { try c.execute("INSERT OR IGNORE INTO source_capabilities(source_id) VALUES(?)", [first]) }
    }

    // MARK: helpers

    static func jsonArray(_ items: [String]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: items, options: []), as: UTF8.self)
    }
    static func firstString(_ json: String) throws -> String {
        guard let a = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any], let s = a.first as? String else { throw CocoaError(.coderInvalidValue) }
        return s
    }
}
