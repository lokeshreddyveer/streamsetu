import Foundation

/// What a reset will delete, counted from the database right now, so the confirmation can name it exactly.
struct DataSummary: Equatable, Sendable {
    var playlists = 0, channels = 0, movies = 0, series = 0
    var favorites = 0, collections = 0, historyEntries = 0, resumePoints = 0, searchTerms = 0

    var removeAllLines: [String] {
        [
            "\(playlists) playlist\(playlists == 1 ? "" : "s") and their saved logins (StreamSetu's own Keychain items only)",
            "\(channels.formatted()) channels, \(movies.formatted()) movies and \(series.formatted()) series downloaded from them",
            "\(favorites) favorite\(favorites == 1 ? "" : "s") and \(collections) collection\(collections == 1 ? "" : "s")",
            "\(historyEntries) history entr\(historyEntries == 1 ? "y" : "ies") and \(resumePoints) resume point\(resumePoints == 1 ? "" : "s")",
            "Search history (\(searchTerms)), hidden items, renamed channels, the artwork cache and the program guide",
        ]
    }
}

/// Targeted resets. Each one does one thing; nothing here touches other applications' data or Keychain items.
final class DataResetService: @unchecked Sendable {
    private let db: DatabaseManager
    private let catalog: CatalogRepository
    private let sources: SourceManager
    private let history: HistoryRepository

    init(db: DatabaseManager, catalog: CatalogRepository, sources: SourceManager, history: HistoryRepository) {
        self.db = db; self.catalog = catalog; self.sources = sources; self.history = history
    }

    func summary() -> DataSummary {
        var s = DataSummary()
        s.playlists = ((try? catalog.sources()) ?? []).count
        let c = (try? catalog.counts(sourceID: nil)) ?? CatalogCounts()
        s.channels = c.channels; s.movies = c.movies; s.series = c.series
        _ = try? db.read { c in
            s.favorites = try c.scalarInt("SELECT COUNT(*) FROM favorites")
            s.collections = try c.scalarInt("SELECT COUNT(*) FROM collections")
            s.historyEntries = try c.scalarInt("SELECT COUNT(*) FROM watch_history")
            s.resumePoints = try c.scalarInt("SELECT COUNT(*) FROM watch_progress")
            s.searchTerms = try c.scalarInt("SELECT COUNT(*) FROM search_history")
        }
        return s
    }

    /// Watch log, "recently watched" and resume points. Favorites and collections stay.
    func clearViewingHistory() throws {
        try history.clearHistory()
        try db.write { try $0.exec("DELETE FROM watch_progress") }
    }

    /// Playlists (with their saved logins), the downloaded catalog, and everything attached to it. Preferences are kept;
    /// reset those separately.
    func removeEverything() throws {
        for s in try catalog.sources() { try sources.remove(s.id) }
        try db.write { c in
            try c.exec("""
                DELETE FROM favorites; DELETE FROM collection_items; DELETE FROM collections; DELETE FROM hidden_items;
                DELETE FROM metadata_overrides; DELETE FROM watch_history; DELETE FROM recently_watched; DELETE FROM watch_progress;
                DELETE FROM search_history; DELETE FROM video_layouts;
                """)
        }
        try db.maintenance { c in try c.exec("PRAGMA wal_checkpoint(TRUNCATE)") }
    }
}
