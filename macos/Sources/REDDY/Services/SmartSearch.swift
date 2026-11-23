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

    /// Everything derived from the vocabulary once, so a correction does no whole-vocabulary scan: the words sorted (prefix test by binary search), grouped by first letter and length (edit candidates),
    /// by their ending after the first letter (first-letter slips), and by spelling-insensitive key (transliteration).
    struct Index: Sendable {
        let sorted: [String]
        let byFirstAndLength: [String: [String]]
        let byTail: [String: [String]]
        let folded: [String: String]
        init(_ vocabulary: [String: Int]) {
            sorted = vocabulary.keys.sorted()
            var a: [String: [String]] = [:], t: [String: [String]] = [:]
            for w in sorted { a[Self.key(w.first, w.count), default: []].append(w); t[String(w.dropFirst().prefix(3)), default: []].append(w) }
            byFirstAndLength = a; byTail = t
            var best: [String: (w: String, n: Int)] = [:]
            for w in sorted {
                let n = vocabulary[w] ?? 0, k = ArtworkMatchDecision.fold(w)
                if let b = best[k], b.n >= n { continue }
                best[k] = (w, n)
            }
            folded = best.mapValues(\.w)
        }
        static func key(_ first: Character?, _ length: Int) -> String { String(first ?? " ") + String(length) }
        /// Whether any word starts with `prefix`.
        func hasWord(withPrefix prefix: String) -> Bool {
            var lo = 0, hi = sorted.count
            while lo < hi { let m = (lo + hi) / 2; if sorted[m] < prefix { lo = m + 1 } else { hi = m } }
            return lo < sorted.count && sorted[lo].hasPrefix(prefix)
        }
    }

    private var index: Index?
    func correct(_ query: String) -> String? {
        let v = vocabulary()
        let ix: Index = lock.withLock { if let index { return index }; let n = Index(v); index = n; return n }
        return Self.correct(query, vocabulary: v, index: ix)
    }

    /// `index` is built from `vocabulary` when not given (one pass over it, the cost of a single scan).
    static func correct(_ query: String, vocabulary: [String: Int], index: Index? = nil) -> String? {
        guard !vocabulary.isEmpty else { return nil }
        let ix = index ?? Index(vocabulary)
        var changed = false
        let fixed = query.split(whereSeparator: \.isWhitespace).map { raw -> String in
            let w = raw.lowercased().filter { $0.isLetter || $0.isNumber }
            guard w.count >= 4, vocabulary[w] == nil else { return String(raw) }
            if ix.hasWord(withPrefix: w) { return String(raw) }        // a word being typed is not a mistake
            if let alt = ix.folded[ArtworkMatchDecision.fold(w)], alt != w { changed = true; return alt }        // same word spelt another way (transliteration)
            let allowed = w.count <= 5 ? 1 : 2
            func better(_ d: Int, _ cand: String, than best: (word: String, distance: Int, count: Int)?) -> Bool {
                guard let best else { return true }
                let c = vocabulary[cand] ?? 0
                return d < best.distance || (d == best.distance && (c > best.count || (c == best.count && cand < best.word)))
            }
            var best: (word: String, distance: Int, count: Int)?
            for len in (w.count - allowed)...(w.count + allowed) {
                for cand in ix.byFirstAndLength[Index.key(w.first, len)] ?? [] {
                    let d = distance(w, cand, limit: allowed)
                    if d <= allowed, better(d, cand, than: best) { best = (cand, d, vocabulary[cand] ?? 0) }
                }
            }
            if best == nil, w.count >= 5 {
                // The first letter is the slip ("qvengers"): same ending, one edit.
                for cand in ix.byTail[String(w.dropFirst().prefix(3))] ?? [] where abs(cand.count - w.count) <= 1 && cand.first != w.first {
                    let d = distance(w, cand, limit: 1)
                    if d <= 1, better(d, cand, than: best) { best = (cand, d, vocabulary[cand] ?? 0) }
                }
            }
            guard let best else { return String(raw) }
            changed = true
            return best.word
        }
        return changed ? fixed.joined(separator: " ") : nil
    }

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
