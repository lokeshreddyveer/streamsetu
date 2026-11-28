import Foundation

/// Whether a string can be a person's name. A page parser sometimes takes a wiki template word ("Infobox", "Plainlist") or markup for a name; such a row
/// must never reach a screen. The graph store answers "not found" for a person row that fails this, so every page (credits, cast, songs, search) skips it
/// without each one having to remember.
enum MusicPersonNameGuard {
    private static let notNames: Set<String> = ["infobox", "plainlist", "unbulleted list", "ubl", "hlist", "flatlist", "cite web", "cite news", "n/a", "tba", "tbd", "unknown", "none"]

    static func isPersonName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard n.count >= 2, n.contains(where: \.isLetter) else { return false }
        if notNames.contains(n.lowercased()) { return false }
        return !n.contains("{{") && !n.contains("}}") && !n.contains("|") && !n.contains("=") && !n.lowercased().hasPrefix("infobox ")
    }

    /// A snapshot a page may show: anything that is not a person, or a person with a real name.
    static func isShowable(kind: MusicEntityKind, name: String) -> Bool { kind != .person || isPersonName(name) }
}
