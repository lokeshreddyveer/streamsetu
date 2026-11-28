import Foundation
import Observation

// The player's single point of contact with Automix. The player asks `advice(for:)` on every position tick; Automix answers "do what you
// always did" (`useDefault`) whenever it has nothing trustworthy to say, so a missing analysis, a streamed song with no file on disk, a
// low-confidence grid or any failure all leave the existing crossfade and gapless behaviour untouched.

struct MusicTransitionQuery: Sendable {
    var current: MusicTrack
    /// A file on this device holding the playing song, when there is one (a download, a local file or an audio-cache entry).
    var currentURL: URL?
    var next: MusicTrack?
    var nextURL: URL?
    var position: Double
    /// The playing copy's length in seconds, as the player measures it.
    var duration: Double
    var tempo: Double
    var settings: MusicAutomixSettings
}

enum MusicTransitionAdvice: Equatable, Sendable {
    case useDefault
    /// Plain crossfade or gapless advance, but timed to the real end of the song instead of the end of the file.
    case fadeEnd(contentEnd: Double)
    case mix(MusicMixPlan)
}

/// The one protocol the player consults.
@MainActor
protocol MusicTransitionAdvising: AnyObject {
    func advice(for query: MusicTransitionQuery) -> MusicTransitionAdvice
    /// Decodes both regions and builds the decks. False when anything failed; the player then carries on as before.
    func prepareMix(_ plan: MusicMixPlan, style: MusicAutomixStyle, outgoing: URL, incoming: URL) async -> Bool
    /// Starts the decks together. `outgoingPosition` is the player's live position in the outgoing file, `level` the sound level to play at.
    func beginMix(outgoingPosition: Double, outgoingLevel level: Float) -> MusicAutomixRenderer.Started?
    func abortMix()
    /// The listening volume changed during a mix.
    func setMixLevel(_ level: Float)
    var onHandover: (@MainActor () -> Void)? { get set }
}

@MainActor @Observable
final class MusicAutomixController: MusicTransitionAdvising {
    /// One line for the settings page.
    private(set) var statusText = "Off"
    private(set) var cachedSongs = 0
    private(set) var cacheBytes: Int64 = 0

    @ObservationIgnored let cache: MusicAnalysisCache
    @ObservationIgnored private let renderer = MusicAutomixRenderer()
    @ObservationIgnored private var analyses: [String: MusicTrackAnalysis] = [:]
    @ObservationIgnored private var diskMisses: Set<String> = []
    @ObservationIgnored private var queued: [(key: String, uid: String, duration: Double, url: URL, title: String)] = []
    @ObservationIgnored private var inFlight: String?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var memo: (key: String, generation: Int, decision: MusicAutomixDecision)?
    @ObservationIgnored private var failedPairs: Set<String> = []

    @ObservationIgnored var onHandover: (@MainActor () -> Void)? {
        get { renderer.onHandover }
        set { renderer.onHandover = newValue }
    }

    init(directory: URL) {
        cache = MusicAnalysisCache(directory: directory.appendingPathComponent("Automix", isDirectory: true))
        refreshCacheStats()
    }

    // MARK: advice

    func advice(for q: MusicTransitionQuery) -> MusicTransitionAdvice {
        guard q.settings.enabled else {
            if statusText != "Off" { statusText = "Off" }
            return .useDefault
        }
        let outKey = Self.key(q.current.uid, q.duration)
        let outAnalysis = known(outKey, uid: q.current.uid, duration: q.duration)
        if outAnalysis == nil { enqueue(key: outKey, uid: q.current.uid, duration: q.duration, url: q.currentURL, title: q.current.title) }
        var inAnalysis: MusicTrackAnalysis?
        if let n = q.next {
            let inKey = Self.key(n.uid, n.duration)
            inAnalysis = known(inKey, uid: n.uid, duration: n.duration)
            if inAnalysis == nil { enqueue(key: inKey, uid: n.uid, duration: n.duration, url: q.nextURL, title: n.title) }
        }
        let decisionKey = [q.current.uid, q.next?.uid ?? "", String(q.settings.style.rawValue), String(q.settings.strength), String(Int(q.duration))].joined(separator: "|")
        let decision: MusicAutomixDecision
        if let m = memo, m.key == decisionKey, m.generation == generation {
            decision = m.decision
        } else {
            decision = MusicAutomixPlanner.decide(MusicAutomixInput(
                outgoing: Self.facts(q.current), incoming: q.next.map(Self.facts) ?? MusicTrackFacts(),
                outgoingAnalysis: outAnalysis, incomingAnalysis: inAnalysis, position: 0, listenerTempo: q.tempo, settings: q.settings))
            memo = (decisionKey, generation, decision)
        }
        switch decision {
        case .fallback(let why):
            setStatus(outAnalysis == nil ? statusWaiting(q) : "Using a plain transition: \(why)")
            return .useDefault
        case .trueEndFade(let end, let why):
            setStatus("Fading at the real end of the song (\(why))")
            return .fadeEnd(contentEnd: end)
        case .mix(let plan):
            if q.position > plan.outStart + MusicAutomixPlanner.lateTolerance {
                setStatus("Using a plain transition: too late to blend")
                return .useDefault
            }
            if failedPairs.contains(decisionKey) { return .useDefault }
            setStatus("Next: \(plan.kind == .beatMatched ? "beat-matched blend" : "filter blend"), \(Int(plan.overlap.rounded())) s")
            return .mix(plan)
        }
    }

    /// The player reports that a prepared mix failed so it is not retried for the same pair.
    func markFailed(current: MusicTrack, next: MusicTrack, settings: MusicAutomixSettings, duration: Double) {
        failedPairs.insert([current.uid, next.uid, String(settings.style.rawValue), String(settings.strength), String(Int(duration))].joined(separator: "|"))
    }

    private func statusWaiting(_ q: MusicTransitionQuery) -> String {
        if q.currentURL == nil { return "Waiting: this song is streamed and not stored on this device" }
        return inFlight != nil ? "Analysing the song" : "Waiting to analyse the song"
    }

    private func setStatus(_ s: String) { if s != statusText { statusText = s } }

    // MARK: mixing

    func prepareMix(_ plan: MusicMixPlan, style: MusicAutomixStyle, outgoing: URL, incoming: URL) async -> Bool {
        do { try await renderer.prepare(plan: plan, style: style, outgoingURL: outgoing, incomingURL: incoming); return true } catch { return false }
    }

    func beginMix(outgoingPosition: Double, outgoingLevel level: Float) -> MusicAutomixRenderer.Started? {
        try? renderer.begin(outgoingPosition: outgoingPosition, level: level)
    }

    func abortMix() { renderer.stop(immediately: false) }
    func setMixLevel(_ level: Float) { renderer.setLevel(level) }

    // MARK: analysis

    private static func key(_ uid: String, _ duration: Double) -> String { MusicAnalysisCache.key(trackUID: uid, duration: duration) }

    private static func facts(_ t: MusicTrack) -> MusicTrackFacts {
        MusicTrackFacts(title: t.title, album: t.album?.title ?? "", artist: t.artistLine, duration: t.duration)
    }

    private func known(_ key: String, uid: String, duration: Double) -> MusicTrackAnalysis? {
        if let a = analyses[key] { return a }
        guard !diskMisses.contains(key) else { return nil }
        if let a = cache.analysis(trackUID: uid, duration: duration) { analyses[key] = a; generation += 1; return a }
        diskMisses.insert(key)
        return nil
    }

    private func enqueue(key: String, uid: String, duration: Double, url: URL?, title: String) {
        guard let url, url.isFileURL, duration >= MusicBeatAnalyzer.minSeconds, inFlight != key, !queued.contains(where: { $0.key == key }) else { return }
        // A hot or low-power device keeps its cycles: the request is simply made again on a later tick.
        let info = ProcessInfo.processInfo
        guard info.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue, !info.isLowPowerModeEnabled else { return }
        queued.append((key, uid, duration, url, title))
        startWorker()
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task(priority: .utility) { [weak self] in
            while let self, !Task.isCancelled, let job = self.queued.first {
                self.queued.removeFirst()
                self.inFlight = job.key
                let result = await MusicBeatAnalyzer.analyze(url: job.url)
                var stored = result
                if stored.duration == 0 { stored.duration = job.duration }
                // The decoded length must match the song's length; a clipped or different copy is recorded as failed, not trusted.
                if !stored.failed, abs(stored.duration - job.duration) > MusicAnalysisCache.lengthTolerance { stored = .failedEntry(duration: job.duration) }
                self.cache.store(stored, trackUID: job.uid, duration: job.duration)
                self.analyses[job.key] = stored
                self.generation += 1
                self.inFlight = nil
                self.refreshCacheStats()
            }
            self?.worker = nil
        }
    }

    // MARK: cache

    func refreshCacheStats() {
        cachedSongs = cache.count
        cacheBytes = cache.totalBytes
    }

    func clearCache() {
        cache.clear()
        analyses = [:]; diskMisses = []; generation += 1; memo = nil; failedPairs = []
        refreshCacheStats()
    }
}
