import Foundation

/// QQ Music (unofficial endpoints). Search uses the search-box suggestions, then one batch call for the lengths.
struct QQMusicProvider: MusicLyricsRequestProvider {
    static let suggest = URL(string: "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg")!
    static let single = URL(string: "https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg")!
    static let lyric = URL(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg")!
    static let timeout = 8.0
    private let http: MusicHTTP
    init(http: MusicHTTP = MusicHTTP()) { self.http = http }

    var info: MusicProviderInfo {
        MusicProviderInfo(id: MusicLyricsSources.qq, name: "QQ Music", summary: MusicLyricsSources.about[MusicLyricsSources.qq] ?? "",
                          privacyNote: "The title and artist of the song being played are sent to y.qq.com (a Chinese service), along with your IP address.")
    }
    var capabilities: MusicCapabilities { [.lyrics] }

    private var headers: [String: String] { ["Referer": "https://y.qq.com/"] }

    func lyrics(for request: MusicLyricsRequest) async throws -> MusicLyrics? {
        let term = "\(request.title) \(request.artists)".trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return nil }
        let h = headers
        let sdata = try await MusicLyricsIO.withTimeout(Self.timeout) { [http] in
            try await http.get(Self.suggest, query: ["format": "json", "key": term], headers: h)
        }
        let mids = Self.mids(try MusicLyricsIO.parseLoose(sdata))
        guard !mids.isEmpty else { return nil }
        var lengths: [String: Double] = [:]
        if request.hasDuration {
            let ldata = try await MusicLyricsIO.withTimeout(Self.timeout) { [http] in
                try await http.get(Self.single, query: ["format": "json", "songmid": mids.joined(separator: ",")], headers: h)
            }
            lengths = Self.lengths(try MusicLyricsIO.parseLoose(ldata))
        }
        for mid in MusicLyricsMatch.ordered(mids, wanted: request.durationSeconds, length: { lengths[$0] }).prefix(3) {
            let data: Data
            do {
                data = try await MusicLyricsIO.withTimeout(Self.timeout) { [http] in
                    try await http.get(Self.lyric, query: ["songmid": mid, "format": "json", "nobase64": "1"], headers: h)
                }
            } catch let e as MusicError where e == .notFound { continue }
            if let l = Self.map(try MusicLyricsIO.parseLoose(data)) { return l }
        }
        return nil
    }

    static func mids(_ obj: Any) -> [String] {
        guard let d = obj as? [String: Any], let items = (((d["data"] as? [String: Any])?["song"]) as? [String: Any])?["itemlist"] as? [[String: Any]] else { return [] }
        return items.compactMap { ($0["mid"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    }

    static func lengths(_ obj: Any) -> [String: Double] {
        guard let d = obj as? [String: Any], let rows = d["data"] as? [[String: Any]] else { return [:] }
        var out: [String: Double] = [:]
        for r in rows { if let m = r["mid"] as? String, let i = MusicLyricsIO.seconds(r["interval"]) { out[m] = i } }
        return out
    }

    static func map(_ obj: Any) -> MusicLyrics? {
        guard let d = obj as? [String: Any], let raw = d["lyric"] as? String, !raw.isEmpty else { return nil }
        let text = MusicLyricsIO.decodeBase64Text(raw) ?? raw
        return MusicLyricsParsers.lyrics(from: text, source: MusicLyricsSources.name(MusicLyricsSources.qq), provider: MusicLyricsSources.qq)
    }
}
