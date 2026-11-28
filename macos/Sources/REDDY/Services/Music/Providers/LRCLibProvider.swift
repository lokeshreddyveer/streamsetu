import Foundation

/// Lyrics from LRCLIB, a free community database with time-synced lyrics.
/// Exact lookup first, then a search that picks the cut whose length is closest, then free-text searches with a cleaned title.
struct LRCLibProvider: MusicLyricsRequestProvider {
    static let getURL = URL(string: "https://lrclib.net/api/get")!
    static let searchURL = URL(string: "https://lrclib.net/api/search")!
    static let timeout = 8.0
    /// Several cuts of a song exist; a cut this far off plays the lyrics visibly out of step.
    static let lengthWindow = 5.0
    private let http: MusicHTTP

    init(http: MusicHTTP = MusicHTTP()) { self.http = http }

    var info: MusicProviderInfo {
        MusicProviderInfo(
            id: "lrclib", name: "LRCLIB", summary: "Free synced and plain lyrics from a community database.",
            privacyNote: "The title, artist, album and length of the song being played are sent to lrclib.net to look up its lyrics. Nothing else is sent.",
            homepage: "https://lrclib.net")
    }
    var capabilities: MusicCapabilities { [.lyrics] }

    /// The exact lookup (with the length), the structured search and the free-text search run side by side; the answer is the first timed
    /// result in that order of trust (exact, structured, free text), so a slow free-text search never delays an exact hit.
    func lyrics(for request: MusicLyricsRequest) async throws -> MusicLyrics? {
        var q = ["track_name": request.title, "artist_name": request.artists]
        if let album = request.album { q["album_name"] = album }
        if let d = request.roundedDuration { q["duration"] = String(d) }
        var s = ["track_name": request.title]
        if !request.artists.isEmpty { s["artist_name"] = request.artists }
        let free = request.searchTitle.isEmpty ? nil : "\(request.searchTitle) \(request.artists)".trimmingCharacters(in: .whitespaces)
        let http = self.http, want = request.durationSeconds, exactQuery = q, structuredQuery = s, title = request.title, artists = request.artists

        async let exact: Result<MusicLyrics?, Error> = Self.attempt {
            let obj = try await MusicLyricsIO.object(http, Self.getURL, query: exactQuery, timeout: Self.timeout)
            return (obj as? [String: Any]).flatMap(Self.mapLyrics)
        }
        async let structured: Result<MusicLyrics?, Error> = Self.attempt {
            let obj = try await MusicLyricsIO.object(http, Self.searchURL, query: structuredQuery, timeout: Self.timeout)
            return Self.pick((obj as? [[String: Any]]) ?? [], wantSeconds: want, title: title, artists: artists)
        }
        async let text: Result<MusicLyrics?, Error> = Self.attempt {
            guard let free else { return nil }
            let obj = try await MusicLyricsIO.object(http, Self.searchURL, query: ["q": free], timeout: Self.timeout)
            return Self.pick((obj as? [[String: Any]]) ?? [], wantSeconds: want, title: title, artists: artists).flatMap { $0.isSynced ? $0 : nil }
        }

        var fallback: MusicLyrics?
        var failures = 0
        for r in [await exact, await structured, await text] {
            switch r {
            case .success(let l):
                guard let l else { continue }
                if l.instrumental || l.isSynced { return l }
                fallback = Self.better(fallback, l)
            case .failure(let e):
                if e is CancellationError { throw e }
                failures += 1
            }
        }
        if fallback == nil, failures == 3 { throw MusicError.network("LRCLIB unreachable") }
        return fallback
    }

    /// A "not found" is a definitive nothing; any other failure is carried to the caller.
    private static func attempt(_ op: @escaping @Sendable () async throws -> MusicLyrics?) async -> Result<MusicLyrics?, Error> {
        do { return .success(try await op()) }
        catch let e as MusicError where e == .notFound { return .success(nil) }
        catch { return .failure(error) }
    }

    private func search(_ query: [String: String]) async throws -> [[String: Any]] {
        let obj = try await MusicLyricsIO.object(http, Self.searchURL, query: query, timeout: Self.timeout)
        return (obj as? [[String: Any]]) ?? []
    }

    // MARK: selection

    /// Instrumental beats synced beats plain.
    private static func better(_ a: MusicLyrics?, _ b: MusicLyrics) -> MusicLyrics {
        guard let a else { return b }
        func rank(_ l: MusicLyrics) -> Int { l.instrumental ? 2 : (l.isSynced ? 1 : 0) }
        return rank(b) > rank(a) ? b : a
    }

    /// Drops candidates whose own length is more than 5 s off (those with no length stay, ranked last). Among the survivors prefers the
    /// synced one whose length is CLOSEST; otherwise the first plain one.
    /// Searches answer with songs that merely look alike (the same title by other singers), so a candidate must be the requested song:
    /// - Singers share a name and the length is within `lengthWindow`: the usual match.
    /// - Singers share a name but the length is off by up to `looseWindow` (a video with an intro or an outro): a fallback, taken only when nothing fits closely, and the plain text is
    ///   preferred then because the timing may be off.
    /// - The singers do not overlap because the "artist" is the uploader of a video (a channel such as "Vel Records", not a singer): only an exact title with a length within `exactWindow`.
    ///   A real singer who does not match is still refused (the Hindi "Radhe Radhe" is not the Telugu one).
    static func pick(_ rows: [[String: Any]], wantSeconds: Double?, title: String? = nil, artists: String? = nil) -> MusicLyrics? {
        struct Cand { var lyrics: MusicLyrics; var diff: Double? }
        var close: [Cand] = [], loose: [Cand] = []
        for row in rows {
            guard !((row["instrumental"] as? Bool) ?? false), let l = mapLyrics(row) else { continue }
            let own = MusicLyricsIO.seconds(row["duration"]).flatMap { $0 > 0 ? $0 : nil }
            guard let title else {
                if let want = wantSeconds, want > 0 {
                    if let own { if abs(own - want) > lengthWindow { continue }; close.append(Cand(lyrics: l, diff: abs(own - want))) } else { close.append(Cand(lyrics: l, diff: nil)) }
                } else { close.append(Cand(lyrics: l, diff: 0)) }
                continue
            }
            let (contains, exact) = titleMatch(row, title: title)
            guard contains else { continue }
            let want = (wantSeconds ?? 0) > 0 ? wantSeconds : nil
            if artistsOverlap(row, artists: artists ?? "") {
                if let want, let own {
                    let d = abs(own - want)
                    if d <= lengthWindow { close.append(Cand(lyrics: l, diff: d)) }
                    else if d <= looseWindow { loose.append(Cand(lyrics: l, diff: d)) }
                } else { close.append(Cand(lyrics: l, diff: want == nil ? 0 : nil)) }
            } else if exact, MusicLyricsQueryBuilder.looksLikeChannel(artists ?? ""), let want, let own, abs(own - want) <= exactWindow {
                close.append(Cand(lyrics: l, diff: abs(own - want)))
            }
        }
        func best(_ list: [Cand], preferPlain: Bool) -> MusicLyrics? {
            let synced = list.filter { $0.lyrics.isSynced }
            let plain = list.filter { !($0.lyrics.plain ?? "").isEmpty }
            func nearest(_ l: [Cand]) -> MusicLyrics? { (l.filter { $0.diff != nil }.min { ($0.diff ?? 0) < ($1.diff ?? 0) } ?? l.first)?.lyrics }
            if preferPlain { return nearest(plain) ?? nearest(synced) }
            return nearest(synced) ?? plain.first?.lyrics
        }
        return best(close, preferPlain: false) ?? best(loose, preferPlain: true)
    }

    static let looseWindow = 25.0
    static let exactWindow = 3.0

    /// The row's title holds the requested title (or the other way round), and whether the two are the same once the film part is cleaned off.
    static func titleMatch(_ row: [String: Any], title: String) -> (contains: Bool, exact: Bool) {
        let rowRaw = (row["trackName"] as? String) ?? (row["name"] as? String) ?? ""
        let rowTitle = MusicText.normalize(rowRaw)
        let wantTitle = MusicText.normalize(MusicLyricsText.searchTitle(title).isEmpty ? title : MusicLyricsText.searchTitle(title))
        if rowTitle.isEmpty || wantTitle.isEmpty { return (true, false) }
        let contains = rowTitle.contains(wantTitle) || wantTitle.contains(rowTitle)
        let rowClean = MusicText.normalize(MusicLyricsText.searchTitle(rowRaw).isEmpty ? rowRaw : MusicLyricsText.searchTitle(rowRaw))
        return (contains, rowClean == wantTitle || rowTitle == wantTitle)
    }

    /// When both sides name artists they share at least one name of three letters or more ("G.V. Prakash Kumar" and "G. V. Prakash Kumar" share "prakash" and "kumar").
    static func artistsOverlap(_ row: [String: Any], artists: String) -> Bool {
        func words(_ s: String) -> Set<String> { Set(MusicText.normalize(s).split(separator: " ").map(String.init).filter { $0.count >= 3 }) }
        let want = words(artists), have = words((row["artistName"] as? String) ?? "")
        return want.isEmpty || have.isEmpty || !want.isDisjoint(with: have)
    }

    /// Whether a search row is the requested song by title and singers (the strict reading, kept for callers that only ask this).
    static func sameSong(_ row: [String: Any], title: String, artists: String) -> Bool {
        titleMatch(row, title: title).contains && artistsOverlap(row, artists: artists)
    }

    static func mapLyrics(_ d: [String: Any]) -> MusicLyrics? {
        if (d["instrumental"] as? Bool) == true { return MusicLyrics(sourceName: "LRCLIB", providerID: "lrclib", instrumental: true) }
        let synced = (d["syncedLyrics"] as? String).map(MusicLyricsParsers.parseLRC).flatMap { $0.isEmpty ? nil : $0 }
        let plain = (d["plainLyrics"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        guard synced != nil || plain != nil else { return nil }
        return MusicLyricsNormalizer.normalize(MusicLyrics(synced: synced, plain: plain, sourceName: "LRCLIB", providerID: "lrclib"))
    }

}
