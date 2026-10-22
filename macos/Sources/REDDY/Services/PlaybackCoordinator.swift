import Foundation
import AVFoundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import Observation

/// Owns playback for the whole app. It lives outside any view, so changing screens or channels never destroys the player.
/// Views read its state and call its intents; they never touch an engine directly.
@MainActor @Observable
final class PlaybackCoordinator {
    // MARK: observable state

    private(set) var state: PlaybackState = .idle { didSet { sleepGuard.update(hold: SleepPolicy.shouldKeepAwake(state: state, hasPlayback: current != nil)) } }
    private(set) var current: PlaybackRequest?
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval?
    private(set) var metrics = PlaybackMetrics()
    private(set) var activeEngine: PlaybackEngineKind = .avPlayer
    private(set) var audioTracks: [AudioTrack] = []
    private(set) var subtitleTracks: [SubtitleTrack] = []
    private(set) var statusMessage: String?
    private(set) var currentChannel: Channel?
    private(set) var queue: [Channel] = []
    private(set) var upNext: Episode?
    private(set) var upNextSeries: Series?
    var volume: Double { didSet { applyVolume(); settings.volume = volume } }
    /// How much louder or quieter this channel plays than the main volume. Remembered per channel.
    private(set) var channelVolumeTrim: Double = 0
    /// The full-screen channel switcher: a list of the channels in the current queue with what is on now and next.
    private(set) var showChannelSwitcher = false
    private(set) var switcher = ChannelSwitcherModel(count: 0, current: nil)
    private(set) var channelEnginePreference: PlaybackEnginePreference?
    let channelPrefs: ChannelPlaybackPrefs
    var effectiveVolume: Double { ChannelVolume.effective(master: volume, trim: channelVolumeTrim) * sleepFade }
    var isMuted = false { didSet { engine.setMuted(isMuted) } }
    private(set) var rate: Double = 1
    // Video presentation (see VideoLayout.swift). Overrides are remembered per channel/title.
    private(set) var videoLayout = VideoLayoutSettings()
    private(set) var hasItemLayoutOverride = false
    var videoSize: CGSize { CGSize(width: metrics.width, height: metrics.height) }
    private(set) var qualityOptions: [QualityOption] = []
    private(set) var selectedQualityID: String?
    private(set) var audioDelay: Double = 0
    private(set) var subtitleDelay: Double = 0
    private(set) var audioProcessing: AudioProcessingMode = .off
    var capabilities: PlaybackCapabilities { engine.capabilities }
    /// What the user asked for. The real state is `fullscreenPhase`, which only changes from window lifecycle callbacks.
    var isFullscreen = false {
        // The channel list belongs to one full-screen session: it never carries over into the next.
        didSet { if isFullscreen != oldValue { showChannelSwitcher = false } }
    }
    var fullscreenPhase: FullscreenPhase = .windowed
    /// True while the separate "StreamSetu Player" window is showing the video.
    var isPoppedOut = false
    /// Set when fullscreen was entered from the expanded player, so leaving fullscreen goes back to it.
    var restoreExpandedAfterFullscreen = false
    /// Which view is allowed to hold the video layers. There is exactly one at any moment.
    var surfaceOwner: SurfaceOwner {
        if fullscreenPhase != .windowed { return .fullscreen }
        if isPoppedOut { return .popout }
        if isExpanded { return .expanded }
        return isLive && livePreviewVisible ? .embedded : .bar
    }
    /// True while Live TV is showing its own preview pane. Otherwise the video lives in the bottom bar.
    var livePreviewVisible = false
    /// How many times a stream has been (re)loaded. Fullscreen transitions must never change it.
    var loadCount: Int { generation }
    /// The expanded player dialog. Shares this session; it is only another view of it.
    var isExpanded = false

    var isActive: Bool { state.isActive || current != nil && state != .idle }
    var isLive: Bool { current?.isLive ?? false }
    var title: String { current?.title ?? "" }
    var subtitle: String? { current?.subtitle }

    // MARK: dependencies

    private let factory: PlaybackEngineFactory
    private let resolver: StreamResolver
    private let historyRepo: HistoryRepository
    private let historyService: HistoryService
    private let catalog: CatalogRepository
    private let settings: AppSettings
    private let itemMemory = ItemMemory()
    private var memoryEntry: ItemMemory.Entry?
    private let introSkip = IntroSkip()
    private let episodeMarks = EpisodeMarks()
    private let diagnostics: DiagnosticsService
    private let videoPrefs: VideoPreferencesRepository
    private let recovery = PlaybackRecoveryService()
    private let sleepGuard = SleepGuard()
    private var wasRunningBeforeSleep = false
    private var wakeTask: Task<Void, Never>?
    private var powerObservers: [NSObjectProtocol] = []

    private var engine: any PlaybackEngine
    /// The system player behind what is playing now, when it is the one playing (SharePlay keeps it in step with others); nil while another engine plays.
    var activeAVPlayer: AVPlayer? { (engine as? AVPlayerEngine)?.player }
    private var startTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var stateTasks: [PlaybackEngineKind: Task<Void, Never>] = [:]
    private var attempt = 0
    private var switchedEngine = false
    private let pacer = ConnectionPacer()
    /// The provider whose live stream is open right now (nil when nothing live is open).
    private var openLiveSource: UUID?
    private var sessionID: Int64?
    private var recordedPlay = false
    private var stableTask: Task<Void, Never>?
    private var lastSavedAt = Date.distantPast
    /// When the person asked for what is playing now: the start-time statistics measure from here, retries included.
    private var tapAt = Date()
    /// When the provider last refused each movie or episode for good, so an immediate second attempt does not wait through every retry again.
    private var refusedAt: [String: Date] = [:]
    /// Watches the connection during playback (see NetworkRecovery). True while a stream waits for the internet to come back.
    private let network = NetworkWatch()
    private(set) var waitingForNetwork = false
    private var switchCheckTask: Task<Void, Never>?
    private var previousChannel: Channel?
    private var currentMovie: Movie?
    private var currentEpisode: (Episode, Series)?
    private var appliedPreferredTracks = false
    private var generation = 0

    init(factory: PlaybackEngineFactory, resolver: StreamResolver, history: HistoryRepository, historyService: HistoryService,
         catalog: CatalogRepository, settings: AppSettings, diagnostics: DiagnosticsService, videoPrefs: VideoPreferencesRepository,
         channelPrefs: ChannelPlaybackPrefs = ChannelPlaybackPrefs()) {
        self.channelPrefs = channelPrefs
        self.factory = factory; self.resolver = resolver; self.historyRepo = history; self.historyService = historyService
        self.catalog = catalog; self.settings = settings; self.diagnostics = diagnostics; self.videoPrefs = videoPrefs
        engine = factory.engine(.avPlayer)
        volume = settings.volume
        audioProcessing = settings.audioProcessing        // the saved default; the player menu can still change it for one session
        videoLayout = videoPrefs.globalLayout()
        engine.setVolume(effectiveVolume)
        observe(engine)
        observeSleepAndWake()
        observeNetwork()
    }

    // MARK: sleep and wake

    // MARK: connection changes

    private func observeNetwork() {
        network.onChange = { [weak self] old, new in self?.networkChanged(from: old, to: new) }
        network.start()
    }

    private func networkChanged(from old: NetworkLink, to new: NetworkLink) {
        Trace.log("network \(old) -> \(new)")
        switch NetworkRecovery.reaction(from: old, to: new, state: state, hasStream: current != nil) {
        case .ignore: break
        case .markOffline: waitForNetwork()
        case .resume:
            waitingForNetwork = false; statusMessage = nil
            attempt = 0
            reResolveAndStart()
        case .checkAfterSwitch:
            // Connections made on the old network are dead. A stream that is playing carries on; one that is stuck starts again.
            switchCheckTask?.cancel()
            switchCheckTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self, !Task.isCancelled, self.current != nil, NetworkRecovery.shouldRestartAfterSwitch(state: self.state) else { return }
                Trace.log("network switch: stream was stuck, starting it again")
                self.attempt = 0
                self.reResolveAndStart()
            }
        }
    }

    /// Offline: waiting costs nothing and retries only waste attempts, so the stream waits and starts again when the connection returns.
    private func waitForNetwork() {
        waitingForNetwork = true
        statusMessage = "No internet connection. It will continue when the connection is back."
        recoveryTask?.cancel()
        state = .recovering
    }

    /// The Mac going to sleep drops network connections, so a live stream that was running is dead on wake. Remember whether
    /// something was running, and on wake reconnect it (a live stream afresh, a movie from where it was).
    private func observeSleepAndWake() {
        #if os(macOS)
        let center = NSWorkspace.shared.notificationCenter
        powerObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWillSleep() }
        })
        powerObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        })
        #endif
        // iOS keeps playing audio and picture-in-picture in the background and resumes by itself, so nothing is restarted there.
    }

    func systemWillSleep() {
        wasRunningBeforeSleep = SleepPolicy.shouldKeepAwake(state: state, hasPlayback: current != nil)
        wakeTask?.cancel()
        if wasRunningBeforeSleep { saveProgress(force: true) }
    }

    func systemDidWake() {
        guard SleepPolicy.shouldReconnectAfterWake(wasRunningBeforeSleep: wasRunningBeforeSleep, hasPlayback: current != nil) else { return }
        wasRunningBeforeSleep = false
        statusMessage = "Reconnecting after sleep…"
        state = .recovering
        attempt = 0
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)           // give the network a moment to come back
            guard let self, !Task.isCancelled, self.current != nil else { return }
            self.reResolveAndStart()
        }
    }

    // MARK: video surfaces

    var avPlayer: AVPlayer { factory.avEngine.player }
    #if os(macOS) || STREAMSETU_MPV
    var mpvLayer: AVSampleBufferDisplayLayer? { factory.mpvEngine?.displayLayer }
    /// What the iPhone and iPad show MPV's video on (a plain layer; see MPVPlayerEngine.surfaceLayer).
    var mpvSurface: CALayer? { factory.mpvEngine?.surfaceLayer }
    #endif
    var availableEngines: Set<PlaybackEngineKind> { factory.available }
    /// What an engine supports, or nil when that engine can't run on this Mac.
    func capabilities(of kind: PlaybackEngineKind) -> PlaybackCapabilities? { factory.available.contains(kind) ? factory.engine(kind).capabilities : nil }
    var screenshotSupported: Bool { engine.capabilities.screenshot }

    // MARK: intents

    /// Channels (quality copies) already tried for the channel being watched, so a failing one is never retried by the fallback.
    private var triedVariants: Set<String> = []
    /// Watching privately: this one play leaves nothing behind. No history, resume point, watched tick, statistics, last channel, subtitle lookup or lock-screen details, and nothing to sync.
    /// It is chosen per title ("Watch Privately") and ends with that play; what follows from it (the next episode, the next channel, another copy) stays private too.
    private(set) var isPrivate = false

    /// Set while a kids profile with limits is in use: asks what stops playback now, counts the time watched, and says how much is left.
    struct ViewingGuard {
        let block: () -> ViewingBlock?
        let add: (Double) -> Void
        let remaining: () -> Double?
    }
    var viewingGuard: ViewingGuard?

    /// A movie or episode started or stopped playing, for Trakt. Never sent for a private play. Set by the app; the player only announces and carries on.
    enum WatchEvent { case started(TraktItem), stopped(TraktItem, progress: Double) }
    var onWatchEvent: ((WatchEvent) -> Void)?
    private var announced: TraktItem?

    private func traktItem() -> TraktItem? {
        if let m = currentMovie, current?.isLive == false { return .movie(title: TraktItem.cleanTitle(m.title), year: m.releaseYear ?? MetadataNormalizer.year(from: m.title)) }
        if let (e, s) = currentEpisode { return .episode(show: TraktItem.cleanTitle(s.title), year: s.releaseYear, season: e.seasonNumber, number: e.episodeNumber) }
        return nil
    }
    /// Called when something starts or stops playing, so other devices on the network can be told promptly.
    var onSessionChange: (() -> Void)?
    /// Why playback was stopped or refused by the profile's limit. The screen shows it until a parent adds time or the time passes.
    var viewingBlock: ViewingBlock?
    private var warnedMinutes: Set<Int> = []

    /// Set by the app: the programme that is on now for a channel (nil without guide data).
    var programOnNow: ((Channel) -> EPGProgram?)?
    /// A programme that began a while ago on the channel just opened, offered as "Start from the beginning" through the provider's catch-up. It goes away after a short while.
    private(set) var startOverOffer: EPGProgram?
    private var startOverShownAt: Date?

    /// Plays the offered programme from its start.
    func startOver() {
        guard let p = startOverOffer, let c = currentChannel else { return }
        startOverOffer = nil
        playCatchup(channel: c, program: p)
    }

    func play(channel: Channel, queue newQueue: [Channel]? = nil, isFallback: Bool = false, privately: Bool = false) {
        if !isFallback { triedVariants = [channel.id] }
        if let newQueue { queue = newQueue }
        if let c = currentChannel, c.id != channel.id { previousChannel = c }
        reset(for: .channel)
        isPrivate = privately
        currentChannel = channel
        if !privately { settings.lastChannelID = channel.id }
        let pref = channelPrefs.pref(for: channel.id)
        channelVolumeTrim = pref.volumeTrim; channelEnginePreference = pref.engineChoice
        applyVolume()
        begin { try self.resolver.resolve(channel: channel) }
        if !isFallback, let p = programOnNow?(channel), StartOver.canOffer(program: p, archiveDays: channel.archiveDays) {
            startOverOffer = p; startOverShownAt = Date()
        }
    }

    /// Plays a past programme from the provider's archive. Falls back to doing nothing (with a message) when the channel has none.
    func playCatchup(channel: Channel, program: EPGProgram) {
        guard channel.archiveDays > 0 else { statusMessage = "This channel has no catch-up."; return }
        let privately = isPrivate          // starting over from a private channel stays private
        reset(for: .channel)
        isPrivate = privately
        currentChannel = channel
        queue = queue.isEmpty ? [channel] : queue
        let offset = settings.catchupOffsetMinutes(for: channel.sourceID)
        begin { guard let r = try self.resolver.resolveCatchup(channel: channel, program: program, utcOffsetMinutes: offset) else { throw SourceError.unsupported("catch-up") }; return r }
    }

    /// True while a past programme is playing.
    var isCatchup: Bool { current?.isCatchup ?? false }

    /// Leaves catch-up and returns to the channel's live stream.
    func goLiveFromCatchup() { if isCatchup, let c = currentChannel { play(channel: c, privately: isPrivate) } }

    /// Finds the copies of a film in the library (set by the container).
    var movieCopies: (@Sendable (Movie) -> [Movie])?
    /// The other copies of the film that was just started, best first: if the one playing fails for good, the next is tried.
    private var fallbackCopies: [Movie] = []

    func play(movie opened: Movie, resume: Bool? = nil, bestCopy: Bool = true, remaining: [Movie] = [], privately: Bool = false) {
        var movie = opened, rest = remaining
        if bestCopy, settings.bestVersionFirst, let find = movieCopies {
            let ordered = BestVersion.order(find(opened)) { [$0.title, $0.categoryName] }
            if let first = ordered.first { movie = first; rest = Array(ordered.dropFirst()) }
        }
        reset(for: .movie)
        isPrivate = privately
        fallbackCopies = rest
        currentMovie = movie
        let shouldResume = resume ?? settings.resumeAutomatically
        begin { try self.resolver.resolve(movie: movie, resume: shouldResume) }
    }

    /// A video from Files, Photos, a folder or a WebDAV server. It plays like a movie that belongs to no playlist, and its position is remembered.
    /// With subtitle files beside it, the player that can show them (MPV) is used.
    func play(file url: URL, title: String, headers: [String: String] = [:], subtitles: [URL] = [], resume: Bool? = nil, privately: Bool = false) {
        reset(for: .movie)
        isPrivate = privately
        currentMovie = nil
        let id = LocalMedia.itemID(url.isFileURL ? url.lastPathComponent + "|" + url.path : url.absoluteString)
        var request = PlaybackRequest(itemID: id, kind: .movie, sourceID: LocalMedia.sourceID, title: title, url: url, isLive: false)
        request.headers = headers
        if resume ?? settings.resumeAutomatically, let p = try? historyRepo.progress(for: id), !p.completed, p.positionSeconds > 10 { request.startPosition = p.positionSeconds }
        tapAt = Date()
        state = .resolving
        switchedEngine = false
        current = request
        loadLayout(for: id)
        let wantsSubtitles = !subtitles.isEmpty && factory.available.contains(.mpv)
        start(request, engineOverride: wantsSubtitles ? .mpv : nil)
        if !subtitles.isEmpty {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard let self, self.current?.itemID == id else { return }
                for sub in subtitles { self.loadSubtitleFile(sub) }
            }
        }
    }

    func play(episode: Episode, series: Series, resume: Bool? = nil, privately: Bool = false) {
        reset(for: .episode)
        isPrivate = privately
        currentEpisode = (episode, series)
        upNext = try? historyService.nextEpisode(after: episode)
        upNextSeries = series
        let shouldResume = resume ?? settings.resumeAutomatically
        begin { try self.resolver.resolve(episode: episode, series: series, resume: shouldResume) }
    }

    func pause() { if state == .playing || state == .buffering { engine.pause() } }
    func resume() { if state == .paused { Task { try? await engine.play() } } }

    func togglePause() {
        switch state {
        case .playing, .buffering: engine.pause()
        case .paused: Task { try? await engine.play() }
        case .ended: seek(to: 0)
        case .failed: retryNow()
        default: break
        }
    }

    func seek(to t: TimeInterval) {
        guard !isLive else { return }
        let target = max(0, min(t, duration ?? t))
        Task { try? await engine.seek(to: target) }
    }

    func seek(by delta: TimeInterval) {
        if let series = currentEpisode?.1, !isLive, introSkip.isOpeningSkip(from: position, to: position + delta) { introSkip.learn(seriesID: series.id, end: position + delta) }
        if let series = currentEpisode?.1, !isLive, let d = duration, episodeMarks.isCreditsSkip(from: position, to: position + delta, duration: d) { episodeMarks.learn(seriesID: series.id, from: position, duration: d) }
        seek(to: position + delta)
    }

    func stop() {
        if sleepTimer != nil, sleepTask != nil, !(sleepTimer?.hasEnded() ?? false) { cancelSleepTimer() }
        stopRecording()
        saveProgress(force: true)
        cancelWork()
        endSession(outcome: "stopped", error: nil)
        engine.stop()
        if let src = openLiveSource { pacer.closed(src); openLiveSource = nil }
        current = nil; currentChannel = nil; currentMovie = nil; currentEpisode = nil; upNext = nil
        isPrivate = false
        waitingForNetwork = false; switchCheckTask?.cancel()
        state = .idle; position = 0; duration = nil; statusMessage = nil; audioTracks = []; subtitleTracks = []; isAudioOnly = false; playingSince = nil
        isFullscreen = false; isExpanded = false; restoreExpandedAfterFullscreen = false; showChannelSwitcher = false; cancelNumberEntry()
    }

    /// Called once the fullscreen window is gone: return to the expanded player if that is where fullscreen began.
    func finishFullscreen() {
        if restoreExpandedAfterFullscreen && current != nil { isExpanded = true }
        restoreExpandedAfterFullscreen = false
    }

    func retryNow() {
        guard let r = current else { return }
        tapAt = Date()
        attempt = 0
        start(r)
    }

    /// Stalls so far in this session. A stream that keeps stopping to buffer is offered a steadier setup.
    var repeatedBuffering: Bool { state == .playing && metrics.stallCount >= 3 }

    /// Gives this playlist the Stability buffering mode and restarts the stream with it.
    func useStabilityBufferingForThisPlaylist() {
        guard let r = current else { return }
        settings.setBufferingOverride(.large, for: r.sourceID)
        retryNow()
    }

    // MARK: live rewind

    /// How far behind the live edge playback is, in seconds. Updated twice a second while a live MPV stream plays.
    private(set) var behindLive: Double = 0
    /// Pause and rewind work for this stream: live, played by an engine that keeps a buffer, and the setting is on.
    var liveRewindAvailable: Bool { isLive && !isCatchup && capabilities.liveRewind && settings.liveRewind }

    func rewindLive(by seconds: TimeInterval) {
        guard liveRewindAvailable else { return }
        let target = max(0, position - seconds)
        Task { try? await engine.seek(to: target) }
    }

    /// Jumps to the newest buffered moment, which is the live edge.
    func goToLiveEdge() {
        guard liveRewindAvailable, let end = engine.liveBufferEnd else { return }
        Task { try? await engine.seek(to: max(0, end - 1)) }
    }

    // MARK: radio mode

    /// True for a stream that has sound and no picture (a radio channel): the player then shows the channel's artwork instead of
    /// a black rectangle. Decided from what the engine reports, with a hint from the folder name while it is still loading.
    private(set) var isAudioOnly = false
    private var playingSince: Date?

    var looksLikeRadio: Bool {
        guard isLive, let name = currentChannel?.categoryName?.lowercased() else { return false }
        return name.contains("radio") || name.contains("fm ") || name.hasSuffix(" fm")
    }

    static func audioOnly(state: PlaybackState, videoWidth: Int, secondsPlaying: TimeInterval, looksLikeRadio: Bool, isLive: Bool) -> Bool {
        guard isLive, videoWidth == 0 else { return false }
        switch state {
        case .playing: return looksLikeRadio || secondsPlaying > 3
        case .buffering, .preparing, .resolving: return looksLikeRadio
        default: return false
        }
    }

    // MARK: sleep timer

    /// When set, playback stops at this time, after a ten-second fade.
    private(set) var sleepTimer: SleepTimer?
    private var sleepFade: Double = 1
    private var sleepTask: Task<Void, Never>?

    func startSleepTimer(minutes: Int) { startSleepTimer(SleepTimer(minutes: minutes)) }

    func startSleepTimer(_ timer: SleepTimer) {
        cancelSleepTimer()
        sleepTimer = timer
        sleepTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let t = self.sleepTimer else { return }
                if t.hasEnded() { self.finishSleepTimer(); return }
                self.sleepFade = t.volumeFactor()
                self.applyVolume()
                try? await Task.sleep(nanoseconds: t.remaining() < SleepTimer.fadeSeconds ? 250_000_000 : 1_000_000_000)
            }
        }
    }

    func cancelSleepTimer() {
        sleepTask?.cancel(); sleepTask = nil; sleepTimer = nil
        if sleepFade != 1 { sleepFade = 1; applyVolume() }
    }

    private func finishSleepTimer() {
        sleepTask = nil; sleepTimer = nil
        stop()                                   // pauses nothing halfway: playback ends, as if the person had pressed stop
        sleepFade = 1; applyVolume()
    }

    /// A timer that ends with the movie or episode now playing (only when its length is known).
    func startSleepTimerAtEndOfItem() {
        guard !isLive, let d = duration, d > position else { return }
        startSleepTimer(SleepTimer(until: Date().addingTimeInterval(d - position)))
    }

    // MARK: channel numbers

    /// Digits typed so far for a channel number, shown on screen until the jump happens. The number of a channel is its place
    /// in the list being watched (the channel list you are browsing), counted from 1.
    private(set) var numberEntry = ""
    private var numberTask: Task<Void, Never>?
    static let numberEntryDelay: Duration = .milliseconds(1600)

    func appendDigit(_ d: Int) {
        guard isLive, !queue.isEmpty, (0...9).contains(d) else { return }
        if numberEntry.count >= String(queue.count).count { numberEntry = "" }          // a fresh number once the digits are used up
        numberEntry += String(d)
        numberTask?.cancel()
        numberTask = Task { [weak self] in
            try? await Task.sleep(for: Self.numberEntryDelay)
            if !Task.isCancelled { self?.commitNumberEntry() }
        }
    }

    func cancelNumberEntry() { numberTask?.cancel(); numberEntry = "" }

    /// Jumps to the typed number. Out of range, or the channel already playing, just clears the entry.
    func commitNumberEntry() {
        numberTask?.cancel()
        defer { numberEntry = "" }
        guard let n = Int(numberEntry), let target = Self.channel(number: n, in: queue), target.id != currentChannel?.id else { return }
        play(channel: target)
    }

    static func channel(number n: Int, in queue: [Channel]) -> Channel? { n >= 1 && n <= queue.count ? queue[n - 1] : nil }

    func channelNumber(of channel: Channel) -> Int? { queue.firstIndex { $0.id == channel.id }.map { $0 + 1 } }

    func toggleChannelSwitcher() { showChannelSwitcher ? closeChannelSwitcher() : openChannelSwitcher() }

    func openChannelSwitcher() {
        guard isLive, !queue.isEmpty else { return }
        let i = currentChannel.flatMap { c in queue.firstIndex { $0.id == c.id } }
        switcher = ChannelSwitcherModel(count: queue.count, current: i)
        showChannelSwitcher = true
    }

    func closeChannelSwitcher() { showChannelSwitcher = false }
    func moveChannelSwitcher(by delta: Int) { if showChannelSwitcher { switcher.move(by: delta) } }
    func highlightChannel(at index: Int) { if showChannelSwitcher, queue.indices.contains(index) { switcher = ChannelSwitcherModel(count: queue.count, current: index) } }

    /// Plays the highlighted channel and closes the switcher. Choosing the channel already playing just closes it.
    func commitChannelSwitcher() {
        guard showChannelSwitcher, queue.indices.contains(switcher.selected) else { closeChannelSwitcher(); return }
        let target = queue[switcher.selected]
        closeChannelSwitcher()
        if target.id != currentChannel?.id { play(channel: target, privately: isPrivate) }
    }

    func nextChannel() { step(+1) }
    func previousChannelInList() { step(-1) }

    /// Jump back to the channel watched before this one.
    func lastChannel() { if let p = previousChannel { play(channel: p, privately: isPrivate) } }

    func playNextEpisode() {
        guard let e = upNext, let s = upNextSeries else { return }
        play(episode: e, series: s, privately: isPrivate)
    }

    private func applyVolume() { engine.setVolume(effectiveVolume * (volumeBoost && engine.capabilities.volumeBoost ? 1.3 : 1)) }

    /// Plays louder than the system volume (up to 130%) on engines that can. Off by default; it can distort loud audio.
    var volumeBoost = false { didSet { applyVolume() } }
    /// The current file's chapters (empty when it has none, or the engine can't list them).
    private(set) var chapters: [PlaybackChapter] = []
    var hasPreviousChannel: Bool { previousChannel != nil }
    /// The series and episode now playing, for an episode list.
    var currentSeries: Series? { currentEpisode?.1 }
    var currentEpisodeID: String? { currentEpisode?.0.id }
    /// Goes back to the channel watched before this one.
    func playPreviousChannel() { lastChannel() }
    #if os(macOS) || STREAMSETU_MPV
    /// Starts or stops feeding the Picture in Picture layer (MPV on iPhone and iPad).
    func setPiPFeed(_ on: Bool) { factory.mpvEngine?.setPiPFeed(on) }
    #endif
    func setLoop(start: Double?, end: Double?) { engine.setLoop(start: start, end: end) }
    func frameStep(forward: Bool) { engine.frameStep(forward: forward); state = .paused }

    /// Louder or quieter for the channel being watched, from −50 to +50 points. Remembered for next time.
    func setChannelVolumeTrim(_ trim: Double) {
        guard let id = currentChannel?.id else { return }
        let clamped = min(ChannelPlaybackPref.trimRange.upperBound, max(ChannelPlaybackPref.trimRange.lowerBound, trim))
        channelVolumeTrim = clamped
        channelPrefs.update(id) { $0.volumeTrim = clamped }
        applyVolume()
    }

    /// The player engine to use for the channel being watched (nil = follow the playlist and the app). Takes effect now.
    func setChannelEnginePreference(_ pref: PlaybackEnginePreference?) {
        guard let id = currentChannel?.id else { return }
        channelEnginePreference = pref
        channelPrefs.update(id) { $0.engine = pref?.rawValue }
        guard let r = current else { return }
        let kind = chooseEngine(for: r, channelPreference: pref)
        if kind != activeEngine { switchEngine(kind) }
    }

    func setRate(_ r: Double) { rate = r; engine.setRate(r); remember() }

    func selectAudio(_ id: String?) { engine.selectAudioTrack(id: id); refreshTracks(); remember() }
    func selectSubtitle(_ id: String?) { engine.selectSubtitleTrack(id: id); refreshTracks(); remember() }
    func applySubtitleStyle() { engine.applySubtitleStyle(settings.subtitleStyle) }

    func setAudioOutput(uid: String?) { factory.avEngine.setAudioOutput(uid: uid.nilIfEmpty) }

    func switchEngine(_ kind: PlaybackEngineKind) {
        guard factory.available.contains(kind), kind != activeEngine, let r = current else { return }
        var req = r
        if !isLive { req.startPosition = position }
        attempt = 0
        start(req, engineOverride: kind)
    }

    func screenshot() -> CGImage? { engine.screenshot() }

    // MARK: video layout (size, aspect ratio, zoom, pan)

    private func loadLayout(for itemID: String) {
        if let own = videoPrefs.layout(for: itemID) { videoLayout = own; hasItemLayoutOverride = true }
        else { videoLayout = videoPrefs.globalLayout(); hasItemLayoutOverride = false }
    }

    func setVideoSizeMode(_ m: VideoSizeMode) { videoLayout.mode = m; if m == .stretch || m == .original { videoLayout.panX = 0; videoLayout.panY = 0 } }
    func setAspectRatio(_ a: AspectRatioOption) { videoLayout.aspect = a }
    func setZoom(_ z: Double) { videoLayout.setZoom(z) }
    func panVideo(by delta: CGSize, container: CGSize) {
        videoLayout = VideoLayoutCalculator.pan(videoLayout, dragging: delta, container: container, source: videoSize)
    }
    func resetVideoLayout() { videoLayout.reset() }

    /// Saves the current layout for this channel / title only.
    func rememberLayoutForThisItem() {
        guard let id = current?.itemID else { return }
        videoPrefs.setLayout(videoLayout, for: id); hasItemLayoutOverride = true
    }

    func removeItemLayoutOverride() {
        guard let id = current?.itemID else { return }
        videoPrefs.clearLayout(for: id); hasItemLayoutOverride = false
        videoLayout = videoPrefs.globalLayout()
    }

    func applyLayoutAsGlobalDefault() { videoPrefs.setGlobalLayout(videoLayout) }

    // MARK: quality, audio and subtitle timing (engine capabilities decide what is available)

    func selectQuality(_ id: String?) { engine.selectQuality(id: id); selectedQualityID = engine.selectedQualityID }
    func setAudioDelay(_ s: Double) { audioDelay = max(-5, min(5, s)); engine.setAudioDelay(audioDelay); remember() }
    func setSubtitleDelay(_ s: Double) { subtitleDelay = max(-10, min(10, s)); engine.setSubtitleDelay(subtitleDelay); remember() }
    /// Colour controls for this session and, saved, for every stream from now on.
    var picture: PictureAdjustments { settings.picture }
    func setPicture(_ p: PictureAdjustments) { settings.picture = p.clamped(); engine.setPicture(settings.picture) }

    /// Loads a subtitle file the person chose. Only engines that support it take it.
    @discardableResult
    func loadSubtitleFile(_ url: URL) -> Bool {
        guard capabilities.externalSubtitles else { return false }
        let ok = engine.addSubtitleFile(url)
        if ok { Task { try? await Task.sleep(nanoseconds: 300_000_000); self.refreshTracks() } }
        return ok
    }

    func setAudioProcessing(_ m: AudioProcessingMode) { audioProcessing = m; engine.setAudioProcessing(m) }

    // MARK: starting

    private func reset(for kind: ContentKind) {
        fallbackCopies = []
        startOverOffer = nil
        stopRecording()
        saveProgress(force: true)
        endSession(outcome: "switched", error: nil)
        attempt = 0
        recordedPlay = false
        appliedPreferredTracks = false
        statusMessage = nil
        if kind != .channel { currentChannel = nil; channelVolumeTrim = 0; channelEnginePreference = nil; applyVolume() }
        if kind != .movie { currentMovie = nil }
        if kind != .episode { currentEpisode = nil; upNext = nil; upNextSeries = nil }
        audioTracks = []; subtitleTracks = []
        position = 0; duration = nil
        isPrivate = false          // whatever starts next is an ordinary play unless it asks to be private (after the previous one's progress was handled above)
    }

    private func begin(_ resolve: @escaping () throws -> PlaybackRequest) {
        if let b = viewingGuard?.block() { viewingBlock = b; stop(); return }
        tapAt = Date()
        state = .resolving
        switchedEngine = false
        do {
            let request = try resolve()
            current = request
            memoryEntry = itemMemory.entry(for: request.itemID)
            loadLayout(for: request.itemID)
            start(request)
            onSessionChange?()
        } catch {
            let e = PlaybackError.classify(error)
            current = nil
            state = .failed(e)
            statusMessage = (error as? LocalizedError)?.errorDescription ?? e.message
            diagnostics.record("resolve failed: \(error.localizedDescription)")
        }
    }

    /// Portal streams (Stalker, Ministra) carry a stand-in address; the portal is asked for the real one first, then playback starts as usual.
    private func startAfterResolvingLink(_ request: PlaybackRequest, engineOverride: PlaybackEngineKind?) {
        generation += 1
        let gen = generation
        startTask?.cancel(); recoveryTask?.cancel()
        current = request
        state = .resolving
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                var real = request
                real.url = try await self.resolver.finalURL(for: request.url, sourceID: request.sourceID)
                guard gen == self.generation else { return }
                self.start(real, engineOverride: engineOverride)
                self.current = request          // keeps the stand-in, so a retry asks the portal for a fresh link
            } catch {
                guard gen == self.generation else { return }
                self.handleFailure(PlaybackError.classify(error))
            }
        }
    }

    /// The one place that decides which player a stream goes to (the most specific choice wins: channel, then playlist, then the app setting).
    private func chooseEngine(for request: PlaybackRequest, channelPreference: PlaybackEnginePreference?) -> PlaybackEngineKind {
        let viewing: AppSettings.ViewingKind = request.isCatchup ? .catchup : request.isLive ? .live : .movies
        return EngineSelector.select(container: StreamCapabilities.container(for: request.url, isLive: request.isLive), preference: settings.engineChoice(for: viewing) ?? settings.enginePreference,
                              playlistPreference: settings.engineOverride(for: request.sourceID), channelPreference: channelPreference, available: factory.available)
    }

    private func start(_ request: PlaybackRequest, engineOverride: PlaybackEngineKind? = nil) {
        if request.url.scheme == PortalLink.scheme { startAfterResolvingLink(request, engineOverride: engineOverride); return }
        if !network.isOnline, !request.url.isFileURL { current = request; waitForNetwork(); return }          // a file on this device needs no connection
        generation += 1
        let gen = generation
        startTask?.cancel(); recoveryTask?.cancel()
        current = request
        let container = StreamCapabilities.container(for: request.url, isLive: request.isLive)
        let kind = engineOverride ?? chooseEngine(for: request, channelPreference: request.isLive ? channelEnginePreference : nil)
        Trace.log("start \(request.kind.rawValue) live=\(request.isLive) \(Trace.describe(request.url)) container=\(container) engine=\(kind.rawValue) (was \(activeEngine.rawValue)) attempt=\(attempt) preference=\(settings.enginePreference)")
        if kind != activeEngine { switchTo(kind) }
        let buffering = settings.bufferingOverride(for: request.sourceID) ?? settings.bufferingMode
        engine.bufferingMode = buffering
        engine.qualityPreference = settings.videoQuality
        #if os(macOS) || STREAMSETU_MPV
        if let mpv = engine as? MPVPlayerEngine {
            mpv.configuration.hardwareDecoding = settings.hardwareDecoding
            mpv.configuration.deinterlace = settings.deinterlace.isOn(live: request.isLive)
            mpv.configuration.hlsBitrate = settings.videoQuality.mpvHLSBitrate
            mpv.configuration.cacheSeconds = buffering.mpvCacheSeconds
            mpv.configuration.resumeThreshold = buffering.mpvResumeThreshold(live: request.isLive)
            mpv.configuration.lowLatency = buffering == .lowLatency
            mpv.configuration.renderingProfile = settings.renderingProfile
            mpv.configuration.stereoDownmix = settings.stereoDownmix
            mpv.configuration.toneMapping = settings.toneMapping
            mpv.configuration.liveRewind = settings.liveRewind
            mpv.configuration.httpProxy = settings.proxy.mpvValue
        }
        #endif
        engine.setMuted(isMuted); engine.setVolume(effectiveVolume); engine.setRate(rate)
        state = .resolving
        watchStart(request, generation: gen)
        // Opening a live stream right after closing another on the same provider can be refused (one-connection plans), so the wait is
        // learned per provider. Quick channel flicking never connects to the channels it passes over: their start is cancelled while waiting.
        let previousLive = openLiveSource
        if let previous = previousLive { pacer.closed(previous) }
        // A movie opened straight after a channel of the same provider meets the same one-connection limit, so it waits the same short while.
        let wait = request.isLive || previousLive == request.sourceID ? pacer.delay(for: request.sourceID) : 0
        openLiveSource = request.isLive ? request.sourceID : nil
        if wait > 0 { Trace.log("pacing: waiting \(String(format: "%.1f", wait)) s before connecting") }
        startTask = Task { [weak self] in
            guard let self else { return }
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)); guard !Task.isCancelled, gen == self.generation else { return } }
            do { try await self.engine.load(request) }
            catch {
                guard gen == self.generation else { return }
                self.handleFailure(PlaybackError.classify(error, httpStatus: self.engine.lastHTTPStatus))
            }
        }
    }

    /// If nothing has played 20 seconds after a start, finds out why (a blocked or missing server name, or a server nothing can connect to)
    /// and says so, instead of leaving the spinner turning. It never touches the stream, and does nothing for a stream that is just slow.
    private func watchStart(_ request: PlaybackRequest, generation gen: Int) {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, !Task.isCancelled, gen == self.generation, !self.recordedPlay, self.state != .playing, self.state != .paused else { return }
            let verdict = await StartDiagnosis.diagnose(request.url)
            guard !Task.isCancelled, gen == self.generation, self.state != .playing else { return }
            guard let error = verdict else { return }       // reachable and resolving: leave the stream alone, however slow
            self.diagnostics.record("start watchdog: \(error.kind.rawValue) \(error.detail ?? "")")
            self.handleFailure(error)
        }
    }

    private func switchTo(_ kind: PlaybackEngineKind) {
        engine.stop()
        engine = factory.engine(kind)
        activeEngine = kind
        observe(engine)
    }

    // MARK: engine events

    private func observe(_ e: any PlaybackEngine) {
        guard stateTasks[e.kind] == nil else { return }
        let kind = e.kind
        let stream = e.stateUpdates
        stateTasks[kind] = Task { [weak self] in
            for await s in stream { self?.engineChanged(s, from: kind) }
        }
    }

    private func engineChanged(_ s: PlaybackState, from kind: PlaybackEngineKind) {
        guard kind == activeEngine else { return }
        Trace.log("state \(kind.rawValue): \(s)")
        state = s
        switch s {
        case .playing:
            statusMessage = nil; waitingForNetwork = false
            if let id = current?.itemID { refusedAt[id] = nil }
            if !recordedPlay, let src = current?.sourceID, current?.isLive == true { pacer.recordSuccess(src) }
            if !recordedPlay {
                recordedPlay = true; onFirstPlay(); fetchSubtitleIfWanted()
                if !isPrivate, announced == nil, let item = traktItem() { announced = item; onWatchEvent?(.started(item)) }
                if let r = current { StartStats.shared.recordStart(source: r.sourceID, engine: activeEngine, live: r.isLive, seconds: Date().timeIntervalSince(tapAt)) }
                // Audio and subtitle tracks can arrive a little after the picture starts: look again a few times.
                let gen = generation
                Task { [weak self] in
                    for wait in [1.0, 2.5, 5.0] {
                        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                        guard let self, gen == self.generation else { return }
                        self.refreshTracks()
                    }
                }
            }
            startTicker()
            markStableAfterDelay()
            refreshTracks()
        case .paused:
            saveProgress(force: true)
        case .ended:
            onEnded()
        case .failed(let e):
            handleFailure(e)
        default: break
        }
    }

    /// Asked to find a subtitle file for the title playing (its name, the series' name, the language); set by the app, which holds the OpenSubtitles account.
    var subtitleFetcher: (@Sendable (_ title: String, _ year: Int?, _ language: String, _ season: Int?, _ episode: Int?) async -> URL?)?
    private var autoSubtitleItem: String?

    /// A few seconds in, a film or episode with no subtitles in the chosen language gets the most downloaded one from OpenSubtitles, when the person turned that on.
    private func fetchSubtitleIfWanted() {
        guard !isPrivate, settings.autoSubtitles, let r = current, !r.isLive, r.kind != .channel, autoSubtitleItem != r.itemID, capabilities.externalSubtitles, let fetch = subtitleFetcher else { return }
        autoSubtitleItem = r.itemID
        let gen = generation
        let language = settings.subtitleLanguages.first ?? "en"
        let title = currentSeries?.title ?? currentMovie?.title ?? r.title
        let year = currentMovie?.releaseYear
        // An episode is asked for by its season and number: a subtitle for the wrong episode is worse than none.
        let season = currentEpisode?.0.seasonNumber, episode = currentEpisode?.0.episodeNumber
        if r.kind == .episode, season == nil || episode == nil { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, gen == self.generation else { return }
            refreshTracks()
            if memoryEntry?.subtitleLanguage == "off" { return }                                                                           // the person turned them off for this title
            if self.subtitleTracks.contains(where: { AudioTrackManager.matches($0.language, language) }) { return }                       // there already are some
            guard let url = await fetch(title, year, language, season, episode), gen == self.generation else { return }
            self.loadSubtitleFile(url)
        }
    }

    private func onFirstPlay() {
        guard let r = current else { return }
        if !isPrivate {
            try? historyRepo.recordPlay(itemID: r.itemID, kind: r.kind, title: r.title)
            sessionID = try? historyRepo.beginSession(itemID: r.itemID, engine: activeEngine.rawValue)
        }
        applySubtitleStyle()
        engine.setPicture(picture)
        engine.setAudioDelay(audioDelay); engine.setSubtitleDelay(subtitleDelay); engine.setAudioProcessing(audioProcessing)
        if !settings.audioOutputUID.isEmpty { setAudioOutput(uid: settings.audioOutputUID) }
    }

    private func markStableAfterDelay() {
        stableTask?.cancel()
        stableTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { self?.attempt = 0 }       // a stream that played for 5s earns a fresh retry budget
        }
    }

    /// Items for which the secure name lookup was already tried in this run, so it is tried once.
    private var secureDNSTried = Set<String>()

    private func handleFailure(_ error: PlaybackError) {
        guard let r = current else { state = .failed(error); return }
        if NetworkRecovery.waitsForConnection(kind: error.kind, online: network.isOnline) { waitForNetwork(); return }
        // Provider retries (a busy or erroring server) must not use up the one allowed switch to the other player, so that decision is counted apart.
        let isFormat = error.kind == .unsupportedFormat || error.kind == .engineUnavailable
        let decisionAttempt = isFormat ? (switchedEngine ? max(attempt, 1) : 0) : attempt
        // This network cannot find the server's name: ask a public encrypted resolver once and connect by address with the MPV player.
        if error.kind == .nameLookup, !secureDNSTried.contains(r.itemID), factory.available.contains(.mpv), let host = r.url.host, !SecureDNS.isIPAddress(host), r.url.scheme == "http" {
            secureDNSTried.insert(r.itemID)
            state = .recovering
            statusMessage = "Looking for the server another way…"
            diagnostics.record("secure DNS lookup for the server name")
            recoveryTask?.cancel()
            recoveryTask = Task { [weak self] in
                let ip = await SecureDNS.resolve(host)
                guard let self, !Task.isCancelled else { return }
                if let ip, let rewritten = SecureDNS.rewrite(r.url, to: ip) {
                    Trace.log("secure DNS found an address for the server; connecting directly")
                    var req = r
                    req.url = rewritten.url
                    req.headers["Host"] = rewritten.hostHeader
                    if !r.isLive { req.startPosition = max(self.position, r.startPosition) }
                    self.start(req, engineOverride: .mpv)
                } else {
                    Trace.log("secure DNS found nothing")
                    self.state = .failed(error); self.statusMessage = error.message
                    self.endSession(outcome: "failed", error: error.detail ?? error.kind.rawValue)
                }
            }
            return
        }
        let recentlyRefused = !r.isLive && (refusedAt[r.itemID].map { Date().timeIntervalSince($0) < 600 } ?? false)
        let action = recovery.decide(error: error, attempt: decisionAttempt, current: activeEngine, available: factory.available, isLive: r.isLive, recentlyRefused: recentlyRefused)
        if error.kind == .providerBusy, !r.isLive, action == .giveUp { refusedAt[r.itemID] = Date() }
        if error.kind == .providerBusy { pacer.recordBusy(r.sourceID) }
        Trace.log("failure \(error.kind.rawValue) detail=\(error.detail ?? "-") attempt=\(attempt) action=\(action)")
        diagnostics.record("playback \(error.kind.rawValue) attempt \(attempt): \(error.detail ?? "")")
        switch action {
        case .retry(let delay, _):
            attempt += 1
            statusMessage = error.kind == .providerBusy ? "The provider is still closing your last stream. Trying again… (\(attempt)/\(PlaybackRecoveryService.busyWaits(isLive: r.isLive, recentlyRefused: recentlyRefused).count))" : "Reconnecting… (\(attempt)/\(recovery.maxRetries))"
            state = .recovering
            recoveryTask?.cancel()
            recoveryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.reResolveAndStart()
            }
        case .switchEngine(let kind):
            attempt += 1
            switchedEngine = true
            // A channel Apple's player cannot read stays that way: remember the other player for it, so the next visit starts there at once.
            if r.isLive, error.kind == .unsupportedFormat, let id = currentChannel?.id {
                let pref: PlaybackEnginePreference = kind == .mpv ? .mpv : .avPlayer
                channelEnginePreference = pref
                channelPrefs.update(id) { $0.engine = pref.rawValue }
            }
            statusMessage = "Trying \(kind.rawValue)…"
            var req = r
            if !r.isLive { req.startPosition = position }
            start(req, engineOverride: kind)
        case .giveUp where r.isLive && !r.isCatchup && fallBackToAnotherVariant(after: error):
            break
        case .giveUp:
            saveProgress(force: true)
            if !r.isLive, let next = fallbackCopies.first, currentMovie != nil {
                statusMessage = "That copy did not play. Trying another."
                play(movie: next, resume: nil, bestCopy: false, remaining: Array(fallbackCopies.dropFirst()), privately: isPrivate)
                return
            }
            let container = StreamCapabilities.container(for: r.url, isLive: r.isLive)
            if error.kind == .unsupportedFormat, !factory.available.contains(.mpv), [.mkv, .rtsp, .dash].contains(container) || r.url.pathExtension.lowercased() == "avi" {
                statusMessage = "This \(r.url.pathExtension.uppercased().isEmpty ? container.rawValue.uppercased() : r.url.pathExtension.uppercased()) video needs the MPV player engine, which isn't included in this build."
            } else { statusMessage = error.message }
            state = .failed(error)
            endSession(outcome: "failed", error: error.detail ?? error.kind.rawValue)
            StartStats.shared.recordFailure(source: r.sourceID, engine: activeEngine, live: r.isLive)
            // Sent only if sharing is on (it is by default, and the person is told on first launch); throttled; low priority; after the stream has already failed.
            DiagnosticsUploader.shared.playbackFailed()
        }
    }

    /// When a live channel has failed for good, tries another quality copy of it (HD, FHD, 4K…) once each. Returns true if one was started.
    private func fallBackToAnotherVariant(after error: PlaybackError) -> Bool {
        guard let c = currentChannel else { return false }
        let all = (try? catalog.variants(ofChannel: c.id)) ?? []
        if all.count > 1, let next = VariantFallback.next(variants: all, tried: triedVariants, errorKind: error.kind) {
            triedVariants.insert(next.variant.id)
            diagnostics.record("variant fallback to \(next.label) after \(error.kind.rawValue)")
            statusMessage = "That stream isn't working. Trying \(next.label)…"
            play(channel: next.variant, isFallback: true, privately: isPrivate)
            return true
        }
        // Every copy in this playlist has failed: the same channel in another playlist of yours is the last resort. (A login or engine problem, or a busy provider, would not be helped by it.)
        guard VariantFallback.next(variants: [(variant: c, label: "")], tried: [], errorKind: error.kind) != nil else { return false }
        let others = (try? catalog.channelCopiesInOtherPlaylists(of: c)) ?? []
        guard let other = others.first(where: { !triedVariants.contains($0.id) }) else { return false }
        triedVariants.insert(other.id)
        let name = ((try? catalog.source(id: other.sourceID)) ?? nil)?.name ?? "another playlist"
        diagnostics.record("playlist fallback to \(name) after \(error.kind.rawValue)")
        statusMessage = "That stream isn't working. Trying it on \(name)…"
        play(channel: other, isFallback: true, privately: isPrivate)
        return true
    }

    /// Provider URLs may carry short-lived tokens, so a retry resolves the stream again.
    private func reResolveAndStart() {
        var fresh: PlaybackRequest?
        if let c = currentChannel { fresh = try? resolver.resolve(channel: c) }
        else if let m = currentMovie { fresh = try? resolver.resolve(movie: m, resume: false) }
        else if let (e, s) = currentEpisode { fresh = try? resolver.resolve(episode: e, series: s, resume: false) }
        guard var req = fresh ?? current else { return }
        if !req.isLive, position > 5 { req.startPosition = position }
        start(req)
    }

    private func onEnded() {
        guard let r = current, !r.isCatchup else { return }
        if !isPrivate { try? historyRepo.markWatched(itemID: r.itemID, kind: r.kind, seriesID: r.seriesID, duration: duration ?? position) }
        endSession(outcome: "ended", error: nil)
        if !r.isLive, queueAdvance?() == true { return }          // a title the person lined up comes before the next episode
        if r.kind == .episode, settings.autoPlayNextEpisode, upNext != nil { playNextEpisode() }
    }

    // MARK: recording a live channel

    /// What is being recorded now: the file and when it began. Nil when nothing is.
    private(set) var recording: (file: URL, since: Date)?

    /// True when the player in use can write the stream to a file (MPV).
    var canRecord: Bool { isLive && engine.kind == .mpv && !(current?.isCatchup ?? false) }

    /// Starts writing the channel being watched to a file. After a few seconds the file is checked: if nothing arrived the recording is dropped and the person told.
    func startRecording(toast: @escaping @MainActor (String) -> Void) {
        guard canRecord, recording == nil, let channel = currentChannel else { return }
        let started = Date()
        let file = Recordings.folder.appendingPathComponent(Recordings.fileName(channel: channel.name, at: started))
        guard engine.setRecording(to: file) else { toast("This channel can't be recorded with this player."); return }
        recording = (file, started)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard let self, let r = self.recording, r.file == file else { return }
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
            if (size ?? 0) == 0 {
                self.stopRecording()
                try? FileManager.default.removeItem(at: file)
                toast("Nothing was recorded: this channel can't be written to a file.")
            }
        }
    }

    func stopRecording() {
        guard recording != nil else { return }
        _ = engine.setRecording(to: nil)
        recording = nil
    }

    /// Plays the title at the front of the person's queue and returns true; false when the queue is empty. Set by the app, which knows how to start a series.
    var queueAdvance: (() -> Bool)?

    // MARK: ticking, progress, tracks

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            var n = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                self.position = self.engine.position
                self.duration = self.engine.duration
                n += 1
                if n % 2 == 0 {
                    self.enforceViewingLimit()
                    if self.startOverOffer != nil, let t = self.startOverShownAt, Date().timeIntervalSince(t) > StartOver.showFor { self.startOverOffer = nil }
                    self.metrics = self.engine.metrics
                    if self.state == .playing { if self.playingSince == nil { self.playingSince = Date() } } else { self.playingSince = nil }
                    let audioOnly = Self.audioOnly(state: self.state, videoWidth: self.metrics.width, secondsPlaying: self.playingSince.map { Date().timeIntervalSince($0) } ?? 0,
                                                   looksLikeRadio: self.looksLikeRadio, isLive: self.isLive)
                    if audioOnly != self.isAudioOnly { self.isAudioOnly = audioOnly }
                }
                self.behindLive = self.liveRewindAvailable ? max(0, (self.engine.liveBufferEnd ?? self.position) - self.position) : 0
                if self.state == .playing, Date().timeIntervalSince(self.lastSavedAt) > 10 { self.saveProgress(force: false) }
                if let d = self.duration, self.current?.kind == .episode, self.settings.autoPlayNextEpisode,
                   self.state == .playing, d - self.position < 1.0, self.upNext != nil { self.onEnded() }
            }
        }
    }

    /// Once a second while something plays in a profile with limits: counts the time, warns when little is left, and stops at the limit.
    private func enforceViewingLimit() {
        guard let g = viewingGuard, state == .playing else { return }
        g.add(1)
        if let b = g.block() { viewingBlock = b; warnedMinutes = []; stop(); return }
        if let left = g.remaining() {
            for m in [5, 1] where left <= Double(m) * 60 && !warnedMinutes.contains(m) {
                warnedMinutes.insert(m)
                statusMessage = m == 1 ? "1 minute left for today" : "5 minutes left for today"
            }
        }
    }

    /// Writes the resume position now (used when the app is about to leave the screen).
    func persistProgress() { saveProgress(force: true) }

    private func saveProgress(force: Bool) {
        guard !isPrivate, settings.rememberPosition, let r = current, !r.isLive, !r.isCatchup else { return }
        // Read the engine itself, not only the copy the ticker refreshes twice a second, so a save made as playback stops or switches is current.
        let pos = max(position, engine.position)
        guard let d = duration ?? engine.duration, d > 0, pos > 1 else {
            if force { Trace.log("progress not saved: position \(Int(pos)) s, length \(duration.map { String(Int($0)) } ?? "unknown")") }
            return
        }
        lastSavedAt = Date()
        try? historyRepo.saveProgress(WatchProgress(itemID: r.itemID, kind: r.kind, seriesID: r.seriesID, positionSeconds: pos,
                                                   durationSeconds: d, updatedAt: Date(), completed: false))
        Trace.log("progress saved: \(Int(pos)) s of \(Int(d)) s\(force ? " (on leaving)" : "")")
    }

    private func refreshTracks() {
        qualityOptions = engine.qualityOptions(); selectedQualityID = engine.selectedQualityID
        chapters = engine.chapters()
        audioTracks = engine.availableAudioTracks()
        subtitleTracks = engine.availableSubtitleTracks()
        guard !appliedPreferredTracks, !audioTracks.isEmpty || !subtitleTracks.isEmpty else { return }
        appliedPreferredTracks = true
        // What was chosen for this title last time beats the general language settings.
        if let m = memoryEntry {
            if let l = m.audioLanguage, let t = audioTracks.first(where: { AudioTrackManager.matches($0.language, l) }) { engine.selectAudioTrack(id: t.id) }
            if m.subtitleLanguage == "off" { engine.selectSubtitleTrack(id: nil) }
            else if let l = m.subtitleLanguage, let t = subtitleTracks.first(where: { AudioTrackManager.matches($0.language, l) }) { engine.selectSubtitleTrack(id: t.id) }
            if m.rate != 1 { rate = m.rate; engine.setRate(m.rate) }
            if m.audioDelay != 0 { audioDelay = m.audioDelay; engine.setAudioDelay(m.audioDelay) }
            if m.subtitleDelay != 0 { subtitleDelay = m.subtitleDelay; engine.setSubtitleDelay(m.subtitleDelay) }
            audioTracks = engine.availableAudioTracks(); subtitleTracks = engine.availableSubtitleTracks()
            return
        }
        if let i = AudioTrackManager.preferredIndex(in: audioTracks, languages: settings.audioLanguages) { engine.selectAudioTrack(id: audioTracks[i].id) }
        if settings.subtitlesByDefault, let i = SubtitleManager.preferredIndex(in: subtitleTracks, languages: settings.subtitleLanguages) {
            engine.selectSubtitleTrack(id: subtitleTracks[i].id)
        }
        audioTracks = engine.availableAudioTracks(); subtitleTracks = engine.availableSubtitleTracks()
    }

    // MARK: remembered choices, skip intro, go to time

    /// Whether audio, subtitles, speed and timing come back the next time the same title plays.
    var remembersPerTitle: Bool { get { itemMemory.enabled } set { itemMemory.enabled = newValue } }

    private func remember() {
        guard !isPrivate, let id = current?.itemID else { return }          // a private play leaves no remembered choices
        let e = ItemMemory.Entry(audioLanguage: audioTracks.first(where: \.isSelected)?.language, subtitleLanguage: subtitleTracks.first(where: \.isSelected).map { $0.language ?? "" } ?? "off",
                                 rate: rate, audioDelay: audioDelay, subtitleDelay: subtitleDelay)
        memoryEntry = e
        itemMemory.save(e, for: id)
    }

    /// Where the opening of this episode ends, while it is still on screen; nil for anything else.
    var introEnd: TimeInterval? {
        guard !isLive, let series = currentEpisode?.1 else { return nil }
        return introSkip.target(seriesID: series.id, position: position)
    }

    func skipIntro() { if let end = introEnd { seek(to: end) } }

    /// Where the recap at the start of this episode ends, while it is on screen; nil for anything else.
    var recapEnd: TimeInterval? {
        guard !isLive, currentEpisode != nil else { return nil }
        return episodeMarks.recapEnd(chapters: chapters, position: position, duration: duration)
    }

    func skipRecap() { if let end = recapEnd { seek(to: end) } }

    /// True once the credits of this episode have started and there is still something to skip.
    var creditsShowing: Bool {
        guard !isLive, let series = currentEpisode?.1, let d = duration, let start = episodeMarks.creditsStart(seriesID: series.id, chapters: chapters, duration: d) else { return false }
        return position >= start && d - position > 3
    }

    /// Skipping the credits plays the next episode when there is one, and otherwise goes to the end.
    func skipCredits() {
        guard let series = currentEpisode?.1, let d = duration else { return }
        if episodeMarks.isCreditsSkip(from: position, to: d, duration: d) { episodeMarks.learn(seriesID: series.id, from: position, duration: d) }
        if queueAdvance?() == true { return }
        if upNext != nil { playNextEpisode() } else { seek(to: d) }
    }

    /// Jumps to a point in a movie or episode.
    func goTo(_ seconds: TimeInterval) { seek(to: seconds) }

    /// "1:23:45", "83:45" or "45" (seconds) as seconds; nil when it is not a time.
    nonisolated static func parseTime(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }

    private func step(_ delta: Int) {
        guard !queue.isEmpty else { return }
        let i = currentChannel.flatMap { c in queue.firstIndex { $0.id == c.id } } ?? (delta > 0 ? -1 : 0)
        let next = queue[((i + delta) % queue.count + queue.count) % queue.count]
        play(channel: next, privately: isPrivate)
    }

    private func endSession(outcome: String, error: String?) {
        defer { onSessionChange?() }
        if let item = announced {
            announced = nil
            let done = outcome == "ended" ? 100 : ((duration ?? 0) > 0 ? min(100, position / (duration ?? 1) * 100) : 0)
            onWatchEvent?(.stopped(item, progress: done))
        }
        if let id = sessionID { try? historyRepo.endSession(id: id, outcome: outcome, error: error); sessionID = nil }
    }

    private func cancelWork() {
        startTask?.cancel(); recoveryTask?.cancel(); stableTask?.cancel(); watchdogTask?.cancel(); ticker?.cancel(); ticker = nil
        generation += 1
    }

    /// For diagnostics export.
    var diagnosticsSummary: String { "state=\(state) · \(metrics.summary) · engines=\(factory.available.map(\.rawValue).sorted())" }
}
