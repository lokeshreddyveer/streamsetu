import Foundation
import Observation

// Listen Together, as the screens see it. One session is either idle, hosting a room or following one. Nothing runs until the person
// starts a room or joins one, and everything stops when they leave. Every device plays its own audio; only timing information travels.

/// What a room needs from a player. `MusicPlayer` conforms below, through members it already has; tests use a fake.
@MainActor protocol MusicRoomPlayable: AnyObject {
    var roomTrack: MusicTrack? { get }
    var roomCurrentKey: String? { get }
    var roomLivePosition: TimeInterval { get }
    var roomIsPlaying: Bool { get }
    var roomIsBuffering: Bool { get }
    var roomHasFailed: Bool { get }
    var roomQueueWindow: [MusicTrack] { get }
    /// Changes as the player moves, so a host that watches it hears every tick while music plays and nothing while it does not.
    var roomTick: Double { get }
    /// Puts the track in place at a position, and starts it only when `autoplay` is true.
    func roomLoad(_ track: MusicTrack, at position: TimeInterval, autoplay: Bool)
    func roomSeek(to position: TimeInterval)
    func roomSetRate(_ rate: Float)
    func roomPause()
    func roomResume()
    func roomStop()
    func roomEnqueue(_ track: MusicTrack)
}

@MainActor @Observable
final class MusicRoomSession {
    enum Role: Equatable, Sendable { case none, host, guest }

    enum Status: Equatable, Sendable {
        case idle
        case hosting
        case connecting
        case waitingForApproval
        case joined
        /// The host's connection dropped; the song keeps playing for a short while before the room closes.
        case hostConnectionLost
        /// The room ended or the person was turned away. The text says why.
        case ended(String)

        var text: String {
            switch self {
            case .idle: ""
            case .hosting: "Your room is open."
            case .connecting: "Connecting..."
            case .waitingForApproval: "Waiting for the host to let you in."
            case .joined: "You are listening together."
            case .hostConnectionLost: "Lost contact with the host. Your song keeps playing."
            case .ended(let why): why
            }
        }
    }

    static let noSourceText = "No source on this device"

    private(set) var role = Role.none
    private(set) var status = Status.idle
    private(set) var roomName = ""
    private(set) var participants: [MusicRoomParticipant] = []
    /// The host's current song and what is queued after it, as the host described them.
    private(set) var nowPlaying: MusicRoomTrack?
    private(set) var queueWindow: [MusicRoomTrack] = []
    /// Set while this device cannot play the current song ("No source on this device"). The room keeps going without it.
    private(set) var trackNote: String?
    private(set) var suggestionNote: String?
    private(set) var errorMessage: String?
    /// The last clock measurement against the host (offset and network round trip), or nil until the first one finishes. Read-only for screens.
    private(set) var clockSample: MusicRoomClockSample?

    let host: MusicRoomHost
    let discovery: MusicRoomDiscovery
    let deviceName: String

    @ObservationIgnored private let player: any MusicRoomPlayable
    @ObservationIgnored private let hasAudioSource: @MainActor () -> Bool
    @ObservationIgnored private let uptime: @MainActor () -> Double
    @ObservationIgnored private let identity: MusicRoomIdentity
    @ObservationIgnored private var guest: MusicRoomGuest?
    @ObservationIgnored private var latestAnchor: MusicRoomAnchor?
    @ObservationIgnored private var loadedKey: String?
    @ObservationIgnored private var noSource = false
    /// Playback rate used to close a small gap to the host; 1 means in step. Observed so a screen can say "adjusting".
    private var rate: Float = 1
    @ObservationIgnored private var readyTask: Task<Void, Never>?
    @ObservationIgnored private var recheckTask: Task<Void, Never>?
    @ObservationIgnored private var remeasureTask: Task<Void, Never>?
    @ObservationIgnored private var lostTask: Task<Void, Never>?
    @ObservationIgnored private var leaving = false

    init(player: any MusicRoomPlayable, hasAudioSource: @escaping @MainActor () -> Bool,
         store: any MusicRemoteSecretStore = MusicRemoteKeychain(),
         uptime: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        let identity = MusicRoomIdentity(store: store)
        self.identity = identity
        self.player = player
        self.hasAudioSource = hasAudioSource
        self.uptime = uptime
        self.deviceName = MusicRoomIdentity.defaultName()
        self.host = MusicRoomHost(deviceID: { identity.deviceID }, deviceName: MusicRoomIdentity.defaultName(), source: player, uptime: uptime)
        self.discovery = MusicRoomDiscovery(ownDeviceID: { identity.deviceID })
    }

    // MARK: what the screens ask

    var isHosting: Bool { role == .host }
    var isFollowing: Bool { role == .guest && (status == .joined || status == .hostConnectionLost) }

    /// Play, pause and seek follow the host while this device is in a room. Volume stays the person's own.
    var controlsLocked: Bool { isFollowing }

    /// True while this device plays slightly faster or slower to close a small gap to the host.
    var isAdjustingToHost: Bool { rate != 1 }
    static let lockExplanation = "Play, pause and skipping follow the host while you are in a room. Your volume is still yours. Leave the room to control playback yourself."

    // MARK: hosting

    func startRoom() {
        guard role == .none else { return }
        errorMessage = nil
        host.open()
        if host.isOpen { role = .host; status = .hosting } else { errorMessage = host.error ?? "The room could not start." }
    }

    func closeRoom() {
        guard role == .host else { return }
        host.close()
        role = .none
        status = .idle
    }

    // MARK: following

    /// Knocks on a room with its six-digit code. The host still has to approve.
    func join(_ room: MusicPeer, code: String) {
        guard role == .none else { return }
        guard MusicRoomHandshake.normalizedCode(code) != nil else {
            errorMessage = "Enter the 6-digit code shown on the host's screen."
            return
        }
        errorMessage = nil
        resetFollowing()
        let g = MusicRoomGuest(deviceID: identity.deviceID, name: deviceName, uptime: uptime)
        wire(g)
        guest = g
        role = .guest
        status = .connecting
        roomName = room.name
        g.connect(to: room.endpoint, code: code)
    }

    func leave() {
        guard role == .guest else { return }
        leaving = true
        guest?.leave()
        finishFollowing(.idle)
    }

    /// Asks the host to add a song. The host decides.
    @discardableResult
    func suggest(_ track: MusicTrack) -> Bool {
        guard isFollowing, let t = MusicRoomTrack(track).sanitized() else {
            // Every path sets the note, so a caller's toast never shows an earlier answer.
            suggestionNote = Localized.string("This song cannot be suggested to the room.")
            return false
        }
        guest?.suggest(t)
        suggestionNote = Localized.string("Sent to the host. It plays only if the host agrees.")
        return true
    }

    /// Stops everything: the app locked or Music became unavailable.
    func shutDown() {
        closeRoom()
        leave()
        discovery.stop()
    }

    private func wire(_ g: MusicRoomGuest) {
        g.onApprovalPending = { [weak self] in self?.status = .waitingForApproval }
        g.onWelcome = { [weak self] name, roster, queue in
            guard let self else { return }
            self.roomName = name; self.participants = roster; self.queueWindow = queue
            self.status = .joined
        }
        g.onRoster = { [weak self] r in self?.participants = r }
        g.onQueue = { [weak self] q in self?.queueWindow = q }
        g.onAnchor = { [weak self] a in self?.applyAnchor(a) }
        g.onClockUpdated = { [weak self] in
            guard let self else { return }
            self.clockSample = self.guest?.clock.current
            guard let a = self.latestAnchor else { return }
            self.applyAnchor(a)
        }
        g.onSuggestionAnswer = { [weak self] _, approved in
            self?.suggestionNote = approved ? Localized.string("The host added your song.") : Localized.string("The host did not add your song.")
        }
        g.onClosed = { [weak self] reason in self?.guestClosed(reason) }
    }

    private func guestClosed(_ reason: MusicRoomError?) {
        guard role == .guest else { return }
        if leaving { return }
        if status == .joined, reason == nil || reason == .timedOut {
            hostConnectionDropped()
            return
        }
        switch reason {
        case .roomClosed?: finishFollowing(.ended(MusicRoomError.roomClosed.message))
        case .kicked?: finishFollowing(.ended(MusicRoomError.kicked.message))
        case .denied?: finishFollowing(.ended(MusicRoomError.denied.message))
        case let r?: finishFollowing(.ended(r.message))
        case nil: finishFollowing(.ended(MusicRoomError.hostLeft.message))
        }
    }

    /// The line to the host dropped. The current song plays on, and after twenty seconds the room closes with "Host left".
    private func hostConnectionDropped() {
        status = .hostConnectionLost
        recheckTask?.cancel(); remeasureTask?.cancel(); remeasureTask = nil
        lostTask?.cancel()
        lostTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(MusicRoomLimits.hostLostGrace * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finishFollowing(.ended(MusicRoomError.hostLeft.message))
        }
    }

    private func finishFollowing(_ final: Status) {
        readyTask?.cancel(); recheckTask?.cancel(); remeasureTask?.cancel(); lostTask?.cancel()
        readyTask = nil; recheckTask = nil; remeasureTask = nil; lostTask = nil
        if rate != 1 { rate = 1; player.roomSetRate(1) }
        guest = nil
        role = .none
        status = final
        leaving = false
        participants = []; queueWindow = []; nowPlaying = nil; trackNote = nil; latestAnchor = nil; loadedKey = nil; noSource = false
        clockSample = nil
    }

    private func resetFollowing() {
        participants = []; queueWindow = []; nowPlaying = nil; trackNote = nil; suggestionNote = nil
        latestAnchor = nil; loadedKey = nil; noSource = false; rate = 1; leaving = false; clockSample = nil
    }

    // MARK: following the anchors

    private var offset: Double? { guest?.clock.offset }

    /// Where the host is right now, by this device's clock.
    private func expectedNow(_ a: MusicRoomAnchor) -> Double? {
        offset.map { a.expectedPosition(atHostTime: uptime() + $0) }
    }

    private func applyAnchor(_ a: MusicRoomAnchor) {
        guard role == .guest, status == .joined else { return }
        latestAnchor = a
        nowPlaying = a.track
        updateRemeasure(playing: a.isPlaying)
        // Until the clock offset is known there is nothing to compute; the clock calls back here when it is.
        guard offset != nil else { return }
        guard let track = a.track else {
            loadedKey = nil; trackNote = nil; noSource = false
            if player.roomIsPlaying { player.roomPause() }
            return
        }
        if track.key != loadedKey { startLoad(track, a); return }
        if noSource { return }
        reconcile()
    }

    private func startLoad(_ track: MusicRoomTrack, _ a: MusicRoomAnchor) {
        readyTask?.cancel(); recheckTask?.cancel()
        loadedKey = track.key
        noSource = false
        trackNote = nil
        if rate != 1 { rate = 1; player.roomSetRate(1) }
        guard hasAudioSource(), let expected = expectedNow(a) else { markNoSource(); return }
        // Asking the player for this song makes it use this device's own sources: the same provider first, otherwise a match by title,
        // artists and length. A descriptor never carries a stream.
        player.roomLoad(track.asTrack(), at: expected, autoplay: a.isPlaying)
        if a.isPlaying { awaitReady(key: track.key) }
    }

    private func markNoSource() {
        noSource = true
        trackNote = Self.noSourceText
        readyTask?.cancel(); recheckTask?.cancel()
        // The clock keeps running; a later song gets a fresh try.
        if player.roomIsPlaying { player.roomStop() }
    }

    /// One bounded wait for a song to start (up to 25 seconds). It sleeps between looks and ends as soon as the song is ready or failed.
    private func awaitReady(key: String) {
        readyTask?.cancel()
        readyTask = Task { [weak self] in
            for _ in 0..<125 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled, let self, self.loadedKey == key else { return }
                if self.player.roomHasFailed { self.markNoSource(); return }
                if self.player.roomCurrentKey == key, self.player.roomIsPlaying, !self.player.roomIsBuffering {
                    self.afterLoad()
                    return
                }
            }
            if let self, self.loadedKey == key { self.markNoSource() }
        }
    }

    /// The song started later than the moment it was asked for, so it jumps to where the host is now, once.
    private func afterLoad() {
        guard let a = latestAnchor, a.isPlaying, let expected = expectedNow(a) else { return }
        if abs(player.roomLivePosition - expected) > 0.15 { player.roomSeek(to: expected) }
        scheduleRecheck(after: 1.5)
    }

    private func reconcile() {
        guard role == .guest, status == .joined, let a = latestAnchor, let track = a.track, track.key == loadedKey, !noSource,
              let expected = expectedNow(a) else { return }
        guard a.isPlaying else {
            recheckTask?.cancel()
            if rate != 1 { rate = 1; player.roomSetRate(1) }
            if player.roomIsPlaying { player.roomPause() }
            if abs(player.roomLivePosition - a.position) > 0.1 { player.roomSeek(to: a.position) }
            return
        }
        // The host's song is about to end; the next anchor says what comes next.
        if track.duration > 0, expected >= track.duration - 0.25 { return }
        if !player.roomIsPlaying {
            player.roomSeek(to: expected)
            player.roomResume()
            awaitReady(key: track.key)
            return
        }
        // While the song buffers there is nothing to measure; the next anchor looks again.
        if player.roomIsBuffering { return }
        let drift = player.roomLivePosition - expected
        switch MusicRoomSync.decide(drift: drift, currentRate: rate, expected: expected) {
        case .none:
            break
        case .setRate(let r):
            rate = r
            player.roomSetRate(r)
            if r != 1 { scheduleRecheck(after: MusicRoomSync.recheckDelay(forDrift: drift)) }
        case .seek(let to):
            rate = 1
            player.roomSetRate(1)
            player.roomSeek(to: to)
            scheduleRecheck(after: 1.5)
        }
    }

    /// One look later, never a loop: a nudge or a seek is checked once when it should have worked.
    private func scheduleRecheck(after seconds: TimeInterval) {
        recheckTask?.cancel()
        recheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.reconcile()
        }
    }

    /// The clock is measured again once a minute, and only while music plays.
    private func updateRemeasure(playing: Bool) {
        guard playing else { remeasureTask?.cancel(); remeasureTask = nil; return }
        guard remeasureTask == nil else { return }
        remeasureTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(MusicRoomClockEstimator.remeasureInterval * 1_000_000_000))
                guard !Task.isCancelled, let self, self.role == .guest else { return }
                self.guest?.measureClock()
            }
        }
    }
}

/// This device's id for rooms, made once and kept in the Keychain, and a friendly device name. The Keychain is touched only when a room is
/// started or joined.
@MainActor
final class MusicRoomIdentity {
    private let store: any MusicRemoteSecretStore
    private var cached: String?
    private static let account = "room-device-id"

    init(store: any MusicRemoteSecretStore) { self.store = store }

    var deviceID: String {
        if let cached { return cached }
        if let d = store.read(Self.account), let s = String(data: d, encoding: .utf8), !s.isEmpty { cached = s; return s }
        let id = UUID().uuidString
        store.write(Self.account, Data(id.utf8))
        cached = id
        return id
    }

    static func defaultName() -> String {
        var n = ProcessInfo.processInfo.hostName
        if n.hasSuffix(".local") { n = String(n.dropLast(6)) }
        n = MusicRoomSanitizer.text(n, max: MusicRoomLimits.maxName)
        return n.isEmpty ? "StreamSetu Music" : n
    }
}

// MARK: the real player

extension MusicPlayer: MusicRoomPlayable {
    var roomTrack: MusicTrack? { current }
    var roomCurrentKey: String? { current?.uid }
    var roomLivePosition: TimeInterval { livePosition }
    var roomIsPlaying: Bool { isPlaying }
    var roomIsBuffering: Bool { isBuffering }
    var roomHasFailed: Bool { error != nil && !isBuffering }
    var roomTick: Double { position }

    var roomQueueWindow: [MusicTrack] {
        guard let i = index, i >= 0, i < queue.count else { return [] }
        return Array(queue[i...].prefix(MusicRoomLimits.maxQueue))
    }

    /// Loads without playing the first moments from zero: the player is told what to play, stopped before audio starts, moved to the position,
    /// and only then resumed, so it starts at the right second.
    func roomLoad(_ track: MusicTrack, at position: TimeInterval, autoplay: Bool) {
        play([track], startAt: 0)
        stop()
        seek(to: position)
        if autoplay { resume() }
    }

    func roomSeek(to position: TimeInterval) { seek(to: position) }
    func roomSetRate(_ rate: Float) { self.rate = rate }
    func roomPause() { pause() }
    func roomResume() { resume() }
    func roomStop() { stop() }
    func roomEnqueue(_ track: MusicTrack) { enqueue([track]) }
}
