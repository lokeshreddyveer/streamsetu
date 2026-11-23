import Foundation

// Budgets, breaker, negative cache and the request queue: pure value types with an injected clock, so they are unit-tested without a network.

/// What one source may be asked, and how fast.
struct HubPolicy: Sendable, Equatable {
    var burst: Int
    var refillPerSecond: Double
    var bulkAllowed: Bool
    var bulkWorkers: Int
    var perRunCap: Int
    var perDayCap: Int
    /// How long stored data from this source is kept.
    var keep: TimeInterval

    static let day: TimeInterval = Retention.day
    /// TMDB keeps its own pacing (MetadataMatchService); these numbers only bound the hub's extra calls.
    static let tmdb = HubPolicy(burst: 5, refillPerSecond: 4, bulkAllowed: true, bulkWorkers: 1, perRunCap: 300, perDayCap: 5000, keep: Retention.maxKeep)
    /// fanart.tv's terms: no bulk crawling, no more requests than necessary. Express lane only (a title the person opened or that is on screen), at most 2 a second and a daily cap per install.
    static let fanart = HubPolicy(burst: 2, refillPerSecond: 2, bulkAllowed: false, bulkWorkers: 0, perRunCap: 150, perDayCap: 300, keep: Retention.maxKeep)
    /// TheTVDB says its answers may be cached "a week or even longer": 7 days, refreshed quietly.
    static let tvdb = HubPolicy(burst: 4, refillPerSecond: 2, bulkAllowed: true, bulkWorkers: 1, perRunCap: 300, perDayCap: 1500, keep: Retention.tvdbKeep)
    /// TVmaze: at most 10 calls per 10 seconds (half the documented floor), burst 5 then 0.5/s so any 10 s window holds at most 10, one bulk worker (embed calls are "unique" endpoints).
    static let tvmaze = HubPolicy(burst: 5, refillPerSecond: 0.5, bulkAllowed: true, bulkWorkers: 1, perRunCap: 200, perDayCap: 2000, keep: Retention.maxKeep)

    static func policy(for s: HubSource) -> HubPolicy {
        switch s { case .tmdb, .playlist: .tmdb; case .fanart: .fanart; case .tvdb: .tvdb; case .tvmaze: .tvmaze }
    }
    /// Daily schedule rows live 2 days.
    static let scheduleKeep: TimeInterval = 2 * day
}

struct TokenBucket: Sendable {
    let capacity: Double
    let refillPerSecond: Double
    private(set) var tokens: Double
    private(set) var last: Date

    init(capacity: Int, refillPerSecond: Double, now: Date) { self.capacity = Double(capacity); self.refillPerSecond = refillPerSecond; tokens = Double(capacity); last = now }
    init(_ p: HubPolicy, now: Date) { self.init(capacity: p.burst, refillPerSecond: p.refillPerSecond, now: now) }

    private mutating func refill(_ now: Date) {
        let dt = max(0, now.timeIntervalSince(last))
        tokens = min(capacity, tokens + dt * refillPerSecond); last = max(last, now)
    }
    /// Takes one token and returns 0, or returns how many seconds to wait before one is available (nothing taken).
    mutating func take(now: Date) -> TimeInterval {
        refill(now)
        if tokens >= 1 { tokens -= 1; return 0 }
        return (1 - tokens) / refillPerSecond
    }
}

struct CircuitBreaker: Sendable {
    enum State: Sendable, Equatable { case closed, open(until: Date), halfOpen }
    static let threshold = 5
    static let openFor: TimeInterval = 15 * 60
    private(set) var failures = 0
    private(set) var state: State = .closed
    private var probing = false

    /// Whether a request may go out now. After the open period exactly one probe is let through.
    mutating func allow(now: Date) -> Bool {
        switch state {
        case .closed: return true
        case .open(let until):
            if now >= until { state = .halfOpen; probing = true; return true }
            return false
        case .halfOpen:
            if probing { return false }
            probing = true; return true
        }
    }
    mutating func success() { failures = 0; state = .closed; probing = false }
    mutating func failure(now: Date) {
        probing = false
        failures += 1
        if state == .halfOpen || failures >= Self.threshold { state = .open(until: now.addingTimeInterval(Self.openFor)) }
    }
}

/// How long a miss is remembered.
enum NegativeCache {
    enum Outcome: Sendable, Equatable { case notFound, serverError, offline, rateLimited(retryAfter: TimeInterval?), ok }
    static let notFound: TimeInterval = 30 * 86400
    static let serverError: TimeInterval = 6 * 3600
    /// nil: remember nothing (offline just waits).
    static func missUntil(_ o: Outcome, now: Date) -> Date? {
        switch o {
        case .notFound: now.addingTimeInterval(notFound)
        case .serverError: now.addingTimeInterval(serverError)
        case .offline, .ok: nil
        case .rateLimited(let after): now.addingTimeInterval(min(max(after ?? 10, 1), 900))
        }
    }
    static func outcome(forStatus s: Int, retryAfter: TimeInterval?) -> Outcome {
        switch s { case 404: .notFound; case 429: .rateLimited(retryAfter: retryAfter); case 500...599: .serverError; default: .serverError }
    }
    /// Rate-limit back-off: Retry-After, else 10 s doubling to 15 minutes.
    static func backoff(retryAfter: TimeInterval?, previousFailures: Int) -> TimeInterval {
        if let r = retryAfter, r > 0 { return min(r, 900) }
        return min(900, 10 * pow(2, Double(max(0, previousFailures))))
    }
}

enum HubLane: Sendable, Equatable { case express, bulk }

/// The queue of one source: express (a title the person opened or sees) before bulk, de-duplicated, at most one express request in flight, caps per run and per day.
/// A source that forbids bulk (fanart.tv) refuses bulk work outright.
struct HubQueue: Sendable {
    let policy: HubPolicy
    private(set) var express: [String] = []
    private(set) var bulk: [String] = []
    private(set) var inFlightExpress: Set<String> = []
    private(set) var inFlightBulk: Set<String> = []
    private(set) var doneThisRun = 0
    private(set) var dayStart: Date
    private(set) var doneToday = 0

    init(policy: HubPolicy, now: Date) { self.policy = policy; dayStart = Calendar.current.startOfDay(for: now) }

    var inFlight: Int { inFlightExpress.count + inFlightBulk.count }

    /// Returns false when the work was refused (bulk not allowed, or already queued/in flight).
    @discardableResult mutating func enqueue(_ key: String, lane: HubLane) -> Bool {
        if inFlightExpress.contains(key) || inFlightBulk.contains(key) { return false }
        switch lane {
        case .express:
            bulk.removeAll { $0 == key }                       // promoted
            express.removeAll { $0 == key }; express.insert(key, at: 0)   // newest opened title first
            return true
        case .bulk:
            guard policy.bulkAllowed, !express.contains(key), !bulk.contains(key) else { return false }
            bulk.append(key); return true
        }
    }

    private mutating func rollDay(_ now: Date) {
        let d = Calendar.current.startOfDay(for: now)
        if d > dayStart { dayStart = d; doneToday = 0 }
    }
    var capReached: Bool { doneThisRun >= policy.perRunCap || doneToday >= policy.perDayCap }
    /// The daily cap binds express too; the run cap only bulk.
    mutating func next(now: Date) -> (key: String, lane: HubLane)? {
        rollDay(now)
        if doneToday >= policy.perDayCap { return nil }
        if inFlightExpress.isEmpty, !express.isEmpty {
            let k = express.removeFirst(); inFlightExpress.insert(k); return (k, .express)
        }
        if policy.bulkAllowed, doneThisRun < policy.perRunCap, inFlightBulk.count < policy.bulkWorkers, !bulk.isEmpty {
            let k = bulk.removeFirst(); inFlightBulk.insert(k); return (k, .bulk)
        }
        return nil
    }
    mutating func finish(_ key: String) {
        inFlightExpress.remove(key); inFlightBulk.remove(key); doneThisRun += 1; doneToday += 1
    }
    mutating func newRun() { doneThisRun = 0; bulk.removeAll() }
}
