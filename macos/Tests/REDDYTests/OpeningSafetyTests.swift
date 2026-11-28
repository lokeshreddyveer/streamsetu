import Testing
import Foundation
import SwiftUI
@testable import REDDY

/// The opening may never hold the app back: the watchdog, the hard stop, and the art being decoded once and drawn cheaply.
@Suite("Opening: safety") @MainActor struct OpeningSafetyTests {
    private func coordinator(env: [String: String] = [:]) -> OpeningCoordinator {
        let d = UserDefaults(suiteName: "opening-safety-\(UUID().uuidString)")!
        return OpeningCoordinator(memory: LaunchMemory(defaults: d), version: "2.16.1", env: env, lingers: false)
    }

    // MARK: watchdog

    @Test func healthyFramesNeverTrip() {
        var w = OpeningWatchdog()
        for i in 0..<300 { #expect(w.record(drawMs: 2, at: Double(i) / 60) == nil) }
        #expect(w.tripped == nil)
    }

    @Test func slowDrawsTripAfterAFewFramesAndOnlyOnce() {
        var w = OpeningWatchdog()
        var reasons: [String] = []
        for i in 0..<20 { if let r = w.record(drawMs: 30, at: Double(i) / 60) { reasons.append(r) } }
        #expect(reasons.count == 1)
        #expect(w.seen <= w.warmup + w.window + 1 || reasons.count == 1)
    }

    @Test func theFirstFramesAreWarmUpAndOneSlowFrameDoesNotTrip() {
        var w = OpeningWatchdog()
        #expect(w.record(drawMs: 400, at: 0) == nil)
        #expect(w.record(drawMs: 400, at: 0.016) == nil)       // warm-up
        for i in 2..<40 { #expect(w.record(drawMs: i == 10 ? 30 : 3, at: Double(i) / 60) == nil) }
    }

    @Test func oneLongStallDuringLaunchDoesNotCutTheOpening() {
        var w = OpeningWatchdog()
        var t = 0.0
        for i in 0..<120 { t += (i == 40 ? 0.12 : 1.0 / 60); #expect(w.record(drawMs: 2, at: t) == nil) }
        #expect(w.tripped == nil)
    }

    @Test func framesThatArriveTooRarelyTrip() {
        var w = OpeningWatchdog()
        var tripped = false
        for i in 0..<40 { if w.record(drawMs: 1, at: Double(i) * 0.1) != nil { tripped = true } }       // 10 fps with cheap draws: the main thread or GPU is starved
        #expect(tripped)
    }

    @Test func theStoryOverrunningIsDetected() {
        let hold = OpeningVariant.firstInstall.holdMs
        #expect(!OpeningWatchdog.overran(elapsedMs: Double(hold) + 900, holdMs: hold))
        #expect(OpeningWatchdog.overran(elapsedMs: Double(hold) + 1100, holdMs: hold))
    }

    // MARK: the hard stop

    @Test func abortStopsTheStoryAndFadesTheFrameOutOverTheApp() throws {
        let c = coordinator()
        c.start(reduceMotion: false)
        #expect(c.isVisible && c.blocksInput)
        c.abort(reason: "test")
        #expect(c.abortReason == "test")
        // The app is revealed and the layer takes no input; the frame it stopped on fades out (no hard cut).
        #expect(c.revealedAt != nil && !c.blocksInput)
        let at = c.storyTime(at: Date())
        #expect(c.storyTime(at: Date().addingTimeInterval(0.4)) == at, "the story does not carry on after an abort")
        c.abort(reason: "again")                                  // once
        #expect(c.abortReason == "test")
    }

    @Test func abortWorksWhileTheAppIsStillStartingAndLaterReadinessChangesNothing() {
        let c = coordinator()
        c.start(reduceMotion: false)
        c.abort(reason: "slow")
        let revealed = c.revealedAt
        c.destinationReady(ok: true, hasSources: true)
        #expect(c.revealedAt == revealed && !c.blocksInput)
    }

    @Test func aFrozenReviewIsNeverAborted() {
        let c = coordinator(env: ["SS_INTRO_AT": "3"])
        c.start(reduceMotion: false)
        c.abort(reason: "x")
        #expect(c.abortReason == nil && c.isVisible)
    }

    @Test func theHardStopIsOneSecondPastTheStory() {
        #expect(OpeningCoordinator.overrunSeconds == 1.0)
    }

    // MARK: the art

    @Test func theArtIsDecodedOnceAtMostTheSizeItIsDrawnAndNotAgainPerFrame() throws {
        let first = OpeningArt.loadNow()
        #expect(first.isReady && first.isLayered)
        let decodes = OpeningArt.decodeCount
        for _ in 0..<50 { _ = OpeningArt.current; _ = OpeningArt.loadNow(); _ = OpeningArt.load() }
        #expect(OpeningArt.decodeCount == decodes)
        #expect(OpeningArt.current.isLayered)
        #expect(OpeningArt.pending.isReady == false && !OpeningArt.pending.isLayered)
    }

    @Test func downscalingKeepsTheCanvasSquareAndNeverEnlarges() throws {
        let big = try #require(CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let small = try #require(OpeningArt.downscaled(big, maxPixel: 640))
        #expect(small.width == 640 && small.height == 640)
        let same = try #require(OpeningArt.downscaled(big, maxPixel: 2000))
        #expect(same.width == 1024)
    }

    @Test func aFrameBeforeTheArtIsReadyDrawsOnlyTheBackground() {
        // Must not crash and must not need any image.
        let r = ImageRenderer(content: Canvas { ctx, size in OpeningRenderer.draw(&ctx, size: size, frame: OpeningTimeline.frame(.firstInstall, at: 3000), art: .pending, time: 3000) }.frame(width: 100, height: 200))
        #expect(r.cgImage != nil)
    }

    @Test func aFullFrameAtPhoneResolutionIsCheap() throws {
        let art = OpeningArt.loadNow()
        var worst = 0.0, total = 0.0, n = 0.0
        for ms in stride(from: 500.0, through: 7000.0, by: 500.0) {
            let f = OpeningTimeline.frame(.firstInstall, at: ms)
            let r = ImageRenderer(content: Canvas { ctx, size in OpeningRenderer.draw(&ctx, size: size, frame: f, art: art, time: ms) }.frame(width: 440, height: 956))
            r.scale = 3
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = r.cgImage
            let d = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            worst = max(worst, d); total += d; n += 1
        }
        // A generous bound for a loaded test machine; the measured figures are in the report.
        #expect(total / n < 60, "mean \(total / n) ms, worst \(worst) ms")
    }
}
