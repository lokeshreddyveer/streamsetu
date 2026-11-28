import Foundation

/// The other names and dubbed languages the film's About tab lists, worked out from what the graph holds. Pure, so a test can hold the rows. No source's name or
/// identifier is listed: Music's pages never name where a fact came from.
enum MusicFilmIdentifiers {
    /// The film's other names, each once, none repeating the title: "Title (Telugu)" when the source named the language.
    static func otherNames(_ aliases: [NameAlias], title: String, limit: Int = 8) -> String? {
        var seen = Set<String>([MusicGraphText.latin(title), title.lowercased()])
        var parts: [String] = []
        for a in aliases {
            let t = a.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted, seen.insert(MusicGraphText.latin(t)).inserted else { continue }
            let lang = a.lang.map { MusicFilmLanguageNames.name(for: $0) }.flatMap { $0.isEmpty ? nil : $0 }
            parts.append(lang.map { "\(t) (\($0))" } ?? t)
            if parts.count == limit { break }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The languages the film's dubbed soundtrack editions are in, each once, in the order the editions come.
    static func dubbedLanguages(_ dubLanguages: [String?]) -> String? {
        var seen = Set<String>(); var names: [String] = []
        for l in dubLanguages.compactMap({ $0 }) where seen.insert(l).inserted {
            let n = MusicFilmLanguageNames.name(for: l)
            if !n.isEmpty { names.append(n) }
        }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    /// All the extra About rows in page order: other names, dubbed languages.
    static func rows(aliases: [NameAlias], title: String, dubLanguages: [String?]) -> [(String, String)] {
        var out: [(String, String)] = []
        if let n = otherNames(aliases, title: title) { out.append((Localized.string("Also known as"), n)) }
        if let d = dubbedLanguages(dubLanguages) { out.append((Localized.string("Dubbed in"), d)) }
        return out
    }
}
