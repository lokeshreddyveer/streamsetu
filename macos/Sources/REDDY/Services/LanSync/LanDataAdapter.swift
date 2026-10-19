import Foundation

/// Local item ids ("<source id>|movie|<provider id>") and the shape they take on the wire: the playlist's key, the kind, and the provider's own id.
enum LanIds {
    struct Item: Equatable { let sourceId: String; let kind: String; let provider: String }
    private static let kinds: Set<String> = ["movie", "series", "episode", "channel"]

    static func parse(_ id: String) -> Item? {
        let parts = id.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0].count == 36, kinds.contains(parts[1]), !parts[2].isEmpty else { return nil }
        return Item(sourceId: parts[0].lowercased(), kind: parts[1], provider: parts[2])
    }
    static func local(sourceId: String, kind: String, provider: String) -> String? { kinds.contains(kind) ? "\(sourceId)|\(kind)|\(provider)" : nil }
}

/// Reads favorites, Watch Later, collections and resume points from the database as records for another device, and applies the records that come back. Items are named by the
/// playlist's key (the same on every device that has that playlist), so a playlist this device does not have is ignored and its items are left alone.
final class LanDataAdapter: LanData, @unchecked Sendable {
    private let db: DatabaseManager
    private let changed: @Sendable (Set<String>) -> Void
    static let watchLater = "watch-later"

    init(db: DatabaseManager, changed: @escaping @Sendable (Set<String>) -> Void = { _ in }) { self.db = db; self.changed = changed }

    private struct Sources { var keyOf: [String: String] = [:]; var idOf: [String: String] = [:] }

    private func sources(_ c: Connection) throws -> Sources {
        var s = Sources()
        for row in try c.query("SELECT id, base_url FROM sources WHERE base_url != '' ORDER BY enabled DESC, sort_order", [], { ($0.string(0).lowercased(), $0.string(1)) }) {
            let key = LanSourceKey.of(row.1)
            s.keyOf[row.0] = key
            if s.idOf[key] == nil { s.idOf[key] = row.0 }
        }
        return s
    }

    private func wire(_ s: Sources, _ localId: String) -> [String]? {
        guard let item = LanIds.parse(localId), let key = s.keyOf[item.sourceId] else { return nil }
        return [key, item.kind, item.provider]
    }

    private func local(_ s: Sources, _ key: [String]) -> String? {
        guard key.count >= 3, let id = s.idOf[key[0]] else { return nil }
        return LanIds.local(sourceId: id, kind: key[1], provider: key[2])
    }

    private func ms(_ seconds: Double) -> Int64 { Int64(seconds * 1000) }

    func snapshot() async -> [LanRecord] {
        (try? db.read { c in try self.collect(c) }) ?? []
    }

    private func collect(_ c: Connection) throws -> [LanRecord] {
        let s = try sources(c); var out: [LanRecord] = []
        // favorites
        for r in try c.query("SELECT f.item_id, f.created_at, l.ts, l.deleted FROM favorites f LEFT JOIN lan_log l ON l.kind = 'fav' AND l.key = f.item_id", [], { ($0.string(0), $0.double(1), $0.isNull(2) ? nil : Int64($0.int(2)), $0.int(3)) }) {
            guard let key = wire(s, r.0) else { continue }
            let ts = (r.2 != nil && r.3 == 0) ? r.2! : ms(r.1)
            out.append(LanRecord(kind: "fav", key: key + ["favorites"], ts: ts, value: ["at": .int(ms(r.1))]))
        }
        for r in try c.query("SELECT key, ts FROM lan_log WHERE kind = 'fav' AND deleted = 1", [], { ($0.string(0), Int64($0.int(1))) }) {
            if let key = wire(s, r.0) { out.append(LanRecord(kind: "fav", key: key + ["favorites"], ts: r.1, deleted: true)) }
        }
        // Watch Later is a collection here and a list there
        let later = Self.watchLater
        for r in try c.query("SELECT i.item_id, i.added_at, l.ts, l.deleted FROM collection_items i LEFT JOIN lan_log l ON l.kind = 'colitem' AND l.key = i.collection_id || char(1) || i.item_id WHERE i.collection_id = ?", [later], { ($0.string(0), $0.double(1), $0.isNull(2) ? nil : Int64($0.int(2)), $0.int(3)) }) {
            guard let key = wire(s, r.0) else { continue }
            let ts = (r.2 != nil && r.3 == 0) ? r.2! : ms(r.1)
            out.append(LanRecord(kind: "fav", key: key + ["later"], ts: ts, value: ["at": .int(ms(r.1))]))
        }
        for r in try c.query("SELECT key, ts FROM lan_log WHERE kind = 'colitem' AND deleted = 1 AND key LIKE ? || char(1) || '%'", [later], { ($0.string(0), Int64($0.int(1))) }) {
            let parts = r.0.components(separatedBy: "\u{1}")
            if parts.count == 2, let key = wire(s, parts[1]) { out.append(LanRecord(kind: "fav", key: key + ["later"], ts: r.1, deleted: true)) }
        }
        // resume points
        for r in try c.query("SELECT p.item_id, p.series_id, p.position_seconds, p.duration_seconds, p.updated_at, p.completed, l.ts, l.deleted FROM watch_progress p LEFT JOIN lan_log l ON l.kind = 'prog' AND l.key = p.item_id", [],
                             { ($0.string(0), $0.optString(1), $0.double(2), $0.double(3), $0.double(4), $0.bool(5), $0.isNull(6) ? nil : Int64($0.int(6)), $0.int(7)) }) {
            guard let key = wire(s, r.0) else { continue }
            var value: [String: LanValue] = ["pos": .double(r.2), "dur": .double(r.3), "done": .bool(r.5)]
            if let series = r.1.flatMap({ LanIds.parse($0)?.provider }) { value["series"] = .string(series) }
            out.append(LanRecord(kind: "prog", key: key, ts: (r.6 != nil && r.7 == 0) ? r.6! : ms(r.4), value: value))
        }
        for r in try c.query("SELECT key, ts FROM lan_log WHERE kind = 'prog' AND deleted = 1", [], { ($0.string(0), Int64($0.int(1))) }) {
            if let key = wire(s, r.0) { out.append(LanRecord(kind: "prog", key: key, ts: r.1, deleted: true)) }
        }
        // collections and what is in them (Watch Later is sent as a list above)
        for r in try c.query("SELECT c.id, c.name, c.created_at, l.ts, l.deleted FROM collections c LEFT JOIN lan_log l ON l.kind = 'col' AND l.key = c.id WHERE c.id != ?", [later], { ($0.string(0), $0.string(1), $0.double(2), $0.isNull(3) ? nil : Int64($0.int(3)), $0.int(4)) }) {
            let scope = (try? c.queryOne("SELECT kind FROM collection_items WHERE collection_id = ? LIMIT 1", [r.0]) { $0.string(0) }) ?? "movie"
            out.append(LanRecord(kind: "col", key: [r.0], ts: (r.3 != nil && r.4 == 0) ? r.3! : ms(r.2), value: ["name": .string(r.1), "scope": .string(scope)]))
        }
        for r in try c.query("SELECT key, ts FROM lan_log WHERE kind = 'col' AND deleted = 1", [], { ($0.string(0), Int64($0.int(1))) }) {
            out.append(LanRecord(kind: "col", key: [r.0], ts: r.1, deleted: true))
        }
        for r in try c.query("SELECT i.collection_id, i.item_id, i.added_at, l.ts, l.deleted FROM collection_items i LEFT JOIN lan_log l ON l.kind = 'colitem' AND l.key = i.collection_id || char(1) || i.item_id WHERE i.collection_id != ?", [later],
                             { ($0.string(0), $0.string(1), $0.double(2), $0.isNull(3) ? nil : Int64($0.int(3)), $0.int(4)) }) {
            guard let key = wire(s, r.1) else { continue }
            out.append(LanRecord(kind: "colitem", key: [r.0] + key, ts: (r.3 != nil && r.4 == 0) ? r.3! : ms(r.2), value: ["at": .int(ms(r.2))]))
        }
        for r in try c.query("SELECT key, ts FROM lan_log WHERE kind = 'colitem' AND deleted = 1 AND key NOT LIKE ? || char(1) || '%'", [later], { ($0.string(0), Int64($0.int(1))) }) {
            let parts = r.0.components(separatedBy: "\u{1}")
            if parts.count == 2, let key = wire(s, parts[1]) { out.append(LanRecord(kind: "colitem", key: [parts[0]] + key, ts: r.1, deleted: true)) }
        }
        return out
    }

    func apply(_ records: [LanRecord]) async -> Int {
        let order: [String: Int] = ["col": 0, "fav": 1, "prog": 1, "colitem": 2]
        let sorted = records.sorted { (order[$0.kind] ?? 9, $0.deleted ? 1 : 0) < (order[$1.kind] ?? 9, $1.deleted ? 1 : 0) }
        var applied = 0; var touched = Set<String>()
        do {
            try db.write { c in
                let s = try self.sources(c)
                try c.execute("UPDATE lan_flag SET applying = 1")
                for r in sorted { if try self.applyOne(c, s, r, &touched) { applied += 1 } }
                try c.execute("UPDATE lan_flag SET applying = 0")
            }
        } catch { return 0 }
        if applied > 0 { changed(touched) }
        return applied
    }

    private func localTs(_ c: Connection, _ kind: String, _ logKey: String, natural: String, _ args: [(any SQLConvertible)?]) throws -> Int64? {
        if let logged = try c.queryOne("SELECT ts FROM lan_log WHERE kind = ? AND key = ?", [kind, logKey], { Int64($0.int(0)) }) { return logged }
        return try c.queryOne(natural, args) { Int64($0.double(0) * 1000) }
    }

    private func log(_ c: Connection, _ kind: String, _ key: String, _ ts: Int64, _ deleted: Bool) throws {
        try c.execute("INSERT OR REPLACE INTO lan_log(kind, key, ts, deleted) VALUES(?, ?, ?, ?)", [kind, key, ts, deleted ? 1 : 0])
    }

    private func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    private func applyOne(_ c: Connection, _ s: Sources, _ r: LanRecord, _ touched: inout Set<String>) throws -> Bool {
        let v = r.value
        let later = Self.watchLater
        switch r.kind {
        case "fav":
            guard r.key.count == 4, let itemId = local(s, r.key) else { return false }
            if r.key[3] == "later" {
                let logKey = later + "\u{1}" + itemId
                guard lanShouldApply(localTs: try localTs(c, "colitem", logKey, natural: "SELECT added_at FROM collection_items WHERE collection_id = ? AND item_id = ?", [later, itemId]), remoteTs: r.ts) else { return false }
                if r.deleted { try c.execute("DELETE FROM collection_items WHERE collection_id = ? AND item_id = ?", [later, itemId]) }
                else {
                    try c.execute("INSERT OR IGNORE INTO collections(id, name, created_at) VALUES(?, 'Watch Later', ?)", [later, date(r.ts)])
                    try c.execute("INSERT OR REPLACE INTO collection_items(collection_id, item_id, kind, sort_order, added_at) VALUES(?, ?, ?, 0, ?)", [later, itemId, r.key[1], date(v?["at"]?.integer ?? r.ts)])
                }
                try log(c, "colitem", logKey, r.ts, r.deleted); touched.insert("collection_items"); return true
            }
            guard r.key[3] == "favorites" else { return false }
            guard lanShouldApply(localTs: try localTs(c, "fav", itemId, natural: "SELECT created_at FROM favorites WHERE item_id = ?", [itemId]), remoteTs: r.ts) else { return false }
            if r.deleted { try c.execute("DELETE FROM favorites WHERE item_id = ?", [itemId]) }
            else { try c.execute("INSERT OR REPLACE INTO favorites(item_id, kind, created_at, sort_order) VALUES(?, ?, ?, 0)", [itemId, r.key[1], date(v?["at"]?.integer ?? r.ts)]) }
            try log(c, "fav", itemId, r.ts, r.deleted); touched.insert("favorites"); return true
        case "prog":
            guard r.key.count == 3, let itemId = local(s, r.key) else { return false }
            guard lanShouldApply(localTs: try localTs(c, "prog", itemId, natural: "SELECT updated_at FROM watch_progress WHERE item_id = ?", [itemId]), remoteTs: r.ts) else { return false }
            if r.deleted { try c.execute("DELETE FROM watch_progress WHERE item_id = ?", [itemId]) }
            else {
                let seriesId: String? = v?["series"]?.string.flatMap { provider in s.idOf[r.key[0]].flatMap { sid in LanIds.local(sourceId: sid, kind: "series", provider: provider) } }
                try c.execute("INSERT OR REPLACE INTO watch_progress(item_id, kind, series_id, position_seconds, duration_seconds, updated_at, completed) VALUES(?, ?, ?, ?, ?, ?, ?)",
                              [itemId, r.key[1], seriesId, v?["pos"]?.number ?? 0, v?["dur"]?.number ?? 0, date(r.ts), v?["done"]?.flag ?? false])
            }
            try log(c, "prog", itemId, r.ts, r.deleted); touched.insert("watch_progress"); return true
        case "col":
            guard r.key.count == 1, r.key[0] != later else { return false }
            let id = r.key[0]
            guard lanShouldApply(localTs: try localTs(c, "col", id, natural: "SELECT created_at FROM collections WHERE id = ?", [id]), remoteTs: r.ts) else { return false }
            if r.deleted { try c.execute("DELETE FROM collections WHERE id = ?", [id]); try c.execute("DELETE FROM collection_items WHERE collection_id = ?", [id]) }
            else { try c.execute("INSERT INTO collections(id, name, created_at) VALUES(?, ?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name", [id, v?["name"]?.string ?? "Collection", date(r.ts)]) }
            try log(c, "col", id, r.ts, r.deleted); touched.insert("collections"); return true
        case "colitem":
            guard r.key.count == 4, r.key[0] != later, let itemId = local(s, Array(r.key.dropFirst())) else { return false }
            let collection = r.key[0]; let logKey = collection + "\u{1}" + itemId
            guard lanShouldApply(localTs: try localTs(c, "colitem", logKey, natural: "SELECT added_at FROM collection_items WHERE collection_id = ? AND item_id = ?", [collection, itemId]), remoteTs: r.ts) else { return false }
            if r.deleted { try c.execute("DELETE FROM collection_items WHERE collection_id = ? AND item_id = ?", [collection, itemId]) }
            else {
                try c.execute("INSERT OR IGNORE INTO collections(id, name, created_at) VALUES(?, 'Collection', ?)", [collection, date(r.ts)])
                try c.execute("INSERT OR REPLACE INTO collection_items(collection_id, item_id, kind, sort_order, added_at) VALUES(?, ?, ?, 0, ?)", [collection, itemId, r.key[2], date(v?["at"]?.integer ?? r.ts)])
            }
            try log(c, "colitem", logKey, r.ts, r.deleted); touched.insert("collection_items"); return true
        default: return false
        }
    }
}
