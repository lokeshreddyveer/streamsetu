import Foundation

// Songs of Indian films that are set to a documented raga, read from Wikipedia's list "List of film songs based on ragas". Every row says which raga, song, film,
// composer, singers and (when it is given) language; nothing is added that the list does not say. The parser is a pure function of the page's wikitext.

struct MusicRagaSong: Codable, Hashable, Sendable, Identifiable {
    var ragas: [String]
    var title: String
    var film: String
    var year: Int?
    var composer: String
    var singers: [String]
    var language: String?
    var id: String { (ragas.first ?? "") + "|" + title + "|" + film }
    var primaryRaga: String { ragas.first ?? "" }
}

struct MusicRagaGroup: Hashable, Sendable, Identifiable {
    var name: String
    var aliases: [String]
    var songs: [MusicRagaSong]
    var id: String { MusicRagaTable.key(name) }
}

enum MusicRagaTable {
    static let page = "List_of_film_songs_based_on_ragas"
    static var url: URL { URL(string: "https://en.wikipedia.org/w/api.php?action=parse&page=\(page)&prop=wikitext&format=json&formatversion=2")! }

    /// The wikitext inside the API's JSON reply.
    static func wikitext(fromAPI data: Data) -> String? {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let p = j["parse"] as? [String: Any] else { return nil }
        return p["wikitext"] as? String
    }

    private static func replace(_ s: String, _ pattern: String, _ template: String, options: NSRegularExpression.Options = [.dotMatchesLineSeparators]) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// One cell's text without references, templates, link brackets, emphasis and markup.
    static func clean(_ raw: String) -> String {
        var s = raw
        s = replace(s, "<ref[^>]*?/>", "")
        s = replace(s, "<ref[^>]*?>.*?</ref>", "")
        s = replace(s, "<br\\s*/?>", " / ")
        for _ in 0..<2 { s = replace(s, "\\{\\{[^{}]*\\}\\}", "") }
        s = replace(s, "\\[\\[(?:[^\\]|]*\\|)?([^\\]]*)\\]\\]", "$1")
        s = replace(s, "'{2,}", "")
        s = replace(s, "<[^>]+>", "")
        s = replace(s, "\\s+", " ")
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " \"“”"))
    }

    /// The text of a cell and its rowspan (1 when it has none).
    private static func split(cell: String) -> (text: String, span: Int) {
        // Cell attributes ("rowspan=2|") come before the first bar and hold no link, template or tag; a bar inside "[[a|b]]" or "{{cite|x=y}}" is part of the text.
        guard let bar = cell.firstIndex(of: "|"), cell[..<bar].contains("="), !cell[..<bar].contains(where: { "[{<".contains($0) }) else { return (cell, 1) }
        let attrs = cell[..<bar]
        var span = 1
        if let r = attrs.range(of: "rowspan") {
            let digits = attrs[r.upperBound...].drop { !$0.isNumber }.prefix { $0.isNumber }
            span = Int(digits) ?? 1
        }
        return (String(cell[cell.index(after: bar)...]), max(1, span))
    }

    /// Every song row of the list, with the cells a row leaves out (a composer shared down several rows) filled in from above.
    static func parse(wikitext: String) -> [MusicRagaSong] {
        var out: [MusicRagaSong] = []
        for table in wikitext.components(separatedBy: "\n{|").dropFirst() {
            let body = table.components(separatedBy: "\n|}").first ?? table
            var pending: [Int: (text: String, left: Int)] = [:]
            for row in body.components(separatedBy: "\n|-").dropFirst() {
                var cells: [String] = []
                var isHeader = false
                for line in row.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false) {
                    if line.hasPrefix("!") { isHeader = true; break }
                    if line.hasPrefix("|") && !line.hasPrefix("|}") { cells.append(String(line.dropFirst())) }
                    else if !cells.isEmpty { cells[cells.count - 1] += " " + line }
                }
                guard !isHeader, !cells.isEmpty else { continue }
                var placed: [String] = []
                var col = 0, k = 0
                while true {
                    if let p = pending[col], p.left > 0 { placed.append(p.text); pending[col] = (p.text, p.left - 1); col += 1; continue }
                    guard k < cells.count else { break }
                    let (text, span) = split(cell: cells[k]); k += 1
                    let v = clean(text)
                    if span > 1 { pending[col] = (v, span - 1) }
                    placed.append(v); col += 1
                }
                if let song = song(from: placed) { out.append(song) }
            }
        }
        return out
    }

    /// Columns are raga, song, film, composer, singers and (sometimes) language.
    static func song(from c: [String]) -> MusicRagaSong? {
        guard c.count >= 5, !c[0].isEmpty, !c[1].isEmpty else { return nil }
        let (film, year) = filmAndYear(c[2])
        return MusicRagaSong(ragas: ragaNames(c[0]), title: c[1], film: film, year: year, composer: c[3], singers: people(c[4]), language: c.count > 5 && !c[5].isEmpty ? c[5] : nil)
    }

    /// "Ābhēri (Carnatic) / Bhimpalasi (Hindustani)" is two names for one scale.
    static func ragaNames(_ s: String) -> [String] {
        s.split(whereSeparator: { "/".contains($0) }).map { part in
            var n = part.trimmingCharacters(in: .whitespaces)
            if let p = n.firstIndex(of: "(") { n = String(n[..<p]).trimmingCharacters(in: .whitespaces) }
            return n
        }.filter { !$0.isEmpty }
    }

    /// "Laila Majnu(1953 film)" is the film and its year.
    static func filmAndYear(_ s: String) -> (String, Int?) {
        guard let open = s.lastIndex(of: "("), s.hasSuffix(")") else { return (s, nil) }
        let inside = s[s.index(after: open)..<s.index(before: s.endIndex)]
        let year = inside.split(separator: " ").first.flatMap { Int($0) }.flatMap { (1900...2100).contains($0) ? $0 : nil }
        guard let y = year else { return (s, nil) }
        return (String(s[..<open]).trimmingCharacters(in: .whitespaces), y)
    }

    static func people(_ s: String) -> [String] {
        s.replacingOccurrences(of: " and ", with: " & ").split(separator: "&").map {
            var n = $0.trimmingCharacters(in: .whitespaces)
            if let p = n.range(of: " (singer)") ?? n.range(of: " (actor)") ?? n.range(of: " (actress)") { n.removeSubrange(p) }
            return n
        }.filter { !$0.isEmpty }
    }

    static func key(_ name: String) -> String { MusicText.normalize(name) }

    /// Songs grouped by their first raga name, the longest groups first. Another name for the same scale is kept as an alias.
    static func groups(_ songs: [MusicRagaSong]) -> [MusicRagaGroup] {
        var by: [String: MusicRagaGroup] = [:]
        for s in songs {
            guard let name = s.ragas.first else { continue }
            let k = key(name)
            var g = by[k] ?? MusicRagaGroup(name: name, aliases: [], songs: [])
            for a in s.ragas.dropFirst() where !g.aliases.contains(a) && key(a) != k { g.aliases.append(a) }
            g.songs.append(s)
            by[k] = g
        }
        return by.values.sorted { $0.songs.count != $1.songs.count ? $0.songs.count > $1.songs.count : $0.name < $1.name }
    }

    static func filter(_ groups: [MusicRagaGroup], query: String) -> [MusicRagaGroup] {
        let q = key(query)
        guard !q.isEmpty else { return groups }
        return groups.filter { g in key(g.name).contains(q) || g.aliases.contains { key($0).contains(q) } }
    }
}

/// The list, fetched once a month from Wikipedia and kept on this device.
actor MusicRagaCatalog {
    static let shared = MusicRagaCatalog()
    static let maxAge: TimeInterval = 30 * 86_400
    private struct Stored: Codable { var fetched: Date; var songs: [MusicRagaSong] }
    private var memory: [MusicRagaSong]?

    private var file: URL { MusicStorage.subfolder("Ragas").appendingPathComponent("raga-songs-v1.json") }

    func songs(online: Bool, now: Date = Date()) async -> [MusicRagaSong] {
        if let memory { return memory }
        let stored = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        if let s = stored, now.timeIntervalSince(s.fetched) < Self.maxAge { memory = s.songs; return s.songs }
        guard online else { return stored?.songs ?? [] }
        do {
            let data = try await MusicHTTP().send(url: MusicRagaTable.url, method: "GET", query: [:], headers: [:], body: nil)
            guard let text = MusicRagaTable.wikitext(fromAPI: data) else { return stored?.songs ?? [] }
            let parsed = MusicRagaTable.parse(wikitext: text)
            guard !parsed.isEmpty else { return stored?.songs ?? [] }
            if let d = try? JSONEncoder().encode(Stored(fetched: now, songs: parsed)) { try? d.write(to: file, options: .atomic) }
            memory = parsed
            return parsed
        } catch { return stored?.songs ?? [] }
    }
}
