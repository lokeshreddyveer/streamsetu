import Foundation

/// Name folding for the graph: one function turns any script or spelling into a Latin skeleton, so "आवारा", "ఆవారా", "Awaara" and "Avara" meet.
/// Used for the `name_latin` column, the FTS index and every query. Pure; no UI, no app types.
enum MusicGraphText {
    /// Ordered rewrite rules for Latin text (longer sequences first). The same spellings the app's transliteration key folds.
    private static let rules: [(String, String)] = [
        ("chh", "c"), ("ch", "c"), ("sh", "s"), ("kh", "k"), ("gh", "g"), ("jh", "j"), ("th", "t"), ("dh", "d"), ("bh", "b"), ("ph", "p"),
        ("ck", "k"), ("aa", "a"), ("ee", "i"), ("ii", "i"), ("oo", "u"), ("uu", "u"), ("ai", "e"), ("ei", "e"), ("ay", "e"), ("ey", "e"),
        ("au", "o"), ("ou", "o"), ("ow", "o"), ("w", "v"), ("z", "j"), ("q", "k"), ("f", "p"), ("x", "ks"), ("c", "k"),
    ]

    /// Lower case, accents and width folded, punctuation to single spaces. Keeps every script's letters.
    static func fold(_ text: String) -> String {
        let t = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out = ""; var space = true
        for ch in t.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) || CharacterSet.nonBaseCharacters.contains(ch) { out.unicodeScalars.append(ch); space = false }
            else if !space { out.append(" "); space = true }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    /// The Latin skeleton: transliterated to Latin, folded, then the ambiguous letter sequences collapsed per word. Empty for text with no letters.
    private static let latinMemo = MusicBoundedMemo<String, String>(capacity: 8_192)

    static func latin(_ text: String) -> String { latinMemo.value(for: text) { computeLatin(text) } }

    private static func computeLatin(_ text: String) -> String {
        // Text that is already plain ASCII has nothing to transliterate: the ICU transform (the slow part) is skipped for it.
        let romanised = text.utf8.allSatisfy { $0 < 0x80 } ? text : (text.applyingTransform(.toLatin, reverse: false) ?? text)
        return fold(romanised).split(separator: " ").map { word -> String in
            var t = String(word)
            for (a, b) in rules { t = t.replacingOccurrences(of: a, with: b) }
            var out = ""
            for ch in t where out.last != ch || !ch.isLetter { out.append(ch) }
            return out
        }.joined(separator: " ")
    }

    /// Words of a query for the index: letters and digits of any script.
    static func tokens(_ text: String) -> [String] { fold(text).split(separator: " ").map(String.init) }

    /// The FTS5 match expression for a user query: original-script words against name and aliases, or the folded words against the Latin column.
    /// Every word is a prefix match. Nil when the query has no usable word.
    static func ftsExpression(_ query: String) -> String? {
        let raw = tokens(query), lat = tokens(latin(query))
        func group(_ ws: [String]) -> String { ws.map { "\"\($0)\"*" }.joined(separator: " AND ") }
        var parts: [String] = []
        if !raw.isEmpty { parts.append("{name aliases} : (\(group(raw)))") }
        if !lat.isEmpty { parts.append("{latin} : (\(group(lat)))") }
        return parts.isEmpty ? nil : parts.joined(separator: " OR ")
    }
}
