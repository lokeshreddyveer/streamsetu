import Foundation

/// Finds episodes that were added to the series a person is watching, so those series can be marked NEW and listed under New Episodes.
///
/// It only looks at series the person has played an episode of, a few at a time, with a pause between them, and never while something is
/// playing: reading episode lists from the provider competes with a stream for the connection (and some providers allow only one at a time).
/// It reads nothing that playback uses and writes only its own table.
final class NewEpisodeService: Sendable {
    private let db: DatabaseManager
    private let catalog: CatalogRepository
    private let history: HistoryService
    private let details: DetailService
    private let busy: @Sendable () async -> Bool

    /// At most this many series are looked at in one pass.
    static let seriesPerPass = 12
    /// A series read within this long ago is not read again.
    static let recheckAfter: TimeInterval = 6 * 3600
    /// A new episode that was never played stops being flagged after this long.
    static let keepFor: TimeInterval = 60 * 86400

    init(db: DatabaseManager, catalog: CatalogRepository, history: HistoryService, details: DetailService, busy: @escaping @Sendable () async -> Bool) {
        self.db = db; self.catalog = catalog; self.history = history; self.details = details; self.busy = busy
    }

    /// The rule: with no episodes stored before there is nothing to compare with, so nothing is "new" (a first read of a series is not news);
    /// otherwise the episodes that were not there before.
    static func newEpisodes(before: Set<String>, after: [Episode]) -> [String] {
        guard !before.isEmpty else { return [] }
        return after.map(\.id).filter { !before.contains($0) }
    }

    /// Looks at the series the person played recently (in one playlist, or all) and records any episode that was not stored before.
    /// Returns how many were found.
    @discardableResult
    func refresh(sourceID: UUID? = nil, now: Date = Date()) async -> Int {
        if await busy() { return 0 }
        prune(now: now)
        let watched = (try? history.recentSeries(limit: Self.seriesPerPass * 2, sourceID: sourceID)) ?? []
        var found = 0
        for series in watched.prefix(Self.seriesPerPass) {
            if Task.isCancelled { break }
            if await busy() { break }
            if let t = series.lastMetadataRefresh, now.timeIntervalSince(t) < Self.recheckAfter { continue }
            let before = Set(((try? catalog.episodes(seriesID: series.id)) ?? []).map(\.id))
            guard let detail = try? await details.series(id: series.id, force: true) else { continue }
            let fresh = Self.newEpisodes(before: before, after: detail.episodes)
            if !fresh.isEmpty { record(seriesID: series.id, episodeIDs: fresh, at: now); found += fresh.count }
            try? await Task.sleep(nanoseconds: 400_000_000)          // one series at a time, with a pause: never a burst of requests
        }
        return found
    }

    func record(seriesID: String, episodeIDs: [String], at date: Date) {
        try? db.write { c in
            for id in episodeIDs { try c.execute("INSERT OR IGNORE INTO new_episodes(episode_id, series_id, discovered_at) VALUES(?,?,?)", [id, seriesID, date]) }
        }
    }

    /// Series that have at least one new episode the person has not played.
    func seriesIDs() -> Set<String> {
        Set((try? db.read { try $0.query("""
            SELECT DISTINCT series_id FROM new_episodes
            WHERE episode_id NOT IN (SELECT item_id FROM watch_progress) AND episode_id NOT IN (SELECT item_id FROM watch_history)
            """) { $0.string(0) } }) ?? [])
    }

    /// The unplayed new episodes of one series, oldest first.
    func episodeIDs(seriesID: String) -> [String] {
        (try? db.read { try $0.query("""
            SELECT episode_id FROM new_episodes WHERE series_id=?
            AND episode_id NOT IN (SELECT item_id FROM watch_progress) AND episode_id NOT IN (SELECT item_id FROM watch_history)
            ORDER BY discovered_at, episode_id
            """, [seriesID]) { $0.string(0) } }) ?? []
    }

    /// Forgets old flags, and flags whose episode is gone from the catalog or has been played.
    func prune(now: Date = Date()) {
        try? db.write { c in
            try c.execute("DELETE FROM new_episodes WHERE discovered_at < ?", [now.addingTimeInterval(-Self.keepFor)])
            try c.execute("DELETE FROM new_episodes WHERE episode_id IN (SELECT item_id FROM watch_progress)")
            try c.execute("DELETE FROM new_episodes WHERE episode_id NOT IN (SELECT id FROM episodes)")
        }
    }
}
