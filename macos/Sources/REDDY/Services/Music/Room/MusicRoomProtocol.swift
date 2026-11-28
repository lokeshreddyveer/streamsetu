import Foundation
import CryptoKit

// Listen Together: the wire format. Devices on one local network follow a host's clock; every device streams its own audio, so no audio,
// file or token ever travels here. Everything that arrives is treated as hostile and is checked and trimmed before it is used.

enum MusicRoomLimits {
    static let version = 1
    /// Rooms reuse the Devices Bonjour type and are told apart by a TXT flag, so no new Info.plist entry is needed.
    static let serviceType = MusicRemoteLimits.serviceType
    static let txtFlagKey = "room"
    static let maxGuests = 8
    static let maxQueue = 50
    static let maxFrame = MusicRemoteLimits.maxFrame
    static let messagesPerSecond = 20
    /// The only periodic traffic: the host repeats its anchor so guests can re-check their drift.
    static let heartbeat: TimeInterval = 10
    /// After the host's connection drops, guests keep playing and then give up after this long.
    static let hostLostGrace: TimeInterval = 20
    /// A silent connection (no heartbeat at all) is treated as dropped.
    static let silenceLimit: TimeInterval = 35
    static let strikesToKick = 5
    static let approvalSeconds: TimeInterval = 60
    static let maxText = 200
    static let maxName = 64
    static let maxID = 128
    static let maxArtists = 8
    static let maxURL = 512
    static let maxPendingSuggestions = 20
    static let suggestionsPerGuest = 3
    static let maxDurationMs: Int64 = 86_400_000
}

enum MusicRoomError: Error, Equatable, Sendable {
    case malformed(String), unsupportedVersion, frameTooLarge, authenticationFailed, locked, codeClosed
    case roomClosed, roomFull, denied, kicked, privateNetworkOnly, timedOut, hostLeft

    /// Plain text for the person.
    var message: String {
        switch self {
        case .malformed, .frameTooLarge: "The other device sent something this app does not understand."
        case .unsupportedVersion: "The other device runs a different version of this feature. Update both devices."
        case .authenticationFailed: "The code was wrong, or the room could not be verified."
        case .locked: "Too many wrong codes. This room is locked for a while."
        case .codeClosed: "This room is not accepting new guests right now. Ask the host for a new code."
        case .roomClosed: "The host closed the room."
        case .roomFull: "This room is full."
        case .denied: "The host did not let you in."
        case .kicked: "The host removed you from the room."
        case .privateNetworkOnly: "Only devices on your own network can connect."
        case .timedOut: "The host did not answer."
        case .hostLeft: "Host left"
        }
    }
}

// MARK: Sanitizing

enum MusicRoomSanitizer {
    private static let spoofing: Set<UInt32> = [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0x200E, 0x200F, 0xFEFF]

    /// Printable text of bounded length: control and direction-changing characters removed, edges trimmed.
    static func text(_ s: String, max: Int = MusicRoomLimits.maxText) -> String {
        let kept = String(String.UnicodeScalarView(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !spoofing.contains($0.value) }))
        return String(kept.trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
    }

    /// A provider or track id: unchanged by cleaning, not empty, not too long.
    static func identifier(_ s: String, max: Int = MusicRoomLimits.maxID) -> String? {
        guard !s.isEmpty, s.count <= max, text(s, max: max) == s else { return nil }
        return s
    }

    static func providerID(_ s: String) -> String? {
        guard !s.isEmpty, s.count <= 64, s.unicodeScalars.allSatisfy({ isASCIIAlnum($0) || "._-:".unicodeScalars.contains($0) }) else { return nil }
        return s
    }

    private static let secretNames = ["token", "key", "sig", "signature", "auth", "secret", "password", "session", "jwt", "credential", "x-amz", "access"]

    /// Only plain https pages pass: no other scheme, no embedded password, no query that looks like a credential, no fragment.
    static func httpsURL(_ s: String?) -> String? {
        guard let s, !s.isEmpty, s.count <= MusicRoomLimits.maxURL, text(s, max: MusicRoomLimits.maxURL) == s,
              var c = URLComponents(string: s), c.scheme?.lowercased() == "https",
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil else { return nil }
        if let items = c.queryItems, items.contains(where: { i in secretNames.contains { i.name.lowercased().contains($0) } }) { return nil }
        c.fragment = nil
        return c.string
    }

    /// An ISRC is twelve letters and digits; hyphens are tolerated and removed.
    static func isrc(_ s: String) -> String? {
        let t = s.replacingOccurrences(of: "-", with: "").uppercased()
        guard t.count == 12, t.unicodeScalars.allSatisfy({ isASCIIAlnum($0) }) else { return nil }
        return t
    }

    private static func isASCIIAlnum(_ u: Unicode.Scalar) -> Bool {
        (u.value >= 48 && u.value <= 57) || (u.value >= 65 && u.value <= 90) || (u.value >= 97 && u.value <= 122)
    }

    static func finite(_ d: Double, _ lo: Double, _ hi: Double) -> Double { d.isFinite ? min(hi, max(lo, d)) : lo }
}

// MARK: Track descriptor

/// What a guest needs to find the same recording through its own sources. Streams, stream links and tokens are never part of it.
struct MusicRoomTrack: Codable, Hashable, Sendable {
    var providerID: String
    var id: String
    var title: String
    var artists: [String]
    var album: String?
    var durationMs: Int64
    var isrc: String?
    var externalURL: String?

    var key: String { providerID + ":" + id }
    var duration: TimeInterval { TimeInterval(durationMs) / 1000 }

    init(providerID: String, id: String, title: String, artists: [String], album: String? = nil, durationMs: Int64 = 0, isrc: String? = nil, externalURL: String? = nil) {
        self.providerID = providerID; self.id = id; self.title = title; self.artists = artists; self.album = album
        self.durationMs = durationMs; self.isrc = isrc; self.externalURL = externalURL
    }

    /// From this device's own track. A link that would not pass the receiving checks is simply left out.
    init(_ t: MusicTrack) {
        self.init(providerID: t.providerID, id: t.id, title: t.title, artists: t.artists.map(\.name), album: t.album?.title,
                  durationMs: t.durationMs, isrc: t.isrc.flatMap { MusicRoomSanitizer.isrc($0) }, externalURL: MusicRoomSanitizer.httpsURL(t.externalURL))
    }

    /// The cleaned descriptor, or nil when anything the receiver relies on is malformed.
    func sanitized() -> MusicRoomTrack? {
        guard let pid = MusicRoomSanitizer.providerID(providerID), let tid = MusicRoomSanitizer.identifier(id) else { return nil }
        let t = MusicRoomSanitizer.text(title)
        guard !t.isEmpty, durationMs >= 0, durationMs <= MusicRoomLimits.maxDurationMs else { return nil }
        let names = artists.prefix(MusicRoomLimits.maxArtists).map { MusicRoomSanitizer.text($0, max: 128) }.filter { !$0.isEmpty }
        var clean = MusicRoomTrack(providerID: pid, id: tid, title: t, artists: names, durationMs: durationMs)
        if let album, !album.isEmpty { let a = MusicRoomSanitizer.text(album); clean.album = a.isEmpty ? nil : a }
        if let isrc { guard let i = MusicRoomSanitizer.isrc(isrc) else { return nil }; clean.isrc = i }
        if let externalURL { guard let u = MusicRoomSanitizer.httpsURL(externalURL) else { return nil }; clean.externalURL = u }
        return clean
    }

    /// The track as this device's own player understands it. Streams are never accepted from the network, so the player and resolver
    /// find the audio with this device's own sources.
    func asTrack() -> MusicTrack {
        MusicTrack(id: id, providerID: providerID, title: title, durationMs: durationMs,
                   artists: artists.map { MusicArtistRef(id: $0, name: $0) },
                   album: album.map { MusicAlbumRef(id: $0, title: $0) }, isrc: isrc, externalURL: externalURL)
    }
}

// MARK: Anchor

/// "At host time T the song was at second P, playing at rate R." Everything a guest needs to know where the host is at any moment.
struct MusicRoomAnchor: Codable, Equatable, Sendable {
    var id: Int
    var track: MusicRoomTrack?
    var position: Double
    var hostTime: Double
    var rate: Double
    var isPlaying: Bool

    func sanitized() -> MusicRoomAnchor? {
        guard id >= 0, hostTime.isFinite, position.isFinite else { return nil }
        var t: MusicRoomTrack?
        if let track { guard let c = track.sanitized() else { return nil }; t = c }
        return MusicRoomAnchor(id: id, track: t, position: MusicRoomSanitizer.finite(position, 0, 86_400), hostTime: max(0, hostTime),
                               rate: MusicRoomSanitizer.finite(rate, 0.5, 2), isPlaying: isPlaying)
    }

    /// Where the host is at `hostNow`. A paused anchor stands still; a playing one moves at its rate, and never past the end of the song.
    func expectedPosition(atHostTime hostNow: Double) -> Double {
        var p = position
        if isPlaying { p += max(0, hostNow - hostTime) * rate }
        if let d = track?.duration, d > 0 { p = min(p, d) }
        return max(0, p)
    }
}

struct MusicRoomParticipant: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var isHost: Bool
}

// MARK: Messages

enum MusicRoomMessageKind: String, Codable, Sendable {
    case join, pending, welcome, roster, anchor, queue, suggest, approve, deny, leave, kick, ping, pong, closed, error
}

/// Everything after the handshake is one of these, sealed with the room key.
struct MusicRoomMessage: Codable, Equatable, Sendable {
    var v: Int = MusicRoomLimits.version
    var kind: MusicRoomMessageKind
    /// join: the guest's id.
    var id: String?
    /// join: the guest's name. welcome: the room's name.
    var name: String?
    /// approve or deny: the suggestion this answers; absent when it answers a join.
    var ref: String?
    var text: String?
    var track: MusicRoomTrack?
    var tracks: [MusicRoomTrack]?
    var anchor: MusicRoomAnchor?
    var roster: [MusicRoomParticipant]?
    var t0: Double?
    var t1: Double?
    var t2: Double?

    init(kind: MusicRoomMessageKind) { self.kind = kind }

    static func join(id: String, name: String) -> MusicRoomMessage { var m = MusicRoomMessage(kind: .join); m.id = id; m.name = name; return m }
    static let pending = MusicRoomMessage(kind: .pending)
    static func welcome(roomName: String, roster: [MusicRoomParticipant], queue: [MusicRoomTrack]) -> MusicRoomMessage {
        var m = MusicRoomMessage(kind: .welcome); m.name = roomName; m.roster = roster; m.tracks = queue; return m
    }
    static func roster(_ r: [MusicRoomParticipant]) -> MusicRoomMessage { var m = MusicRoomMessage(kind: .roster); m.roster = r; return m }
    static func anchor(_ a: MusicRoomAnchor) -> MusicRoomMessage { var m = MusicRoomMessage(kind: .anchor); m.anchor = a; return m }
    static func queue(_ t: [MusicRoomTrack]) -> MusicRoomMessage { var m = MusicRoomMessage(kind: .queue); m.tracks = t; return m }
    static func suggest(id: String, _ t: MusicRoomTrack) -> MusicRoomMessage { var m = MusicRoomMessage(kind: .suggest); m.ref = id; m.track = t; return m }
    static func approve(ref: String?) -> MusicRoomMessage { var m = MusicRoomMessage(kind: .approve); m.ref = ref; return m }
    static func deny(ref: String?) -> MusicRoomMessage { var m = MusicRoomMessage(kind: .deny); m.ref = ref; return m }
    static let leave = MusicRoomMessage(kind: .leave)
    static let kick = MusicRoomMessage(kind: .kick)
    static let closed = MusicRoomMessage(kind: .closed)
    static func ping(t0: Double) -> MusicRoomMessage { var m = MusicRoomMessage(kind: .ping); m.t0 = t0; return m }
    static func pong(t0: Double, t1: Double, t2: Double) -> MusicRoomMessage { var m = MusicRoomMessage(kind: .pong); m.t0 = t0; m.t1 = t1; m.t2 = t2; return m }
    static func error(_ t: String) -> MusicRoomMessage { var m = MusicRoomMessage(kind: .error); m.text = t; return m }

    /// Kinds only a host may send. A guest that sends one is counted toward a kick.
    var isHostOnly: Bool {
        switch kind {
        case .pending, .welcome, .roster, .anchor, .queue, .approve, .deny, .kick, .pong, .closed, .error: true
        case .join, .suggest, .leave, .ping: false
        }
    }

    func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= MusicRoomLimits.maxFrame - 64 else { throw MusicRoomError.frameTooLarge }
        return data
    }

    /// A queue message that fits one frame: the window is shortened from the end until it does.
    static func fittingQueue(_ tracks: [MusicRoomTrack]) -> MusicRoomMessage {
        var list = Array(tracks.prefix(MusicRoomLimits.maxQueue))
        while !list.isEmpty, (try? MusicRoomMessage.queue(list).encoded()) == nil { list.removeLast(max(1, list.count / 4)) }
        return .queue(list)
    }

    static func decode(_ data: Data) throws -> MusicRoomMessage {
        guard data.count <= MusicRoomLimits.maxFrame else { throw MusicRoomError.frameTooLarge }
        let m: MusicRoomMessage
        do { m = try JSONDecoder().decode(MusicRoomMessage.self, from: data) } catch { throw MusicRoomError.malformed("json") }
        guard m.v == MusicRoomLimits.version else { throw MusicRoomError.unsupportedVersion }
        var out = m
        out.text = m.text.map { MusicRoomSanitizer.text($0) }
        out.name = m.name.map { MusicRoomSanitizer.text($0, max: MusicRoomLimits.maxName) }
        if let r = m.ref { guard let c = MusicRoomSanitizer.identifier(r, max: 64) else { throw MusicRoomError.malformed("ref") }; out.ref = c }
        if let id = m.id { guard let c = MusicRoomSanitizer.identifier(id, max: 64) else { throw MusicRoomError.malformed("id") }; out.id = c }
        if let t = m.track { guard let c = t.sanitized() else { throw MusicRoomError.malformed("track") }; out.track = c }
        if let list = m.tracks {
            guard list.count <= MusicRoomLimits.maxQueue else { throw MusicRoomError.malformed("queue") }
            out.tracks = try list.map { guard let c = $0.sanitized() else { throw MusicRoomError.malformed("track") }; return c }
        }
        if let a = m.anchor { guard let c = a.sanitized() else { throw MusicRoomError.malformed("anchor") }; out.anchor = c }
        if let r = m.roster {
            guard r.count <= MusicRoomLimits.maxGuests + 1 else { throw MusicRoomError.malformed("roster") }
            out.roster = r.map { MusicRoomParticipant(id: String($0.id.prefix(64)), name: MusicRoomSanitizer.text($0.name, max: MusicRoomLimits.maxName), isHost: $0.isHost) }
        }
        for t in [m.t0, m.t1, m.t2] { if let t, !t.isFinite { throw MusicRoomError.malformed("time") } }
        switch out.kind {
        case .join:
            guard out.id != nil else { throw MusicRoomError.malformed("join") }
            if (out.name ?? "").isEmpty { out.name = "Guest" }
        case .welcome: guard out.roster != nil else { throw MusicRoomError.malformed("welcome") }
        case .roster: guard out.roster != nil else { throw MusicRoomError.malformed("roster") }
        case .anchor: guard out.anchor != nil else { throw MusicRoomError.malformed("anchor") }
        case .queue: guard out.tracks != nil else { throw MusicRoomError.malformed("queue") }
        case .suggest: guard out.track != nil, out.ref != nil else { throw MusicRoomError.malformed("suggest") }
        case .ping: guard out.t0 != nil else { throw MusicRoomError.malformed("ping") }
        case .pong: guard out.t0 != nil, out.t1 != nil, out.t2 != nil else { throw MusicRoomError.malformed("pong") }
        case .pending, .approve, .deny, .leave, .kick, .closed, .error: break
        }
        return out
    }
}

// MARK: Handshake

/// The first two frames travel unsealed: who is calling, a fresh public key and a fresh nonce. The join code is mixed into the room key and
/// is never sent; it is right only if the guest's first sealed message opens.
struct MusicRoomHello: Codable, Equatable, Sendable {
    var v: Int = MusicRoomLimits.version
    var deviceID: String
    var name: String
    var publicKey: Data
    var nonce: Data
    /// Set on a refusal; the other fields are then unused.
    var error: String?

    static func decode(_ data: Data) throws -> MusicRoomHello {
        guard data.count <= MusicRoomLimits.maxFrame else { throw MusicRoomError.frameTooLarge }
        let h: MusicRoomHello
        do { h = try JSONDecoder().decode(MusicRoomHello.self, from: data) } catch { throw MusicRoomError.malformed("hello") }
        guard h.v == MusicRoomLimits.version else { throw MusicRoomError.unsupportedVersion }
        if h.error != nil { return h }
        guard MusicRoomSanitizer.identifier(h.deviceID, max: 64) != nil, h.name.count <= MusicRoomLimits.maxName,
              h.publicKey.count == 32, h.nonce.count == 16 else { throw MusicRoomError.malformed("hello fields") }
        return h
    }

    static func refusal(_ e: MusicRoomError) -> MusicRoomHello {
        MusicRoomHello(deviceID: "-", name: "", publicKey: Data(), nonce: Data(), error: e.message)
    }
}

enum MusicRoomHandshake {
    struct Keys: Sendable {
        let guestToHost: SymmetricKey
        let hostToGuest: SymmetricKey
    }

    static func derive(privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublic: Data, code: String,
                       guestNonce: Data, hostNonce: Data, guestPublic: Data, hostPublic: Data) throws -> Keys {
        let shared: SharedSecret
        do {
            shared = try privateKey.sharedSecretFromKeyAgreement(with: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublic))
        } catch { throw MusicRoomError.authenticationFailed }
        var transcript = Data("streamsetu-music-room-v1".utf8)
        for part in [Data(code.utf8), guestNonce, hostNonce, guestPublic, hostPublic] {
            transcript.append(UInt8(part.count >> 8)); transcript.append(UInt8(part.count & 0xff))
            transcript.append(part)
        }
        let salt = Data(SHA256.hash(data: transcript))
        func key(_ label: String) -> SymmetricKey {
            shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data(label.utf8), outputByteCount: 32)
        }
        return Keys(guestToHost: key("g2h"), hostToGuest: key("h2g"))
    }

    /// Keeps digits only; the code is exactly six of them.
    static func normalizedCode(_ s: String) -> String? {
        let d = s.filter(\.isNumber)
        return d.count == 6 ? d : nil
    }
}
