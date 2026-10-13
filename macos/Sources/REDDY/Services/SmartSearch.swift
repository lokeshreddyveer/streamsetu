import Foundation

/// Reads a typed search the way a person means it: "hindi movies 2024" is Hindi titles from 2024, and the word "movies" is not part of the title.
enum SmartQueryParser {
    struct Parsed: Equatable { var text: String; var year: Int? }

    /// Words that say what kind of thing is wanted, which the screen already knows.
    static let filler: Set<String> = ["movie", "movies", "film", "films", "series", "show", "shows", "serial", "serials", "new", "latest", "full"]

    static func parse(_ raw: String) -> Parsed {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        // One word is always taken as it is: "1917" and "2012" are films, not years.
        guard tokens.count > 1 else { return Parsed(text: trimmed, year: nil) }
        var year: Int?
        var rest: [String] = []
        for t in tokens {
            if year == nil, t.count == 4, let y = Int(t), (1900...2099).contains(y) { year = y } else { rest.append(t) }
        }
        let meaningful = rest.filter { !filler.contains($0.lowercased()) }
        if meaningful.isEmpty { return Parsed(text: year != nil ? "" : rest.joined(separator: " "), year: year) }
        return Parsed(text: meaningful.joined(separator: " "), year: year)
    }
}

/// Fixes a misspelt search using the words that really occur in the library's titles and channel names. It only steps in when the search found
/// nothing, and it tells the person what it searched for instead.
final class SpellingIndex: @unchecked Sendable {
    private let db: DatabaseManager?
    private let lock = NSLock()
    private var words: [String: Int]?

    init(db: DatabaseManager) { self.db = db }
    init(words: [String: Int]) { self.db = nil; self.words = words }      // for tests

    func correct(_ query: String) -> String? { Self.correct(query, vocabulary: vocabulary()) }

    private func vocabulary() -> [String: Int] {
        lock.withLock {
            if let words { return words }
            var counts: [String: Int] = [:]
            let rows: [String] = (try? db?.read { c in
                try c.query("SELECT normalized_title FROM movies UNION ALL SELECT normalized_title FROM series UNION ALL SELECT normalized_name FROM channels") { $0.string(0) }
            }) ?? []
            for row in rows {
                for w in row.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) where w.count >= 3 { counts[String(w), default: 0] += 1 }
            }
            words = counts
            return counts
        }
    }

    static func correct(_ query: String, vocabulary: [String: Int]) -> String? {
        guard !vocabulary.isEmpty else { return nil }
        var changed = false
        let fixed = query.split(whereSeparator: \.isWhitespace).map { raw -> String in
            let w = raw.lowercased().filter { $0.isLetter || $0.isNumber }
            guard w.count >= 4, vocabulary[w] == nil else { return String(raw) }
            if vocabulary.keys.contains(where: { $0.hasPrefix(w) }) { return String(raw) }        // a word being typed is not a mistake
            let allowed = w.count <= 5 ? 1 : 2
            var best: (word: String, distance: Int, count: Int)?
            for (cand, count) in vocabulary where abs(cand.count - w.count) <= allowed && cand.first == w.first {
                let d = distance(w, cand, limit: allowed)
                if d <= allowed, best == nil || d < best!.distance || (d == best!.distance && count > best!.count) { best = (cand, d, count) }
            }
            guard let best else { return String(raw) }
            changed = true
            return best.word
        }
        return changed ? fixed.joined(separator: " ") : nil
    }

    /// Edit distance (insert, delete, change, swap two neighbours), giving up above `limit`.
    static func distance(_ a: String, _ b: String, limit: Int) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev2 = [Int](repeating: 0, count: y.count + 1)
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [Int](repeating: 0, count: y.count + 1)
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] { cur[j] = min(cur[j], prev2[j - 2] + 1) }
                rowMin = min(rowMin, cur[j])
            }
            if rowMin > limit { return limit + 1 }
            prev2 = prev; prev = cur
        }
        return prev[y.count]
    }
}

/// The last few searches on a screen, newest first, kept on this device.
struct RecentSearches {
    let scope: String
    var defaults: UserDefaults = .standard
    static let limit = 8

    private var key: String { "recentSearches.\(scope)" }

    func list() -> [String] { defaults.stringArray(forKey: key) ?? [] }

    func add(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else { return }
        var all = list().filter { $0.caseInsensitiveCompare(t) != .orderedSame }
        all.insert(t, at: 0)
        defaults.set(Array(all.prefix(Self.limit)), forKey: key)
    }

    func clear() { defaults.removeObject(forKey: key) }
}
