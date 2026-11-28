import Foundation

/// Community's lyrics service, read side. Lyrics are filed under a video id; with a known length the server may answer with another upload of
/// the same song. Keyed by revision so a cached copy can be revalidated with If-None-Match.
struct CommunityLyricsProvider: MusicLyricsRequestProvider {
    static let base = URL(string: "https://lyrics.limusic.app")!
    static let timeout = 2.0
    static let hintTimeout = 8.0
    private let http: MusicHTTP
    init(http: MusicHTTP = MusicHTTP()) { self.http = http }

    var info: MusicProviderInfo {
        MusicProviderInfo(id: MusicLyricsSources.community, name: "Community lyrics", summary: MusicLyricsSources.about[MusicLyricsSources.community] ?? "",
                          privacyNote: "The video id, title, artist and length of the song being played are sent to the community lyrics service. When a lyric from another source is word by word, the service may be told the song is being played so it can fetch it too.",
                          homepage: Self.base.absoluteString)
    }
    var capabilities: MusicCapabilities { [.lyrics] }

    enum Fetch: Sendable { case lyrics(MusicLyrics), notModified, none }

    func lyrics(for request: MusicLyricsRequest) async throws -> MusicLyrics? {
        if case .lyrics(let l) = try await fetch(request, filedID: nil, revision: nil) { return l }
        return nil
    }

    /// `filedID` asks for exactly the id a cached lyric was filed under (revalidation); `revision` adds If-None-Match.
    func fetch(_ request: MusicLyricsRequest, filedID: String?, revision: Int?) async throws -> Fetch {
        guard !request.searched, !request.isLocal, let asked = filedID ?? request.videoID, MusicLyricsText.plausibleVideoID(asked) else { return .none }
        let url = Self.base.appendingPathComponent("v1/lyrics/\(asked)")
        var q: [String: String] = [:]
        if filedID == nil, request.hasDuration, let d = request.roundedDuration {
            q = ["title": request.title.trimmingCharacters(in: .whitespacesAndNewlines),
                 "artist": request.artists.trimmingCharacters(in: .whitespacesAndNewlines), "duration": String(d)]
        }
        var headers: [String: String] = [:]
        if let revision { headers["If-None-Match"] = "\"\(revision)\"" }
        let data: Data
        let query = q, sent = headers
        do { data = try await MusicLyricsIO.withTimeout(Self.timeout) { [http] in try await http.get(url, query: query, headers: sent) } }
        catch let e as MusicError where e == .notFound { return .none }
        catch { if MusicLyricsIO.isNotModified(error) { return .notModified }; throw error }
        guard let l = Self.map(try MusicLyricsIO.parse(data), askedID: asked) else { return .none }
        return .lyrics(l)
    }

    // MARK: mapping

    static func map(_ obj: Any, askedID: String) -> MusicLyrics? {
        guard let d = obj as? [String: Any], let rows = d["lines"] as? [[String: Any]] else { return nil }
        let lines = rows.compactMap(line)
        guard !lines.isEmpty else { return nil }
        let origin = (d["origin"] as? String)?.lowercased() ?? ""
        let via: String? = [MusicLyricsSources.unison, MusicLyricsSources.boidu, MusicLyricsSources.lyricsPlus].contains(origin) ? MusicLyricsSources.name(origin) : nil
        var authors: [String] = []
        if origin == "community", let a = d["authors"] as? [String] {
            authors = Array(a.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(5))
        }
        let l = MusicLyrics(synced: lines, sourceName: MusicLyricsSources.name(MusicLyricsSources.community), providerID: MusicLyricsSources.community,
                            revision: MusicLyricsIO.int64(d["revision"]).map(Int.init), authors: authors, via: via,
                            communityID: (d["video_id"] as? String) ?? askedID)
        return MusicLyricsNormalizer.normalize(l)
    }

    private static func words(_ any: Any?) -> [MusicLyricWord]? {
        guard let arr = any as? [[String: Any]], !arr.isEmpty else { return nil }
        let w = arr.compactMap { x -> MusicLyricWord? in
            guard let t = x["text"] as? String, let s = MusicLyricsIO.int64(x["start_ms"]) else { return nil }
            return MusicLyricWord(text: t, startMs: s, endMs: MusicLyricsIO.int64(x["end_ms"]) ?? s, background: (x["bg"] as? Bool) ?? false)
        }
        return w.isEmpty ? nil : w
    }

    private static func line(_ r: [String: Any]) -> MusicLyricLine? {
        let w = words(r["words"])
        guard let t = MusicLyricsIO.int64(r["time_ms"]) ?? w?.map(\.startMs).min() else { return nil }
        var l = MusicLyricLine(timeMs: t, text: (r["text"] as? String) ?? "", endMs: MusicLyricsIO.int64(r["end_time_ms"]), words: w)
        if let a = r["agent"] as? String, MusicLyricsVoices.isValidAgent(a) { l.voice = a }
        l.translation = (r["translation"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        l.romanized = (r["romanized"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        l.romanizedWords = words(r["romanized_words"])
        return l
    }

    // MARK: hint

    /// Whether a finished walk should tell the service about a word-timed lyric it mirrors. Not for searches, local files, a lyric that
    /// is not word-timed, Community's own answer, or when Community is switched off.
    static func shouldHint(winner: MusicLyrics, request: MusicLyricsRequest, communityOn: Bool) -> Bool {
        guard communityOn, !request.searched, !request.isLocal, let v = request.videoID, MusicLyricsText.plausibleVideoID(v) else { return false }
        guard [MusicLyricsSources.boidu, MusicLyricsSources.unison, MusicLyricsSources.lyricsPlus].contains(winner.providerID) else { return false }
        return winner.isWordTimed
    }

    static func hintBody(request: MusicLyricsRequest, provider: String) -> Data? {
        guard let v = request.videoID else { return nil }
        var body: [String: Any] = ["video_id": v, "provider": provider, "title": request.title, "artist": request.artists]
        if let a = request.album { body["album"] = a }
        if let d = request.roundedDuration { body["duration"] = d }
        return try? JSONSerialization.data(withJSONObject: body)
    }

    /// One fire-and-forget POST; the answer is ignored and a failure changes nothing.
    func sendHint(request: MusicLyricsRequest, provider: String) async {
        guard let body = Self.hintBody(request: request, provider: provider) else { return }
        let url = Self.base.appendingPathComponent("v1/hints")
        _ = try? await MusicLyricsIO.withTimeout(Self.hintTimeout) { [http] in try await http.postJSON(url, body: body) }
    }
}
