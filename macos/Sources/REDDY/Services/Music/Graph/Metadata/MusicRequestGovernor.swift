import Foundation

/// Time for the governor, so tests can run a virtual clock. Seconds on a monotonic scale.
protocol MusicGovernorClock: Sendable {
    func now() -> TimeInterval
    /// Returns when `now() >= time` (immediately when already past). Throws `CancellationError` when the task is cancelled.
    func sleep(until time: TimeInterval) async throws
}

struct MusicSystemClock: MusicGovernorClock {
    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    func sleep(until time: TimeInterval) async throws {
        let d = time - now()
        if d > 0 { try await Task.sleep(nanoseconds: UInt64(d * 1_000_000_000)) }
    }
}

enum MusicGovernorError: Error, Equatable, Sendable {
    /// The host failed too often: no request is made until `until` (a half-open probe then tries one).
    case circuitOpen(host: String, until: TimeInterval)
}

struct MusicGovernedResponse: Sendable {
    var data: Data
    /// The network failed and this is an earlier answer.
    var stale: Bool
}

/// Pacing, deduplication, back-off and a circuit breaker for every metadata request (section 3.3). Nothing on the playback path calls it.
/// - one lane per host: minimum gap between starts, requests in flight, breaker
/// - single flight per request key: concurrent askers share one network call; the call is cancelled only when every waiter left (a background one finishes)
/// - 429/503/timeouts: exponential back-off with jitter (honours Retry-After), up to `maxRetries`, counted toward the breaker
/// - a global bound on requests in flight; stale-while-error through the `stale` closure
actor MusicRequestGovernor {
    struct Lane: Sendable {
        var minInterval: TimeInterval
        var maxConcurrent: Int
        var failuresToOpen = 5
        var openFor: TimeInterval = 60
        var maxOpenFor: TimeInterval = 900
        var maxRetries = 3
        var backoffBase: TimeInterval = 1
        var maxBackoff: TimeInterval = 30
        init(minInterval: TimeInterval, maxConcurrent: Int) { self.minInterval = minInterval; self.maxConcurrent = maxConcurrent }
    }

    struct HostStats: Sendable, Equatable {
        var started = 0, succeeded = 0, failed = 0, retries = 0, breakerOpens = 0
    }

    /// The lanes of the sources (section 3.3): MusicBrainz one at a time, 1.1 s apart; Wikidata two, 0.3 s; SPARQL one, background only; and so on.
    static let defaultLanes: [String: Lane] = [
        "musicbrainz.org": Lane(minInterval: 1.1, maxConcurrent: 1),
        "coverartarchive.org": Lane(minInterval: 0.5, maxConcurrent: 2),
        "wikidata.org": Lane(minInterval: 0.3, maxConcurrent: 2),
        "query.wikidata.org": Lane(minInterval: 2, maxConcurrent: 1),
        "api.listenbrainz.org": Lane(minInterval: 0.5, maxConcurrent: 2),
        "api.discogs.com": Lane(minInterval: 2.5, maxConcurrent: 1),
        "tmdb": Lane(minInterval: 0, maxConcurrent: 6),
        "v2.sg.media-imdb.com": Lane(minInterval: 0.6, maxConcurrent: 2),
        "www.imdb.com": imdbPage,
        "en.wikipedia.org": Lane(minInterval: 0.3, maxConcurrent: 2),
        "commons.wikimedia.org": Lane(minInterval: 0.3, maxConcurrent: 2),
        "ws.audioscrobbler.com": Lane(minInterval: 0.5, maxConcurrent: 2),
        "www.omdbapi.com": Lane(minInterval: 0.5, maxConcurrent: 1),
        // Artwork sources: Deezer allows 50 requests per 5 seconds; iTunes Search about 20 a minute; JioSaavn's public search is unofficial, so gentle.
        "api.deezer.com": Lane(minInterval: 0.25, maxConcurrent: 2),
        "itunes.apple.com": Lane(minInterval: 3, maxConcurrent: 1),
        "www.jiosaavn.com": Lane(minInterval: 1, maxConcurrent: 1),
    ]
    /// IMDb's title page is gentle and gives up early: two failures open the breaker for ten minutes.
    private static var imdbPage: Lane {
        var l = Lane(minInterval: 3, maxConcurrent: 1)
        l.failuresToOpen = 2; l.openFor = 600; l.maxOpenFor = 3600; l.maxRetries = 1
        return l
    }
    static let fallbackLane = Lane(minInterval: 0.25, maxConcurrent: 4)
    static let globalLimit = 6

    private struct HostState {
        var inFlight = 0
        var nextStart: TimeInterval = 0
        var failures = 0
        var openUntil: TimeInterval?
        var openCount = 0
        var probing = false
        var stats = HostStats()
    }

    private final class Flight {
        let id: UInt64
        var task: Task<Data, Error>?
        var waiters = 1
        let background: Bool
        init(id: UInt64, background: Bool) { self.id = id; self.background = background }
    }

    private struct Waiter { let id: UInt64; let priority: MusicRequestPriority; let continuation: CheckedContinuation<Void, Never> }

    private let clock: any MusicGovernorClock
    private let lanes: [String: Lane]
    private let globalMax: Int
    private let jitter: @Sendable () -> Double
    private var hosts: [String: HostState] = [:]
    private var flights: [String: Flight] = [:]
    private var waiters: [Waiter] = []
    private var globalInFlight = 0
    private var nextID: UInt64 = 0

    init(clock: any MusicGovernorClock = MusicSystemClock(), lanes: [String: Lane] = MusicRequestGovernor.defaultLanes, globalLimit: Int = MusicRequestGovernor.globalLimit,
         jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.clock = clock; self.lanes = lanes; self.globalMax = max(1, globalLimit); self.jitter = jitter
    }

    /// The lane for a host name (`www.wikidata.org` and `wikidata.org` share one).
    static func laneKey(for host: String) -> String {
        let h = host.lowercased()
        for key in ["query.wikidata.org", "api.listenbrainz.org", "api.discogs.com", "coverartarchive.org"] where h == key { return key }
        if h.hasSuffix(".wikipedia.org") { return "en.wikipedia.org" }
        for key in ["musicbrainz.org", "wikidata.org"] where h == key || h.hasSuffix("." + key) { return key }
        return h
    }

    private func lane(_ host: String) -> Lane { lanes[host] ?? Self.fallbackLane }

    func stats(host: String) -> HostStats { hosts[host]?.stats ?? HostStats() }
    func isOpen(host: String) -> Bool { (hosts[host]?.openUntil).map { clock.now() < $0 } ?? false }
    var activeFlights: Int { flights.count }

    /// Runs `work` for `key` on `host`. Many callers with one key share one run. When the network fails and `stale` has an answer, that is returned
    /// with `stale: true` instead of the error (an open breaker counts as a failure).
    func perform(host: String, key: String, background: Bool = false, priority: MusicRequestPriority? = nil, stale: (@Sendable () async -> Data?)? = nil,
                 work: @escaping @Sendable () async throws -> Data) async throws -> MusicGovernedResponse {
        do {
            let data = try await singleFlight(host: host, key: key, background: background, priority: priority ?? (background ? .background : .foreground), work: work)
            return MusicGovernedResponse(data: data, stale: false)
        } catch {
            if error is CancellationError || (error as? MusicError) == .cancelled { throw error }
            if let stale, let old = await stale() { return MusicGovernedResponse(data: old, stale: true) }
            throw error
        }
    }

    // MARK: single flight

    private func singleFlight(host: String, key: String, background: Bool, priority: MusicRequestPriority, work: @escaping @Sendable () async throws -> Data) async throws -> Data {
        let flight: Flight
        if let f = flights[key] {
            f.waiters += 1
            flight = f
        } else {
            nextID += 1
            let f = Flight(id: nextID, background: background)
            flights[key] = f
            f.task = Task { [self] in
                do {
                    let d = try await execute(host: host, priority: priority, work: work)
                    finish(key: key, id: f.id)
                    return d
                } catch {
                    finish(key: key, id: f.id)
                    throw error
                }
            }
            flight = f
        }
        guard let task = flight.task else { throw CancellationError() }
        let id = flight.id
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { await self.leave(key: key, id: id) }
        }
    }

    private func finish(key: String, id: UInt64) {
        if flights[key]?.id == id { flights[key] = nil }
    }

    private func leave(key: String, id: UInt64) {
        guard let f = flights[key], f.id == id else { return }
        f.waiters -= 1
        if f.waiters <= 0, !f.background {
            f.task?.cancel()
            flights[key] = nil
        }
    }

    // MARK: lanes, retries, breaker

    private enum Outcome { case success, neutral, retryable(after: TimeInterval?), fatal, cancelled }

    private func classify(_ error: Error) -> Outcome {
        if error is CancellationError { return .cancelled }
        if let e = error as? MusicError {
            switch e {
            case .cancelled: return .cancelled
            case .notFound: return .success
            case .rateLimited(let after): return .retryable(after: after)
            case .network(let s):
                if s == "unexpected reply" || s == "bad address" { return .neutral }
                return .retryable(after: nil)
            default: return .neutral
            }
        }
        if let e = error as? MusicGovernorError, case .circuitOpen = e { return .fatal }
        if (error as? URLError)?.code == .cancelled { return .cancelled }
        return .retryable(after: nil)
    }

    private func execute(host: String, priority: MusicRequestPriority, work: @escaping @Sendable () async throws -> Data) async throws -> Data {
        let lane = lane(host)
        var attempt = 0
        while true {
            try await acquire(host, priority: priority)
            do {
                let data = try await work()
                release(host, failure: false)
                return data
            } catch {
                let outcome = classify(error)
                switch outcome {
                case .success, .neutral, .fatal: release(host, failure: false)
                case .cancelled: release(host, failure: false); throw error
                case .retryable: release(host, failure: true)
                }
                guard case .retryable(let after) = outcome, attempt < lane.maxRetries else { throw error }
                let base = min(lane.maxBackoff, lane.backoffBase * pow(2, Double(attempt)))
                let delay = min(60, after ?? base * (1 + 0.5 * min(1, max(0, jitter()))))
                attempt += 1
                hosts[host, default: HostState()].stats.retries += 1
                try await clock.sleep(until: clock.now() + delay)
            }
        }
    }

    private func acquire(_ host: String, priority: MusicRequestPriority) async throws {
        let lane = lane(host)
        var isProbe = false
        while true {
            try Task.checkCancellation()
            var st = hosts[host, default: HostState()]
            let t = clock.now()
            if let until = st.openUntil, !isProbe {
                if t < until || st.probing { throw MusicGovernorError.circuitOpen(host: host, until: until) }
                st.probing = true; isProbe = true
                hosts[host] = st
            }
            if st.inFlight < lane.maxConcurrent, globalInFlight < globalMax {
                let start = max(t, st.nextStart)
                st.nextStart = start + lane.minInterval
                st.inFlight += 1; st.stats.started += 1
                hosts[host] = st
                globalInFlight += 1
                if start > t {
                    do { try await clock.sleep(until: start) } catch {
                        releaseSlot(host)
                        if isProbe { hosts[host]?.probing = false }
                        throw error
                    }
                }
                return
            }
            hosts[host] = st
            await waitForSlot(priority)
        }
    }

    private func releaseSlot(_ host: String) {
        hosts[host]?.inFlight -= 1
        globalInFlight -= 1
        // the page the person is on first, then first come first served; the lane's spacing and one-at-a-time rule are unchanged
        let order = MusicWaiterOrder.sorted(waiters.map { MusicWaiterOrder.Item(id: $0.id, priority: $0.priority) })
        let byID = Dictionary(waiters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        waiters.removeAll()
        for item in order { byID[item.id]?.continuation.resume() }
    }

    private func release(_ host: String, failure: Bool) {
        let lane = lane(host)
        var st = hosts[host, default: HostState()]
        if failure {
            st.stats.failed += 1
            st.failures += 1
            if st.probing || st.failures >= lane.failuresToOpen {
                st.openCount += 1
                let span = min(lane.maxOpenFor, lane.openFor * pow(2, Double(max(0, st.openCount - 1))))
                st.openUntil = clock.now() + span
                st.stats.breakerOpens += 1
                st.failures = 0
                st.probing = false
            }
        } else {
            st.stats.succeeded += 1
            st.failures = 0
            if st.probing || st.openUntil != nil { st.openUntil = nil; st.openCount = 0; st.probing = false }
        }
        hosts[host] = st
        releaseSlot(host)
    }

    private var waiterID: UInt64 = 0

    private func waitForSlot(_ priority: MusicRequestPriority) async {
        waiterID += 1
        let id = waiterID
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in waiters.append(Waiter(id: id, priority: priority, continuation: c)) }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        if let i = waiters.firstIndex(where: { $0.id == id }) { waiters.remove(at: i).continuation.resume() }
    }
}

/// The last good reply per request key, bounded, so a network failure can still be answered (stale-while-error) without a disk read.
final class MusicResponseMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var order: [String] = []
    private let capacity: Int
    private let maxItemBytes: Int

    init(capacity: Int = 48, maxItemBytes: Int = 400_000) { self.capacity = max(4, capacity); self.maxItemBytes = maxItemBytes }

    func store(_ data: Data, for key: String) {
        guard data.count <= maxItemBytes else { return }
        lock.lock(); defer { lock.unlock() }
        if items[key] == nil { order.append(key) }
        items[key] = data
        while order.count > capacity { items[order.removeFirst()] = nil }
    }

    func data(for key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return items[key] }
    func removeAll() { lock.lock(); items.removeAll(); order.removeAll(); lock.unlock() }
}

/// The production transport: every request goes through the governor and then `MusicHTTP` (the app's HTTP client: proxy, secure DNS, redirect guard).
/// No `URLSession.shared` anywhere. The User-Agent is the one `MusicHTTP` already sends, which carries the project address and no personal detail.
struct MusicGovernedTransport: MusicMetadataTransport {
    var governor: MusicRequestGovernor
    var http: MusicHTTP
    var memory: MusicResponseMemory
    var background = false
    /// Where this transport's requests queue on a shared lane. Nil keeps the old rule (a background transport queues as background).
    var priority: MusicRequestPriority?

    init(governor: MusicRequestGovernor, http: MusicHTTP = MusicHTTP(), memory: MusicResponseMemory = MusicResponseMemory(), background: Bool = false, priority: MusicRequestPriority? = nil) {
        self.governor = governor; self.http = http; self.memory = memory; self.background = background; self.priority = priority
    }

    func get(_ url: URL, query: [String: String], headers: [String: String]) async throws -> Data {
        let host = MusicRequestGovernor.laneKey(for: url.host ?? "")
        let key = url.absoluteString + "?" + query.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: "&")
        let http = self.http, memory = self.memory
        let r = try await governor.perform(host: host, key: key, background: background, priority: priority,
                                           stale: { memory.data(for: key) },
                                           work: {
            let d = try await http.get(url, query: query, headers: headers)
            memory.store(d, for: key)
            return d
        })
        return r.data
    }
}
