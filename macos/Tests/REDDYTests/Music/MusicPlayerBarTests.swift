import Testing
import Foundation
@testable import REDDY

@Suite("Music player bar logic") struct MusicPlayerBarTests {
    // MARK: priority collapse

    private let all = Set(MusicBarControl.allCases)

    @Test func collapseFollowsThePriorityOrder() {
        // The budgets are the ones the live pill uses (`MusicPlayerBar.pillBudget`), not an unused table.
        let m = MusicBarCollapse.resolve(available: MusicPlayerBar.pillBudget(for: .medium), present: all)
        let e = MusicBarCollapse.resolve(available: MusicPlayerBar.pillBudget(for: .expanded), present: all)
        let w = MusicBarCollapse.resolve(available: MusicPlayerBar.pillBudget(for: .wide), present: all)
        #expect(m.shown.first == .queue)
        #expect(m.shown.count <= e.shown.count)
        #expect(e.shown.count <= w.shown.count)
        // What a pill shows is always the head of the priority list (the tail folds into the menu first), in every class.
        for r in [m, e, w] { #expect(r.shown == Array(MusicBarCollapse.priority.prefix(r.shown.count))) }
        #expect(Set(w.shown).union(w.overflow) == all)
    }

    @Test func compactClassShowsNoClusterAndKeepsEverythingReachable() {
        let r = MusicBarCollapse.resolve(available: 0, present: all)
        #expect(r.shown.isEmpty)
        #expect(Set(r.overflow) == all)
    }

    @Test func widerNeverShowsFewerAndNothingIsLost() {
        var last = 0
        for w in stride(from: CGFloat(0), through: 700, by: 4) {
            let r = MusicBarCollapse.resolve(available: w, present: all)
            #expect(r.shown.count >= last)
            #expect(Set(r.shown).union(r.overflow) == all)
            #expect(Set(r.shown).isDisjoint(with: r.overflow))
            last = r.shown.count
        }
    }

    @Test func absentControlsTakeNoRoom() {
        let present: Set<MusicBarControl> = [.queue, .lyrics]
        let r = MusicBarCollapse.resolve(available: 140, present: present)
        #expect(r.shown == [.queue, .lyrics] && r.overflow.isEmpty)
        #expect(MusicBarCollapse.resolve(available: .nan, present: present).shown.isEmpty)
    }

    @Test func barHeightsAreInTheDesignRange() {
        for cls in MusicLayoutClass.allCases {
            let h = MusicBarMetrics.height(for: cls)
            #expect(h >= 68 && h <= 80)
        }
        #expect(Set(MusicBarCollapse.priority) == all && Set(MusicBarCollapse.displayOrder) == all)
        #expect(MusicBarCollapse.compactShowsNext(width: 360) && !MusicBarCollapse.compactShowsNext(width: 300))
    }

    // MARK: scrub versus playback

    @Test func draggingShowsTheFingerNotPlayback() {
        var s = MusicScrubState()
        s.begin(0.2)
        s.update(0.6)
        #expect(s.isScrubbing)
        #expect(s.displayFraction(playback: 0.21, now: 0) == 0.6)
        #expect(s.displayFraction(playback: 0.9, now: 5) == 0.6)
    }

    @Test func releaseHoldsTheTargetUntilPlaybackArrives() {
        var s = MusicScrubState()
        s.begin(0.1)
        #expect(s.end(0.7, now: 10) == 0.7)
        #expect(!s.isScrubbing)
        #expect(s.displayFraction(playback: 0.1, now: 10.3) == 0.7)
        #expect(s.displayFraction(playback: 0.69, now: 10.4) == 0.69)
        s.settle(playback: 0.7, now: 10.5)
        #expect(s.pendingFraction == nil)
        #expect(s.displayFraction(playback: 0.72, now: 10.6) == 0.72)
    }

    @Test func aSeekThatNeverArrivesStopsHoldingAfterTheTimeout() {
        var s = MusicScrubState()
        s.begin(0.5)
        _ = s.end(nil, now: 0)
        #expect(s.displayFraction(playback: 0.1, now: 0.5) == 0.5)
        #expect(s.displayFraction(playback: 0.1, now: MusicScrubState.settleTimeout + 0.1) == 0.1)
        s.settle(playback: 0.1, now: MusicScrubState.settleTimeout + 0.1)
        #expect(s.pendingFraction == nil)
    }

    @Test func endWithoutADragDoesNothingAndCancelClears() {
        var s = MusicScrubState()
        #expect(s.end(0.4, now: 0) == nil)
        s.begin(0.3)
        s.cancel()
        #expect(!s.isScrubbing && s.pendingFraction == nil)
        #expect(MusicScrubState.clamp(1.7) == 1 && MusicScrubState.clamp(-1) == 0 && MusicScrubState.clamp(.nan) == 0)
        #expect(MusicScrubState.nudged(0.5, forward: true) > 0.5 && MusicScrubState.nudged(0.0, forward: false) == 0)
        #expect(MusicScrubState.paged(0.5, forward: true) == 0.7 && MusicScrubState.paged(0.1, forward: false) == 0 && MusicScrubState.paged(0.95, forward: true) == 1)
        #expect(MusicScrubState.paged(0.5, forward: true) > MusicScrubState.nudged(0.5, forward: true))
    }

    @Test func timeLabelsKeepAStableWidth() {
        #expect(MusicBarTimeLabel.width(forDuration: 200) == MusicBarTimeLabel.width(forDuration: 3000))
        #expect(MusicBarTimeLabel.width(forDuration: 4000) > MusicBarTimeLabel.width(forDuration: 200))
    }

    // MARK: marquee

    @Test func marqueeRestsThenScrollsThenRests() {
        let w: CGFloat = 300
        #expect(MusicMarqueeSchedule.offset(elapsed: 0.5, textWidth: w) == 0)
        #expect(MusicMarqueeSchedule.offset(elapsed: MusicMarqueeSchedule.initialRest, textWidth: w) == 0)
        let moving = MusicMarqueeSchedule.offset(elapsed: MusicMarqueeSchedule.initialRest + 2, textWidth: w)
        #expect(abs(moving + 2 * MusicMarqueeMath.speed) < 0.01)
        let pass = MusicMarqueeSchedule.passDuration(textWidth: w)
        #expect(MusicMarqueeSchedule.offset(elapsed: MusicMarqueeSchedule.initialRest + pass + 1, textWidth: w) == 0)
    }

    @Test func marqueeStopsAfterItsPassesAndNeverMovesForShortText() {
        let w: CGFloat = 200
        let total = MusicMarqueeSchedule.totalDuration(textWidth: w)
        #expect(MusicMarqueeSchedule.isFinished(elapsed: total, textWidth: w))
        #expect(!MusicMarqueeSchedule.isFinished(elapsed: total - 1, textWidth: w))
        #expect(MusicMarqueeSchedule.offset(elapsed: total + 10, textWidth: w) == 0)
        #expect(MusicMarqueeSchedule.offset(elapsed: 5, textWidth: 0) == 0)
        #expect(MusicMarqueeSchedule.offset(elapsed: .nan, textWidth: w) == 0)
    }

    @Test func marqueeRunUsesAnInjectedClock() {
        var run = MusicMarqueeRun(startedAt: 100)
        #expect(run.elapsed(at: 99) == 0)
        #expect(run.offset(at: 101, textWidth: 300) == 0)
        let t = 100 + MusicMarqueeSchedule.initialRest + 1
        #expect(run.offset(at: t, textWidth: 300) < 0)
        run.restart(at: t)
        #expect(run.offset(at: t + 0.5, textWidth: 300) == 0)
        #expect(run.isFinished(at: t + MusicMarqueeSchedule.totalDuration(textWidth: 300), textWidth: 300))
    }

    // MARK: quality facts

    @Test func lossyStreamShowsOnlyWhatItReports() {
        let f = MusicQualityFacts.make(stream: MusicStream(url: "u", codec: "aac", container: "m4a", bitrate: 256))
        #expect(f.chip == "AAC 256 kbps")
        #expect(f.rows.map(\.id) == ["codec", "container", "bitrate", "delivery"])
        #expect(!f.isVerifiedLossless)
    }

    @Test func losslessNeedsALosslessCodecAndAStreamThatSaysSo() {
        let flac = MusicQualityFacts.make(stream: MusicStream(url: "u", codec: "flac", container: "flac", sampleRate: 44100))
        #expect(flac.isVerifiedLossless && flac.chip == "FLAC 44.1 kHz")
        #expect(flac.rows.map(\.id).contains("lossless") && flac.rows.map(\.id).contains("sampleRate"))
        // A sample rate without a bitrate is not proof: an AAC stream like that is not called lossless.
        let aac = MusicQualityFacts.make(stream: MusicStream(url: "u", codec: "aac", container: "m4a", sampleRate: 48000))
        #expect(!aac.isVerifiedLossless && !aac.rows.map(\.id).contains("lossless"))
        #expect(aac.chip == "AAC")
        // A lossless codec that also reports a bitrate is lossy as far as the stream says.
        let odd = MusicQualityFacts.make(stream: MusicStream(url: "u", codec: "flac", container: "flac", bitrate: 900, sampleRate: 44100))
        #expect(!odd.isVerifiedLossless)
    }

    @Test func nothingIsInventedWhenTheStreamIsSilent() {
        let none = MusicQualityFacts.make(stream: nil)
        #expect(none.rows.isEmpty && none.chip == nil)
        let blank = MusicQualityFacts.make(stream: MusicStream(url: "u", codec: "", container: ""))
        #expect(blank.chip == nil)
        #expect(!blank.rows.map(\.id).contains("bitrate") && !blank.rows.map(\.id).contains("sampleRate"))
        // Bit depth is not exposed by the stream, so no row ever carries it.
        let rich = MusicQualityFacts.make(stream: MusicStream(url: "u", codec: "flac", container: "flac", sampleRate: 96000), effectsActive: true, route: "Desk speakers")
        #expect(!rich.rows.contains { $0.id == "bitDepth" })
        #expect(rich.rows.map(\.id).suffix(2) == ["route", "effects"])
    }

    @Test func routeFollowsTheResolvedOutput() {
        #expect(MusicOutputRoute.label(resolution: .device("x"), chosenName: "Desk speakers") == "Desk speakers")
        #expect(MusicOutputRoute.label(resolution: .systemDefault, chosenName: "Desk speakers") == MusicOutputRoute.label(resolution: .yieldedMissing("x"), chosenName: nil))
    }

    // MARK: now playing

    @Test func artworkFillsThePanelUpToFiveHundred() {
        #expect(MusicNowPlayingMetrics.artworkSize(panelWidth: 340) == 340 - MusicNowPlayingMetrics.sideMargin * 2)
        #expect(MusicNowPlayingMetrics.sideMargin == MusicSpace.md)
        #expect(MusicNowPlayingMetrics.artworkSize(panelWidth: 560) == 500)
        #expect(MusicNowPlayingMetrics.artworkSize(panelWidth: 280) == 248)
        #expect(MusicNowPlayingMetrics.artworkSize(panelWidth: 0) == 0 && MusicNowPlayingMetrics.artworkSize(panelWidth: .nan) == 0)
    }

    @Test func versionLabelsComeFromTheTrack() {
        var t = MusicTrack(id: "1", providerID: "p", title: "T", durationMs: 1000, artists: [])
        #expect(MusicNowPlayingMetrics.versionLabels(t).isEmpty)
        t.explicit = true
        #expect(MusicNowPlayingMetrics.versionLabels(t).count == 1)
        t.isVideo = true
        #expect(MusicNowPlayingMetrics.versionLabels(t).count == 2)
    }

    @Test func focusRingShowsOnlyForKeyboardFocus() {
        #expect(MusicBarFocusRing.visible(focused: true, keyboard: true))
        #expect(!MusicBarFocusRing.visible(focused: true, keyboard: false))
        #expect(!MusicBarFocusRing.visible(focused: false, keyboard: true))
        #expect(MusicBarFocusRing.lineWidth(increasedContrast: true) > MusicBarFocusRing.lineWidth(increasedContrast: false))
    }

    @Test func panelHeaderKeepsRoomForHeartAndMenu() {
        for panel: CGFloat in [300, 380] {
            let art = MusicNowPlayingMetrics.artworkSize(panelWidth: panel)
            let title = MusicNowPlayingMetrics.headerTitleMaxWidth(headerWidth: art)
            #expect(title + MusicTokens.hitTarget * 2 + MusicNowPlayingMetrics.headerGap * 2 <= art)
            #expect(art + MusicNowPlayingMetrics.sideMargin * 2 <= panel)
        }
    }
}
