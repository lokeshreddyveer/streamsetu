import Foundation

/// Reads a typed search the way a person says it: "telugu movies 2024 under 2 hours I haven't watched" is Telugu films from 2024 that run under two hours and were never played.
/// It never guesses at a name: only words it knows (a language, a year, "under 2 hours", "unwatched", "4K", "favourites", "top rated") become filters; everything else stays as the title
/// to look for. A search with no such words is returned untouched.
struct NaturalQuery: Equatable, Sendable {
    var text = ""
    var language: String?
    var year: Int?
    var decade: Int?
    var quality: String?
    var minRating: Double?
    var maxMinutes: Int?
    var minMinutes: Int?
    var unwatched = false
    var started = false
    var favorites = false
    var addedWithinDays: Int?

    /// True when at least one filter was found, so the caller knows the search was understood and not just a title.
    var isStructured: Bool { language != nil || year != nil || decade != nil || quality != nil || minRating != nil || maxMinutes != nil || minMinutes != nil || unwatched || started || favorites || addedWithinDays != nil }

    /// "Telugu · 2024 · under 2 h · unwatched": what was understood, for showing under the search box.
    var summary: [String] {
        var out: [String] = []
        if let language { out.append(language) }
        if let year { out.append(String(year)) }
        if let decade { out.append("\(decade)s") }
        if let quality { out.append(quality) }
        if let minRating { out.append("rated \(Int(minRating))+") }
        if let maxMinutes { out.append("under " + Self.length(maxMinutes)) }
        if let minMinutes { out.append("over " + Self.length(minMinutes)) }
        if unwatched { out.append("unwatched") }
        if started { out.append("unfinished") }
        if favorites { out.append("favourites") }
        if addedWithinDays != nil { out.append("added recently") }
        return out
    }

    private static func length(_ minutes: Int) -> String { minutes % 60 == 0 ? "\(minutes / 60) h" : (minutes > 90 ? String(format: "%.1f h", Double(minutes) / 60) : "\(minutes) min") }

    private static let qualities: [(words: [String], name: String)] = [(["4k", "uhd", "2160p"], "4K"), (["1080p", "fhd"], "1080p"), (["720p"], "720p"), (["hdr"], "HDR")]
    /// Words that only carry the sense of the sentence and are not part of any title being asked for.
    private static let filler: Set<String> = ["movie", "movies", "film", "films", "series", "show", "shows", "serial", "serials", "me", "find", "show", "please", "that", "which", "i", "ive", "i've"]

    static func parse(_ raw: String, languages: [String] = LanguageTags.known) -> NaturalQuery {
        let tokens = raw.lowercased().replacingOccurrences(of: "’", with: "'").split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        var q = NaturalQuery()
        guard tokens.count > 1 || (tokens.count == 1 && !tokens[0].allSatisfy(\.isNumber)) else { q.text = raw.trimmingCharacters(in: .whitespacesAndNewlines); return q }   // one number is a title ("1917")
        var rest: [String] = []
        var i = 0
        func word(_ k: Int) -> String? { k < tokens.count ? tokens[k] : nil }
        while i < tokens.count {
            let t = tokens[i]
            // "haven't watched", "not watched", "never watched", "unwatched", "not seen"
            if ["unwatched", "unseen"].contains(t) { q.unwatched = true; i += 1; continue }
            if ["havent", "haven't", "not", "never", "didnt", "didn't"].contains(t), let n = word(i + 1), ["watched", "seen", "played"].contains(n) { q.unwatched = true; i += 2; continue }
            if ["havent", "haven't"].contains(t), word(i + 1) == "seen" || word(i + 1) == "watched" { q.unwatched = true; i += 2; continue }
            if ["unfinished", "continue", "resume"].contains(t) { q.started = true; i += 1; continue }
            if ["favorite", "favorites", "favourite", "favourites", "fav", "favs"].contains(t) { q.favorites = true; i += 1; continue }
            if let l = languages.first(where: { $0.lowercased() == t }) { q.language = l; i += 1; continue }
            if let qual = qualities.first(where: { $0.words.contains(t) }) { q.quality = qual.name; i += 1; continue }
            if t == "dolby", word(i + 1) == "vision" { q.quality = "Dolby Vision"; i += 2; continue }
            if t.count == 4, let y = Int(t), (1900...2099).contains(y) { q.year = y; i += 1; continue }
            if t.hasSuffix("s"), let d = Int(t.dropLast()), t.count == 5 || t.count == 3 {                  // 1990s, 90s
                let full = d < 100 ? (d >= 30 ? 1900 + d : 2000 + d) : d
                if full % 10 == 0, (1930...2020).contains(full) { q.decade = full; i += 1; continue }
            }
            if ["top", "best", "highly"].contains(t), ["rated", "rating"].contains(word(i + 1) ?? "") { q.minRating = 8; i += 2; continue }
            if t.hasSuffix("+"), let r = Double(t.dropLast()), (1...10).contains(r) { q.minRating = r; i += 1; continue }
            if ["rated", "rating"].contains(t), let n = word(i + 1), let r = Double(n.hasSuffix("+") ? String(n.dropLast()) : n), (1...10).contains(r) { q.minRating = r; i += 2; continue }
            if ["recent", "recently", "latest"].contains(t) { q.addedWithinDays = 30; i += 1; if word(i) == "added" { i += 1 }; continue }
            // "under 2 hours", "less than 90 minutes", "shorter than 2h", "over 2 hours", "longer than 3h"
            if let (dir, skip) = lengthWord(tokens, i), let (minutes, used) = duration(tokens, i + skip) {
                if dir < 0 { q.maxMinutes = minutes } else { q.minMinutes = minutes }
                i += skip + used; continue
            }
            if filler.contains(t) { i += 1; continue }
            rest.append(String(raw.lowercased().contains(t) ? t : t)); i += 1
        }
        q.text = rest.joined(separator: " ")
        if !q.isStructured { q = NaturalQuery(); q.text = raw.trimmingCharacters(in: .whitespacesAndNewlines) }
        return q
    }

    /// "under", "less than", "shorter than" → -1; "over", "longer than", "more than" → +1; and how many words it took.
    private static func lengthWord(_ t: [String], _ i: Int) -> (Int, Int)? {
        let w = t[i]
        if w == "under" || w == "below" { return (-1, 1) }
        if w == "over" || w == "above" { return (1, 1) }
        if (w == "less" || w == "shorter" || w == "more" || w == "longer"), i + 1 < t.count, t[i + 1] == "than" { return (w == "less" || w == "shorter" ? -1 : 1, 2) }
        return nil
    }

    /// "2 hours", "90 minutes", "2h", "1.5 hours", "2hrs" → minutes, and how many words it took.
    private static func duration(_ t: [String], _ i: Int) -> (Int, Int)? {
        guard i < t.count else { return nil }
        let w = t[i]
        let units: [(String, Double)] = [("hours", 60), ("hour", 60), ("hrs", 60), ("hr", 60), ("h", 60), ("minutes", 1), ("minute", 1), ("mins", 1), ("min", 1), ("m", 1)]
        if let u = units.first(where: { w.hasSuffix($0.0) && Double(w.dropLast($0.0.count)) != nil }) { return (Int(Double(w.dropLast(u.0.count))! * u.1), 1) }
        if let n = Double(w), i + 1 < t.count, let u = units.first(where: { $0.0 == t[i + 1] }) { return (Int(n * u.1), 2) }
        return nil
    }
}
