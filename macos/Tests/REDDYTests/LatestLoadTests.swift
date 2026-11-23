import Testing
import Foundation
@testable import REDDY

/// Holds a piece of blocking work until the test lets it go, so the order in which reads finish is chosen, not hoped for.
private final class Latch: @unchecked Sendable {
    private let sem = DispatchSemaphore(value: 0)
    func wait() { sem.wait() }
    func open() { sem.signal() }
}
private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

@MainActor @Suite("LatestLoad: stale results, cancellation, coalescing") struct LatestLoadTests {
    @Test func aSlowOlderReadCannotOverwriteANewerAnswer() async {
        let load = LatestLoad(), gate = Latch()
        var applied: [String] = []
        let a = load.run({ gate.wait(); return "old" }, apply: { applied.append($0) })
        let b = load.run({ "new" }, apply: { applied.append($0) })
        await b.value
        gate.open()                                   // the old read finishes last
        await a.value
        #expect(applied == ["new"])
    }

    @Test func cancelDropsWhatIsInFlight() async {
        let load = LatestLoad(), gate = Latch()
        var applied: [Int] = []
        let a = load.run({ gate.wait(); return 1 }, apply: { applied.append($0) })
        load.cancel()
        gate.open()
        await a.value
        #expect(applied.isEmpty)
        await load.run({ 2 }, apply: { applied.append($0) }).value
        #expect(applied == [2], "a request after a cancel works normally")
    }

    @Test func manyRequestsWhileOneRunsCostOneFollowUpAndTheLastChangeIsSeen() async {
        let load = LatestLoad(), gate = Latch(), runs = Counter()
        var applied: [Int] = []
        let work: @Sendable () -> Int = { let n = runs.next(); if n == 1 { gate.wait() }; return n }
        load.coalesced(work, apply: { applied.append($0) })
        for _ in 0..<5 { load.coalesced(work, apply: { applied.append($0) }) }
        gate.open()
        await load.settle()
        #expect(runs.value == 2, "six requests, one scan plus one follow-up")
        #expect(applied == [1, 2], "applied in order; the follow-up holds the newest state")
    }

    @Test func aRequestAfterCoalescedWorkEndedStartsAFreshScan() async {
        let load = LatestLoad(), runs = Counter()
        var applied: [Int] = []
        load.coalesced({ runs.next() }, apply: { applied.append($0) })
        await load.settle()
        load.coalesced({ runs.next() }, apply: { applied.append($0) })
        await load.settle()
        #expect(applied == [1, 2])
    }

    @Test func cancelDuringCoalescedWorkDropsItAndAllowsANewScan() async {
        let load = LatestLoad(), gate = Latch(), runs = Counter()
        var applied: [Int] = []
        load.coalesced({ let n = runs.next(); if n == 1 { gate.wait() }; return n }, apply: { applied.append($0) })
        load.cancel()
        gate.open()
        await load.settle()
        #expect(applied.isEmpty)
        load.coalesced({ runs.next() }, apply: { applied.append($0) })
        await load.settle()
        #expect(applied == [2])
    }
}

@MainActor @Suite("AppRouter: search flag") struct RouterSearchFlagTests {
    @Test func theFlagFollowsTheTextAndOnlyFlipsAtTheEdges() {
        let r = AppRouter()
        #expect(!r.isSearching)
        r.searchQuery = "  "; #expect(!r.isSearching)
        r.searchQuery = "h"; #expect(r.isSearching)
        r.searchQuery = "he"; #expect(r.isSearching)
        r.clearSearch(); #expect(!r.isSearching)
    }

    @Test func typingDoesNotInvalidateAViewThatOnlyReadsTheFlag() {
        let r = AppRouter()
        let invalidations = Counter()
        func track() { withObservationTracking { _ = r.isSearching } onChange: { _ = invalidations.next() } }
        track()
        r.searchQuery = "a"                                       // blank to text: flips
        #expect(invalidations.value == 1)
        track()
        r.searchQuery = "ab"; r.searchQuery = "abc"
        #expect(invalidations.value == 1, "more keystrokes while a search is open do not redraw it")
    }
}
