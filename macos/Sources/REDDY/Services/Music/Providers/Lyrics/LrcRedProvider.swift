import Foundation

/// lrc.red: Apple Music timings re-hosted by an individual, looked up by recording code. Unofficial; the privacy note says so.
struct LrcRedProvider: MusicLyricsRequestProvider {
    static let documentBase = "https://lrc.red/s/"
    static let searchURL = URL(string: "https://lrc.red/search.json")!
    static let timeout = 6.0
    private let http: MusicHTTP
    init(http: MusicHTTP = MusicHTTP()) { self.http = http }

    var info: MusicProviderInfo {
        MusicProviderInfo(id: MusicLyricsSources.lrcRed, name: "lrc.red", summary: MusicLyricsSources.about[MusicLyricsSources.lrcRed] ?? "",
                          privacyNote: "The title and artist of the song being played, and its recording code when known, are sent to lrc.red, a lyrics site run by an individual. Its lyrics come from Apple Music without a licence agreement, so this source is unofficial.",
                          homepage: "https://lrc.red")
    }
    var capabilities: MusicCapabilities { [.lyrics] }

    struct Hit: Sendable, Hashable { var isrc: String; var title: String; var artist: String; var seconds: Double? }

    func lyrics(for request: MusicLyricsRequest) async throws -> MusicLyrics? {
        let source = MusicLyricsSources.name(MusicLyricsSources.lrcRed)
        if let isrc = MusicISRC.normalize(request.isrc), let l = try await document(isrc, source: source) { return l }
        guard !request.title.isEmpty else { return nil }
        let title = MusicLyricsTitleClean.title(request.title), artist = MusicLyricsTitleClean.artist(request.artists)
        let obj: Any
        do { obj = try await MusicLyricsIO.object(http, Self.searchURL, query: ["q": "\(title) \(artist)".trimmingCharacters(in: .whitespaces)], timeout: Self.timeout) }
        catch let e as MusicError where e == .notFound { return nil }
        guard let hit = Self.pick(obj, title: title, artist: artist, seconds: request.durationSeconds) else { return nil }
        return try await document(hit.isrc, source: source)
    }

    private func document(_ isrc: String, source: String) async throws -> MusicLyrics? {
        guard let url = URL(string: Self.documentBase + isrc + ".ttml") else { return nil }
        let data: Data
        do { data = try await MusicLyricsDocumentFetcher.shared.data(url, http: http, timeout: Self.timeout) } catch let e as MusicError where e == .notFound { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return MusicLyricsEnvelope.parse(text, source: source, provider: MusicLyricsSources.lrcRed)
    }

    static func hits(_ obj: Any) -> [Hit] {
        guard let d = obj as? [String: Any], let rows = d["hits"] as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let isrc = MusicISRC.normalize(r["isrc"] as? String) else { return nil }
            return Hit(isrc: isrc, title: (r["title"] as? String) ?? "", artist: (r["artist"] as? String) ?? "", seconds: MusicLyricsIO.seconds(r["duration"]))
        }
    }

    static func pick(_ obj: Any, title: String, artist: String, seconds: Double?) -> Hit? {
        MusicRecordingMatch.pick(hits(obj), wantSeconds: seconds,
                                 accepts: { MusicRecordingMatch.accepts(wantTitle: title, wantArtist: artist, wantSeconds: seconds, title: $0.title, artist: $0.artist, seconds: $0.seconds) },
                                 seconds: { $0.seconds })
    }
}
