import Foundation

/// One row of a contextual sidebar, as the sidebar component sees it.
struct SidebarEntry: Identifiable, Hashable, Sendable {
    let id: String
    let selection: SidebarSelection
    let title: String
    let symbol: String
    var count: Int?
}

/// Pure sidebar logic: which shortcuts are pinned, which folders show for a search, and what a row is called.
enum SidebarModel {
    static func pinned(for tab: AppTab) -> [SidebarEntry] {
        Shortcut.pinned(for: tab).map { SidebarEntry(id: "s:" + $0.rawValue, selection: .shortcut($0), title: $0.title, symbol: $0.symbol) }
    }

    /// Every provider category becomes a folder. Empty ones are listed unless `hideEmpty` is on, and items that belong to no
    /// category are reachable through an "Uncategorized" folder at the end.
    static func folders(_ categories: [CatalogCategory], hideEmpty: Bool = true, uncategorized: Int = 0) -> [SidebarEntry] {
        var out = categories.filter { !hideEmpty || $0.itemCount > 0 }
            .map { SidebarEntry(id: "f:" + $0.id, selection: .folder($0.id), title: $0.name, symbol: FolderIcons.symbol(for: $0.name), count: $0.itemCount) }
        if uncategorized > 0 {
            out.append(SidebarEntry(id: "f:" + CatalogCategory.uncategorizedID, selection: .folder(CatalogCategory.uncategorizedID), title: "Uncategorized", symbol: "tray", count: uncategorized))
        }
        return out
    }

    /// In "All Playlists" two playlists can have a folder of the same name ("Sports" in each). Their rows would look identical but open different lists, so a name more than one
    /// playlist has gets the playlist's name after it. A name only one playlist has stays as it is.
    static func tellingPlaylistsApart(_ entries: [SidebarEntry], categories: [CatalogCategory], playlistNames: [UUID: String]) -> [SidebarEntry] {
        var owner: [String: CatalogCategory] = [:]
        for c in categories { owner["f:" + c.id] = c }
        var sources: [String: Set<UUID>] = [:]
        for e in entries { if let c = owner[e.id] { sources[MetadataNormalizer.normalize(e.title), default: []].insert(c.sourceID) } }
        return entries.map { e in
            guard let c = owner[e.id], (sources[MetadataNormalizer.normalize(e.title)]?.count ?? 0) > 1, let name = playlistNames[c.sourceID], !name.isEmpty else { return e }
            return SidebarEntry(id: e.id, selection: e.selection, title: "\(e.title) · \(name)", symbol: e.symbol, count: e.count)
        }
    }

    /// Folder search filters folders only. The pinned shortcuts are never affected.
    static func filter(_ folders: [SidebarEntry], query: String) -> [SidebarEntry] {
        let q = MetadataNormalizer.normalize(query)
        guard !q.isEmpty else { return folders }
        return folders.filter { MetadataNormalizer.normalize($0.title).contains(q) }
    }

    static func categoryKind(for tab: AppTab) -> ContentKind? {
        switch tab { case .liveTV, .guide: .channel; case .movies: .movie; case .series: .series; case .home: nil }
    }
}
