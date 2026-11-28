import Foundation

// Reading the many shapes a lyrics service can answer with: the generic "envelope" body, QQ/Netease karaoke lines, title cleaning,
// and the recording match rules used by the Apple-timed mirrors. Pure functions.

enum MusicLyricsEnvelope {
    /// The finished lyric for a service answer: any of JSON wrapper, TTML (also HTML-escaped), karaoke lines, enhanced LRC, LRC, plain lines.
    /// Background tails are split, syllables glued, instrumental gaps placed; nil when nothing readable is left.
    static func parse(_ raw: String, source: String, provider: String, explicitSpacing: Bool = false) -> MusicLyrics? {
        let text = unwrap(raw)
        guard !text.isEmpty else { return nil }
        var lines: [MusicLyricLine] = []
        var voiceTypes: [String: String] = [:]
        var plain: String?
        let lower = text.lowercased()
        if lower.contains("<tt") || lower.contains("www.w3.org/ns/ttml") {
            let parsed = MusicLyricsParsers.parseTTML(text)
            lines = parsed.filter(\.timed).map(\.line)
            voiceTypes = MusicLyricsParsers.agentTypes(in: text)
            if lines.isEmpty { plain = parsed.map(\.line.text).filter { !$0.isEmpty }.joined(separator: "\n") }
        } else if looksLikeKaraoke(text) {
            lines = parseKaraoke(text)
        } else if text.hasPrefix("<") {
            return nil
        } else {
            let lrc = MusicLyricsParsers.parseLRC(text)
            if !lrc.isEmpty { lines = lrc } else {
                let rows = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !isMetadataTag($0) }
                let joined = rows.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if joined.isEmpty || isNotFoundText(joined) { return nil }
                plain = joined
            }
        }
        if !lines.isEmpty {
            guard lines.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
            if MusicLyricsNotice.isInstrumentalNotice(lines) { return nil }
            lines = MusicLyricsSyllables.glueLines(lines, explicitSpacing: explicitSpacing)
            lines = MusicLyricsBackground.splitAll(lines)
            lines = lines.contains(where: \.isWordSynced) ? MusicLyricsGaps.insert(into: lines) : MusicLyricsGaps.pruneEmptyStamps(lines)
            var l = MusicLyrics(synced: lines, sourceName: source, providerID: provider)
            l.voiceTypes = voiceTypes
            return MusicLyricsNormalizer.normalize(l)
        }
        guard let plain, !plain.isEmpty else { return nil }
        return MusicLyricsParsers.plainLyrics(plain, source: source, provider: provider)
    }

    /// Strips a byte order mark and markdown fences, digs the lyric string out of a JSON wrapper, and unescapes HTML-escaped TTML.
    static func unwrap(_ raw: String) -> String {
        var t = raw
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            if let nl = t.firstIndex(of: "\n") { t = String(t[t.index(after: nl)...]) }
            if t.hasSuffix("```") { t.removeLast(3) }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if t.hasPrefix("{") || t.hasPrefix("["), let data = t.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) {
            guard let inner = extractText(obj) else { return "" }
            return unwrap(inner)
        }
        if t.contains("&lt;tt") { t = unescapeMarkup(t) }
        return t
    }

    private static let keyOrder = ["ttml", "ttmlContent", "lyrics", "lrc", "content", "text", "plainLyrics", "syncedLyrics", "line", "lines",
                                   "lyric", "data", "result", "response", "metadata", "words"]

    static func extractText(_ any: Any, depth: Int = 0) -> String? {
        guard depth < 8 else { return nil }
        if let s = any as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s }
        if let a = any as? [Any] {
            let parts = a.compactMap { extractText($0, depth: depth + 1) }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        guard let d = any as? [String: Any] else { return nil }
        if (d["isError"] as? Bool) == true || (d["ok"] as? Bool) == false { return nil }
        if let e = d["error"], !(e is NSNull), (e as? Bool) != false, (e as? String)?.isEmpty != true { return nil }
        for k in keyOrder {
            if let v = d[k], let t = extractText(v, depth: depth + 1) { return t }
        }
        return nil
    }

    static func unescapeMarkup(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func isMetadataTag(_ line: String) -> Bool {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return false }
        let tag = line[line.index(after: line.startIndex)..<close]
        return tag.contains(":") && MusicLyricsParsers.stampMs(String(tag)) == nil && close == line.index(before: line.endIndex)
    }

    static func isNotFoundText(_ t: String) -> Bool {
        let l = t.lowercased()
        return l.count < 120 && (l.contains("lyrics not found") || l.contains("lyrics unavailable") || l.contains("no lyrics")
                                 || l.contains("lyrics are not available") || l == "error")
    }

    // MARK: karaoke lines (QQ QRC, Netease YRC)

    static func looksLikeKaraoke(_ text: String) -> Bool {
        let t = text.contains("LyricContent=") ? decodeWrapper(text) : text
        return t.split(whereSeparator: \.isNewline).prefix(12).contains { l in
            l.range(of: #"^\s*\[\d+,\d+\]"#, options: .regularExpression) != nil
        }
    }

    private static func decodeWrapper(_ text: String) -> String {
        guard let r = text.range(of: "LyricContent=\""), let e = text.range(of: "\"", range: r.upperBound..<text.endIndex) else { return text }
        return MusicLyricsText.decodeEntities(String(text[r.upperBound..<e.lowerBound]))
    }

    /// Lines `[start,duration]` then runs `text(start,duration[,x])` (QRC) or `(start,duration[,x])text` (YRC); the style that yields more
    /// characters is used. Runs without a space between them are syllables of one word; unspaced scripts stay separate words.
    static func parseKaraoke(_ raw: String) -> [MusicLyricLine] {
        let text = raw.contains("LyricContent=") ? decodeWrapper(raw) : raw
        var out: [MusicLyricLine] = []
        for row in text.split(whereSeparator: \.isNewline) {
            guard let m = row.range(of: #"^\s*\[(\d+),(\d+)\]"#, options: .regularExpression) else { continue }
            let head = String(row[m]).trimmingCharacters(in: CharacterSet(charactersIn: "[] \t")).split(separator: ",")
            guard head.count == 2, let start = Int64(head[0]), let dur = Int64(head[1]) else { continue }
            let body = String(row[m.upperBound...])
            let suffix = runs(body, prefixStyle: false), prefix = runs(body, prefixStyle: true)
            let chosen = suffix.reduce(0) { $0 + $1.text.count } >= prefix.reduce(0) { $0 + $1.text.count } ? suffix : prefix
            let words = chosen.filter { !$0.text.isEmpty }
            guard !words.isEmpty else { continue }
            let glued = MusicLyricsSyllables.glue(words, explicitSpacing: false)
            let line = MusicLyricsText.collapsed(glued.map(\.text).joined()).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            out.append(MusicLyricLine(timeMs: start, text: line, endMs: start + dur, words: glued))
        }
        return out.sorted { $0.timeMs < $1.timeMs }
    }

    private static func runs(_ body: String, prefixStyle: Bool) -> [MusicLyricWord] {
        let pattern = prefixStyle ? #"\((\d+),(\d+)(?:,\d+)?\)"# : #"\((\d+),(\d+)(?:,\d+)?\)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = body as NSString
        let matches = re.matches(in: body, range: NSRange(location: 0, length: ns.length))
        var out: [MusicLyricWord] = []
        for (i, m) in matches.enumerated() {
            guard let st = Int64(ns.substring(with: m.range(at: 1))), let du = Int64(ns.substring(with: m.range(at: 2))) else { continue }
            let textRange: NSRange
            if prefixStyle {
                let from = m.range.upperBound
                let to = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
                textRange = NSRange(location: from, length: max(0, to - from))
            } else {
                let from = i == 0 ? 0 : matches[i - 1].range.upperBound
                textRange = NSRange(location: from, length: max(0, m.range.location - from))
            }
            out.append(MusicLyricWord(text: ns.substring(with: textRange), startMs: st, endMs: st + du))
        }
        return out
    }
}

// MARK: title and artist cleaning

enum MusicLyricsTitleClean {
    /// Credits and upload labels removed; version words (remix, acoustic, live, remastered) are kept because they name another recording.
    static func title(_ raw: String) -> String {
        var t = raw
        let patterns = [
            #"\s*[\(\[]\s*(?:feat|ft|featuring|with)\b[^\)\]]*[\)\]]"#,
            #"\s*[\(\[]\s*(?:official\s+)?(?:music\s+)?(?:video|audio|visuali[sz]er|lyrics?\s+video|lyrics?|m/?v|hd|hq|4k|full\s+song)\s*[\)\]]"#,
            #"\s*[\(\[]\s*official\s*[\)\]]"#,
            #"\s+\b(?:feat|ft|featuring)\b\.?\s.*$"#
        ]
        for p in patterns { t = t.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive]) }
        t = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        while let l = t.last, ",-–— ".contains(l) { t.removeLast() }
        return t.isEmpty ? raw : t
    }

    static func artist(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"\s*-\s*Topic\s*$"#, with: "", options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: .whitespaces)
    }

    /// LRCLIB's own cleaning: also drops from/feat/official/lyrical/video/audio/remix parentheses, every square bracket, upload phrases, and
    /// cuts at " | ".
    static func lrclibTitle(_ raw: String) -> String {
        var t = raw
        if let r = t.range(of: " | ") { t = String(t[..<r.lowerBound]) }
        let patterns = [
            #"\s*\((?:[^)]*\b)?(?:from|feat|official|lyrical|video|audio|remix)\b[^)]*\)"#,
            #"\s*\[[^\]]*\]"#,
            #"\b(?:official\s+(?:music\s+)?(?:video|audio)|lyrical|full\s+song|4k\s+video)\b"#
        ]
        for p in patterns { t = t.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive]) }
        t = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return t.isEmpty ? raw : t
    }
}

// MARK: recording match (lrc.red, BiniLyrics)

enum MusicRecordingMatch {
    static let versionWords: Set<String> = ["live", "remix", "remixed", "mix", "acoustic", "unplugged", "instrumental", "karaoke", "cappella",
        "acapella", "demo", "edit", "version", "cover", "sped", "slowed", "reverb", "nightcore", "lofi", "orchestral", "extended"]
    static let lengthWindow = 3.0

    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// The title text outside brackets and before " - ", reduced to lower-case letters and digits.
    static func coreTitle(_ s: String) -> String {
        var depth = 0
        var out = ""
        for ch in s {
            if "([{【（".contains(ch) { depth += 1; continue }
            if ")]}】）".contains(ch) { depth = max(0, depth - 1); continue }
            if depth == 0 { out.append(ch) }
        }
        if let r = out.range(of: " - ") { out = String(out[..<r.lowerBound]) }
        return fold(out).filter { $0.isLetter || $0.isNumber }
    }

    /// Version words from the brackets and the " - " suffix, as a set.
    static func versions(_ s: String) -> Set<String> {
        var parts: [String] = []
        var depth = 0
        var cur = ""
        for ch in s {
            if "([{【（".contains(ch) { depth += 1; if depth == 1 { cur = "" }; continue }
            if ")]}】）".contains(ch) { if depth == 1 { parts.append(cur) }; depth = max(0, depth - 1); continue }
            if depth > 0 { cur.append(ch) }
        }
        if let r = s.range(of: " - ") { parts.append(String(s[r.upperBound...])) }
        var set = Set<String>()
        for p in parts {
            for w in fold(p).split(whereSeparator: { !$0.isLetter && !$0.isNumber }) where versionWords.contains(String(w)) { set.insert(String(w)) }
        }
        return set
    }

    static func artists(_ s: String) -> Set<String> {
        var t = fold(s)
        for sep in [" and ", " x ", " with ", " feat. ", " ft. ", " feat ", " ft "] { t = t.replacingOccurrences(of: sep, with: ",") }
        for sep in ["&", ";", "/"] { t = t.replacingOccurrences(of: sep, with: ",") }
        return Set(t.split(separator: ",").map { String($0.filter { $0.isLetter || $0.isNumber }) }.filter { !$0.isEmpty })
    }

    /// Every rule is a requirement: core title equal, version words equal, one credited artist shared (skipped when none is wanted),
    /// lengths within 3 s when both are known.
    static func accepts(wantTitle: String, wantArtist: String, wantSeconds: Double?, title: String, artist: String, seconds: Double?) -> Bool {
        guard coreTitle(wantTitle) == coreTitle(title), !coreTitle(title).isEmpty else { return false }
        guard versions(wantTitle) == versions(title) else { return false }
        let wa = artists(wantArtist)
        if !wa.isEmpty, wa.isDisjoint(with: artists(artist)) { return false }
        if let w = wantSeconds, w > 0, let c = seconds, c > 0, abs(w - c) > lengthWindow { return false }
        return true
    }

    /// Among accepted candidates, the one closest in length; ties go to the earlier search rank.
    static func pick<T>(_ items: [T], wantSeconds: Double?, accepts: (T) -> Bool, seconds: (T) -> Double?) -> T? {
        var best: (T, Double)?
        for it in items where accepts(it) {
            let d: Double
            if let w = wantSeconds, w > 0, let c = seconds(it), c > 0 { d = abs(w - c) } else { d = 0 }
            if best == nil || d < (best?.1 ?? .infinity) { best = (it, d) }
        }
        return best?.0
    }
}

// MARK: candidate scoring over arbitrary JSON (PaxSenix)

enum MusicCandidateScore {
    struct Candidate: Sendable, Hashable { var id: String; var score: Int }

    private static let idKeys = ["id", "trackId", "track_id", "realId"]
    private static let titleKeys = ["name", "title", "trackName", "track_name"]
    private static let artistKeys = ["artistName", "artist_name"]
    private static let durationKeys = ["durationInMillis", "durationMs", "duration_ms", "duration"]

    /// Walks the whole tree and returns the best candidate with a score of at least `minimum`.
    static func best(in json: Any, title: String, artist: String, seconds: Double?, minimum: Int = 10) -> Candidate? {
        var all: [Candidate] = []
        collect(json, title: title, artist: artist, seconds: seconds, into: &all, depth: 0)
        guard let top = all.max(by: { $0.score < $1.score }), top.score >= minimum else { return nil }
        return top
    }

    private static func collect(_ any: Any, title: String, artist: String, seconds: Double?, into out: inout [Candidate], depth: Int) {
        guard depth < 12 else { return }
        if let a = any as? [Any] { for v in a { collect(v, title: title, artist: artist, seconds: seconds, into: &out, depth: depth + 1) }; return }
        guard let d = any as? [String: Any] else { return }
        let id = idKeys.compactMap { k in (d[k] as? String) ?? (d[k] as? NSNumber).map { "\($0)" } }.first
        // Apple nests the descriptive fields in `attributes`.
        let src: [String: Any] = titleKeys.contains(where: { d[$0] is String }) ? d : ((d["attributes"] as? [String: Any]) ?? d)
        let t = titleKeys.compactMap { src[$0] as? String }.first
        if let id, let t {
            var a = artistKeys.compactMap { src[$0] as? String }.first
            if a == nil, let arr = src["artists"] as? [[String: Any]] { a = arr.compactMap { $0["name"] as? String }.joined(separator: ", ") }
            if a == nil, let o = src["artists"] as? [String: Any] { a = o["name"] as? String }
            if a == nil, let o = src["artist"] as? [String: Any] { a = o["name"] as? String }
            if a == nil { a = src["artist"] as? String }
            var dur: Double?
            for k in durationKeys { if let n = MusicLyricsIO.seconds(src[k]) { dur = n < 10_000 ? n : n / 1000; break } }
            out.append(Candidate(id: id, score: score(title: title, artist: artist, seconds: seconds, cTitle: t, cArtist: a ?? "", cSeconds: dur)))
        }
        for v in d.values { collect(v, title: title, artist: artist, seconds: seconds, into: &out, depth: depth + 1) }
    }

    static func score(title: String, artist: String, seconds: Double?, cTitle: String, cArtist: String, cSeconds: Double?) -> Int {
        var s = 0
        let wt = title.lowercased().trimmingCharacters(in: .whitespaces), ct = cTitle.lowercased().trimmingCharacters(in: .whitespaces)
        if !wt.isEmpty {
            if wt == ct { s += 20 } else if ct.contains(wt) || wt.contains(ct), !ct.isEmpty { s += 10 }
        }
        let wa = artist.lowercased().trimmingCharacters(in: .whitespaces), ca = cArtist.lowercased().trimmingCharacters(in: .whitespaces)
        if !wa.isEmpty {
            if wa == ca { s += 15 } else if !ca.isEmpty, ca.contains(wa) || wa.contains(ca) { s += 5 }
        }
        if let w = seconds, w > 0, let c = cSeconds, c > 0 {
            let d = abs(w - c)
            if d <= 3 { s += 10 } else if d <= 10 { s += 5 }
        }
        return s
    }
}

// MARK: shared document fetch

/// One download per address while several sources want the same document (BiniLyrics names the address lrc.red also serves). The
/// download runs on its own task, so the source that loses the race does not cancel the other's copy.
actor MusicLyricsDocumentFetcher {
    static let shared = MusicLyricsDocumentFetcher()
    private var running: [String: Task<Data, Error>] = [:]

    func data(_ url: URL, http: MusicHTTP, headers: [String: String] = [:], timeout: Double) async throws -> Data {
        let key = url.absoluteString
        let task: Task<Data, Error>
        if let t = running[key] { task = t } else {
            task = Task { try await MusicLyricsIO.withTimeout(timeout) { try await http.get(url, headers: headers) } }
            running[key] = task
            Task { [weak self] in _ = try? await task.value; try? await Task.sleep(nanoseconds: 20_000_000_000); await self?.forget(key) }
        }
        return try await task.value
    }

    private func forget(_ key: String) { running[key] = nil }
}

// MARK: recording identity memory

/// Video id to recording code, in memory only and 100 entries at most (a wrong answer kept on disk would stay wrong).
actor MusicRecordingMemory {
    static let shared = MusicRecordingMemory()
    private var order: [String] = []
    private var map: [String: MusicLyricsIdentified] = [:]
    let capacity = 100

    func get(_ videoID: String) -> MusicLyricsIdentified? {
        guard let v = map[videoID] else { return nil }
        order.removeAll { $0 == videoID }; order.append(videoID)
        return v
    }

    func set(_ videoID: String, _ value: MusicLyricsIdentified) {
        map[videoID] = value
        order.removeAll { $0 == videoID }; order.append(videoID)
        while order.count > capacity, let oldest = order.first { order.removeFirst(); map[oldest] = nil }
    }

    var count: Int { map.count }
}
