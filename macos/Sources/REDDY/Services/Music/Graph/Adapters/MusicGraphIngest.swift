import Foundation

/// The feed point that turns the songs and albums the app already loaded into graph claims. Fire and forget: nothing in a page load or in playback
/// waits for it, awaits it, or sees its errors. Work runs on one low-priority task, one item at a time, with a short pause between items.
///
/// Bounds: at most `queueLimit` items wait (a new one past the limit drops the OLDEST), an item already queued or written within `seenTTL` (and
/// unchanged) is skipped, and the memory of what was written is capped at `seenLimit` entries. `gate` is asked before every write (Kids profile, app
/// lock), and `reset()` empties everything, as the privacy wipe does.
actor MusicGraphIngest {
    enum Item: Sendable {
        case track(MusicTrack)
        case album(MusicAlbum, [MusicTrack])

        /// Identity plus a fingerprint of what the item says, so a changed credit list is written again but a repeat is not.
        var key: String {
            switch self {
            case .track(let t): "t|" + t.uid + "|" + Self.fingerprint(t.title, t.credits ?? [], t.hints)
            case .album(let a, let ts): "a|" + a.uid + "|" + String(ts.count) + "|" + Self.fingerprint(a.title, (a.credits ?? []) + ts.flatMap { $0.credits ?? [] }, a.hints)
            }
        }
        private static func fingerprint(_ title: String, _ credits: [MusicCredit], _ hints: MusicProviderHints?) -> String {
            var h = Hasher()
            h.combine(title); h.combine(credits.count)
            for c in credits { h.combine(c.name); h.combine(c.role); h.combine(c.level); h.combine(c.providerArtistID) }
            h.combine(hints?.genre); h.combine(hints?.language)
            return String(UInt(bitPattern: h.finalize()), radix: 36)
        }
    }

    private let store: @Sendable () -> any MusicGraphStoring
    private let gate: @Sendable () async -> Bool
    private let clock: @Sendable () -> Date
    private let queueLimit: Int
    private let seenLimit: Int
    private let seenTTL: TimeInterval
    private let pause: Duration

    private var queue: [(key: String, item: Item)] = []
    private var queued = Set<String>()
    private var seen: [String: Date] = [:]
    private var worker: Task<Void, Never>?
    private var generation = 0
    private(set) var written = 0
    private(set) var dropped = 0

    init(store: @escaping @Sendable () -> any MusicGraphStoring, gate: @escaping @Sendable () async -> Bool = { true },
         clock: @escaping @Sendable () -> Date = { Date() }, queueLimit: Int = 200, seenLimit: Int = 4_000, seenTTL: TimeInterval = 6 * 3_600,
         pause: Duration = .milliseconds(40)) {
        self.store = store; self.gate = gate; self.clock = clock
        self.queueLimit = max(1, queueLimit); self.seenLimit = max(16, seenLimit); self.seenTTL = seenTTL; self.pause = pause
    }

    // MARK: fire and forget (callable from anywhere, returns at once)

    nonisolated func ingest(track: MusicTrack) {
        Task.detached(priority: .background) { [self] in await enqueue(.track(track)) }
    }

    nonisolated func ingest(album: MusicAlbum, tracks: [MusicTrack]) {
        Task.detached(priority: .background) { [self] in await enqueue(.album(album, tracks)) }
    }

    /// The first `limit` songs of a result list (20 by default).
    nonisolated func ingest(tracks: [MusicTrack], limit: Int = 20) {
        let top = Array(tracks.prefix(max(0, limit)))
        guard !top.isEmpty else { return }
        Task.detached(priority: .background) { [self] in for t in top { await enqueue(.track(t)) } }
    }

    // MARK: queue

    var depth: Int { queue.count }
    var seenCount: Int { seen.count }

    func enqueue(_ item: Item) {
        let key = item.key
        if queued.contains(key) { return }
        if let at = seen[key], clock().timeIntervalSince(at) < seenTTL { return }
        if queue.count >= queueLimit {
            let old = queue.removeFirst()
            queued.remove(old.key)
            dropped += 1
        }
        queue.append((key, item)); queued.insert(key)
        startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task(priority: .background) { [self] in await run() }
    }

    private func run() async {
        while let next = pop() {
            if await gate() { await write(next) } else { clearQueue() }
            if pause > .zero { try? await Task.sleep(for: pause) }
            await Task.yield()
        }
        worker = nil
        // An item may have arrived between the last pop and here.
        if !queue.isEmpty { startWorkerIfNeeded() }
    }

    private func pop() -> (key: String, item: Item)? {
        guard !queue.isEmpty else { return nil }
        let n = queue.removeFirst()
        queued.remove(n.key)
        return n
    }

    private func write(_ n: (key: String, item: Item)) async {
        let gen = generation
        let now = clock()
        let batch: MusicCreditsBatch
        switch n.item {
        case .track(let t): batch = MusicCreditsAdapter.batch(track: t, now: now)
        case .album(let a, let ts): batch = MusicCreditsAdapter.batch(album: a, tracks: ts, now: now)
        }
        guard gen == generation else { return }
        do {
            try await MusicCreditsAdapter.commit(batch, to: store())
            guard gen == generation else { return }
            remember(n.key, at: now)
            written += 1
        } catch {
            // A failed write is dropped; the item is offered again the next time the app sees it.
        }
    }

    private func remember(_ key: String, at date: Date) {
        seen[key] = date
        if seen.count > seenLimit {
            let keep = seen.sorted { $0.value > $1.value }.prefix(seenLimit * 3 / 4)
            seen = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    private func clearQueue() { queue.removeAll(); queued.removeAll() }

    /// Writes one song now, ahead of the queue, and returns when it is in the graph: for opening the song's page, which needs the song to exist (a chart row that was never played has not been seen yet).
    func ingestNow(track t: MusicTrack) async {
        guard await gate() else { MusicDebugLog.log("graph", "ingestNow blocked by the gate for \(t.uid)"); return }
        await write((key: Item.track(t).key, item: .track(t)))
        MusicDebugLog.log("graph", "ingestNow wrote \(t.title) (\(t.uid))")
    }

    /// Waits until the queue is empty and the worker has stopped. For tests.
    func drain() async {
        while worker != nil || !queue.isEmpty {
            startWorkerIfNeeded()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The privacy wipe: nothing queued or remembered survives, and a write already in flight is not recorded.
    func reset() {
        generation += 1
        clearQueue(); seen.removeAll()
    }
}
