import Testing
import Foundation
@testable import REDDY

/// The indexed SpellingIndex must answer exactly what a plain scan of the whole vocabulary answers (the scan is kept here as the reference).
@Suite("SpellingIndex: indexed lookup equals the reference scan") struct SpellingIndexEquivalenceTests {
    static let vocab: [String: Int] = {
        var v: [String: Int] = [:]
        let words = "avengers endgame infinity war interstellar inception baahubali conclusion pushpa kalki dhoom jawan pathaan animal gladiator godfather matrix reloaded revolutions parasite squid game money heist amelie casablanca titanic avatar frozen shrek madagascar minions oppenheimer barbie dune spiderman batman superman joker wicked sholay lagaan dangal drishyam kantara vikram leo master theri mersal bigil sarkar".split(separator: " ").map(String.init)
        for (i, w) in words.enumerated() where w.count >= 3 { v[w] = 1 + i % 5 }
        return v
    }()

    /// Whole-vocabulary scan: same rules as SpellingIndex.correct, with ties broken by the word so the answer is unique.
    static func reference(_ query: String, _ vocabulary: [String: Int]) -> String? {
        var changed = false
        let fixed = query.split(whereSeparator: \.isWhitespace).map { raw -> String in
            let w = raw.lowercased().filter { $0.isLetter || $0.isNumber }
            guard w.count >= 4, vocabulary[w] == nil else { return String(raw) }
            if vocabulary.keys.contains(where: { $0.hasPrefix(w) }) { return String(raw) }
            let fw = ArtworkMatchDecision.fold(w)
            let sameFold = vocabulary.filter { ArtworkMatchDecision.fold($0.key) == fw && $0.key != w }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            if let alt = sameFold.first { changed = true; return alt.key }
            let allowed = w.count <= 5 ? 1 : 2
            func pick(_ pool: [String], limit: Int) -> String? {
                var best: (word: String, d: Int, n: Int)?
                for cand in pool.sorted() {
                    let d = SpellingIndex.distance(w, cand, limit: limit), n = vocabulary[cand] ?? 0
                    guard d <= limit else { continue }
                    if best == nil || d < best!.d || (d == best!.d && n > best!.n) { best = (cand, d, n) }
                }
                return best?.word
            }
            var hit = pick(vocabulary.keys.filter { abs($0.count - w.count) <= allowed && $0.first == w.first }, limit: allowed)
            if hit == nil, w.count >= 5 {
                hit = pick(vocabulary.keys.filter { abs($0.count - w.count) <= 1 && $0.first != w.first && $0.dropFirst().prefix(3) == w.dropFirst().prefix(3) }, limit: 1)
            }
            guard let hit else { return String(raw) }
            changed = true
            return hit
        }
        return changed ? fixed.joined(separator: " ") : nil
    }

    @Test func sameAnswersAsTheScan() {
        let queries = ["avngers", "avengrs endgam", "intersteller", "bahubali", "baahubalee", "qvengers", "gladiater", "godfater", "parasit", "squid gme", "money hiest", "zzzzzz", "avenge", "matrx reloded", "oppenheimr", "kantaraa", "dhoomm", "pushpaa", "shreck", "frozn", "wicked", "the avengers", "superman", "supermen"]
        let ix = SpellingIndex.Index(Self.vocab)
        for q in queries { #expect(SpellingIndex.correct(q, vocabulary: Self.vocab, index: ix) == Self.reference(q, Self.vocab), Comment(rawValue: q)) }
    }

    @Test func realMisspellingsAreFixed() {
        let s = SpellingIndex(words: Self.vocab)
        #expect(s.correct("avngers") == "avengers")
        #expect(s.correct("qvengers") == "avengers")
        #expect(s.correct("avenge") == nil, "a word being typed is left alone")
        #expect(s.correct("bahubali") == "baahubali", "transliteration spelling")
    }
}
