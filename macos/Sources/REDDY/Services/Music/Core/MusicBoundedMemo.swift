import Foundation

/// A bounded memory of the answers of a pure function (the same text always gives the same result). Used where a screen asks the same cheap-looking
/// question hundreds of times (every card cleans its title on every redraw): the work is done once per distinct input. When it holds `capacity` answers
/// it starts again empty, so memory stays bounded without any bookkeeping per read.
final class MusicBoundedMemo<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [Key: Value] = [:]
    let capacity: Int

    init(capacity: Int = 4_096) { self.capacity = max(8, capacity) }

    func value(for key: Key, _ compute: () -> Value) -> Value {
        lock.lock()
        if let hit = store[key] { lock.unlock(); return hit }
        lock.unlock()
        let v = compute()
        lock.lock()
        if store.count >= capacity { store.removeAll(keepingCapacity: true) }
        store[key] = v
        lock.unlock()
        return v
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return store.count }
    func clear() { lock.lock(); store.removeAll(); lock.unlock() }
}
