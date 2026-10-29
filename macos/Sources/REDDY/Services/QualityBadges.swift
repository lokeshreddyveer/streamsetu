import Foundation

/// What a title's own text says about its picture and sound: "…[4K HDR] Dolby Atmos 5.1" gives 4K, HDR, Atmos and 5.1. It reads only the words the playlist put in
/// the title or the folder name, so a title with no such words shows nothing rather than a guess.
enum QualityBadges {
    private static let rules: [(label: String, pattern: String)] = [
        ("4K", #"\b(4k|uhd|2160p)\b"#),
        ("1080p", #"\b(fhd|1080p|1080i)\b"#),
        ("720p", #"\b720p\b"#),
        ("HDR10+", #"hdr10\s?(\+|plus)"#),
        ("HDR", #"\bhdr(10)?\b(?!\s?(\+|plus))"#),
        ("Dolby Vision", #"dolby[\s._-]?vision|\bdovi\b|\bdv\b"#),
        ("Atmos", #"\batmos\b"#),
        ("7.1", #"(?<![0-9])7\.1(?![0-9])"#),
        ("5.1", #"(?<![0-9])5\.1(?![0-9])"#),
    ]

    /// The same rules, compiled once instead of on every title (this runs for every title shown and every title imported).
    private static let compiled: [(label: String, regex: NSRegularExpression)] = rules.map { ($0.label, try! NSRegularExpression(pattern: $0.pattern)) }

    /// The badges for the given pieces of text, in a fixed order (picture, then sound), at most [limit].
    static func from(_ texts: [String?], limit: Int = 4) -> [String] {
        let text = texts.compactMap { $0 }.joined(separator: " ").lowercased()
        guard !text.isEmpty else { return [] }
        var out: [String] = []
        let whole = NSRange(text.startIndex..., in: text)
        for (label, regex) in compiled where !(label == "720p" && out.contains("4K") || label == "720p" && out.contains("1080p") || label == "1080p" && out.contains("4K")) {
            if regex.firstMatch(in: text, range: whole) != nil { out.append(label) }
        }
        return Array(out.prefix(limit))
    }
}
