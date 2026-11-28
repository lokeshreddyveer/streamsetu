import Foundation

/// BiniLyrics: the same Apple timings as lrc.red, matched on the recording itself. Also the recording finder: one search by name,
/// capped at 2.5 s, tells the other sources which recording is playing.
struct BiniLyricsProvider: MusicLyricsRequestProvider {
    static let apiURL = URL(string: "https://lrc.red/api/v1")!
    static let timeout = 6.0
    static let identifyCap = 2.5
    private let http: MusicHTTP
    init(http: MusicHTTP = MusicHTTP()) { self.http = http }

    var info: MusicProviderInfo {
        MusicProviderInfo(id: MusicLyricsSources.bini, name: "BiniLyrics", summary: MusicLyricsSources.about[MusicLyricsSources.bini] ?? "",
                          privacyNote: "The title, artist, album and length of the song being played, and its recording code when known, are sent to lyrics-api.binimum.org, a service run by an individual. Its lyrics come from Apple Music without a licence agreement, so this source is unofficial.",
                          homepage: "https://lyrics-api.binimum.org")
    }
    var capabilities: MusicCapabilities { [.lyrics] }

    struct Result: Sendable, Hashable {
        var title: String; var artist: String; var seconds: Double?; var isrc: String?; var url: String?; var timing: String
    }

    func lyrics(for request: MusicLyricsRequest) async throws -> MusicLyrics? {
        var documentURL = request.identified?.documentURL
        if documentURL == nil {
            if let isrc = MusicISRC.normalize(request.isrc) {
                let rows = try await query(["isrc": isrc])
                documentURL = rows.first?.url
            } else if let hit = try await search(request) { documentURL = hit.url }
        }
        guard let s = documentURL, let url = URL(string: s), url.scheme == "https" else { return nil }
        let data: Data
        do { data = try await MusicLyricsDocumentFetcher.shared.data(url, http: http, timeout: Self.timeout) } catch let e as MusicError where e == .notFound { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return MusicLyricsEnvelope.parse(text, source: MusicLyricsSources.name(MusicLyricsSources.bini), provider: MusicLyricsSources.bini)
    }

    /// The recording finder: an accepted hit by name, with its code and document address. Nil when nothing matches.
    func identify(_ request: MusicLyricsRequest) async -> MusicLyricsIdentified? {
        guard let hit = try? await MusicLyricsIO.withTimeout(Self.identifyCap, { try await self.search(request) }), let isrc = MusicISRC.normalize(hit.isrc) else { return nil }
        return MusicLyricsIdentified(isrc: isrc, documentURL: hit.url)
    }

    private func search(_ request: MusicLyricsRequest) async throws -> Result? {
        guard !request.title.isEmpty else { return nil }
        let title = MusicLyricsTitleClean.title(request.title), artist = MusicLyricsTitleClean.artist(request.artists)
        var q = ["track": title, "artist": artist]
        if let al = request.album { q["album"] = al }
        if request.hasDuration, let d = request.durationSeconds { q["duration"] = String(Int(d.rounded(.down))) }
        let rows = try await query(q)
        return Self.pick(rows, title: title, artist: artist, seconds: request.durationSeconds)
    }

    private func query(_ q: [String: String]) async throws -> [Result] {
        let obj: Any
        do { obj = try await MusicLyricsIO.object(http, Self.apiURL, query: q, timeout: Self.timeout) } catch let e as MusicError where e == .notFound { return [] }
        return Self.results(obj)
    }

    static func results(_ obj: Any) -> [Result] {
        guard let d = obj as? [String: Any], let rows = d["results"] as? [[String: Any]] else { return [] }
        return rows.map { r in
            Result(title: (r["track_name"] as? String) ?? "", artist: (r["artist_name"] as? String) ?? "", seconds: MusicLyricsIO.seconds(r["duration"]),
                   isrc: r["isrc"] as? String, url: r["lyricsUrl"] as? String, timing: (r["timing_type"] as? String) ?? "none")
        }
    }

    static func pick(_ rows: [Result], title: String, artist: String, seconds: Double?) -> Result? {
        MusicRecordingMatch.pick(rows, wantSeconds: seconds,
                                 accepts: { $0.url != nil && MusicRecordingMatch.accepts(wantTitle: title, wantArtist: artist, wantSeconds: seconds, title: $0.title, artist: $0.artist, seconds: $0.seconds) },
                                 seconds: { $0.seconds })
    }
}
