import Foundation

// The Subsonic / OpenSubsonic wire protocol, as plain values and pure functions: how a request is signed, how a reply is read, how a
// song, album, artist or playlist becomes a canonical Music model, and how a stream or cover address is built. No network and no storage
// are in here, so every rule can be tested with a canned reply.

/// How a request proves who is asking. The password never travels: each request carries a salted hash of it.
enum SubsonicAuth {
    static let apiVersion = "1.16.1"
    static let clientName = "StreamSetu"
    /// The id of the one provider that serves every server the person adds.
    static let providerID = "subsonic"

    /// The token the protocol asks for: the lower-case hex MD5 of the password followed by the salt.
    static func token(password: String, salt: String) -> String { MusicHash.md5(password + salt) }

    /// A fresh random salt (lower-case hex). It is made once per server and kept, so every address built for the same server stays identical.
    static func makeSalt(length: Int = 12) -> String {
        var g = SystemRandomNumberGenerator()
        return String((0..<max(6, length)).map { _ in "0123456789abcdef".randomElement(using: &g)! })
    }
}

/// What the person may ask the server to convert audio to. Both parts are optional; nothing set leaves the choice to the server.
struct SubsonicTranscode: Equatable, Sendable {
    static let formats = ["mp3", "opus", "aac"]
    static let bitrates = [320, 256, 192, 160, 128, 96, 64]
    static let defaultsKey = "music.subsonic.transcode"

    var format: String?
    var maxBitRate: Int?

    init(format: String? = nil, maxBitRate: Int? = nil) {
        self.format = format.flatMap { Self.formats.contains($0) ? $0 : nil }
        self.maxBitRate = maxBitRate.flatMap { Self.bitrates.contains($0) ? $0 : nil }
    }

    var isOriginal: Bool { format == nil && maxBitRate == nil }

    /// Stored as "mp3:192", "mp3:", ":192" or nothing.
    var stored: String? { isOriginal ? nil : "\(format ?? ""):\(maxBitRate.map(String.init) ?? "")" }

    init(stored: String?) {
        let parts = (stored ?? "").split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        self.init(format: parts.first.flatMap { $0.isEmpty ? nil : $0 }, maxBitRate: parts.count > 1 ? Int(parts[1]) : nil)
    }

    static func load(_ d: UserDefaults = .standard) -> SubsonicTranscode { SubsonicTranscode(stored: d.string(forKey: defaultsKey)) }

    func save(_ d: UserDefaults = .standard) {
        if let s = stored { d.set(s, forKey: Self.defaultsKey) } else { d.removeObject(forKey: Self.defaultsKey) }
    }
}

/// One signed-in server as the request builder sees it. It holds the token, never the password.
struct SubsonicSession: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    var serverID: String
    var base: URL
    var user: String
    var salt: String
    var token: String

    init(serverID: String, base: URL, user: String, password: String, salt: String) {
        self.serverID = serverID; self.base = base; self.user = user; self.salt = salt
        self.token = SubsonicAuth.token(password: password, salt: salt)
    }

    /// Never prints the token, so a log line or a failed test cannot leak it.
    var description: String { "SubsonicSession(\(serverID))" }
    var debugDescription: String { description }

    var authItems: [URLQueryItem] {
        [URLQueryItem(name: "u", value: user), URLQueryItem(name: "t", value: token), URLQueryItem(name: "s", value: salt),
         URLQueryItem(name: "v", value: SubsonicAuth.apiVersion), URLQueryItem(name: "c", value: SubsonicAuth.clientName), URLQueryItem(name: "f", value: "json")]
    }

    /// `<base>/rest/<method>` with the signature and the given parameters. A parameter may repeat (several `id`s).
    func url(_ method: String, _ items: [(String, String)] = []) -> URL? {
        guard var c = URLComponents(url: base.appendingPathComponent("rest").appendingPathComponent(method), resolvingAgainstBaseURL: false) else { return nil }
        c.queryItems = authItems + items.map { URLQueryItem(name: $0.0, value: $0.1) }
        // A plus sign in a value would be read as a space by the server.
        if let q = c.percentEncodedQuery, q.contains("+") { c.percentEncodedQuery = q.replacingOccurrences(of: "+", with: "%2B") }
        return c.url
    }

    func coverURL(_ coverID: String, size: Int) -> String? { url("getCoverArt", [("id", coverID), ("size", String(size))])?.absoluteString }

    func streamURL(_ songID: String, transcode: SubsonicTranscode) -> String? {
        var items = [("id", songID)]
        if let f = transcode.format { items.append(("format", f)) }
        if let b = transcode.maxBitRate { items.append(("maxBitRate", String(b))) }
        return url("stream", items)?.absoluteString
    }
}

/// A track, album, artist or playlist id on one of the person's servers. The server is part of the id because two servers can reuse an id.
enum SubsonicID {
    static func make(_ serverID: String, _ raw: String) -> String { serverID + "~" + raw }
    static func split(_ id: String) -> (server: String, raw: String)? {
        guard let i = id.firstIndex(of: "~"), i != id.startIndex else { return nil }
        let raw = String(id[id.index(after: i)...])
        return raw.isEmpty ? nil : (String(id[..<i]), raw)
    }
}

/// What a server said about itself in its ping answer.
struct SubsonicServerInfo: Equatable, Sendable {
    var type: String?
    var serverVersion: String?
    var openSubsonic: Bool
    var apiVersion: String?
    var isNavidrome: Bool { (type ?? "").lowercased() == "navidrome" }
}

enum SubsonicReply {
    /// The `subsonic-response` object of a reply, or the error it carries.
    static func envelope(_ obj: Any) throws -> [String: Any] {
        guard let root = (obj as? [String: Any])?["subsonic-response"] as? [String: Any] else { throw MusicError.network("unexpected reply") }
        if (root["status"] as? String) == "ok" { return root }
        let err = root.dict("error")
        throw mapError(code: err?.int("code") ?? 0)
    }

    /// Protocol error codes into the app's own errors. The server's message and the request address are dropped on purpose: the address carries the token.
    static func mapError(code: Int) -> MusicError {
        switch code {
        case 40, 41: .notSignedIn("Subsonic")
        case 50, 60: .refused("Subsonic")
        case 70: .notFound
        case 20, 30: .network("server version not supported")
        case 10: .network("bad request")
        default: .network("server error \(code)")
        }
    }

    static func info(_ root: [String: Any]) -> SubsonicServerInfo {
        SubsonicServerInfo(type: root.str("type"), serverVersion: root.str("serverVersion"), openSubsonic: (root["openSubsonic"] as? Bool) == true, apiVersion: root.str("version"))
    }
}

/// What one server sent as ReplayGain for a song (OpenSubsonic servers only).
struct SubsonicReplayGain: Equatable, Sendable {
    var trackGain: Double?
    var albumGain: Double?
    var baseGain: Double?
    var fallbackGain: Double?

    init(trackGain: Double? = nil, albumGain: Double? = nil, baseGain: Double? = nil, fallbackGain: Double? = nil) {
        self.trackGain = trackGain; self.albumGain = albumGain; self.baseGain = baseGain; self.fallbackGain = fallbackGain
    }

    init?(_ d: [String: Any]?) {
        guard let d else { return nil }
        func num(_ k: String) -> Double? { (d[k] as? Double) ?? (d[k] as? Int).map(Double.init) ?? (d[k] as? String).flatMap(MusicLoudnessMath.parseReplayGain) }
        self.init(trackGain: num("trackGain"), albumGain: num("albumGain"), baseGain: num("baseGain"), fallbackGain: num("fallbackGain"))
        if trackGain == nil && albumGain == nil && fallbackGain == nil { return nil }
    }

    /// The track gain wins; the album gain stands in; a server's fallback gain is the last resort. The result is an absolute loudness in LUFS
    /// (ReplayGain is measured against -18 LUFS), ready for the loudness store; nil when the server sent nothing usable.
    var lufs: Double? {
        guard let g = trackGain ?? albumGain ?? fallbackGain, g.isFinite, abs(g) < 60 else { return nil }
        return MusicLoudnessMath.loudness(replayGainDB: g)
    }
}

/// Reads server JSON into canonical models for one server.
struct SubsonicMapper: Sendable {
    let session: SubsonicSession

    static let listCoverSize = 300
    static let largeCoverSize = 1200

    func id(_ raw: String) -> String { SubsonicID.make(session.serverID, raw) }

    func thumbnails(_ coverID: String?) -> [MusicThumbnail] {
        guard let coverID, !coverID.isEmpty else { return [] }
        return [(Self.listCoverSize), (Self.largeCoverSize)].compactMap { size in
            session.coverURL(coverID, size: size).map { MusicThumbnail(url: $0, width: size, height: size) }
        }
    }

    func artistRef(id raw: String?, name: String?, coverID: String? = nil) -> MusicArtistRef? {
        guard let name, !name.isEmpty else { return nil }
        return MusicArtistRef(id: raw.map(id) ?? "", name: name, thumbnails: thumbnails(coverID))
    }

    func song(_ d: [String: Any]) -> MusicTrack? {
        guard let raw = d.str("id"), let title = d.str("title") else { return nil }
        if (d["isDir"] as? Bool) == true { return nil }
        var artists: [MusicArtistRef] = []
        for a in d.array("artists") { if let r = artistRef(id: a.str("id"), name: a.str("name")) { artists.append(r) } }
        if artists.isEmpty, let r = artistRef(id: d.str("artistId"), name: d.str("artist")) { artists = [r] }
        if artists.isEmpty { artists = [MusicArtistRef(id: "", name: "Unknown artist")] }
        let cover = d.str("coverArt") ?? d.str("albumId")
        var album: MusicAlbumRef?
        if let t = d.str("album") {
            album = MusicAlbumRef(id: d.str("albumId").map(id) ?? "", title: t, artists: Array(artists.prefix(1)), thumbnails: thumbnails(cover),
                                  releaseDate: d.int("year").map(String.init))
        }
        let isrc: String? = (d["isrc"] as? [String])?.first ?? d.str("isrc")
        var track = MusicTrack(
            id: id(raw), providerID: SubsonicAuth.providerID, title: title, durationMs: Int64(d.int("duration") ?? 0) * 1000,
            trackNumber: d.int("track"), discNumber: d.int("discNumber"), artists: artists, album: album, thumbnails: thumbnails(cover),
            explicit: (d.str("explicitStatus") ?? "").lowercased() == "explicit", popularity: d.int("playCount"), isrc: isrc,
            rating: d.str("starred") != nil ? .like : .none)
        track.creditBundle = SubsonicCreditMapper.trackBundle(d, id: id)
        return track
    }

    func album(_ d: [String: Any]) -> MusicAlbum? {
        guard let raw = d.str("id"), let name = d.str("name") ?? d.str("title") else { return nil }
        var artists: [MusicArtistRef] = []
        for a in d.array("artists") { if let r = artistRef(id: a.str("id"), name: a.str("name")) { artists.append(r) } }
        if artists.isEmpty, let r = artistRef(id: d.str("artistId"), name: d.str("artist")) { artists = [r] }
        return MusicAlbum(id: id(raw), providerID: SubsonicAuth.providerID, title: name, artists: artists, thumbnails: thumbnails(d.str("coverArt") ?? raw),
                          releaseDate: d.int("year").map(String.init), totalTracks: d.int("songCount"), albumType: "Album")
    }

    func artist(_ d: [String: Any]) -> MusicArtist? {
        guard let raw = d.str("id"), let name = d.str("name") else { return nil }
        var genres: [String] = []
        if let g = d.str("genre") { genres = [g] }
        return MusicArtist(id: id(raw), providerID: SubsonicAuth.providerID, name: name, thumbnails: thumbnails(d.str("coverArt")),
                           genres: genres)
    }

    func playlist(_ d: [String: Any]) -> MusicPlaylist? {
        guard let raw = d.str("id"), let name = d.str("name") else { return nil }
        return MusicPlaylist(id: id(raw), providerID: SubsonicAuth.providerID, name: name, summary: d.str("comment"), owner: d.str("owner"),
                             thumbnails: thumbnails(d.str("coverArt")), trackCount: d.int("songCount"), isPublic: (d["public"] as? Bool) ?? false)
    }

    /// The stream a song is played from, built from what the server said about the file. A converted stream carries the asked-for format and ceiling.
    func stream(for d: [String: Any], raw: String, transcode: SubsonicTranscode) -> MusicStream? {
        guard let url = session.streamURL(raw, transcode: transcode) else { return nil }
        if let f = transcode.format {
            return MusicStream(url: url, codec: f, container: f == "opus" ? "ogg" : (f == "aac" ? "m4a" : f), proto: .progressive, bitrate: transcode.maxBitRate ?? d.int("bitRate"))
        }
        let suffix = (d.str("suffix") ?? Self.suffix(forContentType: d.str("contentType")) ?? "mp3").lowercased()
        let lossless = ["flac", "alac", "wav", "aiff", "aif", "ape", "wv"].contains(suffix)
        let rate = d.int("samplingRate")
        let bitrate: Int? = lossless ? nil : (transcode.maxBitRate.map { min($0, d.int("bitRate") ?? $0) } ?? d.int("bitRate"))
        return MusicStream(url: url, codec: Self.codec(forSuffix: suffix), container: suffix, proto: .progressive, bitrate: bitrate,
                           sampleRate: lossless ? (rate ?? 44100) : rate)
    }

    static func codec(forSuffix s: String) -> String {
        switch s { case "m4a", "mp4", "aac": "aac"; case "oga", "ogg": "vorbis"; default: s }
    }

    static func suffix(forContentType t: String?) -> String? {
        switch (t ?? "").lowercased() {
        case "audio/mpeg": "mp3"; case "audio/flac", "audio/x-flac": "flac"; case "audio/ogg", "audio/vorbis": "ogg"; case "audio/opus": "opus"
        case "audio/mp4", "audio/x-m4a", "audio/aac": "m4a"; case "audio/wav", "audio/x-wav": "wav"
        default: nil
        }
    }
}

/// One listing out of a reply: the rows of `key` inside `container`, as the reply writes them (a one-row list can arrive as a single object).
enum SubsonicRows {
    static func rows(_ root: [String: Any], _ container: String, _ key: String) -> [[String: Any]] {
        guard let c = root[container] as? [String: Any] else { return [] }
        if let list = c[key] as? [[String: Any]] { return list }
        if let one = c[key] as? [String: Any] { return [one] }
        return []
    }

    /// Artists come grouped under alphabetical index entries.
    static func indexedArtists(_ root: [String: Any]) -> [[String: Any]] {
        guard let c = root["artists"] as? [String: Any] else { return [] }
        let groups = (c["index"] as? [[String: Any]]) ?? []
        return groups.flatMap { $0.array("artist") }
    }
}
