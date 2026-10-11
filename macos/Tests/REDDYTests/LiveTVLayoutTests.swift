import Testing
import Foundation
import CoreGraphics
@testable import REDDY

@Suite("Live TV layout and player ownership") @MainActor struct LiveTVLayoutTests {
    @Test func displayAspectUsesRealDimensionsAndFallsBackToSixteenNine() {
        #expect(LivePlayerLayout.displayAspect(width: 0, height: 0) == 16.0 / 9, "unknown size → the placeholder")
        #expect(abs(LivePlayerLayout.displayAspect(width: 1920, height: 1080) - 16.0 / 9) < 0.001)
        #expect(abs(LivePlayerLayout.displayAspect(width: 720, height: 576) - 1.25) < 0.001, "4:3-ish sources are not forced to 16:9")
        #expect(abs(LivePlayerLayout.displayAspect(width: 2560, height: 1080) - 2560.0 / 1080) < 0.001, "ultrawide")
        #expect(LivePlayerLayout.displayAspect(width: 1, height: 1000) == 16.0 / 9, "an implausible first report doesn't distort the layout")
    }

    @Test func stageUsesTheFullWidthAndKeepsTheAspectWhenHeightAllows() {
        let aspects: [CGFloat] = [16.0 / 9, 4.0 / 3, 21.0 / 9]
        for aspect in aspects {
            let s = LivePlayerLayout.stageSize(available: CGSize(width: 900, height: 900), aspect: aspect, reservedBelow: 64)
            #expect(s.width == 900, "full width")
            #expect(abs(s.width / s.height - aspect) < 0.02, "height follows the picture's aspect (\(aspect)) → \(s)")
        }
    }

    @Test func heightLimitsTheStageButNeverBelowItsMinimumOrAboveWhatIsAvailable() {
        let tall = LivePlayerLayout.stageSize(available: CGSize(width: 1200, height: 500), aspect: 16.0 / 9, reservedBelow: 150)
        #expect(tall.height == 350 && tall.width == 1200, "16:9 at 1200 wide would be 675 high; only 350 remain after the info area")
        let tiny = LivePlayerLayout.stageSize(available: CGSize(width: 600, height: 120), aspect: 16.0 / 9, reservedBelow: 64)
        #expect(tiny.height == LivePlayerLayout.minStageHeight, "never collapses below the minimum")
        let zero = LivePlayerLayout.stageSize(available: .zero, aspect: 16.0 / 9, reservedBelow: 64)
        #expect(zero.width == 0 && zero.height >= 0)
    }

    @Test func stageIsStableForTheSameInputs() {
        let a = LivePlayerLayout.stageSize(available: CGSize(width: 777, height: 640), aspect: 16.0 / 9, reservedBelow: 64)
        let b = LivePlayerLayout.stageSize(available: CGSize(width: 777, height: 640), aspect: 16.0 / 9, reservedBelow: 64)
        #expect(a == b, "no jitter, so no needless invalidation")
    }

    @Test func channelListStaysInRangeAndLeavesRoomForThePlayer() {
        #expect(LivePlayerLayout.channelListWidth(stored: 100, containerWidth: 1400) == 260)
        #expect(LivePlayerLayout.channelListWidth(stored: 900, containerWidth: 1400) == 360)
        #expect(LivePlayerLayout.channelListWidth(stored: 340, containerWidth: 1400) == 340)
        for w in [CGFloat(760), 840, 1000, 1256, 1500] {
            let list = LivePlayerLayout.channelListWidth(stored: 360, containerWidth: w)
            #expect(list >= 260 && list <= 360)
            if w >= 260 + LivePlayerLayout.minPlayerWidth { #expect(w - list >= LivePlayerLayout.minPlayerWidth, "player keeps ≥ \(LivePlayerLayout.minPlayerWidth) at width \(w)") }
        }
    }

    @Test func miniPlayerIsHiddenWhileLiveTVShowsTheSameVideo() {
        func show(live: Bool, onLiveTV: Bool, preview: Bool, playing: Bool = true) -> Bool {
            LivePlayerLayout.shouldShowMiniPlayer(onLiveTV: onLiveTV, isLive: live, livePreviewVisible: preview, hasPlayback: playing)
        }
        #expect(!show(live: true, onLiveTV: true, preview: true), "duplicate of the preview")
        #expect(show(live: true, onLiveTV: false, preview: false), "navigated away: the strip appears")
        #expect(show(live: false, onLiveTV: true, preview: false), "a movie keeps its strip on Live TV")
        #expect(show(live: true, onLiveTV: true, preview: false), "no preview pane open (e.g. nothing selected) → strip shows")
        #expect(!show(live: true, onLiveTV: false, preview: false, playing: false), "nothing playing, nothing shown")
    }

    @Test func liveVideoLivesInThePreviewWhenOneIsShownAndInTheBarOtherwise() throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-lt-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let src = try c.sources.addM3U(name: "Local", url: "http://127.0.0.1:9/list.m3u")
        var ch = TestSupport.channel(src, "a", "Channel A"); ch.streamRef = "http://127.0.0.1:9/live/a.ts"
        try c.indexer.commitChannels(source: src, categories: [], channels: [ch])
        let stored = try #require(try c.catalog.channels(ChannelQuery(collapseVariants: false)).first)
        let p = c.playback
        p.play(channel: stored)
        let player = p.avPlayer, loads = p.loadCount
        #expect(p.surfaceOwner == .bar)
        p.livePreviewVisible = true; #expect(p.surfaceOwner == .embedded, "the Live TV preview holds the video")
        p.livePreviewVisible = false; #expect(p.surfaceOwner == .bar, "leaving Live TV hands it to the bar")
        p.livePreviewVisible = true
        #expect(p.avPlayer === player && p.loadCount == loads, "moving the video between views never restarts or recreates the player")
    }
}
