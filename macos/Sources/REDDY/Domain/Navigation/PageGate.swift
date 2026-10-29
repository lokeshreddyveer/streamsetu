import Foundation

/// Keeps "a page is being read" honest for a list that reads pages one at a time. A new query (different source, folder, search…) starts a new generation and clears the flag
/// itself, so a read that was in flight for the old query can neither append to the new list nor leave the flag set; and only the read that started a flag may clear it.
struct PageGate: Equatable, Sendable {
    private(set) var generation = 0
    private(set) var loading = false

    /// The list was reloaded for a new query: any page still being read belongs to the old one.
    mutating func reset() { generation += 1; loading = false }

    /// Starts reading a page; nil when one is already being read for this query.
    mutating func begin() -> Int? {
        guard !loading else { return nil }
        loading = true
        return generation
    }

    /// A read ended. True when it was for the current query and its rows may be used; false when the query changed meanwhile (the rows are dropped).
    /// The flag is only cleared by a read of the current generation, so a stale read can never clear the flag of the newer one.
    mutating func end(_ started: Int) -> Bool {
        guard started == generation else { return false }
        loading = false
        return true
    }
}
