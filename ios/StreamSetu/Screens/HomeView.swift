import SwiftUI

/// Home: what to watch next, built from the library on this device.
struct HomeView: View {
    @Environment(AppState.self) private var state
    @Environment(IOSRouter.self) private var router
    @Environment(\.container) private var container
    @State private var content: DiscoverContent?
    @State private var featured: [LibraryItem] = []
    @State private var resume: [ContinueItem] = []
    @State private var recentChannels: [Channel] = []
    @State private var topChannels: [Channel] = []
    @State private var upNext: [HistoryService.UpNextEntry] = []
    @State private var watchLater: [LibraryItem] = []
    @State private var nowPlaying: [String: String] = [:]
    @State private var scrollY: CGFloat = 0
    @State private var loaded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The view switch of a ranked shelf rebuilds only that shelf; a newer tap on the same shelf cancels the older build.
    @State private var modeTasks: [String: Task<Void, Never>] = [:]
    /// A genre list, pushed by value like every other destination in this stack (titles opened from it push above it).
    struct GenreRoute: Hashable { let key: String }
    /// A franchise tile's titles, pushed like a genre list.
    struct CollectionRoute: Hashable { let tile: CollectionTile; static func == (a: Self, b: Self) -> Bool { a.tile.id == b.tile.id }; func hash(into h: inout Hasher) { h.combine(tile.id) } }
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var wide: Bool { sizeClass == .regular }
    /// About half the screen, plus the status bar it runs under, so the first shelf peeks in below.
    private var heroHeight: CGFloat { HeroMetrics.height(wide: wide, share: 0.6) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HomeLayout.rowGap) {
                    if !featured.isEmpty { FeaturedBanner(items: featured, height: heroHeight, scrollY: scrollY, immersive: true) }
                    if let container { OfflineHomeBanner(container: container).padding(.horizontal, 16) }
                    if let container { NowPlayingStrip(container: container).padding(.horizontal, 16) }
                    if !resume.isEmpty {
                        Shelf(title: SMNaming.continueWatching.title, caption: SMNaming.continueWatching.subtitle) {
                            ForEach(resume) { r in
                                Button { play(r) } label: { WideCard(title: r.title, subtitle: Self.remaining(r), imageURL: r.artworkURL, progress: r.progress.fraction, width: wide ? 320 : 240, rating: { switch r.content { case .movie(let m): RatingRule.credible(m.rating); case .episode(_, let s): RatingRule.credible(s.rating) } }()) }.buttonStyle(.press)
                                    .continueTileMenu(r)
                                    .atlas("control.ios.home.continue")
                            }
                        }
                    }
                    if !upNext.isEmpty {
                        Shelf(title: "Up Next") {
                            ForEach(upNext) { u in
                                Button { if let container { Play.episode(u.episode, u.series, container) } } label: {
                                    WideCard(title: u.series.title, subtitle: "S\(u.episode.seasonNumber) E\(u.episode.episodeNumber) · \(u.episode.title)",            imageURL: u.episode.imageURL ?? u.series.backdropURL ?? u.series.posterURL,
                                             progress: nil, width: wide ? 320 : 240)
                                }.buttonStyle(.press)
                                .atlas("control.ios.home.upNext")
                            }
                        }
                    }
                    if !watchLater.isEmpty {
                        Shelf(title: "Watch Later") {
                            ForEach(watchLater) { item in
                                NavigationLink(value: item) { PosterCard(item: item, width: wide ? 160 : 120) }.buttonStyle(.press).titleTileMenu(item).atlas("context.tile.menu")
                            }
                        }
                    }
                    if !recentChannels.isEmpty {
                        Shelf(title: "Recently Watched Channels") {
                            ForEach(recentChannels) { c in
                                Button { if let container { Play.channel(c, queue: recentChannels, container) } } label: {
                                    VStack(spacing: 4) {
                                        ChannelLogo(url: c.logoURL, name: c.name, size: wide ? 96 : 72)
                                        Text(c.name).appFont(11, .semibold).lineLimit(1).frame(width: wide ? 110 : 84)
                                        if let p = nowPlaying[c.id] { Text(p).appFont(10).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center).frame(width: wide ? 110 : 84) }
                                    }
                                }.buttonStyle(.press)
                                .atlas("control.ios.home.channel")
                            }
                        }
                    }
                    if !topChannels.isEmpty {
                        Shelf(title: "Your Channels") {
                            ForEach(topChannels) { c in
                                Button { if let container { Play.channel(c, queue: topChannels, container) } } label: {
                                    VStack(spacing: 4) {
                                        ChannelLogo(url: c.logoURL, name: c.name, size: wide ? 96 : 72)
                                        Text(c.name).appFont(11, .semibold).lineLimit(1).frame(width: wide ? 110 : 84)
                                        if let p = nowPlaying[c.id] { Text(p).appFont(10).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center).frame(width: wide ? 110 : 84) }
                                    }
                                }.buttonStyle(.press)
                                .atlas("control.ios.home.channel")
                            }
                        }
                    }
                    // The rows rise in one after another the first time Home appears.
                    ForEach(Array((content?.shelves ?? []).enumerated()), id: \.element.id) { shelfIndex, shelf in
                        let labels = DisplayTitle.labels(shelf.items.map { ($0.id, $0.title) })
                        if !shelf.collections.isEmpty {
                            Shelf(title: shelf.title, caption: shelf.caption) {
                                ForEach(shelf.collections) { tile in
                                    NavigationLink(value: CollectionRoute(tile: tile)) { CollectionTileCard(tile: tile, width: wide ? 160 : 120, onOpen: {}).allowsHitTesting(false) }.buttonStyle(.press).atlasCovers("control.home.collection")
                                }
                            }.staggeredAppear(shelfIndex)
                        } else {
                        Shelf(title: shelf.title, caption: shelf.caption, mode: shelf.mode, onMode: { m in setMode(m, shelf) },seeAll: shelf.genre.map { key in AnyView(NavigationLink(value: GenreRoute(key: key)) { SeeAllLabel() }.buttonStyle(.plain).accessibilityHint("Shows all titles").atlas("control.ios.home.seeAll")) }) {
                            ForEach(shelf.items) { item in
                                NavigationLink(value: item) { PosterCard(item: item, width: wide ? 160 : 120, displayTitle: labels[item.id], uniformHeight: true) }.buttonStyle(.press).titleTileMenu(item).atlas("context.tile.menu")
                            }
                        }
                        .staggeredAppear(shelfIndex)
                        }
                    }
                    if !loaded { ForEach(0..<3, id: \.self) { _ in ShelfSkeleton(tileWidth: wide ? 160 : 120, tiles: wide ? 8 : 3).padding(.horizontal, ShelfLayout.inset) } }
                    if let genres = content?.browseGenres, !genres.isEmpty {
                        Shelf(title: SMNaming.browseByGenre) {
                            ForEach(genres) { g in
                                NavigationLink(value: GenreRoute(key: g.key)) {
                                    Text(SMGenres.byKey[g.key]?.name.loc ?? LocalizedStringKey(g.title)).appFont(13, .medium).lineLimit(1).padding(.horizontal, 14).frame(minHeight: 44)
                                        .background(Color.primary.opacity(0.10), in: Capsule())
                                }.buttonStyle(.plain).accessibilityLabel(Text("\(g.title), \(g.count) titles"))
                                .atlas("control.ios.home.genre")
                            }
                        }
                    }
                    if loaded, content?.shelves.isEmpty ?? true, resume.isEmpty {
                        EmptyState(symbol: state.isSyncing ? "arrow.triangle.2.circlepath" : "tray", title: state.isSyncing ? "Loading your library…" : "Nothing here yet",
                                   message: state.isSyncing ? "Movies and series appear as soon as the playlist has been read." : "This playlist has no movies or series. Live channels are in the Live TV tab.")
                    }
                }
                .padding(.top, featured.isEmpty ? UIScreen.safeTop + 12 : 0).padding(.bottom, 12)
            }
            .ignoresSafeArea(edges: .top)          // the featured artwork runs up under the status bar
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, v in scrollY = v }
            .navigationTitle("Home").atlasScreen("screen.ios.tab.home").themed("Home", tabRoot: true)
            .titleAndPersonDestinations()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { SyncIndicator() }
                TrailingPills {
                    Button { state.shuffleRecommendations(); Haptics.tap() } label: { Image(systemName: "shuffle").pillIcon() }
                        .accessibilityLabel("Shuffle recommendations").accessibilityHint("Picks a new mix. Does not refresh your library.")
                        .atlas("control.ios.home.shuffle")
                    NavigationLink(value: ToolRoute.search(.all)) { Image(systemName: "magnifyingglass").pillIcon() }.accessibilityLabel("Search").atlas("control.ios.home.search")
                }
            }
            .refreshable { state.syncAll() }
            .miniPlayerInset()
        }
        .onAppear { state.reloadWatched() }
        .task(id: "\(state.activeSourceID?.uuidString ?? "")-\(state.catalogVersion)-\(state.watchLaterIDs.count)-\(state.shuffleTick)") {
            await load(); container?.smartMix.refreshTrendingIfNeeded()
            container?.smartMix.refreshListsIfNeeded(genres: (content?.shelves ?? []).compactMap(\.genre))
            if let c = container {
                let warm = (content?.shelves ?? []).compactMap { sh in sh.smartID.flatMap { id in sh.mode.map { (id: id, mode: $0) } } }
                await c.smartMix.warmOtherViews(profile: c.profiles.activeID, sourceID: state.activeSourceID, preferredLanguage: c.settings.preferredAudioLanguage, shelves: warm, kids: c.parental.kidsMode)
            }
        }
        .navigationDestination(for: GenreRoute.self) { genreList($0.key) }
        .navigationDestination(for: CollectionRoute.self) { r in
            CollectionGrid(tile: r.tile, width: wide ? 160 : 108) { item in NavigationLink(value: item) { PosterCard(item: item, width: wide ? 160 : 108, uniformHeight: true) }.buttonStyle(.press).atlasCovers("context.tile.menu") }.navigationTitle(r.tile.name)
        }
        // Back from the player: Continue Watching and Recently Watched Channels show what was just played (not before, so nothing runs while it plays).
        .onChange(of: container?.playback.isExpanded ?? false) { old, now in if old && !now { Task { await load() } } }
    }

    private func setMode(_ m: SMShelfMode, _ shelf: DiscoverShelf) {
        guard let c = container, let id = shelf.smartID, shelf.mode != m else { return }
        let profile = c.profiles.activeID, source = state.activeSourceID, lang = c.settings.preferredAudioLanguage, kids = c.parental.kidsMode
        c.smartMix.setMode(m, profile: profile, shelf: id)
        if var cur = content, let i = cur.shelves.firstIndex(where: { $0.id == shelf.id }) { cur.shelves[i].mode = m; content = cur }      // the control answers at once
        modeTasks[id]?.cancel()
        modeTasks[id] = Task {
            guard let new = await c.smartMix.shelfView(profile: profile, sourceID: source, preferredLanguage: lang, smartID: id, mode: m, kids: kids, avoid: Set((content?.shelves ?? []).filter { $0.id != shelf.id }.flatMap { $0.items.map(\.id) })), !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { content = content?.replacingShelf(new) }
        }
    }

    /// The full list of a genre: Movies (Series for a series-only genre) with that genre chosen and the best rated first.
    @ViewBuilder private func genreList(_ key: String) -> some View {
        if let g = SMGenres.byKey[key] {
            let kind: ContentKind = g.scope == .series ? .series : .movie
            let model = { () -> LibraryModel in
                let m = LibraryModel(kind: kind)
                m.filter.genreName = g.name; m.filter.genres = g.words; m.sort = .rating
                return m
            }()
            LibraryView(kind: kind, model: model).navigationTitle(g.name)
        }
    }

    private func load() async {
        guard let c = container else { return }
        let source = state.activeSourceID
        watchLater = await Task.detached { () -> [LibraryItem] in
            ((try? c.favoritesRepo.collectionItems(id: AppState.watchLaterListID)) ?? []).reversed().prefix(20).compactMap { entry -> LibraryItem? in
                if entry.kind == .series { return (try? c.catalog.seriesItem(id: entry.itemID)).flatMap { $0 }.map { .series($0) } }
                return (try? c.catalog.movie(id: entry.itemID)).flatMap { $0 }.map { .movie($0) }
            }
        }.value
        let smart = await c.smartMix.home(profile: c.profiles.activeID, sourceID: source, preferredLanguage: c.settings.preferredAudioLanguage, kids: c.parental.kidsMode)
        if let order = smart?.heroOrder, !order.isEmpty {
            featured = Array(order.filter { $0.posterURL != nil || $0.backdropURL != nil }.prefix(6))
        } else {
            featured = await Task.detached { (try? c.discover.featured(sourceID: source, kinds: [.movie, .series], count: 6, seed: FeaturedPicker.launchSeed)) ?? [] }.value
        }
        let (built, items, channels, now) = await Task.detached { () -> (DiscoverContent?, [ContinueItem], [Channel], [String: String]) in
            let chans = (try? c.history.recentChannels(limit: 12, sourceID: source)) ?? []
            let at = Date()
            let guide = (try? c.epgRepo.lookup(channelIDs: chans.map(\.id), at: at)) ?? [:]
            return (try? c.discover.build(sourceID: source, smart: smart), (try? c.history.continueWatching(limit: 12, sourceID: source)) ?? [], chans,
                    guide.compactMapValues { $0.now?.title })
        }.value
        let (next, top) = await Task.detached { ((try? c.history.upNext(sourceID: source)) ?? [], (try? c.history.mostWatchedChannels(sourceID: source)) ?? []) }.value
        content = built; resume = items; recentChannels = channels; nowPlaying = now; upNext = next; topChannels = top; loaded = true
    }

    /// "Resume · 45m left" (or the episode, for a series).
    static func remaining(_ r: ContinueItem) -> String {
        let left = max(0, r.progress.durationSeconds - r.progress.positionSeconds)
        let time = left > 60 ? Localized.string("%@ left", DurationFormatter.short(left)) : Localized.string("almost done")
        if case .episode(let e, _) = r.content { return "S\(e.seasonNumber) E\(e.episodeNumber) · \(time)" }
        return "Resume · \(time)"
    }

    private func play(_ r: ContinueItem) {
        guard let c = container else { return }
        switch r.content {
        case .movie(let m): Play.movie(m, c)
        case .episode(let e, let s): Play.episode(e, s, c)
        }
    }
}


/// A small spinner while a playlist is being read, so a long first sync never looks stuck.
struct SyncIndicator: View {
    @Environment(AppState.self) private var state
    var body: some View {
        if state.isSyncing {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Updating").font(.caption).foregroundStyle(.secondary) }
        }
    }
}


extension View {
    /// Continue Watching: the shared tile menu. Removing writes only the Continue Watching marker; progress, resume point and history stay.
    func continueTileMenu(_ r: ContinueItem) -> some View { modifier(ContinueTileMenu(r: r)) }
}

private struct ContinueTileMenu: ViewModifier {
    let r: ContinueItem
    @Environment(\.container) private var container
    @Environment(IOSRouter.self) private var router
    func body(content: Content) -> some View {
        let item = r.libraryItem
        var h = IOSTileHandlers.make(item, container: container, router: router)
        h.play = { guard let c = container else { return }; switch r.content { case .movie(let m): Play.movie(m, c); case .episode(let e, let s): Play.episode(e, s, c) } }
        h.playPrivately = { guard let c = container else { return }; switch r.content { case .movie(let m): Play.movie(m, c, privately: true); case .episode(let e, let s): Play.episode(e, s, c, privately: true) } }
        h.continueID = r.id
        return content.tileMenu(item, kind: .continueWatching, handlers: h)
    }
}
