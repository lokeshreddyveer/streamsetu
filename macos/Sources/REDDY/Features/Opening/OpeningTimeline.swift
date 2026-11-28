import Foundation

// The opening, "Tune In": the retro television is tuned in. In a dark room a teal glow rises in its glass and a single dot appears;
// light sweeps the silver body and the antennas twitch as if tuning, snow flickers and settles, the screen warms, the ribbon draws on
// and binds the set ("setu" = to bind), the dot becomes the cream play button with a small press-in, and the name and the line arrive
// beneath it. The first launch of a new install plays the full story (7.5 s); every other launch plays the short cut (2.8 s). It
// cannot be skipped and ends on elapsed time alone.
//
// This file is the timeline only: what is on screen at any moment, worked out from the time alone (nothing is carried from one frame
// to the next), so any frame can be drawn, tested or frozen for review. The tables must match motion/specification/opening-motion.json
// at the root of the repository (OpeningSpecificationTests fails when they drift apart). Shared by the Mac and the iPhone/iPad apps.

/// One scene's place in a variant, in milliseconds from the start.
struct OpeningScene: Equatable {
    let id: String
    let startMs: Int
    let endMs: Int
}

/// The beats of one variant, in milliseconds (the specification's keyframesMs blocks).
struct OpeningKeyframes: Equatable {
    /// When the dot appears; the silhouette of the set rises from here until the light sweep.
    var dotAppears: Int
    var lightSweep: ClosedRange<Int>
    var antennaTwitch: ClosedRange<Int>
    var snow: ClosedRange<Int>
    var screenWarm, ribbonRearDraw, ribbonFrontDraw, dotToPlay, heroPressIn: ClosedRange<Int>
    var glint: Int
    var ribbonSheen, wordmark, tagline, matchCutExpand: ClosedRange<Int>
    /// The anticipation breath: the camera eases back a little before the hero (full story only).
    var easeBack: ClosedRange<Int>?
}

/// The ways the opening plays.
enum OpeningVariant: String, CaseIterable {
    /// The full story, 7.5 s: the first launch of a new install (and "Replay the full story" in Settings).
    case firstInstall
    /// The short cut, 2.8 s: every other launch.
    case standard
    /// Reduce Motion: the finished lockup as a still for a second, then a fade.
    case reducedMotion

    var durationMs: Int {
        switch self { case .firstInstall: 7500; case .standard: 2800; case .reducedMotion: 1400 }
    }

    var scenes: [OpeningScene] {
        func s(_ id: String, _ a: Int, _ b: Int) -> OpeningScene { OpeningScene(id: id, startMs: a, endMs: b) }
        switch self {
        case .firstInstall:
            return [s("dark", 0, 500), s("glowDot", 500, 1500), s("sweepTwitch", 1500, 2500), s("warm", 2500, 3500), s("anticipation", 3500, 4500),
                    s("hero", 4500, 5000), s("sheen", 5000, 5500), s("wordmark", 5500, 6200), s("tagline", 6200, 7000), s("matchCut", 7000, 7500)]
        case .standard:
            return [s("dark", 0, 200), s("glowDot", 200, 700), s("sweepTwitch", 700, 1200), s("warmWrap", 1200, 1900), s("hero", 1900, 2150),
                    s("lockup", 2150, 2500), s("hold", 2500, 2650), s("matchCut", 2650, 2800)]
        case .reducedMotion:
            return [s("still", 0, 1000), s("fade", 1000, 1400)]
        }
    }

    var keys: OpeningKeyframes? {
        switch self {
        case .firstInstall:
            OpeningKeyframes(dotAppears: 500, lightSweep: 1500...2300, antennaTwitch: 1700...2200, snow: 1500...2500, screenWarm: 2500...3500,
                             ribbonRearDraw: 2500...3500, ribbonFrontDraw: 3500...4500, dotToPlay: 3500...4500, heroPressIn: 4500...4750, glint: 4750,
                             ribbonSheen: 5000...5500, wordmark: 5500...6200, tagline: 6200...7000, matchCutExpand: 7000...7500, easeBack: 3500...4500)
        case .standard:
            // The specification gives the snow as its peak (1000 ms); it rises and falls over 250 ms either side.
            OpeningKeyframes(dotAppears: 200, lightSweep: 700...1150, antennaTwitch: 850...1100, snow: 750...1250, screenWarm: 1100...1700,
                             ribbonRearDraw: 1150...1600, ribbonFrontDraw: 1400...1850, dotToPlay: 1500...1900, heroPressIn: 1900...2050, glint: 2000,
                             ribbonSheen: 2000...2400, wordmark: 2150...2400, tagline: 2250...2500, matchCutExpand: 2650...2800, easeBack: nil)
        case .reducedMotion: nil
        }
    }

    /// Where the story ends and the exit (the match-cut, or the fade) begins: the lockup holds here until the app is ready.
    var holdMs: Int { scenes.last?.startMs ?? 0 }

    /// The Mac's full story runs slower than the shared timeline, so each destination icon stays on screen long enough to be read: the same story, stretched by 40 %. The short cut
    /// (no icons) and Reduce Motion keep their pace. iPhone and iPad keep the shared pace.
    var macStretch: Double { self == .firstInstall ? 1.4 : 1 }

    /// How long the story itself takes on this platform, in milliseconds (before the logo's hold and the exit).
    var storyMs: Int {
        #if os(macOS)
        Int((Double(holdMs) * macStretch).rounded())
        #else
        holdMs
        #endif
    }
    /// How long the exit takes.
    var exitMs: Int { durationMs - holdMs }
}

/// Everything the renderer needs for one frame. Values are 0...1 unless said otherwise.
struct OpeningFrame: Equatable {
    /// How much light is on the set: a dim silhouette in the dark at first, full light once the ribbon has bound it.
    var setLight = 0.0
    /// The centre dot.
    var dot = 0.0
    /// The light band crossing the silver; negative when there is none.
    var sweep = -1.0
    /// The antennas' tuning twitch, in degrees (left and right), settling to 0.
    var twitchLeft = 0.0, twitchRight = 0.0
    var snow = 0.0
    var warm = 0.0
    var ribbonRear = 0.0, ribbonFront = 0.0
    /// The play button growing from its centre out of the dot.
    var play = 0.0
    /// The press-in of the hero beat (0 → 1 → 0).
    var press = 0.0
    var glint = 0.0
    /// The satin light travelling along the ribbon; negative when there is none.
    var sheen = -1.0
    var wordmark = 0.0, tagline = 0.0
    /// The teal screen expanding into the app.
    var matchCut = 0.0
    /// The camera's slow push (0...1 of 4 %), and the brief ease-back of the anticipation.
    var push = 0.0, easeBack = 0.0

    /// The finished lockup: the set, the name and the line, nothing moving.
    static let lockup = OpeningFrame(setLight: 1, warm: 1, ribbonRear: 1, ribbonFront: 1, play: 1, wordmark: 1, tagline: 1, push: 1)
}

enum OpeningEasing {
    static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    static func easeOut(_ x: Double) -> Double { let t = clamp(x); return 1 - pow(1 - t, 3) }
    static func cubicInOut(_ x: Double) -> Double { let t = clamp(x); return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    static func smoothstep(_ x: Double) -> Double { let t = clamp(x); return t * t * (3 - 2 * t) }
    /// Slow at both ends.
    static func slowInOut(_ x: Double) -> Double { let t = clamp(x); return 0.5 - 0.5 * cos(.pi * t) }
}

enum OpeningTimeline {
    private static func p(_ ms: Double, _ r: ClosedRange<Int>) -> Double {
        OpeningEasing.clamp((ms - Double(r.lowerBound)) / Double(max(1, r.upperBound - r.lowerBound)))
    }

    /// Progress through `r`, or -1 outside it (for effects that are only there while they pass).
    private static func inside(_ ms: Double, _ r: ClosedRange<Int>) -> Double {
        ms >= Double(r.lowerBound) && ms <= Double(r.upperBound) ? p(ms, r) : -1
    }

    /// A tuning twitch: a quick turn that overshoots a little and settles, never more than 6 degrees.
    static func twitch(_ q: Double, amplitude: Double, phase: Double) -> Double {
        guard q > 0, q < 1 else { return 0 }
        return amplitude * exp(-3.2 * q) * sin(2 * .pi * (2.1 * q + phase)) * (1 - q)
    }

    /// The frame at `ms` from the start of `variant`. Pure: the same time always gives the same frame. Past the hold the lockup stays,
    /// with only the match-cut moving.
    static func frame(_ variant: OpeningVariant, at ms: Double) -> OpeningFrame {
        guard let k = variant.keys else { return .lockup }
        typealias E = OpeningEasing
        if ms >= Double(variant.holdMs) {
            var f = OpeningFrame.lockup
            f.matchCut = E.cubicInOut(p(ms, k.matchCutExpand))
            return f
        }
        let silhouette = E.easeOut(p(ms, k.dotAppears...k.lightSweep.lowerBound))
        let warm = E.slowInOut(p(ms, k.screenWarm))
        let front = E.cubicInOut(p(ms, k.ribbonFrontDraw))
        let play = E.easeOut(p(ms, k.dotToPlay))
        let twitchP = inside(ms, k.antennaTwitch)
        let snowP = p(ms, k.snow)
        let glintSpan = max(150, (k.heroPressIn.upperBound - k.heroPressIn.lowerBound))
        let glintP = inside(ms, (k.glint - glintSpan / 2)...(k.glint + glintSpan / 2))
        let pressP = inside(ms, k.heroPressIn)
        var f = OpeningFrame()
        // The set stays dim until the ribbon has bound it, which also keeps the corner under the ribbon in shadow while it draws on.
        f.setLight = min(1, 0.22 * silhouette + 0.33 * warm + 0.45 * front)
        f.dot = E.easeOut(p(ms, k.dotAppears...(k.dotAppears + 250))) * (1 - play)
        let sweepP = inside(ms, k.lightSweep)
        f.sweep = sweepP < 0 ? -1 : E.cubicInOut(sweepP)
        f.twitchLeft = twitch(max(0, twitchP), amplitude: -5.5, phase: 0)
        f.twitchRight = twitch(max(0, twitchP), amplitude: 5, phase: 0.08)
        f.snow = snowP > 0 && snowP < 1 ? sin(.pi * snowP) : 0
        f.warm = warm
        f.ribbonRear = E.cubicInOut(p(ms, k.ribbonRearDraw))
        f.ribbonFront = front
        f.play = play
        f.press = pressP > 0 && pressP < 1 ? sin(.pi * E.easeOut(pressP)) : 0
        f.glint = glintP > 0 && glintP < 1 ? sin(.pi * glintP) : 0
        f.sheen = inside(ms, k.ribbonSheen)
        f.wordmark = E.easeOut(p(ms, k.wordmark))
        f.tagline = E.easeOut(p(ms, k.tagline))
        f.push = E.slowInOut(p(ms, k.dotAppears...variant.holdMs))
        f.easeBack = k.easeBack.map { sin(.pi * p(ms, $0)) } ?? 0
        return f
    }

    /// The scene playing at `ms`, or nil past the end.
    static func scene(_ variant: OpeningVariant, at ms: Int) -> String? {
        variant.scenes.first { ms >= $0.startMs && ms < $0.endMs }?.id
    }
}

// MARK: - What this launch shows

/// The "Opening" setting: Automatic (the launch plan below) or Off.
enum OpeningPreference: String, CaseIterable, Identifiable {
    case automatic, off
    var id: String { rawValue }
    var label: String { self == .automatic ? "Automatic" : "Off" }
    static let key = "settings.opening"
    static func stored(_ defaults: UserDefaults = .standard) -> OpeningPreference {
        defaults.string(forKey: key).flatMap(OpeningPreference.init(rawValue:)) ?? .automatic
    }
}

/// Which opening plays (none in a test run, or with the setting Off), and whether What's New follows it. Pure, so it can be tested.
struct LaunchPlan: Equatable {
    var variant: OpeningVariant?
    var whatsNew: Bool
    var newInstall: Bool

    static let none = LaunchPlan(variant: nil, whatsNew: false, newInstall: false)

    /// The first launch of a new install (no playlist ever added, the opening never seen) gets the full story; every other launch the
    /// short cut, and the first launch after an update the short cut then What's New. Reduce Motion shows the still. `suppressed`: a test
    /// run or SS_SKIP_INTRO. With the setting Off nothing plays, but What's New still follows an update.
    static func decide(introDone: Bool, hasSources: Bool, seenVersion: String?, current: String, reducedMotion: Bool, suppressed: Bool,
                       preference: OpeningPreference = .automatic) -> LaunchPlan {
        if suppressed { return .none }
        let newInstall = !introDone && !hasSources
        let update = !newInstall && hasSources && seenVersion != current
        let variant: OpeningVariant? = preference == .off ? nil : (reducedMotion ? .reducedMotion : (newInstall ? .firstInstall : .standard))
        return LaunchPlan(variant: variant, whatsNew: update, newInstall: newInstall)
    }

    /// The variant to start with on the first frame, before the library is open: the full story when the opening has never been seen.
    /// (Both variants begin in the dark, so the choice can still change to the short cut once the library shows playlists.)
    static func firstVariant(introDone: Bool, reducedMotion: Bool, suppressed: Bool, preference: OpeningPreference = .automatic) -> OpeningVariant? {
        if suppressed || preference == .off { return nil }
        if reducedMotion { return .reducedMotion }
        return introDone ? .standard : .firstInstall
    }

    /// A test run, or `SS_SKIP_INTRO=1`, never plays the opening.
    static func suppressed(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        env["SS_SKIP_INTRO"] == "1" || env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
            || env["STREAMSETU_TESTING"] != nil || env["STREAMSETU_SELFTEST_MEDIA"] != nil
    }
}

/// The small facts the launch plan remembers, kept with the app's other small settings in UserDefaults.
struct LaunchMemory {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var introDone: Bool { defaults.bool(forKey: "intro_done") }
    var seenVersion: String? { defaults.string(forKey: "whatsnew_seen_version") }
    var preference: OpeningPreference { OpeningPreference.stored(defaults) }

    /// Written when the app is revealed, so quitting during What's New never shows it again for this version.
    func storySeen(version: String) {
        defaults.set(true, forKey: "intro_done")
        defaults.set(version, forKey: "whatsnew_seen_version")
    }
}

/// The app's release as the launch plan compares it: the marketing version, so a rebuild of the same version is not an update.
enum AppRelease {
    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
}

// MARK: - Start-up state machine

/// The start-up steps, the same on every platform. The opening and the app's own start-up run side by side and may finish in either
/// order; whichever comes second moves on, and the app is revealed exactly once.
enum StartupState: String {
    case notStarted, starting, animating, initializing, awaitingDestination, ready, failed, transitioning, completed
}

/// The state machine without any SwiftUI in it, so the order of events can be tested. The app is revealed exactly once.
struct StartupMachine {
    private(set) var state: StartupState = .notStarted
    private(set) var animationDone = false
    /// nil while the app's start-up is still running; true when it finished, false when it failed.
    private(set) var initOK: Bool?
    private(set) var revealed = false
    /// Every state passed through, in order (for tests).
    private(set) var history: [StartupState] = [.notStarted]

    private mutating func go(_ s: StartupState) { if state != s { state = s; history.append(s) } }

    mutating func start() { if state == .notStarted { go(.starting) } }

    /// The plan is known: an opening plays (the Reduce Motion still counts: it is held for its second), or with none only the
    /// start-up is waited for.
    mutating func planned(_ variant: OpeningVariant?) {
        guard state == .starting else { return }
        if variant == nil {
            animationDone = true
            go(initOK == nil ? .initializing : .awaitingDestination)
            settle()
        } else {
            go(.animating)
        }
    }

    /// The story reached its end (on time; it cannot be skipped).
    mutating func animationFinished() {
        guard !animationDone, state != .notStarted, state != .starting else { return }
        animationDone = true
        if state == .animating { go(.awaitingDestination) }
        settle()
    }

    /// The app's own start-up finished. On Apple a failure still reveals the app, whose own recovery screen then shows.
    mutating func initFinished(ok: Bool) {
        guard initOK == nil else { return }
        initOK = ok
        settle()
    }

    /// The exit has ended.
    mutating func exitFinished() { if state == .transitioning { go(.completed) } }

    private mutating func settle() {
        guard animationDone, state == .awaitingDestination || state == .initializing, let ok = initOK else { return }
        go(ok ? .ready : .failed)
        go(.transitioning)
        revealed = true
    }
}
