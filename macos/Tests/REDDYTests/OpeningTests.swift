import Testing
import Foundation
import SwiftUI
@testable import REDDY

/// The opening's timeline against the canonical specification in motion/specification (shared with Android), the launch plan, and
/// the start-up state machine.
@Suite("Opening: Tune In") @MainActor struct OpeningSpecificationTests {
    private var specFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("motion/specification")
    }

    private func json(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: specFolder.appendingPathComponent(name))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func scenesAndDurationsMatchTheSpecification() throws {
        let spec = try json("opening-motion.json")
        #expect(spec["id"] as? String == "streamsetu.tune-in")
        #expect(spec["version"] as? Int == 4)
        let artboard = try #require(spec["artboard"] as? [String: Any])
        #expect(artboard["width"] as? Int == 1000 && artboard["height"] as? Int == 600)
        let variants = try #require(spec["variants"] as? [String: Any])
        for variant in OpeningVariant.allCases {
            let v = try #require(variants[variant.rawValue] as? [String: Any], "missing \(variant.rawValue)")
            #expect(v["durationMs"] as? Int == variant.durationMs, "\(variant.rawValue) duration")
            let scenes = try #require(v["scenes"] as? [[String: Any]])
            let fromSpec = scenes.map { OpeningScene(id: $0["name"] as? String ?? "", startMs: $0["startMs"] as? Int ?? -1, endMs: $0["endMs"] as? Int ?? -1) }
            #expect(fromSpec == variant.scenes, "\(variant.rawValue) scenes")
        }
    }

    @Test func geometryAndColoursMatchTheTokens() throws {
        let tokens = try json("design-tokens.json")
        let geo = try #require(tokens["geometry"] as? [String: Any])
        let mark = try #require(geo["mark"] as? [String: Double])
        let size = mark["size"]!
        #expect(OpeningGeometry.markRect == CGRect(x: mark["centerX"]! - size / 2, y: mark["centerY"]! - size / 2, width: size, height: size))
        #expect(OpeningGeometry.markCentre == CGPoint(x: mark["centerX"]!, y: mark["centerY"]!))
        #expect(Double(OpeningGeometry.wordmarkBaseline) == geo["wordmarkBaselineY"] as? Double)
        #expect(Double(OpeningGeometry.taglineBaseline) == geo["taglineBaselineY"] as? Double)
        let colours = try #require(tokens["color"] as? [String: String])
        #expect(colours["background"] == "#04090D" && colours["backgroundGlow"] == "#0A2A33" && colours["cream"] == "#F2EEE6")
    }

    @Test func keyframesMatchTheSpecification() throws {
        let spec = try json("opening-motion.json")
        func range(_ any: Any?) -> ClosedRange<Int>? { (any as? [Int]).flatMap { $0.count == 2 ? $0[0]...$0[1] : nil } }
        // The short cut.
        let s = try #require(spec["keyframesMs"] as? [String: Any]), k = try #require(OpeningVariant.standard.keys)
        #expect(s["dotAppears"] as? Int == k.dotAppears)
        #expect((s["lightSweepStart"] as? Int).flatMap { a in (s["lightSweepEnd"] as? Int).map { a...$0 } } == k.lightSweep)
        #expect(s["snowPeak"] as? Int == (k.snow.lowerBound + k.snow.upperBound) / 2)
        #expect(s["glint"] as? Int == k.glint)
        for (name, value) in [("antennaTwitch", k.antennaTwitch), ("screenWarm", k.screenWarm), ("ribbonRearDraw", k.ribbonRearDraw), ("ribbonFrontDraw", k.ribbonFrontDraw),
                              ("dotToPlay", k.dotToPlay), ("heroPressIn", k.heroPressIn), ("ribbonSheen", k.ribbonSheen), ("wordmark", k.wordmark),
                              ("tagline", k.tagline), ("matchCutExpand", k.matchCutExpand)] {
            #expect(range(s[name]) == value, "standard \(name)")
        }
        // The full story.
        let f = try #require(spec["keyframesMsFirstInstall"] as? [String: Any]), kf = try #require(OpeningVariant.firstInstall.keys)
        #expect(f["dotAppears"] as? Int == kf.dotAppears && f["glint"] as? Int == kf.glint)
        for (name, value) in [("lightSweep", kf.lightSweep), ("antennaTwitch", kf.antennaTwitch), ("snow", kf.snow), ("screenWarm", kf.screenWarm),
                              ("ribbonRearDraw", kf.ribbonRearDraw), ("ribbonFrontDraw", kf.ribbonFrontDraw), ("dotToPlay", kf.dotToPlay), ("heroPressIn", kf.heroPressIn),
                              ("ribbonSheen", kf.ribbonSheen), ("wordmark", kf.wordmark), ("tagline", kf.tagline), ("matchCutExpand", kf.matchCutExpand)] {
            #expect(range(f[name]) == value, "firstInstall \(name)")
        }
        #expect((spec["interaction"] as? String)?.hasPrefix("none") == true)
    }

    @Test func keyframesStayInsideTheStory() throws {
        for variant in [OpeningVariant.firstInstall, .standard] {
            let k = try #require(variant.keys)
            let story = 0...variant.holdMs
            for r in [k.lightSweep, k.antennaTwitch, k.snow, k.screenWarm, k.ribbonRearDraw, k.ribbonFrontDraw, k.dotToPlay, k.heroPressIn, k.ribbonSheen, k.wordmark, k.tagline] {
                #expect(story.contains(r.lowerBound) && story.contains(r.upperBound), "\(variant.rawValue) \(r)")
            }
            #expect(k.matchCutExpand == variant.holdMs...variant.durationMs)
            #expect(variant.scenes.last?.id == "matchCut" && variant.scenes.last?.endMs == variant.durationMs)
            // The hero beat (the press-in) lands inside the scene named for it; the rear ribbon starts before the front.
            let hero = try #require(variant.scenes.first { $0.id == "hero" })
            #expect(k.heroPressIn.lowerBound >= hero.startMs && k.heroPressIn.lowerBound < hero.endMs)
            #expect(k.ribbonRearDraw.lowerBound < k.ribbonFrontDraw.lowerBound)
            // The name and the line are fully there before the exit begins (readable for at least a quarter of a second).
            #expect(variant.holdMs - k.tagline.upperBound >= 0 && variant.holdMs - k.wordmark.upperBound >= 250)
        }
        #expect(OpeningVariant.reducedMotion.holdMs == 1000 && OpeningVariant.reducedMotion.exitMs == 400)
    }

    @Test func framesAreContinuousAndEndOnTheLockup() {
        for variant in [OpeningVariant.firstInstall, .standard] {
            var last = OpeningTimeline.frame(variant, at: 0)
            #expect(last.play == 0 && last.wordmark == 0 && last.setLight == 0)
            var ms = 1.0
            while ms <= Double(variant.durationMs) {
                let f = OpeningTimeline.frame(variant, at: ms)
                for (a, b) in [(f.setLight, last.setLight), (f.warm, last.warm), (f.ribbonFront, last.ribbonFront), (f.ribbonRear, last.ribbonRear), (f.play, last.play),
                               (f.wordmark, last.wordmark), (f.tagline, last.tagline), (f.push, last.push), (f.matchCut, last.matchCut)] {
                    #expect(abs(a - b) < 0.05, "\(variant.rawValue) jumps at \(ms) ms")
                }
                // The antennas never turn more than the 6 degrees the artwork allows.
                #expect(abs(f.twitchLeft) <= 6 && abs(f.twitchRight) <= 6)
                last = f
                ms += 1
            }
            var lockup = OpeningFrame.lockup
            #expect(OpeningTimeline.frame(variant, at: Double(variant.holdMs)) == lockup)
            lockup.matchCut = 1
            #expect(OpeningTimeline.frame(variant, at: 60_000) == lockup)
        }
        #expect(OpeningTimeline.frame(.reducedMotion, at: 0) == .lockup)
        #expect(OpeningTimeline.scene(.firstInstall, at: 4600) == "hero")
        #expect(OpeningTimeline.scene(.standard, at: 2000) == "hero")
        #expect(OpeningTimeline.scene(.standard, at: 2800) == nil)
    }

    // MARK: launch plan

    @Test func launchPlanForEachKindOfLaunch() {
        func plan(introDone: Bool, sources: Bool, seen: String?, reduced: Bool = false, suppressed: Bool = false, pref: OpeningPreference = .automatic) -> LaunchPlan {
            LaunchPlan.decide(introDone: introDone, hasSources: sources, seenVersion: seen, current: "2.16.1", reducedMotion: reduced, suppressed: suppressed, preference: pref)
        }
        // The first launch of a new install: the full story, then the welcome.
        #expect(plan(introDone: false, sources: false, seen: nil) == LaunchPlan(variant: .firstInstall, whatsNew: false, newInstall: true))
        // The first launch after an update (or of an install from before the opening existed): the short cut, then What's New.
        #expect(plan(introDone: true, sources: true, seen: "2.16.0") == LaunchPlan(variant: .standard, whatsNew: true, newInstall: false))
        #expect(plan(introDone: false, sources: true, seen: nil) == LaunchPlan(variant: .standard, whatsNew: true, newInstall: false))
        // Every other launch: the short cut.
        #expect(plan(introDone: true, sources: true, seen: "2.16.1") == LaunchPlan(variant: .standard, whatsNew: false, newInstall: false))
        #expect(plan(introDone: true, sources: false, seen: "2.16.1") == LaunchPlan(variant: .standard, whatsNew: false, newInstall: false))
        // Reduce Motion keeps the plan and shows the still lockup; Off plays nothing but keeps What's New.
        #expect(plan(introDone: true, sources: true, seen: "2.16.0", reduced: true) == LaunchPlan(variant: .reducedMotion, whatsNew: true, newInstall: false))
        #expect(plan(introDone: true, sources: true, seen: "2.16.0", pref: .off) == LaunchPlan(variant: nil, whatsNew: true, newInstall: false))
        // A test run or SS_SKIP_INTRO: nothing.
        #expect(plan(introDone: false, sources: false, seen: nil, suppressed: true) == .none)
        #expect(LaunchPlan.suppressed(["SS_SKIP_INTRO": "1"]) && LaunchPlan.suppressed(["XCTestConfigurationFilePath": "x"]) && !LaunchPlan.suppressed([:]))
        // The first frame, before the library is open.
        #expect(LaunchPlan.firstVariant(introDone: true, reducedMotion: false, suppressed: false) == .standard)
        #expect(LaunchPlan.firstVariant(introDone: false, reducedMotion: false, suppressed: false) == .firstInstall)
        #expect(LaunchPlan.firstVariant(introDone: false, reducedMotion: true, suppressed: false) == .reducedMotion)
        #expect(LaunchPlan.firstVariant(introDone: false, reducedMotion: false, suppressed: true) == nil)
        #expect(LaunchPlan.firstVariant(introDone: false, reducedMotion: false, suppressed: false, preference: .off) == nil)
    }

    // MARK: start-up state machine

    @Test func animationFirstThenStartUp() {
        var m = StartupMachine()
        m.start(); m.planned(.firstInstall)
        #expect(m.state == .animating)
        m.animationFinished()
        #expect(m.state == .awaitingDestination && !m.revealed)
        m.initFinished(ok: true)
        #expect(m.state == .transitioning && m.revealed)
        m.exitFinished()
        #expect(m.history == [.notStarted, .starting, .animating, .awaitingDestination, .ready, .transitioning, .completed])
    }

    @Test func startUpFirstThenAnimation() {
        var m = StartupMachine()
        m.start(); m.initFinished(ok: true); m.planned(.standard)
        #expect(m.state == .animating && !m.revealed)
        m.animationFinished()
        #expect(m.state == .transitioning)
        // Late or repeated events change nothing.
        m.animationFinished(); m.initFinished(ok: false)
        #expect(m.history.filter { $0 == .transitioning }.count == 1)
    }

    @Test func failureStillRevealsTheRecoveryScreen() {
        var m = StartupMachine()
        m.start(); m.planned(.firstInstall); m.animationFinished(); m.initFinished(ok: false)
        #expect(m.history.contains(.failed) && m.state == .transitioning)
    }

    @Test func noOpeningOnlyWaitsForStartUp() {
        var m = StartupMachine()
        m.start(); m.planned(nil)
        #expect(m.state == .initializing && m.animationDone)
        m.initFinished(ok: true)
        #expect(m.state == .transitioning)
    }

    @Test func theReducedMotionStillIsHeldLikeAnOpening() {
        var m = StartupMachine()
        m.start(); m.planned(.reducedMotion); m.initFinished(ok: true)
        #expect(m.state == .animating)
        m.animationFinished()
        #expect(m.state == .transitioning)
    }

    // MARK: the coordinator

    private func coordinator(introDone: Bool = false, seen: String? = nil, env: [String: String] = [:]) -> OpeningCoordinator {
        let d = UserDefaults(suiteName: "opening-\(UUID().uuidString)")!
        if introDone { d.set(true, forKey: "intro_done") }
        if let seen { d.set(seen, forKey: "whatsnew_seen_version") }
        return OpeningCoordinator(memory: LaunchMemory(defaults: d), version: "2.16.1", env: env, lingers: false)
    }

    @Test func theOpeningEndsOnTimeAloneAndNeverRestarts() throws {
        let c = coordinator()
        c.start(reduceMotion: false)
        #expect(c.variant == .firstInstall && c.isVisible && c.blocksInput)
        let first = c.startedAt
        c.start(reduceMotion: false)          // a rebuilt view or a new window asks again: nothing restarts
        #expect(c.startedAt == first)
        // Past the story's length the frame is the lockup, however late the frame is drawn.
        #expect(c.storyTime(at: first.addingTimeInterval(30)) == Double(OpeningVariant.firstInstall.storyMs))
        c.destinationReady(ok: true, hasSources: false)
        // The story's clock begins when the app's start-up is done (while the screen is still dark): its start is read after that.
        let begun = c.startedAt
        #expect(begun >= first)
        // Nothing ends it early: only the time.
        c.advance(to: begun.addingTimeInterval(Double(OpeningVariant.firstInstall.storyMs) / 1000 - 0.5))
        #expect(c.state == .animating)
        c.advance(to: begun.addingTimeInterval(Double(OpeningVariant.firstInstall.storyMs) / 1000 + 0.001))
        #expect(c.state == .transitioning)
        let revealed = try #require(c.revealedAt)
        #expect(c.layerOpacity(at: revealed) == 1)
        #expect(c.layerOpacity(at: revealed.addingTimeInterval(Double(c.exitMs(.firstInstall)) / 1000)) <= 0.0001)
        // Once the app is revealed the layer takes no input.
        #expect(!c.blocksInput)
    }

    @Test func anExistingInstallGetsTheShortCutAndATestRunNothing() {
        let same = coordinator(introDone: true, seen: "2.16.1")
        same.start(reduceMotion: false)
        #expect(same.variant == .standard)
        // An install from before the opening existed has playlists: decided while the screen is still dark, it gets the short cut.
        let old = coordinator()
        old.start(reduceMotion: false)
        old.destinationReady(ok: true, hasSources: true)
        #expect(old.variant == .standard)
        let test = coordinator(env: ["SS_SKIP_INTRO": "1"])
        test.start(reduceMotion: false)
        #expect(test.variant == nil && !test.isVisible)
    }

    #if os(macOS)
    @Test func theFinishedLogoHoldsForAMomentBeforeTheAppIsRevealed() throws {
        let d = UserDefaults(suiteName: "opening-\(UUID().uuidString)")!
        let c = OpeningCoordinator(memory: LaunchMemory(defaults: d), version: "2.16.1", env: [:])      // the hold is on
        c.start(reduceMotion: false)
        c.destinationReady(ok: true, hasSources: false)
        let begun = c.startedAt
        c.advance(to: begun.addingTimeInterval(Double(OpeningVariant.firstInstall.storyMs) / 1000 + 0.001))
        #expect(c.state == .transitioning)
        #expect(c.revealedAt == nil, "the story is over, but the logo is still held: the app is not revealed yet")
        #expect(c.blocksInput && c.isVisible)
        #expect(c.lingerSeconds(for: .firstInstall) > 1 && c.lingerSeconds(for: .standard) > 0.5 && c.lingerSeconds(for: .reducedMotion) == 0)
        // The watchdog's last guard waits for the hold too, so it cannot cut the logo short.
        #expect(c.lingerSeconds(for: .firstInstall) < 5)
    }
    #endif
}
