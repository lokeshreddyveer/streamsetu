import Testing
import Foundation
@testable import REDDY

// The lyrics panel must always end in a terminal state: lyrics, instrumental-or-none, or an offline/retry state. These tests drive the
// service's state machine (the thing the panel observes) with sources that hang, fail, or answer, on short real timings.

private enum FakeMode: Sendable { case hang, hangDeaf, fail, miss, hit }

private struct FakeLyricsSource: MusicLyricsProvider {
    var info: MusicProviderInfo
    var capabilities: MusicCapabilities { .lyrics }
    var mode: FakeMode

    init(id: String = MusicLyricsSources.lrclib, mode: FakeMode) {
        info = MusicProviderInfo(id: id, name: id, summary: "test"); self.mode = mode
    }

    func lyrics(for track: MusicTrack) async throws -> MusicLyrics? {
        switch mode {
        case .hang: while true { try await Task.sleep(nanoseconds: 50_000_000) }
        case .hangDeaf: await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }; return nil
        case .fail: throw MusicError.network("down")
        case .miss: return nil
        case .hit:
            return MusicLyrics(synced: [MusicLyricLine(timeMs: 1000, text: "first line here"), MusicLyricLine(timeMs: 5000, text: "second line here"),
                                        MusicLyricLine(timeMs: 9000, text: "third line here")], providerID: info.id)
        }
    }
}

private func track(_ n: Int = 1, title: String = "Song", seconds: Int64 = 200) -> MusicTrack {
    MusicTrack(id: "t\(n)", providerID: "audius", title: title, durationMs: seconds * 1000, artists: [MusicArtistRef(id: "a", name: "Artist")])
}

@MainActor
private func service(_ mode: FakeMode?, overall: Double = 1.5) -> MusicLyricsService {
    let reg = MusicRegistry(defaults: UserDefaults(suiteName: "lyr.\(UUID().uuidString)")!)
    if let mode {
        let p = FakeLyricsSource(mode: mode)
        reg.register(p)
        reg.setEnabled(true, id: p.id, reason: .setup)
    }
    let s = MusicLyricsService(registry: reg, cacheDirectory: nil)
    s.timing.overall = overall; s.timing.walkBudget = overall * 0.6; s.timing.mixBudget = overall * 0.3
    s.timing.cap = overall * 0.3; s.timing.stagger = 0.01
    return s
}

@MainActor
private func settle(_ s: MusicLyricsService, _ t: MusicTrack, within seconds: Double = 4) async -> (state: MusicLyricsLoadState, took: Double) {
    let start = Date()
    while !s.loadState(for: t).isTerminal, Date().timeIntervalSince(start) < seconds { try? await Task.sleep(nanoseconds: 20_000_000) }
    return (s.loadState(for: t), Date().timeIntervalSince(start))
}

@MainActor
struct LyricsTerminalStateTests {
    @Test func everySourceHangsStillEnds() async {
        let s = service(.hang), t = track()
        s.ensureLoaded(t)
        #expect(s.loadState(for: t) == .loading)
        let r = await settle(s, t)
        #expect(r.state.isTerminal)
        #expect(r.took < 3)
        if case .found = r.state { Issue.record("a hanging source cannot produce lyrics") }
    }

    @Test func aSourceThatIgnoresCancellationIsStillCut() async {
        let s = service(.hangDeaf), t = track()
        s.ensureLoaded(t)
        let r = await settle(s, t)
        #expect(r.state.isTerminal)
        #expect(r.took < 3)
    }

    @Test func allSourcesFailIsOfflineWithRetry() async {
        let s = service(.fail), t = track()
        s.ensureLoaded(t)
        let r = await settle(s, t)
        #expect(r.state == .none(.offline))
    }

    @Test func aHitIsFound() async {
        let s = service(.hit), t = track()
        s.ensureLoaded(t)
        let r = await settle(s, t)
        guard case .found(let l) = r.state else { Issue.record("expected lyrics"); return }
        #expect(l.isSynced)
    }

    @Test func aMissIsNotFound() async {
        let s = service(.miss), t = track()
        s.ensureLoaded(t)
        #expect(await settle(s, t).state == .none(.notFound))
    }

    @Test func noSourcesAtAllEndsNotOnTheSkeleton() async {
        let s = service(nil), t = track()
        s.ensureLoaded(t)
        #expect(await settle(s, t).state.isTerminal)
    }

    @Test func theViewGoingAwayDoesNotStrandTheState() async {
        // The view only calls ensureLoaded; cancelling the task that called it changes nothing, and calling again joins the same lookup.
        let s = service(.hit), t = track()
        let viewTask = Task { @MainActor in s.ensureLoaded(t); try? await Task.sleep(nanoseconds: 5_000_000_000) }
        viewTask.cancel()
        s.ensureLoaded(t)
        #expect(await settle(s, t).state.isTerminal)
        let again = Task { @MainActor in s.ensureLoaded(t) }
        again.cancel()
        await again.value
        if case .found = s.loadState(for: t) {} else { Issue.record("a re-created view must keep the finished state") }
    }

    @Test func trackChangeMidLoadKeepsBothStates() async {
        let s = service(.hit), a = track(1), b = track(2, title: "Other")
        s.ensureLoaded(a)
        s.ensureLoaded(b)
        let ra = await settle(s, a), rb = await settle(s, b)
        #expect(ra.state.isTerminal && rb.state.isTerminal)
    }

    @Test func aMissIsRememberedAndSearchAgainAsksAgain() async {
        let s = service(.miss), t = track()
        s.ensureLoaded(t)
        #expect(await settle(s, t).state == .none(.notFound))
        // Remembered: a second ask is answered at once, with no walk.
        s.ensureLoaded(t)
        #expect(s.loadState(for: t) == .none(.notFound))
        s.searchAgain(t)
        #expect(s.loadState(for: t) == .loading)
        #expect(await settle(s, t).state == .none(.notFound))
    }

    @Test func missTTLIsSixHours() {
        #expect(MusicLyricsCachePolicy.missTTL == 6 * 3600)
        let now = Date()
        #expect(MusicLyricsCachePolicy.isFresh(hit: false, fetchedAt: now.addingTimeInterval(-5 * 3600), now: now))
        #expect(!MusicLyricsCachePolicy.isFresh(hit: false, fetchedAt: now.addingTimeInterval(-7 * 3600), now: now))
    }

    @Test func mixDetection() {
        #expect(MusicLyricsMix.isLikelyMix(title: "Margib - 2021 Telugu Vibes Mixtape", durationSeconds: 675))
        #expect(MusicLyricsMix.isLikelyMix(title: "Anything", durationSeconds: 481))
        #expect(MusicLyricsMix.isLikelyMix(title: "Best Jukebox", durationSeconds: 200))
        #expect(MusicLyricsMix.isLikelyMix(title: "Non-Stop Hits", durationSeconds: 200))
        #expect(MusicLyricsMix.isLikelyMix(title: "Party Mashup", durationSeconds: 200))
        #expect(!MusicLyricsMix.isLikelyMix(title: "Bohemian Rhapsody", durationSeconds: 354))
    }

    @Test func aMixWithNoMatchIsNotAvailableForAMix() async {
        let s = service(.miss), t = track(title: "Telugu Vibes Mixtape", seconds: 675)
        s.ensureLoaded(t)
        #expect(await settle(s, t).state == .none(.mix))
    }

    @Test func aMixWithARealSyncedHitStillShowsIt() async {
        let s = service(.hit), t = track(title: "Telugu Vibes Mixtape", seconds: 675)
        s.ensureLoaded(t)
        guard case .found = await settle(s, t).state else { Issue.record("a real synced match must not be hidden"); return }
    }

    // MARK: the deadline helper on a virtual clock

    @Test func deadlineFiresOnTheInjectedClockWithoutWaiting() async {
        let gate = Locked<CheckedContinuation<Void, Never>?>(nil)
        let started = Date()
        let task = Task<Int?, Never> {
            await MusicDeadline.orNil(seconds: 12, sleep: { _ in await withCheckedContinuation { c in gate.mutate { $0 = c } } }) { () async -> Int in
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }   // never answers, ignores cancellation
                return 1
            }
        }
        while gate.value == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
        gate.value?.resume()   // the virtual 12 seconds pass
        let r = await task.value
        #expect(r == nil)
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func deadlineLetsAFastAnswerThrough() async {
        let r = await MusicDeadline.orNil(seconds: 12, sleep: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }) { () async -> Int in 7 }
        #expect(r == 7)
    }

    @Test func callerCancellationReleasesTheWaiter() async {
        let task = Task<Int?, Never> {
            await MusicDeadline.orNil(seconds: 60, sleep: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }) { () async -> Int in
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return 1
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        #expect(await task.value == nil)
    }

    // MARK: layout margins

    @Test func contextPanelBodyKeepsAMarginAtBothWidths() {
        for width in [300.0, 380.0] {
            let usable = width - 2 * Double(MusicSpace.md)
            #expect(usable > 0 && usable < width)
        }
        #expect(MusicLyricsSkeleton.blocks.flatMap { $0 }.allSatisfy { $0 <= 1.0 })
    }
}
