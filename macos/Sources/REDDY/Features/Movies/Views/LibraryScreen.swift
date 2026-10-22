import SwiftUI

/// Movies and Series. The sidebar selection decides what is listed; sorting and search sit under any banner.
struct LibraryScreen: View {
    let kind: ContentKind
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(AppRouter.self) private var router
    @Environment(AppSettings.self) private var settings
    @Environment(\.reddyDensity) private var density
    @State private var appliedDefaultSort = false
    @State private var vm: LibraryBrowserViewModel
    @State private var slides: [FeaturedSlide] = []

    init(kind: ContentKind) { self.kind = kind; _vm = State(initialValue: LibraryBrowserViewModel(kind: kind)) }

    private var selection: SidebarSelection { router.selection }
    private var taskKey: String { "\(selection)-\(state.activeSourceID?.uuidString ?? "")-\(state.catalogVersion)-\(vm.sort.rawValue)-\(String(describing: vm.filter))" }

    private var showsSlideshow: Bool { kind == .movie && selection == .shortcut(.featured) }
    private var slideshowKey: String { "\(showsSlideshow)-\(state.activeSourceID?.uuidString ?? "")-\(FeaturedPolicy.dayKey(Date()))-\(container?.parental.isRestricting == true ? "locked" : "open")" }

    /// The page header and the toolbar stay put. The slideshow is the first thing in the scrolling region, so it scrolls up and out of the way with the posters;
    /// the region is clipped, so nothing draws over the header or the toolbar.
    var body: some View {
        GeometryReader { g in
            let layout = PosterGridLayout.compute(available: g.size.width - 2 * LayoutTokens.gutter, minCard: density.posterRange.min, maxCard: density.posterRange.max)
            VStack(alignment: .leading, spacing: 10) {
                PageHead(title: title)
                LibraryToolbar(search: $vm.search, prompt: "Search all \(vm.noun)…", count: vm.countText, focusToken: router.focusSearch) {
                    SortMenu(options: vm.availableSorts, selection: $vm.sort, filterCount: vm.filter.count) { $0.rawValue } extra: {
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
                    content(layout).padding(.bottom, 16).frame(maxWidth: .infinity, alignment: .leading)
                        .animation(AnimationTokens.page, value: vm.loading)
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: .infinity)
                .clipped()
            }
            .padding(.horizontal, LayoutTokens.gutter).padding(.top, 10)
        }
        .onAppear { if !appliedDefaultSort { appliedDefaultSort = true; vm.sort = settings.defaultLibrarySort.sort } }
        .onAppear { state.reloadWatched(); takeLibraryQuery() }
        .onChange(of: router.libraryQuery) { _, _ in takeLibraryQuery() }
        .task(id: taskKey) { if let c = container { await vm.reset(c, selection: selection, source: state.activeSourceID) } }
        // The slideshow depends on the playlist and the day only, so a catalog refresh or a sort change never rebuilds it.
        .task(id: slideshowKey) {
            guard showsSlideshow, let c = container else { slides = []; return }
            let built = await c.featured.movieSlides(sourceID: state.activeSourceID, restricted: c.parental.isRestricting)
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
                ForEach(vm.items) { item in
                    ReddyPosterCard(model: noted(PosterCardModel(item: item, progress: vm.progress[item.id] ?? state.partialProgress(item.id), isFavorite: state.isFavorite(item.id), isNew: state.hasNewEpisodes(item.id), isWatched: state.isWatched(item.id)), item.id), width: layout.cardWidth,
                                    onOpen: { open(item) }, onPlay: { play(item) })
                        .contextMenu { menu(item) }
                        .task { if let c = container { await vm.loadMoreIfNeeded(c, current: item, selection: selection, source: state.activeSourceID) } }
                }
            }
            if vm.loading { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 10) }
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

    @ViewBuilder private func menu(_ item: LibraryItem) -> some View {
        Button("Play") { play(item) }
        Button("Watch Privately", systemImage: "eye.slash") { play(item, privately: true) }
        Button("View details") { open(item) }
        Button(state.isFavorite(item.id) ? "Remove from Favorites" : "Add to Favorites") { state.toggleFavorite(item.id, kind: item.kind) }
        Button(state.isWatchLater(item.id) ? "Remove from Watch Later" : "Add to Watch Later") { state.toggleWatchLater(item.id, kind: item.kind); if selection == .shortcut(.watchLater) { Task { await vm.reset(container!, selection: selection, source: state.activeSourceID) } } }
        QueueMenu(item: item)
        FavoriteOrderMenu(item: item)
        CollectionMenu(itemID: item.id, kind: item.kind)
        Divider()
        Button("Hide") { try? container?.favoritesRepo.hide(item.id, kind: item.kind.rawValue); state.catalogVersion += 1 }
    }

    /// A command typed in the top search put words for this list's own search box: they are used once, so the filters and ordering in them apply here.
    private func takeLibraryQuery() {
        guard let q = router.libraryQuery else { return }
        router.libraryQuery = nil
        vm.search = q
        if let c = container { vm.scheduleSearch(c, selection: selection, source: state.activeSourceID) }
    }
}
