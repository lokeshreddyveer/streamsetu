import Foundation

/// Time, so pacing and back-off can be tested without waiting.
protocol MatchClock: Sendable {
    func now() -> TimeInterval
    func sleep(_ seconds: TimeInterval) async throws
}
struct SystemMatchClock: MatchClock {
    func now() -> TimeInterval { Date().timeIntervalSince1970 }
    func sleep(_ seconds: TimeInterval) async throws { if seconds > 0 { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } }
}

/// Hands out request slots at a steady rate (never a burst) and can be told to hold everything for a while (a 429).
actor RequestPacer {
    private let interval: TimeInterval
    private let clock: MatchClock
    private let expressInterval: TimeInterval
    private var next: TimeInterval = 0
    private var nextExpress: TimeInterval = 0
    private var blockedUntil: TimeInterval = 0
    /// The express lane (what the person opens or sees) has its own steady budget of slots, so the bulk run can never use them up; both stop for a 429.
    init(interval: TimeInterval, expressInterval: TimeInterval? = nil, clock: MatchClock = SystemMatchClock()) { self.interval = interval; self.expressInterval = expressInterval ?? (interval > 0 ? 1.0 / 6 : 0); self.clock = clock }
    func wait(express: Bool = false) async throws {
        guard interval > 0 || blockedUntil > 0 else { return }
        let t = clock.now()
        let slot = max(t, express ? nextExpress : next, blockedUntil)
        if express { nextExpress = slot + expressInterval } else { next = slot + interval }
        if slot > t { try await clock.sleep(slot - t) }
    }
    func release() { blockedUntil = 0 }
    func hold(for seconds: TimeInterval) { blockedUntil = max(blockedUntil, clock.now() + seconds) }
    var heldUntil: TimeInterval { blockedUntil }
}

/// Whether the network may be used for artwork right now.
protocol MatchNetwork: Sendable { func isUsable(allowCellular: Bool) -> Bool }

/// Where the matcher keeps its small state (the switch, the cellular choice, the back-off), per profile.
struct MatchStateStore: @unchecked Sendable {
    let defaults: UserDefaults
    let profileID: @Sendable () -> String
    private func key(_ k: String) -> String { "artwork.auto.\(k).\(profileID())" }
    var enabled: Bool { get { defaults.object(forKey: key("enabled")) as? Bool ?? true } nonmutating set { defaults.set(newValue, forKey: key("enabled")) } }
    var allowCellular: Bool { get { defaults.object(forKey: key("cellular")) as? Bool ?? true } nonmutating set { defaults.set(newValue, forKey: key("cellular")) } }
    var backoffUntil: TimeInterval { get { defaults.double(forKey: "artwork.auto.backoffUntil") } nonmutating set { defaults.set(newValue, forKey: "artwork.auto.backoffUntil") } }
    var failures: Int { get { defaults.integer(forKey: "artwork.auto.failures") } nonmutating set { defaults.set(newValue, forKey: "artwork.auto.failures") } }
}

/// What the person is told. `line` is the whole progress sentence.
struct ArtworkMatchStatus: Equatable, Sendable {
    enum State: Equatable, Sendable { case off, noKey, builtInRejected, waitingForNetwork, backingOff, running, complete, idle }
    var state: State = .idle
    var done = 0, total = 0, notFound = 0
    /// Titles a minute and the minutes left, once enough are done this session to tell.
    var perMinute: Int?
    var minutesLeft: Int?
    private var pace: String { guard let r = perMinute, let m = minutesLeft else { return "" }; return " · \(r.formatted()) a minute · about \(m <= 1 ? "1 min" : "\(m) min") left" }

    var line: String {
        let nf = notFound > 0 ? " · \(notFound.formatted()) not found" : ""
        switch state {
        case .off: return "Matching artwork is off."
        case .noKey: return "Matching artwork needs an artwork and details key."
        case .builtInRejected: return "The built-in key is not working; add your own free key to keep artwork."
        case .complete: return "All artwork matched" + nf
        case .waitingForNetwork: return "Matching artwork will continue when the network allows: \(done.formatted()) of \(total.formatted()) done" + nf
        case .backingOff: return "Matching artwork is paused for a moment: \(done.formatted()) of \(total.formatted()) done" + nf
        case .running: return "Matching artwork: \(done.formatted()) of \(total.formatted()) done" + nf + pace
        case .idle: return "Matching artwork: \(done.formatted()) of \(total.formatted()) done" + nf
        }
    }
}

/// Fills in missing posters and summaries on its own, one title at a time, for the whole library: newest first, what is on screen first, at a polite pace, resuming after a relaunch
/// (the database remembers what is done), pausing when the switch is off, the key goes, or the network is not Wi-Fi. Restricted titles are never queued, and are dropped from the queue
/// the moment something is locked or hidden. Bulk work is the cheap search only; details (cast, backdrop) are fetched when a title is opened.
final class ArtworkAutoMatcher: @unchecked Sendable {
    static let workers = 8
    static let interval: TimeInterval = 0.045               // about 22 requests a second in all (TMDB tolerates about 50 a second per address)
    static let refill = 200
    static let writeBatch = 50
    static let expressWorkers = 3
    static let expressBatch = 12

    private let service: MetadataMatchService
    private let store: MatchStateStore
    private let network: MatchNetwork
    private let clock: MatchClock
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var foreground = true
    private var feed = Feed()
    private var queued: [String] = []                       // ids asked for by the screen, oldest first, waiting for the debounce
    private var express: [MetadataMatchService.Candidate] = []
    private var expressActive = 0
    private(set) var expressServed: [String] = []
    private var ratingTaken: Set<String> = []          // titles whose rating is being fetched (by the screen or the slow pass): asked once
    private var debounce: Task<Void, Never>?
    private var landed: [String] = []
    private var lastFlush: TimeInterval = 0
    private var _status = ArtworkMatchStatus()
    private var listeners: [UUID: @Sendable (ArtworkMatchStatus) -> Void] = [:]
    private(set) var requestsSent = 0
    private var writes: [(item: MetadataMatchService.Candidate, hit: MetadataMatchService.Hit?)] = []
    private var lastWrite: TimeInterval = 0
    private var sessionStart: TimeInterval = 0, sessionDone = 0, startedDone = 0

    init(service: MetadataMatchService, store: MatchStateStore, network: MatchNetwork, clock: MatchClock = SystemMatchClock()) {
        self.service = service; self.store = store; self.network = network; self.clock = clock
    }

    // MARK: controls

    var enabled: Bool {
        get { store.enabled }
        set { store.enabled = newValue; if newValue { start() } else { stop(); publish(.off) } }
    }
    var allowCellular: Bool {
        get { store.allowCellular }
        set { store.allowCellular = newValue; if newValue { start() } }
    }
    var status: ArtworkMatchStatus { lock.withLock { _status } }
    var isRunning: Bool { lock.withLock { task != nil } }

    @discardableResult func observe(_ f: @escaping @Sendable (ArtworkMatchStatus) -> Void) -> UUID { let id = UUID(); lock.withLock { listeners[id] = f }; return id }
    func removeObserver(_ id: UUID) { lock.withLock { listeners[id] = nil } }

    /// The app is on screen (or has been given background time): work may run.
    /// `stopping: false` lets a run that is under way carry on for the extra seconds iOS grants after the app leaves the screen.
    func setForeground(_ on: Bool, stopping: Bool = true) { lock.withLock { foreground = on }; if on { start() } else if stopping { stop() } }

    /// Starts or resumes the run (no-op when it is running or may not run).
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard task == nil, foreground else { return }
        task = Task.detached(priority: .utility) { [weak self] in await self?.run(); self?.finish() }
    }

    func stop() { lock.lock(); let t = task; task = nil; lock.unlock(); t?.cancel() }

    /// "Match now": forgets any waiting period and starts at once.
    func matchNow() { store.backoffUntil = 0; store.failures = 0; Task { await service.pacer.release() }; start() }

    /// Runs until nothing is left or something stops it, in the caller's task (the iOS background task uses this; cancel the task to stop).
    func runToCompletion() async { guard !isRunning else { return }; await run() }

    private func finish() { lock.withLock { task = nil } }

    /// The titles on screen or opened go to the EXPRESS lane (served before the bulk run, with its own request budget). Cheap (ids only) and debounced: many calls while scrolling become one,
    /// and only the 12 newest are kept, newest first.
    func prioritize(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        lock.lock()
        queued.removeAll { ids.contains($0) }; queued += ids
        let pending = debounce == nil
        if pending { debounce = Task { [weak self] in try? await self?.clock.sleep(0.3); self?.flushPriority() } }
        lock.unlock()
    }

    /// Hero candidates: those without a poster join the express queue; the first few without a backdrop get match + details at once (backdrops are fetched on demand, never in bulk).
    func expressHero(_ items: [LibraryItem]) {
        let top = Array(items.prefix(Self.expressBatch))
        prioritize(top.filter { ($0.posterURL ?? "").isEmpty }.map(\.id))
        guard store.enabled, service.hasKey else { return }
        for it in top.filter({ ($0.backdropURL ?? "").isEmpty }).prefix(3) {
            let cand = MetadataMatchService.Candidate(id: it.id, isSeries: it.isSeries, title: it.title, year: it.year)
            Task.detached(priority: .userInitiated) { [service] in _ = await service.details(for: cand) }
        }
    }

    /// These titles scrolled away: if they are still waiting, they are dropped from the express lane.
    func cancelPriority(_ ids: [String]) {
        lock.withLock { let s = Set(ids); queued.removeAll { s.contains($0) }; express.removeAll { s.contains($0.id) } }
    }

    private func flushPriority() {
        let ids: [String] = lock.withLock { let x = Array(queued.suffix(Self.expressBatch).reversed()); queued = []; debounce = nil; return x }
        guard !ids.isEmpty, store.enabled, service.hasKey else { return }
        let cands = service.candidates(ids: ids) + service.ratingCandidates(ids: ids)          // only those that still wait and may be sent
        lock.withLock { let have = Set(cands.map(\.id)); express.removeAll { have.contains($0.id) }; express = cands + express }
        startExpress()
        start()
    }

    private func startExpress() {
        let n: Int = lock.withLock { let free = max(0, Self.expressWorkers - expressActive), want = min(free, express.count); expressActive += want; return want }
        for _ in 0..<n { Task.detached(priority: .userInitiated) { [self] in await runExpress() } }
    }

    private func runExpress() async {
        defer { lock.withLock { expressActive -= 1 } }
        while !Task.isCancelled {
            guard case .go = gate() else { return }          // no key, switched off, offline, or backing off: the express lane does nothing, silently
            guard let item = lock.withLock({ express.isEmpty ? nil : express.removeFirst() }) else { return }
            guard service.isSendable(item.id) else { continue }          // checked again at the moment of sending
            if item.ratingOnly, !lock.withLock({ ratingTaken.insert(item.id).inserted }) { continue }
            do {
                try await MetadataMatchService.$expressLane.withValue(true) {
                    if item.ratingOnly { try await service.backfillRating(item); return }
                    let hit = try await service.lookup(item)
                    try service.store(item, hit, notify: true)          // written at once, so the tile and the page update, and the bulk run skips it
                }
                lock.withLock { requestsSent += 1; expressServed.append(item.id) }
            } catch { return }
        }
    }

    /// Something was locked or hidden: nothing already queued may be sent. The queue is emptied now and refilled from the gated query.
    func restrictionChanged() {
        lock.withLock { feed.clear(); queued = []; express = [] }
    }

    // MARK: the run

    private func publish(_ s: ArtworkMatchStatus.State? = nil) {
        let counts = service.lookedUpCounts(), left = (try? service.pendingCount()) ?? 0
        let ls: [@Sendable (ArtworkMatchStatus) -> Void] = lock.withLock {
            if let s { _status.state = s }
            _status.done = counts.done; _status.notFound = counts.notFound; _status.total = counts.done + left
            let t = clock.now() - sessionStart, did = counts.done - startedDone
            if _status.state == .running, sessionStart > 0, did >= 100, t > 5 {
                let perSec = Double(did) / t
                _status.perMinute = Int((perSec * 60).rounded()); _status.minutesLeft = max(1, Int((Double(left) / perSec / 60).rounded(.up)))
            } else { _status.perMinute = nil; _status.minutesLeft = nil }
            return Array(listeners.values)
        }
        let st = status
        for l in ls { l(st) }
    }

    /// Reads the counts now and tells the listeners, keeping the state as it is (used when a settings screen opens).
    func refreshCounts() {
        if lock.withLock({ task == nil && [.idle, .complete, .off, .noKey, .builtInRejected].contains(_status.state) }) {
            let st: ArtworkMatchStatus.State = !store.enabled ? .off : !service.hasKey ? (service.access.builtInRejected ? .builtInRejected : .noKey) : (((try? service.pendingCount()) ?? 0) == 0 ? .complete : .idle)
            publish(st)
        } else { publish() }
    }

    private enum Gate { case go, off, noKey, rejected, network, backoff(TimeInterval) }
    private func gate() -> Gate {
        if !store.enabled { return .off }
        if !service.hasKey { return service.access.builtInRejected && !service.hasOwnKey ? .rejected : .noKey }
        if !network.isUsable(allowCellular: store.allowCellular) { return .network }
        let wait = store.backoffUntil - clock.now()
        if wait > 0 { return .backoff(wait) }
        return .go
    }

    private func run() async {
        service.runCache.clear()
        service.purgeExpired()
        lock.withLock { sessionStart = clock.now(); startedDone = service.lookedUpCounts().done }
        publish(.running)
        while !Task.isCancelled {
            switch gate() {
            case .off: publish(.off); return
            case .noKey: publish(.noKey); return
            case .rejected: publish(.builtInRejected); return
            case .network: publish(.waitingForNetwork); do { try await clock.sleep(30) } catch { return }; continue
            case .backoff(let w): publish(.backingOff); do { try await clock.sleep(min(w, 60)) } catch { return }; continue
            case .go: break
            }
            publish(.running)
            let more = await drain()
            flushWrites(force: true)
            flushLanded(force: true)
            if Task.isCancelled { return }
            if !more { publish(finishedState()); await ratingsPass(); return }
        }
    }

    /// After the posters: a slow pass (about two a second) that gives matched and unmatched titles their TMDB rating, newest first, so the library fills over time. Stops with the run.
    /// The slow rating pass after the posters (on in the app; tests that count requests turn it off).
    var ratingPassEnabled: Bool { get { lock.withLock { _ratingPass } } set { lock.withLock { _ratingPass = newValue } } }
    private var _ratingPass = true

    private func ratingsPass() async {
        guard ratingPassEnabled else { return }
        while !Task.isCancelled {
            guard case .go = gate() else { return }
            let taken = lock.withLock { ratingTaken }
            let batch = service.ratingBacklog(limit: 30, excluding: taken)
            if batch.isEmpty { return }
            for item in batch {
                guard !Task.isCancelled, case .go = gate() else { return }
                if !lock.withLock({ ratingTaken.insert(item.id).inserted }) { continue }
                do { try await service.backfillRating(item) }
                catch let e as MetadataMatchService.MatchError where e == .rateLimited || e == .offline { await backOff(after: e == .rateLimited ? service.lastRetryAfter : nil, base: 30); lock.withLock { _ = ratingTaken.remove(item.id) }; return }
                catch { return }
                try? await clock.sleep(0.5)
            }
        }
    }

    private func finishedState() -> ArtworkMatchStatus.State { ((try? service.pendingCount()) ?? 0) == 0 ? .complete : .idle }

    /// Runs the workers until the queue is empty (returns false) or something paused the run (returns true).
    private func drain() async -> Bool {
        let paused = OnceFlag()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<Self.workers { group.addTask { [self] in await work(paused) } }
        }
        return paused.value
    }

    private func work(_ paused: OnceFlag) async {
        var sinceCounts = 0
        while !Task.isCancelled, !paused.value {
            guard case .go = gate() else { paused.set(); return }
            guard let item = await nextItem() else { return }
            guard service.isSendable(item.id) else { lock.withLock { feed.skip(item.id) }; continue }          // checked again at the moment of sending
            do {
                guard let answer = try await service.lookupForBatch(item) else { continue }          // not sendable any more: nothing was sent
                lock.withLock { requestsSent += 1; landed.append(item.id); writes.append((item, answer)) }
                flushWrites(force: false)
                if store.failures != 0 { store.failures = 0 }
                sinceCounts += 1
                if sinceCounts >= 50 { sinceCounts = 0; flushWrites(force: true); publish() }
                flushLanded(force: false)
            } catch is CancellationError { return }
            catch let e as MetadataMatchService.MatchError {
                switch e {
                case .rateLimited, .offline:
                    await backOff(after: e == .rateLimited ? service.lastRetryAfter : nil, base: e == .rateLimited ? 30 : 15)          // the hold is set before the title goes back, so no other worker can slip it through
                    lock.withLock { feed.addFront(item) }
                    paused.set(); return
                case .noKey, .invalidKey, .switchedOff: lock.withLock { feed.addFront(item) }; paused.set(); return
                case .unreadable, .notFound: lock.withLock { feed.skip(item.id) }
                }
            } catch { lock.withLock { feed.skip(item.id) } }
        }
    }

    private func backOff(after: TimeInterval?, base: TimeInterval) async {
        let n = store.failures
        let wait = min(after ?? base * pow(2, Double(min(n, 6))), 900)
        let until = clock.now() + wait
        if until > store.backoffUntil { store.backoffUntil = until; store.failures = n + 1 }
        await service.pacer.hold(for: wait)
    }

    private func nextItem() async -> MetadataMatchService.Candidate? {
        if let x = lock.withLock({ feed.take() }) { return x }
        // The buffer is empty: one worker at a time fetches the next page (ids and titles only), off the main thread.
        let (exclude, mayFill) = lock.withLock { () -> (Set<String>, Bool) in
            if feed.filling { return ([], false) }
            feed.filling = true; return (feed.exclude, true)
        }
        if !mayFill { try? await clock.sleep(0.05); return lock.withLock { feed.take() } }
        var skipped: [String] = []
        let page = (try? service.pending(limit: Self.refill, excluding: exclude, skipped: { skipped.append($0) }))?.items ?? []
        return lock.withLock {
            feed.filling = false
            for s in skipped { feed.skip(s) }
            feed.fill(page)
            return feed.take()
        }
    }

    /// The answers so far, in one transaction: when fifty have gathered, or a second and a half has passed, or the run stops.
    private func flushWrites(force: Bool) {
        let rows: [(item: MetadataMatchService.Candidate, hit: MetadataMatchService.Hit?)] = lock.withLock {
            let t = clock.now()
            guard !writes.isEmpty, force || writes.count >= Self.writeBatch || t - lastWrite > 1.5 else { return [] }
            lastWrite = t; let x = writes; writes = []; return x
        }
        try? service.storeBatch(rows)
    }

    private func flushLanded(force: Bool) {
        let ids: [String] = lock.withLock {
            let t = clock.now()
            guard !landed.isEmpty, force || landed.count >= 30 || t - lastFlush > 10 else { return [] }
            lastFlush = t; let x = landed; landed = []; return x
        }
        TitleMetadataEvent.post(ids, bulk: true)
    }

    /// Ids and a few columns only: the queue never holds the library.
    struct Feed {
        private var priority: [MetadataMatchService.Candidate] = []
        private var buffer: [MetadataMatchService.Candidate] = []
        private var seen: Set<String> = []                 // handed out this session, or skipped
        var filling = false
        var exclude: Set<String> { seen }
        mutating func addPriority(_ c: [MetadataMatchService.Candidate]) {
            let fresh = c.filter { !seen.contains($0.id) }
            let ids = Set(fresh.map(\.id))
            buffer.removeAll { ids.contains($0.id) }; priority.removeAll { ids.contains($0.id) }
            priority = fresh + priority
        }
        mutating func addFront(_ c: MetadataMatchService.Candidate) { seen.remove(c.id); priority.insert(c, at: 0) }
        mutating func fill(_ c: [MetadataMatchService.Candidate]) { buffer += c.filter { !seen.contains($0.id) } }
        mutating func skip(_ id: String) { seen.insert(id) }
        mutating func take() -> MetadataMatchService.Candidate? {
            let x = priority.isEmpty ? (buffer.isEmpty ? nil : buffer.removeFirst()) : priority.removeFirst()
            if let x { seen.insert(x.id) }
            return x
        }
        mutating func clear() { priority = []; buffer = []; seen = [] }
        var queuedIDs: [String] { (priority + buffer).map(\.id) }
    }
    var queuedIDs: [String] { lock.withLock { feed.queuedIDs } }
}

/// The id of the profile in use, readable from any thread (the matcher keeps its switch per profile).
final class MatchProfileBox: Sendable {
    private let v = Locked("main")
    var id: String { get { v.value } set { v.value = newValue } }
}
