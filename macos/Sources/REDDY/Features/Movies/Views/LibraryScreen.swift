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
    private var taskKey: String { "\(selection)-\(state.activeSourceID?.uuidString ?? "")-\(state.catalogVersion)-\(vm.sort.rawValue)" }

    private var showsSlideshow: Bool { kind == .movie && selection == .shortcut(.featured) }
    private var slideshowKey: String { "\(showsSlideshow)-\(state.activeSourceID?.uuidString ?? "")-\(FeaturedPolicy.dayKey(Date()))" }

    /// Page header, slideshow and toolbar are fixed; only the poster grid below them scrolls. The slideshow is not inside any
    /// scroll view, so scrolling can't move it, and the grid is clipped to its own region so posters never draw over it.
    var body: some View {
        GeometryReader { g in
            let layout = PosterGridLayout.compute(available: g.size.width - 2 * LayoutTokens.gutter, minCard: density.posterRange.min, maxCard: density.posterRange.max)
            VStack(alignment: .leading, spacing: 10) {
                PageHead(title: title)
                if showsSlideshow, !slides.isEmpty {
                    FeaturedSlideshow(slides: slides, kicker: "FEATURED · FROM YOUR LIBRARY",
                                      height: FeaturedLayout.bannerHeight(contentHeight: g.size.height),
                                      onPlay: { play($0.item) }, onInfo: { open($0.item) })
                }
                LibraryToolbar(search: $vm.search, prompt: "Search all \(vm.noun)…", count: vm.countText, focusToken: router.focusSearch) {
                    SortMenu(options: vm.availableSorts, selection: $vm.sort) { $0.rawValue }
                }
                ScrollView {
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
        .task(id: taskKey) { if let c = container { await vm.reset(c, selection: selection, source: state.activeSourceID) } }
        // The slideshow depends on the playlist and the day only, so a catalog refresh or a sort change never rebuilds it.
        .task(id: slideshowKey) {
            guard showsSlideshow, let c = container else { slides = []; return }
            let built = await c.featured.movieSlides(sourceID: state.activeSourceID)
            if !built.isEmpty || slides.isEmpty { slides = built }
        }
        .onChange(of: vm.search) { _, _ in if let c = container { vm.scheduleSearch(c, selection: selection, source: state.activeSourceID) } }
    }

    @ViewBuilder private func content(_ layout: PosterGridLayout.Result) -> some View {
        if state.activeSource == nil {
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
                    ReddyPosterCard(model: PosterCardModel(item: item, progress: vm.progress[item.id], isFavorite: state.isFavorite(item.id)), width: layout.cardWidth,
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
    private var emptySymbol: String { selection == .shortcut(.favorites) ? "heart" : selection == .shortcut(.continueWatching) ? "play.circle" : "film" }
    private var emptyTitle: String {
        if !vm.search.isEmpty { return "No matches" }
        switch selection { case .shortcut(.favorites): return "No favorites yet"; case .shortcut(.continueWatching): return "Nothing to continue"; default: return "No \(vm.noun) here" }
    }
    private var emptyMessage: String {
        if !vm.search.isEmpty { return "Nothing matches “\(vm.search)”." }
        switch selection {
        case .shortcut(.favorites): return "Save a title from its details to find it here."
        case .shortcut(.continueWatching): return kind == .movie ? "Movies you start but don't finish appear here." : "Series you're partway through appear here."
        default: return "This folder is empty, or the playlist hasn't finished updating."
        }
    }

    // MARK: actions

    private func play(_ item: LibraryItem) { if let c = container { PlayActions(container: c, toasts: state.toasts).play(item) } }
    private func open(_ item: LibraryItem) { switch item { case .movie(let m): router.open(movie: m); case .series(let s): router.open(series: s) } }

    @ViewBuilder private func menu(_ item: LibraryItem) -> some View {
        Button("Play") { play(item) }
        Button("View details") { open(item) }
        Button(state.isFavorite(item.id) ? "Remove from Favorites" : "Add to Favorites") { state.toggleFavorite(item.id, kind: item.kind) }
        CollectionMenu(itemID: item.id, kind: item.kind)
        Divider()
        Button("Hide") { try? container?.favoritesRepo.hide(item.id, kind: item.kind.rawValue); state.catalogVersion += 1 }
    }
}
