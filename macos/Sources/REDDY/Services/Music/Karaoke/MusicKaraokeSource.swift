import Foundation
import Observation

// MARK: What the player sees

enum MusicKaraokePhase: Sendable, Equatable {
    /// Karaoke is switched off.
    case off
    /// On, but no model is installed, so nothing happens.
    case notSetUp
    case queued
    case preparing
    /// The instrumental is being written and already readable ahead of the playhead.
    case streaming
    case ready
    case tooLong
    case waitingToRetry
    case failed(MusicKaraokeFailure)
}

struct MusicKaraokeProgress: Sendable, Equatable {
    var phase: MusicKaraokePhase = .off
    /// The finished instrumental, or the growing file while `phase` is `.streaming`.
    var fileURL: URL?
    /// 0...1 of the song separated.
    var fraction: Double = 0
    /// Seconds written directly ahead of the position that was asked about.
    var readyAhead: TimeInterval = 0
    /// Seconds of audio produced per second of wall time.
    var productionRate: Double = 0
    var isComplete: Bool = false

    static let off = MusicKaraokeProgress(phase: .off)
    static let notSetUp = MusicKaraokeProgress(phase: .notSetUp)
}

/// The hook the player calls. All of it runs on the main actor.
@MainActor
protocol MusicKaraokeProviding: AnyObject {
    /// Starts (or continues) work on `track` from `startingAt` and returns where it stands right now. Never waits for the song to finish.
    func instrumentalURL(for track: MusicTrack, startingAt: TimeInterval) async -> MusicKaraokeProgress
    /// A cheap read of the same state, for the player's position tick.
    func progress(for track: MusicTrack, position: TimeInterval) -> MusicKaraokeProgress
    /// Tells the queue what is coming so the next two songs are prepared ahead.
    func prefetch(current: MusicTrack?, upcoming: [MusicTrack], position: TimeInterval)
    /// Keeps the file the player is on from being evicted from the cache while it plays.
    func pin(_ url: URL)
    func unpin(_ url: URL)
}

extension MusicKaraokeProviding {
    func pin(_ url: URL) {}
    func unpin(_ url: URL) {}
}

// MARK: Swap rule

/// Which audio the player is on right now.
enum MusicKaraokePlaying: Sendable, Equatable {
    case original
    /// The growing file.
    case instrumentalStream
    /// The finished cached file.
    case instrumentalFile
}

enum MusicKaraokeSwapDecision: Sendable, Equatable {
    case stay
    /// Load `url` at the current position, with a short equal-power crossfade.
    case swapToInstrumental(url: URL, finished: Bool, crossfade: TimeInterval)
    /// Go back to the original stream at the current position.
    case fallBackToOriginal(crossfade: TimeInterval)
}

/// When the vocals drop out. Pure: the caller supplies the time.
enum MusicKaraokeSwapPolicy {
    static let crossfade: TimeInterval = 0.08
    /// After a fall-back the stream gets a moment to get ahead again before another swap is tried.
    static let cooldown: TimeInterval = 2

    static func decide(playing: MusicKaraokePlaying, progress p: MusicKaraokeProgress,
                       lastFallBack: Date? = nil, now: Date = Date()) -> MusicKaraokeSwapDecision {
        switch playing {
        case .original:
            if let t = lastFallBack, now.timeIntervalSince(t) < cooldown { return .stay }
            if p.isComplete, let url = p.fileURL, p.phase == .ready { return .swapToInstrumental(url: url, finished: true, crossfade: crossfade) }
            if p.phase == .streaming, let url = p.fileURL,
               p.readyAhead >= MusicKaraokeLimits.swapMinReadySeconds, p.productionRate >= MusicKaraokeLimits.swapMinRate {
                return .swapToInstrumental(url: url, finished: false, crossfade: crossfade)
            }
            return .stay
        case .instrumentalStream:
            if p.isComplete, let url = p.fileURL, p.phase == .ready { return .swapToInstrumental(url: url, finished: true, crossfade: crossfade) }
            if p.phase == .off || p.phase == .notSetUp { return .fallBackToOriginal(crossfade: crossfade) }
            // The playhead outran the work (a seek ahead, or a slow stretch): back to the original until the stream covers the new spot.
            if p.readyAhead < MusicKaraokeLimits.fallBackMarginSeconds { return .fallBackToOriginal(crossfade: crossfade) }
            // The job died while the stream plays: leave before the end of what was written.
            if p.phase != .streaming, p.phase != .preparing, p.readyAhead < 2 { return .fallBackToOriginal(crossfade: crossfade) }
            return .stay
        case .instrumentalFile:
            if p.phase == .off || p.phase == .notSetUp { return .fallBackToOriginal(crossfade: crossfade) }
            return .stay
        }
    }
}

// MARK: Settings

struct MusicKaraokeSettings: Codable, Equatable, Sendable {
    var tier: MusicKaraokeTier = .light
    var modelID: String?
    var cacheLimitMB: Int = MusicKaraokeLimits.defaultCacheLimitMB
    var processor: MusicKaraokeProcessor = .cpu
}

/// Words for the status line, shared by the settings section and the lyrics switch.
enum MusicKaraokeStatusText {
    static func line(_ p: MusicKaraokeProgress) -> String {
        switch p.phase {
        case .off: "Karaoke is off."
        case .notSetUp: "Not set up"
        case .queued: "Waiting for its turn"
        case .preparing: p.fraction > 0 ? "\(Int(p.fraction * 100))% done" : "Getting this song ready"
        case .streaming: "Vocals removed ahead of you, \(Int(p.fraction * 100))% done"
        case .ready: "Vocals removed"
        case .tooLong: MusicKaraokeFailure.tooLong.message
        case .waitingToRetry: "Couldn't prepare this song. Trying again shortly."
        case .failed(let f): f.message
        }
    }

    static func help(_ p: MusicKaraokeProgress) -> String {
        switch p.phase {
        case .off: "Karaoke: remove vocals"
        case .notSetUp: "Karaoke is not set up. Open Music settings to add a model."
        case .queued, .preparing: "Karaoke on: getting this song ready"
        case .streaming, .ready: "Karaoke on: vocals removed"
        case .tooLong: "Karaoke on: this song is too long"
        case .waitingToRetry, .failed: "Karaoke couldn't prepare this song"
        }
    }
}

// MARK: Model holder

/// Keeps one loaded model and lets go of it after 30 seconds without work.
final class MusicKaraokeModelHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var model: MusicStemModel?
    private var key: String?
    private var lastUsed = Date.distantPast
    static let idleSeconds: Double = 30

    func get(key: String, make: () throws -> MusicStemModel) throws -> MusicStemModel {
        lock.lock(); defer { lock.unlock() }
        lastUsed = Date()
        if let m = model, self.key == key { return m }
        let m = try make()
        model = m; self.key = key
        return m
    }

    func touch() { lock.lock(); lastUsed = Date(); lock.unlock() }
    func unload() { lock.lock(); model = nil; key = nil; lock.unlock() }
    var isLoaded: Bool { lock.lock(); defer { lock.unlock() }; return model != nil }

    /// Unloads when the model has been idle long enough. Returns whether it did.
    @discardableResult
    func unloadIfIdle(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard model != nil, now.timeIntervalSince(lastUsed) >= Self.idleSeconds else { return false }
        model = nil; key = nil
        return true
    }
}

// MARK: Centre

/// Everything karaoke in one place: settings, models, the job queue and the cache. The player and the views talk only to this.
/// Off by default at every launch; with no model installed it reports "Not set up" and does nothing.
@MainActor @Observable
final class MusicKaraokeCenter: MusicKaraokeProviding {
    static let shared = MusicKaraokeCenter()

    private(set) var settings: MusicKaraokeSettings
    /// Never persisted: karaoke is off at every launch.
    private(set) var isEnabled = false
    let models: MusicKaraokeModelManager
    let cache: MusicKaraokeCache
    private(set) var jobs: MusicKaraokeJobs?
    private(set) var cacheBytes: Int64 = 0
    private(set) var processorInUse: MusicKaraokeProcessor?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let holder = MusicKaraokeModelHolder()
    @ObservationIgnored private var fetcher: MusicKaraokeAudioFetching?
    @ObservationIgnored private var upcoming: [MusicTrack] = []
    @ObservationIgnored private var current: MusicTrack?
    @ObservationIgnored private let clock: MusicKaraokeClock
    @ObservationIgnored private static let key = "music.karaoke.settings"

    init(models: MusicKaraokeModelManager? = nil, cache: MusicKaraokeCache? = nil, defaults: UserDefaults = .standard,
         clock: MusicKaraokeClock = MusicKaraokeSystemClock()) {
        self.defaults = defaults; self.clock = clock
        let s = (defaults.data(forKey: Self.key)).flatMap { try? JSONDecoder().decode(MusicKaraokeSettings.self, from: $0) } ?? MusicKaraokeSettings()
        var fixed = s
        fixed.cacheLimitMB = MusicKaraokeLimits.clampCacheLimitMB(s.cacheLimitMB)
        if !MusicKaraokeProcessor.coreMLAvailable { fixed.processor = .cpu }
        settings = fixed
        self.models = models ?? MusicKaraokeModelManager()
        self.cache = cache ?? MusicKaraokeCache(directory: MusicKaraokeCacheLocation.songs, limitMB: fixed.cacheLimitMB)
        self.cache.setLimitMB(fixed.cacheLimitMB)
    }

    // MARK: Wiring

    /// Tells karaoke how to reach a song's audio. Call once with the stream resolver's result, for example
    /// `{ track in let s = try await resolver.resolve(track, quality: .high); return MusicKaraokeAudioLocation(url: URL(string: s.url)!, headers: s.headers, isDownloadable: s.proto == .progressive) }`.
    func attach(locate: @escaping @Sendable (MusicTrack) async throws -> MusicKaraokeAudioLocation) {
        attach(fetcher: MusicKaraokeStreamFetcher(locate: locate))
    }

    func attach(fetcher: MusicKaraokeAudioFetching) {
        self.fetcher = fetcher
        rebuildJobs()
    }

    private func rebuildJobs() {
        jobs?.cancelAll()
        guard let fetcher else { jobs = nil; return }
        let holder = self.holder
        let models = self.models
        let settings = self.settings
        let separator = MusicKaraokeSeparator(fetcher: fetcher, cache: cache, loadModel: { [weak self] in
            guard let installed = await MainActor.run(body: { models.resolve(modelID: settings.modelID, tier: settings.tier) }) else {
                throw MusicKaraokeFailure.noModel
            }
            let url = await MainActor.run { models.compiledURL(for: installed) }
            let processor = settings.processor
            let m = try holder.get(key: installed.id + "|" + processor.rawValue) {
                if installed.family == .spleeter { return try SpleeterStemModel(compiledURL: url, processor: processor) }
                return try MusicCoreMLStemModel(compiledURL: url, layout: installed.layout, processor: processor)
            }
            await MainActor.run { self?.processorInUse = processor }
            return m
        })
        let j = MusicKaraokeJobs(worker: separator, cache: cache, clock: clock, modelStem: { [weak self] in self?.activeModel?.id })
        j.setEnabled(isEnabled)
        jobs = j
    }

    // MARK: State

    /// The model that would be used: the chosen one, else any installed one of the chosen tier.
    var activeModel: MusicKaraokeInstalledModel? {
        models.resolve(modelID: settings.modelID, tier: settings.tier)
    }
    var isSetUp: Bool { activeModel != nil }

    /// Short honest status for the settings page.
    var statusText: String {
        if !isSetUp { return "Not set up" }
        if !isEnabled { return "Off" }
        if jobs == nil { return "Waiting for the player" }
        return "On"
    }

    func setEnabled(_ on: Bool) {
        // With no model the switch does nothing: it stays off and the status says so.
        isEnabled = on && isSetUp
        jobs?.setEnabled(isEnabled)
        if isEnabled { jobs?.updateWanted(current: current, upcoming: upcoming) }
        else if !on { holder.touch() }
    }

    func update(_ change: (inout MusicKaraokeSettings) -> Void) {
        let before = settings
        var s = settings; change(&s)
        s.cacheLimitMB = MusicKaraokeLimits.clampCacheLimitMB(s.cacheLimitMB)
        if !MusicKaraokeProcessor.coreMLAvailable { s.processor = .cpu }
        settings = s
        if let d = try? JSONEncoder().encode(s) { defaults.set(d, forKey: Self.key) }
        cache.setLimitMB(s.cacheLimitMB)
        if s.cacheLimitMB != before.cacheLimitMB { cache.evict(); refreshCacheSize() }
        if s.modelID != before.modelID || s.tier != before.tier || s.processor != before.processor {
            holder.unload()
            rebuildJobs()
            if !isSetUp { isEnabled = false }
        }
    }

    func clearCache() {
        if let jobs { jobs.clearCache() } else { cache.clear() }
        refreshCacheSize()
    }

    /// The app locked or a Kids profile began: switch off, stop the work in flight and any model download.
    func shutDown() {
        isEnabled = false
        jobs?.setEnabled(false)
        jobs?.cancelAll()
        models.cancelDownload()
    }

    func refreshCacheSize() { cacheBytes = cache.usedBytes }

    /// After a model is deleted: forget it as the chosen one and switch off if nothing is left.
    func modelDeleted(_ id: String) {
        holder.unload()
        if settings.modelID == id { update { $0.modelID = nil } }
        if !isSetUp { isEnabled = false }
        jobs?.modelChanged()
    }

    /// Pinning for the file the player is playing or has queued next.
    func pin(_ url: URL) { cache.pin(url) }
    func unpin(_ url: URL) { cache.unpin(url) }

    // MARK: Provider

    func prefetch(current: MusicTrack?, upcoming: [MusicTrack], position: TimeInterval) {
        self.current = current; self.upcoming = upcoming
        guard isEnabled else { return }
        jobs?.updateWanted(current: current, upcoming: upcoming, startingAt: position)
    }

    func instrumentalURL(for track: MusicTrack, startingAt: TimeInterval) async -> MusicKaraokeProgress {
        guard isEnabled else { return isSetUp ? .off : .notSetUp }
        if current?.uid != track.uid { current = track }
        jobs?.updateWanted(current: track, upcoming: upcoming, startingAt: startingAt)
        return progress(for: track, position: startingAt)
    }

    func progress(for track: MusicTrack, position: TimeInterval) -> MusicKaraokeProgress {
        guard isSetUp else { return .notSetUp }
        guard isEnabled, let jobs else { return .off }
        if !MusicKaraokeLimits.isQueueable(durationMs: track.durationMs) { return MusicKaraokeProgress(phase: .tooLong) }
        switch jobs.states[track.uid] {
        case .ready(let url)?:
            return MusicKaraokeProgress(phase: .ready, fileURL: url, fraction: 1, readyAhead: .infinity, productionRate: .infinity, isComplete: true)
        case .preparing(let f)?:
            guard let g = jobs.growing[track.uid] else { return MusicKaraokeProgress(phase: .preparing, fraction: f) }
            let ahead = g.readyAhead(of: position), rate = g.productionRate(now: clock.now())
            return MusicKaraokeProgress(phase: ahead > 0 && rate > 0 ? .streaming : .preparing, fileURL: g.url,
                                        fraction: g.fractionWritten, readyAhead: ahead, productionRate: rate, isComplete: g.isComplete)
        case .waitingRetry?: return MusicKaraokeProgress(phase: .waitingToRetry)
        case .exhausted(let f)?: return MusicKaraokeProgress(phase: .failed(f))
        case .tooLong?: return MusicKaraokeProgress(phase: .tooLong)
        case .queued?, nil:
            if jobs.blockedReason == .noModel { return .notSetUp }
            return MusicKaraokeProgress(phase: .queued)
        }
    }
}
