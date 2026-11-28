import Foundation

/// Unison, the Better Lyrics community database (ODbL data: the picker credits it). Asked by video id first (it files lyrics under the
/// exact upload), then by title, artist, album and length on the newer host, then by name on the original host.
struct UnisonProvider: MusicLyricsRequestProvider {
    static let url = URL(string: "https://unison.betterlyrics.org/lyrics")!
    static let nameURL = URL(string: "https://unison.boidu.dev/lyrics")!
    static let timeout = 8.0
    private let http: MusicHTTP
    init(http: MusicHTTP = MusicHTTP()) { self.http = http }

    var info: MusicProviderInfo {
        MusicProviderInfo(id: MusicLyricsSources.unison, name: "Unison", summary: MusicLyricsSources.about[MusicLyricsSources.unison] ?? "",
                          privacyNote: "The video id (or title, artist, album and length) of the song being played is sent to unison.betterlyrics.org and unison.boidu.dev. Its lyrics are shared under the ODbL licence.",
                          homepage: "https://unison.betterlyrics.org")
    }
    var capabilities: MusicCapabilities { [.lyrics] }

    func lyrics(for request: MusicLyricsRequest) async throws -> MusicLyrics? {
        var attempts: [(URL, [String: String])] = []
        if let v = request.videoID, !request.searched, !request.isLocal { attempts.append((Self.url, ["v": v])) }
        // The name search needs an artist (it answers 400 without one).
        if !request.title.isEmpty, !request.artists.isEmpty {
            var q = ["song": request.title, "artist": request.artists]
            if let al = request.album, !request.searched { q["album"] = al }
            if let d = request.roundedDuration { q["duration"] = String(d) }
            attempts.append((Self.nameURL, q))
            var old = ["song": request.title, "artist": request.artists]
            if let d = request.roundedDuration { old["duration"] = String(d) }
            attempts.append((Self.url, old))
        }
        var failure: Error?
        for (url, q) in attempts {
            do {
                let obj = try await MusicLyricsIO.object(http, url, query: q, timeout: Self.timeout)
                if let l = Self.map(obj) { return l }
            } catch let e as MusicError where e == .notFound {
                continue
            } catch {
                if error is CancellationError { throw error }
                failure = error
            }
        }
        if let failure { throw failure }
        return nil
    }

    /// `format` ttml reads as TTML; `syncType` plain (or format plain) is one line per non-blank line; anything else is enhanced LRC and,
    /// without word stamps, plain LRC. Votes and confidence are not used: fresh submissions have none, and filtering would drop most of it.
    static func map(_ obj: Any) -> MusicLyrics? {
        guard let d = obj as? [String: Any], let data = d["data"] as? [String: Any], let text = data["lyrics"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let name = MusicLyricsSources.name(MusicLyricsSources.unison)
        let format = (data["format"] as? String)?.lowercased() ?? "", sync = (data["syncType"] as? String)?.lowercased() ?? ""
        if format == "plain" || sync == "plain" { return MusicLyricsParsers.plainLyrics(text, source: name, provider: MusicLyricsSources.unison) }
        if format == "ttml" { return MusicLyricsEnvelope.parse(text, source: name, provider: MusicLyricsSources.unison) }
        return MusicLyricsParsers.lyrics(from: text, source: name, provider: MusicLyricsSources.unison)
    }
}
