import Foundation

/// A parsed line plus whether it carried a start time. Untimed lines only come from TTML.
struct MusicParsedLine: Sendable, Hashable {
    var line: MusicLyricLine
    var timed: Bool
}

/// Text to lines: LRC (with enhanced word stamps), TTML (word spans, background vocals, Apple readings) and a small JSON shape.
/// Pure functions; every provider that gets lyric text goes through here.
enum MusicLyricsParsers {

    // MARK: entry points

    /// Order: JSON, then TTML, then LRC, on trimmed text.
    static func parse(_ raw: String) -> [MusicParsedLine] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return [] }
        if text.hasPrefix("[") || text.hasPrefix("{"), let j = parseJSON(text), !j.isEmpty { return j }
        if text.hasPrefix("<") || text.contains("<p ") || text.contains("<tt") { return parseTTML(text) }
        return parseLRC(text).map { MusicParsedLine(line: $0, timed: true) }
    }

    /// Lyrics from text in any supported format. Timed lines make it synced; otherwise the text lines are the plain lyrics.
    /// Text with no recognisable structure is taken as plain lyrics. The result is normalised.
    static func lyrics(from text: String, source: String, provider: String) -> MusicLyrics? {
        let parsed = parse(text)
        var l = MusicLyrics(sourceName: source, providerID: provider)
        let timed = parsed.filter(\.timed).map(\.line)
        if !timed.isEmpty {
            l.synced = timed.enumerated().sorted { ($0.element.timeMs, $0.offset) < ($1.element.timeMs, $1.offset) }.map(\.element)
        } else if !parsed.isEmpty {
            l.plain = parsed.map(\.line.text).joined(separator: "\n")
        } else {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let looksStructured = t.hasPrefix("<") || t.hasPrefix("{") || t.hasPrefix("[")
            if looksStructured { return nil }
            l.plain = t
        }
        return MusicLyricsNormalizer.normalize(l)
    }

    /// Plain text, blank lines kept as stanza breaks.
    static func plainLyrics(_ text: String, source: String, provider: String) -> MusicLyrics? {
        let t = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return MusicLyricsNormalizer.normalize(MusicLyrics(plain: t, sourceName: source, providerID: provider))
    }

    // MARK: LRC

    /// Parses LRC text, enhanced LRC included. `[offset:+500]` shifts every line earlier by that many milliseconds (ours; the format
    /// defines it). A line may carry several stamps; a first tag that is not a time stops tag reading, so "[Chorus] yeah" keeps its
    /// bracket. Timestamped empty lines are kept. Sorted by time, stable.
    static func parseLRC(_ text: String) -> [MusicLyricLine] {
        struct Raw { var time: Int64; var text: String; var words: [(Int64, String)]; var closing: Int64?; var order: Int }
        var offset: Int64 = 0
        var raws: [Raw] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var rest = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            var stamps: [Int64] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = String(rest[rest.index(after: rest.startIndex)..<close])
                if let ms = stampMs(tag) { stamps.append(ms); rest = rest[rest.index(after: close)...] } else {
                    if stamps.isEmpty, let o = offsetMs(tag) { offset = o }
                    break
                }
            }
            guard let first = stamps.first else { continue }
            let body = String(rest)
            let enhanced = parseEnhanced(body, lineStart: first)
            for s in stamps {
                if let e = enhanced {
                    let delta = s - first
                    raws.append(Raw(time: s, text: e.text, words: e.words.map { ($0.0 + delta, $0.1) }, closing: e.closing.map { $0 + delta }, order: raws.count))
                } else {
                    raws.append(Raw(time: s, text: body.trimmingCharacters(in: .whitespaces), words: [], closing: nil, order: raws.count))
                }
            }
        }
        raws.sort { ($0.time, $0.order) < ($1.time, $1.order) }
        var out: [MusicLyricLine] = []
        for (i, r) in raws.enumerated() {
            let t = max(r.time - offset, 0)
            guard !r.words.isEmpty else { out.append(MusicLyricLine(timeMs: t, text: r.text)); continue }
            let nextStart = i + 1 < raws.count ? raws[i + 1].time : nil
            var words: [MusicLyricWord] = []
            for (k, w) in r.words.enumerated() {
                let start = max(w.0 - offset, 0)
                var end: Int64
                if k + 1 < r.words.count { end = max(r.words[k + 1].0 - offset, 0) } else if let c = r.closing { end = max(c - offset, 0) } else {
                    let cap = start + 3000
                    end = nextStart.map { min(max($0 - offset, 0), cap) } ?? cap
                }
                end = max(end, start)
                words.append(MusicLyricWord(text: w.1, startMs: start, endMs: end))
            }
            if var last = words.last { last.text = trimTrailing(last.text); words[words.count - 1] = last }
            let lineText = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            out.append(MusicLyricLine(timeMs: t, text: lineText, endMs: words.last?.endMs, words: words))
        }
        return out
    }

    private static func trimTrailing(_ s: String) -> String {
        var x = s
        while let l = x.last, l.isWhitespace { x.removeLast() }
        return x
    }

    /// Inline `<mm:ss.xx>` stamps. Each one starts the word after it. Nil when the text has none.
    private static func parseEnhanced(_ body: String, lineStart: Int64) -> (text: String, words: [(Int64, String)], closing: Int64?)? {
        guard body.contains("<") else { return nil }
        var segments: [(Int64?, String)] = [(nil, "")]
        var i = body.startIndex
        var sawTag = false
        while i < body.endIndex {
            let ch = body[i]
            if ch == "<", let gt = body[i...].prefix(16).firstIndex(of: ">"),
               let ms = stampMs(String(body[body.index(after: i)..<gt])) {
                segments.append((ms, ""))
                sawTag = true
                i = body.index(after: gt)
                continue
            }
            segments[segments.count - 1].1.append(ch)
            i = body.index(after: i)
        }
        guard sawTag else { return nil }
        var words: [(Int64, String)] = []
        var closing: Int64?
        for (idx, seg) in segments.enumerated() {
            let start = seg.0 ?? lineStart
            let raw = seg.1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if idx == segments.count - 1, seg.0 != nil { closing = seg.0 } else if !raw.isEmpty, let last = words.last, !last.1.hasSuffix(" ") {
                    words[words.count - 1].1 += " "
                }
                continue
            }
            if raw.first?.isWhitespace == true, let last = words.last, !last.1.hasSuffix(" ") { words[words.count - 1].1 += " " }
            let trailing = raw.last?.isWhitespace == true ? " " : ""
            words.append((start, trimmed + trailing))
        }
        guard !words.isEmpty else { return nil }
        let text = words.map(\.1).joined().trimmingCharacters(in: .whitespaces)
        return (text, words, closing)
    }

    /// `mm:ss`, `mm:ss.x`, `mm:ss.xx`, `mm:ss.xxx` (a colon before the fraction is also seen in the wild).
    static func stampMs(_ tag: String) -> Int64? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.count <= 3, let min = Int64(parts[0]), min >= 0 else { return nil }
        let secPart: Substring
        var frac = ""
        if parts.count == 3 { secPart = parts[1]; frac = String(parts[2]) } else {
            let sp = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard sp.count <= 2 else { return nil }
            secPart = sp[0]
            if sp.count == 2 { frac = String(sp[1]) }
        }
        guard let sec = Int64(secPart), sec >= 0, frac.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
        let padded = String((frac + "000").prefix(3))
        return min * 60_000 + sec * 1000 + (Int64(padded) ?? 0)
    }

    private static func offsetMs(_ tag: String) -> Int64? {
        guard tag.lowercased().hasPrefix("offset:") else { return nil }
        return Int64(tag.dropFirst("offset:".count).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+", with: ""))
    }

    // MARK: TTML

    /// TTML clock values: `1.241s`, `500ms`, `h:mm:ss.fff`, `m:ss.fff`, or bare seconds.
    static func clock(_ raw: String?) -> Int64? { MusicTime.parseMs(raw) }

    /// The `<ttm:agent>` declarations of a TTML head: singer id to "person", "group" or "other".
    static func agentTypes(in text: String) -> [String: String] {
        guard let re = try? NSRegularExpression(pattern: #"<(?:\w+:)?agent\b[^>]*>"#) else { return [:] }
        let ns = text as NSString
        var out: [String: String] = [:]
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            func attr(_ name: String) -> String? {
                guard let r = tag.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*["']([^"']*)["']"#, options: .regularExpression) else { return nil }
                let seg = String(tag[r])
                return seg.split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }
            }
            if let id = attr("xml:id") ?? attr("id"), let type = attr("type") { out[id] = type }
        }
        return out
    }

    static func parseTTML(_ text: String) -> [MusicParsedLine] {
        let wrapped = text.contains("<tt") ? text : "<tt><body>\(text)</body></tt>"
        let builder = TTMLBuilder()
        let parser = XMLParser(data: Data(wrapped.utf8))
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        _ = parser.parse()
        return builder.result()
    }

    // MARK: JSON (small fallback shape: list of {text|words|line, time|startTime|start|t, words:[...]}, times in milliseconds)

    private static func parseJSON(_ text: String) -> [MusicParsedLine]? {
        guard let data = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var rows: [[String: Any]]?
        if let a = obj as? [[String: Any]] { rows = a } else if let d = obj as? [String: Any] {
            for k in ["lyrics", "lines", "element"] { if let a = d[k] as? [[String: Any]] { rows = a; break } }
        }
        guard let rows else { return nil }
        func ms(_ any: Any?) -> Int64? {
            if let n = any as? NSNumber { return n.int64Value }
            if let s = any as? String { return Int64(s) ?? Double(s).map { Int64($0) } }
            return nil
        }
        var out: [MusicParsedLine] = []
        for r in rows {
            let t = (r["text"] as? String) ?? (r["words"] as? String) ?? (r["line"] as? String)
            guard let t else { continue }
            let start = ms(r["time"]) ?? ms(r["startTime"]) ?? ms(r["start"]) ?? ms(r["t"])
            var words: [MusicLyricWord]?
            if let ws = r["words"] as? [[String: Any]] {
                words = ws.compactMap { w in
                    guard let wt = (w["text"] as? String) ?? (w["word"] as? String) else { return nil }
                    let s = ms(w["startTime"]) ?? ms(w["start"]) ?? ms(w["time"]) ?? start ?? 0
                    let e = ms(w["endTime"]) ?? ms(w["end"]) ?? (s + 500)
                    return MusicLyricWord(text: wt, startMs: s, endMs: e)
                }
            }
            out.append(MusicParsedLine(line: MusicLyricLine(timeMs: start ?? 0, text: t, words: words), timed: start != nil))
        }
        return out.sorted { $0.line.timeMs < $1.line.timeMs }
    }
}

// MARK: - TTML reader

/// Streams a TTML document into lines. Words are spans; text between spans becomes the trailing space of the word before it.
/// A span with role x-bg is a background voice: either it wraps timed spans (every inner word is background) or it is itself one word.
private final class TTMLBuilder: NSObject, XMLParserDelegate {
    private struct Span {
        var begin: Int64?
        var end: Int64?
        var background: Bool
        var childCount = 0
        var text = ""
        var prefix = ""
        var firstWordIndex: Int
    }
    private struct Container {
        var begin: Int64?
        var end: Int64?
        var key: String?
        var voice: String?
        var text = ""
        var words: [MusicLyricWord] = []
        var spans: [Span] = []
    }

    private var lines: [MusicParsedLine] = []
    private var keys: [Int: String] = [:]
    private var readings: [String: (text: String, words: [MusicLyricWord])] = [:]
    private var current: Container?
    private var inTransliteration = 0
    private var readingKey: String?
    /// Inside a translation or reading span of the lead text: its words are not part of the line.
    private var skipSpanDepth = 0

    func result() -> [MusicParsedLine] {
        var out = lines
        for i in out.indices {
            guard let key = keys[i], let r = readings[key] else { continue }
            let reading = MusicLyricsText.collapsed(r.text)
            if !reading.isEmpty, reading != MusicLyricsText.collapsed(out[i].line.text) {
                out[i].line.romanized = reading
                out[i].line.romanizedWords = r.words.isEmpty ? nil : r.words
            }
        }
        return out.enumerated().sorted { a, b in
            switch (a.element.timed, b.element.timed) {
            case (true, true): return (a.element.line.timeMs, a.offset) < (b.element.line.timeMs, b.offset)
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    private func attr(_ a: [String: String], _ name: String) -> String? {
        if let v = a[name] { return v }
        return a.first { $0.key.hasSuffix(":" + name) }?.value
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes a: [String: String]) {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        switch local {
        case "transliteration": inTransliteration += 1
        case "text" where inTransliteration > 0:
            readingKey = a["for"]
            current = Container(begin: MusicLyricsParsers.clock(a["begin"]), end: MusicLyricsParsers.clock(a["end"]), key: a["for"])
        case "p" where inTransliteration == 0:
            current = Container(begin: MusicLyricsParsers.clock(a["begin"]), end: MusicLyricsParsers.clock(a["end"]), key: attr(a, "key"),
                                voice: attr(a, "agent").flatMap { $0.isEmpty ? nil : $0 })
        case "span":
            guard var c = current else { return }
            if skipSpanDepth > 0 || ["x-translation", "x-roman"].contains(attr(a, "role") ?? "") { skipSpanDepth += 1; return }
            if !c.spans.isEmpty {
                let i = c.spans.count - 1
                if c.spans[i].childCount == 0 {
                    // Text written before the first inner span (an opening parenthesis) is kept for that span's word.
                    let t = c.spans[i].text
                    c.spans[i].prefix = t.trimmingCharacters(in: .whitespaces).isEmpty ? "" : t
                    c.spans[i].text = ""
                }
                c.spans[i].childCount += 1
            }
            let bgParent = c.spans.last?.background ?? false
            let bg = bgParent || attr(a, "role") == "x-bg"
            c.spans.append(Span(begin: MusicLyricsParsers.clock(a["begin"]), end: MusicLyricsParsers.clock(a["end"]), background: bg, firstWordIndex: c.words.count))
            current = c
        case "br":
            if current != nil { characters(" ") }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { characters(string) }

    private func characters(_ raw: String) {
        guard skipSpanDepth == 0, var c = current else { return }
        let s = collapse(raw)
        guard !s.isEmpty else { return }
        c.text += s
        if var span = c.spans.last {
            if span.childCount == 0 { span.text += s } else if c.words.count > span.firstWordIndex {
                c.words[c.words.count - 1].text += s
            } else { span.prefix += s }
            c.spans[c.spans.count - 1] = span
        } else if !c.words.isEmpty {
            c.words[c.words.count - 1].text += s
        }
        current = c
    }

    private func collapse(_ s: String) -> String {
        var out = ""
        var lastSpace = false
        for ch in s {
            if ch.isWhitespace { if !lastSpace { out.append(" ") }; lastSpace = true } else { out.append(ch); lastSpace = false }
        }
        return out
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        switch local {
        case "transliteration": inTransliteration = max(0, inTransliteration - 1)
        case "span":
            if skipSpanDepth > 0 { skipSpanDepth -= 1; return }
            guard var c = current, let span = c.spans.popLast() else { return }
            if span.childCount == 0 {
                let enclosing = c.spans.reversed()
                let begin = span.begin ?? enclosing.compactMap(\.begin).first ?? c.begin
                let end = span.end ?? enclosing.compactMap(\.end).first ?? c.end
                var text = span.text
                // Text on an enclosing wrapper that came before this word (an opening parenthesis) belongs to it.
                if let parent = c.spans.last, parent.childCount == 1, !parent.prefix.isEmpty {
                    text = parent.prefix + text
                    c.spans[c.spans.count - 1].prefix = ""
                }
                if !text.trimmingCharacters(in: .whitespaces).isEmpty, let b = begin {
                    c.words.append(MusicLyricWord(text: text, startMs: b, endMs: max(end ?? b, b), background: span.background))
                }
            }
            current = c
        case "text" where readingKey != nil:
            finishReading()
        case "p" where inTransliteration == 0:
            finishLine()
        default: break
        }
    }

    private func finishReading() {
        guard let c = current, let k = readingKey else { return }
        readingKey = nil
        current = nil
        let words = Self.tidy(c.words)
        readings[k] = (c.text.trimmingCharacters(in: .whitespaces), words)
    }

    private func finishLine() {
        guard let c = current else { return }
        current = nil
        let words = MusicLyricsSyllables.glue(Self.tidy(c.words))
        let text = c.text.trimmingCharacters(in: .whitespaces)
        // Apple opens a paragraph a hair late on soft consonants: the line starts at the earlier of the paragraph and its first word.
        let firstWord = words.map(\.startMs).min()
        let begin: Int64? = c.begin.map { b in firstWord.map { min(b, $0) } ?? b } ?? firstWord
        guard !text.isEmpty || begin != nil else { return }
        let end = c.end ?? words.map(\.endMs).max()
        var line = MusicLyricLine(timeMs: begin ?? 0, text: text, endMs: end, words: words.isEmpty ? nil : words)
        line.voice = c.voice
        if let k = c.key { keys[lines.count] = k }
        lines.append(MusicParsedLine(line: line, timed: begin != nil))
    }

    private static func tidy(_ words: [MusicLyricWord]) -> [MusicLyricWord] {
        var w = words
        if var f = w.first { while f.text.first == " " { f.text.removeFirst() }; w[0] = f }
        if var l = w.last { while l.text.last == " " { l.text.removeLast() }; w[w.count - 1] = l }
        return w.filter { !$0.text.isEmpty }
    }
}
