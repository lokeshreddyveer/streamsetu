import Foundation

/// One row in the search results' "Actions and screens" section.
struct AtlasPaletteRow: Identifiable, Equatable, Sendable {
    let id: String                  // the Atlas entry id
    let title: String
    let breadcrumb: String
    let shortcut: String?
    let kind: AtlasKind
    let symbol: String
    /// The entry has a route the app can open (a tab, a settings page, a window, a modal).
    let canOpen: Bool
}

/// What the top search (Mac) and the Search tab (iPhone, iPad) show from the Atlas. The views only call this; the ranking is the engine's, in list mode.
enum AtlasPaletteSource {
    /// Kinds that make sense as a row: somewhere to go, a key to press, a how-to.
    static let listedKinds: Set<AtlasKind> = [.screen, .settingsPage, .setting, .menuItem, .shortcut, .recipe, .contextAction, .gesture]

    /// A row needs at least this share of the best possible word-match score, or it is noise ("inception" must not offer a settings page).
    static let minimumConfidence = 0.34

    static func rows(for query: String, engine: SetuEngine, platform: AtlasPlatforms, appStore: Bool = false, limit: Int = 5) -> [AtlasPaletteRow] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        let r = engine.retrieve(q, platform: platform, appStore: appStore, limit: 25)
        guard r.confidence >= minimumConfidence else { return [] }
        let words = Normalise.words(q).filter { !Normalise.stopWords.contains($0) }
        var out: [AtlasPaletteRow] = []
        for h in r.hits where h.bm25Rank != nil && listedKinds.contains(h.entry.kind) && covers(h.entry, words: words) {
            out.append(row(h.entry))
            if out.count >= limit { break }
        }
        return out
    }

    /// The engine is forgiving (spelling, synonyms) because Setu answers questions; a list of rows must not be: "star wars" is a title, not a request for Favorites. Most of the typed words, as typed, must appear in the entry's own words
    /// (title, aliases, where it is, summary), with one typo allowed in a long word.
    static func covers(_ e: AtlasEntry, words: [String]) -> Bool {
        guard !words.isEmpty else { return false }
        let own = Set(Normalise.words(([e.title, e.summary] + e.aliases + e.path).joined(separator: " ")).map(Normalise.stem))
        let hit = words.filter { w in
            let st = Normalise.stem(w)
            if own.contains(st) { return true }
            return w.count >= 6 && own.contains { $0.count >= 5 && abs($0.count - st.count) <= 1 && withinOneEdit($0, st) }
        }.count
        return hit * 3 >= words.count * 2
    }

    static func withinOneEdit(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        if x == y { return true }
        if abs(x.count - y.count) > 1 { return false }
        var i = 0
        while i < min(x.count, y.count), x[i] == y[i] { i += 1 }
        if x.count == y.count { return Array(x[(i + 1)...]) == Array(y[(i + 1)...]) }
        let (long, short) = x.count > y.count ? (x, y) : (y, x)
        return Array(long[(i + 1)...]) == Array(short[i...])
    }

    static func row(_ e: AtlasEntry) -> AtlasPaletteRow {
        AtlasPaletteRow(id: e.id, title: e.title, breadcrumb: e.path.joined(separator: " > "), shortcut: e.shortcut, kind: e.kind, symbol: symbol(e.kind), canOpen: e.reach != .none)
    }

    static func symbol(_ k: AtlasKind) -> String {
        switch k {
        case .screen: "rectangle.on.rectangle"
        case .settingsPage: "gearshape"
        case .setting, .control: "switch.2"
        case .menuItem: "filemenu.and.selection"
        case .shortcut: "command"
        case .recipe: "list.number"
        case .contextAction, .gesture: "hand.tap"
        default: "questionmark.circle"
        }
    }

    private static let questionWords: Set<String> = ["how", "why", "what", "where", "when", "which", "can", "does", "do", "is", "are", "should", "will", "could", "who"]

    /// Whether the typed text reads as a question for Setu rather than a title to find: a question word first, a question mark, or four words or more that start with a question word or "my".
    static func isQuestion(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return false }
        if t.hasSuffix("?") { return true }
        let words = t.split(separator: " ").map(String.init)
        if let first = words.first, questionWords.contains(first), words.count >= 2 { return true }
        if words.count >= 4, words.first == "my" || words.first == "i" { return true }
        return false
    }

    static func askTitle(_ query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? "Ask Setu" : "Ask Setu: \(q)"
    }
}
