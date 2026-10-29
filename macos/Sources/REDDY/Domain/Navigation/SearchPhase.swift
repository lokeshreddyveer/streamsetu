import Foundation

/// Where a search is: nothing typed, looking, showing results, nothing found, or could not be completed. They are different things, and the screen says which one it is:
/// a failure is never shown as "No results", and the results already on screen stay while the next ones load or if a search fails.
enum SearchPhase: Equatable, Sendable {
    case idle, loading, results, empty, failed

    /// What to show when a query starts being looked up.
    static func begin(query: String) -> SearchPhase { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .idle : .loading }
    /// What to show once a lookup has finished without error.
    static func finish(_ found: GlobalSearchResults) -> SearchPhase { found.isEmpty ? .empty : .results }
}

extension GlobalSearchResults {
    /// The result whose title is exactly what was typed (ignoring case, accents and spacing), which goes first. Channels, movies and series are preferred over the rest, and the
    /// first of equals wins.
    func exactMatch(for query: String) -> SearchResult? {
        func key(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let q = key(query)
        guard !q.isEmpty else { return nil }
        let order: [SearchResultKind] = [.movie, .series, .channel, .episode, .programme, .collection, .folder]
        for kind in order { if let hit = byKind[kind]?.first(where: { key($0.title) == q }) { return hit } }
        return nil
    }
}
