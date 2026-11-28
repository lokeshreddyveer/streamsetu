import Testing
import Foundation
@testable import REDDY

// Pure logic of the Music accessibility foundation: text step maths, hit targets, contrast thresholds and the announcer's debounce.

@MainActor
struct MusicAccessibilityTests {
    final class Clock { var now: TimeInterval = 100 }

    private func announcer(_ clock: Clock, _ spoken: Box) -> MusicAnnouncer {
        MusicAnnouncer(window: 1, clock: { clock.now }, autoFlush: false, post: { spoken.items.append($0) })
    }
    final class Box { var items: [String] = [] }

    private func snap(_ id: String?, playing: Bool, seeking: Bool = false) -> MusicAnnouncer.Snapshot {
        .init(trackID: id, title: "Song \(id ?? "")", artist: "Artist", isPlaying: playing, isSeeking: seeking)
    }

    @Test func textStepScalesRoles() {
        #expect(MusicTextStep.standard.size(for: .body) == 13)
        #expect(MusicTextStep.largest.size(for: .body) > MusicTextStep.large.size(for: .body))
        #expect(MusicTextStep.small.size(for: .display) < 34)
        #expect(MusicTextStep(raw: 99) == .standard)
        let scales = MusicTextStep.allCases.sorted { $0.rawValue < $1.rawValue }.map(\.scale)
        #expect(scales == scales.sorted())
        #expect(MusicAccessibility(textStep: .larger).scaled(MusicTypeRole.page) == 26 * 1.25)
    }

    @Test func hitTargetMaths() {
        #expect(MusicHitTarget.minimum(isMac: true) == 28)
        #expect(MusicHitTarget.minimum(isMac: false) == 44)
        #expect(MusicHitTarget.padding(forVisible: 16, minimum: 28) == 6)
        #expect(MusicHitTarget.padding(forVisible: 40, minimum: 28) == 0)
        #expect(MusicHitTarget.meets(width: 28, height: 30, minimum: 28))
        #expect(!MusicHitTarget.meets(width: 27, height: 40, minimum: 28))
    }

    @Test func contrastThresholds() {
        #expect(abs(MusicContrast.ratio(1, 0) - 21) < 0.001)
        #expect(MusicContrast.ratio(0.5, 0.5) == 1)
        #expect(MusicContrast.meets(1, 0.18, minimum: MusicContrast.textMinimum))
        #expect(MusicContrast.scrimLevel(forBackgroundLuminance: 0.05) == .whisper)
        #expect(MusicContrast.scrimLevel(forBackgroundLuminance: 1) == .heavy)
        let low = MusicContrast.scrimLevel(forBackgroundLuminance: 0.5)
        let high = MusicContrast.scrimLevel(forBackgroundLuminance: 0.5, increased: true)
        #expect(low.rawValue <= high.rawValue)
        #expect(MusicContrast.ratio(1, 0.5 * (1 - low.rawValue)) >= MusicContrast.textMinimum)
    }

    @Test func firstSnapshotOnlySetsBaseline() {
        let clock = Clock(), spoken = Box(), a = announcer(clock, spoken)
        a.observe(snap("a", playing: true))
        #expect(spoken.items.isEmpty)
    }

    @Test func neverAnnouncesOnTicks() {
        let clock = Clock(), spoken = Box(), a = announcer(clock, spoken)
        a.observe(snap("a", playing: true))
        for _ in 0..<500 { clock.now += 0.25; a.observe(snap("a", playing: true)) }
        #expect(spoken.items.isEmpty)
    }

    @Test func neverAnnouncesWhileSeeking() {
        let clock = Clock(), spoken = Box(), a = announcer(clock, spoken)
        a.observe(snap("a", playing: true))
        clock.now += 5
        a.observe(snap("a", playing: false, seeking: true))
        a.observe(snap("b", playing: true, seeking: true))
        #expect(spoken.items.isEmpty)
        clock.now += 5
        a.observe(snap("a", playing: true))
        #expect(spoken.items.isEmpty)
    }

    @Test func announcesPauseAndTrackChange() {
        let clock = Clock(), spoken = Box(), a = announcer(clock, spoken)
        a.observe(snap("a", playing: true))
        clock.now += 5
        a.observe(snap("a", playing: false))
        #expect(spoken.items == ["Paused"])
        clock.now += 5
        a.observe(snap("b", playing: true))
        #expect(spoken.items.count == 2)
        #expect(spoken.items[1].contains("Song b"))
    }

    @Test func debounceKeepsLatestAndFlushesAfterWindow() {
        let clock = Clock(), spoken = Box(), a = announcer(clock, spoken)
        a.observe(snap("a", playing: true))
        clock.now += 5
        a.observe(snap("a", playing: false))
        clock.now += 0.2
        a.observe(snap("a", playing: true))
        clock.now += 0.2
        a.observe(snap("b", playing: true))
        #expect(spoken.items.count == 1)
        a.flushPending()
        #expect(spoken.items.count == 1)
        clock.now += 1
        a.flushPending()
        #expect(spoken.items.count == 2)
        #expect(spoken.items[1].contains("Song b"))
    }

    @Test func sameTextInsideWindowIsDropped() {
        let clock = Clock(), spoken = Box(), a = announcer(clock, spoken)
        a.announce("Added to queue")
        clock.now += 0.3
        a.announce("Added to queue")
        clock.now += 2
        a.flushPending()
        #expect(spoken.items == ["Added to queue"])
    }

    @Test func lyricTimeLabel() {
        #expect(MusicLyricsA11y.timeLabel(65.9) == "1:05")
        #expect(MusicLyricsA11y.timeLabel(-3) == "0:00")
        #expect(MusicLyricsA11y.timeLabel(.nan) == "0:00")
    }

    @Test func checklistIsNotEmpty() { #expect(MusicA11yChecklist.items.count >= 10) }
}
