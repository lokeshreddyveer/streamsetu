import Foundation

/// Least-recently-used bookkeeping for several dictionaries that share one key (a track uid). `touch` marks a key as just used; `evict` names the
/// keys to drop so the caller removes them from every map at once. Keys the caller says are still in use are never named.
struct MusicRecency: Sendable, Equatable {
    private var stamp: [String: Int] = [:]
    private var counter = 0

    init() {}
    var count: Int { stamp.count }
    func contains(_ key: String) -> Bool { stamp[key] != nil }

    mutating func touch(_ key: String) { counter += 1; stamp[key] = counter }
    mutating func forget(_ key: String) { stamp[key] = nil }

    /// The oldest keys beyond `limit`, skipping `keeping`. They are forgotten here; the caller removes them from its maps.
    mutating func evict(limit: Int, keeping: Set<String> = []) -> [String] {
        let over = stamp.count - max(1, limit)
        guard over > 0 else { return [] }
        let victims = stamp.filter { !keeping.contains($0.key) }.sorted { $0.value < $1.value }.prefix(over).map(\.key)
        for k in victims { stamp[k] = nil }
        return Array(victims)
    }
}
