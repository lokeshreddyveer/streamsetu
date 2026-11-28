import Foundation

/// Plain lyrics from JioSaavn's public web API, the same one its own website uses (text only, never audio). Very good for Hindi, Telugu, Tamil,
/// Kannada, Malayalam and Punjabi film songs, which the open databases often lack. The song is found by title (and the film or artist as a
/// hint), accepted only when the title, the version and the running time agree, and then its lyrics are read by id.
struct JioSaavnLyricsProvider: MusicLyricsRequestProvider {
    static let base = URL(string: "https://www.jiosaavn.com/api.php")!
    static let timeout = 5.0
    /// A cut this far off in length is another version (remix, unplugged).
    static let lengthWindow = 8.0
    private let http: MusicHTTP
    init(http: MusicHTTP = MusicHTTP()) { self.http = http }

    var info: MusicProviderInfo {
        MusicProviderInfo(id: MusicLyricsSources.jioSaavn, name: MusicLyricsSources.name(MusicLyricsSources.jioSaavn),
                          summary: MusicLyricsSources.about[MusicLyricsSources.jioSaavn] ?? "",
                          privacyNote: "The title and artist of the song being played are sent to www.jiosaavn.com, the same web address its own website uses, to find the song and read its lyrics. No account and no device id are sent. Only text is read.",
                          homepage: "https://www.jiosaavn.com")
    }
    var capabilities: MusicCapabilities { [.lyrics] }

    struct Candidate: Sendable, Hashable {
        var id: String
        var title: String
        var artists: String
        var seconds: Double?
        var hasLyrics: Bool
    }

    func lyrics(for request: MusicLyricsRequest) async throws -> MusicLyrics? {
        guard !request.isLocal, !request.title.isEmpty else { return nil }
        let cleaned = MusicLyricsQueryBuilder.cleanTitle(request.title)
        let title = cleaned.title.isEmpty ? MusicLyricsTitleClean.lrclibTitle(request.title) : cleaned.title
        let artist = MusicLyricsQueryBuilder.cleanArtists(request.artists)
        var q = title
        // The first credited person narrows the search; a song with no person named is searched with its film.
        if let first = artist.split(separator: ",").first { q += " " + first } else if let film = cleaned.film ?? request.album, !film.isEmpty { q += " " + film }
        let found = try await call("search.getResults", ["q": q, "p": "1", "n": "10"])
        guard let pick = Self.pick(Self.candidates(found), title: title, artist: artist, seconds: request.durationSeconds) else { return nil }
        let reply = try await call("lyrics.getLyrics", ["lyrics_id": pick.id])
        guard let text = Self.text(reply) else { return nil }
        return MusicLyrics(plain: text, sourceName: MusicLyricsSources.name(MusicLyricsSources.jioSaavn), providerID: MusicLyricsSources.jioSaavn)
    }

    private func call(_ name: String, _ extra: [String: String]) async throws -> Any {
        var q = ["__call": name, "_format": "json", "_marker": "0", "api_version": "4", "ctx": "web6dot0"]
        for (k, v) in extra { q[k] = v }
        do { return try await MusicLyricsIO.object(http, Self.base, query: q, timeout: Self.timeout) }
        catch let e as MusicError where e == .notFound { return [String: Any]() }
    }

    // MARK: readers

    static func candidates(_ obj: Any) -> [Candidate] {
        guard let d = obj as? [String: Any] else { return [] }
        return d.array("results").compactMap { r in
            guard let id = r.str("id") else { return nil }
            let more = r.dict("more_info") ?? [:]
            let has = (more["has_lyrics"] as? Bool) ?? ((more.str("has_lyrics") ?? "").lowercased() == "true")
            let sub = MusicLyricsText.decodeEntities(r.str("subtitle") ?? "")
            // "Artists - Album": the credit line is what comes before the last " - ".
            let credit = sub.range(of: " - ", options: .backwards).map { String(sub[..<$0.lowerBound]) } ?? sub
            return Candidate(id: id, title: MusicLyricsText.decodeEntities(r.str("title") ?? ""), artists: credit,
                             seconds: MusicLyricsIO.seconds(more["duration"]), hasLyrics: has)
        }
    }

    /// Every rule is a requirement: lyrics exist, the title agrees (spelling variants allowed), the version words agree, the length agrees
    /// when both are known, and when no length is known an artist must agree. The nearest length wins.
    static func pick(_ items: [Candidate], title: String, artist: String, seconds: Double?) -> Candidate? {
        let want = base(title)
        var best: (Candidate, Double)?
        for c in items where c.hasLyrics {
            guard MusicTransliterationKey.similarity(want, base(c.title)) >= 0.9 else { continue }
            guard MusicRecordingMatch.versions(want) == MusicRecordingMatch.versions(c.title) else { continue }
            let wa = MusicRecordingMatch.artists(artist)
            let artistOK = wa.isEmpty || !wa.isDisjoint(with: MusicRecordingMatch.artists(c.artists))
            var diff = 0.0
            if let w = seconds, w > 0, let s = c.seconds, s > 0 {
                diff = abs(w - s)
                if diff > lengthWindow { continue }
            } else if !wa.isEmpty && !artistOK { continue }
            // A wrong artist with a matching length is still accepted (the playing artist is often a channel); it just ranks below.
            let score = diff + (artistOK ? 0 : 3)
            if best == nil || score < (best?.1 ?? .infinity) { best = (c, score) }
        }
        return best?.0
    }

    /// The title without brackets, upload words and a " - Male" style suffix.
    static func base(_ s: String) -> String {
        var t = MusicLyricsTitleClean.lrclibTitle(s)
        if let r = t.range(of: " - ") { t = String(t[..<r.lowerBound]) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// The reply's `lyrics` text with line breaks restored and entities decoded; nil when empty.
    static func text(_ obj: Any) -> String? {
        guard let d = obj as? [String: Any], let raw = d["lyrics"] as? String else { return nil }
        var t = raw.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        t = MusicLyricsText.decodeEntities(t).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count >= 20 ? t : nil
    }
}
