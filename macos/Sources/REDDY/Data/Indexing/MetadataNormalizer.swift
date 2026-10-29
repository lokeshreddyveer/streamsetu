import Foundation

/// Conservative normalization for search and grouping. Display text is only cleaned, never rewritten.
enum MetadataNormalizer {
    static let qualityTokens: Set<String> = ["hd", "fhd", "uhd", "4k", "sd", "hevc", "h265", "h264", "1080p", "720p", "2160p", "50fps", "60fps"]

    /// "Café  Zürich+ HD" -> "cafe zurich plus hd"
    static func normalize(_ s: String) -> String {
        let folded = s.replacingOccurrences(of: "+", with: " plus ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Trims, collapses whitespace and strips control characters.
    static func cleanDisplay(_ s: String) -> String {
        let noControl = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        return noControl.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Normalized name with quality markers removed ("sky sports hd" -> "sky sports").
    static func baseName(_ normalized: String) -> String {
        normalized.split(separator: " ").filter { !qualityTokens.contains(String($0)) }.joined(separator: " ")
    }

    static func qualityLabel(_ normalized: String) -> String? {
        let t = Set(normalized.split(separator: " ").map(String.init))
        if t.contains("4k") || t.contains("uhd") || t.contains("2160p") { return "4K" }
        if t.contains("fhd") || t.contains("1080p") { return "FHD" }
        if t.contains("hd") || t.contains("720p") { return "HD" }
        if t.contains("sd") { return "SD" }
        return nil
    }

    static func qualityRank(_ label: String?) -> Int {
        switch label { case "4K": 4; case "FHD": 3; case "HD": 2; case nil: 1; default: 0 }
    }

    /// Compiled once: this runs for every title of a catalog being imported.
    private static let yearPattern = try! NSRegularExpression(pattern: #"[\(\[]((?:19|20)\d{2})[\)\]]"#)

    /// "Movie Title (2019)" -> 2019
    static func year(from title: String) -> Int? {
        guard let m = yearPattern.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let range = Range(m.range(at: 1), in: title) else { return nil }
        return Int(title[range])
    }

    /// Placeholder rows like "######## Bulgaria Channels ########" are section headers, not channels.
    static func isSeparator(_ name: String) -> Bool {
        let t = name.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }
        let decorative = CharacterSet(charactersIn: "#=*-_~|•·.")
        let letters = t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        let marks = t.unicodeScalars.filter { decorative.contains($0) }.count
        return marks >= 4 && (t.hasPrefix("###") || t.hasPrefix("===") || t.hasPrefix("***") || t.hasPrefix("---") || marks > letters)
    }
}

enum CategoryNormalizer {
    /// Strips decorative separators ("|| NEWS ||" -> "NEWS") while keeping the provider's wording.
    static func clean(_ name: String) -> String {
        let trimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "|:-–—#*_~•"))
        let c = MetadataNormalizer.cleanDisplay(name).trimmingCharacters(in: trimSet)
        return c.isEmpty ? "Uncategorized" : c
    }

    private static let countryPattern = try! NSRegularExpression(pattern: #"^\s*([A-Z]{2})\s*[:|\-]"#)

    /// Two-letter uppercase prefix such as "BG:", "DK |", "UK -" -> country code. Nothing else is guessed.
    static func countryPrefix(_ name: String) -> String? {
        guard let m = countryPattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(m.range(at: 1), in: name) else { return nil }
        return String(name[range])
    }
}
