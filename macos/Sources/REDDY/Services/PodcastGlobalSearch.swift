import Foundation

// Podcast shows in the app-wide search (the top search box, Cmd+K). Like Music, they appear only once the app connects the search to Podcasts, and never for a Kids
// profile or a locked app: the connection checks `allowed` on every search. The words go to Apple's public podcast directory, the same call the Podcasts search box makes.

enum PodcastGlobalSearch {
    static let limit = 6
    static let minimumCharacters = 2

    typealias Provider = @Sendable (String, Int) async -> [SearchResult]

    private final class Hook: @unchecked Sendable {
        private let lock = NSLock()
        private var fn: Provider?
        func set(_ f: Provider?) { lock.lock(); fn = f; lock.unlock() }
        func get() -> Provider? { lock.lock(); defer { lock.unlock() }; return fn }
    }
    private static let hook = Hook()

    /// Connects the search to the podcast directory. `allowed` is asked at search time (false for Kids or a locked app), so nothing is sent then.
    static func install(service: PodcastService, allowed: @escaping @Sendable @MainActor () -> Bool) {
        hook.set { query, limit in
            guard await allowed() else { return [] }
            let found = (try? await service.search(query, limit: limit)) ?? []
            return found.enumerated().map { i, s in row(s, query: query, position: i) }
        }
    }
    static func uninstall() { hook.set(nil) }
    static func installForTesting(_ f: @escaping Provider) { hook.set(f) }
    static var isInstalled: Bool { hook.get() != nil }

    static func rows(for query: String, limit: Int = limit) async -> [SearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= minimumCharacters, let f = hook.get() else { return [] }
        return Array(await f(q, limit).prefix(limit))
    }

    static func row(_ s: PodcastSubscription, query: String, position: Int) -> SearchResult {
        SearchResult(id: "podcast:" + s.feedURL.absoluteString, kind: .podcast, title: s.title, subtitle: s.author, sourceID: nil, sourceName: "Podcasts",
                     artworkURL: s.artwork?.absoluteString, destination: .podcast(feedURL: s.feedURL, title: s.title, author: s.author, artwork: s.artwork),
                     score: GlobalSearchService.score(title: s.title, query: query, position: position))
    }
}
