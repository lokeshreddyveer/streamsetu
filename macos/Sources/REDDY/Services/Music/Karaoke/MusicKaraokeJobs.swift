import Foundation
import Observation

/// Time source for the queue, so tests can run the retry ladder instantly.
protocol MusicKaraokeClock: Sendable {
    func now() -> Date
    func sleep(seconds: Double) async throws
}

struct MusicKaraokeSystemClock: MusicKaraokeClock {
    func now() -> Date { Date() }
    func sleep(seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
}

enum MusicKaraokeTrackState: Sendable, Equatable {
    case queued
    case preparing(Double)
    case ready(URL)
    case waitingRetry(MusicKaraokeFailure, attempt: Int)
    case exhausted(MusicKaraokeFailure)
    case tooLong
}

/// Pure scheduling rules.
enum MusicKaraokeScheduler {
    static let cancelGraceSeconds: Double = 1.5

    /// Current track, then the next two that can be done. Songs over the length cap are reported separately and the search moves on.
    static func wanted(current: MusicTrack?, upcoming: [MusicTrack]) -> (wanted: [MusicTrack], tooLong: [MusicTrack]) {
        var out: [MusicTrack] = [], long: [MusicTrack] = [], seen = Set<String>()
        if let c = current {
            seen.insert(c.uid)
            if MusicKaraokeLimits.isQueueable(durationMs: c.durationMs) { out.append(c) } else { long.append(c) }
        }
        var nextCount = 0
        for t in upcoming where nextCount < 2 && !seen.contains(t.uid) {
            seen.insert(t.uid)
            if MusicKaraokeLimits.isQueueable(durationMs: t.durationMs) { out.append(t); nextCount += 1 } else { long.append(t) }
        }
        return (out, long)
    }

    /// Delay before retry number `failures` (1-based), or nil once the ladder is used up.
    static func retryDelay(afterFailures failures: Int) -> Double? {
        let d = MusicKaraokeLimits.retryDelays
        return failures >= 1 && failures <= d.count ? d[failures - 1] : nil
    }

    /// The first wanted track that still needs work.
    static func nextToRun(wanted: [MusicTrack], states: [String: MusicKaraokeTrackState]) -> MusicTrack? {
        wanted.first { t in
            switch states[t.uid] {
            case nil, .queued?: true
            default: false
            }
        }
    }
}

/// One song at a time: the current track, then the next two. Failed songs back off 5, 15, 30 and 60 seconds, then wait for the person to retry.
@MainActor @Observable
final class MusicKaraokeJobs {
    private(set) var states: [String: MusicKaraokeTrackState] = [:]
    private(set) var growing: [String: MusicGrowingInstrumental] = [:]
    private(set) var wanted: [MusicTrack] = []
    private(set) var runningUID: String?
    private(set) var startedAt: [String: Date] = [:]
    /// Set when the last job could not start for a reason the person can fix, such as a missing model.
    private(set) var blockedReason: MusicKaraokeFailure?
    private(set) var enabled = false

    @ObservationIgnored private let worker: MusicKaraokeWorking
    @ObservationIgnored let cache: MusicKaraokeCache
    @ObservationIgnored private let clock: MusicKaraokeClock
    @ObservationIgnored private let modelStem: () -> String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var retryTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var failures: [String: Int] = [:]
    @ObservationIgnored private var startPosition: TimeInterval = 0
    @ObservationIgnored private var graceToken = 0
    @ObservationIgnored private var lastProgressAt: Date = .distantPast

    init(worker: MusicKaraokeWorking, cache: MusicKaraokeCache, clock: MusicKaraokeClock = MusicKaraokeSystemClock(), modelStem: @escaping () -> String?) {
        self.worker = worker; self.cache = cache; self.clock = clock; self.modelStem = modelStem
    }

    func state(for track: MusicTrack) -> MusicKaraokeTrackState? { states[track.uid] }

    // MARK: Control

    func setEnabled(_ on: Bool) {
        enabled = on
        // Turning it off does not stop a running job: people turn it off for a verse, and the work lands in the cache.
        if on { blockedReason = nil; reschedule() }
    }

    /// Call whenever the queue changes, a track starts, or the player advances.
    func updateWanted(current: MusicTrack?, upcoming: [MusicTrack], startingAt: TimeInterval = 0) {
        let plan = MusicKaraokeScheduler.wanted(current: current, upcoming: upcoming)
        for t in plan.tooLong { states[t.uid] = .tooLong }
        wanted = plan.wanted
        startPosition = startingAt
        cache.evict(wanted: wantedURLs())
        reschedule()
    }

    /// Manual "Try again" for a track that used up its retries (or any failed one).
    func retryNow(_ track: MusicTrack) {
        retryTasks[track.uid]?.cancel(); retryTasks[track.uid] = nil
        failures[track.uid] = 0
        states[track.uid] = nil
        reschedule()
    }

    /// The model changed: nothing made by the old one is valid and the running job is dropped.
    func modelChanged() {
        task?.cancel()
        for t in retryTasks.values { t.cancel() }
        retryTasks = [:]; failures = [:]; states = [:]; growing = [:]; blockedReason = nil
        reschedule()
    }

    func cancelAll() {
        task?.cancel()
        for t in retryTasks.values { t.cancel() }
        retryTasks = [:]
        wanted = []
    }

    func clearCache() {
        task?.cancel()
        for (uid, s) in states { if case .ready = s { states[uid] = nil } }
        cache.clear()
        reschedule()
    }

    private func wantedURLs() -> Set<URL> {
        Set(states.compactMap { uid, s in
            if case .ready(let u) = s, wanted.contains(where: { $0.uid == uid }) { return u }
            return nil
        })
    }

    // MARK: Loop

    private func reschedule() {
        guard let stem = modelStem() else { return }
        // Songs that are already prepared are announced ready without any work.
        for t in wanted {
            if case .ready? = states[t.uid] { continue }
            if let hit = cache.lookup(modelStem: stem, trackID: t.uid) { states[t.uid] = .ready(hit) }
        }
        if let running = runningUID {
            if !wanted.contains(where: { $0.uid == running }) { cancelAfterGrace(running) }
            return
        }
        guard enabled, task == nil, let next = MusicKaraokeScheduler.nextToRun(wanted: wanted, states: states) else { return }
        start(next, stem: stem)
    }

    /// A quick skip and skip back should not throw work away.
    private func cancelAfterGrace(_ uid: String) {
        graceToken += 1
        let token = graceToken
        Task { [weak self, clock] in
            try? await clock.sleep(seconds: MusicKaraokeScheduler.cancelGraceSeconds)
            guard let self, token == self.graceToken, self.runningUID == uid, !self.wanted.contains(where: { $0.uid == uid }) else { return }
            self.task?.cancel()
        }
    }

    private func start(_ track: MusicTrack, stem: String) {
        let uid = track.uid
        runningUID = uid; states[uid] = .preparing(0); startedAt[uid] = clock.now()
        let job = MusicKaraokeJobRequest(track: track, startingAt: startPosition, modelStem: stem)
        let worker = self.worker, clock = self.clock
        let sink = MusicKaraokeJobSink(self)
        task = Task { [weak self] in
            do {
                let url = try await worker.run(job,
                    onGrowing: { g in Task { @MainActor in sink.jobs?.growing[uid] = g } },
                    progress: { p in Task { @MainActor in sink.jobs?.reportProgress(uid, p, clock.now()) } })
                self?.finished(uid, .success(url))
            } catch {
                self?.finished(uid, .failure((error as? MusicKaraokeFailure) ?? (Task.isCancelled ? .cancelled : .failed)))
            }
        }
    }

    /// At most four updates a second.
    private func reportProgress(_ uid: String, _ p: Double, _ now: Date) {
        guard case .preparing? = states[uid], now.timeIntervalSince(lastProgressAt) >= 0.25 || p >= 1 else { return }
        lastProgressAt = now
        states[uid] = .preparing(p)
    }

    private func finished(_ uid: String, _ result: Result<URL, MusicKaraokeFailure>) {
        runningUID = nil; task = nil; growing[uid] = nil; startedAt[uid] = nil
        switch result {
        case .success(let url):
            states[uid] = .ready(url); failures[uid] = nil
            cache.evict(wanted: wantedURLs())
        case .failure(let f):
            switch f {
            case .cancelled: states[uid] = nil
            case .tooLong: states[uid] = .tooLong
            case .noModel: states[uid] = nil; blockedReason = .noModel
            case .failed, .incompleteDownload:
                let n = (failures[uid] ?? 0) + 1
                failures[uid] = n
                if let delay = MusicKaraokeScheduler.retryDelay(afterFailures: n) {
                    states[uid] = .waitingRetry(f, attempt: n)
                    retryTasks[uid] = Task { [weak self, clock] in
                        try? await clock.sleep(seconds: delay)
                        guard !Task.isCancelled, let self else { return }
                        self.retryTasks[uid] = nil
                        if case .waitingRetry? = self.states[uid] { self.states[uid] = nil }
                        self.reschedule()
                    }
                } else { states[uid] = .exhausted(f) }
            }
        }
        reschedule()
    }

    /// Waits until nothing is running or waiting to retry. For tests.
    func waitUntilIdle() async {
        while task != nil || !retryTasks.isEmpty { await Task.yield(); try? await Task.sleep(nanoseconds: 1_000_000) }
    }
}

/// A weak handle the worker's callbacks can capture.
final class MusicKaraokeJobSink: Sendable {
    // Only read and written on the main actor, where the queue itself lives.
    nonisolated(unsafe) weak var jobs: MusicKaraokeJobs?
    init(_ jobs: MusicKaraokeJobs) { self.jobs = jobs }
}
