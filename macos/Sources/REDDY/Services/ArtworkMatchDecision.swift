import Foundation

/// Engine v2: the pure decision that picks the TMDB result for a library title, or none. No network, no database: candidates in, an id (or nil) out.
/// The same rules are ported to the other platforms and checked against artwork/fixtures/match-decision.json.
enum ArtworkMatchDecision {
    struct Query: Sendable, Equatable {
        var title: String
        var year: Int?
        var isSeries: Bool
        /// The library's language for the title ("Telugu"), or empty.
        var languageTag: String = ""
    }
    struct Candidate: Sendable, Equatable {
        var id: Int
        var title: String?
        var originalTitle: String?
        var year: Int?
        var popularity: Double
        var originalLanguage: String?
    }

    static let minSimilarity = 0.88

    /// TMDB's language code for what the library calls a language.
    static let languageCodes: [String: String] = ["telugu": "te", "hindi": "hi", "tamil": "ta", "malayalam": "ml", "kannada": "kn", "bengali": "bn", "punjabi": "pa", "marathi": "mr", "gujarati": "gu", "urdu": "ur",
                                                  "turkish": "tr", "english": "en", "arabic": "ar", "korean": "ko", "japanese": "ja", "spanish": "es", "french": "fr", "german": "de", "chinese": "zh", "thai": "th",
                                                  "portuguese": "pt", "italian": "it", "russian": "ru", "indonesian": "id", "dutch": "nl", "polish": "pl", "persian": "fa", "hebrew": "he", "vietnamese": "vi", "odia": "or", "assamese": "as", "nepali": "ne", "sinhala": "si", "malay": "ms", "tagalog": "tl"]
    /// The library's language word for a TMDB original-language code (the inverse of `languageCodes`), for any language of the table.
    static func name(forCode code: String) -> String? { languageCodes.first { $0.value == code }?.key }
    static func code(for tag: String) -> String? { languageCodes[tag.lowercased()] }
    /// The region-qualified language to ask TMDB for ("te-IN") for an Indian language, else nil.
    static func searchLanguage(for tag: String) -> String? {
        guard let c = code(for: tag), ["te", "hi", "ta", "ml", "kn", "bn", "pa", "mr", "gu", "ur"].contains(c) else { return nil }
        return c + "-IN"
    }

    // MARK: text

    private static let romans: [String: String] = ["ii": "2", "iii": "3", "iv": "4", "vi": "6", "vii": "7", "viii": "8", "ix": "9"]
    private static let numberWords: [String: String] = ["one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10"]

    /// Lower case, no accents, "&" as "and", no apostrophes, no punctuation, no leading article, roman numerals and "Part N" as digits.
    static func canon(_ s: String) -> String {
        var t = s.precomposedStringWithCompatibilityMapping.lowercased()
            .replacingOccurrences(of: "&", with: " and ").replacingOccurrences(of: "+", with: " plus ")
            .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
            .replacingOccurrences(of: "\u{0131}", with: "i")       // Turkish dotless i: "AŞK-I" and "Aşk-ı" are one name
        t = t.folding(options: [.diacriticInsensitive], locale: nil)
        var tokens = t.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        if let f = tokens.first, ["the", "a", "an"].contains(f), tokens.count > 1 { tokens.removeFirst() }
        var out: [String] = []
        for (i, tok) in tokens.enumerated() {
            if ["part", "chapter", "vol", "volume", "episode"].contains(tok), i + 1 < tokens.count, isNumberLike(tokens[i + 1]) { continue }
            if i > 0, let d = romans[tok] { out.append(d); continue }
            if i > 0, i == tokens.count - 1, tok == "v" || tok == "x" || tok == "i" { out.append(tok == "v" ? "5" : tok == "x" ? "10" : "1"); continue }
            if i > 0, i > 0, let prev = out.last, ["part", "chapter"].contains(prev), let d = numberWords[tok] { out.append(d); continue }
            out.append(tok)
        }
        return out.joined(separator: " ")
    }
    private static func isNumberLike(_ t: String) -> Bool { Int(t) != nil || romans[t] != nil || numberWords[t] != nil || ["v", "x", "i"].contains(t) }

    /// Spellings that differ only by transliteration are folded together (aa/a, ee/i, w/v, th/t, ph/f, double letters ...).
    static func fold(_ canon: String) -> String {
        var s = canon
        for (a, b) in [("sh", "s"), ("ph", "f"), ("th", "t"), ("dh", "d"), ("bh", "b"), ("kh", "k"), ("gh", "g"), ("ch", "c"), ("aa", "a"), ("ee", "i"), ("oo", "u"), ("ii", "i"), ("uu", "u"), ("ou", "u"), ("ae", "e"), ("ai", "e"), ("ay", "e"), ("ey", "e"), ("w", "v"), ("z", "j"), ("q", "k"), ("x", "ks")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        var out = "", last: Character?
        for ch in s { if ch == last, ch.isLetter { continue }; out.append(ch); last = ch }
        return out
    }

    /// The consonant skeleton of the whole name (first letter kept): "Dulhaniya Le Aaeegi" and "Dulhania Le Aayegi" share one.
    static func skeleton(_ canon: String) -> String {
        var out = "", prev: Character?
        for tok in canon.split(separator: " ") {
            for ch in fold(String(tok)) {
                guard ch.isLetter || ch.isNumber else { continue }
                let vowel = "aeiouyh".contains(ch)
                if !vowel { if ch != prev { out.append(ch) }; prev = ch } else { prev = nil }
            }
        }
        return out
    }

    // MARK: similarity

    static func levenshteinRatio(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        if x == y { return 1 }
        if x.isEmpty || y.isEmpty { return 0 }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)) }
            prev = cur
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    static func jaroWinkler(_ a: String, _ b: String) -> Double {
        let s = Array(a), t = Array(b)
        if s.isEmpty || t.isEmpty { return 0 }
        if s == t { return 1 }
        let window = max(0, max(s.count, t.count) / 2 - 1)
        var sm = [Bool](repeating: false, count: s.count), tm = [Bool](repeating: false, count: t.count)
        var matches = 0
        for i in 0..<s.count {
            let lo = max(0, i - window), hi = min(t.count - 1, i + window)
            if lo > hi { continue }
            for j in lo...hi where !tm[j] && s[i] == t[j] { sm[i] = true; tm[j] = true; matches += 1; break }
        }
        if matches == 0 { return 0 }
        var k = 0, trans = 0
        for i in 0..<s.count where sm[i] { while !tm[k] { k += 1 }; if s[i] != t[k] { trans += 1 }; k += 1 }
        let m = Double(matches)
        let jaro = (m / Double(s.count) + m / Double(t.count) + (m - Double(trans) / 2) / m) / 3
        var l = 0
        while l < min(4, min(s.count, t.count)), s[l] == t[l] { l += 1 }
        return jaro + Double(l) * 0.1 * (1 - jaro)
    }

    /// Words in any order: the sorted words are compared, so "Le Dulhania" and "Dulhania Le" agree.
    static func tokenSetRatio(_ a: String, _ b: String) -> Double {
        let x = a.split(separator: " ").sorted().joined(separator: " "), y = b.split(separator: " ").sorted().joined(separator: " ")
        return levenshteinRatio(x, y)
    }

    /// How alike two names are, 0...1, over the plain, the transliteration-folded and the space-free forms.
    static func similarity(_ a: String, _ b: String) -> Double {
        let ca = canon(a), cb = canon(b)
        if ca.isEmpty || cb.isEmpty { return 0 }
        if ca == cb { return 1 }
        let fa = fold(ca), fb = fold(cb)
        if fa == fb { return 0.98 }
        let nsa = fa.replacingOccurrences(of: " ", with: ""), nsb = fb.replacingOccurrences(of: " ", with: "")
        var best = max(levenshteinRatio(ca, cb), tokenSetRatio(ca, cb) * 0.99, levenshteinRatio(fa, fb) * 0.99, tokenSetRatio(fa, fb) * 0.98, levenshteinRatio(nsa, nsb) * 0.97)
        if nsa.count >= 8 { best = max(best, jaroWinkler(nsa, nsb) >= 0.96 ? 0.9 : 0) }
        // A different number is a different film ("Dhoom" and "Dhoom 2", "Film 19" and "Film"): never close enough.
        let da = Set(ca.split(separator: " ").filter { $0.allSatisfy(\.isNumber) }), db = Set(cb.split(separator: " ").filter { $0.allSatisfy(\.isNumber) })
        if da != db { best = min(best, 0.8) }
        return best
    }

    /// The name before a subtitle (": ", " - ", " | "), when there is one.
    static func head(_ s: String) -> String? {
        for sep in [": ", " - ", " | ", " – "] { if let r = s.range(of: sep) { let h = String(s[..<r.lowerBound]); if h.count >= 2 { return h } } }
        return nil
    }

    struct Score { var sim: Double; var phonetic: Bool; var viaHead: Bool }

    /// The best similarity of a library name to a candidate's names (title and original title), also trying the name without its subtitle on either side (a little less sure).
    static func score(_ libraryText: String, _ c: Candidate) -> Score {
        var best = Score(sim: 0, phonetic: false, viaHead: false)
        let libs = [libraryText] + (head(libraryText).map { [$0] } ?? [])
        let libSkeleton = skeleton(canon(libraryText))
        for name in [c.title, c.originalTitle].compactMap({ $0 }) where !name.isEmpty {
            let names = [name] + (head(name).map { [$0] } ?? [])
            for (li, l) in libs.enumerated() {
                for (ni, n) in names.enumerated() {
                    var s = similarity(l, n)
                    let isHead = li > 0 || ni > 0
                    if isHead { s *= 0.95 }
                    if s > best.sim { best = Score(sim: s, phonetic: false, viaHead: isHead) }
                }
            }
            let sk = skeleton(canon(name))
            if sk.count >= 4, sk == libSkeleton, best.sim < 0.9 { best = Score(sim: 0.9, phonetic: true, viaHead: false) }
        }
        return best
    }

    // MARK: decision

    /// Owner policy: the match is decided by the NAME only. No year, language, runtime or popularity is read. A candidate whose title, original title (or the part of either before a subtitle) equals the cleaned name token for token wins; the first such one in the candidates' own (relevance) order. Failing an exact name, the existing name-similarity tiers (transliteration fold, consonant skeleton, subtitle head, near-exact spelling >= 0.88) are tried and the best-scoring name wins, ties again by result order. A name that does not match is never accepted.
    /// `Query.year` and `Query.languageTag` are kept only so callers and the wire shape do not change; they are not read here.
    static func decide(_ q: Query, _ candidates: [Candidate], text: String? = nil) -> Int? {
        let lib = text ?? ArtworkNameCleaner.clean(q.title, year: q.year)
        guard !lib.isEmpty else { return nil }
        let libCanon = canon(lib)
        var best: (id: Int, sim: Double)?
        for c in candidates {
            let s = score(lib, c)
            guard s.sim >= minSimilarity else { continue }
            let exact = !s.phonetic && !s.viaHead && [c.title, c.originalTitle].contains { $0.map { canon($0) == libCanon } ?? false }
            let sim = exact ? 2 : s.sim          // an exact name outranks every close one
            if exact { return c.id }
            if best == nil || sim > best!.sim { best = (c.id, sim) }
        }
        return best?.id
    }
}
