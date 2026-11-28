import Foundation
import Observation
import WebKit

/// What a page is doing, from WebKit's public `requestMediaPlaybackState` only (no script is run, nothing in the page is read).
enum ServiceMediaState: Equatable, Sendable {
    case playing, paused, suspended
    /// No web view (not made, or released).
    case noView
    init(_ s: WKMediaPlaybackState) { switch s { case .playing: self = .playing; case .paused: self = .paused; default: self = .suspended } }
}

/// Reads one service's playback state. The app's implementation asks the web view; tests use a fake.
@MainActor protocol ServiceMediaProbing: AnyObject {
    func playbackState(of id: ProviderID) async -> ServiceMediaState
}

/// A repeating timer the monitor starts and stops. Tests hold a fake that counts starts and cancels and fires a tick by hand.
@MainActor protocol PollScheduling: AnyObject {
    /// Runs `tick` now and then every `interval` until the returned handle is cancelled.
    func schedule(every interval: Duration, tick: @escaping @MainActor () async -> Void) -> PollHandle
}

final class PollHandle {
    private let onCancel: () -> Void
    private var done = false
    init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    /// Idempotent; also runs when the handle is released, so a timer never outlives its monitor.
    func cancel() { guard !done else { return }; done = true; onCancel() }
    deinit { if !done { onCancel() } }
}

@MainActor final class TaskPollScheduler: PollScheduling {
    func schedule(every interval: Duration, tick: @escaping @MainActor () async -> Void) -> PollHandle {
        let task = Task { @MainActor in
            while !Task.isCancelled {
                await tick()
                try? await Task.sleep(for: interval)
            }
        }
        return PollHandle { task.cancel() }
    }
}

/// Knows which services are playing, polling only while that can matter: while the visible service is watched for a play start (a start
/// claims the audio and stops other media), while a hidden service that was playing may still be, and, slowly, every live hidden page (hidden autoplay).
///
/// WHAT WEBKIT OFFERS (checked in the SDK headers): `requestMediaPlaybackState`, `pauseAllMediaPlayback`, `setAllMediaPlaybackSuspended`,
/// `closeAllMediaPresentations`. There is NO public event, delegate or KVO property for "audio started/stopped" (the audible flags are private), so
/// everything here is polling and therefore best effort: a page can start (or autoplay while hidden) between two observations and briefly overlap
/// with another source until the next poll notices it. The faster poll while another participant plays, the slow scan of hidden live views and the
/// probe taken when a view is hidden narrow that window; none of them closes it.
@MainActor @Observable final class ServiceMediaMonitor {
    /// Services confirmed playing by the last poll (visible or hidden).
    private(set) var playingIDs: Set<ProviderID> = []
    /// When each currently playing service was first seen playing (for the first-in-first-out order under memory pressure).
    @ObservationIgnored private(set) var playingSince: [ProviderID: Date] = [:]
    /// Hidden services that were playing, until a poll shows they stopped.
    @ObservationIgnored private(set) var candidates: Set<ProviderID> = []
    /// Services just hidden whose state is being probed once; they are held (never evicted) until the answer is in.
    @ObservationIgnored private(set) var pendingProbes: Set<ProviderID> = []
    @ObservationIgnored private(set) var watched: ProviderID?
    @ObservationIgnored private var misses: [ProviderID: Int] = [:]
    @ObservationIgnored private var lastSeenPlaying: [ProviderID: Date] = [:]
    @ObservationIgnored private var probeTasks: [ProviderID: Task<Void, Never>] = [:]
    @ObservationIgnored private var handle: PollHandle?
    @ObservationIgnored private var scanHandle: PollHandle?
    @ObservationIgnored private var scheduledInterval: Duration?
    @ObservationIgnored private var ticking = false
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private let probe: ServiceMediaProbing
    @ObservationIgnored private let scheduler: PollScheduling
    @ObservationIgnored private let clock: () -> Date
    /// The normal poll interval (1.5 s: the documented detection delay).
    @ObservationIgnored let interval: Duration
    /// The poll interval of the visible service while another participant plays (a start there must pause the other quickly).
    @ObservationIgnored let fastInterval: Duration
    /// How often every live hidden page is looked at, to notice one that started by itself.
    @ObservationIgnored let scanInterval: Duration
    /// A service seen playing this recently is never evicted.
    @ObservationIgnored let recentGrace: TimeInterval
    /// The ownership generation now; an observation carries the value from when it was requested.
    @ObservationIgnored var currentGeneration: () -> UInt64 = { 0 }
    /// True while some other participant (the native player, a podcast, another service) plays: the visible service is polled faster then.
    @ObservationIgnored var otherAudioPlaying: () -> Bool = { false }
    /// Live web views (for the slow scan of hidden ones). Set by the registry.
    @ObservationIgnored var liveIDs: () -> [ProviderID] = { [] }
    /// A service was observed going from not playing to playing (`hidden`: the page was not showing, i.e. it started by itself). The answer says whether
    /// ownership accepted it; a stale observation (the owner changed meanwhile) is refused and forgotten so the next poll looks again.
    @ObservationIgnored var onStartedPlaying: (_ id: ProviderID, _ generation: UInt64, _ hidden: Bool) -> Bool = { _, _, _ in true }
    /// The playing set, or the candidates, changed (retention and the cap run again).
    @ObservationIgnored var onChange: () -> Void = {}
    /// Polls in a row that must find a hidden service not playing before it stops being checked (a track change is not a stop).
    static let missesToStop = 2
    var isPolling: Bool { handle != nil }
    var isScanningHidden: Bool { scanHandle != nil }
    var currentInterval: Duration? { scheduledInterval }

    init(probe: ServiceMediaProbing, scheduler: PollScheduling = TaskPollScheduler(), clock: @escaping () -> Date = { Date() },
         interval: Duration = .milliseconds(1500), fastInterval: Duration = .milliseconds(500), scanInterval: Duration = .seconds(5), recentGrace: TimeInterval = 10) {
        self.probe = probe; self.scheduler = scheduler; self.clock = clock; self.interval = interval
        self.fastInterval = fastInterval; self.scanInterval = scanInterval; self.recentGrace = recentGrace
    }

    /// True for a service that is playing, may still be playing, is being probed, or was seen playing a moment ago (kept alive by retention).
    func isHeld(_ id: ProviderID) -> Bool {
        if playingIDs.contains(id) || candidates.contains(id) || pendingProbes.contains(id) { return true }
        if let t = lastSeenPlaying[id], clock().timeIntervalSince(t) < recentGrace { return true }
        return false
    }

    /// A service was hidden. When it was playing it becomes a candidate and keeps being polled until a poll shows it stopped. Otherwise ONE probe is taken
    /// at once (the last poll may be up to a whole interval old, and the page may have started in that time): the service is held, and so cannot be evicted,
    /// until the answer arrives; `onChange` then runs the retention again.
    func serviceHidden(_ id: ProviderID) {
        if watched == id { watched = nil }
        if playingIDs.contains(id) {
            candidates.insert(id); misses[id] = 0
            refresh(); onChange(); return
        }
        candidates.remove(id)
        pendingProbes.insert(id)
        let gen = currentGeneration()
        probeTasks[id]?.cancel()
        probeTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            let state = await self.probe.playbackState(of: id)
            self.finishHiddenProbe(id, state, generation: gen)
        }
        refresh()
    }

    /// Waits for the probes taken at hiding (tests).
    func settleProbes() async { for t in Array(probeTasks.values) { await t.value } }

    private func finishHiddenProbe(_ id: ProviderID, _ state: ServiceMediaState, generation gen: UInt64) {
        probeTasks[id] = nil
        guard pendingProbes.remove(id) != nil else { return }
        if watched != id, state == .playing {
            playingIDs.insert(id); playingSince[id] = playingSince[id] ?? clock(); lastSeenPlaying[id] = clock()
            candidates.insert(id); misses[id] = 0
            if !onStartedPlaying(id, gen, false) { forget(id) }
        }
        refresh(); onChange()
    }

    /// A service is showing: it is no longer a hidden candidate, and it is watched for a play start (a start claims the audio).
    func serviceShown(_ id: ProviderID) {
        candidates.remove(id); misses[id] = nil
        pendingProbes.remove(id); probeTasks[id]?.cancel(); probeTasks[id] = nil
        watched = id
        refresh()
    }

    /// A service was paused, released, signed out or its process ended: it is not playing, and nothing about it is held any more.
    func stopped(_ id: ProviderID) {
        // Every set is cleared (no short-circuit: a service that is both playing and a candidate must leave both).
        let wasPlaying = playingIDs.remove(id) != nil, wasCandidate = candidates.remove(id) != nil, wasProbing = pendingProbes.remove(id) != nil
        let changed = wasPlaying || wasCandidate || wasProbing
        probeTasks[id]?.cancel(); probeTasks[id] = nil
        playingSince[id] = nil; misses[id] = nil; lastSeenPlaying[id] = nil
        refresh()
        if changed { onChange() }
    }

    /// An observation was refused as stale: the service is not recorded as playing, so the next poll looks again (and claims with a current generation).
    private func forget(_ id: ProviderID) {
        playingIDs.remove(id); playingSince[id] = nil; candidates.remove(id); lastSeenPlaying[id] = nil
    }

    /// The interval the visible service should be polled at now: fast while another participant plays.
    private var desiredInterval: Duration { watched != nil && otherAudioPlaying() ? fastInterval : interval }

    /// Ownership changed (or the other participants started or stopped): the poll speed may need to change.
    func intervalMayHaveChanged() { refresh() }

    /// Starts or stops the pollers. Public so the registry can call it when live views appear or go.
    func refresh() {
        let needed = !candidates.isEmpty || watched != nil
        if needed {
            let want = desiredInterval
            if handle == nil || scheduledInterval != want {
                handle?.cancel()
                scheduledInterval = want
                handle = scheduler.schedule(every: want) { [weak self] in await self?.tick() }
            }
        } else if let h = handle { h.cancel(); handle = nil; scheduledInterval = nil }
        let hiddenLive = !hiddenLiveIDs().isEmpty
        if hiddenLive, scanHandle == nil { scanHandle = scheduler.schedule(every: scanInterval) { [weak self] in await self?.scan() } }
        else if !hiddenLive, let h = scanHandle { h.cancel(); scanHandle = nil }
    }

    private func hiddenLiveIDs() -> [ProviderID] {
        liveIDs().filter { $0 != watched && !candidates.contains($0) }
    }

    /// One poll of every service that needs it. Public so tests can drive it. Each answer carries the ownership generation from when the poll began.
    func tick() async {
        guard !ticking else { return }
        ticking = true; defer { ticking = false }
        let gen = currentGeneration()
        var changed = false
        var started: [ProviderID] = []
        for id in candidates.union(watched.map { [$0] } ?? []) {
            let result = apply(await probe.playbackState(of: id), to: id)
            changed = changed || result.changed
            if result.started { started.append(id) }
        }
        refresh()
        if changed { onChange() }
        for id in started where !onStartedPlaying(id, gen, false) { forget(id) }
    }

    /// The slow look at every hidden live page: one that plays although nothing started it is shown with the badge and claims the audio
    /// (WebKit cannot report it any other way). Public so tests can drive it.
    func scan() async {
        guard !scanning else { return }
        scanning = true; defer { scanning = false }
        let gen = currentGeneration()
        for id in hiddenLiveIDs() where !pendingProbes.contains(id) {
            guard await probe.playbackState(of: id) == .playing, watched != id, !playingIDs.contains(id) else { continue }
            playingIDs.insert(id); playingSince[id] = clock(); lastSeenPlaying[id] = clock(); candidates.insert(id); misses[id] = 0
            if !onStartedPlaying(id, gen, true) { forget(id) }
            refresh(); onChange()
        }
        refresh()
    }

    /// Records what a poll found for one service. `started` is true when the watched, visible service went from not playing to playing.
    @discardableResult func apply(_ state: ServiceMediaState, to id: ProviderID) -> (changed: Bool, started: Bool) {
        var changed = false, started = false
        if state == .playing {
            misses[id] = 0; lastSeenPlaying[id] = clock()
            if playingIDs.insert(id).inserted {
                changed = true; playingSince[id] = clock()
                started = id == watched
            }
        } else {
            if playingIDs.remove(id) != nil { changed = true; playingSince[id] = nil }
            if candidates.contains(id) {
                misses[id, default: 0] += 1
                if misses[id, default: 0] >= Self.missesToStop || state == .noView { candidates.remove(id); misses[id] = nil; changed = true }
            }
        }
        return (changed, started)
    }
}

/// The app's probe: asks the service's own web view (public API only).
@MainActor final class WebViewMediaProbe: ServiceMediaProbing {
    private let lookup: (ProviderID) -> WKWebView?
    init(lookup: @escaping (ProviderID) -> WKWebView?) { self.lookup = lookup }
    func playbackState(of id: ProviderID) async -> ServiceMediaState {
        guard let v = lookup(id) else { return .noView }
        return ServiceMediaState(await v.requestMediaPlaybackState())
    }
}
