import Foundation

/// The derived `content_identity` table: written inside the sync's own transaction, backfilled in small batches for rows that have none, and read to group copies of a title.
/// No playlist row, id, address or metadata is ever written by anything here.
struct IdentityStore: Sendable {
    let db: DatabaseManager

    struct Row: Sendable { let id: String; let title: String; let category: String?; let year: Int? }

    // MARK: writing (inside the sync transaction)

    /// Derives and stores identity for the rows that are new or whose title, folder or year changed (one hash compare for every other row), and removes the rows of titles that
    /// left the playlist. Called by the catalog indexer inside the transaction that writes the catalog, so a sync that fails leaves both exactly as they were.
    @discardableResult
    static func apply(rows: [Row], removedIDs: [String], source: UUID, kind: ContentKind, in c: Connection, onlyThese: Bool = false) throws -> IdentityChangeSet {
        var changes = IdentityChangeSet(sourceID: source, kind: kind)
        var existing: [String: (hash: Int64, ver: Int)] = [:]
        if onlyThese {
            // A backfill batch: only the existing rows of these ids are needed, not every row of the playlist (which made a full backfill quadratic).
            for chunk in stride(from: 0, to: rows.count, by: 400).map({ Array(rows[$0..<min($0 + 400, rows.count)]) }) {
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                try c.forEachRow("SELECT item_id, in_hash, ident_ver FROM content_identity WHERE item_id IN (\(marks))", chunk.map { $0.id as (any SQLConvertible)? }) {
                    existing[$0.string(0)] = (Int64($0.int(1)), $0.int(2))
                }
            }
        } else {
            try c.forEachRow("SELECT item_id, in_hash, ident_ver FROM content_identity WHERE source_id=? AND kind=?", [source, kind.rawValue]) {
                existing[$0.string(0)] = (Int64($0.int(1)), $0.int(2))
            }
        }
        let st = try c.prepare("""
            INSERT INTO content_identity(item_id, kind, source_id, identity_key, year, lang, quality_rank, is_cam, folder_key, in_hash, ident_ver)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(item_id) DO UPDATE SET identity_key=excluded.identity_key, year=excluded.year, lang=excluded.lang, quality_rank=excluded.quality_rank,
                is_cam=excluded.is_cam, folder_key=excluded.folder_key, in_hash=excluded.in_hash, ident_ver=excluded.ident_ver
            """)
        for r in rows {
            let hash = IdentityDerive.inputHash(title: r.title, categoryName: r.category, year: r.year)
            if let e = existing[r.id], e.hash == hash, e.ver == IdentityKey.version { continue }
            let d = IdentityDerive.derive(title: r.title, categoryName: r.category, year: r.year, kind: kind)
            try st.run([r.id, kind.rawValue, source, d.key, d.year, d.language, d.qualityRank, d.isCam, d.folderKey, hash, IdentityKey.version])
            if existing[r.id] == nil { changes.added(r.id) } else { changes.changed(r.id) }
        }
        if !removedIDs.isEmpty {
            let del = try c.prepare("DELETE FROM content_identity WHERE item_id=?")
            for id in removedIDs { try del.run([id]); changes.removed(id) }
        }
        return changes
    }

    // MARK: backfill

    /// Titles that have no identity row yet (or an old version), as a share of all titles. Below 99 % the recommendation code does not rely on the table.
    func coverage() throws -> (done: Int, total: Int) {
        try db.read { c in
            let total = try c.scalarInt("SELECT (SELECT COUNT(*) FROM movies) + (SELECT COUNT(*) FROM series)")
            let done = try c.scalarInt("SELECT COUNT(*) FROM content_identity WHERE ident_ver=?", [IdentityKey.version])
            return (done, total)
        }
    }

    /// Derives identity for up to `batch` titles that have none, in one short transaction. Returns how many it did; zero means nothing is left. Safe to stop at any time and to run again.
    @discardableResult
    func backfill(batch: Int = 2000) throws -> Int {
        var done = 0
        for (table, kind) in [("movies", ContentKind.movie), ("series", .series)] {
            let left = batch - done
            if left <= 0 { break }
            let rows: [(Row, UUID)] = try db.read { c in
                try c.query("""
                    SELECT m.id, m.title, m.category_name, m.release_year, m.source_id FROM \(table) m
                    LEFT JOIN content_identity ci ON ci.item_id = m.id
                    WHERE ci.item_id IS NULL OR ci.ident_ver <> ? LIMIT ?
                    """, [IdentityKey.version, left]) { (Row(id: $0.string(0), title: $0.string(1), category: $0.optString(2), year: $0.optInt(3)), $0.uuid(4) ?? UUID()) }
            }
            guard !rows.isEmpty else { continue }
            try db.write { c in
                for (source, group) in Dictionary(grouping: rows, by: { $0.1 }) {
                    try Self.apply(rows: group.map(\.0), removedIDs: [], source: source, kind: kind, in: c, onlyThese: true)
                }
            }
            done += rows.count
        }
        return done
    }

    /// Runs the backfill to the end in batches, giving up the write lock between them. Never call it on the main thread.
    func backfillAll(batch: Int = 2000, pause: TimeInterval = 0.02) {
        while !Task.isCancelled, ((try? backfill(batch: batch)) ?? 0) > 0 { Thread.sleep(forTimeInterval: pause) }
    }

    // MARK: twin playlists

    struct Twin: Equatable, Sendable { let kind: ContentKind; let a: UUID; let b: UUID; let matched: Int; let totalA: Int; let totalB: Int
        var isTwin: Bool { Double(matched) >= 0.9 * Double(max(1, min(totalA, totalB))) } }

    /// How much of each playlist's titles another enabled playlist also has, stored in `source_twin`. Two playlists whose overlap is at least 90 % are twins.
    @discardableResult
    func refreshTwins() throws -> [Twin] {
        // The counting (a correlated lookup per row) runs on a reader, so the writer is held only for the few rows that are stored at the end.
        let out: [Twin] = try db.read { c in
            let sources = try c.query("SELECT id FROM sources WHERE enabled=1 ORDER BY id") { $0.uuid(0) }.compactMap { $0 }
            var out: [Twin] = []
            for kind in [ContentKind.movie, .series] {
                for (i, a) in sources.enumerated() { for b in sources[(i + 1)...] {
                    let totalA = try c.scalarInt("SELECT COUNT(*) FROM content_identity WHERE source_id=? AND kind=?", [a, kind.rawValue])
                    let totalB = try c.scalarInt("SELECT COUNT(*) FROM content_identity WHERE source_id=? AND kind=?", [b, kind.rawValue])
                    guard totalA > 0, totalB > 0 else { continue }
                    let matched = try c.scalarInt("""
                        SELECT COUNT(*) FROM content_identity x WHERE x.source_id=? AND x.kind=? AND EXISTS
                            (SELECT 1 FROM content_identity y WHERE y.kind=x.kind AND y.identity_key=x.identity_key AND y.source_id=? AND (y.year IS x.year))
                        """, [a, kind.rawValue, b])
                    out.append(Twin(kind: kind, a: a, b: b, matched: matched, totalA: totalA, totalB: totalB))
                } }
            }
            return out
        }
        try db.write { c in
            try c.execute("DELETE FROM source_twin")
            let now = Date()
            for t in out {
                try c.execute("INSERT INTO source_twin(kind, source_a, source_b, matched, total_a, total_b, checked_at) VALUES(?,?,?,?,?,?,?)",
                              [t.kind.rawValue, t.a, t.b, t.matched, t.totalA, t.totalB, now])
            }
        }
        return out
    }

    func sourceHealth() throws -> [SourceHealth] {
        try db.read { c in
            try c.query("SELECT id, enabled, sync_status, last_sync, sort_order FROM sources") { r in
                r.uuid(0).map { SourceHealth(id: $0, enabled: r.bool(1), syncStatus: r.string(2), lastSync: r.optDate(3), sortOrder: r.int(4)) }
            }.compactMap { $0 }
        }
    }
}

extension Connection {
    /// Calls `body` for each row of a query without building an array first.
    func forEachRow(_ sql: String, _ args: [(any SQLConvertible)?] = [], _ body: (Row) throws -> Void) throws {
        _ = try query(sql, args) { try body($0) }
    }
}
