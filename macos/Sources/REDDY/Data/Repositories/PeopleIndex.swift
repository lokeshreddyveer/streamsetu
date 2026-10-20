import Foundation

/// The people in the library (cast and directors), kept so a name can be searched for. It only ever adds rows of its own and reads the catalog.
struct PeopleIndex: Sendable {
    let db: DatabaseManager

    static func norm(_ name: String) -> String { MetadataNormalizer.normalize(name) }

    /// Replaces what is known about the people in one title, and remembers that the title was looked at.
    func save(itemID: String, kind: ContentKind, sourceID: UUID, names: [String]) throws {
        let source = sourceID.uuidString.lowercased()
        try db.write { c in
            try c.execute("DELETE FROM people WHERE item_id=?", [itemID])
            var seen = Set<String>()
            for name in names.prefix(40) {
                let n = Self.norm(name)
                guard n.count >= 3, seen.insert(n).inserted else { continue }
                try c.execute("INSERT OR IGNORE INTO people(item_id, kind, source_id, name, norm) VALUES(?,?,?,?,?)", [itemID, kind.rawValue, source, name, n])
            }
            try c.execute("INSERT OR REPLACE INTO people_done(item_id, source_id, done_at) VALUES(?,?,?)", [itemID, source, Date()])
        }
    }

    /// Series names that came with a playlist's series list. Each series is saved with the people it came with.
    func saveSeries(_ people: [String: [String]], sourceID: UUID) {
        for (id, names) in people where !names.isEmpty { try? save(itemID: id, kind: .series, sourceID: sourceID, names: names) }
    }

    func markDone(itemID: String, sourceID: UUID) {
        try? db.write { c in try c.execute("INSERT OR REPLACE INTO people_done(item_id, source_id, done_at) VALUES(?,?,?)", [itemID, sourceID.uuidString.lowercased(), Date()]) }
    }

    /// Movies not asked about yet, the best-rated and newest first, from playlists that are switched on.
    func pendingMovies(limit: Int) -> [(id: String, sourceID: UUID)] {
        let sql = """
            SELECT m.id, m.source_id FROM movies m JOIN sources s ON s.id = m.source_id AND s.enabled = 1
            WHERE NOT EXISTS (SELECT 1 FROM people_done d WHERE d.item_id = m.id)
            ORDER BY CAST(COALESCE(m.rating,'0') AS REAL) DESC, m.added_at DESC LIMIT ?
            """
        return (try? db.read { c in try c.query(sql, [limit]) { r in (r.string(0), r.uuid(1)) } })?.compactMap { id, s in s.map { (id, $0) } } ?? []
    }

    func progress() -> (done: Int, total: Int) {
        (try? db.read { c in
            let total = try c.scalarInt("SELECT COUNT(*) FROM movies m JOIN sources s ON s.id = m.source_id AND s.enabled = 1")
            let done = try c.scalarInt("SELECT COUNT(*) FROM movies m JOIN sources s ON s.id = m.source_id AND s.enabled = 1 JOIN people_done d ON d.item_id = m.id")
            return (done, total)
        }) ?? (0, 0)
    }

    /// Titles with a person whose name starts with each word typed ("keanu", "reeves", "keanu re"). Needs at least three letters.
    func hits(term: String, kinds: Set<ContentKind>, sourceID: UUID?, limit: Int) -> [SearchHit] {
        let words = Self.norm(term).split(separator: " ").map(String.init)
        guard words.joined().count >= 3, kinds.contains(.movie) || kinds.contains(.series) else { return [] }
        var sql = """
            SELECT p.item_id, p.kind, p.source_id, COALESCE(m.title, s.title), COALESCE(m.category_name, s.category_name)
            FROM (SELECT DISTINCT item_id, kind, source_id FROM people WHERE 1=1
            """
        var args: [(any SQLConvertible)?] = []
        for w in words { sql += " AND (norm LIKE ? OR norm LIKE ?)"; args.append(w + "%"); args.append("% " + w + "%") }
        sql += """
            ) p JOIN sources src ON src.id = p.source_id AND src.enabled = 1
            LEFT JOIN movies m ON p.kind = 'movie' AND m.id = p.item_id
            LEFT JOIN series s ON p.kind = 'series' AND s.id = p.item_id
            WHERE (m.id IS NOT NULL OR s.id IS NOT NULL) AND p.item_id NOT IN (SELECT item_id FROM hidden_items)
            """
        if let sourceID { sql += " AND p.source_id = ?"; args.append(sourceID.uuidString.lowercased()) }
        sql += " ORDER BY CAST(COALESCE(m.rating, s.rating, '0') AS REAL) DESC LIMIT \(max(1, limit))"
        let found = (try? db.read { c in
            try c.query(sql, args) { r in SearchHit(itemID: r.string(0), kind: ContentKind(rawValue: r.string(1)) ?? .movie, sourceID: r.uuid(2) ?? UUID(), title: r.string(3), category: r.optString(4)) }
        }) ?? []
        return found.filter { kinds.contains($0.kind) }
    }

    /// For a search, which of these titles matched because of somebody in them and not because of their name: "Cast: Mahesh Babu". Titles whose own name has every word are left out.
    func matchNotes(term: String, items: [(id: String, title: String)]) -> [String: String] {
        let words = Self.norm(term).split(separator: " ").map(String.init)
        guard words.joined().count >= 3, !items.isEmpty else { return [:] }
        let needing = items.filter { item in let t = Self.norm(item.title); return !words.allSatisfy { t.contains($0) } }
        guard !needing.isEmpty else { return [:] }
        var out: [String: String] = [:]
        for chunk in stride(from: 0, to: needing.count, by: 80).map({ Array(needing[$0..<min($0 + 80, needing.count)]) }) {
            var sql = "SELECT item_id, name FROM people WHERE item_id IN (" + chunk.map { _ in "?" }.joined(separator: ",") + ")"
            var args: [(any SQLConvertible)?] = chunk.map { $0.id }
            for w in words { sql += " AND (norm LIKE ? OR norm LIKE ?)"; args.append(w + "%"); args.append("% " + w + "%") }
            let rows = (try? db.read { c in try c.query(sql, args) { ($0.string(0), $0.string(1)) } }) ?? []
            for (id, name) in rows where out[id] == nil { out[id] = "Cast: " + name }
        }
        return out
    }

    /// The people known for each of these titles, as written (empty for a title not read yet).
    func names(forItems ids: [String]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 80).map({ Array(ids[$0..<min($0 + 80, ids.count)]) }) {
            let sql = "SELECT item_id, name FROM people WHERE item_id IN (" + chunk.map { _ in "?" }.joined(separator: ",") + ")"
            let rows = (try? db.read { c in try c.query(sql, chunk.map { $0 as (any SQLConvertible)? }) { ($0.string(0), $0.string(1)) } }) ?? []
            for (id, name) in rows { out[id, default: []].append(name) }
        }
        return out
    }
}
