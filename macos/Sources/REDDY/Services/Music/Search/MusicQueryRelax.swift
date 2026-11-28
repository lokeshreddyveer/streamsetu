import Foundation

/// A looser wording of a query for when the exact words find nothing: edition and format notes sources add to titles ("(Deluxe Edition)", "[Remastered]",
/// "- EP", "- Single") are dropped, because the source's own search often does not match them. Pure; nothing here names an artist, album or country.
enum MusicQueryRelax {
    private static let bracketed = try! NSRegularExpression(pattern: #"[\(\[][^\)\]]*[\)\]]"#)
    private static let trailing = try! NSRegularExpression(pattern: #"\s+[-–—]\s+(ep|single|deluxe( edition)?|remaster(ed)?( \d{4})?|expanded edition|bonus track version)\s*$"#, options: [.caseInsensitive])

    /// The looser wording, or nil when it would be the same words or nothing at all.
    static func relaxed(_ query: String) -> String? {
        var s = query
        for re in [bracketed, trailing] { s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ") }
        let words = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !words.isEmpty, MusicText.normalize(words) != MusicText.normalize(query) else { return nil }
        return words
    }
}
