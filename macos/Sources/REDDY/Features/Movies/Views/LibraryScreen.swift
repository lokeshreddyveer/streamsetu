import SwiftUI

/// Movies and Series. Finds the model kept for this profile and playlist (so filter, search, sort, loaded pages and scroll place survive a tab switch) and shows it.
struct LibraryScreen: View {
    let kind: ContentKind
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state

    var body: some View {
        if let c = container {
            LibraryScreenContent(kind: kind, vm: c.screens.model(ScreenKey(screen: .library(kind), profile: c.profiles.activeID, source: state.activeSourceID), revision: c.parental.restrictionRevision) { LibraryBrowserViewModel(kind: kind) })
        } else {
            LibraryScreenContent(kind: kind, vm: LibraryBrowserViewModel(kind: kind))
        }
    }
}

private struct LibraryScreenContent: View {
    let kind: ContentKind
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(AppRouter.self) private var router
    @Environment(AppSettings.self) private var settings
    @Environment(\.reddyDensity) private var density
    @Bindable var vm: LibraryBrowserViewModel
    @State private var slides: [FeaturedSlide] = []
    @State private var viewMode: FolderViewMode = .folders
    @State private var topRow: String?

    init(kind: ContentKind, vm: LibraryBrowserViewModel) { self.kind = kind; self.vm = vm }

    private var selection: SidebarSelection { router.selection }
    private var taskKey: String { "\(vm.uid)-\(selection)-\(state.activeSourceID?.uuidString ?? "")-\(state.catalogVersion)-\(vm.sort.rawValue)-\(String(describing: vm.filter))" }

    /// Folders is the default view of the full Movies / Series lists; a search or a filter always shows the grid, and so do the shortcut lists (favourites, unwatched, and so on).
    private var showsFolders: Bool {
        guard viewMode == .folders, vm.search.isEmpty, vm.filter.count == 0 else { return false }
        return selection == .shortcut(.allMovies) || selection == .shortcut(.featured) || selection == .shortcut(.library)
    }
    private var showsModeSwitch: Bool { selection == .shortcut(.allMovies) || selection == .shortcut(.featured) || selection == .shortcut(.library) }
    /// The kept model of the folder rows for this profile and playlist (their tiles and place are not read again on a return).
    private var folderModel: FolderRowsModel? {
        guard let c = container else { return nil }
        return c.screens.model(ScreenKey(screen: .folders(kind), profile: c.profiles.activeID, source: state.activeSourceID), revision: c.parental.restrictionRevision) { FolderRowsModel(kind: kind) }
    }
    private var syncStamp: Double { state.sources.filter { state.activeSourceID == nil || $0.id == state.activeSourceID }.compactMap { $0.lastSync?.timeIntervalSince1970 }.max() ?? 0 }
    private var profileID: String { container?.profiles.activeID ?? "main" }

    private var showsSlideshow: Bool { kind == .movie && selection == .shortcut(.featured) }
    private var slideshowKey: String { "\(showsSlideshow)-\(state.activeSourceID?.uuidString ?? "")-\(FeaturedPolicy.dayKey(Date()))-\(container?.parental.restrictionRevision ?? 0)" }

    /// The page header and the toolbar stay put. The slideshow is the first thing in the scrolling region, so it scrolls up and out of the way with the posters;
    /// the region is clipped, so nothing draws over the header or the toolbar.
    var body: some View {
        GeometryReader { g in
            let layout = PosterGridLayout.compute(available: g.size.width - 2 * LayoutTokens.gutter, minCard: density.posterRange.min, maxCard: density.posterRange.max)
            VStack(alignment: .leading, spacing: 10) {
                PageHead(title: title)
                LibraryToolbar(search: $vm.search, prompt: "Search all \(vm.noun)…", count: vm.countText, focusToken: router.focusSearch) {
                    if showsModeSwitch {
                        Picker("View", selection: Binding(get: { viewMode }, set: { viewMode = $0; FolderViewMode.save($0, kind, profile: profileID) })) {
                            Label("Folders", systemImage: "folder").tag(FolderViewMode.folders); Label("Grid", systemImage: "square.grid.2x2").tag(FolderViewMode.grid)
                        }.pickerStyle(.segmented).labelsHidden().fixedSize().accessibilityLabel("Folders or grid").atlas("control.library.viewMode")
                    }
                    SortMenu(options: vm.availableSorts, selection: Binding(get: { vm.sort }, set: { newSort in
                        // Folder rows keep each folder's own order, so choosing a sort means choosing the grid, which honours it.
                        if showsFolders, newSort != vm.sort { viewMode = .grid; FolderViewMode.save(.grid, kind, profile: profileID) }
                        vm.sort = newSort
                    }), filterCount: vm.filter.count) { $0.rawValue } extra: {
                        LibraryFilterMenus(kind: kind, filter: $vm.filter, options: vm.filterOptions)
                    }
                }
                ScrollView {
                    if showsSlideshow, !slides.isEmpty {
                        FeaturedSlideshow(slides: slides, kicker: "FEATURED · FROM YOUR LIBRARY",
                                          height: FeaturedLayout.bannerHeight(contentHeight: g.size.height),
                                          onPlay: { play($0.item) }, onInfo: { open($0.item) })
                            .padding(.bottom, 10)
                    }
                    if !vm.understood.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkle.magnifyingglass").font(.system(size: 11)).foregroundStyle(ColorTokens.textSecondary)
                            Text("Understood as").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                            ForEach(vm.understood, id: \.self) { Text($0).font(Typography.caption).padding(.horizontal, 8).padding(.vertical, 3).background(Color.white.opacity(0.08), in: Capsule()) }
                            Spacer()
                        }.padding(.bottom, 8).transition(.opacity)
                    }
                    if showsFolders, state.hasLibrary {
                        let fm = folderModel
                        FolderRowsSection(kind: kind, memoryKey: "\(kind.rawValue)-\(profileID)", topRow: $topRow, model: fm).id(fm?.uid ?? 0).padding(.bottom, 16).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        content(layout).padding(.bottom, 16).frame(maxWidth: .infinity, alignment: .leading)
                            .animation(AnimationTokens.page, value: vm.loading)
                    }
                }
                .scrollPosition(id: $topRow, anchor: .top)
                .scrollIndicators(.hidden)
                .frame(maxHeight: .infinity)
                .clipped()
            }
            .padding(.horizontal, LayoutTokens.gutter).padding(.top, 10)
        }
        .onAppear { viewMode = FolderViewMode.load(kind, profile: profileID) }
        .onChange(of: profileID) { _, _ in viewMode = FolderViewMode.load(kind, profile: profileID); topRow = nil }
        .onChange(of: showsFolders) { _, on in if !on { topRow = nil } }          // the grid must not inherit a folder row as its scroll position; the row is restored from memory on return
        .onAppear { vm.applyDefaultSort(settings.defaultLibrarySort) }
        .onChange(of: settings.defaultLibrarySort) { _, new in vm.applyDefaultSort(new) }
        .onAppear { if !showsFolders, topRow == nil { topRow = vm.scrollAnchor } }          // back on the grid: the title that was at the top is at the top again
        .onChange(of: topRow) { _, id in if !showsFolders, let id { vm.scrollAnchor = id } }
        .onDisappear { vm.trimForRetention() }
        .onAppear { state.reloadWatched(); takeLibraryQuery(); takeLibraryFilter() }
        .onChange(of: router.screenQuery) { _, _ in takeLibraryQuery() }
        .onChange(of: router.libraryFilter) { _, _ in takeLibraryFilter() }
        .task(id: taskKey) {
            guard let c = container else { return }
            // Back on a list that was already read for exactly this state: nothing to do. Lists that change as titles are played or saved are read again.
            if vm.loadedKey == taskKey, !vm.items.isEmpty || vm.total == 0, LibraryBrowserViewModel.isStaticListing(selection, filter: vm.filter, search: vm.search) { return }
            vm.scrollAnchor = nil; if !showsFolders { topRow = nil }          // a list read again starts at its top; an anchor from the old list means nothing
            vm.syncStamp = syncStamp
            await vm.reset(c, selection: selection, source: state.activeSourceID)
            if !Task.isCancelled { vm.loadedKey = taskKey }
        }
        // The slideshow depends on the playlist and the day only, so a catalog refresh or a sort change never rebuilds it.
        .task(id: slideshowKey) {
            guard showsSlideshow, let c = container else { slides = []; return }
            let built = await c.featured.movieSlides(sourceID: state.activeSourceID, restricted: c.parental.isRestricting, revision: c.parental.restrictionRevision)
            if !built.isEmpty || slides.isEmpty { slides = built }
        }
        .onChange(of: vm.search) { _, _ in if let c = container { vm.scheduleSearch(c, selection: selection, source: state.activeSourceID) } }
    }

    @ViewBuilder private func content(_ layout: PosterGridLayout.Result) -> some View {
        if !state.hasLibrary {
            EmptyStateView(symbol: "list.bullet.rectangle", title: "No playlist yet", message: "Add a playlist to start watching.", actionTitle: "Add playlist") { router.modal = .addPlaylist }.frame(height: 280)
        } else if vm.items.isEmpty && vm.loading {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(layout.cardWidth), spacing: 12, alignment: .top), count: layout.columns), alignment: .leading, spacing: 16) {
                ForEach(0..<(layout.columns * 2), id: \.self) { _ in SkeletonBlock(width: layout.cardWidth, height: layout.cardWidth * 1.45, radius: 8) }
            }
        } else if vm.items.isEmpty {
            EmptyStateView(symbol: emptySymbol, title: emptyTitle, message: emptyMessage).frame(height: 260)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(layout.cardWidth), spacing: 12, alignment: .top), count: layout.columns), alignment: .leading, spacing: 16) {
                // The first screenful rises in one after another; titles scrolled to later appear at once.
                ForEach(Array(vm.items.enumerated()), id: \.element.id) { index, item in
                    ReddyPosterCard(model: noted(PosterCardModel(item: item, progress: vm.progress[item.id] ?? state.partialProgress(item.id), isFavorite: state.isFavorite(item.id), isNew: state.hasNewEpisodes(item.id), isWatched: state.isWatched(item.id)), item.id), width: layout.cardWidth,
                                    onOpen: { open(item) }, onPlay: { play(item) })
                        .tileMenu(item, handlers: menuHandlers(item))
                        .task { if let c = container { await vm.loadMoreIfNeeded(c, current: item, selection: selection, source: state.activeSourceID) } }
                        .staggeredAppear(index)
                }
            }
            .scrollTargetLayout()
            if vm.loading { BrandLoader(size: 28).frame(maxWidth: .infinity).padding(.vertical, 10) }
        }
    }

    // MARK: copy

    private var title: String {
        switch selection {
        case .shortcut(let s): s == .library ? "Series" : s.title
        case .folder(let id): state.folderName(id) ?? (kind == .movie ? "Movies" : "Series")
        }
    }
    private var emptySymbol: String { selection == .shortcut(.favorites) ? "heart" : selection == .shortcut(.watchLater) ? "bookmark" : selection == .shortcut(.continueWatching) ? "play.circle" : selection == .shortcut(.unwatched) ? "eye.slash" : selection == .shortcut(.unwatchedFavorites) ? "heart.slash" : selection == .shortcut(.addedThisMonth) ? "calendar.badge.plus" : selection == .shortcut(.newEpisodes) ? "sparkles.tv" : "film" }
    private var emptyTitle: String {
        if !vm.search.isEmpty { return "No matches" }
        switch selection { case .shortcut(.favorites): return "No favorites yet"; case .shortcut(.watchLater): return "Nothing saved for later"; case .shortcut(.continueWatching): return "Nothing to continue"; case .shortcut(.unwatched): return "Everything has been played"; case .shortcut(.unwatchedFavorites): return "No unwatched favorites"; case .shortcut(.addedThisMonth): return "Nothing new this month"; case .shortcut(.newEpisodes): return "No new episodes"; default: return "No \(vm.noun) here" }
    }
    private var emptyMessage: String {
        if !vm.search.isEmpty { return "Nothing matches “\(vm.search)”." }
        switch selection {
        case .shortcut(.favorites): return "Save a title from its details to find it here."
        case .shortcut(.watchLater): return "Tap the bookmark on a title's details to keep it here for later."
        case .shortcut(.continueWatching): return kind == .movie ? "Movies you start but don't finish appear here." : "Series you're partway through appear here."
        case .shortcut(.unwatched): return "Titles you have never played are listed here."
        case .shortcut(.unwatchedFavorites): return "Favorites you have not played yet are listed here."
        case .shortcut(.addedThisMonth): return "Titles your provider added in the last 30 days. A title with no added date is not listed."
        case .shortcut(.newEpisodes): return "When a series you are watching gets a new episode, it is listed here until you play it."
        default: return "This folder is empty, or the playlist hasn't finished updating."
        }
    }

    // MARK: actions

    private func play(_ item: LibraryItem, privately: Bool = false) { if let c = container { PlayActions(container: c, toasts: state.toasts).play(item, privately: privately) } }
    /// While searching, a title found because of somebody in it says who ("Cast: Mahesh Babu") where its year and genre would be.
    private func noted(_ model: PosterCardModel, _ id: String) -> PosterCardModel {
        guard let note = vm.matchNotes[id] else { return model }
        var m = model; m.subtitle = note
        return m
    }

    private func open(_ item: LibraryItem) { switch item { case .movie(let m): router.open(movie: m); case .series(let s): router.open(series: s) } }

    private func menuHandlers(_ item: LibraryItem) -> TileMenuHandlers {
        var h = TileMenuHandlers(play: { play(item) }, playPrivately: { play(item, privately: true) }, open: { open(item) })
        if let cat = item.categoryID { h.openFolder = { router.openFolder(item.isSeries ? .series : .movies, categoryID: cat) } }
        h.goToCast = { CastFocus.request(item.id); open(item) }
        h.changed = { if selection == .shortcut(.watchLater) || selection == .shortcut(.favorites), let c = container { Task { await vm.reset(c, selection: selection, source: state.activeSourceID) } } }
        return h
    }

    /// A genre chosen on Home: the filter is used once, with the best rated first when the list can be ordered that way.
    private func takeLibraryFilter() {
        guard let f = router.libraryFilter else { return }
        router.libraryFilter = nil
        vm.filter = f
        if vm.availableSorts.contains(.topRated) { vm.sort = .topRated }
    }

    /// A command typed in the top search put words for this list's own search box: they are used once, so the filters and ordering in them apply here.
    private func takeLibraryQuery() {
        guard let q = router.takeScreenQuery(for: kind == .movie ? .movies : .series) else { return }
        vm.search = q
        if let c = container { vm.scheduleSearch(c, selection: selection, source: state.activeSourceID) }
    }
}
