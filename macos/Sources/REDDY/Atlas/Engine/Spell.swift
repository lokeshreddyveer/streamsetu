import Foundation

/// Step 4: spelling correction against the vocabulary of the atlas itself (a few thousand words), never against a general dictionary.
struct SpellCorrector: Sendable {
    private let freq: [String: Int]
    private let byLength: [Int: [String]]

    init(vocabulary: [String: Int]) {
        freq = vocabulary
        var b: [Int: [String]] = [:]
        for w in vocabulary.keys { b[w.count, default: []].append(w) }
        byLength = b
    }

    var size: Int { freq.count }
    func knows(_ w: String) -> Bool { freq[w] != nil }

    /// Returns the word itself if known, short, numeric or has no close match.
    func correct(_ w: String) -> String {
        guard freq[w] == nil, w.count >= 4, w.allSatisfy({ $0.isLetter }) else { return w }
        let limit = w.count >= 8 ? 2 : 1
        var best: (String, Int, Int)?
        for len in max(1, w.count - limit)...(w.count + limit) {
            for cand in byLength[len] ?? [] {
                // A typo keeps its first letter far more often than not; this also keeps the scan cheap.
                guard cand.first == w.first || limit == 2 else { continue }
                let d = Self.distance(w, cand, limit: limit)
                guard d <= limit else { continue }
                let f = freq[cand] ?? 0
                if best == nil || d < best!.1 || (d == best!.1 && f > best!.2) { best = (cand, d, f) }
            }
        }
        return best?.0 ?? w
    }

    /// Damerau-Levenshtein (optimal string alignment) with an early exit above `limit`.
    static func distance(_ a: String, _ b: String, limit: Int) -> Int {
        let s = Array(a.unicodeScalars), t = Array(b.unicodeScalars)
        if abs(s.count - t.count) > limit { return limit + 1 }
        var prev2 = [Int](repeating: 0, count: t.count + 1), prev = Array(0...t.count), cur = prev
        for i in 1...max(1, s.count) where !s.isEmpty {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...max(1, t.count) where !t.isEmpty {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                var v = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, s[i - 1] == t[j - 2], s[i - 2] == t[j - 1] { v = min(v, prev2[j - 2] + 1) }
                cur[j] = v
                rowMin = min(rowMin, v)
            }
            if rowMin > limit { return limit + 1 }
            prev2 = prev; prev = cur
        }
        return prev[t.count]
    }
}
