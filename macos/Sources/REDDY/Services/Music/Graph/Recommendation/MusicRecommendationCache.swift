import Foundation

/// Memory-only, short-lived answers keyed by entity and band configuration (section 5.4's `rec_cache` without the table: a recommendation is cheap to
/// rebuild from cached edges, so nothing is written to disk). An expired entry is kept until it is pushed out, so a graph outage can still be answered.
actor MusicRecommendationCache {
    struct Key: Hashable, Sendable {
        var seed: MusicEntityID
        var signature: String
    }
    private struct Entry { var result: MusicRecResult; var storedAt: Date }

    let capacity: Int
    let ttl: TimeInterval
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private(set) var hits = 0
    private(set) var misses = 0

    init(capacity: Int = 64, ttl: TimeInterval = 120) { self.capacity = max(1, capacity); self.ttl = ttl }

    var count: Int { entries.count }

    /// A fresh answer, or nil.
    func fresh(_ key: Key, now: Date = Date()) -> MusicRecResult? {
        guard let e = entries[key], now.timeIntervalSince(e.storedAt) < ttl else { misses += 1; return nil }
        hits += 1
        touch(key)
        return e.result
    }

    /// Whatever is stored, however old: for when the graph cannot be read.
    func stale(_ key: Key) -> MusicRecResult? { entries[key]?.result }

    func store(_ result: MusicRecResult, for key: Key, now: Date = Date()) {
        entries[key] = Entry(result: result, storedAt: now)
        touch(key)
        while order.count > capacity { entries[order.removeFirst()] = nil }
    }

    private func touch(_ key: Key) { order.removeAll { $0 == key }; order.append(key) }

    /// Drops every answer about (or containing) an entity: its graph changed.
    func invalidate(_ id: MusicEntityID) {
        for k in entries.keys where k.seed == id || entries[k]!.result.items.contains(where: { $0.id == id }) { entries[k] = nil }
        order.removeAll { entries[$0] == nil }
    }

    /// The privacy wipe, and the affinity reset.
    func removeAll() { entries = [:]; order = [] }
}
