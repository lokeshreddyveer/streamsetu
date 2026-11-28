import Foundation
import Testing
@testable import REDDY

// Lyrics clock gating, the start/stall watchdog policy and page first paint that does not wait for enrichment.

struct AudibleClockTests {
    @Test func loadingNeverAdvances() {
        var c = MusicAudibleClock()
        c.observe(position: 0, at: 0)
        #expect(!c.advancing(wantsToPlay: true, loading: true, buffering: false, now: 5))
        #expect(c.state(wantsToPlay: true, loading: true, buffering: false, now: 5) == .loading)
    }
    @Test func pressedButNoSoundHolds() {
        var c = MusicAudibleClock()
        // The press set the intent; the player position never moved.
        for t in stride(from: 0.0, through: 6, by: 0.25) { c.observe(position: 0, at: t) }
        #expect(!c.advancing(wantsToPlay: true, loading: false, buffering: false, now: 6))
        #expect(c.state(wantsToPlay: true, loading: false, buffering: false, now: 6) == .buffering)
    }
    @Test func movingPositionAdvances() {
        var c = MusicAudibleClock()
        for i in 0..<8 { c.observe(position: Double(i) * 0.25, at: Double(i) * 0.25) }
        #expect(c.advancing(wantsToPlay: true, loading: false, buffering: false, now: 1.9))
    }
    @Test func stallHoldsAfterStaleWindow() {
        var c = MusicAudibleClock()
        for i in 0..<8 { c.observe(position: Double(i) * 0.25, at: Double(i) * 0.25) }
        #expect(c.advancing(wantsToPlay: true, loading: false, buffering: false, now: 2.5))
        #expect(!c.advancing(wantsToPlay: true, loading: false, buffering: false, now: 1.75 + MusicAudibleClock.staleSeconds + 0.1))
    }
    /// A stale buffering flag (a missed or reordered status change) does not hold the lyrics while the position is really moving.
    @Test func movingPositionBeatsStaleBufferingFlag() {
        var c = MusicAudibleClock()
        for i in 0..<4 { c.observe(position: Double(i) * 0.25, at: Double(i) * 0.25) }
        #expect(c.advancing(wantsToPlay: true, loading: false, buffering: true, now: 0.8))
        // Once the position stops, the same flag holds the line.
        #expect(!c.advancing(wantsToPlay: true, loading: false, buffering: true, now: 0.75 + MusicAudibleClock.staleSeconds + 0.1))
    }
    @Test func seekNeedsConfirmation() {
        var c = MusicAudibleClock()
        for i in 0..<4 { c.observe(position: Double(i) * 0.25, at: Double(i) * 0.25) }
        c.observe(position: 120, at: 1.0)
        #expect(!c.isMoving(now: 1.0))
        c.observe(position: 120.25, at: 1.25)
        #expect(c.isMoving(now: 1.25))
    }
    @Test func pausedAndIdle() {
        let c = MusicAudibleClock()
        #expect(c.state(wantsToPlay: false, loading: false, buffering: false, now: 0) == .paused)
        #expect(c.state(wantsToPlay: false, loading: true, buffering: false, now: 0) == .idle)
        #expect(MusicAudibleClock.State.buffering.holdNote != nil)
        #expect(MusicAudibleClock.State.playing.holdNote == nil)
    }
    /// The lyrics clock fed only while the audio clock runs does not run ahead of the song during a 10 s spinner.
    @Test func lyricsClockStaysAtZeroWhileNothingPlays() {
        var audio = MusicAudibleClock(), lyric = MusicLyricClock()
        for i in 0..<40 {
            let t = Double(i) * 0.25
            audio.observe(position: 0, at: t)
            let adv = audio.advancing(wantsToPlay: true, loading: i < 20, buffering: false, now: t)
            lyric.ingest(MusicLyricClockReading(positionMs: 0, takenAt: t, token: 0, advancing: adv))
        }
        #expect(lyric.lyricMs(at: 10) == 0)
    }
}

struct StartWatchdogTests {
    @Test func waitsThenNoticesThenFails() {
        let l = MusicStartWatchdog.Limits()
        #expect(MusicStartWatchdog.verdict(phase: .resolving, elapsed: 1, noticed: false) == .wait)
        if case .notice = MusicStartWatchdog.verdict(phase: .resolving, elapsed: l.resolve * 0.5, noticed: false) {} else { Issue.record("no notice") }
        #expect(MusicStartWatchdog.verdict(phase: .resolving, elapsed: l.resolve * 0.7, noticed: true) == .wait)
        if case .fail(let why) = MusicStartWatchdog.verdict(phase: .resolving, elapsed: l.resolve, noticed: true) { #expect(why.contains("No stream")) } else { Issue.record("no fail") }
    }
    @Test func everyPhaseFails() {
        for p in MusicStartWatchdog.Phase.allCases {
            let v = MusicStartWatchdog.verdict(phase: p, elapsed: 60, noticed: true)
            if case .fail = v {} else { Issue.record("phase \(p) never fails") }
        }
    }
    @Test func offlineIsNotJudged() {
        #expect(MusicStartWatchdog.verdict(phase: .awaitingSound, elapsed: 60, noticed: true, online: false) == .wait)
    }
    @Test func limitsAreShortEnough() {
        let l = MusicStartWatchdog.Limits()
        #expect(l.resolve <= 10 && l.awaitingSound <= 12 && l.midSongStall <= 15)
    }
}

struct FirstPaintTests {
    @Test func slowEnrichmentIsAbandonedAtTheDeadline() async {
        let t0 = Date()
        let r: [Int]? = await MusicFirstPaint.improved(deadline: 0.2) { try? await Task.sleep(nanoseconds: 5_000_000_000); return [1, 2, 3] }
        #expect(r == nil)
        #expect(Date().timeIntervalSince(t0) < 1.0)
    }
    @Test func fastEnrichmentIsReturned() async {
        let r: [Int]? = await MusicFirstPaint.improved(deadline: 2) { [1, 2, 3] }
        #expect(r == [1, 2, 3])
    }
    @Test func replaceRules() {
        #expect(!MusicFirstPaint.shouldReplace(painted: ["a", "b"], enriched: ["a", "b"]))
        #expect(!MusicFirstPaint.shouldReplace(painted: ["a", "b"], enriched: ["a"]))
        #expect(!MusicFirstPaint.shouldReplace(painted: ["a"], enriched: []))
        #expect(MusicFirstPaint.shouldReplace(painted: ["a", "b"], enriched: ["a", "b", "c"]))
    }
    /// The page paints the plain rows at once and does not wait for the (slow) enrichment.
    @Test func plainRowsDoNotWaitForEnrichment() async {
        let t0 = Date()
        let plain = ["a", "b"]   // painted at once
        let paintedAfter = Date().timeIntervalSince(t0)
        let better: [String]? = await MusicFirstPaint.improved(deadline: 0.1) { try? await Task.sleep(nanoseconds: 3_000_000_000); return ["a", "b", "c"] }
        #expect(paintedAfter < 0.05 && plain.count == 2 && better == nil)
    }
    @Test func boundedRunnerNeverExceedsLimit() async {
        final class Gauge: @unchecked Sendable { let l = NSLock(); var cur = 0, peak = 0
            func enter() { l.lock(); cur += 1; peak = max(peak, cur); l.unlock() }
            func leave() { l.lock(); cur -= 1; l.unlock() } }
        let g = Gauge()
        let jobs: [@Sendable () async -> Int] = (0..<12).map { i in { g.enter(); try? await Task.sleep(nanoseconds: 20_000_000); g.leave(); return i } }
        let out = await MusicBoundedRunner.run(jobs, limit: 3)
        #expect(out.compactMap { $0 } == Array(0..<12))
        #expect(g.peak <= 3)
    }
}

struct WatchdogTextTests {
    /// Every notice and hold note is a plain key that the hi and te files translate (the keys equal the English text).
    @Test func noticesAreStableKeys() {
        for p in MusicStartWatchdog.Phase.allCases { #expect(!MusicStartWatchdog.notice(p).contains("%")) }
        #expect(MusicAudibleClock.State.loading.holdNote == "Starting the song")
        #expect(MusicAudibleClock.State.buffering.holdNote == "Buffering")
    }
}

struct LyricClockOrderTests {
    @Test func olderDatesNeverMoveTheClockBack() {
        func run(_ dates: [Double]) -> Double {
            var c = MusicLyricClock()
            c.ingest(MusicLyricClockReading(positionMs: 0, takenAt: 0, token: 0, advancing: true))
            var last = 0.0
            for d in dates { last = c.positionMs(at: d) }
            return last
        }
        // Two timelines interleave: a 15 Hz driver and display-rate rows; the dates arrive out of order.
        let sorted = Array(stride(from: 0.0, through: 1.0, by: 1.0 / 30))
        var shuffled = sorted
        for i in stride(from: 1, to: shuffled.count - 1, by: 3) { shuffled.swapAt(i, i + 1) }
        let inOrder = run(sorted), jittered = run(shuffled)
        #expect(abs(inOrder - 1000) < 150)
        #expect(jittered <= inOrder + 1)   // never ahead because of out-of-order dates
        #expect(abs(jittered - inOrder) < 40)
    }
    @Test func positionIsMonotoneUnderInterleaving() {
        var c = MusicLyricClock()
        c.ingest(MusicLyricClockReading(positionMs: 0, takenAt: 0, token: 0, advancing: true))
        var prev = 0.0
        for i in 0..<200 {
            let t = Double(i / 2) * 0.02 + (i % 2 == 0 ? 0.0 : -0.01)   // pairs of dates, the second slightly older
            let p = c.positionMs(at: max(0, t))
            #expect(p >= prev - 0.0001); prev = p
        }
    }
}

struct RecencyAndFlightTests {
    @Test func recencyEvictsOldestAndSparesBusy() {
        var r = MusicRecency()
        for i in 0..<10 { r.touch("k\(i)") }
        r.touch("k0")   // k0 is now the newest
        let gone = r.evict(limit: 6, keeping: ["k1"])
        #expect(gone == ["k2", "k3", "k4", "k5"])
        #expect(r.count == 6 && r.contains("k0") && r.contains("k1") && !r.contains("k2"))
    }
    @Test func recencyBoundHoldsForALongSession() {
        var r = MusicRecency(); var dict: [String: Int] = [:]
        for i in 0..<5000 { let k = "u\(i)"; dict[k] = i; r.touch(k); for old in r.evict(limit: 300) { dict[old] = nil } }
        #expect(dict.count == 300 && r.count == 300)
    }
    @Test func lastWaiterCancelledCancelsTheLookup() async {
        let board = MusicFlightBoard<Int>()
        let flag = Flag()
        let waiter = Task { try await board.value(key: "a") { Task { try await Task.sleep(nanoseconds: 5_000_000_000); return 1 } } }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(board.isRunning("a") && board.waiters("a") == 1)
        waiter.cancel()
        _ = try? await waiter.value
        #expect(!board.isRunning("a"))
        flag.done = true
    }
    @Test func lookupSurvivesWhileAnotherWaiterRemains() async {
        let board = MusicFlightBoard<Int>()
        let first = Task { try await board.value(key: "b") { Task { try await Task.sleep(nanoseconds: 300_000_000); return 7 } } }
        try? await Task.sleep(nanoseconds: 30_000_000)
        let second = Task { try await board.value(key: "b") { Task { return 99 } } }
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(board.waiters("b") == 2)
        first.cancel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(board.isRunning("b") && board.waiters("b") == 1)
        let v = try? await second.value
        #expect(v == 7)
    }
    @Test func cancelAllByPrefixReachesTheTask() async {
        let board = MusicFlightBoard<Int>()
        let w = Task { try await board.value(key: "uid|q") { Task { try await Task.sleep(nanoseconds: 5_000_000_000); return 1 } } }
        try? await Task.sleep(nanoseconds: 30_000_000)
        board.cancelAll(prefix: "uid|")
        let t0 = Date()
        let r = try? await w.value
        #expect(r == nil && Date().timeIntervalSince(t0) < 1)
    }
    final class Flag: @unchecked Sendable { var done = false }
}
