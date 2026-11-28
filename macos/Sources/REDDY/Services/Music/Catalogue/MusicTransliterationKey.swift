import Foundation

/// Indian-language words have no standard Latin spelling: "Zinda" and "Jinda", "Guzarish" and "Gujarish", "Dakko" and "Daakko" are the same word.
/// This folds the ambiguous letter sequences into ONE key so different spellings meet, and offers a few alternate spellings to ask a search box.
/// The key is a hint, never proof: two unrelated words can share one (kala / gala differ, but others will not), so callers use it to build
/// queries and to score, and always need the artist and the running time to agree as well.
enum MusicTransliterationKey {
    /// Ordered rewrite rules applied to lower case Latin text. Data, so a new edge case is one more line and one more test.
    /// Each pair is (sequence, replacement); the order matters (longer sequences first).
    static let rules: [(String, String)] = [
        ("chh", "C"), ("ch", "C"), ("sh", "s"), ("kh", "k"), ("gh", "g"), ("jh", "j"), ("th", "t"), ("dh", "d"), ("bh", "b"), ("ph", "p"),
        ("ck", "k"), ("c", "k"), ("C", "c"),
        ("aa", "a"), ("ee", "i"), ("ii", "i"), ("oo", "u"), ("uu", "u"), ("ai", "e"), ("ei", "e"), ("ay", "e"), ("ey", "e"), ("au", "o"), ("ou", "o"), ("ow", "o"),
        ("w", "v"), ("z", "j"), ("q", "k"), ("f", "p"), ("x", "ks")
    ]

    /// The key of one word. Empty for text with no letters.
    static func key(word: String) -> String {
        var t = MusicText.normalize(MusicCandidateRules.latin(word)).replacingOccurrences(of: " ", with: "")
        guard !t.isEmpty else { return "" }
        for (a, b) in rules { t = t.replacingOccurrences(of: a, with: b) }
        var out = ""
        for ch in t where out.last != ch || !ch.isLetter { out.append(ch) }
        // A trailing "h" or a trailing short "a" is often written and often dropped.
        if out.count >= 3, out.hasSuffix("h") { out.removeLast() }
        if out.count >= 4, out.hasSuffix("a") { out.removeLast() }
        return out
    }

    /// The key of a phrase: one key per word, spaces kept.
    static func key(_ text: String) -> String {
        MusicText.normalize(MusicCandidateRules.latin(text)).split(separator: " ").map { key(word: String($0)) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func sameKey(_ a: String, _ b: String) -> Bool {
        let x = key(a), y = key(b)
        return !x.isEmpty && x == y
    }

    /// 1 for the same text once accents, case and punctuation are ignored; 0.9 for the same key (spelled differently); below that, character-pair
    /// similarity of the keys scaled down, so an exact match always outranks a phonetic one.
    static func similarity(_ a: String, _ b: String) -> Float {
        let na = MusicText.normalize(MusicCandidateRules.latin(a)), nb = MusicText.normalize(MusicCandidateRules.latin(b))
        guard !na.isEmpty, !nb.isEmpty else { return 0 }
        if na == nb { return 1 }
        let ka = key(a), kb = key(b)
        if !ka.isEmpty, ka == kb { return 0.9 }
        let s = MusicTextMatch.similarity(ka.split(separator: " ").map(String.init), kb.split(separator: " ").map(String.init))
        return min(0.85, s * 0.85)
    }

    /// True when the similarity is a phonetic one rather than an exact one.
    static func isPhoneticOnly(_ a: String, _ b: String) -> Bool { similarity(a, b) < 1 }

    // MARK: alternate spellings to ask with

    /// Other likely spellings of a title, at most `limit`, never the title itself. Order: the longer first vowel (how film sites write it),
    /// the shortened form (long vowels and doubled letters collapsed), then the z/j and w/v swaps.
    static func alternates(of title: String, limit: Int = 2) -> [String] {
        guard limit > 0, title.unicodeScalars.allSatisfy({ $0.isASCII }) else { return [] }
        var out: [String] = []
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t.caseInsensitiveCompare(title) != .orderedSame, !out.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { return }
            out.append(t)
        }
        if let long = lengthenFirstA(title) { add(long) }
        add(shorten(title))
        add(swap(title, ["z": "j", "Z": "J"], reverse: ["j": "z", "J": "Z"]))
        add(swap(title, ["w": "v", "W": "V"], reverse: ["v": "w", "V": "W"]))
        return Array(out.prefix(limit))
    }

    /// "Dakko" -> "Daakko": the first "a" of each word of four letters or more gets a second one.
    static func lengthenFirstA(_ title: String) -> String? {
        let words = title.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        var changed = false
        let out = words.map { w -> String in
            let chars = Array(w)
            guard let i = chars.firstIndex(where: { "aeiouAEIOU".contains($0) }), chars[i].lowercased() == "a" else { return w }
            if i + 1 < chars.count, "aeiouAEIOU".contains(chars[i + 1]) { return w }
            guard w.count >= 4 else { return w }
            changed = true
            var c = chars
            c.insert(chars[i], at: i + 1)
            return String(c)
        }
        return changed ? out.joined(separator: " ") : nil
    }

    private static func shorten(_ title: String) -> String {
        var t = title
        for (a, b) in [("aa", "a"), ("Aa", "A"), ("ee", "i"), ("oo", "u"), ("kk", "k"), ("tt", "t"), ("pp", "p"), ("dd", "d"), ("ll", "l"), ("nn", "n"), ("mm", "m"), ("ss", "s")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }

    private static func swap(_ title: String, _ forward: [Character: Character], reverse: [Character: Character]) -> String {
        let hasForward = title.contains { forward[$0] != nil }
        let map = hasForward ? forward : reverse
        return String(title.map { map[$0] ?? $0 })
    }
}
