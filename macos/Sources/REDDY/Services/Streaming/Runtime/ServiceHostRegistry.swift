import Foundation
import WebKit

/// Owns the models of the embedded services: made lazily (one per service, only when first needed, never all at startup), kept for the life of
/// the app, and held to a memory budget. Web views are released least-recently-used first; their website data is never touched. A switch does
/// not stop anything (with "Keep services playing in the background" on): a service keeps playing while hidden (its web view is kept, and parked in the window only when the
/// experimental, opt-in parking is on) and a hidden web view that is playing, was playing a moment ago, is being probed or owns the audio is exempt from the budget and the retention time.
/// Polling is best effort: WebKit has no public "started playing" event, so a page can start between two observations and briefly overlap. Media stops only when something else starts (`ServiceMediaPolicy`), and the
/// number of playing views is capped.
@MainActor final class ServiceHostRegistry: ServiceHostResolving {
    let registry: ProviderRegistry
    private let makeModel: (ProviderDefinition) -> ServiceWebModel
    private let clock: () -> Date
    var budget: MemoryBudget
    private var models: [ProviderID: ServiceWebModel] = [:]
    private var lastUsed: [ProviderID: Date] = [:]
    private var terminations: [Date] = []
    private(set) var visibleID: ProviderID?
    /// The cross-provider limit: this many stops within the recovery window across all services end automatic reloading.
    let circuitBreakerLimit = 3
    private(set) var circuitBreakerTrips = 0

    /// THE one coordinator of who owns the audio. The shell registers the native player and Podcasts as participants; the registry registers every service.
    let ownership: AudioOwnership
    /// "Keep services playing in the background" (Settings, default on). Off: the previous behaviour, a switch pauses.
    private let defaults: UserDefaults
    private var releaseOnHide: Set<ProviderID> = []

    private var ownershipObserver: Int?
    private var previouslyPlaying: Set<ProviderID> = []
    private let mediaProbe: ServiceMediaProbing?
    private let mediaScheduler: PollScheduling
    /// Which services are playing, polled only while that can matter.
    private(set) lazy var media: ServiceMediaMonitor = {
        let m = ServiceMediaMonitor(probe: mediaProbe ?? WebViewMediaProbe { [weak self] id in self?.models[id]?.webView }, scheduler: mediaScheduler, clock: clock)
        m.onChange = { [weak self] in self?.mediaChanged() }
        // A service seen playing claims the audio, but only when ownership is still what it was when the poll was requested (a late answer is dropped).
        m.onStartedPlaying = { [weak self] id, generation, hidden in
            self?.ownership.claim(.service(id), reason: hidden ? .hiddenAutoplay : .servicePlaySeen, observedAt: generation) != nil
        }
        m.currentGeneration = { [weak self] in self?.ownership.generation ?? 0 }
        m.otherAudioPlaying = { [weak self] in
            guard let self else { return false }
            return self.ownership.isAnyPlaying(except: self.visibleID.map { MediaSource.service($0) })
        }
        m.liveIDs = { [weak self] in self?.liveIDs ?? [] }
        ownershipObserver = ownership.addObserver { [weak self] _ in self?.media.intervalMayHaveChanged() }
        return m
    }()

    init(registry: ProviderRegistry = .standard, budget: MemoryBudget = .standard, clock: @escaping () -> Date = { Date() },
         mediaProbe: ServiceMediaProbing? = nil, mediaScheduler: PollScheduling = TaskPollScheduler(),
         ownership: AudioOwnership = AudioOwnership(), defaults: UserDefaults = .standard,
         makeModel: @escaping (ProviderDefinition) -> ServiceWebModel = { ServiceWebModel.forApp($0) }) {
        self.registry = registry; self.budget = budget; self.clock = clock; self.makeModel = makeModel
        self.mediaProbe = mediaProbe; self.mediaScheduler = mediaScheduler; self.ownership = ownership; self.defaults = defaults
    }

    /// Whether a service keeps playing when it is hidden (the setting). Read each time, so a change applies at once.
    var keepsServicesPlaying: Bool { ServicePreferences.keepsPlayingInBackground(defaults) }

    /// Services playing in the background right now (the visible one is not listed): the top bar's "Playing" badge.
    var backgroundPlayingIDs: Set<ProviderID> { media.playingIDs.subtracting(visibleID.map { [$0] } ?? []) }

    /// The service's model, made on first request. Nil for an unknown service or one the registry does not present as embedded.
    func model(for id: ProviderID) -> ServiceWebModel? {
        if let m = models[id] { return m }
        guard let d = registry.definition(for: id), d.platforms.contains(.macOS), d.presentation == .embedded else { return nil }
        let m = makeModel(d)
        m.onBecameVisible = { [weak self] id in self?.didBecomeVisible(id) }
        m.onBecameHidden = { [weak self] id in self?.didBecomeHidden(id) }
        m.onMemoryPressure = { [weak self] critical in self?.handleMemoryPressure(critical: critical) }
        m.onTermination = { [weak self] id, at in self?.serviceTerminated(id); return self?.recordTermination(of: id, at: at) ?? .reload }
        m.onEligibilityLost = { [weak self] id, reason in self?.safetyStop(reason, service: id) }
        m.holdsHiddenView = { [weak self] in self?.isProtected(d.id) ?? false }
        models[id] = m
        ensureParticipant(id)
        return m
    }

    /// Every service that can show or play is a participant of the audio coordinator (made once, whether or not a model exists yet), so a claim by
    /// anything else pauses it even when only its playing state is known.
    private func ensureParticipant(_ id: ProviderID) {
        guard ownership.participant(.service(id)) == nil else { return }
        ownership.register(ClosureAudioParticipant(.service(id), isPlaying: { [weak self] in self?.media.playingIDs.contains(id) ?? false },
                                                   pause: { [weak self] in self?.pauseService(id) }))
    }

    func host(for id: ProviderID) -> (any ExternalServiceHost)? { model(for: id) }

    /// Models that have been made (for tests and diagnostics; no web view implied).
    var createdIDs: [ProviderID] { models.keys.sorted { $0.rawValue < $1.rawValue } }
    /// Models that currently own a web view.
    var liveIDs: [ProviderID] { models.filter { entry in entry.value.webView != nil }.keys.sorted { $0.rawValue < $1.rawValue } }

    // MARK: switching and retention

    /// A service is about to show. Nothing else stops: whatever plays in the background keeps playing, and the retention plan is applied.
    func didBecomeVisible(_ id: ProviderID) {
        visibleID = id; lastUsed[id] = clock()
        ensureParticipant(id)
        // Showing a service is navigation: it never claims the audio. The service claims only when it is seen playing.
        if !keepsServicesPlaying { pauseAll(except: id) }          // setting off: the previous behaviour, a switch pauses
        media.serviceShown(id)          // watched for a play start; the hidden ones that play stay polled
        applyRetention(budget: budget.maxLiveWebViews)
        media.refresh()
    }

    func didBecomeHidden(_ id: ProviderID) {
        if visibleID == id { visibleID = nil }
        lastUsed[id] = clock()
        ensureParticipant(id)
        if !keepsServicesPlaying { pauseService(id) }
        // One probe is taken now; until it answers the service is held, so a page that started less than one poll ago is never evicted by this move.
        media.serviceHidden(id)
        applyRetention(budget: budget.maxLiveWebViews)
        if releaseOnHide.remove(id) != nil { evict(id, force: true) }
        media.refresh()
    }

    /// Something else really started playing (never navigation). Kept as the shell's one entry; it is `ownership.claim`.
    @discardableResult func otherMediaStarted(from source: MediaSource) -> UInt64? {
        let reason: OwnershipReason
        switch source { case .nativePlayer: reason = .nativePlay; case .podcasts: reason = .podcastPlay; case .music: reason = .musicPlay; case .service: reason = .servicePlaySeen }
        return ownership.claim(source, reason: reason)
    }

    /// A restriction came on. With a service, only that service is concerned (sign-out, cleared data, disabled, removed, revoked); without, every service
    /// (Kids profile, lock, blocked, profile switch). The concerned services pause now, the owner is released if it was one of them, the badge clears, and the
    /// web view is released (a visible one when it is hidden next; a signed-out or cleared one that is showing keeps its page).
    func safetyStop(_ reason: MediaSafetyStop, service: ProviderID? = nil) {
        MediaDiagnostics.shared.count("safety.\(reason.code)")
        let targets = service.map { [$0] } ?? Array(Set(models.keys).union(media.playingIDs).union(media.candidates))          // whatever is playing stops, model or not
        for id in targets {
            pauseService(id)
            if visibleID == id || models[id]?.isVisible == true {
                // showing: a signed-out or cleared page stays (it shows its own sign-in); any other stop releases it as soon as it hides
                if reason != .signedOut && reason != .dataCleared { releaseOnHide.insert(id) }
            } else { evict(id, force: true) }
        }
        media.refresh()
    }

    /// Pauses one service and forgets it was playing; releases the audio if it owned it.
    func pauseService(_ id: ProviderID) {
        models[id]?.pauseMedia()
        media.stopped(id)
        ownership.release(.service(id), reason: .stopped)
    }

    /// The service's web process ended: it is not playing, its badge clears and it no longer owns the audio, whatever the last poll said.
    func serviceTerminated(_ id: ProviderID) {
        MediaDiagnostics.shared.count("termination")
        media.stopped(id)
        ownership.release(.service(id), reason: .terminated)
    }

    /// True for a service that must not be evicted now: playing, seen playing a moment ago, being probed, or the owner of the audio.
    func isProtected(_ id: ProviderID) -> Bool { media.isHeld(id) || ownership.owner == .service(id) }

    /// Pauses (and closes full-screen or picture-in-picture for) every live web view except one. Nothing resumes by itself.
    func pauseAll(except id: ProviderID? = nil) {
        for (key, m) in models where key != id { m.pauseMedia() }
        for key in media.playingIDs.union(media.candidates) where key != id { media.stopped(key) }
        if case .service(let o)? = ownership.owner, o != id { ownership.release(.service(o), reason: .stopped) }
    }

    /// The same, returning once every page has actually paused.
    func pauseAllAndWait(except id: ProviderID? = nil) async {
        for (key, m) in models where key != id { await m.pauseMediaAndWait() }
    }

    /// `held` are the views kept whatever the budget says: those playing, and those hidden a moment ago that may still be.
    func applyRetention(budget: Int, held: Set<ProviderID>? = nil) {
        // never evicted: playing, seen playing a moment ago, being probed after hiding, or the current owner
        let always = media.pendingProbes.union(ownership.owner.flatMap { o -> ProviderID? in if case .service(let id) = o { id } else { nil } }.map { [$0] } ?? [])
        // Under critical memory pressure `held` is exactly what plays: a view only waiting for its hide probe, or an owner that is not playing, is released.
        let keep = held ?? Set(models.keys.filter(isProtected)).union(always)
        for id in RetentionPlan.releaseList(live: liveIDs, lastUsed: lastUsed, visible: visibleID, budget: budget, held: keep) { evict(id, force: held != nil) }          // an explicit `held` (critical pressure) already says exactly what stays
    }

    /// The playing set changed: the cap on playing views, then retention (a view that stopped playing is no longer exempt).
    func mediaChanged() {
        for id in RetentionPlan.pauseOverCap(playing: media.playingIDs, lastUsed: lastUsed, visible: visibleID, cap: budget.maxPlayingViews) {
            pauseService(id)
        }
        // A service that was playing, owns the audio and has stopped on its own no longer owns it (so nothing keeps its view alive on that account).
        // Only a seen transition counts: an owner that was never seen playing is left alone.
        if case .service(let owner)? = ownership.owner, previouslyPlaying.contains(owner), !media.isHeld(owner) { ownership.release(.service(owner), reason: .stopped) }
        previouslyPlaying = media.playingIDs
        applyRetention(budget: budget.maxLiveWebViews)
        media.refresh()
    }

    /// Pauses, then releases the web view of a hidden service. Its website data stays, so signing in again is not needed.
    private func evict(_ id: ProviderID, force: Bool = false) {
        guard let m = models[id], !m.isVisible else { return }
        if !force, isProtected(id) { return }          // a playing, recently playing, probed or owning service is never evicted by timing or clean-up
        media.stopped(id)
        ownership.release(.service(id), reason: .stopped)
        m.releaseResources()          // pauses first; the page is torn down either way
    }

    /// Memory is tight: hidden web views that are not playing go (one stays on a warning when the budget allows it). A playing view is kept on a
    /// warning. On a critical level the playing hidden views go too, first in, first out, one per event: the one that started playing first is
    /// paused and released, so memory falls step by step instead of every service going silent at once.
    func handleMemoryPressure(critical: Bool) {
        applyRetention(budget: critical ? 0 : budget.warningMaxLive, held: critical ? media.playingIDs : nil)
        guard critical, let victim = RetentionPlan.pressureVictim(playing: media.playingIDs, playingSince: media.playingSince, visible: visibleID) else { return }
        pauseService(victim); evict(victim, force: true)
    }

    /// The window closed or the app is quitting: everything stops and every web view is released (website data is kept).
    func tearDown() {
        pauseAll()
        for id in liveIDs where id != visibleID { evict(id, force: true) }
    }

    /// Forced: every hidden web view goes, playing or not (tests and explicit clean-up).
    func releaseHidden() { for id in liveIDs where id != visibleID { evict(id, force: true) } }

    // MARK: termination circuit breaker

    /// Records a stopped web process. When several services stop within the window, a shared process is probably failing: automatic reloading
    /// ends everywhere, hidden web views are released and only the visible service shows its Retry card.
    @discardableResult func recordTermination(of id: ProviderID, at: Date) -> TerminationAction {
        terminations = RecoveryPolicy.standard.recent(terminations, now: at) + [at]
        guard terminations.count >= circuitBreakerLimit else { return .reload }
        circuitBreakerTrips += 1
        for other in liveIDs where other != id && other != visibleID { evict(other, force: true) }
        return .showRetryCard
    }
}
