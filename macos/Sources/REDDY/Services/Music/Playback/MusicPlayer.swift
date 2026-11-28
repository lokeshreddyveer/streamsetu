import Foundation
import AVFoundation
import MediaPlayer
import Observation
#if os(macOS)
import AppKit
#endif

/// Why the playing track changed. Notifications use it: a track the person picked from a focused window never notifies.
enum MusicTrackChange: Sendable { case picked, gapless, restored }

/// The music player: its own AVQueuePlayer, its own queue, and no timers while paused.
///
/// - The next track is resolved right after the current one starts and queued behind it, so the change is gapless where the stream
///   allows it. With crossfade on, the next track is held on a second player instead.
/// - Pitch and reverb need Apple's audio engine; while either is on the track plays through `MusicEffectsEngine`. Tempo alone stays on AVPlayer.
/// - Audio ownership: `onClaimAudio` is called before any sound starts; `pauseForOtherAudio()` is how the shell silences it.
/// - Media keys and Now Playing go through the shared command router: this class only answers `RemoteCommandHandling` and hands finished
///   Now Playing dictionaries to `publishNowPlaying`. It never registers system command targets itself.
@MainActor @Observable
final class MusicPlayer: RemoteCommandHandling {
    // MARK: observable state
    private(set) var queue: [MusicTrack] = []
    /// The queue rows with their markers (Play next, Add to queue, autoplay), for the queue panel.
    private(set) var rows: [MusicQueue.Entry] = []
    private(set) var index: Int?
    private(set) var current: MusicTrack?
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    /// What the sound is really doing. Lyrics (and every clock that must follow the audio) run only in `.playing`: the player's own position
    /// is moving, it is not loading and not buffering. "Play was pressed" is not sound.
    private(set) var audioState: MusicAudibleClock.State = .idle
    var audioAdvancing: Bool { audioState == .playing }
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    /// How many songs have played to their end (natural end, custom end or a trimmed length). The sleep timer reads it: under repeat-one the same song starts again,
    /// so neither the song's id nor a once-a-second look at the position can tell that it ended.
    private(set) var finishedPlays = 0
    private(set) var error: String?
    /// A short message that goes away by itself ("Playing next", "Skipped (unavailable): ...").
    private(set) var notice: String?
    /// Songs that could not be started this session; their rows stay in the queue, marked, until they play.
    private(set) var failedUIDs: Set<String> = []
    /// The queue row after which playback stops ("Stop after this song" on the playing row, "Stop after this one" on a later row). It is the row's own id, not the
    /// recording's, so a second copy of the same recording in the queue does not stop playback too.
    private(set) var stopAfterEntryID: UUID?
    /// The plain reason each marked row could not be played, and when the mark stops counting (the unplayable memory's own lifetime).
    private var failureMarks = MusicFailureMarks()
    /// The reason to show on a marked row, or nil once the mark has expired.
    func failureReason(for uid: String) -> String? { failureMarks.reason(for: uid) }
    private func markFailed(_ uid: String, reason: String) {
        onTrackFailed?(uid)
        failureMarks.mark(uid, reason: reason)
        failedUIDs = failureMarks.uids
    }
    /// A mark ends with its verdict: when the song plays, when the person presses play on it, or when its time runs out.
    private func clearFailureMark(_ uid: String) {
        guard failedUIDs.contains(uid) else { return }
        failureMarks.clear(uid)
        failedUIDs = failureMarks.uids
    }
    private func pruneFailureMarks() {
        failureMarks.prune()
        if failedUIDs != failureMarks.uids { failedUIDs = failureMarks.uids }
    }
    private(set) var currentStream: MusicStream?
    /// "Back to <title>" while the replaced queue can be restored.
    private(set) var backTitle: String?
    /// The "Playing from" label.
    private(set) var sourceName: String?
    private(set) var isRadioQueue = false
    private(set) var hasManualRows = false
    /// Tempo, pitch and reverb. Global to the player, shared by every track, and gone at the next launch.
    private(set) var effects = MusicEffectSettings.original
    /// Set when the audio effects could not start and playback fell back to plain.
    private(set) var effectsNotice: String?
    let effectPresets: MusicEffectPresetStore

    var repeatMode: MusicRepeat = .off {
        didSet {
            guard repeatMode != oldValue, !syncingRepeat else { return }
            // A listening-room guest follows the host's queue: the repeat mode is not theirs to change (the same rule as `shuffle`).
            if isRoomGuest { syncingRepeat = true; repeatMode = oldValue; syncingRepeat = false; return }
            q.repeatMode = repeatMode
            if shuffle, repeatMode != .off { installLapShuffler() }
            queueChanged(); saveSoon(); notifySupport()
            if repeatMode == .off { topUpAutoplay() }
        }
    }
    var shuffle = false {
        didSet {
            guard shuffle != oldValue, !syncingShuffle else { return }
            // A listening-room guest follows the host's queue: reordering the mirrored rows locally is not allowed.
            if isRoomGuest { syncingShuffle = true; shuffle = oldValue; syncingShuffle = false; return }
            // The person has spoken: whatever a radio start had put aside no longer counts.
            stickyShuffleWanted = false
            suggestGate.reset()
            // The engine closure (signals, energy cache) is built only when turning shuffle on.
            q.setShuffle(shuffle, wholeQueue: prefs.shuffleWholeQueue, shuffler: shuffle ? shuffleEngineShuffler() : MusicQueue.systemShuffle)
            // Toggling shuffle always drops the lookahead and primes again.
            dropPreload(); sync(); queueChanged(); notifySupport()
            if !shuffle { q.lapShuffler = nil; topUpAutoplay(force: true) }
            else if shuffleMode == .smartSuggest { topUpSuggestions() }
        }
    }

    /// How shuffle orders the queue. Remembered between launches (`MusicShuffleModeStore`).
    var shuffleMode: MusicShuffleMode = MusicShuffleModeStore.load() {
        didSet {
            guard shuffleMode != oldValue else { return }
            MusicShuffleModeStore.save(shuffleMode)
            suggestGate.reset()
            guard shuffle else { return }
            if shuffleMode == .smartSuggest { reshuffle() }
            else { q.removeSuggestedRows(); reshuffle() }
        }
    }

    /// Reads Automix's analysis (read only) for the shuffle's smoothness score. Set by the hub; nil means no energy data.
    @ObservationIgnored var shuffleEnergy: (@Sendable (MusicTrack) -> Double?)?

    /// "Reshuffle": a new smart order for everything still to come. Played rows, the playing row and Play next stay where they are.
    func reshuffle() {
        guard shuffle, !isRoomGuest else { return }
        suggestGate.reset()
        q.reshuffleUpcoming(wholeQueue: prefs.shuffleWholeQueue, shuffler: shuffleEngineShuffler())
        dropPreload(); sync(); queueChanged(); notifySupport()
        if shuffleMode == .smartSuggest { topUpSuggestions() }
    }

    /// What the engine knows about the person's songs (play recency, likes, play counts). One place builds it for every shuffle.
    private func shuffleSignals() -> MusicShuffleSignals {
        var sig = MusicShuffleSignals()
        let visibleHistory = MusicTasteReset.visible(library.history)
        for r in visibleHistory where (sig.lastPlayed[r.track.uid] ?? .distantPast) < r.at { sig.lastPlayed[r.track.uid] = r.at }
        sig.favourites = Set(library.liked.map(\.uid))
        var plays: [String: Int] = [:]
        for r in visibleHistory { plays[r.track.uid, default: 0] += 1 }
        let top = Double(max(1, plays.values.max() ?? 1))
        for (k, v) in plays { sig.affinity[k] = Double(v) / top }
        return sig
    }

    private func shuffleEngineShuffler() -> MusicQueue.Shuffler {
        var sig = pendingShuffleSignals ?? shuffleSignals()
        pendingShuffleSignals = nil
        addEnergy(to: &sig)
        // The rows as they stand now are the order just heard (or the list's own order on a first shuffle): neighbours from it are penalised.
        sig.previousOrder = q.entries.map(\.track.uid)
        let seed = UInt64.random(in: .min ... .max)
        let mode: MusicShuffleMode = shuffleMode == .random ? .random : .smart
        // Repeat-all: each lap gets a fresh smart order that does not open with the end of the last one.
        q.lapShuffler = MusicShuffleEngine.lapShuffler(mode: mode, signals: sig, seed: seed &+ 1)
        // The playing song leads: the first songs after it avoid its artist and album when possible.
        return MusicShuffleEngine.shuffler(mode: mode, signals: sig, seed: seed, lead: q.current?.track)
    }

    private func addEnergy(to sig: inout MusicShuffleSignals) {
        guard let e = shuffleEnergy else { return }
        for row in q.entries { if let v = e(row.track) { sig.energy[row.track.uid] = v } }
    }

    /// Builds only the repeat-all lap shuffler (after a restart, a restored queue or a repeat change), without reordering anything.
    private func installLapShuffler() {
        var sig = shuffleSignals()
        addEnergy(to: &sig)
        let mode: MusicShuffleMode = shuffleMode == .random ? .random : .smart
        q.lapShuffler = MusicShuffleEngine.lapShuffler(mode: mode, signals: sig, seed: UInt64.random(in: .min ... .max))
        q.refreshPendingLap()
    }

    /// A shuffler for rows added while shuffle is on (an album or playlist added to the queue): the same engine, with no side effects.
    private func addShuffler(from: String?) -> MusicQueue.Shuffler {
        guard shuffle, from != nil else { return MusicQueue.systemShuffle }
        let mode: MusicShuffleMode = shuffleMode == .random ? .random : .smart
        return MusicShuffleEngine.shuffler(mode: mode, signals: shuffleSignals(), seed: UInt64.random(in: .min ... .max), lead: q.current?.track)
    }
    /// A radio start clears the shuffle flag for its own order; the person's sticky shuffle is remembered here for the next normal play.
    @ObservationIgnored private var stickyShuffleWanted = false
    /// Signals built once for a Shuffle Play (the opener draw and the ordering share them).
    @ObservationIgnored private var pendingShuffleSignals: MusicShuffleSignals?
    @ObservationIgnored private var suggestTask: Task<Void, Never>?
    /// Keeps a suggestion fetch that could place nothing from being asked again on every tick.
    @ObservationIgnored private var suggestGate = MusicSuggestGate()
    /// The graph recommender as an autoplay source, set by the hub once the graph is ready (nil: provider radio and the library only).
    @ObservationIgnored var autoplayGraphSource: (any MusicAutoplayCandidateSource)?
    /// Kids mode or the lock: false keeps a song out of autoplay and suggestions. Set by the hub.
    @ObservationIgnored var autoplayAllow: (@Sendable (MusicTrack) -> Bool)?
    /// True for songs that play without the network (downloaded, cached, local). Set by the hub.
    @ObservationIgnored var autoplayPlayableOffline: (@Sendable (MusicTrack) -> Bool)?

    private func makeAutoplayEngine(provider: any MusicMetadataProvider) -> MusicAutoplayEngine {
        var sources: [any MusicAutoplayCandidateSource] = []
        if q.isRadio, let r = radioSource { sources.append(r) }
        if let g = autoplayGraphSource { sources.append(g) }
        // A song that came from SoundCloud continues with SoundCloud's own related songs first; any other song gets nothing from it.
        if let registry, registry.isEnabled(SoundCloudProvider.providerID), let sc = registry.provider(id: SoundCloudProvider.providerID) as? SoundCloudProvider {
            sources.append(sc.autoplaySource())
        }
        sources.append(MusicAutoplayProviderSource.make(provider: provider))
        let pool = Array((library.liked + library.recent).prefix(400))
        sources.append(MusicLocalAffinitySource(library: { pool }))
        return MusicAutoplayEngine(sources: sources)
    }

    private func makeAutoplayInput(want: Int) -> (request: MusicAutoplayRequest, context: MusicAutoplayContext)? {
        let built = MusicAutoplayBuilder.make(entries: q.entries, currentIndex: q.index, recent: library.recent, history: MusicTasteReset.visible(library.history).map(\.track),
                                  blocked: q.isRadio ? library.blacklist.union(radioBlocked?() ?? []).union(MusicHiddenRecommendations.shared.set.blockedKeys) : library.blacklist.union(MusicHiddenRecommendations.shared.set.blockedKeys), offline: offlineStalled, want: want, allow: autoplayAllow,
                                  playableOffline: autoplayPlayableOffline)
        guard var made = built else { return nil }
        let taste = MusicTastePreferences.shared.prefs
        made.context.preferredLanguages = taste.languageSet
        if !taste.dislikedGenres.isEmpty {           // a genre marked "not for me" in setup is never auto-added
            let before = made.context.allow
            made.context.allow = { t in (before?(t) ?? true) && !taste.dislikesGenre(t) }
        }
        return made
    }

    /// Smart Shuffle: keeps a recommended song after every few of the person's own, asking for more when the upcoming ones thin out.
    private func topUpSuggestions() {
        guard shuffle, shuffleMode == .smartSuggest, !isRoomGuest, suggestTask == nil, library.settings.consentDone,
              let registry, let provider = registry.activeMetadata else { return }
        let own = q.upcomingOwnCount, suggested = q.upcomingSuggestedCount
        let need = MusicSmartSuggest.needed(ownUpcoming: own, suggestedUpcoming: suggested, ownAfterLastSuggestion: q.ownAfterLastSuggestion)
        let key = MusicSuggestGate.Key(epoch: q.epoch, own: own, suggested: suggested)
        // This runs on every position tick, so an attempt that cannot do better than the last one is not made.
        guard need > 0, suggestGate.shouldFetch(key, now: clock()), var built = makeAutoplayInput(want: need + 2) else { return }
        // Suggestions follow the whole context, not only its last song: seed from the playing row.
        built.request.recentSeeds = []
        let engine = makeAutoplayEngine(provider: provider)
        let epoch = q.epoch
        suggestTask = Task { [weak self] in
            let picks = await engine.fetch(built.request, context: built.context)
            guard let self else { return }
            self.suggestTask = nil
            guard !Task.isCancelled, self.q.epoch == epoch, self.shuffle, self.shuffleMode == .smartSuggest else { return }
            if picks.isEmpty { self.suggestGate.answeredNothing(now: self.clock()); return }
            if self.q.insertSuggestions(picks, seed: built.request.randomSeed) > 0 { self.suggestGate.reset(); self.sync(); self.queueChanged() }
            else { self.suggestGate.placedNothing(key) }
        }
    }

    /// Adds songs a station chose to the end of the queue as autoplay rows (the radio service's refill). Returns how many were added.
    @discardableResult
    func appendRadioPicks(_ picks: [MusicAutoplayPick]) -> Int {
        guard q.isRadio, !isRoomGuest else { return 0 }
        let added = q.mergeAutoplayPicks(picks)
        if added > 0 { q.trimHistory(); sync(); queueChanged() }
        return added
    }

    /// Songs after the playing one (all kinds of rows); the radio service refills when this falls under five.
    var upcomingCount: Int { max(0, q.entries.count - ((q.index ?? -1) + 1)) }

    /// "Keep" on an autoplay row or a suggestion.
    func keepRow(id: UUID) {
        guard !isRoomGuest else { return }
        if q.keepAuto(id: id) || q.keepSuggested(id: id) { queueEdited(startedEmpty: false) }
    }
    /// The volume slider, 0 to 1. The sound level follows `MusicVolumeCurve`, so equal steps feel equal.
    var volume: Float = 1 {
        didSet {
            // Clamp only when the value is out of range, and stop: under @Observable an assignment to `volume` inside its own observer runs the observer again,
            // so an unconditional `volume = clamped` never ended (a stack overflow, build 349 crash report 2026-11-26 01:46).
            let clamped = min(MusicAccessibilityPrefs.volumeCeiling(), max(0, volume))
            if clamped != volume { volume = clamped; return }
            mute.observe(volume)
            applyVolume()
            persistVolumeSoon()
        }
    }

    /// A small speed trim. Listen Together nudges it a few percent to close a gap with the host; it is 1 at all other times.
    var rate: Float = 1 {
        didSet {
            let r = min(1.05, max(0.95, rate))
            if r != rate { rate = r; return }
            applyRate()
        }
    }
    /// The position read straight from the audio clock, in file seconds; the published `position` only updates four times a second.
    var livePosition: TimeInterval {
        if mixLive { return position }
        if usingOpus, let o = opus { return currentLoad != nil ? o.position : position }
        if usingEngine, let e = engine { return currentLoad != nil ? e.position : position }
        let t = player.currentTime().seconds
        return currentLoad != nil && t.isFinite ? max(0, t) : position
    }

    /// A listening room is active: tempo is locked at 1 and crossfade is suspended. The hub sets this from the room session.
    var inRoom = false {
        didSet {
            guard inRoom != oldValue else { return }
            if inRoom, effects.speed != 1 { try? setEffects(effects.inRoom()) }
            queueChanged()
        }
    }
    /// This device follows a host: it cannot edit the queue and endless playback never runs.
    var isRoomGuest = false

    // MARK: wiring (set by the hub)
    var lyrics: MusicLyricsService?
    @ObservationIgnored var downloads: MusicDownloads?
    /// Disk cache of played audio and the loudness store. Both are created by the player itself under its state directory; the hub may
    /// replace them. The cache obeys `cacheEnabled` and `cacheLimitMB` from the settings at every track start.
    @ObservationIgnored var audioCache: MusicAudioCache?
    @ObservationIgnored var loudness: MusicLoudnessService?
    /// Needed by endless playback to find similar music. Without it the feature does nothing.
    @ObservationIgnored var registry: MusicRegistry?
    /// Queue positions added by endless playback, so the queue panel can label them.
    private(set) var autoAddedIndices: Set<Int> = []
    @ObservationIgnored var segmentSkipper = MusicSegmentSkipper()
    /// Called BEFORE any sound starts (play, resume, a new track): takes the audio from every other participant.
    @ObservationIgnored var onClaimAudio: (@MainActor () -> Void)?
    /// Called when playback is stopped for good: the audio is no longer this player's.
    @ObservationIgnored var onReleaseAudio: (@MainActor () -> Void)?
    @ObservationIgnored var onTrackStarted: (@MainActor (MusicTrack) -> Void)?
    @ObservationIgnored var onTrackFinished: (@MainActor (MusicTrack, Int64) -> Void)?
    /// Called when a song could not be played and was skipped (the station logic counts these to recover).
    @ObservationIgnored var onTrackFailed: (@MainActor (String) -> Void)?
    /// A station's own candidate source; asked first while a radio queue plays. Set by the radio service.
    @ObservationIgnored var radioSource: (any MusicAutoplayCandidateSource)?
    /// Song uids a station keeps out of the queue (its bans); added to the "Never play" set for autoplay. Set by the radio service.
    @ObservationIgnored var radioBlocked: (@MainActor () -> Set<String>)?
    /// Called whenever the playing track changes (nil when the queue empties), with the reason.
    @ObservationIgnored var onCurrentChanged: (@MainActor (MusicTrack?, MusicTrackChange) -> Void)?
    /// Receives the Now Playing dictionary (and whether playing) whenever something the system shows changes. The shell passes it to the router.
    @ObservationIgnored var publishNowPlaying: (@MainActor ([String: Any], Bool) -> Void)?
    /// Tells the router that `remoteSupport` changed.
    @ObservationIgnored var onRemoteSupportChanged: (@MainActor () -> Void)?
    /// True while the person has an outbound proxy set: the loopback proxy is then bypassed.
    @ObservationIgnored var userProxyActive: @MainActor () -> Bool = { false }

    // MARK: internals
    private struct Loaded {
        var item: AVPlayerItem
        var entryID: UUID
        var track: MusicTrack
        var stream: MusicStream?
        var pageURL: String?
        var cacheKey: String?
        /// Set when the stream is WebM or Ogg Opus: the system player cannot open it, so the Opus backend plays it.
        var opusSource: MusicOpusByteSource? = nil
        /// How the audio reaches the player, for the failure log: "proxy", "direct", "file", "cache file" or "opus".
        var route = "direct"
    }

    private static let volumeKey = "music.volume"
    private static let queueFile = "queue.json"
    private static let indexFile = "queue-index.json"
    /// Position is saved at most this often while playing.
    private static let saveEvery: TimeInterval = 5

    @ObservationIgnored private let resolver: MusicStreamResolver
    @ObservationIgnored private let library: MusicLibrary
    @ObservationIgnored private let stateDirectory: URL
    @ObservationIgnored private var q = MusicQueue()
    /// Changes whenever the whole queue is replaced (a new song, album, radio). A slow start (a radio waiting for its songs) compares it before it plays, so it never replaces what the person chose meanwhile.
    var queueEpoch: Int { q.epoch }
    @ObservationIgnored private var player = AVQueuePlayer()
    @ObservationIgnored private var secondary = AVQueuePlayer()
    /// The item whose start settings (no waiting, short lead) are still in force; lifted from `tick`.
    @ObservationIgnored private var fastStartItem: AVPlayerItem?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var timeObserverOwner: AVPlayer?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var currentLoad: Loaded?
    @ObservationIgnored private var nextLoad: Loaded?
    @ObservationIgnored private var nextReady = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var preloadTask: Task<Void, Never>?
    @ObservationIgnored private var fadeTask: Task<Void, Never>?
    @ObservationIgnored private var heldPrime = false
    @ObservationIgnored private var primedForCrossfade = false
    @ObservationIgnored private let proxy = MusicStreamProxy()
    /// Volume factor from normalisation for the track playing now (1 when normalisation is off).
    @ObservationIgnored private var normFactor: Float = 1
    @ObservationIgnored private var fadeOutNorm: Float = 1
    @ObservationIgnored private var gainDB = 0.0
    @ObservationIgnored private var normTask: Task<Void, Never>?
    @ObservationIgnored private var normRamp: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var volumeTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var gapless = MusicGaplessState()
    @ObservationIgnored private var primeBudget = MusicPrimeBudget()
    @ObservationIgnored private var ladder = MusicFailureLadder()
    /// Songs whose loaded length was already compared with the catalogue, and songs that play directly because the proxy failed for them.
    @ObservationIgnored private var durationChecked: Set<UUID> = []
    /// The length plan of the song that is playing (what to show, where to end it) and the row it belongs to.
    @ObservationIgnored private var lengthTrim = MusicLengthTrim()
    @ObservationIgnored private var lengthTrimRow: UUID?
    @ObservationIgnored private var proxyBypass: Set<String> = []
    @ObservationIgnored private var endlessWatchdog = MusicEmptyQueueWatchdog()
    @ObservationIgnored private var endlessRetry: Task<Void, Never>?
    @ObservationIgnored private var offlineLadder = MusicOfflineLadder()
    @ObservationIgnored private var offlineTask: Task<Void, Never>?
    @ObservationIgnored private var offlineStalled = false
    /// Whether the device is online, from the app's network watch (set by the hub). Without it the player assumes it is.
    @ObservationIgnored var isOnline: @MainActor () -> Bool = { true }
    private var online: Bool { isOnline() }
    /// Karaoke: the provider that makes vocal-free copies. Set by the hub; with none, or with karaoke off, nothing here does anything.
    @ObservationIgnored var karaoke: (any MusicKaraokeProviding)?
    @ObservationIgnored private var karaokePlaying: MusicKaraokePlaying = .original
    @ObservationIgnored private var karaokeFallBack: Date?
    @ObservationIgnored private var karaokePinned: URL?
    @ObservationIgnored private var karaokeItem: ObjectIdentifier?
    @ObservationIgnored private var originalAsset: AVAsset?
    @ObservationIgnored private var swapTask: Task<Void, Never>?
    @ObservationIgnored private var upgradeTask: Task<Void, Never>?
    /// Set while the app is locked or a Kids profile is on: nothing starts, whatever asks (media keys, a remote, a room).
    @ObservationIgnored var blocked = false
    @ObservationIgnored private var loadingTrack: MusicTrack?
    @ObservationIgnored private var loadingEntry: UUID?
    @ObservationIgnored private var carriedError: String?
    @ObservationIgnored private var resolving = false
    @ObservationIgnored private var endlessGate = MusicEndlessGate()
    @ObservationIgnored private var endlessTask: Task<Void, Never>?
    @ObservationIgnored private var endlessGeneration = 0
    @ObservationIgnored private var autoplayWantsAdvance = false
    @ObservationIgnored private var autoplayEndedAtTail = false
    @ObservationIgnored private var waiting = false
    @ObservationIgnored private var reportedTrack: MusicTrack?
    @ObservationIgnored private var playedMs: Int64 = 0
    @ObservationIgnored private var audible = MusicAudibleClock()
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var watchPhase: MusicStartWatchdog.Phase?
    @ObservationIgnored private var watchSince: TimeInterval = 0
    @ObservationIgnored private var watchNoticed = false
    @ObservationIgnored private var durationSeen: (value: Double, ticks: Int)?
    @ObservationIgnored private var lastTick: TimeInterval?
    @ObservationIgnored private var lastResumeSave: Date = .distantPast
    @ObservationIgnored private var lastRemoteSkip: [RemoteCommandKind: Date] = [:]
    @ObservationIgnored private var lastSavedPosition: TimeInterval = 0
    @ObservationIgnored private var lastBlobFingerprint = ""
    @ObservationIgnored private var lastUserSeek = Date.distantPast
    // Transport guards: seek coalescing, the stale-pause reload and the play/pause echo guard (see MusicTransportGuards).
    @ObservationIgnored private var seekGate = MusicSeekCoalescer()
    @ObservationIgnored private var seekEpoch = 0
    @ObservationIgnored private var stalePause = MusicStalePause()
    @ObservationIgnored private var pressEcho = MusicPlayPauseEcho()
    /// The clock the pause and echo rules and the queue history read. Tests replace it.
    @ObservationIgnored var clock: () -> Date = { Date() }
    /// The wait before a throttled track is tried again.
    @ObservationIgnored private var throttleTask: Task<Void, Never>?
    // Queue undo and redo (see MusicQueueUndo).
    @ObservationIgnored private var queueHistory = MusicQueueHistory()
    private(set) var canUndoQueueEdit = false
    private(set) var canRedoQueueEdit = false
    /// The output device choice for Music (macOS lists devices; iPhone uses the system route picker).
    @ObservationIgnored let outputs = MusicOutputDevices()
    @ObservationIgnored private var outputChangeAt = Date.distantPast
    @ObservationIgnored private var audioProfileUID: String?
    #if os(macOS)
    @ObservationIgnored private var outputWatcher: MusicOutputWatcher?
    #endif
    @ObservationIgnored private var skipSegments: [MusicSkipSegment] = []
    @ObservationIgnored private var lastHadNext = false
    @ObservationIgnored private var lastHadCurrent = false
    @ObservationIgnored private var artwork: MPMediaItemArtwork?
    @ObservationIgnored private var artworkUID: String?
    @ObservationIgnored private var syncingShuffle = false
    @ObservationIgnored private var syncingRepeat = false
    @ObservationIgnored private var mute = MusicMuteMemory()
    @ObservationIgnored private var lastPushedListening: TimeInterval = -100
    @ObservationIgnored private var lastPushAt = Date.distantPast
    // Effects engine path.
    @ObservationIgnored private var engine: MusicEffectsEngine?
    @ObservationIgnored private var usingEngine = false
    @ObservationIgnored private var engineTick: Task<Void, Never>?
    // Opus backend path (WebM and Ogg Opus). While it plays, `usingEngine` is also true, so the AVPlayer-only features stay off.
    @ObservationIgnored private var opus: MusicOpusPlayback?
    @ObservationIgnored private var usingOpus = false
    @ObservationIgnored private var opusRescued: Set<String> = []
    // Equalizer and Automix.
    /// The equalizer, tone pad and widening in force. Persisted in the player preferences; any of it on puts playback on the effects engine.
    private(set) var equalizer = MusicEqualizerSettings()
    /// Beat analysis, the planner and the two-deck renderer. Idle (no work, no timers) while Automix is off.
    @ObservationIgnored let automix: MusicAutomixController
    @ObservationIgnored private var adviceNow: MusicTransitionAdvice = .useDefault
    @ObservationIgnored private var mixPreparing: UUID?
    @ObservationIgnored private var mixReady: (plan: MusicMixPlan, entryID: UUID)?
    @ObservationIgnored private var mixLive = false
    @ObservationIgnored private var mixAbort: (() -> Void)?
    @ObservationIgnored private var pinnedKeys: [String] = []
    /// The cached-file lookups of `analysisURL`, kept for a moment: the tick asks twice a quarter second, and each ask is a file-system check on the main thread.
    @ObservationIgnored private var analysisURLMemo: [String: (url: URL?, at: TimeInterval)] = [:]

    init(resolver: MusicStreamResolver, library: MusicLibrary, stateDirectory: URL? = nil) {
        self.resolver = resolver
        self.library = library
        let dir = stateDirectory ?? Self.defaultStateDirectory()
        self.stateDirectory = dir
        self.audioCache = MusicAudioCache(directory: MusicAudioCache.defaultDirectory(under: dir))
        self.loudness = MusicLoudnessService(directory: dir)
        self.effectPresets = MusicEffectPresetStore(directory: dir)
        self.automix = MusicAutomixController(directory: dir)
        if let v = UserDefaults.standard.object(forKey: Self.volumeKey) as? Float { volume = min(1, max(0, v)) }
        mute.observe(volume)
        player.volume = MusicVolumeCurve.amplitude(slider: Double(volume))
        bindPlayer()
        observeSystem()
        resolver.onLateRejection = { [weak self] t, s in self?.lateRejected(t, s) }
        if library.settings.player.equalizer.isValid { equalizer = library.settings.player.equalizer }
        restore()
        #if os(macOS)
        outputs.apply = { [weak self] uid in self?.applyOutputDevice(uid) ?? true }
        #endif
    }

    static func defaultStateDirectory() -> URL { MusicStorage.root }

    private var prefs: MusicPlayerPrefs { library.settings.player }

    // MARK: music video

    /// The player that holds the picture while a video stream is playing, for a view to show; nil for sound-only streams and while pitch or
    /// reverb has the track on the effects engine (which decodes sound only). Show it with `AVPlayerLayer`; it shares the one clock.
    var videoPlayer: AVPlayer? {
        guard !usingEngine, currentLoad != nil, currentStream?.hasVideo == true else { return nil }
        return player
    }

    // MARK: listening time

    var tempo: Double { effects.speed }
    /// What the bar shows: file seconds divided by tempo.
    var listeningPosition: TimeInterval { MusicVolumeCurve.listening(position, tempo: tempo) }
    var listeningDuration: TimeInterval { MusicVolumeCurve.listening(duration, tempo: tempo) }

    /// A seek from the bar, in listening seconds.
    func seekListening(to s: TimeInterval) { seek(to: MusicVolumeCurve.trackSeconds(fromListening: s, tempo: tempo)) }

    /// Skips by seconds the person hears (so 10 means ten listening seconds at any tempo). Every key, hotkey and OS control uses this.
    func skip(listeningSeconds s: TimeInterval) { seek(to: position + s * tempo) }

    // MARK: queue control

    /// "Shuffle Play": starts `tracks` in the engine's order, once. The opener is a weighted draw, the rest is ordered by the same engine as the shuffle button, and
    /// the player's shuffle mode is on afterwards (turning it off restores the list's own order). Every page's Shuffle button comes here; none shuffles the list itself.
    func playShuffled(_ tracks: [MusicTrack], sourceName: String? = nil, sourceID: String? = nil) {
        guard !tracks.isEmpty else { return }
        let mode: MusicShuffleMode = shuffleMode == .random ? .random : .smart
        let signals = shuffleSignals()
        let start = MusicShuffleEngine.openingIndex(of: tracks, mode: mode, signals: signals, seed: UInt64.random(in: .min ... .max))
        pendingShuffleSignals = signals
        play(tracks, startAt: start, sourceName: sourceName, sourceID: sourceID, shuffleOn: true)
        pendingShuffleSignals = nil
    }

    /// Replaces the queue and starts `startAt`. Upcoming "Play next" and "Add to queue" rows survive; the replaced queue can be restored.
    func play(_ tracks: [MusicTrack], startAt: Int = 0, sourceName: String? = nil, sourceID: String? = nil,
              radioSeed: String? = nil, isRadio: Bool = false, shuffleOn: Bool = false) {
        cancelEndless(); endlessGate.reset()
        queueHistory.reset(); refreshUndoFlags()
        let leaving = currentLoad != nil ? livePosition : position
        let wasShuffle = shuffle || stickyShuffleWanted
        if !isRadio { stickyShuffleWanted = false }
        finishCurrent()
        q.replace(with: tracks, startAt: startAt, sourceName: sourceName, sourceID: sourceID, radioSeed: radioSeed, isRadio: isRadio,
                  leavingPosition: leaving)
        // A new context starts unshuffled unless shuffle is sticky, or this is a Shuffle Play (which is shuffled by the engine exactly once, here).
        // A radio keeps its provider's ranked order unless the person asked for Shuffle Play itself. The chosen opener plays first and every
        // other row of the list (including those before it) is still to come (`fresh`); a one-song list keeps sticky shuffle on.
        let wantShuffle = (shuffleOn || (wasShuffle && prefs.stickyShuffle)) && (shuffleOn || !isRadio)
        if wantShuffle {
            // A one-row list shuffles trivially, so the flag stays on (and un-shuffle still works).
            q.setShuffle(true, wholeQueue: prefs.shuffleWholeQueue, fresh: true, shuffler: shuffleEngineShuffler())
            if !shuffle { setShuffleFlag(true) }
        } else if isRadio {
            // A radio keeps its own order; the person's sticky shuffle is remembered for the next normal play.
            stickyShuffleWanted = wasShuffle && prefs.stickyShuffle
            setShuffleFlag(false)
        } else { setShuffleFlag(false) }
        dropPreload()
        sync()
        if q.current == nil { stop(); return }
        // A song the person (or a radio, a concert, a station) starts brings a hidden player bar back, whichever page asked.
        MusicBarVisibilityModel.shared.restore()
        if let t = q.current?.track { forgiveByUser(t) }
        startCurrent()
        if shuffle, shuffleMode == .smartSuggest { topUpSuggestions() }
    }

    /// The person pressed play on this song: any earlier verdict, parked client or marker is dropped and the lookup is fresh.
    private func forgiveByUser(_ t: MusicTrack) {
        clearFailureMark(t.uid)
        localBypass.remove(t.uid)
        resolver.forgive(t)
    }

    /// Plays one track now. The queue is replaced by it.
    func playNow(_ t: MusicTrack) { play([t], startAt: 0) }

    #if DEBUG
    /// Test seam for the snapshot harness: puts a queue and a paused or playing state on screen without resolving or playing any audio.
    func installSnapshotState(queue tracks: [MusicTrack], startAt: Int, playing: Bool, position at: TimeInterval, duration total: TimeInterval, autoplay tail: [MusicTrack] = []) {
        q.replace(with: tracks, startAt: startAt, sourceName: "Playlist", remember: false)
        if !tail.isEmpty { q.append(tail, auto: true) }
        sync()
        saveTask?.cancel()
        isPlaying = playing
        position = at
        duration = total
    }
    #endif

    /// "Add to queue". False when nothing was added (a room guest cannot edit the queue), so a page never says it was.
    @discardableResult
    func enqueue(_ ts: [MusicTrack], from: String? = nil, quiet: Bool = false) -> Bool {
        guard !ts.isEmpty, allowsQueueAdd() else { return false }
        let r = q.addToQueue(ts, from: from, options: prefs.queueOptions, shuffler: addShuffler(from: from))
        guard r.added > 0 || r.startedEmpty else { return false }   // nothing joined the queue: no "Added" notice and no success
        if !quiet { showNotice(ts.count == 1 ? Localized.string("Added to queue") : Localized.string("Added %d songs to queue", ts.count)) }
        queueEdited(startedEmpty: r.startedEmpty)
        return true
    }

    /// "Play next". False when nothing was added.
    @discardableResult
    func playNext(_ ts: [MusicTrack], from: String? = nil) -> Bool {
        guard !ts.isEmpty, allowsQueueAdd() else { return false }
        let r = q.playNext(ts, from: from, options: prefs.queueOptions, shuffler: addShuffler(from: from))
        guard r.added > 0 || r.startedEmpty else { return false }
        showNotice(ts.count == 1 ? Localized.string("Playing next") : Localized.string("Playing next: %d songs", ts.count))
        queueEdited(startedEmpty: r.startedEmpty)
        return true
    }

    /// Songs the playing list is still handing over (a long chart, the rest of the row that was pressed): they join the list's own rows, with no "Queued" mark, and never
    /// start playback by themselves in an emptied queue.
    func extendContext(_ ts: [MusicTrack], shuffled: Bool = false) {
        guard !isRoomGuest, !ts.isEmpty else { return }
        guard q.extendContext(ts, shuffler: shuffled && shuffle ? addShuffler(from: q.sourceName ?? "") : nil) > 0 else { return }
        queueEdited(startedEmpty: false)
    }

    /// A guest in a listening room follows the host's queue: an add does nothing there, and says why.
    private func allowsQueueAdd() -> Bool {
        guard isRoomGuest else { return true }
        showNotice(Localized.string("Only the host can change the queue."))
        return false
    }

    func remove(at i: Int) {
        guard !isRoomGuest else { return }
        let removedRow = q.removedRow(at: i)
        let shown = shownRowID
        // Taking the last row out while it plays leaves the row before it as "current" in the queue, and that song has already been played: it must not start again.
        let hadFollowing = i < q.count - 1
        let wasCurrent = q.remove(at: i)
        if let removedRow { recordRemoval([removedRow]) }
        if wasCurrent {
            dropPreload()
            finishCurrent()
            if q.current != nil, isPlaying, hadFollowing { sync(); startCurrent() }
            else if q.current == nil { sync(); stop(); duration = 0 }
            else {
                let wasPlaying = isPlaying
                clearLoaded(); position = 0
                if wasPlaying { isPlaying = false; onReleaseAudio?() }
                showWaitingRow(replacing: shown)
            }
        } else {
            queueEdited(startedEmpty: false)
        }
    }

    /// Removes several queue rows at once (the multi-select bar). The playing row is never part of it. One Undo brings them all back.
    func removeRows(ids: Set<UUID>) {
        guard !isRoomGuest, !ids.isEmpty else { return }
        let playing = q.currentID
        let indices = q.entries.indices.filter { ids.contains(q.entries[$0].id) && q.entries[$0].id != playing }.sorted(by: >)
        guard !indices.isEmpty else { return }
        let removedRows = indices.compactMap { q.removedRow(at: $0) }
        for i in indices { q.remove(at: i) }
        if let s = stopAfterEntryID, ids.contains(s) { stopAfterEntryID = nil }
        recordRemoval(removedRows)
        queueEdited(startedEmpty: false)
    }

    /// Reorders an upcoming row; `to` is its final index. Only rows after the playing one move, and only among themselves.
    func moveUpcoming(from: Int, to: Int) {
        guard !isRoomGuest else { return }
        let moved = q.entries.indices.contains(from) ? q.entries[from] : nil
        guard q.moveUpcoming(from: from, to: to) else { return }
        if let moved, let landed = q.entries.firstIndex(where: { $0.id == moved.id }) {
            // The final place is recorded (the queue may have held the row in front of the autoplay rows), with whether it was an autoplay row.
            queueHistory.recordMove(id: moved.id, from: from, to: landed, wasAuto: moved.auto, at: clock()); refreshUndoFlags()
            offerUndo(Localized.string("Queue order changed"))
        }
        queueEdited(startedEmpty: false)
    }

    func move(from: Int, to: Int) { moveUpcoming(from: from, to: to) }

    /// "Move to Play Next" for an upcoming row: it goes right after the playing one and joins the Play next rows.
    func moveToPlayNext(from: Int) {
        guard !isRoomGuest, let c = q.index else { return }
        let moved = q.entries.indices.contains(from) ? q.entries[from] : nil
        guard q.moveToPlayNext(from: from) else { return }
        if let moved, from != c + 1 {
            queueHistory.recordMove(id: moved.id, from: from, to: c + 1, wasAuto: moved.auto, at: clock()); refreshUndoFlags()
            offerUndo(Localized.string("Queue order changed"))
        }
        queueEdited(startedEmpty: false)
    }

    /// "Clear queue": removes every upcoming row the person added by hand. The playlist context and played rows stay.
    func clearQueue() {
        guard !isRoomGuest else { return }
        let rows = q.manualRemovedRows()
        guard q.clearManual() > 0 else { return }
        queueHistory.recordClear(rows, at: clock()); refreshUndoFlags()
        offerUndo(Localized.string("Queue cleared"))
        queueEdited(startedEmpty: false)
    }

    // MARK: queue undo

    private func refreshUndoFlags() {
        if canUndoQueueEdit != queueHistory.canUndo { canUndoQueueEdit = queueHistory.canUndo }
        if canRedoQueueEdit != queueHistory.canRedo { canRedoQueueEdit = queueHistory.canRedo }
    }

    private func recordRemoval(_ rows: [MusicQueue.RemovedRow]) {
        let n = queueHistory.recordRemoval(rows, at: clock())
        refreshUndoFlags()
        offerUndo(n <= 1 ? Localized.string("Removed from queue") : Localized.string("Removed %d songs from queue", n))
    }

    /// A toast with an Undo button. Removals made within a few seconds merge, so one Undo brings them all back.
    private func offerUndo(_ text: String) {
        MusicToasts.shared.show(text, kind: .info, actionTitle: Localized.string("Undo")) { [weak self] in self?.undoQueueEdit() }
    }

    /// Undoes the newest queue removal, clear or reorder.
    func undoQueueEdit() {
        guard !isRoomGuest, queueHistory.undo(on: &q) != nil else { return }
        queueHistoryApplied()
    }

    /// Does the undone queue change again.
    func redoQueueEdit() {
        guard !isRoomGuest, queueHistory.redo(on: &q) != nil else { return }
        queueHistoryApplied()
    }

    private func queueHistoryApplied() {
        refreshUndoFlags()
        // Rows came back into a queue that had emptied: the first one is up.
        if q.currentID == nil, !q.isEmpty {
            q.jump(to: 0); ladder.pointerMoved(); dropPreload(); sync(); startCurrent()
            return
        }
        queueEdited(startedEmpty: false)
    }

    /// "Stop playback" from the bar: stops, gives the audio back and empties the queue, so nothing is current and the bar goes away.
    func stopAndClear() {
        guard !isRoomGuest else { return }
        cancelEndless()
        stop()
        q.clear(keepCurrent: false); setShuffleFlag(false); stickyShuffleWanted = false; stopAfterEntryID = nil; dropPreload(); sync()
        duration = 0
        // An Undo still on screen belongs to the queue that is gone: bringing rows back would start the music again.
        queueHistory.reset(); refreshUndoFlags()
    }

    /// Removes every row after the playing one (Play next, Up next and Autoplay) and keeps the playing song and the songs already played. Undo brings them back.
    func clearUpcoming() {
        guard !isRoomGuest else { return }
        cancelEndless(); endlessGate.suppress(q.currentID)
        let rows = q.upcomingRemovedRows()
        guard q.removeUpcoming() > 0 else { return }
        if let s = stopAfterEntryID, s != q.currentID { stopAfterEntryID = nil }   // its row is gone
        dropPreload(); sync()
        if !rows.isEmpty {
            queueHistory.recordClear(rows, at: clock()); refreshUndoFlags()
            offerUndo(Localized.string("Queue cleared"))
        }
    }

    /// Removes the tracks endless playback added, and stops it adding more for this tail.
    func clearAutoAdded() {
        guard !isRoomGuest else { return }   // a guest follows the host's queue
        // removable as a group, and the group comes back with Undo
        let rows = (q.index.map { c in ((c + 1)..<max(c + 1, q.entries.count)).filter { q.entries[$0].auto }.compactMap { q.removedRow(at: $0) } }) ?? []
        cancelEndless(); endlessGate.suppress(q.currentID)
        q.clearAuto(); queueEdited(startedEmpty: false)
        if !rows.isEmpty { queueHistory.recordClear(rows, at: clock()); refreshUndoFlags(); offerUndo(Localized.string("Removed autoplay songs")) }
    }

    var autoAddedCount: Int { autoAddedIndices.count }

    /// Plays the queue row at `i` (a tap on a queue row), keeping every marker.
    func jump(to i: Int) {
        guard queue.indices.contains(i), !isRoomGuest else { return }
        finishCurrent()
        q.jump(to: i); ladder.pointerMoved(); dropPreload(); sync()
        if let t = q.current?.track { forgiveByUser(t) }
        startCurrent(fromTop: true)
    }

    /// Brings back the queue that the last click replaced, at the track and position it was left.
    func restorePreviousQueue() {
        guard !isRoomGuest, q.previousContext != nil else { return }
        cancelEndless(); endlessGate.reset()
        queueHistory.reset(); refreshUndoFlags()
        finishCurrent()
        guard let at = q.restorePreviousContext() else { return }
        setShuffleFlag(q.shuffle)
        if q.shuffle { installLapShuffler() }
        dropPreload(); sync()
        startCurrent(resumeAt: at > 1 ? at : 0)
    }

    /// Starts the current row again at the saved position (the bar's Retry).
    func retryCurrent() {
        guard !isRoomGuest, let t = current else { return }
        ladder.userRetried()
        forgiveByUser(t)   // the earlier failure mark, the local bypass and the resolver's negative verdict would make this fail at once
        startCurrent(resumeAt: position)
    }

    /// Removes every upcoming copy of tracks that match (a blocked artist, a disliked song), highest index first. If the playing row
    /// matches too it is skipped.
    func purgeUpcoming(where match: (MusicTrack) -> Bool) {
        guard !isRoomGuest else { return }
        for i in q.upcomingIndices(where: match) { q.remove(at: i) }
        let playingMatches = q.current.map { match($0.track) } ?? false
        // The removals show at once, whatever happens to the playing song.
        queueEdited(startedEmpty: false)
        guard playingMatches, let c = q.index else { return }
        if c < q.count - 1 || (q.repeatMode != .off && q.entries.contains { !match($0.track) }) { next(); return }
        // Nothing follows: the song the person turned away must not play on.
        finishCurrent()
        if canAutoplay {
            cancelEndless(); clearLoaded(); isPlaying = false; position = 0; refreshBuffering(); publishNow(force: true)
            topUpAutoplay(force: true, thenAdvance: true, endedAtTail: true)
        } else {
            stop()
            showNotice(Localized.string("The queue ends here."))
        }
    }

    /// The Autoplay switch: off removes the rows endless playback added (rows the person placed stay); on tops the queue up at once.
    func setAutoplay(_ on: Bool) {
        guard !isRoomGuest else { return }
        library.settings.endlessPlayback = on
        if on { topUpAutoplay(force: true) }
        else { cancelEndless(); q.clearAuto(); queueEdited(startedEmpty: false) }
    }

    // MARK: transport

    func next() {
        MusicActionFeedback.fire(.next)
        guard current != nil, !isRoomGuest else { return }
        let nextPos = Int(listeningPosition), nextName = current?.title ?? "?"
        MusicDebugLog.log("queue", "next pressed at \(nextPos) s of \(nextName)")
        if !q.hasNext {
            // At the tail: fetch more now rather than leave a dead button. When autoplay cannot run (it is off, repeat is on, no source, a room guest) say so instead of doing nothing.
            guard canAutoplay else { showNotice(Localized.string("The queue ends here.")); return }
            topUpAutoplay(force: true, thenAdvance: true)
            return
        }
        cancelFade()
        finishCurrent()
        advance(auto: false)
    }

    func previous() {
        MusicActionFeedback.fire(.previous)
        guard current != nil, !isRoomGuest else { return }
        let prevPos = Int(listeningPosition), prevName = current?.title ?? "?"
        MusicDebugLog.log("queue", "previous pressed at \(prevPos) s of \(prevName)")
        if listeningPosition > 3 || q.index == nil { seek(to: 0); return }
        // On the first row Previous restarts the song. Bringing back the replaced queue is only the explicit "Back to ..." control, never a surprise swap.
        if q.index == 0, q.previousContext != nil { seek(to: 0); return }
        if q.retreat() != nil {
            cancelFade(); finishCurrent(); ladder.pointerMoved(); dropPreload(); sync(); startCurrent()
        } else {
            seek(to: 0)
        }
    }

    func toggle() { MusicActionFeedback.fire(isPlaying ? .pause : .play); isPlaying ? pause() : resume() }

    func pause() {
        guard current != nil else { return }
        cancelFade()
        player.pause()
        secondary.pause()
        if usingOpus { opus?.pause() } else if usingEngine { engine?.pause() }
        isPlaying = false
        rememberPlace()
        throttleTask?.cancel(); throttleTask = nil
        stalePause.paused(at: clock())
        pressEcho.pressed(playing: false, at: clock())
        stopTicking()
        lastTick = nil
        refreshBuffering()
        saveNow()
        publishNow()
    }

    /// Another participant took the audio: pause without giving the audio back.
    func pauseForOtherAudio() { if isPlaying { pause() } }

    func resume() {
        guard current != nil, !isPlaying else { return }
        cancelFade()
        offlineTask?.cancel(); offlineStalled = false
        pressEcho.pressed(playing: true, at: clock())
        if currentLoad == nil {
            ladder.userRetried()
            if resolving {
                // Paused and pressed again while the song is still being looked up: playing is wanted again, and the lookup that is running starts it.
                guard !blocked else { return }
                onClaimAudio?()
                isPlaying = true
                audible.reset(); watchPhase = nil
                ensureWatchdog()
                activateSession()
                refreshBuffering()
                publishNow()
                return
            }
            if let t = current { forgiveByUser(t) }
            startCurrent(resumeAt: position, fromTop: position == 0)
            return
        }
        // Paused for five minutes or more: the stream address and its buffers are stale, so the track loads again at the saved position.
        if stalePause.isStale(at: clock()), currentLoad?.stream != nil, let t = current {
            stalePause.clear()
            resolver.invalidate(t)
            startCurrent(resumeAt: position)
            return
        }
        stalePause.clear()
        onClaimAudio?()
        isPlaying = true
        audible.reset(); watchPhase = nil
        ensureWatchdog()
        activateSession()
        if usingOpus { opus?.resume() } else if usingEngine { engine?.resume() } else { player.play() }
        startTicking()
        reportStartIfNeeded()
        refreshBuffering()
        publishNow()
    }

    // MARK: listening modes

    /// The quality a stream is asked for: the person's setting, lowered in Data saving.
    var effectiveQuality: MusicQuality { MusicListeningModes.profile.lowQuality ? .low : library.settings.audioQuality }

    /// A mode that bypasses (or stops bypassing) the signal path was switched: the current song moves to the path it should now use, at the same place.
    func modeChangedSignalPath() {
        guard currentLoad != nil, !usingOpus else { return }
        let bypass = MusicListeningModes.profile.bypassesSignalProcessing
        if bypass, usingEngine { switchToPlayer(settings: MusicEffectSettings(speed: effects.speed)) }
        else if !bypass, !usingEngine, effects.needsEngine || equalizer.needsEngine { try? switchToEngine(effects) }
        if let l = currentLoad { beginNormalisation(for: l, ramp: true) }
    }

    // MARK: visualizer tap

    /// True while a visualizer is on screen. Off: no tap is attached anywhere and no audio is copied.
    private(set) var visualizerOn = false

    func setVisualizer(_ on: Bool) {
        guard on != visualizerOn else { return }
        visualizerOn = on
        MusicAudioTap.shared.setActive(on)
        engine?.setVisualizerTap(on)
        opus?.setVisualizerTap(on)
        if let item = currentLoad?.item, !usingEngine {
            if on { attachVisualizerMix(to: item) } else { item.audioMix = nil }
        }
    }

    private func attachVisualizerMix(to item: AVPlayerItem) {
        Task { @MainActor [weak self] in
            guard let mix = await MusicAudioTap.mix(for: item), self?.visualizerOn == true else { return }
            item.audioMix = mix
        }
    }

    // MARK: song marks (A-B loop, bookmarks, start and end, intro and outro)

    @ObservationIgnored var marks: MusicTrackMarkStore = .shared
    @ObservationIgnored private var marksFired = false

    /// The marks of the song that is playing now.
    var currentMark: MusicTrackMark { current.map { marks.mark(for: $0.uid) } ?? MusicTrackMark() }

    /// True when the mark ended the song (the caller stops working on this position).
    private func applyMarks(_ p: TimeInterval) -> Bool {
        guard let t = current, !marksFired else { return false }
        let m = marks.mark(for: t.uid)
        guard !m.isEmpty else { return false }
        switch MusicTrackMarkRules.action(position: p, mark: m, duration: duration) {
        case .none: return false
        case .seek(let a): seek(to: a); return false
        case .advance:
            marksFired = true
            // A custom end is the song's end: the listen counts, "Stop after this song" holds and repeat-one starts it again.
            trackEnded()
            return true
        }
    }

    func setLoopStart() { guard let t = current else { return }; let p = position; marks.edit(t.uid) { $0.loopA = p; if let b = $0.loopB, b <= p + 0.5 { $0.loopB = nil } } }
    func setLoopEnd() {
        guard let t = current else { return }
        let p = position
        marks.edit(t.uid) { m in
            if let a = m.loopA, p > a + 0.5 { m.loopB = p; m.loopOn = true } else { m.loopB = p; m.loopA = nil }
        }
    }
    func toggleLoop() { guard let t = current else { return }; marks.edit(t.uid) { if $0.hasLoop { $0.loopOn.toggle() } } }
    func clearLoop() { guard let t = current else { return }; marks.edit(t.uid) { $0.loopA = nil; $0.loopB = nil; $0.loopOn = false } }
    func setStartHere() { guard let t = current else { return }; let p = position; marks.edit(t.uid) { $0.start = p; if let e = $0.end, e <= p + 1 { $0.end = nil } } }
    func setEndHere() { guard let t = current else { return }; let p = position; marks.edit(t.uid) { $0.end = p; if let s = $0.start, s >= p - 1 { $0.start = nil } } }
    func clearBounds() { guard let t = current else { return }; marks.edit(t.uid) { $0.start = nil; $0.end = nil; $0.skipIntro = nil; $0.skipOutro = nil } }
    func setSkips(intro: Double?, outro: Double?) { guard let t = current else { return }; marks.edit(t.uid) { $0.skipIntro = intro; $0.skipOutro = outro } }
    func addBookmark(named name: String? = nil) {
        guard let t = current else { return }
        let p = position
        marks.edit(t.uid) { m in
            let label = (name?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? MusicTrackMarkRules.clock(p)
            m.bookmarks.append(.init(name: label, at: p))
            m.bookmarks.sort { $0.at < $1.at }
        }
    }
    func removeBookmark(_ id: UUID) { guard let t = current else { return }; marks.edit(t.uid) { $0.bookmarks.removeAll { $0.id == id } } }
    func renameBookmark(_ id: UUID, to name: String) {
        guard let t = current else { return }
        marks.edit(t.uid) { m in if let i = m.bookmarks.firstIndex(where: { $0.id == id }) { m.bookmarks[i].name = name } }
    }
    func jumpToBookmark(forward: Bool) {
        guard let b = MusicTrackMarkRules.neighbour(of: position, in: currentMark.bookmarks, forward: forward) else { return }
        seek(to: b.at)
    }

    func seek(to t: TimeInterval) {
        let limit = duration > 0 ? duration : .greatestFiniteMagnitude
        let target = min(max(0, t), limit)
        cancelFade()
        position = target
        lastTick = nil
        lastUserSeek = Date()
        if currentLoad != nil {
            if usingOpus { opus?.seek(to: target) }
            else if usingEngine { restartEngine(at: target) }
            else { requestPlayerSeek(target) }
        }
        saveSoon()
        publishNow(force: true)
    }

    // MARK: seek coalescing

    /// One system seek in flight at a time: a seek asked for meanwhile replaces any earlier waiting one and goes out when the first lands.
    private func requestPlayerSeek(_ target: TimeInterval) {
        guard let t = seekGate.request(target) else { return }
        sendPlayerSeek(t)
    }

    private func sendPlayerSeek(_ t: TimeInterval) {
        let epoch = seekEpoch
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in self?.playerSeekLanded(epoch) }
        }
    }

    private func playerSeekLanded(_ epoch: Int) {
        guard epoch == seekEpoch, let next = seekGate.landed() else { return }
        sendPlayerSeek(next)
    }

    /// Stops playback and gives the audio back. The queue stays, so the next play starts the current track again.
    func stop() {
        finishCurrent()
        clearLoaded()
        isPlaying = false
        position = 0
        refreshBuffering()
        saveNow()
        onReleaseAudio?()
        notifySupport()
    }

    // MARK: volume

    /// Mute, or back to the level before muting. The in-app button and the global hotkey share this.
    func toggleMute() { volume = mute.toggled(from: volume) }

    /// A keyboard or wheel step of five percent of the slider.
    func nudgeVolume(by delta: Float) { volume = MusicVolumeCurve.nudged(volume, by: delta) }

    // MARK: effects

    /// Applies tempo, pitch and reverb as one unit. Anything invalid, or a failure while rebuilding the chain, leaves the previous
    /// settings in place. Tempo is refused in a listening room.
    func setEffects(_ new: MusicEffectSettings) throws {
        try new.validate()
        if inRoom, new.speed != 1 { throw MusicEffectError.tempoLockedInRoom }
        guard new != effects else { return }
        effectsNotice = nil
        if currentLoad != nil, !usingOpus {
            if new.needsEngine || equalizer.needsEngine {
                if usingEngine { try engine?.apply(new) } else { try switchToEngine(new) }
            } else if usingEngine {
                switchToPlayer(settings: new)
            }
        }
        effects = new
        applyRate()
        if currentLoad != nil { queueChanged() }
        publishNow(force: true)
        saveSoon()
    }

    func setTempo(_ t: Double) throws { var s = effects; s.speed = MusicEffectSettings.snappedSpeed(t); try setEffects(s) }
    func setPitch(_ semitones: Int) throws {
        var s = effects; s.semitones = min(12, max(-12, semitones)); try setEffects(s)
    }
    /// Applies the equalizer, tone pad and widening as one unit and saves them. A failure puts the previous values back.
    func setEqualizer(_ new: MusicEqualizerSettings) throws {
        try new.validate()
        guard new != equalizer else { return }
        let previous = equalizer
        effectsNotice = nil
        if currentLoad != nil, !usingOpus {
            if new.needsEngine {
                if usingEngine { try engine?.applyEqualizer(new) }
                else {
                    equalizer = new
                    do { try switchToEngine(effects) } catch { equalizer = previous; throw error }
                }
            } else if usingEngine && !effects.needsEngine {
                equalizer = new
                switchToPlayer(settings: effects)
            } else if usingEngine {
                try engine?.applyEqualizer(new)
            }
        }
        equalizer = new
        var p = library.settings.player
        p.equalizer = new
        MusicDeviceAudioProfiles.shared.store(new, for: audioProfileUID)
        library.settings.player = p
        if currentLoad != nil { queueChanged() }
    }

    /// Changes the Automix switch, style or strength and saves it.
    func setAutomix(_ new: MusicAutomixSettings) {
        guard new != library.settings.player.automix else { return }
        var p = library.settings.player
        p.automix = new
        library.settings.player = p
        if !new.enabled { dropMix(); adviceNow = .useDefault }
        if currentLoad != nil { queueChanged() }
    }

    func resetEffects() { try? setEffects(inRoom ? MusicEffectSettings.original.inRoom() : .original) }

    private func applyRate() {
        let r = Float(effects.speed) * rate
        player.defaultRate = r
        secondary.defaultRate = r
        if isPlaying && !usingEngine { player.rate = r }
        for l in [currentLoad, nextLoad].compactMap({ $0 }) { l.item.audioTimePitchAlgorithm = effects.speed == 1 ? .timeDomain : .spectral }
    }

    private func engineInstance() -> MusicEffectsEngine {
        if let e = engine { return e }
        let e = MusicEffectsEngine()
        e.onFinished = { [weak self] token in self?.engineFinished(token) }
        e.onFailed = { [weak self] token, why in self?.engineFailed(token, why) }
        engine = e
        #if os(macOS)
        if let uid = outputs.currentUID { outputChangeAt = Date(); _ = e.setOutputDevice(uid: uid) }
        #endif
        return e
    }

    private func startEngine(_ l: Loaded, at start: TimeInterval, settings: MusicEffectSettings) throws {
        guard let asset = l.item.asset as? AVURLAsset else { throw MusicEffectError.engineFailed("this stream cannot go through the effects") }
        try engineInstance().start(asset: asset, at: start, settings: settings, equalizer: equalizer, gainDB: gainDB, volume: MusicVolumeCurve.amplitude(slider: Double(volume)),
                                   playing: isPlaying, token: generation)
        if visualizerOn { engine?.setVisualizerTap(true) }
    }

    /// Hands the playing track from AVPlayer to the engine at the same position. The old path is stopped only after the new one is running.
    private func switchToEngine(_ s: MusicEffectSettings) throws {
        guard let l = currentLoad, !usingOpus else { return }
        cancelFade()
        let at = livePosition
        dropPreload()
        try startEngine(l, at: at, settings: s)
        player.pause(); player.removeAllItems()
        usingEngine = true
        stopTicking()
        if isPlaying { startTicking() }
    }

    private func switchToPlayer(settings s: MusicEffectSettings) {
        guard let l = currentLoad else { return }
        let at = engine?.position ?? position
        engine?.stop()
        engineTick?.cancel(); engineTick = nil
        usingEngine = false
        player.removeAllItems()
        player.insert(l.item, after: nil)
        l.item.audioTimePitchAlgorithm = s.speed == 1 ? .timeDomain : .spectral
        player.seek(to: CMTime(seconds: at, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        applyVolume()
        applyGain(gainDB, ramp: false)
        let r = Float(s.speed) * rate
        player.defaultRate = r
        if isPlaying { player.play(); player.rate = r; startTicking() }
    }

    private func restartEngine(at t: TimeInterval) {
        guard let l = currentLoad else { return }
        generation += 1
        do { try startEngine(l, at: t, settings: effects) } catch { engineFailed(generation, error.localizedDescription) }
    }

    private func opusInstance() -> MusicOpusPlayback {
        if let o = opus { return o }
        let o = MusicOpusPlayback()
        o.onFinished = { [weak self] token in self?.opusFinished(token) }
        o.onFailed = { [weak self] token, why in self?.opusFailed(token, why) }
        o.onBufferingChanged = { [weak self] token, waiting in
            guard let self, self.usingOpus, token == self.generation else { return }
            self.setWaiting(waiting)
        }
        o.onDuration = { [weak self] token, seconds in
            guard let self, self.usingOpus, token == self.generation, seconds > 0 else { return }
            self.duration = self.adoptReportedLength(seconds)
        }
        opus = o
        #if os(macOS)
        if let uid = outputs.currentUID { outputChangeAt = Date(); _ = o.setOutputDevice(uid: uid) }
        #endif
        return o
    }

    private func startOpus(_ l: Loaded, source: MusicOpusByteSource, at start: TimeInterval) {
        opusInstance().start(source: source, at: start, volume: MusicVolumeCurve.amplitude(slider: Double(volume)), gainDB: gainDB, playing: isPlaying, token: generation)
        if visualizerOn { opus?.setVisualizerTap(true) }
    }

    private func opusFinished(_ token: Int) {
        guard usingOpus, token == generation, currentLoad != nil else { return }
        trackEnded()
    }

    /// The Opus backend could not play the stream: the same ladder as any failed stream, so the next candidate is tried.
    private func opusFailed(_ token: Int, _ why: String) {
        guard usingOpus, token == generation, let cur = currentLoad, let entry = q.current, entry.id == cur.entryID else { return }
        opus?.stop()
        usingOpus = false
        handleFailure(entry, error: nil, message: why, resolveFailure: false, stage: .opus)
    }

    /// The system player refused a stream that turns out to be WebM or Ogg Opus: the Opus backend takes it over at the same spot.
    private func rescueWithOpus(_ entry: MusicQueue.Entry, loaded: Loaded, message: String) -> Bool {
        guard !usingOpus, MusicOpusRouting.isAvailable, let stream = loaded.stream, !opusRescued.contains(loaded.track.uid),
              let source = MusicOpusRouting.source(for: stream) else { return false }
        opusRescued.insert(loaded.track.uid)
        let gen = generation
        let at = position
        Task { [weak self] in
            let kind = await MusicOpusRouting.sniff(source)
            guard let self, gen == self.generation, let cur = self.currentLoad, cur.entryID == entry.id else { return }
            guard kind == .webm || kind == .ogg else {
                self.handleFailure(entry, error: nil, message: message, resolveFailure: false)
                return
            }
            var l = cur
            l.opusSource = source
            self.player.pause()
            self.player.removeAllItems()
            self.itemObservations[ObjectIdentifier(cur.item)] = nil
            self.currentLoad = l
            self.stopTicking()
            self.startOpus(l, source: source, at: at)
            self.usingEngine = true
            self.usingOpus = true
            if self.isPlaying { self.startTicking() }
            self.refreshBuffering()
        }
        return true
    }

    private func engineFinished(_ token: Int) {
        guard usingEngine, token == generation, currentLoad != nil else { return }
        trackEnded()
    }

    private func engineFailed(_ token: Int, _ why: String) {
        guard usingEngine, token == generation else { return }
        // Fall back to plain playback at the same spot rather than lose the song.
        let notice = Localized.string("The audio effects could not start (%@). Playing without them.", why)
        effectsNotice = notice
        showNotice(notice)
        equalizer = MusicEqualizerSettings()
        let plain = MusicEffectSettings(speed: effects.speed)
        switchToPlayer(settings: plain)
        effects = plain
        applyRate()
    }

    // MARK: Now Playing and remote commands

    /// Called by the shell with the artwork it loaded for a track (so this class does no image work).
    func setNowPlayingArtwork(_ art: MPMediaItemArtwork?, forTrack uid: String) {
        // A late result for a track the person already skipped must not replace the current track's artwork.
        guard uid == current?.uid else { return }
        artwork = art; artworkUID = uid
        publishNow(force: true)
    }

    var nowPlayingInfo: [String: Any]? {
        guard let t = current else { return nil }
        var d: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artistLine,
            MPMediaItemPropertyAlbumTitle: t.album?.title ?? "",
            // The system always sees speed 1; position and length are in listening seconds so its clock matches what is heard.
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, listeningPosition),
        ]
        if duration > 0 { d[MPMediaItemPropertyPlaybackDuration] = listeningDuration }
        if let artwork, artworkUID == t.uid { d[MPMediaItemPropertyArtwork] = artwork }
        return d
    }

    var remoteSupport: RemoteCommandSupport {
        guard current != nil else { return .none }
        // A room guest follows the host: media keys and lock-screen controls do nothing here, as the on-screen transport is locked.
        if isRoomGuest { return .none }
        var set: Set<RemoteCommandKind> = [.play, .pause, .toggle, .seek, .previous]
        if q.hasNext || canAutoplay { set.insert(.next) }
        return RemoteCommandSupport(enabled: set)
    }

    func remoteOwnershipChanged(isOwner: Bool) { if isOwner { publishNow(force: true) } }

    func handleRemote(_ event: RemoteCommandEvent) -> RemoteCommandResult {
        guard current != nil, !isRoomGuest else { return .noActionable }
        // A system "next" or "previous" (a media key, headphones, a lock screen) that arrives twice within a moment is one press repeated by the device, not two wishes: the second one
        // is dropped, so a stray repeat never walks the queue back a song.
        if event.kind == .next || event.kind == .previous {
            let now = Date()
            if let last = lastRemoteSkip[event.kind], now.timeIntervalSince(last) < Self.remoteSkipRepeatWindow {
                let kind = event.kind
                MusicDebugLog.log("queue", "system \(kind) repeated within the repeat window: ignored")
                return .success
            }
            lastRemoteSkip[event.kind] = now
            let pos = Int(listeningPosition), name = current?.title ?? "?", kind = event.kind
            MusicDebugLog.log("queue", "system \(kind) command at \(pos) s of \(name)")
        }
        switch event.kind {
        case .play:
            // An outside "play" right after a local press of pause is that press echoed back, not a new wish.
            if pressEcho.isEcho(wantsPlaying: true, at: clock()) { return .success }
            resume(); pressEcho.pressed(playing: true, at: clock(), remote: true)
        case .pause:
            if pressEcho.isEcho(wantsPlaying: false, at: clock()) { return .success }
            pause(); pressEcho.pressed(playing: false, at: clock(), remote: true)
        case .toggle: toggle()
        case .next: next()
        case .previous: previous()
        case .seek: if let t = event.position { seekListening(to: t) }
        case .skipForward: skip(listeningSeconds: event.interval ?? 10)
        case .skipBackward: skip(listeningSeconds: -(event.interval ?? 10))
        }
        return .success
    }

    // MARK: starting a track

    /// True when the "stop after" row was skipped over: it is not the playing row and it sits at or before it, so it can never be reached again.
    static func stopAfterIsStale(stopID: UUID?, currentID: UUID?, rowIDs: [UUID], currentIndex: Int?) -> Bool {
        guard let stopID, stopID != currentID else { return false }
        guard let at = rowIDs.firstIndex(of: stopID) else { return true }
        guard let ci = currentIndex else { return false }
        return at <= ci
    }

    /// Seconds within which an identical system next or previous counts as the device repeating one press. Short, so two real presses are never merged.
    static let remoteSkipRepeatWindow: TimeInterval = 0.15

    /// Where a newly started song begins: the saved place of a long recording (when `resume`), else the custom start or the intro to skip. 0 is the top.
    private func plannedStart(for track: MusicTrack, resume: Bool = true) -> (at: TimeInterval, resumed: Bool) {
        if resume, !MusicPrivateListening.shared.isOn, let saved = library.resumePosition(for: track, duration: track.duration) { return (saved, true) }
        return (MusicTrackMarkRules.startPosition(marks.mark(for: track.uid), duration: track.duration) ?? 0, false)
    }

    private func announceResume(at: TimeInterval) { MusicToasts.shared.show(Localized.string("Resuming at %@", MusicTime.clock(at))) }

    /// A song handed over without a normal start (gapless, crossfade, Automix) begins where a normal start would, and its own marks count again.
    private func promotedStart(for track: MusicTrack) -> TimeInterval {
        marksFired = false
        let plan = plannedStart(for: track)
        if plan.resumed { announceResume(at: plan.at) }
        return plan.at
    }

    /// `fromTop` is a new play of the row already loaded (repeat-one, a tap on it): its custom start counts again.
    private func startCurrent(resumeAt: TimeInterval = 0, fromTop: Bool = false) {
        if Self.stopAfterIsStale(stopID: stopAfterEntryID, currentID: q.currentID, rowIDs: q.entries.map(\.id), currentIndex: q.index) { stopAfterEntryID = nil }
        guard !blocked else { isPlaying = false; return }
        cancelLoads()
        stalePause.clear()
        // Blocked tracks are never played: move past them.
        var guardCount = 0
        while let e = q.current, library.isBlacklisted(e.track), guardCount <= q.count {
            guardCount += 1
            if q.advance(auto: false) == nil { break }
        }
        guard let entry = q.current, !library.isBlacklisted(entry.track) else {
            sync()
            error = q.isEmpty ? nil : Localized.string("Every track in the queue is blocked.")
            stop()
            return
        }
        let track = entry.track
        MusicStartTimeline.shared.begin(track.uid)
        proxy.prepare()
        let changed = loadingEntry != entry.id
        if changed { ladder.pointerMoved() }
        loadingEntry = entry.id
        loadingTrack = track
        generation += 1
        gapless.bump()
        let gen = generation
        error = carriedError; carriedError = nil
        offlineTask?.cancel(); offlineStalled = false
        // A long recording starts where it was left; anything else (and every retry or restore, which pass their own place) starts as asked.
        var startAt = resumeAt
        if startAt == 0, changed || fromTop {
            let plan = plannedStart(for: track, resume: changed)
            startAt = plan.at
            if plan.resumed { announceResume(at: plan.at) }
        }
        marksFired = false
        position = startAt
        duration = track.duration
        currentStream = nil
        resolving = true
        isPlaying = true
        audible.reset(); durationSeen = nil
        onClaimAudio?()
        activateSession()
        sync()
        refreshBuffering()
        ensureWatchdog()
        if changed { onCurrentChanged?(track, .picked) }
        loadTask = Task { [weak self] in await self?.load(entry, gen: gen) }
    }

    private func load(_ entry: MusicQueue.Entry, gen: Int) async {
        do {
            let loaded = try await makeLoaded(entry)
            guard gen == generation else { return }
            // `position` is the one place the start is kept: the saved place, a custom start, or a seek made while the song was being looked up.
            install(loaded, resumeAt: position)
        } catch {
            guard gen == generation, (error as? MusicError) != .cancelled, !(error is CancellationError) else { return }
            resolving = false
            handleFailure(entry, error: error, message: error.localizedDescription, resolveFailure: true)
        }
    }

    private func makeLoaded(_ entry: MusicQueue.Entry) async throws -> Loaded {
        let track = entry.track
        if !localBypass.contains(track.uid), let url = downloads?.localURL(for: track) {
            if let source = await localOpusSource(url) {
                return Loaded(item: AVPlayerItem(asset: AVURLAsset(url: url)), entryID: entry.id, track: track, stream: nil, pageURL: track.externalURL, opusSource: source, route: "file")
            }
            return Loaded(item: AVPlayerItem(asset: AVURLAsset(url: url)), entryID: entry.id, track: track, stream: nil, pageURL: track.externalURL, route: "file")
        }
        if let direct = track.directStreams?.first, let u = URL(string: direct.url), u.isFileURL, !FileManager.default.fileExists(atPath: u.path) {
            throw MusicLocalFileMissing(title: track.title)
        }
        let settings = library.settings
        // Music-video mode: only a track the service calls a video, and only while the person has the mode on. A video stream never goes
        // through the audio cache, so a later sound-only play can never pick up a cached picture file.
        let wantsVideo = settings.player.videoMode && track.isVideo == true
        audioCache?.configure(enabled: settings.cacheEnabled, limitMB: settings.cacheLimitMB)
        let key = MusicAudioCache.key(uid: track.uid, quality: effectiveQuality)
        if !wantsVideo, let url = audioCache?.cachedFile(key: key) {
            if let source = await localOpusSource(url) {
                return Loaded(item: AVPlayerItem(asset: AVURLAsset(url: url)), entryID: entry.id, track: track, stream: nil, pageURL: track.externalURL, cacheKey: key, opusSource: source, route: "cache file")
            }
            return Loaded(item: AVPlayerItem(asset: AVURLAsset(url: url)), entryID: entry.id, track: track, stream: nil, pageURL: track.externalURL, cacheKey: key, route: "cache file")
        }
        let stream = try await resolver.resolve(track, quality: effectiveQuality, wantsVideo: wantsVideo)
        guard let url = URL(string: stream.url) else { throw MusicError.noPlayableSource(track.title) }
        if let source = await opusSource(for: stream) {
            return Loaded(item: AVPlayerItem(asset: AVURLAsset(url: url)), entryID: entry.id, track: track, stream: stream,
                          pageURL: resolver.pageURL(for: track), opusSource: source, route: "opus")
        }
        var options: [String: Any] = [:]
        // Progressive streams that need headers, caching or bounded range fetching go through the loopback proxy; HLS, live streams and
        // anything behind the person's own proxy are played directly.
        let wantsCache = settings.cacheEnabled && audioCache != nil && !(wantsVideo && stream.hasVideo == true)
        let bypass = MusicProxyChunker.shouldBypass(proto: stream.proto, url: url, userProxyActive: userProxyActive())
        if !bypass, !proxyBypass.contains(track.uid), !stream.headers.isEmpty || wantsCache || MusicProxyChunker.throttlesOpenRanges(url),
           let local = await proxy.register(stream, url: url, cacheKey: wantsCache ? key : nil, cache: audioCache, timelineKey: track.uid) {
            return Loaded(item: AVPlayerItem(asset: AVURLAsset(url: local)), entryID: entry.id, track: track, stream: stream,
                          pageURL: resolver.pageURL(for: track), cacheKey: wantsCache ? key : nil, route: "proxy")
        }
        // Direct play (the proxy is off, failed its self-test or failed once for this song): the same headers the proxy would have sent.
        let directHeaders = MusicProxyPolicy.headers(for: url, base: stream.headers)
        if !directHeaders.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = directHeaders }
        if stream.proto == .hls { options["AVURLAssetOutOfBandMIMETypeKey"] = "application/x-mpegURL" }
        let asset = AVURLAsset(url: url, options: options.isEmpty ? nil : options)
        return Loaded(item: AVPlayerItem(asset: asset), entryID: entry.id, track: track, stream: stream, pageURL: resolver.pageURL(for: track), route: url.isFileURL ? "file" : "direct")
    }

    /// The Opus backend's byte source when this stream is WebM or Ogg: by what the stream says it is, or by its first bytes when it says nothing.
    private func opusSource(for stream: MusicStream) async -> MusicOpusByteSource? {
        guard MusicOpusRouting.isAvailable, stream.proto == .progressive, stream.hasVideo != true || MusicOpusRouting.declaresOpusContainer(stream),
              let source = MusicOpusRouting.source(for: stream) else { return nil }
        if MusicOpusRouting.declaresOpusContainer(stream) { return source }
        guard MusicOpusRouting.needsSniff(stream) else { return nil }
        let kind = await MusicOpusRouting.sniff(source)
        return kind == .webm || kind == .ogg ? source : nil
    }

    /// A downloaded or cached file in WebM or Ogg goes to the Opus backend; its first bytes decide.
    private func localOpusSource(_ url: URL) async -> MusicOpusByteSource? {
        guard MusicOpusRouting.isAvailable, url.isFileURL else { return nil }
        let source = MusicOpusFileSource(url: url)
        let kind = await MusicOpusRouting.sniff(source)
        return kind == .webm || kind == .ogg ? source : nil
    }

    /// The place the last installed song was started at (tests read it).
    @ObservationIgnored private(set) var installedStart: TimeInterval?
    /// The queue row the listen being counted belongs to, and how much of it had been heard when the sound now playing was loaded.
    @ObservationIgnored private var listenRow: UUID?
    @ObservationIgnored private var loadHeardBase: Int64 = 0
    /// How long the sound loaded now has been heard (a reload of the same row starts this again; the listen itself keeps counting).
    private var heardThisLoadMs: Int64 { max(0, playedMs - loadHeardBase) }

    private func install(_ loaded: Loaded, resumeAt: TimeInterval) {
        installedStart = resumeAt
        // A reload of the same row (retry, stale pause, offline, a fresh address) is the same listen: what was heard is kept and "started" is not reported twice.
        if listenRow != loaded.entryID { finishCurrent(); playedMs = 0; reportedTrack = nil; listenRow = loaded.entryID }
        loadHeardBase = playedMs
        resolving = false
        outputs.start()
        clearFailureMark(loaded.track.uid)
        player.removeAllItems()
        secondary.pause(); secondary.removeAllItems()
        currentLoad = loaded
        currentStream = loaded.stream
        loaded.item.audioTimePitchAlgorithm = effects.speed == 1 ? .timeDomain : .spectral
        beginNormalisation(for: loaded, ramp: false)
        usingEngine = false
        usingOpus = false
        if let source = loaded.opusSource {
            startOpus(loaded, source: source, at: resumeAt)
            usingEngine = true
            usingOpus = true
        } else if (effects.needsEngine || equalizer.needsEngine) && !MusicListeningModes.profile.bypassesSignalProcessing {
            do {
                try startEngine(loaded, at: resumeAt, settings: effects)
                usingEngine = true
            } catch {
                effectsNotice = Localized.string("The audio effects could not start (%@). Playing without them.", error.localizedDescription)
                effects = MusicEffectSettings(speed: effects.speed)
                equalizer = MusicEqualizerSettings()
            }
        }
        if !usingEngine {
            // The first seconds start as soon as the item can play and keep a short lead; the normal settings return once it has played a while.
            MusicFastStart.apply(item: loaded.item, player: player)
            fastStartItem = loaded.item
            player.insert(loaded.item, after: nil)
            observe(loaded.item)
            if visualizerOn { attachVisualizerMix(to: loaded.item) }
            applyVolume()
            applyRate()
            if resumeAt > 0 {
                loaded.item.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
            }
        }
        lastTick = nil
        endlessWatchdog.reset()
        primeBudget = MusicPrimeBudget()
        if isPlaying {
            if !usingEngine { player.play() }
            startTicking()
            reportStartIfNeeded()
        }
        loadSegments(for: loaded)
        resetKaraoke()
        scheduleUpgrade(for: loaded)
        refreshBuffering()
        publishNow(force: true)
        notifySupport()
        // The lookahead is primed right now, not near the end, so the next stream URL is ready for the whole track.
        queueChanged()
        topUpAutoplay()
    }

    // MARK: track end, failure, advance

    private func itemEnded(_ id: ObjectIdentifier) {
        guard !usingEngine, let cur = currentLoad, ObjectIdentifier(cur.item) == id else { return }
        // The growing instrumental file reached the end of what was written: carry on from the original, not to the next song.
        if karaokeItem == id, karaokePlaying == .instrumentalStream { karaokeLeftBehind(); return }
        trackEnded()
    }

    /// The sleep timer's end-of-track mode uses the stop-after mark, so playback ends at the song's end with no lookahead leaking in.
    func armStopAfterCurrentSong() -> Bool {
        guard !isRoomGuest, let id = q.currentID, stopAfterEntryID != id else { return false }
        toggleStopAfterCurrent()
        return true
    }
    func disarmStopAfterCurrentSong() {
        guard let id = q.currentID, stopAfterEntryID == id else { return }
        toggleStopAfterCurrent()
    }

    /// Stops playback after the song that is playing now, or takes that back. The next song waits, not played.
    func toggleStopAfterCurrent() {
        guard let e = q.current else { return }
        setStopAfter(e)
    }

    /// Stops playback after the queue row `entryID` has played (any row from the playing one on), or takes that back.
    func toggleStopAfter(entryID: UUID) {
        guard !isRoomGuest, let e = q.entries.first(where: { $0.id == entryID }) else { return }
        setStopAfter(e)
    }

    private func setStopAfter(_ e: MusicQueue.Entry) {
        let t = e.track
        stopAfterEntryID = stopAfterEntryID == e.id ? nil : e.id
        let on = stopAfterEntryID != nil
        // A lookahead already inside the queue player would begin the next song before the end-of-track handler runs: drop it now, and prime again when the mark is cleared.
        dropPreload(); queueChanged()
        MusicDebugLog.log("queue", "stop after \(t.title): \(on)")
        MusicToasts.shared.show(on ? Localized.string("Playback will stop after %@.", t.title) : Localized.string("Playback will continue after %@.", t.title))
    }

    /// A long recording remembers where it was left (every 15 seconds while it plays, and when it is paused), so playing it again carries on from there.
    private func rememberPlace() {
        guard let t = current, !MusicPrivateListening.shared.isOn else { return }
        library.rememberResume(t, position: position, duration: duration)
        lastResumeSave = Date()
    }

    /// The playing file finished by itself (AVPlayer or engine), or a custom end mark was reached.
    private func trackEnded() {
        let endName = current?.title ?? "?", endPos = Int(position), endDur = Int(duration)
        MusicDebugLog.log("queue", "track ended: \(endName) at \(endPos) s of \(endDur) s")
        if let t = current { library.forgetResume(t) }      // played to its end: next time it starts from the beginning
        finishedPlays += 1
        // An asked-for stop wins over repeat one: the song is not looped again, and the mark is cleared (the toast said playback would stop).
        if let s = stopAfterEntryID, s == q.currentID {
            stopAfterEntryID = nil
            MusicDebugLog.log("queue", "stopped after \(endName) as asked")
            dropPreload(); finishCurrent()
            _ = q.advance(auto: true)      // the next song becomes the current one and waits
            endOfQueue()
            return
        }
        // Crossfade and Automix keep the next song on the second player. When no mix or fade ran (a custom end mark, a stream that ended early, a trimmed end), hand over in 50 ms instead of reloading it.
        if primedForCrossfade, nextReady, fadeTask == nil, !usingEngine, q.repeatMode != .one,
           let n = nextLoad, q.peekNext()?.id == n.entryID, !library.isBlacklisted(n.track) {
            startCrossfade(ramp: 0.05)
            return
        }
        finishCurrent()
        let promoted = nextLoad
        nextLoad = nil; nextReady = false
        if q.repeatMode == .one {
            dropPreload(); startCurrent(fromTop: true); return
        }
        guard let e = q.advance(auto: true) else {
            dropPreload()
            // No row follows: one more try at endless playback; when it adds rows the first one starts. A custom end must not play on meanwhile.
            if canAutoplay { player.pause(); engine?.pause(); opus?.pause(); topUpAutoplay(force: true, thenAdvance: true, endedAtTail: true) } else { endOfQueue() }
            return
        }
        ladder.pointerMoved()
        if let p = promoted, !usingEngine, p.entryID == e.id, !library.isBlacklisted(e.track), player.currentItem === p.item {
            // A gapless advance: the lookahead was already playing; only the bookkeeping moves.
            gapless.invalidate()
            currentLoad = p; currentStream = p.stream
            clearFailureMark(p.track.uid)
            beginNormalisation(for: p, ramp: true)
            loadingEntry = e.id; loadingTrack = p.track
            let begin = promotedStart(for: p.track)
            error = nil; position = begin; duration = p.track.duration
            lastTick = nil; playedMs = 0; loadHeardBase = 0; reportedTrack = nil; listenRow = e.id
            seekEpoch += 1; seekGate.reset()
            // The lookahead was placed there when it was primed; this covers a mark or a saved place that appeared since.
            if begin > 0, !(player.currentTime().seconds >= begin - 1) { requestPlayerSeek(begin) }
            sync()
            reportStartIfNeeded()
            loadSegments(for: p)
            resetKaraoke()
            scheduleUpgrade(for: p)
            publishNow(force: true)
            onCurrentChanged?(p.track, .gapless)
            primeBudget = MusicPrimeBudget()
            queueChanged()
            topUpAutoplay()
        } else {
            gapless.invalidate()
            if let p = promoted { player.remove(p.item); itemObservations[ObjectIdentifier(p.item)] = nil }
            if library.isBlacklisted(e.track) { advance(auto: false) } else { sync(); startCurrent() }
        }
    }

    private func itemFailed(_ id: ObjectIdentifier, message: String, cause: NSError? = nil) {
        if let n = nextLoad, ObjectIdentifier(n.item) == id {
            // The lookahead could not open: no skip, no message and no mark on its row (it has not been played). Every copy of its address is
            // dropped, so the normal start of this track later is a fresh lookup; the failure is only written to the diagnostics.
            if fadeTask == nil { secondary.removeAllItems() }
            player.remove(n.item); itemObservations[id] = nil; nextLoad = nil; nextReady = false
            resolver.evict(n.track, stream: n.stream)
            gapless.invalidate()
            recordFailureDetail(stage: primedForCrossfade ? .priming : .preload, track: n.track, load: n, error: cause,
                                reason: MusicPlaybackMessages.reason(error: nil, message: message, title: n.track.title),
                                decision: "dropped the lookahead; the row is not marked and loads normally when it is reached")
            return
        }
        guard let cur = currentLoad, ObjectIdentifier(cur.item) == id, let entry = q.current, entry.id == cur.entryID else { return }
        if karaokeItem == id { karaokeLeftBehind(); return }
        if rescueWithOpus(entry, loaded: cur, message: message) { return }
        lastItemError = cause
        handleFailure(entry, error: nil, message: message, resolveFailure: false)
    }

    /// The system error behind the last failed item, kept for the failure log (the ladder itself works from the message).
    @ObservationIgnored private var lastItemError: NSError?
    /// Entries whose success (three seconds heard) was already reported to the resolver.
    @ObservationIgnored private var successNoted: UUID?

    /// Writes one detailed, redacted failure into the playback log: where it failed, the error codes, the host kind and a short address hash,
    /// how far into the song, the network state, the route, whether the address came from a cache and how old it was, and what the ladder did.
    private func recordFailureDetail(stage: MusicFailureStage, track t: MusicTrack, load: Loaded?, error: Error?, reason: String, decision: String?) {
        let cause: (chain: String, status: Int?)? = (error ?? (lastItemError as Error?)).map { MusicErrorChain.describe($0) }
        let stream = load?.stream
        var trace: MusicUpstreamTrace?
        if let stream, let tr = MusicUpstreamTrace.latest(for: t.uid), tr.addressHash == MusicRedaction.shortHash(stream.url) { trace = tr }
        var window: String?
        if let f = trace?.lastFailure { window = "offset \(f.offset)" + (f.length.map { ", \($0) bytes" } ?? "") }
        let age = stream.flatMap { MusicStreamExpiry.estimatedAge(of: $0, now: Date()) }
        let record = MusicFailureRecord(
            at: Date(), track: t.title, provider: resolver.servedProviderName(for: t) ?? t.providerID, stage: stage, reason: reason,
            errorChain: cause?.chain ?? trace?.lastFailure?.errorChain, httpStatus: trace?.lastFailure?.status ?? cause?.status, window: window,
            client: stream.flatMap { MusicRedaction.client($0.url) }, hostClass: stream.map { MusicRedaction.hostClass($0.url) },
            addressHash: stream.map { MusicRedaction.shortHash($0.url) }, secondsIn: stage == .resolve ? nil : max(0, position),
            network: online ? "online" : "offline", route: load?.route,
            fromCache: stream == nil ? nil : (resolver.wasServedFromCache(t) || (age ?? 0) > 30), cacheAgeSeconds: age,
            decision: decision, hypothesis: trace?.hypothesis ?? stream.flatMap { resolver.lateReason(for: $0.url) })
        MusicPlaybackLog.shared.recordFailure(record)
    }

    /// False on a metered link; set by the app shell. While false no stream lookups are made ahead of a press.
    @ObservationIgnored var preResolveAllowed: @MainActor () -> Bool = { !MusicListeningModes.profile.noPreloading }
    @ObservationIgnored private lazy var preResolver = MusicPreResolver(allowed: { [weak self] in
        guard let self else { return false }
        return !self.blocked && self.preResolveAllowed()
    }, warm: { [weak self] track in
        await self?.warmStream(track)
    })

    private func warmStream(_ track: MusicTrack) async {
        let q = effectiveQuality
        _ = try? await resolver.resolve(track, quality: q)
    }

    /// The top few search results, or the row under the pointer: their streams are looked up now so pressing play starts at once. Bounded and
    /// cancelled by the next hint (see `MusicPreResolver`).
    func preResolve(_ tracks: [MusicTrack]) { preResolver.hint(tracks) }
    /// The page that asked has gone away: lookups that have not finished are cancelled.
    func cancelPreResolve() { preResolver.cancelAll() }

    /// A cached copy or a download that would not play is not trusted again by the retry: the cache entry is removed and a download is
    /// bypassed for this song, so the retry streams a fresh copy instead of opening the same broken file.
    private func dropFailedLocalCopy(_ load: Loaded?, track t: MusicTrack) {
        guard let load, load.stream == nil else { return }
        if let key = load.cacheKey { audioCache?.evict(key: key) }
        else if load.route == "file", downloads?.localURL(for: t) != nil { localBypass.insert(t.uid); if localBypass.count > 100 { localBypass = [t.uid] } }
    }
    @ObservationIgnored private var localBypass: Set<String> = []

    /// The rest of the stream check (middle and tail of the file) failed after the song started: carry on from another address at this position.
    /// Once per queue row, so a song with no good address cannot loop.
    @ObservationIgnored private var lateSwaps = MusicLateSwapGate()
    private func lateRejected(_ t: MusicTrack, _ s: MusicStream) {
        // A lookahead that was already loaded with the refused address is dropped, so it is looked up again when it is reached.
        if let n = nextLoad, n.track.uid == t.uid, n.stream?.url == s.url {
            dropPreload()
            recordFailureDetail(stage: .lateRejection, track: t, load: n, error: nil, reason: resolver.lateReason(for: s.url) ?? Localized.string("The rest of the stream could not be read"),
                                decision: "dropped the lookahead; not marked")
            return
        }
        guard let cur = currentLoad, cur.track.uid == t.uid, cur.stream?.url == s.url else { return }
        let first = lateSwaps.allow(uid: t.uid, row: cur.entryID)
        recordFailureDetail(stage: .lateRejection, track: t, load: cur, error: nil, reason: resolver.lateReason(for: s.url) ?? Localized.string("The rest of the stream could not be read"),
                            decision: first ? "swap to a fresh address at the same position (once per song)" : "already swapped once; keeps playing")
        guard first else { return }
        let paused = !isPlaying
        startCurrent(resumeAt: position)
        if paused { pause() }   // a fresh address is not a press of play
    }

    private func itemReady(_ id: ObjectIdentifier) {
        if let c = currentLoad, ObjectIdentifier(c.item) == id { MusicStartTimeline.shared.mark(c.track.uid, .itemReady) }
        if let n = nextLoad, ObjectIdentifier(n.item) == id { nextReady = true }
    }

    /// A stream or a resolve failed. What happens depends on what the failure means: see `MusicFailureLadder`.
    private func handleFailure(_ entry: MusicQueue.Entry, error err: Error?, message: String, resolveFailure: Bool, stage: MusicFailureStage? = nil) {
        guard q.current?.id == entry.id else { return }
        defer { lastItemError = nil }
        let t = entry.track
        // The load that belongs to this row (a resolve that failed while the previous song was still loaded has none).
        let load = currentLoad?.entryID == entry.id ? currentLoad : nil
        let kind = err.map(MusicFailureKind.classify) ?? .thisTrack
        // A guest does not retry or skip on its own: the room re-syncs it.
        if isRoomGuest {
            // The room re-syncs a guest, so nothing is retried here; the address is dropped so the re-sync is a fresh lookup, and the failure is logged.
            resolver.evict(t, stream: load?.stream)
            recordFailureDetail(stage: resolveFailure ? .resolve : .playerItem, track: t, load: load, error: err,
                                reason: MusicPlaybackMessages.reason(error: err, message: message, title: t.title), decision: "guest waits for the room to re-sync")
            finishCurrent(); clearLoaded(); isPlaying = false
            error = Localized.string("Couldn't play %1$@. %2$@", t.title, message)
            refreshBuffering(); publishNow(force: true)
            return
        }
        // Under repeat-all a failure at the tail wraps to the first playable row; the queue stops only when none is left.
        pruneFailureMarks()
        let playable = q.entries.map { !library.isBlacklisted($0.track) && !failedUIDs.contains($0.track.uid) }
        let atTail = (q.index ?? 0) >= q.count - 1 && !MusicWrapRule.wraps(repeatMode: q.repeatMode, current: q.index ?? 0, playable: playable)
        let permanent = resolveFailure && MusicUnplayableMemory.shared.verdict(videoID: t.videoID ?? t.id) != nil
        var retryAfter: TimeInterval?
        if case .rateLimited(let r)? = err as? MusicError { retryAfter = r }
        let action = ladder.decide(kind, row: entry.id, title: t.title, resolveFailure: resolveFailure, atTail: atTail, permanent: permanent, retryAfter: retryAfter)
        let proxyRefused = load?.route == "proxy" && MusicUpstreamTrace.latest(for: t.uid)?.lastFailure != nil
        let inferred: MusicFailureStage = resolveFailure ? .resolve : (heardThisLoadMs >= 3000 ? .stall : (proxyRefused ? .proxy : .playerItem))
        let failedStage: MusicFailureStage = stage ?? inferred
        recordFailureDetail(stage: failedStage, track: t, load: load, error: err, reason: MusicPlaybackMessages.reason(error: err, message: message, title: t.title),
                            decision: action.logName + (permanent ? " (permanent verdict)" : ""))
        // A person who paused while this was loading stays paused, whatever the recovery loads next.
        let pausedByPerson = !isPlaying
        defer { if pausedByPerson, isPlaying { pause() } }
        switch action {
        case .retry:
            // A song that failed through the loopback proxy is tried once more by playing its address directly.
            if proxyBypass.count > 200 { proxyBypass.removeAll() }
            proxyBypass.insert(t.uid)
            // The stream that failed is not offered again, so the retry tries the next candidate or provider.
            if let failed = load?.stream { resolver.reportFailure(t, stream: failed, reason: MusicPlaybackMessages.reason(error: err, message: message, title: t.title)) }
            else { dropFailedLocalCopy(load, track: t) }
            resolver.evict(t, stream: load?.stream)
            let at = position
            let resume = duration > 0 && at > 1 && at < duration ? at : 0
            startCurrent(resumeAt: resume)
        case .skip:
            finishCurrent()
            carriedError = nil
            // The reason is recorded and shown before the queue moves on, and the row stays marked.
            let why = MusicPlaybackMessages.reason(error: err, message: message, title: t.title)
            markFailed(t.uid, reason: why)
            if let s = load?.stream { resolver.reportFailure(t, stream: s, reason: why) }
            else { MusicPlaybackLog.shared.record(track: t.title, provider: nil, reason: why) }
            let text = MusicPlaybackMessages.skippedWithReason(title: t.title, reason: why)
            // An autoplay row or a suggestion the person never chose fails quietly: it is skipped, dropped, and the tail is topped up.
            let quiet = entry.auto || entry.suggested
            if !quiet { showNotice(text); MusicToasts.shared.error(text) }
            advance(auto: false)
            if quiet, let k = q.entries.firstIndex(where: { $0.id == entry.id }) { q.remove(at: k); queueEdited(startedEmpty: false) }
        case .stay:
            resolver.evict(t, stream: load?.stream)
            stopWithError(Localized.string("Couldn't play %1$@. %2$@", t.title, MusicPlaybackMessages.reason(error: err, message: message, title: t.title)))
            offlineStalled = true
            scheduleOfflineRetry()
        case .holdForDevice:
            handleAudioDeviceLost()
        case .waitAndRetry(let delay, let announce):
            // The source said "busy": the same song again after a growing wait, never skipped. It is the same listen, so nothing is reported finished.
            carriedError = nil
            let at = position
            let resume = duration > 0 && at > 1 && at < duration ? at : 0
            clearLoaded()
            isPlaying = true
            setWaiting(true)
            if announce { MusicToasts.shared.show(Localized.string(MusicPlaybackMessages.throttledFirst), kind: .info) }
            publishNow(force: true)
            let rowID = entry.id
            throttleTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled, self.q.current?.id == rowID, self.isPlaying else { return }
                self.setWaiting(false)
                self.startCurrent(resumeAt: resume)
            }
        case .holdThrottled(let text), .holdNetworkRefused(let text):
            finishCurrent()
            let why = Localized.string(text)
            MusicPlaybackLog.shared.record(track: t.title, provider: nil, reason: why)
            stopWithError(why)
        case .removeRow(let note):
            finishCurrent()
            showNotice(note)
            let hadFollowing = (q.index ?? 0) < q.count - 1
            let shown = shownRowID
            q.remove(at: q.index ?? 0)
            dropPreload()
            if hadFollowing, q.current != nil { sync(); startCurrent() }
            else { clearLoaded(); isPlaying = false; position = 0; showWaitingRow(replacing: shown); refreshBuffering(); publishNow(force: true); onReleaseAudio?() }
        case .stopSeveral(let text):
            finishCurrent()
            let severalWhy = MusicPlaybackMessages.reason(error: err, message: message, title: t.title)
            markFailed(t.uid, reason: severalWhy)
            MusicPlaybackLog.shared.record(track: t.title, provider: nil, reason: severalWhy)
            MusicToasts.shared.error(Localized.string(text))
            stopWithError(Localized.string(text))
        case .stopWithError:
            finishCurrent()
            let why = MusicPlaybackMessages.reason(error: err, message: message, title: t.title)
            markFailed(t.uid, reason: why)
            MusicPlaybackLog.shared.record(track: t.title, provider: nil, reason: why)
            MusicToasts.shared.error(Localized.string("Couldn't play %1$@: %2$@", t.title, why))
            stopWithError(Localized.string("Couldn't play %1$@. %2$@", t.title, why))
        }
    }

    /// The item's real length against the catalogue length: a recording that is far off is the wrong one, so its stream is marked bad and the next
    /// candidate is tried. This happens once per queue row; a second mismatch is accepted so a catalogue with a wrong length never loops.
    private func checkLoadedDuration(real: TimeInterval) {
        guard let entry = q.current, let load = currentLoad, load.entryID == entry.id, !durationChecked.contains(entry.id) else { return }
        if durationChecked.count > 200 { durationChecked = [] }
        durationChecked.insert(entry.id)
        guard let stream = load.stream, entry.track.isPodcast != true, !isRoomGuest,
              MusicStreamVerifier.durationMismatch(catalogueSeconds: entry.track.duration, actualSeconds: real),
              // The stream says it is as long as the song and only the player's reading is off: the stream is right, nothing to swap.
              !MusicStreamLength.plan(listed: entry.track.duration, reported: real, declared: MusicStreamLength.declaredSeconds(of: stream)).playerMisreads
        else { return }
        resolver.reportFailure(entry.track, stream: stream, reason: "The stream's length does not match the song")
        resolver.invalidate(entry.track)
        recordFailureDetail(stage: .verify, track: entry.track, load: load, error: nil, reason: "The stream's length does not match the song",
                            decision: "try the next candidate (once per row)")
        startCurrent(resumeAt: 0)
    }

    /// The length to show for the playing song when the item reports `reported`: the catalogue length if the item's own is far off it.
    /// The note goes to the playback log only.
    private func adoptReportedLength(_ reported: TimeInterval) -> TimeInterval {
        guard let load = currentLoad, let entry = q.current, load.entryID == entry.id, entry.track.isPodcast != true, !isRoomGuest else { return reported }
        if lengthTrimRow != entry.id {
            lengthTrim.reset(); lengthTrimRow = entry.id
        }
        let shown = lengthTrim.adopt(listed: entry.track.duration, reported: reported, declared: load.stream.flatMap { MusicStreamLength.declaredSeconds(of: $0) })
        if let plan = lengthTrim.plan, plan.endAt != nil, !lengthNoted.contains(entry.id) {
            lengthNoted.insert(entry.id); if lengthNoted.count > 100 { lengthNoted = [entry.id] }
            MusicPlaybackLog.shared.record(track: entry.track.title, provider: nil, reason: "Video is longer than the song; trimmed")
        }
        return shown
    }
    @ObservationIgnored private var lengthNoted: Set<UUID> = []

    private func stopWithError(_ text: String) {
        clearLoaded()
        isPlaying = false
        error = text
        refreshBuffering()
        onReleaseAudio?()
        publishNow(force: true)
    }

    /// The output device vanished (sleep and wake, unplugged, driver restart). This is not a bad stream: nothing is evicted, retried,
    /// skipped or unpaused. The row and position are kept so pressing play carries on.
    func handleAudioDeviceLost() {
        guard current != nil else { return }
        let at = currentLoad != nil ? livePosition : position
        engine?.stop(); engineTick?.cancel(); engineTick = nil
        opus?.stop()
        clearLoaded()
        position = at
        isPlaying = false
        usingEngine = false
        usingOpus = false
        error = Localized.string(MusicPlaybackMessages.deviceLost)
        refreshBuffering()
        publishNow(force: true)
    }

    private func advance(auto: Bool) {
        let advName = current?.title ?? "?", advPos = Int(listeningPosition), advDur = Int(duration), advWhy = auto ? "the song ended or failed" : "asked"
        MusicDebugLog.log("queue", "advance (\(advWhy)) from \(advName) at \(advPos) s of \(advDur) s")
        var auto = auto
        var tries = 0
        while tries <= q.count {
            tries += 1
            let before = q.index ?? -1
            guard let e = q.advance(auto: auto) else { break }
            auto = false
            ladder.pointerMoved()
            // Past the tail (repeat-all) the first playable row is wanted: blocked rows and rows that failed this run are passed over.
            let wrapped = (q.index ?? 0) <= before
            pruneFailureMarks()
            if library.isBlacklisted(e.track) || (wrapped && failedUIDs.contains(e.track.uid)) { continue }
            dropPreload(); sync(); startCurrent(); return
        }
        guard canAutoplay else { endOfQueue(); return }
        // The pointer may have moved over rows that cannot play: while more songs are fetched the bar shows the row the queue is on, with nothing sounding.
        if let l = currentLoad, l.entryID != q.currentID {
            let shown = shownRowID
            clearLoaded(); isPlaying = false; position = 0; refreshBuffering(); showWaitingRow(replacing: shown)
        } else { sync() }
        topUpAutoplay(force: true, thenAdvance: true, endedAtTail: true)
    }

    /// The row the bar is showing.
    private var shownRowID: UUID? { index.flatMap { rows.indices.contains($0) ? rows[$0].id : nil } }

    /// The pointer is on a row that is not loaded: the bar shows that row, waiting, with its own length.
    private func showWaitingRow(replacing shown: UUID?) {
        sync()
        guard q.currentID != shown else { return }
        duration = current?.duration ?? 0
        if let t = current { onCurrentChanged?(t, .restored) }
        publishNow(force: true)
    }

    private func endOfQueue() {
        let shown = shownRowID
        clearLoaded()
        isPlaying = false
        position = 0
        // "Stop after this song" and rows passed over as unplayable move the queue: the bar follows it, so Play starts the song it shows.
        showWaitingRow(replacing: shown)
        refreshBuffering()
        saveNow()
        onReleaseAudio?()
        publishNow(force: true)
        notifySupport()
    }

    /// Reports the finished listen to the library and the scrobbler hook, once per started track.
    private func finishCurrent() {
        guard let t = reportedTrack else { return }
        let ms = playedMs
        reportedTrack = nil; playedMs = 0; loadHeardBase = 0
        if ms >= 10_000, !MusicPrivateListening.shared.isOn { library.recordPlay(t, playedMs: ms) }
        onTrackFinished?(t, ms)
    }

    private func reportStartIfNeeded() {
        guard reportedTrack == nil, let t = currentLoad?.track ?? current else { return }
        reportedTrack = t
        onTrackStarted?(t)
    }

    // MARK: lookahead and crossfade

    private var crossfadeActive: Bool {
        MusicCrossfade.length(setting: library.settings.crossfadeSeconds) > 0 && !inRoom && !usingEngine && !MusicListeningModes.profile.noFades
    }

    /// Automix needs the next song waiting on the second player, as a crossfade does: for a mix, and for the fade-only style so that its end-of-song hand-over does not reload the song.
    private var automixHolds: Bool {
        let a = prefs.automix
        return a.enabled && !inRoom && !usingEngine && effects.speed == 1 && !MusicListeningModes.profile.noFades
    }

    private var holdsNextOnSecondary: Bool { crossfadeActive || automixHolds }

    /// Called after anything that could change what plays next. Drops a stale lookahead, then primes the right one.
    private func queueChanged() {
        if let k = karaoke {
            let ahead = Array(queue.dropFirst((index ?? -1) + 1).prefix(2))
            k.prefetch(current: current, upcoming: ahead, position: position)
        }
        if q.repeatMode == .one || gapless.isStale(nextRowID: q.peekNext()?.id) || (nextLoad != nil && primedForCrossfade != holdsNextOnSecondary) {
            dropPreload()
        }
        primeNext()
    }

    private func queueEdited(startedEmpty: Bool) {
        sync()
        if startedEmpty { startCurrent() } else { queueChanged() }
        topUpAutoplay(); topUpSuggestions()
    }

    private func primeNext() {
        guard currentLoad != nil, !usingEngine, !resolving, nextLoad == nil, !stopsAfterCurrent, let e = q.peekNext(), e.id != q.currentID else { return }
        guard MusicGaplessState.skipReason(repeatMode: q.repeatMode, hasNext: true, currentIsLive: false, nextIsLive: false) == .none,
              !library.isBlacklisted(e.track) else { return }
        // A lookahead that arrives while a fade runs is held: the idle deck is still the one fading out.
        guard fadeTask == nil else { heldPrime = true; return }
        guard let g = gapless.begin(for: e.id) else { return }
        let forFade = holdsNextOnSecondary
        preloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await self.makeLoaded(e)
                self.preloadTask = nil
                // The Opus backend has no lookahead: the next track starts the normal way when this one ends.
                if loaded.opusSource != nil { self.gapless.abandon(e.id); return }
                guard self.gapless.canCommit(generation: g, id: e.id, nextRowID: self.q.peekNext()?.id), self.nextLoad == nil else {
                    self.gapless.abandon(e.id); return
                }
                self.observe(loaded.item)
                loaded.item.audioTimePitchAlgorithm = self.effects.speed == 1 ? .timeDomain : .spectral
                // Placed at its own start now, so a gapless or faded hand-over does not play the part to be skipped.
                let begin = self.plannedStart(for: e.track).at
                if begin > 0 { loaded.item.seek(to: CMTime(seconds: begin, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil) }
                if forFade && self.fadeTask != nil {
                    // A fade is running (for example the karaoke swap): this song was not placed on any player, so it is not kept as the waiting next song.
                    self.gapless.abandon(e.id); return
                }
                if forFade && self.fadeTask == nil {
                    self.secondary.pause(); self.secondary.removeAllItems()
                    self.secondary.volume = 0
                    self.secondary.insert(loaded.item, after: nil)
                    self.secondary.defaultRate = Float(self.effects.speed) * self.rate
                } else if !forFade {
                    self.player.insert(loaded.item, after: self.player.items().last)
                }
                self.nextLoad = loaded
                self.nextReady = false
                self.primedForCrossfade = forFade
                self.gapless.commit(e.id)
                if loaded.item.status == .readyToPlay { self.nextReady = true }
            } catch {
                self.preloadTask = nil
                self.gapless.abandon(e.id)
                guard !(error is CancellationError), (error as? MusicError) != .cancelled, g == self.gapless.generation else { return }
                self.primeFailed(e, error)
            }
        }
    }

    /// The next row could not be resolved ahead of time. Nothing happens to the queue and the row is not marked: a lookahead that failed is
    /// not a song that failed. The row is looked up again, from scratch, when it is reached; only a failure then counts on the ladder.
    private func primeFailed(_ e: MusicQueue.Entry, _ err: Error) {
        recordFailureDetail(stage: holdsNextOnSecondary ? .priming : .preload, track: e.track, load: nil, error: err,
                            reason: MusicPlaybackMessages.reason(error: err, message: err.localizedDescription, title: e.track.title),
                            decision: "kept in the queue; looked up again when it is reached")
    }

    private func dropPreload() {
        if !mixLive { mixReady = nil; mixPreparing = nil }
        preloadTask?.cancel(); preloadTask = nil
        gapless.invalidate()
        heldPrime = false
        if let n = nextLoad {
            player.remove(n.item)
            if fadeTask == nil { secondary.pause(); secondary.removeAllItems() }
            itemObservations[ObjectIdentifier(n.item)] = nil
            nextLoad = nil; nextReady = false
        }
    }

    /// EXPERIMENTAL. Starts the next track on the second player and ramps the two volumes in opposite directions on an equal-power
    /// curve, in 50 ms steps. Used only while crossfade is on and the next track is loaded and ready.
    private func startCrossfade(ramp: Double) {
        guard fadeTask == nil, let n = nextLoad, nextReady, q.peekNext()?.id == n.entryID else { return }
        finishCurrent()
        fadeOutNorm = normFactor
        guard q.advance(auto: true) != nil else { return }
        ladder.pointerMoved()
        let outgoing = player, incoming = secondary
        stopTicking()
        incoming.volume = 0
        incoming.defaultRate = Float(effects.speed) * rate
        let begin = promotedStart(for: n.track)
        if begin > 0, !(n.item.currentTime().seconds >= begin - 1) { n.item.seek(to: CMTime(seconds: begin, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil) }
        if isPlaying { incoming.play() }
        currentLoad = n; nextLoad = nil; nextReady = false; currentStream = n.stream
        clearFailureMark(n.track.uid)
        gapless.invalidate()
        loadingEntry = n.entryID; loadingTrack = n.track
        position = begin; duration = n.track.duration; lastTick = nil; playedMs = 0; loadHeardBase = 0; listenRow = n.entryID
        seekEpoch += 1; seekGate.reset()
        player = incoming; secondary = outgoing
        bindPlayer()
        let incomingRamp = MusicCrossfade.incomingRamp(ramp, incomingDuration: n.track.duration, tempo: effects.speed)
        let steps = MusicCrossfade.steps(for: incomingRamp)
        fadeTask = Task { [weak self] in
            // The first step is taken now so the fade begins as the track changes.
            for s in 1...steps {
                guard let self, !Task.isCancelled else { return }
                let g = MusicCrossfade.gains(step: s, of: steps)
                let amp = MusicVolumeCurve.amplitude(slider: Double(self.volume))
                incoming.volume = amp * self.normFactor * g.incoming
                outgoing.volume = amp * self.fadeOutNorm * g.outgoing
                try? await Task.sleep(nanoseconds: UInt64(MusicCrossfade.stepSeconds * 1_000_000_000))
            }
            guard let self, !Task.isCancelled else { return }
            outgoing.pause(); outgoing.removeAllItems()
            self.fadeTask = nil
            self.applyVolume()
            if self.heldPrime { self.heldPrime = false; self.queueChanged() }
        }
        beginNormalisation(for: n, ramp: false)
        startTicking()
        sync()
        reportStartIfNeeded()
        loadSegments(for: n)
        resetKaraoke()
        scheduleUpgrade(for: n)
        publishNow(force: true)
        onCurrentChanged?(n.track, .gapless)
        primeBudget = MusicPrimeBudget()
        topUpAutoplay()
    }

    /// A pause, seek, skip or new load during a fade: the outgoing track stops at once and the incoming one comes to full volume.
    private func cancelFade() {
        if let abort = mixAbort {
            mixAbort = nil; abort()
            // The abort clears the fade before the mix's own player has started, so the outgoing song on the second player would play on beside the incoming one.
            if fadeTask == nil { secondary.pause(); secondary.removeAllItems(); applyVolume(); if heldPrime { heldPrime = false; queueChanged() }; return }
        }
        guard fadeTask != nil else { return }
        fadeTask?.cancel(); fadeTask = nil
        secondary.pause(); secondary.removeAllItems()
        applyVolume()
        if heldPrime { heldPrime = false; queueChanged() }
    }

    // MARK: Automix

    /// A file on this device that holds a loaded song, or nil when it is only streamed. Analysis and mixing read files, never network streams.
    private func analysisURL(for l: Loaded?) -> URL? {
        guard let l else { return nil }
        if let u = (l.item.asset as? AVURLAsset)?.url, u.isFileURL { return u }
        guard let k = l.cacheKey else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        if let hit = analysisURLMemo[k], now - hit.at < 3 { return hit.url }
        let found = audioCache?.cachedFile(key: k)
        if analysisURLMemo.count > 8 { analysisURLMemo.removeAll() }
        analysisURLMemo[k] = (found, now)
        return found
    }

    private func hostSeconds(_ host: UInt64) -> Double { AVAudioTime.seconds(forHostTime: host) }

    /// Runs on every position tick while Automix is on: asks the advisor what to do about the end of this song, prepares a mix a few
    /// seconds ahead, and starts it when the playhead reaches the plan. Any "no" from the advisor leaves the normal path alone.
    private func automixTick(_ p: TimeInterval) {
        let settings = prefs.automix
        guard settings.enabled, !usingEngine, !inRoom, let cur = currentLoad, !mixLive, fadeTask == nil else {
            adviceNow = .useDefault
            return
        }
        let query = MusicTransitionQuery(current: cur.track, currentURL: analysisURL(for: cur), next: nextLoad?.track, nextURL: analysisURL(for: nextLoad),
                                         position: p, duration: duration, tempo: effects.speed, settings: settings)
        adviceNow = automix.advice(for: query)
        let keys = [cur.cacheKey, nextLoad?.cacheKey].compactMap { $0 }
        if keys != pinnedKeys { pinnedKeys = keys; audioCache?.pinForAnalysis(keys: keys) }

        // Silence after the last note: with no crossfade running, move on at the real end instead of waiting out the file.
        if case .fadeEnd(let end) = adviceNow, !crossfadeActive, duration - end >= 2, p >= end, nextReady, nextLoad != nil, q.repeatMode != .one {
            trackEnded()
            return
        }
        guard case .mix(let plan) = adviceNow, let n = nextLoad, nextReady, isPlaying, q.repeatMode != .one, q.peekNext()?.id == n.entryID,
              mayMix(into: n.track), let outURL = query.currentURL, let inURL = query.nextURL else { return }
        if let r = mixReady, r.entryID == n.entryID, r.plan == plan {
            if livePosition >= plan.outStart - 0.3 { startAutomix(plan, n) }
        } else if mixPreparing != n.entryID, p >= plan.outStart - 15 {
            mixPreparing = n.entryID
            let entry = n.entryID
            Task { [weak self] in
                guard let self else { return }
                let ok = await self.automix.prepareMix(plan, style: settings.style, outgoing: outURL, incoming: inURL)
                guard self.mixPreparing == entry else { return }
                self.mixPreparing = nil
                if ok, self.nextLoad?.entryID == entry { self.mixReady = (plan, entry) }
                else if !ok { self.automix.markFailed(current: cur.track, next: n.track, settings: settings, duration: self.duration) }
            }
        }
    }

    /// The person asked to stop after the playing song (a row's own id, so a second copy does not stop playback).
    private var stopsAfterCurrent: Bool { stopAfterEntryID != nil && stopAfterEntryID == q.currentID }

    /// A mix hands one song straight into the next from the plan's own cue: never past a "Stop after this song", and never into a song that starts part-way in.
    private func mayMix(into next: MusicTrack) -> Bool { !stopsAfterCurrent && plannedStart(for: next).at == 0 }

    /// Forgets any prepared mix and stops a running one without touching the players (used when everything is being replaced anyway).
    private func dropMix() {
        mixReady = nil; mixPreparing = nil
        if mixLive || mixAbort != nil { automix.abortMix() }
        mixLive = false; mixAbort = nil
    }

    private func startAutomix(_ plan: MusicMixPlan, _ n: Loaded) {
        guard fadeTask == nil, nextReady, q.peekNext()?.id == n.entryID, mayMix(into: n.track) else { return }
        let level = MusicVolumeCurve.amplitude(slider: Double(volume)) * normFactor
        guard let started = automix.beginMix(outgoingPosition: livePosition, outgoingLevel: level) else {
            mixReady = nil
            automix.markFailed(current: current ?? n.track, next: n.track, settings: prefs.automix, duration: duration)
            return
        }
        mixReady = nil; mixPreparing = nil
        finishCurrent()
        fadeOutNorm = normFactor
        guard q.advance(auto: true) != nil else { automix.abortMix(); return }
        ladder.pointerMoved()
        mixLive = true
        stopTicking()
        let outgoing = player, incoming = secondary
        incoming.volume = 0
        incoming.defaultRate = rate
        currentLoad = n; nextLoad = nil; nextReady = false; currentStream = n.stream
        gapless.invalidate()
        loadingEntry = n.entryID; loadingTrack = n.track
        position = plan.inCue; duration = n.track.duration; lastTick = nil; playedMs = 0; loadHeardBase = 0; listenRow = n.entryID
        marksFired = false
        player = incoming; secondary = outgoing
        bindPlayer()
        mixAbort = { [weak self] in self?.abortAutomix(plan: plan, started: started) }
        fadeTask = Task { [weak self] in await self?.runAutomix(plan: plan, started: started, outgoing: outgoing, incoming: incoming) }
        beginNormalisation(for: n, ramp: false)
        sync()
        reportStartIfNeeded()
        loadSegments(for: n)
        resetKaraoke()
        scheduleUpgrade(for: n)
        publishNow(force: true)
        onCurrentChanged?(n.track, .gapless)
        primeBudget = MusicPrimeBudget()
        topUpAutoplay()
    }

    /// The mix itself, on the main actor: the renderer carries the sound, this keeps the players in step. The outgoing player goes quiet as
    /// the decks begin; the incoming player is parked at the hand-over point and told to start at an exact host time, so the renderer's
    /// last 40 ms fade out as the player's own sound fades in.
    private func runAutomix(plan: MusicMixPlan, started: MusicAutomixRenderer.Started, outgoing: AVQueuePlayer, incoming: AVQueuePlayer) async {
        incoming.automaticallyWaitsToMinimizeStalling = false
        let target = CMTime(seconds: plan.handoverMedia, preferredTimescale: 600)
        _ = await incoming.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        guard !Task.isCancelled else { return }
        let ready = await incoming.preroll(atRate: 1)
        guard !Task.isCancelled else { return }
        let startAt = started.handoverHost
        guard ready, hostSeconds(startAt) - hostSeconds(mach_absolute_time()) > 0.05 else {
            // Too late to schedule the hand-over precisely: let the normal path take over from where the decks are.
            if let abort = mixAbort { mixAbort = nil; abort() }
            fadeTask = nil
            // The outgoing player was left playing by the mix start: silence it, or both songs would sound together.
            outgoing.pause(); outgoing.removeAllItems()
            applyVolume()
            if heldPrime { heldPrime = false; queueChanged() }
            return
        }
        incoming.setRate(rate, time: target, atHostTime: CMClockMakeHostTimeFromSystemUnits(startAt))
        // Quiet the outgoing player as the decks begin.
        try? await Task.sleep(nanoseconds: UInt64(max(0, hostSeconds(started.startHost) - hostSeconds(mach_absolute_time())) * 1_000_000_000))
        guard !Task.isCancelled else { return }
        for step in stride(from: 2, through: 0, by: -1) {
            outgoing.volume = MusicVolumeCurve.amplitude(slider: Double(volume)) * fadeOutNorm * Float(step) / 3
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        outgoing.pause(); outgoing.removeAllItems()
        guard !Task.isCancelled else { return }
        // Keep the position and lyrics moving while the decks play.
        while hostSeconds(mach_absolute_time()) < hostSeconds(startAt) - 0.02 {
            guard !Task.isCancelled else { return }
            let t = hostSeconds(mach_absolute_time()) - hostSeconds(started.startHost) + started.skipped
            position = min(plan.handoverMedia, plan.inCue + max(0, t) * plan.inRate)
            publishNow(force: false)
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        try? await Task.sleep(nanoseconds: UInt64(max(0, hostSeconds(startAt) - hostSeconds(mach_absolute_time())) * 1_000_000_000))
        guard !Task.isCancelled else { return }
        // Hand-over: the player's sound fades in over 40 ms while the deck fades out.
        let amp = MusicVolumeCurve.amplitude(slider: Double(volume)) * normFactor
        for step in 1...4 {
            incoming.volume = amp * Float(sin(Double(step) / 4 * Double.pi / 2))
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard !Task.isCancelled else { return }
        mixAbort = nil
        mixLive = false
        fadeTask = nil
        position = max(0, incoming.currentTime().seconds.isFinite ? incoming.currentTime().seconds : plan.handoverMedia)
        lastTick = nil
        applyVolume()
        if isPlaying { startTicking() }
        publishNow(force: true)
        if heldPrime { heldPrime = false; queueChanged() }
    }

    /// A pause, seek, skip or edit during a mix: the decks stop and the incoming player carries on from where the incoming deck had reached.
    private func abortAutomix(plan: MusicMixPlan, started: MusicAutomixRenderer.Started) {
        automix.abortMix()
        mixLive = false
        let elapsed = max(0, hostSeconds(mach_absolute_time()) - hostSeconds(started.startHost) + started.skipped)
        let media = min(plan.handoverMedia, plan.inCue + elapsed * plan.inRate)
        player.pause()
        position = media
        player.seek(to: CMTime(seconds: media, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        fadeTask?.cancel(); fadeTask = nil
        applyVolume()
        lastTick = nil
        if isPlaying { player.play(); startTicking() }
        if heldPrime { heldPrime = false; queueChanged() }
    }

    // MARK: ticking

    private func startTicking() {
        stopTicking()
        if usingEngine {
            engineTick = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard let self, !Task.isCancelled else { return }
                    if self.usingOpus { if let o = self.opus { self.tick(o.position) } }
                    else if let e = self.engine { self.tick(e.position) }
                }
            }
            return
        }
        let owner = player
        // Four times a second: that is how often the bar and the lyrics need the position.
        timeObserver = owner.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated { self?.tick(seconds) }
        }
        timeObserverOwner = owner
    }

    private func stopTicking() {
        if let o = timeObserver { timeObserverOwner?.removeTimeObserver(o) }
        timeObserver = nil; timeObserverOwner = nil
        engineTick?.cancel(); engineTick = nil
    }

    private func tick(_ seconds: TimeInterval) {
        guard isPlaying, seconds.isFinite else { return }
        var p = max(0, seconds)
        if !usingEngine {
            // Reports that were already on their way before a seek are dropped; a report just short of the target shows as the target.
            switch seekGate.report(p) {
            case .ignore: return
            case .resend(let t): sendPlayerSeek(t); return
            case .accept(let shown): p = shown
            }
        }
        if Date().timeIntervalSince(lastResumeSave) > 15 { rememberPlace() }
        if let last = lastTick {
            let d = p - last
            if d > 0, d < 2 { playedMs += Int64(d * 1000) }
        }
        lastTick = p
        position = p
        if applyMarks(p) { return }
        audible.observe(position: p, at: ProcessInfo.processInfo.systemUptime)
        refreshAudible()
        if let l = currentLoad, p > 0.03, !MusicStartTimeline.shared.has(l.track.uid, .firstSound) { MusicStartTimeline.shared.mark(l.track.uid, .firstSound) }
        if let fs = fastStartItem {
            if player.currentItem !== fs { fastStartItem = nil }
            else if MusicFastStart.shouldRelax(playedSeconds: Double(heardThisLoadMs) / 1000, isWaiting: waiting) { MusicFastStart.relax(item: fs, player: player); fastStartItem = nil }
        }
        if !usingEngine, let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 {
            // The length counts only once the item has reported the same value for a second: a fragmented file's first reading can still grow.
            if let seen = durationSeen, abs(seen.value - d) < 0.5 { durationSeen = (d, seen.ticks + 1) } else { durationSeen = (d, 1) }
            if (durationSeen?.ticks ?? 0) >= 4 { checkLoadedDuration(real: d) }
            let shown = adoptReportedLength(d)
            if abs(shown - duration) > 0.5 { duration = shown }
        }
        if heardThisLoadMs >= 3000, ladder.consecutive > 0 { ladder.playbackStarted() }
        if heardThisLoadMs >= 3000, let l = currentLoad, successNoted != l.entryID {
            // Heard for three seconds: whatever was held against this song (marker, parked clients, provider failures, a verdict) is over.
            successNoted = l.entryID
            clearFailureMark(l.track.uid)
            resolver.noteSuccess(l.track)
        }
        if usingOpus, let d = opus?.duration, d > 0 {
            let shown = adoptReportedLength(d)
            if abs(shown - duration) > 0.5 { duration = shown }
        }
        // A stream that runs past the song (a long video, a player that reads the length twice) ends at the song's length, and the queue moves on.
        if lengthTrim.shouldEnd(position: p), lengthTrimRow == q.current?.id { trackEnded(); return }

        if library.settings.skipNonMusicSegments, !usingEngine, Date().timeIntervalSince(lastUserSeek) > 4,
           let seg = skipSegments.first(where: { $0.contains(p) }) {
            player.seek(to: CMTime(seconds: seg.end, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            lastTick = nil
            publishNow(force: true)
        }
        karaokeTick(p)
        if holdsNextOnSecondary != primedForCrossfade, nextLoad != nil { queueChanged() }
        automixTick(p)
        if duration > 0 {
            let gate = MusicCrossfadeGate(enabled: crossfadeActive, nextReady: nextReady, fadeRunning: fadeTask != nil,
                                          repeatOne: q.repeatMode == .one, paused: !isPlaying, live: false, inRoom: inRoom)
            // With Automix on, a song that ends in silence fades at its real end, and a pair with a mix plan is left to the mix.
            var fadeLength = duration
            var mixOwnsIt = false
            switch adviceNow {
            case .fadeEnd(let end) where end < duration - 0.5: fadeLength = end
            case .mix: mixOwnsIt = nextLoad.map { mayMix(into: $0.track) } ?? false
            default: break
            }
            // A song the person asked to stop after must not be faded into the next one.
            if gate.canStart, !mixOwnsIt, !stopsAfterCurrent, let ramp = MusicCrossfade.rampLength(setting: library.settings.crossfadeSeconds, position: p, duration: fadeLength, tempo: effects.speed) {
                startCrossfade(ramp: ramp)
            }
        }
        if abs(p - lastSavedPosition) >= Self.saveEvery { saveNow() }
        publishNow(force: false)
        topUpAutoplay(); topUpSuggestions()
    }

    // MARK: endless playback

    private func cancelEndless() {
        endlessGeneration += 1
        endlessTask?.cancel(); endlessTask = nil
        endlessGate.finish()
        autoplayWantsAdvance = false; autoplayEndedAtTail = false
    }

    private var canAutoplay: Bool {
        library.settings.consentDone && library.settings.endlessPlayback && !isRoomGuest && q.repeatMode == .off && registry?.activeMetadata != nil
    }

    /// The queue ran dry and autoplay found nothing: one more try after a short wait, then the queue ends without a message.
    private func autoplayDry() {
        guard endlessWatchdog.shouldRetry() else { endOfQueue(); return }
        let epoch = q.epoch
        endlessRetry?.cancel()
        endlessRetry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(MusicEmptyQueueWatchdog.retryDelay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.q.epoch == epoch else { return }
            self.endlessRetry = nil
            self.topUpAutoplay(force: true, thenAdvance: true, endedAtTail: true)
        }
    }

    private func scheduleAutoplayRetry() {
        guard let delay = endlessGate.retryDelay else { return }
        let epoch = q.epoch
        endlessRetry?.cancel()
        endlessRetry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.q.epoch == epoch else { return }
            self.endlessRetry = nil
            self.topUpAutoplay()
        }
    }

    /// Fetches more music when two rows or fewer remain. Called after every track start, at the end of a track, on Skip at the tail, after
    /// un-shuffle and when the switch turns on. It does nothing unless every guard passes; failures never touch playback.
    private func topUpAutoplay(force: Bool = false, thenAdvance: Bool = false, endedAtTail: Bool = false) {
        func giveUp() { if endedAtTail { endOfQueue() } }
        // Nothing is fetched before the person has agreed to the sources, whatever the switch says.
        guard library.settings.consentDone, library.settings.endlessPlayback, !isRoomGuest, q.repeatMode == .off, q.current != nil, let last = q.entries.last,
              q.wantsAutoplay(enabled: true, isGuest: false, hydrating: false), let registry, let provider = registry.activeMetadata else { giveUp(); return }
        if thenAdvance { autoplayWantsAdvance = true }
        if endedAtTail { autoplayEndedAtTail = true }
        if force { endlessGate.reset() }
        guard endlessGate.shouldFetch(enabled: true, repeatOff: true, isTail: true, tailKey: last.id) else {
            if endedAtTail, !endlessGate.inFlight { autoplayEndedAtTail = false; giveUp() }
            return
        }
        endlessGate.begin(last.id)
        let gen = endlessGeneration
        let epoch = q.epoch
        // The smart autoplay engine picks the songs: graph bands first, then the provider's radio, then the library; language, spacing,
        // history, blocking and version rules are applied by its selector.
        guard let built = makeAutoplayInput(want: MusicAutoplayEngine.wantCount(upcomingAuto: q.upcomingAutoCount)) else { endlessGate.finish(); giveUp(); return }
        let engine = makeAutoplayEngine(provider: provider)
        endlessTask = Task { [weak self] in
            let found = await engine.fetch(built.request, context: built.context)
            guard let self, !Task.isCancelled, gen == self.endlessGeneration else { return }
            self.endlessTask = nil
            self.endlessGate.finish()
            let advance = self.autoplayWantsAdvance, atTail = self.autoplayEndedAtTail
            self.autoplayWantsAdvance = false; self.autoplayEndedAtTail = false
            guard self.q.epoch == epoch, self.library.settings.endlessPlayback else {
                if atTail { if self.q.hasNext { self.cancelFade(); self.finishCurrent(); self.advance(auto: false) } else { self.endOfQueue() } }
                return
            }
            let added = self.q.mergeAutoplayPicks(found)
            guard added > 0 else {
                // Songs the person added while this was fetching still play: the end of the queue is not the end while a row waits.
                if atTail, self.q.hasNext { self.cancelFade(); self.finishCurrent(); self.advance(auto: false); return }
                // Nothing came back: ask the same tail again after a growing wait (3 s, 10 s, 30 s) before giving up.
                self.endlessGate.noteEmpty()
                if atTail { self.autoplayDry() } else { self.scheduleAutoplayRetry() }
                return
            }
            self.q.trimHistory()
            self.sync()
            if advance {
                self.cancelFade(); self.finishCurrent(); self.advance(auto: false)
            } else {
                self.queueChanged()
            }
        }
    }

    // MARK: AVFoundation plumbing

    private func bindPlayer() {
        // `.initial` seeds the flag when the player is (re)bound after a swap. The status is read live inside the main-actor hop, never taken from the
        // KVO thread, so hops that run late or out of order all apply the current value and cannot leave a stale `waiting`.
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.setWaiting(self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
            }
        }
    }

    private func observe(_ item: AVPlayerItem) {
        itemObservations[ObjectIdentifier(item)] = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            let id = ObjectIdentifier(it)
            switch it.status {
            case .failed:
                let message = it.error?.localizedDescription ?? Localized.string("The stream stopped working.")
                let cause = it.error.map { $0 as NSError }
                Task { @MainActor [weak self] in self?.itemFailed(id, message: message, cause: cause) }
            case .readyToPlay:
                Task { @MainActor [weak self] in self?.itemReady(id) }
            default: break
            }
        }
    }

    private func observeSystem() {
        let nc = NotificationCenter.default
        notificationTokens.append(nc.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] n in
            guard let item = n.object as? AVPlayerItem else { return }
            let id = ObjectIdentifier(item)
            MainActor.assumeIsolated { self?.itemEnded(id) }
        })
        notificationTokens.append(nc.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] n in
            guard let item = n.object as? AVPlayerItem else { return }
            let id = ObjectIdentifier(item)
            let cause = n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            let message = cause?.localizedDescription ?? Localized.string("The stream stopped working.")
            MainActor.assumeIsolated { self?.itemFailed(id, message: message, cause: cause) }
        })
        notificationTokens.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            // The output device changed under the effects engine (unplugged, sleep and wake): hold the row, wait for the person.
            MainActor.assumeIsolated {
                // A change this player made itself (choosing an output device) is not a lost device.
                if self?.usingEngine == true, Date().timeIntervalSince(self?.outputChangeAt ?? .distantPast) > 1.5 { self?.handleAudioDeviceLost() }
            }
        })
        #if os(macOS)
        notificationTokens.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resolver.resetNegativeState(); self?.offlineTrigger() }
        })
        #endif
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        notificationTokens.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] n in
            let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionRaw = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                guard let self, let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if type == .began { self.pauseForOtherAudio() }
                else if AVAudioSession.InterruptionOptions(rawValue: optionRaw).contains(.shouldResume) { self.resume() }
            }
        })
        notificationTokens.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] n in
            let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                // Headphones pulled out: stop, as listeners expect.
                if let raw, AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable, self?.prefs.pauseWhenOutputRemoved ?? true { self?.pause() }
            }
        })
        #endif
    }

    #if os(macOS)
    /// Pauses when a Bluetooth or USB output that was playing goes away, unless the person has turned that off. A change the app made itself does not count.
    func startOutputWatch() {
        guard outputWatcher == nil else { return }
        let w = MusicOutputWatcher(onRemoved: { [weak self] in
            guard let self else { return }
            if MusicOutputRemoval.shouldPause(previousWasRemovable: true, previousStillPresent: false, wasPlaying: self.isPlaying,
                                              enabled: self.prefs.pauseWhenOutputRemoved, changedByApp: Date().timeIntervalSince(self.outputChangeAt) < 2) {
                self.pause()
                MusicToasts.shared.show(Localized.string("Paused because the headphones or speaker were disconnected."))
            }
        }, onChanged: { [weak self] uid in self?.outputDeviceChanged(to: uid) })
        outputWatcher = w
        audioProfileUID = MusicCoreAudioOutputs.defaultUID()
        w.start()
    }
    /// The output changed: keep what was set for the old one and bring back what the person set for the new one (when remembering per output is on).
    func outputDeviceChanged(to uid: String?) {
        let profiles = MusicDeviceAudioProfiles.shared
        let old = audioProfileUID
        audioProfileUID = uid
        guard profiles.remembers, old != uid else { return }
        profiles.store(equalizer, for: old)
        if let p = profiles.profile(for: uid), p != equalizer { try? setEqualizer(p) }
    }
    #else
    func startOutputWatch() {}
    #endif

    #if os(macOS)
    /// Points every output of this player at `uid` (nil is the system output). False when the device would not open.
    private func applyOutputDevice(_ uid: String?) -> Bool {
        if let uid, MusicCoreAudioOutputs.deviceID(forUID: uid) == nil { return false }
        outputChangeAt = Date()
        for p in [player, secondary] { p.audioOutputDeviceUniqueID = uid }
        var ok = true
        if let e = engine { ok = e.setOutputDevice(uid: uid) && ok }
        if let o = opus { ok = o.setOutputDevice(uid: uid) && ok }
        if ok { outputDeviceChanged(to: uid ?? MusicCoreAudioOutputs.defaultUID()) }
        return ok
    }
    #endif

    private func activateSession() {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default)
        try? s.setActive(true)
        #endif
    }

    private func setWaiting(_ w: Bool) { waiting = w; refreshBuffering() }

    // MARK: audible clock and stall watchdog

    private struct StartTimeout: Error, LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    private func refreshAudible(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let s = audible.state(wantsToPlay: isPlaying, loading: resolving, buffering: waiting, now: now)
        if s != audioState { audioState = s }
    }

    /// One light loop while something is meant to be playing: keeps `audioState` honest between position reports (a stalled player sends none)
    /// and turns a start or a stall that goes on too long into a notice, then into the failure ladder (another source), with the stage logged.
    private func ensureWatchdog() {
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, !Task.isCancelled else { return }
                if !self.isPlaying || self.q.current == nil { self.watchPhase = nil; self.refreshAudible(); self.watchTask = nil; return }
                self.watchdogStep()
            }
        }
    }

    private func watchdogStep() {
        let now = ProcessInfo.processInfo.systemUptime
        refreshAudible(now: now)
        let heard = heardThisLoadMs > 0
        let phase: MusicStartWatchdog.Phase?
        if resolving { phase = .resolving }
        else if currentLoad != nil, !heard { phase = .awaitingSound }
        else if currentLoad != nil, heard, audioState != .playing { phase = .midSongStall }
        else { phase = nil }
        guard let phase, fadeTask == nil else { watchPhase = nil; return }
        if phase != watchPhase { watchPhase = phase; watchSince = now; watchNoticed = false; return }
        switch MusicStartWatchdog.verdict(phase: phase, elapsed: now - watchSince, noticed: watchNoticed, online: online) {
        case .wait: break
        case .notice(let text): watchNoticed = true; showNotice(Localized.string(text))
        case .fail(let reason):
            guard let entry = q.current else { return }
            watchPhase = nil
            if phase == .resolving { loadTask?.cancel(); resolving = false }
            handleFailure(entry, error: StartTimeout(text: reason), message: reason, resolveFailure: phase == .resolving, stage: phase.stage)
        }
    }

    private func refreshBuffering() {
        let b = isPlaying && (resolving || waiting)
        if b != isBuffering { isBuffering = b }
        refreshAudible()
    }

    // MARK: offline retry

    /// The app's network watch calls this when the connection changes; coming back online restarts a stalled track.
    func networkChanged(online ok: Bool) { if ok { resolver.resetNegativeState(); offlineTrigger() } }

    /// Timer ladder 2, 4, 8, 15, 30 s. Each tick first asks whether the network is back, so the bar does not flip between error and loading.
    private func scheduleOfflineRetry() {
        offlineTask?.cancel()
        guard let delay = offlineLadder.nextDelay() else { return }
        offlineTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.offlineTrigger(fromTimer: true)
        }
    }

    /// Coming back online, the window gaining focus, or a ladder tick.
    private func offlineTrigger(fromTimer: Bool = false) {
        guard offlineStalled, current != nil, !isPlaying, online else {
            if fromTimer, offlineStalled { scheduleOfflineRetry() }
            return
        }
        offlineStalled = false
        offlineTask?.cancel()
        error = nil
        startCurrent(resumeAt: position)
    }

    // MARK: volume and gain

    private func applyVolume() {
        let amp = MusicVolumeCurve.amplitude(slider: Double(volume))
        if usingOpus { opus?.setVolume(amp) } else if usingEngine { engine?.setVolume(amp) }
        if mixLive { automix.setMixLevel(Float(amp * fadeOutNorm)) }   // the decks carry the outgoing song until the hand-over; the incoming player takes its own level then
        guard fadeTask == nil else { return }
        player.volume = amp * normFactor
        secondary.volume = amp * normFactor
    }

    private func persistVolumeSoon() {
        volumeTask?.cancel()
        volumeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(MusicVolumeCurve.persistDelay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            UserDefaults.standard.set(self.volume, forKey: Self.volumeKey)
        }
    }

    // MARK: volume normalisation

    /// Picks the gain for the track that just became current. While the loudness is unknown the baseline alone is used, so a loud track
    /// never starts at full volume; when a measurement arrives the gain eases in.
    private func beginNormalisation(for loaded: Loaded, ramp: Bool) {
        normTask?.cancel(); normTask = nil
        audioCache?.protect(key: loaded.cacheKey)
        guard library.settings.normalizeVolume, !MusicListeningModes.profile.bypassesSignalProcessing else { applyGain(0, ramp: ramp, off: true); return }
        let uid = loaded.track.uid
        applyGain(0, ramp: ramp)
        guard let service = loudness else { return }
        let source = normalisationSource(for: loaded)
        normTask = Task { [weak self] in
            var lufs = await service.known(uid)
            if lufs == nil, let source { lufs = await service.loudness(uid: uid, asset: source) }
            guard let lufs, !Task.isCancelled, let self, self.currentLoad?.track.uid == uid, self.library.settings.normalizeVolume else { return }
            self.applyGain(MusicLoudnessMath.gainDB(loudness: lufs), ramp: true)
        }
    }

    /// Sets the loudness gain of the playing track. Off means no gain at all; a change under 0.05 dB is ignored by the engine path.
    private func applyGain(_ db: Double, ramp: Bool, off: Bool = false) {
        let disabled = off || !library.settings.normalizeVolume
        gainDB = disabled ? 0 : db
        if usingOpus { opus?.setGain(db: gainDB) } else if usingEngine { engine?.setGain(db: gainDB) }
        setNormFactor(disabled ? 1 : MusicLoudnessMath.volumeFactor(gainDB: db), ramp: ramp)
    }

    /// The media to read tags from and measure: a download, a cached file, or the stream itself when it is a plain progressive file.
    private func normalisationSource(for loaded: Loaded) -> AVURLAsset? {
        if let url = downloads?.localURL(for: loaded.track) { return AVURLAsset(url: url) }
        if let key = loaded.cacheKey, let url = audioCache?.cachedFile(key: key) { return AVURLAsset(url: url) }
        guard let s = loaded.stream, s.proto == .progressive, let url = URL(string: s.url) else { return nil }
        let options: [String: Any]? = s.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": s.headers]
        return AVURLAsset(url: url, options: options)
    }

    /// Moves the normalisation factor to its new value in about 150 ms, so a change at a track boundary is not a click.
    private func setNormFactor(_ target: Float, ramp: Bool) {
        normRamp?.cancel(); normRamp = nil
        let start = normFactor
        guard ramp, abs(target - start) > 0.001, fadeTask == nil, !usingEngine else { normFactor = target; applyVolume(); return }
        normRamp = Task { [weak self] in
            for step in 1...8 {
                try? await Task.sleep(nanoseconds: 20_000_000)
                guard !Task.isCancelled, let self else { return }
                self.normFactor = start + (target - start) * Float(step) / 8
                self.applyVolume()
            }
            self?.normRamp = nil
        }
    }

    /// Re-applies normalisation to the track playing now; call it after the setting is switched. The playing track is retuned at once.
    func refreshNormalisation() {
        guard let l = currentLoad else { normFactor = 1; applyVolume(); return }
        beginNormalisation(for: l, ramp: true)
    }

    private func loadSegments(for loaded: Loaded) {
        skipSegments = []
        guard library.settings.skipNonMusicSegments else { return }
        let page = loaded.pageURL
        let skipper = segmentSkipper
        let uid = loaded.track.uid
        Task { [weak self] in
            let found = await skipper.segments(forPageURL: page)
            guard let self, self.currentLoad?.track.uid == uid else { return }
            self.skipSegments = found
        }
    }

    // MARK: state mirror, persistence

    private func cancelLoads() {
        loadTask?.cancel(); loadTask = nil
        throttleTask?.cancel(); throttleTask = nil
        seekEpoch += 1; seekGate.reset()
        if let t = loadingTrack, resolving { resolver.cancel(t) }
        dropMix()
        fadeTask?.cancel(); fadeTask = nil
        resetKaraoke()
        upgradeTask?.cancel(); upgradeTask = nil
        dropPreload()
        stopTicking()
        player.pause()
        secondary.pause(); secondary.removeAllItems()
        if usingEngine { engine?.stop() }
        if usingOpus { opus?.stop(); usingOpus = false }
        applyVolume()
        if let c = currentLoad { itemObservations[ObjectIdentifier(c.item)] = nil }
        currentLoad = nil
        skipSegments = []
        resolving = false
    }

    private func clearLoaded() {
        generation += 1
        cancelLoads()
        normTask?.cancel(); normTask = nil
        audioCache?.protect(key: nil)
        proxy.stop()
        player.removeAllItems()
        currentStream = nil
        lastTick = nil
        usingEngine = false
        usingOpus = false
    }

    private func setShuffleFlag(_ on: Bool) {
        syncingShuffle = true
        shuffle = on
        syncingShuffle = false
    }

    private func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { self?.notice = nil }
        }
    }

    private func sync() {
        q.refreshPendingLap()
        queue = q.tracks
        rows = q.entries
        index = q.index
        let was = current
        current = q.current?.track
        autoAddedIndices = Set(q.entries.enumerated().compactMap { $1.auto ? $0 : nil })
        backTitle = q.backTitle
        sourceName = q.sourceName
        isRadioQueue = q.isRadio
        hasManualRows = q.hasManualUpcoming
        if was != nil, current == nil { onCurrentChanged?(nil, .picked) }
        saveSoon()
        notifySupport()
        publishNow(force: true)
    }

    private func notifySupport() {
        let hasCurrent = current != nil, hasNext = q.hasNext
        guard hasCurrent != lastHadCurrent || hasNext != lastHadNext else { return }
        lastHadCurrent = hasCurrent; lastHadNext = hasNext
        onRemoteSupportChanged?()
    }

    /// Pushes Now Playing. From the position tick it goes out at most once a second and only when the position moved more than two
    /// seconds from the last push, because every push wakes every listener on the system.
    private func publishNow(force: Bool = true) {
        let lp = listeningPosition
        if !force {
            guard Date().timeIntervalSince(lastPushAt) >= 1, abs(lp - lastPushedListening) > 2 else { return }
        }
        guard let info = nowPlayingInfo else { return }
        lastPushAt = Date(); lastPushedListening = lp
        publishNowPlaying?(info, isPlaying)
    }

    private var queueURL: URL { stateDirectory.appendingPathComponent(Self.queueFile) }
    private var indexURL: URL { stateDirectory.appendingPathComponent(Self.indexFile) }

    /// Playing the restored queue on launch, when the person asked for it. The hub calls this once the window is up.
    func playOnStartIfEnabled() {
        guard prefs.playOnStart, current != nil, !isPlaying, !isRoomGuest, online else { return }
        resume()
    }

    /// The queue comes back paused, at the saved track and position.
    private func restore() {
        guard let data = try? Data(contentsOf: queueURL), let snap = try? JSONDecoder().decode(MusicQueue.Snapshot.self, from: data),
              !((snap.rows ?? []).isEmpty && snap.tracks.isEmpty) else { return }
        q = MusicQueue(snapshot: snap)
        // The small index record wins only when it was written for exactly these rows; otherwise the large file's own pointer is used.
        var pos = snap.position
        if let d = try? Data(contentsOf: indexURL), let rec = try? JSONDecoder().decode(MusicQueue.IndexRecord.self, from: d), q.apply(rec) { pos = rec.position }
        // A queue saved by an older build may hold hand-placed rows behind the autoplay rows; they go back in front (after the small record, which names the old rows).
        let repaired = q.repairAutoplayTail()
        syncingShuffle = true; shuffle = q.shuffle; syncingShuffle = false
        syncingRepeat = true; repeatMode = q.repeatMode; syncingRepeat = false
        // The lap shuffler is a closure and is not saved: without it a restarted repeat-all shuffle would replay one order every lap.
        if q.shuffle, repeatMode != .off { installLapShuffler() }
        queue = q.tracks; rows = q.entries; index = q.index; current = q.current?.track
        autoAddedIndices = Set(q.entries.enumerated().compactMap { $1.auto ? $0 : nil })
        backTitle = nil; sourceName = q.sourceName; isRadioQueue = q.isRadio; hasManualRows = q.hasManualUpcoming
        position = max(0, pos)
        duration = current?.duration ?? 0
        lastSavedPosition = position
        lastBlobFingerprint = repaired ? "" : q.fingerprint()
        lastHadCurrent = current != nil; lastHadNext = q.hasNext
        if let c = current { onCurrentChanged?(c, .restored) }
        if repaired { saveSoon() }
    }

    private func saveSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !Task.isCancelled { self?.saveNow() }
        }
    }

    /// The large queue file is rewritten only when its fingerprint changed; the small index record goes out on every save.
    private func saveNow() {
        saveTask?.cancel(); saveTask = nil
        lastSavedPosition = position
        let fp = q.fingerprint()
        let blob: MusicQueue.Snapshot? = fp != lastBlobFingerprint ? q.snapshot(position: position) : nil
        if blob != nil { lastBlobFingerprint = fp }
        let record = q.indexRecord(position: position)
        let big = queueURL, small = indexURL
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: big.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let blob, let data = try? JSONEncoder().encode(blob) { try? data.write(to: big, options: .atomic) }
            if let data = try? JSONEncoder().encode(record) { try? data.write(to: small, options: .atomic) }
        }
    }
}


// MARK: - karaoke and mid-song swaps

extension MusicPlayer {
    private func resetKaraoke() {
        swapTask?.cancel(); swapTask = nil
        if let u = karaokePinned { karaoke?.unpin(u) }
        karaokePinned = nil; karaokeItem = nil; originalAsset = nil
        karaokePlaying = .original; karaokeFallBack = nil
    }

    /// The instrumental item failed or ran out: go back to the original at the same spot, and leave it alone for a moment.
    private func karaokeLeftBehind() {
        karaokeFallBack = Date()
        startKaraokeSwap(.fallBackToOriginal(crossfade: MusicKaraokeSwapPolicy.crossfade))
    }

    /// Asks the swap rule on every position tick; the rule decides, this only carries it out.
    private func karaokeTick(_ p: TimeInterval) {
        guard let k = karaoke, !usingEngine, fadeTask == nil, swapTask == nil, let load = currentLoad else { return }
        let progress = k.progress(for: load.track, position: p)
        let d = MusicKaraokeSwapPolicy.decide(playing: karaokePlaying, progress: progress, lastFallBack: karaokeFallBack)
        if d != .stay { startKaraokeSwap(d) }
    }

    private func startKaraokeSwap(_ d: MusicKaraokeSwapDecision) {
        guard swapTask == nil, let cur = currentLoad, !usingEngine else { return }
        let gen = generation, uid = cur.track.uid
        switch d {
        case .stay:
            return
        case .swapToInstrumental(let url, let finished, let fade):
            let asset = originalAsset ?? cur.item.asset
            swapTask = Task { [weak self] in
                guard let self else { return }
                let item = AVPlayerItem(url: url)
                let ok = await self.swapPlaying(to: item, fade: fade, gen: gen, uid: uid)
                self.swapTask = nil
                guard ok else { self.karaokeFallBack = Date(); return }
                self.originalAsset = asset
                if let old = self.karaokePinned, old != url { self.karaoke?.unpin(old) }
                self.karaoke?.pin(url)
                self.karaokePinned = url
                self.karaokeItem = ObjectIdentifier(item)
                self.karaokePlaying = finished ? .instrumentalFile : .instrumentalStream
            }
        case .fallBackToOriginal(let fade):
            guard let asset = originalAsset else { karaokePlaying = .original; return }
            swapTask = Task { [weak self] in
                guard let self else { return }
                let ok = await self.swapPlaying(to: AVPlayerItem(asset: asset), fade: fade, gen: gen, uid: uid)
                self.swapTask = nil
                guard ok else { return }
                if let u = self.karaokePinned { self.karaoke?.unpin(u) }
                self.karaokePinned = nil; self.karaokeItem = nil
                self.karaokePlaying = .original
                self.karaokeFallBack = Date()
            }
        }
    }

    /// Puts `item` in place of what is playing, at the same position, with a short equal-power crossfade on the second player. False when it
    /// could not be done (paused, another song, the effects engine): the caller leaves things as they were.
    private func swapPlaying(to item: AVPlayerItem, fade: TimeInterval, gen: Int, uid: String) async -> Bool {
        guard !usingEngine, fadeTask == nil, isPlaying, generation == gen, let cur = currentLoad, cur.track.uid == uid else { return false }
        let incoming = secondary, outgoing = player
        incoming.pause(); incoming.removeAllItems()
        incoming.volume = 0
        item.audioTimePitchAlgorithm = cur.item.audioTimePitchAlgorithm
        incoming.insert(item, after: nil)
        let landed = await item.seek(to: outgoing.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        guard landed, !Task.isCancelled, !usingEngine, fadeTask == nil, isPlaying, generation == gen, currentLoad?.track.uid == uid,
              item.status != .failed else { incoming.removeAllItems(); return false }
        dropPreload()
        incoming.defaultRate = Float(effects.speed) * rate
        incoming.setRate(Float(effects.speed) * rate, time: outgoing.currentTime(), atHostTime: .invalid)
        stopTicking()
        itemObservations[ObjectIdentifier(cur.item)] = nil
        currentLoad?.item = item
        player = incoming; secondary = outgoing
        bindPlayer()
        observe(item)
        let steps = max(2, Int((fade / 0.02).rounded()))
        fadeTask = Task { [weak self] in
            for s in 1...steps {
                guard let self, !Task.isCancelled else { return }
                let t = Double(s) / Double(steps)
                let amp = MusicVolumeCurve.amplitude(slider: Double(self.volume)) * self.normFactor
                incoming.volume = amp * Float(sin(t * .pi / 2))
                outgoing.volume = amp * Float(cos(t * .pi / 2))
                try? await Task.sleep(nanoseconds: UInt64(fade / Double(steps) * 1_000_000_000))
            }
            guard let self, !Task.isCancelled else { return }
            outgoing.pause(); outgoing.removeAllItems()
            self.fadeTask = nil
            self.applyVolume()
        }
        startTicking()
        queueChanged()
        return true
    }

    /// After a lossy track starts: asks the other sources once for a clearly better copy and swaps to it, keeping the position. The ask
    /// only happens when the person added at least one source of their own.
    private func scheduleUpgrade(for loaded: Loaded) {
        upgradeTask?.cancel(); upgradeTask = nil
        guard !blocked, let chain = resolver.chain, !chain.store.addons.isEmpty, let stream = loaded.stream,
              !stream.isLossless, stream.hasVideo != true else { return }
        let playing = SourceQuality(stream: stream)
        guard playing.kbps != nil else { return }
        let track = loaded.track, gen = generation
        let quality = effectiveQuality
        let served = resolver.servedBy(track)
        upgradeTask = Task { [weak self] in
            guard let self else { return }
            guard let r = await chain.upgrade(track, playing: playing, servedBy: served, quality: quality),
                  !Task.isCancelled, SourceQuality.worthSwapping(playing: playing, candidate: r.quality),
                  !self.resolver.isKnownBad(r.stream.url), MusicStreamExpiry.isUsable(r.stream, now: Date()),
                  self.karaokePlaying == .original, self.duration - self.position > 8 else { return }
            guard let item = await self.makeItem(for: r.stream) else { return }
            if await self.swapPlaying(to: item, fade: MusicKaraokeSwapPolicy.crossfade, gen: gen, uid: track.uid) {
                self.currentLoad?.stream = r.stream
                self.currentStream = r.stream
            }
        }
    }

    private func makeItem(for stream: MusicStream) async -> AVPlayerItem? {
        guard let url = URL(string: stream.url), !MusicOpusRouting.declaresOpusContainer(stream) else { return nil }
        let bypass = MusicProxyChunker.shouldBypass(proto: stream.proto, url: url, userProxyActive: userProxyActive())
        if !bypass, !stream.headers.isEmpty || MusicProxyChunker.throttlesOpenRanges(url),
           let local = await proxy.register(stream, url: url, cacheKey: nil, cache: nil) {
            return AVPlayerItem(asset: AVURLAsset(url: local))
        }
        var options: [String: Any] = [:]
        let directHeaders = MusicProxyPolicy.headers(for: url, base: stream.headers)
        if !directHeaders.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = directHeaders }
        if stream.proto == .hls { options["AVURLAssetOutOfBandMIMETypeKey"] = "application/x-mpegURL" }
        return AVPlayerItem(asset: AVURLAsset(url: url, options: options.isEmpty ? nil : options))
    }
}
