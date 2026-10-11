import Foundation

struct SearchResults: Sendable {
    var channels: [Channel] = []
    var movies: [Movie] = []
    var series: [Series] = []
    var isEmpty: Bool { channels.isEmpty && movies.isEmpty && series.isEmpty }
    var total: Int { channels.count + movies.count + series.count }
}

/// Runs searches off the main thread and hydrates ranked hits into full items.
/// Callers cancel the surrounding Task to drop a stale query; cancellation is checked between stages.
final class SearchService: Sendable {
    let searchRepo: SearchRepository
    let catalog: CatalogRepository

    init(searchRepo: SearchRepository, catalog: CatalogRepository) { self.searchRepo = searchRepo; self.catalog = catalog }

    func search(_ term: String, filters: SearchFilters = SearchFilters(), limit: Int = 120) async throws -> SearchResults {
        try await Task.detached(priority: .userInitiated) { [searchRepo, catalog] in
            let hits = try searchRepo.search(term: term, filters: filters, limit: limit)
            try Task.checkCancellation()
            func ids(_ k: ContentKind) -> [String] { hits.filter { $0.kind == k }.map(\.itemID) }
            var out = SearchResults()
            // keep the repository's ranking when hydrating
            func ordered<T: Identifiable>(_ items: [T], _ ids: [String]) -> [T] where T.ID == String {
                let by = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                return ids.compactMap { by[$0] }
            }
            let c = ids(.channel), m = ids(.movie), s = ids(.series)
            if !c.isEmpty { out.channels = ordered(try catalog.channels(ChannelQuery(collapseVariants: false, includeHidden: true, ids: c)), c) }
            try Task.checkCancellation()
            if !m.isEmpty { out.movies = ordered(try catalog.movies(VODQuery(includeHidden: true, ids: m)), m) }
            if !s.isEmpty { out.series = ordered(try catalog.series(VODQuery(includeHidden: true, ids: s)), s) }
            return out
        }.value
    }

    func commit(_ term: String) { try? searchRepo.recordSearch(term) }
    func recent() -> [String] { (try? searchRepo.recentSearches(limit: 8)) ?? [] }
    func clearHistory() { try? searchRepo.clearSearchHistory() }
}
