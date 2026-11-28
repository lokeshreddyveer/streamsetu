import Foundation

/// Kugou (unofficial endpoints). It throttles by IP and then answers with empty results instead of errors.
struct KugouProvider: MusicLyricsRequestProvider {
    static let search = URL(string: "https://mobileservice.kugou.com/api/v3/search/song")!
    static let candidates = URL(string: "https://krcs.kugou.com/search")!
    static let download = URL(string: "https://lyrics.kugou.com/download")!
    static let timeout = 8.0
    private let http: MusicHTTP
    init(http: MusicHTTP = MusicHTTP()) { self.http = http }

    var info: MusicProviderInfo {
        MusicProviderInfo(id: MusicLyricsSources.kugou, name: "Kugou", summary: MusicLyricsSources.about[MusicLyricsSources.kugou] ?? "",
                          privacyNote: "The title and artist of the song being played are sent to kugou.com (a Chinese service), along with your IP address.")
    }
    var capabilities: MusicCapabilities { [.lyrics] }

    func lyrics(for request: MusicLyricsRequest) async throws -> MusicLyrics? {
        let title = request.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        let term = request.artists.isEmpty ? title : "\(title) - \(request.artists)"
        let sdata = try await MusicLyricsIO.withTimeout(Self.timeout) { [http] in
            try await http.get(Self.search, query: ["keyword": term, "version": "9108", "plat": "0", "pagesize": "8", "showtype": "0"])
        }
        for hash in Self.hashes(try MusicLyricsIO.parse(sdata), wanted: request.durationSeconds).prefix(3) {
            let cdata = try await MusicLyricsIO.withTimeout(Self.timeout) { [http] in
                try await http.get(Self.candidates, query: ["ver": "1", "man": "yes", "client": "mobi", "hash": hash])
            }
            guard let (id, key) = Self.firstCandidate(try MusicLyricsIO.parse(cdata)) else { continue }
            let ddata: Data
            do {
                ddata = try await MusicLyricsIO.withTimeout(Self.timeout) { [http] in
                    try await http.get(Self.download, query: ["ver": "1", "client": "pc", "id": id, "accesskey": key, "fmt": "lrc"])
                }
            } catch let e as MusicError where e == .notFound { continue }
            if let l = Self.map(try MusicLyricsIO.parse(ddata)) { return l }
        }
        return nil
    }

    /// Hashes from the mobile search (`data.info`, length in seconds), nearest length first; also reads the older `data.lists` shape.
    static func hashes(_ obj: Any, wanted: Double?) -> [String] {
        guard let d = (obj as? [String: Any])?["data"] as? [String: Any] else { return [] }
        if let info = d["info"] as? [[String: Any]] {
            return MusicLyricsMatch.ordered(info, wanted: wanted) { MusicLyricsIO.seconds($0["duration"]) }
                .compactMap { ($0["hash"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        }
        guard let lists = d["lists"] as? [[String: Any]] else { return [] }
        return MusicLyricsMatch.ordered(lists, wanted: wanted) { MusicLyricsIO.seconds($0["Duration"]) }
            .compactMap { ($0["FileHash"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    }

    static func pickHash(_ obj: Any, wanted: Double?) -> String? {
        guard let d = obj as? [String: Any], let lists = (d["data"] as? [String: Any])?["lists"] as? [[String: Any]] else { return nil }
        let pick = MusicLyricsMatch.closest(lists, wanted: wanted) { MusicLyricsIO.seconds($0["Duration"]) }
        return (pick?["FileHash"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func firstCandidate(_ obj: Any) -> (String, String)? {
        guard let d = obj as? [String: Any], let c = (d["candidates"] as? [[String: Any]])?.first else { return nil }
        guard let id = c["id"].flatMap({ ($0 as? String) ?? ($0 as? NSNumber).map { "\($0)" } }), let key = c["accesskey"] as? String, !id.isEmpty, !key.isEmpty else { return nil }
        return (id, key)
    }

    static func map(_ obj: Any) -> MusicLyrics? {
        guard let d = obj as? [String: Any], let content = d["content"] as? String, let text = MusicLyricsIO.decodeBase64Text(content) else { return nil }
        let cleaned = stripCredits(text)
        if MusicLyricsNotice.isInstrumentalNotice(MusicLyricsParsers.parseLRC(cleaned)) { return nil }
        return MusicLyricsParsers.lyrics(from: cleaned, source: MusicLyricsSources.name(MusicLyricsSources.kugou), provider: MusicLyricsSources.kugou)
    }

    /// Kugou puts songwriter, composer and arranger lines ("Lyricist: name") at the top and bottom of the file. Only stamped lines are
    /// kept. At the top, the block of credit lines (after at most a few title lines) is cut together with everything above it; at the
    /// bottom, the block of credit lines is cut. Text with no stamped lines is returned unchanged.
    static func stripCredits(_ lrc: String) -> String {
        var lines = lrc.split(whereSeparator: \.isNewline).map(String.init).filter { l in
            l.range(of: #"^\s*\[\d+:\d+(?:[.:]\d+)?\]"#, options: .regularExpression) != nil
        }
        guard !lines.isEmpty else { return lrc }
        func isCredit(_ l: String) -> Bool { l.range(of: #"^\s*\[[^\]]+\][^\[\]]*[:：].+"#, options: .regularExpression) != nil }
        var lastCredit = -1
        for i in 0..<min(30, lines.count) {
            if isCredit(lines[i]) { lastCredit = i } else if lastCredit >= 0 || i >= 3 { break }
        }
        if lastCredit >= 0 { lines.removeFirst(lastCredit + 1) }
        var cut = lines.count
        while cut > 0, lines.count - cut < 30, isCredit(lines[cut - 1]) { cut -= 1 }
        if cut < lines.count { lines.removeSubrange(cut...) }
        return lines.joined(separator: "\n")
    }
}
