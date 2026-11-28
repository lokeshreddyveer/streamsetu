import Foundation

/// How Music compares and searches text: accents, case, width, apostrophes and punctuation do not matter, "&" reads as "and", and every script keeps
/// its letters. Matching, importing and the local library all use this one function, so the same title always folds to the same words.
enum MusicText {
    static func normalize(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for u in s.decomposedStringWithCompatibilityMapping.unicodeScalars {
            switch u.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: continue
            default: break
            }
            if u == "'" || u == "\u{2019}" || u == "\u{2018}" || u == "`" { continue }
            if u == "&" { out += " and "; continue }
            if CharacterSet.alphanumerics.contains(u) { out += String(u).lowercased() } else { out += " " }
        }
        return out.split(separator: " ").joined(separator: " ")
    }
}
