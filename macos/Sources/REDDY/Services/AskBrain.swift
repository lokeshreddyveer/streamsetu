import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

// MARK: - taste

/// What the person tends to watch, learned from their own history on this device and never sent anywhere: the genres, languages and people that come up most.
struct TasteProfile: Equatable, Sendable {
    var genres: [String: Double] = [:]
    var languages: [String: Double] = [:]
    var people: [String: Double] = [:]
    var titlesSeen = 0

    var isUsable: Bool { titlesSeen >= 5 }

    /// 0 to 1: how much of a title's genres, language and cast the person usually watches. And why, in words.
    func affinity(genreText: String, languages itemLangs: Set<String>, cast: [String]) -> (score: Double, why: String?) {
        let g = genres.filter { genreText.contains($0.key.lowercased()) }.max { $0.value < $1.value }
        let l = itemLangs.compactMap { name in languages[name].map { v in (k: name, v: v) } }.max { $0.v < $1.v }
        let p = cast.compactMap { name in people[name].map { v in (k: name, v: v) } }.max { $0.v < $1.v }
        let score = (g?.value ?? 0) * 0.45 + (l?.v ?? 0) * 0.25 + (p?.v ?? 0) * 0.30
        var why: String?
        if let p, p.v >= 0.5 { why = "You watch \(p.k) a lot" }
        else if let g, g.value >= 0.5 { why = "You often watch \(g.key)" }
        else if let l, l.v >= 0.6 { why = "You mostly watch \(l.k)" }
        return (score, why)
    }

    /// Builds the profile from the last few hundred things watched.
    static func learn(history: SQLiteHistoryRepository, catalog: CatalogRepository, people: PeopleIndex, limit: Int = 300) -> TasteProfile {
        var t = TasteProfile()
        let ids = ((try? history.rawStrings("SELECT item_id FROM watch_history ORDER BY played_at DESC LIMIT \(limit)", [])) ?? [])
        var itemIDs: [String] = [], seen = Set<String>()
        for id in ids {
            var key = id
            if let e = (try? catalog.episode(id: id)).flatMap({ $0 }) { key = e.seriesID }
            if seen.insert(key).inserted { itemIDs.append(key) }
        }
        var genreCount: [String: Int] = [:], langCount: [String: Int] = [:]
        for id in itemIDs {
            let item: LibraryItem? = (try? catalog.movie(id: id)).flatMap { $0 }.map { .movie($0) } ?? (try? catalog.seriesItem(id: id)).flatMap { $0 }.map { .series($0) }
            guard let item else { continue }
            t.titlesSeen += 1
            for g in Self.genreNames(item.genre) { genreCount[g, default: 0] += 1 }
            for l in LanguageTags.languages(of: item) { langCount[l, default: 0] += 1 }
        }
        func scale(_ c: [String: Int]) -> [String: Double] { let m = Double(c.values.max() ?? 1); return c.mapValues { Double($0) / m } }
        t.genres = scale(genreCount); t.languages = scale(langCount)
        var personCount: [String: Int] = [:]
        for (_, names) in people.names(forItems: itemIDs) { for n in Set(names) { personCount[n, default: 0] += 1 } }
        t.people = scale(personCount.filter { $0.value >= 2 })
        return t
    }

    static func genreNames(_ raw: String?) -> [String] {
        (raw ?? "").split(whereSeparator: { ",/|;".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 3 }
    }
}

// MARK: - meaning

/// Compares the meaning of words with the meaning of a title's genre and plot, on this device, using Apple's built-in language model. No network.
struct SemanticMatcher: @unchecked Sendable {
    #if canImport(NaturalLanguage)
    private let embedding: NLEmbedding?
    init() { embedding = NLEmbedding.sentenceEmbedding(for: .english) }
    var isAvailable: Bool { embedding != nil }

    /// Closer to 0 is closer in meaning (cosine distance); nil when the model cannot read the text.
    func distance(_ a: String, _ b: String) -> Double? {
        guard let e = embedding, !a.isEmpty, !b.isEmpty else { return nil }
        let d = e.distance(between: a, and: b)
        return d.isFinite && d < 3 ? d : nil
    }
    #else
    init() {}
    var isAvailable: Bool { false }
    func distance(_ a: String, _ b: String) -> Double? { nil }
    #endif

    /// How well each title fits an idea (genre, title and the start of the plot against the words): 0 (not at all) to 1 (the closest in this list). The model's distances are only
    /// meaningful against each other, so they are compared within the list, and a title that is not clearly closer than ordinary is given 0.
    func rank(idea: String, texts: [(title: String, genre: String?, overview: String?)]) -> [Double] {
        let d: [Double?] = texts.map { t in
            let text = [t.title, t.genre ?? "", String((t.overview ?? "").prefix(300))].filter { !$0.isEmpty }.joined(separator: ". ")
            return distance(idea, text)
        }
        let known = d.compactMap { $0 }
        guard let lo = known.min(), let hi = known.max(), hi - lo > 0.02, lo <= Self.relevant else { return d.map { _ in 0 } }
        return d.map { v in
            guard let v, v <= Self.relevant + 0.05 else { return 0 }
            let f = (hi - v) / (hi - lo)
            return f >= 0.6 ? f : 0
        }
    }

    /// The farthest a title may be, in the model's own measure, and still count as about the same thing. Chosen by measuring: related text sits near 1.0 to 1.2, unrelated near 1.25 to 1.4.
    static let relevant = 1.24
}

// MARK: - the AI as a judge over real candidates

/// After the library has found real candidates, the chosen AI may pick the best of them and say why. It can only choose from the numbered list it is given, so it cannot add a title of its own.
enum JudgeAdvisor {
    static let system = """
    You help someone pick what to watch tonight from a numbered list of films and series that really are in their library. Reply with JSON only, no other text, shaped like:
    [{"n": 3, "why": "short reason"}, ...]
    Pick at most 8 from the list, best first, using only the numbers given. "why" is at most 10 words, specific to that title and to what they asked, with no spoilers. Never add a title that is not in the list.
    """

    struct Candidate: Sendable { let n: Int; let title: String; let year: Int?; let genre: String?; let rating: String?; let overview: String? }

    static func prompt(request: String, taste: String?, candidates: [Candidate]) -> String {
        var p = "What they asked for: " + request.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        if let taste, !taste.isEmpty { p += "What they usually watch: " + taste + "\n" }
        p += "The list:\n"
        for c in candidates {
            p += "\(c.n). \(c.title)" + (c.year.map { " (\($0))" } ?? "") + (c.genre.map { " · \($0)" } ?? "") + (c.rating.map { " · rated \($0)" } ?? "")
            if let o = c.overview, !o.isEmpty { p += " · " + String(o.prefix(140)) }
            p += "\n"
        }
        return p
    }

    /// The picks in order, each with its reason; numbers that are not in the list are dropped.
    static func parse(_ answer: String, valid: Set<Int>) -> [(n: Int, why: String)] {
        guard let start = answer.firstIndex(of: "["), let end = answer.lastIndex(of: "]"), start < end,
              let data = String(answer[start...end]).data(using: .utf8), let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        var seen = Set<Int>(), out: [(Int, String)] = []
        for r in rows {
            guard let n = (r["n"] as? Int) ?? (r["n"] as? Double).map(Int.init), valid.contains(n), seen.insert(n).inserted else { continue }
            out.append((n, ((r["why"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return Array(out.prefix(8))
    }
}


// MARK: - the AI as a memory of who was in what

/// When cast has not been read yet and there is no TMDB key, the chosen AI is asked what a person is best known for. Its list is never shown as it is: each title is looked for in the library
/// by name and year, so a film the AI got wrong, or one the person does not have, simply does not appear.
enum KnownForAdvisor {
    static let system = """
    You list the films and series an actor or director is best known for. Reply with JSON only, no other text, shaped like:
    [{"title": "Pokiri", "year": 2006, "show": false}, ...]
    At most 40 entries, the most popular first, with the original release year. Include only titles you are sure exist and that this person really worked on. If you do not know the person, reply [].
    """

    static func prompt(_ name: String) -> String { "Person: " + name }

    static func parse(_ answer: String, name: String) -> AskLibrary.TMDBFilmography? {
        guard let a = answer.firstIndex(of: "["), let b = answer.lastIndex(of: "]"), a < b,
              let data = String(answer[a...b]).data(using: .utf8), let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        let credits: [(title: String, year: Int?, isShow: Bool)] = rows.compactMap { r in
            guard let t = (r["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            let y = (r["year"] as? Int) ?? (r["year"] as? Double).map(Int.init)
            return (t, y.flatMap { (1900...2100).contains($0) ? $0 : nil }, (r["show"] as? Bool) ?? false)
        }
        return credits.isEmpty ? nil : AskLibrary.TMDBFilmography(name: name, credits: Array(credits.prefix(40)))
    }
}
