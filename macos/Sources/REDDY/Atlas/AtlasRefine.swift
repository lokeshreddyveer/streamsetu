import Foundation

/// A correction laid over an entry that already exists (declared in another file or imported from the older catalogue). It replaces only the fields it names and adds aliases. Used to fix stale or thin
/// text and wrong paths without rewriting the file the entry lives in; a test checks every refinement points at a real entry.
struct AtlasRefinement: Sendable {
    var title: String?
    var summary: String?
    var detail: String?
    var path: [String]?
    var aliases: [String] = []
    var reach: AtlasReach?
    var platforms: AtlasPlatforms?
    var related: [String] = []
    var shortcut: String?
    var safety: AtlasSafety?

    func apply(to e: inout AtlasEntry) {
        if let title { e.title = title }
        if let summary { e.summary = summary }
        if let detail { e.detail = detail }
        if let path { e.path = path }
        if let reach { e.reach = reach }
        if let platforms { e.platforms = platforms }
        if let shortcut { e.shortcut = shortcut }
        if let safety { e.safety = safety }
        for a in aliases where !e.aliases.contains(a) { e.aliases.append(a) }
        for r in related where !e.related.contains(r) && r != e.id { e.related.append(r) }
        e.reviewed = true
    }
}

enum AtlasRefine {
    /// Entry id to its correction. App-wide corrections first, then Music.
    static let table: [String: AtlasRefinement] = AppRefinements.table.merging(MusicRefinements.table) { a, _ in a }

    /// Short builder so the tables read as data.
    static func r(title: String? = nil, _ summary: String? = nil, detail: String? = nil, path: [String]? = nil, aliases: [String] = [], reach: AtlasReach? = nil, platforms: AtlasPlatforms? = nil,
                  related: [String] = [], shortcut: String? = nil, safety: AtlasSafety? = nil) -> AtlasRefinement {
        AtlasRefinement(title: title, summary: summary, detail: detail, path: path, aliases: aliases, reach: reach, platforms: platforms, related: related, shortcut: shortcut, safety: safety)
    }
}
