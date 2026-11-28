import Foundation

/// The anonymous user token Musixmatch's mobile gateway hands out, held in memory only, and a cool-down for when the gateway asks for a captcha.
actor MusixmatchSession {
    static let shared = MusixmatchSession()
    private var token: String?
    private var tokenAt = Date.distantPast
    private var blockedUntil = Date.distantPast
    static let tokenLife: TimeInterval = 600
    static let captchaPause: TimeInterval = 300

    func isPaused(now: Date = Date()) -> Bool { now < blockedUntil }
    func pause(now: Date = Date()) { blockedUntil = now.addingTimeInterval(Self.captchaPause); token = nil }
    func forgetToken() { token = nil }

    func userToken(http: MusicHTTP, now: Date = Date()) async throws -> String {
        if let token, now.timeIntervalSince(tokenAt) < Self.tokenLife { return token }
        let url = try MusixmatchProvider.url("token.get", ["user_language": "en"])
        let d = try await MusicLyricsIO.withTimeout(MusixmatchProvider.timeout) { try await http.get(url, headers: MusixmatchProvider.headers) }
        let obj = try MusicLyricsIO.parse(d)
        if MusixmatchProvider.status(obj) == 401 { pause(now: now); throw MusicError.network("Musixmatch asked for a captcha") }
        guard let t = MusixmatchProvider.body(obj)?["user_token"] as? String, !t.isEmpty, !t.hasPrefix("UpgradeOnly") else { throw MusicError.network("no token") }
        token = t; tokenAt = now
        return t
    }
}

/// Musixmatch through the anonymous calls its own mobile app makes: a user token, then one `macro.subtitles.get` that matches the song on the
/// server and returns line-timed lyrics and, where Musixmatch has them, word-timed ones. Unofficial: the address and headers are the app's.
struct MusixmatchProvider: MusicLyricsRequestProvider {
    static let base = "https://apic-appmobile.musixmatch.com/ws/1.1/"
    static let timeout = 10.0
    static let appID = "mac-ios-v2.0"
    static let agent = "Musixmatch/2025120901 CFNetwork/3860.300.31 Darwin/25.2.0"
    static let headers = ["X-User-Agent": agent, "User-Agent": agent, "x-mxm-app-version": "10.1.1", "Accept-Language": "en-US,en;q=0.9", "Accept": "application/json"]
    /// A song found by the server must look like the wanted one at least this much (see `score`): title and artist both close, or the exact title.
    static let acceptScore = 80
    private let http: MusicHTTP
    init(http: MusicHTTP = MusicHTTP()) { self.http = http }

    var info: MusicProviderInfo {
        MusicProviderInfo(id: MusicLyricsSources.musixmatch, name: "Musixmatch", summary: MusicLyricsSources.about[MusicLyricsSources.musixmatch] ?? "",
                          privacyNote: "The title, artist and length of the song being played, and your IP address, are sent to Musixmatch. This source presents itself as Musixmatch's own mobile app, which is unofficial access to a third-party service.",
                          homepage: "https://www.musixmatch.com")
    }
    var capabilities: MusicCapabilities { [.lyrics] }

    static func url(_ path: String, _ query: [String: String], now: Date = Date()) throws -> URL {
        var items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "app_id", value: appID))
        items.append(URLQueryItem(name: "t", value: String(Int64(now.timeIntervalSince1970 * 1000))))
        var c = URLComponents(string: base + path)
        c?.queryItems = items
        guard let u = c?.url else { throw MusicError.network("bad address") }
        return u
    }

    static func body(_ obj: Any) -> [String: Any]? { (((obj as? [String: Any])?["message"] as? [String: Any])?["body"]) as? [String: Any] }
    static func status(_ obj: Any) -> Int? { MusicLyricsIO.int64(((((obj as? [String: Any])?["message"]) as? [String: Any])?["header"] as? [String: Any])?["status_code"]).map(Int.init) }

    // MARK: flow

    func lyrics(for request: MusicLyricsRequest) async throws -> MusicLyrics? {
        guard !request.title.isEmpty else { return nil }
        let session = MusixmatchSession.shared
        if await session.isPaused() { MusicDebugLog.log("lyrics", "musixmatch paused after a captcha"); return nil }
        let title = MusicLyricsTitleClean.title(request.title), artist = MusicLyricsTitleClean.artist(request.artists)
        var q = ["format": "json", "namespace": "lyrics_richsynched", "optional_calls": "track.richsync", "subtitle_format": "lrc", "q_track": title, "q_artist": artist]
        if let s = request.durationSeconds, s > 0 { q["q_duration"] = String(Int(s.rounded())) }
        let token = try await session.userToken(http: http)
        q["usertoken"] = token
        let query = q
        let d = try await MusicLyricsIO.withTimeout(Self.timeout) { [http] in try await http.get(try Self.url("macro.subtitles.get", query), headers: Self.headers) }
        let obj = try MusicLyricsIO.parse(d)
        if Self.status(obj) == 401 { await session.pause(); MusicDebugLog.log("lyrics", "musixmatch asked for a captcha, pausing 5 minutes"); return nil }
        guard let calls = Self.body(obj)?["macro_calls"] as? [String: Any] else { return nil }
        return Self.lyrics(from: calls, title: title, artist: artist, seconds: request.durationSeconds)
    }

    /// The matched song must be the wanted one, then word-timed lyrics are preferred over line-timed ones.
    static func lyrics(from calls: [String: Any], title: String, artist: String, seconds: Double?) -> MusicLyrics? {
        func body(_ k: String) -> [String: Any]? { ((calls[k] as? [String: Any])?["message"] as? [String: Any])?["body"] as? [String: Any] }
        guard let t = body("matcher.track.get")?["track"] as? [String: Any] else { return nil }
        let found = Track(id: MusicLyricsIO.int64(t["track_id"]) ?? 0, title: (t["track_name"] as? String) ?? "", artist: (t["artist_name"] as? String) ?? "",
                          seconds: MusicLyricsIO.seconds(t["track_length"]), hasRichsync: false)
        guard score(found, title: title, artist: artist, seconds: seconds) >= acceptScore else {
            MusicDebugLog.log("lyrics", "musixmatch matched \(found.title) by \(found.artist): not the wanted song")
            return nil
        }
        let name = MusicLyricsSources.name(MusicLyricsSources.musixmatch)
        if let text = (body("track.richsync.get")?["richsync"] as? [String: Any])?["richsync_body"] as? String, let lines = parseRichsync(text), !lines.isEmpty {
            return MusicLyricsNormalizer.normalize(MusicLyrics(synced: MusicLyricsGaps.insert(into: MusicLyricsBackground.splitAll(lines)), sourceName: name, providerID: MusicLyricsSources.musixmatch))
        }
        if let list = body("track.subtitles.get")?["subtitle_list"] as? [[String: Any]],
           let text = (list.first?["subtitle"] as? [String: Any])?["subtitle_body"] as? String {
            let lines = MusicLyricsParsers.parseLRC(text)
            if !lines.isEmpty { return MusicLyricsNormalizer.normalize(MusicLyrics(synced: lines, sourceName: name, providerID: MusicLyricsSources.musixmatch)) }
        }
        return nil
    }

    // MARK: matching and parsing

    struct Track: Sendable, Hashable { var id: Int64; var title: String; var artist: String; var seconds: Double?; var hasRichsync: Bool }

    static func tracks(_ obj: Any) -> [Track] {
        guard let list = body(obj)?["track_list"] as? [[String: Any]] else { return [] }
        return list.compactMap { row in
            guard let t = row["track"] as? [String: Any], let id = MusicLyricsIO.int64(t["track_id"]) else { return nil }
            return Track(id: id, title: (t["track_name"] as? String) ?? "", artist: (t["artist_name"] as? String) ?? "",
                         seconds: MusicLyricsIO.seconds(t["track_length"]), hasRichsync: (MusicLyricsIO.int64(t["has_richsync"]) ?? 0) != 0)
        }
    }

    /// Title equal +80, either contains the other +40; artist contains the wanted one +40; length within 2 s +30, 5 s +15, 10 s +5, else -20.
    static func score(_ t: Track, title: String, artist: String, seconds: Double?) -> Int {
        var s = 0
        let wt = title.lowercased().trimmingCharacters(in: .whitespaces), ct = t.title.lowercased().trimmingCharacters(in: .whitespaces)
        if wt == ct { s += 80 } else if !wt.isEmpty, !ct.isEmpty, ct.contains(wt) || wt.contains(ct) { s += 40 }
        let wa = artist.lowercased().trimmingCharacters(in: .whitespaces)
        if !wa.isEmpty, t.artist.lowercased().contains(wa) { s += 40 }
        if let w = seconds, w > 0, let c = t.seconds, c > 0 {
            let d = abs(w - c)
            s += d <= 2 ? 30 : d <= 5 ? 15 : d <= 10 ? 5 : -20
        }
        return s
    }

    static func pickTrack(_ obj: Any, title: String, artist: String, seconds: Double?) -> Track? {
        tracks(obj).max { score($0, title: title, artist: artist, seconds: seconds) < score($1, title: title, artist: artist, seconds: seconds) }
    }

    /// `[{ts, te, l:[{c, o}], x}]`: seconds, fragments with offsets from the line start. A fragment that is only blank spaces the word before.
    static func parseRichsync(_ text: String) -> [MusicLyricLine]? {
        guard let data = text.data(using: .utf8), let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var out: [MusicLyricLine] = []
        for row in arr {
            guard let ts = MusicLyricsIO.seconds(row["ts"]), let te = MusicLyricsIO.seconds(row["te"]) else { continue }
            let start = Int64((ts * 1000).rounded()), end = Int64((te * 1000).rounded())
            let frags = (row["l"] as? [[String: Any]]) ?? []
            var runs: [MusicLyricWord] = []
            for (i, f) in frags.enumerated() {
                guard let c = f["c"] as? String else { continue }
                let o = Int64(((MusicLyricsIO.seconds(f["o"]) ?? 0) * 1000).rounded())
                if c.trimmingCharacters(in: .whitespaces).isEmpty {
                    if var last = runs.popLast(), !last.text.hasSuffix(" ") { last.text += " "; runs.append(last) }
                    continue
                }
                let st = start + o
                let next = frags[(i + 1)...].compactMap { MusicLyricsIO.seconds($0["o"]) }.first.map { start + Int64(($0 * 1000).rounded()) } ?? end
                runs.append(MusicLyricWord(text: c, startMs: st, endMs: max(st, next)))
            }
            let text = (row["x"] as? String) ?? ""
            guard !runs.isEmpty else { if !text.isEmpty { out.append(MusicLyricLine(timeMs: start, text: text, endMs: end)) }; continue }
            let words = MusicLyricsSyllables.glue(runs, explicitSpacing: true)
            out.append(MusicLyricLine(timeMs: min(start, words[0].startMs), text: words.map(\.text).joined().trimmingCharacters(in: .whitespaces), endMs: end, words: words))
        }
        return out.sorted { $0.timeMs < $1.timeMs }
    }

    /// `[{text, time:{total}}]` in seconds, as line stamps.
    static func parseSubtitle(_ text: String) -> [MusicLyricLine]? {
        guard let data = text.data(using: .utf8), let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let lines = arr.compactMap { row -> MusicLyricLine? in
            guard let t = row["text"] as? String, let total = MusicLyricsIO.seconds((row["time"] as? [String: Any])?["total"]) else { return nil }
            return MusicLyricLine(timeMs: Int64((total * 1000).rounded()), text: t)
        }
        return lines.sorted { $0.timeMs < $1.timeMs }
    }
}
