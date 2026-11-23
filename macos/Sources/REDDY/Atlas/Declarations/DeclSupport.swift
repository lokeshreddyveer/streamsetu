import Foundation

extension AtlasEntry {
    /// The one way declarations are written: id, kind, title, summary and breadcrumb are required; the rest has a plain default. `reviewed` stays false unless the text was checked against the code.
    static func make(_ id: String, _ kind: AtlasKind, _ title: String, _ summary: String, path: [String], reach: AtlasReach = .none, aliases: [String] = [], detail: String? = nil,
                     platforms: AtlasPlatforms = .all, shortcut: String? = nil, anchor: String? = nil, related: [String] = [], recipe: [AtlasStep]? = nil, safety: AtlasSafety = .read,
                     guideOnly: Bool = false, since: String? = nil, reviewed: Bool = false, value: AtlasValueReader? = nil) -> AtlasEntry {
        AtlasEntry(id: id, kind: kind, title: title, aliases: aliases, summary: summary, detail: detail, path: path, reach: reach, value: value, platforms: platforms, shortcut: shortcut,
                   anchor: anchor, related: related, recipe: recipe, safety: safety, guideOnly: guideOnly, since: since, reviewed: reviewed)
    }
}

/// Extra words and fixes for an entry that already exists in the typed catalogue (`AppSettingsCatalog`). The catalogue owns the value reader and the write; the note adds what Setu needs to find and explain it.
struct AtlasSettingNote: Sendable {
    var aliases: [String] = []
    /// Replaces the first sentence of the catalogue text when set.
    var summary: String?
    var detail: String?
    var related: [String] = []
    var platforms: AtlasPlatforms?
    var reviewed = false
}
