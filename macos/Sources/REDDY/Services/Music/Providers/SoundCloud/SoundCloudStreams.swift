import Foundation

/// Why a SoundCloud upload cannot be played in full here. Shown calmly ("can't play this one here"); never an error alarm.
struct SoundCloudUnavailable: Error, Sendable, Equatable {
    enum Reason: String, Sendable, Equatable {
        /// Only a 30 second preview is offered (a paid release).
        case preview
        /// The uploader or a rights holder blocks it.
        case blocked
        /// Protected by encryption this player cannot open.
        case protected
        /// Private, removed or not available in this country.
        case notStreamable
        /// The track lists no usable way to fetch audio.
        case noTranscodings
        /// Every listed way to fetch audio failed.
        case resolveFailed
    }
    var reason: Reason
    var text: String {
        switch reason {
        case .preview: Localized.string("Only a short preview of this one is available.")
        case .blocked, .notStreamable: Localized.string("This one can't be played here.")
        case .protected: Localized.string("This one is protected and can't be played here.")
        case .noTranscodings, .resolveFailed: Localized.string("This one can't be played right now.")
        }
    }
}

/// What the picker decides for a track before any audio address is asked for.
enum SoundCloudAvailability: Sendable, Equatable {
    case playable
    case unavailable(SoundCloudUnavailable.Reason)

    var isPlayable: Bool { if case .playable = self { return true } else { return false } }

    /// A track that is only a bare id (a playlist stub) is judged after it is fetched in full.
    static func of(_ t: SCTrack) -> SoundCloudAvailability {
        if t.isStub { return .playable }
        if SoundCloudStreams.hasEncrypted(t.transcodings) { return .unavailable(.protected) }
        if (t.policy ?? "").uppercased() == "BLOCK" { return .unavailable(.blocked) }
        if t.streamable == false { return .unavailable(.notStreamable) }
        if t.transcodings.isEmpty { return .unavailable(.noTranscodings) }
        if SoundCloudStreams.candidates(from: t.transcodings).isEmpty {
            let snippedAny = t.transcodings.contains { SoundCloudStreams.isPreview($0) } || (t.policy ?? "").uppercased() == "SNIP"
            return .unavailable(snippedAny ? .preview : .noTranscodings)
        }
        return .playable
    }
}

/// Choosing among a track's transcodings. Pure.
enum SoundCloudStreams {
    /// Seconds an address is trusted for. SoundCloud states no figure, so it is short.
    static let trust: TimeInterval = 600

    static func isEncrypted(_ t: SCTranscoding) -> Bool {
        let p = t.proto.lowercased()
        return p.contains("encrypted") || p.hasPrefix("ctr-") || p.hasPrefix("cbc-")
    }
    /// Any encrypted variant beside plain ones means the whole track is protected (the plain listings are empty promises).
    static func hasEncrypted(_ list: [SCTranscoding]) -> Bool { list.contains(where: isEncrypted) }

    /// A preview: flagged as snipped, or an address of the 30 second kind.
    static func isPreview(_ t: SCTranscoding) -> Bool { t.snipped || isPreviewURL(t.url) }
    static func isPreviewURL(_ url: String) -> Bool {
        let u = url.lowercased()
        return u.contains("/0/30/") || u.contains("/preview/")
    }

    static func codec(of t: SCTranscoding) -> String {
        let m = t.mime.lowercased(), p = t.preset.lowercased()
        if m.contains("mp4a") || p.hasPrefix("aac") || p.hasPrefix("m4a") { return "aac" }
        if m.contains("opus") || m.contains("ogg") || p.hasPrefix("opus") { return "opus" }
        if m.contains("mpeg") || p.hasPrefix("mp3") { return "mp3" }
        return "unknown"
    }

    /// kbps from a preset such as `aac_160k`; MP3 without a number is 128.
    static func bitrate(of t: SCTranscoding) -> Int? {
        let p = t.preset.lowercased()
        if let re = try? NSRegularExpression(pattern: "(\\d{2,3})k"), let m = re.firstMatch(in: p, range: NSRange(location: 0, length: (p as NSString).length)) {
            return Int((p as NSString).substring(with: m.range(at: 1)))
        }
        return codec(of: t) == "mp3" ? 128 : nil
    }

    private static func isProgressive(_ t: SCTranscoding) -> Bool { t.proto.lowercased() == "progressive" }
    private static func isHLS(_ t: SCTranscoding) -> Bool { t.proto.lowercased() == "hls" }
    private static func isMasterPlaylist(_ t: SCTranscoding) -> Bool { t.mime.lowercased().contains("mpegurl") }

    /// Plain (unencrypted, full length) transcodings this player can open, best first: progressive AAC or MP3, then HLS AAC by bitrate, then HLS MP3.
    /// Opus is left out (the player opens it only from an Ogg file, not from a stream like this). An encrypted variant anywhere empties the list.
    static func candidates(from list: [SCTranscoding]) -> [SCTranscoding] {
        if hasEncrypted(list) { return [] }
        let usable = list.filter { !isPreview($0) && !isMasterPlaylist($0) && ["aac", "mp3"].contains(codec(of: $0)) && (isProgressive($0) || isHLS($0)) }
        func kbps(_ t: SCTranscoding) -> Int { bitrate(of: t) ?? 0 }
        func rank(_ t: SCTranscoding) -> Int {
            let c = codec(of: t)
            if isProgressive(t) { return 0 }
            return c == "aac" ? 1 : 2
        }
        return usable.enumerated().sorted { a, b in
            let (x, y) = (rank(a.element), rank(b.element))
            if x != y { return x < y }
            if kbps(a.element) != kbps(b.element) { return kbps(a.element) > kbps(b.element) }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// The player-facing stream for an address SoundCloud returned for one transcoding.
    static func stream(address: String, from t: SCTranscoding, now: Date = Date()) -> MusicStream {
        let c = codec(of: t)
        let hls = isHLS(t)
        var expires = now.addingTimeInterval(trust)
        if let e = MusicStreamExpiry.urlExpiry(address), e < expires { expires = e }
        return MusicStream(url: address, codec: c, container: hls ? "m3u8" : (c == "aac" ? "m4a" : "mp3"), proto: hls ? .hls : .progressive,
                           bitrate: bitrate(of: t), expiresAt: expires)
    }

    /// Reads the reply of a transcoding address: `{"url": "<signed address>"}`.
    static func address(fromReply data: Data) -> String? {
        guard let u = SoundCloudJSON.object(data)?.str("url"), u.hasPrefix("https://") else { return nil }
        return u
    }
}

/// Remembers, for this run, which tracks turned out unplayable and why, so a row or the player can say so without asking again.
final class SoundCloudAvailabilityBook: @unchecked Sendable {
    static let shared = SoundCloudAvailabilityBook()
    private let lock = NSLock()
    private var reasons: [String: SoundCloudUnavailable.Reason] = [:]
    private static let limit = 2_000

    func note(trackID: String, _ a: SoundCloudAvailability) {
        lock.lock(); defer { lock.unlock() }
        switch a {
        case .playable: reasons[trackID] = nil
        case .unavailable(let r):
            if reasons.count >= Self.limit { reasons.removeAll() }
            reasons[trackID] = r
        }
    }
    func reason(forTrackID id: String) -> SoundCloudUnavailable.Reason? { lock.lock(); defer { lock.unlock() }; return reasons[id] }
    /// The calm sentence for a SoundCloud track known to be unplayable, nil otherwise.
    func line(for t: MusicTrack) -> String? {
        guard t.providerID == SoundCloudProvider.providerID, let r = reason(forTrackID: t.id) else { return nil }
        return SoundCloudUnavailable(reason: r).text
    }
}
