import Foundation

struct ContinueItem: Identifiable, Sendable {
    enum Content: Sendable { case movie(Movie), episode(Episode, Series) }
    let content: Content
    let progress: WatchProgress
    var id: String { progress.itemID }

    var title: String {
        switch content { case .movie(let m): m.title; case .episode(let e, let s): "\(s.title) · S\(e.seasonNumber)E\(e.episodeNumber)" }
    }
    var artworkURL: String? {
        switch content { case .movie(let m): m.backdropURL ?? m.posterURL; case .episode(let e, let s): e.imageURL ?? s.backdropURL ?? s.posterURL }
    }
}

final class HistoryService: Sendable {
    let repo: HistoryRepository
    let catalog: CatalogRepository

    init(repo: HistoryRepository, catalog: CatalogRepository) { self.repo = repo; self.catalog = catalog }

    func continueWatching(limit: Int = 12, sourceID: UUID? = nil) throws -> [ContinueItem] {
        try repo.continueWatching(limit: limit * 6).compactMap { p -> ContinueItem? in
            switch p.kind {
            case .movie:
                return try catalog.movie(id: p.itemID).flatMap { sourceID == nil || $0.sourceID == sourceID ? ContinueItem(content: .movie($0), progress: p) : nil }
            case .episode:
                guard let e = try catalog.episode(id: p.itemID), let s = try catalog.seriesItem(id: e.seriesID), sourceID == nil || s.sourceID == sourceID else { return nil }
                return ContinueItem(content: .episode(e, s), progress: p)
            default: return nil
            }
        }.prefix(limit).map { $0 }
    }

    func recentChannels(limit: Int = 12, sourceID: UUID? = nil) throws -> [Channel] {
        let ids = try repo.recentIDs(kind: .channel, limit: limit * 4)
        let by = Dictionary(try catalog.channels(ChannelQuery(sourceID: sourceID, collapseVariants: false, ids: ids)).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return Array(ids.compactMap { by[$0] }.prefix(limit))
    }

    func recentMovies(limit: Int = 12, sourceID: UUID? = nil) throws -> [Movie] {
        let ids = try repo.recentIDs(kind: .movie, limit: limit * 4)
        let by = Dictionary(try catalog.movies(VODQuery(sourceID: sourceID, ids: ids)).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return Array(ids.compactMap { by[$0] }.prefix(limit))
    }

    /// Series you have watched an episode of, most recent first.
    func recentSeries(limit: Int = 12, sourceID: UUID? = nil) throws -> [Series] {
        var seen = Set<String>(), out: [Series] = []
        for id in try repo.recentIDs(kind: .episode, limit: limit * 6) {
            guard let e = try catalog.episode(id: id), seen.insert(e.seriesID).inserted,
                  let s = try catalog.seriesItem(id: e.seriesID), sourceID == nil || s.sourceID == sourceID else { continue }
            out.append(s)
            if out.count == limit { break }
        }
        return out
    }

    struct LogItem: Identifiable, Sendable {
        let entry: WatchLogEntry
        var id: String { "\(entry.itemID)|\(entry.playedAt.timeIntervalSince1970)" }
    }

    /// Chronological playback log for the playlist (titles as they were when played).
    func watchLog(limit: Int = 200, sourceID: UUID? = nil) throws -> [LogItem] {
        let prefix = sourceID.map { $0.uuidString.lowercased() + "|" }
        return try repo.watchLog(limit: limit * 3).filter { prefix == nil || $0.itemID.hasPrefix(prefix!) }.prefix(limit).map(LogItem.init)
    }

    /// The episode to offer after `episode`: the next one in the same season, else the first of the next season.
    func nextEpisode(after episode: Episode) throws -> Episode? {
        let all = try catalog.episodes(seriesID: episode.seriesID)
        guard let i = all.firstIndex(where: { $0.id == episode.id }), i + 1 < all.count else { return nil }
        return all[i + 1]
    }

    /// "Play next episode" target for a series: resume an unfinished episode, else the first unwatched one.
    func resumeTarget(seriesID: String) throws -> Episode? {
        let eps = try catalog.episodes(seriesID: seriesID)
        let prog = Dictionary(try repo.progress(forSeries: seriesID).map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })
        if let inProgress = eps.last(where: { (prog[$0.id]?.completed == false) && (prog[$0.id]?.positionSeconds ?? 0) > 30 }) { return inProgress }
        if let lastDone = eps.lastIndex(where: { prog[$0.id]?.completed == true }) { return lastDone + 1 < eps.count ? eps[lastDone + 1] : eps.last }
        return eps.first
    }
}
