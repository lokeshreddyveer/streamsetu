import Foundation

/// Genius: plain text read off a lyrics web page. The last resort: the walk only asks it when every source above has missed.
struct GeniusProvider: MusicLyricsRequestProvider {
    static let searchURL = URL(string: "https://genius.com/api/search/multi")!
    static let timeout = 8.0
    private let http: MusicHTTP
    /// Genius refuses requests that claim to be a browser, so the call carries a plain app name.
    static let userAgent = "StreamSetu"
    init(http: MusicHTTP = MusicHTTP()) { self.http = http }

    var info: MusicProviderInfo {
        MusicProviderInfo(id: MusicLyricsSources.genius, name: "Genius", summary: MusicLyricsSources.about[MusicLyricsSources.genius] ?? "",
                          privacyNote: "Only when no other source has the lyrics, the title and artist of the song being played are sent to genius.com as a web search, and the song page is read like a browser would. This source is unofficial.",
                          homepage: "https://genius.com")
    }
    var capabilities: MusicCapabilities { [.lyrics] }

    struct Hit: Sendable, Hashable { var path: String; var title: String; var artist: String; var score: Int }

    func lyrics(for request: MusicLyricsRequest) async throws -> MusicLyrics? {
        guard !request.title.isEmpty else { return nil }
        let (title, artist) = Self.workOut(title: request.title, artist: request.artists)
        for q in Self.queries(title: title, artist: artist) {
            let obj: Any
            do { obj = try await MusicLyricsIO.object(http, Self.searchURL, query: ["q": q], headers: ["User-Agent": Self.userAgent, "Accept": "application/json"], timeout: Self.timeout) }
            catch let e as MusicError where e == .notFound { continue }
            guard let hit = Self.best(Self.hits(obj, title: title, artist: artist)), let url = URL(string: "https://genius.com" + hit.path) else { continue }
            let data = try await MusicLyricsIO.withTimeout(Self.timeout) { [http] in try await http.get(url, headers: ["User-Agent": Self.userAgent]) }
            if let text = Self.lyricsText(inPage: String(decoding: data, as: UTF8.self)) {
                return Self.build(text)
            }
        }
        return nil
    }

    // MARK: query

    static let noise = #"(?:from|feat\.?|ft\.?|featuring|with|prod\.?|produced by|official|lyrical|video|audio|remix|music video|visuali[sz]er|mv|hd|4k|hq|full song)"#

    /// "Artist - Title" or "Artist: Title" style names: the part equal to the artist is the artist, the other is the title.
    static func workOut(title: String, artist: String) -> (String, String) {
        let cleanArtist = MusicLyricsTitleClean.artist(artist)
        for sep in [" - ", ": "] {
            if let r = title.range(of: sep) {
                let a = String(title[..<r.lowerBound]).trimmingCharacters(in: .whitespaces), b = String(title[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if a.lowercased() == cleanArtist.lowercased() { return (b, cleanArtist) }
                if b.lowercased() == cleanArtist.lowercased() { return (a, cleanArtist) }
            }
        }
        return (title, cleanArtist)
    }

    static func clean(_ s: String) -> String {
        var t = s
        if let r = t.range(of: " | ") { t = String(t[..<r.lowerBound]) }
        t = t.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*\b"# + noise + #"\b[^\)\]]*[\)\]]"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\s+prod(?:uced)?\.?\s+by\s.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"[^\p{L}\p{N}\s'&,.\-]"#, with: " ", options: .regularExpression)
        return t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Up to five searches, in order: artist+title, artist+title without brackets, cleaned both, title alone, bracket-free title alone.
    static func queries(title: String, artist: String) -> [String] {
        let noBrackets = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let ct = clean(title), ca = clean(artist)
        var out: [String] = []
        for q in ["\(artist) \(title)", "\(artist) \(noBrackets)", "\(ca) \(ct)", ct, noBrackets] {
            let t = q.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, !out.contains(t) { out.append(t) }
        }
        return Array(out.prefix(5))
    }

    // MARK: choosing

    static func hits(_ obj: Any, title: String, artist: String) -> [Hit] {
        guard let sections = (((obj as? [String: Any])?["response"] as? [String: Any])?["sections"]) as? [[String: Any]] else { return [] }
        var out: [Hit] = []
        for sec in sections where (sec["type"] as? String) == "song" {
            for h in (sec["hits"] as? [[String: Any]]) ?? [] {
                guard let r = h["result"] as? [String: Any], let path = r["path"] as? String else { continue }
                let t = (r["title"] as? String) ?? "", a = (r["primary_artist"] as? [String: Any])?["name"] as? String ?? (r["artist_names"] as? String) ?? ""
                out.append(Hit(path: path, title: t, artist: a, score: score(path: path, title: title, artist: artist, cTitle: t, cArtist: a)))
            }
        }
        return out
    }

    static func score(path: String, title: String, artist: String, cTitle: String, cArtist: String) -> Int {
        var s = 0
        let wt = title.lowercased(), ct = cTitle.lowercased(), wa = artist.lowercased(), ca = cArtist.lowercased()
        let titleMatch = wt == ct || ct.contains(wt) || wt.contains(ct), artistMatch = wa == ca || ca.contains(wa) || wa.contains(ca)
        if wt == ct { s += 50 } else if !wt.isEmpty, titleMatch { s += 25 }
        if wa == ca { s += 40 } else if !wa.isEmpty, artistMatch { s += 20 }
        let p = path.lowercased()
        if p.contains("translation"), !wt.contains("translation") { s -= 30 }
        if p.contains("turkce") || p.contains("polskie") || p.contains("tlumaczenie") { s -= 40 }
        if p.contains("tracklist") || p.contains("album-art") { s -= 50 }
        if !titleMatch, !artistMatch { return 0 }
        return s
    }

    static func best(_ hits: [Hit]) -> Hit? {
        hits.filter { $0.score > 0 }.max { $0.score < $1.score }
    }

    // MARK: page

    /// The text of every lyrics container: line breaks kept, header, ad, button, script and style nodes and anything marked as excluded
    /// from selection removed.
    static func lyricsText(inPage html: String) -> String? {
        var out: [String] = []
        var search = html.startIndex
        while let open = html.range(of: #"<div[^>]*data-lyrics-container="true"[^>]*>"#, options: .regularExpression, range: search..<html.endIndex) {
            let (inner, end) = balancedDiv(html, from: open.upperBound)
            out.append(flatten(inner))
            search = end
        }
        if out.isEmpty, let open = html.range(of: #"<div[^>]*class="lyrics"[^>]*>"#, options: .regularExpression) {
            out.append(flatten(balancedDiv(html, from: open.upperBound).0))
        }
        var t = out.joined(separator: "\n")
        t = MusicLyricsText.decodeEntities(t)
        t = t.replacingOccurrences(of: #"\d*You might also like"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\d*Embed\s*$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{200B}", with: "")
        let cleaned = tidyLines(t)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// One blank line between stanzas; no blank line at either end and no repeated ones.
    static func tidyLines(_ t: String) -> String {
        var lines: [String] = []
        for raw in t.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(l)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static func balancedDiv(_ html: String, from: String.Index) -> (String, String.Index) {
        var depth = 1
        var i = from
        let len = html.endIndex
        while i < len {
            if html[i] == "<" {
                let rest = html[i...]
                if rest.hasPrefix("</div") {
                    depth -= 1
                    if depth == 0 { return (String(html[from..<i]), html.index(i, offsetBy: 6, limitedBy: len) ?? len) }
                } else if rest.hasPrefix("<div") { depth += 1 }
            }
            i = html.index(after: i)
        }
        return (String(html[from...]), len)
    }

    /// Tags to text. Subtrees of excluded nodes are skipped by counting nesting of the same tag name.
    private static func flatten(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        var skipTag: String?
        var skipDepth = 0
        while i < s.endIndex {
            guard s[i] == "<", let close = s[i...].firstIndex(of: ">") else {
                if skipTag == nil { out.append(s[i]) }
                i = s.index(after: i)
                continue
            }
            let tag = String(s[s.index(after: i)..<close])
            let name = tag.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(whereSeparator: { $0 == " " || $0 == "/" }).first.map { String($0).lowercased() } ?? ""
            let closing = tag.hasPrefix("/")
            if let st = skipTag {
                if name == st { if closing { skipDepth -= 1; if skipDepth == 0 { skipTag = nil } } else if !tag.hasSuffix("/") { skipDepth += 1 } }
            } else if !closing, ["script", "style", "button"].contains(name) || tag.contains("data-exclude-from-selection") || tag.lowercased().contains("header") && name == "div" {
                if !tag.hasSuffix("/") { skipTag = name; skipDepth = 1 }
            } else if name == "br" { out.append("\n") } else if closing, name == "p" || name == "div" { out.append("\n") }
            i = s.index(after: close)
        }
        return out
    }

    /// Section markers like `[Chorus]` stay as plain lines; the text is plain lyrics with no timing.
    static func build(_ text: String) -> MusicLyrics? {
        MusicLyricsParsers.plainLyrics(text, source: MusicLyricsSources.name(MusicLyricsSources.genius), provider: MusicLyricsSources.genius)
    }

    static func isSectionMarker(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("[") && t.hasSuffix("]") && (3...60).contains(t.count)
    }
}
