import Foundation

/// A small spelling index over the words Music has seen (titles, artists, albums, films, the person's own searches). It answers two questions in well under
/// a millisecond: "is this word spelled the way the catalogue spells it?" and "which known word did they mean?".
///
/// A word is a candidate for a typed word when it is one keystroke away (a letter dropped, added, changed or two swapped; two keystrokes for long words), or
/// when it is the same word written another way (the Indian-language spellings that have no standard Latin form: "Zinda" and "Jinda", "Daakko" and "Dakko",
/// through `MusicTransliterationKey`). The typed word is never "corrected" while it could still be the start of a known word, so typing is never fought.
/// Pure and value-typed: it holds no clock, no network and no storage.
struct MusicSpellIndex: Sendable {
    /// Known word -> how much it has been seen (more is likelier).
    private(set) var weight: [String: Int] = [:]
    /// A word with one letter removed -> the words that give it. One-keystroke candidates come from here.
    private var deletes: [String: [String]] = [:]
    /// The phonetic key -> the words that share it.
    private var phonetic: [String: [String]] = [:]
    /// Words grouped by their first two letters, for the two-keystroke search of long words.
    private var buckets: [String: [String]] = [:]
    /// Known words in order, for "does any word start with this?".
    private var sortedWords: [String] = []
    private var dirty = false

    static let maxWords = 60_000
    static let minWordLength = 3
    static let maxIndexedLength = 24

    var count: Int { weight.count }

    // MARK: building

    /// Adds the words of `text` (split on anything that is not a letter or digit). Words shorter than three letters carry no spelling signal and are skipped.
    mutating func add(text: String, weight w: Int = 1) {
        for token in Self.tokens(text) { add(word: token, weight: w) }
    }

    mutating func add(word: String, weight w: Int = 1) {
        let word = word.lowercased()
        guard word.count >= Self.minWordLength, word.count <= Self.maxIndexedLength else { return }
        if let old = weight[word] { weight[word] = old + max(1, w); return }
        guard weight.count < Self.maxWords else { return }
        weight[word] = max(1, w)
        dirty = true
        let chars = Array(word)
        for i in chars.indices {
            var d = chars; d.remove(at: i)
            deletes[String(d), default: []].append(word)
        }
        deletes[word, default: []].append(word)
        let key = MusicTransliterationKey.key(word: word)
        if !key.isEmpty { phonetic[key, default: []].append(word) }
        buckets[String(word.prefix(2)), default: []].append(word)
    }

    mutating func prepare() {
        guard dirty else { return }
        sortedWords = weight.keys.sorted()
        dirty = false
    }

    // MARK: asking

    func isKnown(_ word: String) -> Bool { weight[word.lowercased()] != nil }

    /// True when some known word starts with `prefix` (needs `prepare()` after the last add).
    func hasWord(startingWith prefix: String) -> Bool {
        let p = prefix.lowercased()
        guard !p.isEmpty else { return false }
        var lo = 0, hi = sortedWords.count
        while lo < hi { let mid = (lo + hi) / 2; if sortedWords[mid] < p { lo = mid + 1 } else { hi = mid } }
        return lo < sortedWords.count && sortedWords[lo].hasPrefix(p)
    }

    /// How many keystrokes away a word may be and still count as the same word typed badly.
    static func allowedDistance(forLength n: Int) -> Int { n <= 3 ? 0 : (n <= 6 ? 1 : 2) }

    /// The known word the person most likely meant by `token`, or nil when the token is already a known word (or could still become one) or nothing is close.
    func correction(for token: String, stillTyping: Bool = false) -> String? {
        let t = token.lowercased()
        guard t.count >= Self.minWordLength else { return nil }
        if weight[t] != nil { return nil }
        if stillTyping, hasWord(startingWith: t) { return nil }
        let limit = Self.allowedDistance(forLength: t.count)
        var best: (word: String, score: Double)?
        func consider(_ w: String, viaPhonetic: Bool) {
            guard w != t else { return }
            let d = Self.distance(t, w, limit: max(limit, viaPhonetic ? 3 : 0))
            guard d <= max(limit, viaPhonetic ? 3 : 0) else { return }
            // Fewer keystrokes first; the same word spelled another way counts as half a keystroke closer; a likelier word wins a tie.
            let score = Double(d) - (viaPhonetic ? 0.5 : 0) - min(0.45, log(Double(weight[w] ?? 1) + 1) / 20)
            if best == nil || score < best!.score { best = (w, score) }
        }
        if limit >= 1 {
            var variants: [String] = [t]
            let chars = Array(t)
            for i in chars.indices { var d = chars; d.remove(at: i); variants.append(String(d)) }
            var seen = Set<String>()
            for v in variants { for w in deletes[v] ?? [] where seen.insert(w).inserted { consider(w, viaPhonetic: false) } }
            if limit >= 2, best == nil {
                for w in buckets[String(t.prefix(2))] ?? [] where abs(w.count - t.count) <= limit { consider(w, viaPhonetic: false) }
            }
        }
        let key = MusicTransliterationKey.key(word: t)
        if !key.isEmpty { for w in phonetic[key] ?? [] { consider(w, viaPhonetic: true) } }
        return best?.word
    }

    /// The query with each wrong word replaced by the known word it was meant to be. The last word is left alone while it could still be the start of a word.
    /// `changed` is false when nothing needed fixing.
    func corrected(query: String, typingLastWord: Bool = true) -> (text: String, changed: Bool) {
        let parts = Self.tokens(query)
        guard !parts.isEmpty else { return (query, false) }
        var out: [String] = [], changed = false
        for (i, p) in parts.enumerated() {
            let last = i == parts.count - 1
            if let c = correction(for: p, stillTyping: last && typingLastWord) { out.append(c); changed = true } else { out.append(p) }
        }
        return (out.joined(separator: " "), changed)
    }

    // MARK: pieces

    static func tokens(_ text: String) -> [String] {
        MusicText.normalize(text).split(separator: " ").map(String.init)
    }

    /// Optimal string alignment distance (a swap of two neighbours is one keystroke), giving up past `limit`.
    static func distance(_ a: String, _ b: String, limit: Int) -> Int {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        if abs(x.count - y.count) > limit { return limit + 1 }
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev2 = [Int](repeating: 0, count: y.count + 1)
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                var v = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] { v = min(v, prev2[j - 2] + 1) }
                cur[j] = v
                rowMin = min(rowMin, v)
            }
            if rowMin > limit { return limit + 1 }
            (prev2, prev, cur) = (prev, cur, prev2)
        }
        return prev[y.count]
    }
}
