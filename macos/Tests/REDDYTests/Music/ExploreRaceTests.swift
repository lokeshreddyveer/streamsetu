import Foundation
import Testing
@testable import REDDY

@Suite("Explore deadline race and load gate") struct ExploreRaceTests {
    @Test func aFastAnswerWinsAndIsReturnedAtOnce() async throws {
        let v = try await MusicStreamResolver.withDeadline(5) { 42 }
        #expect(v == 42)
    }

    @Test func aSlowAnswerTimesOutWithoutWaitingForTheWork() async {
        let start = Date()
        do {
            _ = try await MusicStreamResolver.withDeadline(0.1) { () async throws -> Int in
                // Work that ignores cancellation and takes much longer than the deadline.
                await withCheckedContinuation { c in DispatchQueue.global().asyncAfter(deadline: .now() + 3) { c.resume() } }
                return 1
            }
            Issue.record("expected a timeout")
        } catch {
            var isTimeout = false
            if case MusicError.network(let m) = error { isTimeout = m == "timed out" }
            #expect(isTimeout, "only the deadline may end this call")
            #expect(Date().timeIntervalSince(start) < 1.5, "the caller must not wait for work that ignores cancellation")
        }
    }

    @Test func aWorkErrorComesThroughAsItIs() async {
        struct Boom: Error {}
        do { _ = try await MusicStreamResolver.withDeadline(5) { () async throws -> Int in throw Boom() }; Issue.record("expected an error") }
        catch { #expect(error is Boom) }
    }

    @Test func cancellingTheCallerEndsTheRace() async {
        let t = Task { () async -> Bool in
            do { _ = try await MusicStreamResolver.withDeadline(30) { () async throws -> Int in try await Task.sleep(nanoseconds: 20_000_000_000); return 1 }; return false }
            catch { return true }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        t.cancel()
        #expect(await t.value)
    }

    @Test func aBadDurationDoesNotCrash() async throws {
        // A deadline that is not a number counts as the shortest one: slow work times out at once instead of waiting for ever.
        let start = Date()
        var timedOut = false
        do {
            _ = try await MusicStreamResolver.withDeadline(.nan) { () async throws -> Int in
                await withCheckedContinuation { c in DispatchQueue.global().asyncAfter(deadline: .now() + 3) { c.resume() } }
                return 1
            }
        } catch MusicError.network(let m) { timedOut = m == "timed out" } catch { timedOut = false }
        #expect(timedOut)
        #expect(Date().timeIntervalSince(start) < 1.5)
    }

    @Test func theLoadGateNeverLetsMoreThanSixRunAtOnce() async {
        let gate = MusicExploreLoadGate()
        final class Counter: @unchecked Sendable { var now = 0, peak = 0; let l = NSLock()
            func enter() { l.lock(); now += 1; peak = max(peak, now); l.unlock() }
            func leave() { l.lock(); now -= 1; l.unlock() } }
        let c = Counter()
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<12 {
                g.addTask {
                    guard await gate.enter() else { return }; c.enter()
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    c.leave(); await gate.leave()
                }
            }
        }
        #expect(c.peak <= MusicExploreLoadGate.limit && c.peak >= 1, "peak was \(c.peak)")
    }

    @Test func aWaitingRowThatIsCancelledLeavesTheLineAtOnce() async {
        let gate = MusicExploreLoadGate()
        for _ in 0..<MusicExploreLoadGate.limit { _ = await gate.enter() }
        let waiter = Task { await gate.enter() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()
        let got = await waiter.value
        #expect(got == false)
        for _ in 0..<MusicExploreLoadGate.limit { await gate.leave() }
    }
}
