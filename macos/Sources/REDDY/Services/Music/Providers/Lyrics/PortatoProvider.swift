import Foundation

/// BetterLyrics Portato: QQ Music karaoke timings served through the BetterLyrics host. Same questions as Boidu, one request.
struct PortatoProvider: MusicLyricsRequestProvider {
    static let url = URL(string: "https://lyrics-api.boidu.dev/qq/getLyrics")!
    static let timeout = 6.0
    private let http: MusicHTTP
    init(http: MusicHTTP = MusicHTTP()) { self.http = http }

    var info: MusicProviderInfo {
        MusicProviderInfo(id: MusicLyricsSources.portato, name: "BetterLyrics Portato", summary: MusicLyricsSources.about[MusicLyricsSources.portato] ?? "",
                          privacyNote: "The title, artist, album and length of the song being played are sent to lyrics-api.boidu.dev, which answers with timings taken from QQ Music, a Chinese service. This source is unofficial.",
                          homepage: "https://better-lyrics.boidu.dev")
    }
    var capabilities: MusicCapabilities { [.lyrics] }

    func lyrics(for request: MusicLyricsRequest) async throws -> MusicLyrics? {
        guard !request.title.isEmpty else { return nil }
        var query = ["s": request.title, "a": request.artists]
        if let d = request.roundedDuration { query["d"] = String(d) }
        if let al = request.album { query["al"] = al }
        let q = query
        let data: Data
        do { data = try await MusicLyricsIO.withTimeout(Self.timeout) { [http] in try await http.get(Self.url, query: q) } }
        catch let e as MusicError where e == .notFound { return nil }
        catch MusicError.notSignedIn, MusicError.refused { return nil }
        return Self.map(data)
    }

    static func map(_ data: Data) -> MusicLyrics? {
        guard let text = String(data: data, encoding: .utf8), let l = MusicLyricsEnvelope.parse(text, source: MusicLyricsSources.name(MusicLyricsSources.portato), provider: MusicLyricsSources.portato) else { return nil }
        return isPlaceholder(l) ? nil : l
    }

    /// The service answers "instrumental" or a single note instead of lyrics for tracks it has no words for.
    static func isPlaceholder(_ l: MusicLyrics) -> Bool {
        let texts = (l.synced?.map(\.text) ?? [l.plain ?? ""]).map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " []()♪♫-")) }.filter { !$0.isEmpty }
        return texts.isEmpty || texts.allSatisfy { $0 == "instrumental" || $0 == "music" }
    }
}
