import Foundation

// The wire format for controlling Music on another device of the same person. Control only: no audio, no files and no tokens ever
// travel here. Every value that arrives from the network is treated as hostile and is checked before it is used.

enum MusicRemoteLimits {
    static let version = 1
    static let serviceType = "_streamsetu-music._tcp"
    /// One frame, ciphertext included. Anything larger closes the connection.
    static let maxFrame = 64 * 1024
    static let commandsPerSecond = 20
    static let maxQueueTracks = 100
    static let maxText = 512
    static let maxName = 64
    static let upNextCount = 5
}

enum MusicRemoteError: Error, Equatable, Sendable {
    case frameTooLarge, emptyFrame, malformed(String), unsupportedVersion, notPaired, pairingClosed, locked, authenticationFailed
    case rateLimited, privateNetworkOnly, closed, timedOut

    /// Plain text for the person.
    var message: String {
        switch self {
        case .frameTooLarge, .emptyFrame, .malformed: "The other device sent something this app does not understand."
        case .unsupportedVersion: "The other device runs a different version of this feature. Update both devices."
        case .notPaired: "This device is not paired. Pair it first with the code shown on the other device."
        case .pairingClosed: "Pairing is not open on the other device. Tap Show pairing code there first."
        case .locked: "Too many wrong codes. Pairing is locked for a while."
        case .authenticationFailed: "The code was wrong, or the other device could not be verified."
        case .rateLimited: "Too many commands too quickly."
        case .privateNetworkOnly: "Only devices on your own network can connect."
        case .closed: "The connection closed."
        case .timedOut: "The other device did not answer."
        }
    }
}

// MARK: Payloads

/// A track as it travels: just enough to show it and to ask the other device to find and play it with its own sources.
struct MusicRemoteTrack: Codable, Hashable, Sendable {
    var providerID: String
    var id: String
    var title: String
    var artist: String
    var album: String?
    var artworkURL: String?
    var durationMs: Int64

    init(providerID: String, id: String, title: String, artist: String, album: String? = nil, artworkURL: String? = nil, durationMs: Int64 = 0) {
        self.providerID = providerID; self.id = id; self.title = title; self.artist = artist
        self.album = album; self.artworkURL = artworkURL; self.durationMs = durationMs
    }

    init(_ t: MusicTrack) {
        self.init(providerID: t.providerID, id: t.id, title: t.title, artist: t.artistLine, album: t.album?.title,
                  artworkURL: MusicRemoteSanitizer.artworkURL(t.thumbnails.best(minSide: 300)), durationMs: t.durationMs)
    }

    /// The track as this device's own player understands it. Streams are never accepted from the network.
    func asTrack() -> MusicTrack {
        let names = artist.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let refs = (names.isEmpty ? [artist] : names).map { MusicArtistRef(id: $0, name: $0) }
        return MusicTrack(id: id, providerID: providerID, title: title, durationMs: max(0, durationMs), artists: refs,
                          album: album.map { MusicAlbumRef(id: $0, title: $0) },
                          thumbnails: artworkURL.map { [MusicThumbnail(url: $0)] } ?? [])
    }
}

/// What a controller may see: the current track, where it is, and a short look at the queue.
struct MusicRemoteState: Codable, Equatable, Sendable {
    var hasTrack: Bool
    var title: String
    var artist: String
    var artworkURL: String?
    var position: Double
    var duration: Double
    var isPlaying: Bool
    var volume: Double
    var queueCount: Int
    var queueIndex: Int?
    var upNext: [String]

    static let idle = MusicRemoteState(hasTrack: false, title: "", artist: "", artworkURL: nil, position: 0, duration: 0, isPlaying: false,
                                       volume: 1, queueCount: 0, queueIndex: nil, upNext: [])

    /// Clamps and trims everything so a hostile peer cannot push odd values into the screen.
    func sanitized() -> MusicRemoteState {
        func finite(_ d: Double, _ hi: Double) -> Double { d.isFinite ? min(hi, max(0, d)) : 0 }
        var s = self
        s.title = MusicRemoteSanitizer.text(title); s.artist = MusicRemoteSanitizer.text(artist)
        s.artworkURL = MusicRemoteSanitizer.artworkURL(artworkURL)
        s.position = finite(position, 86_400); s.duration = finite(duration, 86_400); s.volume = finite(volume, 1)
        s.queueCount = min(max(0, queueCount), 100_000)
        s.queueIndex = queueIndex.flatMap { $0 >= 0 && $0 < 100_000 ? $0 : nil }
        s.upNext = Array(upNext.prefix(MusicRemoteLimits.upNextCount)).map { MusicRemoteSanitizer.text($0) }
        return s
    }
}

enum MusicRemoteCommandKind: String, Codable, Sendable { case play, pause, next, previous, seek, volume, playTrack }

struct MusicRemoteCommand: Codable, Equatable, Sendable {
    var kind: MusicRemoteCommandKind
    var seconds: Double?
    var volume: Double?
    var tracks: [MusicRemoteTrack]?
    var startAt: Int?

    static let play = MusicRemoteCommand(kind: .play)
    static let pause = MusicRemoteCommand(kind: .pause)
    static let next = MusicRemoteCommand(kind: .next)
    static let previous = MusicRemoteCommand(kind: .previous)
    static func seek(_ s: Double) -> MusicRemoteCommand { MusicRemoteCommand(kind: .seek, seconds: s) }
    static func volume(_ v: Double) -> MusicRemoteCommand { MusicRemoteCommand(kind: .volume, volume: v) }
    static func playTrack(_ tracks: [MusicRemoteTrack], startAt: Int = 0) -> MusicRemoteCommand { MusicRemoteCommand(kind: .playTrack, tracks: tracks, startAt: startAt) }

    init(kind: MusicRemoteCommandKind, seconds: Double? = nil, volume: Double? = nil, tracks: [MusicRemoteTrack]? = nil, startAt: Int? = nil) {
        self.kind = kind; self.seconds = seconds; self.volume = volume; self.tracks = tracks; self.startAt = startAt
    }

    /// The command with every field checked and clamped, or an error when a field it needs is missing or absurd.
    func validated() throws -> MusicRemoteCommand {
        switch kind {
        case .play, .pause, .next, .previous:
            return MusicRemoteCommand(kind: kind)
        case .seek:
            guard let s = seconds, s.isFinite, s >= 0, s <= 86_400 else { throw MusicRemoteError.malformed("seek") }
            return .seek(s)
        case .volume:
            guard let v = volume, v.isFinite else { throw MusicRemoteError.malformed("volume") }
            return .volume(min(1, max(0, v)))
        case .playTrack:
            guard let list = tracks, !list.isEmpty, list.count <= MusicRemoteLimits.maxQueueTracks else { throw MusicRemoteError.malformed("queue") }
            var clean: [MusicRemoteTrack] = []
            for t in list {
                guard !t.id.isEmpty, t.id.count <= MusicRemoteLimits.maxText, !t.providerID.isEmpty, t.providerID.count <= 64 else { throw MusicRemoteError.malformed("track") }
                var c = t
                c.title = MusicRemoteSanitizer.text(t.title); c.artist = MusicRemoteSanitizer.text(t.artist)
                c.album = t.album.map { MusicRemoteSanitizer.text($0) }
                c.artworkURL = MusicRemoteSanitizer.artworkURL(t.artworkURL)
                c.durationMs = min(max(0, t.durationMs), 86_400_000)
                clean.append(c)
            }
            let at = min(max(0, startAt ?? 0), clean.count - 1)
            return .playTrack(clean, startAt: at)
        }
    }
}

enum MusicRemoteMessageKind: String, Codable, Sendable { case auth, ready, state, command, error, bye }

/// Everything after the handshake is one of these, sealed with the session key.
struct MusicRemoteMessage: Codable, Equatable, Sendable {
    var v: Int = MusicRemoteLimits.version
    var kind: MusicRemoteMessageKind
    var state: MusicRemoteState?
    var command: MusicRemoteCommand?
    var text: String?

    static let auth = MusicRemoteMessage(kind: .auth)
    static func ready(_ s: MusicRemoteState) -> MusicRemoteMessage { MusicRemoteMessage(kind: .ready, state: s) }
    static func state(_ s: MusicRemoteState) -> MusicRemoteMessage { MusicRemoteMessage(kind: .state, state: s) }
    static func command(_ c: MusicRemoteCommand) -> MusicRemoteMessage { MusicRemoteMessage(kind: .command, command: c) }
    static func error(_ t: String) -> MusicRemoteMessage { MusicRemoteMessage(kind: .error, text: t) }
    static let bye = MusicRemoteMessage(kind: .bye)

    func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= MusicRemoteLimits.maxFrame - 64 else { throw MusicRemoteError.frameTooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> MusicRemoteMessage {
        guard data.count <= MusicRemoteLimits.maxFrame else { throw MusicRemoteError.frameTooLarge }
        let m: MusicRemoteMessage
        do { m = try JSONDecoder().decode(MusicRemoteMessage.self, from: data) } catch { throw MusicRemoteError.malformed("json") }
        guard m.v == MusicRemoteLimits.version else { throw MusicRemoteError.unsupportedVersion }
        var out = m
        out.state = m.state?.sanitized()
        out.text = m.text.map { MusicRemoteSanitizer.text($0) }
        if let c = m.command { out.command = try c.validated() }
        switch out.kind {
        case .command: guard out.command != nil else { throw MusicRemoteError.malformed("command") }
        case .ready, .state: guard out.state != nil else { throw MusicRemoteError.malformed("state") }
        case .auth, .error, .bye: break
        }
        return out
    }
}

/// The first two frames of a connection travel unsealed: who is calling, a fresh public key and a fresh nonce. The code or paired key is
/// mixed into the session keys, never sent.
struct MusicRemoteHello: Codable, Equatable, Sendable {
    var v: Int = MusicRemoteLimits.version
    var mode: MusicRemoteHandshake.Mode
    var deviceID: String
    var name: String
    var publicKey: Data
    var nonce: Data
    /// Set on a refusal; the other fields are then unused.
    var error: String?

    static func decode(_ data: Data) throws -> MusicRemoteHello {
        guard data.count <= MusicRemoteLimits.maxFrame else { throw MusicRemoteError.frameTooLarge }
        let h: MusicRemoteHello
        do { h = try JSONDecoder().decode(MusicRemoteHello.self, from: data) } catch { throw MusicRemoteError.malformed("hello") }
        guard h.v == MusicRemoteLimits.version else { throw MusicRemoteError.unsupportedVersion }
        if h.error != nil { return h }
        guard !h.deviceID.isEmpty, h.deviceID.count <= MusicRemoteLimits.maxName, h.name.count <= MusicRemoteLimits.maxName,
              h.publicKey.count == 32, h.nonce.count == 16 else { throw MusicRemoteError.malformed("hello fields") }
        return h
    }

    static func refusal(_ e: MusicRemoteError, mode: MusicRemoteHandshake.Mode) -> MusicRemoteHello {
        MusicRemoteHello(mode: mode, deviceID: "-", name: "", publicKey: Data(), nonce: Data(), error: e.message)
    }
}

// MARK: Framing

/// Length-prefixed frames: four bytes big endian, then the body. The limit is checked before any body is buffered.
enum MusicRemoteFraming {
    static func encode(_ body: Data) throws -> Data {
        guard !body.isEmpty else { throw MusicRemoteError.emptyFrame }
        guard body.count <= MusicRemoteLimits.maxFrame else { throw MusicRemoteError.frameTooLarge }
        var out = Data(capacity: 4 + body.count)
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }
}

/// Collects bytes as they arrive and hands back whole frames. A bad length throws, and the caller must close the connection.
struct MusicRemoteFrameBuffer: Sendable {
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0 else { throw MusicRemoteError.emptyFrame }
            guard length <= UInt32(MusicRemoteLimits.maxFrame) else { throw MusicRemoteError.frameTooLarge }
            let total = 4 + Int(length)
            guard buffer.count >= total else { break }
            frames.append(Data(buffer.prefix(total).dropFirst(4)))
            buffer = Data(buffer.dropFirst(total))
        }
        return frames
    }

    var pendingBytes: Int { buffer.count }
}

// MARK: Sanitizing

enum MusicRemoteSanitizer {
    /// Printable text of bounded length: control characters removed.
    static func text(_ s: String) -> String {
        let cleaned = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        return String(cleaned.prefix(MusicRemoteLimits.maxText))
    }

    private static let secretNames = ["token", "key", "sig", "signature", "auth", "secret", "password", "session", "jwt", "credential", "x-amz", "access"]

    /// Only plain web pictures pass: no file or custom schemes, no embedded passwords, no query that looks like a credential.
    static func artworkURL(_ s: String?) -> String? {
        guard let s, s.count <= MusicRemoteLimits.maxText, var c = URLComponents(string: s),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil else { return nil }
        if let items = c.queryItems {
            let risky = items.contains { i in secretNames.contains { i.name.lowercased().contains($0) } }
            if risky { return nil }
        }
        c.fragment = nil
        return c.string
    }
}

// MARK: Rate limit

/// At most `limit` events in any one second. Pure: the caller supplies the clock.
struct MusicRemoteRateLimiter: Sendable {
    let limit: Int
    private var stamps: [TimeInterval] = []
    init(limit: Int = MusicRemoteLimits.commandsPerSecond) { self.limit = limit }

    mutating func allow(at now: TimeInterval) -> Bool {
        stamps.removeAll { now - $0 >= 1 }
        guard stamps.count < limit else { return false }
        stamps.append(now)
        return true
    }
}

// MARK: Addresses

enum MusicRemoteAddress {
    /// True for addresses that cannot be reached from the internet (`MusicNetworkPolicy`).
    static func isPrivate(_ b: [UInt8]) -> Bool { MusicNetworkPolicy.isPrivateAddress(b) }
}

// MARK: What the host needs from a player

/// The small surface the host drives. `MusicPlayer` conforms through `MusicPlayerRemoteAdapter.swift`; tests use a fake.
@MainActor protocol MusicRemoteControllable: AnyObject {
    func remoteSnapshot() -> MusicRemoteState
    func remotePlay()
    func remotePause()
    func remoteNext()
    func remotePrevious()
    func remoteSeek(to seconds: TimeInterval)
    func remoteSetVolume(_ volume: Float)
    func remotePlayQueue(_ tracks: [MusicTrack], startAt: Int)
}

extension MusicRemoteControllable {
    func apply(_ c: MusicRemoteCommand) {
        switch c.kind {
        case .play: remotePlay()
        case .pause: remotePause()
        case .next: remoteNext()
        case .previous: remotePrevious()
        case .seek: if let s = c.seconds { remoteSeek(to: s) }
        case .volume: if let v = c.volume { remoteSetVolume(Float(v)) }
        case .playTrack: if let t = c.tracks { remotePlayQueue(t.map { $0.asTrack() }, startAt: c.startAt ?? 0) }
        }
    }
}
