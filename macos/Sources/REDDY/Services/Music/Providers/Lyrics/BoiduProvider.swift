import Foundation

/// Boidu, the Better Lyrics cache of Apple lyrics as TTML. Answers only from its own cache and replies 401 for a miss; the cache key
/// includes the album, and some songs are cached with it and some without, so the album form is tried first and the bare one second.
struct BoiduProvider: MusicLyricsRequestProvider {
    static let url = URL(string: "https://lyrics-api.boidu.dev/getLyrics")!
    static let timeout = 8.0
    private let http: MusicHTTP
    init(http: MusicHTTP = MusicHTTP()) { self.http = http }

    var info: MusicProviderInfo {
        MusicProviderInfo(id: MusicLyricsSources.boidu, name: "Boidu", summary: MusicLyricsSources.about[MusicLyricsSources.boidu] ?? "",
                          privacyNote: "The title, artist, album and length of the song being played are sent to lyrics-api.boidu.dev.",
                          homepage: "https://better-lyrics.boidu.dev")
    }
    var capabilities: MusicCapabilities { [.lyrics] }

    func lyrics(for request: MusicLyricsRequest) async throws -> MusicLyrics? {
        // The server matches on the exact length, so without one there is nothing to ask.
        guard let d = request.roundedDuration, !request.title.isEmpty else { return nil }
        let base = ["s": request.title, "a": request.artists, "d": String(d)]
        var forms: [[String: String]] = []
        if let al = request.album { var withAlbum = base; withAlbum["al"] = al; forms.append(withAlbum) }
        forms.append(base)
        for (i, q) in forms.enumerated() {
            do {
                let data = try await MusicLyricsIO.withTimeout(Self.timeout) { [http] in try await http.get(Self.url, query: q) }
                return try Self.map(data)
            } catch MusicError.notSignedIn, MusicError.refused {
                if i == forms.count - 1 { return nil }
            } catch let e as MusicError where e == .notFound {
                if i == forms.count - 1 { return nil }
            }
        }
        return nil
    }

    /// First present, non-empty value of `ttml`, `syncedLyrics`, `lyrics`, `lrc`; an array value is re-serialised and parsed as JSON.
    static func map(_ data: Data) throws -> MusicLyrics? {
        let obj = try MusicLyricsIO.parse(data)
        guard let d = obj as? [String: Any] else { throw MusicError.network("unreadable answer") }
        for key in ["ttml", "syncedLyrics", "lyrics", "lrc"] {
            var text: String?
            if let s = d[key] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = s } else if let a = d[key] as? [Any], !a.isEmpty,
                      let j = try? JSONSerialization.data(withJSONObject: a), let s = String(data: j, encoding: .utf8) { text = s }
            if let text { return MusicLyricsParsers.lyrics(from: text, source: MusicLyricsSources.name(MusicLyricsSources.boidu), provider: MusicLyricsSources.boidu) }
        }
        return nil
    }
}
