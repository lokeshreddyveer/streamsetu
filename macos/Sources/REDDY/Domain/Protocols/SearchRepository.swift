import Foundation

struct SearchFilters: Sendable {
    var kinds: Set<ContentKind> = [.channel, .movie, .series]
    var sourceID: UUID?
    var category: String?
    var language: String?
    var genre: String?
}

struct SearchHit: Identifiable, Hashable, Sendable {
    var id: String { itemID }
    let itemID: String
    let kind: ContentKind
    let sourceID: UUID
    let title: String
    let category: String?
}

protocol SearchRepository: Sendable {
    /// Exact title first, then prefix, then full-text rank.
    func search(term: String, filters: SearchFilters, limit: Int) throws -> [SearchHit]
    func recordSearch(_ term: String) throws
    func recentSearches(limit: Int) throws -> [String]
    func clearSearchHistory() throws
}
