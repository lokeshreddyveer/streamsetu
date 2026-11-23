import Testing
import Foundation
@testable import REDDY

/// Hub budgets under load with a manual clock: no sleeps, no network.
@Suite("Hub resilience quality") struct QualityHubLoadTests {
    struct RNG: RandomNumberGenerator { var s: UInt64; mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) } }
    final class Clock: @unchecked Sendable { private let l = NSLock(); private var t = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { l.withLock { t } }; func advance(_ s: TimeInterval) { l.withLock { t = t.addingTimeInterval(s) } } }
    final class Shared<T>: @unchecked Sendable { private let l = NSLock(); var v: T; init(_ v: T) { self.v = v }; func with<R>(_ f: (inout T) -> R) -> R { l.withLock { f(&v) } } }

    @Test func tokenBucketNeverGrantsMoreThanBurstPlusRefill() {
        let steps = ProcessInfo.processInfo.environment["STREAMSETU_PERF"] == "1" ? 200_000 : 800
        for p in [HubPolicy.tmdb, .fanart, .tvdb, .tvmaze] {
            var rng = RNG(s: 42); let clock = Clock(); let start = clock.now
            var b = TokenBucket(p, now: start); var granted = 0
            for _ in 0..<steps {
                clock.advance(Double.random(in: 0...0.5, using: &rng))
                if b.take(now: clock.now) == 0 { granted += 1 }
                #expect(b.tokens >= 0 && b.tokens <= Double(p.burst))
            }
            let bound = Double(p.burst) + p.refillPerSecond * clock.now.timeIntervalSince(start)
            #expect(Double(granted) <= bound + 1e-6, "\(p)")
        }
    }

    @Test func tokenBucketWaitHintIsHonest() {
        let clock = Clock(); var b = TokenBucket(capacity: 1, refillPerSecond: 2, now: clock.now)
        #expect(b.take(now: clock.now) == 0)
        let wait = b.take(now: clock.now)
        #expect(abs(wait - 0.5) < 1e-9)
        clock.advance(wait); #expect(b.take(now: clock.now) == 0)
        clock.advance(-100); _ = b.take(now: clock.now)       // a clock that jumps back never mints tokens
        #expect(b.tokens <= 1)
    }

    @Test func breakerLetsExactlyOneProbeThroughFromManyThreads() async {
        let clock = Clock(); let br = Shared(CircuitBreaker())
        for _ in 0..<CircuitBreaker.threshold { br.with { $0.failure(now: clock.now) } }
        #expect(br.with { $0.allow(now: clock.now) } == false)
        clock.advance(CircuitBreaker.openFor + 1)
        let admitted = await withTaskGroup(of: Int.self) { g in
            for _ in 0..<64 { g.addTask { br.with { $0.allow(now: clock.now) } ? 1 : 0 } }
            return await g.reduce(0, +)
        }
        #expect(admitted == 1)
        br.with { $0.failure(now: clock.now) }                      // the probe failed: closed to everyone again for the full period
        #expect(br.with { $0.allow(now: clock.now) } == false)
        clock.advance(CircuitBreaker.openFor + 1); _ = br.with { $0.allow(now: clock.now) }
        br.with { $0.success() }
        #expect(br.with { $0.allow(now: clock.now) } && br.with { $0.failures } == 0)
    }

    @Test func fanartNeverRunsBulkAndTheDailyCapBindsExpressToo() {
        let clock = Clock(); var q = HubQueue(policy: .fanart, now: clock.now)
        #expect(q.enqueue("a", lane: .bulk) == false)
        var served = 0
        for i in 0..<(HubPolicy.fanart.perDayCap + 20) {
            q.enqueue("k\(i)", lane: .express)
            if let n = q.next(now: clock.now) { served += 1; q.finish(n.key) }
        }
        #expect(served == HubPolicy.fanart.perDayCap)
        clock.advance(86_400 * 2)                                     // a new day resets the cap
        q.enqueue("again", lane: .express)
        #expect(q.next(now: clock.now)?.key == "again")
    }

    @Test func expressBeatsBulkAndNothingRunsTwice() {
        let clock = Clock(); var q = HubQueue(policy: .tvmaze, now: clock.now)
        for i in 0..<5 { q.enqueue("b\(i)", lane: .bulk) }
        q.enqueue("e", lane: .express); q.enqueue("b3", lane: .express)   // b3 is promoted, not duplicated
        var order: [String] = []
        while let n = q.next(now: clock.now) {
            #expect(q.inFlightExpress.count <= 1 && q.inFlightBulk.count <= HubPolicy.tvmaze.bulkWorkers)
            order.append(n.key); q.finish(n.key)
        }
        #expect(order.first == "b3" && Set(order).count == order.count && order.count == 6)
    }

    @Test func rateLimitBackoffDoublesAndIsCapped() {
        let a = (0...12).map { NegativeCache.backoff(retryAfter: nil, previousFailures: $0) }
        #expect(a.first == 10 && a.last == 900 && zip(a, a.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(NegativeCache.backoff(retryAfter: 5000, previousFailures: 0) == 900)
    }

    @Test func builtInKeyPauseExpiresOnTheClockAndNeverPausesOwnKeys() throws {
        let name = "quality.pause.\(UUID().uuidString)"; let d = try #require(UserDefaults(suiteName: name)); defer { d.removePersistentDomain(forName: name) }
        let clock = Clock(); let p = BuiltInKeyPause(storageKey: "k", defaults: d, now: { clock.now })
        p.reportRefused(ownKeyInUse: true); #expect(!p.isPaused)
        p.reportRefused(ownKeyInUse: false); #expect(p.isPaused)
        clock.advance(Retention.builtInKeyPause - 1); #expect(p.isPaused)
        clock.advance(2); #expect(!p.isPaused)
    }
}
