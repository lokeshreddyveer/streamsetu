import SwiftUI

/// Home: what to watch next, built from the library on this device.
struct HomeView: View {
    @Environment(AppState.self) private var state
    @Environment(IOSRouter.self) private var router
    @Environment(\.container) private var container
    @State private var content: DiscoverContent?
    @State private var resume: [ContinueItem] = []
    @State private var recentChannels: [Channel] = []
    @State private var nowPlaying: [String: String] = [:]
    @State private var scrollY: CGFloat = 0
    @State private var loaded = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var wide: Bool { sizeClass == .regular }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let hero = content?.hero { HeroCard(item: hero, height: wide ? 340 : 260, scrollY: scrollY) }
                    if !resume.isEmpty {
                        Shelf(title: "Continue Watching") {
                            ForEach(resume) { r in
                                Button { play(r) } label: { WideCard(title: r.title, subtitle: Self.remaining(r), imageURL: r.artworkURL, progress: r.progress.fraction, width: wide ? 320 : 240) }.buttonStyle(.press)
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
        .task(id: "\(state.activeSourceID?.uuidString ?? "")-\(state.catalogVersion)") { await load() }
    }

    private func load() async {
        guard let c = container else { return }
        let source = state.activeSourceID
        let (built, items, channels, now) = await Task.detached { () -> (DiscoverContent?, [ContinueItem], [Channel], [String: String]) in
            let chans = (try? c.history.recentChannels(limit: 12, sourceID: source)) ?? []
            let at = Date()
            let guide = (try? c.epgRepo.nowNext(channelIDs: chans.map(\.id), at: at)) ?? [:]
            return (try? c.discover.build(sourceID: source), (try? c.history.continueWatching(limit: 12, sourceID: source)) ?? [], chans,
                    guide.compactMapValues { $0.first { $0.isLive(at: at) }?.title })
        }.value
        content = built; resume = items; recentChannels = channels; nowPlaying = now; loaded = true
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

private struct HeroCard: View {
    let item: LibraryItem
    var height: CGFloat = 260
    var scrollY: CGFloat = 0

    var body: some View {
        NavigationLink(value: item) {
            ZStack(alignment: .bottomLeading) {
                ParallaxBanner(height: height, scrollY: scrollY) {
                    ArtworkImage(url: item.backdropURL ?? item.posterURL, kind: .backdrop, contentMode: .fill, symbol: "film")
                }
                LinearGradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.88)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).appFont(height > 280 ? 30 : 22, .bold).lineLimit(2)
                    HStack(spacing: 8) {
                        if !item.detailLine.isEmpty { Text(item.detailLine) }
                        if let r = item.ratingValue { Label(String(format: "%.1f", r), systemImage: "star.fill").labelStyle(.titleAndIcon).foregroundStyle(.yellow) }
                    }.appFont(12, .medium).foregroundStyle(.white.opacity(0.8))
                    if let o = item.overview, !o.isEmpty { Text(o).appFont(13).foregroundStyle(.white.opacity(0.78)).lineLimit(2) }
                    Label("Play", systemImage: "play.fill").appFont(13, .semibold).foregroundStyle(.black)
                        .padding(.horizontal, 16).padding(.vertical, 7).background(.white, in: Capsule()).padding(.top, 2)
                }.padding(16)
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)).padding(.horizontal, 16)
        }
        .buttonStyle(.press)
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
