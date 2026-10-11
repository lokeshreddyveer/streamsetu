import Foundation

struct IndexHealthReport: Sendable {
    var schemaVersion: Int
    var integrityOK: Bool
    var integrityMessage: String
    var searchDocs: Int
    var catalogItems: Int
    var ftsConsistent: Bool
    var orphanedSearchDocs: Int
    var healthy: Bool { integrityOK && ftsConsistent && orphanedSearchDocs == 0 }
}

/// Checks the database and the search index, and repairs the index when it has drifted.
struct IndexHealthMonitor: Sendable {
    let db: DatabaseManager

    func check() throws -> IndexHealthReport {
        var report = try db.read { c in
            let quick = try c.queryOne("PRAGMA quick_check") { $0.string(0) } ?? "unknown"
            let docs = try c.scalarInt("SELECT COUNT(*) FROM search_docs")
            let items = try c.scalarInt("SELECT (SELECT COUNT(*) FROM channels) + (SELECT COUNT(*) FROM movies) + (SELECT COUNT(*) FROM series)")
            let orphans = try c.scalarInt("""
                SELECT COUNT(*) FROM search_docs d WHERE
                (d.kind='channel' AND d.item_id NOT IN (SELECT id FROM channels)) OR
                (d.kind='movie' AND d.item_id NOT IN (SELECT id FROM movies)) OR
                (d.kind='series' AND d.item_id NOT IN (SELECT id FROM series))
                """)
            return IndexHealthReport(schemaVersion: try c.scalarInt("PRAGMA user_version"), integrityOK: quick == "ok", integrityMessage: quick,
                                     searchDocs: docs, catalogItems: items, ftsConsistent: false,
                                     orphanedSearchDocs: orphans)
        }
        // FTS5's integrity-check raises when the index disagrees with its content table. It runs on the writer
        // connection because it is issued as an INSERT command (it changes nothing).
        var ftsOK = true
        do { try db.write { try $0.exec("INSERT INTO catalog_fts(catalog_fts, rank) VALUES('integrity-check', 1)") } } catch { ftsOK = false }
        report.ftsConsistent = ftsOK && report.searchDocs == report.catalogItems
        return report
    }

    /// Removes orphans and rebuilds the FTS index from `search_docs`.
    func repair() throws {
        try db.write { c in
            try c.exec("""
                DELETE FROM search_docs WHERE
                (kind='channel' AND item_id NOT IN (SELECT id FROM channels)) OR
                (kind='movie' AND item_id NOT IN (SELECT id FROM movies)) OR
                (kind='series' AND item_id NOT IN (SELECT id FROM series));
                INSERT INTO catalog_fts(catalog_fts) VALUES('rebuild');
                """)
        }
    }
}
