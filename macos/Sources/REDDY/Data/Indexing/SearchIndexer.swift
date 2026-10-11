import Foundation

struct SearchDoc: Sendable {
    let itemID: String
    let kind: ContentKind
    let sourceID: UUID
    let title: String
    let normalized: String
    let category: String?
    let genre: String?
    let language: String?
    let sourceName: String
}

/// Keeps `search_docs` (and, through triggers, the FTS5 index) in step with the catalog.
/// Rows are only rewritten when something actually changed, so a refresh of an unchanged catalog touches nothing.
enum SearchIndexer {
    static let upsertSQL = """
    INSERT INTO search_docs(item_id, kind, source_id, title, normalized, category, genre, language, source_name)
    VALUES(?,?,?,?,?,?,?,?,?)
    ON CONFLICT(item_id) DO UPDATE SET
        title=excluded.title, normalized=excluded.normalized, category=excluded.category,
        genre=COALESCE(excluded.genre, search_docs.genre), language=excluded.language, source_name=excluded.source_name
    WHERE search_docs.title IS NOT excluded.title OR search_docs.normalized IS NOT excluded.normalized
       OR search_docs.category IS NOT excluded.category OR search_docs.language IS NOT excluded.language
       OR search_docs.source_name IS NOT excluded.source_name
       OR (excluded.genre IS NOT NULL AND search_docs.genre IS NOT excluded.genre)
    """

    static func upsert(_ docs: [SearchDoc], in c: Connection) throws {
        let st = try c.prepare(upsertSQL)
        for d in docs {
            try st.run([d.itemID, d.kind.rawValue, d.sourceID, d.title, d.normalized, d.category, d.genre, d.language, d.sourceName])
        }
    }

    static func removeStale(kind: ContentKind, table: String, sourceID: UUID, in c: Connection) throws {
        try c.execute("DELETE FROM search_docs WHERE source_id=? AND kind=? AND item_id NOT IN (SELECT id FROM \(table) WHERE source_id=?)",
                      [sourceID, kind.rawValue, sourceID])
    }

    /// "bbc new" -> `"bbc"* "new"*` (every term must match as a word prefix). nil when no usable terms.
    static func ftsQuery(_ input: String) -> String? {
        let terms = MetadataNormalizer.normalize(input).split(separator: " ").map(String.init).filter { !$0.isEmpty }
        // Terms are alphanumeric only after normalization, so quoting is safe against FTS syntax injection.
        return terms.isEmpty ? nil : terms.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    static func rebuildIndex(_ db: DatabaseManager) throws {
        try db.write { try $0.exec("INSERT INTO catalog_fts(catalog_fts) VALUES('rebuild')") }
    }
}
