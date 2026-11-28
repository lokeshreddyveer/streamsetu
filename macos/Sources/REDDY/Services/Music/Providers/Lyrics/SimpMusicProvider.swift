import Foundation

/// SimpMusic: community lyrics filed under the video id. Some regions are refused with a 403, which counts as "no lyrics".
struct SimpMusicProvider: MusicLyricsRequestProvider {
    static let base = "https://api-lyrics.simpmusic.org/v1/"
    static let timeout = 6.0
    static let lengthWindow = 10.0
    private let http: MusicHTTP
    init(http: MusicHTTP = MusicHTTP()) { self.http = http }

    var info: MusicProviderInfo {
        MusicProviderInfo(id: MusicLyricsSources.simpMusic, name: "SimpMusic", summary: MusicLyricsSources.about[MusicLyricsSources.simpMusic] ?? "",
                          privacyNote: "The video id of the song being played is sent to api-lyrics.simpmusic.org, a community service. Some regions are not served.",
                          homepage: "https://simpmusic.org")
    }
    var capabilities: MusicCapabilities { [.lyrics] }

    func lyrics(for request: MusicLyricsRequest) async throws -> MusicLyrics? {
        guard !request.isLocal, !request.searched, let id = request.videoID, MusicLyricsText.plausibleVideoID(id), let url = URL(string: Self.base + id) else { return nil }
        let obj: Any
        do { obj = try await MusicLyricsIO.object(http, url, timeout: Self.timeout) }
        catch let e as MusicError where e == .notFound { return nil }
        catch MusicError.notSignedIn, MusicError.refused { return nil }
        return Self.map(obj, wantSeconds: request.durationSeconds)
    }

    static func map(_ obj: Any, wantSeconds: Double?) -> MusicLyrics? {
        guard let d = obj as? [String: Any], let rows = d["data"] as? [[String: Any]] else { return nil }
        let pick = MusicLyricsMatch.closest(rows, wanted: wantSeconds, window: lengthWindow) { MusicLyricsIO.seconds($0["duration"]) }
        guard let row = pick else { return nil }
        let name = MusicLyricsSources.name(MusicLyricsSources.simpMusic)
        for key in ["richSyncLyrics", "syncedLyrics"] {
            if let s = row[key] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let l = MusicLyricsEnvelope.parse(MusicLyricsText.decodeEntities(s), source: name, provider: MusicLyricsSources.simpMusic, explicitSpacing: false) { return l }
        }
        if let s = row["plainLyrics"] as? String { return MusicLyricsParsers.plainLyrics(MusicLyricsText.decodeEntities(s), source: name, provider: MusicLyricsSources.simpMusic) }
        return nil
    }
}
