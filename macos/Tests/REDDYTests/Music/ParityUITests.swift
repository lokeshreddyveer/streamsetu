import Testing
import Foundation
@testable import REDDY

@MainActor
private final class FakeSleepPlayer: MusicSleepPlayback {
    var isPlaying = true
    var isBuffering = false
    var volume: Float = 0.8
    var position: TimeInterval = 0
    var duration: TimeInterval = 200
    var currentUID: String? = "p:1"
    var paused = 0
    func pause() { paused += 1; isPlaying = false }
}

@MainActor
private final class Clock {
    var t = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ s: TimeInterval) { t = t.addingTimeInterval(s) }
}

private func track(_ id: String, title: String = "Song", artist: String = "Artist", ms: Int64 = 200_000) -> MusicTrack {
    MusicTrack(id: id, providerID: "p", title: title, durationMs: ms, artists: [MusicArtistRef(id: "ar-" + artist, name: artist)])
}

@Suite("Sleep timer") @MainActor struct MusicSleepTimerTests {
    @Test func fadeIsFlatThenLinearToZero() {
        #expect(MusicSleepLogic.fadeFactor(remaining: 30) == 1)
        #expect(MusicSleepLogic.fadeFactor(remaining: 10) == 1)
        #expect(MusicSleepLogic.fadeFactor(remaining: 5) == 0.5)
        #expect(MusicSleepLogic.fadeFactor(remaining: 0) == 0)
        #expect(MusicSleepLogic.fadeFactor(remaining: -3) == 0)
        #expect(MusicSleepLogic.label(remaining: 65) == "1:05")
    }

    @Test func durationTimerFadesThenPausesAndRestoresVolume() {
        let clock = Clock(); let p = FakeSleepPlayer()
        let timer = MusicSleepTimer(player: p, now: { clock.t }, autoTick: false)
        timer.start(.minutes(15))
        #expect(timer.isRunning)
        clock.advance(15 * 60 - 20); timer.tick()
        #expect(p.volume == 0.8 && p.paused == 0)
        clock.advance(15); timer.tick()
        #expect(abs(p.volume - 0.4) < 0.001)
        clock.advance(5); timer.tick()
        #expect(p.paused == 1)
        #expect(p.volume == 0.8)
        #expect(!timer.isRunning && timer.remaining == nil)
    }

    @Test func endOfTrackFollowsThePlayersPosition() {
        let clock = Clock(); let p = FakeSleepPlayer()
        let timer = MusicSleepTimer(player: p, now: { clock.t }, autoTick: false)
        p.position = 50
        timer.start(.endOfTrack)
        #expect(timer.remaining == 150)
        p.position = 195; timer.tick()
        #expect(timer.remaining == 5 && p.paused == 0)
        p.position = 200; timer.tick()
        #expect(p.paused == 1 && !timer.isRunning)
    }

    @Test func endOfTrackPausesWhenTheTrackChanges() {
        let p = FakeSleepPlayer()
        let timer = MusicSleepTimer(player: p, autoTick: false)
        timer.start(.endOfTrack)
        p.currentUID = "p:2"; timer.tick()
        #expect(p.paused == 1 && !timer.isRunning)
    }

    @Test func manualPauseCancelsAfterTwoQuietTicksAndKeepsVolume() {
        let p = FakeSleepPlayer()
        let timer = MusicSleepTimer(player: p, autoTick: false)
        timer.start(.minutes(30))
        p.isPlaying = false
        timer.tick(); #expect(timer.isRunning)
        timer.tick(); #expect(!timer.isRunning)
        #expect(p.paused == 0 && p.volume == 0.8)
    }

    @Test func cancelMidFadeRestoresVolume() {
        let clock = Clock(); let p = FakeSleepPlayer()
        let timer = MusicSleepTimer(player: p, now: { clock.t }, autoTick: false)
        timer.start(.minutes(15))
        clock.advance(15 * 60 - 4); timer.tick()
        #expect(p.volume < 0.8)
        timer.cancel()
        #expect(p.volume == 0.8 && !timer.isRunning)
    }

    @Test func endOfTrackRestoresVolumeWhenTheSongIsSoughtBackOutOfTheFade() {
        let p = FakeSleepPlayer()
        let timer = MusicSleepTimer(player: p, autoTick: false)
        timer.start(.endOfTrack)
        p.position = 195; timer.tick()
        #expect(p.volume < 0.8)
        p.position = 20; timer.tick()
        #expect(p.volume == 0.8 && p.paused == 0 && timer.isRunning)
    }

    @Test func endOfTrackFinishesWhenRepeatOneStartsTheSongAgain() {
        let p = FakeSleepPlayer()
        let timer = MusicSleepTimer(player: p, autoTick: false)
        timer.start(.endOfTrack)
        p.position = 199; timer.tick()
        p.position = 1; timer.tick()
        #expect(p.paused == 1 && !timer.isRunning && p.volume == 0.8)
    }
}

@Suite("Match overrides") @MainActor struct MatchOverrideTests {
    private func dir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("music-overrides-" + UUID().uuidString) }

    @Test func chooseThenResetAndPersist() {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        let t = track("1")
        let o = MusicMatchOverrides(directory: d, debounce: .milliseconds(1))
        #expect(o.override(for: t) == nil)
        let src = MusicAudioSource(id: "v9", providerID: "piped", title: "Song", artist: "Artist", durationMs: 200_000, externalURL: "https://example.test/v9", confidence: 0.9)
        o.choose(src, for: t)
        #expect(o.override(for: t)?.providerID == "piped" && o.override(for: t)?.sourceID == "v9")
        #expect(o.pageURL(for: t) == "https://example.test/v9")
        o.flush()
        let reopened = MusicMatchOverrides(directory: d)
        #expect(reopened.override(for: t)?.sourceID == "v9")
        reopened.reset(for: t)
        #expect(reopened.override(for: t) == nil && !reopened.hasOverride(for: t))
    }

    @Test func rankDropsDuplicatesAndSortsBestFirst() {
        let t = track("1", title: "Blue Sky", artist: "Ana")
        let good = MusicAudioSource(id: "a", providerID: "x", title: "Blue Sky", artist: "Ana", durationMs: 200_000, confidence: 0.9)
        let poor = MusicAudioSource(id: "b", providerID: "x", title: "Something else entirely", artist: "Other", durationMs: 90_000, confidence: 0.1)
        let ranked = MusicMatchOverrides.rank([[poor, good], [good]], for: t)
        #expect(ranked.map(\.id) == ["a", "b"])
    }
}

@Suite("Never-play list") struct BlacklistLogicTests {
    @Test func namesComeFromKnownTracksAndUnknownKeysShowAsIs() {
        let t = track("1", title: "Blue Sky", artist: "Ana")
        let rows = MusicBlacklistLogic.entries(keys: [t.uid, "ar-Ana", "zzz"], known: [t])
        #expect(rows.count == 3)
        #expect(rows.first { $0.key == t.uid }?.name == "Blue Sky")
        #expect(rows.first { $0.key == "ar-Ana" }?.kind == .artist)
        #expect(rows.first { $0.key == "zzz" }?.name == "zzz")
    }

    @Test func filterMatchesNameOrDetailIgnoringCase() {
        let t = track("1", title: "Blue Sky", artist: "Ana")
        let rows = MusicBlacklistLogic.entries(keys: [t.uid], known: [t])
        #expect(MusicBlacklistLogic.filter(rows, query: "blue").count == 1)
        #expect(MusicBlacklistLogic.filter(rows, query: "ANA").count == 1)
        #expect(MusicBlacklistLogic.filter(rows, query: "xyz").isEmpty)
        #expect(MusicBlacklistLogic.filter(rows, query: "  ").count == 1)
    }
}

@Suite("Parity navigation") struct ParityNavTests {
    @Test func devicesSectionAndBlacklistRouteExist() {
        #expect(MusicSection.allCases.contains(.devices))
        #expect(!MusicSection.devices.title.isEmpty && !MusicSection.devices.symbol.isEmpty)
        var nav = MusicNav()
        nav.push(.blacklist)
        #expect(nav.top == .blacklist && nav.canGoBack)
    }
}
