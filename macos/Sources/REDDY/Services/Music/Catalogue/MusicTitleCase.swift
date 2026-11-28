import Foundation

/// Repairs the one casing slip that title-casing makes in English text: the letter after an apostrophe is capitalised ("He'S", "Don'T", "I'M"), which turns a
/// contraction or a possessive into a typo. Only words that already carry a lowercase letter are touched, so an all-capitals title ("DON'T STOP") stays as written.
/// Pure and language-neutral: it looks at the apostrophe and the letters around it, never at a word list.
enum MusicTitleCase {
    private static let slip = try! NSRegularExpression(pattern: #"(\p{L}*\p{Ll}\p{L}*|I)(['’])(\p{Lu})(?=$|[^\p{L}])"#)

    static func repair(_ text: String) -> String {
        guard text.contains("'") || text.contains("’") else { return text }
        let ns = text as NSString
        var out = text
        // From the end, so earlier ranges stay valid.
        // A lone capital I ("I'M") counts as a word with a lowercase letter only when the title has lowercase letters elsewhere: an all-capitals title stays as written.
        let hasLower = text.contains { $0.isLowercase }
        for m in slip.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            if ns.substring(with: m.range(at: 1)) == "I", !hasLower { continue }
            let letter = m.range(at: 3)
            guard let r = Range(letter, in: out) else { continue }
            out.replaceSubrange(r, with: out[r].lowercased())
        }
        return out
    }

    /// A name made of words, each capitalised, with the apostrophe slip repaired ("rock 'n' roll" is left to the caller's own rules).
    static func capitalized(_ text: String) -> String { repair(text.capitalized) }

    /// A record's title as the page heads it: the casing slip repaired, and a trailing " - EP" / " - Single" taken off when the page already says so in its label.
    static func recordTitle(_ name: String, subkind: String?) -> String {
        var t = repair(name)
        if subkind == MusicAlbumSubkind.ep.rawValue || subkind == MusicAlbumSubkind.single.rawValue {
            for tail in [" - EP", " – EP", " - Single", " – Single"] where t.hasSuffix(tail) && t.count > tail.count { t.removeLast(tail.count); break }
        }
        return t
    }
}
