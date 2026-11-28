import Foundation

/// Step 1 and the word-level helpers: lowercase, fold accents and curly quotes, expand contractions, strip filler, split into words, and a light English stemmer.
enum Normalise {
    private static let contractions: [(String, String)] = [
        ("won't", "will not"), ("can't", "can not"), ("cannot", "can not"), ("don't", "do not"), ("doesn't", "does not"), ("didn't", "did not"), ("isn't", "is not"), ("aren't", "are not"),
        ("what's", "what is"), ("where's", "where is"), ("how's", "how is"), ("it's", "it is"), ("that's", "that is"), ("there's", "there is"), ("i'm", "i am"), ("i'd", "i would"),
        ("i'll", "i will"), ("i've", "i have"), ("you're", "you are"), ("let's", "let us"), ("wasn't", "was not"), ("shouldn't", "should not"), ("couldn't", "could not"),
    ]

    /// Lowercased, folded, contractions expanded, punctuation turned to spaces, single-spaced. Intent rules read this.
    static func clean(_ raw: String) -> String {
        var s = raw.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
        s = s.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
        for (a, b) in contractions { s = s.replacingOccurrences(of: a, with: b) }
        s = String(s.map { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "⌘" ? $0 : " " })
        s = s.replacingOccurrences(of: "'", with: "")
        return s.split(separator: " ").joined(separator: " ")
    }

    static func words(_ raw: String) -> [String] { clean(raw).split(separator: " ").map(String.init) }

    /// Words that carry no topic. Dropped from retrieval, not from intent detection.
    static let stopWords: Set<String> = [
        "the", "a", "an", "to", "of", "in", "on", "off", "my", "me", "i", "it", "is", "are", "am", "do", "does", "did", "how", "what", "where", "can", "could", "would", "should", "will",
        "and", "or", "for", "with", "when", "why", "if", "this", "that", "there", "you", "your", "be", "we", "our", "at", "from", "by", "as", "please", "want", "need", "like", "tell",
        "show", "find", "get", "go", "turn", "set", "change", "make", "enable", "disable", "use", "see", "hey", "setu", "not", "so", "up", "then", "i", "some", "any", "about", "all",
        "which", "who", "has", "have", "was", "were", "just", "also", "into", "out", "way", "thing", "things", "option", "setting", "settings", "happens", "happen",
        // Hinglish and Telugu question and filler words: they carry the intent (see IntentDetector), not the topic.
        "kaise", "kese", "kaisay", "kaisey", "kahan", "kahaan", "kidhar", "kyun", "kyu", "kyon", "kya", "hai", "hain", "ho", "raha", "rahi", "rahe", "nahi", "nahin", "karna", "karu", "karun", "kare", "karein", "karo",
        "ela", "ekkada", "enduku", "endhuku", "cheyali", "cheyyali", "cheyyandi", "ledu", "enti", "idi", "naku", "naa", "ka", "ki", "ke", "ko", "se", "mein", "par", "mera", "meri", "mere", "dekhe", "dekhna", "dekhu", "batao", "bataiye", "kavali",
    ]

    /// Light suffix stripper. Applied to indexed text and queries alike, so it only has to be consistent.
    static func stem(_ w: String) -> String {
        guard w.count > 3, w.allSatisfy({ $0.isLetter }) else { return w }
        var s = w
        if s.hasSuffix("ies") && s.count > 4 { return String(s.dropLast(3)) + "y" }
        if s.hasSuffix("sses") { return String(s.dropLast(2)) }
        if s.hasSuffix("ing") && s.count > 5 { s = String(s.dropLast(3)); return undouble(s) }
        if s.hasSuffix("ed") && s.count > 4 { s = String(s.dropLast(2)); return undouble(s) }
        if s.hasSuffix("es") && s.count > 4 && (s.hasSuffix("ches") || s.hasSuffix("shes") || s.hasSuffix("xes") || s.hasSuffix("zes")) { return String(s.dropLast(2)) }
        if s.hasSuffix("s") && !s.hasSuffix("ss") && !s.hasSuffix("us") && !s.hasSuffix("is") { s = String(s.dropLast()) }
        if s.hasSuffix("e") && s.count > 4 { s = String(s.dropLast()) }
        return s
    }

    private static func undouble(_ s: String) -> String {
        let c = Array(s)
        if c.count > 2, c[c.count - 1] == c[c.count - 2], !"lsz".contains(c[c.count - 1]) { return String(c.dropLast()) }
        return s.hasSuffix("e") && s.count > 4 ? String(s.dropLast()) : s
    }
}
