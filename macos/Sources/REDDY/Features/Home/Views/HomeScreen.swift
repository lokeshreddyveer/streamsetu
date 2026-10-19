import SwiftUI

/// Home tab: the sidebar shortcut decides which page is shown.
struct HomeScreen: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        switch router.selection {
        case .shortcut(.continueWatching): ContinueWatchingPage()
        case .shortcut(.recentlyWatched): RecentlyWatchedPage()
        case .shortcut(.watchHistory): WatchHistoryPage()
        case .shortcut(.statistics): StatisticsPage()
        case .shortcut(.favorites): FavoritesPage()
        case .shortcut(.watchLater): WatchLaterPage()
        case .shortcut(.collections): CollectionsPage()
        default: DiscoverPage()
        }
    }
}

/// Shared page frame: heading, scrolling body, gutter.
struct PageScroll<Content: View>: View {
    let title: String
    var trailing: AnyView?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) { PageHead(title: title); Spacer(minLength: 12); trailing }
                content
            }
            .padding(.horizontal, LayoutTokens.gutter).padding(.top, 10).padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - Cards used across Home

/// A movie/series poster with the open/play pair and the standard context menu.
struct LibraryItemCard: View {
    let item: LibraryItem
    var rank: Int?
    var progress: Double?
    var width: CGFloat = 150
    /// Adds a "remove from this list" entry to the card's menu (used by the history lists).
    var removal: (title: String, action: () -> Void)?
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(AppRouter.self) private var router

    var body: some View {
        ReddyPosterCard(model: PosterCardModel(item: item, rank: rank, progress: progress ?? state.partialProgress(item.id), isFavorite: state.isFavorite(item.id), isNew: state.hasNewEpisodes(item.id), isWatched: state.isWatched(item.id)), width: width,
                        onOpen: { PlayActions.open(item, router: router) },
                        onPlay: { if let c = container { PlayActions(container: c, toasts: state.toasts).play(item) } })
            .contextMenu {
                Button("Play") { if let c = container { PlayActions(container: c, toasts: state.toasts).play(item) } }
                Button("View details") { PlayActions.open(item, router: router) }
                Button(state.isFavorite(item.id) ? "Remove from Favorites" : "Add to Favorites") { state.toggleFavorite(item.id, kind: item.kind) }
                Button(state.isWatchLater(item.id) ? "Remove from Watch Later" : "Add to Watch Later") { state.toggleWatchLater(item.id, kind: item.kind) }
                QueueMenu(item: item)
                FavoriteOrderMenu(item: item)
                CollectionMenu(itemID: item.id, kind: item.kind)
                if let removal { Divider(); Button(removal.title, role: .destructive, action: removal.action) }
            }
    }
}

/// "Clear" menu shared by the history pages: each entry says exactly what it removes.
struct ClearMenu: View {
    struct Option: Identifiable { let id = UUID(); let title: String; let destructive: Bool; let action: () -> Void
        init(_ title: String, destructive: Bool = false, action: @escaping () -> Void) { self.title = title; self.destructive = destructive; self.action = action } }
    let options: [[Option]]
    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { i, group in
                if i > 0 { Divider() }
                ForEach(group) { o in Button(o.title, role: o.destructive ? .destructive : nil, action: o.action) }
            }
        } label: { Label("Clear", systemImage: "trash") }
        .menuStyle(.button).fixedSize()
    }
}

enum HistoryClearing {
    /// Ids in a playlist start with "<uuid>|", so one prefix scopes a clear to the playlist being viewed.
    static func prefix(_ sourceID: UUID?) -> String? { sourceID.map { $0.uuidString.lowercased() + "|" } }
}

/// Wrapping grid. Poster cards share the width evenly; cards with their own fixed size (`cardWidth`) keep it, and the
/// column count follows the card, so a card is never placed in a column narrower than itself.
struct ItemGrid<Item: Identifiable, Card: View>: View {
    let items: [Item]
    var cardWidth: CGFloat?
    @ViewBuilder let card: (Item, CGFloat) -> Card

    var body: some View {
        if let w = cardWidth {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: w, maximum: w), spacing: 12, alignment: .topLeading)], alignment: .leading, spacing: 12) {
                ForEach(items) { card($0, w) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else { FlexGrid(items: items, card: card) }
    }
}

/// Fixed-column poster grid that fills the width without stretching cards.
private struct FlexGrid<Item: Identifiable, Card: View>: View {
    let items: [Item]
    @ViewBuilder let card: (Item, CGFloat) -> Card
    @State private var width: CGFloat = 900
    @Environment(\.reddyDensity) private var density

    var body: some View {
        let layout = PosterGridLayout.compute(available: width, minCard: density.posterRange.min, maxCard: density.posterRange.max)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(layout.cardWidth), spacing: 12, alignment: .top), count: layout.columns), alignment: .leading, spacing: 16) {
            ForEach(items) { card($0, layout.cardWidth) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { g in Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w } })
    }
}

// MARK: - Discover

struct DiscoverPage: View {
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(AppRouter.self) private var router
    @State private var content: DiscoverContent?
    @State private var loaded = false
    @State private var slides: [FeaturedSlide] = []
    @State private var filter = DiscoverFilter()

    private var slideshowKey: String { "\(state.activeSourceID?.uuidString ?? "")-\(FeaturedPolicy.dayKey(Date()))-\(content != nil)" }

    /// The header and the toolbar stay put. The slideshow is the first thing in the scrolling region, so it scrolls up and out of the way with the rails.
    /// The region is clipped, so nothing can move the top navigation or the sidebar.
    var body: some View {
        GeometryReader { g in
            VStack(alignment: .leading, spacing: 10) {
                PageHead(title: "Discover")
                if let content, !content.shelves.isEmpty { toolbar(content) }
                ScrollView {
                    if state.hasLibrary, !slides.isEmpty {
                        FeaturedSlideshow(slides: slides, kicker: "DISCOVER · FROM YOUR LIBRARY", height: FeaturedLayout.bannerHeight(contentHeight: g.size.height),
                                          onPlay: { play($0.item) }, onInfo: { PlayActions.open($0.item, router: router) })
                            .padding(.bottom, 10)
                    }
                    VStack(alignment: .leading, spacing: 16) { rails }.padding(.bottom, 18).frame(maxWidth: .infinity, alignment: .leading)
                        .animation(AnimationTokens.page, value: loaded)
                }
                .scrollIndicators(.hidden).frame(maxHeight: .infinity).clipped()
            }
            .padding(.horizontal, LayoutTokens.gutter).padding(.top, 10)
        }
        .onAppear { state.reloadWatched() }
        .task(id: "\(state.activeSourceID?.uuidString ?? "")-\(state.catalogVersion)") {
            guard let c = container, state.hasLibrary else { loaded = true; return }
            let sid = state.activeSourceID
            let built = await Task.detached { try? c.discover.build(sourceID: sid) }.value
            content = built; loaded = true
        }
        // Keyed on the playlist and the day (and on whether content exists yet), not on filters or refreshes: choosing a
        // filter or a catalog update never rebuilds or restarts the slideshow.
        .task(id: slideshowKey) {
            guard let c = container, let content, state.hasLibrary else { return }
            let built = await c.featured.discoverSlides(ranked: DiscoverFilter.slideshowOrder(content.shelves), sourceID: state.activeSourceID)
            if !built.isEmpty || slides.isEmpty { slides = built }
        }
    }

    @ViewBuilder private var rails: some View {
        if !state.hasLibrary {
            EmptyStateView(symbol: "list.bullet.rectangle", title: "No playlist yet", message: "Add a playlist to start watching.", actionTitle: "Add playlist") { router.modal = .addPlaylist }.frame(height: 300)
        } else if !loaded {
            HStack(spacing: 11) { ForEach(0..<7, id: \.self) { _ in SkeletonBlock(width: 150, height: 218, radius: 8) } }
        } else if let content, !content.shelves.isEmpty {
            let shown = filter.apply(to: content.shelves)
            if shown.isEmpty {
                EmptyStateView(symbol: "line.3.horizontal.decrease.circle", title: "Nothing matches", message: "No titles match these filters. Clear them to see everything.", actionTitle: "Clear filters") { filter = DiscoverFilter() }.frame(height: 240)
            } else {
                ForEach(shown) { shelf in
                    ReddyRail(title: shelf.title, caption: shelf.caption, items: shelf.items) { item, index in
                        LibraryItemCard(item: item, rank: shelf.ranked ? index : nil)
                    }
                }
            }
        } else {
            EmptyStateView(symbol: "film.stack", title: "Nothing to discover yet", message: state.isSyncing ? "Your playlist is still loading." : "This playlist has no movies or series.").frame(height: 280)
        }
    }

    private func toolbar(_ content: DiscoverContent) -> some View {
        HStack(spacing: 10) {
            InlineSearchField(text: $filter.query, prompt: "Filter Discover…").frame(minWidth: 180, maxWidth: 320)
            Spacer(minLength: 8)
            Picker("Order", selection: $filter.mode) { ForEach(DiscoverMode.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            let languages = LanguageTags.available(in: content.shelves).prefix(14)
            if !languages.isEmpty {
                Menu {
                    Button { filter.language = nil } label: { Label("All languages", systemImage: filter.language == nil ? "checkmark" : "") }
                    Divider()
                    ForEach(Array(languages), id: \.language) { l in Button { filter.language = l.language } label: { Label("\(l.language) (\(l.count))", systemImage: filter.language == l.language ? "checkmark" : "") } }
                } label: { Label(filter.language ?? "Language", systemImage: "globe") }
                    .menuStyle(.button).fixedSize()
            }
            if !filter.isDefault { Button("Clear") { filter = DiscoverFilter() }.buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary) }
        }
    }

    private func play(_ item: LibraryItem) { if let c = container { PlayActions(container: c, toasts: state.toasts).play(item) } }
}

// MARK: - Continue Watching

struct ContinueWatchingPage: View {
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(AppRouter.self) private var router
    @State private var items: [ContinueItem] = []
    @State private var loaded = false
    @State private var confirmClear = false
    private var movies: [ContinueItem] { items.filter { if case .movie = $0.content { true } else { false } } }
    private var episodes: [ContinueItem] { items.filter { if case .episode = $0.content { true } else { false } } }

    var body: some View {
        PageScroll(title: "Continue Watching", trailing: items.isEmpty ? nil : AnyView(ClearMenu(options: [[.init("Clear Continue Watching…", destructive: true) { confirmClear = true }]]))) {
            if !loaded { ProgressView().controlSize(.small) }
            else if items.isEmpty { EmptyStateView(symbol: "play.circle", title: "Nothing to continue", message: "Start a movie or episode and it will wait for you here.").frame(height: 260) }
            else {
                if !movies.isEmpty {
                    ReddyRail(title: "Movies", caption: "\(movies.count) unfinished", items: movies) { ci, _ in resumeCard(ci) }
                }
                if !episodes.isEmpty {
                    ReddyRail(title: "Series", caption: "\(episodes.count) unfinished", items: episodes) { ci, _ in resumeCard(ci) }
                }
            }
        }
        .task(id: "\(state.activeSourceID?.uuidString ?? "")-\(state.catalogVersion)") { await load() }
        .confirmationDialog("Clear Continue Watching?", isPresented: $confirmClear) {
            Button("Clear Continue Watching", role: .destructive) { clearAll() }
        } message: { Text("Forgets where you stopped in every movie and episode of this playlist. Your watch history and favorites are not changed.") }
    }

    private func load() async {
        guard let c = container else { return }
        let sid = state.activeSourceID
        items = await Task.detached { (try? c.history.continueWatching(limit: 60, sourceID: sid)) ?? [] }.value
        loaded = true
    }

    private func clearAll() {
        guard let c = container else { return }
        let prefix = HistoryClearing.prefix(state.activeSourceID)
        items = []
        Task { await Task.detached { try? c.historyRepo.clearResumePoints(sourcePrefix: prefix) }.value; state.catalogVersion += 1 }
    }

    private func remove(_ ci: ContinueItem) {
        guard let c = container else { return }
        let id: String
        switch ci.content { case .movie(let m): id = m.id; case .episode(let e, _): id = e.id }
        items.removeAll { $0.id == ci.id }
        Task { await Task.detached { try? c.historyRepo.clearProgress(itemID: id) }.value; state.catalogVersion += 1 }
    }

    private func resumeCard(_ ci: ContinueItem) -> some View {
        Button { resume(ci) } label: {
            LandscapeCard(title: ci.title, subtitle: "\(DurationFormatter.short(max(0, ci.progress.durationSeconds - ci.progress.positionSeconds))) left", imageURL: ci.artworkURL, progress: ci.progress.fraction)
        }
        .buttonStyle(.plain).accessibilityLabel("Resume \(ci.title)")
        .contextMenu {
            Button("Resume") { resume(ci) }
            Divider()
            Button("Remove from Continue Watching", role: .destructive) { remove(ci) }
        }
    }

    private func resume(_ ci: ContinueItem) {
        switch ci.content {
        case .movie(let m): container?.playback.play(movie: m)
        case .episode(let e, let s): container?.playback.play(episode: e, series: s)
        }
    }
}

// MARK: - Recently Watched

struct RecentlyWatchedPage: View {
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @State private var channels: [Channel] = []
    @State private var movies: [Movie] = []
    @State private var series: [Series] = []
    @State private var loaded = false
    @State private var confirmClear = false
    private var isEmpty: Bool { channels.isEmpty && movies.isEmpty && series.isEmpty }

    var body: some View {
        PageScroll(title: "Recently Watched", trailing: isEmpty ? nil : AnyView(clearMenu)) {
            if !loaded { ProgressView().controlSize(.small) }
            else if isEmpty {
                EmptyStateView(symbol: "clock", title: "Nothing watched yet", message: "Channels, movies and shows you play appear here.").frame(height: 260)
            } else {
                if !channels.isEmpty {
                    ReddyRail(title: "Channels", items: channels) { ch, _ in
                        Button { container?.playback.play(channel: ch, queue: channels) } label: { ChannelCard(channel: ch) }
                            .buttonStyle(.plain).accessibilityLabel("Play \(ch.name)")
                            .contextMenu {
                                Button("Play") { container?.playback.play(channel: ch, queue: channels) }
                                Divider()
                                Button("Remove from Recently Watched", role: .destructive) { remove(ch.id) }
                            }
                    }
                }
                if !movies.isEmpty { ReddyRail(title: "Movies", items: movies) { m, _ in LibraryItemCard(item: .movie(m), width: 155, removal: ("Remove from Recently Watched", { remove(m.id) })) } }
                if !series.isEmpty { ReddyRail(title: "Series", items: series) { s, _ in LibraryItemCard(item: .series(s), width: 155, removal: ("Remove from Recently Watched", { remove(s.id) })) } }
            }
        }
        .task(id: "\(state.activeSourceID?.uuidString ?? "")-\(state.catalogVersion)") { await load() }
        .confirmationDialog("Clear everything in Recently Watched?", isPresented: $confirmClear) {
            Button("Clear Recently Watched", role: .destructive) { clear(nil) }
        } message: { Text("Empties these lists for this playlist. Your watch history log, Continue Watching and favorites are not changed.") }
    }

    private var clearMenu: some View {
        ClearMenu(options: [
            [.init("Clear Channels") { clear(.channel) }, .init("Clear Movies") { clear(.movie) }, .init("Clear Series") { clear(.series) }],
            [.init("Clear All…", destructive: true) { confirmClear = true }]])
    }

    private func load() async {
        guard let c = container else { return }
        let sid = state.activeSourceID
        let r = await Task.detached { ((try? c.history.recentChannels(limit: 24, sourceID: sid)) ?? [], (try? c.history.recentMovies(limit: 24, sourceID: sid)) ?? [], (try? c.history.recentSeries(limit: 24, sourceID: sid)) ?? []) }.value
        channels = r.0; movies = r.1; series = r.2; loaded = true
    }

    private func remove(_ id: String) {
        guard let c = container else { return }
        channels.removeAll { $0.id == id }; movies.removeAll { $0.id == id }; series.removeAll { $0.id == id }
        Task { await Task.detached { try? c.historyRepo.removeRecent(itemID: id) }.value }
    }

    private func clear(_ kind: ContentKind?) {
        guard let c = container else { return }
        let prefix = HistoryClearing.prefix(state.activeSourceID)
        if kind == nil || kind == .channel { channels = [] }
        if kind == nil || kind == .movie { movies = [] }
        if kind == nil || kind == .series { series = [] }
        Task { await Task.detached { try? c.historyRepo.clearRecent(kind: kind, sourcePrefix: prefix) }.value }
    }
}

// MARK: - Watch History

struct WatchHistoryPage: View {
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @State private var log: [HistoryService.LogItem] = []
    @State private var loaded = false
    @State private var confirm: Confirmation?

    private enum Confirmation: Identifiable { case allHistory, everything; var id: Self { self } }

    var body: some View {
        PageScroll(title: "Watch History", trailing: log.isEmpty ? nil : AnyView(clearMenu)) {
            if !loaded { ProgressView().controlSize(.small) }
            else if log.isEmpty { EmptyStateView(symbol: "list.bullet", title: "No history yet", message: "Each time you start playback it is logged here.").frame(height: 260) }
            else {
                LazyVStack(spacing: 0) {
                    ForEach(log) { item in
                        HistoryRow(item: item, icon: icon(item.entry.kind)) { remove(item) }
                        Divider().overlay(ColorTokens.line)
                    }
                }
                .surface()
            }
        }
        .task(id: "\(state.activeSourceID?.uuidString ?? "")-\(state.catalogVersion)") { await load() }
        .confirmationDialog(confirm == .everything ? "Clear all history and resume points?" : "Clear the whole watch history?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            if confirm == .everything { Button("Clear Everything", role: .destructive) { clearEverything() } }
            else { Button("Clear Watch History", role: .destructive) { clearLog(since: nil) } }
        } message: {
            Text(confirm == .everything
                 ? "Removes this playlist's watch history, Recently Watched lists and Continue Watching positions from this Mac. Favorites and collections are not changed."
                 : "Removes every entry in this list for this playlist. Recently Watched and Continue Watching are not changed.")
        }
    }

    private var clearMenu: some View {
        ClearMenu(options: [
            [.init("Clear Last Hour") { clearLog(since: Date().addingTimeInterval(-3600)) },
             .init("Clear Today") { clearLog(since: Calendar.current.startOfDay(for: Date())) },
             .init("Clear Last 7 Days") { clearLog(since: Date().addingTimeInterval(-7 * 86400)) }],
            [.init("Clear All History…", destructive: true) { confirm = .allHistory }],
            [.init("Clear Everything…", destructive: true) { confirm = .everything }]])
    }

    private func icon(_ k: ContentKind) -> String { k == .channel ? "dot.radiowaves.left.and.right" : k == .movie ? "film" : "rectangle.stack" }

    private func load() async {
        guard let c = container else { return }
        let sid = state.activeSourceID
        log = await Task.detached { (try? c.history.watchLog(limit: 200, sourceID: sid)) ?? [] }.value
        loaded = true
    }

    private func remove(_ item: HistoryService.LogItem) {
        guard let c = container else { return }
        log.removeAll { $0.id == item.id }
        let e = item.entry
        Task { await Task.detached { try? c.historyRepo.removeLogEntry(itemID: e.itemID, playedAt: e.playedAt) }.value }
    }

    private func clearLog(since: Date?) {
        guard let c = container else { return }
        let prefix = HistoryClearing.prefix(state.activeSourceID)
        Task { await Task.detached { try? c.historyRepo.clearLog(since: since, sourcePrefix: prefix) }.value; await load() }
    }

    private func clearEverything() {
        guard let c = container else { return }
        let prefix = HistoryClearing.prefix(state.activeSourceID)
        log = []
        Task {
            await Task.detached {
                try? c.historyRepo.clearLog(since: nil, sourcePrefix: prefix)
                try? c.historyRepo.clearRecent(kind: nil, sourcePrefix: prefix)
                try? c.historyRepo.clearResumePoints(sourcePrefix: prefix)
            }.value
            state.catalogVersion += 1
        }
    }
}

private struct HistoryRow: View {
    let item: HistoryService.LogItem
    let icon: String
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 12)).frame(width: 18).foregroundStyle(ColorTokens.textSecondary)
            Text(item.entry.title).font(Typography.row).lineLimit(1)
            Spacer()
            Text(item.entry.playedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 22).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(ColorTokens.textSecondary).help("Remove this entry")
                .opacity(hovering ? 1 : 0).accessibilityLabel("Remove \(item.entry.title) from history")
        }
        .padding(.horizontal, 12).frame(height: 34)
        .background(hovering ? Color.white.opacity(0.04) : .clear)
        .onHover { hovering = $0 }
        .animation(AnimationTokens.quick, value: hovering)
        .contextMenu { Button("Remove Entry", role: .destructive, action: onRemove) }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Favorites

struct FavoritesPage: View {
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @State private var channels: [Channel] = []
    @State private var movies: [Movie] = []
    @State private var series: [Series] = []
    @State private var loaded = false

    var body: some View {
        PageScroll(title: "Favorites") {
            if !loaded { ProgressView().controlSize(.small) }
            else if channels.isEmpty && movies.isEmpty && series.isEmpty {
                EmptyStateView(symbol: "heart", title: "No favorites yet", message: "Tap the heart on a channel, movie or series to keep it here.").frame(height: 260)
            } else {
                if !channels.isEmpty {
                    SectionHeader(title: "Channels")
                    ItemGrid(items: channels, cardWidth: 200) { ch, _ in
                        Button { container?.playback.play(channel: ch, queue: channels) } label: { ChannelCard(channel: ch) }
                            .buttonStyle(.plain).accessibilityLabel("Play \(ch.name)")
                    }
                }
                if !movies.isEmpty { SectionHeader(title: "Movies"); ItemGrid(items: movies) { m, w in LibraryItemCard(item: .movie(m), width: w) } }
                if !series.isEmpty { SectionHeader(title: "Series"); ItemGrid(items: series) { s, w in LibraryItemCard(item: .series(s), width: w) } }
            }
        }
        .task(id: "\(state.activeSourceID?.uuidString ?? "")-\(state.catalogVersion)-\(state.favoriteIDs.count)") {
            guard let c = container else { return }
            let sid = state.activeSourceID
            let r = await Task.detached { ((try? c.favorites.channels(sourceID: sid)) ?? [], (try? c.favorites.movies(sourceID: sid)) ?? [], (try? c.favorites.series(sourceID: sid)) ?? []) }.value
            channels = r.0; movies = r.1; series = r.2; loaded = true
        }
    }
}

// MARK: - Watch Later

/// Movies and series saved to watch later, newest first.
struct WatchLaterPage: View {
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @State private var items: [LibraryItem] = []
    @State private var loaded = false

    var body: some View {
        PageScroll(title: "Watch Later") {
            if !loaded { ProgressView().controlSize(.small) }
            else if items.isEmpty {
                EmptyStateView(symbol: "bookmark", title: "Nothing saved for later", message: "Tap the bookmark on a movie or series to keep it here.")
            } else {
                ItemGrid(items: items) { item, w in LibraryItemCard(item: item, width: w) }
            }
        }
        .task(id: "\(state.activeSourceID?.uuidString ?? "")-\(state.catalogVersion)-\(state.watchLaterIDs.count)") {
            guard let c = container else { return }
            let sid = state.activeSourceID
            items = await Task.detached { () -> [LibraryItem] in
                ((try? c.favoritesRepo.collectionItems(id: AppState.watchLaterListID)) ?? []).reversed().compactMap { entry -> LibraryItem? in
                    if entry.kind == .series { return (try? c.catalog.seriesItem(id: entry.itemID)).flatMap { $0 }.flatMap { sid == nil || $0.sourceID == sid ? .series($0) : nil } }
                    return (try? c.catalog.movie(id: entry.itemID)).flatMap { $0 }.flatMap { sid == nil || $0.sourceID == sid ? .movie($0) : nil }
                }
            }.value
            loaded = true
        }
    }
}

// MARK: - Collections

struct CollectionsPage: View {
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @State private var collections: [CatalogCollection] = []
    @State private var selectedID: String?
    @State private var channels: [Channel] = []
    @State private var movies: [Movie] = []
    @State private var series: [Series] = []
    @State private var confirmDelete: CatalogCollection?

    var body: some View {
        PageScroll(title: "Collections") {
            HStack(spacing: 8) {
                ForEach(collections) { col in
                    Button { selectedID = col.id } label: {
                        Text("\(col.name) · \(col.itemCount)").font(Typography.row).padding(.horizontal, 11).frame(height: 28)
                            .background(selectedID == col.id ? Color.white.opacity(0.09) : Color.white.opacity(0.04), in: Capsule())
                            .foregroundStyle(selectedID == col.id ? ColorTokens.textPrimary : ColorTokens.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { Button("Rename…") { rename(col) }; Button("Delete", role: .destructive) { confirmDelete = col } }
                }
                Button { create() } label: { Label("New collection", systemImage: "plus").font(Typography.row).padding(.horizontal, 11).frame(height: 28).overlay(Capsule().strokeBorder(ColorTokens.glassEdge)) }
                    .buttonStyle(.plain)
                Spacer()
            }
            if collections.isEmpty {
                EmptyStateView(symbol: "square.stack", title: "No collections yet", message: "Right-click any channel, movie or series and choose Add to Collection.").frame(height: 240)
            } else if channels.isEmpty && movies.isEmpty && series.isEmpty {
                EmptyStateView(symbol: "tray", title: "This collection is empty", message: "Right-click an item and choose Add to Collection.").frame(height: 220)
            } else {
                if !channels.isEmpty {
                    SectionHeader(title: "Channels")
                    ItemGrid(items: channels, cardWidth: 200) { ch, _ in
                        Button { container?.playback.play(channel: ch, queue: channels) } label: { ChannelCard(channel: ch) }
                            .buttonStyle(.plain)
                            .contextMenu { Button("Play") { container?.playback.play(channel: ch, queue: channels) }; Button("Remove from collection") { remove(ch.id) } }
                    }
                }
                if !movies.isEmpty { SectionHeader(title: "Movies"); ItemGrid(items: movies) { m, w in LibraryItemCard(item: .movie(m), width: w).contextMenu { Button("Remove from collection") { remove(m.id) } } } }
                if !series.isEmpty { SectionHeader(title: "Series"); ItemGrid(items: series) { s, w in LibraryItemCard(item: .series(s), width: w).contextMenu { Button("Remove from collection") { remove(s.id) } } } }
            }
        }
        .task(id: "\(state.catalogVersion)-\(state.activeSourceID?.uuidString ?? "")") { await load() }
        .task(id: selectedID) { await loadItems() }
        .confirmationDialog("Delete “\(confirmDelete?.name ?? "")”?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete Collection", role: .destructive) { if let col = confirmDelete { try? container?.favoritesRepo.deleteCollection(id: col.id); Task { await load() } } }
        } message: { Text("The items themselves stay in your library.") }
    }

    private func load() async {
        guard let c = container else { return }
        collections = (try? c.favoritesRepo.collections()) ?? []
        if selectedID == nil || !collections.contains(where: { $0.id == selectedID }) { selectedID = collections.first?.id }
        await loadItems()
    }

    private func loadItems() async {
        guard let c = container, let id = selectedID else { channels = []; movies = []; series = []; return }
        let sid = state.activeSourceID
        let r = await Task.detached { () -> ([Channel], [Movie], [Series]) in
            let items = (try? c.favoritesRepo.collectionItems(id: id)) ?? []
            func ids(_ k: ContentKind) -> [String] { items.filter { $0.kind == k }.map(\.itemID) }
            let ch = ids(.channel).isEmpty ? [] : ((try? c.catalog.channels(ChannelQuery(sourceID: sid, collapseVariants: false, ids: ids(.channel)))) ?? [])
            let mv = ids(.movie).isEmpty ? [] : ((try? c.catalog.movies(VODQuery(sourceID: sid, ids: ids(.movie)))) ?? [])
            let sr = ids(.series).isEmpty ? [] : ((try? c.catalog.series(VODQuery(sourceID: sid, ids: ids(.series)))) ?? [])
            return (ch, mv, sr)
        }.value
        channels = r.0; movies = r.1; series = r.2
    }

    private func remove(_ itemID: String) {
        guard let c = container, let id = selectedID else { return }
        try? c.favoritesRepo.remove(itemID: itemID, fromCollection: id)
        Task { await load() }
    }

    private func create() {
        NewCollectionPrompt.run { name in
            if let c = container, let col = try? c.favoritesRepo.createCollection(name: name) { selectedID = col.id; Task { await load() } }
        }
    }

    private func rename(_ col: CatalogCollection) {
        let alert = NSAlert(); alert.messageText = "Rename Collection"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); field.stringValue = col.name
        alert.accessoryView = field; alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, let c = container { try? c.favoritesRepo.renameCollection(id: col.id, name: field.stringValue); Task { await load() } }
    }
}
