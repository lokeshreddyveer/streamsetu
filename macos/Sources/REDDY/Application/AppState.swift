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
    /// Bumped by "Shuffle recommendations": Home draws a new mix. It never starts a sync and never touches playback history.
    var shuffleTick = 0
    func shuffleRecommendations() {
        container.smartMix.reshuffle(profile: container.profiles.activeID)
        shuffleTick += 1
        toasts.show("Recommendations shuffled", symbol: "shuffle", kind: .success)
    }
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
    /// Started but not finished: the bar along the bottom of a poster.
    private(set) var partialIDs: [String: Double] = [:]
    func partialProgress(_ id: String) -> Double? { partialIDs[id] }
    private var watchedReloadPending = false
    /// Resume points are saved every few seconds while something plays; the posters catch up at most once every two seconds.
    func scheduleWatchedReload() {
        guard !watchedReloadPending else { return }
        watchedReloadPending = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            watchedReloadPending = false
            reloadWatched()
        }
    }
    @ObservationIgnored private let watchedLoad = LatestLoad()
    @ObservationIgnored private let coreLoad = LatestLoad()
    /// Both aggregations run off the main actor, one scan at a time (a tab entry, a progress save and a sync arriving together cost one scan and one follow-up, not three).
    func reloadWatched() {
        let repo = container.historyRepo
        watchedLoad.coalesced({ ((try? repo.watchedTitleIDs()) ?? [], (try? repo.partialProgress()) ?? [:]) }) { [weak self] (ids, partial) in
            guard let self else { return }
            if ids != watchedIDs { watchedIDs = ids }
            if partial != partialIDs { partialIDs = partial }
        }
    }
    /// Waits for the watched-state scan started so far (tests).
    func settleWatched() async { await watchedLoad.settle() }
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

    @ObservationIgnored nonisolated(unsafe) private var landedObserver: NSObjectProtocol?
    deinit { if let o = landedObserver { NotificationCenter.default.removeObserver(o) } }
    @ObservationIgnored private var landedGate = LandedPublishGate(minInterval: 30)
    @ObservationIgnored private var landedRetry: Task<Void, Never>?

    /// Artwork the background matcher wrote down: tiles on screen patch themselves in place (see `MetadataLandedHub`). The lists reload only when a title on screen changed,
    /// at most once in half a minute, and never while the list is being scrolled (the change waits and is offered again).
    private func watchLandedArtwork() {
        guard landedObserver == nil else { return }
        landedObserver = NotificationCenter.default.addObserver(forName: .titleMetadataLanded, object: nil, queue: .main) { [weak self] n in
            let e = TitleMetadataEvent(n)
            guard e.bulk else { return }
            MainActor.assumeIsolated { self?.landedBatch(e.ids) }
        }
    }

    private func landedBatch(_ ids: [String]) {
        let hub = MetadataLandedHub.shared
        let up = ProcessInfo.processInfo.systemUptime
        if landedGate.offer(now: up, changedVisible: hub.hasVisible(anyOf: ids), busy: hub.isScrolling) { catalogVersion += 1 }
        else if landedGate.pending { scheduleLandedRetry() }
    }

    private func scheduleLandedRetry() {
        guard landedRetry == nil else { return }
        landedRetry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            self.landedRetry = nil
            if Task.isCancelled { return }
            let hub = MetadataLandedHub.shared
            if self.landedGate.retry(now: ProcessInfo.processInfo.systemUptime, busy: hub.isScrolling) { self.catalogVersion += 1 }
            else if self.landedGate.pending { self.scheduleLandedRetry() }
        }
    }

    func start() async {
        watchLandedArtwork()
        await reloadAsync()
        loaded = true
        observerID = await container.sync.addObserver { [weak self] p in
            Task { @MainActor in self?.apply(p) }
        }
        container.onNewEpisodesChanged = { [weak self] in self?.reloadNewEpisodes() }
        container.historyRepo.onProgressChanged = { [weak self] in Task { @MainActor in self?.scheduleWatchedReload() } }
        reloadNewEpisodes()
        reloadWatched()
        container.scheduler.start()
        // Guide hub: guides added by the person and the public channel database, when due (on launch, then every half hour while the app runs).
        Task.detached(priority: .utility) { [container] in while !Task.isCancelled { await container.runGuideHub(); try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000) } }
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
        defaults.set("all", forKey: DefaultsKey.activePlaylist)
        scopeChanged()
        catalogVersion += 1
        toasts.show("Showing all playlists together", symbol: "checkmark.circle.fill", kind: .success)
    }

    /// Switches the active playlist. Playback from the previous playlist is stopped, as content is scoped per playlist.
    func switchPlaylist(_ id: UUID) {
        guard id != activeSourceID || showsAllPlaylists, sources.contains(where: { $0.id == id }) else { return }
        container.playback.stop()
        showsAllPlaylists = false
        activeSourceID = id
        defaults.set(id.uuidString, forKey: DefaultsKey.activePlaylist)
        scopeChanged()
        catalogVersion += 1
        toasts.show("Switched to \(sourceName(id))", symbol: "checkmark.circle.fill", kind: .success)
    }

    /// The playlist (or All) in view changed: the sidebar folders and the counts belong to the old one until they are read again, so the old folders go at once
    /// (a folder of another playlist opens an empty list) and both are read for the new scope. An answer for a scope that is no longer open is dropped.
    private func scopeChanged() {
        folders = [:]
        scopeLoad?.cancel()
        let c = container
        scopeLoad = Task { @MainActor [weak self] in
            guard let self else { return }
            let sid = activeSourceID, all = showsAllPlaylists
            let counts = await offMain { (try? c.catalog.visibleCounts(sourceID: sid)) ?? CatalogCounts() }
            guard !Task.isCancelled, sid == activeSourceID, all == showsAllPlaylists else { return }
            self.counts = counts
            reloadFolders()
        }
    }
    @ObservationIgnored private var scopeLoad: Task<Void, Never>?
    /// Waits for the counts and folders asked for by the last playlist switch (tests).
    func settleScope() async { await scopeLoad?.value }

    /// A playlist was just added (and `reload()` has listed it). Seen as one playlist, the new one opens. In "All Playlists" the view stays as it is: the new playlist is part of it.
    func playlistAdded(_ id: UUID) {
        if showsAllPlaylists, canCombinePlaylists {
            catalogVersion += 1
            scopeChanged()
        } else { switchPlaylist(id) }
    }

    /// Removes a playlist and everything kept for it (channels, titles, favorites, history, guide, login), what is playing from it, a refresh running for it and the screens kept for it.
    /// If it was the open playlist, "All Playlists" opens when two or more remain, else the one that remains, else the empty state.
    func removePlaylist(_ id: UUID) {
        let wasOpen = activeSourceID == id
        let prefix = id.uuidString.lowercased() + "|"
        if let playing = container.playback.current?.itemID, playing.hasPrefix(prefix) { container.playback.stop() }
        let c = container
        Task { await c.sync.cancel(sourceID: id) }
        do { try container.sources.remove(id) }
        catch { toasts.show("Could not remove the playlist: \(error.localizedDescription)", symbol: "xmark.octagon.fill", kind: .error); return }
        syncProgress[id] = nil
        container.screens.removeAll { $0.source == id }
        container.filterOptionsStore.invalidate()
        if wasOpen {
            activeSourceID = nil
            showsAllPlaylists = ((try? container.catalog.sources()) ?? []).filter(\.enabled).count >= 2
            if showsAllPlaylists { defaults.set("all", forKey: DefaultsKey.activePlaylist) }
        }
        reload()
        catalogVersion += 1
    }

    private func validateActiveSource() {
        let enabled = sources.filter(\.enabled)
        if showsAllPlaylists || defaults.string(forKey: DefaultsKey.activePlaylist) == "all", enabled.count >= 2 { showsAllPlaylists = true; activeSourceID = nil; return }
        showsAllPlaylists = false
        if let id = activeSourceID, enabled.contains(where: { $0.id == id }) { return }
        let saved = defaults.string(forKey: DefaultsKey.activePlaylist).flatMap(UUID.init(uuidString:))
        activeSourceID = enabled.first { $0.id == saved }?.id ?? enabled.first?.id
        if let id = activeSourceID { defaults.set(id.uuidString, forKey: DefaultsKey.activePlaylist) } else { defaults.removeObject(forKey: DefaultsKey.activePlaylist) }
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
        let names = Dictionary(sources.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        Task { @MainActor in
            let result = await Task.detached { () -> [ContentKind: [SidebarEntry]] in
                var out: [ContentKind: [SidebarEntry]] = [:]
                for k in [ContentKind.channel, .movie, .series] {
                    let cats = (try? c.catalog.categories(sourceID: sid, kind: k, includeHidden: false)) ?? []
                    var entries = SidebarModel.folders(cats, hideEmpty: hideEmpty, uncategorized: (try? c.catalog.uncategorizedCount(sourceID: sid, kind: k)) ?? 0)
                    if sid == nil { entries = SidebarModel.tellingPlaylistsApart(entries, categories: cats, playlistNames: names) }
                    out[k] = entries
                }
                return out
            }.value
            if sid == self.activeSourceID { self.folders = result }
        }
    }

    /// `reload()` with its reads off the main actor. A newer call makes an older one stale (its result is dropped), and a playlist switch while it ran drops it too.
    /// Returns when the result was applied or dropped.
    func reloadAsync() async {
        let c = container
        let t = coreLoad.run({ () -> ReloadSnapshot in
            var fav = Set<String>()
            for k in [ContentKind.channel, .movie, .series] { fav.formUnion((try? c.favoritesRepo.favoriteIDs(kind: k)) ?? []) }
            let later = Set(((try? c.favoritesRepo.collectionItems(id: Self.watchLaterListID)) ?? []).map(\.itemID))
            return ReloadSnapshot(favorites: fav, watchLater: later, sources: (try? c.catalog.sources()) ?? [])
        }, apply: { [weak self] snap in
            guard let self else { return }
            favoriteIDs = snap.favorites; watchLaterIDs = snap.watchLater; sources = snap.sources
            validateActiveSource()
        })
        await t.value
        // Counts depend on the (validated) active playlist, so they are read after it is known; an answer for a playlist that is no longer active is dropped.
        let sid = activeSourceID
        let counts = await offMain { (try? c.catalog.visibleCounts(sourceID: sid)) ?? CatalogCounts() }
        if sid == activeSourceID { self.counts = counts }
        reloadFolders()
    }
    private struct ReloadSnapshot: Sendable { let favorites: Set<String>; let watchLater: Set<String>; let sources: [PlaylistSource] }

    func reload() {
        coreLoad.cancel()          // an older asynchronous reload must not land on top of this one
        reloadFavorites()
        reloadWatchLater()
        sources = (try? container.catalog.sources()) ?? []
        validateActiveSource()
        counts = (try? container.catalog.visibleCounts(sourceID: activeSourceID)) ?? CatalogCounts()
        reloadFolders()
    }

    private func apply(_ p: SyncProgress) {
        let wasBusy = syncProgress[p.sourceID]?.state.isBusy ?? false
        syncProgress[p.sourceID] = p
        switch p.state {
        case .completed:
            Task { @MainActor in
                await reloadAsync(); catalogVersion += 1
                if wasBusy {
                    let name = sources.first { $0.id == p.sourceID }?.name ?? "Source"
                    toasts.show("\(name) updated", symbol: "checkmark.circle.fill", kind: .success)
                    for n in p.notes { toasts.show(n, symbol: "exclamationmark.triangle.fill", kind: .warning) }
                }
            }
        case .failed(let m):
            Task { @MainActor in
                await reloadAsync()
                let name = sources.first { $0.id == p.sourceID }?.name ?? "Source"
                toasts.show("\(name): \(m)", symbol: "xmark.octagon.fill", kind: .error)
            }
        default: break
        }
    }

    /// A seam for tests: told of every refresh asked for, with whether the guide was forced.
    var syncHook: ((UUID, Bool) -> Void)?
    func sync(_ id: UUID, forceGuide: Bool = false) { syncHook?(id, forceGuide); Task { await container.sync.start(sourceID: id, forceGuide: forceGuide) } }
    func syncAll() { for s in sources where s.enabled { sync(s.id) } }
    /// Refreshes the guide of every playlist that is on, even one that looks fresh enough: what the Settings "Refresh guide" button does, and what the assistant offers.
    func refreshGuides() { for s in sources where s.enabled { sync(s.id, forceGuide: true) } }
    func cancelSync(_ id: UUID) { Task { await container.sync.cancel(sourceID: id) } }

    func sourceName(_ id: UUID) -> String { sources.first { $0.id == id }?.name ?? "" }
}
