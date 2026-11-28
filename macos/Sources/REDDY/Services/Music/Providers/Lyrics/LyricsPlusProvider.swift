import Foundation

/// LyricsPlus (the backend of YouLyPlus): Apple Music lyrics as "KPOE" JSON.
struct LyricsPlusProvider: MusicLyricsRequestProvider {
    /// Volunteer mirrors, perishable (at the last check only the second and third still answered). All are asked at once.
    static let mirrors = ["https://lyricsplus.prjktla.my.id", "https://lyricsplus.atomix.one", "https://lyricsplus.binimum.org",
                          "https://lyricsplus.prjktla.workers.dev", "https://lyricsplus-seven.vercel.app", "https://lyrics-plus-backend.vercel.app"]
    static let path = "/v2/lyrics/get"
    static let timeout = 6.0
    /// Its search strays onto other tracks of the same album; a length this far off is another track.
    static let lengthGuard = 5.0
    private let http: MusicHTTP
    init(http: MusicHTTP = MusicHTTP()) { self.http = http }

    var info: MusicProviderInfo {
        MusicProviderInfo(id: MusicLyricsSources.lyricsPlus, name: "LyricsPlus", summary: MusicLyricsSources.about[MusicLyricsSources.lyricsPlus] ?? "",
                          privacyNote: "The title, artist, album, length and recording code (when known) of the song being played are sent to several community-run LyricsPlus servers at once, for example lyricsplus.binimum.org.")
    }
    var capabilities: MusicCapabilities { [.lyrics] }

    func lyrics(for request: MusicLyricsRequest) async throws -> MusicLyrics? {
        var q = ["title": request.searchTitle, "artist": request.artists]
        if let al = request.album { q["album"] = al }
        if let d = request.roundedDuration { q["duration"] = String(d) }
        if let i = MusicISRC.normalize(request.isrc) { q["isrc"] = i }
        let query = q, want = request.durationSeconds, http = self.http
        // Every mirror at once; the first answer that reads as a lyric wins and the rest are cancelled.
        return try await withThrowingTaskGroup(of: (MusicLyrics?, Bool).self) { group in
            for host in Self.mirrors {
                guard let url = URL(string: host + Self.path) else { continue }
                group.addTask {
                    do {
                        let obj = try await MusicLyricsIO.object(http, url, query: query, timeout: Self.timeout)
                        return (Self.map(obj, wantSeconds: want), false)
                    } catch let e as MusicError where e == .notFound { return (nil, false) } catch { return (nil, true) }
                }
            }
            var errors = 0, total = 0
            for try await (l, failed) in group {
                total += 1
                if let l { group.cancelAll(); return l }
                if failed { errors += 1 }
            }
            if total > 0, errors == total { throw MusicError.network("LyricsPlus unreachable") }
            return nil
        }
    }

    static func map(_ obj: Any, wantSeconds: Double?) -> MusicLyrics? {
        guard let d = obj as? [String: Any], let rows = d["lyrics"] as? [[String: Any]], !rows.isEmpty else { return nil }
        if let want = wantSeconds, want > 0,
           let total = ((d["metadata"] as? [String: Any])?["totalDuration"] as? String).flatMap({ MusicLyricsParsers.clock($0) }),
           abs(Double(total) / 1000 - want) > lengthGuard { return nil }
        let wordType = (d["type"] as? String) == "Word"
        func words(_ any: Any?) -> [MusicLyricWord]? {
            guard wordType, let arr = any as? [[String: Any]], !arr.isEmpty else { return nil }
            let w = arr.compactMap { s -> MusicLyricWord? in
                guard let t = s["text"] as? String, let st = MusicLyricsIO.int64(s["time"]) else { return nil }
                return MusicLyricWord(text: t, startMs: st, endMs: st + (MusicLyricsIO.int64(s["duration"]) ?? 0), background: (s["isBackground"] as? Bool) ?? false)
            }
            return w.isEmpty ? nil : w
        }
        var lines: [MusicLyricLine] = []
        for r in rows {
            guard let t = MusicLyricsIO.int64(r["time"]) else { continue }
            let text = (r["text"] as? String) ?? ""
            var line = MusicLyricLine(timeMs: t, text: text.trimmingCharacters(in: .whitespaces), endMs: MusicLyricsIO.int64(r["duration"]).map { t + $0 })
            line.words = words(r["syllabus"])
            if let tr = r["transliteration"] as? [String: Any], let rt = tr["text"] as? String {
                let reading = rt.trimmingCharacters(in: .whitespaces)
                if !reading.isEmpty, MusicLyricsText.collapsed(reading) != MusicLyricsText.collapsed(text) {
                    line.romanized = reading
                    line.romanizedWords = words(tr["syllabus"])
                }
            }
            lines.append(line)
        }
        guard !lines.isEmpty else { return nil }
        return MusicLyricsNormalizer.normalize(MusicLyrics(synced: lines, sourceName: MusicLyricsSources.name(MusicLyricsSources.lyricsPlus), providerID: MusicLyricsSources.lyricsPlus))
    }
}
