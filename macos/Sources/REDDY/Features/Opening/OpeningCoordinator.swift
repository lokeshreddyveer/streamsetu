import Foundation
import Observation
import os

/// Owns the opening for the whole process: its clock, its end, the reveal of the app and What's New. Views only draw what it says.
///
/// It is created once per process and never by a view, so nothing a view does (being rebuilt, a window made again, a theme change that
/// rebuilds the Mac window, a task being cancelled) can restart the opening or keep it on screen. The opening cannot be skipped; it ends
/// on elapsed time alone: timers on the main run loop end the story and the exit, a last timer reveals the app whatever happens to its
/// start-up, and the frame drawn is worked out from the stored start time, so even with no callback at all the layer is transparent and
/// takes no input once its time is up.
@MainActor @Observable
final class OpeningCoordinator {
    static let shared = OpeningCoordinator()

    private(set) var machine = StartupMachine()
    private(set) var variant: OpeningVariant?
    /// When the opening started. Set once per run, here, never when a view is recomputed.
    private(set) var startedAt = Date()
    /// When the exit began (the app is revealed underneath).
    private(set) var revealedAt: Date?
    /// What's New is on screen (after an update, once the opening has gone).
    private(set) var showsWhatsNew = false
    /// For review: `SS_INTRO_AT=<seconds>` freezes the opening on that moment and never ends it; `SS_OPENING_VARIANT=standard` picks
    /// the variant that is frozen. `SS_WHATS_NEW=1` shows What's New at once.
    let frozenAt: Double?
    private let frozenVariant: OpeningVariant
    private let forceWhatsNew: Bool
    private let memory: LaunchMemory
    private let version: String
    private let env: [String: String]
    private var started = false
    private var suppressed = false
    private var whatsNewDue = false
    /// The variant can still change from the full story to the short cut while the screen is dark (both begin in the dark).
    private var variantSettled = false
    private var timers: [Timer] = []
    private let log = Logger(subsystem: "app.streamsetu", category: "startup")

    init(memory: LaunchMemory = LaunchMemory(), version: String = AppRelease.current, env: [String: String] = ProcessInfo.processInfo.environment) {
        self.memory = memory
        self.version = version
        self.env = env
        frozenAt = env["SS_INTRO_AT"].flatMap(Double.init)
        frozenVariant = env["SS_OPENING_VARIANT"].flatMap(OpeningVariant.init(rawValue:)) ?? .firstInstall
        forceWhatsNew = env["SS_WHATS_NEW"] == "1"
    }

    var state: StartupState { machine.state }
    /// The opening layer is in the view tree: from the first frame until its exit has ended.
    var isVisible: Bool {
        if frozenAt != nil { return true }
        return started && variant != nil && machine.state != .completed
    }
    /// The layer stands in front of the app (and so takes its clicks and taps) only until the app is revealed.
    var blocksInput: Bool { isVisible && revealedAt == nil && frozenAt == nil }

    /// The milliseconds of the story to draw at `now`. The lockup holds at the end of the story until the app is revealed; from the
    /// reveal the exit (the match-cut) plays.
    func storyTime(at now: Date) -> Double {
        if let frozenAt { return frozenAt * 1000 }
        guard let variant else { return 0 }
        if let revealedAt { return min(Double(variant.holdMs) + now.timeIntervalSince(revealedAt) * 1000, Double(variant.durationMs)) }
        return min(now.timeIntervalSince(startedAt) * 1000, Double(variant.holdMs))
    }

    var drawnVariant: OpeningVariant { frozenAt != nil ? frozenVariant : (variant ?? .reducedMotion) }

    /// How opaque the layer is at `now`: 1 until the reveal; then, while the teal screen expands, it crossfades into the app (the
    /// Reduce Motion still simply fades).
    func layerOpacity(at now: Date) -> Double {
        guard let revealedAt else { return 1 }
        let t = now.timeIntervalSince(revealedAt) / max(0.05, Double(drawnVariant.exitMs) / 1000)
        if drawnVariant == .reducedMotion { return 1 - OpeningEasing.cubicInOut(t) }
        return 1 - OpeningEasing.smoothstep((t - 0.3) / 0.7)
    }

    /// Called by the first window's first frame. Runs once per process; later windows, focus changes and resizes do nothing.
    func start(reduceMotion: Bool) {
        guard !started else { return }
        started = true
        startedAt = Date()
        OpeningArt.preload()
        if forceWhatsNew { showsWhatsNew = true }
        guard frozenAt == nil else { return }
        suppressed = LaunchPlan.suppressed(env)
        variant = LaunchPlan.firstVariant(introDone: memory.introDone, reducedMotion: reduceMotion, suppressed: suppressed, preference: memory.preference)
        variantSettled = variant != .firstInstall
        log.info("opening start: \(self.variant?.rawValue ?? "none", privacy: .public)")
        machine.start()
        machine.planned(variant)
        guard variant != nil else { log.info("no opening"); return }
        scheduleEnd()
    }

    /// The story's end, and a last guard: whatever happens to the app's own start-up, the opening leaves within a few seconds of its end.
    private func scheduleEnd() {
        timers.forEach { $0.invalidate() }
        timers.removeAll()
        guard let variant else { return }
        let end = startedAt.addingTimeInterval(Double(variant.holdMs) / 1000).timeIntervalSinceNow
        after(end) { $0.storyEnded() }
        // The hard stop: a second past the story the opening gives way to the app, whatever its start-up is doing.
        after(end + OpeningCoordinator.overrunSeconds) { $0.abort(reason: "overran the story") }
    }

    /// How long past the end of the story the opening may stay before it is ended for good.
    static let overrunSeconds = 1.0
    /// Why the opening was cut short, if the watchdog ended it.
    private(set) var abortReason: String?

    /// Ends the opening at once and shows the app: the watchdog's action (slow frames, or the story overrunning). The opening never holds
    /// the app back. Does nothing when it has already ended, or in a frozen review.
    func abort(reason: String) {
        guard started, frozenAt == nil, variant != nil, machine.state != .completed, abortReason == nil else { return }
        // Past the reveal the exit is already running and ends on its own timer.
        guard revealedAt == nil else { return }
        abortReason = reason
        log.error("opening aborted: \(reason, privacy: .public)")
        timers.forEach { $0.invalidate() }
        timers.removeAll()
        machine.animationFinished()
        machine.initFinished(ok: true)
        settle(exit: false)
    }

    /// Ends the story when its time is up. Called by the timer; tests call it with a time of their choosing.
    func advance(to now: Date) {
        guard let variant, machine.state == .animating, now.timeIntervalSince(startedAt) * 1000 >= Double(variant.holdMs) else { return }
        storyEnded()
    }

    /// The app's own start-up has finished (or failed: its recovery screen is then revealed). `hasSources` decides between the full
    /// story and the short cut (while the screen is still dark) and whether What's New follows.
    func destinationReady(ok: Bool, hasSources: Bool) {
        guard started, !suppressed, frozenAt == nil, machine.initOK == nil else { return }
        let plan = LaunchPlan.decide(introDone: memory.introDone, hasSources: hasSources, seenVersion: memory.seenVersion, current: version,
                                     reducedMotion: variant == .reducedMotion, suppressed: false, preference: memory.preference)
        whatsNewDue = plan.whatsNew
        log.info("destination ready: ok=\(ok, privacy: .public) whatsNew=\(plan.whatsNew, privacy: .public)")
        // An install from before the opening existed has playlists: it gets the short cut, decided while the first frames are still dark.
        if !variantSettled, variant == .firstInstall, plan.variant == .standard, Date().timeIntervalSince(startedAt) < 0.2 {
            variant = .standard
            scheduleEnd()
        }
        variantSettled = true
        if variant == nil {
            machine.initFinished(ok: ok)
            memory.storySeen(version: version)
            if whatsNewDue { showsWhatsNew = true }
            return
        }
        machine.initFinished(ok: ok)
        settle()
    }

    /// "Replay the full story" in Settings: the 7.5 s cut once more, over the app as it is.
    func replayFullStory() {
        guard started, frozenAt == nil, machine.state == .completed || variant == nil else { return }
        log.info("replaying the full story")
        machine = StartupMachine()
        variant = .firstInstall
        variantSettled = true
        revealedAt = nil
        startedAt = Date()
        whatsNewDue = false
        machine.start()
        machine.planned(variant)
        machine.initFinished(ok: true)
        scheduleEnd()
    }

    func finishWhatsNew() { showsWhatsNew = false }

    private func storyEnded() {
        machine.animationFinished()
        settle()
    }

    /// Whichever of the story and the start-up finishes second reveals the app, exactly once.
    private func settle(exit plays: Bool = true) {
        guard machine.state == .transitioning, revealedAt == nil, let variant else { return }
        revealedAt = Date()
        memory.storySeen(version: version)
        log.info("revealing the app")
        if plays { after(Double(variant.exitMs) / 1000) { $0.exitEnded() } } else { exitEnded() }
    }

    private func exitEnded() {
        machine.exitFinished()
        timers.forEach { $0.invalidate() }
        timers.removeAll()
        if whatsNewDue { showsWhatsNew = true }
        log.info("opening completed")
    }

    /// A timer on the main run loop in every mode (so a menu being tracked or a scroll does not hold it back).
    private func after(_ seconds: Double, _ body: @escaping @MainActor (OpeningCoordinator) -> Void) {
        let timer = Timer(timeInterval: max(0, seconds), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { if let self { body(self) } }
        }
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }
}
