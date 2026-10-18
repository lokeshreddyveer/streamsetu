import Foundation

protocol FavoritesRepository: Sendable {
    func isFavorite(_ id: String) throws -> Bool
    func setFavorite(_ id: String, kind: ContentKind, on: Bool) throws
    func favoriteIDs(kind: ContentKind) throws -> [String]
    func reorder(kind: ContentKind, ids: [String]) throws
    /// Puts one favourite first (or last) in its list, leaving the others in the order they were.
    func move(_ id: String, kind: ContentKind, toFront: Bool) throws

    func collections() throws -> [CatalogCollection]
    func createCollection(name: String) throws -> CatalogCollection
    func renameCollection(id: String, name: String) throws
    func deleteCollection(id: String) throws
    func collectionItems(id: String) throws -> [(itemID: String, kind: ContentKind)]
    func add(itemID: String, kind: ContentKind, toCollection id: String) throws
    func remove(itemID: String, fromCollection id: String) throws

    func hide(_ id: String, kind: String) throws
    func unhide(_ id: String) throws
    func hiddenIDs(kind: String?) throws -> [String]

    func setOverride(itemID: String, displayName: String?, categoryName: String?, epgID: String?) throws
    func override(for itemID: String) throws -> (displayName: String?, categoryName: String?, epgID: String?)?
    func clearOverride(itemID: String) throws
    func overrideIDs() throws -> Set<String>
}

struct WatchLogEntry: Hashable, Sendable {
    let itemID: String
    let kind: ContentKind
    let title: String
    let playedAt: Date
}

protocol HistoryRepository: Sendable {
    /// Chronological playback log (newest first).
    func watchLog(limit: Int) throws -> [WatchLogEntry]
    /// Item ids ranked by plays since `since`.
    func mostPlayed(kinds: [ContentKind], since: Date, limit: Int) throws -> [(itemID: String, plays: Int)]
    func recordPlay(itemID: String, kind: ContentKind, title: String) throws
    func recentIDs(kind: ContentKind, limit: Int) throws -> [String]
    func clearHistory() throws
    /// Empties the "recently watched" lists (all, or one type). `sourcePrefix` limits it to one playlist ("<uuid>|").
    func clearRecent(kind: ContentKind?, sourcePrefix: String?) throws
    func removeRecent(itemID: String) throws
    /// Deletes log entries (all, or only those played at or after `since`). The recently watched lists are not touched.
    func clearLog(since: Date?, sourcePrefix: String?) throws
    func removeLogEntry(itemID: String, playedAt: Date) throws
    /// Forgets saved positions, so nothing is offered under Continue Watching.
    func clearResumePoints(sourcePrefix: String?) throws

    func saveProgress(_ p: WatchProgress) throws
    func progress(for itemID: String) throws -> WatchProgress?
    func progress(forSeries seriesID: String) throws -> [WatchProgress]
    func continueWatching(limit: Int) throws -> [WatchProgress]
    func markWatched(itemID: String, kind: ContentKind, seriesID: String?, duration: Double) throws
    func clearProgress(itemID: String) throws

    func beginSession(itemID: String, engine: String) throws -> Int64
    func endSession(id: Int64, outcome: String, error: String?) throws
}
