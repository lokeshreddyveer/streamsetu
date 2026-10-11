import Foundation

struct StorageBreakdown: Equatable, Sendable {
    var database: Int64 = 0
    var artworkCache: Int64 = 0
    var temporary: Int64 = 0
    var playlistFiles: Int64 = 0
    var total: Int64 { database + artworkCache + temporary + playlistFiles }
}

struct OptimizeReport: Equatable, Sendable {
    var sizeBefore: Int64
    var sizeAfter: Int64
    var compacted: Bool
    var summary: String {
        let saved = max(0, sizeBefore - sizeAfter)
        return compacted ? "Database optimized and compacted (\(ByteCountFormatter.string(fromByteCount: saved, countStyle: .file)) recovered)." : "Database optimized."
    }
}

struct IntegrityReport: Equatable, Sendable {
    var ok: Bool
    var problems: [String]
    var schemaVersion: Int
    var foreignKeyViolations: Int
    var verifiedAt: Date
}

struct IndexStats: Sendable {
    var channels: Int, movies: Int, series: Int
    var total: Int { channels + movies + series }
    var health: IndexHealthReport
}

enum IndexRebuildPhase: Sendable, Equatable {
    case clearing, channels, movies, series, fullText, done
    var label: String {
        switch self {
        case .clearing: "Clearing the index"
        case .channels: "Indexing channels"
        case .movies: "Indexing movies"
        case .series: "Indexing series"
        case .fullText: "Rebuilding full-text search"
        case .done: "Done"
        }
    }
}

/// Database and index upkeep. Every operation uses supported SQLite maintenance commands and runs on the database's own
/// write queue, so it is serialized with catalog writes. None of them deletes the catalog or the database file.
final class LibraryMaintenanceService: @unchecked Sendable {
    private let db: DatabaseManager
    private let health: IndexHealthMonitor
    private let defaults: UserDefaults
    private static let lastVerifiedKey = "maintenance.lastIntegrityCheck"
    private static let lastOptimizedKey = "maintenance.lastOptimize"
    private static let lastIndexVerifiedKey = "maintenance.lastIndexVerify"

    init(db: DatabaseManager, health: IndexHealthMonitor, defaults: UserDefaults = .standard) {
        self.db = db; self.health = health; self.defaults = defaults
    }

    var lastIntegrityCheck: Date? { defaults.object(forKey: Self.lastVerifiedKey) as? Date }
    var lastOptimize: Date? { defaults.object(forKey: Self.lastOptimizedKey) as? Date }
    var lastIndexVerification: Date? { defaults.object(forKey: Self.lastIndexVerifiedKey) as? Date }

    // MARK: storage

    /// Files REDDY wrote to the temporary directory (downloads that were never cleaned up). Anything touched in the last
    /// ten minutes is left alone, since it may belong to a download in progress.
    static func temporaryFiles(olderThan age: TimeInterval = 600, in dir: URL = FileManager.default.temporaryDirectory) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { return [] }
        return items.filter { $0.lastPathComponent.lowercased().hasPrefix("reddy") }.filter {
            let m = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return Date().timeIntervalSince(m) > age
        }
    }

    func storage(artworkCacheBytes: Int64, temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> StorageBreakdown {
        let s = StorageService.shared
        var temp: Int64 = 0
        for u in Self.temporaryFiles(olderThan: 0, in: temporaryDirectory) { temp += Self.size(of: u) }
        return StorageBreakdown(database: s.databaseSize(), artworkCache: artworkCacheBytes, temporary: temp, playlistFiles: s.directorySize(StorageService.importedPlaylists))
    }

    private static func size(of url: URL) -> Int64 {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return StorageService.shared.directorySize(url) }
        return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    @discardableResult
    func clearTemporaryFiles(in dir: URL = FileManager.default.temporaryDirectory, olderThan age: TimeInterval = 600) -> (files: Int, bytes: Int64) {
        var n = 0, bytes: Int64 = 0
        for u in Self.temporaryFiles(olderThan: age, in: dir) {
            let sz = Self.size(of: u)
            if (try? FileManager.default.removeItem(at: u)) != nil { n += 1; bytes += sz }
        }
        return (n, bytes)
    }

    // MARK: database

    /// Checkpoints the WAL, refreshes the query planner's statistics and, when more than a fifth of the file is free
    /// pages, compacts it. Runs on the write queue, so it waits for any catalog write in progress.
    func optimizeDatabase() throws -> OptimizeReport {
        let before = StorageService.shared.databaseSize()
        let compacted = try db.maintenance { c -> Bool in
            let pages = try c.scalarInt("PRAGMA page_count"), free = try c.scalarInt("PRAGMA freelist_count")
            try c.exec("PRAGMA wal_checkpoint(TRUNCATE)")
            try c.exec("ANALYZE")
            try c.exec("PRAGMA optimize")
            if pages > 0, Double(free) / Double(pages) > 0.2 { try c.exec("VACUUM"); try c.exec("PRAGMA wal_checkpoint(TRUNCATE)"); return true }
            return false
        }
        defaults.set(Date(), forKey: Self.lastOptimizedKey)
        return OptimizeReport(sizeBefore: before, sizeAfter: StorageService.shared.databaseSize(), compacted: compacted)
    }

    /// Full SQLite integrity check plus a foreign-key check. Read-only.
    func verifyDatabase() throws -> IntegrityReport {
        let r = try db.read { c -> IntegrityReport in
            let rows = try c.query("PRAGMA integrity_check") { $0.string(0) }
            let problems = rows == ["ok"] ? [] : Array(rows.prefix(20))
            let fk = try c.query("PRAGMA foreign_key_check") { _ in 1 }.count
            return IntegrityReport(ok: problems.isEmpty && fk == 0, problems: problems, schemaVersion: try c.scalarInt("PRAGMA user_version"), foreignKeyViolations: fk, verifiedAt: Date())
        }
        defaults.set(r.verifiedAt, forKey: Self.lastVerifiedKey)
        return r
    }

    // MARK: search index

    func indexStats() throws -> IndexStats {
        let (c, m, s) = try db.read { c in
            (try c.scalarInt("SELECT COUNT(*) FROM search_docs WHERE kind='channel'"), try c.scalarInt("SELECT COUNT(*) FROM search_docs WHERE kind='movie'"),
             try c.scalarInt("SELECT COUNT(*) FROM search_docs WHERE kind='series'"))
        }
        return IndexStats(channels: c, movies: m, series: s, health: try health.check())
    }

    func verifyIndex() throws -> IndexHealthReport {
        let r = try health.check()
        defaults.set(Date(), forKey: Self.lastIndexVerifiedKey)
        return r
    }

    /// Regenerates every search document from the catalog tables, then rebuilds the full-text index once. The catalog itself
    /// (channels, movies, series, favorites, history) is never touched.
    ///
    /// It is a single transaction: if anything fails or the app quits part-way, the previous index is still there, never half
    /// of a new one. The sync triggers are set aside inside that transaction, because letting them mirror ~100,000 deletes and
    /// inserts one row at a time into the full-text index leaves it inconsistent (SQLite's own integrity check flags it); one
    /// `rebuild` from the finished table is both correct and much faster.
    func rebuildSearchIndex(progress: @Sendable (IndexRebuildPhase) -> Void = { _ in }) throws {
        try db.write { c in
            progress(.clearing)
            let triggers: [String] = try c.query("SELECT sql FROM sqlite_master WHERE type='trigger' AND tbl_name='search_docs' AND sql IS NOT NULL") { $0.string(0) }
            for name in try c.query("SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name='search_docs'", [], { $0.string(0) }) { try c.exec("DROP TRIGGER \"\(name)\"") }
            try c.exec("DELETE FROM search_docs")
            progress(.channels)
            try c.exec("""
                INSERT INTO search_docs(item_id, kind, source_id, title, normalized, category, genre, language, source_name)
                SELECT c.id, 'channel', c.source_id, c.name, c.normalized_name, c.category_name, NULL, COALESCE(c.language, c.country), s.name
                FROM channels c JOIN sources s ON s.id=c.source_id
                """)
            progress(.movies)
            try c.exec("""
                INSERT INTO search_docs(item_id, kind, source_id, title, normalized, category, genre, language, source_name)
                SELECT m.id, 'movie', m.source_id, m.title, m.normalized_title, m.category_name, m.genre, NULL, s.name
                FROM movies m JOIN sources s ON s.id=m.source_id
                """)
            progress(.series)
            try c.exec("""
                INSERT INTO search_docs(item_id, kind, source_id, title, normalized, category, genre, language, source_name)
                SELECT x.id, 'series', x.source_id, x.title, x.normalized_title, x.category_name, x.genre, NULL, s.name
                FROM series x JOIN sources s ON s.id=x.source_id
                """)
            for sql in triggers { try c.exec(sql) }
            progress(.fullText)
            try c.exec("INSERT INTO catalog_fts(catalog_fts) VALUES('rebuild')")
        }
        defaults.set(Date(), forKey: Self.lastIndexVerifiedKey)
        progress(.done)
    }
}
