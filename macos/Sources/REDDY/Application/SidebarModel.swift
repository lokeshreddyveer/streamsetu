import Foundation

/// One row of a contextual sidebar, as the sidebar component sees it.
struct SidebarEntry: Identifiable, Hashable, Sendable {
    let id: String
    let selection: SidebarSelection
    let title: String
    let symbol: String
    var count: Int?
    /// True for the app's own wording (shortcuts, Uncategorized), which is translated; a provider's folder name never is.
    var titleIsLocalized = false

    /// What is shown for the row, in the language in use.
    var displayTitle: String { titleIsLocalized ? Localized.string(title) : title }
}

/// Pure sidebar logic: which shortcuts are pinned, which folders show for a search, and what a row is called.
enum SidebarModel {
    static func pinned(for tab: AppTab) -> [SidebarEntry] {
        Shortcut.pinned(for: tab).map { SidebarEntry(id: "s:" + $0.rawValue, selection: .shortcut($0), title: $0.title, symbol: $0.symbol, titleIsLocalized: true) }
    }

    /// Every provider category becomes a folder. Empty ones are listed unless `hideEmpty` is on, and items that belong to no
    /// category are reachable through an "Uncategorized" folder at the end. A locked folder is always listed: while folders are
    /// locked its count is reported as 0 so nothing is given away, which does not make it empty.
    static func folders(_ categories: [CatalogCategory], hideEmpty: Bool = true, uncategorized: Int = 0) -> [SidebarEntry] {
        var out = categories.filter { !hideEmpty || $0.itemCount > 0 || $0.isLocked }
            .map { SidebarEntry(id: "f:" + $0.id, selection: .folder($0.id), title: $0.name, symbol: FolderIcons.symbol(for: $0.name), count: $0.itemCount) }
        if uncategorized > 0 {
            out.append(SidebarEntry(id: "f:" + CatalogCategory.uncategorizedID, selection: .folder(CatalogCategory.uncategorizedID), title: "Uncategorized", symbol: "tray", count: uncategorized, titleIsLocalized: true))
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
            return SidebarEntry(id: e.id, selection: e.selection, title: "\(e.title) · \(name)", symbol: e.symbol, count: e.count, titleIsLocalized: false)
        }
    }

    private struct FilterCache: Sendable { var query: String; var language: String; var folders: [SidebarEntry]; var result: [SidebarEntry] }
    private static let filterCache = Locked<FilterCache?>(nil)

    /// Folder search filters folders only. The pinned shortcuts are never affected. The last answer is kept, so a view body
    /// that asks several times for the same (query, folders) does the matching once.
    static func filter(_ folders: [SidebarEntry], query: String) -> [SidebarEntry] {
        let q = MetadataNormalizer.normalize(query)
        guard !q.isEmpty else { return folders }
        let language = Localized.activeCode
        if let c = filterCache.value, c.query == q, c.language == language, c.folders == folders { return c.result }
        // The name the person sees counts too (the app's own wording is translated).
        let out = folders.filter { MetadataNormalizer.normalize($0.title).contains(q) || ($0.titleIsLocalized && MetadataNormalizer.normalize($0.displayTitle).contains(q)) }
        filterCache.value = FilterCache(query: q, language: language, folders: folders, result: out)
        return out
    }

    /// The folder search that applies: none while the sidebar is collapsed, where the field, its clear button and "No matching folders" are not shown.
    static func appliedQuery(_ query: String, collapsed: Bool) -> String { collapsed ? "" : query }

    /// What it takes to show the selected folder: its row id, and whether the folder search hides it (the search is then cleared first). nil when no listed folder is selected.
    static func reveal(_ selection: SidebarSelection, in folders: [SidebarEntry], query: String) -> (rowID: String, clearsSearch: Bool)? {
        guard case .folder = selection, let e = folders.first(where: { $0.selection == selection }) else { return nil }
        return (e.id, !filter(folders, query: query).contains(e))
    }

    /// The order to save after a drag, or nil when the drop left every folder where it was (nothing is written then).
    static func changedOrder(_ held: [SidebarEntry]?, saved: [SidebarEntry]) -> [String]? {
        guard let ids = held?.map(\.id), ids != saved.map(\.id) else { return nil }
        return ids
    }

    /// The tab a pinned list is opened in when asked for by name: the one in view when it pins the list, else the list's usual tab, else the first that pins it.
    static func tab(for shortcut: Shortcut, current: AppTab) -> AppTab? {
        if Shortcut.pinned(for: current).contains(shortcut) { return current }
        let usual: AppTab? = switch shortcut {
        case .featured, .recentlyAdded, .unwatched, .unwatchedFavorites, .addedThisMonth: .movies
        case .newEpisodes: .series
        default: nil
        }
        return usual ?? AppTab.allCases.first { Shortcut.pinned(for: $0).contains(shortcut) }
    }

    /// The Uncategorized folder is fixed at the end: it can be neither moved nor hidden.
    static func isMovable(_ e: SidebarEntry) -> Bool { e.selection != .folder(CatalogCategory.uncategorizedID) }

    /// Which entries of a folder's right-click menu apply.
    struct FolderMenuPlan: Equatable, Sendable {
        var moves = false, moveUp = false, moveDown = false, hide = false, lock = false, unlock = false
        var isEmpty: Bool { !moves && !hide && !lock && !unlock }
    }

    /// Hide Folder does not depend on reordering (which is off while the folder search has text); the Uncategorized folder gets no menu at all.
    static func folderMenu(for e: SidebarEntry, in list: [SidebarEntry], canReorder: Bool, canHide: Bool, parentalAvailable: Bool, canLock: Bool, lockedIDs: Set<String>) -> FolderMenuPlan {
        var plan = FolderMenuPlan()
        guard case .folder(let id) = e.selection, id != CatalogCategory.uncategorizedID else { return plan }
        if canReorder {
            let movable = list.filter(isMovable)
            let i = movable.firstIndex(of: e)
            plan.moves = i != nil
            plan.moveUp = (i ?? 0) > 0
            plan.moveDown = i != nil && i! < movable.count - 1
        }
        plan.hide = canHide
        if parentalAvailable, canLock { if lockedIDs.contains(id) { plan.unlock = true } else { plan.lock = true } }
        return plan
    }

    /// nil when the selection still points at something that exists. A folder that is gone (hidden, emptied, removed) falls back to the tab's first shortcut.
    @MainActor static func selectionAfterReload(_ selection: SidebarSelection, folders: [SidebarEntry], tab: AppTab) -> SidebarSelection? {
        // Uncategorized is listed only while it has titles: when it empties, its row goes and the selection must not stay on a list nobody can see highlighted.
        guard case .folder = selection else { return nil }
        if folders.contains(where: { $0.selection == selection }) { return nil }
        return AppRouter.defaultSelection(for: tab)
    }

    /// A folder drag is over when the primary mouse button is no longer down (dropped outside, or cancelled with Esc).
    static func dragHasEnded(pressedButtons: Int) -> Bool { pressedButtons & 1 == 0 }

    static func categoryKind(for tab: AppTab) -> ContentKind? {
        switch tab { case .liveTV, .guide: .channel; case .movies: .movie; case .series: .series; case .home: nil }
    }
}
