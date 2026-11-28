import Foundation

/// Answers to a repeated question, kept in memory for a few minutes: the same search typed again, or the results page opened again with Back, is served
/// at once. It never touches the disk (what a person searched for is personal), it is capped (the least recently used entry goes first) and it is
/// emptied by the privacy wipe.
///
/// - younger than `fresh`: returned as it is, no request;
/// - younger than `ttl`: returned at once, and one quiet refresh runs behind it, so the next ask has newer results;
/// - older, or none: the source is asked.
/// A failed request never removes a good entry, and one refresh per key runs at a time.
actor MusicQueryCache<Value: Sendable> {
    private struct Entry { var value: Value; var at: Date; var used: Date }

    let fresh: TimeInterval
    let ttl: TimeInterval
    let capacity: Int
    private let clock: @Sendable () -> Date
    private var entries: [String: Entry] = [:]
    private var refreshing = Set<String>()
    /// One request per question at a time: a second identical ask while the first runs waits for it instead of sending its own.
    private var inflight: [String: Task<Value, Error>] = [:]
    /// Bumped by `clear`, so an answer asked for before it is not saved after it.
    private var generation = 0

    init(fresh: TimeInterval = 60, ttl: TimeInterval = 300, capacity: Int = 200, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.fresh = fresh; self.ttl = ttl; self.capacity = max(1, capacity); self.clock = clock
    }

    /// The same words in a different case, with other spacing or accents, are one question.
    static func key(_ parts: String...) -> String { parts.map { MusicText.normalize($0) }.joined(separator: "|") }

    func value(for key: String, fetch: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let now = clock()
        if var e = entries[key] {
            let age = now.timeIntervalSince(e.at)
            if age < ttl {
                e.used = now; entries[key] = e
                if age >= fresh { refresh(key, fetch) }
                return e.value
            }
        }
        if let running = inflight[key] { return try await running.value }
        let task = Task { try await fetch() }
        inflight[key] = task
        // A newer request may sit under this key after a clear: only the one made here is removed.
        defer { if inflight[key] == task { inflight[key] = nil } }
        let asked = generation
        let v = try await task.value
        if asked == generation { store(v, for: key) }
        return v
    }

    func clear() { entries = [:]; refreshing = []; inflight = [:]; generation &+= 1 }
    var count: Int { entries.count }

    private func store(_ v: Value, for key: String) {
        let now = clock()
        entries[key] = Entry(value: v, at: now, used: now)
        if entries.count > capacity, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key { entries[oldest] = nil }
    }

    private func refresh(_ key: String, _ fetch: @escaping @Sendable () async throws -> Value) {
        guard refreshing.insert(key).inserted else { return }
        Task.detached(priority: .background) { [self] in
            if let v = try? await fetch() { await put(v, key) }
            await done(key)
        }
    }
    private func put(_ v: Value, _ key: String) { store(v, for: key) }
    private func done(_ key: String) { refreshing.remove(key) }
}
