import Foundation

final class SQLiteSearchRepository: SearchRepository {
    let db: DatabaseManager
    init(db: DatabaseManager) { self.db = db }

    func search(term: String, filters: SearchFilters, limit: Int = 200) throws -> [SearchHit] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = SearchIndexer.ftsQuery(trimmed), !filters.kinds.isEmpty else { return [] }
        let norm = MetadataNormalizer.normalize(trimmed)

        var sql = """
            SELECT d.item_id, d.kind, d.source_id, d.title, d.category
            FROM catalog_fts f JOIN search_docs d ON d.id = f.rowid
            JOIN sources s ON s.id = d.source_id AND s.enabled = 1
            WHERE catalog_fts MATCH ?
            """
        var args: [(any SQLConvertible)?] = [match]
        let kinds = filters.kinds.map(\.rawValue).sorted()
        sql += " AND d.kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))"
        args += kinds.map { $0 as (any SQLConvertible)? }
        if let s = filters.sourceID { sql += " AND d.source_id=?"; args.append(s) }
        if let c = filters.category { sql += " AND d.category=?"; args.append(c) }
        if let l = filters.language { sql += " AND d.language=?"; args.append(l) }
        if let g = filters.genre { sql += " AND d.genre=?"; args.append(g) }
        sql += " AND d.item_id NOT IN (SELECT item_id FROM hidden_items)"
        // exact title, then title prefix, then BM25 relevance (title weighted highest)
        sql += " ORDER BY (d.normalized = ?) DESC, (d.normalized LIKE ? || '%') DESC, bm25(catalog_fts, 10.0, 6.0, 2.0, 1.0, 1.0, 0.5) LIMIT \(max(1, limit))"
        args.append(norm); args.append(norm)

        return try db.read { c in
            try c.query(sql, args) { r in
                SearchHit(itemID: r.string(0), kind: ContentKind(rawValue: r.string(1)) ?? .channel, sourceID: r.uuid(2) ?? UUID(),
                          title: r.string(3), category: r.optString(4))
            }
        }
    }

    func recordSearch(_ term: String) throws {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else { return }
        try db.write { c in
            try c.execute("INSERT OR REPLACE INTO search_history(term, used_at) VALUES(?,?)", [t, Date()])
            try c.execute("DELETE FROM search_history WHERE term NOT IN (SELECT term FROM search_history ORDER BY used_at DESC LIMIT 30)")
        }
    }

    func recentSearches(limit: Int = 10) throws -> [String] {
        try db.read { try $0.query("SELECT term FROM search_history ORDER BY used_at DESC LIMIT ?", [limit]) { $0.string(0) } }
    }

    func clearSearchHistory() throws { try db.write { try $0.execute("DELETE FROM search_history") } }
}
