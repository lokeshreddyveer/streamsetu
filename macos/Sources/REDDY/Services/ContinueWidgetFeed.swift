import Foundation

/// What the Continue Watching widget may show. Built from a history service that reads the always-restricted view of the catalog, so a title in a locked or hidden folder (or with
/// a copy there) is never part of it, whether or not the app is unlocked at that moment. It only reads Continue Watching; the list itself is not changed.
enum ContinueWidgetFeed {
    struct Entry: Equatable, Sendable {
        let title: String
        let subtitle: String
        let progress: Double
        let link: String
    }

    static func entries(history: HistoryService, limit: Int = 6) -> [Entry] {
        let list = (try? history.continueWatching(limit: limit, sourceID: nil)) ?? []
        return list.compactMap { ci -> Entry? in
            let fraction = ci.progress.durationSeconds > 0 ? ci.progress.positionSeconds / ci.progress.durationSeconds : 0
            switch ci.content {
            case .movie(let m):
                guard let link = DeepLink.link(movie: m.title) else { return nil }
                return Entry(title: m.title, subtitle: "Movie", progress: fraction, link: link.absoluteString)
            case .episode(let e, let s):
                guard let link = DeepLink.link(series: s.title) else { return nil }
                return Entry(title: s.title, subtitle: "S\(e.seasonNumber) E\(e.episodeNumber) · \(e.title)", progress: fraction, link: link.absoluteString)
            }
        }
    }
}
