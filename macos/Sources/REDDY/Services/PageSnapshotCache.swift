import Foundation

/// A small, bounded cache of the first page of a list (Movies or Series for one folder, sort and filter), so going back to a list that was just shown does not read it again.
///
/// It is deliberately strict, because a stale page is worse than a slow one:
///  - every entry is stamped with a `revision` (any change to the catalog, to who is watching, to the open library, to a folder lock or to the adult/kids rule must change it), and an entry
///    is returned only for the revision it was stored under: anything else is discarded on sight, never shown;
///  - `clear()` drops everything at once and is what a change of profile, library or lock calls, so nothing a person is no longer allowed to see can come back from here;
///  - the number of entries and the total cost are bounded, and the least recently used entry goes first;
///  - it holds the list's items and counts only: no address, no login and no playable URL.
@MainActor
final class PageSnapshotCache<Key: Hashable, Value> {
    private struct Entry { var value: Value; var cost: Int; var revision: Int }

    let maxEntries: Int
    let maxCost: Int
    private var entries: [Key: Entry] = [:]
    /// Least recently used first.
    private var order: [Key] = []
    private(set) var totalCost = 0

    init(maxEntries: Int = 8, maxCost: Int = 4_000) { self.maxEntries = max(1, maxEntries); self.maxCost = max(1, maxCost) }

    var count: Int { entries.count }

    /// The page stored for `key` under exactly this `revision`, or nil. Using an entry makes it the most recent; an entry of another revision is removed.
    func get(_ key: Key, revision: Int) -> Value? {
        guard let e = entries[key] else { return nil }
        guard e.revision == revision else { remove(key); return nil }
        touch(key)
        return e.value
    }

    /// Stores a page. `cost` is its size in items. A page bigger than the whole budget is not kept.
    func put(_ key: Key, value: Value, cost: Int, revision: Int) {
        remove(key)
        guard cost <= maxCost else { return }
        entries[key] = Entry(value: value, cost: max(0, cost), revision: revision); order.append(key); totalCost += max(0, cost)
        while entries.count > maxEntries || totalCost > maxCost, let oldest = order.first { remove(oldest) }
    }

    /// Forgets everything: a new profile, library, lock, kids/adult rule or a memory warning.
    func clear() { entries.removeAll(); order.removeAll(); totalCost = 0 }

    private func remove(_ key: Key) {
        if let e = entries.removeValue(forKey: key) { totalCost -= e.cost }
        order.removeAll { $0 == key }
    }

    private func touch(_ key: Key) { order.removeAll { $0 == key }; order.append(key) }
}
