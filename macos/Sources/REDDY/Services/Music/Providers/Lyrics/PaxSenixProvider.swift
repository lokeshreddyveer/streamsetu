import Foundation

/// The few secrets the lyrics sources hold, in the Music Keychain.
enum MusicLyricsKeychain {
    static let service = MusicKeychain.service
    static let paxSenixKey = "lyrics.paxsenix.apikey"

    static func read(_ account: String) -> String? { MusicKeychain.shared.read(account) }

    @discardableResult
    static func write(_ account: String, _ value: String?) -> Bool { MusicKeychain.shared.write(account, value) }
}

/// An Apple Music web-player token taken from music.apple.com's own script, held for the life of the process.
actor PaxSenixAppleToken {
    static let shared = PaxSenixAppleToken()
    private var token: String?

    func value(http: MusicHTTP, timeout: Double) async throws -> String {
        if let token { return token }
        let page = try await text(http, URL(string: "https://music.apple.com/us/new")!, timeout)
        guard let path = Self.scriptPath(in: page), let url = URL(string: "https://music.apple.com" + path) else { throw MusicError.network("no player script") }
        let script = try await text(http, url, timeout)
        guard let t = Self.firstJWT(in: script) else { throw MusicError.network("no player token") }
        token = t
        return t
    }

    func forget() { token = nil }

    private func text(_ http: MusicHTTP, _ url: URL, _ timeout: Double) async throws -> String {
        let d = try await MusicLyricsIO.withTimeout(timeout) { try await http.get(url) }
        return String(decoding: d, as: UTF8.self)
    }

    static func scriptPath(in html: String) -> String? {
        guard let r = html.range(of: #"/assets/index~[A-Za-z0-9_.\-]*\.js"#, options: .regularExpression) else { return nil }
        return String(html[r])
    }

    /// Three base64url segments, the first starting `eyJ`.
    static func firstJWT(in script: String) -> String? {
        guard let r = script.range(of: #"eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+"#, options: .regularExpression) else { return nil }
        return String(script[r])
    }
}

/// PaxSenix. Keyless mode: Apple Music lyrics through the public proxy, using an anonymous token read from Apple's web player. When the
/// person has saved a PaxSenix key, the Spotify and Musixmatch routes and the general search are tried too.
struct PaxSenixProvider: MusicLyricsRequestProvider {
    static let proxy = "https://lyrics.paxsenix.org"
    static let api = "https://api.paxsenix.org"
    static let appleSearch = URL(string: "https://amp-api.music.apple.com/v1/catalog/us/search")!
    static let timeout = 6.0
    static let apiTimeout = 15.0
    private let http: MusicHTTP
    private let key: @Sendable () -> String?
    init(http: MusicHTTP = MusicHTTP(), key: @escaping @Sendable () -> String? = { MusicLyricsKeychain.read(MusicLyricsKeychain.paxSenixKey) }) {
        self.http = http; self.key = key
    }

    var info: MusicProviderInfo {
        MusicProviderInfo(id: MusicLyricsSources.paxSenix, name: "PaxSenix", summary: MusicLyricsSources.about[MusicLyricsSources.paxSenix] ?? "",
                          privacyNote: "The title and artist of the song being played are sent to Apple Music's web search and to lyrics.paxsenix.org. To search, this source reads an anonymous token out of Apple's web player and presents itself as that web player, which is unofficial access to a third-party web client. If you save a PaxSenix key, it is sent to api.paxsenix.org as well.",
                          homepage: "https://paxsenix.org")
    }
    var capabilities: MusicCapabilities { [.lyrics] }

    /// A leading "Bearer " (any case) and surrounding blanks are dropped.
    static func cleanKey(_ raw: String?) -> String? {
        guard var k = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty else { return nil }
        if k.lowercased().hasPrefix("bearer ") { k = String(k.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        return k.isEmpty ? nil : k
    }

    func lyrics(for request: MusicLyricsRequest) async throws -> MusicLyrics? {
        guard !request.title.isEmpty else { return nil }
        let title = MusicLyricsTitleClean.title(request.title), artist = MusicLyricsTitleClean.artist(request.artists)
        let term = "\(title) \(artist)".trimmingCharacters(in: .whitespaces)
        if let apiKey = Self.cleanKey(key()) {
            if let l = try? await viaKey(apiKey, title: title, artist: artist, term: term, seconds: request.durationSeconds) { return l }
        }
        return try await apple(term: term, title: title, artist: artist, seconds: request.durationSeconds)
    }

    // MARK: keyless Apple route

    private func apple(term: String, title: String, artist: String, seconds: Double?) async throws -> MusicLyrics? {
        var token = try await PaxSenixAppleToken.shared.value(http: http, timeout: Self.timeout)
        let headers = { (t: String) in ["Authorization": "Bearer \(t)", "Origin": "https://music.apple.com", "Referer": "https://music.apple.com/"] }
        let obj: Any
        do { obj = try await MusicLyricsIO.object(http, Self.appleSearch, query: ["term": term, "types": "songs", "limit": "10", "l": "en-US"], headers: headers(token), timeout: Self.timeout) }
        catch MusicError.notSignedIn {
            // The token expired: read a fresh one once.
            await PaxSenixAppleToken.shared.forget()
            token = try await PaxSenixAppleToken.shared.value(http: http, timeout: Self.timeout)
            obj = try await MusicLyricsIO.object(http, Self.appleSearch, query: ["term": term, "types": "songs", "limit": "10", "l": "en-US"], headers: headers(token), timeout: Self.timeout)
        }
        guard let best = MusicCandidateScore.best(in: obj, title: title, artist: artist, seconds: seconds), let url = URL(string: Self.proxy + "/apple-music/lyrics") else { return nil }
        do {
            let data = try await MusicLyricsIO.withTimeout(Self.timeout) { [http] in try await http.get(url, query: ["id": best.id, "ttml": "true"]) }
            return Self.map(data)
        } catch let e as MusicError where e == .notFound { return nil }
    }

    // MARK: key routes

    private func viaKey(_ apiKey: String, title: String, artist: String, term: String, seconds: Double?) async throws -> MusicLyrics? {
        let h = ["Authorization": "Bearer \(apiKey)"]
        if let u = URL(string: Self.api + "/lyrics/musixmatch") {
            var query = ["t": title, "a": artist]
            if let s = seconds, s > 0 { query["d"] = String(Int(s.rounded(.down))) }
            let q = query
            if let d = try? await MusicLyricsIO.withTimeout(Self.apiTimeout, { [http] in try await http.get(u, query: q, headers: h) }), let l = Self.map(d) { return l }
        }
        if let u = URL(string: Self.api + "/spotify/search"),
           let obj = try? await MusicLyricsIO.object(http, u, query: ["q": term], headers: h, timeout: Self.apiTimeout),
           let best = MusicCandidateScore.best(in: obj, title: title, artist: artist, seconds: seconds), let lu = URL(string: Self.api + "/lyrics/spotify"),
           let d = try? await MusicLyricsIO.withTimeout(Self.apiTimeout, { [http] in try await http.get(lu, query: ["id": best.id], headers: h) }), let l = Self.map(d) { return l }
        guard let u = URL(string: Self.api + "/lyrics/lrcget") else { return nil }
        let d = try await MusicLyricsIO.withTimeout(Self.apiTimeout) { [http] in try await http.get(u, query: ["q": term], headers: h) }
        return Self.chooseDocument(d, seconds: seconds)
    }

    /// Several candidate documents: metadata is the caller's business; here the one whose last stamp is nearest the song's length wins,
    /// then the one with the most timed lines, then the most word-timed lines.
    static func chooseDocument(_ data: Data, seconds: Double?) -> MusicLyrics? {
        guard let obj = try? JSONSerialization.jsonObject(with: data), let d = obj as? [String: Any], let docs = d["lyrics"] as? [Any] else { return map(data) }
        let parsed = docs.compactMap { doc -> MusicLyrics? in
            let text = (doc as? String) ?? (try? JSONSerialization.data(withJSONObject: doc)).flatMap { String(data: $0, encoding: .utf8) }
            return text.flatMap { MusicLyricsEnvelope.parse($0, source: MusicLyricsSources.name(MusicLyricsSources.paxSenix), provider: MusicLyricsSources.paxSenix, explicitSpacing: true) }
        }
        func key(_ l: MusicLyrics) -> (Double, Int, Int) {
            let lines = l.synced ?? []
            let last = Double(lines.map(\.resolvedEndMs).max() ?? 0) / 1000
            let dist = (seconds ?? 0) > 0 ? abs(last - (seconds ?? 0)) : 0
            return (dist, -lines.count, -lines.filter(\.isWordSynced).count)
        }
        return parsed.min { a, b in let x = key(a), y = key(b); return (x.0, x.1, x.2) < (y.0, y.1, y.2) }
    }

    // MARK: reading the answer

    static func map(_ data: Data) -> MusicLyrics? {
        let name = MusicLyricsSources.name(MusicLyricsSources.paxSenix)
        if let obj = try? JSONSerialization.jsonObject(with: data), let content = firstArray(named: "content", in: obj), let first = content.first as? [String: Any], first["text"] is [Any] || first["timestamp"] != nil,
           let lines = structured(content), !lines.isEmpty {
            return MusicLyricsNormalizer.normalize(MusicLyrics(synced: MusicLyricsGaps.insert(into: MusicLyricsBackground.splitAll(lines)), sourceName: name, providerID: MusicLyricsSources.paxSenix))
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return MusicLyricsEnvelope.parse(text, source: name, provider: MusicLyricsSources.paxSenix, explicitSpacing: true)
    }

    /// `content` rows `{timestamp, text:[{text, timestamp, endtime, part}]}`; `part: true` means the syllable continues into the next one.
    static func structured(_ content: [Any]) -> [MusicLyricLine]? {
        let rows = content.compactMap { $0 as? [String: Any] }
        var out: [MusicLyricLine] = []
        for (i, r) in rows.enumerated() {
            guard let start = MusicLyricsIO.int64(r["timestamp"]) else { continue }
            let lineEnd = rows[(i + 1)...].compactMap { MusicLyricsIO.int64($0["timestamp"]) }.first
            let sylls = (r["text"] as? [[String: Any]]) ?? []
            var runs: [MusicLyricWord] = []
            for (k, s) in sylls.enumerated() {
                guard let t = s["text"] as? String, !t.isEmpty else { continue }
                let st = MusicLyricsIO.int64(s["timestamp"]) ?? start
                let nextStart = sylls[(k + 1)...].compactMap { MusicLyricsIO.int64($0["timestamp"]) }.first
                let end = MusicLyricsIO.int64(s["endtime"]) ?? nextStart ?? lineEnd ?? (st + 800)
                let continues = (s["part"] as? Bool) == true
                runs.append(MusicLyricWord(text: continues ? t : t + " ", startMs: st, endMs: max(end, st)))
            }
            if runs.isEmpty {
                if let t = r["text"] as? String { out.append(MusicLyricLine(timeMs: start, text: t.trimmingCharacters(in: .whitespaces), endMs: lineEnd)) }
                continue
            }
            let words = MusicLyricsSyllables.glue(runs, explicitSpacing: true)
            let text = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            out.append(MusicLyricLine(timeMs: min(start, words.first?.startMs ?? start), text: text, endMs: words.last?.endMs, words: words))
        }
        return out.sorted { $0.timeMs < $1.timeMs }
    }

    static func firstArray(named key: String, in any: Any) -> [Any]? {
        if let d = any as? [String: Any] {
            if let a = d[key] as? [Any], !a.isEmpty, a.first is [String: Any] { return a }
            for v in d.values { if let r = firstArray(named: key, in: v) { return r } }
        } else if let a = any as? [Any] { for v in a { if let r = firstArray(named: key, in: v) { return r } } }
        return nil
    }
}
