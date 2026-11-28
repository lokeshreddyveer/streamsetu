import Foundation

/// Netease Cloud Music (unofficial endpoints). The only source that carries translations.
struct NeteaseProvider: MusicLyricsRequestProvider {
    static let search = URL(string: "https://music.163.com/api/search/get")!
    static let lyric = URL(string: "https://music.163.com/api/song/lyric")!
    static let timeout = 8.0
    private let http: MusicHTTP
    init(http: MusicHTTP = MusicHTTP()) { self.http = http }

    var info: MusicProviderInfo {
        MusicProviderInfo(id: MusicLyricsSources.netease, name: "Netease Cloud Music", summary: MusicLyricsSources.about[MusicLyricsSources.netease] ?? "",
                          privacyNote: "The title and artist of the song being played are sent to music.163.com (a Chinese service), along with your IP address.")
    }
    var capabilities: MusicCapabilities { [.lyrics] }

    private var headers: [String: String] { ["Referer": "https://music.163.com/"] }

    func lyrics(for request: MusicLyricsRequest) async throws -> MusicLyrics? {
        let term = "\(request.title) \(request.artists)".trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return nil }
        let h = headers
        let fields = ["s": term, "type": "1", "limit": "5", "offset": "0"]
        let sdata = try await MusicLyricsIO.withTimeout(Self.timeout) { [http] in try await http.postForm(Self.search, fields: fields, headers: h) }
        let ids = Self.songIDs(try MusicLyricsIO.parse(sdata), wanted: request.durationSeconds)
        // The nearest entry often has no lyric text; the next ones are tried until one does (three at most).
        for id in ids.prefix(3) {
            let ldata: Data
            do {
                ldata = try await MusicLyricsIO.withTimeout(Self.timeout) { [http] in
                    try await http.get(Self.lyric, query: ["id": id, "lv": "1", "kv": "1", "tv": "-1"], headers: h)
                }
            } catch let e as MusicError where e == .notFound { continue }
            if let l = Self.map(try MusicLyricsIO.parse(ldata)) { return l }
        }
        return nil
    }

    static func songIDs(_ obj: Any, wanted: Double?) -> [String] {
        guard let d = obj as? [String: Any], let songs = (d["result"] as? [String: Any])?["songs"] as? [[String: Any]] else { return [] }
        return MusicLyricsMatch.ordered(songs, wanted: wanted) { s in MusicLyricsIO.seconds(s["duration"]).map { $0 / 1000 } }
            .compactMap { MusicLyricsIO.int64($0["id"]) }.map(String.init)
    }

    static func pickSong(_ obj: Any, wanted: Double?) -> String? {
        guard let d = obj as? [String: Any], let songs = (d["result"] as? [String: Any])?["songs"] as? [[String: Any]] else { return nil }
        let pick = MusicLyricsMatch.closest(songs, wanted: wanted) { s in MusicLyricsIO.seconds(s["duration"]).map { $0 / 1000 } }
        return pick.flatMap { MusicLyricsIO.int64($0["id"]) }.map(String.init)
    }

    static func map(_ obj: Any) -> MusicLyrics? {
        guard let d = obj as? [String: Any] else { return nil }
        func text(_ k: String) -> String? { ((d[k] as? [String: Any])?["lyric"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } }
        guard let lrc = text("lrc") else { return nil }
        var lines = MusicLyricsParsers.parseLRC(lrc)
        guard !lines.isEmpty else {
            return MusicLyricsParsers.lyrics(from: lrc, source: MusicLyricsSources.name(MusicLyricsSources.netease), provider: MusicLyricsSources.netease)
        }
        if let k = text("klyric") {
            let kl = MusicLyricsParsers.parseLRC(k)
            if !kl.isEmpty { lines = MusicLyricsMux.mux(base: lines, other: kl) }
        }
        if let t = text("tlyric") {
            let tl = MusicLyricsParsers.parseLRC(t)
            for i in lines.indices {
                if let m = tl.first(where: { $0.timeMs == lines[i].timeMs }), !m.text.trimmingCharacters(in: .whitespaces).isEmpty { lines[i].translation = m.text }
            }
        }
        return MusicLyricsNormalizer.normalize(MusicLyrics(synced: lines, sourceName: MusicLyricsSources.name(MusicLyricsSources.netease), providerID: MusicLyricsSources.netease))
    }
}
