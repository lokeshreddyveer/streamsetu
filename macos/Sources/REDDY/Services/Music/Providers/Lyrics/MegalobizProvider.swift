import Foundation

/// Megalobiz through its public lyrics API (no key; 30 requests a minute, so calls are spaced out).
struct MegalobizProvider: MusicLyricsRequestProvider {
    static let search = URL(string: "https://www.megalobiz.com/search/all")!
    static let host = "https://www.megalobiz.com"
    static let timeout = 6.0
    private let http: MusicHTTP
    init(http: MusicHTTP = MusicHTTP()) { self.http = http }

    var info: MusicProviderInfo {
        MusicProviderInfo(id: MusicLyricsSources.megalobiz, name: "Megalobiz", summary: MusicLyricsSources.about[MusicLyricsSources.megalobiz] ?? "",
                          privacyNote: "The artist and title of the song being played are sent to megalobiz.com to look up its lyrics. This source is unofficial.",
                          homepage: "https://www.megalobiz.com")
    }
    var capabilities: MusicCapabilities { [.lyrics] }

    static let api = URL(string: "https://api.megalobiz.com/api/public/v1")!

    func lyrics(for request: MusicLyricsRequest) async throws -> MusicLyrics? {
        let title = MusicLyricsTitleClean.title(request.title)
        guard !title.isEmpty else { return nil }
        var q = ["title": title, "limit": "5"]
        let artist = MusicLyricsTitleClean.artist(request.artists)
        if !artist.isEmpty { q["artist"] = artist }
        if let d = request.roundedDuration { q["duration"] = String(d) }
        let query = q
        await MegalobizPace.shared.wait()
        let sdata: Data
        do { sdata = try await MusicLyricsIO.withTimeout(Self.timeout) { [http] in try await http.get(Self.api.appendingPathComponent("search"), query: query) } }
        catch let e as MusicError where e == .notFound { return nil }
        for id in Self.ids(try MusicLyricsIO.parse(sdata), wanted: request.durationSeconds, title: title).prefix(2) {
            await MegalobizPace.shared.wait()
            let ldata: Data
            do { ldata = try await MusicLyricsIO.withTimeout(Self.timeout) { [http] in try await http.get(Self.api.appendingPathComponent("lrc/\(id)")) } }
            catch let e as MusicError where e == .notFound { continue }
            if let l = Self.map(try MusicLyricsIO.parse(ldata)) { return l }
        }
        return nil
    }

    /// Result ids, nearest length first (the service's own score breaks ties by keeping its order).
    /// With a wanted title, rows whose own title is another song are dropped (the site otherwise answers with the nearest length).
    static func ids(_ obj: Any, wanted: Double?, title: String? = nil) -> [String] {
        guard var rows = (obj as? [String: Any])?["results"] as? [[String: Any]] else { return [] }
        if let title {
            let want = JioSaavnLyricsProvider.base(title)
            rows = rows.filter { r in
                guard let t = r["title"] as? String, !t.isEmpty else { return true }
                return MusicTransliterationKey.similarity(want, JioSaavnLyricsProvider.base(t)) >= 0.85
            }
        }
        let ordered = MusicLyricsMatch.ordered(rows, wanted: wanted, window: 8) { MusicLyricsIO.seconds($0["duration"]) }
        return ordered.compactMap { MusicLyricsIO.int64($0["id"]).map(String.init) }
    }

    static func map(_ obj: Any) -> MusicLyrics? {
        guard let d = obj as? [String: Any] else { return nil }
        if let lines = d["lines"] as? [[String: Any]] {
            let parsed = lines.compactMap { l -> MusicLyricLine? in
                guard let t = MusicLyricsIO.int64(l["time_ms"]), let text = l["text"] as? String else { return nil }
                return MusicLyricLine(timeMs: t, text: text)
            }
            if !parsed.isEmpty {
                return MusicLyricsNormalizer.normalize(MusicLyrics(synced: parsed, sourceName: MusicLyricsSources.name(MusicLyricsSources.megalobiz), providerID: MusicLyricsSources.megalobiz))
            }
        }
        guard let lrc = d["lrc"] as? String, !lrc.isEmpty else { return nil }
        return MusicLyricsEnvelope.parse(lrc, source: MusicLyricsSources.name(MusicLyricsSources.megalobiz), provider: MusicLyricsSources.megalobiz)
    }

    private func html(_ url: URL, _ q: [String: String]) async throws -> String {
        let d = try await MusicLyricsIO.withTimeout(Self.timeout) { [http] in try await http.get(url, query: q) }
        return String(data: d, encoding: .utf8) ?? ""
    }

    static func firstLink(in html: String) -> String? {
        guard let r = html.range(of: ##"href="(/lrc/maker/[^"#?]+)""##, options: .regularExpression) else { return nil }
        let seg = String(html[r])
        return seg.dropFirst(6).dropLast().isEmpty ? nil : String(seg.dropFirst(6).dropLast())
    }

    /// The lyrics block (an element whose id looks like `lrc_123_details`): line breaks become newlines, tags are dropped, entities decoded.
    static func lrcText(in html: String) -> String? {
        guard let open = html.range(of: #"<(span|div)[^>]*id="lrc_[^"]*_details"[^>]*>"#, options: .regularExpression) else { return nil }
        let rest = String(html[open.upperBound...])
        let end = rest.range(of: "</span>")?.lowerBound ?? rest.range(of: "</div>")?.lowerBound ?? rest.endIndex
        var body = String(rest[..<end])
        body = body.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        body = body.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        body = MusicLyricsText.decodeEntities(body).trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }
}

/// Keeps Megalobiz calls two seconds apart (its public limit is 30 a minute).
actor MegalobizPace {
    static let shared = MegalobizPace()
    private var next = Date.distantPast
    func wait() async {
        let now = Date()
        let at = max(now, next)
        next = at.addingTimeInterval(2)
        let d = at.timeIntervalSince(now)
        if d > 0 { try? await Task.sleep(nanoseconds: UInt64(d * 1_000_000_000)) }
    }
}
