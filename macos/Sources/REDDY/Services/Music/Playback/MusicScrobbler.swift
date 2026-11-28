import Foundation
import Observation

/// Reports listens to the services the person switched on (Last.fm, ListenBrainz, plugins).
/// A listen is sent while the track plays, the moment the accumulated play time (not the playhead) passes the scrobble point (see `ScrobbleThreshold`:
/// the stricter of the configured percent/minutes rule and the 50 % / 180 s rule, never under 30 s), stamped with the time the track started. Every service receives the same cleaned-up track. Playback never waits for any of this.
@MainActor @Observable
final class MusicScrobbler {
    struct Failure: Identifiable, Sendable {
        let id = UUID()
        var provider: String
        var track: String
        var message: String
        var at: Date
    }

    static let maxFailures = 50
    nonisolated static let minimumMs: Int64 = 30_000
    nonisolated static let maximumThresholdMs: Int64 = 4 * 60_000
    /// Waits before the two in-memory retries after a network failure. Nothing is saved to disk.
    nonisolated static let retryDelays: [TimeInterval] = [2, 8]

    private(set) var failures: [Failure] = []
    /// ListenBrainz accepted the token but refuses listens; cleared the first time a listen is accepted.
    private(set) var listenBrainzProblem: ListenBrainzProblem?
    /// Latest outcome per service id, in plain words, for the settings screen.
    private(set) var serviceNotes: [String: String] = [:]

    let configStore: MusicScrobbleConfigStore
    @ObservationIgnored let lastFM: LastFMClient
    @ObservationIgnored let listenBrainz: ListenBrainzClient

    var config: MusicScrobbleConfig { configStore.config }

    /// One play of one track.
    struct Session {
        var track: MusicTrack
        var startedAt: Date
        var playedSeconds: Double = 0
        var lastTick: Date?
        var lastPosition: Double = 0
        var latched = false
        var durationSeconds: Double
    }

    @ObservationIgnored private let registry: MusicRegistry
    @ObservationIgnored private let library: MusicLibrary
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async -> Void
    @ObservationIgnored private(set) var session: Session?
    @ObservationIgnored private weak var player: MusicPlayer?
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    init(registry: MusicRegistry, library: MusicLibrary, defaults: UserDefaults = .standard,
         lastFM: LastFMClient = LastFMClient(), listenBrainz: ListenBrainzClient = ListenBrainzClient(),
         now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.registry = registry
        self.library = library
        self.configStore = MusicScrobbleConfigStore(defaults: defaults)
        self.lastFM = lastFM
        self.listenBrainz = listenBrainz
        self.now = now
        self.sleep = sleep
    }

    /// The scrobble rule on its own with the default settings (50 %, 4 minutes, never under 30 s), so it can be tested.
    nonisolated static func shouldScrobble(playedMs: Int64, durationMs: Int64) -> Bool {
        let fire = ScrobbleThreshold.firePoint(durationSeconds: durationMs > 0 ? Double(durationMs) / 1000 : nil, config: MusicScrobbleConfig())
        guard let fire else { return false }
        return Double(playedMs) / 1000 >= fire
    }

    /// False while the app is locked or a Kids profile is on: nothing is counted or sent.
    var isAllowed = true {
        didSet { if !isAllowed { session = nil; tickTask?.cancel(); tickTask = nil } }
    }
    private var masterOn: Bool { isAllowed && library.settings.scrobbleEnabled }

    // MARK: hooks from the player

    func started(_ t: MusicTrack) {
        session = Session(track: t, startedAt: now(), lastPosition: 0, durationSeconds: t.duration)
        guard masterOn, config.nowPlaying else { return }
        dispatch(.nowPlaying, track: t)
    }

    /// Fallback for hosts that do not call `tick`: counts the finished play if it reached the point while nobody was watching.
    func finished(_ t: MusicTrack, playedMs: Int64) {
        defer { if session?.track.uid == t.uid { session = nil } }
        guard masterOn, let s = session, s.track.uid == t.uid, !s.latched else { return }
        guard let fire = ScrobbleThreshold.firePoint(durationSeconds: t.durationMs > 0 ? t.duration : nil, config: config),
              Double(playedMs) / 1000 >= fire else { return }
        dispatch(.scrobble(s.startedAt), track: t)
    }

    /// Called about once a second while a track plays (position in seconds into the track).
    func tick(position: Double, duration: Double?, isPlaying: Bool, at when: Date? = nil) {
        guard var s = session else { return }
        let at = when ?? now()
        if let d = duration, d > 0 { s.durationSeconds = d }
        if isPlaying, let last = s.lastTick { s.playedSeconds += min(max(0, at.timeIntervalSince(last)), 3) }
        s.lastTick = isPlaying ? at : nil

        // Repeat-one: the position wrapped from near the end to the start, which is a new play.
        if s.durationSeconds > 0, s.lastPosition >= s.durationSeconds - 5, position < 5, s.lastPosition > position + 10 {
            s.startedAt = at; s.playedSeconds = 0; s.latched = false; s.lastTick = isPlaying ? at : nil; s.lastPosition = position
            session = s
            if masterOn, config.nowPlaying { dispatch(.nowPlaying, track: s.track) }
            return
        }
        s.lastPosition = position

        if !s.latched, masterOn, isPlaying,
           let fire = ScrobbleThreshold.firePoint(durationSeconds: s.durationSeconds > 0 ? s.durationSeconds : nil, config: config),
           s.playedSeconds >= fire {
            s.latched = true
            session = s
            dispatch(.scrobble(s.startedAt), track: s.track)
            return
        }
        session = s
    }

    /// The same track with new details (search-started tracks learn their album late): the now-playing line is sent again, the clock is untouched.
    func trackUpdated(_ t: MusicTrack) {
        guard var s = session, s.track.uid == t.uid, s.track != t else { return }
        let hadAlbum = !(s.track.album?.title ?? "").isEmpty
        s.track = t
        session = s
        if !hadAlbum, !(t.album?.title ?? "").isEmpty, masterOn, config.nowPlaying { dispatch(.nowPlaying, track: t) }
    }

    /// Follows the player: ticks once a second while it plays (no timer while paused), and notices a late album.
    func bind(to player: MusicPlayer) {
        self.player = player
        observe()
    }

    private func observe() {
        guard let player else { return }
        let state = withObservationTracking { (player.current, player.isPlaying) } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        if let t = state.0 { trackUpdated(t) }
        if state.1 {
            if tickTask == nil {
                tickTask = Task { [weak self] in
                    while !Task.isCancelled {
                        guard let self, let p = self.player else { return }
                        self.tick(position: p.livePosition, duration: p.duration > 0 ? p.duration : nil, isPlaying: true)
                        await self.sleep(1)
                    }
                }
            }
        } else {
            tickTask?.cancel(); tickTask = nil
            if let p = self.player { tick(position: p.livePosition, duration: nil, isPlaying: false) }
        }
    }

    // MARK: services and preview

    func serviceStates(config override: MusicScrobbleConfig? = nil) -> [ScrobbleServiceState] {
        let cfg = override ?? config
        let on = Set(registry.scrobblers.map(\.id))
        return registry.all.compactMap { $0 as? any MusicScrobbleProvider }.map { p in
            let connected: Bool
            switch p.id {
            case "lastfm": connected = lastFM.isConnected
            case "listenbrainz": connected = listenBrainz.isConnected
            default: connected = true
            }
            return ScrobbleServiceState(id: p.id, name: p.info.name, connected: connected, enabled: on.contains(p.id) && cfg.isServiceEnabled(p.id))
        }
    }

    /// What each service would receive for this track under the given (possibly unsaved) settings, plus the status line.
    /// With no track it previews the built-in sample.
    func preview(for track: MusicTrack?, config override: MusicScrobbleConfig? = nil) -> ScrobblePreview {
        let cfg = override ?? config
        let info = track.map(ScrobbleTrackInfo.init) ?? ScrobblePreviewBuilder.sample
        var live: ScrobbleLiveState?
        if let s = session, s.track.uid == info.uid {
            live = ScrobbleLiveState(positionSeconds: s.playedSeconds, durationSeconds: s.durationSeconds > 0 ? s.durationSeconds : nil)
        }
        return ScrobblePreviewBuilder.build(info: info, config: cfg, masterOn: masterOn, services: serviceStates(config: cfg), live: live)
    }

    // MARK: sending

    private enum Kind { case nowPlaying, scrobble(Date) }

    /// Resolves the cleaned track now (so a rule saved mid-track still applies) and sends it to every active service.
    private func dispatch(_ kind: Kind, track: MusicTrack) {
        var cleaned = MusicTrackCleaner.clean(ScrobbleTrackInfo(track), config.clean)
        guard cleaned.skip == nil else { return }
        // The catalogue's spelling wins over the video's wording, unless the person's own edit rule already decided it.
        if cleaned.editIndex == nil, let c = MusicCatalogNames.canonical(for: track), !c.title.isEmpty {
            cleaned.title = c.title
            if !c.artists.isEmpty { cleaned.artist = c.artists.joined(separator: ", ") }
        }
        let payload = ScrobblePayloadTrack(artist: cleaned.artist, title: cleaned.title, album: cleaned.album, durationMs: track.durationMs,
                                           isrc: track.isrc, originURL: track.providerID == "local" ? nil : track.externalURL)
        var out = track
        out.artists = [MusicArtistRef(id: track.artists.first?.id ?? "", name: cleaned.artist)]
        out.title = cleaned.title
        out.album = cleaned.album.isEmpty ? nil : MusicAlbumRef(id: track.album?.id ?? "", title: cleaned.album)
        let cfg = config
        for p in registry.scrobblers where cfg.isServiceEnabled(p.id) {
            let id = p.id, name = p.info.name
            let send = operation(for: p, kind: kind, payload: payload, cleanedTrack: out)
            if id == "lastfm" || id == "listenbrainz", !(id == "lastfm" ? lastFM.isConnected : listenBrainz.isConnected) { continue }
            let sleep = self.sleep
            Task { [weak self] in
                do {
                    try await Self.retrying(sleep: sleep, send)
                    self?.succeeded(id)
                } catch {
                    self?.failed(id: id, name: name, title: cleaned.title, error: error)
                }
            }
        }
    }

    private func operation(for p: any MusicScrobbleProvider, kind: Kind, payload: ScrobblePayloadTrack, cleanedTrack: MusicTrack) -> @Sendable () async throws -> Void {
        let lastFM = self.lastFM, lb = self.listenBrainz
        switch p.id {
        case "lastfm":
            return {
                switch kind {
                case .nowPlaying: try await lastFM.nowPlaying(artist: payload.artist, title: payload.title, album: payload.album)
                case .scrobble(let start): try await lastFM.scrobble(artist: payload.artist, title: payload.title, album: payload.album, start: start, durationMs: payload.durationMs)
                }
            }
        case "listenbrainz":
            return {
                switch kind {
                case .nowPlaying: try await lb.playingNow(payload)
                case .scrobble(let start): try await lb.listen(payload, start: start)
                }
            }
        default:
            return {
                switch kind {
                case .nowPlaying: await p.nowPlaying(cleanedTrack)
                case .scrobble(let start):
                    do { try await p.scrobble(MusicScrobble(timestamp: start, track: cleanedTrack, playedMs: Int64((Date().timeIntervalSince(start)) * 1000))) }
                    catch let e as MusicError {
                        if case .network(let m) = e { throw ScrobbleSendError.network(m) }
                        if case .notSignedIn = e { throw ScrobbleSendError.signedOut }
                        throw ScrobbleSendError.refused(e.localizedDescription)
                    }
                }
            }
        }
    }

    /// One try plus up to two more after a network failure, with a growing wait. Anything else fails at once. Nothing is stored.
    nonisolated static func retrying(sleep: @Sendable (TimeInterval) async -> Void, delays: [TimeInterval] = retryDelays,
                                     _ op: @Sendable () async throws -> Void) async throws {
        var attempt = 0
        while true {
            do { try await op(); return } catch ScrobbleSendError.network(let m) {
                guard attempt < delays.count else { throw ScrobbleSendError.network(m) }
                await sleep(delays[attempt]); attempt += 1
            }
        }
    }

    private func succeeded(_ id: String) {
        serviceNotes[id] = "Sending."
        if id == "listenbrainz", listenBrainzProblem != nil { listenBrainzProblem = nil }
    }

    private func failed(id: String, name: String, title: String, error: Error) {
        let message = (error as? ScrobbleSendError)?.message ?? error.localizedDescription
        if case ScrobbleSendError.listenBrainz(let p) = error, listenBrainzProblem != p { listenBrainzProblem = p }
        serviceNotes[id] = message
        failures.append(Failure(provider: name, track: title, message: message, at: now()))
        if failures.count > Self.maxFailures { failures.removeFirst(failures.count - Self.maxFailures) }
    }

    /// Connecting or disconnecting ListenBrainz starts from a clean state.
    func resetListenBrainzProblem() { listenBrainzProblem = nil }
}
