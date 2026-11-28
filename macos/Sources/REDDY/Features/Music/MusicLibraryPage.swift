import SwiftUI
import UniformTypeIdentifiers

// The person's own music: songs, albums, artists, playlists, history and local files, with a JSON backup they can export and import.
// The page is the shell: header, tabs, filter and chips. Filtering and ordering happen off the main actor in `MusicLibraryListModel`; the rows
// are drawn by `MusicTrackList` and `MusicLibraryCollection`.

/// Everything the backup file carries. Plain Codable so the file is readable and survives app updates.
struct MusicBackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

enum MusicHistoryLogic {
    /// Newest first, one row per play, capped so a long history does not build a huge list.
    static func recent(_ records: [PlayRecord], limit: Int = 200) -> [PlayRecord] { Array(records.sorted { $0.at > $1.at }.prefix(limit)) }
    static func dayLabel(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(d, inSameDayAs: now) { return Localized.string("Today") }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) { return Localized.string("Yesterday") }
        return d.formatted(date: .abbreviated, time: .omitted)
    }
}

extension MusicLibraryTab {
    /// The name the first tab had before the redesign (the snapshot scenarios still ask for it).
    static var liked: MusicLibraryTab { .songs }
}

/// The words under the title: how many, and how many of them the filter leaves.
enum MusicLibraryCountLine {
    static func total(_ tab: MusicLibraryTab, count n: Int) -> String {
        switch tab {
        case .songs, .local: Localized.plural(n, one: "%@ song", other: "%@ songs")
        case .albums: Localized.plural(n, one: "%@ album", other: "%@ albums")
        case .artists: Localized.plural(n, one: "%@ artist", other: "%@ artists")
        case .playlists: Localized.plural(n, one: "%@ playlist", other: "%@ playlists")
        case .podcasts: Localized.plural(n, one: "%@ episode", other: "%@ episodes")
        case .history: Localized.plural(n, one: "%@ play", other: "%@ plays")
        }
    }
    static func line(_ tab: MusicLibraryTab, shown: Int, total: Int, filtered: Bool) -> String {
        filtered && shown != total ? Localized.string("Showing %1$@ of %2$@", shown.formatted(), Self.total(tab, count: total)) : Self.total(tab, count: total)
    }
}

struct MusicLibraryPage: View {
    let hub: MusicHub
    private let prefs = MusicLibraryPrefs()
    @State private var tab: MusicLibraryTab
    @State private var sort: MusicLibrarySort
    @State private var reversed: Bool
    @State private var filter: MusicLibraryFilterState
    @State private var savedMode: MusicLibraryViewMode?
    @State private var selecting = false
    @State private var contentWidth: CGFloat = 0
    @State private var models = MusicLibraryModels()
    @State private var localTracks: [MusicTrack]?
    @Environment(\.reddyAccent) private var accent
    /// True when the page was opened from a sidebar shortcut (Recently Added, Artists, Albums, Songs): that one list on its own page, with a way back to Your library.
    @State private var standalone = false
    @AppStorage(MusicSetupGate.doneKey) private var setupDone = false
    @AppStorage(MusicSetupGate.dismissedKey) private var setupCardDismissed = false
    private var setupOffer: MusicSetupGate.Offer {
        MusicSetupGate.offer(setupDone: setupDone, cardDismissed: setupCardDismissed, prefs: MusicTastePreferences.shared.prefs, plays: hub.library.history.count, likes: hub.library.liked.count)
    }
    /// The Albums and Artists tabs: saved or followed ones plus those of the liked songs and of the person's own files (see `MusicLibraryDerived`).
    @State private var derivedAlbums = MusicLibraryDerived.Albums(albums: [], fromSongs: [])
    @State private var derivedArtists = MusicLibraryDerived.Artists(artists: [], fromSongs: [])
    @State private var hasPodcasts = false
    @State private var creating = false
    @State private var newName = ""
    @State private var exporting = false
    @State private var importing = false
    @State private var showImport = false
    @State private var showCombine = false
    @State private var backupDoc = MusicBackupDocument(data: Data())
    @State private var note: String?
    @State private var source = MusicLibrarySource.local
    @State private var spotifySignedIn = false
    @State private var facets = MusicFacetSet()
    @State private var facetSel: MusicFacetSelection
    @State private var facetMemo: [String: (key: String, set: MusicFacetSet)] = [:]
    @State private var folderSel: UUID?
    @State private var localFolders = false
    @State private var playCounts: [String: Int] = [:]
    @Environment(\.musicLayoutClass) private var layoutClass

    init(hub: MusicHub, initialTab: MusicLibraryTab? = nil) {
        self.hub = hub
        let p = MusicLibraryPrefs()
        let t = initialTab ?? p.tab ?? .songs
        _tab = State(initialValue: t)
        _sort = State(initialValue: p.sort(t))
        _reversed = State(initialValue: p.reversed(t))
        _filter = State(initialValue: p.filter(t))
        _facetSel = State(initialValue: MusicFacetSession.selection(t.rawValue))
        _savedMode = State(initialValue: p.mode(t))
    }

    /// Your library is always here. A service shows up as its own source only while its account is connected.
    private var sources: [MusicLibrarySource] {
        MusicLibrarySources.available(youTubeAccount: YouTubeMusicAccountBuiltIns.manager.flatMap { $0.isSignedIn ? $0.active : nil },
                                      spotifySignedIn: spotifySignedIn && hub.registry.isEnabled("spotify"))
    }
    private var resolvedSource: MusicLibrarySource { MusicLibrarySources.resolve(saved: source, available: sources) }
    private var localFilesOn: Bool { hub.registry.isEnabled(MusicStatsRules.localProviderID) }
    private var tabs: [MusicLibraryTab] { MusicLibraryTabs.visible(hasPodcasts: hasPodcasts, localFilesOn: localFilesOn) }
    private var activeTab: MusicLibraryTab { MusicLibraryTabs.resolve(saved: tab, visible: tabs) }
    private var standaloneTab: MusicLibraryTab? { standalone ? activeTab : nil }
    private var tabStyle: MusicLibraryTabStyle { MusicLibraryTabStyle.resolve(layoutClass: layoutClass, contentWidth: contentWidth) }

    /// Everything that should make the lists recompute, as one value.
    private struct Trigger: Equatable {
        var tab: MusicLibraryTab
        var sort: MusicLibrarySort
        var reversed: Bool
        var filter: MusicLibraryFilterState
        var liked: Int
        var playlists: Int
        var albums: Int
        var artists: Int
        var history: Int
        var local: Int
        var facet: MusicFacetSelection
        var folder: UUID?
        var folders: Int
    }

    private var trigger: Trigger {
        Trigger(tab: activeTab, sort: sort, reversed: reversed, filter: filter, liked: hub.library.likedRevision,
                playlists: hub.library.playlistsRevision, albums: hub.library.albumsRevision, artists: hub.library.followedRevision,
                history: activeTab == .history || sort == .recentlyPlayed || sort == .mostPlayed ? hub.library.historyRevision : 0, local: localTracks?.count ?? -1,
                facet: facetSel, folder: folderSel, folders: activeTab == .playlists ? hub.library.playlistFolders.revision : 0)
    }

    var body: some View {
        MusicOverlayHostView(hub: hub) {
            MusicPageColumn(spacing: MusicSpace.md, memoryKey: scrollKey) {
                header
                if setupOffer == .quietCard { MusicSetupCard(open: { MusicChromeState.shared.setupOpen = true }, dismiss: { setupCardDismissed = true }) }
                if let note { Text(verbatim: note).musicText(.caption).foregroundStyle(ColorTokens.textSecondary) }
                if sources.count > 1, !standalone { sourceSwitcher }
                if resolvedSource == .local {
                    if !standalone {
                        MusicLibraryTabBar(tabs: tabs, selection: tabBinding, style: tabStyle, counts: [:]) { hub.nav.select(.downloads) }
                        MusicLibraryQuickLinks(active: nil) { quickLink($0) }
                    }
                    controlsAndContent
                } else {
                    MusicAccountLibraryTab(hub: hub, source: resolvedSource)
                }
            }
            .id(scrollKey)
        }
        .task { if let p = hub.registry.provider(id: "spotify") { spotifySignedIn = await p.isSignedIn } }
        .onChange(of: hub.libraryTabRequest?.tab) { _, _ in takeTabRequest() }
        .onAppear { takeTabRequest() }
        .onChange(of: hub.libraryResetToken) { _, _ in standalone = false }
        .onChange(of: standaloneTab, initial: true) { _, t in hub.standaloneLibraryTab = t }          // the sidebar lights that shortcut
        .task(id: trigger) { refresh() }
        .task(id: [.local, .albums, .artists].contains(activeTab)) { await loadLocal() }
        .onChange(of: filter) { _, f in prefs.setFilter(f, for: activeTab) }
        .onChange(of: facetSel) { _, f in MusicFacetSession.set(f, for: activeTab.rawValue) }
        .fileExporter(isPresented: $exporting, document: backupDoc, contentType: .json, defaultFilename: "Music backup") { r in
            if case .failure = r { note = Localized.string("The backup could not be saved.") } else { note = Localized.string("Backup saved.") }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { r in importBackup(r) }
        .sheet(isPresented: $showImport) {
            MusicImportPage(hub: hub, onClose: { showImport = false }).frame(minWidth: 560, minHeight: 520).atlasScreen("screen.music.import")
        }
        .alert("New playlist", isPresented: $creating) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}.atlas("control.music.yourLibraryCancel")
            Button("Create") { let n = newName.trimmingCharacters(in: .whitespacesAndNewlines); if !n.isEmpty { _ = hub.library.createPlaylist(name: n, tracks: []) } }.atlas("control.music.yourLibraryCreate")
        }
    }

    private var scrollKey: String { resolvedSource == .local ? activeTab.scrollKey : "library:account:" + resolvedSource.id }

    private var tabBinding: Binding<MusicLibraryTab> {
        Binding(get: { activeTab }, set: { switchTab($0) })
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: MusicSpace.sm) {
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                if standalone {
                    Button { standalone = false } label: { Label(Localized.string("Your library"), systemImage: "chevron.left").font(Typography.captionMedium) }
                        .buttonStyle(.plain).foregroundStyle(accent).accessibilityLabel("Back to your library").atlas("control.music.libraryPageBack")
                    Text(verbatim: activeTab.title).font(Typography.pageTitle).accessibilityAddTraits(.isHeader)
                } else {
                    Text("Your library").font(Typography.pageTitle).accessibilityAddTraits(.isHeader)
                }
                Text(verbatim: countText).musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
            }
            Spacer(minLength: MusicSpace.sm)
            if resolvedSource == .local {
                // Combine looks through the people and films this app has seen in your own listening, so it belongs here with your music, not on Explore (which is the same for everyone).
                Button { showCombine = true } label: { Label(Localized.string("Combine"), systemImage: "line.3.horizontal.decrease.circle") }
                    .musicButton(.secondary, size: .compact).accessibilityLabel(Localized.string("Find songs by combining people, language and decade")).atlas("control.music.libraryCombine")
                    .sheet(isPresented: $showCombine) { MusicCombineSheet(hub: hub) { showCombine = false } }
                MusicLibraryViewControls(tab: activeTab, mode: mode, sort: sort, reversed: reversed, onMode: setMode, onSort: setSort)
                MusicLibraryMoreMenu(onImportMusic: { showImport = true }, onNewPlaylist: { newName = ""; creating = true },
                                     onExport: { backupDoc = MusicBackupDocument(data: hub.library.exportJSON()); exporting = true },
                                     onImportBackup: { importing = true }, onNeverPlay: { hub.open(.blacklist) })
            }
        }
        .background(GeometryReader { g in
            Color.clear.onAppear { contentWidth = g.size.width }.onChange(of: g.size.width) { _, w in contentWidth = w }
        })
    }

    private var countText: String {
        guard resolvedSource == .local else { return Localized.string("Connected library") }
        let m = activeModel
        if m.total == 0 && !m.ready { return Localized.string("Saved on this Mac. No account needed.") }
        return MusicLibraryCountLine.line(activeTab, shown: m.shown, total: m.total, filtered: filter.isActive || facetSel.isActive || folderSel != nil)
    }

    private var sourceSwitcher: some View {
        HStack(spacing: MusicSpace.xxs) {
            ForEach(sources) { s in MusicChip(title: Localized.string(s.title), selected: s == resolvedSource) { source = s } }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Library source")
    }

    // MARK: models by tab

    /// What the header and the content need to know about the tab on screen, whatever its element type.
    private struct ModelFacts { var shown: Int; var total: Int; var ready: Bool; var working: Bool; var providers: [(id: String, count: Int)] }

    private var activeModel: ModelFacts {
        func facts<T>(_ m: MusicLibraryListModel<T>) -> ModelFacts { ModelFacts(shown: m.shown.count, total: m.total, ready: m.hasResult, working: m.isWorking, providers: m.providers) }
        switch activeTab {
        case .songs: return facts(models.songs)
        case .albums: return facts(models.albums)
        case .artists: return facts(models.artists)
        case .playlists: return facts(models.playlists)
        case .podcasts: return facts(models.podcasts)
        case .history: return facts(models.history)
        case .local: return facts(models.local)
        }
    }

    private var mode: MusicLibraryViewMode { MusicLibraryModeRules.effective(saved: savedMode, tab: activeTab, count: activeModel.total) }

    /// How many items the tab's source holds, before any filter. Zero means the empty state with its ways to fill it.
    private var sourceCount: Int {
        switch activeTab {
        case .songs: hub.library.liked.count
        case .albums: derivedAlbums.albums.count
        case .artists: derivedArtists.artists.count
        case .playlists: hub.library.playlists.count
        case .podcasts: hub.library.liked.lazy.filter { $0.isPodcast == true }.count
        case .history: hub.library.history.count
        case .local: localTracks?.count ?? 0
        }
    }

    // MARK: content

    @ViewBuilder private var controlsAndContent: some View {
        let facts = activeModel
        if sourceCount == 0 && !(activeTab == .local && localTracks == nil) {
            MusicLibraryEmptyView(tab: activeTab, perform: perform).padding(.top, MusicSpace.md)
        } else {
            toolbar(facts)
            if activeTab == .playlists {
                MusicLibraryPlaylistFolderBar(hub: hub, selected: $folderSel)
                MusicLibraryPlaylistToolsBar(hub: hub)
            }
            if !(activeTab == .local && localFolders) {
                MusicLibraryFacetRows(facets: facets, selection: $facetSel, narrow: tabStyle == .menu)
            }
            MusicLibraryChips(tab: activeTab, filter: $filter, sort: sort, reversed: reversed, hub: hub, onResetSort: { setSort(activeTab.defaultSort, false) })
            if !facts.ready { MusicLibrarySkeleton(mode: mode) }
            else if facts.shown == 0 {
                MusicEmptyState(glyph: .emptySearch, title: Localized.string("Nothing matches"), message: Localized.string("No items in this tab match the filter."),
                                actionTitle: Localized.string("Clear filters")) { filter = MusicLibraryFilterState(); facetSel = MusicFacetSelection(); folderSel = nil }
                    .frame(minHeight: MusicSpace.huge * 5)
            } else { tabContent }
        }
    }

    @ViewBuilder private func toolbar(_ facts: ModelFacts) -> some View {
        let tracks = songsShown
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MusicSpace.sm) {
                MusicLibraryFilterBar(tab: activeTab, filter: $filter, providers: facts.providers, hub: hub)
                Spacer(minLength: MusicSpace.xs)
                actions(tracks)
            }
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                MusicLibraryFilterBar(tab: activeTab, filter: $filter, providers: facts.providers, hub: hub)
                actions(tracks)
            }
        }
    }

    @ViewBuilder private func actions(_ tracks: [MusicTrack]) -> some View {
        HStack(spacing: MusicSpace.xs) {
            if activeTab == .playlists {
                Button { newName = ""; creating = true } label: { Label("New playlist", systemImage: "plus") }
                    .musicButton(.secondary, size: .compact).accessibilityLabel("Create a playlist").atlas("control.music.yourLibraryCreateAPlaylist")
            }
            if activeTab == .local {
                Button { localFolders.toggle(); let on = localFolders; MusicDebugLog.log("library", "local files view: \(on ? "folders" : "all files")") } label: {
                    Label(localFolders ? Localized.string("All files") : Localized.string("Folders"), systemImage: localFolders ? "music.note.list" : "folder")
                }
                .musicButton(.tertiary, size: .compact).accessibilityLabel(localFolders ? Localized.string("Show all files") : Localized.string("Browse by folder")).atlas("control.music.libraryLocalFolders")
            }
            if activeTab.holdsSongs {
                MusicLibrarySongActions(hub: hub, tracks: tracks, selecting: $selecting, canSelect: activeTab != .history && mode != .grid)
            }
        }
    }

    /// The songs of the tab on screen, in the order shown, for Play, Shuffle and the queue.
    private var songsShown: [MusicTrack] {
        switch activeTab {
        case .songs: models.songs.shown
        case .podcasts: models.podcasts.shown
        case .local: models.local.shown
        case .history: models.history.shown.map(\.track)
        default: []
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch activeTab {
        case .songs: songList(models.songs.shown, owner: "library:songs", removable: true, removeLabel: Localized.string("Remove from Liked Songs"))
        case .podcasts: songList(models.podcasts.shown, owner: "library:podcasts", removable: true, removeLabel: Localized.string("Remove from Liked Songs"))
        case .local:
            if localFolders { MusicLibraryLocalFolderView(hub: hub, tracks: localTracks ?? []) }
            else { songList(models.local.shown, owner: "library:local", removable: false, removeLabel: "") }
        case .albums:
            MusicLibraryCollection(items: models.albums.shown, idPath: \.uid, mode: mode, owner: "library:albums", artworkClass: .tile, thumbs: { $0.thumbnails },
                                   card: { MusicCard(album: $0, hub: hub) },
                                   row: { a, compact in
                                       MusicLibraryEntityRow(title: a.title, subtitle: MusicHeroText.cardCredit(a.artists),
                                                             trailing: a.releaseDate.map { String($0.prefix(4)) } ?? "", thumbs: a.thumbnails, compact: compact,
                                                             entity: .album(a), hub: hub) { hub.open(.album(a)) }
                                   })
        case .artists:
            MusicFavoriteArtistsShelf(hub: hub)
            MusicLibraryCollection(items: models.artists.shown, idPath: \.uid, mode: mode, owner: "library:artists", artworkClass: .artistPortrait, thumbs: { $0.thumbnails },
                                   card: { MusicCard(artist: $0, hub: hub) },
                                   row: { a, compact in
                                       MusicLibraryEntityRow(title: a.name, subtitle: Localized.string("Artist"), thumbs: a.thumbnails, round: true, compact: compact,
                                                             entity: .artist(a), hub: hub) { hub.open(.artist(a)) }
                                   })
        case .playlists:
            MusicSmartPlaylistsShelf(hub: hub)
            MusicLibraryCollection(items: models.playlists.shown, idPath: \.id.uuidString, mode: mode, owner: "library:playlists", artworkClass: .playlistCover,
                                   thumbs: { $0.tracks.first?.thumbnails ?? [] },
                                   card: { p in
                                       MusicCard(title: p.name, subtitle: Localized.string("%d songs", p.tracks.count), thumbs: p.tracks.first?.thumbnails ?? [], round: false,
                                                 entity: playlistEntity(p), hub: hub,
                                                 coverOverride: AnyView(MusicPlaylistCoverArt(members: p.tracks.prefix(MusicPlaylistCoverPlan.scanLimit).map(\.thumbnails), name: p.name))) { hub.open(.localPlaylist(p.id)) }
                                   },
                                   row: { p, compact in
                                       MusicLibraryEntityRow(title: p.name, trailing: Localized.string("%d songs", p.tracks.count), thumbs: p.tracks.first?.thumbnails ?? [],
                                                             compact: compact, entity: playlistEntity(p), members: p.tracks.prefix(MusicPlaylistCoverPlan.scanLimit).map(\.thumbnails), hub: hub) { hub.open(.localPlaylist(p.id)) }
                                   })
        case .history:
            MusicLibraryHistoryList(records: models.history.shown, mode: mode, groupByDay: sort == .recentlyPlayed && !reversed, hub: hub)
        }
    }

    private func playlistEntity(_ p: LocalPlaylist) -> MusicEntity {
        .playlist(MusicPlaylist(id: p.id.uuidString, providerID: MusicStatsRules.localProviderID, name: p.name, trackCount: p.tracks.count))
    }

    @ViewBuilder private func songList(_ tracks: [MusicTrack], owner: String, removable: Bool, removeLabel: String) -> some View {
        if mode == .grid {
            MusicLibraryCollection(items: tracks, idPath: \.uid, mode: .grid, owner: owner, artworkClass: .tile, thumbs: { $0.thumbnails },
                                   card: { MusicCard(track: $0, queue: tracks, hub: hub) }, row: { _, _ in EmptyView() })
        } else {
            MusicTrackList(hub: hub, tracks: tracks, listKey: nil, showsTools: false, numbered: true, canSort: false,
                           onRemove: removable ? { picked in removeLiked(picked) } : nil, presorted: true,
                           rowStyle: mode == .compact ? .compact : (mode == .table ? .table : .standard), selecting: $selecting,
                           removeLabel: removeLabel, prefetchOwner: owner, trailingDetail: playDetail)
        }
    }

    /// The play count at the end of a row, only while the list is in the Most played order.
    private var playDetail: ((MusicTrack) -> String?)? {
        guard sort == .mostPlayed, activeTab == .songs || activeTab == .local else { return nil }
        let counts = playCounts
        return { t in
            let n = counts[t.uid] ?? 0
            return n > 0 ? Localized.plural(n, one: "%@ play", other: "%@ plays") : nil
        }
    }

    private func quickLink(_ l: MusicLibraryQuickLink) {
        switch l.destination {
        case .songs(let s):
            switchTab(.songs)
            facetSel = MusicFacetSelection(); filter = MusicLibraryFilterState()
            setSort(s, false)
        case .collection(let k): hub.open(collection: k)
        case .recentlyAdded: hub.nav.select(.recentlyAdded); hub.recentlyAddedLeadsWithLibrary = hub.nav.section == .recentlyAdded        // the Recently Added section of Music: only what the person chose
        }
    }

    private func removeLiked(_ picked: [MusicTrack]) {
        let uids = Set(picked.map(\.uid))
        for t in hub.library.liked where uids.contains(t.uid) { hub.library.toggleLike(t) }
    }

    // MARK: actions

    private func takeTabRequest() {
        guard let r = hub.libraryTabRequest else { return }
        hub.libraryTabRequest = nil
        source = .local
        standalone = r.standalone
        switchTab(r.tab)
    }

    private func switchTab(_ t: MusicLibraryTab) {
        guard t != activeTab else { return }
        selecting = false
        prefs.tab = t
        tab = t
        sort = prefs.sort(t); reversed = prefs.reversed(t); filter = prefs.filter(t); savedMode = prefs.mode(t)
        facets = MusicFacetSet(); facetSel = MusicFacetSession.selection(t.rawValue)
    }

    private func setMode(_ m: MusicLibraryViewMode) { savedMode = m; prefs.setMode(m, for: activeTab) }

    private func setSort(_ s: MusicLibrarySort, _ r: Bool) {
        sort = s; reversed = r
        prefs.setSort(s, reversed: r, for: activeTab)
        let tabName = activeTab.rawValue, sortName = s.rawValue
        MusicDebugLog.log("library", "sort \(tabName): \(sortName)\(r ? " reversed" : "")")
    }

    private func perform(_ a: MusicLibraryEmptyAction) {
        switch a.destination {
        case .section(let s): hub.nav.select(s)
        case .settings(let t): MusicChromeState.shared.openSettings(t)
        case .newPlaylistPrompt: newName = ""; creating = true
        case .importSheet: showImport = true
        }
    }

    private func loadLocal() async {
        guard [.local, .albums, .artists].contains(activeTab), localTracks == nil else { return }
        let p = (hub.registry.provider(id: MusicStatsRules.localProviderID) as? LocalFilesProvider) ?? LocalFilesProvider()
        let all = await p.allTracks()
        if !Task.isCancelled { localTracks = all }
    }

    /// Builds the genre and language facets of a tab's source list (once per change of the list), drops a stored choice that no longer exists, and returns
    /// the list the choice leaves plus a tag for the model's signature.
    private func faceted<T>(_ items: [T], tab: MusicLibraryTab, sig: String, build: ([T]) -> MusicFacetSet,
                            filter: ([T], MusicFacetSelection) -> [T]) -> (items: [T], tag: String) {
        let set: MusicFacetSet
        if let m = facetMemo[tab.rawValue], m.key == sig { set = m.set }
        else {
            set = build(items)
            facetMemo[tab.rawValue] = (sig, set)
            let name = tab.rawValue, total = items.count, g = set.genres.count, l = set.languages.count
            MusicDebugLog.log("library", "facets \(name): \(total) items, \(g) genres, \(l) languages")
        }
        if facets != set { facets = set }
        let sel = set.valid(facetSel)
        if sel != facetSel { facetSel = sel }
        guard sel.isActive else { return (items, "") }
        let out = filter(items, sel)
        let name = tab.rawValue, kept = out.count, total = items.count
        MusicDebugLog.log("library", "facet filter \(name): \(kept) of \(total)")
        return (out, "|f\(sel.genre ?? "")|\(sel.language ?? "")")
    }

    /// Hands the tab's source list and the current sort and filter to its model. The work runs off the main actor; the list on screen stays until
    /// the new one is ready.
    /// The songs played long enough to count (the rule the rest of Music uses), podcasts left out.
    private static func countedPlays(_ history: [PlayRecord]) -> [MusicTrack] {
        history.filter { HomeTaste.counts($0) && !($0.track.isPodcast ?? false) }.map(\.track)
    }

    private func refresh() {
        let t = activeTab
        let req = MusicLibraryRequest(sort: sort, reversed: reversed, filter: filter)
        let liked = hub.library.liked
        let podcastsExist = liked.contains { $0.isPodcast == true }
        if podcastsExist != hasPodcasts { hasPodcasts = podcastsExist }
        let needsPlays = sort == .recentlyPlayed || sort == .mostPlayed
        let plays = needsPlays ? "|h\(hub.library.historyRevision)" : ""
        if sort == .mostPlayed, t == .songs || t == .local { playCounts = MusicLibraryEngine.playCounts(hub.library.history) }
        else if !playCounts.isEmpty { playCounts = [:] }
        if ![.songs, .local, .albums, .artists].contains(t), !facets.isEmpty { facets = MusicFacetSet() }
        switch t {
        case .songs:
            let sig = "r\(hub.library.likedRevision)"
            let f = faceted(liked, tab: t, sig: sig, build: { MusicLibraryFacets.build(tracks: $0) }, filter: { MusicLibraryFacets.filter($0, $1) })
            models.songs.apply(items: f.items, signature: sig + f.tag + plays, request: req, history: hub.library.history)
        case .podcasts:
            let eps = liked.filter { $0.isPodcast == true }
            models.podcasts.apply(items: eps, signature: "r\(hub.library.likedRevision)" + plays, request: req, history: hub.library.history)
        case .local:
            if let l = localTracks {
                let sig = MusicLibrarySignature.make(l, id: \.uid)
                let f = faceted(l, tab: t, sig: sig, build: { MusicLibraryFacets.build(tracks: $0) }, filter: { MusicLibraryFacets.filter($0, $1) })
                models.local.apply(items: f.items, signature: sig + f.tag + plays, request: req, history: hub.library.history)
            }
        case .albums:
            let songs = liked.filter { $0.isPodcast != true } + (localTracks ?? [])
            let d = MusicLibraryDerived.albums(saved: hub.library.savedAlbums, songs: songs, played: Self.countedPlays(hub.library.history))
            if d != derivedAlbums { derivedAlbums = d }
            let a = d.albums
            let sig = "r\(hub.library.albumsRevision)|l\(hub.library.likedRevision)|h\(hub.library.historyRevision)|f\(localTracks?.count ?? -1)"
            let f = faceted(a, tab: t, sig: sig, build: { MusicLibraryFacets.build(albums: $0) }, filter: { MusicLibraryFacets.filter($0, $1) })
            models.albums.apply(items: f.items, signature: sig + f.tag, request: req)
        case .artists:
            let songs = liked.filter { $0.isPodcast != true } + (localTracks ?? [])
            let d = MusicLibraryDerived.artists(followed: hub.library.followedArtists, songs: songs, played: Self.countedPlays(hub.library.history))
            if d != derivedArtists { derivedArtists = d }
            let a = d.artists
            let sig = "r\(hub.library.followedRevision)|l\(hub.library.likedRevision)|h\(hub.library.historyRevision)|f\(localTracks?.count ?? -1)"
            let f = faceted(a, tab: t, sig: sig, build: { MusicLibraryFacets.build(artists: $0) }, filter: { MusicLibraryFacets.filter($0, $1) })
            models.artists.apply(items: f.items, signature: sig + f.tag, request: req)
        case .playlists:
            let all = hub.library.playlists
            let book = hub.library.playlistFolders
            book.prune(existing: Set(all.map(\.id)))
            if let id = folderSel, !book.folders.contains(where: { $0.id == id }) { folderSel = nil }
            let p = MusicPlaylistFolderRules.playlists(all, in: folderSel, folders: book.folders)
            models.playlists.apply(items: p, signature: "r\(hub.library.playlistsRevision)|d\(folderSel?.uuidString ?? "")|v\(book.revision)", request: req)
        case .history:
            let h = hub.library.history
            models.history.apply(items: h, signature: "r\(hub.library.historyRevision)", request: req)
        }
    }

    private func importBackup(_ r: Result<URL, Error>) {
        guard case .success(let url) = r else { note = Localized.string("The file could not be opened."); return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let r = try hub.library.importJSON(try Data(contentsOf: url))
            let n = r.likedAdded + r.playlistsAdded + r.playlistTracksAdded + r.historyAdded + r.artistsAdded + r.albumsAdded + r.blacklistAdded
            note = n == 0 ? Localized.string("Nothing new in that backup.") : Localized.string("Added %d items from the backup.", n)
        } catch { note = Localized.string("That file is not a music backup.") }
    }
}
