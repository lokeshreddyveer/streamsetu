import Foundation
import Observation

/// App-wide observable state: configured sources, live sync progress, counts and toasts.
@MainActor @Observable
final class AppState {
    var sources: [PlaylistSource] = []
    var syncProgress: [UUID: SyncProgress] = [:]
    var counts = CatalogCounts()
    /// Bumped whenever the catalog changes so open screens reload.
    var catalogVersion = 0
    var loaded = false
    /// Single source of truth for hearts across every screen.
    private(set) var favoriteIDs: Set<String> = []
    /// Series that gained an episode the person has not played yet (the NEW badge).
    private(set) var newEpisodeSeriesIDs: Set<String> = []
    func hasNewEpisodes(_ seriesID: String) -> Bool { newEpisodeSeriesIDs.contains(seriesID) }
    func reloadNewEpisodes() {
        let service = container.newEpisodes
        Task { @MainActor in
            let ids = await Task.detached { service.seriesIDs() }.value
            if ids != newEpisodeSeriesIDs { newEpisodeSeriesIDs = ids; catalogVersion += 1 }
        }
    }
    /// Movies and series watched to the end (the tick on a poster).
    private(set) var watchedIDs: Set<String> = []
    func isWatched(_ id: String) -> Bool { watchedIDs.contains(id) }
    func reloadWatched() {
        let repo = container.historyRepo
        Task { @MainActor in
            let ids = await Task.detached { (try? repo.watchedTitleIDs()) ?? [] }.value
            if ids != watchedIDs { watchedIDs = ids }
        }
    }
    /// Movies and series saved to watch later. A built-in list, kept with the person's other lists.
    private(set) var watchLaterIDs: Set<String> = []
    nonisolated static let watchLaterListID = "watch-later"
    let toasts = ToastCenter()
    /// The playlist all content is scoped to. Persisted across launches; the start *page* never is.
    private(set) var activeSourceID: UUID?
    /// "All Playlists": the library shows every enabled playlist together. [activeSourceID] is nil then, which the catalog reads as "no filter".
    private(set) var showsAllPlaylists = false
    /// Stands for "All Playlists" in the playlist pickers.
    static let allPlaylistsID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    /// Folder (category) entries for the active playlist, per kind. Never contains demo or invented folders.
    private(set) var folders: [ContentKind: [SidebarEntry]] = [:]
    private let defaults: UserDefaults

    private let container: AppContainer
    private var observerID: UUID?

    init(container: AppContainer, defaults: UserDefaults = .standard) { self.container = container; self.defaults = defaults }

    var needsOnboarding: Bool { loaded && sources.isEmpty }
    var isSyncing: Bool { syncProgress.values.contains { $0.state.isBusy } }
    var hasContent: Bool { counts.channels + counts.movies + counts.series > 0 }

    func start() async {
        reload()
        loaded = true
        observerID = await container.sync.addObserver { [weak self] p in
            Task { @MainActor in self?.apply(p) }
        }
        container.onNewEpisodesChanged = { [weak self] in self?.reloadNewEpisodes() }
        reloadNewEpisodes()
        reloadWatched()
        container.scheduler.start()
        let queue = container.watchQueue
        container.playback.queueAdvance = { [weak self] in
            guard let self, let next = queue.popNext() else { return false }
            self.container.play(queued: next) { [weak self] message in self?.toasts.show(message, symbol: "exclamationmark.triangle.fill", kind: .warning) }
            return true
        }
        container.vpn.onDrop = { [weak self] in
            guard let self else { return }
            let c = self.container
            let playing = c.playback.state == .playing || c.playback.state == .buffering
            if VPNRules.shouldPause(wasOn: true, isOn: false, enabled: c.settings.vpnPause, playing: playing) {
                c.playback.pause()
                self.toasts.show("The VPN disconnected, so playback was paused.", symbol: "lock.slash", kind: .warning, duration: 8)
            }
        }
    }

    func isFavorite(_ id: String) -> Bool { favoriteIDs.contains(id) }

    @discardableResult
    func toggleFavorite(_ id: String, kind: ContentKind) -> Bool {
        let on = !favoriteIDs.contains(id)
        try? container.favoritesRepo.setFavorite(id, kind: kind, on: on)
        if on { favoriteIDs.insert(id) } else { favoriteIDs.remove(id) }
        return on
    }

    /// Puts a favourite first or last in its list; the lists reload.
    func moveFavorite(_ id: String, kind: ContentKind, toFront: Bool) {
        try? container.favoritesRepo.move(id, kind: kind, toFront: toFront)
        catalogVersion += 1
    }

    func isWatchLater(_ id: String) -> Bool { watchLaterIDs.contains(id) }

    @discardableResult
    func toggleWatchLater(_ id: String, kind: ContentKind) -> Bool {
        let on = !watchLaterIDs.contains(id)
        if on {
            // The list is created the first time something is saved to it (a deleted one comes back the same way).
            try? container.db.write { c in try c.execute("INSERT OR IGNORE INTO collections(id, name, created_at) VALUES(?,?,?)", [Self.watchLaterListID, "Watch Later", Date()]) }
            try? container.favoritesRepo.add(itemID: id, kind: kind, toCollection: Self.watchLaterListID)
            watchLaterIDs.insert(id)
        } else {
            try? container.favoritesRepo.remove(itemID: id, fromCollection: Self.watchLaterListID)
            watchLaterIDs.remove(id)
        }
        return on
    }

    func reloadWatchLater() {
        watchLaterIDs = Set(((try? container.favoritesRepo.collectionItems(id: Self.watchLaterListID)) ?? []).map(\.itemID))
    }

    func reloadFavorites() {
        var all = Set<String>()
        for k in [ContentKind.channel, .movie, .series] { all.formUnion((try? container.favoritesRepo.favoriteIDs(kind: k)) ?? []) }
        favoriteIDs = all
    }

    var activeSource: PlaylistSource? { sources.first { $0.id == activeSourceID } }
    /// A playlist (or all of them) is open, as opposed to nothing being set up.
    var hasLibrary: Bool { activeSource != nil || showsAllPlaylists }
    /// Combining needs at least two playlists that are switched on.
    var canCombinePlaylists: Bool { sources.filter(\.enabled).count >= 2 }
    var libraryName: String? { showsAllPlaylists ? "All Playlists" : activeSource?.name }

    /// Shows every enabled playlist together. Playback is stopped, as it is for any switch.
    func switchToAllPlaylists() {
        guard canCombinePlaylists, !showsAllPlaylists else { return }
        container.playback.stop()
        showsAllPlaylists = true; activeSourceID = nil
        defaults.set("all", forKey: "activePlaylist")
        catalogVersion += 1
        toasts.show("Showing all playlists together", symbol: "checkmark.circle.fill", kind: .success)
    }

    /// Switches the active playlist. Playback from the previous playlist is stopped, as content is scoped per playlist.
    func switchPlaylist(_ id: UUID) {
        guard id != activeSourceID || showsAllPlaylists, sources.contains(where: { $0.id == id }) else { return }
        container.playback.stop()
        showsAllPlaylists = false
        activeSourceID = id
        defaults.set(id.uuidString, forKey: "activePlaylist")
        catalogVersion += 1
        toasts.show("Switched to \(sourceName(id))", symbol: "checkmark.circle.fill", kind: .success)
    }

    private func validateActiveSource() {
        let enabled = sources.filter(\.enabled)
        if showsAllPlaylists || defaults.string(forKey: "activePlaylist") == "all", enabled.count >= 2 { showsAllPlaylists = true; activeSourceID = nil; return }
        showsAllPlaylists = false
        if let id = activeSourceID, enabled.contains(where: { $0.id == id }) { return }
        let saved = defaults.string(forKey: "activePlaylist").flatMap(UUID.init(uuidString:))
        activeSourceID = enabled.first { $0.id == saved }?.id ?? enabled.first?.id
        if let id = activeSourceID { defaults.set(id.uuidString, forKey: "activePlaylist") } else { defaults.removeObject(forKey: "activePlaylist") }
    }

    func folderEntries(for tab: AppTab) -> [SidebarEntry] {
        guard let kind = SidebarModel.categoryKind(for: tab) else { return [] }
        return folders[kind] ?? []
    }

    /// Puts the folders of one tab in the given order (entry ids, first = top). The sidebar updates at once; the order is saved
    /// in the background and applies to every sidebar of that type from then on.
    func reorderFolders(tab: AppTab, entryIDs: [String]) {
        guard let kind = SidebarModel.categoryKind(for: tab), let current = folders[kind] else { return }
        let byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var ordered = entryIDs.compactMap { byID[$0] }
        ordered += current.filter { e in !entryIDs.contains(e.id) }          // anything not mentioned (e.g. Uncategorized) keeps its place at the end
        folders[kind] = ordered
        let c = container
        let categoryIDs = ordered.compactMap { e -> String? in if case .folder(let id) = e.selection, id != CatalogCategory.uncategorizedID { id } else { nil } }
        Task.detached { try? c.catalog.setFolderOrder(categoryIDs) }
    }

    func hideFolder(_ id: String) {
        let c = container
        Task { @MainActor in
            await Task.detached { try? c.favoritesRepo.hide(id, kind: "category") }.value
            reloadFolders()
        }
    }

    func folderName(_ id: String) -> String? {
        if id == CatalogCategory.uncategorizedID { return "Uncategorized" }
        for list in folders.values { if let e = list.first(where: { if case .folder(let f) = $0.selection { f == id } else { false } }) { return e.title } }
        return nil
    }

    func reloadFolders() {
        let c = container, sid = activeSourceID, hideEmpty = container.settings.hideEmptyFolders
        Task { @MainActor in
            let result = await Task.detached { () -> [ContentKind: [SidebarEntry]] in
                var out: [ContentKind: [SidebarEntry]] = [:]
                for k in [ContentKind.channel, .movie, .series] {
                    out[k] = SidebarModel.folders((try? c.catalog.categories(sourceID: sid, kind: k, includeHidden: false)) ?? [], hideEmpty: hideEmpty,
                                                  uncategorized: (try? c.catalog.uncategorizedCount(sourceID: sid, kind: k)) ?? 0)
                }
                return out
            }.value
            if sid == self.activeSourceID { self.folders = result }
        }
    }

    func reload() {
        reloadFavorites()
        reloadWatchLater()
        sources = (try? container.catalog.sources()) ?? []
        validateActiveSource()
        counts = (try? container.catalog.counts(sourceID: activeSourceID)) ?? CatalogCounts()
        reloadFolders()
    }

    private func apply(_ p: SyncProgress) {
        let wasBusy = syncProgress[p.sourceID]?.state.isBusy ?? false
        syncProgress[p.sourceID] = p
        switch p.state {
        case .completed:
            reload(); catalogVersion += 1
            if wasBusy {
                let name = sources.first { $0.id == p.sourceID }?.name ?? "Source"
                toasts.show("\(name) updated", symbol: "checkmark.circle.fill", kind: .success)
                for n in p.notes { toasts.show(n, symbol: "exclamationmark.triangle.fill", kind: .warning) }
            }
        case .failed(let m):
            reload()
            let name = sources.first { $0.id == p.sourceID }?.name ?? "Source"
            toasts.show("\(name): \(m)", symbol: "xmark.octagon.fill", kind: .error)
        default: break
        }
    }

    func sync(_ id: UUID, forceGuide: Bool = false) { Task { await container.sync.start(sourceID: id, forceGuide: forceGuide) } }
    func syncAll() { for s in sources where s.enabled { sync(s.id) } }
    func cancelSync(_ id: UUID) { Task { await container.sync.cancel(sourceID: id) } }

    func sourceName(_ id: UUID) -> String { sources.first { $0.id == id }?.name ?? "" }
}
