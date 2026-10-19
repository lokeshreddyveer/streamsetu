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
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var wide: Bool { sizeClass == .regular }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !featured.isEmpty { FeaturedBanner(items: featured, height: wide ? 340 : 260, scrollY: scrollY) }
                    if !resume.isEmpty {
                        Shelf(title: "Continue Watching") {
                            ForEach(resume) { r in
                                Button { play(r) } label: { WideCard(title: r.title, subtitle: Self.remaining(r), imageURL: r.artworkURL, progress: r.progress.fraction, width: wide ? 320 : 240) }.buttonStyle(.press)
                            }
                        }
                    }
                    if !upNext.isEmpty {
                        Shelf(title: "Up Next") {
                            ForEach(upNext) { u in
                                Button { if let container { Play.episode(u.episode, u.series, container) } } label: {
                                    WideCard(title: u.series.title, subtitle: "S\(u.episode.seasonNumber) E\(u.episode.episodeNumber) · \(u.episode.title)",
                                             imageURL: u.episode.imageURL ?? u.series.backdropURL ?? u.series.posterURL,
                                             progress: nil, width: wide ? 320 : 240)
                                }.buttonStyle(.press)
                            }
                        }
                    }
                    if !watchLater.isEmpty {
                        Shelf(title: "Watch Later") {
                            ForEach(watchLater) { item in
                                NavigationLink(value: item) { PosterCard(item: item, width: wide ? 160 : 120) }.buttonStyle(.press).contextMenu { TitleMenu(item: item) }
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
                            }
                        }
                    }
                    ForEach(content?.shelves ?? []) { shelf in
                        Shelf(title: shelf.title, caption: shelf.caption) {
                            ForEach(shelf.items) { item in
                                NavigationLink(value: item) { PosterCard(item: item, width: wide ? 160 : 120) }.buttonStyle(.press)
                            }
                        }
                    }
                    if loaded, content?.shelves.isEmpty ?? true, resume.isEmpty {
                        EmptyState(symbol: state.isSyncing ? "arrow.triangle.2.circlepath" : "tray", title: state.isSyncing ? "Loading your library…" : "Nothing here yet",
                                   message: state.isSyncing ? "Movies and series appear as soon as the playlist has been read." : "This playlist has no movies or series. Live channels are in the Live TV tab.")
                    }
                }
                .padding(.vertical, 12)
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, v in scrollY = v }
            .navigationTitle("Home").themed("Home")
            .navigationDestination(for: LibraryItem.self) { DetailView(item: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { SyncIndicator() }
                TrailingPills {
                    NavigationLink { SearchView(embedded: true) } label: { Image(systemName: "magnifyingglass").pillIcon() }.accessibilityLabel("Search")
                }
            }
            .refreshable { state.syncAll() }
            .miniPlayerInset()
        }
        .onAppear { state.reloadWatched() }
        .task(id: "\(state.activeSourceID?.uuidString ?? "")-\(state.catalogVersion)-\(state.watchLaterIDs.count)") { await load() }
        // Back from the player: Continue Watching and Recently Watched Channels show what was just played (not before, so nothing runs while it plays).
        .onChange(of: container?.playback.isExpanded ?? false) { old, now in if old && !now { Task { await load() } } }
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
        featured = await Task.detached { (try? c.discover.featured(sourceID: source, kinds: [.movie, .series], count: 6, seed: FeaturedPicker.launchSeed)) ?? [] }.value
        let (built, items, channels, now) = await Task.detached { () -> (DiscoverContent?, [ContinueItem], [Channel], [String: String]) in
            let chans = (try? c.history.recentChannels(limit: 12, sourceID: source)) ?? []
            let at = Date()
            let guide = (try? c.epgRepo.nowNext(channelIDs: chans.map(\.id), at: at)) ?? [:]
            return (try? c.discover.build(sourceID: source), (try? c.history.continueWatching(limit: 12, sourceID: source)) ?? [], chans,
                    guide.compactMapValues { $0.first { $0.isLive(at: at) }?.title })
        }.value
        let (next, top) = await Task.detached { ((try? c.history.upNext(sourceID: source)) ?? [], (try? c.history.mostWatchedChannels(sourceID: source)) ?? []) }.value
        content = built; resume = items; recentChannels = channels; nowPlaying = now; upNext = next; topChannels = top; loaded = true
    }

    /// "Resume · 45m left" (or the episode, for a series).
    static func remaining(_ r: ContinueItem) -> String {
        let left = max(0, r.progress.durationSeconds - r.progress.positionSeconds)
        let time = left > 60 ? "\(DurationFormatter.short(left)) left" : "almost done"
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
